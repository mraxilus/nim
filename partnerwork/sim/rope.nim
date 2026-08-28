## Lay a rope taut between two turning bodies, and say how long it has to be.
##
## The one thing this has to get right, and the thing its predecessor got
## wrong, is that **a wound rope has a position**.  Winding is not a counter
## and not a price: it is how far around a body the rope actually lies, and
## everything else -- how much rope is spent, whether it clears the other
## body, which of two ropes is on top -- is read off that.
##
##   A body is a vertical cylinder, so it obstructs the *plan* and nothing
##     else.  That is what keeps this tractable: which plan paths a rope may
##     take does not depend on how high it is carried, and for fixed end
##     heights the cheapest way to realise a plan path of length `L` is to
##     climb at a constant slope, costing `sqrt(L^2 + dz^2)`.  So the plan
##     problem and the height problem separate, and neither needs the other.
##   The rope is anchored on the rim at each shoulder.  Turning a body drags
##     its anchor round the rim, and the rope hugs from the anchor to wherever
##     it can leave on a tangent.  That hug is the wind, and it may pass a
##     full turn -- which is exactly what a counter could not say.
##   A wind is *given* to this module, never searched for.  A shortest path
##     has no memory: after a full turn it is the path it was at rest, so a
##     solver that always minimises can never report a body as wound.  What
##     remembers is `sweep`, by turning in steps small enough to keep count.
##     Only the whole turns are stored; where the rope leaves the rim is
##     recomputed from the geometry every step, so a sweep out and back
##     returns the angle it started with exactly rather than nearly.
##
## What is approximated, said plainly:
##   The plan path is chosen without regard to height, and the height is then
##     fitted to that plan path.  A real rope trades a little plan length for
##     a shallower climb, so this overstates a steep one -- worst exactly
##     where a connection is carried over a head, and in the direction that
##     refuses rather than allows.
##   The joined hands ride at the middle of the rope, so raising them is a
##     tent: up from one shoulder and down to the other.

{.experimental: "strictFuncs".}

import std/[math, options]


type
  Vec* = tuple[x, y: float] ## A point of the plan, in metres.

  Arm* {.pure.} = enum ## One of a body's two hands, from its own point of view.
    Left, Right

  Body* {.pure.} = enum ## One of the two bodies.
    ##   Deliberately not `Dancer`: two other modules in this repository have a
    ##     type of that name meaning something near but not the same, and this
    ##     one is meant to share nothing with either.
    One, Two

  Band* {.pure.} = enum ## Which of a body's two cylinders a wind turns on.
    ##   State, not a derivation.  Deriving it from the solved height would
    ##     make the radius depend on the length and the length on the radius,
    ##     which is a fixed point, which is an iteration count -- not a thing
    ##     to put inside a slider.  Asked instead, and answered wrong is a
    ##     `Fault.Band` rather than a quiet wrong number.
    Torso, Head

  Hand* = tuple[body: Body, arm: Arm] ## Names one of the four hands.

  Rig* = object ## Every measurement the sim is built from, in metres.
    torso*: float    ## Radius of the torso cylinder, floor to `shoulder`.
    head*: float     ## Radius of the head and neck, `shoulder` to `crown`.
    arm*: float      ## One arm, shoulder to hand, as rope.
    limb*: float     ## Half the thickness of an arm: how near two ropes may
                     ## pass before they are touching rather than clearing.
    shoulder*: float ## Height of the shoulder line, where the torso stops.
    crown*: float    ## Height the head stops at.  Above it, nothing.

  Stance* = object ## Where one body stands and which way it is turned.
    centre*: Vec   ## Plan position of its axis.
    facing*: float ## Radians anticlockwise from the x axis.

  Wind* = object ## One turn of rope around one cylinder.
    body*: Band0Body ## Which body.
    band*: Band      ## Which of its two radii.
    way*: int        ## +1 anticlockwise seen from above, -1 clockwise.
    turns*: int      ## Whole turns beyond the sweep the geometry shows.
                     ## Never negative: a wind that would need -1 has come
                     ## off, and is deleted instead.

  Band0Body = Body ## Spelt out so `Wind.body` reads as a body, not a band.

  Link* = object ## One connection: two hands, the winds between them, a height.
    ends*: array[2, Hand]
    winds*: seq[Wind] ## In order along the rope, from `ends[0]`.
    height*: float    ## Height of the joined hands, which ride at its middle.

  State* = object ## The whole world as one plain value.
    ##   A value, because a browser rebuilds it from a slider sixty times a
    ##     second and everything downstream is a `func`: the same slider
    ##     position gives the same picture, however it was dragged there.
    rig*: Rig
    stance*: array[Body, Stance]
    links*: seq[Link]

  Kind* {.pure.} = enum ## What one stretch of a taut rope is doing.
    Reach, ## Straight through the air.
    Hug    ## Along a cylinder: an arc in plan, a helix in space.

  Stretch* = object ## One stretch of a taut rope.
    kind*: Kind
    plan*: seq[Vec] ## Its plan polyline.
    span*: float    ## Its plan length.
    turn*: float    ## `Hug` only: signed total turning, which may pass 2*PI.

  Lie* = object ## How a connection lies taut, in the winds it is carrying.
    stretches*: seq[Stretch]
    plan*: seq[Vec] ## The whole plan polyline, anchor to anchor.
    span*: float    ## Its plan length.
    length*: float  ## Its length in space, once the climb is paid for.
    hugs*: int      ## How many rims it hugs.

  Fault* {.pure.} = enum ## Why a state is refused, one reason at a time.
    Tangent, ## A wind cannot be laid: a rim is unreachable from the one before.
    Through, ## The rope passes through a body.
    Budget   ## The lie is longer than the two arms are.


