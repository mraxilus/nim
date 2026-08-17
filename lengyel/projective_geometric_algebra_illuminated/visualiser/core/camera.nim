## Orbit camera about target, and assemble transforms OpenGL draws through.
##
## Camera's own frame is still derived through RGA, exactly as objects it looks at are:
##
##   |-------------|---------------|-------------------------------------------------|
##   | Identifier  | Construction  | Meaning                                         |
##   |-------------|---------------|-------------------------------------------------|
##   | axis_sight  | 𝐞 ∧ 𝐭         | Line joining eye to target.                     |
##   | forward     | att(𝐋)        | Unit direction eye looks along.                 |
##   | axis_right  | -(𝐋 ∧ 𝐮)☆     | Unit direction of view's +x.                    |
##   | axis_up     | -(𝐋 ∧ 𝐫)☆     | Unit direction of view's +y.                    |
##   |-------------|---------------|-------------------------------------------------|
##
## Only projection is left to convention: perspective divide, depth range and clip volume
## belong to graphics pipeline rather than to geometry, so they are written out directly.
##
## Placement is spherical about target, since that is what mouse drag turns.
##   Elevation is clamped short of poles, where up direction would run along sight axis
##   and the joins above would collapse.

## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

# Reorder so placement reads before frame derived from it, though `pan` calls `frame`.
#   Constants below stay in dependency order regardless, as reordering does not cover them.
{.experimental: "codeReordering".}
{.experimental: "strictFuncs".}

import std/[math, options]

import ../../pga
import ./[mesh, objects]



#[ Camera Configuration ]#

const
  UP_WORLD* = Direction(x: 0.0, y: 0.0, z: 1.0)
    ## Fix world's up direction, which azimuth turns about and elevation rises from.
  ELEVATION_LIMIT* = 0.5*PI - 0.02
    ## Bound elevation short of pole, where sight axis would run along `UP_WORLD`.
  DISTANCE_LIMIT_NEAR* = 0.05
    ## Bound how close eye may orbit to target.
  DISTANCE_LIMIT_FAR* = 500.0
    ## Bound how far eye may orbit from target.
  FACTOR_CLIP_FAR* = 20.0
    ## Set the far clip plane this many times the orbit distance out. Scaled rather than
    ## fixed so everything meant to read as "at the horizon" -- `mesh.radiusHorizonFor`,
    ## `mesh.extentFurnitureFor`, and the far end of every drawn line -- stays past what
    ## the frame can show at any orbit distance. A fixed plane cannot: the view's own
    ## extent grows with distance while the plane does not, so dollying out eventually
    ## brings a line's own far end inside the frame, where it reads as stopping in
    ## mid-air. Worse, a plane fixed nearer than `DISTANCE_LIMIT_FAR` clips the target
    ## itself away once the eye orbits past it.
  FRACTION_VIEW_CENTRED* = 2.0/3.0
    ## Fraction of the frame that counts as being looked at: this much of its height, and
    ## this much of its width **or its height, whichever is less**. `reachCentred` is the
    ## one place that shape is written down, and says why the width is capped.
    ##   Why a box at all rather than the whole frame: an object clinging to the very edge
    ##   is on screen without being what the view is about, and the marker ringing it is
    ##   half off-frame. Why not the exact middle: a selection is *framed* inside this box,
    ##   spread across it, and demanding every object at the middle would mean demanding
    ##   they coincide.
    ##   Lives here rather than beside the pixel test in `picking` because the camera needs
    ##   it too, to solve how far back an eye must stand for a whole selection to fit; that
    ##   solution is `distanceFitting`, and `picking` imports this module already.
  FACTOR_CLIP_NEAR* = 1.0/400.0
    ## Set the near clip plane this fraction of the orbit distance out. Scaled alongside
    ## `FACTOR_CLIP_FAR` so the frustum stays the same shape at every distance, which
    ## holds depth-buffer precision -- a function of the far-to-near ratio -- constant
    ## rather than letting it decay as the camera pulls back.

