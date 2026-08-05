## Visualise and manipulate geometric objects of RGA, live, in an SDL3 window.
##
## Prototype covers 4D rigid PGA only, i.e. 3D Euclidean space, where grade names object:
## grade 1 is point, grade 2 is line, grade 3 is plane.
##   Conformal metric is out of scope until library's round objects settle.
##
## Everything drawn is asked of library rather than derived beside it:
##
##   |-------------------|----------|------------------------------------------------|
##   | Expression        | Lengyel  | Meaning                                        |
##   |-------------------|----------|------------------------------------------------|
##   | p ∧ q             | join     | Line through two points.                       |
##   | p ∧ q ∧ r         | join     | Plane through three points.                    |
##   | g ∨ h             | meet     | Line where two planes cross.                   |
##   | L ∨ g             | meet     | Point where line pierces plane.                |
##   | ∩m                | sup(m)   | Point of object nearest origin.                |
##   | ⊖m                | att(m)   | Direction of object, standing at horizon.      |
##   | e ∧ t             | join     | Camera's own sight axis, and frame from it.    |
##   |-------------------|----------|------------------------------------------------|
##
## Bootstrap order, left to right:
##
##   pga -> objects -> mesh -> scene -> panel ------------> visualiser
##                       |       ^--------^                  ^
##   camera -> picking --+-> interaction ---------------------
##                       +-> marker ---------------------------
##   sdl3 -> gui ----------------------------------------------
##   opengl -> renderer -----------------------------------------
##   scene -> storyboard -------------------------------------------
##
##   objects reads drawable quantities out of multivectors.
##   mesh tessellates those quantities into vertices, into fixed storage.
##   camera orbits, and assembles transforms from its own RGA-derived frame.
##   picking hit-tests scene items in screen space, against those same transforms.
##   marker shapes a selection or hover outline to the object it marks, in the same space.
##   renderer owns OpenGL names and draws the meshes.
##   scene holds objects and catalogue of operations that derive new ones.
##   selection holds which objects are picked, in the order that names an operation's operands.
##   interaction tracks a mouse drag from one item to another, and applies what they make.
##   panel lays out the widgets user edits scene through.
##   storyboard scripts a construction, one operation per exported frame.
##   image encodes a frame readback as PNG.
##
## Render paths: this file is the native desktop entry point (SDL3/OpenGL/Dear ImGui,
## compiled `--backend:cpp` per `visualiser.nim.cfg`); `visualiser/browser/browser_bridge.nim`
## is the browser entry point (compiled through `nim js` per its own sibling
## `browser_bridge.nim.cfg`, presentation done by hand-written JS living outside this
## repo). Neither imports the other, and nothing shared imports either render target's
## own presentation layer.
##
## **The directory a module sits in is which render path may reach it**, so the boundary is
## read off the layout rather than off a table that has to be kept in step with it:
##
##   |----------------------|--------------------------------------------------------|
##   | Directory            | Reachable from                                         |
##   |----------------------|--------------------------------------------------------|
##   | `visualiser/core`    | Both. Geometry, scene, and everything derived from it.  |
##   | `visualiser/desktop` | This file only. SDL3, OpenGL, Dear ImGui, PNG, GIF.     |
##   | `visualiser/browser` | `browser_bridge.nim` only. Bridge, markup, glue.        |
##   |----------------------|--------------------------------------------------------|
##
## `pga` is vendored above all three and shared by both. `core` imports nothing outside
## itself and `pga`; `desktop` and `browser` each import `core` and never each other. A
## `core` module needing something only one path has states that as `when not defined(js)`
## and is exercised on both backends by the suite, rather than left to a comment to police.
##
## Controls:
##   Drag from one object to another to derive a third. What it derives is read off the
##   two grades, not off the button, and ghosted while you drag so the gesture shows its
##   answer before it commits it; the rubber-band is tinted to match, and wears the
##   reserved magenta over a pair that makes nothing. Left takes that answer; right opens
##   a four-way choice menu instead, as does holding still over the target. `more…` in
##   that menu hands both operands to the apply section, for the other twenty-four.
##   Drag from empty space instead to move the camera: left orbits, right pans, wheel dollies.
##   `S` writes current frame to the export path. `Escape` abandons whatever is in
##   progress -- the help panel, a drag, an open edit, a selection -- and `ctrl+Z` and
##   `ctrl+shift+Z` step the same timeline the panel's own undo and redo buttons do.
##   `ctrl+Q` quits; `Escape` used to, and pressing it twice to be sure of a cancel would
##   have thrown away an unsaved scene.
##   The `?` in the bottom-right corner says all of this, from `help.nim`, which the
##   browser build's own help panel reads too.
##   Every panel is a collapsing header; `diagnostics` starts closed and holds live frame
##   time, memory use of both arenas, and the object pool -- nothing needed day to day.
##
## Command line, for validating a build without sitting in front of it:
##   `--screenshot:PATH` writes one PNG, `--frames:N` exits after N frames,
##   `--hidden` never maps the window, and `--storyboard:DIR` writes one frame per
##   scripted construction step and quits.
##   `--timings` reports frame-time statistics (mean, percentiles, tessellation cost)
##   over a `--frames:N` run; `--novsync` disables vsync from startup for an uncapped
##   reading, and `--fill` tops the scene up to capacity first, for the heaviest case.
##   `--drive-drag` scripts a construction drag through SDL's own event queue, so a
##   headless run can be caught mid-gesture with its choice menu open; `--drive-keys`
##   scripts a run of view keys through that same queue and reports what the camera and
##   focus did, which is how "Dear ImGui swallows them" gets measured rather than assumed;
##   `--drive-undo` builds something, orbits away from it and undoes it, so where undo
##   leaves the view can be looked at rather than reasoned about.

{.experimental: "strictFuncs".}

when compileOption("profiler"):
  import std/nimprof

import std/[algorithm, math, monotimes, options, os, parseopt, strformat, strutils]

import ./pga
import ./visualiser/core/[
  camera, format, help, history, interaction, marker, mesh, objects, picking, scene,
  selection, storyboard,
]
import ./visualiser/desktop/[arena, gif, gui, image, panel, renderer]
import ./visualiser/desktop/opengl as gl
import ./visualiser/desktop/sdl3



#[ Application Configuration ]#

const
  TITLE* = "Projective Geometric Algebra Illuminated — RGA workbench"
  SAMPLES_MULTISAMPLE* {.define: "visualiser.samples_multisample".} = 4
    ## Ask the framebuffer for this many samples per pixel. Four is where a 1.5-pixel
    ## ribbon stops reading as dotted; more buys little on geometry this thin. Settable so
    ## a machine whose visuals top out lower can still ask for what it has.
  PIXELS_WIDTH* {.define: "visualiser.pixels_width".} = 1440
  PIXELS_HEIGHT* {.define: "visualiser.pixels_height".} = 900
  PATH_FONT* {.define: "visualiser.path_font".} =
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
    ## Carry the UI's own text: Latin, punctuation, subscripts and combining marks.
  PATH_FONT_MATH* {.define: "visualiser.path_font_math".} =
    "/usr/share/fonts/truetype/noto/NotoSansMath-Regular.ttf"
    ## Carry the operators the notation is written with, and Lengyel's bold operands --
    ## neither of which Noto Sans itself has. Merged into the same atlas font; see
    ## `gui_shim.cpp`.
  PATH_FONT_SYMBOL* {.define: "visualiser.path_font_symbol".} =
    "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf"
    ## Carry the bulk and weight dual stars and the abandon button's cross, which neither
    ## face above has. Merged the same way.
  SIZE_FONT* = 16.0'f32
  PATH_EXPORT_DEFAULT* = "rga_workbench.png"

const
  SPEED_ORBIT = 0.008
    ## Set how far a dragged pixel turns the orbit, in radians.
  SPEED_PAN = 0.0016
    ## Set how far a dragged pixel slides the target, as fraction of orbit distance.
  FACTOR_DOLLY = 1.12
    ## Set how much one wheel notch scales orbit distance.
  FRAMES_SETTLE = 2
    ## Draw this many frames before capturing, so widget layout has settled.
  INK_GHOST = Ink.Guide
    ## Palette slot the add panel's own uncommitted multivector draws in, muted -- reuses
    ## `Ink.Guide`'s existing "construction helper" meaning rather than adding a palette
    ## entry for this alone. Mirrors `browser_bridge.INK_GHOST`.
  FRAMES_GIF_GROW = 6
    ## Set how many sub-frames sweep each storyboard step's own appear animation.
  FRAMES_GIF_HOLD = 4
    ## Set how many repeated frames hold on a step's settled result, so playback reads.
  CENTISECONDS_GIF_DELAY = 8
    ## Set hold time per GIF frame, in hundredths of a second.
  STRIDE_GIF = 2
    ## Keep every this-many-th pixel in both directions, so the storyboard's GIF stays
    ## a short preview rather than a full-resolution capture nobody asked for.
  WIDTH_SHAPE_WORD = 32
    ## Bound length of the shape word alone, longest being "mixed grade, nothing to draw".
  WIDTH_EXPORT_MAX* {.define: "visualiser.width_export_max".} = 3840
    ## Bound the largest window a pixel readback or PNG export is ever asked to cover.
  HEIGHT_EXPORT_MAX* {.define: "visualiser.height_export_max".} = 2160
  CAPACITY_ARENA_PERMANENT* {.define: "visualiser.capacity_arena_permanent".} = 160*1024*1024
    ## Set the permanent arena's own size: the pixel readback buffer, and every
    ## storyboard GIF frame collected before the final GIF is written, live here for
    ## as long as the process runs. Sized for `STRIDE_GIF`'s own downsample plus
    ## `WIDTH_EXPORT_MAX`x`HEIGHT_EXPORT_MAX`'s own readback, with headroom to spare --
    ## raised from an earlier 128 MiB alongside `STEPS`, since GIF frame storage scales
    ## with how many steps the storyboard now has.
  CAPACITY_ARENA_FRAME* {.define: "visualiser.capacity_arena_frame".} = 64*1024*1024
    ## Set the frame arena's own size: whichever of PNG's filtered/compressed scanlines
    ## or one GIF frame's quantized indices and LZW output is using it, reclaimed the
    ## moment that single unit of work is written out.
  FRAMES_TIMING_MAX* {.define: "visualiser.frames_timing_max".} = 20_000
    ## Bound how many per-frame timings `--timings` can record; independent of either
    ## arena above, since a benchmarking run is not itself the interactive draw loop
    ## either arena was carved to serve.
  BYTES_MEMORY_TOTAL* =
    CAPACITY_ARENA_PERMANENT + CAPACITY_ARENA_FRAME +
    sizeof(MeshSet) + sizeof(Scene) + sizeof(Workbench) + FRAMES_TIMING_MAX*sizeof(float32)
    ## Sum of every fixed-size reservation this binary makes for itself: both arenas at
    ## their full capacity, committed in the data segment regardless of use; tessellation
    ## storage; the object pool; the panel's own state, frame-time ring buffer included;
    ## and the `--timings` benchmark buffer. Excludes anything Dear ImGui, SDL, or the
    ## graphics driver allocate on their own account, which this process cannot see.

