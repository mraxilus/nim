## Place the couple in world coordinates, and give them every way to rotate.
##
##   A pose is where the two dancers actually are; `canonicalise` turns the
##     world until the lead faces up the page, which is what makes two poses
##     that are the same configuration seen from different angles the same
##     picture.
##     Cost of canonicalising: a pose's world coordinates are never shown, so
##       a reader cannot tell from one picture which way the room was.
##       Accepted -- the room was never the subject.
##   A cycle is move, come home, move back, come home, so an animation
##     returns exactly to its start and loops without a snap.
##   Dancers and arms index fixed arrays: the domain is closed and two wide,
##     so the storage is enum-indexed rather than keyed by name.

{.experimental: "strictFuncs".}

import std/[math, options]

import ./[geometry, rules]


const SEPARATION* = 56.0     ## Between the two dancers' centres.

type
  Wind* = array[Arm, float] ## Degrees each arm has been carried past rest.
  Winds* = array[Dancer, Wind] ## Both dancers' windings at once.
  Ring* = tuple ## The orbit ring, drawn only while an orbit is happening.
    centre: Point
    radius: float
  Pose* = object ## Hold where the couple are, and how far their arms wound.
    place*: array[Dancer, Point]  ## World position of each dancer.
    facing*: array[Dancer, float] ## Bearing each dancer faces, degrees.
    wind*: Winds                  ## How far each arm is carried round.
    ring*: Option[Ring]           ## The orbit ring, where one is happening.


func rest*(wind: Winds = default(Winds)): Pose =
  ## Get the pose every picture is measured from: the lead facing up the page.
  Pose(
    place: [(0.0, SEPARATION / 2), (0.0, -SEPARATION / 2)],
    facing: [0.0, 180.0],
    wind: wind,
    ring: none(Ring),
  )


func movedPose*(pose: Pose; mid: Point; spin, amount: float): Pose =
  ## Turn the whole pose about `mid`, then pull it `amount` of the way home.
  func moved(p: Point): Point =
    let q = turn(p, mid, spin)
    (q.x - amount * mid.x, q.y - amount * mid.y)

  result = pose
  for who in Dancer:
    result.place[who] = moved(pose.place[who])
    result.facing[who] = pose.facing[who] + spin
  if pose.ring.isSome:
    result.ring = some (moved(pose.ring.get.centre), pose.ring.get.radius)


type Anchor* {.pure.} = enum ## Say what a picture is framed on.
  Pair,                      ## The couple's midpoint: they sit in the middle.
  Lead                       ## The lead's own place: they are the still point.


func canonicalise*(pose: Pose; amount = 1.0; on = Anchor.Pair): Pose =
  ## Turn the world until the lead faces up the page.
  ##   Not until the pair stands upright -- until the *lead* does.
  ##     Everything is read from them, so they are the thing that holds
  ##     still, and where the follow has got to is then part of what the
  ##     picture says rather than something the framing has thrown away.
  ##   `on` says what the turning goes round and what is brought to the
  ##     middle afterwards.  On the pair, the couple is centred and any move
  ##     that shifts their midpoint carries the lead across the box with it.
  ##     On the lead, the lead never moves at all: a follow's orbit leaves
  ##     the framing exactly as it found it and needs no second stage, and a
  ##     lead's axis turn swings only the follow (rule 25).
  ##   At `amount` 0 it leaves the pose alone and at 1 it finishes the job,
  ##     so the second stage of a move is animated rather than snapped.
  let hub =
    case on
    of Anchor.Pair:
      ((pose.place[Dancer.Lead].x + pose.place[Dancer.Follow].x) / 2,
       (pose.place[Dancer.Lead].y + pose.place[Dancer.Follow].y) / 2)
    of Anchor.Lead:
      pose.place[Dancer.Lead]
  movedPose(pose, hub, -amount * wrap180(pose.facing[Dancer.Lead]), amount)


func spinAbout*(pose: Pose; who: Dancer; degrees: float): Pose =
  ## Turn one dancer on their own axis: nothing travels.
  result = pose
  result.facing[who] = pose.facing[who] + degrees
  result.ring = none(Ring)


func orbit*(pose: Pose; who: Dancer; degrees: float; locked = true): Pose =
  ## Walk one dancer round the other, who stands still.
  ##   `locked` keeps their face to their partner all the way round; without
  ##     it they keep their own bearing and arrive facing the way they set
  ##     off.  Those are two different moves, landing in two different places.
  let pivot = pose.place[if who == Dancer.Lead: Dancer.Follow else: Dancer.Lead]
  result = pose
  result.place[who] = turn(pose.place[who], pivot, degrees)
  result.facing[who] = pose.facing[who] + (if locked: degrees else: 0.0)
  result.ring = some (pivot, dist(pose.place[who], pivot))


func couple*(pose: Pose; degrees: float): Pose =
  ## Turn both round each other: the pair rotates rigidly about the midpoint.
  let mid = ((pose.place[Dancer.Lead].x + pose.place[Dancer.Follow].x) / 2,
             (pose.place[Dancer.Lead].y + pose.place[Dancer.Follow].y) / 2)
  result = movedPose(pose, mid, degrees, 0.0)
  result.ring = some (mid, dist(pose.place[Dancer.Lead], mid))


