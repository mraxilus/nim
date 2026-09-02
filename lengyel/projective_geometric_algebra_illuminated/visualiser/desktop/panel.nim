## Lay out panels user edits scene and camera through.
##
## Panel holds what GUI needs between frames and scene does not own: which operands are
## picked, what open edit is staging, where to export. Everything else is read straight
## off scene and camera, so there is one source of truth and no synchronisation step.
##
##   |-------------|-------------------------------------------------------------------------|
##   | Panel       | Offers                                                                  |
##   |-------------|-------------------------------------------------------------------------|
##   | Top bar     | Start new object, toggle world furniture, save or load scene.           |
##   | Apply       | Apply any library operation of chosen arity to picked operands, both of |
##   |             | which current selection fills in.                                       |
##   | Diagnostics | Live frame time, vsync, memory use of both arenas, object pool, and     |
##   |             | everything else this binary reserves for itself, added up.              |
##   | Objects     | Select, show, hide, remove; edit any object's label, colour and         |
##   |             | coefficients through one staged session, shared with composing new one. |
##   | View        | Orbit, target, lens, PNG export.                                        |
##   |-------------|-------------------------------------------------------------------------|
##
## Every panel except top bar is collapsing header, ordered alphabetically and matching
## browser drawer section for section. Top bar sits outside them all, because its `add`
## button has to open Objects. Only Objects opens by default: what returning session looks
## at first, and opening all four buries 3D view.
##
## Coefficients are staged through 32-bit floats because that is what widget writes, and
## written back only where widget reports change, so editing costs no precision on
## untouched coefficients.
##
## Multivectors are printed by `scene.formatMultivector` rather than library's `$`, which
## returns fresh heap `string` once per visible item per frame. Atlas carries mathematical
## bold and subscript blocks library writes basis elements in.
##
## Desktop-only; unreachable from browser build. See `visualiser.nim`'s "Render Paths".

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../../pga
import ./gui
import ../core/[boundary, camera, format, help, history, interaction, tessellate, scene, selection]



#[ Panel Configuration ]#

const
  MESSAGE_MAX* = 96
    ## Bound length of outcome reported after action.
  PATH_MAX* = 256
    ## Bound length of export path user may type.
  WIDTH_PANEL* = 440.0'f32
    ## Set width panels open at, in pixels: wide enough that six coefficient cells share
    ## one line, close to browser drawer's 400. Opening editor must not resize window, so
    ## this holds whether or not one is open.
  SPEED_DRAG* = 0.01'f32
    ## Set how fast coefficient moves per pixel dragged.
  WIDTH_ITEM_LINE = WIDTH_SHAPE_WORD + WIDTH_MULTIVECTOR
    ## Bound one item's shape-and-coefficient line in *bytes*, redrawn every frame. Sized
    ## from what two printers filling it declare: shape word then whole multivector, and
    ## mixed-grade object prints every basis term.
  COEFFICIENTS_PER_ROW = 6
    ## Wrap grade's elements after this many. In 4D metric largest grade holds exactly six,
    ## so every grade fits one line and grid matches browser's grade row. Wrap point, not
    ## divisor: line's cells share line between however many are on it.
  INK_LABEL = Rgba(red: 0.357, green: 0.400, blue: 0.451, alpha: 1.0)
    ## Draw control's name in this, browser's `--ink-faint`: name is read once, value
    ## beside it keeps changing.
  WIDTH_ITEM_LABEL = 150.0'f32
    ## Set width item row's selectable label spans, leaving three buttons room on line.
  ALPHA_ITEM_HIDDEN = 0.45'f32
    ## Dim hidden item's row to this fraction, matching browser's `.item-row.hidden-item`.
  HELP_COEFFICIENTS_PENDING: cstring =
    "The 16 numbers of the new multivector, in the library's basis order, stacked one " &
    "row per grade. A live preview draws as soon as any goes non-zero; nothing joins " &
    "the scene until you save."
    ## Explain coefficient grid while composing new object.
  HELP_COEFFICIENTS_EDITING: cstring =
    "The 16 numbers of this object's own multivector, in the library's basis order, " &
    "stacked one row per grade. The object itself only moves when you save."
    ## Explain coefficient grid while editing existing object.
  WIDTH_LABEL_FIELD = 96.0'f32
    ## Reserve room to right of field for its label, which Dear ImGui draws there.
  SPACING_SEGMENT = 8.0'f32
    ## Separate segments of segmented control, matching gap `sameLine` leaves.
  WIDTH_OVERLAY_TEXT = 48
    ## Bound length of bar or graph's overlay text, redrawn every frame.
  SIZES_POOL_CELL = [14.0'f32, 10.0'f32, 6.0'f32, 4.0'f32, 3.0'f32, 2.0'f32]
    ## Offer sides one object-pool cell may take, in pixels, largest first.
    ##   **Chosen against capacity, not fixed.** 14 was right at 64 slots; at 1,024 that
    ## cell wraps to ~37 rows and 555 px, off bottom of panel. `sizePoolCell` picks largest
    ## that fits `HEIGHT_POOL_MAX`, same rule browser's `CELLS_POOL` follows. Checked by
    ## rendering: at 14 grid genuinely ran off panel.

  SPACING_POOL_CELL = 1.0'f32
    ## How much `gui.poolBar` leaves between two cells, in pixels; see its shim.

  HEIGHT_POOL_MAX = 150.0'f32
    ## Bound how tall object-pool grid may be, in pixels: block taken in at glance beside
    ## memory bars, not page to scroll past.
  CHANNELS_POOL_CELL = 3
    ## Count floats one pool cell contributes to `gui.poolBar`'s buffer: red, green, blue,
    ## no alpha, since every cell is opaque.
  INK_POOL_FREE = Ink.Grid
    ## Draw free object-pool slot in palette's recessive furniture colour.
  FRAMES_HISTORY* {.define: "visualiser.frames_history".} = 240
    ## Bound how many recent per-frame timings live diagnostics graph keeps: few seconds,
    ## long enough to see stutter land and scroll off.



#[ Type Definitions ]#

