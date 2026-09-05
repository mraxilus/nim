## A connection between two hands: whether a pose of it holds, and finding
## the most comfortable one that does.
##
##   A connection is two arms meeting at one grip.  Where the grip is, which
##     way each hand points off its wrist, and where each elbow sits on its
##     circle are the nine numbers of a pose; every other point follows from
##     the rig.  Evaluating a pose reads every joint against its range, every
##     link against both bodies and against the other arm, and the grip
##     against the band the hands are carried in.
##   Two measures, two jobs.  Whether a pose *holds* is a set of hard tests,
##     and where it fails the largest failure is named -- the joint, or the
##     body part and whose.  Among the poses that hold, the one returned is
##     the one with the least comfort cost: the joints nearest their rest,
##     the arm lowest, the hands lowest in their band.  The cost is smooth,
##     so neighbouring turns get neighbouring poses.
##   The search is a pattern search: try each number a step either way, keep
##     the best improvement, halve the steps when nothing improves.  Seeded
##     from a grid over the grip with each arm laid out independently, since
##     for a fixed grip the two arms only meet in the arm-against-arm test.
##     Deterministic throughout: the same question gets the same answer.
##     Cost of a local search: a pose that holds may go unfound.  Accepted --
##       the seed is a grid, the laws check a coarse seed against a fine one,
##       and a block is reported with whether any pose exists there at all.

{.experimental: "strictFuncs".}

import std/[math, options]

import ./[body, contact, limb, rig, vec]


type
  Link* = object ## One connection: which two hands it joins.
    ends*: array[2, Hand]

  Params* = object ## The nine numbers of a connection's pose.
    g*: Vec ## The grip.
    h*: array[2, Vec] ## Unit: which way each hand points off its wrist.
    swivel*: array[2, float] ## Each elbow's place on its circle.

  Reason* {.pure.} = enum ## What stops a pose, one thing at a time.
    None,     ## Nothing: it holds.
    Reach,    ## The grip is further than the arm is long.
    Shoulder, ## The upper arm too far behind or across.
    Twist,    ## The upper arm turned too far in or out.
    Elbow,    ## Bent past what an elbow does.
    Wrist,    ## The hand too far off the forearm.
    Through,  ## A link through a body.
    Arms,     ## Two arms through each other.
    Band      ## The grip out of the band the hands are carried in.

  LinkFit* = object ## What evaluating one connection found.
    arms*: array[2, ArmPose]
    joints*: array[2, Joints]
    strain*: float ## The worst joint's strain, nought to one and past.
    strainedArm*: int
    strainedDof*: Dof

  Verdict* = object ## What evaluating a whole state found.
    ok*: bool
    reason*: Reason
    part*: Part    ## For `Through`: which part.
    whose*: Body   ## For `Through`: whose.
    link*, arm*: int ## Which connection and which of its arms is at fault.
    dof*: Dof      ## For a joint's refusal: which joint.
    worst*: float  ## The largest failure, in units of its own ease; nought when it holds.
    penalty*: float ## Every failure squared and summed: smooth, for climbing out.
    strain*: float ## The worst strain over every arm.
    cost*: float   ## The comfort cost, summed.
    fits*: array[2, LinkFit]
    n*: int        ## How many of `fits` are real.

  State* = object ## The whole world as one plain value.
    rig*: Rig
    stance*: array[Body, Stance]
    band*: Band
    links*: seq[Link]
    params*: seq[Params] ## One per link once solved; empty until then.
    overhead*: bool ## Whether hands over the crown are held over `turning`'s
                    ## head rather than between the shoulders: a couple sets
                    ## a hold up for the turn they are about to do.
    turning*: Body


const
  TOLERANCE* = 0.1 ## A failure smaller than this holds: under three degrees
                   ## at a joint, under five millimetres at a body -- less than
                   ## flesh gives.  Without it a search converging onto a
                   ## contact from outside never arrives.
  CENTRING = [2.0, 2.0, 0.5] ## Per band, the weight of the grip's distance
    ## from between the shoulders.  Light over the crown: a hand held over a
    ## head is held over the turning partner's head, not between the two.
  EXCUSE = 0.15  ## Two arms holding one grip may converge within this of it.
  SLACK = 0.05   ## The unit a reach or band overshoot is counted in, metres.
  DIRS14 = block:
    var d: seq[Vec]
    for x in [-1.0, 0.0, 1.0]:
      for y in [-1.0, 0.0, 1.0]:
        for z in [-1.0, 0.0, 1.0]:
          if (x == 0.0 and y == 0.0) or (x == 0.0 and z == 0.0) or
             (y == 0.0 and z == 0.0):
            if not (x == 0.0 and y == 0.0 and z == 0.0):
              d.add unit((x, y, z))
          elif x != 0.0 and y != 0.0 and z != 0.0:
            d.add unit((x, y, z))
    d
  DIRS26 = block:
    var d: seq[Vec]
    for x in [-1.0, 0.0, 1.0]:
      for y in [-1.0, 0.0, 1.0]:
        for z in [-1.0, 0.0, 1.0]:
          if not (x == 0.0 and y == 0.0 and z == 0.0):
            d.add unit((x, y, z))
    d