const HUMAN* = Rig(torso: 0.16, head: 0.09, arm: 0.62, limb: 0.04,
                   shoulder: 1.40, crown: 1.67)
  ## A human-proportioned body, in metres.
  ##   Hand-entered and cited to nothing.  Every answer the sim gives is a
  ##     fact about *these* numbers until they are measured off a person,
  ##     which is why the page lets them be moved rather than baking them in.
  ##   `crown` is `shoulder + 3 * head`: the neck and the head stacked on the
  ##     shoulder line.



#[ Plan arithmetic ]#

func `+`(a, b: Vec): Vec = (a.x + b.x, a.y + b.y)
func `-`(a, b: Vec): Vec = (a.x - b.x, a.y - b.y)
func `*`(a: Vec; by: float): Vec = (a.x * by, a.y * by)
func dot(a, b: Vec): float = a.x * b.x + a.y * b.y
func cross(a, b: Vec): float = a.x * b.y - a.y * b.x

func dist*(a, b: Vec): float =
  ## Measure the straight way between two plan points.
  sqrt(dot(a - b, a - b))

func unit(a: Vec): Vec =
  let n = sqrt(dot(a, a))
  if n < 1e-12: (0.0, 0.0) else: a * (1.0 / n)

func spun(a: Vec; by: float): Vec =
  ## Turn a plan vector anticlockwise.
  (a.x * cos(by) - a.y * sin(by), a.x * sin(by) + a.y * cos(by))

func rimAt(centre: Vec; radius, angle: float): Vec =
  (centre.x + cos(angle) * radius, centre.y + sin(angle) * radius)

func angleOf(centre, p: Vec): float =
  arctan2(p.y - centre.y, p.x - centre.x)

func bitesInto(a, b, o: Vec; radius, bite: float): bool =
  ## Test whether a straight run cuts into a body rather than grazing it.
  ##   The endpoints cannot decide this.  A rope is anchored *on* both rims,
  ##     so every run of it starts and ends touching a body; asking "does an
  ##     end lie on this rim" therefore excuses every body from every test,
  ##     which is how the first draft of this managed never to wind at all.
  ##   What separates leaving a rim from cutting through one is where the run
  ##     comes closest: at an end, it is leaving; in the middle, it is
  ##     cutting.
  let
    ab = b - a
    span = dot(ab, ab)
  if span < 1e-18:
    return dist(a, o) < radius - bite
  let t = dot(o - a, ab) / span
  if t <= 1e-9 or t >= 1.0 - 1e-9:
    return min(dist(a, o), dist(b, o)) < radius - bite
  dist(a + ab * t, o) < radius - bite


func nearing(a, b, o: Vec): float =
  ## Measure how close a straight run comes to a point.
  let
    ab = b - a
    span = dot(ab, ab)
  if span < 1e-18:
    return dist(a, o)
  let t = clamp(dot(o - a, ab) / span, 0.0, 1.0)
  dist(a + ab * t, o)


