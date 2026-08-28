## Bridge the interactive RGA panel to a WebGL front end, compiled through Nim's own
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

import ../../pga
import ../core/[
  camera, format, framing, help, history, interaction, marker, mesh, objects, picking,
  scene, selection, storyboard,
]



proc performanceNow(): float {.importjs: "performance.now()".}
  ## Read the page's own monotonic clock, in milliseconds.
  ##   The bridge's one piece of interop beyond its exports: everything else takes the
  ##   frame's `now` as a parameter, but the per-phase draw timings the diagnostics tab
  ##   shows have to bracket work *inside* one call, which a single caller-supplied
  ##   reading cannot do. Confined to timing -- no rule may read it.



#[ Panel State ]#

type SettingsFurniture = tuple
  ## Name everything the ground grid and the world axes are built from.
  ##   `mesh.addGrid` and `mesh.addAxes` read only a reach and a `DrawExtent`, and
  ## `camera.drawExtentFor` derives every field of that from exactly these -- so two frames
  ## agreeing here draw the same furniture, vertex for vertex. A field added to `Camera`
  ## that `drawExtentFor` reads has to be added here too, or a frame will hold furniture
  ## that no longer matches the view.
  target_x, target_y, target_z: float
  distance, azimuth, elevation, degrees_field_of_view: float
  height_pixels: int
  is_axes_shown, is_grid_shown: bool


type SettingsOverlay = tuple
  ## Name everything the overlay's shared draw extent and view-projection depend on:
  ## the camera's whole placement and the viewport it is asked about.
  target_x, target_y, target_z: float
  distance, azimuth, elevation, degrees_field_of_view: float
  width, height: int

type ShapedMarker = tuple
  ## One shaped marker beside everything it was shaped from; see `g_shaped_marker`.
  slot: int
  width, height: int
  progress: float
  is_touch: bool
  swell: float
  travel: float
  settings: SettingsOverlay
  marker: ref Marker
    ## Boxed, and the box is the point: a `Marker` is a wide variant object -- two 35-point
    ## pulse runs, a 64-point loop, both bands -- and the JS backend deep-copies every
    ## value assignment through `nimCopy`. Stored by value, the memo's own store-and-read
    ## copied the marker twice over and measured as slow as the shaping it replaced; the
    ## same backend trap PROVENANCE.md already lists three earlier catches of. Behind a
    ## ref there is one copy at the store and none at the read.


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
  g_settings_furniture = none(SettingsFurniture) ## What the furniture standing in
    ## `g_meshes_furniture` was built from, or none where none has been built yet.
    ##   Kept so a frame whose settings match can skip the rebuild entirely; see
    ## `FrameData.is_furniture_held` for the measurement that earns it.
  g_settings_overlay = none(SettingsOverlay) ## What `g_scale_overlay`/`g_vp_overlay`
    ## below were derived from, or none where none has been derived yet.
  g_scale_overlay: DrawExtent ## The draw extent the overlay calls share; see
    ## `extentViewOverlay`.
  g_vp_overlay: Matrix4 ## The view-projection those same calls share.
  g_shaped_marker = none(ShapedMarker) ## The marker `nimSelectionMarker` last shaped,
    ## with everything it was shaped from, so `nimSelectionPulse` asked the very same
    ## question in the very same frame reads the answer instead of shaping it again.
    ##   Why reuse is sound: the overlay draws each slot marker-then-pulse back to back in
    ## one synchronous pass, so nothing -- no pointer event, no edit -- can run between
    ## the write and the read; and the marker call *always* shapes fresh and overwrites
    ## this, so an entry can never outlive the frame that wrote it into a later one whose
    ## scene differs. The key still carries every non-scene input, so a pulse asked at
    ## other settings shapes for itself rather than trusting a near miss.
    ##   Measured before this existed: shaping twice cost ~1 ms per selected object per
    ## frame on the driving container, the largest overlay cost left after the mesh work.
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
  g_operations: OperationMemory ## Which operation each arity's picker opens on, carried
    ## from the last apply so a reader picking five wedges in a row picks once.
  g_clock_pulse: PulseClock ## Each selected object's own orientation-pulse phase, carried
    ## between frames rather than computed from the clock -- see `selection.PulseClock` for
    ## why a phase read straight off the time teleports whenever the camera moves.
  g_seconds_step_pulse: float ## How long the frame being drawn is, for that clock. Held
    ## rather than passed, because `nimTickPulse` takes one reading and every
    ## `nimSelectionPulse` after it in the same frame must advance by that same step.
  g_tween_camera: CameraTween ## Carries the camera toward whatever is being built or
    ## edited -- see `camera.CameraTween`. Aimed and advanced inside `nimBuildFrame`, from
    ## the same one rule the desktop build uses, so neither UI decides for itself when the
    ## camera should move.
  g_history: History ## Undo/redo timeline of scene-content edits; scoped exactly as
    ## `visualiser.HISTORY` is -- see `history.nim`'s own doc comment for what is and is
    ## not on this timeline. Seeded via `initHistory(g_scene, g_camera)` wherever `g_scene`
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
  g_preview = none(Preview) ## What an open **apply** control would build, ghosted while the
    ## reader is still choosing it rather than only once apply is pressed -- the rule the
    ## drag's own rubber-band already follows.
    ##   Its own slot rather than `g_ghost`'s, so which of the two shows is decided in Nim
    ## by `staged` below and not by whichever presentation-layer handler happened to fire
    ## last. Written by `nimGhostOperation` and dropped by `nimClearPreview`.

const INK_GHOST = Ink.Guide
  ## Palette slot the ghost draws in, muted -- reuses Ink.Guide's own existing
  ## "construction helper" semantics rather than adding a palette entry just for this.


proc toRgbSeq(c: Rgba): seq[float32] = @[c.red, c.green, c.blue]
  ## Format colour as an `[r, g, b]` triple, for a caller that wants a CSS colour string
  ## to format one for itself -- DOM styling is not this module's own job.


func countOverlay(mesh: Mesh): int =
  ## Count how many of one mesh's vertices are its overlay run, drawn with no depth test.
  ##   Zero where nothing asked to be drawn over; see `mesh.Mesh.index_overlay`.
  if mesh.index_overlay.isNone: return 0
  max(0, mesh.count_vertices - clamp(mesh.index_overlay.get, 0, mesh.count_vertices))


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
  ##   Arrives as a replay, like the demo and like a loaded file: the opening scene is a
  ##   construction someone else made too, and watching it build states in half a second
  ##   what a static arrangement of five objects does not -- that these were placed one at
  ##   a time and everything else here is derived from them.
  g_scene = initScene()
  constructSeeds(g_scene, now)
  g_scene.replayFrom(now)
  for slot in 0 ..< g_scene.len: g_borns[slot] = g_scene.bornAt(slot)


proc nimInit(now: cfloat) {.exportc.} =
  ## Build the default interactive scene and place the camera at the same default orbit
  ## the desktop app itself opens on.
  placeSeeds(float(now))
  g_camera = initCameraDefault()
  g_selection.clear()
  g_history = initHistory(g_scene, g_camera)


proc nimLoadDemo(now: cfloat) {.exportc.} =
  ## Replace the current scene with the full eleven-step storyboard construction, as
  ## ordinary live items -- a one-click preset rather than a scripted playback mode: once
  ## loaded, every one of its objects is exactly as editable, removable and pickable as
  ## anything built by hand.
  ##   Arrives as a replay: `scene.replayFrom` restamps the whole construction, so the
  ##   seeds appear one after another and then each derived step in turn, exactly as a
  ##   loaded `.rgascene` file does. The same rule for all three because they are the same
  ##   thing to a reader -- a construction handed over whole, played back in the order it
  ##   was made -- and one beat kept in one place cannot drift from the others.
  ##   Restamped after the fact rather than as each step is applied, so the beat is fitted
  ##   to the whole arrival without this proc having to count it out in advance.
  g_scene = initScene()
  let clock = float(now)
  constructSeeds(g_scene, clock)
  for step in STEPS: applyStep(g_scene, step, clock)
  g_scene.replayFrom(clock)
  for slot in 0 ..< g_scene.len: g_borns[slot] = g_scene.bornAt(slot)
  g_selection.clear()
  g_history = initHistory(g_scene, g_camera)



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