static:
  doAssert PIXELS_WIDTH >= 640 and PIXELS_HEIGHT >= 480,
    &"Window must be at least 640x480; got `{PIXELS_WIDTH}x{PIXELS_HEIGHT}`."
  doAssert PIXELS_WIDTH <= WIDTH_EXPORT_MAX and PIXELS_HEIGHT <= HEIGHT_EXPORT_MAX,
    &"Window must fit within the {WIDTH_EXPORT_MAX}x{HEIGHT_EXPORT_MAX} export bound; " &
    &"raise `--define:visualiser.width_export_max` or `...height_export_max`."

# Hold vertex storage at module scope, as it is far too large to sit on a stack frame.
var MESHES: MeshSet ## Every scene object, excluding world furniture below.
var MESHES_FURNITURE: MeshSet ## Ground grid and world axes alone, drawn in their own pass
  ## before the scene's, so every object's translucent wash blends over the reference marks
  ## rather than under whichever of them happened to be emitted later. Their thinner width
  ## (`mesh.WIDTH_LINE_FURNITURE`) is geometry now, not a draw setting, so it no longer
  ## needs a pass of its own -- this ordering does.
var HISTORY: History ## Undo/redo timeline of scene-content edits; too large for a stack
  ## frame for the same reason `MESHES` is (`history.CAPACITY_HISTORY * sizeof(Scene)`).
  ## Holds a zeroed placeholder nothing reads until `main` seeds it via `initHistory`
  ## once the startup scene (demo or loaded) is built.

# Two arenas, one permanent and one reset after each throwaway unit of work; see
#   `arena.nim` for why the interactive draw loop needs neither, and what does.
var
  BUFFER_ARENA_PERMANENT: array[CAPACITY_ARENA_PERMANENT, byte]
  ARENA_PERMANENT = initArena(BUFFER_ARENA_PERMANENT)
  BUFFER_ARENA_FRAME: array[CAPACITY_ARENA_FRAME, byte]
  ARENA_FRAME = initArena(BUFFER_ARENA_FRAME)

# Carved once from the permanent arena: the pixel readback every export reuses.
var PIXELS_READBACK = push[uint8](ARENA_PERMANENT, WIDTH_EXPORT_MAX*HEIGHT_EXPORT_MAX*3)

# Carved once from the permanent arena: every GIF frame a storyboard run collects,
#   back to back, before `writeGif` reads them all at once at the very end.
const
  WIDTH_GIF_MAX = PIXELS_WIDTH div STRIDE_GIF
  HEIGHT_GIF_MAX = PIXELS_HEIGHT div STRIDE_GIF
  COUNT_GIF_FRAMES_MAX = (len(STEPS) + 1) * (FRAMES_GIF_GROW + FRAMES_GIF_HOLD)
var GIF_FRAMES =
  push[uint8](ARENA_PERMANENT, COUNT_GIF_FRAMES_MAX*WIDTH_GIF_MAX*HEIGHT_GIF_MAX*3)

# Hold at module scope for the same reason `MESHES` does: too large for a stack frame,
#   and only ever touched by a `--timings` run, never by the interactive loop otherwise.
var TIMINGS_FRAME_MILLISECONDS: array[FRAMES_TIMING_MAX, float32]



#[ Command Line ]#

type Options = object ## Hold what command line asked of this run.
  path_screenshot: string ## Where one-shot export is written; empty for none.
  path_storyboard: string ## Directory scripted construction is written to; empty for none.
  path_load_scene: string ## Scene file to open instead of the built-in demo; empty for none.
  count_frames: int ## Frames to draw before quitting; 0 to run until closed.
  is_hidden: bool ## Whether window is left unmapped.
  is_timed: bool ## Whether to record and report per-frame timing statistics.
  is_novsync: bool ## Whether to disable vsync from startup, for uncapped timing runs.
  is_filled: bool ## Whether to top scene up to capacity with synthetic items, for
    ## timing the heaviest tessellation and draw load rather than the demo's own light one.
  is_drag_driven: bool ## Whether to script a construction drag through the event queue,
    ## so a headless run can be made to show a drag mid-gesture. See `driveDrag`.
  is_key_driven: bool ## Whether to script a run of view keys through the event queue, so
    ## a headless run can show that they reach the view at all. See `driveKeys`.
  is_select_driven: bool ## Whether to script clicks that pick one, two and three objects,
    ## so a headless run can show the floating selection menu at each. See `driveSelect`.
  is_undo_driven: bool ## Whether to script a construction, an orbit away from it and the
    ## undo of it, so a headless run can show where undo leaves the view. See `driveUndo`.
  path_help_driven: Option[HelpPath] ## Which help tab to open at startup, if any. A
    ## headless run cannot click a tab strip, so `--drive-help:<tab>` names one; without
    ## it the panel stays shut, exactly as it does for a reader who has not asked for it.


proc parseOptions(): Options =
  ## Read command line into options, rejecting anything unrecognised.
  for kind, key, value in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "screenshot": result.path_screenshot = value
      of "storyboard": result.path_storyboard = value
      of "load-scene": result.path_load_scene = value
      of "frames": result.count_frames = parseInt(value)
      of "hidden": result.is_hidden = true
      of "timings": result.is_timed = true
      of "novsync": result.is_novsync = true
      of "fill": result.is_filled = true
      of "drive-drag": result.is_drag_driven = true
      of "drive-keys": result.is_key_driven = true
      of "drive-select": result.is_select_driven = true
      of "drive-undo": result.is_undo_driven = true
      of "drive-help":
        for path in HelpPath:
          if titleOf(path) == value: result.path_help_driven = some(path)
        doAssert result.path_help_driven.isSome,
          &"Unknown help tab `{value}`; expected one this build actually has."
      else:
        doAssert false,
          &"Unknown option `--{key}`; expected screenshot, storyboard, load-scene, " &
          "frames, hidden, timings, novsync, fill, drive-drag, drive-keys, " &
          "drive-select, drive-undo or drive-help."
    of cmdArgument:
      doAssert false, &"Unexpected argument `{key}`; every input is a named option."
    of cmdEnd: discard



#[ Frame Assembly ]#

proc secondsNow(): float =
  ## Read monotonic clock as seconds, for animating how recently an item was added.
  ##   Nanosecond ticks, not seconds since any fixed epoch, but only ever differenced
  ##   against another reading from the same process, so that never matters.
  float(getMonoTime().ticks) / 1_000_000_000.0


proc offerCameraAim(
  workbench: var Workbench; scene: Scene; camera: Camera; now: float; scale: DrawExtent
) =
  ## Offer the camera whatever is being worked on to look at, from one rule rather than
  ## from each path that could change it: an open session's own staged multivector, or
  ## else the object solely selected -- which is exactly what every construction path
  ## leaves behind (`selectOnly`), so applying an operation, releasing a drag and stepping
  ## the storyboard all aim without knowing anything about the camera.
  ##   A standing offer, re-made every frame rather than at each event: `aimAt` ignores a
  ##   goal it already holds, so an unchanged scene costs nothing while a moving one -- a
  ##   coefficient being dragged -- reads as one continuous chase.
  ##   Anything that draws nothing (a still-empty composing session) aims at nothing and
  ##   releases, which is what lets picking the same object again aim at it afresh.
  let geometry =
    if workbench.session.isSome: some(workbench.session.get.geometry)
    elif workbench.selection.len == 1 and scene.isAlive(workbench.selection.at(0)):
      some(scene[workbench.selection.at(0)].geometry)
    else: none(Multivector)
  let aim = if geometry.isSome: aimFor(geometry.get, scale) else: none(CameraAim)
  if aim.isSome: workbench.tween_camera.aimAt(camera, aim.get, now, ANIMATION_SECONDS)
  else: workbench.tween_camera.release()


