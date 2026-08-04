## Expose the whole geometry core to the browser's script layer.
##
## Everything the page shows is derived here and read across the boundary; the script layer
## does only what a browser alone can do — buffer upload and draw calls, DOM construction,
## event wiring, binary packing through the platform's own facilities, file download. Nothing
## in `glue.js` decides a colour, a label, a grade, an operation or a gesture's meaning.
##
## Names are prefixed `rga`, so the concatenated bundle has one flat namespace with no
## collisions, and every exported name is a plain function the glue calls directly.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ../core/[demo, diagnostics, format, sceneio, workbench]



#[ Boundary Constants ]#

const SLOT_NONE* = -1
  ## Stand for "no slot" at the boundary, and only at the boundary.
  ##   A JavaScript number cannot carry an optional, so absence is translated here, once. The
  ##   core keeps its `Option[Slot]` on this side of the line.


type Float32Array = ref object
  ## Name the platform's own typed array, which the glue allocates and this module fills.

proc `[]=`(buffer: Float32Array, index: int, value: float32) {.importjs: "#[#] = #".}
  ## Write one element of a typed array, through the platform's own indexing.



#[ State ]#

var
  bench = initWorkbench()
    ## Hold the tool's whole state, one instance for the page.
  meshes: Mesh
    ## Hold one frame's primitives.
    ##   At module scope and cleared per frame, never re-declared: there is no stack
    ##   allocation for storage this size, and re-declaring it measured ~90 ms/frame.
  frame_times: FrameTimes
    ## Hold the frame-time ring buffer the diagnostics section graphs.
  viewport = Viewport(width: 1.0, height: 1.0)
    ## Hold the canvas size the hit test and the projection both read.
  loading: seq[ItemRecord]
    ## Stage items being read from a file, so a bad file never reaches the live scene.



#[ Lifecycle ]#

proc rgaInit() {.exportc.} =
  ## Start the tool on the seeds alone, as the desktop build also opens.
  bench.reset(seedScene())


proc rgaFrame(now_ms, width, height: float) {.exportc.} =
  ## Advance one frame: aim the camera once, ease it, and rebuild every mesh.
  let delta_ms = if bench.now_ms > 0.0: now_ms - bench.now_ms else: 0.0
  bench.now_ms = now_ms
  viewport = Viewport(width: max(width, 1.0), height: max(height, 1.0))
  frame_times.record(delta_ms)
  bench.aim()
  bench.advanceCamera(delta_ms)
  bench.buildMesh(meshes)


proc rgaLoadDemo() {.exportc.} =
  ## Populate the scene with the eleven derived steps, as ordinary editable items.
  bench.loadDemo()


proc rgaResetScene() {.exportc.} =
  ## Return the scene to the seeds alone.
  bench.reset(seedScene())



#[ Mesh Packing ]#

proc packVertices(
  buffer: Float32Array, vertices: openArray[Vertex], count: int
): int {.inline.} =
  ## Fill a typed array with interleaved position and colour, and report the vertex count.
  for index in 0 ..< count:
    let
      vertex = vertices[index]
      base = index*7
    buffer[base] = vertex.position.x.float32
    buffer[base + 1] = vertex.position.y.float32
    buffer[base + 2] = vertex.position.z.float32
    buffer[base + 3] = vertex.color.r.float32
    buffer[base + 4] = vertex.color.g.float32
    buffer[base + 5] = vertex.color.b.float32
    buffer[base + 6] = vertex.color.a.float32
  count


proc rgaPackPoints(buffer: Float32Array): int {.exportc.} =
  ## Fill the points buffer.
  packVertices(buffer, meshes.points, meshes.point_count)

proc rgaPackLines(buffer: Float32Array): int {.exportc.} =
  ## Fill the scene-line buffer.
  packVertices(buffer, meshes.lines, meshes.line_count)

proc rgaPackFurniture(buffer: Float32Array): int {.exportc.} =
  ## Fill the furniture buffer.
  packVertices(buffer, meshes.furniture, meshes.furniture_count)

proc rgaPackTriangles(buffer: Float32Array): int {.exportc.} =
  ## Fill the translucent-triangle buffer, horizon domes first.
  packVertices(buffer, meshes.triangles, meshes.triangle_count)


