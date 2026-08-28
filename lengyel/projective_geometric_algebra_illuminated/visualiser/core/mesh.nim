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
      ##   The *boundary* reading of the eye; world-space algebra reads `eye_point`.
    # The four multivector twins below are the algebra's own reading of this camera,
    #   derived once per frame in `camera.drawExtentFor` so nothing downstream rebuilds
    #   `toMultivector(eye)` -- or worse, a whole plane -- per segment. The Position and
    #   Direction fields they twin stay, because the boundary (the view matrix, ribbon
    #   packing, `worldPerPixelAt`) is licensed to read components; everything else takes
    #   the multivectors.
    eye_point*: Multivector ## The eye as a unit-weight point.
    forward_point*: Multivector ## The sight direction as a point at the horizon.
    plane_eye*: Multivector ## The unitized plane through the eye perpendicular to the
      ## sight direction: `depthAgainst` it is view depth, and its sign is "in front".
    plane_near*: Multivector ## The same plane pushed `depth_near` forward: the near clip
      ## as the algebra states it, for `clipToEyeSide`'s own meet.
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

func algebraFilled*(scale: DrawExtent): DrawExtent =
  ## Return the extent with its four multivector twins derived from its own plain fields.
  ##   The one derivation point: `camera.drawExtentFor` goes through here, and so must any
  ##   hand-built extent -- a test fixture, a partial one -- or its twins are zero
  ##   multivectors and everything algebraic downstream silently draws nothing. Found
  ##   exactly that way: the suite's own fixtures built extents fieldwise and the ground
  ##   grid vanished from every one of them.
  result = scale
  result.eye_point = toMultivector(scale.eye)
  result.forward_point = toMultivector(scale.forward)
  result.plane_eye = planeThrough(result.eye_point, result.forward_point)
  result.plane_near = planeThrough(
    add(result.eye_point, wedge(scale.depth_near, result.forward_point)),
    result.forward_point,
  )


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
    position(add(
      scale.eye_point, wedge(scale.radius_horizon, toMultivector(heading.get))
    ))
  of Shape.Line, Shape.Plane:
    positionAnchor(m)


func anchorFor*(
  m: Multivector; anchor_override: Option[Position]; scale: DrawExtent
): Option[Position] =
  ## Resolve one point standing for `m` **as it is actually drawn**, for anything that has
  ## to meet an object on screen: a rubber-band leaving it, a comet aimed from it, a menu
  ## hanging off it.
  ##   Reads `anchor_override` exactly as `addPlane` and `marker.markerFor` read it, so a
  ##   plane's disc has one centre and not two. It matters: on this project's own demo scene
  ##   the stored creation anchor stands 0.5, 2.7 and 3.7 units from the support, against a
  ##   disc of radius 8, so a band drawn from the support leaves from a point nowhere on the
  ##   circle a reader can see.
  ##   Ignored for every other shape, as `addObject` ignores it: a point and a line are
  ##   drawn about their own places whatever an item happens to carry.
  if anchor_override.isSome and shape(m) == some(Shape.Plane): return anchor_override
  anchorFor(m, scale)



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


func pointFrom*(m: Multivector): Position =
  ## Read a point assembled by the tessellation back out for the boundary.
  ##   Exported for `marker` and `picking`, whose own sampling loops assemble points the
  ##   same way and read them out at the same boundary.
  ##   Every caller here builds `m` as a unit-weight point plus weightless directions, so
  ##   the weight is exactly one and the read cannot refuse; asserted rather than silently
  ##   defaulted, because a zero weight here means the assembly upstream is wrong.
  let read = position(m)
  doAssert read.isSome, "A tessellated point must carry weight; its assembly is wrong."
  read.get


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
  ##   **The join is the implementation, and it is the hot path's largest cost -- kept.**
  ##   Every ribbon of every frame runs this, ~3,800 times a frame while the camera moves,
  ##   and under the JS backend each `∧` of full multivectors walks 16x16 coefficient
  ##   pairs through `nimCopy`; a written-out cross product was measured 6.7 ms a frame
  ##   cheaper and was shipped briefly, then reverted -- exercising the algebra is what
  ##   this project exists to do, and a cost it carries is a finding, not a fault. See
  ##   PROVENANCE.md's bottleneck ledger. The suite still holds this normal equal to the
  ##   classical cross product, sign included -- the classical form lives in the test.
  directionNormal(toMultivector(tail) ∧ toMultivector(head) ∧ toMultivector(eye))


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
  tint_tail, tint_head: Rgba; width: float32; scale: DrawExtent
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