func budget*(rig: Rig): float = 2.0 * rig.arm
  ## Get the rope one connection has: two arms tied at the joined hands.

func radiusOf*(rig: Rig; band: Band): float =
  ## Get the radius a wind in this band turns at.
  if band == Band.Torso: rig.torso else: rig.head

func girth*(rig: Rig; height: float): float =
  ## Get how wide a body is at a height: torso, then head, then nothing.
  ##   The whole of what carrying a connection over someone's head *is*: at a
  ##     height above the crown a body presents no width, so there is nothing
  ##     for the rope to go round.  Nothing else in the module special-cases
  ##     a lift; it falls out of this.
  if height <= rig.shoulder: rig.torso
  elif height <= rig.crown: rig.head
  else: 0.0

func touching*(rig: Rig): float = 2.0 * rig.torso
  ## Get how close two bodies can stand, centre to centre: rims in contact.

func handAngle*(state: State; hand: Hand): float =
  ## Get the angle on a body's rim that one of its hands is anchored at.
  ##   A body's left is a quarter turn anticlockwise of the way it faces, its
  ##     right a quarter turn clockwise.  Every consequence of two people
  ##     facing one another -- that one's left meets the other's right without
  ##     crossing -- comes out of this line and is written nowhere else.
  state.stance[hand.body].facing +
    (if hand.arm == Arm.Left: PI / 2 else: -PI / 2)

func anchor*(state: State; hand: Hand): Vec =
  ## Get where one hand's rope is anchored, on the rim of its own torso.
  rimAt(state.stance[hand.body].centre, state.rig.torso, handAngle(state, hand))

func facing*(rig: Rig; apart: float): State =
  ## Stand two bodies `apart` metres away, facing one another.
  State(rig: rig,
        stance: [Stance(centre: (0.0, 0.0), facing: PI / 2),
                 Stance(centre: (0.0, apart), facing: -PI / 2)])



#[ Tangents, in closed form ]#

func onto(p, centre: Vec; radius, way: float): Option[float] =
  ## Find the angle on a rim where a rope from `p` first touches it, hugging
  ## the given way.
  ##   Closed form rather than a candidate loop: the tangent from a point is
  ##     `arccos(r/d)` off the line to the centre, and the hug's own sense
  ##     picks which side without a dot-product tolerance having to guess.
  let d = dist(p, centre)
  if d < radius - 1e-9:
    return none(float)
  if d <= radius + 1e-9:
    # The ordinary case for a hand on the rim of its own body.
    return some(angleOf(centre, p))
  some(angleOf(centre, p) + way * arccos(clamp(radius / d, -1.0, 1.0)))


func offTo(centre, q: Vec; radius, way: float): Option[float] =
  ## Find the angle on a rim where a rope leaves it for `q`, hugging that way.
  let d = dist(q, centre)
  if d < radius - 1e-9:
    return none(float)
  if d <= radius + 1e-9:
    return some(angleOf(centre, q))
  some(angleOf(centre, q) - way * arccos(clamp(radius / d, -1.0, 1.0)))


func across(a_at: Vec; a_r, a_way: float; b_at: Vec;
    b_r, b_way: float): Option[(float, float)] =
  ## Find where a rope leaves one rim and meets the next, hugging each its
  ## own way.
  ##   One formula for both tangents, and unlike the equal-radius shortcut it
  ##     replaces it is right when the two rims differ -- which they do the
  ##     moment one wind sits on a neck and the other on a chest.  Same
  ##     senses give the outer tangent, opposite senses the inner one, and
  ##     the inner one simply does not exist when the rims are close enough
  ##     to overlap, so that is refused rather than clamped into being.
  let
    d = dist(a_at, b_at)
    same = a_way * b_way
    rho = a_r - same * b_r
  if d < 1e-12 or abs(rho) > d:
    return none((float, float))
  let
    beta = -a_way * arccos(clamp(rho / d, -1.0, 1.0))
    n = spun(unit(b_at - a_at), beta)
  some((angleOf(a_at, a_at + n * a_r), angleOf(b_at, b_at + n * (same * b_r))))