type
  EditSession* = object ## Hold what open edit is staging, before any of it reaches scene.
    ## One session at time, in one of two modes; see `slot`.
    slot*: Option[int] ## Item being edited. None while composing brand-new object.
    coefficients*: array[Basis, cfloat] ## Staged multivector, one per basis element, drawn
      ## every frame as muted ghost. `cfloat` because that is what drag widget writes.
    label*: array[LABEL_MAX, char] ## Staged label. Staged because `gui.inputText` writes
      ## straight through pointer, and scene's buffer must not change before save.
    index_ink*: cint ## Staged palette slot.

  ItemRow* = object ## Hold what one object row has resolved about itself.
    ## Computed once at top of `layoutItem` and handed to each part of row, so three agree.
    slot*: Option[int] ## Item backing row. None for composing row.
    is_open*: bool ## Whether this row's edit session is one open.
    is_visible*: bool ## Whether object is shown in 3D view.
    tint*: Rgba ## Colour row's name draws in; staged where session is open, so recolouring
      ## previews itself.

  Panel* = object ## Hold GUI's state between frames.
    is_help_open*: bool ## Whether help panel is showing. Closed at startup: reference that
      ## opens itself is one returning user closes every session.
    session*: Option[EditSession] ## Edit in progress, if any. Its staged multivector is
      ## what `visualiser.assembleMeshes` draws as ghost, read later in same frame.
    preview*: Option[Preview] ## What open **apply** control would build, ghosted while
      ## reader is choosing, as drag's rubber-band does.
      ##   Written by whichever apply control is on screen, cleared at top of every frame
      ## by `layoutPanel`: closed section never writes, which is whole of "shown while
      ## choosing".
      ##   **Loses to `session`** where both stand: session is being typed into. Its
      ## `Preview.operands` has camera frame result beside its objects; see
      ## `framing.watched`.
    selection*: Selection ## Items picked right now, in pick order, each ringed by
      ## `visualiser.drawSelectionRing`. Picked through row's checkbox (toggles) or name
      ## (picks alone), replaced by every construction path. Cleared by successful undo or
      ## redo, since restored snapshot's slot numbers may not match.
    tween_camera*: CameraTween ## Carries camera toward whatever is being built or edited;
      ## see `camera.CameraTween`. Advanced once per frame by `visualiser.renderFrame`.
    slots_ordered*: array[ITEMS_MAX, int] ## Live slots in creation order, as
      ## `scene.slotsCreated` fills them; valid to `count_ordered`.
    count_ordered*: int ## How many of `slots_ordered` are filled.
    revision_ordered*: Option[int] ## `scene.revision` order was sorted at; none before
      ## first layout.
    index_operand_first*: cint ## Item picked as left operand.
    index_operand_second*: cint ## Item picked as right operand.
    revision_selection_synced*: int ## `selection.revision` apply controls were defaulted
      ## against, so `layoutApply` re-derives arity and operands only when selection
      ## changes: panel redraws every frame, and unconditional resync would fight reader's
      ## later manual pick.
    operations*: OperationMemory ## Which operation each arity's picker opens on, carried
      ## from last apply.
    index_operation*: cint ## Operation picked from catalogue.
    index_arity*: cint ## Arity filter operation picker offers: 0 unary, 1 binary, matching
      ## `Arity`'s ordinals. Filters list rather than greying second operand.
    is_menu_selection_shown*: bool ## Whether floating selection menu is on screen; see
      ## `layoutSelectionMenu`. Not derived from selection being non-empty: every
      ## construction leaves result selected, and menu over each new object would sit in
      ## way of next drag. Raised by gestures that *pick*, lowered by ones that build, as
      ## browser's `refreshSelectionMenu`/`adoptConstructionSelection` pair does.
    is_menu_selection_picking*: bool ## Whether that menu's operation picker is revealed,
      ## which its `apply` button opens before committing.
    position_menu_selection*: array[2, cfloat] ## Where that menu sits, in window pixels.
      ## Kept between frames: object it follows can pass behind camera, and menu that
      ## vanished for those frames would be worse than one staying put.
    index_operation_menu*: cint ## Operation picked in that menu. Own reading: section's
      ## list is indexed per arity reader chose *there*, menu's is always arity selection
      ## implies.
    is_grid_shown*: bool ## Whether ground reference grid is drawn.
    is_axes_shown*: bool ## Whether world axes are drawn.
    is_algebra_shown*: bool ## Whether algebra's debug layer is drawn over scene: every
      ## multivector frame computed, in true form. Off by default; see `algebra_view`.
    is_export_requested*: bool ## Whether frame should be written out after drawing.
    is_undo_requested*, is_redo_requested*: bool ## Whether key asked to step timeline. Set
      ## by key handler and consumed right after layout: `handleEvent` has no `History`,
      ## and routing button and key through one call stops them drifting.
    is_vsync_enabled*: bool ## Whether swap waits for display refresh before returning.
    microseconds_tessellate*: float ## Cost of rebuilding vertex storage, last frame.
    count_vertices*: int ## Vertices assembled, last frame.
    path_export*: array[PATH_MAX, char] ## Where exported frame is written.
    path_scene*: array[PATH_MAX, char] ## Where scene is saved to and loaded from.
    message*: array[MESSAGE_MAX, char] ## Outcome of last action taken.
    milliseconds_history*: array[FRAMES_HISTORY, cfloat] ## Ring buffer of recent frame
      ## times, oldest to newest by `index_history`; nothing outside panel reads it.
    index_history*: int ## Next slot in `milliseconds_history` fresh reading overwrites.
    bytes_arena_permanent_used*: int ## Snapshot of permanent arena's `used`.
    bytes_arena_permanent_capacity*: int ## Snapshot of permanent arena's `capacity`.
    bytes_arena_frame_peak*: int ## Snapshot of frame arena's `peakUsed`.
    bytes_arena_frame_capacity*: int ## Snapshot of frame arena's `capacity`.
    bytes_memory_total*: int ## Sum of every fixed reservation this binary makes; computed
      ## where every piece is visible, since `panel` cannot see arenas' backing storage.


func initPanel*(path_export: string): Panel =
  ## Construct panel with world furniture shown and export aimed at `path_export`.
  result.is_grid_shown = true
  result.is_axes_shown = true
  result.is_algebra_shown = false
  result.is_vsync_enabled = true
  toChars(path_export, result.path_export)
  toChars("scene.rgascene", result.path_scene)
  toChars("Ready.", result.message)


func isPending*(row: ItemRow): bool = row.slot.isNone
  ## Report whether row is composing object that does not exist yet.


func showSelectionMenu*(panel: var Panel) =
  ## Bring floating selection menu up over whatever is picked, closed on picker.
  ##   Every gesture that *picks* calls this; every gesture that *builds* calls
  ## `hideSelectionMenu`.
  panel.is_menu_selection_shown = true
  panel.is_menu_selection_picking = false


func hideSelectionMenu*(panel: var Panel) =
  ## Put floating selection menu away, leaving selection alone.
  panel.is_menu_selection_shown = false
  panel.is_menu_selection_picking = false


func geometry*(session: EditSession): Multivector =
  ## Read what session is staging, as multivector saving it would commit.
  ##   Coefficients are `cfloat`, so every reader needs this widening; written out at each
  ## of four readers, one drifting was matter of time.
  for b in Basis: result[b] = float(session.coefficients[b])


proc stage*(session: var EditSession; geometry: Multivector) =
  ## Load multivector into session, as values its widgets edit.
  ##   Inverse of `geometry`, and only other place two representations meet.
  for b in Basis: session.coefficients[b] = cfloat(geometry[b])
func staged*(panel: Panel): Option[Preview] =
  ## Resolve what this panel offers as not-yet-committed: open edit session's geometry,
  ## else whatever apply control is previewing, else nothing.
  ##   **Session wins**: session is being typed into, preview is passive reading of two
  ## pickers. Sibling is `browser_bridge.staged`; fix both or neither.
  if panel.session.isSome: return some(previewStaging(panel.session.get.geometry))
  panel.preview




#[ Field Layout ]#

proc widthPushField() =
  ## Size controls that follow to whatever line has left once their names have taken their
  ## column, so field ends flush with panel's right edge at any width.
  ##   Fixed widths were tuned against panel that changed width twice, each time leaving
  ## some field short of edge.
  gui.widthPush(gui.contentWidth() - WIDTH_LABEL_FIELD)


proc fieldLabel(name: cstring) =
  ## Name control, to its left, and leave line open for control itself.
  ##   Dear ImGui draws widget's label to its *right*, which reads backwards. Every control
  ## below gets hidden ImGui label (`##name`) and its name is written here first.
  ## `sameLineAt` puts every control in one column.
  gui.textTinted(name, INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue)
  gui.sameLineAt(WIDTH_LABEL_FIELD)



#[ Objects Panel ]#

