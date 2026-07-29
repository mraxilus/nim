## Turn RGA objects into vertices OpenGL can draw.
##
## Finite objects are tessellated about their support point, i.e. point nearest origin:
##   Line becomes segment reaching `DrawExtent.extent_furniture` either side of support,
##   along its attitude -- the same reach world furniture below gets, so a line always
##   reads as running out toward the horizon rather than stopping at some arbitrary
##   camera-relative length, and a plane crossing it never reads as swallowing it, since
##   a line's own reach dwarfs any plane's.
##   Plane becomes a flat, translucent disc at a fixed radius (`EXTENT_PLANE`) plus a
##   rim marking its edge crisply, spanned by its own frame -- fixed rather than
##   camera-relative, so a plane holds one size in world units and does not appear to
##   grow or shrink as the camera dollies or orbits, exactly as a real fixed-size object
##   would.
##   Support point is what algebra computed; only a plane's own normal is additionally
##   marked, as a bare shaft with no point at its tip, so orientation reads without
##   adding another marker to the scene.
##
## Object at horizon -- infinitely far away, no support point to anchor on -- is drawn
## fixed to `DrawExtent.eye` instead, at `DrawExtent.radius_horizon` (near the camera's
## own far clip plane): a point becomes a marker standing in a fixed direction, a line
## becomes the great circle of directions its own pencil spans, and a plane -- the
## unique universal "whole sky" object every plane at horizon is, regardless of which
## points produced it -- becomes a dome over the entire sky. Fixed to the eye rather
## than the origin, so orbiting or dollying the camera leaves each in the same apparent
## direction, exactly as real stars at effectively infinite distance would; only
## turning the camera to look toward or away from one moves it on screen.
##
## World furniture -- ground grid, world axes -- reaches `DrawExtent.extent_furniture`
## too, tied to the camera's own far clip distance rather than to orbit distance
## (`extentFurnitureFor`), so it reads as extending indefinitely into the distance
## regardless of how far the camera has dollied in or out to inspect finite content.
##
## Storage is fixed and owned by caller: meshes are cleared and refilled every frame.
##   Rebuilding beats tracking which object changed, while scene holds only tens of objects.
##   Cost is a few thousand vertices uploaded per frame, which is far below any budget.
##
##   |-----------|--------------|-------------------------------------|
##   | Primitive | OpenGL       | Carries                             |
##   |-----------|--------------|-------------------------------------|
##   | Triangle  | GL_TRIANGLES | Plane discs, whole-sky domes.       |
##   | Line      | GL_LINES     | Lines, plane rims, horizon circles, |
##   |           |              | axes, ground grid.                  |
##   | Point     | GL_POINTS    | Points, support markers, stars.     |
##   |-----------|--------------|-------------------------------------|

{.experimental: "strictFuncs".}

import std/[math, options, strformat]

import ../pga
import ./objects



#[ Mesh Configuration ]#

# Allow caller to resize a plane's own drawn radius and vertex storage without editing
#   source. E.g. `--define:visualiser.extent_plane=20 --define:visualiser.vertices_max=32768`.
#   Nim's `.define` pragma takes only integers, bools or strings, so `FRACTION_HORIZON`
#   below -- a plain ratio, never needing a caller's own extreme value the way a
#   capacity like `EXTENT_PLANE` or `VERTICES_MAX` might -- stays an ordinary constant.
const
  EXTENT_PLANE* {.define: "visualiser.extent_plane".} = 8
    ## Fix how far a plane's own disc and rim reach from its support point, in world
    ## units -- deliberately independent of the camera, so a plane holds one size
    ## rather than growing or shrinking as the camera dollies or orbits around it.
  FRACTION_HORIZON* = 0.9
    ## Place horizon geometry -- a star, a great circle, the whole sky -- this fraction
    ## of the way to camera's own far clip plane, so it reads as the farthest thing
    ## standing in this scene without ever being clipped away by standing past it.
  FRACTION_FURNITURE* = 0.95
    ## Reach world axes, the ground grid, and every finite line this fraction of the
    ## way to camera's own far clip plane -- tied to that fixed depth rather than to
    ## orbit distance, so all three read as extending indefinitely into the distance
    ## regardless of how far the camera has dollied in or out to inspect finite content.
  FRACTION_GRID_FADE_START* = 0.03
    ## Hold ground grid lines at full alpha out to this fraction of their own reach,
    ## fading the remainder out toward `FRACTION_GRID_FADE_END` -- past that point,
    ## cells crowd into fewer and fewer screen pixels under perspective, reading as
    ## aliasing noise rather than as a reference.
  FRACTION_GRID_FADE_END* = 0.12
    ## Cut ground grid lines off entirely at this fraction of their own reach, well
    ## short of it -- a faint line still aliases under perspective, so the fix is to
    ## stop drawing it there, not just to dim it further.
  VERTICES_MAX* {.define: "visualiser.vertices_max".} = 16384
  ANIMATION_MILLISECONDS* {.define: "visualiser.animation_milliseconds".} = 350
    ## Set how long a freshly added object takes to grow and fade fully into view.
    ##   Held as milliseconds rather than seconds, as `.define` takes an integer.