proc rgaPackRings(buffer: Float32Array): int {.exportc.} =
  ## Fill the ring buffer with screen positions, radii and opacities.
  ##   Projected here rather than in the glue: a ring follows the same anchor the hit test
  ##   uses, and that projection is a domain rule.
  let matrix = bench.camera.viewProjection(viewport.width/viewport.height)
  var written = 0
  for index in 0 ..< meshes.ring_count:
    let
      ring = meshes.rings[index]
      projected = toScreen(matrix, viewport, ring.anchor)
    if projected.isNone: continue
    let base = written*4
    buffer[base] = projected.get.x.float32
    buffer[base + 1] = projected.get.y.float32
    buffer[base + 2] = ring.radius_px.float32
    buffer[base + 3] = ring.alpha.float32
    written += 1
  written


proc rgaViewProjection(buffer: Float32Array): int {.exportc.} =
  ## Fill the combined view-projection transform, in the column-major order GL uploads.
  let matrix = bench.camera.viewProjection(viewport.width/viewport.height)
  for index in 0 ..< 16:
    buffer[index] = matrix.columns[index].float32
  16


proc rgaSlotScreen(slot: int, buffer: Float32Array): bool {.exportc.} =
  ## Project an object's anchor to the page's own coordinates, for a menu that follows it.
  ##   Through the scene's single anchor choke point, so a dead slot reports nothing to draw
  ##   rather than a stale position.
  if not bench.scene.isLive(Slot(slot)): return false
  let anchor = bench.scene.drawAnchor(Slot(slot))
  if anchor.isNone: return false
  let projected = toScreen(
    bench.camera.viewProjection(viewport.width/viewport.height), viewport, anchor.get
  )
  if projected.isNone: return false
  buffer[0] = projected.get.x.float32
  buffer[1] = projected.get.y.float32
  true


proc rgaRingWidth(): float {.exportc.} = RING_WIDTH_PX
  ## Read the ring's stroke width.

proc rgaPointSize(): float {.exportc.} = POINT_SIZE_PX
  ## Read the drawn size of a point.

proc rgaLineWidthObject(): float {.exportc.} = LINE_WIDTH_OBJECT
  ## Read the drawn width of a scene line; most WebGL implementations clamp it to 1 px.

proc rgaLineWidthFurniture(): float {.exportc.} = LINE_WIDTH_FURNITURE
  ## Read the drawn width of furniture; most WebGL implementations clamp it to 1 px.



#[ Camera ]#

proc rgaCameraOrbit(dx, dy: float) {.exportc.} =
  ## Turn the camera, and hand it to the user.
  bench.camera.orbit(dx, dy)
  bench.grabCamera()

proc rgaCameraPan(dx, dy: float) {.exportc.} =
  ## Slide the camera's target, and hand it to the user.
  bench.camera.pan(dx, dy)
  bench.grabCamera()

proc rgaCameraDolly(notches: float) {.exportc.} =
  ## Pull the camera in or out, and hand it to the user.
  bench.camera.dolly(notches)
  bench.grabCamera()


proc rgaCameraField(index: int): float {.exportc.} =
  ## Read one of the seven editable camera fields.
  case index
  of 0: bench.camera.azimuth
  of 1: bench.camera.elevation
  of 2: bench.camera.distance
  of 3: bench.camera.fov
  of 4: bench.camera.target.x
  of 5: bench.camera.target.y
  of 6: bench.camera.target.z
  else: 0.0


proc rgaSetCameraField(index: int, value: float) {.exportc.} =
  ## Write one of the seven editable camera fields, and hand the camera to the user.
  case index
  of 0: bench.camera.azimuth = value
  of 1: bench.camera.elevation = value
  of 2: bench.camera.distance = value
  of 3: bench.camera.fov = value
  of 4: bench.camera.target.x = value
  of 5: bench.camera.target.y = value
  of 6: bench.camera.target.z = value
  else: discard
  bench.camera.clampFields()
  bench.grabCamera()


proc rgaCameraFieldName(index: int): cstring {.exportc.} =
  ## Name one of the seven editable camera fields.
  case index
  of 0: "azimuth"
  of 1: "elevation"
  of 2: "distance"
  of 3: "field of view"
  of 4: "target x"
  of 5: "target y"
  of 6: "target z"
  else: ""


proc rgaCameraFieldCount(): int {.exportc.} = 7
  ## Count the editable camera fields.



#[ Picking And Selection ]#

proc rgaPick(x, y: float): int {.exportc.} =
  ## Decide which object the pointer is over, or report no slot.
  let hit = pick(bench.scene, bench.camera, viewport, ScreenPoint(x: x, y: y))
  if hit.isNone: SLOT_NONE else: hit.get.index