#[ Evaluating ]#


func worse(v: var Verdict; amount: float; reason: Reason; link, arm: int) =
  ## Record a failure: into the sum always, as the largest if it is.
  v.penalty += amount * amount
  if amount > v.worst:
    v.worst = amount
    v.reason = reason
    v.link = link
    v.arm = arm


func fitArm(s: State; hand: Hand; g, h: Vec; swivel: float;
            v: var Verdict; link, arm: int): tuple[pose: ArmPose, joints: Joints, cost: float] =
  ## Lay one arm to the grip and read everything about it on its own.
  let
    st = s.stance[hand.body]
    sh = shoulder(s.rig, st, hand.arm)
    chain = posed(s.rig, sh, g, h, swivel)
  result.pose = chain.pose
  result.joints = joints(st, hand.arm, chain.pose)
  let over = chain.stretch - (s.rig.upper + s.rig.fore)
  if over > 0.0:
    worse(v, over / SLACK, Reason.Reach, link, arm)
  for dof in Dof:
    let m = margin(s.rig.range[dof], reading(result.joints, dof))
    if m < 0.0:
      let why = case dof
        of Dof.Extend, Dof.Across: Reason.Shoulder
        of Dof.Twist: Reason.Twist
        of Dof.Bend: Reason.Elbow
        of Dof.Wrist: Reason.Wrist
      if -m > v.worst:
        v.dof = dof
      worse(v, -m, why, link, arm)
  let p = chain.pose
  for (a, b) in [(p.s, p.e), (p.e, p.w), (p.w, p.g)]:
    for who in Body:
      let t = bodyGap(s.rig, s.stance[who], a, b, own = who == hand.body)
      if t.gap < 0.0:
        if -t.gap / s.rig.limb > v.worst:
          v.part = t.part
          v.whose = who
        worse(v, -t.gap / s.rig.limb, Reason.Through, link, arm)
  result.cost = comfort(s.rig, result.joints)


func links3(p: ArmPose): array[3, (Vec, Vec)] =
  [(p.s, p.e), (p.e, p.w), (p.w, p.g)]


func armsApart(s: State; a, b: ArmPose; meet: Vec; excuse: float;
               v: var Verdict; link, arm: int) =
  ## Every link of one arm against every link of another.
  for (a0, a1) in links3(a):
    for (b0, b1) in links3(b):
      let gap = armGap(s.rig, a0, a1, b0, b1, meet, excuse)
      if gap < 0.0:
        worse(v, -gap / s.rig.limb, Reason.Arms, link, arm)


func fitLink(s: State; i: int; p: Params; v: var Verdict) =
  ## Evaluate connection `i` at `p`, adding what it finds to `v`.
  var fit: LinkFit
  var costs = 0.0
  for k in 0 .. 1:
    let got = fitArm(s, s.links[i].ends[k], p.g, p.h[k], p.swivel[k], v, i, k)
    fit.arms[k] = got.pose
    fit.joints[k] = got.joints
    costs += got.cost
    let st = strain(s.rig, got.joints)
    if st.most >= fit.strain:
      fit.strain = st.most
      fit.strainedArm = k
      fit.strainedDof = st.dof
  let band = s.rig.band[s.band]
  if p.g.z < band.lo:
    worse(v, (band.lo - p.g.z) / SLACK, Reason.Band, i, 0)
  elif p.g.z > band.hi:
    worse(v, (p.g.z - band.hi) / SLACK, Reason.Band, i, 0)
  let lift = (p.g.z - band.lo) / (band.hi - band.lo)
  costs += lift * lift
  # The grip between the two shoulders: a couple holds hands between them,
  # not wherever both arms happen to hang most easily.  Over the crown and
  # set up for a turn, over the turning partner's head instead.
  let
    a = fit.arms[0].s
    b = fit.arms[1].s
  var
    mid: Vec = ((a.x + b.x) / 2.0, (a.y + b.y) / 2.0, p.g.z)
    weight = CENTRING[ord(s.band)]
  if s.overhead and s.band == Band.Crown:
    mid = (s.stance[s.turning].centre.x, s.stance[s.turning].centre.y, p.g.z)
    weight = CENTRING[ord(Band.Torso)]
  let off = dist(p.g, mid) / reach(s.rig)
  costs += weight * off * off
  armsApart(s, fit.arms[0], fit.arms[1], p.g, EXCUSE, v, i, 0)
  v.cost += costs
  v.strain = max(v.strain, fit.strain)
  v.fits[i] = fit


