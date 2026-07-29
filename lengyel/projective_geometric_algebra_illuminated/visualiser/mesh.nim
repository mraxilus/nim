## Turn RGA objects into vertices OpenGL can draw.
##
## Finite objects are tessellated about their support point, i.e. point nearest origin,
## out to `DrawExtent.extent` -- camera-relative (`extentFor`), not a fixed size, so a
## line or plane always reads as extending well past the visible view, however far the
## camera currently orbits:
##   Line becomes segment of that extent either side of support, along its attitude.
##   Plane becomes translucent disc of the same extent, fading toward its own rim rather
##   than stopping at a hard edge, spanned by its own frame.
##   Support point is what algebra computed, so it is marked in both cases.
##
## Object at horizon -- infinitely far away, no support point to anchor on -- is drawn
## fixed to `DrawExtent.eye` instead, at `DrawExtent.radius_horizon` (near the camera's
## own far clip plane, independent of `extent`): a point becomes a marker standing in a
## fixed direction, a line becomes the great circle of directions its own pencil spans,
## and a plane -- the unique universal "whole sky" object every plane at horizon is,
## regardless of which points produced it -- becomes a dome over the entire sky. Fixed
## to the eye rather than the origin, so orbiting or dollying the camera leaves each in
## the same apparent direction, exactly as real stars at effectively infinite distance
## would; only turning the camera to look toward or away from one moves it on screen.
##
## Storage is fixed and owned by caller: meshes are cleared and refilled every frame.
##   Rebuilding beats tracking which object changed, while scene holds only tens of objects.
##   Cost is a few thousand vertices uploaded per frame, which is far below any budget.
##
##   |-----------|--------------|-------------------------------------|
##   | Primitive | OpenGL       | Carries                             |
##   |-----------|--------------|-------------------------------------|
##   | Triangle  | GL_TRIANGLES | Plane discs, whole-sky domes.       |
##   | Line      | GL_LINES     | Lines, horizon circles, axes.       |
##   | Point     | GL_POINTS    | Points, support markers, stars.     |
##   |-----------|--------------|-------------------------------------|

{.experimental: "strictFuncs".}

import std/[math, options, strformat]

import ../pga
import ./objects



#[ Mesh Configuration ]#

# Allow caller to resize drawn extent floor and vertex storage without editing source.
#   E.g. `--define:visualiser.extent_min=20 --define:visualiser.vertices_max=32768`.
#   Nim's `.define` pragma takes only integers, bools or strings, so `EXTENT_FACTOR` and
#   `FRACTION_HORIZON` below -- both plain ratios, never needing a caller's own extreme
#   value the way a capacity like `EXTENT_MIN` or `VERTICES_MAX` might -- stay ordinary
#   constants instead.
const
  EXTENT_MIN* {.define: "visualiser.extent_min".} = 8
    ## Floor under the camera-relative draw extent below, so a line, plane or the
    ## ground grid never shrinks to nothing even when the camera dollies in close.
  EXTENT_FACTOR* = 0.5
    ## Scale camera's own orbit distance by this to reach the draw extent below -- a
    ## touch above the default 45-degree field of view's own half-width tangent
    ## (0.414), so drawn geometry comfortably exceeds the visible view rather than
    ## just reaching its edge, at whatever distance the camera currently orbits.
  FRACTION_HORIZON* = 0.9
    ## Place horizon geometry -- a star, a great circle, the whole sky -- this fraction
    ## of the way to camera's own far clip plane, so it reads as the farthest thing
    ## standing in this scene without ever being clipped away by standing past it.
  VERTICES_MAX* {.define: "visualiser.vertices_max".} = 16384
  ANIMATION_MILLISECONDS* {.define: "visualiser.animation_milliseconds".} = 350
    ## Set how long a freshly added object takes to grow and fade fully into view.
    ##   Held as milliseconds rather than seconds, as `.define` takes an integer.

