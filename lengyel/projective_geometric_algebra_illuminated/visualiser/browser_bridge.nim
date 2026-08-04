## Bridge the interactive RGA workbench to a WebGL front end, compiled through Nim's own
## JS backend rather than reimplemented in JS -- every join, meet, attitude, support,
## expansion, projection, pick and drag the browser offers is computed by the same `pga`,
## `objects`, `mesh`, `camera`, `scene`, `picking`, `interaction` and `storyboard` modules
## the desktop app itself draws through; only the presentation (WebGL calls, DOM, pointer
## input) is JS's own, exactly as OpenGL/SDL/Dear ImGui are the desktop app's own
## presentation layer over the same CPU-side geometry.
##
## Full feature parity with the desktop app: add a point, apply any catalogue operation to
## two picked operands, drag from one object onto another to derive a third (left joins,
## right meets, middle projects, on a pointer that has buttons; tap-then-pick on one that
## does not), edit any object's label, palette slot, visibility or raw coefficients, remove
## an object, save or load a scene, and orbit/pan/dolly the camera by drag or by typing
## numbers directly -- the entire surface `panel.nim` lays out for Dear ImGui, offered here
## as plain exported procs a hand-written presentation layer drives instead.
##
## What does NOT carry over, and why:
##   `scene.toCstring`, `format.appendMagnitude` and every desktop-only diagnostic (the
##   arena bump-allocators, `arena.nim`'s own accounting, the SDL/OpenGL frame loop's own
##   timing) either depend on a C FFI (`format.nim`'s `snprintf` binding) or on an address
##   the JS backend has no notion of, or describe implementation details specific to the
##   native build's own allocator and draw loop with no browser/JS-GC equivalent worth
##   fabricating. What a *coefficient* should read as is this project's own rule rather
##   than C's, so `nimFormatNumber` below answers it from `format.formatMagnitude`
##   instead of leaving it to a `toFixed` on the JS side; a browser-appropriate
##   diagnostics substitute (frame time via
##   `requestAnimationFrame` deltas, JS heap size where available) stands in for the
##   desktop's own arena/frame-time panel, covering the same *purpose* -- surfacing what
##   using this build costs -- without pretending to the same numbers.
##
## Desktop's own file-path save/load becomes browser download/upload of the identical
## `.rgascene` binary format (see `scene.nim`'s own doc comment for the format itself):
## this module exposes raw per-item fields (ink, visibility, label, sixteen basis
## coefficients) rather than bytes directly, since packing IEEE-754 doubles by hand in
## Nim/JS would only reinvent what a browser's own `DataView` already does natively; the
## hand-written presentation layer packs and unpacks the exact documented byte layout.
##
## This is the browser entry point; see `visualiser.nim`'s own "Render Paths" table for
## the full shared/desktop-only/browser-only module split.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./[
  camera, format, history, interaction, marker, mesh, objects, picking, scene, selection,
  storyboard,
]



#[ Workbench State ]#

var
  g_scene: Scene
  g_camera: Camera
  g_meshes_furniture, g_meshes: MeshSet ## Held at module scope and reused every frame
    ## via `clearMeshes` (which only resets each mesh's own `count_vertices`, not its
    ## backing storage) -- mirrors `visualiser.nim`'s own module-level
    ## `MESHES`/`MESHES_FURNITURE`. Declaring these as `nimBuildFrame`'s own locals
    ## instead, freshly on every call, was measured costing ~90ms/frame *regardless of
    ## how many objects the scene actually held* -- a `MeshSet` reserves `VERTICES_MAX`
    ## (16384) vertices per primitive up front, and the JS backend has no true stack
    ## allocation the way re-declaring a fixed-size array inside a proc gets on the C
    ## backend: each call was reallocating and zero-filling ~1.3MB `MeshSet`s from
    ## scratch, whether the scene held nine objects or sixty-four. Fixed the same way
    ## the desktop build already avoids this: allocate once, clear (not reallocate)
    ## every frame.
  g_interaction = Interaction(is_enabled: true) ## Picking and drag are always live here --
    ## there is no storyboard-capture mode to switch them off for, unlike the desktop
    ## build's own `runStoryboard`.
  g_borns: array[ITEMS_MAX, float] ## Stamped once per slot, the moment an item is added
    ## (by point, by operation, or by drag) -- read back by `nimBuildFrame` so it animates
    ## in exactly as the desktop build's own newly-added item does.
  g_selection: Selection ## Items picked right now, in pick order, each ringed by the
    ## presentation layer's own `refreshOverlay`. Replaced outright by every construction
    ## path, and driven directly by the touch/click select gestures through
    ## `nimSelectOnly`/`nimSelectToggle`/`nimSelectClear`. The presentation layer keeps no
    ## list of its own: pick order is what names an operation's operands, so it lives in
    ## `selection.nim` beside every other rule about it, not in hand-written JavaScript.
  g_tween_camera: CameraTween ## Carries the camera toward whatever is being built or
    ## edited -- see `camera.CameraTween`. Aimed and advanced inside `nimBuildFrame`, from
    ## the same one rule the desktop build uses, so neither UI decides for itself when the
    ## camera should move.
  g_history: History ## Undo/redo timeline of scene-content edits; scoped exactly as
    ## `visualiser.HISTORY` is -- see `history.nim`'s own doc comment for what is and is
    ## not on this timeline. Seeded via `initHistory(g_scene)` wherever `g_scene` itself
    ## is (re)initialized (`nimInit`, `nimLoadDemo`, `nimSceneClear`), so undo never
    ## reaches earlier than the moment tracking began for whatever scene is live now.
  g_ghost = none(Multivector) ## Multivector the open edit session is staging, rendered
    ## every frame by `nimBuildFrame` exactly like a live scene object -- but never added
    ## to `g_scene` itself: `nimSceneSlots`/`nimSceneCount` (and so undo/redo, save,
    ## picking) never see it. Serves both session modes, since only one is ever open:
    ## composing a new object, where nothing backs it in the scene yet, and editing an
    ## existing one, where the ghost shows where it would land while the object itself
    ## stays put. None where no session is open, or the last one committed
    ## (`nimAddItem`/`nimCommitItem`) or was abandoned (`nimClearGhost`).

