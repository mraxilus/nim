## Build every vertex both renderers draw, into fixed storage the caller owns.
##
## Nothing here allocates: each buffer is a fixed-capacity array, asserted rather than grown,
## and each build clears and refills. The meshes rebuild against the current eye every frame,
## which is what keeps the line construction below exact while the camera orbits.

{.experimental: "strictFuncs".}

import std/[math, options]

import ./[algebra, camera, config, palette, scene]



#[ Type Definitions ]#

type
  Vertex* = object
    ## Carry one vertex of a mesh.
    position*: Position
    color*: Color

  Ring* = object
    ## Carry one billboarded ring, drawn in screen space at its anchor.
    anchor*: Position
    radius_px*: float
    alpha*: float

  Presentation* {.pure.} = enum
    ## Name how an item is drawn this frame.
    Normal, ## Full colour.
    Muted,  ## Background context: blended toward its own luminance, alpha dropped.
    Hidden, ## Not drawn at all.

  Mesh* = object
    ## Hold every primitive of one frame, in one bucket per kind.
    ##   Large enough that it lives at module scope in both front-ends and is cleared rather
    ##   than re-declared: there is no stack allocation for storage this size, and the
    ##   browser measured ~90 ms/frame re-declaring it against ~6 ms hoisted.
    points*: array[VERTEX_CAPACITY, Vertex]
    point_count*: int
    lines*: array[VERTEX_CAPACITY, Vertex]
    line_count*: int
    furniture*: array[VERTEX_CAPACITY, Vertex]
    furniture_count*: int
    triangles*: array[VERTEX_CAPACITY, Vertex]
    triangle_count*: int
    rings*: array[SELECTION_CAPACITY + 1, Ring]
    ring_count*: int



#[ Drawing Constants ]#

const
  POINT_SIZE_PX* = 9.0
    ## Draw a point this wide.
  RING_RADIUS_PX* = 16.0
    ## Draw a selection ring at this radius.
  RING_WIDTH_PX* = 2.0
    ## Draw a selection ring this thick.
  RING_HOVER_ALPHA* = 0.8
    ## Draw a hover ring at this share of a selection ring's opacity.
  LINE_WIDTH_FURNITURE* = 1.5
    ## Draw furniture this thick, so reference geometry recedes.
  LINE_WIDTH_OBJECT* = 2.5
    ## Draw scene objects this thick.
  PLANE_RADIUS* = 8.0
    ## Draw a plane's disc at this world radius.
    ##   Fixed rather than camera-distance scaled, which visibly resizes a plane as the
    ##   camera orbits. A rendering choice only: every construction path reads the full
    ##   untruncated multivector, so a meet lands correctly far outside this disc.
  PLANE_FILL_ALPHA* = 0.16
    ## Wash a plane's interior at this coverage.
  PLANE_NORMAL_FRACTION* = 0.25
    ## Draw a plane's normal shaft at this fraction of the disc, with no tip.
  DOME_ALPHA* = 0.22
    ## Wash the horizon plane's sky dome at this coverage.
  DISC_SEGMENTS* = 48
    ## Step a disc or great circle this many times around.
  DOME_MERIDIANS* = 24
    ## Step the dome this many times around.
  DOME_PARALLELS* = 12
    ## Step the dome this many times from pole to pole.
  HORIZON_RADIUS_FRACTION* = 0.45
    ## Place sky geometry this far out along the far clip plane.
    ##   Derived from the frustum rather than from the orbit distance, so a dolly never puts
    ##   the sky outside the view.
  GRID_CELL_BASE* = 2.0
    ## Size the finest grid cell, in world units.
  GRID_CELLS_MAX* = 24
    ## Cap how many cells cover the grid's reach before the cell size doubles.
  GRID_FADE_PIECES* = 8
    ## Cut each grid line into this many pieces, so its fade interpolates per vertex.
  GRID_FADE_FULL* = 0.03
    ## Hold a grid line at full alpha out to this fraction of the reach.
  GRID_FADE_ZERO* = 0.12
    ## Fade a grid line to nothing by this fraction of the reach.

# Assert object lines outweigh furniture lines, so reference geometry stays reference.
static:
  doAssert LINE_WIDTH_OBJECT > LINE_WIDTH_FURNITURE,
    "Scene objects must draw thicker than furniture, so furniture recedes."


func horizonRadius*(camera: Camera): float {.inline.} =
  ## Reach sky geometry sits at, derived from the far clip plane.
  camera.farClip*HORIZON_RADIUS_FRACTION


func furnitureReach*(camera: Camera): float {.inline.} =
  ## Reach the world axes extend to.
  ##   Derived from the far clip plane, not from the orbit distance, so furniture reads as
  ##   extending indefinitely however far the camera dollies.
  camera.farClip