static:
  doAssert EXTENT_MIN > 0, &"Drawn extent floor must be positive; got `{EXTENT_MIN}`."
  doAssert EXTENT_FACTOR > 0, &"Extent factor must be positive; got `{EXTENT_FACTOR}`."
  doAssert FRACTION_HORIZON > 0 and FRACTION_HORIZON < 1.0,
    &"Horizon fraction must fall strictly between 0 and 1; got `{FRACTION_HORIZON}`."
  doAssert VERTICES_MAX >= 1024, &"Vertex storage must hold 1024; got `{VERTICES_MAX}`."
  doAssert ANIMATION_MILLISECONDS > 0,
    &"Appear animation must take positive time; got `{ANIMATION_MILLISECONDS}` ms."

const ANIMATION_SECONDS* = float(ANIMATION_MILLISECONDS) / 1000.0
  ## Convert configured duration to the seconds `animationProgress` works in.

const
  CELLS_PLANE* = 4
    ## Set grid line count either side of origin, when tessellating ground furniture.
  SEGMENTS_DISC* = 48
    ## Set triangle count in a finite plane's own fan, dense enough to read as circular.
  SEGMENTS_CIRCLE_HORIZON* = 96
    ## Set segment count in a horizon line's own great circle -- denser than a finite
    ## plane's disc, since the ring alone is all a horizon line ever draws, with no
    ## filled wash of its own to soften a coarser ring's facets.
  LATITUDES_HORIZON* = 12
  LONGITUDES_HORIZON* = 24
    ## Set band counts in a horizon plane's own whole-sky dome.
  ORIGIN_WORLD* = Position(x: 0, y: 0, z: 0)
    ## Set world origin, which objects through it are drawn about.
  ALPHA_WASH* = 0.10'f32
    ## Set opacity of a finite plane's own disc, at its own centre.
  ALPHA_WASH_SKY* = 0.05'f32
    ## Set opacity of a horizon plane's own whole-sky dome -- fainter than a finite
    ## plane's own wash, since this one has no edge to fade toward and would otherwise
    ## read as a dominant tint over the entire view rather than a background hint.
  ALPHA_GUIDE* = 0.75'f32
    ## Set opacity of a plane's own normal arrow, shown a touch less boldly than its
    ## own disc's centre so it reads as a construction aid, not as another competing mark.



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

  DrawExtent* = object ## Hold how far this frame's geometry reaches, and from where.
    extent*: float ## How far a finite line's segment or plane's disc extends from its
      ## own anchor; how far the ground grid and world axes extend from the origin.
    eye*: Position ## Camera's own eye position, horizon geometry is anchored to, so it
      ## stays in a fixed apparent direction as the camera pans or dollies, exactly as
      ## a real star at effectively infinite distance would.
    radius_horizon*: float ## How far from `eye` horizon geometry -- a star, a great
      ## circle, a whole-sky dome -- is drawn.



#[ Camera-Relative Scale ]#

func extentFor*(distance: float): float =
  ## Compute how far a line, plane or the ground grid should reach this frame, given
  ## how far the camera currently orbits from its target -- so drawn geometry always
  ## looks like it extends past the visible view, whether the camera sits close or
  ## dollies far out, without coupling this module to `Camera` itself: caller reads
  ## `camera.distance` and hands over a plain number.
  max(float(EXTENT_MIN), distance * EXTENT_FACTOR)


func radiusHorizonFor*(distance_far: float): float =
  ## Compute how far from the eye horizon geometry sits this frame, given the camera's
  ## own far clip distance -- decoupled from `extentFor` above deliberately: an object
  ## standing for "infinitely far away" should sit near the renderer's own outer depth
  ## limit regardless of how far the camera has dollied in or out to view finite content.
  distance_far * FRACTION_HORIZON



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


proc addDisc(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba; segments: int = SEGMENTS_DISC
) =
  ## Append a filled circle as a fan of triangles from `center`, faded from `tint`'s own
  ## alpha at the centre to fully transparent at `radius` -- GL interpolates each
  ## vertex's own colour linearly across every triangle (confirmed against `renderer.nim`'s
  ## own shader: the vertex-to-fragment colour is a plain varying, not `flat`), so the
  ## fade is smooth with no extra shader work, standing in for a plane's own unbounded
  ## extent without a hard edge that would give away the render's own finite reach.
  let tint_edge = tint.fade(0.0)
  for i in 0 ..< segments:
    let
      angle_a = (2.0*PI * float(i)) / float(segments)
      angle_b = (2.0*PI * float(i + 1)) / float(segments)
      point_a = center + radius*(cos(angle_a)*axis_first + sin(angle_a)*axis_second)
      point_b = center + radius*(cos(angle_b)*axis_first + sin(angle_b)*axis_second)
    meshes.addVertex(Primitive.Triangle, center, tint)
    meshes.addVertex(Primitive.Triangle, point_a, tint_edge)
    meshes.addVertex(Primitive.Triangle, point_b, tint_edge)


