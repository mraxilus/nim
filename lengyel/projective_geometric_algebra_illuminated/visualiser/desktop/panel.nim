## Lay out panels user edits scene and camera through.
##
## Panel holds what the GUI needs between frames and the scene does not own:
## which operands are picked, what an open edit is staging, where to export.
##   Everything else is read straight off scene and camera, so there is one source of truth
##   and no synchronisation step.
##
##   |-------------|-------------------------------------------------------------------------|
##   | Panel       | Offers                                                                  |
##   |-------------|-------------------------------------------------------------------------|
##   | Top bar     | Start a new object, toggle world furniture, save or load the scene.     |
##   | Apply       | Apply any library operation of a chosen arity to picked operands, both  |
##   |             | of which the current selection fills in.                                |
##   | Diagnostics | Live frame time, vsync, memory use of both arenas, object pool,         |
##   |             | and everything else this binary reserves for itself, added up.          |
##   | Objects     | Select, show, hide, remove; edit any object's label, colour and         |
##   |             | coefficients through one staged session, shared with composing a new    |
##   |             | one.                                                                    |
##   | View        | Orbit, target, lens, PNG export.                                        |
##   |-------------|-------------------------------------------------------------------------|
##
## Every panel above except the top bar is a collapsing header, ordered alphabetically and
## matching the browser build's own drawer section for section. The top bar sits outside
## them all, because its `add` button has to be able to open Objects. Only Objects opens by
## default: it is what a returning session looks at first, and opening all four at once
## buries the 3D view the visualiser exists to show.
##
## Coefficients are staged through 32-bit floats because that is what the widget writes,
## and written back only where widget reports a change, so editing costs no precision
## on coefficients the user never touched.
##
## Multivectors are printed by `scene.formatMultivector` rather than by the library's own
## `$`, which returns a fresh heap `string` -- once per visible item, per frame. Basis
## elements are named identically either way; the atlas carries the mathematical bold and
## subscript blocks the library writes them in.
##
## Desktop-only; unreachable from the browser build. See `visualiser.nim`'s own "Render
## Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../../pga
import ./gui
import ../core/[boundary, camera, format, help, history, interaction, tessellate, scene, selection]



#[ Panel Configuration ]#

const
  MESSAGE_MAX* = 96
    ## Bound length of outcome reported after an action.
  PATH_MAX* = 256
    ## Bound length of export path user may type.
  WIDTH_PANEL* = 440.0'f32
    ## Set width panels open at, in pixels -- wide enough that six coefficient cells share
    ## one line, which is what sets the floor here, and close to the browser drawer's own
    ## 400. Opening an editor must not resize the window, so this holds whether or not one
    ## is open, and the grid divides itself out of whatever it is given.
  SPEED_DRAG* = 0.01'f32
    ## Set how fast a coefficient moves per pixel dragged.
  WIDTH_ITEM_LINE = WIDTH_SHAPE_WORD + WIDTH_MULTIVECTOR
    ## Bound one item's shape-and-coefficient line in *bytes*, redrawn every frame. Sized
    ## from what the two printers that fill it declare for themselves, rather than by a
    ## number tuned by hand here: the line is a shape word followed by a whole multivector,
    ## and a mixed-grade object genuinely does print every basis term.
  COEFFICIENTS_PER_ROW = 6
    ## Wrap a grade's own elements after this many. In this build's 4D metric the largest
    ## grade holds exactly six, so every grade fits one line and the desktop grid matches
    ## the browser's own grade row one for one. A build of higher dimension wraps instead
    ## of overflowing the panel. A wrap point, not a divisor: a line's cells share that
    ## line between however many of them are on it.
  INK_LABEL = Rgba(red: 0.357, green: 0.400, blue: 0.451, alpha: 1.0)
    ## Draw a control's own name in this, the browser's `--ink-faint`: a name is read once
    ## and then stops mattering, while the value beside it is what keeps changing.
  WIDTH_ITEM_LABEL = 150.0'f32
    ## Set width an item row's own selectable label spans, leaving its three buttons room
    ## to share the same line.
  ALPHA_ITEM_HIDDEN = 0.45'f32
    ## Dim a hidden item's own row to this fraction, matching the browser's own
    ## `.item-row.hidden-item` rule -- present but plainly not drawn right now.
  HELP_COEFFICIENTS_PENDING: cstring =
    "The 16 numbers of the new multivector, in the library's basis order, stacked one " &
    "row per grade. A live preview draws as soon as any goes non-zero; nothing joins " &
    "the scene until you save."
    ## Explain the coefficient grid while composing a new object.
  HELP_COEFFICIENTS_EDITING: cstring =
    "The 16 numbers of this object's own multivector, in the library's basis order, " &
    "stacked one row per grade. The object itself only moves when you save."
    ## Explain the coefficient grid while editing an object that already exists.
  WIDTH_LABEL_FIELD = 96.0'f32
    ## Reserve room to the right of a field for its own label, which Dear ImGui draws
    ## there rather than above -- so a control sized to fill the line leaves it space.
  SPACING_SEGMENT = 8.0'f32
    ## Separate the segments of a segmented control, matching the gap `sameLine` leaves.
  WIDTH_OVERLAY_TEXT = 48
    ## Bound length of a bar or graph's own overlay text, redrawn every frame.
  SIZES_POOL_CELL = [14.0'f32, 10.0'f32, 6.0'f32, 4.0'f32, 3.0'f32, 2.0'f32]
    ## Offer the sides one object-pool cell may take, in pixels, largest first.
    ##   **Chosen against the capacity, not fixed.** It was 14, which was right when the pool
    ## held 64 slots and the whole grid was three rows. At `ITEMS_MAX` = 1,024 that cell
    ## wraps to about 37 rows and 555px, which ran off the bottom of the panel and pushed the
    ## byte accounting under it out of reach; at 10,080 it is ten times worse. So
    ## `sizePoolCell` picks the largest that still fits `HEIGHT_POOL_MAX`, which is the same
    ## rule and the same reading the browser's `CELLS_POOL` follows -- what the two front-ends
    ## agree on is the colour rule and the reading, not the number.
    ##   Checked by rendering it, not inferred from the constant: at 14 the grid genuinely
    ## did run off the panel, which is how this stopped being a constant at all.

  SPACING_POOL_CELL = 1.0'f32
    ## How much `gui.poolBar` leaves between two cells, in pixels; see its own shim.

  HEIGHT_POOL_MAX = 150.0'f32
    ## Bound how tall the object-pool grid may be, in pixels.
    ##   A block a reader takes in at a glance, beside the memory bars it belongs with,
    ## rather than a page they have to scroll past to reach the accounting under it.
  CHANNELS_POOL_CELL = 3
    ## Count the floats one pool cell contributes to `gui.poolBar`'s own buffer: red,
    ## green and blue, with no alpha, since every cell is drawn opaque.
  INK_POOL_FREE = Ink.Grid
    ## Draw a free object-pool slot in the palette's own recessive furniture colour,
    ## which is what an empty slot is: present, but carrying nothing to look at.
  FRAMES_HISTORY* {.define: "visualiser.frames_history".} = 240
    ## Bound how many recent per-frame timings the live diagnostics graph keeps; at a
    ## typical frame rate this covers a few seconds, long enough to see a stutter land
    ## and scroll back off, not so long the graph goes stale reading it.