func sweepOf(from_angle, to_angle, way: float): float =
  ## Measure the arc from one angle to another, taken the hug's own way.
  ##   Always in `[0, 2*PI)`.  Whole turns are not read off the geometry --
  ##     the geometry cannot see them -- they are carried in `Wind.turns` and
  ##     added on.  The old code clamped a nearly-whole sweep to zero, on the
  ##     grounds that a rope reading the long way round has slipped off; that
  ##     is true only of a wind carrying no whole turns, and for any other it
  ##     deletes most of a turn in one step.  Deciding it needs the step
  ##     before, so it is decided in `carried` and not here.
  let delta = if way > 0: to_angle - from_angle else: from_angle - to_angle
  floorMod(delta, 2.0 * PI)


func arcPoints(centre: Vec; radius, from_angle, turn: float): seq[Vec] =
  ## Sample a hug, however many turns it takes.
  let steps = max(1, int(ceil(abs(turn) / 0.09)))
  for step in 0 .. steps:
    result.add rimAt(centre, radius,
      from_angle + turn * float(step) / float(steps))


#[ Laying a rope out ]#

func rimOf(state: State; wind: Wind): (Vec, float) =
  ## Get the centre and radius one wind turns on.
  (state.stance[wind.body].centre, radiusOf(state.rig, wind.band))


func lay*(state: State; link: Link): Option[Lie] =
  ## Lay one connection taut in the winds it is carrying, or refuse a set of
  ## winds that cannot be laid.
  ##
  ## Built, never searched.  From each anchor the rope hugs whatever rims its
  ## winds name, in order, joined by the straight runs between them.  With no
  ## winds that is a straight line from shoulder to shoulder, which is what a
  ## rope at rest is.
  let
    p = anchor(state, link.ends[0])
    q = anchor(state, link.ends[1])
  var lie = Lie(hugs: link.winds.len)
  if link.winds.len == 0:
    lie.stretches = @[Stretch(kind: Kind.Reach, plan: @[p, q], span: dist(p, q))]
    lie.plan = @[p, q]
    lie.span = dist(p, q)
  else:
    var enters, leaves: seq[float]
    for i, wind in link.winds:
      let (centre, radius) = rimOf(state, wind)
      if i == 0:
        let got = onto(p, centre, radius, wind.way.float)
        if got.isNone: return none(Lie)
        enters.add got.get
      leaves.add 0.0
      if i + 1 < link.winds.len:
        let
          (next_at, next_r) = rimOf(state, link.winds[i + 1])
          got = across(centre, radius, wind.way.float, next_at, next_r,
            link.winds[i + 1].way.float)
        if got.isNone: return none(Lie)
        leaves[i] = got.get[0]
        enters.add got.get[1]
      else:
        let got = offTo(centre, q, radius, wind.way.float)
        if got.isNone: return none(Lie)
        leaves[i] = got.get
    # Walk it: reach in, hug, reach on, and out to the far anchor.
    var stand = p
    for i, wind in link.winds:
      let
        (centre, radius) = rimOf(state, wind)
        start = rimAt(centre, radius, enters[i])
        turn = wind.way.float *
          (sweepOf(enters[i], leaves[i], wind.way.float) +
            2.0 * PI * wind.turns.float)
      if dist(stand, start) > 1e-9:
        lie.stretches.add Stretch(kind: Kind.Reach, plan: @[stand, start],
          span: dist(stand, start))
      let arc = arcPoints(centre, radius, enters[i], turn)
      lie.stretches.add Stretch(kind: Kind.Hug, plan: arc,
        span: radius * abs(turn), turn: turn)
      stand = arc[^1]
    if dist(stand, q) > 1e-9:
      lie.stretches.add Stretch(kind: Kind.Reach, plan: @[stand, q],
        span: dist(stand, q))
    for stretch in lie.stretches:
      lie.span += stretch.span
      for at in stretch.plan:
        if lie.plan.len == 0 or dist(lie.plan[^1], at) > 1e-12:
          lie.plan.add at
  # The joined hands ride at the middle of the rope, so raising them is a
  # tent: up from one shoulder and down to the other.  An arc is measured
  # exactly rather than off its own samples, so the length does not depend
  # on how finely it was drawn.
  let rise = max(0.0, link.height - state.rig.shoulder)
  lie.length = sqrt(lie.span * lie.span + 4.0 * rise * rise)
  some(lie)


