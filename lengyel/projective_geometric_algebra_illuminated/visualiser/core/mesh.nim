## Turn RGA objects into vertices a renderer can draw -- natively through OpenGL,
## in-browser through WebGL.
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
##   | Ribbon    | GL_TRIANGLES | Lines, plane rims and normal shafts,  |
##   |           |              | horizon circles, axes, ground grid.  |
##   | Point     | GL_POINTS    | Points, stars.                       |
##   |-----------|--------------|--------------------------------------|
##
## A line is drawn as a **ribbon** -- a quad sized to a width in screen pixels -- and never
## as `GL_LINES`, because a line width is a hint a target may ignore: most WebGL
## implementations clamp it to one pixel outright, and core-profile OpenGL only ever
## guaranteed one. See `addSegment`. Ribbons stay a primitive kind of their own rather than
## joining `Triangle` because the two draw differently: a ribbon writes depth, a plane's
## own translucent wash does not.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]

import ../../pga
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
  VERTICES_MAX* {.define: "visualiser.vertices_max".} = 49152
    ## Bound how many vertices one primitive's mesh holds, per frame.
    ##   Tripled when lines became ribbons: a segment that was two vertices is now six.
    ## The binding case is a scene filled to `scene.ITEMS_MAX` with planes, each drawing
    ## `SEGMENTS_CIRCLE_HORIZON` rim ribbons -- 64 x 96 x 6, or 36,864, which the old
    ## 16,384 would have asserted on. (It was 97 while every plane also drew a normal
    ## shaft; that shaft is gone, replaced by the orientation pulse `marker.nim` runs
    ## round a selected object's outline.) The suite fills a scene
    ## exactly that way rather than leaving the arithmetic to be trusted.
    ##   Costs `3 * VERTICES_MAX * sizeof(Vertex)` per `MeshSet` and there are two of them,
    ## so this is the largest single reservation this build makes; the diagnostics panel
    ## reports it alongside the rest rather than hiding it.
  ANIMATION_MILLISECONDS* {.define: "visualiser.animation_milliseconds".} = 350
    ## Set how long a freshly added object takes to grow and fade fully into view.
    ##   Held as milliseconds rather than seconds, as `.define` takes an integer.
  SIZE_POINT* = 9.0'f32
    ## Set diameter of drawn points, in pixels.
  WIDTH_LINE_FURNITURE* = 1.5'f32
    ## Set width of the ground grid and world axes, in pixels -- kept thinner than a
    ## scene line object's own width (`WIDTH_LINE_OBJECT`), so reference furniture
    ## recedes behind whatever the visualiser is actually showing.
  WIDTH_LINE_OBJECT* = 2.5'f32
    ## Set width of a scene line object, in pixels -- wider than furniture, so it reads
    ## as what the visualiser is actually showing.

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
  doAssert WIDTH_LINE_OBJECT > WIDTH_LINE_FURNITURE,
    &"Object line width must exceed furniture's; got `{WIDTH_LINE_OBJECT}` <= " &
    &"`{WIDTH_LINE_FURNITURE}`."


const EXTENT_PLANE_F* = float(EXTENT_PLANE)
  ## `EXTENT_PLANE` itself stays an integer default, since Nim's `.define` pragma
  ## cannot take a float literal; every use site, in this module and beyond, wants a
  ## float.

const ANIMATION_SECONDS* = float(ANIMATION_MILLISECONDS) / 1000.0
  ## Convert configured duration to the seconds `animationProgress` works in.

