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
    swan*: float     ## How far two connections may twist, in turns each way.
                     ## **An input, cited to the dance and to nothing in this
                     ## file.**  Every other number here is a measurement of a
                     ## body; this one is a report of what dancers find they
                     ## can do -- no twist, then the X, then the diamond, then
                     ## the swan, and no further.  The geometry has its own
                     ## opinion and `windLimit` will give it; where the two
                     ## disagree, both are said rather than one quietly
                     ## winning.

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
    Hug,   ## Along a cylinder: an arc in plan, a helix in space.
    Braid  ## Spiralling about the couple's axis, round its partner.

  Piece* = object ## One stretch of a taut rope, as measurements rather than
                  ## as points.
    ##   A hug is a centre, a radius and an angle; drawing it means sampling
    ##     it, and sampling is the one expensive thing here -- a rope wound
    ##     three times is some four hundred points, and the solver is asked
    ##     for a lie thousands of times a sweep while only one of them is
    ##     ever drawn.  So a lie carries what it *is* and `traced` makes the
    ##     points, once, for whoever actually needs them.
    kind*: Kind
    a*, b*: Vec  ## Where the stretch starts and ends.
    span*: float ## Its plan length: the chord, or the arc.
    centre*: Vec ## `Hug`: the rim it runs on.  `Braid`: the near body's axis.
    radius*: float ## `Hug`: the rim's.  `Braid`: how far out the rope runs.
    start*: float ## The angle it joins the rim at, or leaves the near body at.
    turn*: float  ## Signed total turning, which may pass 2*PI.
    axis*: Vec  ## `Braid` only: the unit way from one body to the other.
    lift*: float ## `Braid` only: the radius of the spiral's rise and fall,
                 ## which is what holds two braided ropes off each other.
    paired*: float ## `Braid` only: the height the pair's joined hands ride at,
                   ## which the two ropes share and take turns above and below.
    rises*: array[2, float] ## The height each end of the stretch is carried
                            ## at, where the stretch is part of a braid.  A
                            ## braided rope's height is a function of where
                            ## round the spiral it is, not of how far along it
                            ## has got, so it cannot be read off the tent.

  Lie* = object ## How a connection lies taut, in the winds it is carrying.
    pieces*: seq[Piece]
    span*: float    ## Its plan length.
    length*: float  ## Its length in space, once the climb is paid for.
    hugs*: int      ## How many rims it hugs.

  Fault* {.pure.} = enum ## Why a state is refused, one reason at a time.
    Tangent, ## A wind cannot be laid: a rim is unreachable from the one before.
    Through, ## The rope passes through a body.
    Budget,  ## The lie is longer than the two arms are.
    Braided, ## Two ropes cross closer than two arms are thick.
    Swan     ## The pair is twisted past what `Rig.swan` says dancers manage.


const HUMAN* = Rig(torso: 0.16, head: 0.09, arm: 0.62, limb: 0.04,
                   shoulder: 1.40, crown: 1.67, swan: 1.5)
  ## A human-proportioned body, in metres.
  ##   Hand-entered and cited to nothing.  Every answer the sim gives is a
  ##     fact about *these* numbers until they are measured off a person,
  ##     which is why the page lets them be moved rather than baking them in.
  ##   `crown` is `shoulder + 3 * head`: the neck and the head stacked on the
  ##     shoulder line.



#[ Plan Arithmetic ]#

func `+`(a, b: Vec): Vec = (a.x + b.x, a.y + b.y)
func `-`(a, b: Vec): Vec = (a.x - b.x, a.y - b.y)
func `*`(a: Vec; by: float): Vec = (a.x * by, a.y * by)
func dot(a, b: Vec): float = a.x * b.x + a.y * b.y
func cross(a, b: Vec): float = a.x * b.y - a.y * b.x

