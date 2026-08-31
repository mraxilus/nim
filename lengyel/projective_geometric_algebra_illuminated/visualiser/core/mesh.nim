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
## It is drawn as **fog about the eye** (`fogFurnitureFor`): solid nearby, faded to
## nothing at the reach above, and laid wherever the camera has flown to rather than
## only around the world origin. A finite *line object* still reaches that same extent
## from its own support, since it is content and not reference.
##
## Storage is fixed and owned by caller: meshes are cleared and refilled every frame.
##   Rebuilding beats tracking which object changed, while scene holds only tens of objects.
##   Cost is a few thousand vertices uploaded per frame, which is far below any budget.
##
##   |--------|-----------------------|----------------------------------------------|
##   | Kind   | Crosses the wire as   | Carries                                      |
##   |--------|-----------------------|----------------------------------------------|
##   | Ribbon | `RibbonRecord` x1     | Lines, plane rims, horizon circles, axes,    |
##   |        |                       | ground grid.                                 |
##   | Disc   | `DiscRecord` x1       | A finite plane's translucent fill.           |
##   | Dome   | `DomeRecord` x1       | A horizon plane's whole-sky wash.            |
##   | Point  | `Vertex` per point    | Points, stars.                               |
##   |--------|-----------------------|----------------------------------------------|
##
## Every kind but the point is one compact record per shape, widened into triangles by
## its own vertex shader; each record type's doc comment states the expansion, and an
## `expand*` reference proc beside it is what the suite pins and the shaders are checked
## against.
##
## A line is drawn as a **ribbon** -- a quad sized to a width in screen pixels -- and never
## as `GL_LINES`, because a line width is a hint a target may ignore: most WebGL
## implementations clamp it to one pixel outright, and core-profile OpenGL only ever
## guaranteed one. See `addSegment`. Ribbons draw apart from the washes because the two
## differ in state: a ribbon writes depth, a plane's own translucent wash does not.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]