const
  ## How far one **key press** moves the camera. Shared by both front-ends, unlike the
  ## per-pixel drag rates, which differ for a real reason: `visualiser.SPEED_ORBIT` is
  ## radians per pixel dragged and `glue.js` works in fractions of canvas width, so those
  ## two cannot be one number. A press has no pixels in it, so these can be, and are.
  ##   Sized so a reader crosses the useful range in a handful of presses rather than
  ## dozens -- a keyboard route nobody can be bothered to hold down is a keyboard route in
  ## name only -- while still landing somewhere deliberate rather than overshooting.
  TURN_PRESS* = 0.10 ## Azimuth one arrow press turns through, in radians (about 6 degrees).
  RISE_PRESS* = 0.08 ## Elevation one arrow press rises through, in radians.
  PAN_PRESS* = 0.06 ## Target shift one press slides, as a fraction of orbit distance.
  FACTOR_DOLLY_PRESS* = 1.15 ## Orbit distance one press scales by, dollying out; its
    ## reciprocal dollies in, so a press each way returns exactly where it started.



#[ Type Definitions ]#

type
  Matrix4* = object ## Hold 4x4 transform in column-major order, as OpenGL expects.
    elements: array[16, float32]

  Camera* = object ## Hold placement of eye about target, and lens it looks through.
    target*: Position ## Point orbit turns about.
    distance*: float ## Separation of eye from target.
    azimuth*: float ## Angle about world up, in radians.
    elevation*: float ## Angle above horizon, in radians.
    degrees_field_of_view*: float ## Vertical field of view, in degrees.

  FrameCamera* = object ## Hold orthonormal directions of camera's own axes.
    axis_right*: Direction ## Unit direction of view's +x.
    axis_up*: Direction ## Unit direction of view's +y.
    forward*: Direction ## Unit direction eye looks along.



#[ Matrix Arithmetic ]#

func at*(matrix: Matrix4; row, column: int): float32 = matrix.elements[4*column + row]
  ## Read element of matrix, addressed as reader writes it rather than as GPU stores it.


func elementsAddress*(matrix: Matrix4): ptr float32 =
  ## Point at first element, for handing whole matrix to OpenGL.
  unsafeAddr matrix.elements[0]


func `*`*(a, b: Matrix4): Matrix4 =
  ## Compose transforms, applying `b` before `a`.
  for row in 0 .. 3:
    for column in 0 .. 3:
      var sum = 0.0'f32
      for i in 0 .. 3:
        sum += a.at(row, i) * b.at(i, column)
      result.elements[4*column + row] = sum


func initMatrixProjection*(
  degrees_field_of_view, aspect, distance_near, distance_far: float
): Matrix4 =
  ## Construct perspective projection onto OpenGL's clip volume.
  ##   Depth maps to -1 .. 1, and camera looks along its own -z, as pipeline expects.
  let
    focal = 1.0 / tan(0.5 * degToRad(degrees_field_of_view))
    span = distance_near - distance_far
  result.elements[0] = float32(focal / aspect)
  result.elements[5] = float32(focal)
  result.elements[10] = float32((distance_far + distance_near) / span)
  result.elements[11] = -1.0
  result.elements[14] = float32(2.0 * distance_far * distance_near / span)


func initMatrixView*(eye: Position; frame: FrameCamera): Matrix4 =
  ## Construct transform carrying world into camera's own frame.
  ##   Rows hold camera axes, so transform is inverse of camera's placement.
  let (right, up, forward) = (frame.axis_right, frame.axis_up, frame.forward)
  let offset = eye - Position(x: 0, y: 0, z: 0)
  result.elements = [
    float32(right.x), float32(up.x), float32(-forward.x), 0.0,
    float32(right.y), float32(up.y), float32(-forward.y), 0.0,
    float32(right.z), float32(up.z), float32(-forward.z), 0.0,
    float32(-dot(right, offset)), float32(-dot(up, offset)), float32(dot(forward, offset)),
    1.0,
  ]



#[ Camera Placement ]#

func initCamera*(target: Position; distance, azimuth, elevation: float): Camera =
  ## Construct camera orbiting `target` at given separation and angles.
  Camera(
    target: target,
    distance: clamp(distance, DISTANCE_LIMIT_NEAR, DISTANCE_LIMIT_FAR),
    azimuth: azimuth,
    elevation: clamp(elevation, -ELEVATION_LIMIT, ELEVATION_LIMIT),
    degrees_field_of_view: 45.0,
  )


