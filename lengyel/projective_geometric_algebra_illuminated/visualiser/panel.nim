## Lay out panels user edits scene and camera through.
##
## Workbench holds what the GUI needs between frames and the scene does not own:
## which operands are picked, what point is about to be added, where to export.
##   Everything else is read straight off scene and camera, so there is one source of truth
##   and no synchronisation step.
##
##   |-------------|--------------------------------------------------------------------|
##   | Panel       | Offers                                                             |
##   |-------------|--------------------------------------------------------------------|
##   | View        | Orbit, target, lens, world furniture, PNG export.                   |
##   | Construct   | Add point at a position; apply any library operation to operands.   |
##   | Objects     | Show, hide, rename, recolour, remove; edit any coefficient.         |
##   | Diagnostics | Live frame time, vsync, memory use of both arenas, object pool,     |
##   |             | and everything else this binary reserves for itself, added up.     |
##   |-------------|--------------------------------------------------------------------|
##
## Every panel above is a collapsing header, so a first-time reader can open one at a
## time rather than face all four at once; View, Construct and Objects open by default
## since a new session needs them immediately, Diagnostics starts closed since nothing
## in it is needed to use the workbench, only to understand what using it costs.
##
## Coefficients are staged through 32-bit floats because that is what the widget writes,
## and written back only where widget reports a change, so editing costs no precision
## on coefficients the user never touched.
##
## Multivectors are printed by `scene.formatMultivector` rather than by the library's own
## `$`, which writes basis elements in mathematical bold outside the Basic Multilingual
## Plane. No font available to the GUI carries those, so they would draw as empty boxes.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./[camera, format, gui, mesh, objects, scene]



#[ Workbench Configuration ]#

const
  MESSAGE_MAX* = 96
    ## Bound length of outcome reported after an action.
  PATH_MAX* = 256
    ## Bound length of export path user may type.
  WIDTH_PANEL* = 430.0'f32
    ## Set width panels open at, in pixels.
  SPEED_DRAG* = 0.01'f32
    ## Set how fast a coefficient moves per pixel dragged.
  WIDTH_ITEM_LINE = 128
    ## Bound length of one item's coefficient or shape line, redrawn every frame.
  WIDTH_SHAPE_WORD = 32
    ## Bound length of the shape word alone, longest being "mixed grade, nothing to draw".
  WIDTH_OVERLAY_TEXT = 48
    ## Bound length of a bar or graph's own overlay text, redrawn every frame.
  FRAMES_HISTORY* {.define: "visualiser.frames_history".} = 240
    ## Bound how many recent per-frame timings the live diagnostics graph keeps; at a
    ## typical frame rate this covers a few seconds, long enough to see a stutter land
    ## and scroll back off, not so long the graph goes stale reading it.



#[ Type Definitions ]#

type
  Workbench* = object ## Hold GUI's own state between frames.
    place_new*: array[3, cfloat] ## Position next added point stands at.
    index_operand_first*: cint ## Item picked as left operand.
    index_operand_second*: cint ## Item picked as right operand.
    index_operation*: cint ## Operation picked from catalogue.
    is_grid_shown*: bool ## Whether ground reference grid is drawn.
    is_axes_shown*: bool ## Whether world axes are drawn.
    is_export_requested*: bool ## Whether frame should be written out after drawing.
    is_vsync_enabled*: bool ## Whether swap waits for display refresh before returning.
    microseconds_tessellate*: float ## Cost of rebuilding vertex storage, last frame.
    count_vertices*: int ## Vertices assembled, last frame.
    path_export*: array[PATH_MAX, char] ## Where exported frame is written.
    message*: array[MESSAGE_MAX, char] ## Outcome of last action taken.
    milliseconds_history*: array[FRAMES_HISTORY, cfloat] ## Ring buffer of recent frame
      ## times, oldest to newest by `index_history`; owned here rather than in a module
      ## global, since nothing outside the GUI panel that plots it ever reads it.
    index_history*: int ## Next slot in `milliseconds_history` a fresh reading overwrites.
    bytes_arena_permanent_used*: int ## Snapshot of the permanent arena's own `used`.
    bytes_arena_permanent_capacity*: int ## Snapshot of the permanent arena's `capacity`.
    bytes_arena_frame_peak*: int ## Snapshot of the frame arena's own `peakUsed`.
    bytes_arena_frame_capacity*: int ## Snapshot of the frame arena's `capacity`.
    bytes_memory_total*: int ## Sum of every fixed reservation this binary makes for
      ## itself; computed once where every piece is visible, since `panel` alone cannot
      ## see the arenas' own backing storage or the mesh and timing buffers beside them.