func gridReach*(camera: Camera): float {.inline.} =
  ## Reach the ground grid extends to, which is where its fade has reached zero.
  ##   Drawing grid lines past their own fade wastes the vertex budget on nothing, and — worse
  ##   — a line cut into pieces that each span more than the fade band fades every piece out
  ##   at both ends, leaving no grid at all. The fade fractions below are still fractions of
  ##   the far clip plane, as stated; this is where the geometry stops.
  camera.farClip*GRID_FADE_ZERO



#[ Mesh Mutation ]#

func clear*(mesh: var Mesh) =
  ## Empty every bucket, keeping the storage.
  mesh.point_count = 0
  mesh.line_count = 0
  mesh.furniture_count = 0
  mesh.triangle_count = 0
  mesh.ring_count = 0


func addPoint*(mesh: var Mesh, p: Position, color: Color) =
  ## Append one drawn point.
  if mesh.point_count >= VERTEX_CAPACITY: return
  mesh.points[mesh.point_count] = Vertex(position: p, color: color)
  mesh.point_count += 1


func addSegment*(mesh: var Mesh, a, b: Position, color_a, color_b: Color) =
  ## Append one object line segment, coloured per end so a fade interpolates.
  if mesh.line_count + 2 > VERTEX_CAPACITY: return
  mesh.lines[mesh.line_count] = Vertex(position: a, color: color_a)
  mesh.lines[mesh.line_count + 1] = Vertex(position: b, color: color_b)
  mesh.line_count += 2


func addSegment*(mesh: var Mesh, a, b: Position, color: Color) {.inline.} =
  ## Append one object line segment.
  mesh.addSegment(a, b, color, color)


func addFurniture*(mesh: var Mesh, a, b: Position, color_a, color_b: Color) =
  ## Append one furniture segment, coloured per end.
  if mesh.furniture_count + 2 > VERTEX_CAPACITY: return
  mesh.furniture[mesh.furniture_count] = Vertex(position: a, color: color_a)
  mesh.furniture[mesh.furniture_count + 1] = Vertex(position: b, color: color_b)
  mesh.furniture_count += 2


func addTriangle*(mesh: var Mesh, a, b, c: Position, color: Color) =
  ## Append one translucent triangle.
  ##   Translucent triangles share one unsorted bucket drawn with depth writes off, so
  ##   whichever is appended last wins the blend. Callers insert any visible horizon dome
  ##   first, before every other object, so an ordinary plane's wash blends over it.
  if mesh.triangle_count + 3 > VERTEX_CAPACITY: return
  mesh.triangles[mesh.triangle_count] = Vertex(position: a, color: color)
  mesh.triangles[mesh.triangle_count + 1] = Vertex(position: b, color: color)
  mesh.triangles[mesh.triangle_count + 2] = Vertex(position: c, color: color)
  mesh.triangle_count += 3


func addRing*(mesh: var Mesh, anchor: Position, alpha: float) =
  ## Append one billboarded ring at an anchor.
  if mesh.ring_count >= mesh.rings.len: return
  mesh.rings[mesh.ring_count] = Ring(
    anchor: anchor, radius_px: RING_RADIUS_PX, alpha: alpha
  )
  mesh.ring_count += 1



#[ Object Geometry ]#

func spin(first, second: Multivector, angle: float): Multivector {.inline.} =
  ## Combine two spanning directions into the direction at an angle between them.
  cos(angle)*first + sin(angle)*second


func addFinitePoint(mesh: var Mesh, geometry: Multivector, color: Color) =
  ## Draw a finite point.
  let p = geometry.position
  if p.isNone: return
  mesh.addPoint(p.get, color)


func addFiniteLine(mesh: var Mesh, geometry: Multivector, color: Color, camera: Camera) =
  ## Draw a finite line as two segments meeting on the line at its support.
  ##   Each segment runs from the support out to one of the line's two vanishing points, at
  ##   `eye ± horizon radius × axis`. A vanishing point is a property of the eye, not of the
  ##   line: anchoring an end a fixed reach from the line's own support stops short of it by
  ##   roughly the eye-to-line separation over that reach, which measured ~6.7° of visible gap
  ##   for a line 40 units out. One segment cannot do it either — a segment running eye to eye
  ##   passes through the eye and projects to a point.
  ##   Each segment has one end on the true line and one off it, so both lie in the plane
  ##   through the eye containing the line; that plane projects to a single screen line, so
  ##   the pair draws exactly over the true line's projection however far the far ends sit.
  let
    support = ∩ geometry
    axis = ⊖ geometry
  let anchor = support.position
  if anchor.isNone: return
  if axis.locus != Locus.Horizon: return
  let
    eye_point = pointAt(camera.eye)
    reach = camera.horizonRadius
    forward_end = translate(eye_point, axis, reach)
    backward_end = translate(eye_point, axis, -reach)
  if forward_end.isNone or backward_end.isNone: return
  mesh.addSegment(anchor.get, forward_end.get, color)
  mesh.addSegment(anchor.get, backward_end.get, color)