const INK_GHOST = Ink.Guide
  ## Palette slot the ghost draws in, muted -- reuses Ink.Guide's own existing
  ## "construction helper" semantics rather than adding a palette entry just for this.


proc toRgbSeq(c: Rgba): seq[float32] = @[c.red, c.green, c.blue]
  ## Format colour as an `[r, g, b]` triple, for a caller that wants a CSS colour string
  ## to format one for itself -- DOM styling is not this module's own job.


proc flatten(mesh: Mesh): seq[float32] =
  ## Interleave one primitive's vertices as `x, y, z, r, g, b, a, x, y, z, r, g, b, a, ...`,
  ## ready for a caller to hand straight to `gl.bufferData`.
  result = newSeqOfCap[float32](mesh.count_vertices * 7)
  for i in 0 ..< mesh.count_vertices:
    let v = mesh.vertices[i]
    result.add(v.x)
    result.add(v.y)
    result.add(v.z)
    result.add(v.red)
    result.add(v.green)
    result.add(v.blue)
    result.add(v.alpha)



#[ Setup ]#

proc placeSeeds(now: float) =
  ## Build the same default scene the desktop app itself opens on when no saved scene is
  ## given: just the five seeds, nothing derived -- see `visualiser.main`'s own startup,
  ## which this mirrors exactly rather than approximates.
  g_scene = initScene()
  constructSeeds(g_scene, now)
  for slot in 0 ..< g_scene.len: g_borns[slot] = now


proc nimInit(now: cfloat) {.exportc.} =
  ## Build the default interactive scene and place the camera at the same default orbit
  ## the desktop app itself opens on.
  placeSeeds(float(now))
  g_camera = initCamera(
    target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05, elevation = 0.42
  )
  g_selection.clear()
  g_history = initHistory(g_scene)


proc nimLoadDemo(now: cfloat) {.exportc.} =
  ## Replace the current scene with the full eleven-step storyboard construction, as
  ## ordinary live items -- a one-click preset rather than a scripted playback mode: once
  ## loaded, every one of its objects is exactly as editable, removable and pickable as
  ## anything built by hand.
  ##   Stamps `g_borns` one second apart per step (five seeds at `now`, then each of the
  ##   eleven steps one second later than the last), mirroring
  ##   `visualiser.runStoryboard`'s own synthetic clock -- unlike `placeSeeds`'s own
  ##   plain startup scene, this one has derived steps to rank by recency, so the
  ##   staggering still earns its keep here even where the startup scene no longer needs
  ##   it.
  g_scene = initScene()
  var clock = float(now)
  constructSeeds(g_scene, clock)
  let count_seeds = g_scene.len
  for slot in 0 ..< count_seeds: g_borns[slot] = clock
  for index, step in STEPS:
    clock += 1.0
    applyStep(g_scene, step, clock)
    g_borns[count_seeds + index] = clock
  g_selection.clear()
  g_history = initHistory(g_scene)



#[ Scene Inspection ]#

proc nimSceneCount(): cint {.exportc.} = cint(g_scene.len)
  ## Report how many items are currently alive in the scene.


proc nimSceneCapacity(): cint {.exportc.} = cint(ITEMS_MAX)
  ## Report the fixed number of item slots this build reserves.


proc nimSceneSlots(): seq[cint] {.exportc.} =
  ## Report every live slot, in slot order -- the same dense-position-to-slot mapping
  ## `panel.layoutOperation`'s own combo boxes rely on.
  ##   Walks slots directly rather than through the `pairs` iterator: that iterator
  ##   yields an `Item` per live slot purely to hand back the slot number here, and
  ##   under the JS backend constructing an `Item` copies the whole `Scene` by value
  ##   (see `Item`'s own doc comment) -- wasted for a caller that only wants the number.
  for slot in 0 ..< ITEMS_MAX:
    if g_scene.isAlive(slot): result.add(cint(slot))


proc nimIsAlive(slot: cint): bool {.exportc.} = g_scene.isAlive(int(slot))
  ## Report whether slot currently holds a live item.


proc nimItemLabel(slot: cint): cstring {.exportc.} =
  ## Report item's display label, by slot.
  cstring(toText(g_scene.labelAt(int(slot))))


proc nimItemInk(slot: cint): cint {.exportc.} = cint(g_scene.inkAt(int(slot)))
  ## Report item's palette slot, by slot.


proc nimItemVisible(slot: cint): bool {.exportc.} = g_scene.isVisible(int(slot))
  ## Report item's visibility, by slot.


proc nimItemBorn(slot: cint): cfloat {.exportc.} = cfloat(g_borns[int(slot)])
  ## Report the moment (same clock as every other `now` parameter here) item was added,
  ## by slot -- lets the browser's own Objects panel sort by recency.


proc nimItemShapeWord(slot: cint): cstring {.exportc.} =
  ## Report item's shape, by slot, in the words `scene.shapeText` names it -- the same
  ## words the desktop status line uses, because it is the same call.
  cstring(shapeText(g_scene.geometryAt(int(slot))))


proc nimItemCoefficients(slot: cint): seq[float] {.exportc.} =
  ## Report all sixteen basis coefficients of an item's own multivector, in the library's
  ## own `Basis` order -- the same order `scene.saveScene`/`loadScene` read and write, and
  ## the same order `panel.layoutCoefficients` lays its sixteen drag widgets out in.
  let geometry = g_scene.geometryAt(int(slot))
  result = newSeq[float](ord(Basis.high) + 1)
  for b in Basis: result[ord(b)] = geometry[b]