static:
  doAssert EXTENT_PLANE > 0, &"Plane radius must be positive; got `{EXTENT_PLANE}`."
  doAssert FRACTION_HORIZON > 0 and FRACTION_HORIZON < 1.0,
    &"Horizon fraction must fall strictly between 0 and 1; got `{FRACTION_HORIZON}`."
  doAssert FRACTION_FURNITURE > 0 and FRACTION_FURNITURE < 1.0,
    &"Furniture fraction must fall strictly between 0 and 1; got `{FRACTION_FURNITURE}`."
  doAssert FRACTION_GRID_FADE_START > 0 and FRACTION_GRID_FADE_START < 1.0,
    &"Grid fade start fraction must fall strictly between 0 and 1; got " &
    &"`{FRACTION_GRID_FADE_START}`."
  doAssert FRACTION_GRID_FADE_END > FRACTION_GRID_FADE_START and FRACTION_GRID_FADE_END <= 1.0,
    &"Grid fade end fraction must exceed the start fraction and fall within 0 and 1; " &
    &"got `{FRACTION_GRID_FADE_END}`."
  doAssert VERTICES_MAX >= 1024, &"Vertex storage must hold 1024; got `{VERTICES_MAX}`."
  doAssert ANIMATION_MILLISECONDS > 0,
    &"Appear animation must take positive time; got `{ANIMATION_MILLISECONDS}` ms."

const EXTENT_PLANE_F* = float(EXTENT_PLANE)
  ## `EXTENT_PLANE` itself stays an integer default, since Nim's `.define` pragma
  ## cannot take a float literal; every use site, in this module and beyond, wants a
  ## float.

const ANIMATION_SECONDS* = float(ANIMATION_MILLISECONDS) / 1000.0
  ## Convert configured duration to the seconds `animationProgress` works in.

const
  SIZE_CELL_GRID* = 2.0
    ## Fix ground grid's own cell size, regardless of how far it reaches -- so filling
    ## further out toward the far clip plane adds more cells rather than stretching the
    ## existing ones until they lose all use as a local reference near the camera.
  SEGMENTS_GRID_FADE* = 8
    ## Cut each ground grid line into this many pieces, independent of `SIZE_CELL_GRID`,
    ## so `alphaGridFade` can fade it smoothly by distance without one piece per cell.
  SEGMENTS_CIRCLE_HORIZON* = 96
    ## Set segment count in a horizon line's own great circle, or a finite plane's own
    ## rim, dense enough to read as circular.
  LATITUDES_HORIZON* = 12
  LONGITUDES_HORIZON* = 24
    ## Set band counts in a horizon plane's own whole-sky dome.
  ORIGIN_WORLD* = Position(x: 0, y: 0, z: 0)
    ## Set world origin, which objects through it are drawn about.
  ALPHA_WASH* = 0.16'f32
    ## Set opacity of a finite plane's own fill -- flat across the whole disc, since
    ## the rim already marks its edge crisply; low enough that whatever sits behind a
    ## plane, including another plane crossing it, stays legible through it.
  ALPHA_WASH_SKY* = 0.05'f32
    ## Set opacity of a horizon plane's own whole-sky dome -- this one has no edge to
    ## fade toward and would otherwise read as a dominant tint over the entire view
    ## rather than a background hint.
  ALPHA_GUIDE* = 0.75'f32
    ## Set opacity of a plane's own normal arrow, shown a touch less boldly than the
    ## plane's own rim so it reads as a construction aid, not as another competing mark.

