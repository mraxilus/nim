## Model the couple as bodies and ropes, and referee what is physically possible.
##
## Everything else in this package is notation: names, drawings, a matrix.  All
## of it is shorthand for two people whose arms have a length, and a claim made
## in shorthand -- this wraps, that locks, this one passes over -- can only be
## checked against a model that has the bodies in it.  This module is that
## model, kept as small as it can be while still refereeing the claims:
##   A body is a vertical cylinder, seen from above as a disc, with a narrower
##     cylinder stacked on it for the head and neck.
##   An arm is a rope: perfectly flexible, never stretching, anchored at the
##     shoulder on the rim of its own torso.  A connection ties the lead's rope
##     to the follow's at the joined hands, so its whole budget is the two arm
##     lengths, spent between the two shoulders however the rope has to lie.
##   Nothing passes through anything.  A taut rope lies in a chain of straight
##     reaches and hugs along torso rims, computed exactly with tangent
##     geometry; a slack rope lies wherever it likes, so only the taut length
##     matters, and a state is possible exactly when the lie fits the budget.
##
## The couple stand facing on the y axis: the lead at the origin facing up the
## page, the follow at `apart` facing back down it, which is the pose every
## drawing in the package draws.  Turning is not modelled by moving the pose --
## a turned body stands where it stood -- but by what it does to the ropes:
##   A turn danced low winds the rope around the turning torso.  Winding is
##     counted in signed half turns, the workbook's own granularity, and each
##     half turn is paid for with half that torso's girth in rope.
##     Cost of counting rather than sweeping continuously: the first half turn
##       really merges with the hug the rope already lies in, so the linear
##       price slightly overstates it.  Accepted -- the price is exact for
##       every following half turn, and the referee errs toward refusing.
##   A turn danced over the head winds nothing, because the rope is carried on
##     the axis the body turns about.  What it spends instead is the grip: the
##     joined hands swivel, and hands have a comfort limit the rope does not.
##     The limit is anatomy, so it is an input (`grip`), not a derivation --
##     the same number `rotation.nim` holds as `CAPACITY_SINGLE`.
##   Carrying a rope over a head at all costs extra length while it happens --
##     up the neck cylinder and down the far side -- so lifts, and everything
##     built from lifts (turns over the head, shedding a wrap), are possible
##     only when the couple stand close enough to afford the rise.
##
## What the rig referees today, and the tests hold: that every frame can
## actually be held; that a connection crosses the midline exactly when its
## name says it is crossed; that two crossed connections must decide an over
## and parallel ones never meet; that a wrap pulls the couple together; that
## the rope runs out at exactly the wrap capacity `rotation.nim` had to
## measure; and that turns over the head are bounded by comfort, not rope.
## Deferred, deliberately: jointed arms (a rope has no elbow), orbits (the
## pose never moves), hammerlocks (a rope routed behind a back is a longer
## lie this solver can already price but nothing yet asks for), and the cut
## -- what it takes to swap which crossed rope is on top is a question about
## hand heights this plan-view model does not hold.

{.experimental: "strictFuncs".}

import std/[math, options]

import ./draw/geometry
import ./frame
import ./rotation

export geometry.Point, geometry.dist



#[ Vectors ]#

type Vec* = Point ## One point of the plan, in metres.
  ## The drawing's own point type, borrowed rather than restated: the two were
  ##   the same tuple written twice, and a mock-up that draws a solved lie
  ##   should not have to convert it first.
  ## Only `Point` and `dist` are taken.  `geometry`'s angles run clockwise
  ##   from up the page where these run from the x axis, so its `polar` and
  ##   `bearing` are the one thing here that must not be reached for.

func `+`(a, b: Vec): Vec = (a.x + b.x, a.y + b.y)
func `-`(a, b: Vec): Vec = (a.x - b.x, a.y - b.y)
func `*`(a: Vec; by: float): Vec = (a.x * by, a.y * by)
func dot(a, b: Vec): float = a.x * b.x + a.y * b.y
func cross(a, b: Vec): float = a.x * b.y - a.y * b.x

func unit(a: Vec): Vec = a * (1.0 / max(dist(a, (0.0, 0.0)), 1e-12))

func rot(a: Vec; by: float): Vec =
  (a.x * cos(by) - a.y * sin(by), a.x * sin(by) + a.y * cos(by))

