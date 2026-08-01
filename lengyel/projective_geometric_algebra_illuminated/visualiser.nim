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
##   sdl3 -> gui ----------------------------------------------
##   opengl -> renderer -----------------------------------------
##   scene -> storyboard -------------------------------------------
##
##   objects reads drawable quantities out of multivectors.
##   mesh tessellates those quantities into vertices, into fixed storage.
##   camera orbits, and assembles transforms from its own RGA-derived frame.
##   picking hit-tests scene items in screen space, against those same transforms.
##   renderer owns OpenGL names and draws the meshes.
##   scene holds objects and catalogue of operations that derive new ones.
##   selection holds which objects are picked, in the order that names an operation's operands.
##   interaction tracks a mouse drag from one item to another, and applies what it names.
##   panel lays out the widgets user edits scene through.
##   storyboard scripts a construction, one operation per exported frame.
##   image encodes a frame readback as PNG.
##
## Render paths: this file is the native desktop entry point (SDL3/OpenGL/Dear ImGui,
## compiled `--backend:cpp` per `visualiser.nim.cfg`); `visualiser/browser_bridge.nim`
## is the browser entry point (compiled through `nim js` per its own sibling
## `browser_bridge.nim.cfg`, presentation done by hand-written JS living outside this
## repo). Neither imports the other, and nothing shared imports either render target's
## own presentation layer -- verified by import graph, not just by convention:
##
##   |-------------------|---------|-----------------------------------------------|
##   | Module            | Path    | Reachable from                                |
##   |-------------------|---------|-----------------------------------------------|
##   | pga               | Shared  | Both (external, vendored at build time only). |
##   | objects           | Shared  | Both.                                         |
##   | mesh              | Shared  | Both.                                         |
##   | camera            | Shared  | Both.                                         |
##   | scene             | Shared  | Both.                                         |
##   | selection         | Shared  | Both.                                         |
##   | picking           | Shared  | Both.                                         |
##   | interaction       | Shared  | Both.                                         |
##   | storyboard        | Shared  | Both.                                         |
##   | format            | Shared  | Both (transitively, through interaction).     |
##   | browser_bridge    | Browser | Browser entry point.                          |
##   | arena             | Desktop | Desktop only.                                 |
##   | gif               | Desktop | Desktop only.                                 |
##   | image             | Desktop | Desktop only.                                 |
##   | gui, gui_shim.cpp | Desktop | Desktop only.                                 |
##   | opengl            | Desktop | Desktop only.                                 |
##   | sdl3              | Desktop | Desktop only.                                 |
##   | renderer          | Desktop | Desktop only.                                 |
##   | panel             | Desktop | Desktop only.                                 |
##   |-------------------|---------|-----------------------------------------------|
##
## Controls:
##   Drag from one object to another to derive a third: left joins, right meets, middle
##   projects the object dragged from onto the object dragged to. The rubber-band drawn
##   while dragging is tinted to match, and the panel's own top line names the same colours.
##   Drag from empty space instead to move the camera: left orbits, right pans, wheel dollies.
##   `S` writes current frame to the export path; `Escape` quits.
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

{.experimental: "strictFuncs".}

when compileOption("profiler"):
  import std/nimprof

import std/[algorithm, math, monotimes, options, os, parseopt, strformat, strutils]

import ./pga
import ./visualiser/[
  arena, camera, format, gif, gui, history, image, interaction, mesh, objects, panel, picking,
  renderer, scene, selection, storyboard,
]
import ./visualiser/opengl as gl
import ./visualiser/sdl3



#[ Application Configuration ]#

const
  TITLE* = "Projective Geometric Algebra Illuminated — RGA workbench"
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
  RADIUS_OVERLAY_HOVER = 16.0'f32
    ## Set radius of ring drawn around whatever the cursor is over.
  WIDTH_OVERLAY_LINE = 2.0'f32
    ## Set thickness of drag rubber-band and hover ring.
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
var MESHES_FURNITURE: MeshSet ## Ground grid and world axes alone, drawn separately, so
  ## they can hold their own, thinner line width distinct from a scene object's own
  ## (`renderer.WIDTH_LINE_FURNITURE`).
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
      else:
        doAssert false,
          &"Unknown option `--{key}`; expected screenshot, storyboard, load-scene, " &
          "frames, hidden, timings, novsync or fill."
    of cmdArgument:
      doAssert false, &"Unexpected argument `{key}`; every input is a named option."
    of cmdEnd: discard