proc layoutCoefficientGrid(staged: var array[Basis, cfloat]): Option[Basis] =
  ## Lay out one drag widget per basis coefficient, each under its basis name, at most six
  ## per line, each grade starting fresh line; report which coefficient changed.
  ##   Grade comes from library's `grade`, so nothing hardcodes dimension. In 4D grades
  ## hold 1, 4, 6, 4 and 1 elements, each fitting one line.
  ##   Name above cell, matching browser's `.coeff-grid`: beside costs every cell width of
  ## longest name, which forced panel out to 680 px.
  ##   Cells divide line they are on rather than fixed sixth, so grade fills its row;
  ## browser's `flex: 1 1 56px` written out.
  ##   `groupBegin`/`groupEnd` makes name and widget advance `sameLine` as one item.
  ##   Only one change is reported per frame, which is all pointer can make.
  # Read once, before anything is placed: `contentWidth` reports what is left on current
  #   line.
  let width_content = gui.contentWidth()
  for g in Grade.low .. Grade.high:
    var count_grade = 0
    for b in Basis:
      if b.grade == g: inc count_grade
    var placed = 0
    for b in Basis:
      if b.grade != g: continue
      let
        column = placed mod COEFFICIENTS_PER_ROW
        count_line = min(COEFFICIENTS_PER_ROW, count_grade - (placed - column))
        width_cell =
          (width_content - float32(count_line - 1)*SPACING_SEGMENT)/float32(count_line)
      if column > 0: gui.sameLine()
      gui.groupBegin()
      gui.widthPush(width_cell)
      # Name recedes and number reads. Matches browser, where label is `--ink-faint`.
      gui.textTinted(
        cstring(lut_basis_to_name[b]), INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue
      )
      if gui.dragFloat(
        cstring("##" & lut_basis_to_name[b]), addr staged[b], SPEED_DRAG, 0.0, 0.0
      ):
        result = some(b)
      gui.widthPop()
      gui.groupEnd()
      inc placed


proc beginSession(panel: var Panel; scene: var Scene; slot: Option[int]) =
  ## Open edit session against `slot`, or composing one where slot is none.
  ##   Composing session starts on same auto-label and cycled ink every other construction
  ## path assigns, both editable before object exists.
  ##   Does not aim camera: session's staged geometry is offered to tween every frame by
  ## `layoutObjects`.
  var session = EditSession(slot: slot)
  if slot.isSome:
    session.stage(scene.geometryOf(slot.get))
    session.label = scene.labelAt(slot.get)
    session.index_ink = cint(scene.inkAt(slot.get))
  else:
    toChars(&"m{scene.len}", session.label)
    session.index_ink = cint(scene.inkNext)
  panel.session = some(session)


proc layoutSessionFields(panel: var Panel; is_pending: bool) =
  ## Lay out label, colour and coefficient controls open session stages.
  ##   Everything writes into session, never scene; nothing lands until save.
  widthPushField()
  fieldLabel("label")
  discard gui.inputText("##label", toCstring(panel.session.get.label), cint(LABEL_MAX))
  # Offer categorical run alone: structural slots belong to furniture, and combo counts
  #   positions within run. Names come from shared table at its offset, since run is
  #   contiguous; see `tessellate.COUNT_INK_CATEGORICAL`.
  var index_categorical = cint(categoricalIndex(Ink(panel.session.get.index_ink)))
  fieldLabel("colour")
  if gui.combo(
    "##colour", addr index_categorical,
    addr lut_ink_to_name[INK_CATEGORICAL_FIRST], cint(COUNT_INK_CATEGORICAL),
  ):
    panel.session.get.index_ink = cint(ord(inkCategorical(int(index_categorical))))
  gui.widthPop()
  gui.textTinted("coefficients", INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue)
  gui.sameLine()
  gui.helpMarker(
    if is_pending: HELP_COEFFICIENTS_PENDING else: HELP_COEFFICIENTS_EDITING
  )
  discard layoutCoefficientGrid(panel.session.get.coefficients)


proc layoutItemName(panel: var Panel; scene: var Scene; row: ItemRow) =
  ## Lay out row's leading checkbox and its name.
  ##   Checkbox toggles membership, as browser's row checkbox does, so second and third
  ## object join in pick order, which names operands m and n. Name picks that one alone:
  ## browser gets single-select from canvas click, which this build has no equivalent of.
  var is_selected = (not row.isPending) and row.slot.get in panel.selection
  gui.disabledPush(row.isPending) # Nothing to select until it exists.
  if gui.checkbox("", addr is_selected):
    panel.selection.toggle(row.slot.get)
    panel.showSelectionMenu() # Picking from list is picking.
  gui.disabledPop()
  gui.tooltip("Add this object to the selection, or drop it; the 3D view rings each one.")
  gui.sameLine()

  let label_shown =
    if row.is_open: toCstring(panel.session.get.label)
    else: toCstring(scene.labelAt(row.slot.get))
  gui.textColorPush(row.tint.red, row.tint.green, row.tint.blue)
  if gui.selectable(label_shown, is_selected, WIDTH_ITEM_LABEL) and not row.isPending:
    if is_selected and panel.selection.len == 1: panel.selection.clear()
    else: panel.selection.selectOnly(row.slot.get)
    panel.showSelectionMenu()
  gui.textColorPop()