func hugway(radial: Vec; sign: float): Vec =
  ## Get the way a rope travels while hugging a rim, at one point of the hug.
  ##   `sign` is the hug's turning direction: positive is anticlockwise seen
  ##     from above, and the travel is the radial arm turned a quarter that way.
  if sign > 0: unit((-radial.y, radial.x)) else: unit((radial.y, -radial.x))


func segClearance(a, b, o: Vec): float =
  ## Measure how close a straight reach comes to a centre.
  let
    ab = b - a
    span = dot(ab, ab)
  if span < 1e-18:
    return dist(a, o)
  let t = clamp(dot(o - a, ab) / span, 0.0, 1.0)
  dist(a + ab * t, o)



#[ The rig ]#

type Rig* = object ## Hold the sizes everything is refereed against, in metres.
  torso*: float ## Radius of a body's torso cylinder.
  head*: float  ## Radius of the head and neck cylinder stacked on it.
  arm*: float   ## Length of one arm, shoulder to joined hand, as rope.
  apart*: float ## How far apart the couple prefer to stand, centre to centre.
  grip*: int    ## Half turns of swivel two joined hands can take.  Anatomy, so
                ## an input: the number `rotation.nim` holds as `CAPACITY_SINGLE`.


const HUMAN* = Rig(torso: 0.16, head: 0.09, arm: 0.62, apart: 0.90,
  grip: CAPACITY_SINGLE)
  ## A human-proportioned couple, in metres.  Every derived law is stated
  ## against this rig; another build of dancer can be refereed by passing
  ## another rig.


func budget*(rig: Rig): float = 2.0 * rig.arm
  ## Get the whole rope a connection has: the lead's arm tied to the follow's.


func rise*(rig: Rig): float = 6.0 * rig.head
  ## Get the extra rope a connection needs while it is carried over a head.
  ##   The crown stands about three head-radii above the shoulder line -- the
  ##     neck and the head the rig stacks there -- and the rope goes up one
  ##     side and down the other.  A proportion, not a measurement; it is the
  ##     one place the head cylinder's size enters the arithmetic.


func touching*(rig: Rig): float = 2.0 * rig.torso + 0.005
  ## Get how close the couple can possibly stand: torso rims in light contact.


func leadShoulder*(rig: Rig; side: Side): Vec =
  ## Get where a lead hand's rope is anchored: on the rim, facing up the page.
  case side
  of Side.Left: (-rig.torso, 0.0)
  of Side.Right: (rig.torso, 0.0)


func followShoulder*(rig: Rig; apart: float; site: Site): Vec =
  ## Get where a follow hand's rope is anchored, facing back down the page.
  ##   The follow faces the lead, so their left is on the lead's right: the
  ##     mirror the whole vocabulary of crossed and parallel stands on.
  case site
  of Site.LeftHand: (rig.torso, apart)
  of Site.RightHand: (-rig.torso, apart)



#[ The taut lie ]#

type
  Hug = object ## One rim the taut rope bends around, and which way.
    o: Vec
    r: float
    sign: float

  Lie* = object ## How a connection lies taut at rest, before any winding.
    length*: float    ## Exact length of the lie.
    bends*: int       ## Number of bodies it hugs on the way.
    trace*: seq[Vec]  ## The lie sampled as a polyline, for reading its shape.


func entryPoint(p: Vec; hug: Hug): Option[Vec] =
  ## Find where a rope leaving `p` first touches a rim it will hug.
  let d = dist(p, hug.o)
  if d < hug.r - 1e-9:
    return none(Vec)
  if d <= hug.r + 1e-9:
    return some(p)
  let
    reach = arccos(clamp(hug.r / d, -1.0, 1.0))
    base = unit(p - hug.o)
  for way in [1.0, -1.0]:
    let touch = hug.o + rot(base, way * reach) * hug.r
    if dist(touch, p) < 1e-12:
      return some(touch)
    if dot(unit(touch - p), hugway(touch - hug.o, hug.sign)) > 0.999:
      return some(touch)
  none(Vec)


func exitPoint(hug: Hug; q: Vec): Option[Vec] =
  ## Find where a rope hugging a rim leaves it to reach `q`.
  let d = dist(q, hug.o)
  if d < hug.r - 1e-9:
    return none(Vec)
  if d <= hug.r + 1e-9:
    return some(q)
  let
    reach = arccos(clamp(hug.r / d, -1.0, 1.0))
    base = unit(q - hug.o)
  for way in [1.0, -1.0]:
    let touch = hug.o + rot(base, way * reach) * hug.r
    if dist(touch, q) < 1e-12:
      return some(touch)
    if dot(unit(q - touch), hugway(touch - hug.o, hug.sign)) > 0.999:
      return some(touch)
  none(Vec)