proc addGreatCircle(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba; segments: int = SEGMENTS_CIRCLE_HORIZON
) =
  ## Append a closed ring of segments around `center`, in the plane `axis_first` and
  ## `axis_second` span, at `radius` -- the great circle a horizon line traces across
  ## the sky, seen from any point, standing for the pencil of directions it names.
  for i in 0 ..< segments:
    let
      angle_a = (2.0*PI * float(i)) / float(segments)
      angle_b = (2.0*PI * float(i + 1)) / float(segments)
      point_a = center + radius*(cos(angle_a)*axis_first + sin(angle_a)*axis_second)
      point_b = center + radius*(cos(angle_b)*axis_first + sin(angle_b)*axis_second)
    meshes.addSegment(point_a, point_b, tint)


func spherePoint(center: Position; radius: float; theta, phi: float): Position =
  ## Place point on sphere around `center`, at colatitude `theta` and longitude `phi`.
  center + radius*Direction(x: sin(theta)*cos(phi), y: sin(theta)*sin(phi), z: cos(theta))


proc addDome(
  meshes: var MeshSet; center: Position; radius: float; tint: Rgba;
  latitudes: int = LATITUDES_HORIZON; longitudes: int = LONGITUDES_HORIZON
) =
  ## Append a full sphere around `center` -- a plane at horizon is the unique universal
  ## "whole sky" object, the same regardless of which points produced it (see
  ## `directionNormalHorizon`'s own doc comment for why), so nothing about its own
  ## coefficients decides its shape here; only `radius` and `tint` do.
  for lat in 0 ..< latitudes:
    let
      theta_a = PI * float(lat) / float(latitudes)
      theta_b = PI * float(lat + 1) / float(latitudes)
    for lon in 0 ..< longitudes:
      let
        phi_a = 2.0*PI * float(lon) / float(longitudes)
        phi_b = 2.0*PI * float(lon + 1) / float(longitudes)
      meshes.addQuad([
        spherePoint(center, radius, theta_a, phi_a),
        spherePoint(center, radius, theta_a, phi_b),
        spherePoint(center, radius, theta_b, phi_b),
        spherePoint(center, radius, theta_b, phi_a),
      ], tint)



#[ World Furniture ]#

proc addAxes*(meshes: var MeshSet; extent: float) =
  ## Append world axes through origin, each in the standard convention: x red, y green,
  ## z blue, so orientation reads at a glance regardless of where the camera stands.
  const AXES_WORLD = [
    (Direction(x: 1, y: 0, z: 0), Ink.AxisX),
    (Direction(x: 0, y: 1, z: 0), Ink.AxisY),
    (Direction(x: 0, y: 0, z: 1), Ink.AxisZ),
  ]
  for (axis, ink) in AXES_WORLD:
    meshes.addSegment(ORIGIN_WORLD - extent*axis, ORIGIN_WORLD + extent*axis, ink.colour)


proc addGrid*(meshes: var MeshSet; extent: float) =
  ## Append reference grid on ground, so distance and direction stay judgeable.
  ##   Skips the two lines through the origin itself: those coincide exactly with the
  ##   x and y world axes, and would either fight them for the same depth or hide their
  ##   colour under plain grid grey, depending on which happened to draw last.
  const TINT = Ink.Grid.colour
  for i in -CELLS_PLANE .. CELLS_PLANE:
    if i == 0: continue
    let offset = extent*float(i)/float(CELLS_PLANE)
    meshes.addSegment(
      Position(x: offset, y: -extent, z: 0), Position(x: offset, y: extent, z: 0), TINT
    )
    meshes.addSegment(
      Position(x: -extent, y: offset, z: 0), Position(x: extent, y: offset, z: 0), TINT
    )



#[ Object Tessellation ]#

