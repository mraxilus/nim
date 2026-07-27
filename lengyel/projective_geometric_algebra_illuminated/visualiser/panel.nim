## Lay out panels user edits scene and camera through.
##
## Workbench holds what the GUI needs between frames and the scene does not own:
## which operands are picked, what point is about to be added, where to export.
##   Everything else is read straight off scene and camera, so there is one source of truth
##   and no synchronisation step.
##
##   |------------|-------------------------------------------------------------------|
##   | Panel      | Offers                                                            |
##   |------------|-------------------------------------------------------------------|
##   | Objects    | Show, hide, rename, recolour, remove; edit any coefficient.        |
##   | Construct  | Add point at a position; apply any library operation to operands.  |
##   | View       | Orbit, target, lens, world furniture, PNG export, vsync, framerate. |
##   |------------|-------------------------------------------------------------------|
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
import ./[camera, gui, mesh, objects, scene]



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
  gui.sameLine()
  let tint = scene[slot].ink.colour
  gui.textTinted(toCstring(scene.labelAt(slot)), tint.red, tint.green, tint.blue)
  gui.sameLine()
  result = gui.buttonSmall("remove")
  gui.text(cstring(&"  {formatMultivector(scene[slot].geometry)}"))
  gui.text(cstring(&"  {describeShape(scene[slot].geometry)}"))

  if gui.header("edit", is_open_first = false):
    gui.widthPush(220.0)
    discard gui.inputText("label", toCstring(scene.labelAt(slot)), cint(LABEL_MAX))
    var index_ink = cint(scene[slot].ink)
    if gui.combo("colour", addr index_ink, addr lut_ink_to_name[Ink.low], cint(COUNT_INK)):
      scene.setInk(slot, Ink(index_ink))
    gui.widthPop()
    layoutCoefficients(scene.geometryAt(slot))
  gui.separator()


proc layoutObjects*(scene: var Scene) =
  ## Lay out every live item's controls, applying at most one removal per frame.
  ##   One per frame is enough, since a click can only land on one button.
  gui.separatorText(cstring(&"objects ({scene.len} of {ITEMS_MAX})"))
  var slot_removed = none(int)
  for slot, _ in scene.pairs:
    if layoutItem(scene, slot): slot_removed = some(slot)
  if slot_removed.isSome: scene.removeItem(slot_removed.get)



#[ Construct Panel ]#

proc layoutPointNew(workbench: var Workbench; scene: var Scene) =
  ## Lay out controls that add fresh point at a position.
  gui.separatorText("add point")
  gui.widthPush(260.0)
  discard gui.dragFloat3("position", addr workbench.place_new[0], SPEED_DRAG*10.0)
  gui.widthPop()
  gui.disabledPush(scene.isFull)
  if gui.button("add point"):
    let place = Position(
      x: float(workbench.place_new[0]),
      y: float(workbench.place_new[1]),
      z: float(workbench.place_new[2]),
    )
    scene.addItem(toMultivector(place), &"p{scene.len}", inkCycled(scene.len))
    toChars(&"Added point at ({place.x:.2f}, {place.y:.2f}, {place.z:.2f}).",
      workbench.message)
  gui.disabledPop()


proc layoutOperation(workbench: var Workbench; scene: var Scene) =
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
  for slot, _ in scene.pairs:
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
  discard gui.combo("operand m", addr workbench.index_operand_first,
    addr names[0], cint(count))
  gui.disabledPush(not is_binary)
  discard gui.combo("operand n", addr workbench.index_operand_second,
    addr names[0], cint(count))
  gui.disabledPop()
  gui.widthPop()

  gui.disabledPush(scene.isFull)
  if gui.button("apply"):
    let
      first = slots[clamp(int(workbench.index_operand_first), 0, count - 1)]
      second = slots[clamp(int(workbench.index_operand_second), 0, count - 1)]
      derived = applyOperation(operation, scene[first].geometry, scene[second].geometry)
      name_first = $toCstring(scene.labelAt(first))
      name_second = $toCstring(scene.labelAt(second))
      label =
        if is_binary: &"{name_first} {$operation} {name_second}"
        else: &"{$operation} {name_first}"
    scene.addItem(derived, label, inkCycled(scene.len))
    toChars(&"{$operation} gave {describeShape(derived)}.", workbench.message)
  gui.disabledPop()


