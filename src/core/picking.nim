## Decide what a pointer is over, in screen space, for both front-ends.
##
## **Picking priority is strict: point beats line beats plane**, regardless of pixel distance,
## once a shape's own radius is met. That priority is what makes generous radii safe — a wide
## point radius overlapping a line behind it still resolves to the point. The radii are sized
## against a real fingertip's contact patch at phone density.
##
## A line or plane at horizon is never pickable: neither is anchored anywhere a screen test
## could land, since both draw fixed to the eye. A horizon point keeps its star as an anchor.

{.experimental: "strictFuncs".}

import std/[math, options]

import ./[algebra, camera, mesh, scene, transform]



#[ Type Definitions ]#

type
  Viewport* = object
    ## Carry the drawing surface's size in pixels.
    width*, height*: float

  ScreenPoint* = object
    ## Carry a position on the drawing surface, origin at its top left.
    x*, y*: float

  Candidate = object
    ## Carry a hit under consideration, so priority can be applied over pixel distance.
    slot: Slot
    distance_px: float



#[ Picking Constants ]#

const
  PICK_RADIUS_POINT* = 34.0
    ## Accept a point within this many pixels.
  PICK_RADIUS_LINE* = 24.0
    ## Accept a line within this many pixels.
  CLIP_EPSILON* = 1e-6
    ## Hold projected geometry off the near plane, where the divide blows up.



#[ Projection ]#

func toScreen*(matrix: Matrix4, viewport: Viewport, p: Position): Option[ScreenPoint] =
  ## Project a world position to the drawing surface, or nothing where it sits behind the eye.
  ##   The by-hand near-plane test mirrors what the GPU does when drawing: the reach a line's
  ##   far end sits at can easily put an endpoint behind the eye, and dividing by that depth
  ##   would fold it back into view.
  let clip = matrix.project(p)
  if clip.w <= CLIP_EPSILON: return
  let
    ndc_x = clip.x/clip.w
    ndc_y = clip.y/clip.w
  some(ScreenPoint(
    x: (ndc_x*0.5 + 0.5)*viewport.width,
    y: (1.0 - (ndc_y*0.5 + 0.5))*viewport.height,
  ))


func clipToFront*(matrix: Matrix4, a, b: Position): Option[(Position, Position)] =
  ## Trim a segment to the part in front of the near plane.
  ##   Returns nothing where the whole segment sits behind the eye.
  let
    clip_a = matrix.project(a)
    clip_b = matrix.project(b)
    is_front_a = clip_a.w > CLIP_EPSILON
    is_front_b = clip_b.w > CLIP_EPSILON
  if is_front_a and is_front_b: return some((a, b))
  if not is_front_a and not is_front_b: return
  # Cut at the crossing, interpolating in world space by the depths themselves.
  let
    (front, back) = if is_front_a: (a, b) else: (b, a)
    (front_w, back_w) = if is_front_a: (clip_a.w, clip_b.w) else: (clip_b.w, clip_a.w)
    fraction = (front_w - CLIP_EPSILON)/(front_w - back_w)
    cut = Position(
      x: front.x + (back.x - front.x)*fraction,
      y: front.y + (back.y - front.y)*fraction,
      z: front.z + (back.z - front.z)*fraction,
    )
  some((front, cut))



#[ Screen Distance ]#

func distanceToSegment(p, a, b: ScreenPoint): float =
  ## Measure the pixel distance from a pointer to a drawn segment.
  let
    dx = b.x - a.x
    dy = b.y - a.y
    length_squared = dx*dx + dy*dy
  if length_squared <= 0.0:
    return sqrt((p.x - a.x)*(p.x - a.x) + (p.y - a.y)*(p.y - a.y))
  let
    t = clamp(((p.x - a.x)*dx + (p.y - a.y)*dy)/length_squared, 0.0, 1.0)
    nearest_x = a.x + dx*t
    nearest_y = a.y + dy*t
  sqrt((p.x - nearest_x)*(p.x - nearest_x) + (p.y - nearest_y)*(p.y - nearest_y))



#[ Shape Tests ]#

func hitsPoint(
  matrix: Matrix4, viewport: Viewport, anchor: Position, pointer: ScreenPoint
): Option[float] =
  ## Measure how near a pointer is to a drawn point, where it is near enough at all.
  let projected = toScreen(matrix, viewport, anchor)
  if projected.isNone: return
  let
    p = projected.get
    distance = sqrt((p.x - pointer.x)*(p.x - pointer.x) + (p.y - pointer.y)*(p.y - pointer.y))
  if distance > PICK_RADIUS_POINT: return
  some(distance)