proc rgaSetHover(slot: int) {.exportc.} =
  ## Ring the object under the pointer, or clear the reading.
  ##   The clear matters on touch: there is no continuous pointer, so a stale reading would
  ##   sit forever and read as a second selected object.
  bench.hovered =
    if slot == SLOT_NONE or not bench.scene.isLive(Slot(slot)): none(Slot)
    else: some(Slot(slot))


proc rgaSelectOnly(slot: int) {.exportc.} =
  ## Pick one object alone.
  if slot == SLOT_NONE or not bench.scene.isLive(Slot(slot)): return
  bench.selection.replaceWith(Slot(slot))

proc rgaSelectToggle(slot: int) {.exportc.} =
  ## Add an object to the picks, or drop it.
  if slot == SLOT_NONE or not bench.scene.isLive(Slot(slot)): return
  bench.selection.toggle(Slot(slot))

proc rgaSelectClear() {.exportc.} =
  ## Drop every pick.
  bench.selection.clear()

proc rgaSelectionCount(): int {.exportc.} = bench.selection.len
  ## Count picked objects.

proc rgaSelectionAt(index: int): int {.exportc.} =
  ## Read a picked slot, in pick order, which is what names the operands.
  if index < 0 or index >= bench.selection.len: return SLOT_NONE
  bench.selection.at(index).index

proc rgaSelectionIsBinary(): bool {.exportc.} =
  ## Report whether a selection of this size means a binary operation.
  bench.selection.arity == Arity.Binary

proc rgaSelectionIsEntirelyHidden(): bool {.exportc.} =
  ## Report whether every picked object is already hidden, which is what `hide` reads.
  bench.selection.isEntirelyHidden(bench.scene)

proc rgaIsSelected(slot: int): bool {.exportc.} =
  ## Report whether an object is picked.
  slot != SLOT_NONE and bench.selection.contains(Slot(slot))



#[ Scene ]#

proc rgaItemCount(): int {.exportc.} = bench.scene.count
  ## Count live objects.

proc rgaItemSlotAt(index: int): int {.exportc.} =
  ## Read a live slot by position in recency order, newest first.
  var order: array[ITEM_CAPACITY, Slot]
  let length = bench.scene.recentOrder(order)
  if index < 0 or index >= length: return SLOT_NONE
  order[index].index

proc rgaItemLabel(slot: int): cstring {.exportc.} =
  ## Read an object's label.
  if not bench.scene.isLive(Slot(slot)): return ""
  cstring($bench.scene.label(Slot(slot)))

proc rgaItemShapeWord(slot: int): cstring {.exportc.} =
  ## Name what an object draws as, including "nothing to draw".
  if not bench.scene.isLive(Slot(slot)): return ""
  cstring(bench.scene.geometry(Slot(slot)).shape.shapeWord)

proc rgaItemIsVisible(slot: int): bool {.exportc.} =
  ## Report whether an object draws.
  bench.scene.isLive(Slot(slot)) and bench.scene.isVisible(Slot(slot))

proc rgaItemPaint(slot: int): int {.exportc.} =
  ## Read an object's colour slot, as a palette ordinal.
  if not bench.scene.isLive(Slot(slot)): return ord(CATEGORICAL_FIRST)
  ord(bench.scene.paint(Slot(slot)))

proc rgaItemColorHex(slot: int): cstring {.exportc.} =
  ## Read an object's colour, in the browser's own notation.
  if not bench.scene.isLive(Slot(slot)): return "#000000"
  cstring(bench.scene.paint(Slot(slot)).color.toHex)

proc rgaItemCoefficient(slot, basis: int): float {.exportc.} =
  ## Read one coefficient of an object's multivector.
  if not bench.scene.isLive(Slot(slot)): return 0.0
  bench.scene.geometry(Slot(slot)).coefficient(Basis(basis))

proc rgaItemCoefficients(slot: int): cstring {.exportc.} =
  ## Read an object's coefficients as the row's one-line reading.
  if not bench.scene.isLive(Slot(slot)): return ""
  var parts: seq[string]
  let geometry = bench.scene.geometry(Slot(slot))
  for b in Basis:
    let value = geometry.coefficient(b)
    if abs(value) <= TOLERANCE_ABS: continue
    parts.add(format(value) & b.elementName)
  if parts.len == 0: return cstring("0" & Basis.scalar.elementName)
  cstring(parts.join(" "))