proc assembleMeshes(
  workbench: var Workbench; scene: Scene; interaction: Interaction;
  camera: Camera; now: float; scale: DrawExtent;
  are_dimmed: array[ITEMS_MAX, bool] = default(array[ITEMS_MAX, bool])
) =
  ## Refill vertex storage from scene as it stands this frame, recording what it cost.
  ##   `are_dimmed` grays an item out rather than skipping it -- empty (nothing dimmed)
  ##   for ordinary interactive rendering; the storyboard's own rolling emphasis is the
  ##   only caller that fills it in.
  ##   Assembles alone: where the camera should be looking is `offerCameraAim`'s own job,
  ##   called beside this one rather than from inside it.
  let ticks_start = getMonoTime().ticks
  MESHES_FURNITURE.clearMeshes
  if workbench.is_grid_shown: MESHES_FURNITURE.addGrid(scale.extent_furniture, scale)
  if workbench.is_axes_shown: MESHES_FURNITURE.addAxes(scale.extent_furniture, scale)

  MESHES.clearMeshes
  # A horizon plane's own dome first, before anything else that might share its own
  #   translucent `Primitive.Triangle` bucket: that bucket draws in whatever order its
  #   vertices were appended, unsorted by depth, so inserting the dome first guarantees
  #   every ordinary plane's own fill -- however near or far, whichever scene slot it
  #   occupies -- blends over it rather than risking the reverse should scene order
  #   alone have put the dome's own vertices later. Without this, a nearby plane could
  #   end up looking hazed by the sky behind it purely from slot ordering, not from
  #   anything about actual position.
  for slot, item in scene.pairs:
    if not item.isVisible or not isHorizonPlane(item.geometry): continue
    let progress = animationProgress(now, item.born)
    let tint = if are_dimmed[slot]: muted(item.ink.colour) else: item.ink.colour
    discard MESHES.addObject(item.geometry, tint, scale, progress, item.anchorOverride)

  for slot, item in scene.pairs:
    if not item.isVisible or isHorizonPlane(item.geometry): continue
    let progress = animationProgress(now, item.born)
    let tint = if are_dimmed[slot]: muted(item.ink.colour) else: item.ink.colour
    discard MESHES.addObject(item.geometry, tint, scale, progress, item.anchorOverride)

  # The open edit session's own staged multivector, drawn through the same dispatch a
  #   real object uses so composing or reshaping one shows exactly what saving it would
  #   give. Never enters `scene`, so picking, undo/redo and save stay unaware of it; an
  #   all-zero staging degrades to "nothing to draw" through `addObject`'s own
  #   empty-shape branch. While editing an existing object, this draws beside it: the
  #   object holds its committed position and the ghost shows where it would land.
  if workbench.session.isSome:
    discard MESHES.addObject(workbench.session.get.geometry, muted(INK_GHOST.colour), scale)

  # What the drag in progress would build, drawn through that same dispatch and in that
  #   same ghost ink, so a reader learns one "this is not committed yet" appearance rather
  #   than two. This is the whole answer to the drag having had no self-revelation: the
  #   gesture stops being a guess about a button and becomes a thing you watch happen.
  if interaction.preview.isSome:
    discard MESHES.addObject(interaction.preview.get, muted(INK_GHOST.colour), scale)

  workbench.microseconds_tessellate = float(getMonoTime().ticks - ticks_start) / 1000.0
  workbench.count_vertices = 0
  for primitive in Primitive:
    workbench.count_vertices += MESHES[primitive].count_vertices +
      MESHES_FURNITURE[primitive].count_vertices


proc drawMarker(marker: Marker; tint: Rgba; alpha: float32) =
  ## Stroke one marker onto the foreground layer, in whichever outline its shape asked
  ## for.
  ##   Takes alpha separately from `tint` so selection and hover reach this through the
  ##   identical call and differ only in weight, rather than in what is drawn.
  case marker.kind
  of MarkerKind.Ring:
    gui.overlayArc(
      cfloat(marker.centre.x), cfloat(marker.centre.y), cfloat(marker.radius),
      cfloat(marker.fraction), tint.red, tint.green, tint.blue, alpha, WIDTH_MARKER,
    )
  of MarkerKind.Rails:
    for i in 0 ..< marker.count_segment:
      let piece = marker.segments[i]
      gui.overlayLine(
        cfloat(piece[0].x), cfloat(piece[0].y), cfloat(piece[1].x), cfloat(piece[1].y),
        tint.red, tint.green, tint.blue, alpha, WIDTH_MARKER,
      )
  of MarkerKind.Loop:
    # Flatten to the x/y pairs the shim's own path call takes; stack storage, since this
    #   runs once per marked item per frame and the bound is a compile-time constant.
    var points: array[2*SEGMENTS_MARKER_LOOP, cfloat]
    for i in 0 ..< marker.count_point:
      points[2*i] = cfloat(marker.points[i].x)
      points[2*i + 1] = cfloat(marker.points[i].y)
    gui.overlayPolyline(
      addr points[0], cint(marker.count_point), tint.red, tint.green, tint.blue, alpha,
      WIDTH_MARKER, cint(ord(marker.is_closed)),
    )


proc drawSelectionMarker(
  scene: Scene; selection: Selection; camera: Camera; view_projection: Matrix4;
  width, height: int; scale: DrawExtent
): int {.discardable.} =
  ## Draw one marker per selected item, directly onto the foreground layer, shaped to
  ## that item by `marker.markerFor` and tinted with `Ink.Outline`. Report how many were
  ## drawn.
  ##   One per selected slot rather than one overall: an operation reads two operands, and
  ##   a selection that cannot be seen in the view it acts on is not worth much. Matches
  ##   the browser overlay's own per-slot loop.
  ##   The count exists so a test can assert what was drawn without reading pixels; a
  ##   caller uninterested in it may discard it.
  ##   Unconditional, unlike hover/drag below: a storyboard step uses this same marker to
  ##   show which object it just built, so it must still draw with interaction disabled.
  let tint = Ink.Outline.colour
  for position in 0 ..< selection.len:
    let slot = selection.at(position)
    if not (scene.isAlive(slot) and scene[slot].isVisible): continue
    let item = scene[slot]
    let marker = markerFor(
      item.geometry, item.anchorOverride, scale, camera, view_projection, width, height
    )
    if marker.isNone: continue
    drawMarker(marker.get, tint, ALPHA_MARKER_SELECTED)
    result.inc


proc drawChoiceMenu(interaction: Interaction; scene: Scene) =
  ## Draw the four wedges of an open choice menu onto the foreground layer.
  ##   Every wedge is drawn at every opening, at its own fixed compass point, whether or
  ##   not it is offered -- so the position of `meet` is something a reader learns once
  ##   rather than something they read off each time. Which one the cursor stands in is
  ##   `interaction.choiceAt`'s answer, the same one the release will act on, so what is
  ##   highlighted is never a second opinion about where the cursor is.
  let
    centre = interaction.menu.get
    over = destinationOf(interaction)
    highlighted = choiceAt(centre, interaction.cursor)
    is_pair_live =
      over.isSome and over.get != interaction.index_source and
      scene.isAlive(over.get) and scene.isAlive(interaction.index_source)

  let dot = Ink.Outline.colour
  gui.overlayCircle(
    cfloat(centre.x), cfloat(centre.y), RADIUS_MENU_CENTRE,
    dot.red, dot.green, dot.blue, 0.7, WIDTH_MARKER,
  )
  for choice in DragChoice:
    let
      label = labelOf(choice)
      is_offered =
        choice == DragChoice.More or
        (is_pair_live and isOffered(
          choice, scene.geometryOf(interaction.index_source), scene.geometryOf(over.get)
        ))
      at = anchorOf(centre, choice)
      tint = inkOf(choice).colour
      width = gui.textWidth(cstring(label)) + PADDING_MENU_WEDGE
    gui.overlayChip(
      cfloat(at.x), cfloat(at.y), width, HEIGHT_MENU_WEDGE,
      tint.red, tint.green, tint.blue,
      cfloat(if is_offered: ALPHA_MENU_WEDGE else: ALPHA_MENU_UNOFFERED),
      ROUNDING_MENU_WEDGE,
    )
    # The wedge the cursor is in wears an outline as well as its fill, so the highlight
    #   survives being read by someone who cannot tell its fill from its neighbour's.
    if highlighted == some(choice):
      let edge = Ink.Outline.colour
      gui.overlayChip(
        cfloat(at.x), cfloat(at.y), width + 2.0*WIDTH_MARKER,
        HEIGHT_MENU_WEDGE + 2.0*WIDTH_MARKER,
        edge.red, edge.green, edge.blue, 0.9, ROUNDING_MENU_WEDGE + WIDTH_MARKER,
      )
      gui.overlayChip(
        cfloat(at.x), cfloat(at.y), width, HEIGHT_MENU_WEDGE,
        tint.red, tint.green, tint.blue,
        cfloat(if is_offered: ALPHA_MENU_WEDGE else: ALPHA_MENU_UNOFFERED),
        ROUNDING_MENU_WEDGE,
      )
    # An offered wedge is a solid fill and reads best with dark text on it; an unoffered
    #   one is barely a fill at all, so dark text on it disappears into the scene behind.
    #   Light text there instead, dimmed -- legible, and still obviously not a choice.
    let ink_label = (if is_offered: Ink.Backdrop else: Ink.Outline).colour
    gui.overlayText(
      cfloat(at.x), cfloat(at.y), ink_label.red, ink_label.green, ink_label.blue,
      cfloat(if is_offered: 1.0 else: 0.55), cstring(label),
    )