proc nimFormatNumber(value: float): cstring {.exportc.} =
  ## Format one number for a field, to the same four significant digits the desktop's own
  ## drag widget shows: 3.5 reads `3.5`, not `3.5000`.
  ##   Every editable number goes through here -- coefficients, and the camera's own angles,
  ##   distance and target -- because they are all read and typed the same way, and the
  ##   desktop draws every one of them with the same `%.4g` widget.
  ##   Exported rather than left to a `toFixed` on the JS side, because how many digits a
  ##   number is worth is a decision about this project's numbers, not about the DOM.
  ##   `format.formatMagnitude` rather than `format.appendMagnitude`, whose `snprintf`
  ##   needs a C runtime this backend does not have; the suite holds the two to the same
  ##   answer, so a browser field and a desktop one read a number identically.
  cstring(formatMagnitude(value))


proc nimFormatMultivector(slot: cint): cstring {.exportc.} =
  ## Format item's own multivector for display, by slot, through `scene.multivectorText`
  ## -- the same writer the desktop panel's own item line uses, so a coefficient reads
  ## identically in both front-ends.
  ##   This used the library's own `$` until the suite began running on this backend too:
  ##   `$` writes magnitudes at the library's `%G`, not at this project's four significant
  ##   digits, so the same object printed differently in the two UIs.
  cstring(multivectorText(g_scene.geometryAt(int(slot))))



#[ Scene Mutation ]#

proc nimDefaultLabel(): cstring {.exportc.} = cstring(&"m{g_scene.len}")
  ## Report the label a freshly composed object starts out carrying, for a caller to
  ## pre-fill an edit session with and let the user change before committing.


proc nimDefaultInk(): cint {.exportc.} = cint(inkCycled(g_scene.len))
  ## Report the palette slot a freshly composed object starts out carrying, cycled the
  ## same way every construction path already cycles it.


proc nimAddItem(
  coefficients: seq[float]; label: cstring; ink_ordinal: cint; now: cfloat
): cint {.exportc.} =
  ## Commit a composing edit session as a fresh scene object, taking the label and palette
  ## slot the session staged rather than assigning them here -- both are editable before
  ## the commit, unlike every other construction path, which has no user-facing moment
  ## between deciding to build something and it existing.
  ##   Builds `geometry` coefficient-by-coefficient the same way `nimSceneAddRaw` does for
  ##   a loaded item, rather than reusing that proc outright: `nimSceneAddRaw` deliberately
  ##   skips `g_history.record`, stamps `g_borns` to 0.0 (load semantics), and never
  ##   touches `g_selection` -- all three of which a user-driven add must do.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  result = cint(g_scene.addItem(geometry, $label, Ink(ink_ordinal), float(now)))
  g_borns[int(result)] = float(now)
  g_selection.selectOnly(int(result))
  g_history.record(g_scene)


proc nimCommitItem(
  slot: cint; coefficients: seq[float]; label: cstring; ink_ordinal: cint
) {.exportc.} =
  ## Commit an editing session onto the item it was opened against, writing every staged
  ## field at once and recording history exactly once.
  ##   This is the "edit committed" boundary `history.nim`'s own doc comment says the
  ##   continuous widgets lacked: a coefficient drag or a keystroke no longer reaches the
  ##   scene at all, so the timeline gains one entry per save rather than one per frame of
  ##   input, and coefficient/label/colour edits are undoable for the first time.
  let index = int(slot)
  for b in Basis: g_scene.geometryAt(index)[b] = coefficients[ord(b)]
  toChars($label, g_scene.labelAt(index))
  g_scene.setInk(index, Ink(ink_ordinal))
  g_history.record(g_scene)


type OperationResult = object ## Report what applying a catalogue operation produced.
  created_slot: cint ## Slot the derived object was added at.
  message: cstring ## Outcome, for display exactly as the desktop panel's own status line.
  shape_word: cstring ## What the derived object turned out to be.


proc nimApplyOperation(
  operation_ordinal, slot_first, slot_second: cint; now: cfloat
): OperationResult {.exportc.} =
  ## Derive a fresh object by applying a catalogue operation to two picked operands,
  ## exactly as `panel.layoutOperation`'s own apply button does.
  let
    operation = Operation(operation_ordinal)
    operand_first = g_scene.geometryAt(int(slot_first))
    operand_second = g_scene.geometryAt(int(slot_second))
    derived = applyOperation(operation, operand_first, operand_second)
    anchor = creationAnchor(operation, operand_first, operand_second, derived)
    name_first = toText(g_scene.labelAt(int(slot_first)))
    name_second = toText(g_scene.labelAt(int(slot_second)))
    label = notationSubstituted(operation, name_first, name_second)
    slot_created =
      g_scene.addItem(derived, label, inkCycled(g_scene.len), float(now), anchor)
  g_borns[slot_created] = float(now)
  g_selection.selectOnly(slot_created)
  g_history.record(g_scene)
  let shape_word = shapeText(derived)
  OperationResult(
    created_slot: cint(slot_created),
    message: cstring(&"{label} gave {shape_word}."),
    shape_word: cstring(shape_word),
  )


proc nimSetVisible(slot: cint; is_visible: bool) {.exportc.} =
  ## Rewrite item's visibility, by slot.
  g_scene.setVisible(int(slot), is_visible)
  g_history.record(g_scene)


proc nimSetLabel(slot: cint; text: cstring) {.exportc.} =
  ## Rewrite item's display label, by slot.
  toChars($text, g_scene.labelAt(int(slot)))


proc nimSetInk(slot: cint; ink_ordinal: cint) {.exportc.} =
  ## Rewrite item's palette slot, by slot.
  g_scene.setInk(int(slot), Ink(ink_ordinal))
  g_history.record(g_scene)


proc nimSetCoefficient(slot, basis_index: cint; value: cfloat) {.exportc.} =
  ## Rewrite one basis coefficient of item's own multivector, by slot.
  g_scene.geometryAt(int(slot))[Basis(basis_index)] = float(value)


proc nimRemoveItem(slot: cint) {.exportc.} =
  ## Drop item from the scene, freeing its slot for reuse.
  ##   Drops the slot from the selection too: a freed slot goes straight back to the next
  ##   add, so a pick left behind would silently reattach to an unrelated new object.
  g_scene.removeItem(int(slot))
  g_selection.pruneDead(g_scene)
  g_history.record(g_scene)