func evaluate*(s: State; ps: openArray[Params]): Verdict =
  ## Judge the whole state at these poses, one per connection.
  result.n = s.links.len
  for i in 0 ..< s.links.len:
    fitLink(s, i, ps[i], result)
  if s.links.len == 2:
    # Arms of different connections, a dancer's own two among them.
    for a in 0 .. 1:
      for b in 0 .. 1:
        armsApart(s, result.fits[0].arms[a], result.fits[1].arms[b],
                  ps[0].g, 0.0, result, 1, b)
  result.ok = result.worst <= TOLERANCE
  if result.ok:
    result.reason = Reason.None


func evaluate*(s: State): Verdict =
  ## Judge the state at the poses it carries.
  evaluate(s, s.params)


#[ Seeding ]#


func armSeed(s: State; hand: Hand; g: Vec; fine: bool): Option[(Vec, float)] =
  ## The most comfortable hand direction and swivel for one arm at grip `g`,
  ## taken on its own; none if no pair holds.
  let
    dirs = if fine: DIRS26 else: DIRS14
    turns = if fine: 24 else: 12
  var best = Inf
  for h in dirs:
    for j in 0 ..< turns:
      let swivel = j.float * 2.0 * PI / turns.float
      var v: Verdict
      let got = fitArm(s, hand, g, h, swivel, v, 0, 0)
      if v.worst <= TOLERANCE and got.cost < best:
        best = got.cost
        result = some((h, swivel))


func seeds*(s: State; i: int; fine = false; keep = 5): seq[Params] =
  ## First poses for connection `i` from a grid over the grip, the cheapest
  ## few, cheapest first; empty where none holds.
  ##   Several rather than one, because the cheapest grid point need not lie
  ##     in the basin of the cheapest pose; the caller refines each and
  ##     keeps the best.
  let
    a = shoulder(s.rig, s.stance[s.links[i].ends[0].body], s.links[i].ends[0].arm)
    b = shoulder(s.rig, s.stance[s.links[i].ends[1].body], s.links[i].ends[1].arm)
    r = reach(s.rig)
    band = s.rig.band[s.band]
    step = if fine: 0.08 else: 0.12
    mid: Vec = ((a.x + b.x) / 2.0, (a.y + b.y) / 2.0, 0.0)
    span = int(r / step) + 1
    layers = int((band.hi - band.lo) / step) + 1
  var costs: seq[float]
  # A grid about the point between the shoulders, which is always on it, up
  # through the band with its top layer on it too.
  for iz in 0 .. layers:
    let z = min(band.lo + 0.01 + iz.float * step, band.hi - 0.005)
    for iy in -span .. span:
      let y = mid.y + iy.float * step
      for ix in -span .. span:
        let x = mid.x + ix.float * step
        let g: Vec = (x, y, z)
        if dist(g, a) <= r and dist(g, b) <= r:
          let
            p0 = armSeed(s, s.links[i].ends[0], g, fine)
            p1 = armSeed(s, s.links[i].ends[1], g, fine)
          if p0.isSome and p1.isSome:
            let p = Params(g: g, h: [p0.get[0], p1.get[0]],
                           swivel: [p0.get[1], p1.get[1]])
            var one = s
            one.links = @[s.links[i]]
            let v = evaluate(one, [p])
            if v.ok:
              # Keep the cheapest few, in order.
              var at = costs.len
              while at > 0 and costs[at - 1] > v.cost:
                dec at
              if at < keep:
                costs.insert(v.cost, at)
                result.insert(p, at)
                if costs.len > keep:
                  costs.setLen(keep)
                  result.setLen(keep)


#[ Refining ]#


type Moves* = object ## The steps a pattern search is taking.
  dist*, angle*: float