func initWorkbench*(path_export: string): Workbench =
  ## Construct workbench with world furniture shown and export aimed at `path_export`.
  result.is_grid_shown = true
  result.is_axes_shown = true
  result.is_vsync_enabled = true
  toChars(path_export, result.path_export)
  toChars("Ready.", result.message)



#[ Objects Panel ]#

proc layoutCoefficients(geometry: var Multivector) =
  ## Lay out one drag widget per basis coefficient, writing back only what changed.
  var staged: array[Basis, cfloat]
  for b in Basis: staged[b] = cfloat(geometry[b])
  gui.widthPush(140.0)
  for b in Basis:
    if gui.dragFloat(cstring(lut_basis_to_name[b]), addr staged[b], SPEED_DRAG, 0.0, 0.0):
      geometry[b] = float(staged[b])
    if int(b) mod 4 != 3: gui.sameLine()
  gui.widthPop()


proc layoutItem(scene: var Scene; slot: int): bool =
  ## Lay out one item's controls, by slot; report whether user asked for it to be removed.
  gui.idPush(cint(slot))
  defer: gui.idPop()

  discard gui.checkbox("", addr scene.isVisibleAt(slot))
  gui.tooltip("Show or hide this object without removing it.")
  gui.sameLine()
  let tint = scene.ink(slot).colour
  gui.textTinted(toCstring(scene.labelAt(slot)), tint.red, tint.green, tint.blue)
  gui.sameLine()
  result = gui.buttonSmall("remove")
  gui.tooltip("Delete this object; its slot is reused by the next one you add.")

  # Read once, not once per line below -- `geometry` borrows straight out of scene's own
  #   storage, so this costs nothing beyond the two `formatMultivector`/`describeShape`
  #   reads actually need.
  let geometry = scene.geometry(slot)

  # Built into a stack buffer rather than a `string`, since every visible item redraws
  #   both lines every frame; a fresh heap string per item per frame is exactly the kind
  #   of allocator churn an arena-backed scene should not turn around and reintroduce.
  var line: array[WIDTH_ITEM_LINE, char]
  let coefficients = buildChars(line):
    appendChars(line, cursor, "  ")
    formatMultivector(geometry, line, cursor)
  gui.text(coefficients)
  let shape_word = buildChars(line):
    appendChars(line, cursor, "  ")
    describeShape(geometry, line, cursor)
  gui.text(shape_word)

  if gui.header("edit", is_open_first = false):
    gui.widthPush(220.0)
    discard gui.inputText("label", toCstring(scene.labelAt(slot)), cint(LABEL_MAX))
    var index_ink = cint(scene.ink(slot))
    if gui.combo("colour", addr index_ink, addr lut_ink_to_name[Ink.low], cint(COUNT_INK)):
      scene.setInk(slot, Ink(index_ink))
    gui.widthPop()
    gui.text("Coefficients:")
    gui.sameLine()
    gui.helpMarker(
      "The 16 numbers of this RGA object's own multivector, in the library's basis " &
      "order; drag any one to reshape the object directly."
    )
    layoutCoefficients(scene.geometryAt(slot))
  gui.separator()