#[ Ghost Preview ]#

proc nimSetGhost(coefficients: seq[float]) {.exportc.} =
  ## Rewrite the staged ghost multivector wholesale, from the open session's own JS-side
  ## 16-element state array -- called on every `input` event on any one of its sixteen
  ## fields, so the preview tracks a keystroke rather than waiting for the field to blur.
  ## Builds `geometry` coefficient-by-coefficient the same way `nimSceneAddRaw` does for a
  ## loaded item, but writes into `g_ghost` instead of a scene slot; `nimBuildFrame` reads
  ## it back next frame and draws it like any other object, tinted `INK_GHOST`, muted.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  g_ghost = some(geometry)


proc nimDescribeCoefficients(coefficients: seq[float]): cstring {.exportc.} =
  ## Report the same `shape: equation` line an item row shows, for a staged multivector
  ## that has no slot yet -- so a row being composed or edited previews exactly what it
  ## would read as once committed, rather than the presentation layer assembling that
  ## sentence for itself out of two separate exports.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  cstring(shapeText(geometry) & ": " & multivectorText(geometry))


proc nimClearGhost() {.exportc.} =
  ## Discard the ghost, so `nimBuildFrame` stops drawing it -- called once a session
  ## commits (`nimAddItem`/`nimCommitItem`) or is abandoned.
  g_ghost = none(Multivector)



#[ Catalogue Metadata ]#

proc nimOperationCount(): cint {.exportc.} = cint(COUNT_OPERATION)
  ## Report how many catalogue operations exist.


proc nimOperationNotation(index: cint): cstring {.exportc.} =
  ## Report the Nth catalogue operation's own notation and name, from the one table both
  ##   render paths read. A parallel browser-only table existed while the desktop font
  ##   atlas carried no astral-plane glyphs; it does now, so the two cannot drift apart.
  lut_operation_to_notation[Operation(index)]


proc nimOperationArity(index: cint): cint {.exportc.} =
  ## Report 0 for an operation that reads one operand, 1 for one that reads two --
  ## matching `panel.layoutOperation`'s own disabling of the second operand picker.
  cint(lut_operation_to_arity[Operation(index)])


proc nimBasisCount(): cint {.exportc.} = cint(ord(Basis.high) + 1)
  ## Report how many basis coefficients a multivector carries in this build's dimension.


proc nimBasisName(index: cint): cstring {.exportc.} = cstring(lut_basis_to_name[Basis(index)])
  ## Report the Nth basis element's own name.


proc nimBasisGrade(index: cint): cint {.exportc.} = cint(ord(Basis(index).grade))
  ## Report the Nth basis element's own grade, for grouping the coefficient grid.


proc nimInkChoosableSlots(): seq[int] {.exportc.} =
  ## List the palette slots a colour picker may offer, as whole-palette ordinals ready to
  ##   hand back to `nimInkName` and `nimInkColor`. Structural slots are left out: an
  ##   object wearing the backdrop, a world axis or the selection outline is either
  ##   invisible or reads as something it is not.
  for index in 0 ..< COUNT_INK_CATEGORICAL: result.add(ord(inkCategorical(index)))


proc nimInkName(index: cint): cstring {.exportc.} = lut_ink_to_name[Ink(index)]
  ## Report the Nth palette entry's own name.


proc nimInkColor(index: cint): seq[float32] {.exportc.} = toRgbSeq(Ink(index).colour)
  ## Report the Nth palette entry's own colour, as an `[r, g, b]` triple.


proc nimBackdropColor(): seq[float32] {.exportc.} = toRgbSeq(Ink.Backdrop.colour)
  ## Report the canvas backdrop's own colour, as an `[r, g, b]` triple.


const INK_POOL_FREE = Ink.Grid
  ## Mirror `panel.INK_POOL_FREE` exactly (duplicated rather than imported, since
  ##   `panel` is a desktop-only module this build cannot compile): the palette's own
  ##   recessive furniture colour, which is what a free object-pool slot is.


proc nimPoolCellColors(): seq[float32] {.exportc.} =
  ## Report the object-pool strip's own colours, one `[r, g, b]` triple per slot in slot
  ##   order, so a cell wears the ink of whatever object holds it and a free one stays
  ##   recessive. Mirrors `panel.layoutDiagnosticsObjectPool`'s own cell loop; the caller
  ##   walks the result in threes and needs to know no palette rule of its own.
  result = newSeqOfCap[float32](ITEMS_MAX * 3)
  for slot in 0 ..< ITEMS_MAX:
    let colour =
      if g_scene.isAlive(slot): g_scene.inkAt(slot).colour else: INK_POOL_FREE.colour
    result.add(colour.red)
    result.add(colour.green)
    result.add(colour.blue)



#[ Render Metrics ]#

proc nimRenderLineWidths(): seq[float32] {.exportc.} =
  ## Report `[point_size, furniture_line_width, object_line_width]`, so the browser's
  ## own `gl.uniform1f`/`gl.lineWidth` calls draw at the same sizes the desktop build's
  ## `renderer.nim` does, without a hand-copied literal to drift out of sync with it.
  @[SIZE_POINT, WIDTH_LINE_FURNITURE, WIDTH_LINE_OBJECT]


proc nimOverlayMetrics(): seq[float32] {.exportc.} =
  ## Report `[overlay_line_width, selected_alpha, hover_alpha]`, so the browser's SVG overlay
  ## strokes markers and the drag rubber-band at the same weight the desktop build's
  ## `visualiser.drawMarker` does, without a hand-copied literal to drift out of sync
  ## with it.
  ##   A marker's own size is not here: it depends on the shape being marked, and comes
  ##   back from `nimSelectionMarker` with the marker itself.
  @[WIDTH_MARKER, ALPHA_MARKER_SELECTED, ALPHA_MARKER_HOVER]



#[ Camera ]#