func initCameraDefault*(): Camera =
  ## Place the camera where both front-ends open, and where `home` puts it back.
  ##   One statement of it: this placement was written out twice, in `visualiser.main` and
  ##   in `browser_bridge.nimInit`, and a keyboard key that returns to it would have made a
  ##   third copy. Chosen to show the seed scene whole, slightly above the ground plane so
  ##   the plane reads as a plane rather than as a line.
  initCamera(
    target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05, elevation = 0.42
  )


func distanceNear*(camera: Camera): float = camera.distance*FACTOR_CLIP_NEAR
  ## Read nearest depth the clip volume keeps.
  ##   Derived from orbit distance rather than stored, so it cannot go stale: a stored
  ##   pair set once at construction stays at its original value through every dolly,
  ##   which is exactly the bug this replaced.


func distanceFar*(camera: Camera): float = camera.distance*FACTOR_CLIP_FAR
  ## Read farthest depth the clip volume keeps; see `distanceNear` for why it is derived.


func eye*(camera: Camera): Position =
  ## Place eye on sphere about target, from azimuth and elevation.
  let radius = camera.distance * cos(camera.elevation)
  camera.target + Direction(
    x: radius * cos(camera.azimuth),
    y: radius * sin(camera.azimuth),
    z: camera.distance * sin(camera.elevation),
  )


func azimuthElevationFor*(heading: Direction): (float, float) =
  ## Solve orbit angles an orbit camera would need to look along `heading`, regardless
  ## of target or distance -- `eye`'s own formula cancels target out of `forward`
  ## entirely (`forward = normalize(target - eye) = normalize(target - target - D) =
  ## -normalize(D)`, where `D` depends only on azimuth, elevation and distance), so
  ## this is the plain spherical-coordinates inverse of that same `D`, independent of
  ## wherever the camera actually orbits.
  ##   Meant for aiming a capture at a horizon object's own direction: unlike a finite
  ##   one, it is not anchored anywhere a fixed demo angle already frames, so whether
  ##   it falls inside view depends entirely on which way the camera happens to look.
  let elevation = arcsin(clamp(-heading.z, -1.0, 1.0))
  let azimuth = arctan2(-heading.y, -heading.x)
  (azimuth, elevation)


proc orbit*(camera: var Camera; turn, rise: float) =
  ## Turn eye about target by given angles, keeping elevation short of poles.
  camera.azimuth += turn
  camera.elevation = clamp(camera.elevation + rise, -ELEVATION_LIMIT, ELEVATION_LIMIT)


proc dolly*(camera: var Camera; factor: float) =
  ## Scale separation of eye from target, keeping it within orbit's bounds.
  camera.distance = clamp(
    camera.distance * factor, DISTANCE_LIMIT_NEAR, DISTANCE_LIMIT_FAR
  )


proc pan*(camera: var Camera; across, up: float) =
  ## Slide target within plane facing eye, so whole view shifts with it.
  let axes = camera.frame(camera.eye)
  camera.target = camera.target +
    (across * camera.distance)*axes.axis_right +
    (up * camera.distance)*axes.axis_up



#[ Camera Frame ]#

func frame*(camera: Camera; eye: Position): FrameCamera =
  ## Derive camera's orthonormal axes from its placement, through joins and antiduals.
  ##   Elevation clamp keeps sight axis off world up, so every join below stays defined.
  ##   Takes eye explicitly rather than reading `camera.eye` itself, so a caller that
  ##   already holds it, or that calls this once per frame across many items, need not
  ##   pay for the same handful of trig calls again on every one of those calls.
  let
    axis_sight = toMultivector(eye) ∧ toMultivector(camera.target)
    forward = direction(axis_sight)
  doAssert forward.isSome,
    "Camera eye and target must differ; orbit distance is bounded away from zero."

  let axis_right = directionNormal(axis_sight ∧ toMultivector(UP_WORLD))
  doAssert axis_right.isSome,
    "Camera sight axis must not run along world up; elevation is clamped short of poles."

  let axis_up = directionNormal(axis_sight ∧ toMultivector(axis_right.get))
  doAssert axis_up.isSome,
    "Camera sight axis and right direction must span plane; they are perpendicular."

  # Pin view's +y to world up, as antidual fixes axis only up to sign.
  let orientation = if dot(axis_up.get, UP_WORLD) < 0: -1.0 else: 1.0
  FrameCamera(
    axis_right: axis_right.get,
    axis_up: orientation * axis_up.get,
    forward: forward.get,
  )


