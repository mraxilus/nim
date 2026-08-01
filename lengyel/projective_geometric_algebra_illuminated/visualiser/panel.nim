## Lay out panels user edits scene and camera through.
##
## Workbench holds what the GUI needs between frames and the scene does not own:
## which operands are picked, what point is about to be added, where to export.
##   Everything else is read straight off scene and camera, so there is one source of truth
##   and no synchronisation step.
##
##   |-------------|-------------------------------------------------------------------------|
##   | Panel       | Offers                                                                  |
##   |-------------|-------------------------------------------------------------------------|
##   | Add         | Compose a multivector coefficient by coefficient, previewed as a ghost. |
##   | Diagnostics | Live frame time, vsync, memory use of both arenas, object pool,         |
##   |             | and everything else this binary reserves for itself, added up.          |
##   | Objects     | Save, load, select, show, hide, rename, recolour, remove; edit any      |
##   |             | coefficient.                                                            |
##   | Operate     | Apply any library operation of a chosen arity to picked operands.       |
##   | View        | Orbit, target, lens, world furniture, PNG export.                       |
##   |-------------|-------------------------------------------------------------------------|
##
## Every panel above is a collapsing header, ordered alphabetically and matching the
## browser build's own drawer section for section. Only Objects opens by default: it is
## what a returning session looks at first, and opening all five at once buries the 3D
## view the workbench exists to show.
##
## Coefficients are staged through 32-bit floats because that is what the widget writes,
## and written back only where widget reports a change, so editing costs no precision
## on coefficients the user never touched.
##
## Multivectors are printed by `scene.formatMultivector` rather than by the library's own
## `$`, which writes basis elements in mathematical bold outside the Basic Multilingual
## Plane. No font available to the GUI carries those, so they would draw as empty boxes.
##
## Desktop-only; unreachable from the browser build. See `visualiser.nim`'s own "Render
## Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./[camera, format, gui, history, mesh, objects, scene]



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
  WIDTH_ITEM_LINE = 320
    ## Bound length of one item's shape-and-coefficient line, redrawn every frame. Sized
    ## for the worst case that line can reach: the longest shape word plus all sixteen
    ## basis terms written out, which a mixed-grade object genuinely does print.
  WIDTH_SHAPE_WORD = 32
    ## Bound length of the shape word alone, longest being "mixed grade, nothing to draw".
  WIDTH_COEFFICIENT = 116.0'f32
    ## Set width of one coefficient drag widget, sized so this build's widest grade row
    ## (six grade-2 elements) fits the panel without wrapping mid-grade.
  WIDTH_ITEM_LABEL = 150.0'f32
    ## Set width an item row's own selectable label spans, leaving its three buttons room
    ## to share the same line.
  ALPHA_ITEM_HIDDEN = 0.45'f32
    ## Dim a hidden item's own row to this fraction, matching the browser's own
    ## `.item-row.hidden-item` rule -- present but plainly not drawn right now.
  WIDTH_OVERLAY_TEXT = 48
    ## Bound length of a bar or graph's own overlay text, redrawn every frame.
  FRAMES_HISTORY* {.define: "visualiser.frames_history".} = 240
    ## Bound how many recent per-frame timings the live diagnostics graph keeps; at a
    ## typical frame rate this covers a few seconds, long enough to see a stutter land
    ## and scroll back off, not so long the graph goes stale reading it.



#[ Type Definitions ]#

