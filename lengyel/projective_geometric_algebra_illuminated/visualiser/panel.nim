## Lay out panels user edits scene and camera through.
##
## Workbench holds what the GUI needs between frames and the scene does not own:
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
## buries the 3D view the workbench exists to show.
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

import ../pga
import ./[camera, format, gui, history, mesh, objects, scene, selection]



#[ Workbench Configuration ]#

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
  WIDTH_ITEM_LINE = 640
    ## Bound one item's shape-and-coefficient line in *bytes*, redrawn every frame. Sized
    ## for the worst case that line can reach: the longest shape word plus all sixteen
    ## basis terms written out, which a mixed-grade object genuinely does print. A basis
    ## name costs up to 13 bytes rather than 5, since the library names elements in
    ## mathematical bold with subscript digits; the buffer counts bytes, and truncating a
    ## line mid-name would leave a half-written codepoint for the GUI to draw.
  WIDTH_SHAPE_WORD = 32
    ## Bound length of the shape word alone, longest being "mixed grade, nothing to draw".
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
  SIZE_POOL_CELL = 14.0'f32
    ## Set the side of one object-pool cell, in pixels -- large enough that a categorical
    ## ink is recognisable in it, small enough that all 64 slots fit a few panel rows.
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

  Workbench* = object ## Hold GUI's own state between frames.
    session*: Option[EditSession] ## Edit in progress, if any -- see `EditSession`. Its
      ## staged multivector is what `visualiser.assembleMeshes` draws as a ghost, read
      ## later in the same frame this panel writes it, so there is no lag.
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


proc beginSession(workbench: var Workbench; scene: var Scene; slot: Option[int]) =
  ## Open an edit session against `slot`, or a composing one where slot is none.
  ##   A composing session starts on the same auto-label and cycled ink every other
  ##   construction path assigns, leaving both editable before the object exists.
  ##   Does not aim the camera itself: the session's own staged geometry is offered to the
  ##   tween every frame by `layoutObjects` below, which covers the moment it opens too.
  var session = EditSession(slot: slot)
  if slot.isSome:
    for b in Basis: session.coefficients[b] = cfloat(scene.geometryAt(slot.get)[b])
    session.label = scene.labelAt(slot.get)
    session.index_ink = cint(scene.inkAt(slot.get))
  else:
    toChars(&"m{scene.len}", session.label)
    session.index_ink = cint(inkCycled(scene.len))
  workbench.session = some(session)


proc layoutSessionFields(workbench: var Workbench; is_pending: bool) =
  ## Lay out the label, colour and coefficient controls an open session stages.
  ##   Everything here writes into the session, never the scene: the row above previews
  ##   the change and the ghost previews the geometry, but nothing lands until save.
  widthPushField()
  fieldLabel("label")
  discard gui.inputText("##label", toCstring(workbench.session.get.label), cint(LABEL_MAX))
  # Offer the categorical run alone: the structural slots before it belong to the drawing's
  #   own furniture, and the combo therefore counts positions within that run rather than
  #   whole-palette ordinals. Names come from the shared table at its own offset, since the
  #   run is contiguous -- see `mesh.COUNT_INK_CATEGORICAL` for what holds that true.
  var index_categorical = cint(categoricalIndex(Ink(workbench.session.get.index_ink)))
  fieldLabel("colour")
  if gui.combo(
    "##colour", addr index_categorical,
    addr lut_ink_to_name[INK_CATEGORICAL_FIRST], cint(COUNT_INK_CATEGORICAL),
  ):
    workbench.session.get.index_ink = cint(ord(inkCategorical(int(index_categorical))))
  gui.widthPop()
  gui.textTinted("coefficients", INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue)
  gui.sameLine()
  gui.helpMarker(
    if is_pending: HELP_COEFFICIENTS_PENDING else: HELP_COEFFICIENTS_EDITING
  )
  discard layoutCoefficientGrid(workbench.session.get.coefficients)


