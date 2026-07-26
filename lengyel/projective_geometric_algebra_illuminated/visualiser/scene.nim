## Draw RGA objects of scene through camera onto canvas.
##
## Scene owns fixed-capacity list of items, so no allocation happens after setup.
##   Item pairs multivector with presentation; nothing else is stored about it.
##   Everything drawn is recomputed from multivector at draw time, never cached.
##
## Unbounded objects are drawn about their support point, i.e. their point nearest origin:
##   Line becomes span of `EXTENT_WORLD` either side of support, along its attitude.
##   Plane becomes grid patch of same extent, spanned by orthonormal frame inside it.
##   Support point is what algebra actually computed, so it is marked in both cases.
##
## Painting proceeds by descending grade, i.e. planes, then lines, then points.
##   Approximates depth sorting well enough for prototype, since planes are washes.
##   Cost is that near plane never occludes far line; nothing is sorted by depth.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./[camera, canvas, objects]



#[ Scene Configuration ]#

# Allow caller to resize drawn extent and scene capacity without editing source.
#   E.g. `--define:visualiser.extent_world=20 --define:visualiser.items_max=64`.
const
  EXTENT_WORLD* {.define: "visualiser.extent_world".} = 8
  ITEMS_MAX* {.define: "visualiser.items_max".} = 32

static:
  doAssert EXTENT_WORLD > 0, &"Drawn extent must be positive; got `{EXTENT_WORLD}`."
  doAssert ITEMS_MAX > 0, &"Scene capacity must be positive; got `{ITEMS_MAX}`."

const
  SAMPLES_AXIS* = 33
    ## Set vertex count of drawn span of unbounded object.
    ##   Straight span needs only two vertices, but sampling places break near image plane
    ##   close to where clipping would put it, without computing intersection.
  CELLS_PLANE* = 8
    ## Set grid line count either side of support point, when drawing plane.
  ORIGIN_WORLD* = Position(x: 0, y: 0, z: 0)
    ## Set world origin, which unbounded objects through it are drawn about.



#[ Type Definitions ]#

type
  Placement* {.pure.} = enum ## Report what became of item once drawn.
    Finite, ## Object had finite extent and was drawn.
    Horizon, ## Object lay wholly at horizon; only its direction could be drawn.
    Hidden, ## Object lay outside what camera can see.

  Item* = object ## Hold one RGA object together with its presentation.
    geometry*: Multivector ## Object being visualised.
    label*: string ## Display text; drawn verbatim, never inspected.
    ink*: Ink ## Palette slot object is drawn with.

  Scene* = object ## Hold fixed-capacity list of items to draw.
    entries: array[ITEMS_MAX, Item]
    count_entries: int



#[ Scene Construction ]#

proc addItem*(scene: var Scene; geometry: Multivector; label: string; ink: Ink) =
  ## Append object to scene together with its presentation.
  doAssert scene.count_entries < ITEMS_MAX,
    &"Scene holds at most {ITEMS_MAX} items; raise `--define:visualiser.items_max`."
  doAssert shape(geometry).isSome,
    &"Item `{label}` must be point, line or plane; got mixed or trivial grade `{geometry}`."
  scene.entries[scene.count_entries] = Item(geometry: geometry, label: label, ink: ink)
  inc scene.count_entries


func len*(scene: Scene): int = scene.count_entries
  ## Count items held by scene.


iterator items*(scene: Scene): lent Item =
  ## Yield each item in order it was added.
  for i in 0 ..< scene.count_entries:
    yield scene.entries[i]



#[ World Space Drawing ]#

func sampleAxis(anchor: Position, axis: Direction): array[SAMPLES_AXIS, Position] =
  ## Sample straight span of world centred on anchor, running along axis.
  const EXTENT = float(EXTENT_WORLD)
  for i in 0 ..< SAMPLES_AXIS:
    let offset = -EXTENT + 2.0*EXTENT*float(i)/float(SAMPLES_AXIS - 1)
    result[i] = anchor + offset*axis


proc drawPolylineWorld(
  canvas: var Canvas;
  camera: Camera;
  places: openArray[Position];
  ink: Ink;
  width = 1.6;
  opacity = 1.0;
) =
  ## Draw polyline through world positions, breaking run wherever camera cannot see one.
  ##   Segment straddling image plane is dropped rather than clipped against it,
  ##   so span ends short of frame edge where it passes behind camera.
  doAssert len(places) <= SAMPLES_AXIS,
    &"Polyline holds at most {SAMPLES_AXIS} vertices; got `{len(places)}`."
  var
    vertices: array[SAMPLES_AXIS, PointCanvas]
    count_vertices = 0
  for place in places:
    let projection = camera.project(toMultivector(place))
    if projection.isNone:
      if count_vertices >= 2:
        canvas.drawPolyline(vertices.toOpenArray(0, count_vertices - 1), ink, width, opacity)
      count_vertices = 0
      continue
    vertices[count_vertices] = toCanvas(projection.get.position)
    inc count_vertices
  if count_vertices >= 2:
    canvas.drawPolyline(vertices.toOpenArray(0, count_vertices - 1), ink, width, opacity)