type
  Workbench* = object ## Hold GUI's own state between frames.
    coefficients_new*: array[Basis, cfloat] ## Multivector the add panel is composing, one
      ## coefficient per basis element -- committed by its own add button, and drawn every
      ## frame until then as a muted ghost (see `is_ghost_shown`). Staged as `cfloat`
      ## because that is what the drag widget writes.
    are_edit_open*: array[ITEMS_MAX, bool] ## Whether each slot's own coefficient editor is
      ## expanded. Held here rather than as a collapsing header's own internal state so the
      ## toggle can be an inline small button beside hide/remove: Dear ImGui's
      ## `CollapsingHeader` spans the full remaining width, which would push those buttons
      ## onto their own line and read as a section rather than a row control.
    is_ghost_shown*: bool ## Whether the add panel's own staged multivector should draw as
      ## a ghost this frame. Set by `layoutMultivectorNew` while its section is open and
      ## some coefficient is non-zero, cleared otherwise; read by
      ## `visualiser.assembleMeshes` later the same frame, so there is no lag.
    index_highlighted*: Option[int] ## Currently selected item's own slot, drawn ringed
      ## by `visualiser.drawSelectionRing` -- auto-selected by every construction path (a
      ## storyboard step, or this session's own last drag-release or apply-operation
      ## click); no explicit "select by clicking" gesture exists on the desktop build
      ## otherwise. Cleared by a successful undo or redo too, since a restored
      ## snapshot's slot numbers may not match whatever was highlighted before. None
      ## where nothing is selected.
    index_operand_first*: cint ## Item picked as left operand.
    index_operand_second*: cint ## Item picked as right operand.
    index_operand_synced_highlight*: Option[int] ## Last `index_highlighted` reading
      ## operand m's own default was synced against -- lets `layoutOperation` re-default
      ## `index_operand_first` to the selected item only the moment selection actually
      ## changes, not every frame: this panel redraws every frame regardless of whether
      ## anything changed, and an unconditional resync would fight a user's own later
      ## manual pick of a different operand right back to whatever is selected. None
      ## until the first sync runs.
    index_operation*: cint ## Operation picked from catalogue.
    index_arity*: cint ## Arity filter the operation picker offers: 0 unary, 1 binary,
      ## matching `Arity`'s own ordinals. Filters which operations the picker lists at all,
      ## rather than offering all 27 and greying the second operand for the unary ones.
    is_grid_shown*: bool ## Whether ground reference grid is drawn.
    is_axes_shown*: bool ## Whether world axes are drawn.
    is_export_requested*: bool ## Whether frame should be written out after drawing.
    is_vsync_enabled*: bool ## Whether swap waits for display refresh before returning.
    microseconds_tessellate*: float ## Cost of rebuilding vertex storage, last frame.
    count_vertices*: int ## Vertices assembled, last frame.
    path_export*: array[PATH_MAX, char] ## Where exported frame is written.
    path_scene*: array[PATH_MAX, char] ## Where scene is saved to and loaded from.
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
  toChars("scene.rgascene", result.path_scene)
  toChars("Ready.", result.message)



#[ Objects Panel ]#

proc layoutCoefficientGrid(staged: var array[Basis, cfloat]): Option[Basis] =
  ## Lay out one drag widget per basis coefficient, stacked one row per grade, 0 to n;
  ## report which coefficient the user changed, if any.
  ##   Grouping by grade rather than wrapping at a fixed column count keeps a grade's own
  ##   members together: in this build's 4D metric the grades hold 1, 4, 6, 4 and 1
  ##   elements, so any fixed column count cuts across a boundary somewhere. Grade comes
  ##   from the library's own `grade`, so nothing here hardcodes a dimension.
  ##   Only one change is reported per frame, which is all a pointer can make.
  gui.widthPush(WIDTH_COEFFICIENT)
  defer: gui.widthPop()
  for g in Grade.low .. Grade.high:
    var is_first_in_row = true
    for b in Basis:
      if b.grade != g: continue
      if not is_first_in_row: gui.sameLine()
      is_first_in_row = false
      if gui.dragFloat(cstring(lut_basis_to_name[b]), addr staged[b], SPEED_DRAG, 0.0, 0.0):
        result = some(b)