proc addSegment*(
  meshes: var MeshSet; tail, head: Position; tint_tail, tint_head: Rgba; width: float32;
  scale: DrawExtent
) =
  ## Append the ribbon for one segment, deriving its own across direction.
  ##   The general form: the across is the join's normal, per segment -- see
  ## `directionAcross` -- and the packing is `addSegmentAcross`'s. Silently appends
  ## nothing where the segment has no side to step off toward: zero length, or an eye
  ## lying on its own line, where the ribbon is edge-on and covers no pixels anyway.
  let across = directionAcross(tail, head, scale.eye)
  if across.isNone: return
  meshes.addSegmentAcross(tail, head, across.get, tint_tail, tint_head, width, scale)

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
  # The circle's own frame, hoisted: the centre and its two radius-long arms as
  #   multivectors, one assembly per circle; each point is then two scaled arms on the
  #   centre, read out at the boundary.
  let
    centre_point = toMultivector(center)
    arm_first = wedge(radius, toMultivector(axis_first))
    arm_second = wedge(radius, toMultivector(axis_second))
  for i in 0 ..< segments:
    let
      angle_a = (2.0*PI * float(i)) / float(segments)
      angle_b = (2.0*PI * float(i + 1)) / float(segments)
      point_a = pointFrom(add(centre_point,
        add(wedge(cos(angle_a), arm_first), wedge(sin(angle_a), arm_second))))
      point_b = pointFrom(add(centre_point,
        add(wedge(cos(angle_b), arm_first), wedge(sin(angle_b), arm_second))))
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
  let
    centre_point = toMultivector(center)
    arm_first = wedge(radius, toMultivector(axis_first))
    arm_second = wedge(radius, toMultivector(axis_second))
  for i in 0 ..< segments:
    let
      angle_a = (2.0*PI * float(i)) / float(segments)
      angle_b = (2.0*PI * float(i + 1)) / float(segments)
      point_a = pointFrom(add(centre_point,
        add(wedge(cos(angle_a), arm_first), wedge(sin(angle_a), arm_second))))
      point_b = pointFrom(add(centre_point,
        add(wedge(cos(angle_b), arm_first), wedge(sin(angle_b), arm_second))))
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
  let
    centre_point = toMultivector(center)
    arm_first = wedge(radius, toMultivector(axis_first))
    arm_second = wedge(radius, toMultivector(axis_second))
  for i in 0 ..< segments:
    let
      angle_a = (2.0*PI * float(i)) / float(segments)
      angle_b = (2.0*PI * float(i + 1)) / float(segments)
      point_a = pointFrom(add(centre_point,
        add(wedge(cos(angle_a), arm_first), wedge(sin(angle_a), arm_second))))
      point_b = pointFrom(add(centre_point,
        add(wedge(cos(angle_b), arm_first), wedge(sin(angle_b), arm_second))))
    meshes.addSegment(point_a, point_b, tint, WIDTH_LINE_OBJECT, scale)


func spherePoint(centre_point: Multivector; radius: float; theta, phi: float): Position =
  ## Place point on sphere around the centre point, at colatitude `theta`, longitude `phi`.
  ##   The angles parametrise a unit direction -- ground-field trig -- and the point is
  ##   the centre plus that direction scaled, assembled through the algebra.
  pointFrom(add(centre_point, wedge(radius, toMultivector(Direction(
    x: sin(theta)*cos(phi), y: sin(theta)*sin(phi), z: cos(theta)
  )))))


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
  let centre_point = toMultivector(center)
  for lat in 0 ..< latitudes:
    let
      theta_a = PI * float(lat) / float(latitudes)
      theta_b = PI * float(lat + 1) / float(latitudes)
    for lon in 0 ..< longitudes:
      let
        phi_a = 2.0*PI * float(lon) / float(longitudes)
        phi_b = 2.0*PI * float(lon + 1) / float(longitudes)
      meshes.addQuad([
        spherePoint(centre_point, radius, theta_a, phi_a),
        spherePoint(centre_point, radius, theta_a, phi_b),
        spherePoint(centre_point, radius, theta_b, phi_b),
        spherePoint(centre_point, radius, theta_b, phi_a),
      ], tint)