proc drawPatchWorld(
  canvas: var Canvas; camera: Camera; corners: array[4, Position]; ink: Ink
) =
  ## Draw filled quadrilateral through world corners.
  ##   Whole patch is dropped where any corner is unseen, as partial fill would mislead.
  var vertices: array[4, PointCanvas]
  for i, corner in corners:
    let projection = camera.project(toMultivector(corner))
    if projection.isNone: return
    vertices[i] = toCanvas(projection.get.position)
  canvas.drawPolygon(vertices, ink)


proc drawArrowWorld(
  canvas: var Canvas;
  camera: Camera;
  tail: Position;
  axis: Direction;
  length: float;
  ink: Ink;
) =
  ## Draw shaft from tail along axis, marking its head with disc.
  let head = tail + length*axis
  canvas.drawPolylineWorld(camera, [tail, head], ink, width = 1.2)
  let projection = camera.project(toMultivector(head))
  if projection.isNone: return
  canvas.drawMarker(toCanvas(projection.get.position), ink, radius = 2.5)


proc drawLabelWorld(
  canvas: var Canvas; camera: Camera; at: Position; text: string; ink: Ink
) =
  ## Draw text beside projection of world position.
  const OFFSET_LABEL = 9.0
  let projection = camera.project(toMultivector(at))
  if projection.isNone: return
  var place = toCanvas(projection.get.position)
  place.x += OFFSET_LABEL
  place.y -= OFFSET_LABEL
  canvas.drawText(place, text, ink)



#[ Object Drawing ]#

proc drawPoint(
  canvas: var Canvas; camera: Camera; geometry: Multivector; label: string; ink: Ink
): Placement =
  ## Draw grade-1 object as disc, or as arrow from origin where it lies at horizon.
  ##   Point at horizon has no place to mark, so its direction is drawn from origin.
  let place = position(geometry)
  if place.isNone:
    let heading = directionHorizon(geometry)
    if heading.isNone: return Placement.Hidden
    const LENGTH_HEADING = 0.5 * float(EXTENT_WORLD)
    canvas.drawArrowWorld(camera, ORIGIN_WORLD, heading.get, LENGTH_HEADING, ink)
    canvas.drawLabelWorld(camera, ORIGIN_WORLD + LENGTH_HEADING*heading.get, label, ink)
    return Placement.Horizon

  let projection = camera.project(toMultivector(place.get))
  if projection.isNone: return Placement.Hidden
  canvas.drawMarker(toCanvas(projection.get.position), ink)
  canvas.drawLabelWorld(camera, place.get, label, ink)
  Placement.Finite


proc drawLine(
  canvas: var Canvas; camera: Camera; geometry: Multivector; label: string; ink: Ink
): Placement =
  ## Draw grade-2 object as span about its support point, along its attitude.
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
  if anchor.isNone or axis.isNone: return Placement.Horizon

  canvas.drawPolylineWorld(camera, sampleAxis(anchor.get, axis.get), ink, width = 2.2)

  # Mark support point, as it is quantity algebra computed rather than one chosen to draw.
  #   Span stays drawn where support itself falls outside view, so placement is still finite.
  let projection = camera.project(toMultivector(anchor.get))
  if projection.isSome:
    canvas.drawMarker(toCanvas(projection.get.position), ink, radius = 3.0)

  # Label along span rather than at support, so support's own label stays readable.
  const OFFSET_LABEL = 0.35 * float(EXTENT_WORLD)
  canvas.drawLabelWorld(camera, anchor.get + OFFSET_LABEL*axis.get, label, ink)
  Placement.Finite


