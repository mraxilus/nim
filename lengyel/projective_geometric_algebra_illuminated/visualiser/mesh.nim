## Turn RGA objects into vertices OpenGL can draw.
##
## Unbounded objects are tessellated about their support point, i.e. point nearest origin:
##   Line becomes segment of `EXTENT_WORLD` either side of support, along its attitude.
##   Plane becomes translucent quad of same extent, ruled by grid, spanned by its frame.
##   Support point is what algebra computed, so it is marked in both cases.
##   Object at horizon has no support, so its direction is drawn as arrow from origin.
##
## Storage is fixed and owned by caller: meshes are cleared and refilled every frame.
##   Rebuilding beats tracking which object changed, while scene holds only tens of objects.
##   Cost is a few thousand vertices uploaded per frame, which is far below any budget.
##
##   |-----------|--------------|-------------------------------------|
##   | Primitive | OpenGL       | Carries                             |
##   |-----------|--------------|-------------------------------------|
##   | Triangle  | GL_TRIANGLES | Translucent plane washes.           |
##   | Line      | GL_LINES     | Lines, plane grids, axes, arrows.   |
##   | Point     | GL_POINTS    | Points and support markers.         |
##   |-----------|--------------|-------------------------------------|

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./objects



#[ Mesh Configuration ]#

# Allow caller to resize drawn extent and vertex storage without editing source.
#   E.g. `--define:visualiser.extent_world=20 --define:visualiser.vertices_max=32768`.
const
  EXTENT_WORLD* {.define: "visualiser.extent_world".} = 8
  VERTICES_MAX* {.define: "visualiser.vertices_max".} = 16384

static:
  doAssert EXTENT_WORLD > 0, &"Drawn extent must be positive; got `{EXTENT_WORLD}`."
  doAssert VERTICES_MAX >= 1024, &"Vertex storage must hold 1024; got `{VERTICES_MAX}`."

const
  CELLS_PLANE* = 8
    ## Set grid line count either side of support point, when tessellating plane.
  ORIGIN_WORLD* = Position(x: 0, y: 0, z: 0)
    ## Set world origin, which objects through it are drawn about.
  ALPHA_WASH* = 0.13'f32
    ## Set opacity of plane's translucent quad.
  ALPHA_GRID* = 0.55'f32
    ## Set opacity of plane's ruled grid.



#[ Type Definitions ]#

type
  Ink* {.pure.} = enum ## Name palette slot, so every colour in output lives in one table.
    ## Structural slots, spent on furniture of drawing itself.
    Backdrop, ## Colour framebuffer is cleared to.
    Axis, ## World axes through origin.
    Grid, ## World reference grid on ground.
    Guide, ## Construction helper, e.g. plane normal.
    ## Categorical slots, spent by caller on telling one object from another.
    ##   Named by hue rather than by role, as caller alone knows what objects mean.
    ##   Grade is already legible from shape drawn, so colour is free to carry identity.
    Amber, Coral, Cyan, Violet, Lime, Teal, Rose,

  Primitive* {.pure.} = enum ## Name kind of OpenGL primitive vertices are assembled into.
    Triangle, Line, Point

  Rgba* = object ## Hold colour channels, in 0 .. 1.
    red*, green*, blue*, alpha*: float32

  Vertex* = object ## Hold one vertex exactly as it is uploaded.
    x*, y*, z*: float32
    red*, green*, blue*, alpha*: float32

  Mesh* = object ## Hold vertices of one primitive kind, in storage fixed at compile time.
    vertices*: array[VERTICES_MAX, Vertex]
    count_vertices*: int

  MeshSet* = array[Primitive, Mesh] ## Hold one mesh per primitive kind.



#[ Palette ]#