proc layoutItem(
  workbench: var Workbench; scene: var Scene; history: var History; slot: int
): bool =
  ## Lay out one item's controls, by slot; report whether user asked for it to be removed.
  ##   A hidden item's whole row dims rather than disappearing, so it stays readable and
  ##   its own show button stays clickable -- `alphaPush`, not `disabledPush`.
  gui.idPush(cint(slot))
  defer: gui.idPop()

  let
    item = scene[slot]
    tint = item.ink.colour
    is_visible = scene.isVisible(slot)
  if not is_visible: gui.alphaPush(ALPHA_ITEM_HIDDEN)
  defer:
    if not is_visible: gui.alphaPop()

  # Row selects on click, the way the browser's own row does, and shows which item the
  #   ring in the 3D view is currently drawn around.
  gui.textColorPush(tint.red, tint.green, tint.blue)
  let is_selected = workbench.index_highlighted == some(slot)
  if gui.selectable(toCstring(scene.labelAt(slot)), is_selected, WIDTH_ITEM_LABEL):
    workbench.index_highlighted = if is_selected: none(int) else: some(slot)
  gui.textColorPop()
  gui.tooltip("Select this object; the 3D view rings whatever is selected.")

  gui.sameLine()
  if gui.buttonSmall(if is_visible: cstring"hide" else: cstring"show"):
    scene.setVisible(slot, not is_visible)
    history.record(scene)
  gui.tooltip("Show or hide this object without removing it.")
  gui.sameLine()
  if gui.buttonSmall(if workbench.are_edit_open[slot]: cstring"close" else: cstring"edit"):
    workbench.are_edit_open[slot] = not workbench.are_edit_open[slot]
  gui.tooltip("Rename, recolour, or reshape this object coefficient by coefficient.")
  gui.sameLine()
  result = gui.buttonSmall("remove")
  gui.tooltip("Delete this object; its slot is reused by the next one you add.")

  # Built into a stack buffer rather than a `string`, since every visible item redraws
  #   this line every frame; a fresh heap string per item per frame is exactly the kind
  #   of allocator churn an arena-backed scene should not turn around and reintroduce.
  #   Shape word first on the same line as the coefficients, matching the browser's own
  #   `point: 3e1 - 2e2 ...` -- two separate lines doubled every row's height for a word
  #   that reads as a prefix to the equation anyway.
  var line: array[WIDTH_ITEM_LINE, char]
  let description = buildChars(line):
    appendChars(line, cursor, "  ")
    describeShape(item.geometry, line, cursor)
    appendChars(line, cursor, ": ")
    formatMultivector(item.geometry, line, cursor)
  gui.textWrapped(description)

  if workbench.are_edit_open[slot]:
    gui.widthPush(220.0)
    discard gui.inputText("label", toCstring(scene.labelAt(slot)), cint(LABEL_MAX))
    var index_ink = cint(item.ink)
    if gui.combo("colour", addr index_ink, addr lut_ink_to_name[Ink.low], cint(COUNT_INK)):
      scene.setInk(slot, Ink(index_ink))
      history.record(scene)
    gui.widthPop()
    gui.text("Coefficients:")
    gui.sameLine()
    gui.helpMarker(
      "The 16 numbers of this RGA object's own multivector, in the library's basis " &
      "order, stacked one row per grade; drag any one to reshape the object directly."
    )
    var staged: array[Basis, cfloat]
    for b in Basis: staged[b] = cfloat(scene.geometryAt(slot)[b])
    let changed = layoutCoefficientGrid(staged)
    if changed.isSome:
      scene.geometryAt(slot)[changed.get] = float(staged[changed.get])
  gui.separator()


proc layoutObjects*(workbench: var Workbench; scene: var Scene; history: var History) =
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

  gui.widthPush(300.0)
  discard gui.inputText("path", toCstring(workbench.path_scene), cint(PATH_MAX))
  gui.tooltip("File `save scene` writes to and `load scene` reads from.")
  gui.widthPop()
  if gui.button("save scene"):
    toChars(saveScene(scene, $toCstring(workbench.path_scene)), workbench.message)
  gui.sameLine()
  if gui.button("load scene"):
    toChars(loadScene(scene, $toCstring(workbench.path_scene)), workbench.message)
  gui.separator()

  if scene.len == 0:
    gui.text("Nothing here yet -- add a multivector above, or drag between two objects.")
    return

  # Most recently added first, matching the browser's own list order: the object just
  #   built is the one a user is looking for, and it would otherwise sit at whatever
  #   position the free list happened to hand out.
  var
    slots_ordered: array[ITEMS_MAX, int]
    count = 0
  for slot, _ in scene.pairs:
    var position = count
    while position > 0 and scene[slots_ordered[position - 1]].born < scene[slot].born:
      slots_ordered[position] = slots_ordered[position - 1]
      dec position
    slots_ordered[position] = slot
    inc count

  var slot_removed = none(int)
  for position in 0 ..< count:
    let slot = slots_ordered[position]
    if layoutItem(workbench, scene, history, slot): slot_removed = some(slot)
  if slot_removed.isSome:
    scene.removeItem(slot_removed.get)
    if workbench.index_highlighted == slot_removed: workbench.index_highlighted = none(int)
    history.record(scene)



#[ Construct Panel ]#