proc layoutObjects*(scene: var Scene) =
  ## Lay out every live item's controls, applying at most one removal per frame.
  ##   One per frame is enough, since a click can only land on one button.
  var header: array[32, char]
  let label = buildChars(header):
    appendChars(header, cursor, "objects (")
    appendInt(header, cursor, scene.len)
    appendChars(header, cursor, " of ")
    appendInt(header, cursor, ITEMS_MAX)
    appendChars(header, cursor, ")")
  if not gui.header(label, is_open_first = true): return

  if scene.len == 0:
    gui.text("Nothing here yet -- add a point below, or drag between two once you have a few.")
    return

  var slot_removed = none(int)
  for slot in scene.liveSlots:
    if layoutItem(scene, slot): slot_removed = some(slot)
  if slot_removed.isSome: scene.removeItem(slot_removed.get)



#[ Construct Panel ]#

proc layoutPointNew(workbench: var Workbench; scene: var Scene; now: float) =
  ## Lay out controls that add fresh point at a position.
  gui.separatorText("add point")
  gui.widthPush(260.0)
  discard gui.dragFloat3("position", addr workbench.place_new[0], SPEED_DRAG*10.0)
  gui.tooltip("World x, y, z the new point stands at; click and drag a number to change it.")
  gui.widthPop()
  gui.disabledPush(scene.isFull)
  if gui.button("add point"):
    let place = Position(
      x: float(workbench.place_new[0]),
      y: float(workbench.place_new[1]),
      z: float(workbench.place_new[2]),
    )
    scene.addItem(toMultivector(place), &"p{scene.len}", inkCycled(scene.len), now)
    toChars(&"Added point at ({place.x:.2f}, {place.y:.2f}, {place.z:.2f}).",
      workbench.message)
  gui.disabledPop()


proc layoutOperation(workbench: var Workbench; scene: var Scene; now: float) =
  ## Lay out controls that derive fresh object by applying library operation to operands.
  gui.separatorText("apply operation")
  if scene.len == 0:
    gui.text("Scene is empty; add a point first.")
    return

  # Offer every live item by label, so operands are picked by name rather than by slot;
  #   `slots` translates the combo's dense position back to the slot it names.
  var
    names: array[ITEMS_MAX, cstring]
    slots: array[ITEMS_MAX, int]
    count = 0
  for slot in scene.liveSlots:
    names[count] = toCstring(scene.labelAt(slot))
    slots[count] = slot
    inc count

  let operation = Operation(workbench.index_operation)
  let is_binary = lut_operation_to_arity[operation] == Arity.Two
  gui.widthPush(300.0)
  discard gui.combo(
    "operation", addr workbench.index_operation,
    addr lut_operation_to_notation[Operation.low], cint(COUNT_OPERATION),
  )
  gui.tooltip("Library operation to apply below; its own notation names m and n, " &
    "the operands picked next.")
  discard gui.combo("operand m", addr workbench.index_operand_first,
    addr names[0], cint(count))
  gui.tooltip("First operand -- `m` in the notation above -- every operation reads.")
  gui.disabledPush(not is_binary)
  discard gui.combo("operand n", addr workbench.index_operand_second,
    addr names[0], cint(count))
  if is_binary:
    gui.tooltip("Second operand -- `n` above -- this operation combines with `m`.")
  else:
    gui.tooltip("Greyed out because the operation picked above takes one operand, not two.")
  gui.disabledPop()
  gui.widthPop()

  gui.disabledPush(scene.isFull)
  if gui.button("apply"):
    let
      first = slots[clamp(int(workbench.index_operand_first), 0, count - 1)]
      second = slots[clamp(int(workbench.index_operand_second), 0, count - 1)]
      derived = applyOperation(operation, scene.geometry(first), scene.geometry(second))
      name_first = $toCstring(scene.labelAt(first))
      name_second = $toCstring(scene.labelAt(second))
      label =
        if is_binary: &"{name_first} {$operation} {name_second}"
        else: &"{$operation} {name_first}"
    scene.addItem(derived, label, inkCycled(scene.len), now)

    var shape_word: array[WIDTH_SHAPE_WORD, char]
    var cursor_shape = 0
    describeShape(derived, shape_word, cursor_shape)
    finishChars(shape_word, cursor_shape)
    toChars(&"{$operation} gave {$toCstring(shape_word)}.", workbench.message)
  gui.disabledPop()


