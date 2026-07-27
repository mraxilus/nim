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
  camera, gui, image, interaction, mesh, objects, panel, picking, renderer, scene, storyboard
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

proc assembleMeshes(workbench: var Workbench; scene: Scene) =
  ## Refill vertex storage from scene as it stands this frame, recording what it cost.
  let ticks_start = getMonoTime().ticks
  MESHES.clearMeshes
  if workbench.is_grid_shown: MESHES.addGrid
  if workbench.is_axes_shown: MESHES.addAxes
  for item in scene:
    if not item.is_visible: continue
    discard MESHES.addObject(item.geometry, item.ink.colour)

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
): (int, int) =
  ## Lay panels out, draw scene and interaction overlay, and report framebuffer size.
  ##   Panels run first, so an edit made this frame reaches meshes assembled below it.
  ##   Hover is recomputed here too, from this same frame's transform, so a drag started
  ##   next frame reads a pick that matches what was just drawn.
  var (width, height) = (cint(PIXELS_WIDTH), cint(PIXELS_HEIGHT))
  sdl3.getWindowSizeInPixels(window, addr width, addr height)

  gui.frameBegin()
  layoutWorkbench(workbench, scene, camera)

  assembleMeshes(workbench, scene)
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
) =
  ## Fold one SDL3 event into camera placement, drag state, workbench state or run state.
  ##   Mouse is ignored while GUI wants it, so dragging a widget never turns the view or
  ##   starts an operation drag.
  ##   Case runs on raw kind rather than on `EventKind`, since SDL3 sends kinds this
  ##   binding never mirrored and converting those to a sparse enum is undefined.
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
      let message = interaction.endDrag(scene)
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
    var event: Event
    while sdl3.pollEvent(addr event):
      gui.processEvent(addr event)
      handleEvent(
        event, camera, workbench, scene, interaction,
        is_dragging_orbit, is_dragging_pan, is_running, button_dragging,
      )

    let (width, height) = renderFrame(window, renderer, workbench, scene, camera, interaction)

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
  ## Apply each scripted step in turn, writing one frame after each.
  ##   Every step runs through the same catalogue the GUI's apply button does, so frames
  ##   show what clicking would have produced.
  createDir(directory)
  var
    interaction_disabled = Interaction() # is_enabled defaults false; no picking, no overlay.
    pixels = newSeq[uint8](0)

  template capture(stem: string) =
    ## Settle widget layout, then write one numbered frame.
    ##   Template rather than nested procedure, as scene and workbench arrive by `var`
    ##   and a closure may not capture those.
    block:
      var (width, height) = (0, 0)
      for _ in 1 .. FRAMES_SETTLE:
        (width, height) =
          renderFrame(window, renderer, workbench, scene, camera, interaction_disabled)
      echo exportFrame(directory / (stem & ".png"), width, height, pixels)
      sdl3.glSwapWindow(window)

  scene = Scene()
  constructSeeds(scene)
  toChars("Seeds placed.", workbench.message)
  capture("00_seeds")

  for step in STEPS:
    applyStep(scene, step)
    toChars(
      &"{step.label} gave {describeShape(scene[scene.len - 1].geometry)}.",
      workbench.message,
    )
    capture(step.stem)

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
    scene = Scene()
    camera = initCamera(
      target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05, elevation = 0.42
    )
    workbench = initWorkbench(
      if len(options.path_screenshot) > 0: options.path_screenshot
      else: PATH_EXPORT_DEFAULT
    )

  # Open on storyboard's own seeds and first steps, so window and script agree on scene.
  constructSeeds(scene)
  for step in STEPS[0 .. 3]:
    applyStep(scene, step)

  if len(options.path_storyboard) > 0:
    runStoryboard(window, renderer, options.path_storyboard, workbench, scene, camera)
  else:
    runInteractive(window, renderer, options, workbench, scene, camera)

main()