func drawExtentFor*(camera: Camera; height_pixels: int): DrawExtent =
  ## Derive this frame's own draw scale from the camera: how far its geometry reaches,
  ## where from, and everything a ribbon needs to hold a constant width on screen.
  ##   One constructor, because there were four -- three literal copies in `visualiser.nim`
  ##   and a fourth in `browser_bridge`, whose own doc comment admitted to duplicating
  ##   them. It lives here rather than in `mesh`, where `DrawExtent` is declared, because
  ##   it reads a `Camera` and `camera` imports `mesh` rather than the other way round.
  ##   `height_pixels` is the framebuffer's, not the window's: a ribbon's width is
  ##   measured in the pixels actually drawn.
  let eye = camera.eye
  DrawExtent(
    extent_furniture: extentFurnitureFor(camera.distanceFar),
    eye: eye,
    radius_horizon: radiusHorizonFor(camera.distanceFar),
    forward: camera.frame(eye).forward,
    tangent_half_view: tan(0.5*degToRad(camera.degrees_field_of_view)),
    height_pixels: height_pixels,
    depth_near: camera.distanceNear,
  )


func initMatrixViewProjection*(camera: Camera; aspect: float): Matrix4 =
  ## Compose whole transform from world space to clip space.
  let eye = camera.eye
  initMatrixProjection(
    camera.degrees_field_of_view, aspect, camera.distanceNear, camera.distanceFar
  ) * initMatrixView(eye, camera.frame(eye))



#[ Aiming And Easing ]#

type
  SphereWorld* = object ## Bound a set of world points by centre and radius.
    ## What "the selection" means to a camera framing it: everything finite it was asked to
    ## show sits inside this, so a distance that fits the sphere fits every one of them.
    centre*: Position ## Point the orbit should turn about.
    radius*: float ## How far the furthest object stands from `centre`. Zero for one point.

  CameraAim* = object ## Name what a camera has been asked to bring into view.
    ## Not a placement: a **requirement**, derived from the geometry alone and from nothing
    ## about where the camera happens to stand. That is what lets a caller re-offer the same
    ## selection every frame and have it recognised as the same request -- see
    ## `CameraTween.goal`, which rests on it entirely.
    ##   The two halves are reached differently, which is why they are separate rather than
    ## one case: a finite object is somewhere, so the camera moves its target onto it and,
    ## where several are spread wide, pulls back until they fit; a horizon object is only a
    ## direction, drawn fixed to the eye at any distance, so the camera instead turns to
    ## face along it and its target and distance are left alone.
    sphere*: Option[SphereWorld] ## Finite objects to frame, or none where there are none.
    is_bound_by_points*: bool ## Whether `sphere` is over the picked *points* alone.
      ## A point has to fit inside the centred box; a line and a plane have only to cross
      ## it. So where anything has to fit, that alone is what the camera centres and sizes
      ## itself on, and the rest are left to the test -- otherwise a line whose support
      ## happens to stand a hundred units away would drag the view off the point beside it
      ## and force a pull-back for nothing. Where nothing has to fit -- a selection of
      ## lines and planes alone -- the sphere falls back to their own support points, so
      ## the camera still has somewhere to look.
    heading*: Option[Direction] ## Direction of the horizon objects to face, or none.
      ## Merged where several were asked for: no single direction faces two stars on
      ## opposite sides of the sky, and the sum of their unit directions is the nearest
      ## thing to one that does.

  CameraPlacement* = object ## Where a camera stands -- everything an ease moves.
    ## The lens is not here: a field of view is the reader's own setting, and nothing that
    ## aims a camera has any business rewriting it.
    target*: Position ## Point the orbit turns about.
    distance*: float ## Separation of eye from target.
    azimuth*, elevation*: float ## Orbit angles, in radians.

  CameraTween* = object ## Carry a camera from where it was toward where it should look.
    ## Eased over `duration`, so a camera that jumps to a freshly built object is followed
    ## rather than teleported after. Empty until something aims it.
    ##   Retargeting captures wherever the tween had reached as its new start (see
    ##   `aimAt`), which is what lets a goal that moves every frame -- the staged geometry
    ##   of an open edit session, say -- read as one smooth chase instead of restarting.
    goal*: Option[CameraAim] ## What the camera is watching, or has already settled on.
      ## None only while nothing is aimed at all.
      ##   A *requirement*, not a placement: derived from the selected geometry alone, so a
      ##   caller re-offering the same selection every frame offers a goal that compares
      ##   equal every frame. That is what the ignore rule in `aimAt` and the standing-offer
      ##   rule in `abandon` both rest on, and it is why where the ease actually ends is
      ##   kept separately below rather than folded in here.
    destination*: CameraPlacement ## Where the ease ends: the goal resolved against the
      ## camera as it stood when the goal was armed -- see `framing.placementFor`, which is
      ## what computes it, and `framing.offerAim`, which is what every caller uses.
      ##   Meaningless while `goal` is none; set alongside it and never on its own.
    is_arrived*: bool ## Whether `destination` has been reached. Set once the ease runs
      ## out, and what stops `advance` writing to the camera from then on: a caller offering
      ## the same goal every frame -- as one watching a selection does -- must not go on
      ## holding the camera there, or the user's own orbit, pan and dolly are overridden
      ## the moment they let go. `goal` is deliberately kept rather than cleared, so that
      ## same offer is recognised as one already delivered instead of re-arming the ease.
    started*: float ## Clock reading `goal` was last set or retargeted at.
    duration*: float ## Seconds the ease takes, end to end.
    placement_from*: CameraPlacement ## Where the current ease began.