func hitsLine(
  matrix: Matrix4,
  viewport: Viewport,
  geometry: Multivector,
  camera: Camera,
  pointer: ScreenPoint,
): Option[float] =
  ## Measure how near a pointer is to a drawn line, testing both of its halves.
  ##   Both halves are tested because which one a pointer lands on changes as the camera
  ##   orbits; testing one leaves the other unpickable.
  let
    support = ∩ geometry
    axis = ⊖ geometry
    anchor = support.position
  if anchor.isNone or axis.locus != Locus.Horizon: return
  let
    eye_point = pointAt(camera.eye)
    reach = camera.horizonRadius
  var nearest = none(float)
  for direction in [reach, -reach]:
    let far_end = translate(eye_point, axis, direction)
    if far_end.isNone: continue
    let trimmed = clipToFront(matrix, anchor.get, far_end.get)
    if trimmed.isNone: continue
    let
      (near_world, far_world) = trimmed.get
      near_screen = toScreen(matrix, viewport, near_world)
      far_screen = toScreen(matrix, viewport, far_world)
    if near_screen.isNone or far_screen.isNone: continue
    let distance = distanceToSegment(pointer, near_screen.get, far_screen.get)
    if nearest.isNone or distance < nearest.get: nearest = some(distance)
  if nearest.isNone or nearest.get > PICK_RADIUS_LINE: return
  nearest


func hitsPlane(
  matrix: Matrix4,
  viewport: Viewport,
  geometry: Multivector,
  centre: Position,
  pointer: ScreenPoint,
): Option[float] =
  ## Report whether a pointer sits inside a plane's drawn rim.
  ##   Area-based rather than distance-based: a plane is a filled disc, and its rim is where
  ##   it stops. The test walks the same rim positions the mesh draws, projected, so the
  ##   drawn shape and the picked shape cannot disagree.
  let spanning = geometry.tangents
  if spanning.isNone: return
  let
    (first, second) = spanning.get
    first_direction = directionAt(first)
    second_direction = directionAt(second)
    centre_point = pointAt(centre)
  var
    is_inside = false
    previous = none(ScreenPoint)
    initial = none(ScreenPoint)
  for step in 0 ..< DISC_SEGMENTS:
    let
      angle = TAU*step.float/DISC_SEGMENTS.float
      edge = translate(
        centre_point,
        cos(angle)*first_direction + sin(angle)*second_direction,
        PLANE_RADIUS,
      )
    if edge.isNone: return
    let projected = toScreen(matrix, viewport, edge.get)
    if projected.isNone: return  # Part of the rim sits behind the eye: refuse the test.
    if initial.isNone: initial = projected
    if previous.isSome:
      let (a, b) = (previous.get, projected.get)
      if (a.y > pointer.y) != (b.y > pointer.y):
        let crossing = a.x + (pointer.y - a.y)/(b.y - a.y)*(b.x - a.x)
        if pointer.x < crossing: is_inside = not is_inside
    previous = projected

  # Close the rim, so a pointer beyond the last drawn edge is still counted.
  if previous.isSome and initial.isSome:
    let (a, b) = (previous.get, initial.get)
    if (a.y > pointer.y) != (b.y > pointer.y):
      let crossing = a.x + (pointer.y - a.y)/(b.y - a.y)*(b.x - a.x)
      if pointer.x < crossing: is_inside = not is_inside
  if not is_inside: return
  some(0.0)



#[ Picking ]#

func pick*(
  scene: Scene,
  camera: Camera,
  viewport: Viewport,
  pointer: ScreenPoint,
): Option[Slot] =
  ## Decide which object a pointer is over, point before line before plane.
  let matrix = camera.viewProjection(viewport.width/viewport.height)
  var
    best_point = none(Candidate)
    best_line = none(Candidate)
    best_plane = none(Candidate)

  template consider(best: var Option[Candidate], slot: Slot, distance: Option[float]) =
    if distance.isSome and (best.isNone or distance.get < best.get.distance_px):
      best = some(Candidate(slot: slot, distance_px: distance.get))

  for slot in scene.items:
    if not scene.isVisible(slot): continue
    let geometry = scene.geometry(slot)
    case geometry.shape
    of Shape.None: discard
    of Shape.Point:
      let anchor =
        case geometry.locus
        of Locus.Finite: geometry.position
        of Locus.Horizon:
          let heading = geometry.direction
          if heading.isNone: none(Position)
          else: translate(pointAt(camera.eye), directionAt(heading.get),
            camera.horizonRadius)
      if anchor.isSome:
        consider(best_point, slot, hitsPoint(matrix, viewport, anchor.get, pointer))
    of Shape.Line:
      if geometry.locus != Locus.Finite: continue
      consider(best_line, slot, hitsLine(matrix, viewport, geometry, camera, pointer))
    of Shape.Plane:
      if geometry.locus != Locus.Finite: continue
      let centre = scene.drawAnchor(slot)
      if centre.isSome:
        consider(best_plane, slot, hitsPlane(matrix, viewport, geometry, centre.get, pointer))

  if best_point.isSome: return some(best_point.get.slot)
  if best_line.isSome: return some(best_line.get.slot)
  if best_plane.isSome: return some(best_plane.get.slot)
  none(Slot)
