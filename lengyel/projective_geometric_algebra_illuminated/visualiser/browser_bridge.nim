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
##   `scene.formatMultivector`/`scene.describeShape`+`toCstring` and every desktop-only
##   diagnostic (the arena bump-allocators, `arena.nim`'s own accounting, the SDL/OpenGL
##   frame loop's own timing) either depend on a C FFI (`format.nim`'s `snprintf` binding)
##   that does not exist in a browser, or describe implementation details specific to the
##   native build's own allocator and draw loop with no browser/JS-GC equivalent worth
##   fabricating. Numeric formatting for anything shown here happens in hand-written JS
##   instead (which has better native tools for it than reimplementing C's `%#.4g` would
##   give); a browser-appropriate diagnostics substitute (frame time via
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

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./[camera, interaction, mesh, objects, picking, scene, storyboard]



#[ Workbench State ]#

var
  g_scene: Scene
  g_camera: Camera
  g_meshes_furniture, g_meshes, g_meshes_outline: MeshSet ## Held at module scope and
    ## reused every frame via `clearMeshes` (which only resets each mesh's own
    ## `count_vertices`, not its backing storage) -- mirrors `visualiser.nim`'s own
    ## module-level `MESHES`/`MESHES_FURNITURE`/`MESHES_OUTLINE`. Declaring these as
    ## `nimBuildFrame`'s own locals instead, freshly on every call, was measured costing
    ## ~90ms/frame *regardless of how many objects the scene actually held* -- a `MeshSet`
    ## reserves `VERTICES_MAX` (16384) vertices per primitive up front, and the JS
    ## backend has no true stack allocation the way re-declaring a fixed-size array
    ## inside a proc gets on the C backend: each call was reallocating and zero-filling
    ## three ~1.3MB `MeshSet`s from scratch, whether the scene held nine objects or
    ## sixty-four. Fixed the same way the desktop build already avoids this: allocate
    ## once, clear (not reallocate) every frame.
  g_interaction = Interaction(is_enabled: true) ## Picking and drag are always live here --
    ## there is no storyboard-capture mode to switch them off for, unlike the desktop
    ## build's own `runStoryboard`.
  g_borns: array[ITEMS_MAX, float] ## Stamped once per slot, the moment an item is added
    ## (by point, by operation, or by drag) -- read back by `nimBuildFrame` so it animates
    ## in exactly as the desktop build's own newly-added item does.
  g_index_highlighted = none(int) ## Slot most recently constructed, ringed as if freshly
    ## selected; none where nothing has been built yet this session.


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


proc shapeDescription(m: Multivector): string =
  ## Name what shape `m` stands for, or that it stands for none at all. Built by hand
  ## rather than through `scene.describeShape`+`toCstring`: that pattern's fixed-buffer,
  ## `unsafeAddr`-based design does not carry over correctly to the JS backend (the same
  ## kind of gap `scene.Item`'s own doc comment already flags for a value parameter's
  ## address), and a plain string costs nothing extra here, called only on a user action,
  ## not once a frame.
  let s = shape(m)
  if s.isNone: return "mixed grade, nothing to draw"
  case s.get
  of Shape.Point: (if isHorizon(m): "point at horizon" else: "point")
  of Shape.Line: (if isHorizon(m): "line at horizon" else: "line")
  of Shape.Plane: (if isHorizon(m): "plane at horizon" else: "plane")


proc labelString(label: Label): string =
  ## Read a fixed-char label buffer into a plain Nim string, byte by byte until the first
  ## `\0` -- avoids `toCstring`'s `unsafeAddr` pattern (see `shapeDescription`'s own doc
  ## comment for why that does not carry over to the JS backend).
  for ch in label:
    if ch == '\0': break
    result.add(ch)



#[ Setup ]#

