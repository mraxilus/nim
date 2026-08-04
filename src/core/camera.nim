## Place the eye, and move it to whatever the user is working on.
##
## The camera is an orbit camera: a target point, an orbit distance, an azimuth, an elevation
## and a vertical field of view. Both clip planes are **derived from the orbit distance, never
## stored**, so the frustum keeps its shape however far the camera dollies and the depth
## buffer's precision — a function of the far-to-near ratio — stays constant instead of
## decaying as the camera pulls back. A stored pair keeps its construction-time value through
## every dolly, which once put the far plane inside the orbit range and clipped whole scenes
## away.
##
## Aiming is a **standing offer**, applied once per frame rather than at each event, and its
## three subtleties each cost this project a real bug. They are spelled out on `offer`,
## `abandon` and `release`.

{.experimental: "strictFuncs".}

import std/[math, options]

import ./[algebra, config, transform]



#[ Type Definitions ]#

type
  Camera* = object
    ## Hold the orbit camera's seven editable fields.
    target*: Position   ## Point the camera orbits.
    distance*: float    ## Radius of the orbit.
    azimuth*: float     ## Angle about world up, in radians.
    elevation*: float   ## Angle above the ground plane, in radians.
    fov*: float         ## Vertical field of view, in radians.

  Aim* = object
    ## Name where the camera is being asked to look, in whichever parts matter.
    target*: Option[Position]  ## Point to orbit, where the aim moves it.
    azimuth*: Option[float]    ## Angle to turn to, where the aim turns the camera.
    elevation*: Option[float]  ## Angle to rise to, where the aim turns the camera.

  Tween* = object
    ## Ease the camera toward a standing offer, once per frame.
    goal: Option[Aim]
    is_delivered: bool
    elapsed_ms: float
    start: Camera



#[ Camera Constants ]#

const
  WORLD_UP* = Position(x: 0.0, y: 0.0, z: 1.0)
    ## Point world up along +z.
  ELEVATION_LIMIT* = PI*0.5 - 0.02
    ## Stop the elevation short of the pole, where the view frame degenerates.
  DISTANCE_MIN* = 0.05
    ## Hold the orbit off the target.
  DISTANCE_MAX* = 500.0
    ## Cap how far the camera dollies out.
  FAR_CLIP_FACTOR* = 20.0
    ## Set the far plane at this many orbit distances.
  NEAR_CLIP_DIVISOR* = 400.0
    ## Set the near plane at the orbit distance over this.
  ORBIT_RADIANS_PER_PIXEL* = 0.008
    ## Turn the camera this far per pixel of drag.
  PAN_FRACTION_PER_PIXEL* = 0.0016
    ## Slide the target this fraction of the orbit distance per pixel of drag.
  DOLLY_SCALE_PER_NOTCH* = 1.12
    ## Scale the orbit distance by this per wheel notch.

func defaultCamera*(): Camera =
  ## Build the view the tool opens on.
  Camera(
    target: Position(x: 0.0, y: 0.0, z: 1.0),
    distance: 19.0,
    azimuth: 1.05,
    elevation: 0.42,
    fov: 60.0.degToRad,
  )



#[ Camera Queries ]#

func heading*(camera: Camera): Position =
  ## Point from the eye toward the target, the camera's forward direction formula.
  Position(
    x: cos(camera.elevation)*cos(camera.azimuth),
    y: cos(camera.elevation)*sin(camera.azimuth),
    z: sin(camera.elevation),
  )


func anglesFacing*(heading: Position): (float, float) =
  ## Invert the forward-direction formula, for a camera asked to face a direction.
  ##   Closed form, and the only inverse of `heading` anywhere: a capture run reorienting to
  ##   show a horizon object uses this rather than searching for angles that look right.
  let length = sqrt(heading.x*heading.x + heading.y*heading.y + heading.z*heading.z)
  if length <= 0.0: return (0.0, 0.0)
  let elevation = clamp(arcsin(heading.z/length), -ELEVATION_LIMIT, ELEVATION_LIMIT)
  (arctan2(heading.y, heading.x), elevation)