func `==`*(a, b: SphereWorld): bool =
  ## Compare two bounds exactly; see `CameraAim`'s own `==` for why exactly.
  a.centre.x == b.centre.x and a.centre.y == b.centre.y and a.centre.z == b.centre.z and
    a.radius == b.radius


func `==`*(a, b: CameraAim): bool =
  ## Compare two aims. Written out rather than left to Nim so the comparison is stated
  ## where the reason for it is.
  ##   Exact comparison, not approximate: this answers "is this the same request I was
  ##   already given", so a caller offering the same selection every frame does not restart
  ##   its ease. A selection that genuinely moved by a hair should restart it.
  if a.sphere.isSome != b.sphere.isSome: return false
  if a.sphere.isSome and not (a.sphere.get == b.sphere.get): return false
  if a.is_bound_by_points != b.is_bound_by_points: return false
  if a.heading.isSome != b.heading.isSome: return false
  if a.heading.isNone: return true
  let (d, e) = (a.heading.get, b.heading.get)
  d.x == e.x and d.y == e.y and d.z == e.z


func widened*(bound: SphereWorld; place: Position): SphereWorld =
  ## Grow a bound just enough to contain one more point.
  ##   Incremental rather than a fit over the whole set at once, so a caller folding a
  ##   selection needs no array to fold over and allocates nothing. The result depends on
  ##   the order points arrive in and can be a little wider than the tightest sphere over
  ##   the same set; it is always a true bound, which is all the framing needs.
  let
    offset = place - bound.centre
    away = norm(offset)
  if away <= bound.radius: return bound
  let radius = 0.5*(bound.radius + away)
  # Slide the centre toward the new point by exactly what the far side gives up, so the
  #   old sphere stays enclosed rather than being trimmed on the way.
  SphereWorld(centre: bound.centre + ((radius - bound.radius)/away)*offset, radius: radius)