func dist*(a, b: Vec): float =
  ## Measure the straight way between two plan points.
  ##   Written out in its parts rather than as `sqrt(dot(a - b, a - b))`,
  ##     which reads better and is not what this module needs.  Every one of
  ##     those operators makes a fresh pair, and in a browser a fresh pair is
  ##     a fresh object with a copy behind it -- and this is called some
  ##     hundred thousand times for one frame of a drag.  Measured: the
  ##     spelt-out arithmetic is most of the difference between a page that
  ##     keeps up with a finger and one that does not.
  let
    dx = a.x - b.x
    dy = a.y - b.y
  sqrt(dx * dx + dy * dy)

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

func nearOn(a, b, o: Vec): float =
  ## Get how far along a run its closest point to `o` lies, as a fraction.
  let
    abx = b.x - a.x
    aby = b.y - a.y
    span = abx * abx + aby * aby
  if span < 1e-18: 0.0
  else: ((o.x - a.x) * abx + (o.y - a.y) * aby) / span


func alongTo(a, b, o: Vec; t: float): float =
  ## Measure how far `o` is from a point a fraction of the way along a run.
  let
    dx = a.x + (b.x - a.x) * t - o.x
    dy = a.y + (b.y - a.y) * t - o.y
  sqrt(dx * dx + dy * dy)


func bitesInto(a, b, o: Vec; radius, bite: float): bool =
  ## Test whether a straight run cuts into a body rather than grazing it.
  ##   The endpoints cannot decide this.  A rope is anchored *on* both rims,
  ##     so every run of it starts and ends touching a body; asking "does an
  ##     end lie on this rim" therefore excuses every body from every test,
  ##     which is how the first draft of this managed never to wind at all.
  ##   What separates leaving a rim from cutting through one is where the run
  ##     comes closest: at an end, it is leaving; in the middle, it is
  ##     cutting.
  if dist(a, b) < 1e-9:
    return dist(a, o) < radius - bite
  let t = nearOn(a, b, o)
  if t <= 1e-9 or t >= 1.0 - 1e-9:
    return min(dist(a, o), dist(b, o)) < radius - bite
  alongTo(a, b, o, t) < radius - bite


func nearing(a, b, o: Vec): float =
  ## Measure how close a straight run comes to a point.
  if dist(a, b) < 1e-9:
    return dist(a, o)
  alongTo(a, b, o, clamp(nearOn(a, b, o), 0.0, 1.0))



#[ The Rig ]#

func budget*(rig: Rig): float = 2.0 * rig.arm
  ## Get the rope one connection has: two arms tied at the joined hands.

func radiusOf(rig: Rig; band: Band): float =
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

func tentAt(rig: Rig; height, span, s: float): float =
  ## Get how high a connection is carried, a plan distance along it.
  ##   The joined hands ride at the middle of the rope, so raising them is a
  ##     tent: up from one shoulder and down to the other.
  if span < 1e-12:
    return height
  let rise = max(0.0, height - rig.shoulder)
  rig.shoulder + rise * (1.0 - abs(2.0 * s / span - 1.0))

func handAngle(state: State; hand: Hand): float =
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



#[ Tangents, in Closed Form ]#

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



#[ Two Ropes, Braiding ]#

## Two connections between the same pair of bodies are not strangers.  Turn one
## body and they wind about *each other* as surely as a rope winds about a
## chest -- they always braid; a torso or a head merely gets in between
## sometimes.  What follows is the clean case, where nothing is in between.
##
## The braid is described about the couple's axis.  Along it the rope runs
## from one anchor to the other; across it the rope sits at the torso's radius,
## at an angle that turns steadily from the angle its near hand is at to the
## angle its far hand is at.  Two connections are half a turn apart in that
## angle by construction -- one hand of a pair is across the body from the
## other -- and that half turn is the whole of the braid.
##
##   The plan offset is `torso * cos(angle)`, and at both ends that is exactly
##     where the hand is, because a hand *is* at `torso * cos(handAngle)` off
##     the axis.  So the braid meets its anchors exactly, and with the bodies
##     square it is the straight chord and nothing else: no seam at rest.
##   The two ropes cross in plan wherever that cosine is zero -- which happens
##     once per half turn of relative rotation.  Nought, one, two, three
##     crossings: the frame, the X, the diamond, the swan.  Nothing counts
##     them; a cosine has that many zeroes.
##   Across the axis the rope also rises and falls, by `lift * sin(angle)`.
##     At a crossing the cosine is zero so the sine is one, and the two ropes
##     are `2 * lift` apart in height with one above the other.  That is why
##     two braided ropes cannot pass through each other: not a check that
##     catches them, a shape that never lets them meet.
##   **The two ropes share one measure along the axis**, and that is what makes
##     the last sentence true rather than nearly true.  A hand is fore or aft
##     of its own shoulder as well as left or right of it, so the two
##     connections do not start and finish at the same place along the couple's
##     axis.  Given each its own measure, they would cross where the angles do
##     *not* agree, and cross with nothing between them.  So the spiral proper
##     runs over the stretch of axis both ropes have in common, and each rope
##     reaches its anchors by a straight run at either end -- runs that lie at
##     opposite offsets, and so cannot cross each other either.

