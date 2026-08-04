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
  FACTOR_CLIP_NEAR* = 1.0/400.0
    ## Set the near clip plane this fraction of the orbit distance out. Scaled alongside
    ## `FACTOR_CLIP_FAR` so the frustum stays the same shape at every distance, which
    ## holds depth-buffer precision -- a function of the far-to-near ratio -- constant
    ## rather than letting it decay as the camera pulls back.



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


func initMatrixViewProjection*(camera: Camera; aspect: float): Matrix4 =
  ## Compose whole transform from world space to clip space.
  let eye = camera.eye
  initMatrixProjection(
    camera.degrees_field_of_view, aspect, camera.distanceNear, camera.distanceFar
  ) * initMatrixView(eye, camera.frame(eye))



#[ Aiming And Easing ]#

type
  CameraAim* = object ## Name where a camera should look to bring one object into view.
    ## Two cases, because a finite object and a horizon one are reached differently: a
    ## finite object is somewhere, so the camera moves its target onto it; a horizon
    ## object is only a direction, drawn fixed to the eye at any distance, so the camera
    ## instead turns to face along it and its target is left alone.
    case is_horizon*: bool
    of true:
      azimuth*, elevation*: float ## Orbit angles that look along the object's direction.
    of false:
      target*: Position ## Point the orbit should turn about.

  CameraTween* = object ## Carry a camera from where it was toward where it should look.
    ## Eased over `duration`, so a camera that jumps to a freshly built object is followed
    ## rather than teleported after. Empty until something aims it.
    ##   Retargeting captures wherever the tween had reached as its new start (see
    ##   `aimAt`), which is what lets a goal that moves every frame -- the staged geometry
    ##   of an open edit session, say -- read as one smooth chase instead of restarting.
    goal*: Option[CameraAim] ## Where the camera is heading, or has already arrived at.
      ## None only while nothing is aimed at all.
    is_arrived*: bool ## Whether `goal` has been reached. Set once the ease runs out, and
      ## what stops `advance` writing to the camera from then on: a caller offering the
      ## same goal every frame -- as one watching a selected object does -- must not go on
      ## holding the camera there, or the user's own orbit, pan and dolly are overridden
      ## the moment they let go. `goal` is deliberately kept rather than cleared, so that
      ## same offer is recognised as one already delivered instead of re-arming the ease.
    started*: float ## Clock reading `goal` was last set or retargeted at.
    duration*: float ## Seconds the ease takes, end to end.
    azimuth_from*, elevation_from*: float ## Orbit angles the current ease began at.
    target_from*: Position ## Target point the current ease began at.


func `==`*(a, b: CameraAim): bool =
  ## Compare two aims. Written out rather than left to Nim, whose generated `==` walks a
  ## case object's fields in parallel and refuses to compile for one.
  ##   Exact comparison, not approximate: this answers "is this the same aim I was already
  ##   given", so a caller offering the same goal every frame does not restart its ease.
  ##   An aim that genuinely moved by a hair should restart it.
  if a.is_horizon != b.is_horizon: return false
  if a.is_horizon:
    a.azimuth == b.azimuth and a.elevation == b.elevation
  else:
    a.target.x == b.target.x and a.target.y == b.target.y and a.target.z == b.target.z


func aimFor*(m: Multivector; scale: DrawExtent): Option[CameraAim] =
  ## Resolve where a camera should look to see `m`, or none where `m` draws nothing.
  ##   A point at horizon is a fixed star: the camera turns along its own direction.
  ##   A line at horizon is a whole great circle, so no single direction faces it; the
  ##   first axis spanning perpendicular to its normal is picked, which puts some of that
  ##   circle in view. A plane at horizon fills the sky and needs no aiming at all.
  ##   Everything finite is reached through `anchorFor`'s own representative point, so the
  ##   camera targets exactly what the overlay already rings.
  let shape_m = shape(m)
  if shape_m.isNone: return
  if isHorizon(m):
    var heading = none(Direction)
    case shape_m.get
    of Shape.Point: heading = directionHorizon(m)
    of Shape.Line:
      let normal = directionNormalHorizon(m)
      if normal.isSome:
        let axes = spanPerpendicular(Position(x: 0, y: 0, z: 0), normal.get)
        if axes.isSome: heading = some(axes.get[0])
    of Shape.Plane: discard
    if heading.isNone: return
    let (azimuth, elevation) = azimuthElevationFor(heading.get)
    return some(CameraAim(is_horizon: true, azimuth: azimuth, elevation: elevation))
  let anchor = anchorFor(m, scale)
  if anchor.isNone: return
  some(CameraAim(is_horizon: false, target: anchor.get))


proc aimAt*(tween: var CameraTween; camera: Camera; goal: CameraAim; now, duration: float) =
  ## Send the camera toward `goal`, easing from wherever it stands right now.
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
  if tween.goal.isSome and tween.goal.get == goal: return
  tween.goal = some(goal)
  tween.is_arrived = false
  tween.started = now
  tween.duration = duration
  tween.azimuth_from = camera.azimuth
  tween.elevation_from = camera.elevation
  tween.target_from = camera.target


proc advance*(
  tween: var CameraTween; camera: var Camera; now: float;
  ease: proc(t: float): float {.noSideEffect.},
) =
  ## Carry the camera one frame further toward its goal, and drop the goal on arrival.
  ##   `ease` is passed in rather than imported so this module stays independent of where
  ##   the project keeps its easing curve; callers hand it `mesh.easeOutCubic`, which is
  ##   the same curve and duration a freshly added object grows in with.
  if tween.goal.isNone or tween.is_arrived: return
  let progress = ease(clamp((now - tween.started) / max(tween.duration, 1.0e-6), 0.0, 1.0))
  let goal = tween.goal.get
  if goal.is_horizon:
    # Turn the short way round: azimuth is an angle, so a goal just past -pi is next door
    #   to a camera just short of +pi, not most of a turn away.
    var delta = goal.azimuth - tween.azimuth_from
    while delta > PI: delta -= 2.0*PI
    while delta < -PI: delta += 2.0*PI
    camera.azimuth = tween.azimuth_from + progress*delta
    camera.elevation = tween.elevation_from +
      progress*(goal.elevation - tween.elevation_from)
  else:
    camera.target = tween.target_from + progress*(goal.target - tween.target_from)
  if now - tween.started >= tween.duration: tween.is_arrived = true


proc settle*(tween: var CameraTween; camera: var Camera) =
  ## Put the camera on its goal at once -- for a caller that must not show a half-finished
  ## pan, such as a storyboard frame about to be captured.
  if tween.goal.isNone or tween.is_arrived: return
  let goal = tween.goal.get
  if goal.is_horizon:
    camera.azimuth = goal.azimuth
    camera.elevation = goal.elevation
  else:
    camera.target = goal.target
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
  ## as long as an object stays selected, so a goal cleared here is simply offered again
  ## on the very next frame and the camera is taken straight back off the user -- which
  ## is the whole bug. Keeping the goal and marking it done is what makes that standing
  ## offer read as one already answered.
  if tween.goal.isSome: tween.is_arrived = true