proc rgaSetItemVisible(slot: int, is_visible: bool) {.exportc.} =
  ## Show or hide an object, recording the edit.
  bench.setVisibility(Slot(slot), is_visible)

proc rgaSetSelectionVisible(is_visible: bool) {.exportc.} =
  ## Show or hide every picked object at once.
  bench.setSelectionVisibility(is_visible)

proc rgaSetItemPaint(slot, paint: int) {.exportc.} =
  ## Recolour an object.
  bench.setPaint(Slot(slot), Paint(paint))

proc rgaRemoveItem(slot: int) {.exportc.} =
  ## Remove an object.
  bench.removeSlot(Slot(slot))

proc rgaRemoveSelected() {.exportc.} =
  ## Remove every picked object.
  bench.removeSelected()



#[ Catalogue ]#

proc rgaOperationCount(is_binary: bool): int {.exportc.} =
  ## Count the operations of one arity.
  operationCount(if is_binary: Arity.Binary else: Arity.Unary)

proc rgaOperationAt(is_binary: bool, index: int): int {.exportc.} =
  ## Read an operation of one arity, in catalogue order.
  var seen = 0
  for operation in operations(if is_binary: Arity.Binary else: Arity.Unary):
    if seen == index: return ord(operation)
    seen += 1
  SLOT_NONE

proc rgaOperationLabel(operation: int): cstring {.exportc.} =
  ## Read an operation's label: notation, two spaces, English name.
  cstring(Operation(operation).label)

proc rgaOperationIsBinary(operation: int): bool {.exportc.} =
  ## Report whether an operation reads two operands.
  Operation(operation).arity == Arity.Binary

proc rgaOperationForButton(button: int): int {.exportc.} =
  ## Name the operation a drag with this button derives.
  ##   The browser numbers its buttons 0, 2, 1 for left, right and middle; translating that
  ##   numbering is the only part of the mapping the script layer holds.
  ord(operationFor(PointerButton(button)))


proc rgaApply(operation, first, second: int): int {.exportc.} =
  ## Apply an operation to two slots, and report the slot it built.
  let derived = bench.applyOperation(Operation(operation), Slot(first), Slot(second))
  if derived.isNone: SLOT_NONE else: derived.get.index

proc rgaApplySelection(operation: int): int {.exportc.} =
  ## Apply an operation to the picked operands, in pick order.
  let
    first = bench.selection.first
    second = bench.selection.second
  if first.isNone: return SLOT_NONE
  let
    is_binary = Operation(operation).arity == Arity.Binary
    other = if is_binary and second.isSome: second.get else: first.get
  if is_binary and second.isNone: return SLOT_NONE
  let derived = bench.applyOperation(Operation(operation), first.get, other)
  if derived.isNone: SLOT_NONE else: derived.get.index

proc rgaDrag(button, source, destination: int): int {.exportc.} =
  ## Derive an object from a drag of one object onto another.
  let derived = bench.applyDrag(PointerButton(button), Slot(source), Slot(destination))
  if derived.isNone: SLOT_NONE else: derived.get.index



#[ Basis And Formatting ]#

proc rgaBasisCount(): int {.exportc.} = BASIS_COUNT
  ## Count basis elements of the configured algebra.

proc rgaBasisName(index: int): cstring {.exportc.} =
  ## Name a basis element, exactly as the library prints it.
  cstring(Basis(index).elementName)

proc rgaBasisGrade(index: int): int {.exportc.} =
  ## Read a basis element's grade, so the coefficient grid rows by grade.
  int(Basis(index).grade)

proc rgaMaxGrade(): int {.exportc.} = DIMENSIONS
  ## Read the highest grade of the configured algebra.

proc rgaFormat(value: float): cstring {.exportc.} =
  ## Format a number to four significant digits, the one rule every field obeys.
  cstring(format(value))

proc rgaParseNumber(text: cstring): float {.exportc.} =
  ## Read a number back from an edited field.
  parseNumber($text)



#[ Palette ]#

proc rgaPaletteCount(): int {.exportc.} = CATEGORICAL_COUNT
  ## Count assignable hues; a picker walks exactly these.

proc rgaPaletteAt(index: int): int {.exportc.} = ord(categorical(index))
  ## Read an assignable hue by position, as a palette ordinal.