func twist*(state: State): float =
  ## Get how far the two bodies have turned relative to one another, in
  ## radians, and nought when they stand square.
  ##   Not carried anywhere.  A facing accumulates without wrapping, so the
  ##     relative turn -- laps and all -- has been in the state since the
  ##     beginning and only wanted reading.
  state.stance[Body.Two].facing - state.stance[Body.One].facing + PI


func restAngle(hand: Hand): float =
  ## Get the angle a hand sits at on its rim with the bodies square.
  (if hand.body == Body.One: PI / 2 else: -PI / 2) +
    (if hand.arm == Arm.Left: PI / 2 else: -PI / 2)


func restTurn(link: Link): float =
  ## Get the turn a connection's braid already carries with the bodies square.
  ##   A hold that joins opposite hands lies flat: no turn.  One that joins
  ##     hands of the same name is already crossed over its partner, which is
  ##     half a turn, and the two ways of reading that half turn are the two
  ##     ways such a pair can be crossed -- a thing dancers choose and geometry
  ##     does not.  Taken anticlockwise, and said here rather than hidden.
  let delta = restAngle(link.ends[1]) - restAngle(link.ends[0])
  PI - floorMod(PI - delta, 2.0 * PI)


func braidTurn(state: State; link: Link): float =
  ## Get the angle a connection's braid turns through, end to end.
  (handAngle(state, link.ends[1]) - handAngle(state, link.ends[0])) -
    (restAngle(link.ends[1]) - restAngle(link.ends[0])) + restTurn(link)


func braidAt(piece: Piece; t: float): Vec =
  ## Get a plan point of a braid, a fraction of the way along the axis.
  ##   Along the axis by `d`, across it by the axis turned a quarter, which is
  ##     `(d.y, -d.x)`.  Spelt out in its parts for the reason `dist` is:
  ##     this is the innermost thing on the page.
  let
    dx = piece.axis.x
    dy = piece.axis.y
    near = (piece.a.x - piece.centre.x) * dx + (piece.a.y - piece.centre.y) * dy
    far = (piece.b.x - piece.centre.x) * dx + (piece.b.y - piece.centre.y) * dy
    along = near + (far - near) * t
    side = piece.radius * cos(piece.start + piece.turn * t)
  (piece.centre.x + dx * along + dy * side,
   piece.centre.y + dy * along - dx * side)


func braidLift(piece: Piece; t: float): float =
  ## Get how far above or below the pair's height a braid rides, a fraction
  ## of the way along the axis.
  piece.lift * sin(piece.start + piece.turn * t)


func braidSteps(piece: Piece): int =
  ## Get how finely a braid has to be sampled to draw and cross it truly.
  ##   Always even, so the middle of the braid -- where the joined hands are
  ##     and where the height it is carried at turns over -- is a sample
  ##     rather than something a chord cuts the corner off.
  let n = max(16, int(ceil(abs(piece.turn) / 0.15)))
  n + (n and 1)


