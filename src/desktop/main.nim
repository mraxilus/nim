## Run the desktop build: a window, a scene, and one immediate-mode panel drawn over it.
##
## Command line, all optional:
##
## | Option             | Effect                                                           |
## |--------------------|------------------------------------------------------------------|
## | `--screenshot:PATH`| Write one image and exit.                                        |
## | `--frames:N`       | Exit after N frames.                                             |
## | `--hidden`         | Never map the window, for a headless run.                        |
## | `--storyboard:DIR` | Run capture mode: one image per demo step, plus an animated GIF. |
## | `--load-scene:PATH`| Open a saved scene instead of the seeds.                         |
## | `--timings`        | Report frame-time statistics over a `--frames:N` run.            |
## | `--novsync`        | Disable vsync, for an uncapped reading.                          |
## | `--fill`           | Top the scene up to capacity first, for the heaviest case.       |

{.experimental: "strictFuncs".}

import std/[options, os, strutils, tables, times, unicode]

import ../core/[demo, diagnostics, format, sceneio, workbench]
import ./[arena, font, glyphs, panel, platform, png, renderer, storyboard]



#[ Options ]#

type Options = object
  ## Hold what the command line asked for.
  screenshot: Option[string]
  frames: Option[int]
  storyboard: Option[string]
  load_scene: Option[string]
  is_hidden: bool
  is_reporting_timings: bool
  is_vsync_disabled: bool
  is_filling: bool

const VALID_OPTIONS = [
  "--screenshot:PATH", "--frames:N", "--hidden", "--storyboard:DIR", "--load-scene:PATH",
  "--timings", "--novsync", "--fill",
]

proc parseOptions(): Options =
  ## Read the command line, naming the valid set where an option is not one of them.
  for index in 1 .. paramCount():
    let argument = paramStr(index)
    if argument.startsWith("--screenshot:"):
      result.screenshot = some(argument["--screenshot:".len .. ^1])
    elif argument.startsWith("--frames:"):
      result.frames = some(parseInt(argument["--frames:".len .. ^1]))
    elif argument.startsWith("--storyboard:"):
      result.storyboard = some(argument["--storyboard:".len .. ^1])
    elif argument.startsWith("--load-scene:"):
      result.load_scene = some(argument["--load-scene:".len .. ^1])
    elif argument == "--hidden": result.is_hidden = true
    elif argument == "--timings": result.is_reporting_timings = true
    elif argument == "--novsync": result.is_vsync_disabled = true
    elif argument == "--fill": result.is_filling = true
    else:
      quit("unknown option `" & argument & "`; valid options are " & VALID_OPTIONS.join(" "))



#[ Window Input ]#

var
  bench = initWorkbench()
    ## Hold the tool's whole state.
  meshes: Mesh
    ## Hold one frame's primitives, at module scope so no frame re-declares it.
  frame_times: FrameTimes
    ## Hold the frame-time ring buffer the diagnostics section graphs.
  ui: Panel
    ## Hold the panel's own little interaction state.
  draw: Renderer
    ## Hold every GL object.
  permanent_arena = initArena("permanent", 0)
    ## Hold scratch memory image export never gives back; sized at startup.
  frame_arena = initArena("frame", 0)
    ## Hold scratch memory reset after each throwaway unit of work.
  pointer_slot = none(Slot)
    ## Remember which object a drag started on.
  pointer_button = PointerButton.Left
    ## Remember which button a drag started with.
  press_x, press_y, press_time_ms: float
    ## Remember where and when a press started, so a click can be told from a drag.
  scene_path = "scene.rgascene"
    ## Name the file the save and load controls write and read.


