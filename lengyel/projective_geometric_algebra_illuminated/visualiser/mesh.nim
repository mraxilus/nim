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
  ANIMATION_MILLISECONDS* {.define: "visualiser.animation_milliseconds".} = 350
    ## Set how long a freshly added object takes to grow and fade fully into view.
    ##   Held as milliseconds rather than seconds, as `.define` takes an integer.

static:
  doAssert EXTENT_WORLD > 0, &"Drawn extent must be positive; got `{EXTENT_WORLD}`."
  doAssert VERTICES_MAX >= 1024, &"Vertex storage must hold 1024; got `{VERTICES_MAX}`."
  doAssert ANIMATION_MILLISECONDS > 0,
    &"Appear animation must take positive time; got `{ANIMATION_MILLISECONDS}` ms."

const ANIMATION_SECONDS* = float(ANIMATION_MILLISECONDS) / 1000.0
  ## Convert configured duration to the seconds `animationProgress` works in.

const
  CELLS_PLANE* = 4
    ## Set grid line count either side of support point, when tessellating plane.
    ##   Halved from an earlier 8: a plane's own ruled grid is what a second or third
    ##   overlapping plane turns into visual noise fastest, since every one of them
    ##   draws its own full set of lines across the same shared space. Four still reads
    ##   as a grid and still conveys tilt under perspective; eight, doubled or tripled
    ##   by nearby planes, reads as a thicket.
  ORIGIN_WORLD* = Position(x: 0, y: 0, z: 0)
    ## Set world origin, which objects through it are drawn about.
  ALPHA_WASH* = 0.10'f32
    ## Set opacity of plane's translucent quad.
  ALPHA_GRID_BOUNDARY* = 0.65'f32
    ## Set opacity of the grid lines running along a plane's own outer edge, crisp
    ## enough that its extent reads at a glance regardless of how faint the rest is.
  ALPHA_GRID_INTERIOR* = 0.22'f32
    ## Set opacity of every grid line strictly inside a plane's own boundary: present
    ## enough to still read as a ruled surface and carry perspective tilt, faint enough
    ## that two or three overlapping planes don't drown each other in crossing lines.
  ALPHA_GUIDE* = 0.75'f32
    ## Set opacity of a plane's own normal arrow, shown a touch less boldly than its
    ## boundary so it reads as a construction aid, not as another competing line.



#[ Type Definitions ]#

type
  Ink* {.pure.} = enum ## Name palette slot, so every colour in output lives in one table.
    ## Structural slots, spent on furniture of drawing itself.
    Backdrop, ## Colour framebuffer is cleared to.
    AxisX, ## World x axis through origin; standard convention is red.
    AxisY, ## World y axis through origin; standard convention is green.
    AxisZ, ## World z axis through origin; standard convention is blue.
    Grid, ## World reference grid on ground.
    Guide, ## Construction helper, e.g. plane normal.
    ## Categorical slots, spent by caller on telling one object from another.
    ##   Named by hue rather than by role, as caller alone knows what objects mean.
    ##   Grade is already legible from shape drawn, so colour is free to carry identity.
    ##   Declared in this exact order, not just for cycling: consecutive names sit far
    ##   apart on the colour wheel, so two objects added one after another -- the most
    ##   likely pair to end up compared or drawn near each other -- read as different
    ##   colours even under colour-vision deficiency, not just to typical vision.
    Amber, Cyan, Rose, Lime, Violet, Coral, Teal,

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
  Ink.AxisX: Rgba(red: 0.851, green: 0.239, blue: 0.239, alpha: 1.0),
  Ink.AxisY: Rgba(red: 0.298, green: 0.780, blue: 0.298, alpha: 1.0),
  Ink.AxisZ: Rgba(red: 0.298, green: 0.482, blue: 0.929, alpha: 1.0),
  Ink.Grid: Rgba(red: 0.180, green: 0.204, blue: 0.259, alpha: 1.0),
  Ink.Guide: Rgba(red: 0.286, green: 0.322, blue: 0.400, alpha: 1.0),
  Ink.Amber: Rgba(red: 0.690, green: 0.510, blue: 0.145, alpha: 1.0),
  Ink.Cyan: Rgba(red: 0.231, green: 0.518, blue: 0.808, alpha: 1.0),
  Ink.Rose: Rgba(red: 0.824, green: 0.251, blue: 0.557, alpha: 1.0),
  Ink.Lime: Rgba(red: 0.255, green: 0.639, blue: 0.157, alpha: 1.0),
  Ink.Violet: Rgba(red: 0.510, green: 0.271, blue: 0.827, alpha: 1.0),
  Ink.Coral: Rgba(red: 0.824, green: 0.329, blue: 0.251, alpha: 1.0),
  Ink.Teal: Rgba(red: 0.129, green: 0.624, blue: 0.608, alpha: 1.0),
] ## Map palette slot to colour: each hue picked at matched lightness and moderate,
  ## consistent saturation (rather than the mix of near-neon and washed-out shades a
  ## quick, unchecked choice tends to produce), and the whole set run through the
  ## dataviz skill's own palette validator (adjacent CVD ΔE and normal-vision ΔE both
  ## clear their floors against this backdrop) rather than picked by eye.


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



