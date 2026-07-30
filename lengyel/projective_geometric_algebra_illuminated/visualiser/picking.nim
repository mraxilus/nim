## Hit-test scene items against the cursor, so a mouse action knows which object it touched.
##
## Point and line are tested in screen space, by pixel distance: that answers where a pixel
## is, a rasterisation question, not an algebraic one, exactly as the camera's own clip
## volume is written out directly rather than derived. A line's own endpoints are computed
## the same way `mesh.addLine` draws them -- `radius_horizon` backward from support, the
## same radius forward from the eye instead -- so a hit always agrees with what is drawn.
##
## Plane is tested differently, through the algebra rather than around it: cursor's own
## sight ray is built as an RGA line (eye ∧ heading) and met with the plane directly,
## `ray ∨ plane`, giving the exact point struck. Screen-space quad-projection was tried first
## and discarded — a corner near the eye sends its projected position to infinity, and the
## point-in-polygon test on that blown-up quad can then accept a cursor nowhere near the
## plane at all. Meeting in 3D has no such singularity nearby: it fails cleanly (ray parallel
## to plane, or the hit behind the eye) instead of failing wrongly.
##
##   |------------|-------------------------------------------------------------------|
##   | Shape      | Tested against                                                    |
##   |------------|-------------------------------------------------------------------|
##   | Point      | Projected marker, by pixel distance.                              |
##   | Line       | Projected drawn segment, by distance to its nearest point.        |
##   | Plane      | Sight ray met with the plane, by whether that point falls inside  |
##   |            |   the drawn quad, and by distance from eye if it does.            |
##   |------------|-------------------------------------------------------------------|
##
## A point wins a tie over a line, and a line over a plane: the smaller target should not
## be swallowed by a larger one drawn behind or through it.

{.experimental: "strictFuncs".}

import std/[math, options]

import ../pga
import ./[camera, mesh, objects, scene]



#[ Picking Configuration ]#

const
  RADIUS_PICK_POINT* = 14.0
    ## Bound how far, in pixels, cursor may sit from a point's marker and still hit it.
  RADIUS_PICK_LINE* = 9.0
    ## Bound how far, in pixels, cursor may sit from a line's drawn segment and still hit it.



#[ Type Definitions ]#

type ScreenPosition* = object ## Hold projected position, in window pixels, y downward.
  x*, y*: float
  depth*: float ## View-space depth; positive and smaller is nearer the eye.



#[ Screen Projection ]#

func projectToScreen*(
  view_projection: Matrix4; width, height: int; position: Position
): ScreenPosition =
  ## Project world position through clip space onto window pixels.
  var clip: array[4, float]
  let coordinates = [position.x, position.y, position.z, 1.0]
  for row in 0 .. 3:
    for column in 0 .. 3:
      clip[row] += float(view_projection.at(row, column)) * coordinates[column]

  let (ndc_x, ndc_y) = (clip[0]/clip[3], clip[1]/clip[3])
  ScreenPosition(
    x: (ndc_x*0.5 + 0.5) * float(width),
    y: (1.0 - (ndc_y*0.5 + 0.5)) * float(height),
    depth: clip[3],
  )


func isInFront*(screen: ScreenPosition): bool = screen.depth > 1.0e-6
  ## Report whether projected position stands in front of eye, where perspective divide
  ## and every pixel distance measured from it are meaningful.



#[ Representative Point ]#

func anchorFor*(m: Multivector; scale: DrawExtent): Option[Position] =
  ## Resolve one point standing for `m`, for picking a point and for cursor feedback.
  ##   Point uses its own place, or its own star position at horizon where it has none,
  ##   matching exactly where `mesh.addPoint` draws it.
  ##   Line and plane use their support point, matching what mesh actually anchors on;
  ##   neither is pickable at horizon (see `pickNearest`'s own doc comment), so no
  ##   equivalent horizon anchor is needed for them here.
  ##   None where `m` carries no drawable geometry at all.
  let shape = shape(m)
  if shape.isNone: return
  case shape.get
  of Shape.Point:
    let place = position(m)
    if place.isSome: return place
    let heading = directionHorizon(m)
    if heading.isNone: return
    some(scale.eye + scale.radius_horizon*heading.get)
  of Shape.Line, Shape.Plane:
    positionAnchor(m)



#[ Segment Test ]#

func clipToEyeSide(
  a, b: Position; eye: Position; forward: Direction; distance_near: float
): Option[(Position, Position)] =
  ## Clip segment `a`-`b` to the half-space at least `distance_near` in front of `eye`
  ## -- the same near-side clip the GPU already performs when actually drawing the
  ## segment, done by hand here since a screen-space hit test needs to divide by each
  ## endpoint's own depth, which the far reach `mesh.addLine` now gives a line can put
  ## at or behind the eye from some camera angles even though the near half of the very
  ## same segment stays plainly on screen.
  ##   None where the whole segment lies behind `eye`.
  let
    depth_a = dot(a - eye, forward)
    depth_b = dot(b - eye, forward)
  if depth_a <= distance_near and depth_b <= distance_near: return
  if depth_a > distance_near and depth_b > distance_near: return some((a, b))
  let crossing = a + ((distance_near - depth_a) / (depth_b - depth_a))*(b - a)
  if depth_a > distance_near: some((a, crossing)) else: some((crossing, b))


func distanceToSegment(p, a, b: ScreenPosition): float =
  ## Measure pixel distance from `p` to nearest point of segment `a`-`b`.
  let
    (dx, dy) = (b.x - a.x, b.y - a.y)
    length_squared = dx*dx + dy*dy
  if length_squared <= 1.0e-9: return hypot(p.x - a.x, p.y - a.y)
  let t = clamp(((p.x - a.x)*dx + (p.y - a.y)*dy) / length_squared, 0.0, 1.0)
  hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))