func heightAt*(state: State; link: Link; lie: Lie; s: float): float =
  ## Get how high a lie is carried, at a plan distance along it.
  if lie.span < 1e-12:
    return link.height
  let rise = max(0.0, link.height - state.rig.shoulder)
  state.rig.shoulder + rise * (1.0 - abs(2.0 * s / lie.span - 1.0))


func slack*(state: State; link: Link): float =
  ## Get the rope a connection has left over, which is its room to move.
  let laid = lay(state, link)
  if laid.isNone: -Inf else: budget(state.rig) - laid.get.length


func clearance*(state: State; link: Link; lie: Lie): float =
  ## Measure how far a lie stays outside every body, in space.
  ##   Read at the width a body actually presents at the height the rope is
  ##     carried past it, so a connection lifted over a crown clears by
  ##     construction rather than by a special case.
  ##   A hug touches the rim it is on by definition, so only the free runs
  ##     between hugs are asked, and each is asked only about the bodies it
  ##     is not leaving or arriving at.
  result = Inf
  var gone = 0.0
  for stretch in lie.stretches:
    if stretch.kind == Kind.Reach:
      let
        mid = gone + stretch.span / 2.0
        bar = girth(state.rig, heightAt(state, link, lie, mid))
      if bar > 0.0:
        for who in Body:
          result = min(result, nearing(stretch.plan[0], stretch.plan[^1],
            state.stance[who].centre) - bar)
    gone += stretch.span


func faultOf*(state: State; link: Link): Option[Fault] =
  ## Say what refuses this connection, if anything does.
  let laid = lay(state, link)
  if laid.isNone:
    return some(Fault.Tangent)
  if clearance(state, link, laid.get) < -1e-6:
    return some(Fault.Through)
  if laid.get.length > budget(state.rig) + 1e-9:
    return some(Fault.Budget)
  none(Fault)


func holds*(state: State): bool =
  ## Referee a whole state: every connection reaches, and nothing passes
  ## through anything.
  for link in state.links:
    if faultOf(state, link).isSome:
      return false
  true


#[ Turning, and keeping count ]#

const
  BIRTH_BITE = 1e-6
    ## How far a straight run must cut into a body before the rope is taken
    ## to have caught on it.
    ##   Strictly positive, and that is what makes the hysteresis look after
    ##     itself.  At the instant a wind dies its sweep has come all the way
    ##     round, so the run replacing it leaves exactly tangent -- cutting in
    ##     by nothing.  A birth needs a strictly positive bite, so a wind
    ##     cannot be reborn in the step it died in, and nothing flickers.
  STEP_MOST = PI / 4
    ## The most a sweep may move in one step before the step is halved.
    ##   Counting turns rests on a step being smaller than half a circle, and
    ##     what bounds the sweep is not the angle turned: a tangent point
    ##     slides at `1 / (d * sqrt(1 - (r/d)^2))`, which runs away as a body
    ##     nears the other's rim.  So the step watches the sweep, not the
    ##     turn, and refuses to guess rather than miscount in silence.


func sweepNow(state: State; link: Link; index: int): Option[float] =
  ## Get the bare geometric sweep of one wind, as the bodies stand now.
  let
    wind = link.winds[index]
    (centre, radius) = rimOf(state, wind)
  var enter, leave: float
  if index == 0:
    let got = onto(anchor(state, link.ends[0]), centre, radius, wind.way.float)
    if got.isNone: return none(float)
    enter = got.get
  else:
    let
      (prev_at, prev_r) = rimOf(state, link.winds[index - 1])
      got = across(prev_at, prev_r, link.winds[index - 1].way.float,
        centre, radius, wind.way.float)
    if got.isNone: return none(float)
    enter = got.get[1]
  if index + 1 < link.winds.len:
    let
      (next_at, next_r) = rimOf(state, link.winds[index + 1])
      got = across(centre, radius, wind.way.float, next_at, next_r,
        link.winds[index + 1].way.float)
    if got.isNone: return none(float)
    leave = got.get[0]
  else:
    let got = offTo(centre, anchor(state, link.ends[1]), radius, wind.way.float)
    if got.isNone: return none(float)
    leave = got.get
  some(sweepOf(enter, leave, wind.way.float))


