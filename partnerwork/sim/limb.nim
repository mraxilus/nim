## One arm: where its joints are for a given hand, and what each joint reads.
##
##   An arm is three rigid links -- upper arm, forearm, hand -- on a shoulder
##     that swings and twists, an elbow that bends, and a wrist that bends any
##     way.  The forearm's own rotation is left free: it turns the palm, and a
##     grip is a point.
##   Given the shoulder and the grip, the pose has three freedoms: which way
##     the hand points off the wrist (two), and where the elbow sits on the
##     circle a two-link chain leaves it (one).  Everything else follows.  So
##     the solver next door searches three numbers per arm, and every pose it
##     ever tries has its lengths right by construction.
##   The joints are read back off the pose, in the body's own terms, and the
##     left arm is read in a mirror so that one set of ranges serves both.
##     The shoulder's twist is read swing-and-twist: the arm at rest hangs
##     down with the elbow bending forward; at any other direction the
##     resting plane is carried there by the least rotation, and the twist is
##     how far the actual elbow plane is turned from it.  That reading is
##     continuous everywhere but a vertical arm, which no hold reaches.
##     Cost: the reading is a convention, and anatomists have three.  Accepted
##       -- this one has its one singularity where no dancer's arm goes, and
##       the ranges cited for it are the ordinary clinical ones.

{.experimental: "strictFuncs".}

import std/math

import ./[body, rig, vec]


type
  ArmPose* = object ## The four points of one arm, in the world.
    s*, e*, w*, g*: Vec ## Shoulder, elbow, wrist, grip.

  Joints* = object ## What each joint reads, radians, in the body's own terms.
    extend*, across*, elev*: float ## The upper arm: behind, across, up.
    twist*, bend*, wrist*: float

  Chain* = object ## What laying out an arm to a grip found.
    pose*: ArmPose
    stretch*: float ## Shoulder to wrist: over `upper + fore` is out of reach.


const
  REST_DOWN = (0.0, 0.0, -1.0) ## The upper arm hanging: the swing's rest.
  REST_PLANE = (1.0, 0.0, 0.0) ## Its elbow plane's normal at rest: bending
                               ## forward, with the arm read as a right arm.
  STRAIGHT = 5.0 * PI / 180.0  ## Under this bend an elbow has no plane, so
                               ## no twist is read off it.


func shoulderLocal*(rig: Rig): Vec = (rig.shoulderOut, 0.0, rig.shoulderUp)
  ## The shoulder in the body's mirrored terms: always a right arm here.


func posed*(rig: Rig; s, g, h: Vec; swivel: float): Chain =
  ## Lay the arm from shoulder `s` to grip `g` with the hand pointing along
  ## the unit `h` and the elbow at `swivel` round its circle, nought being
  ## the lowest the elbow can hang.
  ##   Out of reach is not refused here: the elbow goes as far as it can and
  ##     the forearm is left too long, so that a searcher minimising the
  ##     overshoot has something smooth to descend.
  let
    w = g - h * rig.hand
    d = dist(w, s)
  result.stretch = d
  if d < 1e-9:
    result.pose = ArmPose(s: s, e: s + (0.0, 0.0, -rig.upper), w: w, g: g)
    return
  let
    u = (w - s) * (1.0 / d)
    along = clamp((rig.upper * rig.upper - rig.fore * rig.fore + d * d) / (2.0 * d),
                  -rig.upper, rig.upper)
    rad = sqrt(max(0.0, rig.upper * rig.upper - along * along))
  var down = REST_DOWN - u * dot(REST_DOWN, u)
  if norm(down) < 1e-6:
    down = perp(u)
  else:
    down = unit(down)
  let
    side = cross(u, down)
    e = s + u * along + down * (rad * cos(swivel)) + side * (rad * sin(swivel))
  result.pose = ArmPose(s: s, e: e, w: w, g: g)


func placed*(rig: Rig; st: Stance; arm: Arm; u: Vec;
             twist, bend, wrist, roll: float): ArmPose =
  ## Build an arm from its joints: the upper arm along the unit `u` in the
  ## body's mirrored terms, twisted, bent at the elbow, the hand off the
  ## forearm by `wrist` in the direction `roll` turns it to.
  ##   Forward kinematics, for the laws: what `joints` reads must be what
  ##     was set here.
  let
    plane = spun(carried(REST_PLANE, REST_DOWN, u), u, twist)
    f = u * cos(bend) + cross(plane, u) * sin(bend)
    m = spun(plane, f, roll)
    h = f * cos(wrist) + m * sin(wrist)
    s = shoulderLocal(rig)
    e = s + u * rig.upper
    w = e + f * rig.fore
    g = w + h * rig.hand
    ax = axesOf(st)
  func placedOut(p: Vec): Vec =
    toWorld(ax, (if arm == Arm.Left: mirrored(p) else: p))
  ArmPose(s: placedOut(s), e: placedOut(e), w: placedOut(w), g: placedOut(g))


func joints*(st: Stance; arm: Arm; pose: ArmPose): Joints =
  ## Read every joint off the pose, in the body's own terms.
  let ax = axesOf(st)
  func own(p: Vec): Vec =
    let q = toBody(ax, p)
    if arm == Arm.Left: mirrored(q) else: q
  let
    s = own(pose.s)
    e = own(pose.e)
    w = own(pose.w)
    g = own(pose.g)
    u = unit(e - s)
    f = unit(w - e)
    h = unit(g - w)
  result.extend = arcsin(clamp(-u.y, -1.0, 1.0))
  result.across = arcsin(clamp(-u.x, -1.0, 1.0))
  result.elev = arcsin(clamp(u.z, -1.0, 1.0))
  result.bend = angleBetween(u, f)
  result.wrist = angleBetween(f, h)
  if result.bend > STRAIGHT:
    let
      rest = carried(REST_PLANE, REST_DOWN, u)
      plane = unit(cross(u, f))
    result.twist = signedAngle(rest, plane, u)
  else:
    result.twist = 0.0


func reading*(j: Joints; dof: Dof): float =
  ## The one value of the joints a range applies to.
  case dof
  of Dof.Extend: j.extend
  of Dof.Across: j.across
  of Dof.Twist: j.twist
  of Dof.Bend: j.bend
  of Dof.Wrist: j.wrist

func margins*(rig: Rig; j: Joints): array[Dof, float] =
  ## Each freedom's distance inside its range, in its ease.
  for dof in Dof:
    result[dof] = margin(rig.range[dof], reading(j, dof))

func strain*(rig: Rig; j: Joints): tuple[most: float, dof: Dof] =
  ## How far into the last stretch before an edge the arm is: nought well
  ## inside, one at the edge, more past it; and which joint that is.
  result = (0.0, Dof.Extend)
  var least = Inf
  for dof in Dof:
    let m = margin(rig.range[dof], reading(j, dof))
    if m < least:
      least = m
      result.dof = dof
  result.most = max(0.0, 1.0 - least)

func comfort*(rig: Rig; j: Joints): float =
  ## The smooth cost of a pose: how far every joint sits from its rest,
  ## squared and summed, with the arm's lift counted too.
  ##   Minimised by the solver among the poses that hold, so that neighbouring
  ##     turns get neighbouring poses and a hanging arm is preferred to a
  ##     raised one where both would do.
  for dof in Dof:
    let d = eased(rig.range[dof], reading(j, dof))
    result += d * d
  let lift = (j.elev + PI / 2.0) / PI
  result += lift * lift