#[ Sight Ray ]#

func castRay(
  camera: Camera; eye: Position; frame: FrameCamera; width, height: int; cursor: ScreenPosition
): Multivector =
  ## Build RGA line running from eye through cursor's own pixel, into the scene.
  ##   Undoes `initMatrixProjection`'s own construction: cursor becomes NDC again, scaled
  ##   by the same field-of-view tangent, and composed from camera's own right/up/forward.
  ##   Takes eye and frame precomputed, since a cursor position tests against every item
  ##   in the scene with the very same ray; recomputing it per item would repeat the same
  ##   two RGA joins and antiduals up to `ITEMS_MAX` times for one cursor position.
  let
    half_height = tan(0.5 * degToRad(camera.degrees_field_of_view))
    half_width = half_height * (float(width) / float(height))
    ndc_x = (cursor.x / float(width))*2.0 - 1.0
    ndc_y = 1.0 - (cursor.y / float(height))*2.0
    heading = (ndc_x*half_width)*frame.axis_right + (ndc_y*half_height)*frame.axis_up +
      frame.forward
  toMultivector(eye) ∧ toMultivector(heading)


func rayPlaneHit(
  ray: Multivector; eye: Position; forward: Direction;
  plane: Multivector; anchor: Position; axes: FramePlane; extent: float
): Option[float] =
  ## Meet cursor's sight ray with `plane`; report distance from eye where it lands inside
  ## the drawn disc, so a nearer plane can be preferred over a farther one behind it.
  ##   None where the ray misses the plane, the hit falls behind the eye, or it lands
  ##   outside the drawn disc.
  let hit = position(ray ∨ plane)
  if hit.isNone: return

  let distance = dot(hit.get - eye, forward)
  if distance <= 1.0e-6: return

  # Bound is circular, matching `mesh.addPlaneRing` exactly: a plane's own hit test
  #   should agree with what is drawn, not with a square the render no longer produces.
  let local = hit.get - anchor
  if dot(local, local) > extent*extent: return
  some(distance)



#[ Item Hit Testing ]#

func pickNearest*(
  scene: Scene; camera: Camera; view_projection: Matrix4; width, height: int;
  cursor: ScreenPosition;
): Option[int] =
  ## Find visible item nearest cursor, preferring points over lines over planes.
  ##   None where nothing visible falls within its shape's pick radius.
  ##   A line or plane at horizon is never pickable: neither is anchored anywhere a
  ##   screen-space or ray test could land on, since both are drawn fixed to the eye
  ##   rather than to a point in the scene (see `mesh.addLine`/`addPlane`'s own horizon
  ##   branches). Only a point at horizon -- a fixed star -- keeps a pickable anchor.
  ##   Exceeds the working 60-line default: the three shape branches below are
  ##   irreducibly different geometry (point/line/plane hit-testing), each already
  ##   minimal, and all three share the `eye`/`frame_camera`/`ray`/`scale` setup computed
  ##   once above rather than per-candidate -- extracting a branch into its own proc
  ##   would mean threading all four back in as parameters for no simplification.

  # Eye, camera frame and sight ray depend only on camera and cursor, not on which item is
  #   being tested, so each is built once here rather than once per plane candidate below.
  let
    eye = camera.eye
    frame_camera = camera.frame(eye)
    ray = castRay(camera, eye, frame_camera, width, height, cursor)
    scale = DrawExtent(eye: eye, radius_horizon: radiusHorizonFor(camera.distance_far))

  var
    slot_best = none(int)
    priority_best = high(int)
    distance_best = Inf

  template consider(priority: int; distance: float) =
    if priority < priority_best or (priority == priority_best and distance < distance_best):
      priority_best = priority
      distance_best = distance
      slot_best = some(slot)

  for slot, item in scene.pairs:
    if not item.isVisible: continue
    let geometry = item.geometry
    let shape = shape(geometry)
    if shape.isNone: continue

    case shape.get
    of Shape.Point:
      let anchor = anchorFor(geometry, scale)
      if anchor.isNone: continue
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if not screen.isInFront: continue
      let distance = hypot(cursor.x - screen.x, cursor.y - screen.y)
      if distance <= RADIUS_PICK_POINT: consider(0, distance)

    of Shape.Line:
      let (anchor, axis) = (positionAnchor(geometry), direction(geometry))
      if anchor.isNone or axis.isNone: continue
      let clipped = clipToEyeSide(
        anchor.get - scale.radius_horizon*axis.get, eye + scale.radius_horizon*axis.get,
        eye, frame_camera.forward, camera.distance_near,
      )
      if clipped.isNone: continue
      let (a, b) = clipped.get
      let
        tail = projectToScreen(view_projection, width, height, a)
        head = projectToScreen(view_projection, width, height, b)
      if not (tail.isInFront and head.isInFront): continue
      let distance = distanceToSegment(cursor, tail, head)
      if distance <= RADIUS_PICK_LINE: consider(1, distance)

    of Shape.Plane:
      let
        anchor =
          if item.anchorOverride.isSome: item.anchorOverride else: positionAnchor(geometry)
        axes = frame(geometry)
      if anchor.isNone or axes.isNone: continue
      let hit = rayPlaneHit(
        ray, eye, frame_camera.forward, geometry, anchor.get, axes.get, EXTENT_PLANE_F
      )
      if hit.isSome: consider(2, hit.get)

  slot_best