#[ Appear Animation ]#

func easeOutCubic(t: float): float =
  ## Ease progress toward 1, quickly at first then settling, for a materialising feel.
  let u = 1.0 - clamp(t, 0.0, 1.0)
  1.0 - u*u*u


func animationProgress*(now, born: float): float =
  ## Report how much of its appear animation an item born at `born` has completed by `now`.
  ##   Clamped and eased, so a caller may pass any `now - born` -- however large, negative,
  ##   or mid-flight -- and always get a value straight back to scale or fade geometry by.
  easeOutCubic((now - born) / ANIMATION_SECONDS)



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
  ## Append world axes through origin, each in the standard convention: x red, y green,
  ## z blue, so orientation reads at a glance regardless of where the camera stands.
  const AXES_WORLD = [
    (Direction(x: 1, y: 0, z: 0), Ink.AxisX),
    (Direction(x: 0, y: 1, z: 0), Ink.AxisY),
    (Direction(x: 0, y: 0, z: 1), Ink.AxisZ),
  ]
  const EXTENT = float(EXTENT_WORLD)
  for (axis, ink) in AXES_WORLD:
    meshes.addSegment(ORIGIN_WORLD - EXTENT*axis, ORIGIN_WORLD + EXTENT*axis, ink.colour)


proc addGrid*(meshes: var MeshSet) =
  ## Append reference grid on ground, so distance and direction stay judgeable.
  ##   Skips the two lines through the origin itself: those coincide exactly with the
  ##   x and y world axes, and would either fight them for the same depth or hide their
  ##   colour under plain grid grey, depending on which happened to draw last.
  const
    EXTENT = float(EXTENT_WORLD)
    TINT = Ink.Grid.colour
  for i in -CELLS_PLANE .. CELLS_PLANE:
    if i == 0: continue
    let offset = EXTENT*float(i)/float(CELLS_PLANE)
    meshes.addSegment(
      Position(x: offset, y: -EXTENT, z: 0), Position(x: offset, y: EXTENT, z: 0), TINT
    )
    meshes.addSegment(
      Position(x: -EXTENT, y: offset, z: 0), Position(x: EXTENT, y: offset, z: 0), TINT
    )



#[ Object Tessellation ]#