static:
  doAssert SIZE_CELL_GRID > 0, &"Grid cell size must be positive; got `{SIZE_CELL_GRID}`."
  doAssert SEGMENTS_GRID_FADE >= 2, &"Grid fade needs at least 2 pieces; got `{SEGMENTS_GRID_FADE}`."



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
    ##   Every hue here also clears the dataviz skill's own validator against the three
    ##   axis colours above, not just against each other (see `lut_ink_to_rgba`'s own
    ##   comment) -- a categorical object is never the same hue family as a structural
    ##   axis line, so neither is ever mistaken for the other.
    Amber, Teal, Rose, Lime, Orchid, Cyan, Violet,

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
    extent_furniture*: float ## How far the ground grid, world axes, and every finite
      ## line extend from the origin or their own support -- tied to the camera's own
      ## far clip distance, via `extentFurnitureFor`, rather than to orbit distance, so
      ## all three read as reaching indefinitely into the distance regardless of how
      ## far the camera has dollied in or out.
    eye*: Position ## Camera's own eye position, horizon geometry is anchored to, so it
      ## stays in a fixed apparent direction as the camera pans or dollies, exactly as
      ## a real star at effectively infinite distance would.
    radius_horizon*: float ## How far from `eye` horizon geometry -- a star, a great
      ## circle, a whole-sky dome -- is drawn.



#[ Camera-Relative Scale ]#

func radiusHorizonFor*(distance_far: float): float =
  ## Compute how far from the eye horizon geometry sits this frame, given the camera's
  ## own far clip distance: an object standing for "infinitely far away" should sit
  ## near the renderer's own outer depth limit regardless of how far the camera has
  ## dollied in or out to view finite content.
  distance_far * FRACTION_HORIZON


func extentFurnitureFor*(distance_far: float): float =
  ## Compute how far the ground grid, world axes, and every finite line should reach
  ## this frame, given the camera's own far clip distance -- independent of orbit
  ## distance, so all three keep reaching almost all the way to the renderer's own
  ## outer depth limit regardless of how far the camera has dollied in or out to
  ## inspect finite content, reading as extending indefinitely rather than shrinking
  ## back when the camera does.
  distance_far * FRACTION_FURNITURE



#[ Palette ]#