func braidHigh(rig: Rig; piece: Piece; t: float): float =
  ## Get how high a braid is carried, a fraction of the way along the axis.
  ##   The pair's height, not the rope's own, and read off the shared axis
  ##     rather than off either rope's length.  That is what makes the two
  ##     ropes exactly `2 * lift` apart wherever they cross: they are at the
  ##     same place along the same axis, one the spiral's radius above the
  ##     pair's height and the other the same below.  Give each rope its own
  ##     tent instead, as an unbraided one has, and the two tents disagree by
  ##     more than the spiral separates by -- so the ropes meet.
  ##   The tent profile is scale-free, so a span of one with `s = t` reads it
  ##     by fraction.
  tentAt(rig, piece.paired, 1.0, t) + braidLift(piece, t)


func braiding*(state: State): bool =
  ## Say whether the two connections are free to braid about each other.
  ##   Two of them, and neither caught on a body.  A pair that is free to
  ##     braid with no turn between them is braiding all the same; it is a
  ##     braid of nothing, which is two straight ropes.
  if state.links.len != 2:
    return false
  for link in state.links:
    if link.winds.len > 0:
      return false
  true


func braidOf(state: State; link: Link): Option[Piece] =
  ## Describe the braid one connection is in, if it is in one.
  ##   Only a pair free to braid gets one.  Once either rope has caught on a
  ##     body the wind geometry governs and this steps aside -- the seam in
  ##     this model, named as such in the README.
  if not braiding(state):
    return none(Piece)
  var mate = -1
  for i, other in state.links:
    if other.ends != link.ends:
      mate = i
  if mate < 0:
    return none(Piece)
  let
    c1 = state.stance[link.ends[0].body].centre
    c2 = state.stance[link.ends[1].body].centre
  if dist(c1, c2) < 1e-9:
    return none(Piece)
  let
    d = unit(c2 - c1)
    n: Vec = (d.y, -d.x)
    other = state.links[mate]
    # The stretch of axis both ropes reach: from the further of the two near
    # hands to the nearer of the two far ones.  Inside it the two are measured
    # by the one ruler, which is what puts a crossing where the angles agree.
    from_at = max(dot(anchor(state, link.ends[0]) - c1, d),
                  dot(anchor(state, other.ends[0]) - c1, d))
    to_at = min(dot(anchor(state, link.ends[1]) - c1, d),
                dot(anchor(state, other.ends[1]) - c1, d))
    near = min(from_at, (from_at + to_at) / 2.0)
    far = max(to_at, (from_at + to_at) / 2.0)
    start = handAngle(state, link.ends[0])
    turn = braidTurn(state, link)
    reach = state.rig.torso
  some(Piece(kind: Kind.Braid,
             a: c1 + d * near + n * (reach * cos(start)),
             b: c1 + d * far + n * (reach * cos(start + turn)),
             centre: c1, axis: d, radius: reach, start: start, turn: turn,
             paired: (link.height + other.height) / 2.0,
             # Closed up as far as the arms allow, and no closer: half an arm's
             # thickness each is what keeps the two ropes off one another where
             # they cross.  Hands held at different heights simply braid wider.
             lift: max(state.rig.limb,
                       abs(link.height - other.height) / 2.0)))



#[ Sampling a Lie ]#

func braidedLie*(lie: Lie): bool =
  ## Say whether a connection is lying in a braid.
  for piece in lie.pieces:
    if piece.kind == Kind.Braid:
      return true
  false