proc nimCameraOrbit(turn, rise: cfloat) {.exportc.} =
  ## Rotate camera about its own target by turn (azimuth) and rise (elevation), radians.
  g_tween_camera.abandon()
  camera.orbit(g_camera, float(turn), float(rise))


proc nimCameraDolly(factor: cfloat) {.exportc.} =
  ## Scale camera's own distance from target by factor.
  g_tween_camera.abandon()
  camera.dolly(g_camera, float(factor))


proc nimCameraPan(across, up: cfloat) {.exportc.} =
  ## Slide camera's own target sideways and vertically in its own view plane.
  g_tween_camera.abandon()
  camera.pan(g_camera, float(across), float(up))


proc nimCameraAzimuth(): cfloat {.exportc.} = cfloat(g_camera.azimuth)
  ## Report angle about world up, in radians.
proc nimCameraElevation(): cfloat {.exportc.} = cfloat(g_camera.elevation)
  ## Report angle above the horizontal plane, in radians.
proc nimCameraDistance(): cfloat {.exportc.} = cfloat(g_camera.distance)
  ## Report distance from target, in world units.
proc nimCameraFov(): cfloat {.exportc.} = cfloat(g_camera.degrees_field_of_view)
  ## Report vertical field of view, in degrees.
proc nimCameraTarget(): seq[float32] {.exportc.} =
  ## Report point camera orbits around, as an `[x, y, z]` triple.
  @[cfloat(g_camera.target.x), cfloat(g_camera.target.y), cfloat(g_camera.target.z)]


proc nimSetCameraAzimuth(v: cfloat) {.exportc.} =
  ## Rewrite angle about world up, in radians.
  g_tween_camera.abandon()
  g_camera.azimuth = float(v)


proc nimSetCameraElevation(v: cfloat) {.exportc.} =
  ## Rewrite angle above the horizontal plane, in radians, clamped to the same bound
  ## `panel.layoutView`'s own drag widget uses.
  g_tween_camera.abandon()
  g_camera.elevation = clamp(float(v), -ELEVATION_LIMIT, ELEVATION_LIMIT)


proc nimSetCameraDistance(v: cfloat) {.exportc.} =
  ## Rewrite distance from target, in world units, clamped to the same bound
  ## `panel.layoutView`'s own drag widget uses.
  g_tween_camera.abandon()
  g_camera.distance = clamp(float(v), DISTANCE_LIMIT_NEAR, DISTANCE_LIMIT_FAR)


proc nimSetCameraFov(v: cfloat) {.exportc.} = g_camera.degrees_field_of_view = float(v)
  ## Rewrite vertical field of view, in degrees.


proc nimSetCameraTarget(x, y, z: cfloat) {.exportc.} =
  ## Rewrite point camera orbits around.
  g_tween_camera.abandon()
  g_camera.target = Position(x: float(x), y: float(y), z: float(z))


proc nimCameraLimits(): seq[float32] {.exportc.} =
  ## Report the same bounds `panel.layoutView`'s own drag widgets clamp to, so a numeric
  ## input in the browser cannot walk the camera somewhere the desktop build would refuse.
  @[cfloat(ELEVATION_LIMIT), cfloat(DISTANCE_LIMIT_NEAR), cfloat(DISTANCE_LIMIT_FAR)]



#[ Picking And Drag ]#

const SLOT_NONE = -1'i32
  ## Cross the `{.exportc.}` boundary as "no slot" -- `cint` cannot carry `Option[int]`
  ## into JS, so every exported proc reporting an optional slot translates through this
  ## one constant at its own return, rather than inventing its own inline `-1`. See
  ## The boundary is where a JS-incompatible representation gets translated, not a reason
  ## to use it upstream -- everything on this side of that translation stays `Option[int]`.


func drawExtentFor(cam: Camera): DrawExtent =
  ## Derive camera-relative draw scale, exactly as `visualiser.drawExtentFor` does for
  ## the desktop build (duplicated rather than imported, since that proc lives in
  ## `visualiser.nim` itself, which does not compile under `nim js`).
  DrawExtent(
    extent_furniture: extentFurnitureFor(cam.distanceFar),
    eye: cam.eye,
    radius_horizon: radiusHorizonFor(cam.distanceFar),
  )


proc nimUpdateCursor(x, y: cfloat) {.exportc.} =
  ## Forward to `interaction.updateCursor`; see its own doc comment.
  interaction.updateCursor(g_interaction, float(x), float(y))


proc nimUpdateHover(width, height: cint) {.exportc.} =
  ## Forward to `interaction.updateHover`; see its own doc comment.
  let vp = g_camera.initMatrixViewProjection(float(width) / float(height))
  interaction.updateHover(g_interaction, g_scene, g_camera, vp, int(width), int(height))


proc nimHoverSlot(): cint {.exportc.} =
  ## Report slot currently hovered, or `SLOT_NONE` where nothing is.
  if g_interaction.index_hover.isSome: cint(g_interaction.index_hover.get) else: SLOT_NONE


proc nimClearHover() {.exportc.} =
  ## Discard whatever is currently hovered. Touch has no continuous pointer position the
  ## way a mouse does -- `nimUpdateHover` only ever runs at a specific touch-down point
  ## (long-press timer, tap detection), so once that finger lifts with nothing further
  ## touching the canvas, the last hover reading would otherwise sit stale forever and
  ## `refreshOverlay`'s own hover ring (only 20% dimmer than the selection ring) would
  ## keep drawing at that object indefinitely, reading as a second selected object.
  g_interaction.index_hover = none(int)


proc nimSelectionSlots(): seq[int] {.exportc.} =
  ## List the picked slots in pick order -- the presentation layer's own `refreshOverlay`
  ##   reads this to ring each one, the same way it already reads `nimHoverSlot` for the
  ##   hover ring, and the object rows read it to tick their own checkboxes.
  for position in 0 ..< g_selection.len: result.add(g_selection.at(position))


proc nimSelectionCount(): cint {.exportc.} = cint(g_selection.len)
  ## Count picked items, for a caller that only needs to know how many.


