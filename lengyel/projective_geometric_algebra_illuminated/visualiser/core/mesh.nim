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
  SEGMENTS_GRID_FADE* = 8
    ## Cut each ground grid line into at most this many pieces, independent of
    ## `SIZE_CELL_GRID`, so `alphaGridFade` can fade it smoothly by distance without one
    ## piece per cell. **At most**, because `SEGMENTS_GRID_MAX` may spend fewer on a
    ## family drawing many lines; see there.
  SEGMENTS_GRID_MAX* = 640
    ## Spend no more than this many ribbon segments on the ground grid, both families
    ## together, however many lattice lines the ground reach asks for.
    ##   **The scenery's cost is its segment count, and its segment count sawtooths with
    ## camera distance.** `sizeCellGridFor` steps the cell by a decade only once the
    ## ground reach passes `CELLS_GRID_HALF_MAX*SIZE_CELL_GRID`, so within each decade the
    ## line count climbs with distance to as many as `2*CELLS_GRID_HALF_MAX` a family
    ## before the step drops it back by ten. Measured on the driving container at a fixed
    ## viewport, grid phase against distance: **154 segments/7.3 ms at 19, 712/35.4 ms at
    ## 100, 2,084/126.5 ms at 300**, then 706/44.6 ms at 1,000 once the cell had stepped --
    ## about 50-60 us a segment throughout, so the price is the count and nothing else. A
    ## reader panning near the top of a decade met a scenery phase of over a tenth of a
    ## second, intermittently, which is exactly how it was reported.
    ##   The lines themselves are untouched: what a reader sees is where the world's own
    ## lattice falls, and thinning that would move the grid rather than cheapen it. What
    ## adapts is how finely each line is *cut for its fade* -- 8 pieces where a family
    ## draws few lines, down to a floor of `SEGMENTS_GRID_FADE_MIN` where it draws many.
    ## A far-out grid line spans few pixels and its fade has correspondingly little room
    ## to band in, which is why the coarser sampling is not visible where it applies and
    ## the near view, which never reaches the budget, is bit-identical.
    ##   640 rather than a round 1,000: it holds the worst case near the 19-distance
    ## opening view's own price, which is the frame a reader spends most of a session in.
  SEGMENTS_GRID_FADE_MIN* = 2
    ## Never cut a grid line into fewer pieces than this, however many lines there are.
    ## Two pieces still fade from both ends toward the middle; one could not fade at all,
    ## and a line of flat alpha reads as a hard edge where the fog should have taken it.
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
  doAssert SEGMENTS_GRID_FADE >= 2,
    &"Grid fade needs at least 2 pieces; got `{SEGMENTS_GRID_FADE}`."
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

  Placement* {.pure.} = enum ## Report what became of object once drawn.
    Finite, ## Object had finite extent and was drawn where it stands.
    Horizon, ## Object lay wholly at horizon; only its direction could be drawn.
    Empty, ## Multivector carried no drawable geometry at all.

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


proc addVertex*(meshes: var MeshSet; primitive: Primitive; at: Position; tint: Rgba) =
  ## Exported for `tessellate`, which fans a plane's fill straight into the triangle
  ##   bucket rather than through a shape helper.
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


proc addSegmentAcross*(
  meshes: var MeshSet; tail, head: Position; across: Direction;
  tint_tail, tint_head: Rgba; width: float32; scale: DrawScale
) =
  ## Append a line segment joining two positions, as a **ribbon**: a world-space quad
  ## `width` pixels across, wound as two triangles, stepped off along `across`.
  ##   A quad rather than a `GL_LINES` pair because a line width is a *hint* both this
  ## project's targets are entitled to ignore -- most WebGL implementations clamp it to
  ## one pixel outright, and core-profile OpenGL only ever guaranteed one. Drawing the
  ## width as geometry is the only way both builds show the same thing.
  ##   `across` is the caller's, because collinear segments before one eye share one
  ## plane: the ground grid derives each lattice line's across **once** -- the same
  ## `directionNormal(line ∧ eye)` the per-piece join would re-derive eight times over --
  ## and hands it down. A restructuring in the algebra's own terms: fewer joins, the same
  ## joins. `addSegment` below derives it per segment for a caller with nothing to share.
  ##   Everything in this body is the GPU boundary -- the licensed componentwise copy of
  ## what a geometry shader would do -- and its near clip is pinned equal to the algebra's
  ## own `clipToEyeSide` by the suite:
  ##   Each end is offset by half a width of *its own* world-per-pixel, so the ribbon
  ## narrows with distance exactly as the line it draws does, and two parallel lines keep
  ## their shared vanishing point. A constant world offset would hold the far end open;
  ## a constant screen offset would not converge at all.
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
  let
    depth_tail = dot(tail - scale.eye, scale.forward)
    depth_head = dot(head - scale.eye, scale.forward)
  if depth_tail < scale.depth_near and depth_head < scale.depth_near: return

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
    offset_near = 0.5*float(width)*worldPerPixelAt(near, scale)*across
    offset_far = 0.5*float(width)*worldPerPixelAt(far, scale)*across
    corners = [
      near - offset_near, far - offset_far, far + offset_far, near + offset_near,
    ]
    tints = [tint_near, tint_far, tint_far, tint_near]
  for index in [0, 1, 2, 0, 2, 3]:
    meshes.addVertex(Primitive.Ribbon, corners[index], tints[index])


proc addQuad*(meshes: var MeshSet; corners: array[4, Position]; tint: Rgba) =
  ## Append filled quadrilateral, wound as two triangles.
  for index in [0, 1, 2, 0, 2, 3]:
    meshes.addVertex(Primitive.Triangle, corners[index], tint)