const
  SIZE_CELL_GRID* = 2.0
    ## Set the ground grid's own finest cell size, used whenever the grid's reach is
    ## short enough that `CELLS_GRID_HALF_MAX` cells cover it; see `sizeCellGridFor`.
  CELLS_GRID_HALF_MAX* = 24
    ## Bound how many cells the ground grid lays between the origin and the edge of its
    ## own reach, in each direction. The reach follows the camera's own far clip plane,
    ## which follows orbit distance, so a cell size fixed against it would multiply
    ## without limit as the camera pulls back -- past the vertex budget, and long past
    ## the point where cells crowd below one screen pixel and stop being a reference at
    ## all. Bounding the count instead is what keeps both finite.
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
  FRACTION_DIMMED_ALPHA* = 0.55'f32
    ## Scale an already-constructed but non-focal object's own alpha by this, so it
    ## stays legible as background context -- shown rather than hidden outright -- while
    ## still clearly receding behind whatever the current step is showcasing.
  MUTE_DESATURATION* = 0.6'f32
    ## Blend a muted object's own colour this far toward its own grayscale equivalent,
    ## short of replacing it outright -- keeps a dulled hint of its own hue rather than
    ## converging every muted object to one indistinguishable grey.
  MUTE_AXIS_TOWARD_GREY* = 0.22'f32
    ## Blend a world axis's own colour this far toward its own grayscale equivalent --
    ## much less than `MUTE_DESATURATION`'s 0.6, and with no alpha change (unlike
    ## `muted()`, a permanent palette entry, not a per-frame "not in focus" dim): enough
    ## to soften the axes so a bright red/green/blue trio doesn't compete with
    ## categorical object colours, not so much they stop reading as axes at a glance.

static:
  doAssert SIZE_CELL_GRID > 0, &"Grid cell size must be positive; got `{SIZE_CELL_GRID}`."
  doAssert CELLS_GRID_HALF_MAX > 0,
    &"Grid must lay at least one cell each way; got `{CELLS_GRID_HALF_MAX}`."
  doAssert SEGMENTS_GRID_FADE >= 2,
    &"Grid fade needs at least 2 pieces; got `{SEGMENTS_GRID_FADE}`."
  doAssert FRACTION_DIMMED_ALPHA > 0 and FRACTION_DIMMED_ALPHA < 1.0,
    &"Dimmed alpha fraction must fall strictly between 0 and 1; got `{FRACTION_DIMMED_ALPHA}`."
  doAssert MUTE_DESATURATION > 0 and MUTE_DESATURATION <= 1.0,
    &"Mute desaturation must fall between 0 and 1; got `{MUTE_DESATURATION}`."
  doAssert MUTE_AXIS_TOWARD_GREY > 0 and MUTE_AXIS_TOWARD_GREY <= 1.0,
    &"Axis mute fraction must fall between 0 and 1; got `{MUTE_AXIS_TOWARD_GREY}`."



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
    Invalid, ## Reserved for an object that is wrong rather than merely coloured -- a
      ## magenta no object may be assigned, so seeing it always means something is
      ## invalid. Structural for exactly that reason: a status colour a caller could
      ## also pick for an ordinary object would say nothing.
      ##   Worn by the rubber-band of a drag standing over a pair that makes nothing
      ## (`interaction.inkOfDrag`), which is the warning that arrives before the release
      ## rather than as a message after it. Never leaned on alone, as it must not be:
      ## magenta reads as blue under deuteranopia, which is where every assignable hue
      ## is furthest from it, so that drag simultaneously shows no ghost.
    ## Categorical slots, spent by caller on telling one object from another.
    ##   Named by hue rather than by role, as caller alone knows what objects mean.
    ##   Grade is already legible from shape drawn, so colour is free to carry identity.
    ##   Declared in this exact order, not just for cycling: consecutive names sit far
    ##   apart on the colour wheel, so two objects added one after another -- the most
    ##   likely pair to end up compared or drawn near each other -- read as different
    ##   colours even under colour-vision deficiency, not just to typical vision.
    ##   Five slots, not sixteen and no longer eight: a prior round widened this set
    ##   to sixteen so a longer run of objects would stay individually distinct before
    ##   `inkCycled` wraps, but packing that many hues into the narrow band that stays
    ##   clear of all three axis colours left every slot reading as a shade of teal,
    ##   blue, violet or magenta -- more colours, but not more *distinguishable* ones.
    ##   Reserving magenta for `Invalid` then cost three more: the whole pink-purple
    ##   arc has to stay clear of a status colour, and the axis hues already flank it
    ##   on both sides, so what is left is one arc of warm hues and one of cool. Adding
    ##   hues back inside that remainder was measured, not guessed, and reproduced the
    ##   sixteen-slot failure exactly -- see `lut_ink_to_rgba`'s own comment.
    Rose, Copper, Olive, Jade, Cobalt,

  Primitive* {.pure.} = enum ## Name kind of OpenGL primitive vertices are assembled into.
    ## Every kind is a triangle or a point on the wire; `Ribbon` is a *line drawn as*
    ## triangles -- see `addSegment` -- kept a kind of its own rather than folded into
    ## `Triangle` because the two draw differently: a ribbon writes depth, a plane's own
    ## translucent wash does not.
    Triangle, Ribbon, Point

  Rgba* = object ## Hold colour channels, in 0 .. 1.
    red*, green*, blue*, alpha*: float32

  Vertex* = object ## Hold one vertex exactly as it is uploaded.
    x*, y*, z*: float32
    red*, green*, blue*, alpha*: float32

  Mesh* = object ## Hold vertices of one primitive kind, in storage fixed at compile time.
    vertices*: array[VERTICES_MAX, Vertex]
    count_vertices*: int
    index_overlay*: Option[int] ## Where the overlay run begins, if this mesh has one.
      ## Vertices below it are drawn against the depth buffer as usual; the rest are drawn
      ## after them with the test off, so they land over whatever is already there.
      ## `markOverlay` is what sets it, and each render path draws the two runs as two
      ## calls -- see `renderer.drawPrimitive`. None where nothing asked to be drawn over,
      ## which is every furniture mesh and every frame with nothing selected; an index of
      ## zero says the opposite and means the whole mesh is the overlay.
      ##   A watermark rather than a second `MeshSet`, because a set reserves `VERTICES_MAX`
      ## per primitive up front and a third of them is the largest reservation this build
      ## makes again, for a run that is usually one object. Order already decides what
      ## these buckets look like (see `visualiser.assembleMeshes`), so an index into the
      ## order costs nothing and states the same thing.

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
    # The four below are what a *ribbon* needs to hold a constant width on screen; see
    #   `worldPerPixelAt`. They are the camera's own facts rather than a `Camera`, because
    #   `camera` imports this module and cannot be imported back.
    forward*: Direction ## Camera's own sight axis, depth is measured along.
    tangent_half_view*: float ## Tangent of half the vertical field of view.
    height_pixels*: int ## Framebuffer height, which the vertical field of view spans.
    depth_near*: float ## Camera's own near clip distance, depth is clamped at. Nothing
      ## nearer is drawn, so nothing needs a width measured nearer -- and without the
      ## clamp a segment running past the eye reads a negative depth and turns its own
      ## ribbon inside out.