proc layoutConstruct*(workbench: var Workbench; scene: var Scene; now: float) =
  ## Lay out both ways of growing scene, then report outcome of last action.
  ##   `now` is only ever forwarded to a freshly added item's `born` reading; nothing
  ##   here reads a clock itself.
  if not gui.header("construct", is_open_first = true): return
  layoutPointNew(workbench, scene, now)
  layoutOperation(workbench, scene, now)
  gui.separator()
  gui.text(toCstring(workbench.message))



#[ View Panel ]#

proc layoutView*(workbench: var Workbench; camera: var Camera) =
  ## Lay out camera placement, world furniture and frame export.
  if not gui.header("view", is_open_first = true): return
  gui.widthPush(260.0)

  var placement = [
    cfloat(camera.azimuth), cfloat(camera.elevation), cfloat(camera.distance)
  ]
  if gui.dragFloat("azimuth", addr placement[0], 0.01, 0.0, 0.0):
    camera.azimuth = float(placement[0])
  gui.tooltip("Spin the camera around its target.")
  if gui.dragFloat("elevation", addr placement[1], 0.01,
      cfloat(-ELEVATION_LIMIT), cfloat(ELEVATION_LIMIT)):
    camera.elevation = float(placement[1])
  gui.tooltip("Tilt the camera up or down; clamped short of looking straight up or down.")
  if gui.dragFloat("distance", addr placement[2], 0.05,
      cfloat(DISTANCE_LIMIT_NEAR), cfloat(DISTANCE_LIMIT_FAR)):
    camera.distance = float(placement[2])
  gui.tooltip("Move the camera toward or away from its target.")

  var target = [cfloat(camera.target.x), cfloat(camera.target.y), cfloat(camera.target.z)]
  if gui.dragFloat3("target", addr target[0], SPEED_DRAG*10.0):
    camera.target = Position(x: float(target[0]), y: float(target[1]), z: float(target[2]))
  gui.tooltip("World point the camera looks at and orbits around.")

  var field_of_view = cfloat(camera.degrees_field_of_view)
  if gui.dragFloat("field of view", addr field_of_view, 0.2, 10.0, 120.0):
    camera.degrees_field_of_view = float(field_of_view)
  gui.tooltip("Lens angle; smaller looks through a telephoto, larger through a wide angle.")
  gui.widthPop()

  discard gui.checkbox("world axes", addr workbench.is_axes_shown)
  gui.tooltip("Toggle the red/green/blue x/y/z axis lines through the origin.")
  gui.sameLine()
  discard gui.checkbox("ground grid", addr workbench.is_grid_shown)
  gui.tooltip("Toggle the reference grid at z = 0.")

  gui.separatorText("export")
  gui.widthPush(300.0)
  discard gui.inputText("path", toCstring(workbench.path_export), cint(PATH_MAX))
  gui.tooltip("File `save PNG` and the `S` key both write the current frame to.")
  gui.widthPop()
  if gui.button("save PNG"): workbench.is_export_requested = true



#[ Diagnostics Panel ]#