proc drawInteractionOverlay(
  interaction: Interaction; scene: Scene; camera: Camera; view_projection: Matrix4;
  width, height: int; scale: DrawExtent
) =
  ## Draw drag's rubber-band and hover's marker directly onto the foreground layer.
  ##   Off entirely during storyboard capture, where interaction is never enabled.
  if not interaction.is_enabled: return

  # Hover wears the selection's own marker at lower opacity rather than a shape of its
  #   own, so hovering a line previews exactly the rails selecting it would draw.
  #   Keyboard focus wears the very same marker: a reader who has never touched a pointer
  #   still sees where they are, and the focus indicator WCAG 2.4.7 asks for is machinery
  #   already built and already tested rather than a second one invented beside it.
  for index in [interaction.index_hover, interaction.index_focus]:
    if index.isNone or not scene.isAlive(index.get): continue
    let item = scene[index.get]
    let marker = markerFor(
      item.geometry, item.anchorOverride, scale, camera, view_projection, width, height
    )
    if marker.isSome:
      drawMarker(marker.get, Ink.Outline.colour, ALPHA_MARKER_HOVER)

  if interaction.is_dragging:
    let anchor = anchorFor(scene[interaction.index_source].geometry, scale)
    if anchor.isSome:
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if screen.isInFront:
        # Tinted by what releasing would do rather than by which button started the drag,
        #   which is the same rule the browser's rubber-band answers from.
        let tint = interaction.inkOfDrag.colour
        gui.overlayLine(
          cfloat(screen.x), cfloat(screen.y),
          cfloat(interaction.cursor.x), cfloat(interaction.cursor.y),
          tint.red, tint.green, tint.blue, 0.85, WIDTH_MARKER,
        )
  if interaction.menu.isSome:
    drawChoiceMenu(interaction, scene)



proc anchorOfSelection(
  workbench: Workbench; scene: Scene; view_projection: Matrix4; width, height: int;
  scale: DrawExtent
): Option[tuple[x, y: cfloat]] =
  ## Say where the most recently picked object sits on screen, for the floating selection
  ## menu to follow.
  ##   The *most recent* rather than the middle of them all: an average would jump about
  ##   as membership changes, for nothing. Projected through the same `anchorFor` the
  ##   rubber-band and the browser's own `nimAnchorScreen` use, so the menu, the marker and
  ##   the drag line all agree on where an object is.
  ##   None where there is nothing picked, where the object has no representative point,
  ##   or where it stands behind the camera -- see `layoutSelectionMenu` for what the menu
  ##   does with that.
  if workbench.selection.len == 0: return none(tuple[x, y: cfloat])
  let slot = workbench.selection.at(workbench.selection.len - 1)
  if not scene.isAlive(slot): return none(tuple[x, y: cfloat])
  let anchor = anchorFor(scene[slot].geometry, scale)
  if anchor.isNone: return none(tuple[x, y: cfloat])
  let screen = projectToScreen(view_projection, width, height, anchor.get)
  if not screen.isInFront: return none(tuple[x, y: cfloat])
  some((x: cfloat(screen.x), y: cfloat(screen.y)))


proc renderFrame(
  window: Window; renderer: Renderer;
  workbench: var Workbench; scene: var Scene; camera: var Camera; interaction: var Interaction;
  now: float; are_dimmed: array[ITEMS_MAX, bool] = default(array[ITEMS_MAX, bool]);
  path_help: Option[HelpPath] = none(HelpPath)
): (int, int) =
  ## Lay panels out, draw scene and interaction overlay, and report framebuffer size.
  ##   Panels run first, so an edit made this frame reaches meshes assembled below it.
  ##   Hover is recomputed here too, from this same frame's transform, so a drag started
  ##   next frame reads a pick that matches what was just drawn.
  ##   `now` is this frame's own clock reading; caller decides what clock that is, so a
  ##   real one drives interactive animation and a scripted one drives storyboard capture.
  ##   `are_dimmed` is forwarded to `assembleMeshes` untouched; see its own doc comment.
  ##   `path_help` is forwarded to `layoutHelp` untouched; see its own doc comment.
  var (width, height) = (cint(PIXELS_WIDTH), cint(PIXELS_HEIGHT))
  sdl3.getWindowSizeInPixels(window, addr width, addr height)

  # Snapshot both arenas before the panel that reads them draws, so what it shows this
  #   frame is this frame's own state; shared by both run modes, so a storyboard capture
  #   reports real figures too rather than whatever `Workbench` happened to start zeroed at.
  workbench.bytes_arena_permanent_used = ARENA_PERMANENT.used
  workbench.bytes_arena_permanent_capacity = ARENA_PERMANENT.capacity
  workbench.bytes_arena_frame_peak = ARENA_FRAME.peakUsed
  workbench.bytes_arena_frame_capacity = ARENA_FRAME.capacity
  workbench.bytes_memory_total = BYTES_MEMORY_TOTAL

  gui.frameBegin()
  # Consumed before layout, so a key pressed this frame and the button beside it reach the
  #   timeline through the identical call and land on the same frame.
  if workbench.is_undo_requested or workbench.is_redo_requested:
    let is_undo = workbench.is_undo_requested
    (workbench.is_undo_requested, workbench.is_redo_requested) = (false, false)
    toChars(
      if stepHistory(workbench, scene, camera, HISTORY, is_undo):
        (if is_undo: "Stepped back." else: "Stepped forward.")
      else:
        (if is_undo: "Nothing to undo." else: "Nothing to redo."),
      workbench.message,
    )
  layoutWorkbench(workbench, scene, camera, HISTORY, now)
  layoutHelp(workbench, path_help)

  # Advance before this frame's transforms are built, so the frame draws where the camera
  #   has reached rather than a frame behind. `offerCameraAim` below sets the goal this
  #   advance consumes next frame, which is one frame later by design -- there is nothing
  #   to advance toward until something has been aimed at.
  workbench.tween_camera.advance(camera, now, easeOutCubic)

  let scale = camera.drawExtentFor(int(height))
  offerCameraAim(workbench, scene, camera, now, scale)
  # Hover and the drag reading it run *before* meshes are assembled, so the drag's own
  #   preview is this frame's rather than last frame's. Costs nothing to order this way:
  #   the transform they pick against needs only the camera, which has already advanced.
  let view_projection = camera.initMatrixViewProjection(width / height)
  # The floating menu is placed here rather than beside the other panels because it has to
  #   be told where its object is on screen, which needs this frame's own transform -- and
  #   it is placed *before* meshes are assembled, so a delete pressed on it leaves the
  #   scene this frame draws rather than one object stale.
  layoutSelectionMenu(
    workbench, scene, camera, HISTORY,
    anchorOfSelection(workbench, scene, view_projection, int(width), int(height), scale),
    now,
  )
  interaction.updateHover(scene, camera, view_projection, int(width), int(height))
  interaction.pruneFocus(scene)
  interaction.updateDrag(scene, now)
  assembleMeshes(workbench, scene, interaction, camera, now, scale, are_dimmed)
  clearFrame(int(width), int(height))
  renderer.drawMeshes(MESHES_FURNITURE, view_projection)
  renderer.drawMeshes(MESHES, view_projection)

  drawSelectionMarker(
    scene, workbench.selection, camera, view_projection, int(width), int(height), scale
  )
  drawInteractionOverlay(
    interaction, scene, camera, view_projection, int(width), int(height), scale
  )

  gui.frameEnd()
  (int(width), int(height))


proc exportFrame(path: string; width, height: int): string =
  ## Read framebuffer back and write it out as PNG, reporting what happened.
  ##   Must run before buffers are swapped, as back buffer is what was just drawn into.
  ##   Reads into the permanent arena's own pixel buffer, and writes through the frame
  ##   arena, reset the moment the file is closed.
  if len(path) == 0: return "Export path is empty; nothing written."
  doAssert width <= WIDTH_EXPORT_MAX and height <= HEIGHT_EXPORT_MAX,
    &"Window grew past the {WIDTH_EXPORT_MAX}x{HEIGHT_EXPORT_MAX} export bound; " &
    &"raise `--define:visualiser.width_export_max` or `...height_export_max`."
  let count = width*height*3
  capturePixels(width, height, PIXELS_READBACK.toOpenArray(0, count - 1))
  writePng(ARENA_FRAME, path, width, height, PIXELS_READBACK.toOpenArray(0, count - 1))
  ARENA_FRAME.reset()
  &"Wrote {width}x{height} frame to `{path}`."


proc downsampleInto(
  destination: var openArray[uint8]; pixels: openArray[uint8]; width, height, stride: int
) =
  ## Keep every `stride`-th pixel in both directions, so a GIF frame stays small without
  ## a box filter costing time nobody asked to spend on a diagnostic capture.
  let width_small = width div stride
  for row in 0 ..< height div stride:
    for column in 0 ..< width_small:
      let
        source = (row*stride*width + column*stride)*3
        destination_at = (row*width_small + column)*3
      destination[destination_at] = pixels[source]
      destination[destination_at + 1] = pixels[source + 1]
      destination[destination_at + 2] = pixels[source + 2]



#[ Input Handling ]#

func keyFor(scancode: uint32): Option[Key] =
  ## Translate one SDL scancode into the key the view knows it by, if it is one.
  ##   Only the numbering is this build's own; what each key *does* is
  ##   `interaction.actionFor`'s to say, so both render paths and the help panel answer
  ##   from one table.
  if scancode == uint32(Scancode.Left): some(Key.Left)
  elif scancode == uint32(Scancode.Right): some(Key.Right)
  elif scancode == uint32(Scancode.Up): some(Key.Up)
  elif scancode == uint32(Scancode.Down): some(Key.Down)
  elif scancode == uint32(Scancode.BracketLeft): some(Key.BracketLeft)
  elif scancode == uint32(Scancode.BracketRight): some(Key.BracketRight)
  elif scancode == uint32(Scancode.Minus): some(Key.Minus)
  elif scancode == uint32(Scancode.Equals): some(Key.Plus)
  elif scancode == uint32(Scancode.Return): some(Key.Enter)
  elif scancode == uint32(Scancode.Home): some(Key.Home)
  else: none(Key)