proc addPoint(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float; scale: DrawExtent
): Placement =
  ## Append grade-1 object as marker, or, at horizon, as a marker fixed at `scale.eye`
  ## plus its own direction scaled out to `scale.radius_horizon` -- a star effectively
  ## infinitely far away, staying in the same apparent direction as the camera pans or
  ## dollies, moving only as the eye itself does.
  ##   `progress` fades a marker in and, at horizon, also grows how far out it stands.
  let place = position(geometry)
  if place.isSome:
    meshes.addMarker(place.get, tint.fade(tint.alpha*progress))
    return Placement.Finite

  let heading = directionHorizon(geometry)
  if heading.isNone: return Placement.Empty
  meshes.addMarker(
    scale.eye + (progress*scale.radius_horizon)*heading.get, tint.fade(tint.alpha*progress)
  )
  Placement.Horizon


proc addLine(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float; scale: DrawExtent
): Placement =
  ## Append grade-2 object as segment about its support point, along its attitude, or,
  ## at horizon, as a great circle around `scale.eye` -- the pencil of directions the
  ## line stands for, traced across the sky at `scale.radius_horizon`.
  ##   `progress` grows the segment, or the circle's own radius, out from nothing, and
  ##   fades it in alongside, so a freshly derived line visibly extends rather than
  ##   popping in.
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
  if anchor.isSome and axis.isSome:
    let
      extent = progress*scale.extent
      tint_progress = tint.fade(tint.alpha*progress)
    meshes.addSegment(anchor.get - extent*axis.get, anchor.get + extent*axis.get, tint_progress)
    meshes.addMarker(anchor.get, tint_progress)
    return Placement.Finite

  let normal = directionNormalHorizon(geometry)
  if normal.isNone: return Placement.Empty
  let axes = spanPerpendicular(ORIGIN_WORLD, normal.get)
  if axes.isNone: return Placement.Empty
  let (axis_first, axis_second) = axes.get
  meshes.addGreatCircle(
    scale.eye, axis_first, axis_second, progress*scale.radius_horizon,
    tint.fade(tint.alpha*progress),
  )
  Placement.Horizon


proc addPlane(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float; scale: DrawExtent
): Placement =
  ## Append grade-3 object as translucent disc about its support point, or, at horizon,
  ## as a dome filling the whole sky around `scale.eye` -- the unique universal object
  ## every plane at horizon stands for, regardless of which points produced it.
  ##   `progress` grows the disc, its normal arrow, or the dome's own radius out from
  ##   nothing, and fades every part of it in alongside.
  let
    anchor = positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isSome and axes.isSome:
    let
      extent = progress*scale.extent
      (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)
      tint_progress = tint.fade(tint.alpha*progress)

    # Disc first, so plane reads as surface rather than as loose bundle of lines; fades
    #   toward its own rim rather than stopping at a hard edge that would give away this
    #   render's own finite reach for what is, in the algebra, an unbounded plane.
    meshes.addDisc(anchor.get, axis_first, axis_second, extent, tint.fade(ALPHA_WASH*progress))

    # Show normal, as it is what tells plane apart from its own reflection.
    meshes.addArrow(
      anchor.get, axes.get.normal, 0.25*extent, Ink.Guide.colour.fade(ALPHA_GUIDE*progress)
    )
    meshes.addMarker(anchor.get, tint_progress)
    return Placement.Finite

  meshes.addDome(scale.eye, progress*scale.radius_horizon, tint.fade(ALPHA_WASH_SKY*progress))
  Placement.Horizon


proc addObject*(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; scale: DrawExtent; progress: float = 1.0
): Placement =
  ## Append object, dispatching on geometry its grade stands for.
  ##   Empty where multivector carries no drawable geometry at all.
  ##   `progress` is how much of its appear animation the object has completed, from
  ##   `mesh.animationProgress`; defaults to fully appeared, for a caller with nothing
  ##   to animate against.
  let shape = shape(geometry)
  if shape.isNone: return Placement.Empty
  case shape.get
  of Shape.Point: meshes.addPoint(geometry, tint, progress, scale)
  of Shape.Line: meshes.addLine(geometry, tint, progress, scale)
  of Shape.Plane: meshes.addPlane(geometry, tint, progress, scale)