func caught(state: State; link: Link): int =
  ## Find a body a straight run of this rope now cuts through, or -1.
  ##   Read at the width the body presents at the height the rope passes it,
  ##     so a connection carried over a crown catches on nothing.
  let laid = lay(state, link)
  if laid.isNone:
    return -1
  var gone = 0.0
  for stretch in laid.get.stretches:
    if stretch.kind == Kind.Reach:
      let
        mid = gone + stretch.span / 2.0
        bar = girth(state.rig, heightAt(state, link, laid.get, mid))
      if bar > 0.0:
        for who in Body:
          if bitesInto(stretch.plan[0], stretch.plan[^1],
              state.stance[who].centre, bar, BIRTH_BITE):
            return ord(who)
    gone += stretch.span
  -1


func withWind(link: Link; who: Body; band: Band; way: int): Link =
  ## Put one fresh wind on a rope, at the end nearest the body it caught on.
  result = link
  let fresh = Wind(body: who, band: band, way: way, turns: 0)
  if who == link.ends[0].body: result.winds.insert(fresh, 0)
  else: result.winds.add fresh


func tidied(state: State; link: Link): Link =
  ## Drop every wind that is no longer holding any rope.
  result = link
  var kept: seq[Wind]
  for i, wind in link.winds:
    let sweep = sweepNow(state, link, i)
    if wind.turns == 0 and (sweep.isNone or sweep.get < 1e-4):
      continue
    kept.add wind
  result.winds = kept


func carried(before, after: State; link: Link): Link =
  ## Carry one rope's winding across a step of a body's turn.
  ##   Only the whole turns are remembered.  Where the rope leaves a rim is
  ##     recomputed from the geometry, so a sweep out and back returns what it
  ##     started with exactly; a float total incremented step by step would
  ##     drift, and could not be trusted to come home.
  ##   A sweep that jumps most of a circle between two small steps has not
  ##     jumped: it has passed the anchor and begun another lap, which is the
  ##     one thing the geometry cannot see and the count is for.
  result = link
  for i in 0 ..< link.winds.len:
    let
      was = sweepNow(before, link, i)
      now = sweepNow(after, link, i)
    if was.isNone or now.isNone:
      continue
    if now.get < was.get - PI:
      result.winds[i].turns += 1
    elif now.get > was.get + PI:
      result.winds[i].turns -= 1
  # A wind asked for a turn it has not got has come off the body entirely.
  var kept: seq[Wind]
  for wind in result.winds:
    if wind.turns >= 0:
      kept.add wind
  result.winds = kept
  result = tidied(after, result)
  # And a run that now cuts a body has caught on it.  Which way round is
  # settled by laying both and keeping the shorter, since at birth the turn
  # is near nothing and the shorter is the way a real rope falls.
  let bit = caught(after, result)
  if bit >= 0:
    let
      who = Body(bit)
      band = if result.height > after.rig.shoulder and
                result.height <= after.rig.crown: Band.Head else: Band.Torso
      one = lay(after, withWind(result, who, band, 1))
      other = lay(after, withWind(result, who, band, -1))
    if one.isSome and (other.isNone or one.get.span <= other.get.span):
      result = withWind(result, who, band, 1)
    elif other.isSome:
      result = withWind(result, who, band, -1)


func settled*(state: State): State =
  ## Let every rope catch on whatever it is already lying against.
  ##   A rope put down between two hands has not been anywhere, so it carries
  ##     no winds -- and a hold whose straight line runs through a chest is
  ##     therefore refused the moment it is built, before anything has turned.
  ##     Settling is what a real pair do by taking the hold: the rope finds
  ##     the body and lies on it.
  ##   Repeated, because one pass catches one body and a rope may lie on two.
  result = state
  for _ in 0 ..< 4:
    var moved = false
    for i in 0 ..< result.links.len:
      let after = carried(result, result, result.links[i])
      if after.winds.len != result.links[i].winds.len:
        result.links[i] = after
        moved = true
    if not moved:
      break


func advance*(state: State; who: Body; by: float): State =
  ## Turn one body a small step, carrying every rope's winding with it.
  result = state
  result.stance[who].facing += by
  for i in 0 ..< state.links.len:
    result.links[i] = carried(state, result, state.links[i])


