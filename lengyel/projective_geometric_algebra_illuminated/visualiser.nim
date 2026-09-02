## Visualise and manipulate geometric objects of RGA, live, in SDL3 window.
##
## Prototype covers 4D rigid PGA only, i.e. 3D Euclidean space, where grade names object:
## grade 1 is point, grade 2 is line, grade 3 is plane. Conformal metric is out of scope
## until library's round objects settle.
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
##   | e ∧ t             | join     | Camera's sight axis, and frame from it.        |
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
##   camera orbits, and assembles transforms from its RGA-derived frame.
##   picking hit-tests scene items in screen space, against same transforms.
##   marker shapes selection or hover outline to object it marks, in same space.
##   renderer owns OpenGL names and draws meshes.
##   scene holds objects and catalogue of operations that derive new ones.
##   selection holds which objects are picked, in order naming operation's operands.
##   interaction tracks mouse drag from one item to another, and applies what they make.
##   panel lays out widgets user edits scene through.
##   storyboard scripts construction, one operation per exported frame.
##   image encodes frame readback as PNG.
##
## Render paths: this file is native desktop entry point (SDL3/OpenGL/Dear ImGui, compiled
## `--backend:cpp` per `visualiser.nim.cfg`); `visualiser/browser/browser_bridge.nim` is
## browser entry point (compiled through `nim js` per its sibling `browser_bridge.nim.cfg`,
## presentation by hand-written JS). Neither imports other, and nothing shared imports
## either render target's presentation layer.
##
## **Directory module sits in is which render path may reach it**, so boundary is read off
## layout rather than off table kept in step with it:
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
## itself and `pga`; `desktop` and `browser` each import `core` and never each other.
## `core` module needing something only one path has states that as `when not
## defined(js)` and is exercised on both backends by suite.
##
## Controls:
##   Drag from one object to another to derive third. What it derives is read off two
##   grades, not off button, and ghosted while dragging; rubber-band is tinted to match,
##   and wears reserved magenta over pair that makes nothing. Left takes that answer; right
##   opens four-way choice menu, as does holding still over target. `more…` hands both
##   operands to apply section, for other twenty-four.
##   Drag from empty space to move camera: left orbits, right pans, wheel zooms toward
##   whatever pointer is over.
##   `ctrl+S` writes current frame to export path. `Escape` abandons whatever is in
##   progress (help panel, drag, open edit, selection); `ctrl+Z` and `ctrl+shift+Z` step
##   same timeline panel's undo and redo buttons do. `ctrl+Q` quits; `Escape` used to,
##   and pressing it twice to be sure of cancel would have thrown away unsaved scene.
##   `?` in bottom-right corner says all of this, from `help.nim`, which browser's help
##   panel reads too.
##   Every panel is collapsing header; `diagnostics` starts closed and holds live frame
##   time, memory use of both arenas, and object pool.
##
## Command line, for validating build without sitting in front of it:
##   `--screenshot:PATH` writes one PNG, `--frames:N` exits after N frames, `--hidden`
##   never maps window, `--storyboard:DIR` writes one frame per scripted construction step
##   and quits.
##   `--timings` reports frame-time statistics (mean, percentiles, tessellation cost) over
##   `--frames:N` run; `--novsync` disables vsync from startup, `--fill` tops scene up to
##   capacity first.
##   `--drive-drag` scripts construction drag through SDL's event queue, so headless run
##   can be caught mid-gesture with choice menu open; `--drive-keys` scripts run of view
##   keys and reports what camera and focus did; `--drive-undo` builds something, orbits
##   away and undoes it, so where undo leaves view can be looked at.

{.experimental: "strictFuncs".}

when compileOption("profiler"):
  import std/nimprof

import std/[algorithm, math, monotimes, options, os, parseopt, strformat, strutils]

import ./pga
import ./visualiser/core/[
  algebra_trace, algebra_view, boundary, camera, format, framing, help, history,
  interaction, marker, orrery, picking,
  scene, selection, storyboard, tessellate, timings,
]
import ./visualiser/desktop/[arena, gif, gui, image, panel, renderer]
import ./visualiser/desktop/opengl as gl
import ./visualiser/desktop/sdl3



#[ Application Configuration ]#

const
  TITLE* = "Projective Geometric Algebra Illuminated — RGA visualiser"
  SAMPLES_MULTISAMPLE* {.define: "visualiser.samples_multisample".} = 4
    ## Ask framebuffer for this many samples per pixel. Four is where 1.5-pixel ribbon
    ## stops reading as dotted; more buys little on geometry this thin.
  PIXELS_WIDTH* {.define: "visualiser.pixels_width".} = 1440
  PIXELS_HEIGHT* {.define: "visualiser.pixels_height".} = 900
  PATH_FONT* {.define: "visualiser.path_font".} =
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf"
    ## Carry UI's text: Latin, punctuation, subscripts and combining marks.
  PATH_FONT_MATH* {.define: "visualiser.path_font_math".} =
    "/usr/share/fonts/truetype/noto/NotoSansMath-Regular.ttf"
    ## Carry operators notation is written with, and Lengyel's bold operands, neither of
    ## which Noto Sans has. Merged into same atlas font; see `gui_shim.cpp`.
  PATH_FONT_SYMBOL* {.define: "visualiser.path_font_symbol".} =
    "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf"
    ## Carry bulk and weight dual stars and abandon button's cross. Merged same way.
  SIZE_FONT* = 16.0'f32
  PATH_EXPORT_DEFAULT* = "rga_visualiser.png"

const
  SPEED_ORBIT = 0.008
    ## Set how far dragged pixel turns orbit, in radians.
  FACTOR_DOLLY = 1.12
    ## Set how much one wheel notch scales orbit distance; notch is aimed at cursor
    ## (`interaction.dollyAtCursor`).
  FRAMES_SETTLE = 2
    ## Draw this many frames before capturing, so widget layout has settled.
  INK_GHOST = Ink.Guide
    ## Palette slot add panel's uncommitted multivector draws in, muted; reuses
    ## `Ink.Guide`'s "construction helper" role. Mirrors `browser_bridge.INK_GHOST`.
  FRAMES_GIF_GROW = 6
    ## Set how many sub-frames sweep each storyboard step's appear animation.
  FRAMES_GIF_HOLD = 4
    ## Set how many repeated frames hold on step's settled result.
  CENTISECONDS_GIF_DELAY = 8
    ## Set hold time per GIF frame, in hundredths of second.
  STRIDE_GIF = 2
    ## Keep every this-many-th pixel in both directions, so storyboard's GIF stays short
    ## preview.
  WIDTH_SHAPE_WORD = 32
    ## Bound length of shape word alone, longest being "mixed grade, nothing to draw".
  WIDTH_EXPORT_MAX* {.define: "visualiser.width_export_max".} = 3840
    ## Bound largest window pixel readback or PNG export is ever asked to cover.
  HEIGHT_EXPORT_MAX* {.define: "visualiser.height_export_max".} = 2160
  CAPACITY_ARENA_PERMANENT* {.define: "visualiser.capacity_arena_permanent".} = 160*1024*1024
    ## Set permanent arena's size: pixel readback buffer and every storyboard GIF frame
    ## live here for whole process. Sized for `STRIDE_GIF`'s downsample plus
    ## `WIDTH_EXPORT_MAX`x`HEIGHT_EXPORT_MAX` readback, with headroom; GIF storage scales
    ## with `STEPS`.
  CAPACITY_ARENA_FRAME* {.define: "visualiser.capacity_arena_frame".} = 64*1024*1024
    ## Set frame arena's size: PNG's filtered scanlines or one GIF frame's quantized
    ## indices and LZW output, reclaimed once that unit of work is written out.
  CAPACITY_ARENA_SWAP* {.define: "visualiser.capacity_arena_swap".} = 256*1024
    ## Set each half of frame swap pair. Two blocks: pair's promise is that last frame's
    ## bytes are still there to read.
    ##   Sized from loops that carve it: largest is ground grid's, bounded by
    ## `mesh.LINES_GRID_MAX` chords, under 20 KiB. Quarter mebibyte leaves room, and both
    ## halves are ten-thousandth of export arena.
  FRAMES_TIMING_MAX* {.define: "visualiser.frames_timing_max".} = 20_000
    ## Bound how many per-frame timings `--timings` can record; independent of arenas,
    ## since benchmark run is not interactive draw loop.
  BYTES_MEMORY_TOTAL* =
    CAPACITY_ARENA_PERMANENT + CAPACITY_ARENA_FRAME + 2*CAPACITY_ARENA_SWAP +
    2*sizeof(MeshSet) + sizeof(Scene) + sizeof(History) + sizeof(Panel) +
    FRAMES_TIMING_MAX*sizeof(float32)
    ## Sum of every fixed-size reservation this binary makes: both arenas at full
    ## capacity, committed in data segment regardless of use; both mesh sets; object pool;
    ## undo timeline, `history.CAPACITY_HISTORY` whole copies of that pool; panel's state;
    ## `--timings` buffer. Excludes anything Dear ImGui, SDL or driver allocate.
    ##   Timeline was missing until pool at 10080 slots made it largest term (71.1 MiB
    ## against 12.3 for both mesh sets). Figure omitting its biggest entry is worse than
    ## none.

static:
  doAssert PIXELS_WIDTH >= 640 and PIXELS_HEIGHT >= 480,
    &"Window must be at least 640x480; got `{PIXELS_WIDTH}x{PIXELS_HEIGHT}`."
  doAssert PIXELS_WIDTH <= WIDTH_EXPORT_MAX and PIXELS_HEIGHT <= HEIGHT_EXPORT_MAX,
    &"Window must fit within the {WIDTH_EXPORT_MAX}x{HEIGHT_EXPORT_MAX} export bound; " &
    &"raise `--define:visualiser.width_export_max` or `...height_export_max`."

# Hold vertex storage at module scope, far too large for stack frame.
var MESHES: MeshSet ## Every scene object, excluding world furniture below.
var TRACE: AlgebraTrace ## Scratch debug layer records into, reused every frame: `ITEMS_MAX`
  ## entries long. See `algebra_view.addFrameTrace`.
var SETTINGS_FURNITURE_HELD = none(SettingsFurniture)
  ## What `MESHES_FURNITURE` stands for, or none before first frame. Desktop was clearing
  ## and rebuilding furniture every frame, so still camera paid whole grid for nothing.
var MESHES_FURNITURE: MeshSet ## Ground grid and world axes alone, drawn in own pass before
  ## scene's, so every object's translucent wash blends over reference marks. Thinner width
  ## (`mesh.WIDTH_LINE_FURNITURE`) is geometry, not draw setting; this ordering needs pass.