func addFinitePlane(
  mesh: var Mesh, geometry: Multivector, color: Color, centre: Position
) =
  ## Draw a finite plane as a solid rim, a flat translucent fill and a bare normal shaft.
  ##   No crosshair, no ruled grid, no anchor marker: the rim already marks the boundary.
  let spanning = geometry.tangents
  if spanning.isNone: return
  let
    (first, second) = spanning.get
    first_direction = directionAt(first)
    second_direction = directionAt(second)
    centre_point = pointAt(centre)
    fill_color = color.withAlpha(PLANE_FILL_ALPHA)
  var previous = none(Position)
  for step in 0 .. DISC_SEGMENTS:
    let
      angle = TAU*step.float/DISC_SEGMENTS.float
      edge = translate(centre_point, spin(first_direction, second_direction, angle),
        PLANE_RADIUS)
    if edge.isNone: continue
    if previous.isSome:
      mesh.addSegment(previous.get, edge.get, color)
      mesh.addTriangle(centre, previous.get, edge.get, fill_color)
    previous = edge

  # Draw the normal as a bare shaft, so a plane's facing is readable without a tip to size.
  let normal = geometry.normal
  if normal.isNone: return
  let tip = translate(centre_point, directionAt(normal.get),
    PLANE_RADIUS*PLANE_NORMAL_FRACTION)
  if tip.isNone: return
  mesh.addSegment(centre, tip.get, Paint.Guide.color)


func addHorizonPoint(mesh: var Mesh, geometry: Multivector, color: Color, camera: Camera) =
  ## Draw a horizon point as a fixed star, anchored to the eye.
  let heading = geometry.direction
  if heading.isNone: return
  let star = translate(pointAt(camera.eye), directionAt(heading.get), camera.horizonRadius)
  if star.isNone: return
  mesh.addPoint(star.get, color)


func addHorizonLine(mesh: var Mesh, geometry: Multivector, color: Color, camera: Camera) =
  ## Draw a horizon line as a great circle around the eye.
  ##   A line at infinity keeps no direction, only the moment naming the plane of directions
  ##   it spans; that moment is the axis its circle turns about.
  let axis = geometry.normal
  if axis.isNone: return
  let
    eye_point = pointAt(camera.eye)
    axis_line = eye_point ∧ directionAt(axis.get)
    facing = eye_point.expandWeight(axis_line)  # Plane through the eye, normal to the axis.
    spanning = facing.tangents
  if spanning.isNone: return
  let
    (first, second) = spanning.get
    first_direction = directionAt(first)
    second_direction = directionAt(second)
    reach = camera.horizonRadius
  var previous = none(Position)
  for step in 0 .. DISC_SEGMENTS:
    let
      angle = TAU*step.float/DISC_SEGMENTS.float
      edge = translate(eye_point, spin(first_direction, second_direction, angle), reach)
    if edge.isNone: continue
    if previous.isSome: mesh.addSegment(previous.get, edge.get, color)
    previous = edge


func addHorizonPlane*(mesh: var Mesh, color: Color, camera: Camera) =
  ## Draw the horizon plane as a full sphere dome around the eye.
  ##   Full, not hemispherical: an orbit view sits elevated and tilted down, so cutting the
  ##   dome at the eye's horizontal removes sky the camera can see. Every horizon plane is the
  ##   same universal object and carries no orientation to render.
  let
    eye_point = pointAt(camera.eye)
    reach = camera.horizonRadius
    wash = color.withAlpha(DOME_ALPHA)
    east = directionAt(1.0, 0.0, 0.0)
    north = directionAt(0.0, 1.0, 0.0)
    up = directionAt(0.0, 0.0, 1.0)
  # Walk the sphere by parallels and meridians, each vertex a direction combined from the
  #   three axis directions and read back through the same position projection.
  for parallel in 0 ..< DOME_PARALLELS:
    for meridian in 0 ..< DOME_MERIDIANS:
      var corners: array[4, Option[Position]]
      for corner in 0 ..< 4:
        let
          parallel_step = parallel + (if corner in [2, 3]: 1 else: 0)
          meridian_step = meridian + (if corner in [1, 2]: 1 else: 0)
          inclination = PI*parallel_step.float/DOME_PARALLELS.float
          azimuth = TAU*meridian_step.float/DOME_MERIDIANS.float
          ring = spin(east, north, azimuth)
          heading = sin(inclination)*ring + cos(inclination)*up
        corners[corner] = translate(eye_point, heading, reach)
      if corners[0].isNone or corners[1].isNone or corners[2].isNone or corners[3].isNone:
        continue
      mesh.addTriangle(corners[0].get, corners[1].get, corners[2].get, wash)
      mesh.addTriangle(corners[0].get, corners[2].get, corners[3].get, wash)