#[ World Furniture ]#

func alphaGridFade(radius, radius_fade_start, radius_end: float): float =
  ## Fall from full alpha at `radius_fade_start` to none at `radius_end` -- past the
  ## fade start, a grid line's own cells crowd into fewer and fewer screen pixels
  ## under perspective, reading as aliasing noise rather than as a reference; fading
  ## them out trades that noise for a clean horizon instead of fighting it.
  ##   `radius` is a distance **from the eye**, and the two bounds come from
  ##   `fogFurnitureFor`; see it for why the fog is centred there and not on the origin.
  ##   Shared with `addAxes`, which fades on the same schedule so that all the world
  ##   furniture ends at one horizon rather than the grid stopping while the axes run on.
  1.0 - clamp((radius - radius_fade_start) / (radius_end - radius_fade_start), 0.0, 1.0)


proc addAxes*(meshes: var MeshSet; extent: float; scale: DrawExtent) =
  ## Append world axes through origin, each in the standard convention: x red, y green,
  ## z blue, so orientation reads at a glance regardless of where the camera stands.
  ##   **Faded out and cut off in the ground grid's own fog**, rather than running the
  ## full furniture extent at flat alpha as they once did. An axis reaching the horizon at
  ## full strength is the longest, brightest mark in the frame, and readers were taking
  ## them for drawn lines -- width alone (`WIDTH_LINE_FURNITURE` against
  ## `WIDTH_LINE_OBJECT`) was never going to carry that on its own. Sharing the grid's own
  ## fog rather than taking radii of their own puts all the furniture inside one horizon,
  ## so reference reads as a neighbourhood around the *reader* and anything outside it is
  ## content.
  ##   Each axis is drawn only over the stretch of it lying inside that fog: a chord of
  ## the sphere of radius `radius_gone` about the eye, solved below. An axis the eye has
  ## flown clear of contributes nothing at all, which is what fog means -- the origin is
  ## a place in the world rather than a place the reader is tied to.
  const AXES_WORLD = [
    (Direction(x: 1, y: 0, z: 0), Ink.AxisX),
    (Direction(x: 0, y: 1, z: 0), Ink.AxisY),
    (Direction(x: 0, y: 0, z: 1), Ink.AxisZ),
  ]
  let fog = fogFurnitureFor(extent)
  for (axis, ink) in AXES_WORLD:
    # Chord of the fog sphere along this axis, about the eye's own perpendicular foot on
    #   it: the axis passes the eye at `separation`, so it is inside the fog for `half`
    #   either side of the foot and nowhere else. The foot is the algebra's orthogonal
    #   projection of the eye onto the axis line; the chord half-length stays a scalar
    #   solve, since a sphere has no representative in the rigid algebra -- the one
    #   documented exception, and the incidence feeding it is the library's own.
    let
      axis_line = wedge(toMultivector(ORIGIN_WORLD), toMultivector(axis))
      foot_raw = projectOrthogonal(scale.eye_point, axis_line)
      foot = position(foot_raw)
    if foot.isNone: continue
    let
      separation = distanceBetween(unitize(foot_raw), scale.eye_point)
      half_squared = fog.radius_gone*fog.radius_gone - separation*separation
    if half_squared <= 0.0: continue
    let
      half = sqrt(half_squared)
      tint = ink.colour
      foot_point = unitize(foot_raw)
      axis_point = toMultivector(axis)
      # One across for the whole axis: all its pieces lie on the one line, so they share
      #   the plane it joins with the eye -- the grid's own per-line rule.
      across_axis = directionNormal(wedge(axis_line, scale.eye_point))
    if across_axis.isNone: continue
    # Cut into the same number of pieces the grid uses, each faded by its own endpoints'
    #   distance from the eye, so the cutoff never reads as a hard edge.
    for j in 0 ..< 2*SEGMENTS_GRID_FADE:
      let
        end_tail = add(foot_point,
          wedge(half*(float(j)/float(SEGMENTS_GRID_FADE) - 1.0), axis_point))
        end_head = add(foot_point,
          wedge(half*(float(j + 1)/float(SEGMENTS_GRID_FADE) - 1.0), axis_point))
        tint_tail = tint.fade(tint.alpha * alphaGridFade(
          distanceBetween(end_tail, scale.eye_point), fog.radius_full, fog.radius_gone))
        tint_head = tint.fade(tint.alpha * alphaGridFade(
          distanceBetween(end_head, scale.eye_point), fog.radius_full, fog.radius_gone))
      meshes.addSegmentAcross(
        pointFrom(end_tail), pointFrom(end_head), across_axis.get, tint_tail, tint_head,
        WIDTH_LINE_FURNITURE, scale,
      )