proc onMouseButton(window: Window, button, action, modifiers: cint) {.cdecl.} =
  ## Turn a button press into a pick, and a release into a selection or a derivation.
  var x, y: cdouble
  glfwGetCursorPos(window, addr x, addr y)
  ui.pointer_x = x
  ui.pointer_y = y
  if ui.isBusy:
    ui.is_pointer_down = action == GLFW_PRESS
    return
  let mapped =
    case button
    of GLFW_MOUSE_BUTTON_RIGHT: PointerButton.Right
    of GLFW_MOUSE_BUTTON_MIDDLE: PointerButton.Middle
    else: PointerButton.Left
  var width, height: cint
  glfwGetFramebufferSize(window, addr width, addr height)
  let viewport = Viewport(width: width.float, height: height.float)
  if action == GLFW_PRESS:
    pointer_button = mapped
    press_x = x
    press_y = y
    press_time_ms = bench.now_ms
    pointer_slot = pick(bench.scene, bench.camera, viewport, ScreenPoint(x: x, y: y))
    ui.is_pointer_down = true
    return

  ui.is_pointer_down = false
  let
    elapsed = bench.now_ms - press_time_ms
    moved = abs(x - press_x) + abs(y - press_y)
  if isClick(elapsed, moved):
    if pointer_slot.isNone: bench.selection.clear()
    elif glfwGetKey(window, GLFW_KEY_LEFT_SHIFT) == GLFW_PRESS or
        glfwGetKey(window, GLFW_KEY_RIGHT_SHIFT) == GLFW_PRESS:
      bench.selection.toggle(pointer_slot.get)
    else: bench.selection.replaceWith(pointer_slot.get)
    pointer_slot = none(Slot)
    return
  if pointer_slot.isSome:
    let destination = pick(bench.scene, bench.camera, viewport, ScreenPoint(x: x, y: y))
    if destination.isSome and destination.get != pointer_slot.get:
      discard bench.applyDrag(pointer_button, pointer_slot.get, destination.get)
  pointer_slot = none(Slot)


proc onScroll(window: Window, x, y: cdouble) {.cdecl.} =
  ## Turn a wheel notch into a dolly.
  if ui.isBusy: return
  bench.camera.dolly(y.float)
  bench.grabCamera()


proc onChar(window: Window, codepoint: cuint) {.cdecl.} =
  ## Feed a typed character to whichever field has the keyboard.
  ui.typed.add(Rune(codepoint.int))


proc onKey(window: Window, key, scancode, action, modifiers: cint) {.cdecl.} =
  ## Feed the editing keys that produce no character.
  if action != GLFW_PRESS: return
  case key
  of GLFW_KEY_BACKSPACE: ui.is_backspace = true
  of GLFW_KEY_ENTER: ui.is_enter = true
  of GLFW_KEY_ESCAPE: ui.is_escape = true
  else: discard



#[ Panel Content ]#

var
  apply_arity = 0
  apply_operation = 0
  apply_first = 0
  apply_second = 0

proc pickerControl(
  draw: var Renderer, id: int, name, reading: string, count: int, chosen: var int
) =
  ## Draw a stepping picker: a name, the current reading, and a control on each side.
  ##   A list box would need scrolling and a scrollbar; stepping keeps the panel's own width
  ##   free for the reading, which is the part that has to be legible.
  let step_width = measureButton(draw, "›")
  ui.sameLine(0)
  ui.label(draw, name, is_faint = true)
  ui.sameLine(0)
  if ui.button(draw, id, "‹", step_width) and count > 0:
    chosen = (chosen - 1 + count) mod count
  ui.sameLine(step_width + ROW_GAP)
  discard draw.text(ui.x + step_width + ROW_GAP*2, ui.y + 4.0, reading, tones().ink)
  ui.sameLine(ui.contentWidth - step_width)
  if ui.button(draw, id + 1, "›", step_width) and count > 0:
    chosen = (chosen + 1) mod count
  ui.newLine(CONTROL_HEIGHT)