#[ Frame Assembly ]#

proc secondsNow(): float =
  ## Read monotonic clock as seconds, for animating how recently an item was added.
  ##   Nanosecond ticks, not seconds since any fixed epoch, but only ever differenced
  ##   against another reading from the same process, so that never matters.
  float(getMonoTime().ticks) / 1_000_000_000.0


proc assembleMeshes(
  workbench: var Workbench; scene: Scene; now: float; scale: DrawExtent;
  are_dimmed: array[ITEMS_MAX, bool] = default(array[ITEMS_MAX, bool])
) =
  ## Refill vertex storage from scene as it stands this frame, recording what it cost.
  ##   `are_dimmed` grays an item out rather than skipping it -- empty (nothing dimmed)
  ##   for ordinary interactive rendering; the storyboard's own rolling emphasis is the
  ##   only caller that fills it in.
  let ticks_start = getMonoTime().ticks
  MESHES_FURNITURE.clearMeshes
  if workbench.is_grid_shown: MESHES_FURNITURE.addGrid(scale.extent_furniture)
  if workbench.is_axes_shown: MESHES_FURNITURE.addAxes(scale.extent_furniture)

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
    var ghost: Multivector
    for b in Basis: ghost[b] = float(workbench.session.get.coefficients[b])
    discard MESHES.addObject(ghost, muted(INK_GHOST.colour), scale)

  workbench.microseconds_tessellate = float(getMonoTime().ticks - ticks_start) / 1000.0
  workbench.count_vertices = 0
  for primitive in Primitive:
    workbench.count_vertices += MESHES[primitive].count_vertices +
      MESHES_FURNITURE[primitive].count_vertices


const lut_drag_to_ink: array[DragOperation, Ink] = [
  DragOperation.Join: Ink.Jade,
  DragOperation.Meet: Ink.Magenta,
  DragOperation.Project: Ink.Olive,
] ## Match the panel's own drag legend, so the rubber-band names its outcome as it's drawn.


proc drawSelectionRing(
  scene: Scene; selection: Selection; view_projection: Matrix4;
  width, height: int; scale: DrawExtent
): int {.discardable.} =
  ## Draw one ring per selected item, directly onto the foreground layer, with the exact
  ## same `gui.overlayCircle` call the hover ring below uses -- tinted with `Ink.Outline`
  ## instead of hover's own inline white, so both read as one family of plain circle
  ## markers rather than two different mechanisms. Report how many rings were drawn.
  ##   One per selected slot rather than one overall: an operation reads two operands, and
  ##   a selection that cannot be seen in the view it acts on is not worth much. Matches
  ##   the browser overlay's own per-slot loop.
  ##   The count exists so a test can assert what was drawn without reading pixels; a
  ##   caller uninterested in it may discard it.
  ##   Unconditional, unlike hover/drag below: a storyboard step uses this same ring to
  ##   show which object it just built, so it must still draw with interaction disabled.
  let tint = Ink.Outline.colour
  for position in 0 ..< selection.len:
    let slot = selection.at(position)
    if not (scene.isAlive(slot) and scene[slot].isVisible): continue
    let anchor = anchorFor(scene[slot].geometry, scale)
    if anchor.isNone: continue
    let screen = projectToScreen(view_projection, width, height, anchor.get)
    if not screen.isInFront: continue
    gui.overlayCircle(
      cfloat(screen.x), cfloat(screen.y), RADIUS_OVERLAY_HOVER,
      tint.red, tint.green, tint.blue, tint.alpha, WIDTH_OVERLAY_LINE,
    )
    result.inc


