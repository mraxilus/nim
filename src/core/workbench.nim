## Hold the whole tool's state, and every action either front-end can take on it.
##
## Both front-ends call in here for everything that derives a value from domain data: what a
## drag builds, what a result is called, where the camera should look, what the meshes hold.
## Neither front-end decides any of it; each one draws what this module reports and turns its
## own events into these calls.

{.experimental: "strictFuncs".}

import std/options

import ./[
  algebra, anchoring, camera, catalogue, config, history, interaction, mesh, palette,
  picking, scene, selection, session,
]

export algebra, camera, catalogue, config, history, interaction, mesh, palette, picking,
  scene, selection, session



#[ Type Definitions ]#

type Workbench* = object
  ## Hold everything the tool knows.
  scene*: Scene
  history*: History
  selection*: Selection
  camera*: Camera
  tween*: Tween
  session*: Option[Session]
  hovered*: Option[Slot]
  is_showing_axes*: bool
  is_showing_grid*: bool
  now_ms*: float



#[ Construction ]#

func initWorkbench*(): Workbench =
  ## Build a tool with an empty scene, a seeded timeline and the default view.
  result.scene = initScene()
  result.history = initHistory(result.scene)
  result.camera = defaultCamera()
  result.is_showing_axes = true
  result.is_showing_grid = true


func reset*(workbench: var Workbench, scene: Scene) =
  ## Replace the scene wholesale, reseeding the timeline and dropping every held slot.
  workbench.scene = scene
  workbench.history = initHistory(scene)
  workbench.selection.clear()
  workbench.session = none(Session)
  workbench.hovered = none(Slot)
  workbench.tween.release()



#[ Scene Actions ]#

func addObject*(
  workbench: var Workbench,
  geometry: Multivector,
  label: Label,
  anchor: Option[Position] = none(Position),
  paint: Option[Paint] = none(Paint),
): Option[Slot] =
  ## Add an object, select it alone and record the edit.
  let slot = workbench.scene.add(
    geometry = geometry,
    label = label,
    born_ms = workbench.now_ms,
    anchor = anchor,
    paint = paint,
  )
  if slot.isNone: return
  workbench.selection.replaceWith(slot.get)
  workbench.history.record(workbench.scene)
  slot


func applyOperation*(
  workbench: var Workbench, operation: Operation, first, second: Slot
): Option[Slot] =
  ## Apply an operation to two slots, naming and anchoring the result from what built it.
  ##   A unary operation reads the first slot alone; the second is ignored but still checked,
  ##   so a dead slot can never reach the algebra.
  if not workbench.scene.isLive(first): return
  let is_binary = operation.arity == Arity.Binary
  if is_binary and not workbench.scene.isLive(second): return
  let
    m = workbench.scene.geometry(first)
    n = if is_binary: workbench.scene.geometry(second) else: Multivector()
    derived = operation.apply(m, n)
    name_first = $workbench.scene.label(first)
    name_second = if is_binary: $workbench.scene.label(second) else: ""
    label = initLabel(operation.derivedLabel(name_first, name_second))
    anchor = creationAnchor(operation, m, n, derived)
  workbench.addObject(derived, label, anchor)


func applyDrag*(
  workbench: var Workbench, button: PointerButton, source, destination: Slot
): Option[Slot] =
  ## Derive an object from a drag of one object onto another.
  ##   Both slots are checked before either label is read: a drag spans frames, and either
  ##   end may have been removed while it was in flight.
  if not workbench.scene.isLive(source): return
  if not workbench.scene.isLive(destination): return
  workbench.applyOperation(operationFor(button), source, destination)


func removeSlot*(workbench: var Workbench, slot: Slot) =
  ## Remove an object, clearing every held reference to its slot.
  if not workbench.scene.isLive(slot): return
  workbench.scene.remove(slot)
  workbench.selection.prune(workbench.scene)
  if workbench.hovered.isSome and workbench.hovered.get == slot:
    workbench.hovered = none(Slot)
  workbench.history.record(workbench.scene)


func removeSelected*(workbench: var Workbench) =
  ## Remove every picked object.
  var doomed: array[SELECTION_CAPACITY, Slot]
  var count = 0
  for slot in workbench.selection:
    doomed[count] = slot
    count += 1
  for i in 0 ..< count:
    workbench.scene.remove(doomed[i])
  workbench.selection.prune(workbench.scene)
  workbench.hovered = none(Slot)
  workbench.history.record(workbench.scene)