func between(a, b: Hug): Option[(Vec, Vec)] =
  ## Find the straight reach from one hugged rim to the next.
  ##   Hugs turned the same way share an outer tangent; hugs turned opposite
  ##     ways hand the rope across between the bodies, which exists only once
  ##     the rims are clear of each other.
  let
    d = dist(a.o, b.o)
    ahead = unit(b.o - a.o)
  var found: seq[(Vec, Vec)] = @[]
  if a.sign * b.sign > 0:
    for way in [1.0, -1.0]:
      let lean = hugway(ahead, way)
      found.add (a.o + lean * a.r, b.o + lean * b.r)
  else:
    if d <= a.r + b.r + 1e-12:
      return none((Vec, Vec))
    let
      middle = (a.o + b.o) * 0.5
      reach = arccos(clamp(a.r / (d / 2.0), -1.0, 1.0))
    for way in [1.0, -1.0]:
      found.add (a.o + rot(unit(middle - a.o), way * reach) * a.r,
                 b.o + rot(unit(middle - b.o), way * reach) * b.r)
  for (ta, tb) in found:
    if dist(ta, tb) < 1e-9:
      # The rims touch and the reach vanishes; the hug directions must agree.
      if dot(hugway(ta - a.o, a.sign), hugway(tb - b.o, b.sign)) > 0.999:
        return some((ta, tb))
      continue
    let ahead2 = unit(tb - ta)
    if dot(ahead2, hugway(ta - a.o, a.sign)) > 0.999 and
        dot(ahead2, hugway(tb - b.o, b.sign)) > 0.999:
      return some((ta, tb))
  none((Vec, Vec))


func sweepOf(hug: Hug; enter, leave: Vec): float =
  ## Measure the arc a hug covers, in the hug's own turning direction.
  let
    ta = arctan2(enter.y - hug.o.y, enter.x - hug.o.x)
    tb = arctan2(leave.y - hug.o.y, leave.x - hug.o.x)
    delta = if hug.sign > 0: tb - ta else: ta - tb
  result = floorMod(delta, 2.0 * PI)
  # A sweep within a hair of a full circle is a vanishing arc read the long
  # way round, which a taut rope would slip off.
  if result > 2.0 * PI - 1e-6:
    result = 0.0


func lieAlong(p, q: Vec; hugs: seq[Hug]; walls: seq[Hug]): Option[Lie] =
  ## Lay the rope taut from `p` to `q` around the given hugs, if it can be.
  ##   `walls` are every body in the scene: a straight reach that would pass
  ##     through one is not a lie at all, whatever its length.
  var
    enters: seq[Vec] = @[]
    leaves: seq[Vec] = @[]
  if hugs.len > 0:
    let first = entryPoint(p, hugs[0])
    if first.isNone:
      return none(Lie)
    enters.add first.get
    for index in 0 ..< hugs.len - 1:
      let pair = between(hugs[index], hugs[index + 1])
      if pair.isNone:
        return none(Lie)
      leaves.add pair.get[0]
      enters.add pair.get[1]
    let last = exitPoint(hugs[^1], q)
    if last.isNone:
      return none(Lie)
    leaves.add last.get

  # Walk the chain, measuring reaches and hugs and refusing walls.
  var
    lie = Lie(trace: @[p])
    stand = p
  func reach(lie: var Lie; stand: var Vec; target: Vec;
      walls: seq[Hug]): bool =
    if dist(stand, target) >= 1e-9:
      for wall in walls:
        if segClearance(stand, target, wall.o) < wall.r - 1e-7:
          return false
      lie.length += dist(stand, target)
      lie.trace.add target
    stand = target
    true
  for index, hug in hugs:
    if not reach(lie, stand, enters[index], walls):
      return none(Lie)
    let sweep = sweepOf(hug, enters[index], leaves[index])
    if sweep > 1e-9:
      inc lie.bends
      lie.length += hug.r * sweep
      let steps = max(2, int(ceil(sweep / 0.09)))
      let start = arctan2(enters[index].y - hug.o.y, enters[index].x - hug.o.x)
      for step in 1 .. steps:
        let at = start + hug.sign * sweep * float(step) / float(steps)
        lie.trace.add hug.o + (cos(at), sin(at)) * hug.r
    stand = leaves[index]
    if lie.trace[^1] != stand:
      lie.trace.add stand
  if not reach(lie, stand, q, walls):
    return none(Lie)
  some(lie)