func traced*(state: State; link: Link; lie: Lie):
    tuple[at: seq[Vec], high: seq[float]] =
  ## Sample a lie as a polyline, with the height each point is carried at.
  ##   The one place arcs and spirals become points, and it is called once per
  ##     rope per picture rather than thousands of times per sweep.
  ##   Two ways of getting a height, and which applies is which kind of
  ##     stretch it is: an ordinary run is tented over its own length, as it
  ##     always was, while a braid is carried at the pair's height read off
  ##     the axis both ropes share.  The runs that join a braid to its hands
  ##     carry the heights `lay` worked out for their ends.
  let braided = braidedLie(lie)
  var gone = 0.0
  for piece in lie.pieces:
    case piece.kind
    of Kind.Reach:
      if result.at.len == 0:
        result.at.add piece.a
        result.high.add (if braided: piece.rises[0]
                         else: tentAt(state.rig, link.height, lie.span, gone))
      result.at.add piece.b
      result.high.add (if braided: piece.rises[1]
                       else: tentAt(state.rig, link.height, lie.span,
                                    gone + piece.span))
    of Kind.Hug:
      let arc = arcPoints(piece.centre, piece.radius, piece.start, piece.turn)
      for k, at in arc:
        if result.at.len == 0 or dist(result.at[^1], at) > 1e-12:
          result.at.add at
          result.high.add tentAt(state.rig, link.height, lie.span,
            gone + piece.span * float(k) / float(max(1, arc.high)))
    of Kind.Braid:
      let steps = braidSteps(piece)
      for k in 0 .. steps:
        let
          t = float(k) / float(steps)
          at = braidAt(piece, t)
        if result.at.len == 0 or dist(result.at[^1], at) > 1e-12:
          result.at.add at
          result.high.add braidHigh(state.rig, piece, t)
    gone += piece.span



#[ Laying a Rope Out ]#

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
  ## rope at rest is -- unless it is braiding with a partner, in which case it
  ## is the spiral that braid puts it on.
  ##
  ## Nothing is sampled here but a braid, which has to be: an arc is measured
  ## as `radius * angle`, which is exact and costs nothing, where a spiral's
  ## length is an integral nobody has in closed form.
  let
    p = anchor(state, link.ends[0])
    q = anchor(state, link.ends[1])
  var lie = Lie(hugs: link.winds.len)
  var braid = none(Piece)
  if link.winds.len == 0:
    let got = braidOf(state, link)
    # A braid carrying no turn is the chord and nothing else, so it is left as
    # the chord: the resting hold has no seam in it and costs not a millimetre
    # more than it did before there was a braid to be in.
    if got.isSome and abs(got.get.turn) > 1e-9:
      braid = got
  if braid.isSome:
    var piece = braid.get
    let
      steps = braidSteps(piece)
      up = braidHigh(state.rig, piece, 0.0)
      down = braidHigh(state.rig, piece, 1.0)
    # Both measures in the one walk.  A braid's height depends on where round
    # the spiral it is and not on how far along it has got, so the length does
    # not have to wait for the span to be known -- and this is called some
    # hundreds of times for every frame of a drag, so it walks once.
    var
      was = braidAt(piece, 0.0)
      high = up
      span = 0.0
    for i in 1 .. steps:
      let
        t = float(i) / float(steps)
        at = braidAt(piece, t)
        step = dist(was, at)
        rise = braidHigh(state.rig, piece, t)
      span += step
      lie.length += sqrt(step * step + (rise - high) * (rise - high))
      was = at
      high = rise
    piece.span = span
    # The two straight runs that bring the rope off the spiral and out to the
    # hands.  They lie along the axis at the offset the hand is already at, so
    # the pair's two are on opposite sides of it and cannot meet each other.
    if dist(p, piece.a) > 1e-12:
      let run = dist(p, piece.a)
      lie.pieces.add Piece(kind: Kind.Reach, a: p, b: piece.a,
        span: run, rises: [state.rig.shoulder, up])
      lie.length += sqrt(run * run +
        (up - state.rig.shoulder) * (up - state.rig.shoulder))
    lie.pieces.add piece
    if dist(piece.b, q) > 1e-12:
      let run = dist(piece.b, q)
      lie.pieces.add Piece(kind: Kind.Reach, a: piece.b, b: q,
        span: run, rises: [down, state.rig.shoulder])
      lie.length += sqrt(run * run +
        (down - state.rig.shoulder) * (down - state.rig.shoulder))
    for one in lie.pieces:
      lie.span += one.span
  elif link.winds.len == 0:
    lie.pieces = @[Piece(kind: Kind.Reach, a: p, b: q, span: dist(p, q))]
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
    var stand = p
    for i, wind in link.winds:
      let
        (centre, radius) = rimOf(state, wind)
        start = rimAt(centre, radius, enters[i])
        turn = wind.way.float *
          (sweepOf(enters[i], leaves[i], wind.way.float) +
            2.0 * PI * wind.turns.float)
        stop = rimAt(centre, radius, enters[i] + turn)
      if dist(stand, start) > 1e-9:
        lie.pieces.add Piece(kind: Kind.Reach, a: stand, b: start,
          span: dist(stand, start))
      lie.pieces.add Piece(kind: Kind.Hug, a: start, b: stop,
        span: radius * abs(turn), centre: centre, radius: radius,
        start: enters[i], turn: turn)
      stand = stop
    if dist(stand, q) > 1e-9:
      lie.pieces.add Piece(kind: Kind.Reach, a: stand, b: q,
        span: dist(stand, q))
    for piece in lie.pieces:
      lie.span += piece.span
  if braid.isNone:
    # The joined hands ride at the middle of the rope, so raising them is a
    # tent: up from one shoulder and down to the other.  A braided rope's
    # length was measured in its own walk above, climb and all.
    let rise = max(0.0, link.height - state.rig.shoulder)
    lie.length = sqrt(lie.span * lie.span + 4.0 * rise * rise)
  some(lie)