proc layoutMultivectorNew*(
  workbench: var Workbench; scene: var Scene; history: var History; now: float
) =
  ## Lay out controls that compose and add a fresh multivector, one coefficient per basis
  ## element.
  ##   Adds any multivector rather than only a point, matching what the operation
  ##   catalogue below can already derive: a point was never a special case the scene
  ##   itself recognised, only what the old three-field position widget could express.
  ##   Sets `is_ghost_shown` while composing, so the not-yet-committed object draws muted
  ##   in the 3D view the moment any coefficient goes non-zero, and stops the moment this
  ##   section closes or the object commits.
  workbench.is_ghost_shown = false
  if not gui.header("add", is_open_first = false): return

  gui.text("The 16 numbers of a fresh multivector, in the library's basis order.")
  gui.sameLine()
  gui.helpMarker(
    "Stacked one row per grade: a scalar, then this build's four grade-1 elements, and " &
    "so on. A live preview draws in the view as soon as any field goes non-zero; " &
    "nothing joins the scene until you add it below."
  )
  discard layoutCoefficientGrid(workbench.coefficients_new)

  for b in Basis:
    if workbench.coefficients_new[b] != 0.0:
      workbench.is_ghost_shown = true
      break

  gui.disabledPush(scene.isFull)
  if gui.button("add multivector"):
    var geometry: Multivector
    for b in Basis: geometry[b] = float(workbench.coefficients_new[b])
    let slot = scene.addItem(geometry, &"m{scene.len}", inkCycled(scene.len), now)
    workbench.index_highlighted = some(slot)
    history.record(scene)

    var shape_word: array[WIDTH_SHAPE_WORD, char]
    var cursor_shape = 0
    describeShape(geometry, shape_word, cursor_shape)
    finishChars(shape_word, cursor_shape)
    toChars(&"Added {$toCstring(shape_word)}.", workbench.message)

    # Committing clears the composer, the same way the browser's own add section resets
    #   its sixteen fields -- and with them the ghost, now that a real object stands in
    #   its place.
    for b in Basis: workbench.coefficients_new[b] = 0.0
    workbench.is_ghost_shown = false
  gui.disabledPop()
  gui.tooltip("Commit the multivector above as a new object in the scene.")


proc layoutOperation*(
  workbench: var Workbench; scene: var Scene; history: var History; now: float
) =
  ## Lay out controls that derive fresh object by applying library operation to operands.
  if not gui.header("operate", is_open_first = false): return
  if scene.len == 0:
    gui.text("Scene is empty; add a multivector first.")
    return

  # Offer every live item by label, so operands are picked by name rather than by slot;
  #   `slots` translates the combo's dense position back to the slot it names.
  var
    names: array[ITEMS_MAX, cstring]
    slots: array[ITEMS_MAX, int]
    count = 0
  for slot, _ in scene.pairs:
    names[count] = toCstring(scene.labelAt(slot))
    slots[count] = slot
    inc count

  # Operand m defaults to whatever is currently selected, but only right when
  #   selection itself changes -- see `index_operand_synced_highlight`'s own doc.
  if workbench.index_highlighted != workbench.index_operand_synced_highlight:
    workbench.index_operand_synced_highlight = workbench.index_highlighted
    if workbench.index_highlighted.isSome:
      let slot_selected = workbench.index_highlighted.get
      for pos in 0 ..< count:
        if slots[pos] == slot_selected:
          workbench.index_operand_first = cint(pos)
          break

  # Offer only the operations of the chosen arity, rather than all of them with the
  #   second operand greyed out for the unary ones: the catalogue is long enough that
  #   halving it is the difference between scanning and hunting. `operations` translates
  #   the filtered combo's dense position back to the operation it names, the same shape
  #   `slots` uses for operands above.
  var
    notations: array[COUNT_OPERATION, cstring]
    operations: array[COUNT_OPERATION, Operation]
    count_offered = 0
  let arity_wanted = Arity(workbench.index_arity)
  for operation in Operation:
    if lut_operation_to_arity[operation] != arity_wanted: continue
    notations[count_offered] = lut_operation_to_notation[operation]
    operations[count_offered] = operation
    inc count_offered

  gui.widthPush(300.0)
  const lut_arity_to_name = [Arity.One: cstring"unary", Arity.Two: cstring"binary"]
  if gui.combo("arity", addr workbench.index_arity, addr lut_arity_to_name[Arity.low], 2):
    workbench.index_operation = 0
  gui.tooltip("Whether to list operations reading one operand or two.")

  let index_offered = clamp(int(workbench.index_operation), 0, count_offered - 1)
  workbench.index_operation = cint(index_offered)
  discard gui.combo(
    "operation", addr workbench.index_operation, addr notations[0], cint(count_offered),
  )
  gui.tooltip("Library operation to apply below; its own notation names m and n, " &
    "the operands picked next.")
  let
    operation = operations[clamp(int(workbench.index_operation), 0, count_offered - 1)]
    is_binary = arity_wanted == Arity.Two

  discard gui.combo("operand m", addr workbench.index_operand_first,
    addr names[0], cint(count))
  gui.tooltip("First operand -- `m` in the notation above -- every operation reads.")
  if is_binary:
    discard gui.combo("operand n", addr workbench.index_operand_second,
      addr names[0], cint(count))
    gui.tooltip("Second operand -- `n` above -- this operation combines with `m`.")
  gui.widthPop()

  gui.disabledPush(scene.isFull)
  if gui.button("apply"):
    let
      first = slots[clamp(int(workbench.index_operand_first), 0, count - 1)]
      second =
        if is_binary: slots[clamp(int(workbench.index_operand_second), 0, count - 1)]
        else: first # A unary operation ignores its second operand; naming the first
          # keeps a stale picker reading from ever reaching `applyOperation`.
      operand_first = scene[first].geometry
      operand_second = scene[second].geometry
      derived = applyOperation(operation, operand_first, operand_second)
      anchor = creationAnchor(operation, operand_first, operand_second, derived)
      name_first = $toCstring(scene.labelAt(first))
      name_second = $toCstring(scene.labelAt(second))
      label = notationSubstituted(operation, name_first, name_second)
    workbench.index_highlighted =
      some(scene.addItem(derived, label, inkCycled(scene.len), now, anchor))
    history.record(scene)

    var shape_word: array[WIDTH_SHAPE_WORD, char]
    var cursor_shape = 0
    describeShape(derived, shape_word, cursor_shape)
    finishChars(shape_word, cursor_shape)
    toChars(&"{label} gave {$toCstring(shape_word)}.", workbench.message)
  gui.disabledPop()