const lut_ink_to_rgba: array[Ink, Rgba] = [
  Ink.Backdrop: Rgba(red: 0.063, green: 0.075, blue: 0.102, alpha: 1.0),
  Ink.AxisX: Rgba(red: 0.851, green: 0.239, blue: 0.239, alpha: 1.0),
  Ink.AxisY: Rgba(red: 0.298, green: 0.780, blue: 0.298, alpha: 1.0),
  Ink.AxisZ: Rgba(red: 0.298, green: 0.482, blue: 0.929, alpha: 1.0),
  Ink.Grid: Rgba(red: 0.180, green: 0.204, blue: 0.259, alpha: 1.0),
  Ink.Guide: Rgba(red: 0.286, green: 0.322, blue: 0.400, alpha: 1.0),
  Ink.Amber: Rgba(red: 0.788, green: 0.506, blue: 0.000, alpha: 1.0),
  Ink.Teal: Rgba(red: 0.000, green: 0.408, blue: 0.588, alpha: 1.0),
  Ink.Rose: Rgba(red: 0.549, green: 0.267, blue: 0.420, alpha: 1.0),
  Ink.Lime: Rgba(red: 0.431, green: 0.439, blue: 0.000, alpha: 1.0),
  Ink.Orchid: Rgba(red: 0.745, green: 0.373, blue: 0.945, alpha: 1.0),
  Ink.Cyan: Rgba(red: 0.000, green: 0.655, blue: 0.647, alpha: 1.0),
  Ink.Violet: Rgba(red: 0.455, green: 0.110, blue: 0.851, alpha: 1.0),
] ## Map palette slot to colour: each hue picked at matched lightness and moderate,
  ## consistent saturation (rather than the mix of near-neon and washed-out shades a
  ## quick, unchecked choice tends to produce), and the whole set run through the
  ## dataviz skill's own palette validator against the three axis colours above as
  ## well as against each other -- CVD ΔE, normal-vision ΔE and lightness/chroma bounds
  ## all clear their floors against both, catching a first version of this palette
  ## (`Coral`, `Cyan` and `Lime` all sat close enough to `AxisX`/`AxisZ`/`AxisY` that a
  ## reader could mistake a categorical object for a world axis) that eyeballing alone
  ## had missed. `Coral` is retired as `Orchid` here: the hue "coral" names is claimed
  ## by `AxisX` itself, too close to separate from it at any lightness or chroma this
  ## validator accepts, so no hue there could keep both its old name and a safe margin.


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


proc addPlaneRing(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba; segments: int = SEGMENTS_CIRCLE_HORIZON
) =
  ## Append a plain circle of segments at `radius`, in the plane `axis_first` and
  ## `axis_second` span -- a finite plane's own rim, marking exactly how far it is
  ## drawn.
  for i in 0 ..< segments:
    let
      angle_a = (2.0*PI * float(i)) / float(segments)
      angle_b = (2.0*PI * float(i + 1)) / float(segments)
      point_a = center + radius*(cos(angle_a)*axis_first + sin(angle_a)*axis_second)
      point_b = center + radius*(cos(angle_b)*axis_first + sin(angle_b)*axis_second)
    meshes.addSegment(point_a, point_b, tint)


proc addPlaneFill(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba; segments: int = SEGMENTS_CIRCLE_HORIZON
) =
  ## Append a flat, uniformly translucent fan filling the same circle `addPlaneRing`
  ## outlines -- flat rather than faded toward the rim, since the rim itself already
  ## marks the boundary crisply; a plane's own tilt still reads through the fan's own
  ## foreshortened ellipse, and low, constant alpha keeps whatever sits behind it
  ## legible through every one of its triangles alike.
  for i in 0 ..< segments:
    let
      angle_a = (2.0*PI * float(i)) / float(segments)
      angle_b = (2.0*PI * float(i + 1)) / float(segments)
      point_a = center + radius*(cos(angle_a)*axis_first + sin(angle_a)*axis_second)
      point_b = center + radius*(cos(angle_b)*axis_first + sin(angle_b)*axis_second)
    meshes.addVertex(Primitive.Triangle, center, tint)
    meshes.addVertex(Primitive.Triangle, point_a, tint)
    meshes.addVertex(Primitive.Triangle, point_b, tint)


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


func alphaGridFade(radius, radius_fade_start, radius_end: float): float =
  ## Fall from full alpha at `radius_fade_start` to none at `radius_end` -- past the
  ## fade start, a grid line's own cells crowd into fewer and fewer screen pixels
  ## under perspective, reading as aliasing noise rather than as a reference; fading
  ## them out trades that noise for a clean horizon instead of fighting it.
  1.0 - clamp((radius - radius_fade_start) / (radius_end - radius_fade_start), 0.0, 1.0)