proc drawInteractionOverlay(
  interaction: Interaction; scene: Scene; view_projection: Matrix4; width, height: int;
  scale: DrawExtent
) =
  ## Draw drag's rubber-band and hover's ring directly onto the foreground layer.
  ##   Off entirely during storyboard capture, where interaction is never enabled.
  if not interaction.is_enabled: return

  if interaction.index_hover.isSome:
    let anchor = anchorFor(scene[interaction.index_hover.get].geometry, scale)
    if anchor.isSome:
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if screen.isInFront:
        gui.overlayCircle(
          cfloat(screen.x), cfloat(screen.y), RADIUS_OVERLAY_HOVER,
          1.0, 1.0, 1.0, 0.8, WIDTH_OVERLAY_LINE,
        )

  if interaction.operation.isSome:
    let anchor = anchorFor(scene[interaction.index_source].geometry, scale)
    if anchor.isSome:
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if screen.isInFront:
        let tint = lut_drag_to_ink[interaction.operation.get].colour
        gui.overlayLine(
          cfloat(screen.x), cfloat(screen.y),
          cfloat(interaction.cursor.x), cfloat(interaction.cursor.y),
          tint.red, tint.green, tint.blue, 0.85, WIDTH_OVERLAY_LINE,
        )


proc renderFrame(
  window: Window; renderer: Renderer;
  workbench: var Workbench; scene: var Scene; camera: var Camera; interaction: var Interaction;
  now: float; are_dimmed: array[ITEMS_MAX, bool] = default(array[ITEMS_MAX, bool])
): (int, int) =
  ## Lay panels out, draw scene and interaction overlay, and report framebuffer size.
  ##   Panels run first, so an edit made this frame reaches meshes assembled below it.
  ##   Hover is recomputed here too, from this same frame's transform, so a drag started
  ##   next frame reads a pick that matches what was just drawn.
  ##   `now` is this frame's own clock reading; caller decides what clock that is, so a
  ##   real one drives interactive animation and a scripted one drives storyboard capture.
  ##   `are_dimmed` is forwarded to `assembleMeshes` untouched; see its own doc comment.
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
  layoutWorkbench(workbench, scene, camera, HISTORY, now)

  let eye = camera.eye
  let scale = DrawExtent(
    extent_furniture: extentFurnitureFor(camera.distance_far),
    eye: eye,
    radius_horizon: radiusHorizonFor(camera.distance_far),
  )
  assembleMeshes(workbench, scene, now, scale, are_dimmed)
  clearFrame(int(width), int(height))
  let view_projection = camera.initMatrixViewProjection(width / height)
  renderer.drawMeshes(MESHES_FURNITURE, view_projection, WIDTH_LINE_FURNITURE)
  renderer.drawMeshes(MESHES, view_projection)

  interaction.updateHover(scene, camera, view_projection, int(width), int(height))
  drawSelectionRing(
    scene, workbench.selection, view_projection, int(width), int(height), scale
  )
  drawInteractionOverlay(interaction, scene, view_projection, int(width), int(height), scale)

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