proc layoutConstruct*(workbench: var Workbench; scene: var Scene) =
  ## Lay out both ways of growing scene, then report outcome of last action.
  layoutPointNew(workbench, scene)
  layoutOperation(workbench, scene)
  gui.separator()
  gui.text(toCstring(workbench.message))



#[ View Panel ]#

proc layoutView*(workbench: var Workbench; camera: var Camera) =
  ## Lay out camera placement, world furniture and frame export.
  gui.separatorText("view")
  gui.widthPush(260.0)

  var placement = [
    cfloat(camera.azimuth), cfloat(camera.elevation), cfloat(camera.distance)
  ]
  if gui.dragFloat("azimuth", addr placement[0], 0.01, 0.0, 0.0):
    camera.azimuth = float(placement[0])
  if gui.dragFloat("elevation", addr placement[1], 0.01,
      cfloat(-ELEVATION_LIMIT), cfloat(ELEVATION_LIMIT)):
    camera.elevation = float(placement[1])
  if gui.dragFloat("distance", addr placement[2], 0.05,
      cfloat(DISTANCE_LIMIT_NEAR), cfloat(DISTANCE_LIMIT_FAR)):
    camera.distance = float(placement[2])

  var target = [cfloat(camera.target.x), cfloat(camera.target.y), cfloat(camera.target.z)]
  if gui.dragFloat3("target", addr target[0], SPEED_DRAG*10.0):
    camera.target = Position(x: float(target[0]), y: float(target[1]), z: float(target[2]))

  var field_of_view = cfloat(camera.degrees_field_of_view)
  if gui.dragFloat("field of view", addr field_of_view, 0.2, 10.0, 120.0):
    camera.degrees_field_of_view = float(field_of_view)
  gui.widthPop()

  discard gui.checkbox("world axes", addr workbench.is_axes_shown)
  gui.sameLine()
  discard gui.checkbox("ground grid", addr workbench.is_grid_shown)

  gui.separatorText("export")
  gui.widthPush(300.0)
  discard gui.inputText("path", toCstring(workbench.path_export), cint(PATH_MAX))
  gui.widthPop()
  if gui.button("save PNG"): workbench.is_export_requested = true

  # Report what the frame cost here rather than in a benchmark, since the answer is the
  #   reader's own machine, and tessellation is the only part this code controls.
  gui.separatorText("cost")
  discard gui.checkbox("vsync", addr workbench.is_vsync_enabled)
  gui.sameLine()
  gui.text("uncheck to see uncapped cost; uneven fps below settles over ~1s after any change")
  gui.text(cstring(&"{int(gui.framerate())} fps, {1000.0/max(gui.framerate(), 1.0):.2f} ms/frame"))
  gui.text(cstring(
    &"tessellate {workbench.microseconds_tessellate:.1f} us into " &
    &"{workbench.count_vertices} vertices"
  ))



#[ Whole Workbench ]#

proc layoutWorkbench*(workbench: var Workbench; scene: var Scene; camera: var Camera) =
  ## Lay out every panel inside one window.
  gui.windowPlace(16.0, 16.0, WIDTH_PANEL, 720.0)
  if gui.windowBegin("RGA workbench"):
    gui.text("Drag object to object: left joins, right meets, middle projects.")
    gui.text("Drag empty space: left orbits, right pans, wheel dollies.")
    gui.separator()
    layoutView(workbench, camera)
    layoutConstruct(workbench, scene)
    layoutObjects(scene)
  gui.windowEnd()