#[ Camera-Relative Scale ]#

func radiansPerPixel*(scale: DrawExtent): float =
  ## Measure how much of the camera's own angular field one pixel of height spans.
  ##   The small-angle reading of `worldPerPixelAt` at unit depth, and the right unit for
  ##   anything placed by *direction* rather than by position -- horizon geometry is drawn
  ##   on a sphere about the eye, where a pixel is an angle and not a distance.
  2.0*scale.tangent_half_view/float(max(scale.height_pixels, 1))


func worldPerPixelAt*(place: Position; scale: DrawExtent): float =
  ## Measure how much world distance one screen pixel spans at `place`'s own depth.
  ##   What turns a width or a clearance stated in pixels into the world offset it has to
  ##   use, wherever it is anchored in space rather than on screen. Every ribbon's own
  ##   half-width comes through here, and so does every marker's clearance.
  ##   Depth along the sight axis, not distance from the eye: perspective divides by the
  ##   former, and the two differ by the cosine of how far off-axis the point sits -- over
  ##   a percent even near the middle of the frame, which is a visible fraction of a gap
  ##   this tight.
  ##   Clamped at the near plane. Depth goes negative behind the eye, and a negative
  ##   half-width folds a ribbon over on itself; nothing nearer than the near plane is
  ##   drawn anyway, so there is no width there to get right.
  let depth = max(dot(place - scale.eye, scale.forward), scale.depth_near)
  2.0*depth*scale.tangent_half_view/float(max(scale.height_pixels, 1))


