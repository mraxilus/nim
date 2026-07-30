## Turn RGA objects into vertices OpenGL can draw.
##
## Finite objects are tessellated about their support point, i.e. point nearest origin:
##   Line becomes segment along its attitude: `DrawExtent.radius_horizon` backward from
##   support, the same radius forward from the eye instead, so the forward end lands
##   exactly on `eye + radius_horizon*axis` -- precisely where a horizon marker for this
##   line's own attitude would be drawn, with no gap between the two -- and dwarfs any
##   plane crossing it, since a plane holds a fixed, far smaller radius regardless of
##   camera distance.
##   Plane becomes a flat, translucent disc at a fixed radius (`EXTENT_PLANE`) plus a
##   rim marking its edge crisply, spanned by its own frame -- fixed rather than
##   camera-relative, so a plane holds one size in world units and does not appear to
##   grow or shrink as the camera dollies or orbits, exactly as a real fixed-size object
##   would.
##   Support point is what algebra computed, but no object marks it beyond its own
##   drawn shape (a point marker is that shape; a line's segment or a plane's disc
##   already passes through it): a plane's own normal is marked too, as a bare shaft
##   with no point at its tip, so orientation reads without adding another marker.
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
## instead, tied to the camera's own far clip distance rather than to orbit distance
## (`extentFurnitureFor`), so it reads as extending indefinitely into the distance
## regardless of how far the camera has dollied in or out to inspect finite content.
## Held distinct from `radius_horizon` deliberately: furniture has no attitude of its
## own to meet, so nothing ties its reach to the eye the way a line's does.
##
## Storage is fixed and owned by caller: meshes are cleared and refilled every frame.
##   Rebuilding beats tracking which object changed, while scene holds only tens of objects.
##   Cost is a few thousand vertices uploaded per frame, which is far below any budget.
##
##   |-----------|--------------|--------------------------------------|
##   | Primitive | OpenGL       | Carries                              |
##   |-----------|--------------|--------------------------------------|
##   | Triangle  | GL_TRIANGLES | Plane discs, whole-sky domes.        |
##   | Line      | GL_LINES     | Lines, plane rims and normal shafts,  |
##   |           |              | horizon circles, axes, ground grid.  |
##   | Point     | GL_POINTS    | Points, stars.                       |
##   |-----------|--------------|--------------------------------------|

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
  ALPHA_WASH_SKY* = 0.22'f32
    ## Set opacity of a horizon plane's own sky dome -- this one has no edge to fade
    ## toward and covers the whole sphere around the eye, so needs to read as a
    ## genuinely coloured sky rather than a barely-there hint at a glance, without
    ## overwhelming whatever furniture or objects the ordinary depth test still lets
    ## show through in front of it.
  ALPHA_GUIDE* = 0.75'f32
    ## Set opacity of a plane's own normal shaft, shown a touch less boldly than the
    ## plane's own rim so it reads as a construction aid, not as another competing mark.
  FRACTION_NORMAL_SHAFT* = 0.25
    ## Scale a plane's own radius by this to reach the length its normal shaft is drawn
    ## at -- long enough to read as an arrow rather than a stub, short enough not to
    ## compete with the disc's own rim for attention.
  FRACTION_DIMMED_ALPHA* = 0.55'f32
    ## Scale an already-constructed but non-focal object's own alpha by this, so it
    ## stays legible as background context -- shown rather than hidden outright -- while
    ## still clearly receding behind whatever the current step is showcasing.
  MUTE_DESATURATION* = 0.6'f32
    ## Blend a muted object's own colour this far toward its own grayscale equivalent,
    ## short of replacing it outright -- keeps a dulled hint of its own hue rather than
    ## converging every muted object to one indistinguishable grey.