#[ Object Dispatch ]#

func addObject*(
  mesh: var Mesh,
  geometry: Multivector,
  color: Color,
  camera: Camera,
  anchor_override: Option[Position] = none(Position),
) =
  ## Draw one object, whatever its shape and wherever it sits.
  ##   A multivector with no shape draws nothing, through this one branch and with no special
  ##   case: that is how an all-zero ghost degrades to "nothing to draw".
  case geometry.shape
  of Shape.None: discard
  of Shape.Point:
    case geometry.locus
    of Locus.Finite: mesh.addFinitePoint(geometry, color)
    of Locus.Horizon: mesh.addHorizonPoint(geometry, color, camera)
  of Shape.Line:
    case geometry.locus
    of Locus.Finite: mesh.addFiniteLine(geometry, color, camera)
    of Locus.Horizon: mesh.addHorizonLine(geometry, color, camera)
  of Shape.Plane:
    case geometry.locus
    of Locus.Finite:
      let centre =
        if anchor_override.isSome: anchor_override
        else: (∩ geometry).position
      if centre.isSome: mesh.addFinitePlane(geometry, color, centre.get)
    of Locus.Horizon: mesh.addHorizonPlane(color, camera)



#[ Furniture ]#

func gridCell*(reach: float): float =
  ## Size the grid's cell for a reach, doubling until few enough cells cover it.
  ##   Doubling rather than dividing evenly, so a coarser grid's lines fall exactly on a
  ##   subset of the finer one's and the change reads as alternate lines dropping out rather
  ##   than the grid sliding underfoot.
  result = GRID_CELL_BASE
  while reach/result > GRID_CELLS_MAX.float:
    result *= 2.0


func addFurnitureGrid*(mesh: var Mesh, camera: Camera) =
  ## Draw the ground reference grid, fading out with distance.
  let
    reach = camera.gridReach
    cell = gridCell(reach)
    full = camera.farClip*GRID_FADE_FULL
    zero = camera.farClip*GRID_FADE_ZERO
    base = Paint.Grid.color
    lines = int(reach/cell)

  # Fade per vertex rather than per piece, so the interpolation stays smooth.
  func fade(distance: float): Color =
    let alpha =
      if distance <= full: 1.0
      elif distance >= zero: 0.0
      else: 1.0 - (distance - full)/(zero - full)
    base.withAlpha(alpha)

  for index in -lines .. lines:
    let offset = index.float*cell
    # Skip the two lines that would coincide with the world axes, avoiding depth fighting.
    if abs(offset) < cell*0.5: continue
    for piece in 0 ..< GRID_FADE_PIECES:
      let
        span = 2.0*reach/GRID_FADE_PIECES.float
        near_edge = -reach + span*piece.float
        far_edge = near_edge + span
      for is_along_x in [true, false]:
        let
          a =
            if is_along_x: Position(x: near_edge, y: offset, z: 0.0)
            else: Position(x: offset, y: near_edge, z: 0.0)
          b =
            if is_along_x: Position(x: far_edge, y: offset, z: 0.0)
            else: Position(x: offset, y: far_edge, z: 0.0)
          distance_a = sqrt(a.x*a.x + a.y*a.y)
          distance_b = sqrt(b.x*b.x + b.y*b.y)
        mesh.addFurniture(a, b, fade(distance_a), fade(distance_b))


func addFurnitureAxes*(mesh: var Mesh, camera: Camera) =
  ## Draw the three world axes, in the standard convention: x red, y green, z blue.
  let reach = camera.furnitureReach
  for (paint, direction) in [
    (Paint.AxisX, Position(x: 1.0, y: 0.0, z: 0.0)),
    (Paint.AxisY, Position(x: 0.0, y: 1.0, z: 0.0)),
    (Paint.AxisZ, Position(x: 0.0, y: 0.0, z: 1.0)),
  ]:
    let
      color = paint.color
      near_end = Position(
        x: -direction.x*reach, y: -direction.y*reach, z: -direction.z*reach
      )
      far_end = Position(x: direction.x*reach, y: direction.y*reach, z: direction.z*reach)
    mesh.addFurniture(near_end, far_end, color, color)