func setVisibility*(workbench: var Workbench, slot: Slot, is_visible: bool) =
  ## Show or hide an object.
  if not workbench.scene.isLive(slot): return
  workbench.scene.setVisible(slot, is_visible)
  workbench.history.record(workbench.scene)


func setSelectionVisibility*(workbench: var Workbench, is_visible: bool) =
  ## Show or hide every picked object at once.
  for slot in workbench.selection:
    if workbench.scene.isLive(slot): workbench.scene.setVisible(slot, is_visible)
  workbench.history.record(workbench.scene)


func setPaint*(workbench: var Workbench, slot: Slot, paint: Paint) =
  ## Recolour an object.
  if not workbench.scene.isLive(slot): return
  if not paint.isAssignable: return
  workbench.scene.setPaint(slot, paint)
  workbench.history.record(workbench.scene)



#[ History Actions ]#

func undo*(workbench: var Workbench): bool =
  ## Step back one scene edit, clearing the selection unconditionally.
  ##   A restored snapshot's slot numbers need not match what was picked, so nothing picked
  ##   survives the step.
  if not workbench.history.undo(workbench.scene): return false
  workbench.selection.clear()
  workbench.session = none(Session)
  workbench.hovered = none(Slot)
  true


func redo*(workbench: var Workbench): bool =
  ## Step forward one scene edit, clearing the selection unconditionally.
  if not workbench.history.redo(workbench.scene): return false
  workbench.selection.clear()
  workbench.session = none(Session)
  workbench.hovered = none(Slot)
  true



#[ Session Actions ]#

func isSessionOpen*(workbench: Workbench): bool {.inline.} = workbench.session.isSome
  ## Report whether an edit session is open, which is when `add` is disabled.


func startComposing*(workbench: var Workbench, label: Label) =
  ## Open a session for a new object, refusing to open a second over an open one.
  if workbench.session.isSome: return
  workbench.session = some(initComposing(
    categorical(workbench.scene.count), label
  ))


func startEditing*(workbench: var Workbench, slot: Slot) =
  ## Open a session on an existing object, replacing any open session.
  let started = initEditing(workbench.scene, slot)
  if started.isNone: return
  workbench.session = started


func saveSession*(workbench: var Workbench): Option[Slot] =
  ## Commit the open session, recording one entry for coefficients, label and colour at once.
  if workbench.session.isNone: return
  let slot = workbench.session.get.save(workbench.scene, workbench.now_ms)
  workbench.session = none(Session)
  if slot.isNone: return
  workbench.selection.replaceWith(slot.get)
  workbench.history.record(workbench.scene)
  slot


func cancelSession*(workbench: var Workbench) =
  ## Abandon the open session: nothing was added while composing, nothing moved while editing.
  workbench.session = none(Session)


func ghost*(workbench: Workbench): Option[Multivector] =
  ## Read the multivector the session preview draws, where a session is open.
  ##   One ghost serves both modes, a direct consequence of the sessions being one type.
  if workbench.session.isNone: return
  some(workbench.session.get.staged)



#[ Aiming ]#

func aimFor*(geometry: Multivector, anchor: Option[Position]): Option[Aim] =
  ## Choose where the camera should look to show a multivector.
  ##   A horizon point is faced along its own direction; a horizon line along the first axis
  ##   spanning perpendicular to its normal, since no single direction faces a whole great
  ##   circle; a horizon plane not at all, since it fills the sky; anything finite at the same
  ##   representative point the selection ring is drawn on.
  case geometry.locus
  of Locus.Finite:
    if anchor.isNone: return
    some(aimAt(anchor.get))
  of Locus.Horizon:
    case geometry.shape
    of Shape.Point:
      let heading = geometry.direction
      if heading.isNone: return
      some(aimAlong(heading.get))
    of Shape.Line:
      let axis = geometry.normal
      if axis.isNone: return
      let
        origin_point = pointAt(Position(x: 0.0, y: 0.0, z: 0.0))
        axis_line = origin_point ∧ directionAt(axis.get)
        facing = origin_point.expandWeight(axis_line)
        spanning = facing.tangents
      if spanning.isNone: return
      some(aimAlong(spanning.get[0]))
    else: none(Aim)


