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
import ./[boundary, tessellate]



#[ Camera Configuration ]#

const
  UP_WORLD* = Direction(x: 0.0, y: 0.0, z: 1.0)
    ## Fix world's up direction, which azimuth turns about and elevation rises from.
  ELEVATION_LIMIT* = 0.5*PI - 0.02
    ## Bound elevation short of pole, where sight axis would run along `UP_WORLD`.
  DISTANCE_LIMIT_NEAR* = 0.05
    ## Bound how close eye may orbit to target, through `distanceHeld`.
    ##   **The only bound left on where the camera may stand.** It is not a matter of
    ##   taste: at an orbit distance of zero the eye coincides with its target, the sight
    ##   axis joining them is undefined, and every direction `frame` derives from it
    ##   collapses. The far end had a limit of 500 for no comparable reason -- it was a
    ##   round number -- and a reader who dollied out to look at something a kilometre
    ##   across simply stopped moving, which is the camera reading as bounded to a region.
    ##   Nothing downstream needs a ceiling: the clip planes are both fractions of the
    ##   orbit distance (`FACTOR_CLIP_NEAR`, `FACTOR_CLIP_FAR`), so the frustum keeps its
    ##   shape at any distance, and the ground grid bounds its own line count
    ##   (`tessellate.CELLS_GRID_HALF_MAX`) rather than leaning on this. What does degrade, far
    ##   out, is `tessellate.Vertex`'s float32 storage: past roughly a million units a
    ##   coordinate carries less than a tenth of a unit of precision, and furniture that
    ##   far out will visibly quantise. That is a reason to state the limit, not to
    ##   impose one short of it.
  FACTOR_CLIP_FAR* = 20.0
    ## Set the far clip plane this many times the orbit distance out. Scaled rather than
    ## fixed so everything meant to read as "at the horizon" -- `tessellate.radiusHorizonFor`,
    ## `tessellate.extentFurnitureFor`, and the far end of every drawn line -- stays past what
    ## the frame can show at any orbit distance. A fixed plane cannot: the view's own
    ## extent grows with distance while the plane does not, so dollying out eventually
    ## brings a line's own far end inside the frame, where it reads as stopping in
    ## mid-air. Worse, a plane fixed at any particular distance clips the target itself
    ## away once the eye orbits past it, and there is no longer a ceiling on how far out
    ## it may orbit.
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
  ## How fast a **held key** moves the camera, per second of holding. Shared by both
  ## front-ends, unlike the per-pixel drag rates, which differ for a real reason:
  ## `visualiser.SPEED_ORBIT` is radians per pixel dragged and `glue.js` works in fractions
  ## of canvas width, so those two cannot be one number. A held key has no pixels in it, so
  ## these can be, and are.
  ##   **Per second, not per press.** These replaced a set of per-press steps that leaned on
  ## the operating system's own auto-repeat to move any distance: movement began only after
  ## the repeat delay and then arrived in stutters, which is not what a reader who has held
  ## W in any other program expects. `interaction.driveHeld` applies them once a frame,
  ## scaled by the frame's own elapsed time, so how far a hold travels depends on how long
  ## it was held and not on how fast the machine draws.
  ##   Sized so a reader crosses the useful range in a second or two of holding rather than
  ## in ten -- a keyboard route nobody can be bothered to hold is a keyboard route in name
  ## only -- while still being controllable in short taps.
  TURN_SECOND* = 1.4 ## Azimuth a held arrow turns through per second, in radians.
  RISE_SECOND* = 1.1 ## Elevation a held arrow rises through per second, in radians.
  SLIDE_SECOND* = 1.2 ## Ground distance a held key slides per second, as a fraction of
    ## orbit distance -- so a reader who has zoomed in to inspect one object crosses it at
    ## the same apparent speed as one looking at the whole scene.
  FACTOR_DOLLY_SECOND* = 4.0 ## Orbit distance a held key scales by per second, dollying
    ## out; its reciprocal dollies in, so a second each way returns exactly where it
    ## started. **Compounded as a power of the elapsed seconds**, never multiplied per
    ## frame: a scale applied once per frame would move a 144 Hz reader more than twice as
    ## far as a 60 Hz one for the same hold.
  FACTOR_HASTE* = 4.0 ## Multiply every rate above by this while shift is held.
    ## Shift means *faster* on every movement key rather than meaning something different
    ## on each -- it used to turn an arrow's orbit into a pan -- which is what Blender,
    ## Unity, Unreal and Godot all do with it.



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