proc placeSeedsAndFirstSteps(now: float) =
  ## Build the same default scene the desktop app itself opens on when no saved scene is
  ## given: four seeds, then the storyboard's own first four steps applied through the
  ## real `applyOperation` catalogue -- see `visualiser.main`'s own startup, which this
  ## mirrors exactly rather than approximates.
  g_scene = initScene()
  constructSeeds(g_scene, now)
  for step in STEPS[0 .. 3]:
    applyStep(g_scene, step, now)
  for slot in 0 ..< ITEMS_MAX: g_borns[slot] = now


proc nimInit(now: cfloat) {.exportc.} =
  ## Build the default interactive scene and place the camera at the same default orbit
  ## the desktop app itself opens on.
  placeSeedsAndFirstSteps(float(now))
  g_camera = initCamera(
    target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05, elevation = 0.42
  )
  g_index_highlighted = none(int)


proc nimLoadDemo(now: cfloat) {.exportc.} =
  ## Replace the current scene with the full eleven-step storyboard construction, as
  ## ordinary live items -- a one-click preset rather than a scripted playback mode: once
  ## loaded, every one of its objects is exactly as editable, removable and pickable as
  ## anything built by hand.
  g_scene = initScene()
  constructSeeds(g_scene, float(now))
  for step in STEPS: applyStep(g_scene, step, float(now))
  for slot in 0 ..< ITEMS_MAX: g_borns[slot] = float(now)
  g_index_highlighted = none(int)



#[ Scene Inspection ]#

proc nimSceneCount(): cint {.exportc.} = cint(g_scene.len)


proc nimSceneCapacity(): cint {.exportc.} = cint(ITEMS_MAX)


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


proc nimItemLabel(slot: cint): cstring {.exportc.} =
  cstring(labelString(g_scene.labelAt(int(slot))))


proc nimItemInk(slot: cint): cint {.exportc.} = cint(g_scene.inkAt(int(slot)))


proc nimItemVisible(slot: cint): bool {.exportc.} = g_scene.isVisible(int(slot))


proc nimItemShapeWord(slot: cint): cstring {.exportc.} =
  cstring(shapeDescription(g_scene.geometryAt(int(slot))))


proc nimItemCoefficients(slot: cint): seq[float] {.exportc.} =
  ## Report all sixteen basis coefficients of an item's own multivector, in the library's
  ## own `Basis` order -- the same order `scene.saveScene`/`loadScene` read and write, and
  ## the same order `panel.layoutCoefficients` lays its sixteen drag widgets out in.
  let geometry = g_scene.geometryAt(int(slot))
  result = newSeq[float](ord(Basis.high) + 1)
  for b in Basis: result[ord(b)] = geometry[b]



#[ Scene Mutation ]#

proc nimAddPoint(x, y, z, now: cfloat): cint {.exportc.} =
  ## Add a fresh point at a position, exactly as `panel.layoutPointNew`'s own button does.
  let place = Position(x: float(x), y: float(y), z: float(z))
  result = cint(
    g_scene.addItem(toMultivector(place), &"p{g_scene.len}", inkCycled(g_scene.len), float(now))
  )
  g_index_highlighted = some(int(result))


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
    is_binary = lut_operation_to_arity[operation] == Arity.Two
    operand_first = g_scene.geometryAt(int(slot_first))
    operand_second = g_scene.geometryAt(int(slot_second))
    derived = applyOperation(operation, operand_first, operand_second)
    anchor = creationAnchor(operation, operand_first, operand_second, derived)
    name_first = labelString(g_scene.labelAt(int(slot_first)))
    name_second = labelString(g_scene.labelAt(int(slot_second)))
    label =
      if is_binary: &"{name_first} {$operation} {name_second}"
      else: &"{$operation} {name_first}"
    slot_created =
      g_scene.addItem(derived, label, inkCycled(g_scene.len), float(now), anchor)
  g_borns[slot_created] = float(now)
  g_index_highlighted = some(slot_created)
  let shape_word = shapeDescription(derived)
  OperationResult(
    created_slot: cint(slot_created),
    message: cstring(&"{$operation} gave {shape_word}."),
    shape_word: cstring(shape_word),
  )