proc drawApplySection(draw: var Renderer) =
  ## Draw the apply section: an arity toggle, an operation picker, operand pickers, a button.
  ##   Stays usable at three or more selected, because it has operand pickers and can say
  ##   which two it means.
  apply_arity = ui.segmented(draw, 100, ["unary", "binary"], apply_arity)
  let
    arity = if apply_arity == 1: Arity.Binary else: Arity.Unary
    operations = operationCount(arity)
  if apply_operation >= operations: apply_operation = 0
  var chosen = apply_operation
  var name = ""
  var seen = 0
  for operation in operations(arity):
    if seen == chosen: name = operation.label
    seen += 1
  pickerControl(draw, 110, "operation", name, operations, chosen)
  apply_operation = chosen

  var order: array[ITEM_CAPACITY, Slot]
  let live = bench.scene.recentOrder(order)
  if live > 0:
    if apply_first >= live: apply_first = 0
    if apply_second >= live: apply_second = 0
    var first = apply_first
    pickerControl(draw, 120, OPERAND_FIRST, $bench.scene.label(order[first]), live, first)
    apply_first = first
    if arity == Arity.Binary:
      var second = apply_second
      pickerControl(
        draw, 130, OPERAND_SECOND, $bench.scene.label(order[second]), live, second
      )
      apply_second = second

  if ui.button(draw, 140, "apply") and live > 0:
    var seen_again = 0
    for operation in operations(arity):
      if seen_again == apply_operation:
        discard bench.applyOperation(
          operation, order[apply_first],
          (if arity == Arity.Binary: order[apply_second] else: order[apply_first]),
        )
        break
      seen_again += 1
  ui.newLine(CONTROL_HEIGHT)


proc drawSessionRow(draw: var Renderer, id: int, slot: Option[Slot]) =
  ## Draw the open session's own row: its fields, its controls and its coefficient grid.
  let is_editing = slot.isSome
  var buttons = @[measureButton(draw, "save"), measureButton(draw, "✕")]
  if is_editing:
    buttons.add(measureButton(draw, "hide"))
    buttons.add(measureButton(draw, "remove"))
  let start = ui.rightAligned(draw, buttons)

  let (text, is_committed) = ui.field(draw, id, $bench.session.get.label, start - ROW_GAP)
  if is_committed: bench.session.get.setLabel(initLabel(text))

  var offset = start
  ui.sameLine(offset)
  if ui.button(draw, id + 1, "save", buttons[0]): discard bench.saveSession()
  offset += buttons[0] + ROW_GAP
  ui.sameLine(offset)
  if ui.button(draw, id + 2, "✕", buttons[1]): bench.cancelSession()
  if is_editing and bench.session.isSome:
    offset += buttons[1] + ROW_GAP
    ui.sameLine(offset)
    if ui.button(draw, id + 3, "hide", buttons[2]):
      bench.setVisibility(slot.get, not bench.scene.isVisible(slot.get))
    offset += buttons[2] + ROW_GAP
    ui.sameLine(offset)
    if ui.button(draw, id + 4, "remove", buttons[3]):
      bench.cancelSession()
      bench.removeSlot(slot.get)
  ui.newLine(CONTROL_HEIGHT)
  if bench.session.isNone: return

  # One line per grade, with each element's name above its cell rather than beside it:
  #   beside charges every cell the width of the longest name and pushed the panel to 680 px.
  const WRAP = 6  # Wrap point, not divisor: this build's largest grade holds exactly six.
  var
    row: seq[Basis]
    current_grade = -1
  proc flushRow(draw: var Renderer, row: var seq[Basis]) =
    if row.len == 0: return
    let cell = ui.contentWidth/min(row.len, WRAP).float
    for index, b in row:
      ui.sameLine(cell*index.float)
      discard draw.text(ui.x + cell*index.float, ui.y, b.elementName, tones().ink_faint)
    ui.newLine(ui.line_height)
    for index, b in row:
      ui.sameLine(cell*index.float)
      let (text, is_committed) = ui.field(
        draw, 2000 + ord(b), format(bench.session.get.coefficient(b)), cell - ROW_GAP
      )
      if is_committed:
        bench.session.get.setCoefficient(b, parseNumber(text))
    ui.newLine(CONTROL_HEIGHT)
    row.setLen(0)

  for b in Basis:
    let grade = int(b.grade)
    if grade != current_grade or row.len >= WRAP:
      flushRow(draw, row)
      current_grade = grade
    row.add(b)
  flushRow(draw, row)