func eye*(camera: Camera): Position =
  ## Place the eye, at the orbit distance back along the heading.
  let forward = camera.heading
  Position(
    x: camera.target.x - forward.x*camera.distance,
    y: camera.target.y - forward.y*camera.distance,
    z: camera.target.z - forward.z*camera.distance,
  )


func nearClip*(camera: Camera): float {.inline.} = camera.distance / NEAR_CLIP_DIVISOR
  ## Derive the near plane from the orbit distance.

func farClip*(camera: Camera): float {.inline.} = camera.distance * FAR_CLIP_FACTOR
  ## Derive the far plane from the orbit distance.

func viewMatrix*(camera: Camera): Matrix4 {.inline.} =
  ## Build the view transform for this camera.
  lookAt(camera.eye, camera.target, WORLD_UP)

func projectionMatrix*(camera: Camera, aspect: float): Matrix4 {.inline.} =
  ## Build the projection transform for this camera at a viewport shape.
  perspective(camera.fov, aspect, camera.nearClip, camera.farClip)

func viewProjection*(camera: Camera, aspect: float): Matrix4 {.inline.} =
  ## Build the combined transform both renderers and the hit test read.
  camera.projectionMatrix(aspect) * camera.viewMatrix



#[ Camera Movement ]#

func clampFields*(camera: var Camera) =
  ## Hold every field inside its limit, after any move or edit.
  camera.distance = clamp(camera.distance, DISTANCE_MIN, DISTANCE_MAX)
  camera.elevation = clamp(camera.elevation, -ELEVATION_LIMIT, ELEVATION_LIMIT)
  camera.fov = clamp(camera.fov, 5.0.degToRad, 170.0.degToRad)


func orbit*(camera: var Camera, dx, dy: float) =
  ## Turn the camera about its target by a drag in pixels.
  camera.azimuth -= dx*ORBIT_RADIANS_PER_PIXEL
  camera.elevation += dy*ORBIT_RADIANS_PER_PIXEL
  camera.clampFields()


func pan*(camera: var Camera, dx, dy: float) =
  ## Slide the target across the view by a drag in pixels.
  let
    reach = camera.distance*PAN_FRACTION_PER_PIXEL
    forward = camera.heading
    # Derive the screen's own axes from the heading, so a pan tracks the pointer.
    side = Position(x: -sin(camera.azimuth), y: cos(camera.azimuth), z: 0.0)
    raised = Position(
      x: -sin(camera.elevation)*cos(camera.azimuth),
      y: -sin(camera.elevation)*sin(camera.azimuth),
      z: cos(camera.elevation),
    )
  discard forward
  camera.target = Position(
    x: camera.target.x - side.x*dx*reach + raised.x*dy*reach,
    y: camera.target.y - side.y*dx*reach + raised.y*dy*reach,
    z: camera.target.z - side.z*dx*reach + raised.z*dy*reach,
  )


func dolly*(camera: var Camera, notches: float) =
  ## Pull the camera in or out by wheel notches.
  camera.distance = camera.distance * pow(DOLLY_SCALE_PER_NOTCH, -notches)
  camera.clampFields()



#[ Aiming ]#

func aimAt*(p: Position): Aim =
  ## Aim at a point, leaving the camera's angles alone.
  Aim(target: some(p), azimuth: none(float), elevation: none(float))


func aimAlong*(heading: Position): Aim =
  ## Aim along a direction, leaving the camera's target alone.
  let (azimuth, elevation) = anglesFacing(heading)
  Aim(target: none(Position), azimuth: some(azimuth), elevation: some(elevation))


func `=~`(a, b: float): bool {.inline.} = abs(a - b) <= 1e-6
  ## Compare angles and coordinates approximately, for recognising an offer already held.