static:
  doAssert SIZE_CELL_GRID > 0, &"Grid cell size must be positive; got `{SIZE_CELL_GRID}`."
  doAssert SEGMENTS_GRID_FADE >= 2, &"Grid fade needs at least 2 pieces; got `{SEGMENTS_GRID_FADE}`."
  doAssert FRACTION_NORMAL_SHAFT > 0,
    &"Normal shaft fraction must be positive; got `{FRACTION_NORMAL_SHAFT}`."
  doAssert FRACTION_DIMMED_ALPHA > 0 and FRACTION_DIMMED_ALPHA < 1.0,
    &"Dimmed alpha fraction must fall strictly between 0 and 1; got `{FRACTION_DIMMED_ALPHA}`."
  doAssert MUTE_DESATURATION > 0 and MUTE_DESATURATION <= 1.0,
    &"Mute desaturation must fall between 0 and 1; got `{MUTE_DESATURATION}`."



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
    Outline, ## Selection outline drawn around the one object currently highlighted --
      ## never cycled to automatically, only drawn where a caller names a specific
      ## slot as highlighted (see `renderer.drawOutline`).
    ## Categorical slots, spent by caller on telling one object from another.
    ##   Named by hue rather than by role, as caller alone knows what objects mean.
    ##   Grade is already legible from shape drawn, so colour is free to carry identity.
    ##   Declared in this exact order, not just for cycling: consecutive names sit far
    ##   apart on the colour wheel, so two objects added one after another -- the most
    ##   likely pair to end up compared or drawn near each other -- read as different
    ##   colours even under colour-vision deficiency, not just to typical vision.
    ##   Eight slots, not sixteen: a prior round widened this set to sixteen so a
    ##   longer run of objects would stay individually distinct before `inkCycled`
    ##   wraps, but packing that many hues into the narrow band that stays clear of
    ##   all three axis colours left every slot reading as a shade of teal, blue,
    ##   violet or magenta -- more colours, but not more *distinguishable* ones.
    ##   Cut back to eight so every one of the 28 possible pairings, not just the
    ##   ones `inkCycled` places back to back, clears a real separation floor -- see
    ##   `lut_ink_to_rgba`'s own comment for the exact floors and the trade this
    ##   made to hit them.
    Rose, Copper, Olive, Jade, Cobalt, Violet, Magenta, Cerise,

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
  Ink.Outline: Rgba(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
  Ink.Rose: Rgba(red: 0.690, green: 0.090, blue: 0.373, alpha: 1.0),
  Ink.Copper: Rgba(red: 0.812, green: 0.451, blue: 0.275, alpha: 1.0),
  Ink.Olive: Rgba(red: 0.341, green: 0.431, blue: 0.000, alpha: 1.0),
  Ink.Jade: Rgba(red: 0.133, green: 0.655, blue: 0.478, alpha: 1.0),
  Ink.Cobalt: Rgba(red: 0.027, green: 0.424, blue: 0.573, alpha: 1.0),
  Ink.Violet: Rgba(red: 0.396, green: 0.082, blue: 0.965, alpha: 1.0),
  Ink.Magenta: Rgba(red: 0.612, green: 0.000, blue: 0.722, alpha: 1.0),
  Ink.Cerise: Rgba(red: 0.949, green: 0.031, blue: 0.765, alpha: 1.0),
] ## Map palette slot to colour: eight hues, cut back down from sixteen (see the
  ## enum's own comment for why more slots made the palette read as less distinct,
  ## not more). Re-derived from scratch, not just trimmed to eight of the sixteen --
  ## the sixteen were only ever separated pairwise *adjacent* in declaration order,
  ## so keeping any eight of them would carry the same "only next-door pairs are
  ## checked" weakness this round set out to fix.
  ##   Screened through the dataviz skill's own validator (OKLCH lightness/chroma
  ## bounds, CVD ΔE, normal-vision ΔE, `--pairs all`) with axis-safety loosened from
  ## the sixteen-hue round's full separation floor to a smaller hue-distance-plus-ΔE
  ## gate (>= 20 degrees of hue and a lower ΔE floor from each of `AxisX`/`AxisY`/
  ## `AxisZ`): thin axis lines and filled categorical objects were never going to be
  ## mistaken for each other at the sixteen-hue round's own strictness, and holding
  ## that floor is what had squeezed every categorical hue into one narrow arc of the
  ## wheel in the first place. Freed from that, all 28 possible pairings among the
  ## eight -- not just the ones `inkCycled` places back to back -- clear the
  ## adjacent-pair-grade floor (CVD ΔE >= 8, normal-vision ΔE >= 15) except one, at
  ## CVD ΔE 6.6 (`Cobalt`/`Magenta`), inside the validator's own 6-8 legal-with-
  ## secondary-encoding band -- and every categorical object here already carries
  ## secondary encoding through its own shape and position, same as the panel's own
  ## legend. Worst normal-vision pair is 15.6, just clear of the 15.0 hard floor.
  ##   Also required >= 20 degrees of hue from every other slot, not just enough ΔE:
  ## two hues barely 2-9 degrees apart can still clear a ΔE floor on lightness or
  ## chroma alone while still reading, at a glance, as "two shades of the same
  ## colour" -- exactly the complaint that sent this palette back to eight in the
  ## first place. The eight that resulted spend one hue each on rose, copper, olive,
  ## jade, blue, violet, magenta and pink, spread across most of the wheel apart from
  ## the three axis-adjacent arcs.


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