func barFor(state: State; link: Link; lie: Lie; gone, span: float): float =
  ## Get the width a body presents to one stretch of a lie.
  ##   A braided connection is asked about as *one* stretch, read at its
  ##     middle, because that is how an unbraided one has always been asked:
  ##     a single reach from hand to hand, judged where the joined hands are.
  ##     Splitting the braid into its spiral and its two lead-ins and then
  ##     judging each at its own height would have a rope carried over both
  ##     crowns catching on a chest at the very ends -- a difference made by
  ##     the sampling and not by the dance.
  let mid = if braidedLie(lie): lie.span / 2.0 else: gone + span / 2.0
  girth(state.rig, tentAt(state.rig, link.height, lie.span, mid))


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
  for piece in lie.pieces:
    let bar = barFor(state, link, lie, gone, piece.span)
    case piece.kind
    of Kind.Reach:
      if bar > 0.0:
        for who in Body:
          result = min(result, nearing(piece.a, piece.b,
            state.stance[who].centre) - bar)
    of Kind.Hug:
      discard # A hug touches the rim it is on by definition.
    of Kind.Braid:
      # A braid bows about the axis, so it is asked run by run: the bow is
      # what could put it into a chest.
      if bar > 0.0:
        let steps = braidSteps(piece)
        var was = braidAt(piece, 0.0)
        for i in 1 .. steps:
          let at = braidAt(piece, float(i) / float(steps))
          for who in Body:
            result = min(result,
              nearing(was, at, state.stance[who].centre) - bar)
          was = at
    gone += piece.span



#[ Two Ropes, and Which Is on Top ]#

type Meeting* = object ## Where two ropes cross in plan, and how high each is.
  at*: Vec
  along*: array[2, float] ## Plan distance along each lie to the crossing.
  high*: array[2, float]  ## Height of each lie there.