func lie*(rig: Rig; apart: float; side: Side; site: Site): Lie =
  ## Find how a connection lies taut at rest: its shortest possible lie.
  ##   Tried over every way of hugging the two torsos -- neither, either,
  ##     both, each way round -- and the shortest valid lie wins, which is
  ##     what a real rope does when the hands draw it tight.
  ##   A parallel connection comes back straight; a crossed one comes back
  ##     hugging both bodies, because its straight line would pass through
  ##     both chests, which is not a lie a rope can take.
  let
    p = leadShoulder(rig, side)
    q = followShoulder(rig, apart, site)
    bodies = [Hug(o: (0.0, 0.0), r: rig.torso),
              Hug(o: (0.0, apart), r: rig.torso)]
  var walls: seq[Hug] = @[]
  for body in bodies:
    walls.add body
  var candidates: seq[seq[Hug]] = @[@[]]
  for way in [1.0, -1.0]:
    candidates.add @[Hug(o: bodies[0].o, r: rig.torso, sign: way)]
    candidates.add @[Hug(o: bodies[1].o, r: rig.torso, sign: way)]
    for second in [1.0, -1.0]:
      candidates.add @[Hug(o: bodies[0].o, r: rig.torso, sign: way),
                       Hug(o: bodies[1].o, r: rig.torso, sign: second)]
  var best = none(Lie)
  for hugs in candidates:
    let laid = lieAlong(p, q, hugs, walls)
    if laid.isNone:
      continue
    if best.isNone or laid.get.length < best.get.length - 1e-9 or
        (abs(laid.get.length - best.get.length) <= 1e-9 and
          laid.get.bends < best.get.bends):
      best = laid
  doAssert best.isSome, "no taut lie found; the rig is malformed"
  best.get



#[ Connections under motion ]#

type Rope* = object ## One held connection, as the physical thing it is.
  side*: Side  ## The lead hand it is anchored to.
  site*: Site  ## The follow hand it is anchored to.
  winds*: array[Dancer, int] ## Signed half turns wound around each torso,
                             ## beyond the rest lie.  A turn danced low.
  twist*: int  ## Signed half turns of swivel in the joined hands.
               ## A turn danced over the head.


func rope*(side: Side; site: Site): Rope =
  ## Tie one connection, lying at rest.
  Rope(side: side, site: site)


func windCost*(rig: Rig; held: Rope): float =
  ## Get the rope a connection's winding is paid for with.
  ##   Each half turn wound around a torso costs half that torso's girth,
  ##     whichever way it is wound: winding back unwinds, so the signs cancel
  ##     per body, but a wind on the lead cannot cancel one on the follow.
  (abs(held.winds[Dancer.Lead]) + abs(held.winds[Dancer.Follow])).float *
    PI * rig.torso


func cost*(rig: Rig; apart: float; held: Rope): float =
  ## Get the rope a connection needs in a given state, taut.
  lie(rig, apart, held.side, held.site).length + windCost(rig, held)


func slack*(rig: Rig; apart: float; held: Rope): float =
  ## Get the rope a connection has left over, which is its room to move.
  budget(rig) - cost(rig, apart, held)


func feasible*(rig: Rig; apart: float; held: Rope): bool =
  ## Referee a state: the bodies keep their distance and the rope reaches.
  apart >= 2.0 * rig.torso - 1e-9 and slack(rig, apart, held) >= 0.0


func wound*(held: Rope; dancer: Dancer; halfTurns: int): Rope =
  ## Wind a connection: that dancer turns while the rope is carried low.
  result = held
  result.winds[dancer] += halfTurns


func twisted*(held: Rope; halfTurns: int): Rope =
  ## Twist a connection: a dancer turns while the rope is carried over the head.
  result = held
  result.twist += halfTurns


func comfortable*(rig: Rig; held: Rope): bool =
  ## Referee the grip: joined hands swivel only so far.
  abs(held.twist) <= rig.grip


