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
##   | ⊖m                | att(m)   | Direction of object, standing at horizon.       |
##   | e ∧ t             | join     | Camera's own sight axis, and frame from it.    |
##   |-------------------|----------|------------------------------------------------|
##
## Bootstrap order, left to right:
##
##   pga -> objects -> mesh -> scene -> panel -> visualiser
##   sdl3 -> gui --------------^ ^-------^
##   opengl -> renderer -----------------^
##   camera and image stand beside renderer, depending only on objects.
##
##   objects reads drawable quantities out of multivectors.
##   mesh tessellates those quantities into vertices, into fixed storage.
##   camera orbits, and assembles transforms from its own RGA-derived frame.
##   renderer owns OpenGL names and draws the meshes.
##   scene holds objects and catalogue of operations that derive new ones.
##   panel lays out the widgets user edits scene through.
##   image encodes a frame readback as PNG.
##
## Controls:
##   Left drag orbits, right drag pans, wheel dollies.
##   `S` writes current frame to the export path; `Escape` quits.
##
## Command line, for validating a build without sitting in front of it:
##   `--screenshot:PATH` writes one PNG, `--frames:N` exits after N frames,
##   `--hidden` never maps the window. Together they render a scene and quit.

{.experimental: "strictFuncs".}

when compileOption("profiler"):
  import std/nimprof

import std/[math, parseopt, strformat, strutils]

import ./pga
import ./visualiser/[camera, gui, image, mesh, objects, panel, renderer, scene]
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

static:
  doAssert PIXELS_WIDTH >= 640 and PIXELS_HEIGHT >= 480,
    &"Window must be at least 640x480; got `{PIXELS_WIDTH}x{PIXELS_HEIGHT}`."

# Hold vertex storage at module scope, as it is far too large to sit on a stack frame.
var MESHES: MeshSet



#[ Command Line ]#

type Options = object ## Hold what command line asked of this run.
  path_screenshot: string ## Where one-shot export is written; empty for none.
  count_frames: int ## Frames to draw before quitting; 0 to run until closed.
  is_hidden: bool ## Whether window is left unmapped.


proc parseOptions(): Options =
  ## Read command line into options, rejecting anything unrecognised.
  for kind, key, value in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "screenshot": result.path_screenshot = value
      of "frames": result.count_frames = parseInt(value)
      of "hidden": result.is_hidden = true
      else: doAssert false, &"Unknown option `--{key}`; expected screenshot, frames, hidden."
    of cmdArgument:
      doAssert false, &"Unexpected argument `{key}`; every input is a named option."
    of cmdEnd: discard



#[ Demonstration Scene ]#

proc constructScene(): Scene =
  ## Construct opening scene: three seed points, and everything else derived from them.
  let
    point_a = toMultivector(Position(x: 3.0, y: -2.0, z: 0.5))
    point_b = toMultivector(Position(x: -2.5, y: 2.0, z: 3.5))
    point_c = toMultivector(Position(x: 1.0, y: 4.0, z: 1.0))
    ground = (
      toMultivector(Position(x: 0, y: 0, z: 0)) ∧
      toMultivector(Position(x: 1, y: 0, z: 0)) ∧
      toMultivector(Position(x: 0, y: 1, z: 0))
    )
    line_ab = point_a ∧ point_b
    plane_abc = point_a ∧ point_b ∧ point_c

  result.addItem(point_a, "a", Ink.Amber)
  result.addItem(point_b, "b", Ink.Amber)
  result.addItem(point_c, "c", Ink.Amber)
  result.addItem(ground, "ground", Ink.Lime)
  result.addItem(line_ab, "L = a ^ b", Ink.Cyan)
  result.addItem(plane_abc, "G = a ^ b ^ c", Ink.Teal)
  result.addItem(ground ∨ plane_abc, "ground v G", Ink.Violet)
  result.addItem(line_ab ∨ ground, "L v ground", Ink.Coral)



#[ Frame Assembly ]#