var CLOCK_PULSE: PulseClock ## Each selected object's orientation-pulse phase, carried
  ## between frames. Module scope as `HISTORY` is: too large for stack, outlives frames.
var HISTORY: History ## Undo/redo timeline of scene-content edits; too large for stack
  ## (`history.CAPACITY_HISTORY * sizeof(Scene)`). Zeroed placeholder until `main` seeds it
  ## via `initHistory` once startup scene is built.

# Two arenas, one permanent and one reset after each throwaway unit of work; see
#   `arena.nim` for why interactive draw loop needs neither.
var
  BUFFER_ARENA_PERMANENT: array[CAPACITY_ARENA_PERMANENT, byte]
  ARENA_PERMANENT = initArena(BUFFER_ARENA_PERMANENT)
  BUFFER_ARENA_FRAME: array[CAPACITY_ARENA_FRAME, byte]
  ARENA_FRAME = initArena(BUFFER_ARENA_FRAME)
  # Draw loop's scratch, two blocks swapped each frame so what one frame assembled is
  #   still readable through next. See `arena.ArenaSwap`.
  BUFFER_ARENA_SWAP_FIRST: array[CAPACITY_ARENA_SWAP, byte]
  BUFFER_ARENA_SWAP_SECOND: array[CAPACITY_ARENA_SWAP, byte]
  ARENA_SWAP = initArenaSwap(BUFFER_ARENA_SWAP_FIRST, BUFFER_ARENA_SWAP_SECOND)

# Carved once from permanent arena: pixel readback every export reuses.
var PIXELS_READBACK = push[uint8](ARENA_PERMANENT, WIDTH_EXPORT_MAX*HEIGHT_EXPORT_MAX*3)

# Carved once from permanent arena: every GIF frame storyboard run collects, back to
#   back, before `writeGif` reads them all at end.
const
  WIDTH_GIF_MAX = PIXELS_WIDTH div STRIDE_GIF
  HEIGHT_GIF_MAX = PIXELS_HEIGHT div STRIDE_GIF
  COUNT_GIF_FRAMES_MAX = (len(STEPS) + 1) * (FRAMES_GIF_GROW + FRAMES_GIF_HOLD)
var GIF_FRAMES =
  push[uint8](ARENA_PERMANENT, COUNT_GIF_FRAMES_MAX*WIDTH_GIF_MAX*HEIGHT_GIF_MAX*3)

# Module scope as `MESHES` is: too large for stack, touched only by `--timings` run.
var TIMINGS_FRAME_MILLISECONDS: array[FRAMES_TIMING_MAX, float32]



#[ Command Line ]#

type Options = object ## Hold what command line asked of this run.
  path_screenshot: string ## Where one-shot export is written; empty for none.
  path_storyboard: string ## Directory scripted construction is written to; empty for none.
  path_load_scene: string ## Scene file to open instead of built-in demo; empty for none.
  count_frames: int ## Frames to draw before quitting; 0 to run until closed.
  is_hidden: bool ## Whether window is left unmapped.
  is_timed: bool ## Whether to record and report per-frame timing statistics.
  is_novsync: bool ## Whether to disable vsync from startup, for uncapped timing runs.
  is_filled: bool ## Whether to top scene up to capacity with synthetic items, for timing
    ## heaviest tessellation and draw load.
  scale_demo: Option[ScaleOrrery] ## Which size of orrery preset to open on instead of
    ## storyboard's seeds, if any, through same `orrery.showOrrery` browser's demo buttons
    ## load. Desktop had no way to reach heaviest scene shared core builds.
    ##   `Option`, not `bool` and size: "no demo" and "demo at default size" differ, and
    ## sentinel size would put absence inside value's range.
  is_asserted: bool ## Whether driven run ends in verdict rather than report, exiting
    ## non-zero where it fails. See `verdictDriven`.
  is_drag_driven: bool ## Whether to script construction drag through event queue, so
    ## headless run shows drag mid-gesture. See `driveDrag`.
  is_key_driven: bool ## Whether to script run of view keys through event queue, so
    ## headless run shows they reach view. See `driveKeys`.
  is_select_driven: bool ## Whether to script clicks picking one, two and three objects,
    ## so headless run shows floating selection menu at each. See `driveSelect`.
  is_undo_driven: bool ## Whether to script construction, orbit away and undo, so
    ## headless run shows where undo leaves view. See `driveUndo`.
  is_sky_driven: bool ## Whether to script drag and click on bare sky, so headless run
    ## shows press on it still reaches camera. See `driveSky`.
  path_help_driven: Option[HelpPath] ## Which help tab to open at startup, if any.
    ## Headless run cannot click tab strip, so `--drive-help:<tab>` names one.


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
      of "demo":
        # Named by item count; counts come from `itemsOf`, so size added in `orrery` is
        #   accepted here untouched.
        if len(value) == 0:
          result.scale_demo = some(SCALE_ORRERY_DEFAULT)
        else:
          for scale in ScaleOrrery:
            if $itemsOf(scale) == value: result.scale_demo = some(scale)
          var counts: seq[string]
          for scale in ScaleOrrery: counts.add($itemsOf(scale))
          doAssert result.scale_demo.isSome,
            &"Unknown demo size `{value}`; expected " & counts.join(", ") &
              ", or `--demo` on its own for the default."
      of "drive-assert": result.is_asserted = true
      of "drive-drag": result.is_drag_driven = true
      of "drive-keys": result.is_key_driven = true
      of "drive-select": result.is_select_driven = true
      of "drive-undo": result.is_undo_driven = true
      of "drive-sky": result.is_sky_driven = true
      of "drive-help":
        for path in HelpPath:
          if titleOf(path) == value: result.path_help_driven = some(path)
        doAssert result.path_help_driven.isSome,
          &"Unknown help tab `{value}`; expected one this build actually has."
      else:
        doAssert false,
          &"Unknown option `--{key}`; expected screenshot, storyboard, load-scene, " &
          "frames, hidden, timings, novsync, fill, demo[:<items>], drive-assert, " &
          "drive-drag, " &
          "drive-keys, drive-select, drive-undo, drive-sky or drive-help."
    of cmdArgument:
      doAssert false, &"Unexpected argument `{key}`; every input is a named option."
    of cmdEnd: discard



#[ Frame Assembly ]#

proc secondsNow(): float =
  ## Read monotonic clock as seconds, for animating how recently item was added.
  ##   Nanosecond ticks since no fixed epoch, only ever differenced within one process.
  float(getMonoTime().ticks) / 1_000_000_000.0


proc offerCameraAim(
  panel: var Panel; scene: Scene; camera: Camera; scale: DrawExtent; now: float;
  width, height: int
) =
  ## Offer camera whatever is being worked on to frame, from one rule.
  ##   Rule is `framing.offerAim`, shared with browser; this hands it panel's staged
  ## session and selection, and frame's pixel dimensions. Every construction path leaves
  ## new object selected, so all frame result without knowing about camera.
  panel.tween_camera.offerAim(
    camera, scene, panel.selection, panel.staged, scale, width, height, now,
    ANIMATION_SECONDS,
  )


proc assembleMeshes(
  panel: var Panel; scene: Scene; interaction: Interaction;
  camera: Camera; now: float; scale: DrawExtent; width, height: int;
  are_dimmed: array[ITEMS_MAX, bool] = default(array[ITEMS_MAX, bool])
) =
  ## Refill vertex storage from scene as it stands this frame, recording what it cost.
  ##   `are_dimmed` grays item out rather than skipping it; empty for interactive
  ## rendering, filled by storyboard's rolling emphasis alone.
  ##   Assembles alone: where camera should look is `offerCameraAim`'s job.
  let ticks_start = getMonoTime().ticks
  # Where grid assembles pieces before emitting, carved from frame pair: per-frame scratch
  #   that arena was waiting for, handed back clean at top of every frame.
  let scratch = ARENA_SWAP.current.push[:DrawScratch](1)
  # Held on unchanged frames, by same rule and tuple as browser.
  let settings_furniture = settingsFurnitureFor(
    camera, height, panel.is_axes_shown, panel.is_grid_shown,
  )
  if SETTINGS_FURNITURE_HELD.isNone or SETTINGS_FURNITURE_HELD.get != settings_furniture:
    SETTINGS_FURNITURE_HELD = some(settings_furniture)
    MESHES_FURNITURE.clearMeshes
    if panel.is_grid_shown:
      MESHES_FURNITURE.addGrid(scratch[0], scale.extent_furniture, scale)
    if panel.is_axes_shown:
      MESHES_FURNITURE.addAxes(scratch[0], scale.extent_furniture, scale)

  MESHES.clearMeshes
  # Horizon plane's dome first, before anything sharing translucent wash pass: wash runs
  #   draw in append order, unsorted by depth, so dome first guarantees every ordinary
  #   plane's fill blends over it whatever slot either occupies.
  for slot, item in scene.pairs:
    if not item.isVisible or not isHorizonPlane(item.geometry) or slot in panel.selection:
      continue
    let progress = animationProgress(now, item.born)
    let tint = if are_dimmed[slot]: muted(item.ink.colour) else: item.ink.colour
    discard MESHES.addObject(scratch[0], item.geometry, tint, scale, progress, item.anchorOverride)

  for slot, item in scene.pairs:
    if not item.isVisible or isHorizonPlane(item.geometry) or slot in panel.selection:
      continue
    let progress = animationProgress(now, item.born)
    let tint = if are_dimmed[slot]: muted(item.ink.colour) else: item.ink.colour
    discard MESHES.addObject(scratch[0], item.geometry, tint, scale, progress, item.anchorOverride)

  # Open edit session's staged multivector, through same dispatch real object uses, so
  #   composing shows exactly what saving gives. Never enters `scene`; all-zero staging
  #   degrades to "nothing to draw". While editing existing object, ghost draws beside it.
  #   Or, with no session open, whatever apply control previews: one ghost for both;
  #   `panel.staged` decides order.
  let staged = panel.staged
  if staged.isSome:
    discard MESHES.addObject(
      scratch[0], staged.get.geometry, muted(INK_GHOST.colour), scale,
      anchor_override = staged.get.anchor,
    )

  # What drag in progress would build, in same ghost ink, so reader learns one "not
  #   committed yet" appearance. Centred on anchor commit stores, so ghosted plane stays
  #   where ghosted.
  if interaction.preview.isSome:
    discard MESHES.addObject(
      scratch[0], interaction.preview.get.geometry, muted(INK_GHOST.colour), scale,
      anchor_override = interaction.preview.get.anchor,
    )

  # Everything selected, held back to here and drawn with depth test off, so picked object
  #   is never buried by whatever stands between it and camera. Lasts as long as selection
  #   does. Horizon plane selected comes through here too, costing its dome first-in-bucket
  #   place above; sky drawn over one plane while selected is point of this pass.
  MESHES.markOverlay
  for position in 0 ..< panel.selection.len:
    let slot = panel.selection.at(position)
    if not scene.isAlive(slot) or not scene[slot].isVisible: continue
    let item = scene[slot]
    let progress = animationProgress(now, item.born)
    let tint = if are_dimmed[slot]: muted(item.ink.colour) else: item.ink.colour
    discard MESHES.addObject(scratch[0], item.geometry, tint, scale, progress, item.anchorOverride)

  # **Algebra's own layer**, over everything: every multivector this frame computed, drawn
  #   as what it is; `algebra_view.addFrameTrace`, shared with browser. See
  #   `algebra_trace`.
  if panel.is_algebra_shown:
    MESHES.addFrameTrace(
      scratch[0], TRACE, scene, camera, staged, interaction.cursor, scale,
      width = width, height = height,
    )

  panel.microseconds_tessellate = float(getMonoTime().ticks - ticks_start) / 1000.0
  # Per record, what its shader emits: vertices drawn, not floats carried. Six per ribbon,
  #   whole fan per disc, sphere per dome.
  panel.count_vertices =
    MESHES.points.count_vertices + MESHES_FURNITURE.points.count_vertices +
    6*(MESHES.ribbons.count + MESHES_FURNITURE.ribbons.count) +
    3*SEGMENTS_CIRCLE_HORIZON*(MESHES.discs.count + MESHES_FURNITURE.discs.count) +
    6*LATITUDES_HORIZON*LONGITUDES_HORIZON*(MESHES.domes.count + MESHES_FURNITURE.domes.count)