func muted*(base: Rgba): Rgba =
  ## Dull colour partway toward its own grayscale equivalent, and cut its opacity to
  ## `FRACTION_DIMMED_ALPHA`, for an object that has already been constructed but is
  ## not part of the step currently in focus -- shown as background context, rather
  ## than hidden outright, so a construction's own history stays visible without
  ## competing with what is being showcased right now.
  ##   Blended toward its own luminance, not replaced by `Ink.Grid.colour` as an
  ##   earlier version did: fading every hue to one shared grey made a muted line
  ##   object indistinguishable from the ground grid itself, and lost the object's own
  ##   identity entirely rather than just dimming it.
  let luminance = 0.299'f32*base.red + 0.587'f32*base.green + 0.114'f32*base.blue
  Rgba(
    red: base.red + (luminance - base.red)*MUTE_DESATURATION,
    green: base.green + (luminance - base.green)*MUTE_DESATURATION,
    blue: base.blue + (luminance - base.blue)*MUTE_DESATURATION,
    alpha: base.alpha*FRACTION_DIMMED_ALPHA,
  )



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
  ## coefficients decides its shape here; only `radius` and `tint` do. Every direction
  ## the camera can actually see sky in should show it, including looking down across
  ## the ground grid toward the horizon, not only straight overhead -- an earlier
  ## version stopped this dome at the eye's own horizontal, reasoning a full sphere
  ## would bleed through the sparse ground grid's own gaps; reverted on explicit
  ## feedback that halving it cut off sky the camera genuinely can see. Occlusion
  ## against anything nearer is the ordinary depth test's job (still on for this
  ## translucent pass, only its write is off), same as any other drawn geometry --
  ## not something this proc's own shape needs to work around.
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
  ## Append grade-2 object as segment along its attitude: backward `scale.radius_horizon`
  ## from support, forward the same radius from the eye instead, so the forward end
  ## lands exactly on `scale.eye + scale.radius_horizon*axis` -- precisely where
  ## `addPoint` draws this same line's own attitude as a horizon marker, closing what
  ## would otherwise be a gap between a finite reach measured from support and an
  ## infinite one measured from the eye. The one straight segment between two ends each
  ## anchored a touch differently bends by an angle no wider than the support-to-eye
  ## separation over `scale.radius_horizon` itself -- imperceptible at the scale a
  ## radius reaching toward the camera's own far clip plane is drawn at, and the price
  ## of a line that visibly continues to exactly where its own attitude stands, rather
  ## than short of it.
  ##   Or, at horizon, as a great circle around `scale.eye` -- the pencil of directions
  ##   the line stands for, traced across the sky at `scale.radius_horizon`.
  ##   `progress` grows the segment, or the circle's own radius, out from nothing, and
  ##   fades it in alongside, so a freshly derived line visibly extends rather than
  ##   popping in.
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
  if anchor.isSome and axis.isSome:
    let
      reach = progress*scale.radius_horizon
      tint_progress = tint.fade(tint.alpha*progress)
    meshes.addSegment(anchor.get - reach*axis.get, scale.eye + reach*axis.get, tint_progress)
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
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float; scale: DrawExtent;
  anchor_override: Option[Position] = none(Position); outline: bool = false
): Placement =
  ## Append grade-3 object as a filled disc and rim about its support point, at a fixed
  ## radius (`EXTENT_PLANE`) independent of the camera, or, at horizon, as a dome
  ## filling the whole sky around `scale.eye` -- the unique universal object every
  ## plane at horizon stands for, regardless of which points produced it.
  ##   `anchor_override`, if given, centres the disc there instead -- some point the
  ##   plane's own construction fixed more specifically than its closest-to-origin
  ##   support does; see `scene.creationAnchor`. `frame`'s own axes do not depend on
  ##   which point anchors the plane (see `spanPerpendicular`'s own doc comment), so
  ##   only where the disc is drawn changes, never how it is oriented.
  ##   `progress` grows the disc, its rim, and the normal shaft out from nothing, and
  ##   fades every part of it in alongside.
  ##   `outline` draws only a solid rim, at the object's own ordinary radius, skipping
  ##   the fill and normal shaft -- for the "selection outline" pass, whose whole point
  ##   is to peek out past the object's own true-size redraw over it. Drawn at exactly
  ##   the same radius the ordinary rim below is (not a separately-tuned wider one): the
  ##   border comes entirely from `renderer.drawOutline`'s own wider line width for this
  ##   pass, the same mechanism a line object's outline uses, so the two rings stay
  ##   concentric by construction rather than by matching two independent constants
  ##   (an earlier version widened the radius itself here, which needed a world-space
  ##   offset tuned to roughly match the renderer's pixel-space one at some assumed
  ##   camera distance -- correct only there, visibly off-centre everywhere else).
  let
    anchor = if anchor_override.isSome: anchor_override else: positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isSome and axes.isSome:
    let
      (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)

    if outline:
      meshes.addPlaneRing(anchor.get, axis_first, axis_second, progress*EXTENT_PLANE_F, tint)
      return Placement.Finite

    let
      extent = progress*EXTENT_PLANE_F
      tint_progress = tint.fade(tint.alpha*progress)

    # Fill first, so plane reads as a surface rather than a bare outline; flat, since
    #   the rim drawn over it already marks the edge crisply on its own.
    meshes.addPlaneFill(anchor.get, axis_first, axis_second, extent, tint.fade(ALPHA_WASH*progress))
    meshes.addPlaneRing(anchor.get, axis_first, axis_second, extent, tint_progress)

    # Show normal as a bare shaft, no marker at its tip: tells plane apart from its own
    #   reflection without adding another point to the scene.
    meshes.addSegment(
      anchor.get, anchor.get + (FRACTION_NORMAL_SHAFT*extent)*axes.get.normal,
      Ink.Guide.colour.fade(ALPHA_GUIDE*progress),
    )
    return Placement.Finite

  meshes.addDome(scale.eye, progress*scale.radius_horizon, tint.fade(ALPHA_WASH_SKY*progress))
  Placement.Horizon