func radiusHorizonFor*(distance_far: float): float =
  ## Compute how far from the eye horizon geometry sits this frame, given the camera's
  ## own far clip distance: an object standing for "infinitely far away" should sit
  ## near the renderer's own outer depth limit regardless of how far the camera has
  ## dollied in or out to view finite content.
  distance_far * FRACTION_HORIZON


func sizeCellGridFor*(radius_fade_end: float): float =
  ## Choose the ground grid's own cell size for a given reach: `SIZE_CELL_GRID`, doubled
  ## as many times as it takes to lay no more than `CELLS_GRID_HALF_MAX` cells across it.
  ##   Doubling rather than dividing the reach evenly, so a cell size only ever steps
  ## between fixed multiples of the finest one as the camera dollies. Every coarser grid
  ## then has its lines exactly on a subset of the finer grid's, and the change reads as
  ## alternate lines dropping out rather than as the whole grid sliding to new positions.
  result = SIZE_CELL_GRID
  while radius_fade_end/result > float(CELLS_GRID_HALF_MAX): result *= 2.0


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
  # Each blended toward its own luminance-grey by `MUTE_AXIS_TOWARD_GREY`, using the
  #   same 0.299/0.587/0.114 luminance weights `muted()` uses below -- this table is a
  #   plain compile-time literal, not a runtime call, so the blend is baked in rather
  #   than computed through `muted()` itself (whose alpha cut this must not inherit).
  Ink.AxisX: Rgba(red: 0.757, green: 0.279, blue: 0.279, alpha: 1.0),
  Ink.AxisY: Rgba(red: 0.360, green: 0.736, blue: 0.360, alpha: 1.0),
  Ink.AxisZ: Rgba(red: 0.338, green: 0.481, blue: 0.830, alpha: 1.0),
  Ink.Grid: Rgba(red: 0.180, green: 0.204, blue: 0.259, alpha: 1.0),
  Ink.Guide: Rgba(red: 0.286, green: 0.322, blue: 0.400, alpha: 1.0),
  Ink.Outline: Rgba(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
  Ink.Invalid: Rgba(red: 0.612, green: 0.000, blue: 0.722, alpha: 1.0),
  Ink.Rose: Rgba(red: 0.690, green: 0.090, blue: 0.373, alpha: 1.0),
  Ink.Copper: Rgba(red: 0.812, green: 0.451, blue: 0.275, alpha: 1.0),
  Ink.Olive: Rgba(red: 0.341, green: 0.431, blue: 0.000, alpha: 1.0),
  Ink.Jade: Rgba(red: 0.133, green: 0.655, blue: 0.478, alpha: 1.0),
  Ink.Cobalt: Rgba(red: 0.357, green: 0.565, blue: 0.780, alpha: 1.0),
] ## Map palette slot to colour: five assignable hues, plus the magenta `Invalid` is
  ## held out of that run entirely (see the enum's own comment for why the run shrank).
  ##   Screened through the dataviz skill's own validator (OKLCH lightness/chroma
  ## bounds, CVD deltaE, normal-vision deltaE, `--pairs all`) rather than by eye, with
  ## axis-safety as a hue-distance-plus-deltaE gate (>= 20 degrees of hue and a lower
  ## deltaE floor from each of `AxisX`/`AxisY`/`AxisZ`) rather than the full categorical
  ## floor: thin axis lines and filled objects were never going to be mistaken for each
  ## other, and holding that floor is what had squeezed every hue into one narrow arc.
  ##   All ten pairings among the five clear the adjacent-pair floor (normal-vision
  ## deltaE >= 15) except `Jade`/`Copper` at CVD deltaE 7.6, inside the validator's own
  ## 6-8 legal-with-secondary-encoding band -- every object here already carries its own
  ## shape and position as secondary encoding. `Rose` sits at contrast 2.78 against the
  ## backdrop, under the 3:1 the validator wants, which its own always-present row label
  ## in both panels is the required relief for.
  ##
  ## **Every assignable hue is also held clear of `Invalid`**, which is the point of the
  ## run being this short. Worst separation from it is `Rose` at CVD deltaE 15.2, then
  ## `Cobalt` at 14.4; the rest are 23 or better.
  ##   `Cobalt` is re-derived rather than kept: at its old value it sat at CVD deltaE 6.6
  ## from magenta -- fine when magenta was just another categorical peer, and the reason
  ## the pair was documented as this palette's one exception, but not fine once magenta
  ## means "this object is wrong". Blue and magenta converge under deuteranopia even
  ## though 88 degrees of hue separate them, so hue distance alone would have missed it;
  ## lightening `Cobalt` and pushing it bluer is what opens the pair back up.
  ##   Do not fill the remaining arc back up to eight. That was tried and measured: a
  ## seven-hue set spread across what is left put `Olive` and a new yellow-green at CVD
  ## deltaE 0.4, and two blues at normal-vision deltaE 5.6. There is only so much wheel
  ## outside the axis arcs and the reserved one, and five is what fits it honestly.