proc addPoint(meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float): Placement =
  ## Append grade-1 object as marker, or as arrow from origin where it lies at horizon.
  ##   `progress` fades a marker in and, for the arrow, also grows its length -- a point
  ##   sprite has no length of its own to grow, so its own appearance is fade alone.
  let place = position(geometry)
  if place.isSome:
    meshes.addMarker(place.get, tint.fade(tint.alpha*progress))
    return Placement.Finite

  let heading = directionHorizon(geometry)
  if heading.isNone: return Placement.Empty
  meshes.addArrow(
    ORIGIN_WORLD, heading.get, progress*0.5*float(EXTENT_WORLD), tint.fade(tint.alpha*progress)
  )
  Placement.Horizon


proc addLine(meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float): Placement =
  ## Append grade-2 object as segment about its support point, along its attitude.
  ##   `progress` grows the segment symmetrically out from its support point, and fades
  ##   it in alongside, so a freshly derived line visibly extends rather than popping in.
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
  if anchor.isNone or axis.isNone: return Placement.Horizon
  let
    extent = progress*float(EXTENT_WORLD)
    tint_progress = tint.fade(tint.alpha*progress)
  meshes.addSegment(anchor.get - extent*axis.get, anchor.get + extent*axis.get, tint_progress)
  meshes.addMarker(anchor.get, tint_progress)
  Placement.Finite


proc addPlane(meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float): Placement =
  ## Append grade-3 object as translucent quad ruled by grid, about its support point.
  ##   `progress` grows the quad, grid and normal arrow out from the support point exactly
  ##   as `addLine` grows a segment, and fades every part of it in alongside.
  let
    anchor = positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isNone or axes.isNone: return Placement.Horizon
  let
    extent = progress*float(EXTENT_WORLD)
    (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)
    tint_progress = tint.fade(tint.alpha*progress)

  # Wash quad first, so plane reads as surface rather than as loose bundle of lines.
  meshes.addQuad([
    anchor.get + extent*axis_first + extent*axis_second,
    anchor.get - extent*axis_first + extent*axis_second,
    anchor.get - extent*axis_first - extent*axis_second,
    anchor.get + extent*axis_first - extent*axis_second,
  ], tint.fade(ALPHA_WASH*progress))

  # Rule grid both ways, so plane's orientation stays legible under perspective.
  #   Boundary drawn crisp so extent reads at a glance; interior left faint, so a
  #   second or third overlapping plane adds a wash and an edge, not another thicket
  #   of full-strength lines fighting the first plane's own for attention.
  let
    tint_boundary = tint.fade(ALPHA_GRID_BOUNDARY*progress)
    tint_interior = tint.fade(ALPHA_GRID_INTERIOR*progress)
  for i in -CELLS_PLANE .. CELLS_PLANE:
    let
      tint_grid = if abs(i) == CELLS_PLANE: tint_boundary else: tint_interior
      offset = extent*float(i)/float(CELLS_PLANE)
      start_first = anchor.get + offset*axis_second
      start_second = anchor.get + offset*axis_first
    meshes.addSegment(
      start_first - extent*axis_first, start_first + extent*axis_first, tint_grid
    )
    meshes.addSegment(
      start_second - extent*axis_second, start_second + extent*axis_second, tint_grid
    )

  # Show normal, as it is what tells plane apart from its own reflection.
  meshes.addArrow(
    anchor.get, axes.get.normal, 0.25*extent, Ink.Guide.colour.fade(ALPHA_GUIDE*progress)
  )
  meshes.addMarker(anchor.get, tint_progress)
  Placement.Finite


proc addObject*(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float = 1.0
): Placement =
  ## Append object, dispatching on geometry its grade stands for.
  ##   Empty where multivector carries no drawable geometry at all.
  ##   `progress` is how much of its appear animation the object has completed, from
  ##   `mesh.animationProgress`; defaults to fully appeared, for a caller with nothing
  ##   to animate against.
  let shape = shape(geometry)
  if shape.isNone: return Placement.Empty
  case shape.get
  of Shape.Point: meshes.addPoint(geometry, tint, progress)
  of Shape.Line: meshes.addLine(geometry, tint, progress)
  of Shape.Plane: meshes.addPlane(geometry, tint, progress)