import ./euclid



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
  FRACTION_GRID_FADE_START* = 0.06
    ## Hold ground grid lines at full alpha out to this fraction of their own reach,
    ## fading the remainder out toward `FRACTION_GRID_FADE_END` -- past that point,
    ## cells crowd into fewer and fewer screen pixels under perspective, reading as
    ## aliasing noise rather than as a reference.
    ##   Doubled from 0.03 when the fade moved from the world origin to the eye
    ##   (`fogFurnitureFor`), and the two are not comparable: a core measured about the
    ##   origin covered the content, while the eye stands a whole orbit distance away from
    ##   it, so the same fraction left the ground under what the reader was looking at
    ##   already fading. 0.06 of the reach is 1.14 orbit distances, which puts the target
    ##   inside the solid core with room to spare. **Measured by rendering it**: at 0.03
    ##   the ground at the target was faint enough to read as absent.
  FRACTION_GRID_FADE_END* = 0.20
    ## Cut ground grid lines off entirely at this fraction of their own reach, well
    ## short of it -- a faint line still aliases under perspective, so the fix is to
    ## stop drawing it there, not just to dim it further.
    ##   Raised from 0.12 with the move to fog about the eye, for the same reason
    ##   `FRACTION_GRID_FADE_START` was: a radius measured from the origin reached that
    ##   far *past* the content, while the same radius measured from the eye is spent
    ##   getting to it. 0.20 of the reach is 3.8 orbit distances, which puts the fog's
    ##   edge about 2.8 distances beyond what the camera is looking at -- close to the
    ##   ground the halo used to cover, and still a fifth of the far clip plane.
  RIBBONS_MAX* {.define: "visualiser.ribbons_max".} = 131072
    ## Bound how many ribbon segments one frame holds.
    ##   The binding case is a scene filled with planes, each drawing
    ## `SEGMENTS_CIRCLE_HORIZON` rim segments: at `scene.ITEMS_MAX` = 1,024 that is
    ## 1,024 x 96 = 98,304, with the same third of headroom. One record here is what six
    ## vertices were before the widening moved to the vertex shader.
    ##   **This is the cap with a price.** 131,072 records at sixteen floats is 8.4 MB, and
    ## `visualiser.BYTES_MEMORY_TOTAL` counts two mesh sets, so it is about 17 MB of the
    ## binary's reported reservation. That is the cost of being able to hold a thousand
    ## objects and have any of them be a plane.
    ##   `scene.nim` carries a `static` check tying this to `ITEMS_MAX`, because this module
    ## cannot see that constant: `scene` imports `tessellate` imports `mesh`, never back.
    ## Overflow here is a `doAssert`, so an undersized cap is a dead page rather than a
    ## dropped triangle -- which is exactly what raising `ITEMS_MAX` from 64 would have
    ## caused, on all four caps at once, had the check not been added with it.
  VERTICES_MAX* {.define: "visualiser.vertices_max".} = 2048
    ## Bound how many vertices the point mesh holds, per frame.
    ##   Points are all that is left in vertex form: lines became ribbon records when the
    ## widening moved to the vertex shader, and plane fills and sky domes became disc and
    ## dome records when their fans followed it -- each of those is bounded by its own
    ## record cap below. The binding case here is a scene filled to `scene.ITEMS_MAX`
    ## with points, every one selected and so drawn twice: 2,048 at `ITEMS_MAX` = 1,024.
  DISCS_MAX* {.define: "visualiser.discs_max".} = 2176
    ## Bound how many disc records one frame holds.
    ##   The binding case is a scene filled to `scene.ITEMS_MAX` with finite planes,
    ## every one selected and so drawn twice, plus a ghost -- 2,049, with headroom. One
    ## record here is what a `3 * SEGMENTS_CIRCLE_HORIZON`-vertex fan cost before the
    ## fan moved to the vertex shader.
  DOMES_MAX* {.define: "visualiser.domes_max".} = 2176
    ## Bound how many dome records one frame holds, by the same worst case as
    ## `DISCS_MAX` with every plane at horizon instead.
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
  SIZE_CELL_GRID* = 10.0
    ## Set the ground grid's own cell size, in world units, at every reach a reader works
    ## at. **One size**: the grid used to step its cell with its own reach, doubling from a
    ## two-unit cell, which meant the ground silently re-scaled under a reader as they
    ## dollied and no distance read off it was comparable with the last one. A fixed cell
    ## is a ruler; a stepping one is not.
    ##   `sizeCellGridFor` steps it by decades past 1,200 units of ground reach, where the
    ##   alternative to stepping is no ground at all rather than a finer grid; see there.
    ##   Ten rather than a hundred, **measured by rendering both**: the reach follows orbit
    ##   distance (`fogFurnitureFor`), and at the opening placement -- distance 19, a reach
    ##   near 72 units -- a hundred-unit cell put at most one line in view and usually
    ##   none, leaving the ground reading as empty. Ten lays a legible lattice there.
  CELLS_GRID_HALF_MAX* = 120
    ## Bound how many cells the ground grid lays between the camera and the edge of its
    ## own reach, in each direction. The reach follows the camera's own far clip plane,
    ## which follows orbit distance, so a reach left unbounded would multiply the lines
    ## drawn without limit as the camera pulls back, straight past the vertex budget.
    ##   **`sizeCellGridFor` spends this on the cell, not on the reach**, and that is the
    ##   second thing this number has bounded. Cutting the *reach* against it meant a
    ##   camera further out than 1,200 units had the ground stop reaching what it was
    ##   looking at, and past twice that saw no ground at all -- a black void with no
    ##   reference of any kind, which is what a reader zooming out actually met. Stepping
    ##   the cell instead keeps the same count of lines, drawn across the reach the camera
    ##   has rather than across the first 1,200 units of it.
    ##   It was 24 while the cell was a hundred; dropping the cell to ten without raising
    ##   this left the grid a patch floating in the near field at an orbit distance of 300,
    ##   with no ground at all under the objects being looked at. Rendered, not reasoned.
    ##   Costs about 23,000 ribbon vertices where it binds, against `VERTICES_MAX`; world
    ##   furniture keeps a mesh set of its own, so that is the whole of what it competes with.
  ALPHA_GRID* = 0.75'f32
    ## Scale the ground grid's own opacity by this, on top of whatever `alphaGridFade`
    ## leaves it. Width alone (`WIDTH_LINE_FURNITURE` against `WIDTH_LINE_OBJECT`) was not
    ## carrying the difference: a full-strength grid line and a drawn line differ by one
    ## pixel of width, and readers were reading the ruled ground as content.
    ##   A quarter off rather than a half: the grid's own colour already sits close to the
    ##   backdrop, so opacity spends fast. 0.55 was tried first and rendered a ground that
    ##   read as absent rather than as recessive.
    ##   Applied where the grid is built rather than to `Ink.Grid` itself, because that
    ##   palette entry is also `INK_POOL_FREE` -- the colour a scene object takes when the
    ##   pool has run dry -- and dimming the entry would make that object translucent.
  LINES_GRID_MAX* = 2*CELLS_GRID_HALF_MAX + 1
    ## Bound how many lattice lines one grid family lays, which since the fog fade moved
    ## to the fragment shader is also how many ribbon records it costs: a line is **one
    ## record** spanning its whole chord of the fog disc, faded per fragment by its own
    ## distance from the eye.
    ##   This replaces a whole piece-cutting economy. Each line used to be cut into up to
    ## eight pieces purely so the fade could be sampled at their boundaries, under a
    ## 640-piece budget (`SEGMENTS_GRID_MAX`) that squeezed the cut down to two where a
    ## family drew many lines -- ~920 per-boundary multivector sums, fades and depth dots
    ## per moving frame, which the diagnostics measured as the whole grid row. The
    ## per-fragment fade needs no boundaries at all, is exact where the piecewise-linear
    ## interpolation was an approximation, and leaves the placement two boundary sums per
    ## line.
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
  MUTE_AXIS_TOWARD_GREY* = 0.45'f32
    ## Blend a world axis's own colour this far toward its own grayscale equivalent, with
    ## no alpha change -- unlike `muted()`, this is a permanent palette entry rather than a
    ## per-frame "not in focus" dim. Enough that a red/green/blue trio stops competing with
    ## the categorical object colours, not so much that the axes stop reading as axes.
    ##   Raised from 0.22 on a report that axes were still being taken for drawn lines.
    ##   **Read by `axisTinted`, which builds the three palette entries from it.** It used
    ##   to be documentation only, with its blend hand-applied into the literals -- so the
    ##   number and the colours it described could drift apart with nothing to catch it.
  SCALE_AXIS_LUMINANCE* = 0.50'f32
    ## Scale a world axis's blended colour down by this, after the grey blend.
    ##   Desaturating alone leaves three mid-grey lines as conspicuous as the objects they
    ##   sit behind; furniture wants to be *dimmer*, not merely less colourful. Together
    ##   these two put the axes between the ground grid and a drawn object in weight, which
    ##   is where reference belongs.