func moved(p: Params; which: int; sign: float; m: Moves): Params =
  ## Pose `p` with one of its nine numbers stepped.
  ##   0..2 the grip; 3..4 and 6..7 each hand turned about two axes across
  ##     it; 5 and 8 each swivel.
  result = p
  case which
  of 0: result.g.x += sign * m.dist
  of 1: result.g.y += sign * m.dist
  of 2: result.g.z += sign * m.dist
  else:
    let k = if which < 6: 0 else: 1
    case (which - 3) mod 3
    of 0: result.h[k] = spun(p.h[k], perp(p.h[k]), sign * m.angle)
    of 1: result.h[k] = spun(p.h[k], cross(p.h[k], perp(p.h[k])), sign * m.angle)
    else: result.swivel[k] += sign * m.angle


func better(a, b: Verdict; feasible: bool): bool =
  ## Whether `a` beats `b`: by cost among poses that hold, else by failure.
  if feasible:
    a.ok and (not b.ok or a.cost < b.cost - 1e-12)
  else:
    if abs(a.penalty - b.penalty) > 1e-12: a.penalty < b.penalty
    else: a.cost < b.cost - 1e-12


func within(p, home: Params; trust: float): bool =
  ## Whether a pose is still within the trust region of where it started.
  if trust >= Inf:
    return true
  if dist(p.g, home.g) > trust:
    return false
  let turn = trust * 7.0 # radians: a tenth of a metre allows forty degrees
  for k in 0 .. 1:
    if angleBetween(p.h[k], home.h[k]) > turn or
       abs(p.swivel[k] - home.swivel[k]) > turn:
      return false
  true


func refined*(s: State; start: seq[Params]; feasible: bool;
              first = Moves(dist: 0.04, angle: 15.0 * PI / 180.0);
              trust = Inf): tuple[params: seq[Params], verdict: Verdict] =
  ## Pattern-search from `start`: by comfort among poses that hold when
  ## `feasible`, else by the largest failure until nothing fails.
  var
    ps = start
    m = first
    v = evaluate(s, ps)
  const
    LEAST_DIST = 0.001
    LEAST_ANGLE = 0.5 * PI / 180.0
  var rounds = 0
  while (m.dist >= LEAST_DIST or m.angle >= LEAST_ANGLE) and rounds < 400:
    inc rounds
    var
      bestV = v
      bestPs = ps
      improved = false
    for i in 0 ..< ps.len:
      for which in 0 .. 8:
        for sign in [-1.0, 1.0]:
          var trial = ps
          trial[i] = moved(ps[i], which, sign, m)
          if not within(trial[i], start[i], trust):
            continue
          let tv = evaluate(s, trial)
          if better(tv, bestV, feasible):
            bestV = tv
            bestPs = trial
            improved = true
    if improved:
      ps = bestPs
      v = bestV
      if not feasible and v.ok:
        break
    else:
      m.dist /= 2.0
      m.angle /= 2.0
  (ps, v)


#[ Settling ]#


func jump*(a, b: State): float =
  ## The furthest any joint moves between two solved states of the same links.
  let
    va = evaluate(a)
    vb = evaluate(b)
  for i in 0 ..< a.links.len:
    for k in 0 .. 1:
      let
        p = va.fits[i].arms[k]
        q = vb.fits[i].arms[k]
      for (x, y) in [(p.e, q.e), (p.w, q.w), (p.g, q.g)]:
        result = max(result, dist(x, y))


func restings*(s: State; fine = false): seq[State] =
  ## The distinct poses the search settles on, most comfortable first;
  ## empty where some connection has no pose that holds.
  ##   Each connection's few best seeds are refined on their own; every
  ##     distinct pose of the first connection is kept, paired with the best
  ##     of the second, and with two connections the pair is refined
  ##     together.  Distinct means a joint sits more than a hand's breadth
  ##     from where it sits in every pose already kept.
  var perLink: seq[seq[Params]]
  for i in 0 ..< s.links.len:
    var one = s
    one.links = @[s.links[i]]
    var kept: seq[(float, Params)]
    for seed in seeds(s, i, fine):
      let got = refined(one, @[seed], feasible = true)
      if not got.verdict.ok:
        continue
      var fresh = true
      for (_, p) in kept:
        var a = one
        a.params = @[p]
        var b = one
        b.params = @[got.params[0]]
        if jump(a, b) < 0.10:
          fresh = false
      if fresh:
        var at = kept.len
        while at > 0 and kept[at - 1][0] > got.verdict.cost:
          dec at
        kept.insert((got.verdict.cost, got.params[0]), at)
    if kept.len == 0:
      return
    var ps: seq[Params]
    for (_, p) in kept: ps.add p
    perLink.add ps
  for first in perLink[0]:
    var starts = @[first]
    for i in 1 ..< s.links.len:
      starts.add perLink[i][0]
    var got = (params: starts, verdict: evaluate(s, starts))
    if s.links.len > 1:
      got = refined(s, starts, feasible = true)
      if not got.verdict.ok:
        # Settled apart, the two may lie through each other; work free first.
        got = refined(s, starts, feasible = false)
        if got.verdict.ok:
          got = refined(s, got.params, feasible = true)
    if got.verdict.ok:
      var done = s
      done.params = got.params
      var at = result.len
      while at > 0 and evaluate(result[at - 1]).cost > got.verdict.cost:
        dec at
      result.insert(done, at)