func isMenuForcedFor(button: uint8): Option[bool] =
  ## Say whether a mouse button starts a construction drag, and whether it asks or decides.
  ##   Only the numbering is this build's own -- SDL's, which the browser does not share.
  ##   What each button means is `interaction.isMenuForcedBy`'s to say, so both render
  ##   paths and the help panel answer from one rule.
  if button == uint8(MouseButton.Left): isMenuForcedBy(PointerButton.Left)
  elif button == uint8(MouseButton.Right): isMenuForcedBy(PointerButton.Right)
  elif button == uint8(MouseButton.Middle): isMenuForcedBy(PointerButton.Middle)
  else: none(bool)


proc handleEvent(
  event: Event;
  camera: var Camera; workbench: var Workbench; scene: var Scene; interaction: var Interaction;
  is_dragging_orbit, is_dragging_pan, is_running: var bool; button_dragging: var Option[uint8];
  now: float;
) =
  ## Fold one SDL3 event into camera placement, drag state, workbench state or run state.
  ##   Mouse is ignored while GUI wants it, so dragging a widget never turns the view or
  ##   starts an operation drag.
  ##   Case runs on raw kind rather than on `EventKind`, since SDL3 sends kinds this
  ##   binding never mirrored and converting those to a sparse enum is undefined.
  ##   `now` is only ever forwarded to a drag's own derived item, so it animates in too.
  case event.kind
  of uint32(EventKind.Quit):
    is_running = false
  of uint32(EventKind.KeyDown):
    # `wantsKeys`, not `wantsKeyboard`: with navigation enabled the latter is true from
    #   the first frame and would swallow every key the view answers. See `gui_shim.cpp`.
    if gui.wantsKeys(): return
    # Control on every platform, and command as well, which is what a reader on macOS
    #   presses for the same shortcut.
    let is_accelerator =
      (event.key.modifiers and (MODIFIER_CONTROL or MODIFIER_COMMAND)) != 0
    let is_shifted = (event.key.modifiers and MODIFIER_SHIFT) != 0
    if event.key.scancode == uint32(Scancode.Escape):
      # Cancels what is in progress rather than quitting, which is what it used to do.
      #   Escape is the key a reader presses to get out of something, and pressing it
      #   twice to be sure would have thrown away an unsaved scene; quitting moved to
      #   ctrl+Q, beside every other accelerator, and the window's own close button is
      #   unaffected.
      if workbench.is_help_open: workbench.is_help_open = false
      elif interaction.is_dragging:
        interaction.cancelDrag()
        toChars("Cancelled.", workbench.message)
      elif workbench.session.isSome: workbench.session = none(EditSession)
      elif workbench.is_menu_selection_shown: workbench.hideSelectionMenu()
      elif len(workbench.selection) > 0: workbench.selection.clear()
    elif event.key.scancode == uint32(Scancode.S) and not is_accelerator:
      workbench.is_export_requested = true
    elif is_accelerator and event.key.scancode == uint32(Scancode.Q):
      is_running = false
    elif is_accelerator and event.key.scancode == uint32(Scancode.Z) and not is_shifted:
      workbench.is_undo_requested = true
    elif is_accelerator and
        (event.key.scancode == uint32(Scancode.Y) or
         (event.key.scancode == uint32(Scancode.Z) and is_shifted)):
      workbench.is_redo_requested = true
    elif not is_accelerator:
      # The keys the 3D view itself answers, which is what makes the canvas reachable
      #   without a pointer at all. Nothing here is an accelerator, so a chord that missed
      #   every branch above falls through rather than orbiting the camera by accident.
      let key = keyFor(event.key.scancode)
      if key.isSome:
        let index_selected = interaction.applyAction(
          camera, scene, actionFor(key.get, is_shifted)
        )
        if index_selected.isSome:
          # Shift adds rather than replaces, exactly as shift-click does -- the one place
          #   the shift state means something `actionFor` cannot answer on its own.
          if is_shifted: workbench.selection.toggle(index_selected.get)
          else: workbench.selection.selectOnly(index_selected.get)
          # Reached without a pointer at all, so the menu is the only place the keyboard
          #   can get at apply, edit, hide and delete for what it just picked.
          workbench.showSelectionMenu()
        # Moving the camera by key is a camera move like any other, so it abandons a tween
        #   already carrying it somewhere; otherwise the tween would drag it straight back.
        workbench.tween_camera.abandon()
  of uint32(EventKind.MouseButtonDown):
    if gui.wantsMouse(): return
    # Every press is noted before anything is decided about it: whether it was a click is
    #   only knowable at the release, and both branches below can end in one -- over an
    #   object it selects, over empty space it clears.
    interaction.beginPress(now)
    # Press on a pickable item starts an operation drag; press on empty space falls back
    #   to camera control, exactly as before this feature existed.
    let is_menu_forced = isMenuForcedFor(event.button.button)
    if is_menu_forced.isSome and interaction.beginDrag(is_menu_forced.get, now):
      button_dragging = some(event.button.button)
    elif event.button.button == uint8(MouseButton.Left):
      is_dragging_orbit = true
    elif event.button.button == uint8(MouseButton.Right):
      is_dragging_pan = true
  of uint32(EventKind.MouseButtonUp):
    let is_shifted = (sdl3.getModState() and MODIFIER_SHIFT) != 0
    if button_dragging == some(event.button.button):
      let outcome = interaction.endDrag(scene, now)
      if len(outcome.message) > 0: toChars(outcome.message, workbench.message)
      if outcome.index_clicked.isSome:
        # A press that never became a drag. Shift adds, exactly as shift+enter does from
        #   the keyboard, and either way the selection menu follows what was picked.
        if is_shifted: workbench.selection.toggle(outcome.index_clicked.get)
        else: workbench.selection.selectOnly(outcome.index_clicked.get)
        workbench.showSelectionMenu()
      elif outcome.index_created.isSome:
        workbench.selection.selectOnly(outcome.index_created.get)
        workbench.hideSelectionMenu()
        HISTORY.record(scene, camera)
      elif outcome.choice == some(DragChoice.More) and outcome.operands.isSome:
        # The way out of the gesture's own three operations into the other twenty-four:
        #   both operands selected in the order they were dragged, which is the order the
        #   apply section reads as m then n, and that section opened so they are visible.
        workbench.selection.selectOnly(outcome.operands.get.source)
        workbench.selection.toggle(outcome.operands.get.destination)
        workbench.is_apply_opening = true
        workbench.hideSelectionMenu()
      button_dragging = none(uint8)
    elif event.button.button == uint8(MouseButton.Left) and
        interaction.isClick(now) and not is_shifted:
      # A plain left click over empty space, which began no drag to end. Clears, mirroring
      #   the browser's own rule; shift is left alone, since shift means "keep what I have".
      workbench.selection.clear()
      workbench.hideSelectionMenu()
    if event.button.button == uint8(MouseButton.Left): is_dragging_orbit = false
    if event.button.button == uint8(MouseButton.Right): is_dragging_pan = false
  of uint32(EventKind.MouseWheel):
    if gui.wantsMouse(): return
    workbench.tween_camera.abandon()
    camera.dolly(pow(FACTOR_DOLLY, -float(event.wheel.y)))
  of uint32(EventKind.MouseMotion):
    interaction.updateCursor(float(event.motion.x), float(event.motion.y))
    if is_dragging_orbit:
      workbench.tween_camera.abandon()
      camera.orbit(
        -SPEED_ORBIT*float(event.motion.xrel), SPEED_ORBIT*float(event.motion.yrel)
      )
    if is_dragging_pan:
      workbench.tween_camera.abandon()
      camera.pan(-SPEED_PAN*float(event.motion.xrel), SPEED_PAN*float(event.motion.yrel))
  else: discard



#[ Run Modes ]#

proc reportTimings(milliseconds: var openArray[float32]) =
  ## Print frame-time statistics over a completed `--timings` run.
  ##   Mean and standard deviation alone hide a stutter a percentile catches: a run that
  ##   spends 99% of frames at 2ms and 1% at 40ms reports a fine mean, so the tail past
  ##   p95 is what actually answers "does this stutter."
  let count = len(milliseconds)
  var total = 0.0
  for value in milliseconds: total += float(value)
  let mean = total / float(count)

  var variance = 0.0
  for value in milliseconds: variance += (float(value) - mean)*(float(value) - mean)
  let deviation = sqrt(variance / float(count))

  sort(milliseconds)
  template atPercentile(fraction: float): float32 =
    milliseconds[min(count - 1, int(fraction * float(count)))]
  let (p50, p90, p95, p99) =
    (atPercentile(0.50), atPercentile(0.90), atPercentile(0.95), atPercentile(0.99))

  echo &"Frame time over {count} frames, milliseconds (fps in parentheses):"
  echo &"  mean {mean:.3f} ({1000.0/mean:.1f})  stddev {deviation:.3f}"
  echo &"  min {milliseconds[0]:.3f}  p50 {p50:.3f} ({1000.0/float(p50):.1f})  " &
    &"p90 {p90:.3f} ({1000.0/float(p90):.1f})"
  echo &"  p95 {p95:.3f} ({1000.0/float(p95):.1f})  p99 {p99:.3f} ({1000.0/float(p99):.1f})  " &
    &"max {milliseconds[^1]:.3f} ({1000.0/float(milliseconds[^1]):.1f})"