static:
  doAssert SIZE_CELL_GRID > 0, &"Grid cell size must be positive; got `{SIZE_CELL_GRID}`."
  doAssert CELLS_GRID_HALF_MAX > 0,
    &"Grid must lay at least one cell each way; got `{CELLS_GRID_HALF_MAX}`."
  doAssert ALPHA_GRID > 0 and ALPHA_GRID < 1.0,
    &"Grid opacity must fall strictly between 0 and 1; got `{ALPHA_GRID}`."
  doAssert FRACTION_DIMMED_ALPHA > 0 and FRACTION_DIMMED_ALPHA < 1.0,
    &"Dimmed alpha fraction must fall strictly between 0 and 1; got `{FRACTION_DIMMED_ALPHA}`."
  doAssert MUTE_DESATURATION > 0 and MUTE_DESATURATION <= 1.0,
    &"Mute desaturation must fall between 0 and 1; got `{MUTE_DESATURATION}`."
  doAssert MUTE_AXIS_TOWARD_GREY > 0 and MUTE_AXIS_TOWARD_GREY <= 1.0,
    &"Axis mute fraction must fall between 0 and 1; got `{MUTE_AXIS_TOWARD_GREY}`."
  doAssert SCALE_AXIS_LUMINANCE > 0 and SCALE_AXIS_LUMINANCE <= 1.0,
    &"Axis luminance scale must fall between 0 and 1; got `{SCALE_AXIS_LUMINANCE}`."



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
    Algebra, ## The debug layer that draws the multivectors a frame computed, in their true
      ## form -- see `algebra_trace`. Structural, and deliberately not assignable: an
      ## entry drawn in it is the *algebra's* own geometry, and a reader must never have
      ## to wonder whether a shape in that ink is something they built -- so it is screened
      ## against every assignable slot and against `Invalid`, at the floors an assignable
      ## pair is held to. A cyan: worst measured separation is 8.2 against jade under
      ## tritanopia and 9.2 against cobalt under a red-green deficiency, both over the 6.0
      ## floor, and 54.4 against the backdrop it is drawn over.
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

  Placement* {.pure.} = enum ## Report what became of object once drawn.
    Finite, ## Object had finite extent and was drawn where it stands.
    Horizon, ## Object lay wholly at horizon; only its direction could be drawn.
    Empty, ## Multivector carried no drawable geometry at all.

  Rgba* = object ## Hold colour channels, in 0 .. 1.
    red*, green*, blue*, alpha*: float32

  Vertex* = object ## Hold one vertex exactly as it is uploaded.
    x*, y*, z*: float32
    red*, green*, blue*, alpha*: float32

  Mesh* = object ## Hold point vertices, in storage fixed at compile time.
    ## The one shape still uploaded as vertices: every widened kind -- ribbons, disc
    ## fans, sky domes -- crosses the wire as records for its own vertex shader instead.
    vertices*: array[VERTICES_MAX, Vertex]
    count_vertices*: int
    index_overlay*: Option[int] ## Where the overlay run begins, if this mesh has one.
      ## Vertices below it are drawn against the depth buffer as usual; the rest are drawn
      ## after them with the test off, so they land over whatever is already there.
      ## `markOverlay` is what sets it, and each render path draws the two runs as two
      ## calls -- see `renderer.drawRun`. None where nothing asked to be drawn over,
      ## which is every furniture mesh and every frame with nothing selected; an index of
      ## zero says the opposite and means the whole mesh is the overlay.
      ##   A watermark rather than a second `MeshSet`, because a set reserves its whole
      ## fixed storage up front, for a run that is usually one object. Order already
      ## decides what these buckets look like (see `visualiser.assembleMeshes`), so an
      ## index into the order costs nothing and states the same thing.

  RibbonRecord* = object ## Hold one line segment exactly as it is uploaded.
    ## **The vertex shader's input, not a vertex.** Each record is drawn as one instance
    ## of six corners; the shader clips it to the near plane, derives the across direction
    ## as `cross(head - tail, eye - tail)`, and steps each corner off by half a width of
    ## its own end's world-per-pixel -- the very work `expandRibbon` below states in Nim,
    ## which is the reference the shaders are held to. Sixteen floats a segment against
    ## the forty-two its six expanded vertices cost, and none of the arithmetic on a CPU.
    tail_x*, tail_y*, tail_z*: float32
    head_x*, head_y*, head_z*: float32
    width*: float32
    fog*: float32 ## Whether the fragment shader fades this record by its own distance
      ## from the eye -- 1 for world furniture and the debug layer's lattices, 0 for
      ## everything else. What the fade is is `alphaGridFade`'s statement, the reference
      ## the fog half of both ribbon fragment shaders is held to; carrying the flag on
      ## the record is what lets fogged and unfogged ribbons share one buffer in
      ## whatever order the frame emitted them.
    tail_red*, tail_green*, tail_blue*, tail_alpha*: float32
    head_red*, head_green*, head_blue*, head_alpha*: float32

  RibbonMesh* = object ## Hold every ribbon segment of one frame, in fixed storage.
    records*: array[RIBBONS_MAX, RibbonRecord]
    count*: int
    index_overlay*: Option[int] ## Where the overlay run begins; `Mesh.index_overlay`'s
      ## own doc comment says what that means and why it is a watermark.

  DiscRecord* = object ## Hold one filled disc exactly as it is uploaded.
    ## **The disc-fill vertex shader's input, not a vertex.** Each record is drawn as one
    ## instance of a static fan of `3 * SEGMENTS_CIRCLE_HORIZON` unit-circle corners; the
    ## shader places every corner at `centre + cos*arm_first + sin*arm_second` -- the very
    ## work `expandDiscVertex` below states in Nim, which is the reference the shaders are
    ## held to. Thirteen floats a disc against the `3 * SEGMENTS_CIRCLE_HORIZON * 7` its
    ## fanned vertices cost, and no per-frame trigonometry on a CPU.
    ##   The arms arrive already scaled by the disc's radius, so the record needs no
    ## radius of its own and the shader no multiply by one.
    centre_x*, centre_y*, centre_z*: float32
    arm_first_x*, arm_first_y*, arm_first_z*: float32
    arm_second_x*, arm_second_y*, arm_second_z*: float32
    fill_red*, fill_green*, fill_blue*, fill_alpha*: float32

  DomeRecord* = object ## Hold one whole-sky sphere exactly as it is uploaded.
    ## **The dome vertex shader's input, not a vertex.** Each record is drawn as one
    ## instance of a static lat/long sphere of unit directions; the shader places every
    ## corner at `centre + radius*direction` -- the very sum `spherePoint` used to walk
    ## through the algebra per frame, now stated once in `expandDomeVertex` below as the
    ## reference the shaders are held to. A dome's orientation is not a field because a
    ## full sphere has none: which plane produced it never shaped it (see
    ## `tessellate.addPlane`), so eight floats say everything the picture needs.
    centre_x*, centre_y*, centre_z*, radius*: float32
    red*, green*, blue*, alpha*: float32

  DiscMesh* = object ## Hold every disc record of one frame, in fixed storage.
    records*: array[DISCS_MAX, DiscRecord]
    count*: int

  DomeMesh* = object ## Hold every dome record of one frame, in fixed storage.
    records*: array[DOMES_MAX, DomeRecord]
    count*: int

  WashKind* {.pure.} = enum ## Name which record array one wash run draws from.
    Disc, Dome

  WashRun* = object ## Hold one stretch of same-kind wash records, drawn as one call.
    kind*: WashKind
    first*: int32 ## Index of the run's first record, within its own kind's array.
    count*: int32

  WashRuns* = object ## Hold the frame's wash draw order, across both record kinds.
    ## **The translucent pass's memory of scene order.** Discs and domes land in two
    ## record arrays, but two washes crossing still blend in the order the scene emitted
    ## them -- so each append extends the current run where it can and opens a new one
    ## where the kind changes, and each render path walks the runs in sequence instead of
    ## drawing one whole array after the other. Usually one run per object, of one record.
    runs*: array[DISCS_MAX + DOMES_MAX, WashRun]
    count*: int
    index_overlay*: Option[int] ## Index of the first *run* of the overlay pass --
      ## `Mesh.index_overlay`'s rule, at run rather than record grain, since a run never
      ## straddles the mark: `markOverlay` seals the current run by setting this, and the
      ## append test below refuses to extend across it.

  MeshSet* = object ## Hold everything one frame draws: vertices and every record kind.
    ## Points are the one shape still assembled as vertices; ribbons, discs and domes
    ## cross the wire as records for their own vertex shaders.
    points*: Mesh
    ribbons*: RibbonMesh
    discs*: DiscMesh
    domes*: DomeMesh
    washes*: WashRuns

  DrawScale* = object ## Hold how far this frame's geometry reaches, and from where.
    ## **The Euclidean half of a frame's camera.** Everything a ribbon needs to hold a
    ## constant width on screen, and everything the picture is measured against. The
    ## algebra's own reading of the same camera lives beside it in
    ## `tessellate.DrawExtent`, which carries this whole record and adds the multivector
    ## twins; this module cannot name those, which is the point of the split.
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
    forward*: Direction ## Camera's own sight axis, depth is measured along.
    tangent_half_view*: float ## Tangent of half the vertical field of view.
    height_pixels*: int ## Framebuffer height, which the vertical field of view spans.
    depth_near*: float ## Camera's own near clip distance, depth is clamped at. Nothing
      ## nearer is drawn, so nothing needs a width measured nearer -- and without the
      ## clamp a segment running past the eye reads a negative depth and turns its own
      ## ribbon inside out.