#[ Type Definitions ]#

type
  EditSession* = object ## Hold what an open edit is staging, before any of it reaches
    ## the scene. One session exists at a time, in one of two modes -- see `slot`.
    slot*: Option[int] ## Item being edited. None while composing a brand-new object,
      ## which has nothing backing it in the scene until its own save commits it.
    coefficients*: array[Basis, cfloat] ## Staged multivector, one coefficient per basis
      ## element, drawn every frame as a muted ghost. Held as `cfloat` because that is
      ## what the drag widget writes.
    label*: array[LABEL_MAX, char] ## Staged label. Staged rather than edited in place
      ## because `gui.inputText` writes straight through the pointer it is handed, and
      ## the scene's own buffer must not change before save.
    index_ink*: cint ## Staged palette slot.

  ItemRow* = object ## Hold what one object row has resolved about itself.
    ## Computed once at the top of `layoutItem` and handed to each part of the row, so
    ## the three agree on what they are drawing rather than each deriving it again.
    slot*: Option[int] ## Item backing the row. None for the composing row, which has
      ## nothing in the scene until its own save commits it.
    is_open*: bool ## Whether this row's own edit session is the one open.
    is_visible*: bool ## Whether the object is shown in the 3D view.
    tint*: Rgba ## Colour the row's name draws in -- staged where a session is open, so
      ## recolouring previews itself.

  Panel* = object ## Hold GUI's own state between frames.
    is_help_open*: bool ## Whether the help panel is showing. Closed at startup: the
      ## legend below the drag line already says the common half, and a reference that
      ## opens itself is one a returning user closes every session.
    session*: Option[EditSession] ## Edit in progress, if any -- see `EditSession`. Its
      ## staged multivector is what `visualiser.assembleMeshes` draws as a ghost, read
      ## later in the same frame this panel writes it, so there is no lag.
    preview*: Option[Preview] ## What an open **apply** control would build, ghosted while
      ## the reader is still choosing it rather than only once `apply` is pressed -- the
      ## rule the drag's own rubber-band already follows.
      ##   Written by whichever apply control is on screen, `layoutApply`'s section or the
      ## selection menu's own picker, and cleared once at the top of every frame by
      ## `layoutPanel`: a section that is closed simply never writes, which is the whole of
      ## "shown while choosing" and needs no second flag to say so.
      ##   Distinct from `session`, and **loses to it** where both stand: an edit session is
      ## being typed into, while this is a passive reading of two pickers. Its own
      ## `Preview.operands` is what has the camera frame the result beside the objects it
      ## came from; see `framing.watched`.
    selection*: Selection ## Items picked right now, in pick order, each drawn ringed by
      ## `visualiser.drawSelectionRing`. Picked through an item row's own checkbox (which
      ## toggles) or its name (which picks that one alone), and replaced outright by every
      ## construction path (a storyboard step, or this session's own last drag-release or
      ## apply-operation click). Cleared by a successful undo or redo, since a restored
      ## snapshot's slot numbers may not match whatever was picked before.
    tween_camera*: CameraTween ## Carries the camera toward whatever is being built or
      ## edited -- see `camera.CameraTween`. Retargeted wherever an object is created or
      ## an edit session stages a change, and advanced once per frame by the caller that
      ## owns the clock (`visualiser.renderFrame`).
    index_operand_first*: cint ## Item picked as left operand.
    index_operand_second*: cint ## Item picked as right operand.
    selection_synced*: Selection ## Last `selection` reading the apply controls were
      ## defaulted against -- lets `layoutApply` re-derive arity and operands from the
      ## selection only the moment the selection actually changes, not every frame: this
      ## panel redraws every frame regardless of whether anything changed, and an
      ## unconditional resync would fight a user's own later manual pick right back to
      ## whatever is selected. Empty until the first sync runs.
    operations*: OperationMemory ## Which operation each arity's picker opens on, carried
      ## from the last apply so a reader applying five wedges in a row picks once.
    index_operation*: cint ## Operation picked from catalogue.
    index_arity*: cint ## Arity filter the operation picker offers: 0 unary, 1 binary,
      ## matching `Arity`'s own ordinals. Filters which operations the picker lists at all,
      ## rather than offering all 27 and greying the second operand for the unary ones.
    is_menu_selection_shown*: bool ## Whether the floating selection menu is on screen --
      ## see `layoutSelectionMenu`. Not derived from the selection being non-empty: every
      ## construction path leaves its own result selected, and a menu appearing over each
      ## new object would sit in the way of the next drag. Raised by the gestures that
      ## *pick* something and lowered by the ones that build, exactly as the browser's own
      ## `refreshSelectionMenu`/`adoptConstructionSelection` pair does.
    is_menu_selection_picking*: bool ## Whether that menu's own operation picker is
      ## revealed, which is what its `apply` button opens before it commits anything.
    position_menu_selection*: array[2, cfloat] ## Where that menu sits, in window pixels.
      ## Kept between frames rather than recomputed from the selection each time: the
      ## object it follows can pass behind the camera, and a menu that vanished or flew to
      ## a corner for those frames would be worse than one that stays put.
    index_operation_menu*: cint ## Operation picked in that menu. Its own reading rather
      ## than the apply section's `index_operation`: the section's list is indexed per
      ## whichever arity the reader last chose *there*, while the menu's is always the
      ## arity the selection implies, so one number could not name a position in both.
    is_grid_shown*: bool ## Whether ground reference grid is drawn.
    is_axes_shown*: bool ## Whether world axes are drawn.
    is_algebra_shown*: bool ## Whether the algebra's own debug layer is drawn over the
      ## scene -- every multivector the frame computed, in its true form, a plane as the
      ## infinite lattice it is rather than the disc that stands for one. Off by default;
      ## see `algebra_view`.
    is_export_requested*: bool ## Whether frame should be written out after drawing.
    is_undo_requested*, is_redo_requested*: bool ## Whether a key asked to step the
      ## timeline. Set by the key handler and consumed by the caller right after layout,
      ## rather than stepping history from inside the event loop: `handleEvent` has no
      ## `History` to step, and routing both the button and the key through one call is
      ## what stops the two drifting apart.
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
      ## see the arenas' own backing storage or the tessellate and timing buffers beside them.


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
  ## Report whether the row is composing an object that does not exist yet.