func aimIncluding*(aim: Option[CameraAim]; m: Multivector; scale: DrawExtent): Option[CameraAim] =
  ## Fold one more object into an aim, or start one where there was none.
  ##   Unchanged by geometry that draws nothing, and by a plane at horizon, which fills the
  ##   sky and is in view from every camera there is.
  ##   A point at horizon is a fixed star, faced along its own direction. A line at horizon
  ##   is a whole great circle, so no single direction faces it; the first axis spanning
  ##   perpendicular to its normal is picked, which puts some of that circle in view.
  ##   Everything finite widens the sphere by `anchorFor`'s own representative point, so
  ##   the camera frames exactly what the overlay already rings -- except that the first
  ##   *point* folded in throws away whatever lines and planes had contributed, and they
  ##   contribute nothing thereafter; see `CameraAim.is_bound_by_points`. The outcome does
  ##   not depend on the order they arrive in.
  ##   Horizon objects deliberately widen nothing: `anchorFor` places a star at
  ##   `scale.eye`, and a goal built from where the camera stands would stop comparing
  ##   equal frame to frame.
  let shape_m = shape(m)
  if shape_m.isNone: return aim
  var grown = if aim.isSome: aim.get else: CameraAim()

  if isHorizon(m):
    var heading = none(Direction)
    case shape_m.get
    of Shape.Point: heading = directionHorizon(m)
    of Shape.Line:
      let normal = directionNormalHorizon(m)
      if normal.isSome:
        let axes = spanPerpendicular(ORIGIN_WORLD, normal.get)
        if axes.isSome: heading = some(axes.get[0])
    of Shape.Plane: discard
    if heading.isNone: return aim
    let merged =
      if grown.heading.isNone: heading
      else: normalize(grown.heading.get + heading.get)
    # Two headings that cancel outright leave the first standing: they face opposite ways
    #   and neither turn shows both, so turning to the one already asked for beats turning
    #   to whatever a zero-length sum happens to normalise into.
    grown.heading = if merged.isSome: merged else: grown.heading
    return some(grown)

  let anchor = anchorFor(m, scale)
  if anchor.isNone: return aim
  let is_point = shape_m.get == Shape.Point
  if grown.is_bound_by_points and not is_point: return some(grown)
  if is_point and not grown.is_bound_by_points:
    return some(CameraAim(
      sphere: some(SphereWorld(centre: anchor.get, radius: 0.0)),
      is_bound_by_points: true, heading: grown.heading,
    ))
  grown.sphere =
    if grown.sphere.isNone: some(SphereWorld(centre: anchor.get, radius: 0.0))
    else: some(grown.sphere.get.widened(anchor.get))
  some(grown)


func aimFor*(m: Multivector; scale: DrawExtent): Option[CameraAim] =
  ## Resolve what a camera has been asked to show for one object alone, or none where it
  ## draws nothing. The one-object case of `aimIncluding`, for callers that have one.
  aimIncluding(none(CameraAim), m, scale)


func reachCentred*(width, height: int; inset: float): (float, float) =
  ## Measure the centred box, across and down, in pixels of a `width` x `height` frame.
  ##   The one statement of the box's shape: `picking` turns it into the margins its pixel
  ## test compares against, and `halfAngleCentred` below turns it into the cone
  ## `distanceFitting` solves. Written twice, the two drifted apart -- the cone already took
  ## the narrower axis while the pixel test took the whole rectangle.
  ##   **Why the width is capped at the height.** The field of view is vertical, so a
  ## fraction of the frame's width is a fraction of `aspect` times as much *world*: at
  ## 1440x900 the box reached 23.9 degrees off the sight axis across against 15.4 down,
  ## while at 390x844 it reached 7.3. That is one rule behaving as three, and it is what
  ## made picking an object on a desktop window almost never move the camera -- measured
  ## on the shipped build, a point stayed "already in view" out to two thirds of the way to
  ## the frame's edge whatever the window's shape, which on a wide one is most of the world
  ## in front of the reader. Capping the width at the height makes the box's reach the same
  ## in angle both ways, so a pick behaves the same under a mouse as under a finger.
  ##   The cap is one-sided on purpose: on a frame taller than it is wide -- a phone held
  ## upright -- the width is already the shorter side, so the box is left exactly as it was
  ## and touch keeps the behaviour it already had. Taking `min` on both axes instead would
  ## have tightened the phone's own vertical band to under a third of the frame.
  ##   `inset` pulls the box in by that many pixels on every side, for a caller that needs
  ## what it asks to fit to fit *with room to spare*: `framing` passes the room a point's
  ## own drawn dot takes, so a distance solved from this really does satisfy the pixel test
  ## in `picking`, which insets by the same amount. A box inset past nothing collapses to
  ## the very middle of the frame rather than turning inside out.
  (
    max(FRACTION_VIEW_CENTRED*float(min(width, height)) - 2.0*inset, 0.0),
    max(FRACTION_VIEW_CENTRED*float(height) - 2.0*inset, 0.0),
  )