func distanceHeld*(distance: float): float = max(distance, DISTANCE_LIMIT_NEAR)
  ## Hold an orbit distance off the one value it may not take; see `DISTANCE_LIMIT_NEAR`.
  ##   Every path that writes a distance goes through here -- construction, the dolly, both
  ##   front-ends' numeric fields, and the fitted distance framing solves -- so the floor is
  ##   stated once. It replaced a `clamp` written out at each of those sites, which is
  ##   exactly the shape a limit takes when one site is later missed.


func initCamera*(target: Position; distance, azimuth, elevation: float): Camera =
  ## Construct camera orbiting `target` at given separation and angles.
  Camera(
    target: target,
    distance: distanceHeld(distance),
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
  ##   The angles are parametrization -- trig scalars are ground field -- and the *point*
  ##   they place is assembled through the algebra: the target plus one spherical offset
  ##   direction, as a multivector sum read back at the end. Held equal to the spherical
  ##   closed form by its own suite case.
  let
    radius = camera.distance * cos(camera.elevation)
    offset = toMultivector(Direction(
      x: radius * cos(camera.azimuth),
      y: radius * sin(camera.azimuth),
      z: camera.distance * sin(camera.elevation),
    ))
    placed = position(add(toMultivector(camera.target), offset))
  # A unit-weight point plus a weightless direction is a unit-weight point; the read
  #   cannot refuse, and the fallback target states that rather than hiding an Option.
  if placed.isSome: placed.get else: camera.target


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
  ## Scale separation of eye from target, holding it off the near bound.
  camera.distance = distanceHeld(camera.distance * factor)


proc dollyToward*(camera: var Camera; factor: float; anchor: Position) =
  ## Scale the separation of eye from target by `factor`, moving the eye **along its own
  ## line to `anchor`** rather than straight in, so whatever stands at that point keeps the
  ## pixel it was already on.
  ##   How a map zooms, and a strategy game: the wheel takes the reader toward what they
  ## are pointing at rather than toward the middle of the frame, which is the difference
  ## between aiming once and dollying-then-panning-then-dollying again.
  ##   **Why the anchor keeps its pixel**: the angles do not change, so the sight direction
  ## is fixed, and the eye stays on the line joining it to `anchor`. That line is therefore
  ## the same line afterwards, and a point on the view ray through a pixel is still on it.
  ##   The scale actually applied is read back from `distanceHeld` rather than assumed, so
  ## that a zoom stopped by the near floor moves the eye by exactly as much as the distance
  ## it was allowed -- otherwise the two disagree and the placement no longer describes
  ## where the eye is.
  let
    eye_point = toMultivector(camera.eye)
    target_point = toMultivector(camera.target)
    anchor_point = toMultivector(anchor)
    distance_settled = distanceHeld(camera.distance*factor)
    scale = distance_settled/camera.distance
    # The new eye is the anchor plus the old offset scaled; the new target is that eye
    #   walked back along the target-to-eye direction the placement's own angles fix --
    #   one multivector expression, read back at the end. Every difference of unit-weight
    #   points is a direction, so the sum stays a unit-weight point throughout.
    settled = position(subtract(
      add(anchor_point, wedge(scale, subtract(eye_point, anchor_point))),
      wedge(distance_settled/camera.distance, subtract(eye_point, target_point)),
    ))
  if settled.isSome: camera.target = settled.get
  camera.distance = distance_settled


proc pan*(camera: var Camera; across, up: float) =
  ## Slide target within plane facing eye, so whole view shifts with it.
  ##   The slide is a multivector sum along the frame's own two axes.
  let
    axes = camera.frame(camera.eye)
    slid = position(add(toMultivector(camera.target), add(
      wedge(across * camera.distance, toMultivector(axes.axis_right)),
      wedge(up * camera.distance, toMultivector(axes.axis_up)),
    )))
  if slid.isSome: camera.target = slid.get


func headingGround*(camera: Camera): Direction =
  ## Read the way the camera faces, flattened onto the ground: the direction a reader
  ## means by "forward" when they are looking at a scene standing on the ground plane.
  ##   Solved from azimuth rather than by flattening `frame.forward` and normalising, which
  ##   is the same direction everywhere it is defined and unstable where it matters: at the
  ##   elevation limit the sight direction is within 0.02 radians of `UP_WORLD`, so its
  ##   horizontal part is a rounding error being scaled up to unit length. `eye`'s own
  ##   formula puts the eye at `target + radius*(cos azimuth, sin azimuth, ...)`, so the
  ##   way back to the target is the negation of that, and elevation drops out of it.
  Direction(x: -cos(camera.azimuth), y: -sin(camera.azimuth), z: 0.0)


proc slideGround*(camera: var Camera; ahead, across, rise: float) =
  ## Slide target across the world -- forward along `headingGround`, sideways along the
  ## camera's own right, and up along world up -- leaving the eye's placement about it
  ## alone, so the whole view travels without turning.
  ##   The **map** reading of a movement key rather than the *fly* one: forward keeps the
  ##   camera's height whatever it is looking at, so holding W skims the ground instead of
  ##   diving into it. That is what Supreme Commander and Google Maps do, and it is the
  ##   reading that goes with a zoom aimed at the cursor.
  ##   `across` reuses the frame's own `axis_right`, which is already horizontal -- it is
  ##   the join of the sight line and world up, dualised -- rather than deriving a second
  ##   side direction here that could disagree with the one mouse pan uses in sign.
  ##   All three are fractions of orbit distance, exactly as `pan`'s arguments are, so a
  ##   reader zoomed in on one object travels it at the same apparent speed as one looking
  ##   at the whole scene.
  let
    axes = camera.frame(camera.eye)
    slid = position(add(toMultivector(camera.target), add(
      add(
        wedge(ahead * camera.distance, toMultivector(camera.headingGround)),
        wedge(across * camera.distance, toMultivector(axes.axis_right)),
      ),
      wedge(rise * camera.distance, toMultivector(UP_WORLD)),
    )))
  if slid.isSome: camera.target = slid.get



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

  # Pin view's +y to world up, as antidual fixes axis only up to sign. The alignment is
  #   the library's own inner product of the two directions, read at its scalar.
  let orientation =
    if dot(toMultivector(axis_up.get), toMultivector(UP_WORLD))[Basis.scalar] < 0: -1.0
    else: 1.0
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
  ##   them. It lives here rather than in `tessellate`, where `DrawExtent` is declared, because
  ##   it reads a `Camera` and `camera` imports `tessellate` rather than the other way round.
  ##   `height_pixels` is the framebuffer's, not the window's: a ribbon's width is
  ##   measured in the pixels actually drawn.
  let eye = camera.eye
  # `algebraFilled` derives the four multivector twins from the plain fields -- the one
  #   derivation point, shared with every hand-built extent.
  algebraFilled(DrawExtent(
    scale: DrawScale(
      extent_furniture: extentFurnitureFor(camera.distanceFar),
      eye: eye,
      radius_horizon: radiusHorizonFor(camera.distanceFar),
      forward: camera.frame(eye).forward,
      tangent_half_view: tan(0.5*degToRad(camera.degrees_field_of_view)),
      height_pixels: height_pixels,
      depth_near: camera.distanceNear,
    ),
  ))


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
    is_bound_by_fitted*: bool ## Whether `sphere` is over the picked objects that have to
      ## **fit** alone -- points and finite planes.
      ## A point and a finite plane are both drawn at a size the camera does not set, so
      ## each has to fit inside the centred box; a line is drawn out to the horizon and has
      ## only to cross it. So whatever has to fit is what the camera centres and sizes
      ## itself on, and the rest is left to the test -- otherwise a line whose support
      ## happens to stand a hundred units away would drag the view off the point beside it
      ## and force a pull-back for nothing. Where nothing has to fit -- a selection of
      ## lines alone -- the sphere falls back to their own support points, so the camera
      ## still has somewhere to look.
    heading*: Option[Direction] ## Direction of the horizon objects to face, or none.
      ## Merged where several were asked for: no single direction faces two stars on
      ## opposite sides of the sky, and the sum of their unit directions is the nearest
      ## thing to one that does.
    centroid_sum*: Option[Multivector] ## Middle of the same finite objects `sphere` is over,
      ## **carried as the sum the algebra makes it out of** rather than as a place. Adding
      ## unit-weight points adds their weights, so this sum's own weight is how many places
      ## it is the middle of, and `centroid` below reads the mean straight back out of it --
      ## the division that reads a point out *is* the averaging, and nothing here does any.
      ## Rebuilt from nothing on every `aimFor`, so it never accumulates across frames: its
      ## weight reaches the number of watched objects and stops. That restart is what makes
      ## the aim compare equal to itself frame to frame, which is this record's whole worth.
      ## None where there are no finite objects at all.
      ## **What the orbit turns about once a selection stands**: the sphere is a bound and
      ## its centre is wherever holding everything happened to put it, while this is the
      ## middle of what was actually picked, which is the point a reader means when they
      ## pick things and turn to look at them.
      ##   Over the same objects as `sphere` rather than over everything picked, and for
      ## the same reason `is_bound_by_fitted` gives: a line whose support stands a hundred
      ## units away would drag the centre off the point beside it, and dragging the *target*
      ## there is worse than dragging a bound there.

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


func centroid*(aim: CameraAim): Option[Position] =
  ## Read the middle of what was picked, as a place to point a camera at.
  ##   The sum's own weight is the count, so the read-out's division is the averaging; see
  ##   `centroid_sum`. None where nothing finite was picked -- never for a sum of finite
  ##   points, which cannot lose the weight it accumulated.
  if aim.centroid_sum.isNone: return
  position(aim.centroid_sum.get)


func `==`*(a, b: CameraAim): bool =
  ## Compare two aims. Written out rather than left to Nim so the comparison is stated
  ## where the reason for it is.
  ##   Exact comparison, not approximate: this answers "is this the same request I was
  ##   already given", so a caller offering the same selection every frame does not restart
  ##   its ease. A selection that genuinely moved by a hair should restart it.
  if a.sphere.isSome != b.sphere.isSome: return false
  if a.sphere.isSome and not (a.sphere.get == b.sphere.get): return false
  if a.is_bound_by_fitted != b.is_bound_by_fitted: return false
  if a.centroid_sum.isSome != b.centroid_sum.isSome: return false
  # The sum's four coefficients, not the place it reads out to: the weight is the count, so
  #   comparing the sum is exactly the old test of "same middle *and* same number of things
  #   it is the middle of" in one field instead of two. A sum of points is grade 1, so these
  #   four slots are the whole of it.
  if a.centroid_sum.isSome:
    let (m, n) = (a.centroid_sum.get, b.centroid_sum.get)
    for slot in [Basis.E1, Basis.E2, Basis.E3, Basis.E4]:
      if m[slot] != n[slot]: return false
  if a.heading.isSome != b.heading.isSome: return false
  if a.heading.isNone: return true
  let (d, e) = (a.heading.get, b.heading.get)
  d.x == e.x and d.y == e.y and d.z == e.z


func widened*(bound: SphereWorld; place: Position; reach: float): SphereWorld =
  ## Grow a bound just enough to contain one more ball -- a point where `reach` is zero, a
  ## plane's whole drawn disc where it is `tessellate.EXTENT_PLANE_F`.
  ##   Incremental rather than a fit over the whole set at once, so a caller folding a
  ##   selection needs no array to fold over and allocates nothing. The result depends on
  ##   the order objects arrive in and can be a little wider than the tightest sphere over
  ##   the same set; it is always a true bound, which is all the framing needs.
  let
    centre_point = toMultivector(bound.centre)
    place_point = toMultivector(place)
    away = distanceBetween(centre_point, place_point)
  if away + reach <= bound.radius: return bound
  # The new ball swallowing the old one is its own case: the arithmetic below would slide
  #   the centre past `place`, and there is no direction to slide along at all where the
  #   two are concentric.
  if away + bound.radius <= reach: return SphereWorld(centre: place, radius: reach)
  let
    radius = 0.5*(away + bound.radius + reach)
    # Slide the centre toward the new ball by exactly what the far side gives up, so the
    #   old sphere stays enclosed rather than being trimmed on the way.
    slid = position(add(centre_point, wedge(
      (radius - bound.radius)/away, subtract(place_point, centre_point)
    )))
  SphereWorld(
    centre: (if slid.isSome: slid.get else: place), radius: radius
  )


func aimIncluding*(
  aim: Option[CameraAim]; m: Multivector; scale: DrawExtent;
  anchor_override: Option[Position] = none(Position)
): Option[CameraAim] =
  ## Fold one more object into an aim, or start one where there was none.
  ##   Unchanged by geometry that draws nothing, and by a plane at horizon, which fills the
  ##   sky and is in view from every camera there is.
  ##   A point at horizon is a fixed star, faced along its own direction. A line at horizon
  ##   is a whole great circle, so no single direction faces it; the first axis spanning
  ##   perpendicular to its normal is picked, which puts some of that circle in view.
  ##   Everything finite widens the sphere about `anchorFor`'s own representative point,
  ##   and a finite plane widens it by the whole disc drawn round that point rather than by
  ##   the point alone, so the camera frames exactly what a reader can see -- except that
  ##   the first object that has to *fit* throws away whatever lines had contributed, and
  ##   they contribute nothing thereafter; see `CameraAim.is_bound_by_fitted`. Which
  ##   objects contribute does not depend on the order they arrive in.
  ##   `anchor_override` centres a plane's disc there instead of on its own support, read
  ##   exactly as `tessellate.addPlane` reads it, so the sphere is built round the disc actually
  ##   drawn; ignored for every other shape, as it is there.
  ##   Horizon objects deliberately widen nothing: `anchorFor` places a star at
  ##   `scale.eye`, and a goal built from where the camera stands would stop comparing
  ##   equal frame to frame. **That applies twice over to the centroid**, which the orbit
  ##   turns about: a middle that moved with the eye would re-aim the camera every frame,
  ##   which is the standing offer's one forbidden behaviour.
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
      # Two headings merged as the sum of their horizon points, read back through the
      #   sanctioned horizon reader -- which also refuses the cancelling pair for us.
      else: directionHorizon(add(
        toMultivector(grown.heading.get), toMultivector(heading.get)
      ))
    # Two headings that cancel outright leave the first standing: they face opposite ways
    #   and neither turn shows both, so turning to the one already asked for beats turning
    #   to whatever a zero-length sum happens to normalise into.
    grown.heading = if merged.isSome: merged else: grown.heading
    return some(grown)

  let is_plane = shape_m.get == Shape.Plane
  var anchor = anchorFor(m, scale)
  if is_plane and anchor_override.isSome: anchor = anchor_override
  if anchor.isNone: return aim
  let
    # A plane is drawn as a disc of this radius about its anchor, at a size no camera
    #   changes, so what the camera has to fit is the whole ball -- not the anchor alone,
    #   which would leave the disc it stands at the middle of hanging off every side.
    reach = if is_plane: EXTENT_PLANE_F else: 0.0
    does_fit = shape_m.get in {Shape.Point, Shape.Plane}
  if grown.is_bound_by_fitted and not does_fit: return some(grown)
  # The first object that has to fit starts the bound afresh, discarding the lines that
  #   only had to cross.
  if does_fit and not grown.is_bound_by_fitted:
    return some(CameraAim(
      sphere: some(SphereWorld(centre: anchor.get, radius: reach)),
      is_bound_by_fitted: true, heading: grown.heading,
      # The middle starts afresh with the bound: whatever the lines contributed is being
      #   discarded here, and a centre still holding them would sit off everything left.
      centroid_sum: some(toMultivector(anchor.get)),
    ))
  grown.sphere =
    if grown.sphere.isNone: some(SphereWorld(centre: anchor.get, radius: reach))
    else: some(grown.sphere.get.widened(anchor.get, reach))
  # The middle of the very same objects, folded through the algebra's own reading of one:
  #   see `objects.centroidFolded`. A plane folds in by its disc's centre, not by its whole
  #   ball -- a disc's middle *is* where it stands, and the ball is only what has to fit.
  #   Nothing is read out or scaled here: the sum carries its own weight, and the one
  #   division that turns it back into a place happens in `centroid`, once, at the end.
  grown.centroid_sum =
    if grown.centroid_sum.isNone: some(toMultivector(anchor.get))
    else: some(centroidFolded(grown.centroid_sum.get, toMultivector(anchor.get)))
  some(grown)


func aimFor*(
  m: Multivector; scale: DrawExtent; anchor_override: Option[Position] = none(Position)
): Option[CameraAim] =
  ## Resolve what a camera has been asked to show for one object alone, or none where it
  ## draws nothing. The one-object case of `aimIncluding`, for callers that have one.
  aimIncluding(none(CameraAim), m, scale, anchor_override)


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
  ##   Held off the near bound exactly as the user's own dolly is, and unbounded above it:
  ##   a selection is framed by pulling back however far it takes, since nothing about the
  ##   frustum or the furniture stops working at a distance.
  ##   Solves the **centred box**, which is what a point is held to and stricter than what a
  ##   plane's rim is (`picking.isPlaneShownCentrally` holds that to the frame). That keeps
  ##   this a valid *upper bracket* for `framing.placementFor`'s bisection, which is all it
  ##   is used as -- never as the answer.
  let sine = sin(halfAngleCentred(camera, width, height, inset))
  distanceHeld(radius/max(sine, 1.0e-6))


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
  let stepped = position(add(toMultivector(from_placement.target), wedge(
    progress, subtract(
      toMultivector(to_placement.target), toMultivector(from_placement.target)
    )
  )))
  CameraPlacement(
    target: (if stepped.isSome: stepped.get else: to_placement.target),
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
  ##   the project keeps its easing curve; callers hand it `tessellate.easeOutCubic`, which is
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