const lut_ink_to_rgba: array[Ink, Rgba] = [
  Ink.Backdrop: Rgba(red: 0.063, green: 0.075, blue: 0.102, alpha: 1.0),
  Ink.Axis: Rgba(red: 0.404, green: 0.443, blue: 0.514, alpha: 1.0),
  Ink.Grid: Rgba(red: 0.180, green: 0.204, blue: 0.259, alpha: 1.0),
  Ink.Guide: Rgba(red: 0.286, green: 0.322, blue: 0.400, alpha: 1.0),
  Ink.Amber: Rgba(red: 1.000, green: 0.706, blue: 0.329, alpha: 1.0),
  Ink.Coral: Rgba(red: 1.000, green: 0.435, blue: 0.380, alpha: 1.0),
  Ink.Cyan: Rgba(red: 0.435, green: 0.765, blue: 0.875, alpha: 1.0),
  Ink.Violet: Rgba(red: 0.780, green: 0.573, blue: 0.918, alpha: 1.0),
  Ink.Lime: Rgba(red: 0.561, green: 0.737, blue: 0.353, alpha: 1.0),
  Ink.Teal: Rgba(red: 0.247, green: 0.722, blue: 0.627, alpha: 1.0),
  Ink.Rose: Rgba(red: 0.878, green: 0.424, blue: 0.624, alpha: 1.0),
] ## Map palette slot to colour, chosen for contrast against backdrop and each other.


const COUNT_INK* = ord(Ink.high) + 1
  ## Count palette slots, for handing whole palette to a picker.


let lut_ink_to_name* = block:
  ## Name each palette slot, for offering them in a picker.
  ##   Bound as `let` rather than `const`, since picker needs address of first entry.
  var lut: array[Ink, cstring]
  for ink in Ink: lut[ink] = cstring($ink)
  lut


func colour*(ink: Ink): Rgba = lut_ink_to_rgba[ink]
  ## Read colour of palette slot.


func fade*(base: Rgba; alpha: float32): Rgba =
  ## Rewrite colour's opacity, leaving its hue alone.
  Rgba(red: base.red, green: base.green, blue: base.blue, alpha: alpha)



#[ Vertex Assembly ]#

proc clearMeshes*(meshes: var MeshSet) =
  ## Drop every vertex assembled so far, so frame may be rebuilt from scratch.
  for primitive in Primitive:
    meshes[primitive].count_vertices = 0


proc addVertex(meshes: var MeshSet; primitive: Primitive; at: Position; tint: Rgba) =
  ## Append single vertex to mesh of given primitive kind.
  let count = meshes[primitive].count_vertices
  doAssert count < VERTICES_MAX,
    &"Mesh holds at most {VERTICES_MAX} vertices; raise `--define:visualiser.vertices_max`."
  meshes[primitive].vertices[count] = Vertex(
    x: float32(at.x), y: float32(at.y), z: float32(at.z),
    red: tint.red, green: tint.green, blue: tint.blue, alpha: tint.alpha,
  )
  meshes[primitive].count_vertices = count + 1


proc addMarker*(meshes: var MeshSet; at: Position; tint: Rgba) =
  ## Append point marking single position.
  meshes.addVertex(Primitive.Point, at, tint)


proc addSegment*(meshes: var MeshSet; tail, head: Position; tint: Rgba) =
  ## Append line segment joining two positions.
  meshes.addVertex(Primitive.Line, tail, tint)
  meshes.addVertex(Primitive.Line, head, tint)


proc addQuad*(meshes: var MeshSet; corners: array[4, Position]; tint: Rgba) =
  ## Append filled quadrilateral, wound as two triangles.
  for index in [0, 1, 2, 0, 2, 3]:
    meshes.addVertex(Primitive.Triangle, corners[index], tint)


proc addArrow*(
  meshes: var MeshSet; tail: Position; axis: Direction; length: float; tint: Rgba
) =
  ## Append shaft from tail along axis, marking its head.
  let head = tail + length*axis
  meshes.addSegment(tail, head, tint)
  meshes.addMarker(head, tint)



#[ World Furniture ]#

proc addAxes*(meshes: var MeshSet) =
  ## Append world axes through origin, so scene has frame to be read against.
  const AXES_WORLD = [
    Direction(x: 1, y: 0, z: 0),
    Direction(x: 0, y: 1, z: 0),
    Direction(x: 0, y: 0, z: 1),
  ]
  const EXTENT = float(EXTENT_WORLD)
  for axis in AXES_WORLD:
    meshes.addSegment(ORIGIN_WORLD - EXTENT*axis, ORIGIN_WORLD + EXTENT*axis, Ink.Axis.colour)