proc driveDrag(
  scene: Scene; camera: Camera; width, height, count_drawn: int; scale: DrawExtent
) =
  ## Script a right-button construction drag from the first scene item onto the second,
  ## one step per frame, so a headless run can be made to show the choice menu open.
  ##   For `--drive-drag`, and reached from nowhere else. Every step is posted to SDL's own
  ##   queue rather than handed to `handleEvent` directly: the point of driving this at all
  ##   is to exercise the wiring between the two, and this project has already shipped one
  ##   bug that survived a test calling a handler straight.
  ##   Positions come from the same `anchorFor`/`projectToScreen` pair the overlay draws
  ##   its rubber-band through, so the cursor lands where the item was actually drawn
  ##   rather than where a hard-coded pixel guessed it would be.
  ##   **Not reproducible frame for frame**, unlike `--storyboard`: this runs the real loop
  ##   on the real clock, so every seed's own birth animation stands wherever eight frames
  ##   of wall time put it. Two runs of one binary differ by a few pixels of scene. Look at
  ##   the capture; do not byte-compare it against another run.
  const (FRAME_REACH_SOURCE, FRAME_PRESS, FRAME_REACH_TARGET) = (2, 3, 4)
  if count_drawn notin [FRAME_REACH_SOURCE, FRAME_PRESS, FRAME_REACH_TARGET]: return
  let slot = if count_drawn == FRAME_REACH_TARGET: 1 else: 0
  if not scene.isAlive(slot): return
  let anchor = anchorFor(scene[slot].geometry, scale)
  if anchor.isNone: return
  let screen = projectToScreen(
    camera.initMatrixViewProjection(width/height), width, height, anchor.get
  )
  if not screen.isInFront: return

  var event = Event(kind: uint32(EventKind.MouseMotion))
  event.motion.x = cfloat(screen.x)
  event.motion.y = cfloat(screen.y)
  sdl3.pushEvent(addr event)
  if count_drawn == FRAME_PRESS:
    var press = Event(kind: uint32(EventKind.MouseButtonDown))
    press.button.button = uint8(MouseButton.Right)
    sdl3.pushEvent(addr press)


const lut_keys_driven = [
  Scancode.BracketRight, Scancode.BracketRight, Scancode.Return,
  Scancode.Right, Scancode.Right, Scancode.Up, Scancode.Equals, Scancode.Tab,
] ## Script one press per frame for `--drive-keys`: walk the focus on twice, select what it
  ## lands on, then orbit and dolly. Chosen to touch every kind of action the view answers
  ## -- traversal, selection, camera -- so one run says whether Dear ImGui's own navigation
  ## has swallowed the lot. The trailing Tab is the opposite check: the application binds
  ## it to nothing, so `gui.wantsKeys` turning true afterwards is nav having taken it and
  ## landed on a panel widget, which is what makes the panels reachable at all.


const lut_keycodes_driven = [
  uint32(ord(']')), uint32(ord(']')), 13'u32, # Return is ASCII carriage return.
  1073741903'u32, 1073741903'u32, 1073741906'u32, # SDLK_RIGHT, RIGHT, UP.
  uint32(ord('=')), 9'u32, # Tab is ASCII horizontal tab.
] ## Pair each scripted scancode with the keycode SDL would have sent beside it; see
  ## `driveKeys` on why both are needed. One entry per `lut_keys_driven` entry.


proc driveKeys(count_drawn: int) =
  ## Push one scripted key per frame onto SDL's own queue, for `--drive-keys`.
  ##   Posted to the queue rather than handed to `handleEvent`, for the reason `driveDrag`
  ##   gives: the wiring between the two is exactly what a scripted test is for.
  const FRAME_FIRST = 3 # Past startup, so the first frame's own layout has settled.
  let step = count_drawn - FRAME_FIRST
  if step notin 0 ..< len(lut_keys_driven): return
  var event = Event(kind: uint32(EventKind.KeyDown))
  event.key.scancode = uint32(lut_keys_driven[step])
  # Dear ImGui's own backend reads the layout keycode rather than the scancode, so an
  #   event without one is invisible to it -- and the Tab below is aimed at exactly that.
  #   ASCII is the keycode for every key this script sends.
  event.key.keycode = lut_keycodes_driven[step]
  event.key.is_down = true
  event.key.modifiers = 0
  sdl3.pushEvent(addr event)