proc addObject*(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; scale: DrawExtent; progress: float = 1.0;
  anchor_override: Option[Position] = none(Position); outline: bool = false
): Placement =
  ## Append object, dispatching on geometry its grade stands for.
  ##   Empty where multivector carries no drawable geometry at all.
  ##   `progress` is how much of its appear animation the object has completed, from
  ##   `mesh.animationProgress`; defaults to fully appeared, for a caller with nothing
  ##   to animate against.
  ##   `anchor_override` centres a plane's own disc there instead of its own support;
  ##   ignored for a point or line, neither of which is drawn centred on anything else.
  ##   `outline` builds a plane's own solid rim alone, at its ordinary radius, instead
  ##   of its ordinary fill plus rim plus normal shaft (see `addPlane`'s own doc
  ##   comment); ignored for a point or line, whose own outline pass instead widens a
  ##   draw-time uniform (`renderer.SIZE_POINT_OUTLINE`/`WIDTH_LINE_OUTLINE`) the
  ##   geometry itself does not need to change for.
  let shape = shape(geometry)
  if shape.isNone: return Placement.Empty
  case shape.get
  of Shape.Point: meshes.addPoint(geometry, tint, progress, scale)
  of Shape.Line: meshes.addLine(geometry, tint, progress, scale)
  of Shape.Plane: meshes.addPlane(geometry, tint, progress, scale, anchor_override, outline)