proc layoutDiagnostics*(workbench: var Workbench; scene: Scene) =
  ## Lay out live performance and memory readouts: closed by default, since nothing here
  ## is needed to use the workbench, only to understand what using it costs.
  if not gui.header("diagnostics", is_open_first = false): return
  gui.text("Live cost of this build, updated every frame.")
  gui.sameLine()
  gui.helpMarker(
    "Nothing on this panel changes what you can do here; it exists so a slow frame or " &
    "a full object pool shows itself directly instead of just feeling wrong."
  )

  gui.separatorText("frame time")
  var highest = 16.6'f32 # Floor the range at 60fps, so a smooth run doesn't zoom in on noise.
  for value in workbench.milliseconds_history:
    if value > highest: highest = value
  var overlay: array[WIDTH_OVERLAY_TEXT, char]
  let text_now = buildChars(overlay):
    appendFixed(overlay, cursor, 1000.0/max(float(gui.framerate()), 1.0), 2)
    appendChars(overlay, cursor, " ms now")
  gui.plotLines(
    "##frame_time", addr workbench.milliseconds_history[0], cint(FRAMES_HISTORY),
    cint(workbench.index_history), text_now, 0.0, highest, 0.0, 60.0,
  )
  gui.tooltip(
    "Milliseconds per drawn frame, oldest at the left and most recent at the right. " &
    "An fps average can hide an occasional slow frame; a spike here cannot."
  )

  discard gui.checkbox("vsync", addr workbench.is_vsync_enabled)
  gui.tooltip(
    "Uncheck to see this build's own uncapped cost rather than the display's own " &
    "refresh rate; the reading below settles over about a second after any change."
  )
  var line: array[WIDTH_ITEM_LINE, char]
  let text_rate = buildChars(line):
    appendInt(line, cursor, int(gui.framerate()))
    appendChars(line, cursor, " fps, ")
    appendFixed(line, cursor, 1000.0/max(gui.framerate(), 1.0), 2)
    appendChars(line, cursor, " ms/frame")
  gui.text(text_rate)
  let text_tessellate = buildChars(line):
    appendChars(line, cursor, "tessellate ")
    appendFixed(line, cursor, workbench.microseconds_tessellate, 1)
    appendChars(line, cursor, " us into ")
    appendInt(line, cursor, workbench.count_vertices)
    appendChars(line, cursor, " vertices")
  gui.text(text_tessellate)

  gui.separatorText("memory")
  block:
    let
      mb_used = float(workbench.bytes_arena_permanent_used) / (1024.0*1024.0)
      mb_capacity = float(workbench.bytes_arena_permanent_capacity) / (1024.0*1024.0)
    var text: array[WIDTH_OVERLAY_TEXT, char]
    let overlay_text = buildChars(text):
      appendFixed(text, cursor, mb_used, 1)
      appendChars(text, cursor, " / ")
      appendFixed(text, cursor, mb_capacity, 0)
      appendChars(text, cursor, " MB")
    gui.text("permanent arena")
    gui.progressBar(
      cfloat(mb_used / max(mb_capacity, 1.0)), overlay_text, 380.0, 0.0,
      0.298, 0.482, 0.929, 0.15, 0.15, 0.18,
    )
    gui.tooltip(
      "Never freed until the process exits: the pixel-export buffer, sized for the " &
      "largest frame this build allows, and every frame of a storyboard's own GIF, " &
      "held until the single call at the end that writes them all out."
    )

  block:
    let
      kb_peak = float(workbench.bytes_arena_frame_peak) / 1024.0
      mb_capacity = float(workbench.bytes_arena_frame_capacity) / (1024.0*1024.0)
    var text: array[WIDTH_OVERLAY_TEXT, char]
    let overlay_text = buildChars(text):
      appendChars(text, cursor, "peak ")
      appendFixed(text, cursor, kb_peak, 0)
      appendChars(text, cursor, " KB / ")
      appendFixed(text, cursor, mb_capacity, 0)
      appendChars(text, cursor, " MB")
    gui.text("frame arena")
    let fraction =
      float(workbench.bytes_arena_frame_peak) /
      max(float(workbench.bytes_arena_frame_capacity), 1.0)
    gui.progressBar(
      cfloat(fraction), overlay_text, 380.0, 0.0, 0.561, 0.737, 0.353, 0.15, 0.15, 0.18,
    )
    gui.tooltip(
      "Reset after every PNG or GIF frame it backs, so it reads empty almost any time " &
      "you would look here; the bar instead holds the largest single export this run " &
      "has needed so far, out of its own fixed reservation."
    )

  gui.separatorText("object pool")
  var are_alive: array[ITEMS_MAX, bool]
  for slot in 0 ..< ITEMS_MAX: are_alive[slot] = scene.isAlive(slot)
  gui.poolBar(addr are_alive[0], cint(ITEMS_MAX), 14.0, 0.298, 0.780, 0.298, 0.15, 0.15, 0.18)
  gui.tooltip(
    "One cell per object slot: lit means it currently holds an object, dark means " &
    "it's free and will be handed to the next one you add, most recently freed first."
  )
  var summary: array[WIDTH_ITEM_LINE, char]
  let text_summary = buildChars(summary):
    appendInt(summary, cursor, scene.len)
    appendChars(summary, cursor, " active, ")
    appendInt(summary, cursor, ITEMS_MAX - scene.len)
    appendChars(summary, cursor, " free")
  gui.text(text_summary)

  const
    BYTES_SCENE = sizeof(Scene)
    BYTES_PER_SLOT = BYTES_SCENE div ITEMS_MAX
  var pool_memory: array[WIDTH_ITEM_LINE, char]
  let text_pool = buildChars(pool_memory):
    appendFixed(pool_memory, cursor, float(BYTES_SCENE) / 1024.0, 1)
    appendChars(pool_memory, cursor, " KB allocated, ")
    appendFixed(pool_memory, cursor, float(scene.len * BYTES_PER_SLOT) / 1024.0, 1)
    appendChars(pool_memory, cursor, " KB used, ")
    appendInt(pool_memory, cursor, BYTES_PER_SLOT)
    appendChars(pool_memory, cursor, " B/slot")
  gui.text(text_pool)
  gui.tooltip(
    "Scene is one fixed block sized for all 64 slots up front, not allocated one " &
    "object at a time: `allocated` is that whole block, `used` is however many slots " &
    "are actually alive right now times the per-slot figure, and `B/slot` is roughly " &
    "what one object's own slot costs -- not a measurement of any single object."
  )

  gui.separatorText("total")
  var total: array[WIDTH_OVERLAY_TEXT, char]
  let text_total = buildChars(total):
    appendFixed(total, cursor, float(workbench.bytes_memory_total) / (1024.0*1024.0), 1)
    appendChars(total, cursor, " MB")
  gui.text(text_total)
  gui.tooltip(
    "Every fixed reservation this binary makes for itself, added up: both arenas at " &
    "their full capacity (committed whether or not they're ever filled), the object " &
    "pool above, tessellation storage, and the panel's own state. Excludes whatever " &
    "Dear ImGui, SDL, or the graphics driver allocate on their own account, which " &
    "this process cannot see or account for."
  )