proc assembleMeshes(workbench: Workbench; scene: Scene) =
  ## Refill vertex storage from scene as it stands this frame.
  MESHES.clearMeshes
  if workbench.is_grid_shown: MESHES.addGrid
  if workbench.is_axes_shown: MESHES.addAxes
  for item in scene:
    if not item.is_visible: continue
    discard MESHES.addObject(item.geometry, item.ink.colour)


proc exportFrame(path: string; width, height: int; pixels: var seq[uint8]): string =
  ## Read framebuffer back and write it out as PNG, reporting what happened.
  if len(path) == 0: return "Export path is empty; nothing written."
  capturePixels(width, height, pixels)
  writePng(path, width, height, pixels)
  &"Wrote {width}x{height} frame to `{path}`."



#[ Input Handling ]#

proc handleEvent(
  event: Event; camera: var Camera; workbench: var Workbench;
  is_dragging_orbit, is_dragging_pan, is_running: var bool;
) =
  ## Fold one SDL3 event into camera placement, workbench state or run state.
  ##   Mouse is ignored while GUI wants it, so dragging a widget never turns the view.
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
    if event.button.button == uint8(MouseButton.Left): is_dragging_orbit = true
    if event.button.button == uint8(MouseButton.Right): is_dragging_pan = true
  of uint32(EventKind.MouseButtonUp):
    if event.button.button == uint8(MouseButton.Left): is_dragging_orbit = false
    if event.button.button == uint8(MouseButton.Right): is_dragging_pan = false
  of uint32(EventKind.MouseWheel):
    if gui.wantsMouse(): return
    camera.dolly(pow(FACTOR_DOLLY, -float(event.wheel.y)))
  of uint32(EventKind.MouseMotion):
    if is_dragging_orbit:
      camera.orbit(-SPEED_ORBIT*float(event.motion.xrel), SPEED_ORBIT*float(event.motion.yrel))
    if is_dragging_pan:
      camera.pan(-SPEED_PAN*float(event.motion.xrel), SPEED_PAN*float(event.motion.yrel))
  else: discard



#[ Entry Point ]#

proc main() =
  ## Open window, run frames until asked to stop, then tear everything down in order.
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
    scene = constructScene()
    camera = initCamera(
      target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05, elevation = 0.42
    )
    workbench = initWorkbench(
      if len(options.path_screenshot) > 0: options.path_screenshot
      else: PATH_EXPORT_DEFAULT
    )
    pixels = newSeq[uint8](0)
    is_running = true
    is_dragging_orbit = false
    is_dragging_pan = false
    count_drawn = 0

  while is_running:
    var event: Event
    while sdl3.pollEvent(addr event):
      gui.processEvent(addr event)
      handleEvent(event, camera, workbench, is_dragging_orbit, is_dragging_pan, is_running)

    var (width, height) = (cint(PIXELS_WIDTH), cint(PIXELS_HEIGHT))
    sdl3.getWindowSizeInPixels(window, addr width, addr height)

    # Lay panels out first, so this frame's edits reach meshes assembled below.
    gui.frameBegin()
    layoutWorkbench(workbench, scene, camera)

    assembleMeshes(workbench, scene)
    clearFrame(int(width), int(height))
    renderer.drawMeshes(MESHES, camera.initMatrixViewProjection(width / height))
    gui.frameEnd()

    # Export on final frame of a headless run, so a build can be checked without a screen.
    inc count_drawn
    let is_final = options.count_frames > 0 and count_drawn >= options.count_frames
    if is_final and len(options.path_screenshot) > 0: workbench.is_export_requested = true

    # Read back before swapping, as back buffer is what was just drawn into.
    if workbench.is_export_requested:
      workbench.is_export_requested = false
      let report = exportFrame(
        $toCstring(workbench.path_export), int(width), int(height), pixels
      )
      toChars(report, workbench.message)
      echo report

    sdl3.glSwapWindow(window)
    if is_final: is_running = false

  echo &"Drew {count_drawn} frames."

main()