proc nimSceneSlotsCreated(): seq[cint] {.exportc.} =
  ## Report every live slot, oldest creation first, for `glue.js`'s own scene writer.
  ##   Slot order and creation order part company the moment anything is removed, since
  ##   the arena hands the freed slot to the next arrival; a version-3 file promises the
  ##   latter, and this build writes that version. Kept as its own export rather than
  ##   reordering `nimSceneSlots`, whose callers want the dense positions their combo
  ##   boxes are indexed by.
  var slots: array[ITEMS_MAX, int]
  let count = g_scene.slotsCreated(slots)
  for position in 0 ..< count: result.add(cint(slots[position]))


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


proc nimDefaultInk(): cint {.exportc.} = cint(g_scene.inkNext)
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
  g_history.record(g_scene, g_camera)


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
  g_history.record(g_scene, g_camera)


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
      g_scene.addItem(derived, label, g_scene.takeInk(), float(now), anchor)
  g_operations.remember(operation)
  g_clock_pulse.forget(slot_created) # A fresh object starts its comet at the head.
  g_borns[slot_created] = float(now)
  g_selection.selectOnly(slot_created)
  g_history.record(g_scene, g_camera)
  let shape_word = shapeText(derived)
  OperationResult(
    created_slot: cint(slot_created),
    message: cstring(&"{label} gave {shape_word}."),
    shape_word: cstring(shape_word),
  )


proc nimOperationRemembered(arity: cint): cint {.exportc.} =
  ## Report the operation a picker of this arity should open on: whatever was last
  ## applied at that arity, or the catalogue's own first choice until something has been.
  cint(ord(g_operations.lastOf(if arity == 0: Arity.One else: Arity.Two)))


proc nimGhostOperation(operation_ordinal, slot_first, slot_second: cint): bool
  {.exportc.} =
  ## Stage what applying an operation to these operands *would* build, in the same ghost
  ## appearance an open edit session wears, without touching the scene or the undo timeline.
  ##   So a picker previews its own answer the moment one is chosen rather than only once
  ##   apply is pressed -- the rule the edit session already follows on a keystroke, and
  ##   the drag's own rubber-band beside it.
  ##   Through `scene.previewApplying`, so this ghost carries the anchor its disc will be
  ##   drawn about and the operands the camera should keep in view beside it -- the same
  ##   construction the drag offers, rather than a second one written out here.
  ##   False, and no preview, where either operand is gone or the pair makes nothing
  ##   drawable; a picker left open across a delete is an ordinary thing rather than an
  ##   error, and a pair that makes nothing is worth showing nothing for.
  g_preview = g_scene.previewApplying(
    Operation(operation_ordinal), int(slot_first), int(slot_second)
  )
  g_preview.isSome


proc nimClearPreview() {.exportc.} =
  ## Drop whatever an apply control was previewing, for one that has gone off screen.
  ##   Its own call rather than a flag read here: the presentation layer is what knows a
  ##   section has collapsed or a picker has been closed.
  g_preview = none(Preview)


proc staged(): Option[Preview] =
  ## Resolve what this build is offering as not-yet-committed: an open edit session's own
  ## geometry, else whatever an apply control is previewing, else nothing.
  ##   **The session wins**, and the order is stated here once rather than at the mesh and
  ##   the camera separately: a session is being typed into, while a preview is a passive
  ##   reading of two pickers, and the one the reader's hands are on is the one to show.
  ##   Its sibling is `panel.staged`, which answers the same question for the same two
  ##   sources on the other front-end; fix both or neither.
  if g_ghost.isSome: return some(previewStaging(g_ghost.get))
  g_preview


proc nimSetVisible(slot: cint; is_visible: bool) {.exportc.} =
  ## Rewrite item's visibility, by slot.
  g_scene.setVisible(int(slot), is_visible)
  g_history.record(g_scene, g_camera)


proc nimSetLabel(slot: cint; text: cstring) {.exportc.} =
  ## Rewrite item's display label, by slot.
  toChars($text, g_scene.labelAt(int(slot)))


proc nimSetInk(slot: cint; ink_ordinal: cint) {.exportc.} =
  ## Rewrite item's palette slot, by slot.
  g_scene.setInk(int(slot), Ink(ink_ordinal))
  g_history.record(g_scene, g_camera)


proc nimSetCoefficient(slot, basis_index: cint; value: cfloat) {.exportc.} =
  ## Rewrite one basis coefficient of item's own multivector, by slot.
  g_scene.geometryAt(int(slot))[Basis(basis_index)] = float(value)


proc nimRemoveItem(slot: cint) {.exportc.} =
  ## Drop item from the scene, freeing its slot for reuse.
  ##   Drops the slot from the selection too: a freed slot goes straight back to the next
  ##   add, so a pick left behind would silently reattach to an unrelated new object.
  g_scene.removeItem(int(slot))
  g_selection.pruneDead(g_scene)
  g_history.record(g_scene, g_camera)



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
  ## Report the Nth catalogue operation's own notation -- its symbols alone, without the
  ##   English name the table carries after them, which is three to five times wider and
  ##   pushed this picker's popover past what a hand can reach on a phone. From the one
  ##   table both render paths read. A parallel browser-only table existed while the
  ##   desktop font atlas carried no astral-plane glyphs; it does now, so the two cannot
  ##   drift apart.
  cstring(notationSymbolic(Operation(index)))


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
  ## Report `[overlay_line_width, selected_alpha, hover_alpha]`, so the browser's SVG
  ## overlay strokes markers and the drag rubber-band at the same weights the desktop
  ## build's `visualiser.drawMarker` does, without a hand-copied literal to drift out of
  ## sync with them.
  ##   A marker's own size is not here: it depends on the shape being marked, and comes
  ##   back from `nimSelectionMarker` with the marker itself. Neither is the orientation
  ##   pulse's, which stopped being a width the moment the run gained a taper -- it is
  ##   shaped into the outline `nimSelectionPulse` reports, and filled rather than stroked.
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


proc nimCameraDollyAt(factor: cfloat; width, height: cint) {.exportc.} =
  ## Scale camera's own distance from target by factor, toward whatever the cursor is
  ## over; see `interaction.dollyAtCursor`.
  ##   Reads the cursor this build already tracks (`nimUpdateCursor`), so a caller aiming a
  ## zoom somewhere -- a wheel at the pointer, a pinch at its own midpoint -- says where by
  ## moving the cursor there first, exactly as picking does.
  g_tween_camera.abandon()
  g_interaction.dollyAtCursor(
    g_camera, g_scene, float(factor), int(width), int(height)
  )


proc nimCameraPan(across, up: cfloat) {.exportc.} =
  ## Slide camera's own target sideways and vertically in its own view plane.
  ##   The rate reading of a pan, kept for a caller that has only a step to give.
  ## `nimCameraPanAt` below is what a drag uses.
  g_tween_camera.abandon()
  camera.pan(g_camera, float(across), float(up))


proc nimCameraPanAt(
  before_x, before_y, after_x, after_y: cfloat; width, height: cint
) {.exportc.} =
  ## Slide the view so the world point under `(before_x, before_y)` comes to lie under
  ## `(after_x, after_y)`; see `interaction.panAcross`.
  ##   Both ends of the pointer's step rather than its length, because a grab needs to know
  ## where it started as well as how far it went.
  g_tween_camera.abandon()
  panAcross(
    g_camera, ScreenPosition(x: float(before_x), y: float(before_y)),
    ScreenPosition(x: float(after_x), y: float(after_y)), int(width), int(height),
  )


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
  ## Rewrite distance from target, in world units, held off the one bound an orbit
  ## distance has; see `camera.distanceHeld`.
  g_tween_camera.abandon()
  g_camera.distance = distanceHeld(float(v))


proc nimSetCameraFov(v: cfloat) {.exportc.} = g_camera.degrees_field_of_view = float(v)
  ## Rewrite vertical field of view, in degrees.


proc nimSetCameraTarget(x, y, z: cfloat) {.exportc.} =
  ## Rewrite point camera orbits around.
  g_tween_camera.abandon()
  g_camera.target = Position(x: float(x), y: float(y), z: float(z))


proc nimCameraLimits(): seq[float32] {.exportc.} =
  ## Report the bounds a camera placement is held to, for a caller offering numeric input:
  ## elevation either side of the horizon, and the one floor an orbit distance has. There
  ## is deliberately no third entry -- nothing bounds how far out the camera may orbit; see
  ## `camera.DISTANCE_LIMIT_NEAR`.
  @[cfloat(ELEVATION_LIMIT), cfloat(DISTANCE_LIMIT_NEAR)]