proc nimSelectionArity(): cint {.exportc.} = cint(ord(g_selection.impliedArity))
  ## Report the arity the current selection implies -- see `selection.impliedArity`, which
  ##   is where that rule lives for both builds. Matches `nimOperationArity`'s own
  ##   convention: 0 unary, 1 binary.


proc nimSelectOnly(slot: cint) {.exportc.} = g_selection.selectOnly(int(slot))
  ## Replace the whole selection with one slot.


proc nimSelectToggle(slot: cint) {.exportc.} = g_selection.toggle(int(slot))
  ## Add a slot to the end of the selection, or drop it where it is already picked; pick
  ##   order is what names operands m and n.


proc nimSelectClear() {.exportc.} = g_selection.clear()
  ## Drop every pick.


proc nimSelectionAllHidden(): bool {.exportc.} =
  ## Report whether every picked object is hidden, so a control acting on the whole
  ##   selection can name what it would do -- `show` where they are all hidden, `hide`
  ##   otherwise. Answered here rather than by the caller folding `nimItemVisible` over
  ##   the list, since what "the selection is hidden" means is a rule about a selection.
  ##   An empty selection is not hidden; there is nothing to show.
  if g_selection.len == 0: return false
  for position in 0 ..< g_selection.len:
    if g_scene.isVisible(g_selection.at(position)): return false
  true


proc nimAnimationMilliseconds(): cint {.exportc.} = cint(ANIMATION_MILLISECONDS)
  ## Report how long this build eases an animation for -- the same `mesh` constant a
  ##   freshly added object grows in over, handed out so the presentation layer's own
  ##   transitions run to it rather than to a second number written down separately.


proc nimUndo(): bool {.exportc.} =
  ## Move scene back one step on its own edit timeline; report whether there was an
  ## earlier step to move to. Clears the current selection unconditionally on success,
  ## since a restored snapshot's slot numbers may not match whatever was highlighted
  ## before.
  result = g_history.undo(g_scene)
  if result: g_selection.clear()


proc nimRedo(): bool {.exportc.} =
  ## Move scene forward one step on its own edit timeline; report whether there was a
  ## later step to move to. Clears the current selection unconditionally on success,
  ## for the same reason `nimUndo` does.
  result = g_history.redo(g_scene)
  if result: g_selection.clear()


proc nimCanUndo(): bool {.exportc.} =
  ## Report whether `nimUndo` would move anywhere, so the UI can dim/disable its own
  ## undo button rather than let a user press it only to read "Nothing to undo."
  g_history.canUndo


proc nimCanRedo(): bool {.exportc.} =
  ## Report whether `nimRedo` would move anywhere, mirroring `nimCanUndo`.
  g_history.canRedo


proc nimDragOperationForButton(dom_button: cint): cint {.exportc.} =
  ## Name the drag operation a pointer button starts, as a `DragOperation` ordinal, or
  ## `SLOT_NONE` for a button that starts none -- the browser's own counterpart to
  ## `visualiser.dragOperationFor`, duplicated rather than imported since that proc is
  ## tied to SDL's own button numbering (`visualiser.nim` does not compile under
  ## `nim js`) while this one is tied to `PointerEvent.button`'s (0 left, 1 middle, 2
  ## right -- a different numbering for the same three physical buttons).
  case dom_button
  of 0: cint(DragOperation.Join)
  of 2: cint(DragOperation.Meet)
  of 1: cint(DragOperation.Project)
  else: SLOT_NONE


proc nimBeginDrag(drag_ordinal: cint): bool {.exportc.} =
  ## Forward to `interaction.beginDrag`; see its own doc comment.
  interaction.beginDrag(g_interaction, DragOperation(drag_ordinal))


proc nimCancelDrag() {.exportc.} =
  ## Forward to `interaction.cancelDrag`; see its own doc comment.
  interaction.cancelDrag(g_interaction)


proc nimDragActive(): bool {.exportc.} = g_interaction.operation.isSome
  ## Report whether a drag is currently in progress.


proc nimDragOperation(): cint {.exportc.} =
  ## Report drag's own operation ordinal, or `SLOT_NONE` where no drag is active.
  if g_interaction.operation.isSome: cint(g_interaction.operation.get) else: SLOT_NONE


proc nimDragSourceSlot(): cint {.exportc.} = cint(g_interaction.index_source)
  ## Report item drag started from -- meaningful only while `nimDragActive()` is true,
  ## exactly mirroring `interaction.index_source`'s own doc comment; not a `SLOT_NONE`
  ## case of its own, since it is a plain forward of a field already paired with that
  ## guard rather than an independently optional value.


proc nimDragOperationToOperation(drag_ordinal: cint): cint {.exportc.} =
  ## Translate a `DragOperation` ordinal to the catalogue `Operation` it names -- the
  ## same translation `interaction.toOperation` makes, exposed directly for a caller
  ## (the touch tap-then-pick flow) that wants to call `nimApplyOperation` with an
  ## explicit pair of slots rather than go through the press-drag-release lifecycle a
  ## mouse or pen naturally offers and a tap does not.
  cint(toOperation(DragOperation(drag_ordinal)))


const lut_drag_to_ink = [
  DragOperation.Join: Ink.Jade,
  DragOperation.Meet: Ink.Rose,
  DragOperation.Project: Ink.Olive,
] ## Mirror `visualiser.lut_drag_to_ink` exactly, so the browser's own rubber-band and
  ## tap-then-pick menu tint each operation the same colour the desktop build's own
  ## panel legend and drag overlay do -- duplicated rather than imported, since that
  ## table lives in `visualiser.nim` itself, which does not compile under `nim js`.


proc nimDragTint(drag_ordinal: cint): seq[float32] {.exportc.} =
  ## Report the colour a drag's own operation tints its rubber-band, as an `[r, g, b]`
  ## triple.
  toRgbSeq(lut_drag_to_ink[DragOperation(drag_ordinal)].colour)


type DragResult = object ## Report what ending a drag produced.
  created_slot: cint ## `SLOT_NONE` where nothing was added (released over empty space,
    ## or on the drag's own source).
  message: cstring ## Outcome, for display exactly as the desktop panel's own status line.