func meetings*(state: State; a_link: Link; a: Lie;
    b_link: Link; b: Lie): seq[Meeting] =
  ## Find every place two ropes cross, seen from above.
  ##   Where they cross is where the question of which is on top gets asked;
  ##     everywhere else there is nothing to ask.
  let
    one = traced(state, a_link, a)
    two = traced(state, b_link, b)
  var gone_a = 0.0
  for i in 0 ..< one.at.high:
    # Spelt out in coordinates, and the boxes tested before the crossings.
    #   Two braided ropes are some sixty points each, so this is four
    #     thousand pairs of runs asked three times a frame, and every pair
    #     written as vector arithmetic makes four fresh pairs to throw away.
    #     The boxes throw out all but a handful of them for two comparisons.
    let
      p1x = one.at[i].x
      p1y = one.at[i].y
      p2x = one.at[i + 1].x
      p2y = one.at[i + 1].y
      ex = p2x - p1x
      ey = p2y - p1y
      a_lo = min(p1x, p2x)
      a_hi = max(p1x, p2x)
      a_down = min(p1y, p2y)
      a_up = max(p1y, p2y)
      step_a = sqrt(ex * ex + ey * ey)
    var gone_b = 0.0
    for j in 0 ..< two.at.high:
      let
        q1x = two.at[j].x
        q1y = two.at[j].y
        q2x = two.at[j + 1].x
        q2y = two.at[j + 1].y
        fx = q2x - q1x
        fy = q2y - q1y
        step_b = sqrt(fx * fx + fy * fy)
      if not (max(q1x, q2x) < a_lo or min(q1x, q2x) > a_hi or
              max(q1y, q2y) < a_down or min(q1y, q2y) > a_up):
        let
          d1 = fx * (p1y - q1y) - fy * (p1x - q1x)
          d2 = fx * (p2y - q1y) - fy * (p2x - q1x)
          d3 = ex * (q1y - p1y) - ey * (q1x - p1x)
          d4 = ex * (q2y - p1y) - ey * (q2x - p1x)
        if d1 * d2 < 0 and d3 * d4 < 0:
          let
            t = d1 / (d1 - d2)
            u = d3 / (d3 - d4)
            # Read off the sampled walk, because a braided rope's height is a
            # function of where round the spiral it is and not of how far
            # along it has got -- and at a crossing that is the whole of what
            # keeps the two ropes apart.
            ha = one.high[i] + (one.high[i + 1] - one.high[i]) * t
            hb = two.high[j] + (two.high[j + 1] - two.high[j]) * u
          result.add Meeting(at: (p1x + ex * t, p1y + ey * t),
            along: [gone_a + step_a * t, gone_b + step_b * u], high: [ha, hb])
      gone_b += step_b
    gone_a += step_a


const CROSS_SLIP = 1e-3
  ## How much of the sampling's own error to forgive where two ropes cross.
  ##   A crossing is found on a chord of the spiral rather than on the spiral
  ##     itself, so the height read there is a shade low -- a fifth of a
  ##     millimetre at `braidSteps`'s sampling.  Refusing on that would refuse
  ##     the very braid the geometry has just built to keep the two apart.


func overOf*(rig: Rig; met: Meeting): Option[int] =
  ## Say which of two crossing ropes is on top, where the heights decide it.
  ##   Where they do not, the answer is nothing, and the nothing is the
  ##     point: two ropes within an arm's thickness of each other are
  ##     touching, so which is over is something the dancers settle rather
  ##     than something the geometry has already settled.  Handing back the
  ##     question is more honest than inventing an answer to it.
  ##   Touching is not that case, which matters now there is a braid: two
  ##     ropes braiding at one height come out exactly an arm's thickness
  ##     apart, because that is as close as the braid will let them lie, and
  ##     which took the upper strand is then a fact about the braid.  The
  ##     question is handed back only where the two are *closer* than they can
  ##     be -- which is the same reading that refuses the state outright, and
  ##     rightly so: where two ropes are through each other, which is over is
  ##     not a thing the geometry has.
  let apart = met.high[0] - met.high[1]
  if abs(apart) < 2.0 * rig.limb - CROSS_SLIP: none(int)
  elif apart > 0.0: some(0)
  else: some(1)


func pairFault(state: State; swan = true): Option[Fault] =
  ## Say what refuses a state for the sake of one rope against another.
  ##   Every other judgement in this module takes one connection and asks the
  ##     bodies about it.  This is the one that asks the connections about
  ##     each other, and without it two ropes may occupy the same space at no
  ##     cost -- which they cannot.
  if state.links.len < 2:
    return none(Fault)
  if swan and abs(twist(state)) > state.rig.swan * 2.0 * PI + 1e-9:
    return some(Fault.Swan)
  for i in 0 ..< state.links.len:
    for j in i + 1 ..< state.links.len:
      let
        a = lay(state, state.links[i])
        b = lay(state, state.links[j])
      if a.isNone or b.isNone:
        continue
      for met in meetings(state, state.links[i], a.get, state.links[j], b.get):
        if abs(met.high[0] - met.high[1]) < 2.0 * state.rig.limb - CROSS_SLIP:
          return some(Fault.Braided)
  none(Fault)


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