#[ Whole Workbench ]#

proc layoutWorkbench*(workbench: var Workbench; scene: var Scene; camera: var Camera; now: float) =
  ## Lay out every panel inside one window.
  ##   `now` is this frame's own clock reading, passed through to whichever construct
  ##   control adds an item this frame, so it animates in from the moment it appears.
  gui.windowPlace(16.0, 16.0, WIDTH_PANEL, 720.0)
  if gui.windowBegin("RGA workbench"):
    # Coloured words match the rubber-band drawn while dragging, so the line on screen
    #   names its own outcome before the button is even released.
    gui.text("Drag one object onto another to derive a new one:")
    let (join, meet, project) = (Ink.Cyan.colour, Ink.Coral.colour, Ink.Lime.colour)
    gui.textTinted("  join", join.red, join.green, join.blue)
    gui.sameLine()
    gui.text("left click,")
    gui.sameLine()
    gui.textTinted("meet", meet.red, meet.green, meet.blue)
    gui.sameLine()
    gui.text("right click,")
    gui.sameLine()
    gui.textTinted("project", project.red, project.green, project.blue)
    gui.sameLine()
    gui.text("middle click.")
    gui.text("Drag empty space instead to move the camera: left orbits, right pans, wheel dollies.")
    gui.separator()
    layoutView(workbench, camera)
    layoutConstruct(workbench, scene, now)
    layoutObjects(scene)
    layoutDiagnostics(workbench, scene)
  gui.windowEnd()