proc nimEndDrag(now: cfloat): DragResult {.exportc.} =
  ## End the drag in progress, applying its operation between source and hovered item.
  ##   Calls straight into `interaction.endDrag` for everything it reports -- the same
  ##   catalogue call, anchor resolution, slot bookkeeping, operand-derived label and
  ##   outcome message the desktop build's own mouse-release handler gets -- and adds only
  ##   what is this build's own business: the birth clock, the selection and the history
  ##   entry. This once re-labelled the created item by hand, because `endDrag` read its
  ##   operands' labels through `$toCstring`, which comes out empty under the JS backend;
  ##   `scene.toText` now reads them the same on both, so there is nothing left to fix up.
  let outcome = interaction.endDrag(g_interaction, g_scene, float(now))
  if outcome.index_created.isSome:
    let slot = outcome.index_created.get
    g_borns[slot] = float(now)
    g_selection.selectOnly(slot)
    g_history.record(g_scene)
    return DragResult(created_slot: cint(slot), message: cstring(outcome.message))
  DragResult(created_slot: SLOT_NONE, message: cstring(outcome.message))


proc nimAnchorScreen(slot, width, height: cint): seq[float32] {.exportc.} =
  ## Project the same representative point `picking.anchorFor` and
  ## `visualiser.drawInteractionOverlay` use for this item onto screen pixels, so the
  ## browser's own hover ring and drag rubber-band can be drawn as plain 2D overlay,
  ## exactly matching where the desktop build draws them.
  ##   Reports `[x, y, is_in_front]`, the last 0 or 1: caller should draw nothing where
  ##   it is 0, matching `picking.isInFront`'s own gate -- also 0 where slot no longer
  ##   holds a live item, the same "nothing to draw" response a caller already handles,
  ##   since every caller here (`refreshOverlay`'s hover ring, selection ring and drag
  ##   line) reads a slot carried across frames -- `nimHoverSlot`/`nimDragSourceSlot`
  ##   are not re-picked at draw time -- so any of them can go stale the moment the
  ##   item they name is removed, with no frame boundary forcing a re-check first.
  if not g_scene.isAlive(int(slot)): return @[0.0'f32, 0.0'f32, 0.0'f32]
  let
    scale = drawExtentFor(g_camera)
    anchor = anchorFor(g_scene.geometryAt(int(slot)), scale)
  if anchor.isNone: return @[0.0'f32, 0.0'f32, 0.0'f32]
  let vp = g_camera.initMatrixViewProjection(float(width) / float(height))
  let screen = projectToScreen(vp, int(width), int(height), anchor.get)
  @[cfloat(screen.x), cfloat(screen.y), (if screen.isInFront: 1.0'f32 else: 0.0'f32)]


proc nimSelectionMarker(slot, width, height: cint): seq[float32] {.exportc.} =
  ## Shape this item's own selection/hover marker and report it flat, for the browser's
  ## SVG overlay to stroke: `[kind, is_closed, radius, x0, y0, x1, y1, ...]`.
  ##   `kind` is `marker.MarkerKind`'s own ordinal -- 0 a ring about a point, 1 a pair of
  ##   rails flanking a line (four points, two per rail), 2 a polyline lying on a plane.
  ##   `radius` is meaningful for a ring alone and 0 otherwise; `is_closed` for a
  ##   polyline alone. Point count is whatever is left, so a caller reads it off the
  ##   length rather than being handed a count it could disagree with.
  ##   Empty where there is nothing to draw -- a dead slot, geometry with no shape, or an
  ##   object at horizon, which draws fixed to the eye with nothing to surround. That is
  ##   the same "nothing to draw" answer `nimAnchorScreen` gives, and callers here read a
  ##   slot carried across frames, so any of them can go stale the moment its item is
  ##   removed.
  if not g_scene.isAlive(int(slot)): return
  let
    scale = drawExtentFor(g_camera)
    vp = g_camera.initMatrixViewProjection(float(width) / float(height))
    shaped = markerFor(
      g_scene.geometryAt(int(slot)), g_scene.anchorOverrideAt(int(slot)), scale,
      g_camera, vp, int(width), int(height),
    )
  if shaped.isNone: return

  let marker = shaped.get
  result = @[cfloat(ord(marker.kind)), 0.0'f32, 0.0'f32]
  case marker.kind
  of MarkerKind.Ring:
    result[2] = cfloat(marker.radius)
    result.add([cfloat(marker.centre.x), cfloat(marker.centre.y)])
  of MarkerKind.Rails:
    for i in 0 ..< marker.count_segment:
      for point in marker.segments[i]:
        result.add([cfloat(point.x), cfloat(point.y)])
  of MarkerKind.Loop:
    result[1] = (if marker.is_closed: 1.0'f32 else: 0.0'f32)
    for i in 0 ..< marker.count_point:
      result.add([cfloat(marker.points[i].x), cfloat(marker.points[i].y)])



#[ Scene Save/Load Primitives ]#

proc nimSceneClear() {.exportc.} =
  ## Discard the live scene and start a fresh empty one.
  g_scene = initScene()
  g_selection.clear()
  g_history = initHistory(g_scene)


proc nimSceneAddRaw(
  ink_ordinal: cint; is_visible: bool; label: cstring; coefficients: seq[float]
): cint {.exportc.} =
  ## Add one item straight from parsed `.rgascene` fields, for the load path: the hand-
  ## written presentation layer parses the uploaded file's bytes into exactly these
  ## fields (see this module's own doc comment for why packing/parsing itself lives in
  ## JS, not here) and calls this once per item, in file order.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  let slot = g_scene.addItem(geometry, $label, Ink(ink_ordinal))
  g_scene.setVisible(slot, is_visible)
  # Matches Item.born's own "dawn of time" default for a loaded item (never partway
  #   through an appear-in animation that never happened this run): without this, the
  #   slot could otherwise still hold a stale g_borns reading from whatever occupied it
  #   earlier this session, misranking a just-loaded item as more recent than it is.
  g_borns[slot] = 0.0
  cint(slot)



#[ Frame Assembly ]#

type FrameData = object
  ## Hold one frame's worth of vertex data plus the transform it is drawn through --
  ## everything a caller needs to issue this frame's `gl.drawArrays` calls.
  tri_verts, line_verts, point_verts: seq[float32]
  view_projection: seq[float32]
  furn_line_verts: seq[float32] ## Ground grid and world axes alone -- drawn first, at
    ## their own thinner line width (see `renderer.WIDTH_LINE_FURNITURE`).


proc nimBuildFrame(
  aspect, now: cfloat; is_axes_shown, is_grid_shown: bool
): FrameData {.exportc.} =
  ## Tessellate every visible object in the live scene, at the camera's current
  ## placement, through the same `mesh.addObject` dispatch and `camera` transforms the
  ## desktop app draws through -- every item always at full colour, exactly as the
  ## desktop build's own interactive `assembleMeshes` call (`are_dimmed` all false)
  ## draws outside of a storyboard capture.
  ##   Exceeds the working 60-line default: mirrors `visualiser.assembleMeshes`'s own
  ##   two-pass draw-order invariant (horizon plane first, so its translucent dome never
  ##   occludes an ordinary plane's own fill drawn after it) and additionally packs the
  ##   view-projection matrix plus the whole `FrameData` return struct -- packaging the
  ##   desktop side never needs, since it reads `MESHES`/`MESHES_FURNITURE` straight
  ##   through `renderer.nim` instead of handing them back across an FFI boundary.
  ##   Splitting the packaging out would return partial results across an extra proc
  ##   boundary for no reader benefit.
  ##   Also draws `g_ghost`, if any, through the same `addObject` dispatch, tinted
  ##   `INK_GHOST` and muted -- see that var's own doc comment for why it never touches
  ##   `g_scene` and so is invisible to `nimSceneSlots`/undo/redo/save/picking.
  clearMeshes(g_meshes_furniture)

  # Carry the camera one frame further toward whatever is being worked on, then aim it
  #   again from what this frame holds -- the same one rule `visualiser.assembleMeshes`
  #   applies, so neither UI decides for itself when the camera should move. Advancing
  #   before `scale` is read keeps this frame's furniture extent and horizon radius
  #   consistent with where the camera actually is.
  g_tween_camera.advance(g_camera, float(now), easeOutCubic)
  let scale = drawExtentFor(g_camera)
  block:
    var geometry = none(Multivector)
    if g_ghost.isSome: geometry = g_ghost
    elif g_selection.len == 1 and g_scene.isAlive(g_selection.at(0)):
      geometry = some(g_scene.geometryAt(g_selection.at(0)))
    let aim = if geometry.isSome: aimFor(geometry.get, scale) else: none(CameraAim)
    if aim.isSome: g_tween_camera.aimAt(g_camera, aim.get, float(now), ANIMATION_SECONDS)
    else: g_tween_camera.release()

  if is_grid_shown: addGrid(g_meshes_furniture, scale.extent_furniture)
  if is_axes_shown: addAxes(g_meshes_furniture, scale.extent_furniture)

  clearMeshes(g_meshes)
  # A horizon plane's own dome first, before anything else that might share its own
  #   translucent `Primitive.Triangle` bucket -- see `visualiser.assembleMeshes`'s own
  #   doc comment (mirrored here) for why draw order matters: that bucket draws in
  #   whatever order its vertices were appended, unsorted by depth, so inserting the
  #   dome first guarantees every ordinary plane's own fill blends over it rather than
  #   the reverse, regardless of which scene slot either happens to occupy.
  # Walks slots directly with the by-slot "At" accessors rather than through the `pairs`
  #   iterator: under the JS backend, `Item` holds `Scene` by value rather than by
  #   pointer (see `Item`'s own doc comment), so constructing one -- as `pairs` does,
  #   once per live slot, twice over below -- copies the *entire* scene just to read a
  #   handful of that one slot's own fields. Measured directly: at a full 64-item scene
  #   this cost alone was ~150ms/frame, worse than useless for a 60fps draw loop: fixed
  #   by adding `inkAt`/`anchorOverrideAt` beside the geometry/label/visibility "At"
  #   readers `scene.nim` already had (purely additive there, native-inert, mirroring
  #   the existing `geometryAt`/`isVisible` pattern) and reading every field here by
  #   slot instead.
  for slot in 0 ..< ITEMS_MAX:
    if not g_scene.isAlive(slot): continue
    if g_scene.isVisible(slot):
      let geometry = g_scene.geometryAt(slot)
      if isHorizonPlane(geometry):
        let progress = animationProgress(float(now), g_borns[slot])
        discard g_meshes.addObject(
          geometry, g_scene.inkAt(slot).colour, scale, progress, g_scene.anchorOverrideAt(slot)
        )

  for slot in 0 ..< ITEMS_MAX:
    if not g_scene.isAlive(slot): continue
    if g_scene.isVisible(slot):
      let geometry = g_scene.geometryAt(slot)
      if not isHorizonPlane(geometry):
        let progress = animationProgress(float(now), g_borns[slot])
        discard g_meshes.addObject(
          geometry, g_scene.inkAt(slot).colour, scale, progress, g_scene.anchorOverrideAt(slot)
        )

  if g_ghost.isSome:
    discard g_meshes.addObject(g_ghost.get, INK_GHOST.colour.muted(), scale)

  let vp = g_camera.initMatrixViewProjection(float(aspect))
  var view_projection = newSeq[float32](16)
  for row in 0 .. 3:
    for column in 0 .. 3:
      view_projection[4*column + row] = vp.at(row, column)

  FrameData(
    tri_verts: flatten(g_meshes[Primitive.Triangle]),
    line_verts: flatten(g_meshes[Primitive.Line]),
    point_verts: flatten(g_meshes[Primitive.Point]),
    view_projection: view_projection,
    furn_line_verts: flatten(g_meshes_furniture[Primitive.Line]),
  )