proc drawObjectsSection(draw: var Renderer) =
  ## Draw one row per item: a checkbox, a name, three controls, then its reading.
  if bench.isSessionOpen and bench.session.get.mode == SessionMode.Composing:
    drawSessionRow(draw, 300, none(Slot))

  var order: array[ITEM_CAPACITY, Slot]
  let live = bench.scene.recentOrder(order)
  for index in 0 ..< live:
    let
      slot = order[index]
      id = 1000 + slot.index*8
    # Dim through the style alpha, not a disabled scope, so the row's own show button stays
    #   clickable and the dimming combines with the selection highlight.
    ui.alpha = if bench.scene.isVisible(slot): 1.0 else: 0.45
    let buttons = [
      measureButton(draw, "edit"),
      measureButton(draw, if bench.scene.isVisible(slot): "hide" else: "show"),
      measureButton(draw, "remove"),
    ]
    let start = ui.rightAligned(draw, buttons)

    ui.sameLine(0)
    if ui.checkbox(draw, id, bench.selection.contains(slot)):
      bench.selection.toggle(slot)
    ui.sameLine(22.0)
    ui.swatch(draw, bench.scene.paint(slot).color)
    ui.sameLine(40.0)
    if ui.button(draw, id + 1, $bench.scene.label(slot), start - 40.0 - ROW_GAP):
      bench.selection.replaceWith(slot)

    var offset = start
    ui.sameLine(offset)
    if ui.button(draw, id + 2, "edit", buttons[0]): bench.startEditing(slot)
    offset += buttons[0] + ROW_GAP
    ui.sameLine(offset)
    if ui.button(
      draw, id + 3, (if bench.scene.isVisible(slot): "hide" else: "show"), buttons[1]
    ):
      bench.setVisibility(slot, not bench.scene.isVisible(slot))
    offset += buttons[1] + ROW_GAP
    ui.sameLine(offset)
    if ui.button(draw, id + 4, "remove", buttons[2]): bench.removeSlot(slot)
    ui.newLine(CONTROL_HEIGHT)

    if bench.scene.isLive(slot):
      let geometry = bench.scene.geometry(slot)
      var reading = geometry.shape.shapeWord & ":"
      for b in Basis:
        let value = geometry.coefficient(b)
        if abs(value) <= TOLERANCE_ABS: continue
        reading &= " " & format(value) & b.elementName
      ui.label(draw, reading, is_faint = true, family = Family.Mono)
      if bench.isSessionOpen and bench.session.get.slot == some(slot):
        drawSessionRow(draw, id + 5, some(slot))
    ui.alpha = 1.0


proc drawViewSection(draw: var Renderer) =
  ## Draw the seven editable camera fields.
  const NAMES = [
    "azimuth", "elevation", "distance", "field of view", "target x", "target y", "target z",
  ]
  for index, name in NAMES:
    let value =
      case index
      of 0: bench.camera.azimuth
      of 1: bench.camera.elevation
      of 2: bench.camera.distance
      of 3: bench.camera.fov
      of 4: bench.camera.target.x
      of 5: bench.camera.target.y
      else: bench.camera.target.z
    # Draw the name without advancing, so a field and its name share one row.
    discard draw.text(ui.x, ui.y + 4.0, name, tones().ink_muted)
    ui.sameLine(140.0)
    let (text, is_committed) = ui.field(draw, 400 + index, format(value), ui.contentWidth - 140.0)
    if is_committed:
      let parsed = parseNumber(text)
      case index
      of 0: bench.camera.azimuth = parsed
      of 1: bench.camera.elevation = parsed
      of 2: bench.camera.distance = parsed
      of 3: bench.camera.fov = parsed
      of 4: bench.camera.target.x = parsed
      of 5: bench.camera.target.y = parsed
      else: bench.camera.target.z = parsed
      bench.camera.clampFields()
      bench.grabCamera()
    ui.newLine(CONTROL_HEIGHT)