#[ View Panel ]#

proc layoutView*(workbench: var Workbench; camera: var Camera) =
  ## Lay out camera placement, world furniture and frame export.
  if not gui.header("view", is_open_first = false): return
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

proc layoutDiagnosticsFrameTime(workbench: var Workbench) =
  ## Lay out the "frame time" section: rolling frame-time plot, vsync toggle, current
  ## rate, tessellation cost.
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


proc layoutDiagnosticsMemory(workbench: Workbench) =
  ## Lay out the "memory" section: permanent and per-frame arena usage bars.
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


proc layoutDiagnosticsObjectPool(scene: Scene) =
  ## Lay out the "object pool" section: live/free slot strip and byte accounting.
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


proc layoutDiagnosticsTotal(workbench: Workbench) =
  ## Lay out the "total" section: every fixed reservation this binary makes, added up.
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

  layoutDiagnosticsFrameTime(workbench)
  layoutDiagnosticsMemory(workbench)
  layoutDiagnosticsObjectPool(scene)
  layoutDiagnosticsTotal(workbench)



#[ Whole Workbench ]#

proc layoutWorkbench*(
  workbench: var Workbench; scene: var Scene; camera: var Camera; history: var History; now: float
) =
  ## Lay out every panel inside one window.
  ##   `now` is this frame's own clock reading, passed through to whichever construct
  ##   control adds an item this frame, so it animates in from the moment it appears.
  gui.windowPlace(16.0, 16.0, WIDTH_PANEL, 720.0)
  if gui.windowBegin("RGA workbench"):
    # Coloured words match the rubber-band drawn while dragging, so the line on screen
    #   names its own outcome before the button is even released.
    gui.text("Drag one object onto another to derive a new one:")
    let (join, meet, project) = (Ink.Jade.colour, Ink.Magenta.colour, Ink.Olive.colour)
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

    # Scene-content edits only (add, apply, remove, visibility, recolour) -- label text
    #   and coefficient drags are continuous, multi-frame inputs with no clean "edit
    #   committed" boundary, so neither is on this timeline; see `history.nim`.
    #   Each button greys out where its own side of the timeline is empty, rather than
    #   staying live and reporting "nothing to undo" only once pressed.
    gui.disabledPush(not history.canUndo)
    if gui.button("undo"):
      if history.undo(scene): workbench.index_highlighted = none(int)
    gui.disabledPop()
    gui.tooltip("Step back through scene-content edits; camera moves are not on this timeline.")
    gui.sameLine()
    gui.disabledPush(not history.canRedo)
    if gui.button("redo"):
      if history.redo(scene): workbench.index_highlighted = none(int)
    gui.disabledPop()
    gui.tooltip("Step forward again; a fresh edit discards whatever was ahead.")
    gui.separator()

    # Sections in alphabetical order, matching the browser's own drawer, with `objects`
    #   the one open by default: it is what a returning session looks at first, and the
    #   rest are reached for deliberately.
    layoutMultivectorNew(workbench, scene, history, now)
    layoutDiagnostics(workbench, scene)
    layoutObjects(workbench, scene, history)
    layoutOperation(workbench, scene, history, now)
    layoutView(workbench, camera)
    gui.separator()
    gui.text(toCstring(workbench.message))
  gui.windowEnd()