proc nimSetVisible(slot: cint; is_visible: bool) {.exportc.} =
  g_scene.setVisible(int(slot), is_visible)


proc nimSetLabel(slot: cint; text: cstring) {.exportc.} =
  toChars($text, g_scene.labelAt(int(slot)))


proc nimSetInk(slot: cint; ink_ordinal: cint) {.exportc.} =
  g_scene.setInk(int(slot), Ink(ink_ordinal))


proc nimSetCoefficient(slot, basis_index: cint; value: cfloat) {.exportc.} =
  g_scene.geometryAt(int(slot))[Basis(basis_index)] = float(value)


proc nimRemoveItem(slot: cint) {.exportc.} =
  g_scene.removeItem(int(slot))
  if g_index_highlighted == some(int(slot)): g_index_highlighted = none(int)



#[ Catalogue Metadata ]#

proc nimOperationCount(): cint {.exportc.} = cint(COUNT_OPERATION)


proc nimOperationNotation(index: cint): cstring {.exportc.} =
  lut_operation_to_notation[Operation(index)]


proc nimOperationArity(index: cint): cint {.exportc.} =
  ## Report 0 for an operation that reads one operand, 1 for one that reads two --
  ## matching `panel.layoutOperation`'s own disabling of the second operand picker.
  cint(lut_operation_to_arity[Operation(index)])


proc nimBasisCount(): cint {.exportc.} = cint(ord(Basis.high) + 1)


proc nimBasisName(index: cint): cstring {.exportc.} = cstring(lut_basis_to_name[Basis(index)])


proc nimInkCount(): cint {.exportc.} = cint(COUNT_INK)


proc nimInkName(index: cint): cstring {.exportc.} = lut_ink_to_name[Ink(index)]


proc nimInkColor(index: cint): seq[float32] {.exportc.} = toRgbSeq(Ink(index).colour)


proc nimBackdropColor(): seq[float32] {.exportc.} = toRgbSeq(Ink.Backdrop.colour)



#[ Camera ]#

proc nimCameraOrbit(turn, rise: cfloat) {.exportc.} =
  camera.orbit(g_camera, float(turn), float(rise))


proc nimCameraDolly(factor: cfloat) {.exportc.} =
  camera.dolly(g_camera, float(factor))


proc nimCameraPan(across, up: cfloat) {.exportc.} =
  camera.pan(g_camera, float(across), float(up))


proc nimCameraAzimuth(): cfloat {.exportc.} = cfloat(g_camera.azimuth)
proc nimCameraElevation(): cfloat {.exportc.} = cfloat(g_camera.elevation)
proc nimCameraDistance(): cfloat {.exportc.} = cfloat(g_camera.distance)
proc nimCameraFov(): cfloat {.exportc.} = cfloat(g_camera.degrees_field_of_view)
proc nimCameraTarget(): seq[float32] {.exportc.} =
  @[cfloat(g_camera.target.x), cfloat(g_camera.target.y), cfloat(g_camera.target.z)]


proc nimSetCameraAzimuth(v: cfloat) {.exportc.} = g_camera.azimuth = float(v)


proc nimSetCameraElevation(v: cfloat) {.exportc.} =
  g_camera.elevation = clamp(float(v), -ELEVATION_LIMIT, ELEVATION_LIMIT)


proc nimSetCameraDistance(v: cfloat) {.exportc.} =
  g_camera.distance = clamp(float(v), DISTANCE_LIMIT_NEAR, DISTANCE_LIMIT_FAR)


proc nimSetCameraFov(v: cfloat) {.exportc.} = g_camera.degrees_field_of_view = float(v)


proc nimSetCameraTarget(x, y, z: cfloat) {.exportc.} =
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
  ## `shapeDescription`'s own doc comment for the precedent: the boundary is where a
  ## JS-incompatible representation gets translated, not a reason to use it upstream --
  ## everything on this side of that translation stays `Option[int]`.