const COUNT_INK* = ord(Ink.high) + 1
  ## Count palette slots, structural and categorical alike.


const INK_CATEGORICAL_FIRST* = Ink.Rose
  ## Name where the categorical run begins. Everything declared before it is structural,
  ## spent on the drawing's own furniture, and offering any of those as an object's colour
  ## would let an object wear the backdrop, a world axis, or the selection outline -- three
  ## ways to make it invisible or to make it read as something it is not.


const COUNT_INK_CATEGORICAL* = ord(Ink.high) - ord(INK_CATEGORICAL_FIRST) + 1
  ## Count the slots a colour picker may offer.
  ##   Callers walk the run as one contiguous block, so `Ink`'s own declaration order is
  ##   load-bearing here, not just cosmetic: every categorical slot must follow every
  ##   structural one. The `static` assertion below is what enforces it -- a structural
  ##   slot appended after `Cobalt` changes this count and fails the build.

static:
  doAssert COUNT_INK_CATEGORICAL == 5,
    "Ink's categorical slots must stay one contiguous run ending at Ink.high; a slot " &
    "added or removed after Ink.Rose changes what a colour picker offers."


func inkCategorical*(index: int): Ink = Ink(ord(INK_CATEGORICAL_FIRST) + index)
  ## Read the palette slot at a position within the categorical run.


func categoricalIndex*(ink: Ink): int = ord(ink) - ord(INK_CATEGORICAL_FIRST)
  ## Read a palette slot's own position within the categorical run. Negative for a
  ## structural slot, which has no position there.


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



#[ Appear Animation ]#

func easeOutCubic*(t: float): float =
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
    meshes[primitive].index_overlay = none(int)


proc markOverlay*(meshes: var MeshSet) =
  ## Say that everything appended from here on is drawn over what came before it.
  ##   Called once, between the ordinary objects and the selected ones; see
  ##   `Mesh.count_vertices_tested`. Calling it twice would move the boundary rather than
  ##   add a second one, which is why the assembly order and not this decides what is
  ##   over what.
  for primitive in Primitive:
    meshes[primitive].index_overlay = some(meshes[primitive].count_vertices)


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


func directionAcross*(tail, head, eye: Position): Option[Direction] =
  ## Resolve which way to step off a segment so its own two edges land either side of it
  ## on screen.
  ##   Joining the segment's line with the eye gives the one plane containing both; that
  ##   plane's normal is perpendicular to the line and to every sight ray reaching it,
  ##   which is exactly the direction that shows as sideways from where the camera stands.
  ##   The same rule `marker.directionAcross` flanks a line's rails by, stated here over
  ##   two endpoints rather than over a line's own multivector -- `marker` imports this
  ##   module, so it delegates here rather than the two carrying a derivation each.
  ##   None where the eye lies on the segment's own line, or where the segment has no
  ##   length: neither has a side to step off toward.
  directionNormal(toMultivector(tail) ∧ toMultivector(head) ∧ toMultivector(eye))