#[ Camera-Relative Scale ]#

func radiansPerPixel*(scale: DrawScale): float =
  ## Measure how much of the camera's own angular field one pixel of height spans.
  ##   The small-angle reading of `worldPerPixelAt` at unit depth, and the right unit for
  ##   anything placed by *direction* rather than by position -- horizon geometry is drawn
  ##   on a sphere about the eye, where a pixel is an angle and not a distance.
  2.0*scale.tangent_half_view/float(max(scale.height_pixels, 1))


func worldPerPixelAt*(place: Position; scale: DrawScale): float =
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


func alphaGridFade*(radius, radius_fade_start, radius_end: float): float =
  ## Fall from full alpha at `radius_fade_start` to none at `radius_end` -- past the
  ## fade start, a grid line's own cells crowd into fewer and fewer screen pixels
  ## under perspective, reading as aliasing noise rather than as a reference; fading
  ## them out trades that noise for a clean horizon instead of fighting it.
  ##   `radius` is a distance **from the eye**, and the two bounds come from
  ##   `fogFurnitureFor` below; see it for why the fog is centred there and not on the
  ##   origin. One schedule for all the world furniture -- grid, axes, and the debug
  ##   layer's lattices -- so everything reference ends at one horizon.
  ##   **The reference the fog half of both ribbon fragment shaders is held to**, the
  ##   rule `expandRibbon` states for the widening: a change to this, to the GLSL 3.30
  ##   source in `renderer.nim` or to the WebGL source in `glue.js` is not finished until
  ##   the other two are checked. It runs per fragment there, against the fragment's own
  ##   interpolated world position -- exact along a record of any length, where the
  ##   retired per-piece sampling was a piecewise-linear approximation.
  1.0 - clamp((radius - radius_fade_start) / (radius_end - radius_fade_start), 0.0, 1.0)


func fogFurnitureFor*(extent: float): tuple[radius_full, radius_gone: float] =
  ## Solve where the world furniture's own fog begins and ends, as distances **from the
  ## eye**: a grid line or an axis holds its full strength within `radius_full` and has
  ## faded to nothing by `radius_gone`, with `addGrid` and `addAxes` cutting their
  ## geometry off at the latter.
  ##   Fog rather than a halo about the world origin, which is what this replaced. A halo
  ## makes the origin a place the reader may not leave: pan a hundred units away and the
  ## ground is simply gone, and the camera reads as bounded to a region even though only
  ## its orbit distance ever was. Measured from the eye rather than from the camera's own
  ## target so that it behaves as fog does -- what is near the reader is solid and what is
  ## far is not, whichever way they happen to be looking.
  ##   Both radii follow the camera's own reach, so pulling back reveals more ground; only
  ## their *centre* moved. **Uncapped**, and that is the second thing this proc has been:
  ## the outer radius used to stop at `CELLS_GRID_HALF_MAX` cells, which bounded the lines
  ## drawn but meant a camera further out than that -- 1,200 units, easily reached now that
  ## orbit distance is unbounded -- had the ground vanish from under it and was left in a
  ## black void with no reference of any kind, axes included. The line count is bounded by
  ## `sizeCellGridFor` stepping the *cell* instead, which spends the same budget on the
  ## reach a reader is actually looking across.
  let radius_gone = FRACTION_GRID_FADE_END*extent
  # Held as a ratio of the outer radius rather than as its own fraction of `extent`, so the
  #   two always keep the same proportion whatever the reach comes out at.
  (radius_full: radius_gone*(FRACTION_GRID_FADE_START/FRACTION_GRID_FADE_END),
   radius_gone: radius_gone)


func sizeCellGridFor*(radius_ground: float): float =
  ## Choose the ground grid's own cell size for a ground disc of `radius_ground`, in world
  ## units: `SIZE_CELL_GRID` wherever that lays no more than `CELLS_GRID_HALF_MAX` cells
  ## across the disc's radius, and ten times it for every further factor of ten needed.
  ##   **A cell that steps, which this file argued against, and the argument still holds
  ## where it was made.** A grid whose cell walks continuously with the reach is not a
  ## ruler: nothing read off it is comparable with what was read a moment ago, and that is
  ## why `SIZE_CELL_GRID` is one fixed number. What is answered here is the case that rule
  ## left with nothing at all -- the reach past which a fixed cell would lay tens of
  ## thousands of lines, where the choice is not "fixed cell or stepped" but "stepped cell
  ## or no ground".
  ##   **Decades, so the coarser grid's lines are the finer grid's lines.** Every line of a
  ## hundred-unit lattice is a line of the ten-unit one, so a step coarsens what is drawn
  ## without moving anything: a reader who was measuring against a line still has that
  ## line. A 1-2-5 sequence, which a chart axis would use, does not nest -- stepping 10 to
  ## 20 replaces every odd line with nothing -- and buys only a gentler jump for it.
  ##   The first step is at 1,200 units of ground reach, about orbit distance 316: far past
  ## anything a reader is reading distances off, and by then a ten-unit cell is already the
  ## aliasing haze `FRACTION_GRID_FADE_END` exists to cut short.
  ##   `SIZE_CELL_GRID` itself for a disc of no radius, which lays no lines to size.
  let radius_cells = float(CELLS_GRID_HALF_MAX)*SIZE_CELL_GRID
  if radius_ground <= radius_cells: return SIZE_CELL_GRID
  SIZE_CELL_GRID*pow(10.0, ceil(log10(radius_ground/radius_cells)))