proc rgaPaletteHex(paint: int): cstring {.exportc.} =
  ## Read a palette slot's colour, in the browser's own notation.
  cstring(Paint(paint).color.toHex)

proc rgaPaletteName(paint: int): cstring {.exportc.} =
  ## Name a palette slot.
  cstring($Paint(paint))

proc rgaBackdropColor(buffer: Float32Array): int {.exportc.} =
  ## Read the framebuffer clear colour.
  let color = Paint.Backdrop.color
  buffer[0] = color.r.float32
  buffer[1] = color.g.float32
  buffer[2] = color.b.float32
  buffer[3] = 1.0
  4

proc rgaOutlineHex(): cstring {.exportc.} = cstring(Paint.Outline.color.toHex)
  ## Read the selection ring's colour.



#[ History ]#

proc rgaUndo(): bool {.exportc.} = bench.undo()
  ## Step back one scene edit.

proc rgaRedo(): bool {.exportc.} = bench.redo()
  ## Step forward one scene edit.

proc rgaCanUndo(): bool {.exportc.} = bench.history.canUndo
  ## Report whether the undo control is live.

proc rgaCanRedo(): bool {.exportc.} = bench.history.canRedo
  ## Report whether the redo control is live.



#[ Sessions ]#

proc rgaSessionStartComposing(label: cstring) {.exportc.} =
  ## Open a session for a new object.
  bench.startComposing(initLabel($label))

proc rgaSessionStartEditing(slot: int) {.exportc.} =
  ## Open a session on an existing object.
  bench.startEditing(Slot(slot))

proc rgaSessionSave(): int {.exportc.} =
  ## Commit the open session.
  let slot = bench.saveSession()
  if slot.isNone: SLOT_NONE else: slot.get.index

proc rgaSessionCancel() {.exportc.} =
  ## Abandon the open session.
  bench.cancelSession()

proc rgaSessionIsOpen(): bool {.exportc.} = bench.isSessionOpen
  ## Report whether a session is open, which is when `add` is disabled.

proc rgaSessionIsEditing(): bool {.exportc.} =
  ## Report whether the open session is editing rather than composing.
  bench.session.isSome and bench.session.get.mode == SessionMode.Editing

proc rgaSessionSlot(): int {.exportc.} =
  ## Read the slot the open session edits, where it has one.
  if bench.session.isNone: return SLOT_NONE
  let slot = bench.session.get.slot
  if slot.isNone: SLOT_NONE else: slot.get.index

proc rgaSessionCoefficient(basis: int): float {.exportc.} =
  ## Read one staged coefficient.
  if bench.session.isNone: return 0.0
  bench.session.get.coefficient(Basis(basis))

proc rgaSessionSetCoefficient(basis: int, value: float) {.exportc.} =
  ## Write one staged coefficient; the scene is untouched until save.
  if bench.session.isNone: return
  bench.session.get.setCoefficient(Basis(basis), value)

proc rgaSessionLabel(): cstring {.exportc.} =
  ## Read the staged label.
  if bench.session.isNone: return ""
  cstring($bench.session.get.label)

proc rgaSessionSetLabel(text: cstring) {.exportc.} =
  ## Write the staged label.
  if bench.session.isNone: return
  bench.session.get.setLabel(initLabel($text))

proc rgaSessionPaint(): int {.exportc.} =
  ## Read the staged colour.
  if bench.session.isNone: return ord(CATEGORICAL_FIRST)
  ord(bench.session.get.paint)

proc rgaSessionSetPaint(paint: int) {.exportc.} =
  ## Write the staged colour.
  if bench.session.isNone: return
  bench.session.get.setPaint(Paint(paint))

proc rgaSessionShapeWord(): cstring {.exportc.} =
  ## Name what the staged multivector would draw as.
  if bench.session.isNone: return ""
  cstring(bench.session.get.staged.shape.shapeWord)



#[ Save And Load ]#

proc rgaFileMagic(): cstring {.exportc.} = cstring(MAGIC)
  ## Read the file format's magic.

proc rgaFileVersion(): int {.exportc.} = int(FORMAT_VERSION)
  ## Read the file format's version.

proc rgaRecordCount(): int {.exportc.} = bench.scene.count
  ## Count the records a save writes.

proc rgaRecordPaint(index: int): int {.exportc.} =
  ## Read a record's colour ordinal.
  let records = bench.scene.toRecords
  if index < 0 or index >= records.len: return 0
  records[index].paint