proc driveSelect(
  scene: Scene; camera: Camera; width, height, count_drawn: int; scale: DrawExtent
) =
  ## Script a click, then two shift-clicks, on the first three scene items, and finally a
  ## construction drag off the object the menu is sitting over, so a headless run can show
  ## the floating selection menu at each size and prove it does not swallow the next drag.
  ##   For `--drive-select`, and reached from nowhere else. Which state is captured is
  ##   `--frames`' to choose: the menu over one object by frame 5, two by 7, three by 9,
  ##   the drag off the object it follows resolved by 13. One frame later than each step,
  ##   because Dear ImGui hides an auto-sized window for the one frame it measures it in.
  ##   Posted to SDL's own queue for the reason `driveDrag` gives, and split across two
  ##   frames per gesture for a reason of its own: hover is recomputed inside `renderFrame`,
  ##   so a press arriving in the same drain as the motion that should have caused it
  ##   would still read the previous frame's pick.
  ##   Shift is set through `sdl3.setModState` rather than by pushing a key event, because
  ##   a pushed event never reaches the state `getModState` reads.
  ##   Shares `driveDrag`'s own warning: this runs the real loop on the real clock, so two
  ##   captures differ by a few pixels of birth animation. Look at it; do not byte-compare.
  const
    FRAME_FIRST = 2 # Past startup, so the first frame's own layout has settled.
    STEPS_CLICK = 6 # Three clicks, each a frame to reach and a frame to press.
    lut_step_to_slot = [0, 0, 1, 1, 2, 2, 2, 2, 0, 0]
      ## Which item each step aims at: three clicks on 0, 1 and 2 in turn, then a drag
      ## from 2 -- the one the menu is by then following -- onto 0.
  let step = count_drawn - FRAME_FIRST
  if step notin 0 ..< len(lut_step_to_slot): return
  let
    slot = lut_step_to_slot[step]
    is_acting = (step mod 2) == 1
  if not scene.isAlive(slot): return
  let anchor = anchorFor(scene[slot].geometry, scale)
  if anchor.isNone: return
  let screen = projectToScreen(
    camera.initMatrixViewProjection(width/height), width, height, anchor.get
  )
  if not screen.isInFront: return

  if not is_acting:
    var reach = Event(kind: uint32(EventKind.MouseMotion))
    reach.motion.x = cfloat(screen.x)
    reach.motion.y = cfloat(screen.y)
    sdl3.pushEvent(addr reach)
    return
  # The first click picks alone; the two after it add, which is what shift means here.
  sdl3.setModState(if slot == 0 and step == 1: 0'u16 else: MODIFIER_SHIFT)
  var event = Event(
    kind:
      if step < STEPS_CLICK or step == STEPS_CLICK + 1:
        uint32(EventKind.MouseButtonDown)
      else: uint32(EventKind.MouseButtonUp)
  )
  event.button.button = uint8(MouseButton.Left)
  sdl3.pushEvent(addr event)
  # A click is a press and a release in one drain; the drag's own two halves are frames
  #   apart, so that the cursor really travels between them.
  if step < STEPS_CLICK:
    var release = Event(kind: uint32(EventKind.MouseButtonUp))
    release.button.button = uint8(MouseButton.Left)
    sdl3.pushEvent(addr release)


const lut_keys_undo_driven = [
  (Scancode.Right, uint32(1073741903), 0'u16), # SDLK_RIGHT, no modifier: orbit.
  (Scancode.Right, uint32(1073741903), 0'u16),
  (Scancode.Right, uint32(1073741903), 0'u16),
  (Scancode.Up, uint32(1073741906), 0'u16), # SDLK_UP: rise.
  (Scancode.Z, uint32(ord('z')), MODIFIER_CONTROL), # The undo under test.
] ## Script the keys `--drive-undo` sends after its construction lands: three orbit steps
  ## and a rise, far enough that a view left where they put it cannot be mistaken for the
  ## one the construction was made from, then the undo itself. Scancode, keycode and
  ## modifiers together, for the reason `driveKeys` gives about the keycode.

proc driveUndo(
  scene: Scene; camera: Camera; width, height, count_drawn: int; scale: DrawExtent
) =
  ## Script a construction drag onto the second scene item, an orbit well away from where
  ## it was built, and then the undo of it, one step per frame.
  ##   For `--drive-undo`, and reached from nowhere else. The point is the view, not the
  ##   scene: undo puts the camera back where the construction was made from, and the only
  ##   way to see that it really does -- through the key wiring, the panel and the tween a
  ##   restored view has to survive -- is to look at the frames. Capture around frame 6 for
  ##   the view it was built from, frame 10 for how far the orbit went, and frame 12 or
  ##   later for where undo left it: 6 and 12 should show the same viewpoint.
  ##   Posted to SDL's own queue, and split across frames per gesture, for the reasons
  ##   `driveDrag` and `driveSelect` give. Shares their warning too: this runs the real
  ##   loop on the real clock, so look at the captures rather than byte-comparing them.
  const
    FRAME_FIRST = 2 # Past startup, so the first frame's own layout has settled.
    STEPS_DRAG = 4 # Reach the source, press, reach the target, release.
    lut_step_to_slot = [0, 0, 1, 1]
  let step = count_drawn - FRAME_FIRST
  if step < 0: return

  if step < STEPS_DRAG:
    let slot = lut_step_to_slot[step]
    if not scene.isAlive(slot): return
    let anchor = anchorFor(scene[slot].geometry, scale)
    if anchor.isNone: return
    let screen = projectToScreen(
      camera.initMatrixViewProjection(width/height), width, height, anchor.get
    )
    if not screen.isInFront: return
    if (step mod 2) == 0:
      var reach = Event(kind: uint32(EventKind.MouseMotion))
      reach.motion.x = cfloat(screen.x)
      reach.motion.y = cfloat(screen.y)
      sdl3.pushEvent(addr reach)
      return
    var event = Event(
      kind:
        if step == 1: uint32(EventKind.MouseButtonDown)
        else: uint32(EventKind.MouseButtonUp)
    )
    # The left button, not the right: a right release commits the wedge the cursor stands
    #   in, and a scripted cursor sitting on its target stands in none of them. The left
    #   one takes the proposal, which is the construction this driver is here to undo.
    event.button.button = uint8(MouseButton.Left)
    sdl3.pushEvent(addr event)
    return

  # A frame of slack after the release, so the construction is committed and its own
  #   camera aim armed before the orbit that has to override it starts.
  let index = step - STEPS_DRAG - 1
  if index notin 0 ..< len(lut_keys_undo_driven): return
  let (scancode, keycode, modifiers) = lut_keys_undo_driven[index]
  var event = Event(kind: uint32(EventKind.KeyDown))
  event.key.scancode = uint32(scancode)
  event.key.keycode = keycode
  event.key.is_down = true
  event.key.modifiers = modifiers
  sdl3.pushEvent(addr event)


proc runInteractive(
  window: Window; renderer: Renderer; options: Options;
  workbench: var Workbench; scene: var Scene; camera: var Camera;
) =
  ## Draw frames, folding input in, until user or command line asks to stop.
  ##   Exceeds the working 60-line default: a sequential per-frame state machine
  ##   threading a dozen mutable locals (drag state, vsync tracking, running totals)
  ##   through one loop body. Splitting the loop into helper procs would mean passing
  ##   most of those locals by `var` reference across a new proc boundary, trading a
  ##   readable top-to-bottom frame loop for indirection with no cost reduction.
  var
    interaction = Interaction(is_enabled: true)
    button_dragging = none(uint8)
    is_running = true
    is_dragging_orbit = false
    is_dragging_pan = false
    is_vsync_active = workbench.is_vsync_enabled # Matches the swap interval already set.
    count_drawn = 0
    ticks_previous_frame = getMonoTime().ticks
    total_tessellate_microseconds = 0.0
    total_vertices = 0

  while is_running:
    # Frame arena starts every frame empty; nothing in the draw loop itself asks it for
    #   anything today, but `exportFrame` below may, and always leaves it reset behind it.
    ARENA_FRAME.reset()

    # One reading per frame, shared by every drag that completes this frame and by the
    #   frame's own render, so a completed drag and what gets drawn agree on "now".
    let now = secondsNow()

    # Measured against the previous iteration's own start, so this covers everything a
    #   real frame pays for: events, tessellation, render, and the swap that just blocked
    #   on vsync (or didn't) at the tail of that previous iteration. Always taken, not
    #   just under `--timings`, since the panel's own live graph needs it every frame too.
    let ticks_frame_start = getMonoTime().ticks
    if count_drawn > 0:
      let delta_milliseconds = float32(ticks_frame_start - ticks_previous_frame) / 1_000_000.0
      workbench.milliseconds_history[workbench.index_history] = cfloat(delta_milliseconds)
      workbench.index_history = (workbench.index_history + 1) mod FRAMES_HISTORY
      if options.is_timed:
        doAssert count_drawn - 1 < FRAMES_TIMING_MAX,
          &"Timing run passed its own {FRAMES_TIMING_MAX}-frame bound; raise " &
          "`--define:visualiser.frames_timing_max` or shorten `--frames`."
        TIMINGS_FRAME_MILLISECONDS[count_drawn - 1] = delta_milliseconds
    ticks_previous_frame = ticks_frame_start

    if options.is_key_driven: driveKeys(count_drawn)
    if options.is_drag_driven or options.is_select_driven or options.is_undo_driven:
      let scale_driven = camera.drawExtentFor(PIXELS_HEIGHT)
      if options.is_drag_driven:
        driveDrag(scene, camera, PIXELS_WIDTH, PIXELS_HEIGHT, count_drawn, scale_driven)
      elif options.is_select_driven:
        driveSelect(scene, camera, PIXELS_WIDTH, PIXELS_HEIGHT, count_drawn, scale_driven)
      else:
        driveUndo(scene, camera, PIXELS_WIDTH, PIXELS_HEIGHT, count_drawn, scale_driven)

    var event: Event
    while sdl3.pollEvent(addr event):
      gui.processEvent(addr event)
      handleEvent(
        event, camera, workbench, scene, interaction,
        is_dragging_orbit, is_dragging_pan, is_running, button_dragging, now,
      )

    let (width, height) =
      renderFrame(
        window, renderer, workbench, scene, camera, interaction, now,
        path_help = options.path_help_driven,
      )
    if options.is_timed:
      total_tessellate_microseconds += workbench.microseconds_tessellate
      total_vertices += workbench.count_vertices

    # Change the swap interval only when the checkbox actually flips, not every frame.
    if workbench.is_vsync_enabled != is_vsync_active:
      is_vsync_active = workbench.is_vsync_enabled
      sdl3.glSetSwapInterval(if is_vsync_active: 1 else: 0)

    # Export on final frame of a bounded run, so a build can be checked without a screen.
    inc count_drawn
    let is_final = options.count_frames > 0 and count_drawn >= options.count_frames
    if is_final and len(options.path_screenshot) > 0: workbench.is_export_requested = true

    if workbench.is_export_requested:
      workbench.is_export_requested = false
      let report = exportFrame(toText(workbench.path_export), width, height)
      toChars(report, workbench.message)
      echo report

    sdl3.glSwapWindow(window)
    if is_final: is_running = false

  echo &"Drew {count_drawn} frames."
  if options.is_key_driven:
    # What the scripted keys actually reached, so "Dear ImGui swallowed them" is a reading
    #   rather than a suspicion. A camera still at its opening placement and a focus still
    #   none means nothing got through.
    echo &"Keys: focus {interaction.index_focus}, selected {len(workbench.selection)}, " &
      &"azimuth {camera.azimuth:.4f}, elevation {camera.elevation:.4f}, " &
      &"distance {camera.distance:.4f}; " &
      &"gui.wantsKeys {gui.wantsKeys()}, nav enabled {gui.isNavEnabled()}."
  if options.is_timed and count_drawn > 1:
    reportTimings(TIMINGS_FRAME_MILLISECONDS.toOpenArray(0, count_drawn - 2))
    echo &"  tessellate mean {total_tessellate_microseconds/float(count_drawn):.1f}us, " &
      &"{total_vertices div count_drawn} vertices/frame " &
      &"(both this run's own CPU-side cost, not the rasterizer's)."


proc runStoryboard(
  window: Window; renderer: Renderer; directory: string;
  workbench: var Workbench; scene: var Scene; camera: var Camera;
) =
  ## Apply each scripted step in turn, writing one settled frame after each, plus one
  ## short animated GIF sweeping through every step's own appear-in animation.
  ##   Every step runs through the same catalogue the GUI's apply button does, so frames
  ##   show what clicking would have produced.
  ##   `clock` is a synthetic reading rather than a real one, so the animation sweeps at
  ##   an exact, reproducible pace regardless of how fast this machine draws a frame.
  ##   Exceeds the working 60-line default: a sequential per-step state machine
  ##   threading dimming state, GIF frame accounting, and the synthetic clock through
  ##   one loop body -- the same shape, and the same reason to leave it as one proc,
  ##   as `runInteractive` above.
  createDir(directory)
  var
    interaction_disabled = Interaction() # is_enabled defaults false; no picking, no overlay.
    dims_gif = (0, 0)
    count_frames_gif = 0
    clock = 0.0
    are_dimmed: array[ITEMS_MAX, bool] ## Every slot starts un-dimmed, right for the
      ## seeds-only frame captured below before any step has a rolling window to dim.

  template renderAt(now: float): (int, int) =
    renderFrame(window, renderer, workbench, scene, camera, interaction_disabled, now, are_dimmed)

  template captureGif(now: float) =
    ## Render one frame at `now`, downsample it, and append it to the GIF's own frames.
    ##   Frames are collected in the permanent arena's own storage, since they must all
    ##   survive to the single `writeGif` call at the very end; only the throwaway pixel
    ##   readback in between comes from the frame arena, reset right after.
    block:
      let (width, height) = renderAt(now)
      doAssert width == PIXELS_WIDTH and height == PIXELS_HEIGHT,
        "Storyboard capture assumes a fixed window size; the actual framebuffer differs."
      dims_gif = (width div STRIDE_GIF, height div STRIDE_GIF)
      doAssert count_frames_gif < COUNT_GIF_FRAMES_MAX,
        &"Storyboard asked for more than the {COUNT_GIF_FRAMES_MAX} GIF frames reserved."
      capturePixels(width, height, PIXELS_READBACK.toOpenArray(0, width*height*3 - 1))
      let frame_size = dims_gif[0]*dims_gif[1]*3
      downsampleInto(
        GIF_FRAMES.toOpenArray(count_frames_gif*frame_size, (count_frames_gif + 1)*frame_size - 1),
        PIXELS_READBACK.toOpenArray(0, width*height*3 - 1), width, height, STRIDE_GIF,
      )
      inc count_frames_gif

  template captureStep(stem: string) =
    ## Sweep this step's own items from freshly born to settled into the GIF, hold on
    ## the settled result a moment, then settle widget layout and write the numbered PNG
    ## exactly as before this feature existed -- the still frames never show mid-animation.
    ##   Template rather than nested procedure, as scene and workbench arrive by `var`
    ##   and a closure may not capture those.
    block:
      let now_settled = clock + 2.0*ANIMATION_SECONDS
      for sub in 0 ..< FRAMES_GIF_GROW:
        captureGif(clock + ANIMATION_SECONDS*(float(sub) / float(FRAMES_GIF_GROW - 1)))
      for _ in 1 .. FRAMES_GIF_HOLD:
        captureGif(now_settled)

      var (width, height) = (0, 0)
      for _ in 1 .. FRAMES_SETTLE: (width, height) = renderAt(now_settled)
      echo exportFrame(directory / (stem & ".png"), width, height)
      sdl3.glSwapWindow(window)

  scene = initScene()
  constructSeeds(scene, clock)
  let count_seeds = scene.len
  toChars("Seeds placed.", workbench.message)
  captureStep("00_seeds")

  # Every object stays visible once added: a construction's own history should stay
  #   legible, not disappear as later steps pass it by. Seeds are pinned at full colour
  #   throughout, as the stable reference the rest is read against; a derived object
  #   reads at full colour only for the step that creates it and the one right after --
  #   long enough that a step using yesterday's result still shows it clearly -- and
  #   grays out, rather than vanishing, once two steps have passed it by.
  #   Only a step's real operands count as "involved": a unary operation's own second
  #   index is a required-but-ignored placeholder (see `Step.index_second`'s own doc
  #   comment), not something this step actually reads, so it plays no part here either.
  let
    azimuth_default = camera.azimuth
    elevation_default = camera.elevation
  # Which slots this step and the one before it read or wrote, as flags per slot rather
  #   than as a list of slot numbers: the same fixed-capacity shape `are_dimmed` beside
  #   them already has, so membership is an index rather than a scan, and the loop
  #   allocates nothing per step.
  var are_operative_previous: array[ITEMS_MAX, bool]
  for index, step in STEPS:
    clock += 1.0
    let derived = applyStep(scene, step, clock)

    var are_operative: array[ITEMS_MAX, bool]
    are_operative[step.index_first] = true
    are_operative[count_seeds + index] = true
    if lut_operation_to_arity[step.operation] == Arity.Two:
      are_operative[step.index_second] = true
    for slot, _ in scene.pairs:
      are_dimmed[slot] =
        not (slot < count_seeds or are_operative[slot] or are_operative_previous[slot])
    are_operative_previous = are_operative

    # A finite object is anchored somewhere the fixed demo angle already frames; a
    #   horizon object is not -- it stands wherever its own construction happened to
    #   land it, which that fixed angle may or may not be looking toward. Aim this one
    #   capture at it directly instead (a representative point for a line's own great
    #   circle, since aiming along its normal would place the whole ring at the frame's
    #   own edge, exactly 90 degrees off in every direction), then restore the default
    #   orientation after -- a plane at horizon needs no aiming at all, since the whole
    #   sky around the eye is visible regardless of which way the camera looks. Lens
    #   stays at its own default throughout: reorienting is enough on its own, and
    #   widening it besides would shrink everything else this same capture also shows.
    camera.azimuth = azimuth_default
    camera.elevation = elevation_default
    # Turn to face a result standing at the horizon, which is nowhere the demo's own
    #   fixed angle already frames. Instant, not eased: a captured frame must never show
    #   a half-finished pan. Same `aimFor` the interactive path uses, so both agree on
    #   where an object is worth looking from.
    if isHorizon(derived):
      let scale_aim = camera.drawExtentFor(PIXELS_HEIGHT)
      let aim = aimFor(derived, scale_aim)
      if aim.isSome:
        workbench.tween_camera.aimAt(camera, aim.get, 0.0, 0.0)
        workbench.tween_camera.settle(camera)

    toChars(&"{step.label} gave {shapeText(derived)}.", workbench.message)
    workbench.selection.selectOnly(count_seeds + index)
    captureStep(step.stem)

  let
    path_gif = directory / "storyboard.gif"
    frame_size_gif = dims_gif[0]*dims_gif[1]*3
  writeGif(
    ARENA_FRAME, path_gif, dims_gif[0], dims_gif[1],
    GIF_FRAMES.toOpenArray(0, count_frames_gif*frame_size_gif - 1),
    count_frames_gif, CENTISECONDS_GIF_DELAY,
  )
  ARENA_FRAME.reset()
  echo &"Wrote {count_frames_gif} frames to `{path_gif}`."
  echo &"Wrote {len(STEPS) + 1} frames to `{directory}`."


proc fillSceneForBenchmark(scene: var Scene; now: float) =
  ## Top scene up to capacity with synthetic points, lines and planes, so `--timings`
  ## can measure the heaviest tessellation and draw load this scene ever reaches rather
  ## than the handful of items the demo opens on.
  ##   Positions walk a helix, so no two are ever collinear and every join is well formed.
  ##   Own point buffer, not the scene, backs each join: earlier slots may already hold
  ##   the demo's own seeds, which this helix has nothing to do with.
  var points: array[ITEMS_MAX, Multivector]
  var index = 0
  while not scene.isFull:
    let angle = float(index) * 0.7
    points[index] = toMultivector(
      Position(x: 6.0*cos(angle), y: 6.0*sin(angle), z: -3.0 + 0.15*float(index))
    )
    let ink = inkCycled(index)
    case index mod 3
    of 0: scene.addItem(points[index], &"fill{index}", ink, now)
    of 1: scene.addItem(points[index] ∧ points[index - 1], &"fill{index}", ink, now)
    else:
      scene.addItem(
        points[index] ∧ points[index - 1] ∧ points[index - 2], &"fill{index}", ink, now
      )
    inc index



#[ Entry Point ]#

proc main() =
  ## Open window, run the mode command line asked for, then tear down in order.
  let options = parseOptions()
  doAssert sdl3.init(INIT_VIDEO), &"SDL3 failed to start: {sdl3.getError()}"
  defer: sdl3.quit()

  # Ask for the core profile the renderer's shaders are written against.
  sdl3.glSetAttribute(GL_CONTEXT_MAJOR_VERSION, 3)
  sdl3.glSetAttribute(GL_CONTEXT_MINOR_VERSION, 3)
  sdl3.glSetAttribute(GL_CONTEXT_PROFILE_MASK, GL_CONTEXT_PROFILE_CORE)
  sdl3.glSetAttribute(GL_DOUBLEBUFFER, 1)
  sdl3.glSetAttribute(GL_DEPTH_SIZE, 24)
  var flags = WINDOW_OPENGL or WINDOW_RESIZABLE
  if options.is_hidden: flags = flags or WINDOW_HIDDEN

  # Ask for a multisampled framebuffer, and open without one where no visual offers it.
  #   Every line is now a thin quad rather than a `GL_LINES` run, and nothing else smooths
  #   its edges: at four samples a 1.5-pixel grid ribbon reads as a line, and with none it
  #   reads as dotted. Asked for rather than required, because a visual that cannot supply
  #   it is a real case -- `llvmpipe` under `xvfb`, which every headless capture here runs
  #   on, refuses the window outright rather than downgrading -- and a workbench that will
  #   not start at all is worse than one whose thinnest lines alias.
  sdl3.glSetAttribute(GL_MULTISAMPLEBUFFERS, 1)
  sdl3.glSetAttribute(GL_MULTISAMPLESAMPLES, SAMPLES_MULTISAMPLE)
  var window = sdl3.createWindow(TITLE, PIXELS_WIDTH, PIXELS_HEIGHT, flags)
  if window == nil:
    echo &"No multisampled visual ({sdl3.getError()}); thin lines will alias."
    sdl3.glSetAttribute(GL_MULTISAMPLEBUFFERS, 0)
    sdl3.glSetAttribute(GL_MULTISAMPLESAMPLES, 0)
    window = sdl3.createWindow(TITLE, PIXELS_WIDTH, PIXELS_HEIGHT, flags)
  doAssert window != nil, &"SDL3 failed to open window: {sdl3.getError()}"
  defer: sdl3.destroyWindow(window)

  let context = sdl3.glCreateContext(window)
  doAssert context != nil, &"SDL3 failed to make OpenGL context: {sdl3.getError()}"
  defer: sdl3.glDestroyContext(context)
  sdl3.glSetSwapInterval(if options.is_novsync: 0 else: 1)
  echo &"OpenGL: {gl.getString(gl.VERSION)}"

  doAssert gui.init(
    window, context, PATH_FONT, PATH_FONT_MATH, PATH_FONT_SYMBOL, SIZE_FONT
  ), "Dear ImGui failed to start."
  defer: gui.shutdown()
  if not gui.isFontLoaded():
    echo &"Font `{PATH_FONT}` was not loaded; operator notation will draw as boxes."

  let renderer = initRenderer()
  var
    scene = initScene()
    camera = initCameraDefault()
    workbench = initWorkbench(
      if len(options.path_screenshot) > 0: options.path_screenshot
      else: PATH_EXPORT_DEFAULT
    )
  workbench.is_vsync_enabled = not options.is_novsync
  # A help tab asked for on the command line is a help panel asked for.
  workbench.is_help_open = options.path_help_driven.isSome

  # Open on storyboard's own seeds alone, so window and script agree on where a
  #   construction starts, unless a saved scene was asked for instead, which replaces
  #   the demo entirely.
  let now_startup = secondsNow()
  if len(options.path_load_scene) > 0:
    echo loadScene(scene, options.path_load_scene)
  else:
    constructSeeds(scene, now_startup)
  if options.is_filled: fillSceneForBenchmark(scene, now_startup)
  HISTORY = initHistory(scene, camera)

  if len(options.path_storyboard) > 0:
    runStoryboard(window, renderer, options.path_storyboard, workbench, scene, camera)
  else:
    runInteractive(window, renderer, options, workbench, scene, camera)

main()