func settle*(s: State; fine = false): Option[State] =
  ## The most comfortable pose of every connection, from nothing; none where
  ## some connection has no pose that holds.
  let all = restings(s, fine)
  if all.len == 0: none(State) else: some(all[0])


func follow*(s: State; before: State; trust = 0.15): Option[State] =
  ## The pose of `s` reached from `before`'s pose by small moves: what an
  ## arm does when a body turns a little.  None where no small move holds.
  var ps = before.params
  var v = evaluate(s, ps)
  let gentle = Moves(dist: 0.01, angle: 5.0 * PI / 180.0)
  if not v.ok:
    let back = refined(s, ps, feasible = false, first = gentle, trust = trust)
    if not back.verdict.ok:
      return none(State)
    ps = back.params
  let got = refined(s, ps, feasible = true, first = gentle, trust = trust)
  var done = s
  done.params = got.params
  some(done)


func reason*(s: State; before: State; trust = Inf): Verdict =
  ## Why no small move from `before` holds in `s`: the failure that remains
  ## when the largest has been made as small as it can.
  refined(s, before.params, feasible = false,
          first = Moves(dist: 0.01, angle: 5.0 * PI / 180.0),
          trust = trust).verdict


#[ Routing ]#


func sweptRound(rig: Rig; v: Verdict; i, k: int; st: Stance): float =
  ## The angle one arm sweeps round a body's axis, seen from above, signed,
  ## counting only the arm below the crown: how far round that body the arm
  ## goes, where the body is.
  ##   Above the crown an arm is round nothing, and may pass over the head
  ##     from one side to the other; below it the sweep changes only by
  ##     small amounts under small moves, and by a whole half turn only when
  ##     the arm has passed through the body.  Over a shoulder is beside the
  ##     neck, which is off the axis, so that too is a small move.
  let
    p = v.fits[i].arms[k]
    z1 = rig.top[Part.Head] + rig.limb
  for (a, b) in [(p.s, p.e), (p.e, p.w), (p.w, p.g)]:
    let dz = b.z - a.z
    var lo, hi: float
    if abs(dz) < 1e-12:
      if a.z > z1:
        continue
      lo = 0.0
      hi = 1.0
    else:
      lo = (z1 - a.z) / dz
      if dz > 0.0:
        hi = min(lo, 1.0)
        lo = 0.0
      else:
        lo = max(lo, 0.0)
        hi = 1.0
      if lo >= hi:
        continue
    let
      ax = a.x + (b.x - a.x) * lo - st.centre.x
      ay = a.y + (b.y - a.y) * lo - st.centre.y
      bx = a.x + (b.x - a.x) * hi - st.centre.x
      by = a.y + (b.y - a.y) * hi - st.centre.y
    result += arctan2(ax * by - ay * bx, ax * bx + ay * by)


func routing*(s: State): seq[float] =
  ## Every arm's sweep round every body: the shape of the pose that no
  ## small motion changes.
  let v = evaluate(s)
  for i in 0 ..< s.links.len:
    for k in 0 .. 1:
      for who in Body:
        result.add sweptRound(s.rig, v, i, k, s.stance[who])


func sameRoute*(a, b: State): bool =
  ## Whether two poses of the same links go round the bodies the same way,
  ## so that one can become the other without an arm passing through
  ## anybody.
  ##   An arm that has gone round a body cannot get to a pose that has not,
  ##     however comfortable; that is what being wound is.
  let
    ra = routing(a)
    rb = routing(b)
  if ra.len != rb.len:
    return false
  for i in 0 ..< ra.len:
    if abs(ra[i] - rb[i]) >= PI:
      return false
  true