proc rgaRecordIsVisible(index: int): bool {.exportc.} =
  ## Read a record's visibility.
  let records = bench.scene.toRecords
  if index < 0 or index >= records.len: return true
  records[index].is_visible

proc rgaRecordLabel(index: int): cstring {.exportc.} =
  ## Read a record's label.
  let records = bench.scene.toRecords
  if index < 0 or index >= records.len: return ""
  cstring(records[index].label)

proc rgaRecordCoefficient(index, basis: int): float {.exportc.} =
  ## Read one coefficient of a record.
  let records = bench.scene.toRecords
  if index < 0 or index >= records.len: return 0.0
  records[index].coefficients[basis]


proc rgaLoadBegin() {.exportc.} =
  ## Start reading a file into a staging scene.
  loading = @[]

proc rgaLoadItem(paint: int, is_visible: bool, label: cstring) {.exportc.} =
  ## Stage one item read from a file, with its coefficients to follow.
  loading.add(ItemRecord(paint: paint, is_visible: is_visible, label: $label))

proc rgaLoadCoefficient(basis: int, value: float) {.exportc.} =
  ## Stage one coefficient of the item being read.
  if loading.len == 0: return
  loading[^1].coefficients[basis] = value

proc rgaLoadCommit(): bool {.exportc.} =
  ## Replace the scene with what was staged, or refuse it whole.
  ##   A bad path, a foreign file, a wrong dimension or too many items leaves the existing
  ##   scene untouched, because nothing is written until the staging scene is complete.
  let staged = fromRecords(loading)
  loading = @[]
  if staged.isNone: return false
  bench.reset(staged.get)
  true



#[ Diagnostics ]#

proc rgaFrameSampleCount(): int {.exportc.} = frame_times.len
  ## Count recorded frame times.

proc rgaFrameSampleAt(index: int): float {.exportc.} = frame_times.at(index)
  ## Read one frame time, oldest first, raw and unsmoothed.

proc rgaFramePeak(): float {.exportc.} = frame_times.peak
  ## Read the slowest recorded frame.

proc rgaFrameMean(): float {.exportc.} = frame_times.mean
  ## Read the average frame time.

proc rgaPoolActive(): int {.exportc.} = bench.scene.count
  ## Count occupied pool slots.

proc rgaPoolCapacity(): int {.exportc.} = ITEM_CAPACITY
  ## Count pool slots in total.

proc rgaPoolStrip(buffer: Float32Array): int {.exportc.} =
  ## Fill the pool strip with one colour triple per slot, occupied or free.
  var strip: array[ITEM_CAPACITY*3, float]
  bench.scene.poolStrip(strip)
  for index in 0 ..< ITEM_CAPACITY*3:
    buffer[index] = strip[index].float32
  ITEM_CAPACITY



#[ Animation And Gestures ]#

proc rgaAnimationDuration(): float {.exportc.} = ANIMATION_DURATION_MS
  ## Read the one duration every eased motion takes.

proc rgaAnimationCurve(): cstring {.exportc.} = cstring(ANIMATION_CURVE_CSS)
  ## Read the one easing curve, in the browser's own notation.

proc rgaClickDuration(): float {.exportc.} = CLICK_DURATION_MS
  ## Read how long a press may last and still be a click.

proc rgaClickMovement(): float {.exportc.} = CLICK_MOVEMENT_PX
  ## Read how far a press may move and still be a click.

proc rgaLongPressDuration(): float {.exportc.} = LONG_PRESS_MS
  ## Read how long a touch is held to select.

proc rgaIsTap(duration_ms, movement_px: float): bool {.exportc.} =
  ## Report whether a touch was a tap.
  isTap(duration_ms, movement_px)

proc rgaIsClick(duration_ms, movement_px: float): bool {.exportc.} =
  ## Report whether a press was a click.
  isClick(duration_ms, movement_px)

proc rgaShowAxes(is_showing: bool) {.exportc.} =
  ## Show or hide the world axes.
  bench.is_showing_axes = is_showing

proc rgaShowGrid(is_showing: bool) {.exportc.} =
  ## Show or hide the ground grid.
  bench.is_showing_grid = is_showing

proc rgaIsShowingAxes(): bool {.exportc.} = bench.is_showing_axes
  ## Report whether the world axes draw.

proc rgaIsShowingGrid(): bool {.exportc.} = bench.is_showing_grid
  ## Report whether the ground grid draws.