#[ Picking And Drag ]#

const SLOT_NONE = -1'i32
  ## Cross the `{.exportc.}` boundary as "no slot" -- `cint` cannot carry `Option[int]`
  ## into JS, so every exported proc reporting an optional slot translates through this
  ## one constant at its own return, rather than inventing its own inline `-1`. See
  ## The boundary is where a JS-incompatible representation gets translated, not a reason
  ## to use it upstream -- everything on this side of that translation stays `Option[int]`.


proc nimUpdateCursor(x, y: cfloat) {.exportc.} =
  ## Forward to `interaction.updateCursor`; see its own doc comment.
  interaction.updateCursor(g_interaction, float(x), float(y))


proc nimSetCameraDragging(is_dragging: bool) {.exportc.} =
  ## Say whether a pointer gesture is moving the camera right now -- an orbit or pan drag,
  ## or two fingers on the canvas. What that means for hover is `interaction.updateHover`'s
  ## to say; this build only knows which of its own gestures is under way.
  g_interaction.is_dragging_camera = is_dragging


proc nimUpdateHover(width, height: cint) {.exportc.} =
  ## Forward to `interaction.updateHover`; see its own doc comment.
  let vp = g_camera.initMatrixViewProjection(float(width) / float(height))
  interaction.updateHover(g_interaction, g_scene, g_camera, vp, int(width), int(height))


proc nimHoverSlot(): cint {.exportc.} =
  ## Report slot currently hovered, or `SLOT_NONE` where nothing is.
  if g_interaction.index_hover.isSome: cint(g_interaction.index_hover.get) else: SLOT_NONE


proc nimIsHoverBackdrop(): bool {.exportc.} = g_interaction.is_hover_backdrop
  ## Report whether what is hovered is the whole sky -- a plane at horizon.
  ##   True wherever nothing else is under the pointer and such a plane is in the scene,
  ##   since it is drawn as a dome over every direction. Front-ends need it because it is
  ##   the one hovered thing that must not act like one: it starts no drag (see
  ##   `interaction.beginDrag`), and a tap on it means "empty space" to the touch flow
  ##   whose only way to dismiss a selection is tapping empty space.


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
  ## Forward to `selection.isAllHidden`; see its own doc comment.
  g_selection.isAllHidden(g_scene)


proc nimAnimationMilliseconds(): cint {.exportc.} = cint(ANIMATION_MILLISECONDS)
  ## Report how long this build eases an animation for -- the same `mesh` constant a
  ##   freshly added object grows in over, handed out so the presentation layer's own
  ##   transitions run to it rather than to a second number written down separately.


proc nimUndo(): bool {.exportc.} =
  ## Move scene back one step on its own edit timeline, putting the view back where that
  ## step was made from; report whether there was an earlier step to move to. Clears the
  ## current selection unconditionally on success, since a restored snapshot's slot numbers
  ## may not match whatever was highlighted before.
  ##   Abandons the standing camera tween along with it, or the aim it was carrying drags
  ##   the view straight off the placement just restored -- the same pairing
  ##   `panel.stepHistory` makes on the desktop build.
  result = g_history.undo(g_scene, g_camera)
  if result:
    g_selection.clear()
    g_tween_camera.abandon()


proc nimRedo(): bool {.exportc.} =
  ## Move scene forward one step on its own edit timeline, view and all; report whether
  ## there was a later step to move to. Clears the selection and abandons the camera tween
  ## on success, for the same reasons `nimUndo` does.
  result = g_history.redo(g_scene, g_camera)
  if result:
    g_selection.clear()
    g_tween_camera.abandon()


proc nimCanUndo(): bool {.exportc.} =
  ## Report whether `nimUndo` would move anywhere, so the UI can dim/disable its own
  ## undo button rather than let a user press it only to read "Nothing to undo."
  g_history.canUndo


proc nimCanRedo(): bool {.exportc.} =
  ## Report whether `nimRedo` would move anywhere, mirroring `nimCanUndo`.
  g_history.canRedo


proc nimDragKindForButton(dom_button: cint): cint {.exportc.} =
  ## Say what a pointer button starts: `SLOT_NONE` for no drag at all, otherwise the
  ## ordinal of the `interaction.MenuArming` a drag from that button carries.
  ##   Only the *numbering* is this build's own: `PointerEvent.button` counts 0 left, 1
  ## middle, 2 right, where SDL counts them differently, so each render path translates
  ## into `interaction.PointerButton` and asks the one shared rule what that button means.
  ## Which button does what used to be written out here as well, and the help panel would
  ## have made it a third copy.
  let button = case dom_button
    of 0: some(PointerButton.Left)
    of 1: some(PointerButton.Middle)
    of 2: some(PointerButton.Right)
    else: none(PointerButton)
  if button.isNone: return SLOT_NONE
  let arming = armingOf(button.get)
  if arming.isNone: SLOT_NONE else: cint(ord(arming.get))


proc nimRevealsMenuOnButton(dom_button: cint): bool {.exportc.} =
  ## Say whether a click of this pointer button brings the selection menu up with it.
  ##   Same translation and the same reason as `nimDragKindForButton` above: only the DOM's
  ## numbering is this build's own, and what a button *means* is `interaction`'s to say.
  case dom_button
  of 0: revealsMenuOn(PointerButton.Left)
  of 1: revealsMenuOn(PointerButton.Middle)
  of 2: revealsMenuOn(PointerButton.Right)
  else: false


proc nimRevealsWithoutPicking(has_selection, is_menu_shown: bool): bool {.exportc.} =
  ## Say whether a menu-revealing click should only reveal, leaving the selection alone.
  ##   Forwards to `interaction.revealsWithoutPicking`; see its own doc comment. Exported
  ## rather than written out in `glue.js` because the desktop asks the identical question
  ## and the two answering differently is exactly the drift this boundary exists to stop.
  revealsWithoutPicking(has_selection, is_menu_shown)


proc nimHelpEntries(): seq[cstring] {.exportc.} =
  ## Report every help entry flat, four strings each: the tab it belongs under, action,
  ## outcome, and `"touch"` or `""` for whether it is the touch way of doing it.
  ##   Flat rather than an array of records, for the same reason `nimSelectionMarker` is:
  ##   an object crossing this boundary would be a second shape to keep in step, and the
  ##   presentation layer only ever walks these in order to build rows.
  ##   The entries themselves are `help.lut_help_entries`, which the desktop panel renders
  ##   too -- neither UI writes this text.
  for entry in lut_help_entries:
    result.add([
      cstring(titleOf(entry.path)), cstring(entry.action), cstring(entry.outcome),
      cstring(if entry.is_touch: "touch" else: ""),
    ])


proc nimHelpDescriptions(): seq[cstring] {.exportc.} =
  ## Report what each tab is about, flat, two strings each: the tab's title and its own
  ## one-line description.
  ##   Its own export rather than a fifth string on `nimHelpEntries`, which is per *row*
  ##   and would carry the same sentence once for every row of a tab. Keyed by the title
  ##   the entries themselves carry, so the presentation layer joins the two on the string
  ##   it already groups rows by rather than on a position it would have to keep in step.
  for path in HelpPath:
    result.add([cstring(titleOf(path)), cstring(descriptionOf(path))])


proc nimBeginHold(slot: cint; now: cfloat) {.exportc.} =
  ## Forward to `interaction.beginHold`; see its own doc comment.
  interaction.beginHold(g_interaction, int(slot), float(now))


proc nimCancelHold() {.exportc.} =
  ## Forward to `interaction.cancelHold`; see its own doc comment.
  interaction.cancelHold(g_interaction)


proc nimHoldSlot(): cint {.exportc.} =
  ## Report which item a press in progress is filling, or `SLOT_NONE` where none is.
  if g_interaction.hold.isSome: cint(g_interaction.hold.get.slot) else: SLOT_NONE


proc nimTakeMaturedHold(now: cfloat): cint {.exportc.} =
  ## Forward to `interaction.takeHold`: the slot a matured hold selects, reported exactly
  ## once, or `SLOT_NONE` where there is nothing to take.
  ##   One question rather than "is it mature" asked beside a flag the caller keeps for
  ##   whether it has already acted; see `takeHold` for the regression those two disagreeing
  ##   produced.
  let taken = interaction.takeHold(g_interaction, float(now))
  if taken.isNone: SLOT_NONE else: cint(taken.get)