proc drawPlane(
  canvas: var Canvas; camera: Camera; geometry: Multivector; label: string; ink: Ink
): Placement =
  ## Draw grade-3 object as ruled grid patch about its support point.
  let
    anchor = positionAnchor(geometry)
    axes = frame(geometry)
    normal = directionNormal(geometry)
  if anchor.isNone or axes.isNone or normal.isNone: return Placement.Horizon
  const EXTENT = float(EXTENT_WORLD)
  let (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)

  # Wash patch first, so plane reads as surface rather than as loose bundle of lines.
  canvas.drawPatchWorld(camera, [
    anchor.get + EXTENT*axis_first + EXTENT*axis_second,
    anchor.get - EXTENT*axis_first + EXTENT*axis_second,
    anchor.get - EXTENT*axis_first - EXTENT*axis_second,
    anchor.get + EXTENT*axis_first - EXTENT*axis_second,
  ], ink)

  # Rule grid both ways, so plane's orientation and extent stay legible under perspective.
  for i in -CELLS_PLANE .. CELLS_PLANE:
    let offset = EXTENT*float(i)/float(CELLS_PLANE)
    let (start_first, start_second) = (
      anchor.get + offset*axis_second, anchor.get + offset*axis_first
    )
    canvas.drawPolylineWorld(
      camera, sampleAxis(start_first, axis_first), ink, width = 1.0, opacity = 0.55
    )
    canvas.drawPolylineWorld(
      camera, sampleAxis(start_second, axis_second), ink, width = 1.0, opacity = 0.55
    )

  # Show normal, as it is what tells plane apart from its own reflection.
  canvas.drawArrowWorld(camera, anchor.get, normal.get, 0.25*EXTENT, Ink.Guide)

  # Label at patch's edge rather than at support, so overlapping planes stay legible.
  canvas.drawLabelWorld(camera, anchor.get + (0.8*EXTENT)*axis_first, label, ink)
  Placement.Finite


proc drawItem*(canvas: var Canvas; camera: Camera; item: Item): Placement =
  ## Draw one item, dispatching on geometry its grade stands for.
  let shape = shape(item.geometry)
  doAssert shape.isSome, &"Item `{item.label}` lost its shape; got `{item.geometry}`."
  case shape.get
  of Shape.Point: canvas.drawPoint(camera, item.geometry, item.label, item.ink)
  of Shape.Line: canvas.drawLine(camera, item.geometry, item.label, item.ink)
  of Shape.Plane: canvas.drawPlane(camera, item.geometry, item.label, item.ink)



#[ Scene Drawing ]#

proc drawAxes*(canvas: var Canvas, camera: Camera) =
  ## Draw world axes through origin, so scene has frame to be read against.
  const AXES_WORLD = [
    (Direction(x: 1, y: 0, z: 0), "x"),
    (Direction(x: 0, y: 1, z: 0), "y"),
    (Direction(x: 0, y: 0, z: 1), "z"),
  ]
  for (axis, name) in AXES_WORLD:
    canvas.drawPolylineWorld(
      camera, sampleAxis(ORIGIN_WORLD, axis), Ink.Axis, width = 1.2, opacity = 0.8
    )
    canvas.drawLabelWorld(camera, ORIGIN_WORLD + float(EXTENT_WORLD)*axis, name, Ink.Axis)


proc drawLegend*(canvas: var Canvas, scene: Scene) =
  ## List label, shape and coefficients of each item, so picture and algebra sit together.
  const
    MARGIN_LEGEND = 22.0
    LEADING_LEGEND = 16.0
  var baseline = MARGIN_LEGEND + LEADING_LEGEND
  canvas.drawText(
    PointCanvas(x: MARGIN_LEGEND, y: baseline),
    "4D RGA · 3D Euclidean space",
    Ink.Label,
    size = 15.0,
  )
  baseline += 2.0*LEADING_LEGEND

  for item in scene:
    let shape = shape(item.geometry)
    doAssert shape.isSome, &"Item `{item.label}` lost its shape; got `{item.geometry}`."
    canvas.drawText(
      PointCanvas(x: MARGIN_LEGEND, y: baseline),
      &"{item.label}  ({shape.get})",
      item.ink,
      size = 13.0,
      as_monospace = true,
    )
    baseline += LEADING_LEGEND
    canvas.drawText(
      PointCanvas(x: MARGIN_LEGEND + LEADING_LEGEND, y: baseline),
      $item.geometry,
      Ink.Label,
      size = 12.0,
      as_monospace = true,
    )
    baseline += 1.6*LEADING_LEGEND


proc drawScene*(canvas: var Canvas; camera: Camera; scene: Scene): array[Placement, int] =
  ## Draw world axes, then every item, then legend; tally where items ended up.
  canvas.drawAxes(camera)
  for shape_pass in [Shape.Plane, Shape.Line, Shape.Point]:
    for item in scene:
      if shape(item.geometry) != some(shape_pass): continue
      inc result[canvas.drawItem(camera, item)]
  canvas.drawLegend(scene)