proc drawMarkerPulse(marker: Marker; tint: Rgba; alpha: float32) =
  ## Fill orientation pulse travelling along marker's outline, if it has one.
  ##   Over outline rather than instead of it: pulse is outline swelling along stretch of
  ## itself, tapering back to outline's width so only its head is edge.
  ##   Shape of what pulses is `marker.nim`'s business; every run arrives closed and in
  ## screen space.
  for run in 0 ..< marker.count_run_pulse:
    var points: array[2*POINTS_MARKER_PULSE, cfloat]
    for i in 0 ..< marker.counts_pulse[run]:
      points[2*i] = cfloat(marker.pulses[run][i].x)
      points[2*i + 1] = cfloat(marker.pulses[run][i].y)
    gui.overlayRibbon(
      addr points[0], cint(marker.counts_pulse[run]), tint.red, tint.green, tint.blue,
      alpha,
    )


proc drawMarker(marker: Marker; tint: Rgba; alpha: float32) =
  ## Stroke one marker onto foreground layer, in whichever outline its shape asked for.
  ##   Alpha separate from `tint`, so selection and hover reach this through identical
  ## call and differ only in weight.
  drawMarkerPulse(marker, tint, alpha)
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
    # Flatten to x/y pairs shim's path call takes; stack storage, bound is compile-time.
    var points: array[2*SEGMENTS_MARKER_LOOP, cfloat]
    for i in 0 ..< marker.count_point:
      points[2*i] = cfloat(marker.points[i].x)
      points[2*i + 1] = cfloat(marker.points[i].y)
    gui.overlayPolyline(
      addr points[0], cint(marker.count_point), tint.red, tint.green, tint.blue, alpha,
      WIDTH_MARKER, cint(ord(marker.is_closed)),
    )
  of MarkerKind.Bands:
    # Two independent runs: each band is cut by eye on its own, so one may be closed ring
    #   while other is arc.
    for side in 0 .. 1:
      if marker.counts_band[side] == 0: continue
      var points: array[2*SEGMENTS_MARKER_BANDS, cfloat]
      for i in 0 ..< marker.counts_band[side]:
        points[2*i] = cfloat(marker.points_band[side][i].x)
        points[2*i + 1] = cfloat(marker.points_band[side][i].y)
      gui.overlayPolyline(
        addr points[0], cint(marker.counts_band[side]), tint.red, tint.green, tint.blue,
        alpha, WIDTH_MARKER, cint(ord(marker.are_closed_band[side])),
      )
  of MarkerKind.Frame:
    # Closed unconditionally: built in screen space, no eye to cut it.
    var points: array[2*(SEGMENTS_MARKER_FRAME + CORNERS_MARKER_FRAME), cfloat]
    for i in 0 ..< marker.count_frame:
      points[2*i] = cfloat(marker.points_frame[i].x)
      points[2*i + 1] = cfloat(marker.points_frame[i].y)
    gui.overlayPolyline(
      addr points[0], cint(marker.count_frame), tint.red, tint.green, tint.blue, alpha,
      WIDTH_MARKER, 1,
    )


proc drawSelectionMarker(
  scene: Scene; selection: Selection; clock: var PulseClock; camera: Camera;
  view_projection: Matrix4; width, height: int; scale: DrawExtent; seconds_step: float
): int {.discardable.} =
  ## Draw one marker per selected item onto foreground layer, shaped by `marker.markerFor`
  ## and tinted `Ink.Outline`. Report how many were drawn.
  ##   One per selected slot: operation reads two operands, and selection that cannot be
  ## seen is not worth much. Count lets test assert what was drawn without reading pixels.
  ##   Unconditional, unlike hover/drag: storyboard step uses this marker to show what it
  ## built, with interaction disabled.
  let tint = Ink.Outline.colour
  for position in 0 ..< selection.len:
    let slot = selection.at(position)
    if not (scene.isAlive(slot) and scene[slot].isVisible): continue
    let item = scene[slot]
    # Phase says "this one is selected": places orientation pulse; hover and focus pass
    #   none, so motion means selected.
    var marker: Marker
    if not markerFor(
      item.geometry, item.anchorOverride, scale, camera, view_projection, width, height,
      marker, travel = some(clock.travelAt(slot)),
    ): continue
    # Against lap this marker came out with, so orbiting changes where comet wraps and
    #   never how fast it travels. See `PulseClock`.
    clock.advance(slot, marker.lap, seconds_step)
    drawMarker(marker, tint, ALPHA_MARKER_SELECTED)
    result.inc