func halfAngleCentred*(camera: Camera; width, height: int; inset: float): float =
  ## Measure the half-angle, from the sight axis, that the centred box covers -- the
  ## narrower of its two, so anything inside that cone is inside the box both ways.
  ##   The box is a fraction of the frame *in the projection plane*, not in angle, so its
  ## own half-angles come from scaling tangents rather than from scaling the field of view.
  ## Both scale by the frame's **height**, since that is the dimension the vertical field
  ## of view sizes; the box's own width already carries whatever the aspect did to it.
  let
    tangent_half = tan(0.5*degToRad(camera.degrees_field_of_view))
    (reach_across, reach_down) = reachCentred(width, height, inset)
    tangent_down = max(reach_down/float(height), 1.0e-6)*tangent_half
    tangent_across = max(reach_across/float(height), 1.0e-6)*tangent_half
  arctan(min(tangent_down, tangent_across))


func distanceFitting*(radius: float; camera: Camera; width, height: int; inset: float): float =
  ## Solve how far an eye must stand from the centre of a sphere of `radius` for the whole
  ## of it to fall inside the centred box.
  ##   The sphere's tangent condition, `sin`, not the flat one, `tan`: a point on the near
  ##   side of the sphere stands as far off the sight axis as the far side does while being
  ##   closer to the eye, so it subtends more.
  ##   Clamped to the same bound the user's own dolly is clamped to, so a selection spread
  ##   wider than the world may be viewed from pulls back as far as it may and no further.
  let sine = sin(halfAngleCentred(camera, width, height, inset))
  clamp(radius/max(sine, 1.0e-6), DISTANCE_LIMIT_NEAR, DISTANCE_LIMIT_FAR)


func isGoalHeld*(tween: CameraTween; goal: CameraAim): bool =
  ## Report whether `goal` is one this tween already holds, and would therefore ignore.
  ##   For a caller whose own preparation is worth skipping when the answer is going to be
  ##   discarded: `framing.offerAim` projects every selected object onto the frame several
  ##   times over to decide how far the camera must pull back, and re-offers the same goal
  ##   every frame for as long as a selection stands.
  tween.goal.isSome and tween.goal.get == goal


func placementOf*(camera: Camera): CameraPlacement =
  ## Read where `camera` already stands as a placement of its own.
  CameraPlacement(
    target: camera.target, distance: camera.distance,
    azimuth: camera.azimuth, elevation: camera.elevation,
  )


func placed*(camera: Camera; placement: CameraPlacement): Camera =
  ## Put a copy of `camera` at `placement`, lens untouched.
  result = camera
  result.target = placement.target
  result.distance = placement.distance
  result.azimuth = placement.azimuth
  result.elevation = placement.elevation


func toward*(from_placement, to_placement: CameraPlacement; progress: float): CameraPlacement =
  ## Step `progress` of the way from one placement to another.
  ##   Distance moves geometrically where everything else moves linearly, because distance
  ##   is a multiplicative quantity: the wheel and `FACTOR_DOLLY_PRESS` both scale it, and
  ##   a linear ease from 12 to 300 would cover most of the visible change in the first few
  ##   frames and then crawl.
  # Turn the short way round: azimuth is an angle, so a destination just past -pi is next
  #   door to a camera just short of +pi, not most of a turn away.
  var delta = to_placement.azimuth - from_placement.azimuth
  while delta > PI: delta -= 2.0*PI
  while delta < -PI: delta += 2.0*PI
  let (near, far) = (max(from_placement.distance, 1.0e-6), max(to_placement.distance, 1.0e-6))
  CameraPlacement(
    target: from_placement.target + progress*(to_placement.target - from_placement.target),
    distance: near*pow(far/near, progress),
    azimuth: from_placement.azimuth + progress*delta,
    elevation: from_placement.elevation +
      progress*(to_placement.elevation - from_placement.elevation),
  )