proc addSegment*(
  meshes: var MeshSet; tail, head: Position; tint_tail, tint_head: Rgba; width: float32;
  scale: DrawExtent
) =
  ## Append a line segment joining two positions, as a **ribbon**: a world-space quad
  ## `width` pixels across, wound as two triangles.
  ##   A quad rather than a `GL_LINES` pair because a line width is a *hint* both this
  ## project's targets are entitled to ignore -- most WebGL implementations clamp it to
  ## one pixel outright, and core-profile OpenGL only ever guaranteed one. Drawing the
  ## width as geometry is the only way both builds show the same thing.
  ##   Each end is offset by half a width of *its own* world-per-pixel, so the ribbon
  ## narrows with distance exactly as the line it draws does, and two parallel lines keep
  ## their shared vanishing point. A constant world offset would hold the far end open;
  ## a constant screen offset would not converge at all.
  ##   Silently appends nothing where the segment has no side to step off toward -- zero
  ## length, or an eye lying on its own line, where the ribbon is edge-on and covers no
  ## pixels anyway.
  ##   Takes a tint per end, since the ground grid fades along its own lines; the pair of
  ## corners at one end share that end's own tint, so the fade runs along the ribbon
  ## exactly as it ran along the line.
  ##   **Clipped to the near plane first.** A world offset proportional to depth gives a
  ## constant screen width only while the quad's own straight edges interpolate a depth
  ## that is itself linear along the segment -- which stops being true the moment one end
  ## stands behind the eye and its depth has to be clamped. Left unclipped, a world axis
  ## running from far behind the camera to far in front of it drew twenty pixels wide
  ## near the origin. Clipping restores the property rather than patching the symptom:
  ## both ends then have real, positive depth, and the interpolation between them is
  ## exact. Found by rendering a frame and looking at it.
  let across = directionAcross(tail, head, scale.eye)
  if across.isNone: return
  let
    depth_tail = dot(tail - scale.eye, scale.forward)
    depth_head = dot(head - scale.eye, scale.forward)
  if depth_tail < scale.depth_near and depth_head < scale.depth_near: return

  func blend(first, second: Rgba; fraction: float): Rgba =
    ## Read the colour a fraction of the way along, for an end the clip has moved.
    let (a, b) = (1.0 - fraction, fraction)
    Rgba(
      red: float32(a*float(first.red) + b*float(second.red)),
      green: float32(a*float(first.green) + b*float(second.green)),
      blue: float32(a*float(first.blue) + b*float(second.blue)),
      alpha: float32(a*float(first.alpha) + b*float(second.alpha)),
    )

  var
    (near, far) = (tail, head)
    (tint_near, tint_far) = (tint_tail, tint_head)
  if depth_tail < scale.depth_near:
    let fraction = (scale.depth_near - depth_tail)/(depth_head - depth_tail)
    near = tail + fraction*(head - tail)
    tint_near = blend(tint_tail, tint_head, fraction)
  elif depth_head < scale.depth_near:
    let fraction = (scale.depth_near - depth_head)/(depth_tail - depth_head)
    far = head + fraction*(tail - head)
    tint_far = blend(tint_head, tint_tail, fraction)

  let
    offset_near = 0.5*float(width)*worldPerPixelAt(near, scale)*across.get
    offset_far = 0.5*float(width)*worldPerPixelAt(far, scale)*across.get
    corners = [
      near - offset_near, far - offset_far, far + offset_far, near + offset_near,
    ]
    tints = [tint_near, tint_far, tint_far, tint_near]
  for index in [0, 1, 2, 0, 2, 3]:
    meshes.addVertex(Primitive.Ribbon, corners[index], tints[index])


proc addSegment*(
  meshes: var MeshSet; tail, head: Position; tint: Rgba; width: float32;
  scale: DrawExtent
) =
  ## Append a ribbon of one tint end to end; see the two-tint form above for what it draws.
  meshes.addSegment(tail, head, tint, tint, width, scale)


