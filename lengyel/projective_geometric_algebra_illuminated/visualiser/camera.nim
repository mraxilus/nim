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

import ../pga
import ./objects



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
    distance_near*: float ## Nearest depth kept by clip volume.
    distance_far*: float ## Farthest depth kept by clip volume.

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
    distance_near: 0.05,
    distance_far: 400.0,
  )


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
    camera.degrees_field_of_view, aspect, camera.distance_near, camera.distance_far
  ) * initMatrixView(eye, camera.frame(eye))