proc addGrid*(meshes: var MeshSet; extent: float) =
  ## Append reference grid on ground, so distance and direction stay judgeable, held
  ## at fixed cell size (`SIZE_CELL_GRID`) regardless of how far it reaches. Rather
  ## than drawing all the way out to `extent` at ever-fainter alpha, every line is cut
  ## off entirely at `radius_fade_end` -- well short of `extent` -- since past that
  ## point cells crowd into so few screen pixels under perspective that even a faint
  ## line still aliases; cutting the geometry off there removes the aliasing outright
  ## rather than just dimming it. Within `radius_fade_end`, each line is cut into
  ## `SEGMENTS_GRID_FADE` pieces, faded by each endpoint's own distance from the
  ## origin (`alphaGridFade`) from `radius_fade_start` so the cutoff itself is never
  ## visible as a hard edge.
  ##   Skips the two lines through the origin itself: those coincide exactly with the
  ##   x and y world axes, and would either fight them for the same depth or hide their
  ##   colour under plain grid grey, depending on which happened to draw last.
  let
    tint = Ink.Grid.colour
    radius_fade_end = FRACTION_GRID_FADE_END * extent
    radius_fade_start = FRACTION_GRID_FADE_START * extent
    count = int(ceil(radius_fade_end / SIZE_CELL_GRID))
  func tintAt(u, offset: float): Rgba =
    tint.fade(
      tint.alpha * alphaGridFade(norm(Direction(x: u, y: offset, z: 0)), radius_fade_start, radius_fade_end)
    )
  for i in -count .. count:
    if i == 0: continue
    let offset = float(i) * SIZE_CELL_GRID
    let reach = sqrt(max(0.0, radius_fade_end*radius_fade_end - offset*offset))
    for j in 0 ..< SEGMENTS_GRID_FADE:
      let
        a = reach * (2.0*float(j)/float(SEGMENTS_GRID_FADE) - 1.0)
        b = reach * (2.0*float(j + 1)/float(SEGMENTS_GRID_FADE) - 1.0)
      meshes.addVertex(Primitive.Line, Position(x: offset, y: a, z: 0), tintAt(a, offset))
      meshes.addVertex(Primitive.Line, Position(x: offset, y: b, z: 0), tintAt(b, offset))
      meshes.addVertex(Primitive.Line, Position(x: a, y: offset, z: 0), tintAt(a, offset))
      meshes.addVertex(Primitive.Line, Position(x: b, y: offset, z: 0), tintAt(b, offset))



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
  ## Append grade-2 object as segment about its support point, along its attitude,
  ## reaching `scale.extent_furniture` either side of it -- the same reach world
  ## furniture gets, so a line always reads as running out toward the horizon rather
  ## than stopping short, and a plane crossing it never looks like it swallows the
  ## rest of it -- or, at horizon, as a great circle around `scale.eye` -- the pencil
  ## of directions the line stands for, traced across the sky at `scale.radius_horizon`.
  ##   `progress` grows the segment, or the circle's own radius, out from nothing, and
  ##   fades it in alongside, so a freshly derived line visibly extends rather than
  ##   popping in.
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
  if anchor.isSome and axis.isSome:
    let
      extent = progress*scale.extent_furniture
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
  ## Append grade-3 object as a filled disc and rim about its support point, at a fixed
  ## radius (`EXTENT_PLANE`) independent of the camera, or, at horizon, as a dome
  ## filling the whole sky around `scale.eye` -- the unique universal object every
  ## plane at horizon stands for, regardless of which points produced it.
  ##   `progress` grows the disc, its rim, and the normal shaft out from nothing, and
  ##   fades every part of it in alongside.
  let
    anchor = positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isSome and axes.isSome:
    let
      extent = progress*EXTENT_PLANE_F
      (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)
      tint_progress = tint.fade(tint.alpha*progress)

    # Fill first, so plane reads as a surface rather than a bare outline; flat, since
    #   the rim drawn over it already marks the edge crisply on its own.
    meshes.addPlaneFill(anchor.get, axis_first, axis_second, extent, tint.fade(ALPHA_WASH*progress))
    meshes.addPlaneRing(anchor.get, axis_first, axis_second, extent, tint_progress)

    # Show normal as a bare shaft, no marker at its tip: tells plane apart from its own
    #   reflection without adding another point to the scene.
    meshes.addSegment(
      anchor.get, anchor.get + (0.25*extent)*axes.get.normal,
      Ink.Guide.colour.fade(ALPHA_GUIDE*progress),
    )
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