func dragOperationFor(button: uint8): Option[DragOperation] =
  ## Name operation a mouse button performs while dragging, if any.
  if button == uint8(MouseButton.Left): some(DragOperation.Join)
  elif button == uint8(MouseButton.Right): some(DragOperation.Meet)
  elif button == uint8(MouseButton.Middle): some(DragOperation.Project)
  else: none(DragOperation)


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
    if gui.wantsKeyboard(): return
    if event.key.scancode == uint32(Scancode.Escape): is_running = false
    if event.key.scancode == uint32(Scancode.S): workbench.is_export_requested = true
  of uint32(EventKind.MouseButtonDown):
    if gui.wantsMouse(): return
    # Press on a pickable item starts an operation drag; press on empty space falls back
    #   to camera control, exactly as before this feature existed.
    let drag = dragOperationFor(event.button.button)
    if drag.isSome and interaction.beginDrag(drag.get):
      button_dragging = some(event.button.button)
    elif event.button.button == uint8(MouseButton.Left):
      is_dragging_orbit = true
    elif event.button.button == uint8(MouseButton.Right):
      is_dragging_pan = true
  of uint32(EventKind.MouseButtonUp):
    if button_dragging == some(event.button.button):
      let outcome = interaction.endDrag(scene, now)
      if len(outcome.message) > 0: toChars(outcome.message, workbench.message)
      if outcome.index_created.isSome:
        workbench.selection.selectOnly(outcome.index_created.get)
        HISTORY.record(scene)
      button_dragging = none(uint8)
    if event.button.button == uint8(MouseButton.Left): is_dragging_orbit = false
    if event.button.button == uint8(MouseButton.Right): is_dragging_pan = false
  of uint32(EventKind.MouseWheel):
    if gui.wantsMouse(): return
    camera.dolly(pow(FACTOR_DOLLY, -float(event.wheel.y)))
  of uint32(EventKind.MouseMotion):
    interaction.updateCursor(float(event.motion.x), float(event.motion.y))
    if is_dragging_orbit:
      camera.orbit(
        -SPEED_ORBIT*float(event.motion.xrel), SPEED_ORBIT*float(event.motion.yrel)
      )
    if is_dragging_pan:
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

    var event: Event
    while sdl3.pollEvent(addr event):
      gui.processEvent(addr event)
      handleEvent(
        event, camera, workbench, scene, interaction,
        is_dragging_orbit, is_dragging_pan, is_running, button_dragging, now,
      )

    let (width, height) =
      renderFrame(window, renderer, workbench, scene, camera, interaction, now)
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
      let report = exportFrame($toCstring(workbench.path_export), width, height)
      toChars(report, workbench.message)
      echo report

    sdl3.glSwapWindow(window)
    if is_final: is_running = false

  echo &"Drew {count_drawn} frames."
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
  var operative_previous: seq[int] = @[]
  for index, step in STEPS:
    clock += 1.0
    let derived = applyStep(scene, step, clock)

    var operative_current = @[step.index_first, count_seeds + index]
    if lut_operation_to_arity[step.operation] == Arity.Two:
      operative_current.add(step.index_second)
    for slot, _ in scene.pairs:
      are_dimmed[slot] =
        not (slot < count_seeds or slot in operative_current or slot in operative_previous)
    operative_previous = operative_current

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
    if isHorizon(derived):
      let shape_derived = shape(derived)
      var heading = none(Direction)
      if shape_derived == some(Shape.Point):
        heading = directionHorizon(derived)
      elif shape_derived == some(Shape.Line):
        let normal = directionNormalHorizon(derived)
        if normal.isSome:
          let axes = spanPerpendicular(Position(x: 0, y: 0, z: 0), normal.get)
          if axes.isSome: heading = some(axes.get[0])
      if heading.isSome:
        (camera.azimuth, camera.elevation) = azimuthElevationFor(heading.get)

    var shape_word: array[WIDTH_SHAPE_WORD, char]
    var cursor_shape = 0
    describeShape(derived, shape_word, cursor_shape)
    finishChars(shape_word, cursor_shape)
    toChars(&"{step.label} gave {$toCstring(shape_word)}.", workbench.message)
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
  let window = sdl3.createWindow(TITLE, PIXELS_WIDTH, PIXELS_HEIGHT, flags)
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
    camera = initCamera(
      target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05, elevation = 0.42
    )
    workbench = initWorkbench(
      if len(options.path_screenshot) > 0: options.path_screenshot
      else: PATH_EXPORT_DEFAULT
    )
  workbench.is_vsync_enabled = not options.is_novsync

  # Open on storyboard's own seeds alone, so window and script agree on where a
  #   construction starts, unless a saved scene was asked for instead, which replaces
  #   the demo entirely.
  let now_startup = secondsNow()
  if len(options.path_load_scene) > 0:
    echo loadScene(scene, options.path_load_scene)
  else:
    constructSeeds(scene, now_startup)
  if options.is_filled: fillSceneForBenchmark(scene, now_startup)
  HISTORY = initHistory(scene)

  if len(options.path_storyboard) > 0:
    runStoryboard(window, renderer, options.path_storyboard, workbench, scene, camera)
  else:
    runInteractive(window, renderer, options, workbench, scene, camera)

main()