func turned*(state: State; who: Body; to: float; step = 0.02): State =
  ## Turn one body all the way to an angle, in steps small enough to count.
  ##   Pure: the answer depends on where the body is asked to end up and not
  ##     at all on how it was dragged there, because the whole turn is
  ##     replayed from where it started every time.  The winding underneath
  ##     is path-dependent and has to be; replaying is what keeps that from
  ##     reaching the surface.
  result = state
  if abs(to) < 1e-12:
    return
  let steps = max(1, int(ceil(abs(to) / step)))
  for i in 1 .. steps:
    var take = to / float(steps)
    var tried = advance(result, who, take)
    # Halve the step while a sweep moves too far to be counted; near contact a
    # tangent point can slide many degrees for one degree of turn.
    var halvings = 0
    while halvings < 6:
      var jumped = false
      for k in 0 ..< result.links.len:
        for j in 0 ..< min(result.links[k].winds.len,
            tried.links[k].winds.len):
          let
            was = sweepNow(result, result.links[k], j)
            now = sweepNow(tried, result.links[k], j)
          if was.isSome and now.isSome and
              abs(now.get - was.get) > STEP_MOST and
              abs(now.get - was.get) < 2.0 * PI - STEP_MOST:
            jumped = true
      if not jumped:
        break
      take = take / 2.0
      tried = advance(result, who, take)
      inc halvings
    result = tried


func windLimit*(state: State; who: Body; most = 4.0 * PI;
    step = 0.02): float =
  ## Get how far one body can turn before some connection first refuses.
  ##   Swept, not assumed.  The wind grows, the arc lengthens, and the limit
  ##     is wherever the length first crosses what two arms have.  The number
  ##     is not in the model; it comes out of it.
  var went = 0.0
  while went < most:
    let next = turned(state, who, went + step, step)
    if not holds(next):
      # Bisect the step that failed, so the answer is not the step size.
      var
        lo = went
        hi = went + step
      for _ in 0 ..< 24:
        let mid = (lo + hi) / 2.0
        if holds(turned(state, who, mid, step)): lo = mid else: hi = mid
      return lo
    went += step
  most


#[ Two ropes, and which of them is on top ]#

type Meeting* = object ## Where two ropes cross in plan, and how high each is.
  at*: Vec
  along*: array[2, float] ## Plan distance along each lie to the crossing.
  high*: array[2, float]  ## Height of each lie there.


func meetings*(state: State; a_link: Link; a: Lie;
    b_link: Link; b: Lie): seq[Meeting] =
  ## Find every place two ropes cross, seen from above.
  ##   Where they cross is where the question of which is on top gets asked;
  ##     everywhere else there is nothing to ask.
  var gone_a = 0.0
  for i in 0 ..< a.plan.high:
    var gone_b = 0.0
    for j in 0 ..< b.plan.high:
      let
        p1 = a.plan[i]
        p2 = a.plan[i + 1]
        q1 = b.plan[j]
        q2 = b.plan[j + 1]
        d1 = cross(q2 - q1, p1 - q1)
        d2 = cross(q2 - q1, p2 - q1)
        d3 = cross(p2 - p1, q1 - p1)
        d4 = cross(p2 - p1, q2 - p1)
      if d1 * d2 < 0 and d3 * d4 < 0:
        let
          t = d1 / (d1 - d2)
          u = d3 / (d3 - d4)
          at = p1 + (p2 - p1) * t
          sa = gone_a + dist(p1, p2) * t
          sb = gone_b + dist(q1, q2) * u
        result.add Meeting(at: at, along: [sa, sb],
          high: [heightAt(state, a_link, a, sa),
                 heightAt(state, b_link, b, sb)])
      gone_b += dist(q1, q2)
    gone_a += dist(a.plan[i], a.plan[i + 1])


func overOf*(rig: Rig; met: Meeting): Option[int] =
  ## Say which of two crossing ropes is on top, where the heights decide it.
  ##   Where they do not, the answer is nothing, and the nothing is the
  ##     point: two ropes within an arm's thickness of each other are
  ##     touching, so which is over is something the dancers settle rather
  ##     than something the geometry has already settled.  Handing back the
  ##     question is more honest than inventing an answer to it.
  let apart = met.high[0] - met.high[1]
  if abs(apart) < 2.0 * rig.limb: none(int)
  elif apart > 0.0: some(0)
  else: some(1)