proc nimReleaseHold(now: cfloat) {.exportc.} =
  ## Forward to `interaction.releaseHold`; see its own doc comment.
  interaction.releaseHold(g_interaction, float(now))


proc nimSwellHold(now: cfloat): cfloat {.exportc.} =
  ## Forward to `interaction.swellHold`; see its own doc comment.
  cfloat(interaction.swellHold(g_interaction, float(now)))


proc nimIsHoldSpent(now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.isHoldSpent`; see its own doc comment.
  interaction.isHoldSpent(g_interaction, float(now))


proc nimHoldProgress(now: cfloat): cfloat {.exportc.} =
  ## Forward to `interaction.progressHold`; see its own doc comment.
  ##   Exported rather than left to a subtraction in the presentation layer: how long a
  ##   hold takes is a rule about this gesture, and a second copy of it in JS is a second
  ##   thing to keep in step with the marker it is supposed to be filling.
  cfloat(progressHold(g_interaction, float(now)))


proc nimHoldMature(now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.isHoldMature`; see its own doc comment.
  isHoldMature(g_interaction, float(now))


func keyFor(code: string): Option[Key] =
  ## Translate one DOM `KeyboardEvent.code` into the key the view knows it by, if it is one.
  ##   **`code`, not `key`**: it names the *physical* key, which is what the desktop's own
  ##   scancodes name, so W is the same key under the hand on both builds and on every
  ##   layout. Reading `key` bound the browser to whatever the layout prints -- on AZERTY
  ##   that is the key the desktop calls Z -- and it also changes under shift, which now
  ##   means "faster" rather than a different binding.
  ##   Only the naming is this build's own; what each key *does* is
  ##   `interaction.motionFor` and `interaction.actionFor`'s to say.
  case code
  of "KeyW": some(Key.W)
  of "KeyA": some(Key.A)
  of "KeyS": some(Key.S)
  of "KeyD": some(Key.D)
  of "KeyQ": some(Key.Q)
  of "KeyE": some(Key.E)
  of "KeyF": some(Key.F)
  of "ShiftLeft", "ShiftRight": some(Key.Shift)
  of "ArrowLeft": some(Key.Left)
  of "ArrowRight": some(Key.Right)
  of "ArrowUp": some(Key.Up)
  of "ArrowDown": some(Key.Down)
  of "BracketLeft": some(Key.BracketLeft)
  of "BracketRight": some(Key.BracketRight)
  of "Minus": some(Key.Minus)
  # The physical key most layouts print `+` on is the one carrying `=`; shift decides
  #   which is drawn on it, and the view wants the key rather than the glyph.
  of "Equal": some(Key.Plus)
  of "Enter": some(Key.Enter)
  of "Home": some(Key.Home)
  else: none(Key)


proc nimKeyBound(code: cstring): bool {.exportc.} =
  ## Report whether the view answers this key at all, so a caller knows whether to keep the
  ## browser's own default behaviour for it -- an arrow scrolling the page under the canvas
  ## is the case that matters.
  keyFor($code).isSome


proc nimKeyDown(code: cstring): cint {.exportc.} =
  ## Take one key press: hold it for `nimDriveHeld` to move the camera by, carry out
  ## whatever it does at a press, and report the slot the caller should select, or
  ## `SLOT_NONE`.
  ##   One entry point for both kinds of binding, so `glue.js` carries no opinion about
  ## which keys move the view -- that is `interaction`'s to say, and stating it in
  ## JavaScript is exactly the drift this project keeps finding.
  ##   Idempotent on a key already down, which is what the browser's own auto-repeat
  ## sends; the action below is re-run by a repeat, which is harmless for all four of them.
  let key = keyFor($code)
  if key.isNone: return SLOT_NONE
  g_interaction.holdKey(key.get)
  let action = actionFor(key.get)
  if action.isNone:
    # A key that moves the camera is a camera move like any other, so it abandons whatever
    #   tween was carrying it somewhere -- otherwise the tween drags it straight back.
    g_tween_camera.abandon()
    return SLOT_NONE
  let slot = applyAction(g_interaction, g_camera, g_scene, action.get)
  # Framing is the standing offer's own job (`framing.offerAim`); the key only lets go of
  #   the goal it holds, so the next frame aims afresh at whatever is selected.
  if action.get == KeyAction.FrameSelection: g_tween_camera.release()
  else: g_tween_camera.abandon()
  if slot.isNone: SLOT_NONE else: cint(slot.get)


proc nimKeyUp(code: cstring) {.exportc.} =
  ## Take one key release, so whatever it was moving stops.
  let key = keyFor($code)
  if key.isSome: g_interaction.releaseKey(key.get)


proc nimReleaseKeysAll() {.exportc.} =
  ## Let go of every held key, for a page that has stopped being told about releases --
  ## the window losing focus, or the tab going to the background. Without it the release
  ## arrives somewhere else and the camera moves forever.
  g_interaction.releaseKeysAll()


proc nimDriveHeld(seconds: cfloat) {.exportc.} =
  ## Move the camera by every held key, for one frame of `seconds`; see
  ## `interaction.driveHeld`.
  ##   Abandons the tween only when something is actually held, so a frame with no key
  ## down leaves a camera ease alone.
  if g_interaction.keys_held.len == 0: return
  g_interaction.driveHeld(g_camera, float(seconds))
  g_tween_camera.abandon()


proc nimFocusSlot(): cint {.exportc.} =
  ## Report which item the keyboard stands on, or `SLOT_NONE` where it stands on none.
  if g_interaction.index_focus.isSome: cint(g_interaction.index_focus.get) else: SLOT_NONE


proc nimTapSlop(): cfloat {.exportc.} = cfloat(PIXELS_TAP_SLOP)
  ## Report how far a press may move and still be a press; see `interaction.PIXELS_TAP_SLOP`
  ## for why this is a rule about the gesture rather than a presentation number.


proc nimBeginPress(now: cfloat) {.exportc.} =
  ## Forward to `interaction.beginPress`; see its own doc comment for why every press goes
  ## through it, including the ones that go on to move the camera rather than build.
  interaction.beginPress(g_interaction, float(now))


proc nimIsClick(now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.isClick`; see its own doc comment.
  ##   Reached directly only for a press that started over empty space, which begins no
  ##   drag and so has no `nimEndDrag` to report itself through.
  isClick(g_interaction, float(now))


proc nimBeginDrag(arming_ordinal: cint; now: cfloat): bool {.exportc.} =
  ## Forward to `interaction.beginDrag`; see its own doc comment.
  ##   Takes the arming as an ordinal rather than as a flag, since there are now three of
  ##   them and only two of the three are reachable from a mouse button.
  ##   `nimDragArmingOnDwell` names the one touch uses, so no caller writes a number of
  ##   its own.
  let arming = MenuArming(clamp(int(arming_ordinal), ord(low(MenuArming)), ord(high(MenuArming))))
  interaction.beginDrag(g_interaction, arming, float(now))


proc nimDragArmingOnDwell(): cint {.exportc.} =
  ## Report the arming a pointer with no second button starts a drag with.
  ##   Touch alone. Exported rather than written into the glue as a literal, for the same
  ##   reason every other ordinal crossing this boundary is: an enum reordered in
  ##   `interaction.nim` must not leave a number here quietly meaning something else.
  cint(ord(MenuArming.OnDwell))


proc nimUpdateDrag(now: cfloat) {.exportc.} =
  ## Forward to `interaction.updateDrag`; see its own doc comment.
  ##   Called once a frame, after `nimUpdateHover`, and before the frame that reads the
  ##   preview is built -- exactly the order `visualiser.renderFrame` runs them in.
  interaction.updateDrag(g_interaction, g_scene, float(now))


proc nimCancelDrag() {.exportc.} =
  ## Forward to `interaction.cancelDrag`; see its own doc comment.
  interaction.cancelDrag(g_interaction)


proc nimDragActive(): bool {.exportc.} = g_interaction.is_dragging
  ## Report whether a drag is currently in progress.


proc nimDragSourceSlot(): cint {.exportc.} = cint(g_interaction.index_source)
  ## Report item drag started from -- meaningful only while `nimDragActive()` is true,
  ## exactly mirroring `interaction.index_source`'s own doc comment; not a `SLOT_NONE`
  ## case of its own, since it is a plain forward of a field already paired with that
  ## guard rather than an independently optional value.


proc nimDragTint(): seq[float32] {.exportc.} =
  ## Report the colour the rubber-band wears right now, as an `[r, g, b]` triple.
  ##   Answered by `interaction.inkOfDrag` rather than from a table here: this file used
  ##   to keep its own copy of the operation-to-ink mapping, with a comment telling the
  ##   next reader to check the desktop's. Both now read the one in `core`.
  toRgbSeq(inkOfDrag(g_interaction, g_scene.inkNext).colour)


proc nimDragComet(width, height: cint): seq[float32] {.exportc.} =
  ## Report the drag band's own head flat, `[x0, y0, x1, y1, ...]`, as one closed outline
  ## for the overlay to fill over the band.
  ##   Shaped by `marker.cometFor`, and aimed from where the drag source is *drawn* -- a
  ##   plane's own creation anchor included -- at **this module's own cursor** rather than
  ##   at the one the presentation layer is holding.
  ##   Both are updated from the same pointer events, but only one of them can be the
  ##   answer, and the geometry belongs on the side that owns the gesture.
  ##   Empty where no drag is in flight, where the source's anchor is behind the eye, or
  ##   where the cursor rests on that anchor and there is no direction to point in.
  if not g_interaction.is_dragging: return
  let
    scale = g_camera.drawExtentFor(int(height))
    source = g_scene[g_interaction.index_source]
    anchor = anchorFor(source.geometry, source.anchorOverride, scale)
  if anchor.isNone: return
  let screen = projectToScreen(
    g_camera.initMatrixViewProjection(float(width) / float(height)),
    int(width), int(height), anchor.get,
  )
  if not screen.isInFront: return
  let comet = cometFor(screen, g_interaction.cursor)
  if comet.isNone: return
  for point in comet.get: result.add([cfloat(point.x), cfloat(point.y)])


proc nimMenuMetrics(): seq[float32] {.exportc.} =
  ## Report the sizes a choice menu is drawn at, so the presentation layer holds no copy
  ## of them: wedge height, label padding, corner rounding, border thickness, centre-dot
  ## radius, and the opacity of an offered wedge then of an unoffered one.
  ##   The same arrangement `nimOverlayMetrics` already uses for the marker's own sizes.
  @[
    float32(HEIGHT_MENU_WEDGE), float32(PADDING_MENU_WEDGE),
    float32(ROUNDING_MENU_WEDGE), float32(WIDTH_MENU_WEDGE_BORDER),
    float32(RADIUS_MENU_CENTRE),
    float32(ALPHA_MENU_WEDGE), float32(ALPHA_MENU_UNOFFERED),
  ]


proc nimDragMenuOpen(): bool {.exportc.} = g_interaction.menu.isSome
  ## Report whether the choice menu is open on the drag in progress.


proc nimDragMenuCentre(): seq[float32] {.exportc.} =
  ## Report where the open menu is centred, in canvas pixels, or empty where none is.
  if g_interaction.menu.isNone: return
  @[float32(g_interaction.menu.get.x), float32(g_interaction.menu.get.y)]


proc nimDragMenuLabels(): seq[cstring] {.exportc.} =
  ## Name every wedge, in `DragChoice` order, which is the order the layout below is in.
  for choice in DragChoice: result.add(cstring(labelOf(choice)))


proc nimDragMenuLayout(): seq[float32] {.exportc.} =
  ## Lay the open menu out, three floats per wedge in `DragChoice` order: centre x and y in
  ## canvas pixels, then whether it is offered as 1 or 0.
  ##   Flat rather than a record per wedge, exactly as `nimSelectionMarker` is: an object
  ##   crossing this boundary is a second shape to keep in step, and the presentation
  ##   layer only ever walks these in order to place four elements.
  ##   Carried each wedge's own red, green and blue too, while its label wore the choice's
  ##   hue. The label now wears `--ink`, like every button on the floating selection menu
  ##   this wheel is the other posture of, so the hue crossed this boundary for nobody.
  ##   `interaction.inkOf` still answers for the rubber-band and for the drawer's own
  ##   legend, which is where the hues are taught.
  ##   Empty where no menu is open, so the caller needs no second guard.
  if g_interaction.menu.isNone: return
  let
    centre = g_interaction.menu.get
    over = destinationOf(g_interaction)
    is_pair_live =
      over.isSome and over.get != g_interaction.index_source and
      g_scene.isAlive(over.get) and g_scene.isAlive(g_interaction.index_source)
  for choice in DragChoice:
    let
      at = anchorOf(centre, choice)
      is_offered =
        choice == DragChoice.More or
        (is_pair_live and isOffered(
          choice, g_scene.geometryOf(g_interaction.index_source),
          g_scene.geometryOf(over.get),
        ))
    result.add([float32(at.x), float32(at.y), float32(ord(is_offered))])


proc nimDragMenuHighlighted(): cint {.exportc.} =
  ## Report which wedge the cursor stands in as a `DragChoice` ordinal, or `SLOT_NONE`
  ## where it is back at the centre and nothing is chosen.
  ##   Asked of `interaction.choosing`, the same call the release itself resolves through
  ##   and the same one the ghost is shaped from, so what is highlighted is never a second
  ##   opinion about where the cursor is.
  let choice = g_interaction.choosing
  if choice.isNone: SLOT_NONE else: cint(ord(choice.get))


type DragResult = object ## Report what ending a drag produced.
  created_slot: cint ## `SLOT_NONE` where nothing was added -- released over empty space,
    ## on the drag's own source, on a pair that makes nothing, or on `more…`.
  message: cstring ## Outcome, for display exactly as the desktop panel's own status line.
  is_more: bool ## Whether the release chose `more…`, which builds nothing itself and
    ## instead leaves both operands selected for the apply section.
  clicked_slot: cint ## Item a press that never became a drag came down on, or `SLOT_NONE`
    ## for every actual drag. The caller selects it -- alone, or added where shift is
    ## held, which is a modifier only the caller can read.


proc nimEndDrag(now: cfloat): DragResult {.exportc.} =
  ## End the drag in progress, applying whatever the release resolved to.
  ##   Calls straight into `interaction.endDrag` for everything it reports -- the wedge
  ##   resolution, the catalogue call, anchor resolution, slot bookkeeping,
  ##   operand-derived label and outcome message the desktop build's own mouse-release
  ##   handler gets -- and adds only what is this build's own business: the birth clock,
  ##   the selection and the history entry. This once re-labelled the created item by
  ##   hand, because `endDrag` read its operands' labels through `$toCstring`, which comes
  ##   out empty under the JS backend; `scene.toText` now reads them the same on both.
  let outcome = interaction.endDrag(g_interaction, g_scene, float(now))
  if outcome.index_clicked.isSome:
    # A press that never moved. Reported rather than acted on: whether it replaces the
    #   selection or joins it is the shift key's to say, and that is the caller's to read.
    return DragResult(
      created_slot: SLOT_NONE, clicked_slot: cint(outcome.index_clicked.get)
    )
  if outcome.index_created.isSome:
    let slot = outcome.index_created.get
    g_borns[slot] = float(now)
    g_selection.selectOnly(slot)
    g_history.record(g_scene, g_camera)
    return DragResult(
      created_slot: cint(slot), message: cstring(outcome.message), clicked_slot: SLOT_NONE
    )
  if outcome.choice == some(DragChoice.More) and outcome.operands.isSome:
    # The way out of the gesture's own three operations into the other twenty-four: both
    #   operands selected in the order they were dragged, which is the order the apply
    #   section reads as m then n.
    g_selection.selectOnly(outcome.operands.get.source)
    g_selection.toggle(outcome.operands.get.destination)
    return DragResult(
      created_slot: SLOT_NONE, message: cstring(outcome.message), is_more: true,
      clicked_slot: SLOT_NONE,
    )
  DragResult(
    created_slot: SLOT_NONE, message: cstring(outcome.message), clicked_slot: SLOT_NONE
  )


proc extentViewOverlay(width, height: int): (DrawExtent, Matrix4) =
  ## Hand back the draw extent and view-projection the overlay calls share, deriving them
  ## only when the camera or the viewport has changed since the last ask.
  ##   Every overlay call -- the anchor, each selected object's marker, each pulse, each
  ## hover ring -- was deriving both for itself, and each derivation runs `camera.frame`'s
  ## joins twice over. Within one frame they are all the same answer: these are functions
  ## of the placement and the viewport alone, which is exactly what the key holds, so this
  ## is the furniture cache's reasoning applied to the overlay's own inputs.
  let settings: SettingsOverlay = (
    g_camera.target.x, g_camera.target.y, g_camera.target.z, g_camera.distance,
    g_camera.azimuth, g_camera.elevation, g_camera.degrees_field_of_view,
    width, height,
  )
  if g_settings_overlay.isNone or g_settings_overlay.get != settings:
    g_settings_overlay = some(settings)
    g_scale_overlay = g_camera.drawExtentFor(height)
    g_vp_overlay = g_camera.initMatrixViewProjection(float(width)/float(height))
  (g_scale_overlay, g_vp_overlay)


proc nimAnchorScreen(slot, width, height: cint): seq[float32] {.exportc.} =
  ## Project the same representative point `mesh.anchorFor` and
  ## `visualiser.drawInteractionOverlay` use for this item onto screen pixels, so the
  ## browser's own hover ring and drag rubber-band can be drawn as plain 2D overlay,
  ## exactly matching where the desktop build draws them.
  ##   The item's own **drawn** centre, through the anchor-aware `anchorFor`: a plane's disc
  ## is centred on its stored creation anchor, so a band or a menu answering from the
  ## support would meet the plane at a point nowhere on the circle.
  ##   Reports `[x, y, is_in_front]`, the last 0 or 1: caller should draw nothing where
  ##   it is 0, matching `picking.isInFront`'s own gate -- also 0 where slot no longer
  ##   holds a live item, the same "nothing to draw" response a caller already handles,
  ##   since every caller here (`refreshOverlay`'s hover ring, selection ring and drag
  ##   line) reads a slot carried across frames -- `nimHoverSlot`/`nimDragSourceSlot`
  ##   are not re-picked at draw time -- so any of them can go stale the moment the
  ##   item they name is removed, with no frame boundary forcing a re-check first.
  ##   A plane at horizon reports the middle of the view: it has no place in the scene at
  ##   all, being the whole sky, so the menu that follows it goes to the centre of the very
  ##   frame `marker.markerFrame` draws around it. Without this a sky could be selected and
  ##   then not acted on, the menu having nowhere to be.
  ##   **Duplicated by constraint** in `visualiser.anchorOfSelection`, which answers the
  ##   same question for the same menu on the other front-end; fix both or neither.
  if not g_scene.isAlive(int(slot)): return @[0.0'f32, 0.0'f32, 0.0'f32]
  if g_scene.geometryAt(int(slot)).isHorizonPlane:
    return @[0.5'f32*float32(width), 0.5'f32*float32(height), 1.0'f32]
  let
    (scale, vp) = extentViewOverlay(int(width), int(height))
    item = g_scene[int(slot)]
    anchor = anchorFor(item.geometry, item.anchorOverride, scale)
  if anchor.isNone: return @[0.0'f32, 0.0'f32, 0.0'f32]
  let screen = projectToScreen(vp, int(width), int(height), anchor.get)
  @[cfloat(screen.x), cfloat(screen.y), (if screen.isInFront: 1.0'f32 else: 0.0'f32)]


proc nimSelectionMarker(
  slot, width, height: cint; progress: cfloat; is_touch: bool; swell: cfloat = 0.0
): seq[float32] {.exportc.} =
  ## Shape this item's own selection/hover marker and report it flat, for the browser's
  ## SVG overlay to stroke: `[kind, first, second, third, x0, y0, x1, y1, ...]`.
  ##   `kind` is `marker.MarkerKind`'s own ordinal, and the three header slots after it
  ##   mean whatever that kind needs -- there is one header rather than five, so the
  ##   overlay reads a fixed prefix and then points, whatever it was handed:
  ##
  ##   | Kind | first | second | third | Points |
  ##   |------|-------|--------|-------|--------|
  ##   | 0 `Ring` | -- | radius | swept fraction | centre |
  ##   | 1 `Rails` | -- | -- | -- | two per drawn piece |
  ##   | 2 `Loop` | closed | -- | -- | around the plane |
  ##   | 3 `Bands` | first closed | first's count | second closed | both bands, in order |
  ##   | 4 `Frame` | closed | -- | -- | around the view |
  ##
  ##   Point count is whatever is left, so a caller reads it off the length rather than
  ##   being handed a count it could disagree with -- except `Bands`, which carries two
  ##   runs in one array and so has to say where the first ends.
  ##   `is_touch` says a finger is doing the holding and `swell` how far clear of it the
  ##   outline stands right now -- `nimSwellHold`'s answer, which runs on its own clock
  ##   rather than on the fill's; see `interaction.swellHold`. The caller knows which kind
  ##   of gesture is filling the marker and this module does not, so it is asked rather
  ##   than guessed.
  ##   `progress` draws the marker part-built for a press maturing into a selection; pass
  ##   1 for a finished one. What a partial marker looks like is `marker.markerFor`'s own
  ##   decision, not this bridge's and not the overlay's -- a ring comes back swept, rails
  ##   come back short, a loop comes back small, and the overlay strokes what it is given.
  ##   Empty where there is nothing to draw -- a dead slot, or geometry with no shape at
  ##   all. That is the same "nothing to draw" answer `nimAnchorScreen` gives, and callers
  ##   here read a slot carried across frames, so any of them can go stale the moment its
  ##   item is removed. An object at horizon is no longer among them: both shapes that draw
  ##   fixed to the eye now have a marker wrapping what is drawn.
  if not g_scene.isAlive(int(slot)): return
  let
    (scale, vp) = extentViewOverlay(int(width), int(height))
    # Shaped **with the slot's current travel**, though this call reports no pulse: the
    #   outline is identical either way -- travel only populates the pulse runs -- and
    #   shaping the whole marker once lets `nimSelectionPulse` reuse it rather than
    #   shaping the same thing again a call later. The clock is not advanced here; that
    #   stays the pulse call's own job, whether or not it finds this entry.
    travel = g_clock_pulse.travelAt(int(slot))
    shaped = markerFor(
      g_scene.geometryAt(int(slot)), g_scene.anchorOverrideAt(int(slot)), scale,
      g_camera, vp, int(width), int(height), float(progress), is_touch,
      travel = some(travel), swell = float(swell),
    )
  if shaped.isNone:
    g_shaped_marker = none(ShapedMarker)
    return

  let marker = shaped.get
  var boxed: ref Marker
  new(boxed)
  boxed[] = marker
  g_shaped_marker = some((
    int(slot), int(width), int(height), float(progress), is_touch, float(swell),
    travel, g_settings_overlay.get, boxed,
  ))
  result = @[cfloat(ord(marker.kind)), 0.0'f32, 0.0'f32, 0.0'f32]
  case marker.kind
  of MarkerKind.Ring:
    result[2] = cfloat(marker.radius)
    result[3] = cfloat(marker.fraction)
    result.add([cfloat(marker.centre.x), cfloat(marker.centre.y)])
  of MarkerKind.Rails:
    for i in 0 ..< marker.count_segment:
      for point in marker.segments[i]:
        result.add([cfloat(point.x), cfloat(point.y)])
  of MarkerKind.Loop:
    result[1] = (if marker.is_closed: 1.0'f32 else: 0.0'f32)
    for i in 0 ..< marker.count_point:
      result.add([cfloat(marker.points[i].x), cfloat(marker.points[i].y)])
  of MarkerKind.Bands:
    result[1] = (if marker.are_closed_band[0]: 1.0'f32 else: 0.0'f32)
    result[2] = cfloat(marker.counts_band[0])
    result[3] = (if marker.are_closed_band[1]: 1.0'f32 else: 0.0'f32)
    for side in 0 .. 1:
      for i in 0 ..< marker.counts_band[side]:
        result.add([
          cfloat(marker.points_band[side][i].x), cfloat(marker.points_band[side][i].y)
        ])
  of MarkerKind.Frame:
    result[1] = 1.0'f32 # Always closed: a frame is screen space, never cut by the eye.
    for i in 0 ..< marker.count_frame:
      result.add([cfloat(marker.points_frame[i].x), cfloat(marker.points_frame[i].y)])


proc nimTickPulse(now: cfloat) {.exportc.} =
  ## Take the frame's own clock reading for every orientation pulse on screen.
  ##   Called once a frame, before any `nimSelectionPulse`, so each selected object
  ##   advances by the same step; a clock ticked per call would hand the whole step to
  ##   whichever slot was asked for first and leave the rest standing still.
  g_seconds_step_pulse = g_clock_pulse.secondsStep(float(now))
  g_clock_pulse.tick(float(now))


proc nimSelectionPulse(
  slot, width, height: cint; progress: cfloat; is_touch: bool; swell: cfloat = 0.0
): seq[float32] {.exportc.} =
  ## Report the orientation pulse travelling along this item's own marker, flat, as a run
  ## count then each run's own point count followed by its points:
  ## `[runs, count0, x, y, ..., count1, x, y, ...]`. Each run is a **closed outline to
  ## fill**, not a path to stroke -- the run tapers, and a stroke has one width.
  ##   Its own call rather than a tail on `nimSelectionMarker`, whose format promises that
  ## the points are "whatever is left" -- appending a second array behind them would make
  ## that false for every kind at once. The marker is still shaped **once**: that call
  ## shapes with this slot's travel and leaves the result in `g_shaped_marker`, and this
  ## one reuses it wherever every input matches, shaping for itself only where they do
  ## not. Shaping twice was accepted as "a few dozen projections" when this split was
  ## made, and had grown into the largest overlay cost a profile showed.
  ##   Takes the same `progress` and `is_touch` the marker itself was asked for, so the
  ## pulse lies on the outline actually drawn rather than on the settled one -- a swollen
  ## marker's pulse has to swell with it.
  ##   Empty for anything with no orientation to state: a point, a plane at horizon, a
  ## dead slot, or geometry with no shape. See `marker.markerFor`.
  ##   **The clock is advanced whether or not a run came out**, which is a rule about this
  ## slot having been drawn this frame rather than about what it drew. Returning early on
  ## an empty run deadlocked a line outright: every phase starts at 0, and `samplePulse`
  ## clamps rather than wraps on an *open* outline, so a rail at phase 0 yields nothing --
  ## which then skipped the advance, which left the phase at 0, for ever. A plane's loop is
  ## closed, wraps at 0, and so never entered the deadlock; that is the whole reason planes
  ## pulsed and lines did not. Mirrors `visualiser.drawSelectionMarker`, which advances
  ## right after shaping and was never affected.
  if not g_scene.isAlive(int(slot)): return
  let
    (scale, vp) = extentViewOverlay(int(width), int(height))
    travel = g_clock_pulse.travelAt(int(slot))
  var held = (ref Marker)(nil)
  if g_shaped_marker.isSome:
    let stored = g_shaped_marker.get
    if stored.slot == int(slot) and stored.width == int(width) and
        stored.height == int(height) and stored.progress == float(progress) and
        stored.is_touch == is_touch and stored.swell == float(swell) and
        stored.travel == travel and stored.settings == g_settings_overlay.get:
      held = stored.marker
  if held == nil:
    let shaped = markerFor(
      g_scene.geometryAt(int(slot)), g_scene.anchorOverrideAt(int(slot)), scale,
      g_camera, vp, int(width), int(height), float(progress), is_touch,
      travel = some(travel), swell = float(swell),
    )
    if shaped.isNone: return
    new(held)
    held[] = shaped.get

  template marker: Marker = held[]
  # Carried against the length this marker actually came out at, so orbiting changes how
  #   fast the comet travels and never where it is. See `selection.PulseClock`.
  g_clock_pulse.advance(int(slot), marker.lap, g_seconds_step_pulse)
  if marker.count_run_pulse == 0: return
  result = @[cfloat(marker.count_run_pulse)]
  for run in 0 ..< marker.count_run_pulse:
    result.add(cfloat(marker.counts_pulse[run]))
    for i in 0 ..< marker.counts_pulse[run]:
      result.add([cfloat(marker.pulses[run][i].x), cfloat(marker.pulses[run][i].y)])



#[ Scene Save/Load Primitives ]#

proc nimSceneMagic(): cstring {.exportc.} = cstring(MAGIC_SCENE)
  ## Report the four bytes a `.rgascene` file opens with, for the packer in `glue.js`.


proc nimSceneVersion(): cint {.exportc.} = cint(VERSION_SCENE)
  ## Report the format version this build writes, for that same packer.
  ##   Exported rather than written out again in JavaScript because it *was* written out
  ##   again in JavaScript: the literal `1` there survived this constant's bump to 2, so
  ##   the browser stamped version 1 onto version 2 content and rejected every file the
  ##   desktop wrote. See `scene.MAGIC_SCENE`'s own note. The rule this restores is the
  ##   project's own -- when one language compiles to another, a derived value belongs
  ##   behind an export, not in a literal the other language keeps its own copy of.


proc nimSceneReadsVersion(version: cint): bool {.exportc.} =
  ## Report whether this build can read a scene file stamped with this version.
  ##   A rule rather than a number, for the same reason the number above is an export:
  ##   what a build reads is now a *range*, and a range written out in JavaScript is two
  ##   literals to drift instead of one.
  version >= 0 and version <= int(high(uint8)) and readsSceneVersion(uint8(version))


proc nimSceneClear() {.exportc.} =
  ## Discard the live scene and start a fresh empty one.
  g_scene = initScene()
  g_selection.clear()
  g_history = initHistory(g_scene, g_camera)


proc nimSceneAddRaw(
  version: cint; ink_ordinal: cint; is_visible: bool; label: cstring;
  coefficients: seq[float]; count_total: cint; now: cfloat
): cint {.exportc.} =
  ## Add one item straight from parsed `.rgascene` fields, for the load path: the hand-
  ## written presentation layer parses the uploaded file's bytes into exactly these
  ## fields (see this module's own doc comment for why packing/parsing itself lives in
  ## JS, not here) and calls this once per item, in file order.
  ##   `version` is the file's own, and the item is carried up from it to this build's
  ## shape by `scene.itemUpgraded` -- the same chain the desktop's `loadScene` walks, so
  ## neither build has a reading of an old version that the other lacks. `SLOT_NONE` where
  ## no version could have written the item, which is a corrupt or foreign file and the
  ## caller's cue to say so.
  ##   `count_total` is the file's whole item count and `now` this frame's clock, so the
  ## arrival is staggered by `scene.bornReplaying` -- the same rule the desktop's own
  ## `loadScene` stamps with, so a scene replays its construction identically on both.
  var geometry: Multivector
  for b in Basis: geometry[b] = coefficients[ord(b)]
  let carried = itemUpgraded(
    ItemSaved(
      ink_ordinal: int(ink_ordinal), is_visible: is_visible, label: $label,
      geometry: geometry,
    ),
    uint8(version),
  )
  if carried.isNone: return SLOT_NONE
  # The scene was cleared before the first of these, so how many it already holds is this
  #   item's own position in the file -- no index to pass in and none to get out of step.
  let born = bornReplaying(g_scene.len, int(count_total), float(now))
  let slot = g_scene.addItem(
    carried.get.geometry, carried.get.label, Ink(carried.get.ink_ordinal), born
  )
  g_scene.setVisible(slot, carried.get.is_visible)
  # Stamped rather than left alone: the slot could otherwise still hold a stale reading
  #   from whatever occupied it earlier this session, misranking a just-loaded item.
  g_borns[slot] = born
  cint(slot)



#[ Frame Assembly ]#

type FrameData = object
  ## Hold one frame's worth of vertex data plus the transform it is drawn through --
  ## everything a caller needs to issue this frame's `gl.drawArrays` calls.
  tri_verts, ribbon_verts, point_verts: seq[float32]
  view_projection: seq[float32]
  furn_ribbon_verts: seq[float32] ## Ground grid and world axes alone -- drawn first, and
    ## already built at their own thinner width (see `mesh.WIDTH_LINE_FURNITURE`), since a
    ## ribbon carries its width as geometry rather than as a draw-call setting.
    ## **Empty where `is_furniture_held` is set**, which is not "no furniture" but "the
    ## furniture you already have"; see that field.
  is_furniture_held: bool ## Whether the furniture above is unchanged from the last frame,
    ## so a caller should keep the buffer it already uploaded rather than read an empty
    ## `furn_ribbon_verts` as an empty world.
    ##   The ground grid and the world axes are a function of the camera alone, and the
    ## camera is still for most of the frames of an ordinary session -- between drags,
    ## while reading, while typing a coefficient. Measured on the opening scene, one
    ## `nimBuildFrame` call: **21.9 ms with the furniture and 6.9 ms without it**, so
    ## rebuilding a grid nothing moved is two thirds of the frame spent redrawing the same
    ## picture. A JS-backend concern and stated as one: the desktop's own furniture
    ## assembly is native and pays a fraction of this, and is left alone.
  ms_build, ms_furniture, ms_scene, ms_flatten: float32
    ## What this frame's own assembly cost, in milliseconds: the whole of `nimBuildFrame`,
    ## and its three phases -- the world furniture (ground grid and axes), the scene's own
    ## objects (ghost and drag preview included), and the flatten-and-pack of every mesh
    ## into the arrays above. Read by the diagnostics tab, which shows each step of the
    ## drawing process rather than one opaque frame time; the phases the bridge cannot
    ## see -- GL upload, the SVG overlay -- are timed by `glue.js` around its own calls.
    ## A held furniture frame reports ~0 for its furniture phase, which is the point.
  tri_over, ribbon_over, point_over: int ## How many vertices at the *end* of each of the
    ## three above are the overlay run -- drawn after the rest with the depth test off, so
    ## a selected object lands over whatever stands between it and the camera. A count of
    ## the tail rather than the index it starts at, so the glue subtracts nothing: see
    ## `mesh.Mesh.index_overlay`, which is the same split stated from the other end, and
    ## `renderer.drawPrimitive`, which is the desktop's own two-call draw.


proc nimBuildFrame(
  aspect, now: cfloat; height_pixels: cint; is_axes_shown, is_grid_shown: bool
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
  # One clock per phase boundary, so the diagnostics tab can show each step of the
  #   drawing process rather than one opaque build figure. `performanceNow` is timing-only.
  let ms_entered = performanceNow()
  # A focus is a slot carried across frames like any other, so it needs the same liveness
  #   guard the selection keeps; mirrors `visualiser.renderFrame`.
  g_interaction.pruneFocus(g_scene)

  # Carry the camera one frame further toward whatever is being worked on, then aim it
  #   again from what this frame holds -- the same one rule `visualiser.assembleMeshes`
  #   applies, so neither UI decides for itself when the camera should move. Advancing
  #   before `scale` is read keeps this frame's furniture extent and horizon radius
  #   consistent with where the camera actually is.
  g_tween_camera.advance(g_camera, float(now), easeOutCubic)
  # The framebuffer's own height, not the window's: a ribbon's width is measured in the
  #   pixels actually drawn, and this build renders at a device-pixel-ratio multiple.
  let scale = g_camera.drawExtentFor(int(height_pixels))
  # The width the centred box is measured across comes back from the aspect, since this
  #   build is handed that rather than the framebuffer's own two dimensions.
  g_tween_camera.offerAim(
    g_camera, g_scene, g_selection, staged(), int(float(aspect)*float(height_pixels)),
    int(height_pixels), float(now), ANIMATION_SECONDS,
  )

  # Everything `drawExtentFor` reads, and the two toggles: the furniture is a function of
  #   exactly these, so a frame whose settings match the last one is drawing the very same
  #   vertices and may keep them. Compared exactly rather than approximately -- the
  #   question is "did anything move at all", not "did it move enough to see".
  let settings_furniture = (
    g_camera.target.x, g_camera.target.y, g_camera.target.z, g_camera.distance,
    g_camera.azimuth, g_camera.elevation, g_camera.degrees_field_of_view,
    int(height_pixels), is_axes_shown, is_grid_shown,
  )
  let is_furniture_held =
    g_settings_furniture.isSome and g_settings_furniture.get == settings_furniture
  let ms_before_furniture = performanceNow()
  if not is_furniture_held:
    g_settings_furniture = some(settings_furniture)
    clearMeshes(g_meshes_furniture)
    if is_grid_shown: addGrid(g_meshes_furniture, scale.extent_furniture, scale)
    if is_axes_shown: addAxes(g_meshes_furniture, scale.extent_furniture, scale)
  let ms_after_furniture = performanceNow()

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
    if not g_scene.isAlive(slot) or slot in g_selection: continue
    if g_scene.isVisible(slot):
      let geometry = g_scene.geometryAt(slot)
      if isHorizonPlane(geometry):
        let progress = animationProgress(float(now), g_borns[slot])
        discard g_meshes.addObject(
          geometry, g_scene.inkAt(slot).colour, scale, progress, g_scene.anchorOverrideAt(slot)
        )

  for slot in 0 ..< ITEMS_MAX:
    if not g_scene.isAlive(slot) or slot in g_selection: continue
    if g_scene.isVisible(slot):
      let geometry = g_scene.geometryAt(slot)
      if not isHorizonPlane(geometry):
        let progress = animationProgress(float(now), g_borns[slot])
        discard g_meshes.addObject(
          geometry, g_scene.inkAt(slot).colour, scale, progress, g_scene.anchorOverrideAt(slot)
        )

  # An open session's staged geometry, or an apply control's own preview where none is --
  #   one ghost for both, since they are the same "not committed yet" claim about one
  #   object; `staged` is where that order is decided. Centred on the anchor the commit
  #   will store, so a previewed plane stays where it was ghosted.
  let ghost = staged()
  if ghost.isSome:
    discard g_meshes.addObject(
      ghost.get.geometry, INK_GHOST.colour.muted(), scale,
      anchor_override = ghost.get.anchor,
    )

  # What the drag in progress would build, in that same ghost ink, so a reader learns one
  #   "this is not committed yet" appearance rather than two. Mirrors
  #   `visualiser.assembleMeshes`.
  # Centred on the anchor the commit itself will store, so a ghosted plane stays where it
  #   was ghosted instead of jumping the instant the release lands.
  if g_interaction.preview.isSome:
    discard g_meshes.addObject(
      g_interaction.preview.get.geometry, INK_GHOST.colour.muted(), scale,
      anchor_override = g_interaction.preview.get.anchor,
    )

  # Everything selected, held back to here and drawn with the depth test off, so a picked
  #   object is never buried by whatever stands between it and the camera. Mirrors
  #   `visualiser.assembleMeshes`, which carries the reasoning.
  markOverlay(g_meshes)
  for position in 0 ..< g_selection.len:
    let slot = g_selection.at(position)
    if not g_scene.isAlive(slot) or not g_scene.isVisible(slot): continue
    let progress = animationProgress(float(now), g_borns[slot])
    discard g_meshes.addObject(
      g_scene.geometryAt(slot), g_scene.inkAt(slot).colour, scale, progress,
      g_scene.anchorOverrideAt(slot),
    )

  let vp = g_camera.initMatrixViewProjection(float(aspect))
  var view_projection = newSeq[float32](16)
  for row in 0 .. 3:
    for column in 0 .. 3:
      view_projection[4*column + row] = vp.at(row, column)

  # Flattened into locals rather than in the constructor, so the pack-and-copy phase has
  #   a start and an end a clock can bracket.
  let ms_before_flatten = performanceNow()
  let
    tri_verts = flatten(g_meshes[Primitive.Triangle])
    ribbon_verts = flatten(g_meshes[Primitive.Ribbon])
    point_verts = flatten(g_meshes[Primitive.Point])
    furn_ribbon_verts =
      if is_furniture_held: newSeq[float32](0)
      else: flatten(g_meshes_furniture[Primitive.Ribbon])
  let ms_done = performanceNow()

  FrameData(
    tri_verts: tri_verts,
    ribbon_verts: ribbon_verts,
    point_verts: point_verts,
    view_projection: view_projection,
    furn_ribbon_verts: furn_ribbon_verts,
    is_furniture_held: is_furniture_held,
    ms_build: float32(ms_done - ms_entered),
    ms_furniture: float32(ms_after_furniture - ms_before_furniture),
    # The scene phase is everything between the furniture and the flatten: clearing,
    #   both draw-order passes, the ghost and the drag preview, and the overlay marking.
    ms_scene: float32(ms_before_flatten - ms_after_furniture),
    ms_flatten: float32(ms_done - ms_before_flatten),
    tri_over: countOverlay(g_meshes[Primitive.Triangle]),
    ribbon_over: countOverlay(g_meshes[Primitive.Ribbon]),
    point_over: countOverlay(g_meshes[Primitive.Point]),
  )