func matches(a, b: Aim): bool =
  ## Report whether two aims ask for the same thing.
  for (left, right) in [(a.azimuth, b.azimuth), (a.elevation, b.elevation)]:
    if left.isSome != right.isSome: return false
    if left.isSome and not (left.get =~ right.get): return false
  if a.target.isSome != b.target.isSome: return false
  if a.target.isSome:
    let (p, q) = (a.target.get, b.target.get)
    if not (p.x =~ q.x and p.y =~ q.y and p.z =~ q.z): return false
  true



#[ Tweening ]#

func ease*(t: float): float =
  ## Shape every eased motion in the tool: ease-out cubic.
  let inverted = 1.0 - clamp(t, 0.0, 1.0)
  1.0 - inverted*inverted*inverted


func offer*(tween: var Tween, camera: Camera, aim: Aim) =
  ## Offer the camera a goal, ignoring one it already holds.
  ##   Ignoring a repeat is what lets a caller aim every frame without the ease restarting
  ##   forever and never arriving. Retargeting reads its start off the live camera rather than
  ##   off the previous goal, so a goal that moves every frame — a coefficient being dragged —
  ##   is one continuous chase rather than a restarting jerk.
  if tween.goal.isSome and tween.goal.get.matches(aim): return
  tween.goal = some(aim)
  tween.is_delivered = false
  tween.elapsed_ms = 0.0
  tween.start = camera


func abandon*(tween: var Tween) =
  ## Give up writing to the camera, keeping the goal.
  ##   Called when the user moves the camera themselves. Keeping the goal is the whole point:
  ##   releasing it would let the standing offer look new next frame and take the camera
  ##   straight back.
  if tween.goal.isSome: tween.is_delivered = true


func release*(tween: var Tween) =
  ## Drop the goal entirely.
  ##   Belongs to the offer's own side, called when the aiming rule has nothing to aim at.
  ##   Clearing it is what lets picking the same object again aim at it afresh rather than be
  ##   recognised as already delivered.
  tween.goal = none(Aim)
  tween.is_delivered = false
  tween.elapsed_ms = 0.0


func isChasing*(tween: Tween): bool {.inline.} =
  ## Report whether the tween is still writing to the camera.
  tween.goal.isSome and not tween.is_delivered


func advance*(tween: var Tween, camera: var Camera, delta_ms: float) =
  ## Move the camera along its ease, once per frame.
  ##   On arrival the tween keeps its goal and marks itself delivered, which is what stops it
  ##   writing. Clearing the goal on arrival would make the standing offer look new next
  ##   frame and re-arm the ease from wherever the user just panned to — panning dies for as
  ##   long as anything stays selected, and returns on deselect.
  if not tween.isChasing: return
  tween.elapsed_ms += delta_ms
  let
    progress = clamp(tween.elapsed_ms / ANIMATION_DURATION_MS, 0.0, 1.0)
    eased = ease(progress)
    goal = tween.goal.get
  if goal.target.isSome:
    let (from_target, to_target) = (tween.start.target, goal.target.get)
    camera.target = Position(
      x: from_target.x + (to_target.x - from_target.x)*eased,
      y: from_target.y + (to_target.y - from_target.y)*eased,
      z: from_target.z + (to_target.z - from_target.z)*eased,
    )
  if goal.azimuth.isSome:
    # Turn the short way round, so a goal just past ±π does not unwind the long way.
    var delta = goal.azimuth.get - tween.start.azimuth
    while delta > PI: delta -= 2.0*PI
    while delta < -PI: delta += 2.0*PI
    camera.azimuth = tween.start.azimuth + delta*eased
  if goal.elevation.isSome:
    camera.elevation = tween.start.elevation +
      (goal.elevation.get - tween.start.elevation)*eased
  camera.clampFields()
  if progress >= 1.0: tween.is_delivered = true


func deliver*(tween: var Tween, camera: var Camera) =
  ## Land the camera on its goal at once, for a captured frame that must never show a pan.
  if tween.goal.isNone: return
  tween.advance(camera, ANIMATION_DURATION_MS)
