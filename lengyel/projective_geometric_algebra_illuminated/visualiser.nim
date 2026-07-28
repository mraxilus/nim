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
##   interaction tracks a mouse drag from one item to another, and applies what it names.
##   panel lays out the widgets user edits scene through.
##   storyboard scripts a construction, one operation per exported frame.
##   image encodes a frame readback as PNG.
##
## Controls:
##   Drag from one object to another to derive a third: left joins, right meets, middle
##   projects the object dragged from onto the object dragged to.
##   Drag from empty space instead to move the camera: left orbits, right pans, wheel dollies.
##   `S` writes current frame to the export path; `Escape` quits.
##
## Command line, for validating a build without sitting in front of it:
##   `--screenshot:PATH` writes one PNG, `--frames:N` exits after N frames,
##   `--hidden` never maps the window, and `--storyboard:DIR` writes one frame per
##   scripted construction step and quits.

{.experimental: "strictFuncs".}

when compileOption("profiler"):
  import std/nimprof

import std/[math, monotimes, options, os, parseopt, strformat, strutils]

import ./pga
import ./visualiser/[
  camera, gif, gui, image, interaction, mesh, objects, panel, picking, renderer, scene, storyboard
]
import ./visualiser/opengl as gl
import ./visualiser/sdl3



#[ Application Configuration ]#

const
  TITLE* = "Projective Geometric Algebra Illuminated — RGA workbench"
  PIXELS_WIDTH* {.define: "visualiser.pixels_width".} = 1440
  PIXELS_HEIGHT* {.define: "visualiser.pixels_height".} = 900
  PATH_FONT* {.define: "visualiser.path_font".} =
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
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
  STRIDE_GIF = 4
    ## Keep every this-many-th pixel in both directions, so the storyboard's GIF stays
    ## a short preview rather than a full-resolution capture nobody asked for.

static:
  doAssert PIXELS_WIDTH >= 640 and PIXELS_HEIGHT >= 480,
    &"Window must be at least 640x480; got `{PIXELS_WIDTH}x{PIXELS_HEIGHT}`."

# Hold vertex storage at module scope, as it is far too large to sit on a stack frame.
var MESHES: MeshSet



#[ Command Line ]#

type Options = object ## Hold what command line asked of this run.
  path_screenshot: string ## Where one-shot export is written; empty for none.
  path_storyboard: string ## Directory scripted construction is written to; empty for none.
  count_frames: int ## Frames to draw before quitting; 0 to run until closed.
  is_hidden: bool ## Whether window is left unmapped.


proc parseOptions(): Options =
  ## Read command line into options, rejecting anything unrecognised.
  for kind, key, value in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "screenshot": result.path_screenshot = value
      of "storyboard": result.path_storyboard = value
      of "frames": result.count_frames = parseInt(value)
      of "hidden": result.is_hidden = true
      else:
        doAssert false,
          &"Unknown option `--{key}`; expected screenshot, storyboard, frames or hidden."
    of cmdArgument:
      doAssert false, &"Unexpected argument `{key}`; every input is a named option."
    of cmdEnd: discard



#[ Frame Assembly ]#

proc secondsNow(): float =
  ## Read monotonic clock as seconds, for animating how recently an item was added.
  ##   Nanosecond ticks, not seconds since any fixed epoch, but only ever differenced
  ##   against another reading from the same process, so that never matters.
  float(getMonoTime().ticks) / 1_000_000_000.0


proc assembleMeshes(workbench: var Workbench; scene: Scene; now: float) =
  ## Refill vertex storage from scene as it stands this frame, recording what it cost.
  let ticks_start = getMonoTime().ticks
  MESHES.clearMeshes
  if workbench.is_grid_shown: MESHES.addGrid
  if workbench.is_axes_shown: MESHES.addAxes
  for item in scene:
    if not item.is_visible: continue
    let progress = animationProgress(now, item.born)
    discard MESHES.addObject(item.geometry, item.ink.colour, progress)

  workbench.microseconds_tessellate = float(getMonoTime().ticks - ticks_start) / 1000.0
  workbench.count_vertices = 0
  for primitive in Primitive:
    workbench.count_vertices += MESHES[primitive].count_vertices


proc drawInteractionOverlay(
  interaction: Interaction; scene: Scene; view_projection: Matrix4; width, height: int
) =
  ## Draw drag's rubber-band and hover's ring directly onto the foreground layer.
  ##   Off entirely during storyboard capture, where interaction is never enabled.
  if not interaction.is_enabled: return

  if interaction.index_hover.isSome:
    let anchor = anchorFor(scene[interaction.index_hover.get].geometry)
    if anchor.isSome:
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if screen.isInFront:
        gui.overlayCircle(
          cfloat(screen.x), cfloat(screen.y), RADIUS_OVERLAY_HOVER,
          1.0, 1.0, 1.0, 0.8, WIDTH_OVERLAY_LINE,
        )

  if interaction.operation.isSome:
    let anchor = anchorFor(scene[interaction.index_source].geometry)
    if anchor.isSome:
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if screen.isInFront:
        gui.overlayLine(
          cfloat(screen.x), cfloat(screen.y),
          cfloat(interaction.cursor.x), cfloat(interaction.cursor.y),
          1.0, 1.0, 1.0, 0.65, WIDTH_OVERLAY_LINE,
        )