func drawExtentFor(cam: Camera): DrawExtent =
  DrawExtent(
    extent_furniture: extentFurnitureFor(cam.distance_far),
    eye: cam.eye,
    radius_horizon: radiusHorizonFor(cam.distance_far),
  )


proc nimUpdateCursor(x, y: cfloat) {.exportc.} =
  interaction.updateCursor(g_interaction, float(x), float(y))


proc nimUpdateHover(width, height: cint) {.exportc.} =
  let vp = g_camera.initMatrixViewProjection(float(width) / float(height))
  interaction.updateHover(g_interaction, g_scene, g_camera, vp, int(width), int(height))


proc nimHoverSlot(): cint {.exportc.} =
  if g_interaction.index_hover.isSome: cint(g_interaction.index_hover.get) else: SLOT_NONE


proc nimBeginDrag(drag_ordinal: cint): bool {.exportc.} =
  interaction.beginDrag(g_interaction, DragOperation(drag_ordinal))


proc nimCancelDrag() {.exportc.} =
  interaction.cancelDrag(g_interaction)


proc nimDragActive(): bool {.exportc.} = g_interaction.operation.isSome


proc nimDragOperation(): cint {.exportc.} =
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
  DragOperation.Meet: Ink.Magenta,
  DragOperation.Project: Ink.Olive,
] ## Mirror `visualiser.lut_drag_to_ink` exactly, so the browser's own rubber-band and
  ## tap-then-pick menu tint each operation the same colour the desktop build's own
  ## panel legend and drag overlay do -- duplicated rather than imported, since that
  ## table lives in `visualiser.nim` itself, which does not compile under `nim js`.


proc nimDragTint(drag_ordinal: cint): seq[float32] {.exportc.} =
  toRgbSeq(lut_drag_to_ink[DragOperation(drag_ordinal)].colour)


type DragResult = object ## Report what ending a drag produced.
  created_slot: cint ## `SLOT_NONE` where nothing was added (released over empty space,
    ## or on the drag's own source).
  message: cstring ## Outcome, for display exactly as the desktop panel's own status line.


proc nimEndDrag(now: cfloat): DragResult {.exportc.} =
  ## End the drag in progress, applying its operation between source and hovered item.
  ##   Calls straight into `interaction.endDrag` for the mutation itself -- the same
  ##   catalogue call, anchor resolution and slot bookkeeping the desktop build's own
  ##   mouse-release handler runs -- but re-labels the created item and rebuilds the
  ##   outcome message by hand afterward: `endDrag` builds both its own returned message
  ##   AND the label it stores on the new item through `scene.labelAt`+`$toCstring`,
  ##   which -- confirmed empirically, not just suspected -- comes out empty under the
  ##   JS backend (the same gap `shapeDescription`'s own doc comment flags), so without
  ##   this fix-up every object built by dragging would carry a blank label forever, not
  ##   just show a blank status line once.
  let drag = g_interaction.operation
  # Read both operands' labels *before* `endDrag` runs: it clears `operation` (though
  #   not `index_hover`) once done, and the source/destination slots themselves may no
  #   longer hold what a caller expects once the new item lands in one of them (a freed
  #   slot is reused by the very next `addItem`, which this call itself may be).
  let
    label_source = labelString(g_scene.labelAt(g_interaction.index_source))
    label_destination =
      if g_interaction.index_hover.isSome:
        labelString(g_scene.labelAt(g_interaction.index_hover.get))
      else: ""
    notation_text = if drag.isSome: interaction.notation(drag.get) else: "?"
    outcome = interaction.endDrag(g_interaction, g_scene, float(now))
  if outcome.index_created.isSome:
    let slot = outcome.index_created.get
    g_borns[slot] = float(now)
    g_index_highlighted = some(slot)
    let
      label_fixed = &"{label_source} {notation_text} {label_destination}"
      shape_word = shapeDescription(g_scene.geometryAt(slot))
    toChars(label_fixed, g_scene.labelAt(slot))
    return DragResult(
      created_slot: cint(slot),
      message: cstring(&"{label_fixed} gave {shape_word}."),
    )
  DragResult(
    created_slot: SLOT_NONE,
    message: cstring("Drag released on empty space or its own source; nothing done."),
  )