proc addQuad*(meshes: var MeshSet; corners: array[4, Position]; tint: Rgba) =
  ## Append filled quadrilateral, wound as two triangles.
  for index in [0, 1, 2, 0, 2, 3]:
    meshes.addVertex(Primitive.Triangle, corners[index], tint)


proc addPlaneRing(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba; scale: DrawExtent; segments: int = SEGMENTS_CIRCLE_HORIZON
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
    meshes.addSegment(point_a, point_b, tint, WIDTH_LINE_OBJECT, scale)


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
  radius: float; tint: Rgba; scale: DrawExtent; segments: int = SEGMENTS_CIRCLE_HORIZON
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
    meshes.addSegment(point_a, point_b, tint, WIDTH_LINE_OBJECT, scale)


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

proc addAxes*(meshes: var MeshSet; extent: float; scale: DrawExtent) =
  ## Append world axes through origin, each in the standard convention: x red, y green,
  ## z blue, so orientation reads at a glance regardless of where the camera stands.
  const AXES_WORLD = [
    (Direction(x: 1, y: 0, z: 0), Ink.AxisX),
    (Direction(x: 0, y: 1, z: 0), Ink.AxisY),
    (Direction(x: 0, y: 0, z: 1), Ink.AxisZ),
  ]
  for (axis, ink) in AXES_WORLD:
    meshes.addSegment(
      ORIGIN_WORLD - extent*axis, ORIGIN_WORLD + extent*axis, ink.colour,
      WIDTH_LINE_FURNITURE, scale,
    )


func alphaGridFade(radius, radius_fade_start, radius_end: float): float =
  ## Fall from full alpha at `radius_fade_start` to none at `radius_end` -- past the
  ## fade start, a grid line's own cells crowd into fewer and fewer screen pixels
  ## under perspective, reading as aliasing noise rather than as a reference; fading
  ## them out trades that noise for a clean horizon instead of fighting it.
  1.0 - clamp((radius - radius_fade_start) / (radius_end - radius_fade_start), 0.0, 1.0)


proc addGrid*(meshes: var MeshSet; extent: float; scale: DrawExtent) =
  ## Append reference grid on ground, so distance and direction stay judgeable, at the
  ## cell size `sizeCellGridFor` picks for how far it reaches. Rather
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
    size_cell = sizeCellGridFor(radius_fade_end)
    count = int(ceil(radius_fade_end / size_cell))
  func tintAt(u, offset: float): Rgba =
    tint.fade(
      tint.alpha * alphaGridFade(
        norm(Direction(x: u, y: offset, z: 0)), radius_fade_start, radius_fade_end,
      )
    )
  for i in -count .. count:
    if i == 0: continue
    let offset = float(i) * size_cell
    let reach = sqrt(max(0.0, radius_fade_end*radius_fade_end - offset*offset))
    for j in 0 ..< SEGMENTS_GRID_FADE:
      let
        a = reach * (2.0*float(j)/float(SEGMENTS_GRID_FADE) - 1.0)
        b = reach * (2.0*float(j + 1)/float(SEGMENTS_GRID_FADE) - 1.0)
      meshes.addSegment(
        Position(x: offset, y: a, z: 0), Position(x: offset, y: b, z: 0),
        tintAt(a, offset), tintAt(b, offset), WIDTH_LINE_FURNITURE, scale,
      )
      meshes.addSegment(
        Position(x: a, y: offset, z: 0), Position(x: b, y: offset, z: 0),
        tintAt(a, offset), tintAt(b, offset), WIDTH_LINE_FURNITURE, scale,
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
  ## Append grade-2 object as two segments meeting on the line at its support, each
  ## running out to one of the line's own two vanishing points, `scale.eye` plus and
  ## minus `scale.radius_horizon` along its attitude. The forward one is exactly where
  ## `addPoint` draws this line's attitude as a horizon marker, so the drawn line
  ## reaches its own attitude with no gap.
  ##   Two segments rather than one because a vanishing point is a property of the
  ## *eye*, not of the line: an end anchored a fixed reach from the support instead
  ## stops short of it by roughly the eye-to-line separation over that reach, which is
  ## a visible gap as soon as the line's support is not close to the camera. Anchoring
  ## both ends to the eye is what closes it at both, and a single segment cannot -- one
  ## running eye-to-eye passes through the eye and projects to a point.
  ##   Each segment has one end on the true line and one at `eye ± radius*axis`, so both
  ## lie in the plane through the eye containing the line. That plane projects to a
  ## single screen line, so the pair draws exactly over the true line's own projection
  ## however far the far ends sit from it in world space -- verified as zero screen skew
  ## to floating-point precision, not argued. What it costs is depth: the far ends are
  ## displaced along the view ray, so occlusion against other objects is approximate
  ## there. Rebuilt every frame against the current eye, so this holds as the camera
  ## orbits.
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
    meshes.addSegment(
      anchor.get, scale.eye + reach*axis.get, tint_progress, WIDTH_LINE_OBJECT, scale
    )
    meshes.addSegment(
      anchor.get, scale.eye - reach*axis.get, tint_progress, WIDTH_LINE_OBJECT, scale
    )
    return Placement.Finite

  let normal = directionNormalHorizon(geometry)
  if normal.isNone: return Placement.Empty
  let axes = spanPerpendicular(ORIGIN_WORLD, normal.get)
  if axes.isNone: return Placement.Empty
  let (axis_first, axis_second) = axes.get
  meshes.addGreatCircle(
    scale.eye, axis_first, axis_second, progress*scale.radius_horizon,
    tint.fade(tint.alpha*progress), scale,
  )
  Placement.Horizon


proc addPlane(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float; scale: DrawExtent;
  anchor_override: Option[Position] = none(Position)
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
  ##   `progress` grows the disc and its rim out from nothing, and fades both in
  ##   alongside.
  ##   **No normal is drawn.** A bare shaft out of the anchor used to mark one, which told
  ##   a plane apart from its own reflection -- but it did so on *every* plane in the
  ##   scene, permanently, to answer a question a reader asks about one object at a time.
  ##   Orientation now rides on the selection marker instead, as the direction a pulse
  ##   travels round it; see `marker.markerFor`.
  let
    anchor = if anchor_override.isSome: anchor_override else: positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isSome and axes.isSome:
    let
      (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)
      extent = progress*EXTENT_PLANE_F
      tint_progress = tint.fade(tint.alpha*progress)

    # Fill first, so plane reads as a surface rather than a bare outline; flat, since
    #   the rim drawn over it already marks the edge crisply on its own.
    meshes.addPlaneFill(anchor.get, axis_first, axis_second, extent, tint.fade(ALPHA_WASH*progress))
    meshes.addPlaneRing(anchor.get, axis_first, axis_second, extent, tint_progress, scale)

    return Placement.Finite

  meshes.addDome(scale.eye, progress*scale.radius_horizon, tint.fade(ALPHA_WASH_SKY*progress))
  Placement.Horizon


proc addObject*(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; scale: DrawExtent; progress: float = 1.0;
  anchor_override: Option[Position] = none(Position)
): Placement =
  ## Append object, dispatching on geometry its grade stands for.
  ##   Empty where multivector carries no drawable geometry at all.
  ##   `progress` is how much of its appear animation the object has completed, from
  ##   `mesh.animationProgress`; defaults to fully appeared, for a caller with nothing
  ##   to animate against.
  ##   `anchor_override` centres a plane's own disc there instead of its own support;
  ##   ignored for a point or line, neither of which is drawn centred on anything else.
  let shape = shape(geometry)
  if shape.isNone: return Placement.Empty
  case shape.get
  of Shape.Point: meshes.addPoint(geometry, tint, progress, scale)
  of Shape.Line: meshes.addLine(geometry, tint, progress, scale)
  of Shape.Plane: meshes.addPlane(geometry, tint, progress, scale, anchor_override)