func relative*(pose: Pose): tuple[axis, facing: float] =
  ## Get what a canonical picture holds: where the follow is, and how they
  ## face.
  ##   Both measured against the lead, because the lead is what the picture
  ##     holds still.  Two poses with the same pair are the same picture.
  let axis = bearing(
    pose.place[Dancer.Follow].x - pose.place[Dancer.Lead].x,
    pose.place[Dancer.Follow].y - pose.place[Dancer.Lead].y)
  (round(floorMod(axis - pose.facing[Dancer.Lead], 360.0), 6),
   round(floorMod(pose.facing[Dancer.Follow] - pose.facing[Dancer.Lead],
                  360.0), 6))


func ease*(t: float): float =
  ## Slow both ends, so the two stages read as stages rather than as blur.
  (1 - cos(PI * t)) / 2


type MoveApply* = proc (pose: Pose; scalar: float): Pose {.nimcall, noSideEffect.}
  ## One animated move, as the pose it reaches at `scalar` of its full turn.


func cycle*(move: MoveApply; samples = 14): seq[Pose] =
  ## Sample move, come home, move back, come home -- returning to the start.
  for sign in [1.0, -1.0]:
    let base = if result.len > 0: result[^1] else: rest()
    for i in 0 .. samples:
      result.add move(base, sign * ease(i / samples))
    let landed = result[^1]
    for i in 0 .. samples:
      # Nothing travels in the second stage, so the ring goes out with it.
      var home = canonicalise(landed, ease(i / samples))
      home.ring = none(Ring)
      result.add home


type About* {.pure.} = enum ## What a dancer's turn goes round.
  Axis,                     ## Their own centre: they turn on the spot.
  Orbit                     ## Their partner: they walk the ring round them.


func turned*(base: Pose; who: Dancer; about: About; degrees: float): Pose =
  ## Turn one dancer, on their own axis or round their partner.
  ##   An orbit **keeps its bearing** (rule 20): the walker arrives facing
  ##     the way they set off, because walking round somebody is not the
  ##     same act as turning to keep facing them.
  ##     Keeping the face to the partner all the way round is an orbit and
  ##       an axis turn danced together, and is named as the compound it is
  ##       wherever it is still wanted.
  case about
  of About.Axis: spinAbout(base, who, degrees)
  of About.Orbit: orbit(base, who, degrees, locked = false)


func turnWalk*(base: Pose; who: Dancer; about: About; degrees: float;
    samples = 12; on = Anchor.Pair): seq[Pose] =
  ## Sample one turn and its return, in the stages the dance has.
  ##   Stage one is the turn itself, **with the world held still**: the
  ##     dancer turns where they are and the picture does not follow them.
  ##   Stage two reorients the picture, turning it until the lead faces up
  ##     again (rule 18).  It is only there when there is something to
  ##     bring back -- a turn that leaves the framing as it found it is
  ##     drawn in one stage, and what counts as the framing is `on`.
  ##   Then the same again in reverse, so the going and the coming read
  ##     from the one figure.
  func legs(from_pose: Pose; by: float): seq[Pose] =
    let landed = turned(from_pose, who, about, by)
    if relative(from_pose) == relative(landed):
      return @[from_pose]
    # Stage one: the turn, as the room sees it.
    for i in 0 .. samples:
      result.add turned(from_pose, who, about, by * ease(i / samples))
    # Stage two: the picture is re-framed until the lead faces up and the
    # anchor is back in the middle.  Nothing travels in it, so the orbit's
    # ring goes out with it.  It is skipped where it would draw nothing --
    # framed on the lead, that is every turn but the lead's own (rule 25).
    var settled_home = canonicalise(landed, on = on)
    settled_home.ring = none(Ring)
    if settled_home.place == landed.place and
        settled_home.facing == landed.facing:
      result[^1] = settled_home
      return result
    for i in 1 .. samples:
      var home = canonicalise(landed, ease(i / samples), on)
      home.ring = none(Ring)
      result.add home

  let there = legs(base, degrees)
  result = there
  for p in legs(there[^1], -degrees):
    result.add p


func moveLeadAxis(pose: Pose; scalar: float): Pose =
  spinAbout(pose, Dancer.Lead, 90 * scalar)

func moveFollowOrbits(pose: Pose; scalar: float): Pose =
  orbit(pose, Dancer.Follow, 90 * scalar, locked = false)

func moveLeadOrbits(pose: Pose; scalar: float): Pose =
  orbit(pose, Dancer.Lead, 90 * scalar, locked = false)

func moveCouple(pose: Pose; scalar: float): Pose =
  couple(pose, 90 * scalar)

const MOVES*: array[4, tuple[name: string, apply: MoveApply]] = [
  ("lead axis", MoveApply moveLeadAxis),
  ("follow orbits the lead", moveFollowOrbits),
  ("the lead orbits the follow", moveLeadOrbits),
  ("both, round each other", moveCouple),
] ## Every animated move, in the order the page and the checks walk them.