proc drawDiagnosticsSection(draw: var Renderer) =
  ## Draw the frame graph, the allocator bars, the pool strip and the fixed reservations.
  var samples: array[FRAME_SAMPLE_COUNT, float]
  for index in 0 ..< frame_times.len: samples[index] = frame_times.at(index)
  ui.graph(draw, samples, frame_times.len, max(frame_times.peak, 1.0))
  ui.label(
    draw,
    "frame " & formatFixed(frame_times.latest) & " ms  peak " &
      formatFixed(frame_times.peak) & " ms  mean " & formatFixed(frame_times.mean) & " ms",
    is_faint = true, family = Family.Mono,
  )
  ui.bar(
    draw, permanent_arena.used.float/max(permanent_arena.capacity.float, 1.0),
    "permanent arena " & $(permanent_arena.used div 1024) & " / " &
      $(permanent_arena.capacity div 1024) & " KB",
  )
  ui.bar(
    draw, frame_arena.highWater.float/max(frame_arena.capacity.float, 1.0),
    "frame arena high water " & $(frame_arena.highWater div 1024) & " / " &
      $(frame_arena.capacity div 1024) & " KB",
  )
  var strip: array[ITEM_CAPACITY*3, float]
  bench.scene.poolStrip(strip)
  ui.strip(draw, strip, ITEM_CAPACITY)
  let report = bench.scene.poolReport(sizeof(Scene) div ITEM_CAPACITY)
  ui.label(
    draw,
    $report.active & " active  " & $report.free & " free  " &
      $(report.capacity_bytes div 1024) & " KB pool  " & $report.slot_bytes & " B per slot",
    is_faint = true, family = Family.Mono,
  )
  # Total every fixed reservation the binary makes, computed in the one place that sees them.
  let reserved =
    sizeof(Scene) + sizeof(Mesh) + sizeof(Renderer) + ATLAS_SIZE*ATLAS_SIZE +
    permanent_arena.capacity + frame_arena.capacity + sizeof(History)
  ui.label(
    draw, "fixed reservations " & $(reserved div 1024) & " KB",
    is_faint = true, family = Family.Mono,
  )


proc drawTopBar(draw: var Renderer, window: Window) =
  ## Draw the controls that sit outside every section.
  ##   `add` has to be able to open the objects section, so it cannot live inside it.
  var offset = 0.0
  proc place(draw: var Renderer, id: int, text: string, is_enabled = true): bool =
    let width = measureButton(draw, text)
    ui.sameLine(offset)
    result = ui.button(draw, id, text, width, is_enabled)
    offset += width + ROW_GAP

  if place(draw, 10, "add", not bench.isSessionOpen):
    bench.startComposing(initLabel("new"))
    ui.open_sections["objects"] = true
  if place(draw, 11, "undo", bench.history.canUndo): discard bench.undo()
  if place(draw, 12, "redo", bench.history.canRedo): discard bench.redo()
  if place(draw, 13, "axes"): bench.is_showing_axes = not bench.is_showing_axes
  if place(draw, 14, "grid"): bench.is_showing_grid = not bench.is_showing_grid
  if place(draw, 15, "save"): writeFile(scene_path, encode(bench.scene))
  if place(draw, 16, "load"):
    if fileExists(scene_path):
      let loaded = decode(readFile(scene_path))
      if loaded.isSome: bench.reset(loaded.get)
  ui.newLine(CONTROL_HEIGHT)


proc drawPanel(draw: var Renderer, window: Window, height: float) =
  ## Draw the whole panel: the top bar, then four sections in alphabetical order.
  ui.begin(draw, height)
  drawTopBar(draw, window)
  if ui.section(draw, 20, "apply"): drawApplySection(draw)
  if ui.section(draw, 21, "diagnostics"): drawDiagnosticsSection(draw)
  if ui.section(draw, 22, "objects"): drawObjectsSection(draw)
  if ui.section(draw, 23, "view"): drawViewSection(draw)
  draw.flushOverlay(uses_texture = true)
  ui.finish()



#[ Capture ]#

proc readPixels(width, height: int): seq[uint8] =
  ## Read the framebuffer back, top row first, as a capture or a screenshot needs it.
  var flipped = newSeq[uint8](width*height*4)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glFinish()
  glReadPixels(
    0, 0, width.GLsizei, height.GLsizei, GL_RGBA, GL_UNSIGNED_BYTE, addr flipped[0]
  )
  result = newSeq[uint8](width*height*4)
  for row in 0 ..< height:
    let source = (height - 1 - row)*width*4
    for index in 0 ..< width*4:
      result[row*width*4 + index] = flipped[source + index]



#[ Entry Point ]#