func shed*(held: Rope; dancer: Dancer): Rope =
  ## Unwind every wrap on one body, by carrying the rope over that head.
  ##   Ask `liftable` first: this is what the lift is for, and the lift has
  ##     to be affordable where the couple stand.
  result = held
  result.winds[dancer] = 0


func liftable*(rig: Rig; apart: float; held: Rope;
    over = Dancer.Follow): bool =
  ## Referee carrying this connection over one dancer's head from where the
  ## couple stand.
  ##   The gate on every move danced over the head: a turn that spends twist,
  ##     and the shedding of a wrap.  At full stretch there is no rope left
  ##     to climb the neck with, which is why a turn is led close.
  ##   A wind on the body being lifted over is not charged for: the lift is
  ##     how it pays itself back out.  A wind on the other body stays spent.
  lie(rig, apart, held.side, held.site).length +
    windCost(rig, shed(held, over)) + rise(rig) <= budget(rig)


func bound*(rig: Rig; held: Rope): float =
  ## Get the widest the couple can stand while this connection holds.
  ##   Every wind shortens it, which is the sense in which a wrap binds.
  if not feasible(rig, touching(rig), held):
    return 0.0
  var
    near = touching(rig)
    far = budget(rig) + 2.0 * rig.torso + 1.0
  for _ in 0 ..< 60:
    let mid = (near + far) / 2.0
    if feasible(rig, mid, held):
      near = mid
    else:
      far = mid
  near


func pinLimit*(rig: Rig; side: Side; site: Site): int =
  ## Get how many half turns can be wound low before the rope refuses,
  ## with the couple as close as bodies allow.
  ##   This is the number `rotation.nim` had to measure as
  ##     `CAPACITY_WRAP_LOW`; here it falls out of girth against arm.
  var wraps = 0
  while feasible(rig, touching(rig), wound(rope(side, site), Dancer.Follow,
      wraps + 1)):
    inc wraps
  wraps



#[ Reading the lie ]#

func crossesMidline*(laid: Lie): bool =
  ## Test whether a lie crosses the line the two bodies stand astride.
  ##   The midline is the y axis; a lie crosses when its trace changes side
  ##     an odd number of times.
  var
    was = 0
    changes = 0
  for at in laid.trace:
    let now = if at.x > 1e-9: 1 elif at.x < -1e-9: -1 else: 0
    if now != 0:
      if was != 0 and now != was:
        inc changes
      was = now
  changes mod 2 == 1


func crossings*(a, b: Lie): int =
  ## Count where two lies cross each other on the plan.
  ##   Two ropes that cross must decide which is on top, which is the whole
  ##     of what `Frame.over` records.
  for i in 0 ..< a.trace.len - 1:
    for j in 0 ..< b.trace.len - 1:
      let
        p1 = a.trace[i]
        p2 = a.trace[i + 1]
        q1 = b.trace[j]
        q2 = b.trace[j + 1]
        d1 = cross(q2 - q1, p1 - q1)
        d2 = cross(q2 - q1, p2 - q1)
        d3 = cross(p2 - p1, q1 - p1)
        d4 = cross(p2 - p1, q2 - p1)
      if d1 * d2 < 0 and d3 * d4 < 0:
        inc result


func clearance*(rig: Rig; apart: float; laid: Lie): float =
  ## Measure the closest a lie comes to either body's centre.
  ##   Never less than the torso radius, or the rope is inside somebody.
  result = 1e12
  for o in [(0.0, 0.0), (0.0, apart)]:
    for index in 0 ..< laid.trace.len - 1:
      result = min(result, segClearance(laid.trace[index],
        laid.trace[index + 1], o))



#[ The couple ]#

type Couple* = object ## The whole physical state: a stance and its connections.
  apart*: float
  ropes*: seq[Rope]
  over*: Option[Side] ## Which crossed rope lies on top, where two must decide.


func atRest*(rig: Rig; frame: Frame; apart: float): Couple =
  ## Stand a couple in a frame, every connection lying at rest.
  result = Couple(apart: apart, over: frame.over)
  for side in Side:
    if frame.hold[side].isSome:
      result.ropes.add rope(side, frame.hold[side].get)


func feasible*(rig: Rig; couple: Couple): bool =
  ## Referee a whole state: every connection reaches, every body keeps out.
  for held in couple.ropes:
    if not feasible(rig, couple.apart, held):
      return false
  true