func segmentsGridFadeFor*(count_lines: int): int =
  ## Choose how many pieces each of `count_lines` grid lines is cut into for its fade.
  ##   `SEGMENTS_GRID_FADE` wherever the whole family fits inside its half of
  ## `SEGMENTS_GRID_MAX`, and as few as `SEGMENTS_GRID_FADE_MIN` where it does not. The
  ## budget is halved because the grid is two families laid the same way, and neither
  ## knows what the other will draw.
  ##   A pure function of the count so the rule can be held on its own by the suite,
  ## rather than only observable through a vertex total.
  if count_lines <= 0: return SEGMENTS_GRID_FADE
  let allowed = (SEGMENTS_GRID_MAX div 2) div count_lines
  max(SEGMENTS_GRID_FADE_MIN, min(SEGMENTS_GRID_FADE, allowed))


proc addGridFamily(
  meshes: var MeshSet; scale: DrawExtent; tint: Rgba;
  fog: tuple[radius_full, radius_gone: float]; radius_ground, size_cell: float;
  along, across: Direction
) =
  ## Append one family of ground grid lines: every lattice line running along `along`,
  ## stepped by `size_cell` along `across`, that falls within `radius_ground` of the
  ## point on the ground directly below the eye.
  ##   The cell is passed in rather than read from `SIZE_CELL_GRID` so that both families
  ## are laid on the one `sizeCellGridFor` answered for this frame's disc; two calls could
  ## not disagree, but a reader of one family should not have to prove that.
  ##   The two families are laid separately, unlike the single origin-centred loop this
  ## replaced, because each is now centred on a different one of the eye's own ground
  ## coordinates and no longer shares the other's offsets.
  ##   Lines still sit on **world** multiples of the cell size rather than on offsets from
  ## the camera, so what the reader sees slide past as they move is the world going by,
  ## not a grid dragged along with them -- and a line stays where it was when they come
  ## back to it.
  # The eye resolved onto the two lattice axes: its depth against the plane through the
  #   origin perpendicular to each -- the algebra's statement of a coordinate. One plane
  #   per family per frame, hoisted here rather than rebuilt per lattice line.
  let
    origin_point = toMultivector(ORIGIN_WORLD)
    along_point = toMultivector(along)
    across_point = toMultivector(across)
    centre_across = depthAgainst(planeThrough(origin_point, across_point), scale.eye_point)
    centre_along = depthAgainst(planeThrough(origin_point, along_point), scale.eye_point)
    first = int(ceil((centre_across - radius_ground)/size_cell))
    last = int(floor((centre_across + radius_ground)/size_cell))
    # How finely each line is cut for its fade, decided once for the family from how many
    #   lines it is about to lay: the budget is a property of the family, and a per-line
    #   answer would cut neighbouring lines differently and band the fade across the grid.
    segments_fade = segmentsGridFadeFor(last - first + 1)
  for i in first .. last:
    # Skips the lattice line through the world origin: it coincides exactly with a world
    #   axis, and would either fight it for the same depth or hide its colour under plain
    #   grid grey, depending on which happened to draw last.
    if i == 0: continue
    let
      offset = float(i)*size_cell
      reach_squared = radius_ground*radius_ground -
        (offset - centre_across)*(offset - centre_across)
    if reach_squared <= 0.0: continue
    let
      reach = sqrt(reach_squared)
      # One base point and **one across** per lattice line: every fade piece lies on this
      #   line, so they share the plane it joins with the eye, and deriving that join's
      #   normal once here is the same algebra the per-piece form ran once a piece.
      base = add(origin_point,
        add(wedge(offset, across_point), wedge(centre_along, along_point)))
      across_line = directionNormal(wedge(wedge(base, along_point), scale.eye_point))
    # An eye on the lattice line itself has no side to step a ribbon off toward -- the
    #   very refusal `addSegment` makes per piece, made once for the line.
    if across_line.isNone: continue
    for j in 0 ..< segments_fade:
      let
        a = reach * (2.0*float(j)/float(segments_fade) - 1.0)
        b = reach * (2.0*float(j + 1)/float(segments_fade) - 1.0)
        end_a = add(base, wedge(a, along_point))
        end_b = add(base, wedge(b, along_point))
        tint_a = tint.fade(tint.alpha * alphaGridFade(
          distanceBetween(end_a, scale.eye_point), fog.radius_full, fog.radius_gone))
        tint_b = tint.fade(tint.alpha * alphaGridFade(
          distanceBetween(end_b, scale.eye_point), fog.radius_full, fog.radius_gone))
      meshes.addSegmentAcross(
        pointFrom(end_a), pointFrom(end_b), across_line.get, tint_a, tint_b,
        WIDTH_LINE_FURNITURE, scale,
      )