proc main() =
  ## Run the tool.
  let options = parseOptions()
  if glfwInit() == 0: quit("the window library failed to start")
  glfwWindowHint(GLFW_VISIBLE, if options.is_hidden: 0 else: 1)
  glfwWindowHint(GLFW_SAMPLES, 4)
  let window = glfwCreateWindow(1440, 900, "RGA Workbench", Monitor(nil), Window(nil))
  if pointer(window) == nil:
    glfwTerminate()
    quit("the window could not be created")
  glfwMakeContextCurrent(window)
  glfwSwapInterval(if options.is_vsync_disabled: 0 else: 1)
  glfwSetMouseButtonCallback(window, onMouseButton)
  glfwSetScrollCallback(window, onScroll)
  glfwSetCharCallback(window, onChar)
  glfwSetKeyCallback(window, onKey)

  # Size the permanent arena to the capture run's own measured requirement, not to a round
  #   number: a storyboard frame's quantisation table and its compressed bytes are the largest
  #   thing this binary ever asks for.
  permanent_arena = initArena("permanent", storyboardArenaBytes())
  frame_arena = initArena("frame", storyboardFrameArenaBytes())

  draw.initRenderer(initAtlas(codepointsWritten()))
  bench.reset(seedScene())
  if options.load_scene.isSome:
    let loaded = decode(readFile(options.load_scene.get))
    if loaded.isSome: bench.reset(loaded.get)
    else: quit("that file is not a scene this build can read")
  if options.is_filling:
    while not bench.scene.isFull:
      discard bench.addObject(
        pointAt(float(bench.scene.count mod 7), float(bench.scene.count mod 5), 1.0),
        initLabel("fill " & $bench.scene.count),
      )

  if options.storyboard.isSome:
    runStoryboard(options.storyboard.get, draw, meshes, permanent_arena, frame_arena)
    glfwDestroyWindow(window)
    glfwTerminate()
    return

  var
    frame = 0
    started = epochTime()
    previous_ms = 0.0
  while glfwWindowShouldClose(window) == 0:
    glfwPollEvents()
    var width, height: cint
    glfwGetFramebufferSize(window, addr width, addr height)
    let now_ms = (epochTime() - started)*1000.0
    let delta_ms = if previous_ms > 0.0: now_ms - previous_ms else: 0.0
    previous_ms = now_ms
    frame_times.record(delta_ms)

    var x, y: cdouble
    glfwGetCursorPos(window, addr x, addr y)
    ui.pointer_x = x
    ui.pointer_y = y
    ui.is_pointer_down = glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS

    bench.now_ms = now_ms
    if not ui.isBusy:
      let viewport = Viewport(width: width.float, height: height.float)
      bench.hovered = pick(bench.scene, bench.camera, viewport, ScreenPoint(x: x, y: y))
      # Dragging from empty space moves the camera; dragging from an object derives one.
      if ui.is_pointer_down and pointer_slot.isNone:
        let dx = x - press_x
        let dy = y - press_y
        if pointer_button == PointerButton.Left: bench.camera.orbit(dx, dy)
        elif pointer_button == PointerButton.Right: bench.camera.pan(dx, dy)
        if dx != 0.0 or dy != 0.0: bench.grabCamera()
        press_x = x
        press_y = y

    bench.aim()
    bench.advanceCamera(delta_ms)
    bench.buildMesh(meshes)

    draw.beginFrame(width.int, height.int)
    draw.drawScene(meshes, bench.camera)
    draw.drawRings(meshes, bench.camera)
    drawPanel(draw, window, height.float)
    glfwSwapBuffers(window)

    frame += 1
    if options.screenshot.isSome and frame >= 2:
      writePng(options.screenshot.get, readPixels(width.int, height.int), width.int, height.int)
      break
    if options.frames.isSome and frame >= options.frames.get: break

  if options.is_reporting_timings:
    echo "frames ", frame_times.len,
      "  mean ", formatFixed(frame_times.mean), " ms",
      "  peak ", formatFixed(frame_times.peak), " ms"
    echo "Software rasterisation dominates this reading where no GPU is present; a frame-rate ",
      "target cannot be assessed from it."

  glfwDestroyWindow(window)
  glfwTerminate()


when isMainModule:
  main()