proc addGrid*(meshes: var MeshSet) =
  ## Append reference grid on ground, so distance and direction stay judgeable.
  const
    EXTENT = float(EXTENT_WORLD)
    TINT = Ink.Grid.colour
  for i in -CELLS_PLANE .. CELLS_PLANE:
    let offset = EXTENT*float(i)/float(CELLS_PLANE)
    meshes.addSegment(
      Position(x: offset, y: -EXTENT, z: 0), Position(x: offset, y: EXTENT, z: 0), TINT
    )
    meshes.addSegment(
      Position(x: -EXTENT, y: offset, z: 0), Position(x: EXTENT, y: offset, z: 0), TINT
    )



#[ Object Tessellation ]#

proc addPoint(meshes: var MeshSet; geometry: Multivector; tint: Rgba): Placement =
  ## Append grade-1 object as marker, or as arrow from origin where it lies at horizon.
  let place = position(geometry)
  if place.isSome:
    meshes.addMarker(place.get, tint)
    return Placement.Finite

  let heading = directionHorizon(geometry)
  if heading.isNone: return Placement.Empty
  meshes.addArrow(ORIGIN_WORLD, heading.get, 0.5*float(EXTENT_WORLD), tint)
  Placement.Horizon


proc addLine(meshes: var MeshSet; geometry: Multivector; tint: Rgba): Placement =
  ## Append grade-2 object as segment about its support point, along its attitude.
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
  if anchor.isNone or axis.isNone: return Placement.Horizon
  const EXTENT = float(EXTENT_WORLD)
  meshes.addSegment(anchor.get - EXTENT*axis.get, anchor.get + EXTENT*axis.get, tint)
  meshes.addMarker(anchor.get, tint)
  Placement.Finite


proc addPlane(meshes: var MeshSet; geometry: Multivector; tint: Rgba): Placement =
  ## Append grade-3 object as translucent quad ruled by grid, about its support point.
  let
    anchor = positionAnchor(geometry)
    axes = frame(geometry)
    normal = directionNormal(geometry)
  if anchor.isNone or axes.isNone or normal.isNone: return Placement.Horizon
  const EXTENT = float(EXTENT_WORLD)
  let (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)

  # Wash quad first, so plane reads as surface rather than as loose bundle of lines.
  meshes.addQuad([
    anchor.get + EXTENT*axis_first + EXTENT*axis_second,
    anchor.get - EXTENT*axis_first + EXTENT*axis_second,
    anchor.get - EXTENT*axis_first - EXTENT*axis_second,
    anchor.get + EXTENT*axis_first - EXTENT*axis_second,
  ], tint.fade(ALPHA_WASH))

  # Rule grid both ways, so plane's orientation stays legible under perspective.
  let tint_grid = tint.fade(ALPHA_GRID)
  for i in -CELLS_PLANE .. CELLS_PLANE:
    let
      offset = EXTENT*float(i)/float(CELLS_PLANE)
      start_first = anchor.get + offset*axis_second
      start_second = anchor.get + offset*axis_first
    meshes.addSegment(
      start_first - EXTENT*axis_first, start_first + EXTENT*axis_first, tint_grid
    )
    meshes.addSegment(
      start_second - EXTENT*axis_second, start_second + EXTENT*axis_second, tint_grid
    )

  # Show normal, as it is what tells plane apart from its own reflection.
  meshes.addArrow(anchor.get, normal.get, 0.25*EXTENT, Ink.Guide.colour)
  meshes.addMarker(anchor.get, tint)
  Placement.Finite


proc addObject*(meshes: var MeshSet; geometry: Multivector; tint: Rgba): Placement =
  ## Append object, dispatching on geometry its grade stands for.
  ##   Empty where multivector carries no drawable geometry at all.
  let shape = shape(geometry)
  if shape.isNone: return Placement.Empty
  case shape.get
  of Shape.Point: meshes.addPoint(geometry, tint)
  of Shape.Line: meshes.addLine(geometry, tint)
  of Shape.Plane: meshes.addPlane(geometry, tint)