proc nimAnchorScreen(slot, width, height: cint): seq[float32] {.exportc.} =
  ## Project the same representative point `picking.anchorFor` and
  ## `visualiser.drawInteractionOverlay` use for this item onto screen pixels, so the
  ## browser's own hover ring and drag rubber-band can be drawn as plain 2D overlay,
  ## exactly matching where the desktop build draws them.
  ##   Reports `[x, y, is_in_front]`, the last 0 or 1: caller should draw nothing where
  ##   it is 0, matching `picking.isInFront`'s own gate.
  let
    scale = drawExtentFor(g_camera)
    anchor = anchorFor(g_scene.geometryAt(int(slot)), scale)
  if anchor.isNone: return @[0.0'f32, 0.0'f32, 0.0'f32]
  let vp = g_camera.initMatrixViewProjection(float(width) / float(height))
  let screen = projectToScreen(vp, int(width), int(height), anchor.get)
  @[cfloat(screen.x), cfloat(screen.y), (if screen.isInFront: 1.0'f32 else: 0.0'f32)]



#[ Scene Save/Load Primitives ]#

proc nimSceneClear() {.exportc.} =
  g_scene = initScene()
  g_index_highlighted = none(int)


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
  cint(slot)



#[ Frame Assembly ]#

type FrameData = object
  ## Hold one frame's worth of vertex data plus the transform it is drawn through --
  ## everything a caller needs to issue this frame's `gl.drawArrays` calls.
  tri_verts, line_verts, point_verts: seq[float32]
  view_projection: seq[float32]
  furn_line_verts: seq[float32] ## Ground grid and world axes alone -- drawn first, at
    ## their own thinner line width (see `renderer.WIDTH_LINE_FURNITURE`), and before
    ## the outline pass below so neither ever paints back over a selection border.
  ol_tri_verts, ol_line_verts, ol_point_verts: seq[float32] ## Highlighted item's own
    ## result, built oversized and in a flat outline colour, for the outline pass --
    ## drawn between furniture and the main frame above, so only what peeks out past
    ## that object's own true-size redraw over it shows, reading as a selection
    ## border; empty wherever nothing is currently highlighted.


proc nimBuildFrame(
  aspect, now: cfloat; is_axes_shown, is_grid_shown: bool
): FrameData {.exportc.} =
  ## Tessellate every visible object in the live scene, at the camera's current
  ## placement, through the same `mesh.addObject` dispatch and `camera` transforms the
  ## desktop app draws through -- every item always at full colour, exactly as the
  ## desktop build's own interactive `assembleMeshes` call (`are_dimmed` all false)
  ## draws outside of a storyboard capture.
  clearMeshes(g_meshes_furniture)

  let scale = drawExtentFor(g_camera)

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
  #   the existing `geometryAt`/`isVisibleAt` pattern) and reading every field here by
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

  # Build the highlighted item's own result a second time, oversized and in a flat
  #   outline colour, into its own buffer the outline pass draws before the frame above --
  #   see `renderer.drawOutline`'s own doc comment for why this reads as a selection border.
  clearMeshes(g_meshes_outline)
  if g_index_highlighted.isSome:
    let highlighted = g_index_highlighted.get
    if g_scene.isAlive(highlighted) and g_scene.isVisible(highlighted):
      discard g_meshes_outline.addObject(
        g_scene.geometryAt(highlighted), Ink.Outline.colour, scale,
        animationProgress(float(now), g_borns[highlighted]),
        g_scene.anchorOverrideAt(highlighted), is_outline = true,
      )

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
    ol_tri_verts: flatten(g_meshes_outline[Primitive.Triangle]),
    ol_line_verts: flatten(g_meshes_outline[Primitive.Line]),
    ol_point_verts: flatten(g_meshes_outline[Primitive.Point]),
  )