func showSelectionMenu*(panel: var Panel) =
  ## Bring the floating selection menu up over whatever is picked, closed on the picker.
  ##   Every gesture that *picks* calls this, so the menu is never something a reader has
  ##   to go and find; every gesture that *builds* calls `hideSelectionMenu` instead.
  panel.is_menu_selection_shown = true
  panel.is_menu_selection_picking = false


func hideSelectionMenu*(panel: var Panel) =
  ## Put the floating selection menu away, leaving the selection itself alone.
  panel.is_menu_selection_shown = false
  panel.is_menu_selection_picking = false


func geometry*(session: EditSession): Multivector =
  ## Read what the session is staging, as the multivector saving it would commit.
  ##   Coefficients are held as `cfloat` because that is what the drag widget writes, so
  ##   every reader needs this widening. Written out at each of them once -- the ghost,
  ##   the row's own description line, the save, and the camera's aim -- until one of the
  ##   four drifted from the others was only a matter of time.
  for b in Basis: result[b] = float(session.coefficients[b])


proc stage*(session: var EditSession; geometry: Multivector) =
  ## Load a multivector into the session, as the values its widgets edit.
  ##   Inverse of `geometry` above, and the only other place the two representations meet.
  for b in Basis: session.coefficients[b] = cfloat(geometry[b])
func staged*(panel: Panel): Option[Preview] =
  ## Resolve what this panel is offering as not-yet-committed: an open edit session's own
  ## geometry, else whatever an apply control is previewing, else nothing.
  ##   **The session wins**, and the order is stated here once rather than at the tessellate and
  ##   the camera separately: a session is being typed into, while a preview is a passive
  ##   reading of two pickers, and the one the reader's hands are on is the one to show.
  ##   Its sibling is `browser_bridge.staged`, which answers the same question for the same
  ##   two sources on the other front-end; fix both or neither.
  if panel.session.isSome: return some(previewStaging(panel.session.get.geometry))
  panel.preview




#[ Field Layout ]#

proc widthPushField() =
  ## Size the controls that follow to whatever the line has left once their own names have
  ## taken their column, so a field ends flush with the panel's right edge at any width.
  ##   Fixed widths were tuned against a panel that has since changed width twice, and each
  ##   time left some field stopping short of the edge; there is nothing here a caller
  ##   should have to pick per field.
  gui.widthPush(gui.contentWidth() - WIDTH_LABEL_FIELD)


proc fieldLabel(name: cstring) =
  ## Name a control, to its left, and leave the line open for the control itself.
  ##   Dear ImGui draws a widget's own label to its *right*, which reads backwards: you
  ##   meet the control before being told what it sets. Every control below is therefore
  ##   given a hidden ImGui label (`##name`, which still identifies it) and its name is
  ##   written here first. `sameLineAt` puts every control in one column, so a short name
  ##   and a long one do not stagger their controls.
  gui.textTinted(name, INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue)
  gui.sameLineAt(WIDTH_LABEL_FIELD)



#[ Objects Panel ]#