func `==`*(a, b: CameraPlacement): bool =
  ## Compare two placements exactly, for a caller asking whether a camera would move at all.
  a.target.x == b.target.x and a.target.y == b.target.y and a.target.z == b.target.z and
    a.distance == b.distance and a.azimuth == b.azimuth and a.elevation == b.elevation


proc aimAt*(
  tween: var CameraTween; camera: Camera; goal: CameraAim; destination: CameraPlacement;
  now, duration: float
) =
  ## Set the camera watching `goal` and ease it to `destination`, from where it stands now.
  ##   A requirement and a placement, not one thing twice: `goal` says what has to be in
  ##   view and is what a re-offer is recognised by, `destination` is where that puts the
  ##   camera once resolved against wherever it stood when the goal arrived.
  ##   Reading the start off the live camera rather than off the previous goal is what
  ##   makes a moving goal smooth: the camera has already been eased partway there by
  ##   `advance` below, so starting the next ease from that reading continues the motion
  ##   instead of snapping back.
  ##   Re-aiming at a goal already set is ignored, so a caller may offer the same goal
  ##   every frame -- as one watching an unchanged edit session does -- without the ease
  ##   restarting forever and never arriving. That holds after arrival too, which is what
  ##   keeps a standing offer from re-aiming the camera at something it already reached
  ##   and taking it back off the user each frame. `release` is how a caller says the
  ##   offer is withdrawn, and only then does the same goal aim the camera again.
  if tween.isGoalHeld(goal): return
  tween.goal = some(goal)
  tween.destination = destination
  # Nothing at all to carry where the camera already stands on its destination. Marked
  #   arrived outright rather than left to ease through a whole duration's worth of frames
  #   writing the reading it already holds, which would fight a user who starts orbiting
  #   inside that window.
  tween.is_arrived = destination == camera.placementOf
  tween.started = now
  tween.duration = duration
  tween.placement_from = camera.placementOf


proc advance*(
  tween: var CameraTween; camera: var Camera; now: float;
  ease: proc(t: float): float {.noSideEffect.},
) =
  ## Carry the camera one frame further toward its destination, and mark it arrived there.
  ##   `ease` is passed in rather than imported so this module stays independent of where
  ##   the project keeps its easing curve; callers hand it `mesh.easeOutCubic`, which is
  ##   the same curve and duration a freshly added object grows in with.
  if tween.goal.isNone or tween.is_arrived: return
  let progress = ease(clamp((now - tween.started) / max(tween.duration, 1.0e-6), 0.0, 1.0))
  camera = camera.placed(tween.placement_from.toward(tween.destination, progress))
  if now - tween.started >= tween.duration: tween.is_arrived = true


proc settle*(tween: var CameraTween; camera: var Camera) =
  ## Put the camera on its destination at once -- for a caller that must not show a
  ## half-finished pan, such as a storyboard frame about to be captured.
  if tween.goal.isNone or tween.is_arrived: return
  camera = camera.placed(tween.destination)
  tween.is_arrived = true


proc release*(tween: var CameraTween) =
  ## Withdraw whatever the camera was aimed at, leaving it wherever it stands.
  ##   For whoever offers the aim, once it has nothing to offer -- the selection cleared,
  ## the edit session closed. Clearing the goal outright is what lets picking the same
  ## object again aim at it afresh, rather than having it recognised as one already
  ## delivered and ignored forever.
  ##   Not for a camera the *user* just moved: see `abandon`.
  tween.goal = none(CameraAim)
  tween.is_arrived = false


proc abandon*(tween: var CameraTween) =
  ## Stop carrying the camera, but remember what it was carrying it toward.
  ##   For every path that moves the camera on the user's own instruction: an orbit, pan
  ## or dolly half a second into an ease should win outright rather than fight the
  ## remainder of it.
  ##   Deliberately not `release`. The aim is a standing offer, re-made every frame for
  ## as long as a selection stands, so a goal cleared here is simply offered again on the
  ## very next frame and the camera is taken straight back off the user -- which is the
  ## whole bug. Keeping the goal and marking it done is what makes that standing offer read
  ## as one already answered.
  if tween.goal.isSome: tween.is_arrived = true