proc layoutItemButtons(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  row: ItemRow; now: float
): bool =
  ## Lay out row's actions; report whether user asked for object to go.
  ##   Longer than sixty-line default: run's whole width has to be measured before any of
  ## it is placed, so buttons cannot move out without measuring twice.
  ##   Buttons end flush against panel's right edge, as browser's row does, forming one
  ## column down list. `buttonSmallWidth` measures run first.
  let
    label_commit = if row.is_open: cstring"save" else: cstring"edit"
    width_buttons =
      gui.buttonSmallWidth(label_commit) +
      (if row.is_open: gui.buttonSmallWidth("✕") + SPACING_SEGMENT else: 0.0'f32) +
      (
        if row.isPending or row.is_open: 0.0'f32
        else:
          gui.buttonSmallWidth(if row.is_visible: cstring"hide" else: cstring"show") +
          gui.buttonSmallWidth("remove") + 2.0'f32*SPACING_SEGMENT
      )
  gui.alignRight(width_buttons)
  if gui.buttonSmall(label_commit):
    if not row.is_open:
      beginSession(panel, scene, row.slot)
    else:
      let session = panel.session.get
      let geometry = session.geometry
      if row.isPending:
        let slot_added =
          scene.addItem(geometry, toText(session.label), Ink(session.index_ink), now)
        panel.selection.selectOnly(slot_added)
      else:
        scene.setGeometryAt(row.slot.get, geometry)
        scene.labelAt(row.slot.get) = session.label
        scene.setInk(row.slot.get, Ink(session.index_ink))
      history.record(scene, camera)
      panel.session = none(EditSession)
  gui.tooltip(
    if row.is_open: cstring"Commit these values to the scene."
    else: cstring"Rename, recolour or reshape this object; nothing changes until you save."
  )

  if row.is_open:
    # Abandon: composing row vanishes with nothing added, editing row reverts. Scene was
    #   never touched, so this only drops session.
    gui.sameLine()
    if gui.buttonSmall("✕"): panel.session = none(EditSession)
    gui.tooltip(
      if row.isPending: cstring"Discard this new object."
      else: cstring"Discard these changes."
    )

  # Hide and remove act on object as scene holds it, which open session is staging
  #   replacement for; offering them mid-edit invites acting on one version while looking
  #   at another. Absent for composing row, whose object does not exist yet.
  if not (row.isPending or row.is_open):
    gui.sameLine()
    if gui.buttonSmall(if row.is_visible: cstring"hide" else: cstring"show"):
      scene.setVisible(row.slot.get, not row.is_visible)
      history.record(scene, camera)
    gui.tooltip("Show or hide this object without removing it.")
    gui.sameLine()
    result = gui.buttonSmall("remove")
    gui.tooltip("Delete this object; its slot is reused by the next one you add.")


proc layoutItemDescription(panel: Panel; scene: var Scene; row: ItemRow) =
  ## Lay out row's shape word and coefficients, on one line.
  ##   Built into stack buffer rather than `string`, since every visible item redraws this
  ## every frame. Shape word first on same line, matching browser's `point: 3e1 - 2e2`;
  ## two lines doubled every row's height.
  let geometry_shown =
    if row.is_open: panel.session.get.geometry else: scene.geometryOf(row.slot.get)
  var line: array[WIDTH_ITEM_LINE, char]
  let description = buildChars(line):
    appendChars(line, cursor, "  ")
    describeShape(geometry_shown, line, cursor)
    appendChars(line, cursor, ": ")
    formatMultivector(geometry_shown, line, cursor)
  gui.textWrapped(description)


proc layoutItem(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  slot: Option[int]; now: float
): bool =
  ## Lay out one item's controls; report whether user asked for it to be removed.
  ##   None `slot` lays out composing row: same shape, values from session, no buttons
  ## acting on object that exists (hide, remove).
  ##   Hidden item's row dims rather than disappearing, so it stays readable and its show
  ## button clickable: `alphaPush`, not `disabledPush`.
  ##   Orchestrator over row's three parts: name, actions on it, what it says.
  let is_pending = slot.isNone
  gui.idPush(if is_pending: cint(ITEMS_MAX) else: cint(slot.get))
  defer: gui.idPop()

  let row = block:
    let is_open = is_pending or
      (panel.session.isSome and panel.session.get.slot == slot)
    # Bound first: `colour` lends, and C++ backend cannot lend from converted temporary.
    let ink = if is_open: Ink(panel.session.get.index_ink) else: scene.inkAt(slot.get)
    ItemRow(
      slot: slot,
      is_open: is_open,
      is_visible: is_pending or scene.isVisible(slot.get),
      tint: ink.colour,
    )
  if not row.is_visible: gui.alphaPush(ALPHA_ITEM_HIDDEN)
  defer:
    if not row.is_visible: gui.alphaPop()

  layoutItemName(panel, scene, row)
  result = layoutItemButtons(panel, scene, camera, history, row, now)
  layoutItemDescription(panel, scene, row)
  if row.is_open: layoutSessionFields(panel, is_pending)
  gui.separator()


proc layoutObjects*(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  now: float
) =
  ## Lay out every live item's controls, plus row being composed if there is one, applying
  ## at most one removal per frame, since click lands on one button.
  ##   `now` is forwarded to whichever row commits fresh object, so it animates in.
  var header: array[32, char]
  let label = buildChars(header):
    appendChars(header, cursor, "objects (")
    appendInt(header, cursor, scene.len)
    appendChars(header, cursor, " of ")
    appendInt(header, cursor, ITEMS_MAX)
    appendChars(header, cursor, ")")
  if not gui.header(label, is_open_first = true): return

  let is_composing =
    panel.session.isSome and panel.session.get.slot.isNone
  if scene.len == 0 and not is_composing:
    gui.text("Nothing here yet -- press `add` above, or drag between two objects.")
    return

  # Composing row heads list: newest thing here, with no `born` to sort by.
  if is_composing: discard layoutItem(panel, scene, camera, history, none(int), now)

  # Newest first, as browser lists them. Sorted once per edit, never per frame: sorting
  #   here by `born` each frame was 98% of desktop's CPU frame at 5,038 objects.
  if panel.revision_ordered != some(scene.revision):
    panel.count_ordered = scene.slotsCreated(panel.slots_ordered)
    panel.revision_ordered = some(scene.revision)

  var slot_removed = none(int)
  for position in countdown(panel.count_ordered - 1, 0):
    let slot = panel.slots_ordered[position]
    if layoutItem(panel, scene, camera, history, some(slot), now):
      slot_removed = some(slot)
  if slot_removed.isSome:
    scene.removeItem(slot_removed.get)
    panel.selection.pruneDead(scene)
    # Its session has nothing left to commit against.
    if panel.session.isSome and panel.session.get.slot == slot_removed:
      panel.session = none(EditSession)
    history.record(scene, camera)



#[ Construct Panel ]#

proc layoutTopBar*(panel: var Panel; scene: var Scene; now: float) =
  ## Lay out controls reached for constantly, above every collapsing section: start new
  ## object, toggle world furniture, save or load scene.
  ##   Outside sections as browser's chip row and menu hold them: each is flipped
  ## repeatedly or applies to whole scene. `add` has to live outside `objects`, since
  ## pressing it opens that section.
  gui.disabledPush(panel.session.isSome or scene.isFull)
  if gui.button("add"):
    beginSession(panel, scene, none(int))
  gui.disabledPop()
  gui.tooltip(
    "Compose a new object in the Objects list below; nothing joins the scene until you " &
    "save it. Greyed out while another edit is open, so starting this cannot discard it."
  )

  gui.sameLine()
  discard gui.checkbox("axes", addr panel.is_axes_shown)
  gui.tooltip("Toggle the red/green/blue x/y/z axis lines through the origin.")
  gui.sameLine()
  discard gui.checkbox("grid", addr panel.is_grid_shown)
  gui.tooltip("Toggle the reference grid at z = 0.")
  gui.sameLine()
  # "debug", matching browser chip and diagnostics tree's "debug overlay" row: control
  #   called algebra reads as subject of whole app.
  discard gui.checkbox("debug", addr panel.is_algebra_shown)
  gui.tooltip(
    "Draw every multivector this frame computed, in its true form -- a plane as the " &
    "infinite lattice it is, not the disc that stands for one."
  )

  widthPushField()
  fieldLabel("scene file")
  discard gui.inputText("##scene_file", toCstring(panel.path_scene), cint(PATH_MAX))
  gui.tooltip("File `save scene` writes to and `load scene` reads from.")
  gui.widthPop()
  if gui.button("save scene"):
    toChars(saveScene(scene, toText(panel.path_scene)), panel.message)
  gui.sameLine()
  if gui.button("load scene"):
    # This frame's clock, so file arrives as replay; see `scene.bornReplaying`.
    toChars(loadScene(scene, toText(panel.path_scene), now), panel.message)
    # Loaded scene's slots are not ones any open session was opened against.
    panel.session = none(EditSession)


proc offerOperationsOfArity*(
  arity: Arity
): (array[COUNT_OPERATION, cstring], array[COUNT_OPERATION, Operation], int) =
  ## List catalogue's operations of one arity, with notation each is offered under and
  ## operation each offered position names.
  ##   Only chosen arity rather than all with second operand greyed: halving catalogue is
  ## difference between scanning and hunting. Operations beside notations because combo
  ## hands back dense position, which names nothing once list is filtered.
  ##   `cstring`s point into this build's storage rather than `const` table: combo keeps
  ## address of first entry while list is open.
  for operation in Operation:
    if lut_operation_to_arity[operation] != arity: continue
    result[0][result[2]] = cstring(notationSymbolic(operation))
    result[1][result[2]] = operation
    inc result[2]


proc adoptSelectionAsOperands(
  panel: var Panel; slots: openArray[int]; count: int
) =
  ## Fill arity and operand pickers in from whatever is selected in 3D view.
  ##   How many are picked names arity, pick order names m and n. Only when selection
  ## itself changes (see `revision_selection_synced`), so later manual pick sticks.
  if panel.selection.revision == panel.revision_selection_synced: return
  panel.revision_selection_synced = panel.selection.revision
  if panel.selection.len == 0: return

  func positionOf(slots: openArray[int]; count, slot: int): Option[cint] =
    ## Translate slot back to operand combo's dense position.
    for position in 0 ..< count:
      if slots[position] == slot: return some(cint(position))

  let arity_implied = cint(ord(panel.selection.impliedArity))
  if panel.index_arity != arity_implied:
    # Filtered operation list is indexed per arity, so position carried across names
    #   unrelated operation.
    panel.index_arity = arity_implied
    panel.index_operation = 0
  let position_first = positionOf(slots, count, panel.selection.at(0))
  if position_first.isSome: panel.index_operand_first = position_first.get
  if panel.selection.len >= 2:
    let position_second = positionOf(slots, count, panel.selection.at(1))
    if position_second.isSome: panel.index_operand_second = position_second.get


proc openSelectionMenuPicker*(panel: var Panel) =
  ## Reveal selection menu's operation picker, on operation last applied at arity
  ## selection implies.
  ##   Shared by that menu's `apply` and by drag wheel's `more…`, which lands here rather
  ## than in drawer's apply section: sending it to panel buried two objects it just named
  ## under every other control. See `visualiser.handleEvent`.
  let
    arity = panel.selection.impliedArity
    (_, operations, count_offered) = offerOperationsOfArity(arity)
    wanted = panel.operations.lastOf(arity)
  panel.is_menu_selection_shown = true
  panel.is_menu_selection_picking = true
  # Head of list unless remembered operation is in it: list is per arity.
  panel.index_operation_menu = 0
  for index in 0 ..< count_offered:
    if operations[index] == wanted:
      panel.index_operation_menu = cint(index)
      break


proc applyPickedOperation(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  operation: Operation; first, second: int; now: float
) =
  ## Derive fresh object from picked operation and operands, and say what it gave.
  ##   Leaves result solely selected, which carries camera to it through
  ## `visualiser.offerCameraAim`.
  ##   Operands as *slots*, not picker positions: apply section reads combos, selection
  ## menu reads selection, and neither learns other's indexing. Unary operation names same
  ## slot twice.
  let
    operand_first = scene[first].geometry
    operand_second = scene[second].geometry
    derived = applyOperation(operation, operand_first, operand_second)
    anchor = creationAnchor(operation, operand_first, operand_second, derived)
    name_first = toText(scene.labelAt(first))
    name_second = toText(scene.labelAt(second))
    label = notationSubstituted(operation, name_first, name_second)
  panel.operations.remember(operation)
  panel.selection.selectOnly(
    scene.addItem(derived, label, scene.takeInk(), now, anchor)
  )
  history.record(scene, camera)

  toChars(&"{label} gave {shapeText(derived)}.", panel.message)


proc layoutApply*(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  now: float
) =
  ## Lay out controls that derive fresh object by applying library operation to operands.
  ##   Longer than sixty-line default: one run of controls over one set of offer lists
  ## living exactly as long as controls indexing them; item names are `cstring`s borrowed
  ## from scene's label storage.
  if not gui.header("apply", is_open_first = false): return
  if scene.len == 0:
    gui.text("Scene is empty; add a multivector first.")
    return

  # Offer every live item by label; `slots` translates combo's dense position back.
  var
    names: array[ITEMS_MAX, cstring]
    slots: array[ITEMS_MAX, int]
    count = 0
  for slot, _ in scene.pairs:
    names[count] = toCstring(scene.labelAt(slot))
    slots[count] = slot
    inc count

  adoptSelectionAsOperands(panel, slots, count)

  let arity_wanted = Arity(panel.index_arity)
  let (notations, operations, count_offered) = offerOperationsOfArity(arity_wanted)

  # Arity is segmented control rather than dropdown: exactly two choices, both worth
  #   seeing, one click to switch. Matches browser's `.toggles` pill.
  const lut_arity_to_name = [Arity.One: cstring"unary", Arity.Two: cstring"binary"]
  fieldLabel("arity")
  let width_segment = (gui.contentWidth() - SPACING_SEGMENT)/2.0'f32
  for arity in Arity:
    if arity != Arity.low: gui.sameLine()
    if gui.buttonToggle(
      lut_arity_to_name[arity], panel.index_arity == cint(ord(arity)), width_segment
    ):
      panel.index_arity = cint(ord(arity))
      # Filtered list is indexed per arity. Land on whatever was last applied at arity
      #   switched to, rather than head of list.
      panel.index_operation = 0
      let (_, offered, count) = offerOperationsOfArity(arity)
      let wanted = panel.operations.lastOf(arity)
      for position in 0 ..< count:
        if offered[position] == wanted:
          panel.index_operation = cint(position)
          break
  gui.tooltip("Whether to list operations reading one operand or two.")

  widthPushField()

  let index_offered = clamp(int(panel.index_operation), 0, count_offered - 1)
  panel.index_operation = cint(index_offered)
  fieldLabel("operation")
  discard gui.combo(
    "##operation", addr panel.index_operation, addr notations[0], cint(count_offered),
  )
  gui.tooltip("Library operation to apply below; its own notation names m and n, " &
    "the operands picked next.")
  let
    operation = operations[clamp(int(panel.index_operation), 0, count_offered - 1)]
    is_binary = arity_wanted == Arity.Two

  fieldLabel("operand m")
  discard gui.combo("##operand_m", addr panel.index_operand_first,
    addr names[0], cint(count))
  gui.tooltip("First operand -- `m` in the notation above -- every operation reads.")
  if is_binary:
    fieldLabel("operand n")
    discard gui.combo("##operand_n", addr panel.index_operand_second,
      addr names[0], cint(count))
    gui.tooltip("Second operand -- `n` above -- this operation combines with `m`.")
  gui.widthPop()

  let
    first = slots[clamp(int(panel.index_operand_first), 0, count - 1)]
    second =
      if is_binary: slots[clamp(int(panel.index_operand_second), 0, count - 1)]
      else: first # Unary operation ignores second operand; naming first keeps stale
        # picker reading from reaching `applyOperation`.
  # Ghost what `apply` would build, from very three readings button passes to
  #   `applyPickedOperation`, so preview cannot name different construction from commit.
  #   Resolved here so it follows pickers as worked; closed section previews nothing.
  panel.preview = scene.previewApplying(operation, first, second)

  gui.disabledPush(scene.isFull)
  if gui.buttonWide("apply", gui.contentWidth()):
    applyPickedOperation(panel, scene, camera, history, operation, first, second, now)
    panel.hideSelectionMenu() # Built something; see `showSelectionMenu`.
  gui.disabledPop()



#[ View Panel ]#

proc layoutView*(panel: var Panel; camera: var Camera) =
  ## Lay out camera placement and frame export.
  ##   World furniture toggles live in `layoutTopBar`, flipped constantly while orbiting.
  if not gui.header("view", is_open_first = false): return
  widthPushField()

  var placement = [
    cfloat(camera.azimuth), cfloat(camera.elevation), cfloat(camera.distance)
  ]
  fieldLabel("azimuth")
  if gui.dragFloat("##azimuth", addr placement[0], 0.01, 0.0, 0.0):
    camera.azimuth = float(placement[0])
  gui.tooltip("Spin the camera around its target.")
  fieldLabel("elevation")
  if gui.dragFloat("##elevation", addr placement[1], 0.01,
      cfloat(-ELEVATION_LIMIT), cfloat(ELEVATION_LIMIT)):
    camera.elevation = float(placement[1])
  gui.tooltip("Tilt the camera up or down; clamped short of looking straight up or down.")
  fieldLabel("distance")
  # Unbounded at widget, floored by `distanceHeld` on way in: no ceiling on orbit
  #   distance, and one value it may not take is stated in `camera`.
  if gui.dragFloat("##distance", addr placement[2], 0.05, 0.0, 0.0):
    camera.distance = distanceHeld(float(placement[2]))
  gui.tooltip("Move the camera toward or away from its target.")

  var target = [cfloat(camera.target.x), cfloat(camera.target.y), cfloat(camera.target.z)]
  fieldLabel("target")
  if gui.dragFloat3("##target", addr target[0], SPEED_DRAG*10.0):
    camera.target = Position(x: float(target[0]), y: float(target[1]), z: float(target[2]))
  gui.tooltip("World point the camera looks at and orbits around.")

  var field_of_view = cfloat(camera.degrees_field_of_view)
  fieldLabel("field of view")
  if gui.dragFloat("##field_of_view", addr field_of_view, 0.2, 10.0, 120.0):
    camera.degrees_field_of_view = float(field_of_view)
  gui.tooltip("Lens angle; smaller looks through a telephoto, larger through a wide angle.")
  gui.widthPop()

  gui.separatorText("export")
  widthPushField()
  fieldLabel("path")
  discard gui.inputText("##path_export", toCstring(panel.path_export), cint(PATH_MAX))
  gui.tooltip("File `save PNG` and the `S` key both write the current frame to.")
  gui.widthPop()
  if gui.button("save PNG"): panel.is_export_requested = true



#[ Diagnostics Panel ]#

proc layoutDiagnosticsFrameTime(panel: var Panel) =
  ## Lay out "frame time" section: rolling frame-time plot, vsync toggle, current rate,
  ## tessellation cost.
  gui.separatorText("frame time")
  var highest = 16.6'f32 # Floor range at 60fps, so smooth run does not zoom in on noise.
  for value in panel.milliseconds_history:
    if value > highest: highest = value
  var overlay: array[WIDTH_OVERLAY_TEXT, char]
  let text_now = buildChars(overlay):
    appendFixed(overlay, cursor, 1000.0/max(float(gui.framerate()), 1.0), 2)
    appendChars(overlay, cursor, " ms now")
  # Full panel width, passed rather than left at 0: Dear ImGui reads zero width as default
  #   *item* width, two thirds of window.
  gui.plotLines(
    "##frame_time", addr panel.milliseconds_history[0], cint(FRAMES_HISTORY),
    cint(panel.index_history), text_now, 0.0, highest, gui.contentWidth(), 60.0,
  )
  gui.tooltip(
    "Milliseconds per drawn frame, oldest at the left and most recent at the right. " &
    "An fps average can hide an occasional slow frame; a spike here cannot."
  )

  discard gui.checkbox("vsync", addr panel.is_vsync_enabled)
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
    appendFixed(line, cursor, panel.microseconds_tessellate, 1)
    appendChars(line, cursor, " us into ")
    appendInt(line, cursor, panel.count_vertices)
    appendChars(line, cursor, " vertices")
  gui.text(text_tessellate)


proc layoutDiagnosticsMemory(panel: Panel) =
  ## Lay out "memory" section: permanent and per-frame arena usage bars.
  gui.separatorText("memory")
  block:
    let
      mb_used = float(panel.bytes_arena_permanent_used) / (1024.0*1024.0)
      mb_capacity = float(panel.bytes_arena_permanent_capacity) / (1024.0*1024.0)
    var text: array[WIDTH_OVERLAY_TEXT, char]
    let overlay_text = buildChars(text):
      appendFixed(text, cursor, mb_used, 1)
      appendChars(text, cursor, " / ")
      appendFixed(text, cursor, mb_capacity, 0)
      appendChars(text, cursor, " MB")
    gui.textTinted("permanent arena", INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue)
    gui.progressBar(
      cfloat(mb_used / max(mb_capacity, 1.0)), overlay_text, gui.contentWidth(), 0.0,
      0.298, 0.482, 0.929, 0.15, 0.15, 0.18,
    )
    gui.tooltip(
      "Never freed until the process exits: the pixel-export buffer, sized for the " &
      "largest frame this build allows, and every frame of a storyboard's own GIF, " &
      "held until the single call at the end that writes them all out."
    )

  block:
    let
      kb_peak = float(panel.bytes_arena_frame_peak) / 1024.0
      mb_capacity = float(panel.bytes_arena_frame_capacity) / (1024.0*1024.0)
    var text: array[WIDTH_OVERLAY_TEXT, char]
    let overlay_text = buildChars(text):
      appendChars(text, cursor, "peak ")
      appendFixed(text, cursor, kb_peak, 0)
      appendChars(text, cursor, " KB / ")
      appendFixed(text, cursor, mb_capacity, 0)
      appendChars(text, cursor, " MB")
    gui.textTinted("frame arena", INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue)
    let fraction =
      float(panel.bytes_arena_frame_peak) /
      max(float(panel.bytes_arena_frame_capacity), 1.0)
    gui.progressBar(
      cfloat(fraction), overlay_text, gui.contentWidth(), 0.0,
      0.561, 0.737, 0.353, 0.15, 0.15, 0.18,
    )
    gui.tooltip(
      "Reset after every PNG or GIF frame it backs, so it reads empty almost any time " &
      "you would look here; the bar instead holds the largest single export this run " &
      "has needed so far, out of its own fixed reservation."
    )


func sizePoolCell(width: cfloat): cfloat =
  ## Report side to draw one object-pool cell at, for panel this wide.
  ##   Largest offered whose wrapped grid fits `HEIGHT_POOL_MAX`, or smallest offered where
  ## none does; every slot keeps cell either way.
  for side in SIZES_POOL_CELL:
    let
      columns = max(1, int(width/(side + SPACING_POOL_CELL)))
      rows = (ITEMS_MAX + columns - 1) div columns
    if float32(rows)*(side + SPACING_POOL_CELL) <= HEIGHT_POOL_MAX: return side
  SIZES_POOL_CELL[len(SIZES_POOL_CELL) - 1]


proc layoutDiagnosticsObjectPool(scene: Scene) =
  ## Lay out "object pool" section: live/free slot strip and byte accounting.
  gui.separatorText("object pool")
  # Occupied cell wears its object's ink, so strip reads as scene: which slot object sits
  #   in, and how `inkCycled` has spread palette.
  var cells: array[ITEMS_MAX * CHANNELS_POOL_CELL, cfloat]
  for slot in 0 ..< ITEMS_MAX:
    let colour = if scene.isAlive(slot): scene.inkAt(slot).colour else: INK_POOL_FREE.colour
    cells[slot*CHANNELS_POOL_CELL + 0] = cfloat(colour.red)
    cells[slot*CHANNELS_POOL_CELL + 1] = cfloat(colour.green)
    cells[slot*CHANNELS_POOL_CELL + 2] = cfloat(colour.blue)
  gui.poolBar(addr cells[0], cint(ITEMS_MAX), sizePoolCell(gui.contentWidth()))
  gui.tooltip(
    "One cell per object slot, in the colour of whatever object holds it; dark means " &
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
    "Scene is one fixed block sized for every slot up front, not allocated one " &
    "object at a time: `allocated` is that whole block, `used` is however many slots " &
    "are actually alive right now times the per-slot figure, and `B/slot` is roughly " &
    "what one object's own slot costs -- not a measurement of any single object."
  )


proc layoutDiagnosticsTotal(panel: Panel) =
  ## Lay out "total" section: every fixed reservation this binary makes, added up.
  gui.separatorText("total")
  var total: array[WIDTH_OVERLAY_TEXT, char]
  let text_total = buildChars(total):
    appendFixed(total, cursor, float(panel.bytes_memory_total) / (1024.0*1024.0), 1)
    appendChars(total, cursor, " MB")
  gui.text(text_total)
  # Folded to one literal, so depth is read from `CAPACITY_HISTORY` and tooltip is still
  #   `cstring` pointing at static text.
  const TEXT_TOTAL =
    "Every fixed reservation this binary makes for itself, added up: both arenas at " &
    "their full capacity (committed whether or not they're ever filled), the object " &
    "pool above, the undo timeline -- which is " & $CAPACITY_HISTORY & " more whole " &
    "copies of that pool, and the largest single entry here -- tessellation storage, " &
    "and the panel's own state. Excludes whatever Dear ImGui, SDL, or the graphics " &
    "driver allocate on their own account, which this process cannot see or account for."
  gui.tooltip(TEXT_TOTAL)


proc layoutDiagnostics*(panel: var Panel; scene: Scene) =
  ## Lay out live performance and memory readouts: closed by default, since nothing here
  ## is needed to use visualiser, only to understand what using it costs.
  if not gui.header("diagnostics", is_open_first = false): return
  gui.text("Live cost of this build, updated every frame.")
  gui.sameLine()
  gui.helpMarker(
    "Nothing on this panel changes what you can do here; it exists so a slow frame or " &
    "a full object pool shows itself directly instead of just feeling wrong."
  )

  layoutDiagnosticsFrameTime(panel)
  layoutDiagnosticsMemory(panel)
  layoutDiagnosticsObjectPool(scene)
  layoutDiagnosticsTotal(panel)



#[ History Stepping ]#

proc stepHistory*(
  panel: var Panel; scene: var Scene; camera: var Camera; history: var History;
  is_undo: bool
): bool =
  ## Step timeline one way, putting view back where restored edit was made, and drop
  ## whatever open edit was staged against.
  ##   Reports whether anything moved. One proc for buttons and keys: restored snapshot's
  ## slot numbers need not match ones session or selection held, easy to forget in second
  ## place.
  ##   Abandons standing tween, aiming at whatever was last selected: left running it
  ## drags view off placement just restored.
  result = if is_undo: history.undo(scene, camera) else: history.redo(scene, camera)
  if result:
    panel.selection.clear()
    panel.session = none(EditSession)
    panel.hideSelectionMenu()
    panel.tween_camera.abandon()



#[ Selection Menu ]#

const
  OFFSET_MENU_SELECTION = 46.0'f32
    ## Lift menu this far above object it follows, in pixels.
    ##   Above rather than on: ImGui window makes `gui.wantsMouse` true wherever it sits,
    ## and menu straddling its object would swallow next drag off it. Clears selection
    ## marker too. Matches browser's 60-pixel lift less this row's height, browser
    ## measuring in CSS pixels.
  MARGIN_MENU_SELECTION = 8.0'f32
    ## Keep menu at least this far inside viewport, so object near edge does not push half
    ## of it off screen.
  PADDING_MENU_PICKER = 36.0'f32
    ## Slack added to widest notation offered, for combo's frame and arrow.

proc layoutSelectionMenuApply(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  now: float
) =
  ## Lay out menu's `apply` button and operation picker it reveals beside it.
  ##   One button in both roles: first press opens picker, second commits what it shows.
  ## `apply` never moves or relabels, so picker reads as opening *out of* it.
  ##   Only for one or two picked objects; three or more have no operand pickers here, so
  ## menu offers nothing rather than guessing. Matches browser's `refreshSelectionMenu`.
  let
    count = panel.selection.len
    arity = panel.selection.impliedArity
    (notations, operations, count_offered) = offerOperationsOfArity(arity)
  gui.disabledPush(scene.isFull and panel.is_menu_selection_picking)
  if gui.buttonSmall("apply"):
    if not panel.is_menu_selection_picking:
      panel.openSelectionMenuPicker()
    else:
      let
        index = clamp(int(panel.index_operation_menu), 0, count_offered - 1)
        first = panel.selection.at(0)
        second = if count >= 2: panel.selection.at(1) else: first
      applyPickedOperation(
        panel, scene, camera, history, operations[index], first, second, now
      )
      panel.hideSelectionMenu()
  gui.disabledPop()
  gui.tooltip(
    "Pick an operation to apply to what you selected, then press this again to " &
    "apply it."
  )
  if not panel.is_menu_selection_picking: return

  # Ghost whatever picker shows, from same two slots and index button commits with. Only
  #   while picker is revealed: previewing behind closed `apply` puts object on screen
  #   nothing names.
  #   Written after `visualiser.offerCameraAim` has run this frame, so camera takes it up
  #   next one; offer is re-made every frame.
  block:
    let
      index = clamp(int(panel.index_operation_menu), 0, count_offered - 1)
      first = panel.selection.at(0)
      second = if count >= 2: panel.selection.at(1) else: first
    panel.preview = scene.previewApplying(operations[index], first, second)

  var width_picker = 0.0'f32
  for index in 0 ..< count_offered:
    width_picker = max(width_picker, gui.textWidth(notations[index]))
  gui.sameLine()
  gui.widthPush(width_picker + PADDING_MENU_PICKER)
  discard gui.combo(
    "##operation_menu", addr panel.index_operation_menu,
    addr notations[0], cint(count_offered),
  )
  gui.widthPop()
  gui.tooltip("Library operation; its own notation names m and n, the objects you selected.")
  gui.sameLine()
  if gui.buttonSmall("back"): panel.is_menu_selection_picking = false
  gui.tooltip("Leave the operation unapplied.")


proc layoutSelectionMenu*(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  anchor: Option[tuple[x, y: cfloat]]; now: float
) =
  ## Lay out floating menu over whatever is picked: apply, edit, hide, delete, close.
  ##   Follows *most recently* picked object rather than middle of them all, which would
  ## jump as membership changes. `anchor` is where that object is on screen; none where
  ## behind camera, which leaves menu where it last was.
  ##   Longer than sixty-line default: past `apply`, one run of buttons whose only shared
  ## state is which is on line so far.
  if not panel.is_menu_selection_shown or panel.selection.len == 0: return
  if anchor.isSome:
    panel.position_menu_selection = [
      anchor.get.x,
      max(anchor.get.y - OFFSET_MENU_SELECTION, MARGIN_MENU_SELECTION),
    ]
  let count = panel.selection.len
  var is_line_started = false # Whether anything is on row yet, so first button placed
    # does not ask for `sameLine` with nothing to continue.
  if gui.windowBeginPinned(
    "##selection_menu",
    clamp(
      panel.position_menu_selection[0],
      MARGIN_MENU_SELECTION, gui.viewportWidth() - MARGIN_MENU_SELECTION,
    ),
    clamp(
      panel.position_menu_selection[1],
      MARGIN_MENU_SELECTION, gui.viewportHeight() - MARGIN_MENU_SELECTION,
    ),
    0.5, 1.0,
  ):
    if count <= 2:
      layoutSelectionMenuApply(panel, scene, camera, history, now)
      is_line_started = true

    # Edit and two bulk actions stand aside while operation is being picked, so row stays
    #   one line at any width. Closing stays reachable throughout.
    if not panel.is_menu_selection_picking:
      if count == 1:
        if is_line_started: gui.sameLine()
        is_line_started = true
        if gui.buttonSmall("edit"):
          beginSession(panel, scene, some(panel.selection.at(0)))
          panel.hideSelectionMenu() # Panel owns it now; pick itself stays.
        gui.tooltip("Rename, recolour or reshape it; nothing changes until you save.")

      let is_all_hidden = panel.selection.isAllHidden(scene)
      if is_line_started: gui.sameLine()
      is_line_started = true
      if gui.buttonSmall(if is_all_hidden: cstring"show" else: cstring"hide"):
        for position in 0 ..< count:
          scene.setVisible(panel.selection.at(position), is_all_hidden)
        history.record(scene, camera)
        toChars(
          if is_all_hidden: "Showed the selection." else: "Hid the selection.",
          panel.message,
        )
      gui.tooltip("Show or hide the whole selection, without removing any of it.")

      gui.sameLine()
      if gui.buttonSmall("delete"):
        # Read slots out before removing any: removal prunes selection this loop walks.
        var slots: array[ITEMS_MAX, int]
        for position in 0 ..< count: slots[position] = panel.selection.at(position)
        # Open session against one of these has nothing left to commit against; same
        #   guard `layoutObjects` keeps.
        if panel.session.isSome and panel.session.get.slot.isSome and
            panel.session.get.slot.get in panel.selection:
          panel.session = none(EditSession)
        for position in 0 ..< count: scene.removeItem(slots[position])
        panel.selection.clear()
        history.record(scene, camera)
        toChars("Deleted the selection.", panel.message)
        panel.hideSelectionMenu()
      gui.tooltip("Delete the whole selection; each slot is reused by the next add.")

    gui.sameLine()
    if gui.buttonSmall("✕"):
      panel.selection.clear()
      panel.hideSelectionMenu()
    gui.tooltip("Clear the selection, and put this menu away.")
  gui.windowEnd()



#[ Help ]#

const
  MARGIN_HELP = 16.0'f32
    ## Hold help affordance this far off bottom-right corner, in pixels.
  GAP_HELP_COLUMN = 18.0'f32
    ## Separate entry's action from its outcome by at least this much, so columns read as
    ## columns.
  MARGIN_HELP_PANEL = 96.0'f32
    ## Leave this much of window unclaimed by help panel: `?` button below it, tab strip
    ## above its rows, window's frame.

func helpActionOf(entry: HelpEntry): string =
  ## Write one entry's action as panel draws it, indent and touch marker included.
  ##   One writer, because column is sized by measuring exactly what is then drawn.
  "  " & entry.action & (if entry.is_touch: "  (touch)" else: "")


proc layoutHelp*(panel: var Panel; path_forced: Option[HelpPath] = none(HelpPath)) =
  ## Lay out help affordance: `?` pinned to bottom-right corner, and panel it opens.
  ##   In corner rather than inside panel window: reachable when panel is thing reader
  ## does not understand, and browser puts it in same corner. Both read `help.nim`.
  ##   `path_forced` opens one tab whatever reader last chose. Only `--drive-help` passes
  ## it: headless run cannot click tab strip.
  let (width, height) = (gui.viewportWidth(), gui.viewportHeight())
  if gui.windowBeginPinned(
    "##help_open", width - MARGIN_HELP, height - MARGIN_HELP, 1.0, 1.0
  ):
    if gui.button("  ?  "): panel.is_help_open = not panel.is_help_open
  gui.windowEnd()

  if not panel.is_help_open: return
  # Where outcome column starts, and how wide pair is, measured from widest entries rather
  #   than set by eye: hand-tuned number ran long entry into its outcome. Measured only
  #   while panel is open; every storyboard frame was paying for whole table's metrics.
  var offset_outcome, width_outcome = 0.0'f32
  for entry in lut_help_entries:
    offset_outcome = max(offset_outcome, gui.textWidth(cstring(helpActionOf(entry))))
    width_outcome = max(width_outcome, gui.textWidth(cstring(entry.outcome)))
  offset_outcome += GAP_HELP_COLUMN
  if gui.windowBeginPinned(
    "##help_panel", width - MARGIN_HELP, height - MARGIN_HELP - 44.0, 1.0, 1.0
  ):
    # One tab per path. Window auto-sizes and grows *upward* from corner with no scrollbar,
    #   so tall panel silently loses top rows; region below is bounded to what window has
    #   and scrolls. `ENTRIES_MAX_PATH` keeps scrollbar from being way this is read.
    let
      # Sized from both columns: bounded region asked to fill nothing in auto-sizing window
      #   collapses to widest *item*, and every outcome past that is clipped.
      width_rows = offset_outcome + width_outcome + GAP_HELP_COLUMN
      height_available = height - MARGIN_HELP_PANEL
    if gui.tabBarBegin("##help_tabs"):
      for path in HelpPath:
        if not gui.tabBegin(cstring(titleOf(path)), path_forced == some(path)): continue
        # What tab is about, before rows that assume it. Wrapped, and outside rows child so
        #   it stays put while they scroll.
        gui.textWrappedAt(cstring(descriptionOf(path)), width_rows)
        # Each tab as tall as its rows need, up to what window has: fixed height for
        #   largest leaves `menu`'s five rows floating in blank.
        let height_rows = min(
          gui.childHeightForRows(cint(countOf(path))), height_available
        )
        if gui.childBegin(cstring("##help_rows"), width_rows, height_rows):
          for entry in lut_help_entries:
            if entry.path != path: continue
            # Touch rows say so in word rather than only tint, surviving reader who cannot
            #   tell two greys apart.
            gui.textTinted(cstring(helpActionOf(entry)), 0.74, 0.95, 0.94)
            gui.sameLineAt(offset_outcome)
            gui.text(cstring(entry.outcome))
        gui.childEnd()
        gui.tabEnd()
      gui.tabBarEnd()
  gui.windowEnd()



#[ Whole Panel ]#

proc layoutPanel*(
  panel: var Panel; scene: var Scene; camera: var Camera; history: var History; now: float
) =
  ## Lay out every panel inside one window.
  ##   `now` is this frame's clock reading, passed to whichever construct control adds
  ## item, so it animates in.
  # Drop last frame's apply preview here, so only control on screen this frame can put one
  #   back. Closed section never writes; no flag says whether section is open.
  panel.preview = none(Preview)
  gui.windowPlace(16.0, 16.0, WIDTH_PANEL, 720.0)
  if gui.windowBegin("RGA visualiser"):
    # Coloured words match rubber-band drawn while dragging. Which colour belongs to which
    #   is `interaction.inkOf`'s to say.
    #   **Where three symbols are taught.** Wheel's wedges say `𝐦 ∧ 𝐧` (see
    #   `interaction.labelOf`), unreadable until told it is `join`, so word and notation
    #   appear here together. Sibling is browser's `.drawer-intro` line in `shell.html`.
    gui.textWrapped("Drag one object onto another; the two of them choose what it makes:")
    for choice in [DragChoice.Join, DragChoice.Meet, DragChoice.Project]:
      let tint = inkOf(choice).colour
      gui.textTinted(
        cstring(wordOf(choice) & "  " & labelOf(choice)), tint.red, tint.green, tint.blue
      )
    gui.textWrapped("Right-drag to pick instead; on a touchscreen, hold still over the target.")

    # Scene-content edits only; orbit is not step, though each step restores view it was
    #   made from; see `history.nim`. Each button greys out where its side of timeline is
    #   empty. Successful step drops open session too.
    gui.disabledPush(not history.canUndo)
    if gui.button("undo"):
      discard stepHistory(panel, scene, camera, history, is_undo = true)
    gui.disabledPop()
    gui.tooltip("Step back through scene-content edits, view and all; an orbit on its own " &
      "is not a step.")
    gui.sameLine()
    gui.disabledPush(not history.canRedo)
    if gui.button("redo"):
      discard stepHistory(panel, scene, camera, history, is_undo = false)
    gui.disabledPop()
    gui.tooltip("Step forward again; a fresh edit discards whatever was ahead.")
    gui.separator()
    layoutTopBar(panel, scene, now)
    gui.separator()

    # Sections in alphabetical order, matching browser's drawer, `objects` open by default.
    layoutApply(panel, scene, camera, history, now)
    layoutDiagnostics(panel, scene)
    layoutObjects(panel, scene, camera, history, now)
    layoutView(panel, camera)
    gui.separator()
    gui.text(toCstring(panel.message))
  gui.windowEnd()