func refusal*(state: State; swan = true): Option[Fault] =
  ## Say what refuses a whole state, if anything does.
  ##   Connection by connection first, then the connections against each
  ##     other.  The second half is new and is what the braid is for: two
  ##     ropes were strangers before it, free to lie through one another.
  for link in state.links:
    let fault = faultOf(state, link)
    if fault.isSome:
      return fault
  pairFault(state, swan)


func holds*(state: State; swan = true): bool =
  ## Referee a whole state: every connection reaches, nothing passes through
  ## anything, and the pair is not twisted past what dancers manage.
  ##   `swan = false` asks the geometry alone.  The two answers are worth
  ##     keeping apart, because one of them is measured and the other is
  ##     asserted, and a page that showed only their minimum would let the
  ##     assertion pass for a measurement.
  refusal(state, swan).isNone



#[ Turning, and Keeping Count ]#

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
  for piece in laid.get.pieces:
    let bar = barFor(state, link, laid.get, gone, piece.span)
    case piece.kind
    of Kind.Reach:
      if bar > 0.0:
        for who in Body:
          if bitesInto(piece.a, piece.b, state.stance[who].centre, bar,
              BIRTH_BITE):
            return ord(who)
    of Kind.Hug:
      discard
    of Kind.Braid:
      if bar > 0.0:
        let steps = braidSteps(piece)
        var was = braidAt(piece, 0.0)
        for i in 1 .. steps:
          let at = braidAt(piece, float(i) / float(steps))
          for who in Body:
            if bitesInto(was, at, state.stance[who].centre, bar, BIRTH_BITE):
              return ord(who)
          was = at
    gone += piece.span
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


func advance(state: State; who: Body; by: float): State =
  ## Turn one body a small step, carrying every rope's winding with it.
  result = state
  result.stance[who].facing += by
  for i in 0 ..< state.links.len:
    result.links[i] = carried(state, result, state.links[i])


func turned*(state: State; who: Body; to: float; step = 0.10): State =
  ## Turn one body all the way to an angle, in steps small enough to count.
  ##   Pure: the answer depends on where the body is asked to end up and not
  ##     at all on how it was dragged there, because the whole turn is
  ##     replayed from where it started every time.  The winding underneath
  ##     is path-dependent and has to be; replaying is what keeps that from
  ##     reaching the surface.
  ##   The step is as coarse as it can be without changing the answer.  What
  ##     has to stay under half a circle is the *sweep*, not the turn, and
  ##     the halving below watches the sweep -- so a fine step buys nothing
  ##     but work, and the work is a replay per frame on a page.  Measured:
  ##     every step from 0.01 to 0.30 radians gives the same lengths and the
  ##     same lap counts out to two turns, on both a parallel hold and a
  ##     crossed one -- the halving finds the places that need care, and
  ##     there are not many of them.
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
    step = 0.10; swan = true): float =
  ## Get how far one body can turn before some connection first refuses.
  ##   Swept, not assumed.  The wind grows, the arc lengthens, and the limit
  ##     is wherever the length first crosses what two arms have.  The number
  ##     is not in the model; it comes out of it.
  ##   Scanned once, carrying the turn forward.  Asking `turned` for the
  ##     whole angle at every step of the scan replays the sweep from rest
  ##     each time, which turns a walk into a triangle -- the same answer for
  ##     the square of the work, and it was most of a second on the page.
  ##   The bisection runs inside the one step that failed, from the state at
  ##     the start of it, so the answer is the geometry's rather than the
  ##     step size's without paying for a replay per guess either.
  var
    went = 0.0
    here = state
  while went < most:
    let next = turned(here, who, step, step)
    if not holds(next, swan):
      var
        lo = 0.0
        hi = step
      for _ in 0 ..< 20:
        let mid = (lo + hi) / 2.0
        if holds(turned(here, who, mid, step), swan): lo = mid else: hi = mid
      return went + lo
    here = next
    went += step
  most