proc renderFrame(
  window: Window; renderer: Renderer;
  workbench: var Workbench; scene: var Scene; camera: var Camera; interaction: var Interaction;
  now: float;
): (int, int) =
  ## Lay panels out, draw scene and interaction overlay, and report framebuffer size.
  ##   Panels run first, so an edit made this frame reaches meshes assembled below it.
  ##   Hover is recomputed here too, from this same frame's transform, so a drag started
  ##   next frame reads a pick that matches what was just drawn.
  ##   `now` is this frame's own clock reading; caller decides what clock that is, so a
  ##   real one drives interactive animation and a scripted one drives storyboard capture.
  var (width, height) = (cint(PIXELS_WIDTH), cint(PIXELS_HEIGHT))
  sdl3.getWindowSizeInPixels(window, addr width, addr height)

  gui.frameBegin()
  layoutWorkbench(workbench, scene, camera, now)

  assembleMeshes(workbench, scene, now)
  clearFrame(int(width), int(height))
  let view_projection = camera.initMatrixViewProjection(width / height)
  renderer.drawMeshes(MESHES, view_projection)

  interaction.updateHover(scene, camera, view_projection, int(width), int(height))
  drawInteractionOverlay(interaction, scene, view_projection, int(width), int(height))

  gui.frameEnd()
  (int(width), int(height))


proc exportFrame(path: string; width, height: int; pixels: var seq[uint8]): string =
  ## Read framebuffer back and write it out as PNG, reporting what happened.
  ##   Must run before buffers are swapped, as back buffer is what was just drawn into.
  if len(path) == 0: return "Export path is empty; nothing written."
  capturePixels(width, height, pixels)
  writePng(path, width, height, pixels)
  &"Wrote {width}x{height} frame to `{path}`."


proc downsample(pixels: openArray[uint8]; width, height, stride: int): seq[uint8] =
  ## Keep every `stride`-th pixel in both directions, so a GIF frame stays small without
  ## a box filter costing time nobody asked to spend on a diagnostic capture.
  let
    width_small = width div stride
    height_small = height div stride
  result = newSeq[uint8](width_small*height_small*3)
  for row in 0 ..< height_small:
    for column in 0 ..< width_small:
      let
        source = (row*stride*width + column*stride)*3
        destination = (row*width_small + column)*3
      result[destination] = pixels[source]
      result[destination + 1] = pixels[source + 1]
      result[destination + 2] = pixels[source + 2]



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
      let message = interaction.endDrag(scene, now)
      if len(message) > 0: toChars(message, workbench.message)
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

proc runInteractive(
  window: Window; renderer: Renderer; options: Options;
  workbench: var Workbench; scene: var Scene; camera: var Camera;
) =
  ## Draw frames, folding input in, until user or command line asks to stop.
  var
    interaction = Interaction(is_enabled: true)
    button_dragging = none(uint8)
    pixels = newSeq[uint8](0)
    is_running = true
    is_dragging_orbit = false
    is_dragging_pan = false
    is_vsync_active = true # Matches `sdl3.glSetSwapInterval(1)` already set before this loop.
    count_drawn = 0

  while is_running:
    # One reading per frame, shared by every drag that completes this frame and by the
    #   frame's own render, so a completed drag and what gets drawn agree on "now".
    let now = secondsNow()

    var event: Event
    while sdl3.pollEvent(addr event):
      gui.processEvent(addr event)
      handleEvent(
        event, camera, workbench, scene, interaction,
        is_dragging_orbit, is_dragging_pan, is_running, button_dragging, now,
      )

    let (width, height) =
      renderFrame(window, renderer, workbench, scene, camera, interaction, now)

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
      let report = exportFrame($toCstring(workbench.path_export), width, height, pixels)
      toChars(report, workbench.message)
      echo report

    sdl3.glSwapWindow(window)
    if is_final: is_running = false

  echo &"Drew {count_drawn} frames."


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
  createDir(directory)
  var
    interaction_disabled = Interaction() # is_enabled defaults false; no picking, no overlay.
    pixels = newSeq[uint8](0)
    frames_gif: seq[seq[uint8]]
    dims_gif = (0, 0)
    clock = 0.0

  template renderAt(now: float): (int, int) =
    renderFrame(window, renderer, workbench, scene, camera, interaction_disabled, now)

  template captureGif(now: float) =
    ## Render one frame at `now`, downsample it, and append it to the GIF's own frames.
    block:
      let (width, height) = renderAt(now)
      dims_gif = (width div STRIDE_GIF, height div STRIDE_GIF)
      capturePixels(width, height, pixels)
      frames_gif.add(downsample(pixels, width, height, STRIDE_GIF))

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
      echo exportFrame(directory / (stem & ".png"), width, height, pixels)
      sdl3.glSwapWindow(window)

  scene = initScene()
  constructSeeds(scene, clock)
  toChars("Seeds placed.", workbench.message)
  captureStep("00_seeds")

  for step in STEPS:
    clock += 1.0
    let derived = applyStep(scene, step, clock)
    toChars(&"{step.label} gave {describeShape(derived)}.", workbench.message)
    captureStep(step.stem)

  let path_gif = directory / "storyboard.gif"
  writeGif(path_gif, dims_gif[0], dims_gif[1], frames_gif, CENTISECONDS_GIF_DELAY)
  echo &"Wrote {len(frames_gif)} frames to `{path_gif}`."
  echo &"Wrote {len(STEPS) + 1} frames to `{directory}`."



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
  sdl3.glSetSwapInterval(1)
  echo &"OpenGL: {gl.getString(gl.VERSION)}"

  doAssert gui.init(window, context, PATH_FONT, SIZE_FONT), "Dear ImGui failed to start."
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

  # Open on storyboard's own seeds and first steps, so window and script agree on scene.
  let now_startup = secondsNow()
  constructSeeds(scene, now_startup)
  for step in STEPS[0 .. 3]:
    applyStep(scene, step, now_startup)

  if len(options.path_storyboard) > 0:
    runStoryboard(window, renderer, options.path_storyboard, workbench, scene, camera)
  else:
    runInteractive(window, renderer, options, workbench, scene, camera)

main()