proc layoutCoefficientGrid(staged: var array[Basis, cfloat]): Option[Basis] =
  ## Lay out one drag widget per basis coefficient, each under its own basis name, at most
  ## six to a line, each grade starting a fresh line; report which coefficient changed.
  ##   Grade comes from the library's own `grade`, so nothing here hardcodes a dimension,
  ##   and a grade never shares a line with its neighbour. In this build's 4D metric the
  ##   grades hold 1, 4, 6, 4 and 1 elements, so every one of them fits a single line.
  ##   Name above its cell rather than beside it, matching the browser's own `.coeff-grid`.
  ##   Beside costs every cell the width of the longest name whether or not it needs it,
  ##   which is what forced the panel out to 680 px; above costs one line of text per grade
  ##   and lets the panel sit at a width the rest of the UI actually wants.
  ##   Cells divide the line they are on rather than a fixed sixth of it, so a grade fills
  ##   its own row -- the scalar's lone cell spans the panel, grade 1's four take a quarter
  ##   each. This is the browser's `flex: 1 1 56px` written out: six per line is the wrap
  ##   point, not the divisor.
  ##   `groupBegin`/`groupEnd` is what makes a name and its widget advance `sameLine` as one
  ##   item; Dear ImGui has no notion of a labelled cell.
  ##   Only one change is reported per frame, which is all a pointer can make.
  # Read once, before anything is placed: `contentWidth` reports what is left on the
  #   current line, which is no longer the whole line once a cell sits on it.
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
      # Name recedes and the number reads: both are on screen at once, and only one of
      #   them changes. Matches the browser, where a field's own label is `--ink-faint`.
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
  ## Open an edit session against `slot`, or a composing one where slot is none.
  ##   A composing session starts on the same auto-label and cycled ink every other
  ##   construction path assigns, leaving both editable before the object exists.
  ##   Does not aim the camera itself: the session's own staged geometry is offered to the
  ##   tween every frame by `layoutObjects` below, which covers the moment it opens too.
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
  ## Lay out the label, colour and coefficient controls an open session stages.
  ##   Everything here writes into the session, never the scene: the row above previews
  ##   the change and the ghost previews the geometry, but nothing lands until save.
  widthPushField()
  fieldLabel("label")
  discard gui.inputText("##label", toCstring(panel.session.get.label), cint(LABEL_MAX))
  # Offer the categorical run alone: the structural slots before it belong to the drawing's
  #   own furniture, and the combo therefore counts positions within that run rather than
  #   whole-palette ordinals. Names come from the shared table at its own offset, since the
  #   run is contiguous -- see `tessellate.COUNT_INK_CATEGORICAL` for what holds that true.
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
  ## Lay out the row's leading checkbox and its name.
  ##   Checkbox toggles membership, the way the browser's own row checkbox does, so a
  ##   second and third object join the selection in the order they were picked -- that
  ##   order is what names operands m and n over in `layoutApply`. The name beside it
  ##   picks that one object alone: the browser gets single-select from a plain canvas
  ##   click, which this build has no equivalent of, so the row carries both gestures.
  var is_selected = (not row.isPending) and row.slot.get in panel.selection
  gui.disabledPush(row.isPending) # Nothing to select until it exists.
  if gui.checkbox("", addr is_selected):
    panel.selection.toggle(row.slot.get)
    panel.showSelectionMenu() # Picking from the list is picking; see its own doc.
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
  ## Lay out the row's own actions; report whether user asked for the object to go.
  ##   Longer than the sixty-line default, and not split further: the run's whole width
  ##   has to be measured before any of it is placed, so the buttons after that
  ##   measurement cannot move out without measuring them twice and letting the two
  ##   readings drift.
  ##   Buttons end flush against the panel's own right edge, as the browser's row does,
  ##   so they form one column down the list instead of starting wherever each name
  ##   happens to end. Their run has to be measured before any of it is placed, which is
  ##   what `buttonSmallWidth` is for.
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
    # Abandon: a composing row vanishes with nothing added, an editing row reverts. The
    #   scene was never touched either way, so this only has to drop the session.
    gui.sameLine()
    if gui.buttonSmall("✕"): panel.session = none(EditSession)
    gui.tooltip(
      if row.isPending: cstring"Discard this new object."
      else: cstring"Discard these changes."
    )

  # Hide and remove act on the object as the scene holds it, which is exactly what an open
  #   session is staging a replacement for -- offering them mid-edit invites acting on one
  #   version while looking at another. Absent for a composing row for the same reason its
  #   own object does not exist yet.
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
  ## Lay out the row's own shape word and coefficients, on one line.
  ##   Built into a stack buffer rather than a `string`, since every visible item redraws
  ##   this line every frame; a fresh heap string per item per frame is exactly the kind
  ##   of allocator churn an arena-backed scene should not turn around and reintroduce.
  ##   Shape word first on the same line as the coefficients, matching the browser's own
  ##   `point: 3e1 - 2e2 ...` -- two separate lines doubled every row's height for a word
  ##   that reads as a prefix to the equation anyway.
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
  ##   A none `slot` lays out the composing row instead: same shape, but nothing backs it
  ##   in the scene, so it takes its values from the session and leaves out the buttons
  ##   that act on an object that exists (hide, remove).
  ##   A hidden item's whole row dims rather than disappearing, so it stays readable and
  ##   its own show button stays clickable -- `alphaPush`, not `disabledPush`.
  ##   An orchestrator over the row's three parts, which is what the row is: a name, the
  ##   actions on it, and what it currently says.
  let is_pending = slot.isNone
  gui.idPush(if is_pending: cint(ITEMS_MAX) else: cint(slot.get))
  defer: gui.idPop()

  let row = block:
    let is_open = is_pending or
      (panel.session.isSome and panel.session.get.slot == slot)
    ItemRow(
      slot: slot,
      is_open: is_open,
      is_visible: is_pending or scene.isVisible(slot.get),
      tint:
        if is_open: Ink(panel.session.get.index_ink).colour
        else: scene.inkAt(slot.get).colour,
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
  ## Lay out every live item's controls, plus the row being composed if there is one,
  ## applying at most one removal per frame.
  ##   One per frame is enough, since a click can only land on one button.
  ##   `now` is forwarded to whichever row commits a fresh object this frame, so it
  ##   animates in from the moment it appears.
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

  # A composing row heads the list: it is the newest thing here, and it has no `born`
  #   reading to sort by since nothing backs it in the scene yet.
  if is_composing: discard layoutItem(panel, scene, camera, history, none(int), now)

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
  ## Lay out the controls reached for constantly, above every collapsing section: start a
  ## new object, toggle world furniture, and save or load the scene.
  ##   These sit outside the sections for the same reason the browser's own chip row and
  ##   menu hold them -- each is either flipped repeatedly while working or applies to the
  ##   whole scene, so neither should cost opening a section first. `add` in particular
  ##   has to live outside `objects`, since pressing it opens that section.
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
  # "debug", matching the browser chip and the diagnostics tree's "debug overlay" row:
  #   a control called algebra reads as the subject of the whole app, not the wireframe.
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
    # This frame's own clock, so the file arrives as a replay of its construction rather
    #   than whole; see `scene.bornReplaying`.
    toChars(loadScene(scene, toText(panel.path_scene), now), panel.message)
    # A loaded scene's slots are not the ones any open session was opened against.
    panel.session = none(EditSession)


proc offerOperationsOfArity*(
  arity: Arity
): (array[COUNT_OPERATION, cstring], array[COUNT_OPERATION, Operation], int) =
  ## List the catalogue's operations of one arity, with the notation each is offered
  ## under and the operation each offered position names.
  ##   Only the operations of the chosen arity, rather than all of them with the second
  ##   operand greyed out for the unary ones: the catalogue is long enough that halving
  ##   it is the difference between scanning and hunting.
  ##   Reports the operations alongside the notations because a combo hands back a dense
  ##   position, which names nothing on its own once the list has been filtered.
  ##   The `cstring`s handed back point into this build's own storage rather than at the
  ##   `const` table they are taken from, which is what a combo needs: it keeps the address
  ##   of the first entry and reads through it for as long as the list is open.
  for operation in Operation:
    if lut_operation_to_arity[operation] != arity: continue
    result[0][result[2]] = cstring(notationSymbolic(operation))
    result[1][result[2]] = operation
    inc result[2]


proc adoptSelectionAsOperands(
  panel: var Panel; slots: openArray[int]; count: int
) =
  ## Fill the arity and operand pickers in from whatever is selected in the 3D view.
  ##   Everything the selection already says is taken rather than asked for a second
  ##   time: how many objects are picked names the arity, and the order they were picked
  ##   names m and n. Only right when the selection itself changes -- see
  ##   `selection_synced`'s own doc -- so a later manual pick of either still sticks.
  if panel.selection == panel.selection_synced: return
  panel.selection_synced = panel.selection
  if panel.selection.len == 0: return

  func positionOf(slots: openArray[int]; count, slot: int): Option[cint] =
    ## Translate a slot back to the operand combo's own dense position.
    for position in 0 ..< count:
      if slots[position] == slot: return some(cint(position))

  let arity_implied = cint(ord(panel.selection.impliedArity))
  if panel.index_arity != arity_implied:
    # A filtered operation list is indexed per arity, so a position carried across from
    #   the other list names an unrelated operation -- the arity control resets the same
    #   way for the same reason.
    panel.index_arity = arity_implied
    panel.index_operation = 0
  let position_first = positionOf(slots, count, panel.selection.at(0))
  if position_first.isSome: panel.index_operand_first = position_first.get
  if panel.selection.len >= 2:
    let position_second = positionOf(slots, count, panel.selection.at(1))
    if position_second.isSome: panel.index_operand_second = position_second.get


proc openSelectionMenuPicker*(panel: var Panel) =
  ## Reveal the selection menu's own operation picker, on the operation last applied at
  ## whichever arity the selection implies.
  ##   Shared by that menu's `apply` button and by the drag wheel's `more…`, which lands
  ##   here rather than in the drawer-side apply section: `more…` is a fifth choice on a
  ##   wheel that opened under the cursor, and sending it across to a panel buried the two
  ##   objects it had just named under every other control. See `visualiser.handleEvent`.
  let
    arity = panel.selection.impliedArity
    (_, operations, count_offered) = offerOperationsOfArity(arity)
    wanted = panel.operations.lastOf(arity)
  panel.is_menu_selection_shown = true
  panel.is_menu_selection_picking = true
  # The head of the list unless the remembered operation is in it: the list is per arity,
  #   so a position carried over from the other one would name an unrelated operation.
  panel.index_operation_menu = 0
  for index in 0 ..< count_offered:
    if operations[index] == wanted:
      panel.index_operation_menu = cint(index)
      break


proc applyPickedOperation(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  operation: Operation; first, second: int; now: float
) =
  ## Derive a fresh object from the picked operation and operands, and say what it gave.
  ##   Leaves the result solely selected, which is what carries the camera to it: the
  ##   standing aim in `visualiser.offerCameraAim` reads exactly that, so this path needs
  ##   to know nothing about the camera.
  ##   Takes the two operands as *slots*, not as positions in a picker's own list: the
  ##   apply section reads them off its combos and the floating selection menu reads them
  ##   straight off the selection, and neither should have to learn the other's indexing.
  ##   A unary operation is applied by naming the same slot twice, which is what its
  ##   caller has to decide anyway.
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
  ##   Longer than the sixty-line default, and not split further: what is left after the
  ##   catalogue filter, the selection adoption and the apply itself moved out is one run
  ##   of controls over one set of offer lists, and those lists live exactly as long as
  ##   the controls indexing them do -- the item names are `cstring`s borrowed from the
  ##   scene's own label storage, so handing them across another boundary would be
  ##   lending out a pointer for no gain.
  if not gui.header("apply", is_open_first = false): return
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

  adoptSelectionAsOperands(panel, slots, count)

  let arity_wanted = Arity(panel.index_arity)
  let (notations, operations, count_offered) = offerOperationsOfArity(arity_wanted)

  # Arity is a segmented control rather than a dropdown: there are exactly two choices,
  #   both worth seeing at once, and switching should cost one click. Matches the
  #   browser's own `.toggles` pill.
  const lut_arity_to_name = [Arity.One: cstring"unary", Arity.Two: cstring"binary"]
  fieldLabel("arity")
  let width_segment = (gui.contentWidth() - SPACING_SEGMENT)/2.0'f32
  for arity in Arity:
    if arity != Arity.low: gui.sameLine()
    if gui.buttonToggle(
      lut_arity_to_name[arity], panel.index_arity == cint(ord(arity)), width_segment
    ):
      panel.index_arity = cint(ord(arity))
      # A filtered operation list is indexed per arity, so a position carried across from
      #   the other list names an unrelated operation. Land on whatever was last applied
      #   at the arity being switched to, rather than on the head of its list.
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
      else: first # A unary operation ignores its second operand; naming the first
        # keeps a stale picker reading from ever reaching `applyOperation`.
  # Ghost what `apply` would build, from the very three readings the button below passes
  #   to `applyPickedOperation` -- so the preview cannot name a different construction
  #   from the commit. Resolved here rather than inside the button so it follows the
  #   pickers as they are worked, which is the whole point of previewing at all; this
  #   section returns early while its header is closed, so a closed one previews nothing.
  panel.preview = scene.previewApplying(operation, first, second)

  gui.disabledPush(scene.isFull)
  if gui.buttonWide("apply", gui.contentWidth()):
    applyPickedOperation(panel, scene, camera, history, operation, first, second, now)
    panel.hideSelectionMenu() # Built something; see `showSelectionMenu`.
  gui.disabledPop()



#[ View Panel ]#

proc layoutView*(panel: var Panel; camera: var Camera) =
  ## Lay out camera placement and frame export.
  ##   World furniture toggles moved to `layoutTopBar` -- they are flipped constantly
  ##   while orbiting, so they should not cost opening a section first.
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
  # Unbounded at the widget, floored by `distanceHeld` on the way in: there is no ceiling
  #   on how far the camera may orbit, and the one value it may not take is stated in
  #   `camera` rather than repeated in a widget's own bounds.
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
  ## Lay out the "frame time" section: rolling frame-time plot, vsync toggle, current
  ## rate, tessellation cost.
  gui.separatorText("frame time")
  var highest = 16.6'f32 # Floor the range at 60fps, so a smooth run doesn't zoom in on noise.
  for value in panel.milliseconds_history:
    if value > highest: highest = value
  var overlay: array[WIDTH_OVERLAY_TEXT, char]
  let text_now = buildChars(overlay):
    appendFixed(overlay, cursor, 1000.0/max(float(gui.framerate()), 1.0), 2)
    appendChars(overlay, cursor, " ms now")
  # Full panel width, passed rather than left at 0: Dear ImGui reads a zero width as its
  #   own default *item* width, which is two thirds of the window, and a graph beside two
  #   thirds of a bar reads as one of them being broken.
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
  ## Lay out the "memory" section: permanent and per-frame arena usage bars.
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
  ## Report the side to draw one object-pool cell at, for a panel this wide.
  ##   The largest offered whose wrapped grid still fits `HEIGHT_POOL_MAX`, or the smallest
  ## offered where none does -- every slot keeps a cell either way, which is the property
  ## that matters, and only how big it is gives.
  for side in SIZES_POOL_CELL:
    let
      columns = max(1, int(width/(side + SPACING_POOL_CELL)))
      rows = (ITEMS_MAX + columns - 1) div columns
    if float32(rows)*(side + SPACING_POOL_CELL) <= HEIGHT_POOL_MAX: return side
  SIZES_POOL_CELL[len(SIZES_POOL_CELL) - 1]


proc layoutDiagnosticsObjectPool(scene: Scene) =
  ## Lay out the "object pool" section: live/free slot strip and byte accounting.
  gui.separatorText("object pool")
  # An occupied cell wears its own object's ink, so the strip reads as the scene rather
  #   than as an anonymous occupancy count: which slot a given object sits in, and how
  #   `inkCycled` has spread the palette so far, are both legible at a glance.
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
  ## Lay out the "total" section: every fixed reservation this binary makes, added up.
  gui.separatorText("total")
  var total: array[WIDTH_OVERLAY_TEXT, char]
  let text_total = buildChars(total):
    appendFixed(total, cursor, float(panel.bytes_memory_total) / (1024.0*1024.0), 1)
    appendChars(total, cursor, " MB")
  gui.text(text_total)
  # Folded to one literal rather than concatenated at the call, so the depth is still read
  #   from `CAPACITY_HISTORY` and the tooltip is still a `cstring` pointing at static text.
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
  ## is needed to use the visualiser, only to understand what using it costs.
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
  ## Step the timeline one way, putting the view back where the restored edit was made,
  ## and drop whatever an open edit was staged against.
  ##   Reports whether anything moved, so a caller may say so.
  ##   One proc for the buttons and for the keys that do the same thing: a restored
  ##   snapshot's slot numbers need not match the ones a session or a selection was
  ##   holding, and that consequence is easy to remember in one place and easy to forget
  ##   in the second.
  ##   Abandons the standing tween, which is aiming at whatever was last selected: left
  ##   running it would drag the view straight off the placement just restored.
  result = if is_undo: history.undo(scene, camera) else: history.redo(scene, camera)
  if result:
    panel.selection.clear()
    panel.session = none(EditSession)
    panel.hideSelectionMenu()
    panel.tween_camera.abandon()



#[ Selection Menu ]#

const
  OFFSET_MENU_SELECTION = 46.0'f32
    ## Lift the menu this far above the object it follows, in pixels.
    ##   Above rather than on: an ImGui window makes `gui.wantsMouse` true wherever it
    ## sits, and a menu straddling its own object would swallow the next drag off that
    ## object. Far enough to clear the selection marker drawn around it too, so the menu
    ## never hides the thing it names. Matches the browser's own 60-pixel lift, less the
    ## height this row draws at, which the browser measures in CSS pixels rather than the
    ## framebuffer ones this window is placed in.
  MARGIN_MENU_SELECTION = 8.0'f32
    ## Keep the menu at least this far inside the viewport, so an object near an edge does
    ## not push half of it off screen.
  PADDING_MENU_PICKER = 36.0'f32
    ## Slack added to the widest notation offered, for the combo's own frame and arrow.

proc layoutSelectionMenuApply(
  panel: var Panel; scene: var Scene; camera: Camera; history: var History;
  now: float
) =
  ## Lay out the menu's `apply` button and the operation picker it reveals beside it.
  ##   One button in both roles: the first press opens the picker, the second commits
  ##   whatever it is showing. `apply` itself never moves or relabels while that happens,
  ##   so the picker reads as opening *out of* it rather than replacing it.
  ##   Only for one or two picked objects; three or more have no operand pickers here, so
  ##   this menu cannot say which two of them it would use, and it offers nothing rather
  ##   than guessing. Matches the browser's own `refreshSelectionMenu`.
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

  # Ghost whatever the picker is showing, from the same two slots and the same index the
  #   button above commits with. Only while the picker is revealed: `apply` closed is a
  #   button that has offered nothing yet, and previewing behind it would put an object on
  #   screen that nothing on screen names.
  #   Written after `visualiser.offerCameraAim` has run this frame, so the camera takes it
  #   up on the next one; the offer is re-made every frame, so that costs a frame and
  #   nothing else.
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
  ## Lay out the floating menu over whatever is picked: apply, edit, hide, delete, close.
  ##   Follows the *most recently* picked object rather than the middle of them all, which
  ##   would jump around as membership changes for no gain. `anchor` is where that object
  ##   is on screen; none where it is behind the camera, which leaves the menu where it
  ##   last was rather than flinging it to a corner.
  ##   Longer than the sixty-line default and not split further: past `apply`, which has
  ##   its own proc above, this is one run of buttons whose only shared state is which of
  ##   them is on the line so far, and threading that through another boundary would buy
  ##   nothing.
  if not panel.is_menu_selection_shown or panel.selection.len == 0: return
  if anchor.isSome:
    panel.position_menu_selection = [
      anchor.get.x,
      max(anchor.get.y - OFFSET_MENU_SELECTION, MARGIN_MENU_SELECTION),
    ]
  let count = panel.selection.len
  var is_line_started = false # Whether anything is on the row yet, so the first button
    # placed does not ask for a `sameLine` that has nothing to continue.
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

    # Edit and the two bulk actions stand aside while an operation is being picked, so the
    #   row stays one line at any width. Closing the menu stays reachable throughout.
    if not panel.is_menu_selection_picking:
      if count == 1:
        if is_line_started: gui.sameLine()
        is_line_started = true
        if gui.buttonSmall("edit"):
          beginSession(panel, scene, some(panel.selection.at(0)))
          panel.hideSelectionMenu() # The panel owns it now; the pick itself stays.
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
        # Read the slots out before removing any: removal prunes the selection this loop
        #   would otherwise be walking.
        var slots: array[ITEMS_MAX, int]
        for position in 0 ..< count: slots[position] = panel.selection.at(position)
        # An open session against one of these has nothing left to commit against, the
        #   same guard `layoutObjects` keeps around its own single removal.
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
    ## Hold the help affordance this far off the bottom-right corner, in pixels.
  GAP_HELP_COLUMN = 18.0'f32
    ## Separate an entry's action from its outcome by at least this much, so the two
    ## columns read as columns rather than as one run-on line.
  MARGIN_HELP_PANEL = 96.0'f32
    ## Leave this much of the window unclaimed by the help panel: the `?` button below it,
    ## the tab strip above its rows, and the window's own frame.

func helpActionOf(entry: HelpEntry): string =
  ## Write one entry's action as the panel draws it, indent and touch marker included.
  ##   One writer, because the column is sized by measuring exactly what is then drawn.
  "  " & entry.action & (if entry.is_touch: "  (touch)" else: "")


proc layoutHelp*(panel: var Panel; path_forced: Option[HelpPath] = none(HelpPath)) =
  ## Lay out the help affordance: a `?` pinned to the bottom-right corner, and the panel
  ## it opens.
  ##   Sited in the corner rather than inside the panel window because it has to be
  ##   reachable when the panel is the thing a reader does not yet understand, and
  ##   because the browser build puts it in the same corner -- the two UIs are 1-1 here as
  ##   everywhere else, down to what the panel says, which both read from `help.nim`.
  ##   `path_forced` opens one tab whatever the reader last chose. Only `--drive-help`
  ##   passes it: a headless run cannot click a tab strip, and a help panel no capture can
  ##   reach is one whose rows nobody ever checks fit.
  let (width, height) = (gui.viewportWidth(), gui.viewportHeight())
  if gui.windowBeginPinned(
    "##help_open", width - MARGIN_HELP, height - MARGIN_HELP, 1.0, 1.0
  ):
    if gui.button("  ?  "): panel.is_help_open = not panel.is_help_open
  gui.windowEnd()

  if not panel.is_help_open: return
  # Where the outcome column starts, and how wide the pair is, measured from the widest
  #   entries there actually are rather than set by eye: an entry longer than whatever was
  #   longest when this was written would otherwise run straight into its own outcome,
  #   which is precisely what a hand-tuned number did here first time out. Measured only
  #   while the panel is open -- every frame of a storyboard capture was paying for the
  #   whole table's text metrics to draw nothing.
  var offset_outcome, width_outcome = 0.0'f32
  for entry in lut_help_entries:
    offset_outcome = max(offset_outcome, gui.textWidth(cstring(helpActionOf(entry))))
    width_outcome = max(width_outcome, gui.textWidth(cstring(entry.outcome)))
  offset_outcome += GAP_HELP_COLUMN
  if gui.windowBeginPinned(
    "##help_panel", width - MARGIN_HELP, height - MARGIN_HELP - 44.0, 1.0, 1.0
  ):
    # One tab per path, because a reader opens this in the middle of one way of working
    #   and only that way's rows are any use to them right then. The window auto-sizes and
    #   grows *upward* from the corner, with no scrollbar of its own, so a tall enough
    #   panel silently loses its top rows off the screen; the region below is bounded to
    #   what the window actually has and scrolls instead. `ENTRIES_MAX_PATH` is what keeps
    #   that scrollbar from ever being the way this is read -- it is the safety net.
    let
      # Sized from both columns, not left to fill whatever is available: a bounded region
      #   asked to fill nothing in an auto-sizing window collapses to its widest *item*,
      #   and every outcome, placed by `sameLineAt` past that, is then clipped away.
      width_rows = offset_outcome + width_outcome + GAP_HELP_COLUMN
      height_available = height - MARGIN_HELP_PANEL
    if gui.tabBarBegin("##help_tabs"):
      for path in HelpPath:
        if not gui.tabBegin(cstring(titleOf(path)), path_forced == some(path)): continue
        # What the tab is about, before the rows that assume it. Wrapped rather than
        #   truncated, and drawn outside the rows child so it stays put while they scroll:
        #   a sentence that scrolls away is one a reader loses exactly when they need it.
        gui.textWrappedAt(cstring(descriptionOf(path)), width_rows)
        # Each tab is as tall as its own rows need, up to what the window has: a fixed
        #   height sized for the largest would leave `menu`'s five rows floating in a
        #   third of a panel of blank.
        let height_rows = min(
          gui.childHeightForRows(cint(countOf(path))), height_available
        )
        if gui.childBegin(cstring("##help_rows"), width_rows, height_rows):
          for entry in lut_help_entries:
            if entry.path != path: continue
            # The touch rows say so in a word rather than only in a tint, so which input a
            #   line describes survives a reader who cannot tell two greys apart.
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
  ##   `now` is this frame's own clock reading, passed through to whichever construct
  ##   control adds an item this frame, so it animates in from the moment it appears.
  # Drop last frame's apply preview here, so only a control actually on screen this frame
  #   can put one back. A closed section simply never writes, which is the whole of "shown
  #   while choosing" -- no flag says whether a section is open, because the section's own
  #   early return already does.
  panel.preview = none(Preview)
  gui.windowPlace(16.0, 16.0, WIDTH_PANEL, 720.0)
  if gui.windowBegin("RGA visualiser"):
    # Coloured words match the rubber-band drawn while dragging, so a line on screen names
    #   its own outcome before it is released. Which colour belongs to which is
    #   `interaction.inkOf`'s to say, so this legend cannot come to disagree with what is
    #   actually drawn.
    #   **This is where the three symbols are taught.** The wheel's own wedges say
    #   `𝐦 ∧ 𝐧` (see `interaction.labelOf`), which is the picker's text and unreadable to
    #   anyone who has not been told once that it is `join` -- so the word and the notation
    #   appear here together, both read from `interaction`. Its sibling is the browser's
    #   own `.drawer-intro` line in `shell.html`, which says the same thing in markup.
    gui.textWrapped("Drag one object onto another; the two of them choose what it makes:")
    for choice in [DragChoice.Join, DragChoice.Meet, DragChoice.Project]:
      let tint = inkOf(choice).colour
      gui.textTinted(
        cstring(wordOf(choice) & "  " & labelOf(choice)), tint.red, tint.green, tint.blue
      )
    gui.textWrapped("Right-drag to pick instead; on a touchscreen, hold still over the target.")

    # Scene-content edits only -- an orbit is not a step of its own, though each step
    #   restores the view it was made from; see `history.nim`. Each button greys out where
    #   its own side of the timeline is empty, rather than staying live and reporting
    #   "nothing to undo" only once pressed. A successful step drops any open session too:
    #   a restored snapshot's slot numbers need not match the one it was opened against.
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

    # Sections in alphabetical order, matching the browser's own drawer, with `objects`
    #   the one open by default: it is what a returning session looks at first, and the
    #   rest are reached for deliberately.
    layoutApply(panel, scene, camera, history, now)
    layoutDiagnostics(panel, scene)
    layoutObjects(panel, scene, camera, history, now)
    layoutView(panel, camera)
    gui.separator()
    gui.text(toCstring(panel.message))
  gui.windowEnd()