const
  # Floating selection menu's tones, so wheel and that menu read as one control. Taken
  #   from browser's `--surface-raised`, `--border`, `--accent` and `--accent-ink`, same
  #   copy `gui_shim.guiButtonToggle` makes: chrome palette is stylesheet on one front-end
  #   and ImGui theme on other. **Check siblings when changing one**: `shell.html`'s
  #   `:root` block and `gui_shim.cpp`.
  TONE_WEDGE_SURFACE = (red: 0.106'f32, green: 0.129'f32, blue: 0.169'f32)
  TONE_WEDGE_BORDER = (red: 0.165'f32, green: 0.196'f32, blue: 0.239'f32)
  TONE_WEDGE_CHOSEN = (red: 0.0'f32, green: 0.655'f32, blue: 0.647'f32)
  TONE_WEDGE_LABEL = (red: 0.906'f32, green: 0.925'f32, blue: 0.945'f32)
  TONE_WEDGE_LABEL_CHOSEN = (red: 0.741'f32, green: 0.953'f32, blue: 0.941'f32)


proc drawChoiceMenu(interaction: Interaction; scene: Scene) =
  ## Draw four wedges of open choice menu onto foreground layer.
  ##   Every wedge at every opening, at fixed compass point, offered or not, so position
  ## of `meet` is learned once. Which one cursor stands in is `interaction.choosing`'s
  ## answer, same one release acts on and ghost is shaped from.
  ##   **Wedge is selection menu's button, moved.** Surface fill, hairline border, `--ink`
  ## label, `--accent` border and `--accent-ink` label on one in force, rather than solid
  ## slab of choice's hue, which made two menus look like two things. Label is catalogue
  ## notation `labelOf` reads from `scene.notationSymbolic`. Hues are taught in drawer's
  ## legend and still tint rubber-band.
  let
    centre = interaction.menu.get
    over = destinationOf(interaction)
    highlighted = interaction.choosing
    is_pair_live =
      over.isSome and over.get != interaction.index_source and
      scene.isAlive(over.get) and scene.isAlive(interaction.index_source)

  let dot = Ink.Outline.colour
  gui.overlayCircle(
    cfloat(centre.x), cfloat(centre.y), RADIUS_MENU_CENTRE,
    dot.red, dot.green, dot.blue, 0.7, WIDTH_MARKER, is_over_windows = 1,
  )
  for choice in DragChoice:
    let
      label = labelOf(choice)
      is_offered =
        choice == DragChoice.More or
        (is_pair_live and isOffered(
          choice, scene.geometryOf(interaction.index_source), scene.geometryOf(over.get)
        ))
      is_chosen = highlighted == some(choice)
      at = anchorOf(centre, choice)
      alpha = cfloat(if is_offered: ALPHA_MENU_WEDGE else: ALPHA_MENU_UNOFFERED)
      width = gui.textWidth(cstring(label)) + PADDING_MENU_WEDGE
    # Border first and surface inside it, how hairline outline is drawn with widget that
    #   only fills; chosen wedge swaps border for accent, so highlight survives reader who
    #   cannot tell hues apart.
    let edge = if is_chosen: TONE_WEDGE_CHOSEN else: TONE_WEDGE_BORDER
    gui.overlayChip(
      cfloat(at.x), cfloat(at.y), width + 2.0*WIDTH_MENU_WEDGE_BORDER,
      HEIGHT_MENU_WEDGE + 2.0*WIDTH_MENU_WEDGE_BORDER,
      edge.red, edge.green, edge.blue, alpha,
      ROUNDING_MENU_WEDGE + WIDTH_MENU_WEDGE_BORDER,
    )
    gui.overlayChip(
      cfloat(at.x), cfloat(at.y), width, HEIGHT_MENU_WEDGE,
      TONE_WEDGE_SURFACE.red, TONE_WEDGE_SURFACE.green, TONE_WEDGE_SURFACE.blue, alpha,
      ROUNDING_MENU_WEDGE,
    )
    let ink_label = if is_chosen: TONE_WEDGE_LABEL_CHOSEN else: TONE_WEDGE_LABEL
    gui.overlayText(
      cfloat(at.x), cfloat(at.y), ink_label.red, ink_label.green, ink_label.blue,
      cfloat(if is_offered: 1.0 else: 0.6), cstring(label),
    )


proc drawInteractionOverlay(
  interaction: Interaction; scene: Scene; camera: Camera; view_projection: Matrix4;
  width, height: int; scale: DrawExtent
) =
  ## Draw drag's rubber-band and hover's marker onto foreground layer.
  ##   Off entirely during storyboard capture, where interaction is never enabled.
  if not interaction.is_enabled: return

  # Hover wears selection's marker at lower opacity, so hovering line previews rails
  #   selecting it draws. Keyboard focus wears same marker: focus indicator WCAG 2.4.7
  #   asks for is machinery already built and tested.
  for index in [interaction.index_hover, interaction.index_focus]:
    if index.isNone or not scene.isAlive(index.get): continue
    let item = scene[index.get]
    var marker: Marker
    if markerFor(
      item.geometry, item.anchorOverride, scale, camera, view_projection, width, height,
      marker,
    ):
      drawMarker(marker, Ink.Outline.colour, ALPHA_MARKER_HOVER)

  if interaction.is_dragging:
    let source = scene[interaction.index_source]
    # From where source is *drawn*: plane's disc is centred on creation anchor, and band
    #   leaving support leaves from point nowhere on circle.
    let anchor = anchorFor(source.geometry, source.anchorOverride, scale)
    if anchor.isSome:
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if screen.isInFront:
        # Tinted by what releasing would do, same rule browser's rubber-band answers from.
        let tint = interaction.inkOfDrag(scene.inkNext).colour
        gui.overlayLine(
          cfloat(screen.x), cfloat(screen.y),
          cfloat(interaction.cursor.x), cfloat(interaction.cursor.y),
          tint.red, tint.green, tint.blue, 0.85, WIDTH_MARKER,
        )
        # Which way round pair is taken, drawn at end where answer lands. None while
        #   cursor rests on own source.
        let comet = cometFor(screen, interaction.cursor)
        if comet.isSome:
          var points: array[2*POINTS_MARKER_PULSE, cfloat]
          for i, point in comet.get:
            points[2*i] = cfloat(point.x)
            points[2*i + 1] = cfloat(point.y)
          gui.overlayRibbon(
            addr points[0], POINTS_MARKER_PULSE, tint.red, tint.green, tint.blue, 0.85,
          )
  if interaction.menu.isSome:
    drawChoiceMenu(interaction, scene)



proc anchorOfSelection(
  panel: Panel; scene: Scene; view_projection: Matrix4; width, height: int;
  scale: DrawExtent
): Option[tuple[x, y: cfloat]] =
  ## Say where most recently picked object sits on screen, for floating selection menu to
  ## follow.
  ##   *Most recent* rather than middle of them all, which would jump as membership
  ## changes. Through same anchor-aware `mesh.anchorFor` rubber-band and browser's
  ## `nimAnchorScreen` use, so menu, marker and drag line agree on where object is.
  ##   None where nothing is picked, object has no representative point, or stands behind
  ## camera; see `layoutSelectionMenu`.
  ##   Plane at horizon goes to middle of view: it has no place in scene, so its menu goes
  ## to centre of frame `marker.markerFrame` draws around it.
  ##   **Duplicated by constraint** in `browser_bridge.nimAnchorScreen`; fix both or
  ## neither.
  if panel.selection.len == 0: return none(tuple[x, y: cfloat])
  let slot = panel.selection.at(panel.selection.len - 1)
  if not scene.isAlive(slot): return none(tuple[x, y: cfloat])
  if scene[slot].geometry.isHorizonPlane:
    return some((x: cfloat(0.5*float(width)), y: cfloat(0.5*float(height))))
  let anchor = anchorFor(scene[slot].geometry, scene[slot].anchorOverride, scale)
  if anchor.isNone: return none(tuple[x, y: cfloat])
  let screen = projectToScreen(view_projection, width, height, anchor.get)
  if not screen.isInFront: return none(tuple[x, y: cfloat])
  some((x: cfloat(screen.x), y: cfloat(screen.y)))


proc renderFrame(
  window: Window; renderer: Renderer;
  panel: var Panel; scene: var Scene; camera: var Camera; interaction: var Interaction;
  now: float; are_dimmed: array[ITEMS_MAX, bool] = default(array[ITEMS_MAX, bool]);
  path_help: Option[HelpPath] = none(HelpPath)
): (int, int) =
  ## Lay panels out, draw scene and interaction overlay, and report framebuffer size.
  ##   Panels run first, so edit made this frame reaches meshes assembled below. Hover is
  ## recomputed here from same frame's transform, so drag started next frame reads pick
  ## matching what was drawn.
  ##   `now` is this frame's clock; caller decides which clock, real or scripted.
  ## `are_dimmed` and `path_help` are forwarded untouched to `assembleMeshes` and
  ## `layoutHelp`.
  var (width, height) = (cint(PIXELS_WIDTH), cint(PIXELS_HEIGHT))
  sdl3.getWindowSizeInPixels(window, addr width, addr height)

  # Snapshot both arenas before panel reading them draws, so it shows this frame's state;
  #   shared by both run modes.
  panel.bytes_arena_permanent_used = ARENA_PERMANENT.used
  panel.bytes_arena_permanent_capacity = ARENA_PERMANENT.capacity
  panel.bytes_arena_frame_peak = ARENA_FRAME.peakUsed
  panel.bytes_arena_frame_capacity = ARENA_FRAME.capacity
  panel.bytes_memory_total = BYTES_MEMORY_TOTAL

  gui.frameBegin()
  # Consumed before layout, so key pressed this frame and button beside it reach timeline
  #   through identical call on same frame.
  if panel.is_undo_requested or panel.is_redo_requested:
    let is_undo = panel.is_undo_requested
    (panel.is_undo_requested, panel.is_redo_requested) = (false, false)
    toChars(
      if stepHistory(panel, scene, camera, HISTORY, is_undo):
        (if is_undo: "Stepped back." else: "Stepped forward.")
      else:
        (if is_undo: "Nothing to undo." else: "Nothing to redo."),
      panel.message,
    )
  layoutPanel(panel, scene, camera, HISTORY, now)
  layoutHelp(panel, path_help)

  # Advance before this frame's transforms are built, so frame draws where camera has
  #   reached. `offerCameraAim` sets goal this advance consumes next frame, one frame
  #   later by design.
  panel.tween_camera.advance(camera, now, easeOutCubic)

  let scale = camera.drawExtentFor(int(height))
  offerCameraAim(panel, scene, camera, scale, now, int(width), int(height))
  # Hover and drag reading it run *before* meshes are assembled, so drag's preview is this
  #   frame's. Transform they pick against needs only camera, already advanced.
  let view_projection = camera.initMatrixViewProjection(width / height)
  # Floating menu placed here because it needs this frame's transform, and *before* meshes
  #   are assembled, so delete pressed on it leaves scene this frame draws.
  layoutSelectionMenu(
    panel, scene, camera, HISTORY,
    anchorOfSelection(panel, scene, view_projection, int(width), int(height), scale),
    now,
  )
  interaction.updateHover(scene, camera, scale, view_projection, int(width), int(height))
  interaction.pruneFocus(scene)
  interaction.updateDrag(scene, now)
  assembleMeshes(
    panel, scene, interaction, camera, now, scale, int(width), int(height), are_dimmed
  )
  clearFrame(int(width), int(height))
  renderer.drawMeshes(MESHES_FURNITURE, view_projection, scale)
  renderer.drawMeshes(MESHES, view_projection, scale)

  # One reading per frame, before any slot advances, so every selected object's comet
  #   moves by same step.
  let seconds_step = CLOCK_PULSE.secondsStep(now)
  CLOCK_PULSE.tick(now)
  drawSelectionMarker(
    scene, panel.selection, CLOCK_PULSE, camera, view_projection, int(width), int(height),
    scale, seconds_step,
  )
  drawInteractionOverlay(
    interaction, scene, camera, view_projection, int(width), int(height), scale
  )

  gui.frameEnd()
  (int(width), int(height))


proc exportFrame(path: string; width, height: int): string =
  ## Read framebuffer back and write it out as PNG, reporting what happened.
  ##   Must run before buffers are swapped, as back buffer is what was drawn into. Reads
  ## into permanent arena's pixel buffer, writes through frame arena, reset on close.
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
  ## Keep every `stride`-th pixel in both directions, so GIF frame stays small without box
  ## filter costing time on diagnostic capture.
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
  ## Translate one SDL scancode into key view knows it by, if it is one.
  ##   Only numbering is this build's own; what each key *does* is
  ## `interaction.actionFor`'s, so both render paths and help answer from one table.
  if scancode == uint32(Scancode.W): some(Key.W)
  elif scancode == uint32(Scancode.A): some(Key.A)
  elif scancode == uint32(Scancode.S): some(Key.S)
  elif scancode == uint32(Scancode.D): some(Key.D)
  elif scancode == uint32(Scancode.Q): some(Key.Q)
  elif scancode == uint32(Scancode.E): some(Key.E)
  elif scancode == uint32(Scancode.F): some(Key.F)
  elif scancode == uint32(Scancode.ShiftLeft) or scancode == uint32(Scancode.ShiftRight):
    # Either shift key, since reader holds whichever hand is free; see `Scancode`.
    some(Key.Shift)
  elif scancode == uint32(Scancode.Left): some(Key.Left)
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


func pointerButtonOf(button: uint8): Option[PointerButton] =
  ## Name SDL mouse button in shared vocabulary.
  ##   **Only numbering is this build's own**: SDL counts 1/2/3 left/middle/right, DOM
  ## 0/1/2. What button *means* is `interaction`'s.
  if button == uint8(MouseButton.Left): some(PointerButton.Left)
  elif button == uint8(MouseButton.Right): some(PointerButton.Right)
  elif button == uint8(MouseButton.Middle): some(PointerButton.Middle)
  else: none(PointerButton)


func armingFor(button: uint8): Option[MenuArming] =
  ## Say whether mouse button starts construction drag, and how it reaches its menu.
  let named = pointerButtonOf(button)
  if named.isNone: none(MenuArming) else: armingOf(named.get)


func revealsMenuFor(button: uint8): bool =
  ## Say whether click of this mouse button brings selection menu up with it.
  let named = pointerButtonOf(button)
  named.isSome and revealsMenuOn(named.get)


proc handleEvent(
  event: Event;
  camera: var Camera; panel: var Panel; scene: var Scene; interaction: var Interaction;
  is_dragging_orbit, is_dragging_pan, is_running: var bool; button_dragging: var Option[uint8];
  now: float; width_frame, height_frame: int;
) =
  ## Fold one SDL3 event into camera placement, drag state, panel state or run state.
  ##   Mouse is ignored while GUI wants it, so dragging widget never turns view.
  ##   Case runs on raw kind rather than `EventKind`: SDL3 sends kinds this binding never
  ## mirrored, and converting those to sparse enum is undefined.
  ##   `now` is forwarded to drag's derived item, so it animates in.
  case event.kind
  of uint32(EventKind.Quit):
    is_running = false
  of uint32(EventKind.KeyDown):
    # `wantsKeys`, not `wantsKeyboard`: with navigation enabled latter is true from first
    #   frame and would swallow every key view answers. See `gui_shim.cpp`.
    if gui.wantsKeys(): return
    # Control on every platform, and command as well, for macOS.
    let is_accelerator =
      (event.key.modifiers and (MODIFIER_CONTROL or MODIFIER_COMMAND)) != 0
    let is_shifted = (event.key.modifiers and MODIFIER_SHIFT) != 0
    if event.key.scancode == uint32(Scancode.Escape):
      # Cancels what is in progress rather than quitting: pressing twice to be sure would
      #   have thrown away unsaved scene. Quitting moved to ctrl+Q.
      if panel.is_help_open: panel.is_help_open = false
      elif interaction.is_dragging:
        interaction.cancelDrag()
        toChars("Cancelled.", panel.message)
      elif panel.session.isSome: panel.session = none(EditSession)
      elif panel.is_menu_selection_shown: panel.hideSelectionMenu()
      elif len(panel.selection) > 0: panel.selection.clear()
    elif is_accelerator and event.key.scancode == uint32(Scancode.S):
      # Ctrl+S rather than bare S: S slides view back, and movement key cannot also write
      #   PNG.
      panel.is_export_requested = true
    elif is_accelerator and event.key.scancode == uint32(Scancode.Q):
      is_running = false
    elif is_accelerator and event.key.scancode == uint32(Scancode.Z) and not is_shifted:
      panel.is_undo_requested = true
    elif is_accelerator and
        (event.key.scancode == uint32(Scancode.Y) or
         (event.key.scancode == uint32(Scancode.Z) and is_shifted)):
      panel.is_redo_requested = true
    elif not is_accelerator:
      # Keys 3D view answers, what makes canvas reachable without pointer. Chord that
      #   missed every branch above falls through rather than orbiting by accident.
      let key = keyFor(event.key.scancode)
      if key.isSome:
        # Key that moves view is *held*: `driveHeld` moves camera every frame until
        #   release. Key that acts does so once; auto-repeat is harmless, `holdKey` being
        #   idempotent.
        interaction.holdKey(key.get)
        let action = actionFor(key.get)
        if action.isSome:
          let index_selected = interaction.applyAction(camera, scene, action.get)
          if index_selected.isSome:
            # Shift adds rather than replaces, as shift-click does.
            if is_shifted: panel.selection.toggle(index_selected.get)
            else: panel.selection.selectOnly(index_selected.get)
            # Reached without pointer, so menu is only place keyboard gets at apply, edit,
            #   hide and delete.
            panel.showSelectionMenu()
          # Framing is standing offer's job (`framing.offerAim`); key only lets go of goal
          #   it holds. See `interaction.applyAction`.
          if action.get == KeyAction.FrameSelection: panel.tween_camera.release()
          else: panel.tween_camera.abandon()
        else:
          # Moving camera by key abandons tween carrying it somewhere.
          panel.tween_camera.abandon()
  of uint32(EventKind.KeyUp):
    let key = keyFor(event.key.scancode)
    if key.isSome: interaction.releaseKey(key.get)
  of uint32(EventKind.WindowFocusLost):
    # Releases for anything held go to whichever window took focus, so let go of
    #   everything rather than moving camera forever.
    interaction.releaseKeysAll()
  of uint32(EventKind.MouseButtonDown):
    if gui.wantsMouse(): return
    # Every press is noted before anything is decided: whether it was click is knowable
    #   only at release, and both branches can end in one.
    interaction.beginPress(now)
    # Press on pickable item starts operation drag; press on empty space falls back to
    #   camera control.
    let arming = armingFor(event.button.button)
    if arming.isSome and interaction.beginDrag(arming.get, now):
      button_dragging = some(event.button.button)
    elif event.button.button == uint8(MouseButton.Left):
      is_dragging_orbit = true
    elif event.button.button == uint8(MouseButton.Right):
      is_dragging_pan = true
  of uint32(EventKind.MouseButtonUp):
    let is_shifted = (sdl3.getModState() and MODIFIER_SHIFT) != 0
    if button_dragging == some(event.button.button):
      let outcome = interaction.endDrag(scene, now)
      if len(outcome.message) > 0: toChars(outcome.message, panel.message)
      if outcome.index_clicked.isSome:
        # Press that never became drag. **Button decides whether menu comes with it**;
        #   shift decides add or replace; independent. See `interaction.revealsMenuOn`.
        #   Unshifted, on selection standing with menu dismissed, click only brings menu
        #   back; see `revealsWithoutPicking`.
        if revealsMenuFor(event.button.button) and not is_shifted and
            revealsWithoutPicking(panel.selection.len > 0, panel.is_menu_selection_shown):
          panel.showSelectionMenu()
        else:
          if is_shifted: panel.selection.toggle(outcome.index_clicked.get)
          else: panel.selection.selectOnly(outcome.index_clicked.get)
          if revealsMenuFor(event.button.button): panel.showSelectionMenu()
          else: panel.hideSelectionMenu()
      elif outcome.index_created.isSome:
        panel.selection.selectOnly(outcome.index_created.get)
        panel.hideSelectionMenu()
        HISTORY.record(scene, camera)
      elif outcome.choice == some(DragChoice.More) and outcome.operands.isSome:
        # Way out of gesture's three operations into other twenty-four: both operands
        #   selected in drag order (m then n), picker opened where wheel was.
        panel.selection.selectOnly(outcome.operands.get.source)
        panel.selection.toggle(outcome.operands.get.destination)
        panel.openSelectionMenuPicker()
      button_dragging = none(uint8)
    elif pointerButtonOf(event.button.button).isSome and interaction.isClick(now):
      # Plain click that began no drag: landed on empty space, or on one thing that *is*
      #   empty space, plane at horizon, which `beginDrag` refuses so press could still
      #   become orbit. Clicking selects it, only way pointer can. **Both buttons**, on
      #   same rule as branch above.
      if interaction.is_hover_backdrop and interaction.index_hover.isSome:
        let slot = interaction.index_hover.get
        if revealsMenuFor(event.button.button) and not is_shifted and
            revealsWithoutPicking(panel.selection.len > 0, panel.is_menu_selection_shown):
          panel.showSelectionMenu()
        else:
          if is_shifted: panel.selection.toggle(slot)
          else: panel.selection.selectOnly(slot)
          if revealsMenuFor(event.button.button): panel.showSelectionMenu()
          else: panel.hideSelectionMenu()
      elif event.button.button == uint8(MouseButton.Left) and not is_shifted:
        # Clears, mirroring browser; shift means "keep what I have".
        panel.selection.clear()
        panel.hideSelectionMenu()
    if event.button.button == uint8(MouseButton.Left): is_dragging_orbit = false
    if event.button.button == uint8(MouseButton.Right): is_dragging_pan = false
  of uint32(EventKind.MouseWheel):
    if gui.wantsMouse(): return
    panel.tween_camera.abandon()
    # Toward whatever cursor is over; see `interaction.dollyAtCursor`. Frame's size is
    #   passed because sight ray needs it before frame reports it again.
    interaction.dollyAtCursor(
      camera, scene, pow(FACTOR_DOLLY, -float(event.wheel.y)),
      camera.drawExtentFor(height_frame),
      camera.initMatrixViewProjection(float(width_frame)/float(height_frame)),
      width_frame, height_frame,
    )
  of uint32(EventKind.MouseMotion):
    interaction.updateCursor(float(event.motion.x), float(event.motion.y))
    if is_dragging_orbit or is_dragging_pan:
      # Camera is moving *now*, which hover rule asks; see `updateHover`.
      interaction.is_dragging_camera = true
    if is_dragging_orbit:
      panel.tween_camera.abandon()
      camera.orbit(
        -SPEED_ORBIT*float(event.motion.xrel), SPEED_ORBIT*float(event.motion.yrel)
      )
    if is_dragging_pan:
      panel.tween_camera.abandon()
      # Where pointer was and is, rather than how far it moved: pan grabs level under it
      #   and needs both ends of step. See `interaction.panAcross`.
      camera.panAcross(
        ScreenPosition(
          x: float(event.motion.x - event.motion.xrel),
          y: float(event.motion.y - event.motion.yrel),
        ),
        ScreenPosition(x: float(event.motion.x), y: float(event.motion.y)),
        width_frame, height_frame,
      )
  else: discard



#[ Run Modes ]#

proc reportTimings(milliseconds: var openArray[float32]) =
  ## Print frame-time statistics over completed `--timings` run.
  ##   Mean and deviation hide stutter percentile catches: 99% of frames at 2 ms and 1% at
  ## 40 ms reports fine mean, so tail past p95 answers "does this stutter".
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
  scene: Scene; interaction: Interaction; camera: Camera;
  width, height, count_drawn: int; scale: DrawExtent
) =
  ## Script right-button construction drag from first scene item onto second and out onto
  ## `more…`, one step per frame, so headless run shows choice menu open and where its way
  ## out lands.
  ##   For `--drive-drag`. Every step is posted to SDL's queue rather than handed to
  ## `handleEvent`: point is exercising wiring between two, and one bug survived test
  ## calling handler straight.
  ##   Positions come from same `anchorFor`/`projectToScreen` pair overlay draws through,
  ## so cursor lands where item was drawn.
  ##   **Not reproducible frame for frame**: real loop on real clock, so every seed's birth
  ## animation stands wherever wall time put it. Look at capture; do not byte-compare.
  const
    (FRAME_REACH_SOURCE, FRAME_PRESS, FRAME_REACH_TARGET) = (2, 3, 4)
    (FRAME_REACH_MORE, FRAME_RELEASE) = (8, 9)
      ## Two frames past menu opening: reach `more…` wedge, then let go on it. Shorter runs
      ## still capture open menu.
  if count_drawn == FRAME_REACH_MORE or count_drawn == FRAME_RELEASE:
    # Wedge itself, from same `anchorOf` that drew it, never pixel guessed from compass.
    let at = anchorOf(interaction.menu.get(interaction.cursor), DragChoice.More)
    var reach = Event(kind: uint32(EventKind.MouseMotion))
    reach.motion.x = cfloat(at.x)
    reach.motion.y = cfloat(at.y)
    sdl3.pushEvent(addr reach)
    if count_drawn == FRAME_RELEASE:
      var release = Event(kind: uint32(EventKind.MouseButtonUp))
      release.button.button = uint8(MouseButton.Right)
      sdl3.pushEvent(addr release)
    return
  if count_drawn notin [FRAME_REACH_SOURCE, FRAME_PRESS, FRAME_REACH_TARGET]: return
  let slot = if count_drawn == FRAME_REACH_TARGET: 1 else: 0
  if not scene.isAlive(slot): return
  let anchor = anchorFor(scene[slot].geometry, scene[slot].anchorOverride, scale)
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


type KeyStep = object ## One frame of scripted keyboard run; see `lut_keys_driven`.
  ## Frame carrying no key is point of `Option`: held key moves camera on frames *between*
  ## press and release, and script sending event every frame could never leave it held.
  pressed: Option[tuple[scancode: Scancode; keycode: uint32]]
  is_down: bool ## Whether this step presses key or lets go of it.


func stepKey(scancode: Scancode; keycode: uint32; is_down = true): KeyStep =
  ## Name one scripted press or release.
  KeyStep(pressed: some((scancode: scancode, keycode: keycode)), is_down: is_down)


func stepHold(): KeyStep = KeyStep(pressed: none((Scancode, uint32)), is_down: false)
  ## Let frame pass with whatever is held still held, so hold covers real frames.


const
  KEYCODE_RIGHT = 1073741903'u32
  KEYCODE_UP = 1073741906'u32
  KEYCODE_SHIFT = 1073742049'u32
    ## SDL's keycodes for three non-ASCII keys script sends; see `driveKeys` on why
    ## synthesised event needs one.

const lut_keys_driven = [
  # Walk focus on twice and select what it lands on.
  stepKey(Scancode.BracketRight, uint32(ord(']'))),
  stepKey(Scancode.BracketRight, uint32(ord(']')), is_down = false),
  stepKey(Scancode.BracketRight, uint32(ord(']'))),
  stepKey(Scancode.BracketRight, uint32(ord(']')), is_down = false),
  stepKey(Scancode.Return, 13'u32), # Return is ASCII carriage return.
  stepKey(Scancode.Return, 13'u32, is_down = false),
  # Hold W four frames and let go: middle frames prove movement runs while key is down,
  #   release proves key-up wiring exists. Handler called directly would prove neither.
  stepKey(Scancode.W, uint32(ord('w'))),
  stepHold(), stepHold(), stepHold(),
  stepKey(Scancode.W, uint32(ord('w')), is_down = false),
  stepHold(), # Nothing held: target must stand still across this frame.
  # Shift and W together, which must cover `FACTOR_HASTE` times ground.
  stepKey(Scancode.ShiftLeft, KEYCODE_SHIFT),
  stepKey(Scancode.W, uint32(ord('w'))),
  stepHold(), stepHold(), stepHold(),
  stepKey(Scancode.W, uint32(ord('w')), is_down = false),
  stepKey(Scancode.ShiftLeft, KEYCODE_SHIFT, is_down = false),
  # Orbit and dolly, each held frame, so both reach camera too.
  stepKey(Scancode.Right, KEYCODE_RIGHT), stepHold(),
  stepKey(Scancode.Right, KEYCODE_RIGHT, is_down = false),
  stepKey(Scancode.Equals, uint32(ord('='))), stepHold(),
  stepKey(Scancode.Equals, uint32(ord('=')), is_down = false),
  stepKey(Scancode.Tab, 9'u32), # Tab is ASCII horizontal tab.
] ## Script one keyboard step per frame for `--drive-keys`: walk focus, select, hold
  ## movement key, hold it hastened, orbit and dolly. Touches every kind of binding, so
  ## one run says whether Dear ImGui's navigation has swallowed lot. Trailing Tab is
  ## opposite check: application binds it to nothing, so `gui.wantsKeys` turning true
  ## afterwards is nav having taken it, which makes panels reachable.


proc driveKeys(count_drawn: int) =
  ## Push one scripted keyboard step per frame onto SDL's queue, for `--drive-keys`.
  ##   Posted to queue rather than handed to `handleEvent`, for reason `driveDrag` gives.
  const FRAME_FIRST = 3 # Past startup, so first frame's layout has settled.
  let step = count_drawn - FRAME_FIRST
  if step notin 0 ..< len(lut_keys_driven): return
  let scripted = lut_keys_driven[step]
  if scripted.pressed.isNone: return
  var event = Event(
    kind: uint32(if scripted.is_down: EventKind.KeyDown else: EventKind.KeyUp)
  )
  event.key.scancode = uint32(scripted.pressed.get.scancode)
  # Dear ImGui's backend reads layout keycode rather than scancode, so event without one
  #   is invisible to it, and Tab above is aimed at exactly that.
  event.key.keycode = scripted.pressed.get.keycode
  event.key.is_down = scripted.is_down
  event.key.modifiers = 0
  sdl3.pushEvent(addr event)


proc driveSelect(
  scene: Scene; camera: Camera; width, height, count_drawn: int; scale: DrawExtent
) =
  ## Script click, then two shift-clicks, on first three scene items, and finally
  ## construction drag off object menu sits over, so headless run shows floating selection
  ## menu at each size and proves it does not swallow next drag.
  ##   **Clicks with button that reveals menu**, read from `revealsMenuOn`: menu moved to
  ## right button, and script clicking left would screenshot empty screen.
  ##   For `--drive-select`. Which state is captured is `--frames`' to choose: menu over
  ## one object by frame 5, two by 7, three by 9, drag resolved by 13. One frame later than
  ## each step, because Dear ImGui hides auto-sized window for frame it measures it in.
  ##   Split across two frames per gesture: hover is recomputed inside `renderFrame`, so
  ## press in same drain as its motion reads previous frame's pick.
  ##   Shift is set through `sdl3.setModState`: pushed event never reaches state
  ## `getModState` reads.
  ##   Shares `driveDrag`'s warning: look at capture; do not byte-compare.
  const
    FRAME_FIRST = 2 # Past startup, so first frame's layout has settled.
    STEPS_CLICK = 6 # Three clicks, each frame to reach and frame to press.
    lut_step_to_slot = [0, 0, 1, 1, 2, 2, 2, 2, 0, 0]
      ## Which item each step aims at: three clicks on 0, 1 and 2, then drag from 2 (one
      ## menu follows) onto 0.
  let step = count_drawn - FRAME_FIRST
  if step notin 0 ..< len(lut_step_to_slot): return
  let
    slot = lut_step_to_slot[step]
    is_acting = (step mod 2) == 1
  if not scene.isAlive(slot): return
  let anchor = anchorFor(scene[slot].geometry, scene[slot].anchorOverride, scale)
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
  # First click picks alone; two after it add, which is what shift means.
  sdl3.setModState(if slot == 0 and step == 1: 0'u16 else: MODIFIER_SHIFT)
  var event = Event(
    kind:
      if step < STEPS_CLICK or step == STEPS_CLICK + 1:
        uint32(EventKind.MouseButtonDown)
      else: uint32(EventKind.MouseButtonUp)
  )
  event.button.button =
    if revealsMenuOn(PointerButton.Right): uint8(MouseButton.Right)
    else: uint8(MouseButton.Left)
  sdl3.pushEvent(addr event)
  # Click is press and release in one drain; drag's two halves are frames apart, so cursor
  #   really travels between them.
  if step < STEPS_CLICK:
    var release = Event(kind: uint32(EventKind.MouseButtonUp))
    release.button.button = event.button.button # Button that pressed is one that lifts.
    sdl3.pushEvent(addr release)


const lut_keys_undo_driven = [
  (Scancode.Right, uint32(1073741903), 0'u16, true), # SDLK_RIGHT, no modifier: orbit.
  (Scancode.Right, uint32(1073741903), 0'u16, false),
  (Scancode.Up, uint32(1073741906), 0'u16, true), # SDLK_UP: rise.
  (Scancode.Up, uint32(1073741906), 0'u16, false),
  (Scancode.Z, uint32(ord('z')), MODIFIER_CONTROL, true), # Undo under test.
  (Scancode.Z, uint32(ord('z')), MODIFIER_CONTROL, false),
] ## Script keys `--drive-undo` sends after construction lands: orbit and rise, held frame
  ## each, far enough that view left there cannot be mistaken for one construction was
  ## made from, then undo. Scancode, keycode, modifiers, down or up.
  ##   **Every press is paired with release**: arrow left down orbits every frame, so undo
  ## restored view and still-held key took it away again. Verdict caught exactly that.

proc driveUndo(
  scene: Scene; camera: Camera; width, height, count_drawn: int; scale: DrawExtent
) =
  ## Script construction drag onto second scene item, orbit well away from where it was
  ## built, then undo of it, one step per frame.
  ##   For `--drive-undo`. Point is view: undo puts camera back where construction was
  ## made from, and only way to see that through key wiring, panel and tween is to look at
  ## frames. Frame 6 shows view built from, 10 how far orbit went, 12 or later where undo
  ## left it: 6 and 12 should match.
  ##   Posted to SDL's queue, split across frames, for reasons `driveDrag` and
  ## `driveSelect` give; same warning about byte-comparing.
  const
    FRAME_FIRST = 2 # Past startup, so first frame's layout has settled.
    STEPS_DRAG = 4 # Reach source, press, reach target, release.
    lut_step_to_slot = [0, 0, 1, 1]
  let step = count_drawn - FRAME_FIRST
  if step < 0: return

  if step < STEPS_DRAG:
    let slot = lut_step_to_slot[step]
    if not scene.isAlive(slot): return
    let anchor = anchorFor(scene[slot].geometry, scene[slot].anchorOverride, scale)
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
    # Left button, not right: right release commits wedge cursor stands in, and scripted
    #   cursor on its target stands in none. Left takes proposal.
    event.button.button = uint8(MouseButton.Left)
    sdl3.pushEvent(addr event)
    return

  # Frame of slack after release, so construction is committed and its camera aim armed
  #   before orbit that overrides it starts.
  let index = step - STEPS_DRAG - 1
  if index notin 0 ..< len(lut_keys_undo_driven): return
  let (scancode, keycode, modifiers, is_down) = lut_keys_undo_driven[index]
  var event = Event(
    kind: uint32(if is_down: EventKind.KeyDown else: EventKind.KeyUp)
  )
  event.key.scancode = uint32(scancode)
  event.key.keycode = keycode
  event.key.is_down = is_down
  event.key.modifiers = modifiers
  sdl3.pushEvent(addr event)


proc positionOverSky(
  scene: Scene; camera: Camera; view_projection: Matrix4; width, height: int
): Option[ScreenPosition] =
  ## Find point on screen where topmost thing under cursor is plane at horizon.
  ##   Scanned rather than hard-coded: which patch is bare sky depends on scene and camera,
  ## and fixed pixel would quietly start testing something else.
  const STEP_SCAN = 40
  let scale = camera.drawExtentFor(height)
  for y in countup(STEP_SCAN, height - STEP_SCAN, STEP_SCAN):
    for x in countup(STEP_SCAN, width - STEP_SCAN, STEP_SCAN):
      let at = ScreenPosition(x: float(x), y: float(y))
      let slot = pickNearest(scene, camera, scale, view_projection, width, height, at)
      if slot.isSome and scene.geometryOf(slot.get).isHorizonPlane: return some(at)


proc driveSky(
  scene: var Scene; camera: Camera; width, height, count_drawn: int; now: float
) =
  ## Script left drag across bare sky, then plain click on it, one step per frame.
  ##   For `--drive-sky`. Guards one regression pickable horizon plane could cause: drawn
  ## as dome over every direction, it is hovered wherever nothing else is, and press on it
  ## starting drag would stop press on empty space falling through to camera. Drag below
  ## must *turn view* and build nothing; click must select sky.
  ##   Posted to SDL's queue, for reason `driveDrag` gives.
  const
    FRAME_FIRST = 2
    STEPS_DRAG = 5 # Reach, press, three frames of travel; release follows.
  # **Own precondition, built here.** No sky in opening scene, so every scan found nothing
  #   and this drive silently did nothing for as long as it existed.
  if count_drawn == FRAME_FIRST - 1:
    var has_sky = false
    for slot in 0 ..< scene.bound:
      if scene.isAlive(slot) and scene.geometryOf(slot).isHorizonPlane: has_sky = true
    if not has_sky:
      discard scene.addItem(
        toMultivector(Direction(x: 1, y: 0, z: 0)) ∧
          toMultivector(Direction(x: 0, y: 1, z: 0)) ∧
          toMultivector(Direction(x: 0, y: 0, z: 1)),
        "sky", Ink.Cobalt, now,
      )
    return
  let step = count_drawn - FRAME_FIRST
  if step notin 0 .. STEPS_DRAG + 3: return
  let over_sky = positionOverSky(
    scene, camera, camera.initMatrixViewProjection(width/height), width, height
  )
  if over_sky.isNone: return

  var event: Event
  case step
  of 0, STEPS_DRAG + 1: # Reach sky, for drag and then again for click.
    event = Event(kind: uint32(EventKind.MouseMotion))
    event.motion.x = cfloat(over_sky.get.x)
    event.motion.y = cfloat(over_sky.get.y)
  of 1, STEPS_DRAG + 2:
    event = Event(kind: uint32(EventKind.MouseButtonDown))
    event.button.button = uint8(MouseButton.Left)
  of STEPS_DRAG, STEPS_DRAG + 3:
    event = Event(kind: uint32(EventKind.MouseButtonUp))
    event.button.button = uint8(MouseButton.Left)
  else: # Travel, which orbit reads as turning view.
    event = Event(kind: uint32(EventKind.MouseMotion))
    event.motion.x = cfloat(over_sky.get.x + float(40*step))
    event.motion.y = cfloat(over_sky.get.y)
    event.motion.xrel = cfloat(40)
  sdl3.pushEvent(addr event)


proc verdictDriven(
  options: Options; scene: Scene; camera, camera_opened, camera_before_slide: Camera;
  interaction: Interaction; panel: Panel; count_settled: int;
  was_dragging, was_menu_open: bool
): int =
  ## Judge what `--drive-*` run reached, and report every check pass or fail. Answers with
  ## number that failed, for caller to exit on.
  ##   Drives used to narrate and leave reading to human, so nothing guarded wiring
  ## between runs, and rule wired to wrong event is invisible to suite calling rule
  ## directly. `tools/drive_browser.mjs` is other half, reporting in same shape.
  ##   Each verdict belongs to one drive and is asked only where that drive ran. What is
  ## checked comes from each drive's doc comment.
  var count_failed = 0
  proc report(name: string; is_passing: bool; detail: string) =
    if not is_passing: inc count_failed
    echo (if is_passing: "  ok   " else: " FAIL  ") & name & " -- " & detail

  if options.is_key_driven:
    # Traversal, selection and every kind of camera motion, through queue and past Dear
    #   ImGui's navigation.
    report(
      "the scripted keys reached the view", interaction.index_focus.isSome and
        len(panel.selection) >= 1 and
        abs(camera.azimuth - camera_opened.azimuth) > 1.0e-6 and
        abs(camera.distance - camera_opened.distance) > 1.0e-6,
      &"focus {interaction.index_focus}, selected {len(panel.selection)}, " &
        &"azimuth {camera.azimuth:.4f}, distance {camera.distance:.4f}",
    )
    report(
      "a held key slid the view, and kept its height",
      # Height against where slide started rather than where run opened: pick before it
      #   turns orbit about what was picked, moving target in every axis. Slide must not
      #   change height it slides at.
      norm(camera.target - camera_opened.target) > 0.5 and
        abs(camera.target.z - camera_before_slide.target.z) < 1.0e-3,
      &"target ({camera.target.x:.3f}, {camera.target.y:.3f}, {camera.target.z:.3f}), " &
      &"from height {camera_before_slide.target.z:.3f}",
    )
    report(
      "every scripted key was let go of again", interaction.keys_held.len == 0,
      &"{interaction.keys_held.len} still held",
    )
  if options.is_sky_driven:
    # Regression pickable horizon plane could cause; see `driveSky`.
    report(
      "a drag across bare sky still turns the view",
      abs(camera.azimuth - camera_opened.azimuth) > 1.0e-6,
      &"azimuth {camera_opened.azimuth:.4f} -> {camera.azimuth:.4f}",
    )
    report(
      "a drag across bare sky builds nothing", len(scene) == count_settled,
      &"{len(scene)} items, settled at {count_settled}",
    )
    report(
      "a click on bare sky selects it", len(panel.selection) == 1,
      &"{len(panel.selection)} selected",
    )
  if options.is_undo_driven:
    # Undo's point is view: camera back where construction was made from, through key
    #   wiring, panel and tween it has to survive.
    report(
      "undo took the construction back", len(scene) == count_settled,
      &"{len(scene)} items, settled at {count_settled}",
    )
    report(
      "undo brought the view back to where it built from",
      abs(camera.azimuth - camera_opened.azimuth) < 0.2,
      &"azimuth {camera_opened.azimuth:.4f} -> {camera.azimuth:.4f}",
    )
  if options.is_select_driven:
    # Menu at one, two and three objects, then drag off object it sits over, which menu
    #   swallowing its next press would break.
    report(
      "clicking objects selects them", len(panel.selection) >= 1,
      &"{len(panel.selection)} selected",
    )
    report(
      "the menu did not swallow the drag after it", was_dragging,
      &"a drag began after the clicks: {was_dragging}",
    )
  if options.is_drag_driven:
    # Caught mid-gesture by design: menu is open, or it has already committed.
    report(
      "a drag from one object onto another opens its choice menu",
      was_dragging and was_menu_open,
      &"dragged {was_dragging}, menu opened {was_menu_open}",
    )
  if options.path_help_driven.isSome:
    report(
      "the help tab asked for opened, with rows in it",
      panel.is_help_open and countOf(options.path_help_driven.get) > 0,
      &"open {panel.is_help_open}, " &
        &"{countOf(options.path_help_driven.get)} rows in " &
        &"`{titleOf(options.path_help_driven.get)}`",
    )
  count_failed


proc runInteractive(
  window: Window; renderer: Renderer; options: Options;
  panel: var Panel; scene: var Scene; camera: var Camera;
) =
  ## Draw frames, folding input in, until user or command line asks to stop.
  ##   Exceeds sixty-line default: sequential per-frame state machine threading dozen
  ## mutable locals through one loop body. Splitting would pass most by `var` across new
  ## boundary, trading readable loop for indirection.
  var
    interaction = Interaction(is_enabled: true)
    button_dragging = none(uint8)
    is_running = true
    is_dragging_orbit = false
    is_dragging_pan = false
    is_vsync_active = panel.is_vsync_enabled # Matches swap interval already set.
    count_drawn = 0
    ticks_previous_frame = getMonoTime().ticks
    total_tessellate_microseconds = 0.0
    total_vertices = 0

  # Drawable's size as last frame reported it; window's configured size until one has
  #   been drawn. Events read it, so it cannot wait for frame.
  var (width_frame, height_frame) = (PIXELS_WIDTH, PIXELS_HEIGHT)

  # What scene and camera were before any event, which `--drive-assert`'s verdicts read
  #   against: every one is statement about what scripted gesture *changed*.
  let
    count_opened = len(scene)
    camera_opened = camera
  # Two gestures prove themselves by having happened rather than by what they left: drag
  #   is released before run ends, and right release at menu's centre commits nothing.
  var
    was_dragging = false
    was_menu_open = false
    # Camera as first held motion key found it. **Picking turns orbit about what was
    #   picked**, and script selects before it slides, so opening placement is not what
    #   slide starts from; ease is abandoned by first held frame, so from there height is
    #   slide's own doing.
    camera_before_slide = camera_opened
    is_slide_started = false
    # Scene as gestures found it, after drives' setup frame: `--drive-sky` builds horizon
    #   plane it needs, and counting before that made precondition look like something
    #   drag built. No gesture commits this early.
    count_settled = count_opened

  while is_running:
    # Export arena starts every frame empty. Draw loop's scratch is swap pair below;
    #   `exportFrame` may use this and leaves it reset.
    ARENA_FRAME.reset()
    # Frame pair turns over: this frame carves into block reclaimed here, while *previous*
    #   frame's block stays readable until next swap.
    ARENA_SWAP.swap()
    # Frame's measurements turn over with it, on same two-frame lifetime. See `timings`.
    openFrameTimings()

    # One reading per frame, shared by every drag completing this frame and by render, so
    #   both agree on "now".
    let now = secondsNow()

    # Measured against previous iteration's start, so this covers everything real frame
    #   pays for: events, tessellation, render, swap that blocked on vsync. Always taken,
    #   since panel's live graph needs it.
    let ticks_frame_start = getMonoTime().ticks
    var seconds_frame = 0.0
    if count_drawn > 0:
      let delta_milliseconds = float32(ticks_frame_start - ticks_previous_frame) / 1_000_000.0
      # Same measurement, in units held key's rates are stated in. Zero on first frame.
      seconds_frame = float(delta_milliseconds)/1000.0
      panel.milliseconds_history[panel.index_history] = cfloat(delta_milliseconds)
      panel.index_history = (panel.index_history + 1) mod FRAMES_HISTORY
      if options.is_timed:
        doAssert count_drawn - 1 < FRAMES_TIMING_MAX,
          &"Timing run passed its own {FRAMES_TIMING_MAX}-frame bound; raise " &
          "`--define:visualiser.frames_timing_max` or shorten `--frames`."
        TIMINGS_FRAME_MILLISECONDS[count_drawn - 1] = delta_milliseconds
    ticks_previous_frame = ticks_frame_start

    if options.is_key_driven: driveKeys(count_drawn)
    if options.is_sky_driven:
      driveSky(scene, camera, PIXELS_WIDTH, PIXELS_HEIGHT, count_drawn, now)
    if options.is_drag_driven or options.is_select_driven or options.is_undo_driven:
      let scale_driven = camera.drawExtentFor(PIXELS_HEIGHT)
      if options.is_drag_driven:
        driveDrag(
          scene, interaction, camera, PIXELS_WIDTH, PIXELS_HEIGHT, count_drawn,
          scale_driven,
        )
      elif options.is_select_driven:
        driveSelect(scene, camera, PIXELS_WIDTH, PIXELS_HEIGHT, count_drawn, scale_driven)
      else:
        driveUndo(scene, camera, PIXELS_WIDTH, PIXELS_HEIGHT, count_drawn, scale_driven)

    var event: Event
    while sdl3.pollEvent(addr event):
      gui.processEvent(addr event)
      handleEvent(
        event, camera, panel, scene, interaction,
        is_dragging_orbit, is_dragging_pan, is_running, button_dragging, now,
        width_frame, height_frame,
      )

    # Cleared here only, so release taking early return cannot leave it set. *Raised* by
    #   motion that turns or slides camera, never by press: press that never moves is
    #   click, and click has to know what it came down on.
    if not (is_dragging_orbit or is_dragging_pan): interaction.is_dragging_camera = false

    # Whatever is held moves camera by one frame's worth, after events and before anything
    #   is drawn. Elapsed time is frame time measured above, so hold travels same distance
    #   however fast machine draws. Panel widget with keyboard takes it back: Dear ImGui
    #   swallows releases, so anything held has to be let go of here.
    if gui.wantsKeys(): interaction.releaseKeysAll()
    elif interaction.keys_held.len > 0:
      interaction.driveHeld(camera, seconds_frame)
      panel.tween_camera.abandon()

    let (width, height) =
      renderFrame(
        window, renderer, panel, scene, camera, interaction, now,
        path_help = options.path_help_driven,
      )
    if options.is_asserted:
      if not is_slide_started and interaction.isMovingCamera:
        # First frame key that *moves* camera is held, not merely any bound key. Taken
        #   after this frame's motion and `abandon`, so ease cannot still be writing.
        is_slide_started = true
        camera_before_slide = camera
      was_dragging = was_dragging or interaction.is_dragging
      was_menu_open = was_menu_open or interaction.menu.isSome
      if count_drawn == 2: count_settled = len(scene)
    # Carried into next iteration's events, which need frame's size to cast sight ray.
    (width_frame, height_frame) = (int(width), int(height))
    if options.is_timed:
      total_tessellate_microseconds += panel.microseconds_tessellate
      total_vertices += panel.count_vertices

    # Change swap interval only when checkbox flips, not every frame.
    if panel.is_vsync_enabled != is_vsync_active:
      is_vsync_active = panel.is_vsync_enabled
      sdl3.glSetSwapInterval(if is_vsync_active: 1 else: 0)

    # Export on final frame of bounded run, so build can be checked without screen.
    inc count_drawn
    let is_final = options.count_frames > 0 and count_drawn >= options.count_frames
    if is_final and len(options.path_screenshot) > 0: panel.is_export_requested = true

    if panel.is_export_requested:
      panel.is_export_requested = false
      let report = exportFrame(toText(panel.path_export), width, height)
      toChars(report, panel.message)
      echo report

    sdl3.glSwapWindow(window)
    if is_final: is_running = false

  echo &"Drew {count_drawn} frames."
  if options.is_key_driven:
    # What scripted keys reached, so "Dear ImGui swallowed them" is reading rather than
    #   suspicion.
    echo &"Keys: focus {interaction.index_focus}, selected {len(panel.selection)}, " &
      &"azimuth {camera.azimuth:.4f}, elevation {camera.elevation:.4f}, " &
      &"distance {camera.distance:.4f}, " &
      &"target ({camera.target.x:.3f}, {camera.target.y:.3f}, {camera.target.z:.3f}), " &
      &"held {len(interaction.keys_held)}; " &
      &"gui.wantsKeys {gui.wantsKeys()}, nav enabled {gui.isNavEnabled()}."
  if options.is_asserted:
    let count_failed = verdictDriven(
      options, scene, camera, camera_opened, camera_before_slide, interaction, panel,
      count_settled, was_dragging, was_menu_open,
    )
    if count_failed > 0:
      echo &"\n{count_failed} driven check(s) failed."
      quit(1)
    echo "\nEvery driven check passed."
  if options.is_timed and count_drawn > 1:
    reportTimings(TIMINGS_FRAME_MILLISECONDS.toOpenArray(0, count_drawn - 2))
    echo &"  tessellate mean {total_tessellate_microseconds/float(count_drawn):.1f}us, " &
      &"{total_vertices div count_drawn} vertices/frame " &
      &"(both this run's own CPU-side cost, not the rasterizer's)."


proc runStoryboard(
  window: Window; renderer: Renderer; directory: string;
  panel: var Panel; scene: var Scene; camera: var Camera;
) =
  ## Apply each scripted step in turn, writing one settled frame after each, plus one
  ## short animated GIF sweeping through every step's appear-in animation.
  ##   Every step runs through same catalogue GUI's apply button does. `clock` is
  ## synthetic, so animation sweeps at exact, reproducible pace.
  ##   Exceeds sixty-line default for same reason `runInteractive` does.
  createDir(directory)
  var
    interaction_disabled = Interaction() # is_enabled defaults false; no picking, no overlay.
    dims_gif = (0, 0)
    count_frames_gif = 0
    clock = 0.0
    are_dimmed: array[ITEMS_MAX, bool] ## Every slot starts un-dimmed, right for seeds-only
      ## frame captured below.

  template renderAt(now: float): (int, int) =
    # Frame pair turns over here as interactive loop turns it: each render carves its own
    #   `DrawScratch`, and capture run that never swapped overflowed arena by fifth
    #   sub-frame.
    ARENA_SWAP.swap()
    renderFrame(window, renderer, panel, scene, camera, interaction_disabled, now, are_dimmed)

  template captureGif(now: float) =
    ## Render one frame at `now`, downsample it, and append it to GIF's frames.
    ##   Frames collect in permanent arena, since all must survive to single `writeGif`;
    ## only throwaway readback comes from frame arena.
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
    ## Sweep this step's items from freshly born to settled into GIF, hold on settled
    ## result, then settle widget layout and write numbered PNG; stills never show
    ## mid-animation.
    ##   Template rather than nested proc: scene and panel arrive by `var`, which closure
    ## may not capture.
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

  scene.restoreFrom(initScene())
  constructSeeds(scene, clock)
  let count_seeds = scene.len
  toChars("Seeds placed.", panel.message)
  captureStep("00_seeds")

  # Every object stays visible once added. Seeds are pinned at full colour throughout;
  #   derived object reads at full colour for step creating it and one after, and grays
  #   out once two steps have passed. Only step's real operands count: unary operation's
  #   second index is placeholder (see `Step.index_second`).
  let
    azimuth_default = camera.azimuth
    elevation_default = camera.elevation
  # Which slots this step and one before read or wrote, as flags per slot, same
  #   fixed-capacity shape `are_dimmed` has, so loop allocates nothing.
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

    # Finite object is anchored where fixed demo angle frames it; horizon object stands
    #   wherever construction landed it. Aim this capture at it (representative point for
    #   line's great circle, since aiming along normal puts ring at frame's edge), then
    #   restore default after; plane at horizon needs no aiming. Lens stays default.
    camera.azimuth = azimuth_default
    camera.elevation = elevation_default
    # Instant, not eased: captured frame must never show half-finished pan. Same `framing`
    #   rule interactive path uses.
    if isHorizon(derived):
      panel.tween_camera.offerAimAt(
        camera, derived, PIXELS_WIDTH, PIXELS_HEIGHT, 0.0, 0.0
      )
      panel.tween_camera.settle(camera)

    toChars(&"{step.label} gave {shapeText(derived)}.", panel.message)
    panel.selection.selectOnly(count_seeds + index)
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
  ## measures heaviest load this scene reaches.
  ##   Positions walk helix, so no two are collinear and every join is well formed. Own
  ## point buffer backs each join: earlier slots may hold demo's seeds.
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
  ## Open window, run mode command line asked for, then tear down in order.
  let options = parseOptions()
  doAssert sdl3.init(INIT_VIDEO), &"SDL3 failed to start: {sdl3.getError()}"
  defer: sdl3.quit()

  # Ask for core profile renderer's shaders are written against.
  sdl3.glSetAttribute(GL_CONTEXT_MAJOR_VERSION, 3)
  sdl3.glSetAttribute(GL_CONTEXT_MINOR_VERSION, 3)
  sdl3.glSetAttribute(GL_CONTEXT_PROFILE_MASK, GL_CONTEXT_PROFILE_CORE)
  sdl3.glSetAttribute(GL_DOUBLEBUFFER, 1)
  sdl3.glSetAttribute(GL_DEPTH_SIZE, 24)
  var flags = WINDOW_OPENGL or WINDOW_RESIZABLE
  if options.is_hidden: flags = flags or WINDOW_HIDDEN

  # Ask for multisampled framebuffer, and open without one where no visual offers it.
  #   Every line is thin quad; at four samples 1.5-pixel grid ribbon reads as line, with
  #   none as dotted. Asked for rather than required: `llvmpipe` under `xvfb`, which every
  #   headless capture runs on, refuses window outright rather than downgrading.
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
    panel = initPanel(
      if len(options.path_screenshot) > 0: options.path_screenshot
      else: PATH_EXPORT_DEFAULT
    )
  panel.is_vsync_enabled = not options.is_novsync
  # Help tab asked for on command line is help panel asked for.
  panel.is_help_open = options.path_help_driven.isSome

  # Open on storyboard's seeds alone, so window and script agree on where construction
  #   starts, unless saved scene or demo was asked for instead.
  let now_startup = secondsNow()
  doAssert not (options.scale_demo.isSome and len(options.path_load_scene) > 0),
    "`--demo` and `--load-scene` each replace the opening scene; ask for one of them."
  if options.scale_demo.isSome:
    # Framed for window this run opens at; reader who resizes reframes by looking.
    showOrrery(scene, camera, PIXELS_WIDTH, PIXELS_HEIGHT, options.scale_demo.get, now_startup)
  elif len(options.path_load_scene) > 0:
    echo loadScene(scene, options.path_load_scene, now_startup)
  else:
    # Replayed rather than placed whole, as loaded scene and browser's opening are. Not
    #   inside `constructSeeds`, because `runStoryboard` sweeps each step's animation on
    #   clock of its own.
    constructSeeds(scene, now_startup)
    scene.replayFrom(now_startup)
  if options.is_filled: fillSceneForBenchmark(scene, now_startup)
  HISTORY.initHistory(scene, camera)

  if len(options.path_storyboard) > 0:
    runStoryboard(window, renderer, options.path_storyboard, panel, scene, camera)
  else:
    runInteractive(window, renderer, options, panel, scene, camera)

main()