proc addGrid*(meshes: var MeshSet; extent: float; scale: DrawExtent) =
  ## Append reference grid on the ground, so distance and direction stay judgeable, at
  ## `sizeCellGridFor` cells laid around wherever the camera is standing.
  ##   **Fog, not a halo.** Every line is faded by its own endpoints' distance from the
  ## eye and cut off entirely at `fogFurnitureFor`'s outer radius -- so the ground is
  ## solid underfoot and gone in the distance, wherever the reader has flown to. Cutting
  ## the geometry rather than drawing it at ever-fainter alpha is deliberate: past that
  ## radius cells crowd into so few screen pixels under perspective that even a faint line
  ## still aliases.
  ##   Drawn on the ground plane, so what the fog sphere leaves is a **disc** about the
  ## point below the eye, of radius `sqrt(radius_gone^2 - height^2)`: a camera high above
  ## the ground sees less of it than one standing on it, exactly as fog would leave.
  ## An eye higher than the fog reaches sees no ground at all.
  ##   Dimmed by `ALPHA_GRID` on top of that fade, so the ruled ground reads as reference
  ## rather than as content; see that constant for why it is applied here and not to the
  ## palette entry.
  let
    base = Ink.Grid.colour
    tint = base.fade(base.alpha*ALPHA_GRID)
    fog = fogFurnitureFor(extent)
    # The eye's height over the ground, read as its depth against the ground's own plane
    #   -- `objects.groundPlane`, the algebra's one spelling of it.
    height = abs(depthAgainst(groundPlane(), scale.eye_point))
    radius_squared = fog.radius_gone*fog.radius_gone - height*height
  if radius_squared <= 0.0: return
  let
    radius_ground = sqrt(radius_squared)
    size_cell = sizeCellGridFor(radius_ground)
  meshes.addGridFamily(
    scale, tint, fog, radius_ground, size_cell,
    along = Direction(x: 0, y: 1, z: 0), across = Direction(x: 1, y: 0, z: 0),
  )
  meshes.addGridFamily(
    scale, tint, fog, radius_ground, size_cell,
    along = Direction(x: 1, y: 0, z: 0), across = Direction(x: 0, y: 1, z: 0),
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
    pointFrom(add(scale.eye_point,
      wedge(progress*scale.radius_horizon, toMultivector(heading.get)))),
    tint.fade(tint.alpha*progress),
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
      axis_point = toMultivector(axis.get)
      far_ahead = pointFrom(add(scale.eye_point, wedge(reach, axis_point)))
      far_behind = pointFrom(add(scale.eye_point, wedge(-reach, axis_point)))
    meshes.addSegment(anchor.get, far_ahead, tint_progress, WIDTH_LINE_OBJECT, scale)
    meshes.addSegment(anchor.get, far_behind, tint_progress, WIDTH_LINE_OBJECT, scale)
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