func extentFurnitureFor*(distance_far: float): float =
  ## Compute how far the ground grid, world axes, and every finite line should reach
  ## this frame, given the camera's own far clip distance -- independent of orbit
  ## distance, so all three keep reaching almost all the way to the renderer's own
  ## outer depth limit regardless of how far the camera has dollied in or out to
  ## inspect finite content, reading as extending indefinitely rather than shrinking
  ## back when the camera does.
  distance_far * FRACTION_FURNITURE



#[ Palette ]#

func axisTinted(base: Rgba): Rgba =
  ## Soften one full-strength axis hue into the reference mark it should read as.
  ##   Blends toward the colour's own luminance-grey by `MUTE_AXIS_TOWARD_GREY`, using the
  ##   same 0.299/0.587/0.114 weights `muted()` uses, then scales the result down by
  ##   `SCALE_AXIS_LUMINANCE`. Alpha is untouched -- deliberately not `muted()`, whose
  ##   alpha cut belongs to a per-frame dim rather than to a permanent palette entry.
  ##   Evaluated at compile time into the table below, so the axes *are* what these two
  ##   constants say and cannot drift from them.
  let grey = 0.299*base.red + 0.587*base.green + 0.114*base.blue
  func softened(channel: float32): float32 =
    SCALE_AXIS_LUMINANCE*((1.0'f32 - MUTE_AXIS_TOWARD_GREY)*channel +
      MUTE_AXIS_TOWARD_GREY*grey)
  Rgba(
    red: softened(base.red), green: softened(base.green), blue: softened(base.blue),
    alpha: base.alpha,
  )


const lut_ink_to_rgba: array[Ink, Rgba] = [
  Ink.Backdrop: Rgba(red: 0.063, green: 0.075, blue: 0.102, alpha: 1.0),
  # The standard convention at full strength, softened by `axisTinted` -- the hue says
  #   which axis it is, and the softening keeps it from saying "drawn object".
  Ink.AxisX: axisTinted(Rgba(red: 0.85, green: 0.22, blue: 0.22, alpha: 1.0)),
  Ink.AxisY: axisTinted(Rgba(red: 0.26, green: 0.80, blue: 0.26, alpha: 1.0)),
  Ink.AxisZ: axisTinted(Rgba(red: 0.24, green: 0.42, blue: 0.90, alpha: 1.0)),
  Ink.Grid: Rgba(red: 0.180, green: 0.204, blue: 0.259, alpha: 1.0),
  Ink.Guide: Rgba(red: 0.286, green: 0.322, blue: 0.400, alpha: 1.0),
  Ink.Outline: Rgba(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
  Ink.Algebra: Rgba(red: 0.000, green: 0.729, blue: 0.780, alpha: 1.0),
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
  ## Drop every vertex and record assembled so far, so frame may be rebuilt from scratch.
  meshes.points.count_vertices = 0
  meshes.points.index_overlay = none(int)
  meshes.ribbons.count = 0
  meshes.ribbons.index_overlay = none(int)
  meshes.discs.count = 0
  meshes.domes.count = 0
  meshes.washes.count = 0
  meshes.washes.index_overlay = none(int)


proc markOverlay*(meshes: var MeshSet) =
  ## Say that everything appended from here on is drawn over what came before it.
  ##   Called once, between the ordinary objects and the selected ones; see
  ##   `Mesh.count_vertices_tested`. Calling it twice would move the boundary rather than
  ##   add a second one, which is why the assembly order and not this decides what is
  ##   over what.
  meshes.points.index_overlay = some(meshes.points.count_vertices)
  meshes.ribbons.index_overlay = some(meshes.ribbons.count)
  meshes.washes.index_overlay = some(meshes.washes.count)


proc addMarker*(meshes: var MeshSet; at: Position; tint: Rgba) =
  ## Append point marking single position.
  let count = meshes.points.count_vertices
  doAssert count < VERTICES_MAX,
    &"Mesh holds at most {VERTICES_MAX} vertices; raise `--define:visualiser.vertices_max`."
  meshes.points.vertices[count] = Vertex(
    x: float32(at.x), y: float32(at.y), z: float32(at.z),
    red: tint.red, green: tint.green, blue: tint.blue, alpha: tint.alpha,
  )
  meshes.points.count_vertices = count + 1


func blend(first, second: Rgba; fraction: float): Rgba =
  ## Read the colour a fraction of the way between two tints, for a ribbon end the near
  ## clip has moved.
  ##   At module scope rather than nested in `addSegment`, where it began: the JS backend
  ##   materialises a nested routine on every call of its parent, and `addSegment` runs
  ##   thousands of times a frame while the ground grid rebuilds under a moving camera.
  let (a, b) = (1.0 - fraction, fraction)
  Rgba(
    red: float32(a*float(first.red) + b*float(second.red)),
    green: float32(a*float(first.green) + b*float(second.green)),
    blue: float32(a*float(first.blue) + b*float(second.blue)),
    alpha: float32(a*float(first.alpha) + b*float(second.alpha)),
  )


const POINTS_SCRATCH_MAX* = SEGMENTS_CIRCLE_HORIZON + 1
  ## Bound the places a tessellation step may assemble before emitting them.
  ##   A horizon line's great circle is the largest of them now that the sky dome is one
  ##   record widened over static geometry -- one extra boundary so its closing segment
  ##   ends on a place stepped at the angle the loop would have used, rather than on a
  ##   wrap that would land a hair off it.


type RibbonPiece* = object
  ## Hold one ribbon segment, fully resolved: where it runs, which way it steps off, and
  ## what colour each end is.
  ##   **The record the algebra hands the picture.** A lattice line's pieces used to be
  ## assembled and emitted in one interleaved loop, with the boundary read sitting inside
  ## `addSegmentAcross`'s own argument list -- so the two languages met in the middle of a
  ## statement and no bracket could separate them. Assembling a whole family into these
  ## first and emitting them after makes that seam a line in the code rather than a claim
  ## in a comment, which is what lets the panel say what each side cost.
  ##   Everything here is Euclidean: by the time a piece exists, the algebra has finished
  ## with it.
  tail*, head*: Position
  tint_tail*, tint_head*: Rgba


type DrawScratch* = object
  ## Hold the working space a tessellation step assembles into before it emits anything.
  ##   **One object rather than a buffer per shape**, so a caller supplies scratch once and
  ## every step that needs somewhere to work has it. The desktop carves this from the frame
  ## arena and the browser holds one; neither allocates per frame, and the suite's copy is
  ## the same shape as both.
  ##   Both members are written and read within a single step, never across two, so they
  ## carry nothing between callers and need no clearing.
  ribbons*: array[LINES_GRID_MAX, RibbonPiece]
    ## One piece per lattice line or axis chord now that the fog fade is the fragment
    ## shader's; sized for the larger grid family, which is the largest user left.
  places*: array[POINTS_SCRATCH_MAX, Position]


func directionAcross*(tail, head, eye: Position): Option[Direction] =
  ## Resolve which way to step off a segment so its own two edges land either side of it
  ## on screen.
  ##   Perpendicular to the segment and to the sight ray reaching it, which is exactly the
  ##   direction that shows as sideways from where the camera stands: the cross product of
  ##   the two edges leaving `tail`.
  ##   **The picture's own quantity, not the geometry's.** Which way a line runs is the
  ##   algebra's answer and stays there; how wide the quad standing for it is drawn is not,
  ##   and this is that. It was the join `directionNormal(tail ∧ head ∧ eye)` -- the same
  ##   plane, read for its normal -- which every ribbon of every frame ran, ~3,800 times a
  ##   frame while the camera moves, walking 16x16 coefficient pairs through `nimCopy` on
  ##   the JS backend each time. The suite holds this cross equal to that join, sign
  ##   included: the algebra is what the shipped form is proved against.
  ##   None where the eye lies on the segment's own line, or where the segment has no
  ##   length: neither has a side to step off toward.
  normalize(cross(head - tail, eye - tail))


func expandRibbon*(record: RibbonRecord; scale: DrawScale): array[6, Vertex] =
  ## Expand one ribbon record into the six vertices the shader will make of it -- **the
  ## reference implementation of the ribbon vertex shader, and nothing else runs it.**
  ##   Both render targets carry this same arithmetic in GLSL (`renderer.nim`'s ribbon
  ## vertex shader and `glue.js`'s -- the sibling copies; a change to any one of the three
  ## is not finished until the other two are checked). The suite holds this form against
  ## the algebra -- its near clip equal to `clipToEyeSide`, its across equal to the join
  ## `directionNormal(tail ∧ head ∧ eye)` through `directionAcross` -- so the chain runs
  ## shader ≡ this ≡ the algebra, and the GPU never ships arithmetic nothing pins.
  ##   A quad rather than a `GL_LINES` pair because a line width is a *hint* both targets
  ## are entitled to ignore -- most WebGL implementations clamp it to one pixel outright.
  ##   Each end is offset by half a width of *its own* world-per-pixel, so the ribbon
  ## narrows with distance exactly as the line it draws does, and two parallel lines keep
  ## their shared vanishing point.
  ##   **Clipped to the near plane first.** A world offset proportional to depth gives a
  ## constant screen width only while the quad's own edges interpolate a depth linear
  ## along the segment -- which stops being true the moment one end stands behind the eye.
  ## Left unclipped, a world axis running from far behind the camera drew twenty pixels
  ## wide near the origin. Both ends clipped have real, positive depth, and the
  ## interpolation between them is exact.
  ##   A segment entirely behind the eye, or one the eye stands on, comes back as six
  ## coincident zero-alpha vertices -- a quad that rasterises nothing, exactly as the
  ## shader leaves it, rather than an optional the shader has no way to express.
  let
    tail = Position(x: record.tail_x, y: record.tail_y, z: record.tail_z)
    head = Position(x: record.head_x, y: record.head_y, z: record.head_z)
    tint_tail = Rgba(red: record.tail_red, green: record.tail_green,
      blue: record.tail_blue, alpha: record.tail_alpha)
    tint_head = Rgba(red: record.head_red, green: record.head_green,
      blue: record.head_blue, alpha: record.head_alpha)
    depth_tail = dot(tail - scale.eye, scale.forward)
    depth_head = dot(head - scale.eye, scale.forward)
    across = directionAcross(tail, head, scale.eye)
  if (depth_tail < scale.depth_near and depth_head < scale.depth_near) or across.isNone:
    return

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
    offset_near = 0.5*float(record.width)*worldPerPixelAt(near, scale)*across.get
    offset_far = 0.5*float(record.width)*worldPerPixelAt(far, scale)*across.get
    corners = [
      near - offset_near, far - offset_far, far + offset_far, near + offset_near,
    ]
    tints = [tint_near, tint_far, tint_far, tint_near]
  for slot, index in [0, 1, 2, 0, 2, 3]:
    result[slot] = Vertex(
      x: float32(corners[index].x), y: float32(corners[index].y),
      z: float32(corners[index].z),
      red: tints[index].red, green: tints[index].green,
      blue: tints[index].blue, alpha: tints[index].alpha,
    )


proc addRibbon*(
  meshes: var MeshSet; tail, head: Position; tint_tail, tint_head: Rgba; width: float32;
  is_fogged: bool = false
) =
  ## Append one line segment as a ribbon record, for the vertex shader to widen.
  ##   No camera is needed here any more: the near clip, the across direction and the
  ## screen-constant width all moved to the GPU with the expansion (see `expandRibbon`,
  ## which states exactly what it does there), and `is_fogged` says whether the fragment
  ## shader also fades this record by distance from the eye (see `RibbonRecord.fog`).
  ## The emit half of the boundary is a sixteen-float copy, which is the whole point.
  let count = meshes.ribbons.count
  doAssert count < RIBBONS_MAX,
    &"Frame holds at most {RIBBONS_MAX} ribbons; raise `--define:visualiser.ribbons_max`."
  meshes.ribbons.records[count] = RibbonRecord(
    tail_x: float32(tail.x), tail_y: float32(tail.y), tail_z: float32(tail.z),
    head_x: float32(head.x), head_y: float32(head.y), head_z: float32(head.z),
    width: width,
    fog: (if is_fogged: 1.0'f32 else: 0.0'f32),
    tail_red: tint_tail.red, tail_green: tint_tail.green,
    tail_blue: tint_tail.blue, tail_alpha: tint_tail.alpha,
    head_red: tint_head.red, head_green: tint_head.green,
    head_blue: tint_head.blue, head_alpha: tint_head.alpha,
  )
  meshes.ribbons.count = count + 1


proc addRibbonPieces*(
  meshes: var MeshSet; pieces: openArray[RibbonPiece]; width: float32;
  is_fogged: bool = false
) =
  ## Append every assembled piece as a ribbon record.
  ##   The emit half of the seam above: no multivector is named here, and none can be --
  ##   this module cannot reach the algebra at all.
  for piece in pieces:
    meshes.addRibbon(
      piece.tail, piece.head, piece.tint_tail, piece.tint_head, width, is_fogged
    )


proc addSegment*(
  meshes: var MeshSet; tail, head: Position; tint: Rgba; width: float32
) =
  ## Append a ribbon of one tint end to end; the record form of the old expanded segment.
  meshes.addRibbon(tail, head, tint, tint, width)


let UNIT_CIRCLE_RIM* = unitRing[SEGMENTS_CIRCLE_HORIZON + 1](SEGMENTS_CIRCLE_HORIZON)
  ## The rim's fixed ring of angles, resolved once at start-up by `euclid.unitRing` --
  ## the one generator every fixed ring in this project walks; see it for why the table
  ## is built at run time and what the suites hold it to.
  ##   One boundary past the wrap rather than a reuse of the first entry, so the closing
  ## segment ends on the value `cos(2*PI)` actually takes, a hair off `cos(0)`'s --
  ## exactly the rule `tessellate.addGreatCircle` states for its own ring.
  ##   Exported for the other walkers of the same ring: a horizon line's great circle
  ## (through `addPlaneRing` itself) and `picking`'s sampling of that circle, which must
  ## step the very angles the drawn one does for a hit to agree with what is drawn.


proc addPlaneRing*(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba
) =
  ## Append a plain circle of segments at `radius`, in the plane `axis_first` and
  ## `axis_second` span -- a finite plane's own rim, marking exactly how far it is drawn.
  ##   **A disc is not a plane.** A plane is infinite; this circle is the stand-in drawn
  ##   for one, sized for an eye and carrying no geometric meaning of its own, so it is
  ##   stepped with `euclid.onCircleAt` off the fixed table above rather than assembled
  ##   as multivector sums. Which plane the two arms span is still the algebra's answer
  ##   -- `boundary.frame` -- and `tessellate.addPlane` hands it down; only the walk
  ##   around the rim is arithmetic. The suite holds each point equal to the multivector
  ##   sum it replaced.
  ##   Each boundary is placed once and shared with the next segment, which with the
  ##   table makes the whole rim a stretch of fused multiplies and no trigonometry.
  let
    arm_first = radius*axis_first
    arm_second = radius*axis_second
  var tail = onCircleAt(
    center, arm_first, arm_second,
    UNIT_CIRCLE_RIM[0].cos_angle, UNIT_CIRCLE_RIM[0].sin_angle,
  )
  for i in 1 .. SEGMENTS_CIRCLE_HORIZON:
    let head = onCircleAt(
      center, arm_first, arm_second,
      UNIT_CIRCLE_RIM[i].cos_angle, UNIT_CIRCLE_RIM[i].sin_angle,
    )
    meshes.addSegment(tail, head, tint, WIDTH_LINE_OBJECT)
    tail = head


func expandDiscVertex*(record: DiscRecord; cos_angle, sin_angle: float): Vertex =
  ## Widen one disc record into the fan corner the given table entry stands for --
  ## **the reference the disc-fill vertex shaders are held to**, beside `expandRibbon`;
  ## a change to it, to the GLSL 3.30 source in `renderer.nim` or to the WebGL source in
  ## `glue.js` is not finished until the other two are checked.
  ##   One statement: the centre plus the two radius-scaled arms weighted by the
  ##   corner's own cosine and sine -- `euclid.onCircleAt`, with the centre corner
  ##   carrying zero for both weights. Flat tint across the fan; see `addDisc` for why.
  let at = onCircleAt(
    Position(
      x: float(record.centre_x), y: float(record.centre_y), z: float(record.centre_z)
    ),
    Direction(
      x: float(record.arm_first_x), y: float(record.arm_first_y),
      z: float(record.arm_first_z),
    ),
    Direction(
      x: float(record.arm_second_x), y: float(record.arm_second_y),
      z: float(record.arm_second_z),
    ),
    cos_angle, sin_angle,
  )
  Vertex(
    x: float32(at.x), y: float32(at.y), z: float32(at.z),
    red: record.fill_red, green: record.fill_green,
    blue: record.fill_blue, alpha: record.fill_alpha,
  )


func expandDomeVertex*(record: DomeRecord; unit: Direction): Vertex =
  ## Widen one dome record into the sphere corner the given unit direction stands for --
  ## **the reference the dome vertex shaders are held to**; the same three-way rule as
  ## `expandDiscVertex` above.
  ##   One statement: the centre plus the unit direction scaled by the radius -- the very
  ##   sum `spherePoint` walked through the algebra before the sphere became static
  ##   geometry, which the suite still holds it equal to.
  Vertex(
    x: float32(float(record.centre_x) + float(record.radius)*unit.x),
    y: float32(float(record.centre_y) + float(record.radius)*unit.y),
    z: float32(float(record.centre_z) + float(record.radius)*unit.z),
    red: record.red, green: record.green, blue: record.blue, alpha: record.alpha,
  )


proc discCorners*(): seq[float32] =
  ## Emit the disc fan's static corner buffer: `(cos, sin)` per corner, three corners
  ## per rim segment, in the winding the CPU fan used -- centre, this segment's boundary,
  ## the next one's. The centre corner is the pair `(0, 0)`, which
  ## `expandDiscVertex`'s one statement lands on the centre exactly.
  ##   **The one source for both render targets**: the desktop uploads this from Nim and
  ##   the browser through `nimDiscCorners`, so neither carries a hand-copied table that
  ##   could drift from the reference above.
  result = newSeq[float32](2*3*SEGMENTS_CIRCLE_HORIZON)
  for i in 0 ..< SEGMENTS_CIRCLE_HORIZON:
    let at = 6*i
    result[at + 0] = 0.0
    result[at + 1] = 0.0
    result[at + 2] = float32(UNIT_CIRCLE_RIM[i].cos_angle)
    result[at + 3] = float32(UNIT_CIRCLE_RIM[i].sin_angle)
    result[at + 4] = float32(UNIT_CIRCLE_RIM[i + 1].cos_angle)
    result[at + 5] = float32(UNIT_CIRCLE_RIM[i + 1].sin_angle)


func domeCorners*(): seq[float32] =
  ## Emit the dome's static corner buffer: one unit direction per corner, six corners
  ## per lat/long quad, in the winding the CPU quads used. `expandDomeVertex` above says
  ## what each corner becomes.
  ##   The one source for both render targets, exactly as `discCorners` is.
  result = newSeq[float32](3*6*LATITUDES_HORIZON*LONGITUDES_HORIZON)
  var at = 0
  for lat in 0 ..< LATITUDES_HORIZON:
    for lon in 0 ..< LONGITUDES_HORIZON:
      # The quad's four unit directions, wound [0, 1, 2, 0, 2, 3] as `addQuad` wound it.
      var corners: array[4, tuple[theta, phi: float]]
      corners[0] = (theta: PI*float(lat)/float(LATITUDES_HORIZON),
        phi: 2.0*PI*float(lon)/float(LONGITUDES_HORIZON))
      corners[1] = (theta: PI*float(lat)/float(LATITUDES_HORIZON),
        phi: 2.0*PI*float(lon + 1)/float(LONGITUDES_HORIZON))
      corners[2] = (theta: PI*float(lat + 1)/float(LATITUDES_HORIZON),
        phi: 2.0*PI*float(lon + 1)/float(LONGITUDES_HORIZON))
      corners[3] = (theta: PI*float(lat + 1)/float(LATITUDES_HORIZON),
        phi: 2.0*PI*float(lon)/float(LONGITUDES_HORIZON))
      for index in [0, 1, 2, 0, 2, 3]:
        let (theta, phi) = corners[index]
        result[at + 0] = float32(sin(theta)*cos(phi))
        result[at + 1] = float32(sin(theta)*sin(phi))
        result[at + 2] = float32(cos(theta))
        at += 3


proc appendWashRun(meshes: var MeshSet; kind: WashKind) =
  ## Note one more record of `kind` in the wash draw order, extending the current run
  ## where it is the same kind and this side of the overlay mark, opening a new one
  ## otherwise. See `WashRuns` for why the order is kept at all.
  let count = meshes.washes.count
  if count > 0 and meshes.washes.runs[count - 1].kind == kind and
      meshes.washes.index_overlay != some(count):
    meshes.washes.runs[count - 1].count += 1
    return
  doAssert count < len(meshes.washes.runs),
    &"Frame holds at most {len(meshes.washes.runs)} wash runs."
  meshes.washes.runs[count] = WashRun(
    kind: kind,
    first: int32(if kind == WashKind.Disc: meshes.discs.count else: meshes.domes.count),
    count: 1,
  )
  meshes.washes.count = count + 1


proc addDisc*(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba
) =
  ## Append a flat, uniformly translucent disc record filling the circle `addPlaneRing`
  ## outlines, for the disc-fill vertex shader to fan out -- flat rather than faded
  ## toward the rim, since the rim itself already marks the boundary crisply; a plane's
  ## own tilt still reads through the fan's foreshortened ellipse, and low, constant
  ## alpha keeps whatever sits behind it legible through every one of its triangles
  ## alike.
  let count = meshes.discs.count
  doAssert count < DISCS_MAX,
    &"Frame holds at most {DISCS_MAX} discs; raise `--define:visualiser.discs_max`."
  meshes.appendWashRun(WashKind.Disc)
  let
    arm_first = radius*axis_first
    arm_second = radius*axis_second
  meshes.discs.records[count] = DiscRecord(
    centre_x: float32(center.x), centre_y: float32(center.y), centre_z: float32(center.z),
    arm_first_x: float32(arm_first.x), arm_first_y: float32(arm_first.y),
    arm_first_z: float32(arm_first.z),
    arm_second_x: float32(arm_second.x), arm_second_y: float32(arm_second.y),
    arm_second_z: float32(arm_second.z),
    fill_red: tint.red, fill_green: tint.green, fill_blue: tint.blue,
    fill_alpha: tint.alpha,
  )
  meshes.discs.count = count + 1


proc addDome*(meshes: var MeshSet; center: Position; radius: float; tint: Rgba) =
  ## Append a whole-sky sphere record around `center`, for the dome vertex shader to
  ## widen -- a plane at horizon is the unique universal "whole sky" object, the same
  ## regardless of which points produced it (see `directionNormalHorizon`'s own doc
  ## comment for why), so nothing about its own coefficients decides its shape here;
  ## only `radius` and `tint` do. Every direction the camera can actually see sky in
  ## should show it, including looking down across the ground grid toward the horizon
  ## -- an earlier version stopped this dome at the eye's own horizontal, reverted on
  ## explicit feedback that halving it cut off sky the camera genuinely can see.
  ## Occlusion against anything nearer is the ordinary depth test's job, same as any
  ## other drawn geometry.
  let count = meshes.domes.count
  doAssert count < DOMES_MAX,
    &"Frame holds at most {DOMES_MAX} domes; raise `--define:visualiser.domes_max`."
  meshes.appendWashRun(WashKind.Dome)
  meshes.domes.records[count] = DomeRecord(
    centre_x: float32(center.x), centre_y: float32(center.y), centre_z: float32(center.z),
    radius: float32(radius),
    red: tint.red, green: tint.green, blue: tint.blue, alpha: tint.alpha,
  )
  meshes.domes.count = count + 1