func aim*(workbench: var Workbench) =
  ## Offer the camera whatever the user is working on, once per frame.
  ##   The rule: aim at the open edit session's staged multivector if there is one, else at
  ##   the sole selected object. That second clause is what carries applying an operation,
  ##   releasing a drag and stepping the demo, since each already leaves its new object solely
  ##   selected — none of them needs to know the camera exists.
  var offered = none(Aim)
  if workbench.session.isSome:
    let staged = workbench.session.get.staged
    offered = aimFor(staged, staged.anchor)
  else:
    let sole = workbench.selection.sole
    if sole.isSome and workbench.scene.isLive(sole.get):
      offered = aimFor(workbench.scene.geometry(sole.get), workbench.scene.drawAnchor(sole.get))
  if offered.isNone:
    workbench.tween.release()
    return
  workbench.tween.offer(workbench.camera, offered.get)


func advanceCamera*(workbench: var Workbench, delta_ms: float) =
  ## Move the camera along its ease, once per frame.
  workbench.tween.advance(workbench.camera, delta_ms)


func grabCamera*(workbench: var Workbench) =
  ## Hand the camera to the user, abandoning any goal rather than releasing it.
  workbench.tween.abandon()



#[ Presentation ]#

func presentationFor*(workbench: Workbench, slot: Slot): Presentation =
  ## Decide how an item draws this frame.
  if not workbench.scene.isLive(slot): Presentation.Hidden
  elif not workbench.scene.isVisible(slot): Presentation.Hidden
  else: Presentation.Normal


func colorFor*(workbench: Workbench, slot: Slot, presentation: Presentation): Color =
  ## Choose the colour an item draws in this frame.
  let base = workbench.scene.paint(slot).color
  case presentation
  of Presentation.Normal: base
  of Presentation.Muted: base.muted
  of Presentation.Hidden: base


func growth*(workbench: Workbench, slot: Slot): float =
  ## Measure how far a freshly added object has grown in, over the standard duration.
  if not workbench.scene.isLive(slot): return 1.0
  let elapsed = workbench.now_ms - workbench.scene.birth(slot)
  if elapsed >= ANIMATION_DURATION_MS: return 1.0
  if elapsed <= 0.0: return 0.0
  ease(elapsed/ANIMATION_DURATION_MS)



#[ Mesh Building ]#

func buildMesh*(
  workbench: Workbench,
  target: var Mesh,
  presentations: array[ITEM_CAPACITY, Presentation],
) =
  ## Fill the meshes for one frame, in the order the blend depends on.
  ##   Any visible horizon dome is inserted first, before every other visible object, so an
  ##   ordinary plane's wash blends over it whatever slots they occupy.
  target.clear()
  if workbench.is_showing_grid: target.addFurnitureGrid(workbench.camera)
  if workbench.is_showing_axes: target.addFurnitureAxes(workbench.camera)

  for slot in workbench.scene.items:
    if presentations[slot.index] == Presentation.Hidden: continue
    let geometry = workbench.scene.geometry(slot)
    if geometry.shape != Shape.Plane or geometry.locus != Locus.Horizon: continue
    target.addHorizonPlane(
      workbench.colorFor(slot, presentations[slot.index]), workbench.camera
    )

  for slot in workbench.scene.items:
    let presentation = presentations[slot.index]
    if presentation == Presentation.Hidden: continue
    let geometry = workbench.scene.geometry(slot)
    if geometry.shape == Shape.Plane and geometry.locus == Locus.Horizon: continue
    target.addObject(
      geometry = geometry,
      color = workbench.colorFor(slot, presentation),
      camera = workbench.camera,
      anchor_override = workbench.scene.anchorOverride(slot),
    )

  # Preview the open session through the same dispatch a real object uses, so an all-zero
  #   ghost degrades to "nothing to draw" with no special case.
  let staged = workbench.ghost
  if staged.isSome:
    target.addObject(
      geometry = staged.get,
      color = Paint.Guide.color.muted,
      camera = workbench.camera,
    )

  # Ring every selected slot, and the hovered one at eight tenths the opacity.
  for slot in workbench.selection:
    if not workbench.scene.isLive(slot): continue
    let anchor = workbench.scene.drawAnchor(slot)
    if anchor.isSome: target.addRing(anchor.get, 1.0)
  if workbench.hovered.isSome and workbench.scene.isLive(workbench.hovered.get):
    let anchor = workbench.scene.drawAnchor(workbench.hovered.get)
    if anchor.isSome: target.addRing(anchor.get, RING_HOVER_ALPHA)


func buildMesh*(workbench: Workbench, target: var Mesh) =
  ## Fill the meshes for an ordinary interactive frame.
  var presentations: array[ITEM_CAPACITY, Presentation]
  for slot in workbench.scene.items:
    presentations[slot.index] = workbench.presentationFor(slot)
  workbench.buildMesh(target, presentations)