proc layoutItem(
  workbench: var Workbench; scene: var Scene; history: var History; slot: Option[int];
  now: float
): bool =
  ## Lay out one item's controls; report whether user asked for it to be removed.
  ##   A none `slot` lays out the composing row instead: same shape, but nothing backs it
  ##   in the scene, so it takes its values from the session and leaves out the buttons
  ##   that act on an object that exists (hide, remove).
  ##   A hidden item's whole row dims rather than disappearing, so it stays readable and
  ##   its own show button stays clickable -- `alphaPush`, not `disabledPush`.
  let is_pending = slot.isNone
  gui.idPush(if is_pending: cint(ITEMS_MAX) else: cint(slot.get))
  defer: gui.idPop()

  let
    is_open = is_pending or
      (workbench.session.isSome and workbench.session.get.slot == slot)
    is_visible = is_pending or scene.isVisible(slot.get)
    tint =
      if is_open: Ink(workbench.session.get.index_ink).colour
      else: scene.inkAt(slot.get).colour
  if not is_visible: gui.alphaPush(ALPHA_ITEM_HIDDEN)
  defer:
    if not is_visible: gui.alphaPop()

  # Checkbox toggles membership, the way the browser's own row checkbox does, so a second
  #   and third object join the selection in the order they were picked -- that order is
  #   what names operands m and n over in `layoutApply`. The name beside it picks that one
  #   object alone: the browser gets single-select from a plain canvas click, which this
  #   build has no equivalent of, so the row carries both gestures instead.
  var is_selected = (not is_pending) and slot.get in workbench.selection
  gui.disabledPush(is_pending) # Nothing to select until it exists.
  if gui.checkbox("", addr is_selected): workbench.selection.toggle(slot.get)
  gui.disabledPop()
  gui.tooltip("Add this object to the selection, or drop it; the 3D view rings each one.")
  gui.sameLine()

  let label_shown =
    if is_open: toCstring(workbench.session.get.label) else: toCstring(scene.labelAt(slot.get))
  gui.textColorPush(tint.red, tint.green, tint.blue)
  if gui.selectable(label_shown, is_selected, WIDTH_ITEM_LABEL) and not is_pending:
    if is_selected and workbench.selection.len == 1: workbench.selection.clear()
    else: workbench.selection.selectOnly(slot.get)
  gui.textColorPop()

  # Buttons end flush against the panel's own right edge, as the browser's row does, so
  #   they form one column down the list instead of starting wherever each name happens to
  #   end. Their run has to be measured before any of it is placed, which is what
  #   `buttonSmallWidth` is for.
  let
    label_commit = if is_open: cstring"save" else: cstring"edit"
    width_buttons =
      gui.buttonSmallWidth(label_commit) +
      (if is_open: gui.buttonSmallWidth("✕") + SPACING_SEGMENT else: 0.0'f32) +
      (
        if is_pending or is_open: 0.0'f32
        else:
          gui.buttonSmallWidth(if is_visible: cstring"hide" else: cstring"show") +
          gui.buttonSmallWidth("remove") + 2.0'f32*SPACING_SEGMENT
      )
  gui.alignRight(width_buttons)
  if gui.buttonSmall(label_commit):
    if not is_open:
      beginSession(workbench, scene, slot)
    else:
      let session = workbench.session.get
      var geometry: Multivector
      for b in Basis: geometry[b] = float(session.coefficients[b])
      if is_pending:
        let slot_added =
          scene.addItem(geometry, $toCstring(session.label), Ink(session.index_ink), now)
        workbench.selection.selectOnly(slot_added)
      else:
        scene.geometryAt(slot.get) = geometry
        scene.labelAt(slot.get) = session.label
        scene.setInk(slot.get, Ink(session.index_ink))
      history.record(scene)
      workbench.session = none(EditSession)
  gui.tooltip(
    if is_open: cstring"Commit these values to the scene."
    else: cstring"Rename, recolour or reshape this object; nothing changes until you save."
  )

  if is_open:
    # Abandon: a composing row vanishes with nothing added, an editing row reverts. The
    #   scene was never touched either way, so this only has to drop the session.
    gui.sameLine()
    if gui.buttonSmall("✕"): workbench.session = none(EditSession)
    gui.tooltip(
      if is_pending: cstring"Discard this new object." else: cstring"Discard these changes."
    )

  # Hide and remove act on the object as the scene holds it, which is exactly what an open
  #   session is staging a replacement for -- offering them mid-edit invites acting on one
  #   version while looking at another. Absent for a composing row for the same reason its
  #   own object does not exist yet.
  if not (is_pending or is_open):
    gui.sameLine()
    if gui.buttonSmall(if is_visible: cstring"hide" else: cstring"show"):
      scene.setVisible(slot.get, not is_visible)
      history.record(scene)
    gui.tooltip("Show or hide this object without removing it.")
    gui.sameLine()
    result = gui.buttonSmall("remove")
    gui.tooltip("Delete this object; its slot is reused by the next one you add.")

  # Built into a stack buffer rather than a `string`, since every visible item redraws
  #   this line every frame; a fresh heap string per item per frame is exactly the kind
  #   of allocator churn an arena-backed scene should not turn around and reintroduce.
  #   Shape word first on the same line as the coefficients, matching the browser's own
  #   `point: 3e1 - 2e2 ...` -- two separate lines doubled every row's height for a word
  #   that reads as a prefix to the equation anyway.
  var geometry_shown: Multivector
  if is_open:
    for b in Basis: geometry_shown[b] = float(workbench.session.get.coefficients[b])
  else:
    geometry_shown = scene.geometryAt(slot.get)
  var line: array[WIDTH_ITEM_LINE, char]
  let description = buildChars(line):
    appendChars(line, cursor, "  ")
    describeShape(geometry_shown, line, cursor)
    appendChars(line, cursor, ": ")
    formatMultivector(geometry_shown, line, cursor)
  gui.textWrapped(description)

  if is_open: layoutSessionFields(workbench, is_pending)
  gui.separator()


proc layoutObjects*(
  workbench: var Workbench; scene: var Scene; history: var History; now: float
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
    workbench.session.isSome and workbench.session.get.slot.isNone
  if scene.len == 0 and not is_composing:
    gui.text("Nothing here yet -- press `add` above, or drag between two objects.")
    return

  # A composing row heads the list: it is the newest thing here, and it has no `born`
  #   reading to sort by since nothing backs it in the scene yet.
  if is_composing: discard layoutItem(workbench, scene, history, none(int), now)

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
    if layoutItem(workbench, scene, history, some(slot), now): slot_removed = some(slot)
  if slot_removed.isSome:
    scene.removeItem(slot_removed.get)
    workbench.selection.pruneDead(scene)
    # Its session has nothing left to commit against.
    if workbench.session.isSome and workbench.session.get.slot == slot_removed:
      workbench.session = none(EditSession)
    history.record(scene)



#[ Construct Panel ]#

proc layoutTopBar*(workbench: var Workbench; scene: var Scene) =
  ## Lay out the controls reached for constantly, above every collapsing section: start a
  ## new object, toggle world furniture, and save or load the scene.
  ##   These sit outside the sections for the same reason the browser's own chip row and
  ##   menu hold them -- each is either flipped repeatedly while working or applies to the
  ##   whole scene, so neither should cost opening a section first. `add` in particular
  ##   has to live outside `objects`, since pressing it opens that section.
  gui.disabledPush(workbench.session.isSome or scene.isFull)
  if gui.button("add"):
    beginSession(workbench, scene, none(int))
  gui.disabledPop()
  gui.tooltip(
    "Compose a new object in the Objects list below; nothing joins the scene until you " &
    "save it. Greyed out while another edit is open, so starting this cannot discard it."
  )

  gui.sameLine()
  discard gui.checkbox("axes", addr workbench.is_axes_shown)
  gui.tooltip("Toggle the red/green/blue x/y/z axis lines through the origin.")
  gui.sameLine()
  discard gui.checkbox("grid", addr workbench.is_grid_shown)
  gui.tooltip("Toggle the reference grid at z = 0.")

  widthPushField()
  fieldLabel("scene file")
  discard gui.inputText("##scene_file", toCstring(workbench.path_scene), cint(PATH_MAX))
  gui.tooltip("File `save scene` writes to and `load scene` reads from.")
  gui.widthPop()
  if gui.button("save scene"):
    toChars(saveScene(scene, $toCstring(workbench.path_scene)), workbench.message)
  gui.sameLine()
  if gui.button("load scene"):
    toChars(loadScene(scene, $toCstring(workbench.path_scene)), workbench.message)
    # A loaded scene's slots are not the ones any open session was opened against.
    workbench.session = none(EditSession)


proc layoutApply*(
  workbench: var Workbench; scene: var Scene; history: var History; now: float
) =
  ## Lay out controls that derive fresh object by applying library operation to operands.
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

  # Everything the selection already says is filled in here rather than asked for a second
  #   time: how many objects are picked names the arity, and the order they were picked
  #   names m and n. Only right when the selection itself changes -- see
  #   `selection_synced`'s own doc -- so a later manual pick of either still sticks.
  if workbench.selection != workbench.selection_synced:
    workbench.selection_synced = workbench.selection
    proc positionOf(slots: openArray[int]; count, slot: int): Option[cint] =
      ## Translate a slot back to the operand combo's own dense position.
      for position in 0 ..< count:
        if slots[position] == slot: return some(cint(position))
    if workbench.selection.len > 0:
      let arity_implied = cint(ord(workbench.selection.impliedArity))
      if workbench.index_arity != arity_implied:
        # A filtered operation list is indexed per arity, so a position carried across
        #   from the other list names an unrelated operation -- the arity combo below
        #   resets the same way for the same reason.
        workbench.index_arity = arity_implied
        workbench.index_operation = 0
      let position_first = positionOf(slots, count, workbench.selection.at(0))
      if position_first.isSome: workbench.index_operand_first = position_first.get
      if workbench.selection.len >= 2:
        let position_second = positionOf(slots, count, workbench.selection.at(1))
        if position_second.isSome: workbench.index_operand_second = position_second.get

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

  # Arity is a segmented control rather than a dropdown: there are exactly two choices,
  #   both worth seeing at once, and switching should cost one click. Matches the
  #   browser's own `.toggles` pill.
  const lut_arity_to_name = [Arity.One: cstring"unary", Arity.Two: cstring"binary"]
  fieldLabel("arity")
  let width_segment = (gui.contentWidth() - SPACING_SEGMENT)/2.0'f32
  for arity in Arity:
    if arity != Arity.low: gui.sameLine()
    if gui.buttonToggle(
      lut_arity_to_name[arity], workbench.index_arity == cint(ord(arity)), width_segment
    ):
      workbench.index_arity = cint(ord(arity))
      # A filtered operation list is indexed per arity, so a position carried across from
      #   the other list names an unrelated operation.
      workbench.index_operation = 0
  gui.tooltip("Whether to list operations reading one operand or two.")

  widthPushField()

  let index_offered = clamp(int(workbench.index_operation), 0, count_offered - 1)
  workbench.index_operation = cint(index_offered)
  fieldLabel("operation")
  discard gui.combo(
    "##operation", addr workbench.index_operation, addr notations[0], cint(count_offered),
  )
  gui.tooltip("Library operation to apply below; its own notation names m and n, " &
    "the operands picked next.")
  let
    operation = operations[clamp(int(workbench.index_operation), 0, count_offered - 1)]
    is_binary = arity_wanted == Arity.Two

  fieldLabel("operand m")
  discard gui.combo("##operand_m", addr workbench.index_operand_first,
    addr names[0], cint(count))
  gui.tooltip("First operand -- `m` in the notation above -- every operation reads.")
  if is_binary:
    fieldLabel("operand n")
    discard gui.combo("##operand_n", addr workbench.index_operand_second,
      addr names[0], cint(count))
    gui.tooltip("Second operand -- `n` above -- this operation combines with `m`.")
  gui.widthPop()

  gui.disabledPush(scene.isFull)
  if gui.buttonWide("apply", gui.contentWidth()):
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
    workbench.selection.selectOnly(
      scene.addItem(derived, label, inkCycled(scene.len), now, anchor)
    )
    history.record(scene)

    var shape_word: array[WIDTH_SHAPE_WORD, char]
    var cursor_shape = 0
    describeShape(derived, shape_word, cursor_shape)
    finishChars(shape_word, cursor_shape)
    toChars(&"{label} gave {$toCstring(shape_word)}.", workbench.message)
  gui.disabledPop()





#[ View Panel ]#

proc layoutView*(workbench: var Workbench; camera: var Camera) =
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
  if gui.dragFloat("##distance", addr placement[2], 0.05,
      cfloat(DISTANCE_LIMIT_NEAR), cfloat(DISTANCE_LIMIT_FAR)):
    camera.distance = float(placement[2])
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
  discard gui.inputText("##path_export", toCstring(workbench.path_export), cint(PATH_MAX))
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
  # Full panel width, passed rather than left at 0: Dear ImGui reads a zero width as its
  #   own default *item* width, which is two thirds of the window, and a graph beside two
  #   thirds of a bar reads as one of them being broken.
  gui.plotLines(
    "##frame_time", addr workbench.milliseconds_history[0], cint(FRAMES_HISTORY),
    cint(workbench.index_history), text_now, 0.0, highest, gui.contentWidth(), 60.0,
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
      kb_peak = float(workbench.bytes_arena_frame_peak) / 1024.0
      mb_capacity = float(workbench.bytes_arena_frame_capacity) / (1024.0*1024.0)
    var text: array[WIDTH_OVERLAY_TEXT, char]
    let overlay_text = buildChars(text):
      appendChars(text, cursor, "peak ")
      appendFixed(text, cursor, kb_peak, 0)
      appendChars(text, cursor, " KB / ")
      appendFixed(text, cursor, mb_capacity, 0)
      appendChars(text, cursor, " MB")
    gui.textTinted("frame arena", INK_LABEL.red, INK_LABEL.green, INK_LABEL.blue)
    let fraction =
      float(workbench.bytes_arena_frame_peak) /
      max(float(workbench.bytes_arena_frame_capacity), 1.0)
    gui.progressBar(
      cfloat(fraction), overlay_text, gui.contentWidth(), 0.0,
      0.561, 0.737, 0.353, 0.15, 0.15, 0.18,
    )
    gui.tooltip(
      "Reset after every PNG or GIF frame it backs, so it reads empty almost any time " &
      "you would look here; the bar instead holds the largest single export this run " &
      "has needed so far, out of its own fixed reservation."
    )


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
  gui.poolBar(addr cells[0], cint(ITEMS_MAX), SIZE_POOL_CELL)
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
    gui.textWrapped("Drag one object onto another to derive a new one:")
    let (join, meet, project) = (Ink.Jade.colour, Ink.Rose.colour, Ink.Olive.colour)
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
    gui.textWrapped(
      "Drag empty space instead to move the camera: left orbits, right pans, wheel dollies."
    )

    # Scene-content edits only -- camera moves are not on this timeline; see
    #   `history.nim`. Each button greys out where its own side of the timeline is empty,
    #   rather than staying live and reporting "nothing to undo" only once pressed.
    #   A successful step drops any open session too: a restored snapshot's slot numbers
    #   need not match the one it was opened against.
    gui.disabledPush(not history.canUndo)
    if gui.button("undo"):
      if history.undo(scene):
        workbench.selection.clear()
        workbench.session = none(EditSession)
    gui.disabledPop()
    gui.tooltip("Step back through scene-content edits; camera moves are not on this timeline.")
    gui.sameLine()
    gui.disabledPush(not history.canRedo)
    if gui.button("redo"):
      if history.redo(scene):
        workbench.selection.clear()
        workbench.session = none(EditSession)
    gui.disabledPop()
    gui.tooltip("Step forward again; a fresh edit discards whatever was ahead.")
    gui.separator()
    layoutTopBar(workbench, scene)
    gui.separator()

    # Sections in alphabetical order, matching the browser's own drawer, with `objects`
    #   the one open by default: it is what a returning session looks at first, and the
    #   rest are reached for deliberately.
    layoutApply(workbench, scene, history, now)
    layoutDiagnostics(workbench, scene)
    layoutObjects(workbench, scene, history, now)
    layoutView(workbench, camera)
    gui.separator()
    gui.text(toCstring(workbench.message))
  gui.windowEnd()
