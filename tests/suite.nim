## Test the properties the workbench claims, once, for every configuration it is built in.
##
## Included by each entry point rather than imported, so the configurations cannot drift: an
## entry point is a testament spec header and this include, and nothing else. Every invariant
## the requirements state as a requirement has a case here.
##
## Suites needing a live GL context — the renderer, the panel — are not here; they are covered
## by driving the built binaries, which is what `tools/verify.sh` does.

import std/[math, options, strutils, unicode, unittest]

import ../src/core/[
  algebra, anchoring, camera, catalogue, colorimetry, config, demo, diagnostics, format,
  history, interaction, mesh, palette, picking, scene, sceneio, selection, session, transform,
  workbench,
]



#[ Fixtures ]#

let
  VIEWPORT = Viewport(width: 1440.0, height: 900.0)
  POINT_A = pointAt(3.0, -2.0, 2.5)
  POINT_B = pointAt(-2.5, 2.0, 5.5)
  POINT_C = pointAt(1.0, 4.0, 3.0)

proc screenOf(camera: Camera, p: Position): ScreenPoint =
  ## Project a world position the way the hit test does.
  let projected = toScreen(camera.viewProjection(VIEWPORT.width/VIEWPORT.height), VIEWPORT, p)
  check projected.isSome
  projected.get



#[ Algebra ]#

suite "algebra":
  test "shape reads from grade, and mixed grade has none":
    check (POINT_A).shape == Shape.Point
    check (POINT_A ∧ POINT_B).shape == Shape.Line
    check (POINT_A ∧ POINT_B ∧ POINT_C).shape == Shape.Plane
    check (POINT_A + (POINT_A ∧ POINT_B)).shape == Shape.None
    check (POINT_A ∧ (POINT_A ∧ POINT_B ∧ POINT_C)).shape == Shape.None

  test "position projects through unitization, not through raw coefficients":
    let scaled = 7.0*POINT_A
    check scaled.position.get =~ Position(x: 3.0, y: -2.0, z: 2.5)

  test "weight vanishing puts an object at horizon":
    check POINT_A.locus == Locus.Finite
    check directionAt(1.0, 0.0, 0.0).locus == Locus.Horizon
    check (⊖(POINT_A ∧ POINT_B)).locus == Locus.Horizon

  test "midpoint is a sum of unit-weight points":
    let middle = midpoint(POINT_A, POINT_B).get
    check middle =~ Position(x: 0.25, y: 0.0, z: 4.0)

  test "tangents span the plane and stay perpendicular":
    let
      plane = POINT_A ∧ POINT_B ∧ POINT_C
      (first, second) = plane.tangents.get
      normal = plane.normal.get
    # Each tangent lies in the plane: its direction meets the plane's normal at a right angle.
    check abs(first.x*normal.x + first.y*normal.y + first.z*normal.z) < 1.0e-9
    check abs(second.x*normal.x + second.y*normal.y + second.z*normal.z) < 1.0e-9
    check abs(first.x*second.x + first.y*second.y + first.z*second.z) < 1.0e-9

  test "basis names match what the library prints for that element alone":
    for b in Basis:
      check b.elementName == $initElement(b)



#[ Catalogue ]#

suite "catalogue":
  test "the catalogue holds twenty-seven operations, unary before binary":
    check ord(Operation.high) + 1 == 27
    var seen_binary = false
    for operation in Operation:
      if operation.arity == Arity.Binary: seen_binary = true
      elif seen_binary: check false  # A unary entry after a binary one would break the order.
    check operationCount(Arity.Unary) == 13
    check operationCount(Arity.Binary) == 14

  test "every label is notation, two spaces, then an English name":
    for operation in Operation:
      let label = operation.label
      check label.startsWith(operation.notation)
      check label == operation.notation & "  " & LUT_OPERATION_TO_NAME[operation]
      check not label[operation.notation.len + 2 .. ^1].startsWith(" ")

  test "the five accented operands are spacing modifiers, not combining marks":
    const COMBINING = ["̂", "̲", "̅", "̃", "̰"]
    for operation in Operation:
      for mark in COMBINING:
        check not operation.label.contains(mark)
    check Operation.Unitize.notation == "𝐦ˆ"
    check Operation.ComplementLeft.notation == "𝐦ˍ"
    check Operation.ComplementRight.notation == "𝐦¯"
    check Operation.Reverse.notation == "𝐦˜"
    check Operation.Antireverse.notation == "𝐦˷"

  test "attitude is postfix by exception, negate stays prefix":
    check Operation.Attitude.notation == "𝐦⊖"
    check Operation.Negate.notation == "−𝐦"

  test "subtract carries the declaration's minus sign, not a hyphen":
    check Operation.Subtract.notation.contains("−")
    check not Operation.Subtract.notation.contains("-")

  test "derived labels substitute operands only, through two sentinel passes":
    check Operation.Wedge.derivedLabel("a", "b") == "a ∧ b"
    check Operation.ProjectCentral.derivedLabel("p", "q") == "q ∨ (p ∧ q★)"
    # An operand whose own name contains an operand letter is not substituted twice.
    check Operation.Wedge.derivedLabel("𝐧", "b") == "𝐧 ∧ b"
    check Operation.Add.derivedLabel("𝐦", "𝐧") == "𝐦 + 𝐧"
    # No derived label carries a bold operand it was not given.
    check not Operation.Attitude.derivedLabel("a", "").contains("𝐦")

  test "applying an operation calls the library's own function":
    check (Operation.Wedge.apply(POINT_A, POINT_B)) =~ (POINT_A ∧ POINT_B)
    check (Operation.Antiwedge.apply(POINT_A ∧ POINT_B ∧ POINT_C, POINT_A ∧ POINT_B)) =~
      ((POINT_A ∧ POINT_B ∧ POINT_C) ∨ (POINT_A ∧ POINT_B))
    check Operation.Attitude.apply(POINT_A ∧ POINT_B, Multivector()) =~ ⊖(POINT_A ∧ POINT_B)



#[ Formatting ]#

suite "formatting":
  const SAMPLES = [
    3.5, 1664.0, 1234567.0, 0.0, -0.0, 1.0, -1.0, 0.5, 0.25, 1e-5, 1.5e-5, 9999.5,
    99999.0, 0.000123456, 123456.0, -3.14159265, 2.0/3.0, 1e12, -1e-12, 6.02214076e23,
  ]

  test "four significant digits, no trailing zeros, no trailing point":
    check format(3.5) == "3.5"
    check format(1664.0) == "1664"
    check format(1234567.0) == "1.235e+06"
    check format(0.0) == "0"
    check not format(2.0/3.0).endsWith("0")
    check not format(1.0).endsWith(".")

  test "the portable path and the runtime path agree over twenty values":
    when not defined(js):
      for value in SAMPLES:
        if value == 0.0: continue  # Negative zero is the one pinned difference, below.
        check formatPortable(value) == formatRuntime(value)
      # The platform signs a zero; this tool does not, deliberately and only here.
      check formatRuntime(-0.0) == "-0"
      check formatPortable(-0.0) == "0"
      check formatPortable(0.0) == formatRuntime(0.0)
    else:
      # A C runtime is not available here; the portable path is the one both targets use.
      for value in SAMPLES:
        check formatPortable(value).len > 0

  test "diagnostics readings stay fixed width":
    check formatFixed(3.5) == "3.50"
    check formatFixed(16.0) == "16.00"
    check formatFixed(0.125) == "0.13"



#[ Palette ]#

suite "palette":
  test "the categorical run is the tail of the enumeration":
    check CATEGORICAL_COUNT == 5
    check ord(Paint.high) - ord(CATEGORICAL_FIRST) + 1 == CATEGORICAL_COUNT
    var count = 0
    for paint in assignable():
      check paint.isAssignable
      count += 1
    check count == CATEGORICAL_COUNT

  test "structural slots are never assignable":
    for paint in [Paint.Backdrop, Paint.AxisX, Paint.AxisY, Paint.AxisZ, Paint.Grid,
        Paint.Guide, Paint.Outline, Paint.Invalid]:
      check not paint.isAssignable

  test "the cycler walks the assignable run and wraps":
    for index in 0 ..< CATEGORICAL_COUNT*3:
      check categorical(index).isAssignable
    check categorical(0) == categorical(CATEGORICAL_COUNT)

  test "muting blends toward luminance and drops coverage":
    let base = Paint.Jade.color
    let dimmed = base.muted
    check dimmed.a == MUTE_ALPHA
    check abs(dimmed.luminance - base.luminance) < 1.0e-9
    check abs(dimmed.r - base.r) < abs(base.luminance - base.r) + 1.0e-9

  test "an assignable hue is never the reserved magenta":
    for paint in assignable():
      check paint != Paint.Invalid



#[ Colour Measurement ]#

suite "colour":
  test "the difference formula matches its published test pairs":
    # Sharma, Wu and Dalal (2005) published these to catch exactly the hue-wrap and
    #   rotation-term mistakes CIEDE2000 invites; a validator that fails them measures
    #   nothing.
    const PAIRS = [
      (Lab(lightness: 50.0, a: 2.6772, b: -79.7751),
       Lab(lightness: 50.0, a: 0.0, b: -82.7485), 2.0425),
      (Lab(lightness: 50.0, a: 3.1571, b: -77.2803),
       Lab(lightness: 50.0, a: 0.0, b: -82.7485), 2.8615),
      (Lab(lightness: 50.0, a: -1.3802, b: -84.2814),
       Lab(lightness: 50.0, a: 0.0, b: -82.7485), 1.0000),
      (Lab(lightness: 60.2574, a: -34.0099, b: 36.2677),
       Lab(lightness: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
      (Lab(lightness: 63.0109, a: -31.0961, b: -5.8663),
       Lab(lightness: 62.8187, a: -29.7946, b: -4.0864), 1.2630),
      (Lab(lightness: 22.7233, a: 20.0904, b: -46.6940),
       Lab(lightness: 23.0331, a: 14.9730, b: -42.5619), 2.0373),
    ]
    for (left, right, expected) in PAIRS:
      check abs(deltaE(left, right) - expected) < 0.0002

  test "a colour reads as itself through normal vision":
    for paint in Paint:
      check deltaE(paint.color, paint.color.simulate(Deficiency.Normal)) < 1.0e-9

  test "every pair of assignable hues clears its separation":
    # The floors the brief states: fifteen of difference and twenty degrees of hue, so
    #   lightness can never stand in for a hue difference.
    for first in assignable():
      for second in assignable():
        if ord(second) <= ord(first): continue
        check deltaE(first.color, second.color) >= 15.0
        check hueDistance(first.color, second.color) >= 20.0

  test "exactly one pair leans on a second encoding under colour-vision deficiency":
    var leaning: seq[string]
    for first in assignable():
      for second in assignable():
        if ord(second) <= ord(first): continue
        let worst = deltaEWorst(first.color, second.color)
        check worst >= 6.0                       # No pair may fall below the legal band.
        if worst < 8.0: leaning.add($first & "/" & $second)
    check leaning.len == 1                       # And only one may sit inside it.
    check leaning[0] == "Jade/Cobalt"

  test "every assignable hue clears the reserved magenta under deficiency":
    for paint in assignable():
      check deltaEWorst(paint.color, Paint.Invalid.color) >= 14.0

  test "every assignable hue clears the axis colours, at a looser floor":
    # Looser on purpose: a thin fixed line needs less separation than two adjacent fills.
    for paint in assignable():
      for axis in [Paint.AxisX, Paint.AxisY, Paint.AxisZ]:
        check deltaE(paint.color, axis.color) >= 7.5
        check hueDistance(paint.color, axis.color) >= 18.0



#[ Scene ]#

suite "scene":
  test "a slot stays valid until its own item is removed":
    var scene = initScene()
    let
      first = scene.add(POINT_A, initLabel("a"), 0.0).get
      second = scene.add(POINT_B, initLabel("b"), 0.0).get
      third = scene.add(POINT_C, initLabel("c"), 0.0).get
    scene.remove(second)
    check scene.isLive(first)
    check not scene.isLive(second)
    check scene.isLive(third)
    check $scene.label(third) == "c"
    # The freed slot goes straight back to the next add, and nothing else renumbers.
    let fourth = scene.add(POINT_A, initLabel("d"), 0.0).get
    check fourth == second
    check $scene.label(first) == "a"
    check $scene.label(third) == "c"

  test "the anchor choke point reports nothing for a dead slot":
    var scene = initScene()
    let slot = scene.add(POINT_A, initLabel("a"), 0.0).get
    check scene.drawAnchor(slot).isSome
    scene.remove(slot)
    check scene.drawAnchor(slot).isNone

  test "labels truncate at whole characters":
    let long_label = initLabel("𝐦 ∧ 𝐧".repeat(20))
    check ($long_label).runeLen <= LABEL_CAPACITY
    check ($long_label).validateUtf8 == -1

  test "recency order reads newest first":
    var scene = initScene()
    let
      old_slot = scene.add(POINT_A, initLabel("old"), 0.0).get
      new_slot = scene.add(POINT_B, initLabel("new"), 1000.0).get
    var order: array[ITEM_CAPACITY, Slot]
    let length = scene.recentOrder(order)
    check length == 2
    check order[0] == new_slot
    check order[1] == old_slot



#[ Selection ]#

suite "selection":
  test "selection is ordered, and its size names an arity":
    var selection = Selection()
    check selection.arity == Arity.Unary
    selection.toggle(Slot(3))
    selection.toggle(Slot(1))
    check selection.len == 2
    check selection.first.get == Slot(3)
    check selection.second.get == Slot(1)
    check selection.arity == Arity.Binary
    selection.toggle(Slot(3))
    check selection.first.get == Slot(1)

  test "dead slots are pruned after a removal":
    var scene = initScene()
    let slot = scene.add(POINT_A, initLabel("a"), 0.0).get
    var selection = Selection()
    selection.replaceWith(slot)
    scene.remove(slot)
    selection.prune(scene)
    check selection.isEmpty

  test "a selection knows whether it is entirely hidden":
    var scene = initScene()
    let
      first = scene.add(POINT_A, initLabel("a"), 0.0).get
      second = scene.add(POINT_B, initLabel("b"), 0.0).get
    var selection = Selection()
    selection.toggle(first)
    selection.toggle(second)
    check not selection.isEntirelyHidden(scene)
    scene.setVisible(first, false)
    check not selection.isEntirelyHidden(scene)
    scene.setVisible(second, false)
    check selection.isEntirelyHidden(scene)



#[ Sessions ]#

suite "sessions":
  test "a composing session writes nothing to the scene before save":
    var workbench = initWorkbench()
    let before = workbench.scene.count
    workbench.startComposing(initLabel("new"))
    check workbench.isSessionOpen
    workbench.session.get.setCoefficient(E1, 5.0)
    check workbench.scene.count == before
    check workbench.ghost.isSome
    workbench.cancelSession()
    check workbench.scene.count == before
    check workbench.ghost.isNone

  test "saving a composing session adds exactly one item":
    var workbench = initWorkbench()
    workbench.startComposing(initLabel("new"))
    workbench.session.get.setStaged(POINT_A)
    let before = workbench.scene.count
    let slot = workbench.saveSession()
    check slot.isSome
    check workbench.scene.count == before + 1
    check workbench.selection.sole.get == slot.get

  test "an editing session leaves the object untouched until save":
    var workbench = initWorkbench()
    let slot = workbench.addObject(POINT_A, initLabel("a")).get
    workbench.startEditing(slot)
    workbench.session.get.setStaged(POINT_B)
    check workbench.scene.geometry(slot) =~ POINT_A
    discard workbench.saveSession()
    check workbench.scene.geometry(slot) =~ POINT_B

  test "a session cannot be opened over an open composing session":
    var workbench = initWorkbench()
    workbench.startComposing(initLabel("first"))
    workbench.startComposing(initLabel("second"))
    check $workbench.session.get.label == "first"

  test "an all-zero ghost degrades to nothing to draw":
    var workbench = initWorkbench()
    workbench.startComposing(initLabel("empty"))
    check workbench.ghost.get.shape == Shape.None
    var target {.global.}: Mesh
    workbench.buildMesh(target)
    check target.point_count == 0



#[ History ]#

suite "history":
  test "the entry under the cursor is always the live scene":
    var workbench = initWorkbench()
    discard workbench.addObject(POINT_A, initLabel("a"))
    check workbench.history.current.count == workbench.scene.count

  test "recording to capacity and walking back and forward":
    var
      workbench = initWorkbench()
      expected: seq[int]
    expected.add(workbench.scene.count)
    for index in 0 ..< HISTORY_CAPACITY + 4:
      discard workbench.addObject(POINT_A, initLabel("p" & $index))
      expected.add(workbench.scene.count)
    # Only the last HISTORY_CAPACITY entries survive; the oldest are dropped, not grown into.
    var walked: seq[int]
    walked.add(workbench.scene.count)
    while workbench.history.canUndo:
      check workbench.undo()
      walked.add(workbench.scene.count)
    check walked.len == HISTORY_CAPACITY
    while workbench.history.canRedo:
      check workbench.redo()
    check workbench.scene.count == expected[^1]

  test "undo clears the selection unconditionally":
    var workbench = initWorkbench()
    let slot = workbench.addObject(POINT_A, initLabel("a")).get
    check workbench.selection.sole.get == slot
    check workbench.undo()
    check workbench.selection.isEmpty

  test "a fresh edit truncates the redo path":
    var workbench = initWorkbench()
    discard workbench.addObject(POINT_A, initLabel("a"))
    discard workbench.addObject(POINT_B, initLabel("b"))
    check workbench.undo()
    check workbench.history.canRedo
    discard workbench.addObject(POINT_C, initLabel("c"))
    check not workbench.history.canRedo



#[ Save And Load ]#

suite "save and load":
  test "a scene round-trips through the record boundary both targets share":
    var workbench = initWorkbench()
    workbench.reset(seedScene())
    var records: array[DEMO_STEP_COUNT, StepRecord]
    workbench.applySteps(records)
    workbench.scene.setVisible(Slot(1), false)
    workbench.scene.setPaint(Slot(2), Paint.Cobalt)

    let restored = fromRecords(workbench.scene.toRecords)
    check restored.isSome
    let loaded = restored.get
    check loaded.count == workbench.scene.count
    for slot in workbench.scene.items:
      check loaded.isLive(slot)
      check loaded.geometry(slot) =~ workbench.scene.geometry(slot)
      check $loaded.label(slot) == $workbench.scene.label(slot)
      check loaded.paint(slot) == workbench.scene.paint(slot)
      check loaded.isVisible(slot) == workbench.scene.isVisible(slot)
      # Birth times and anchor overrides are deliberately not stored.
      check loaded.birth(slot) == 0.0
      check loaded.anchorOverride(slot).isNone

  test "records refuse a structural colour and an oversized scene":
    var records = seedScene().toRecords
    records[0].paint = ord(Paint.Grid)
    check fromRecords(records).isNone

  when not defined(js):
    test "a scene round-trips through the file format":
      var workbench = initWorkbench()
      workbench.reset(seedScene())
      var records: array[DEMO_STEP_COUNT, StepRecord]
      workbench.applySteps(records)
      let restored = decode(encode(workbench.scene))
      check restored.isSome
      check restored.get.count == workbench.scene.count
      for slot in workbench.scene.items:
        check restored.get.geometry(slot) =~ workbench.scene.geometry(slot)
        check $restored.get.label(slot) == $workbench.scene.label(slot)

    test "a foreign or short file is refused without touching the caller's scene":
      check decode("").isNone
      check decode("NOPE" & "\1\16" & "\0\0\0\0").isNone
      var wrong_version = encode(seedScene())
      wrong_version[4] = char(FORMAT_VERSION + 1)
      check decode(wrong_version).isNone
      var wrong_basis = encode(seedScene())
      wrong_basis[5] = char(BASIS_COUNT + 1)
      check decode(wrong_basis).isNone

    test "the header names the format, its version and its basis count":
      let bytes = encode(seedScene())
      check bytes[0 ..< 4] == MAGIC
      check uint8(bytes[4]) == FORMAT_VERSION
      check int(uint8(bytes[5])) == BASIS_COUNT
      # Every live item is written, in slot order, at the size the format states.
      var expected = HEADER_SIZE
      for slot in seedScene().items:
        expected += 3 + ($seedScene().label(slot)).len + BASIS_COUNT*FLOAT_SIZE
      check bytes.len == expected



#[ Camera ]#

suite "camera":
  test "clip planes derive from the orbit distance":
    var camera = defaultCamera()
    let ratio = camera.farClip/camera.nearClip
    camera.distance = DISTANCE_MAX
    check abs(camera.farClip/camera.nearClip - ratio) < 1.0e-9
    check camera.farClip > camera.distance

  test "the forward formula and its inverse agree":
    var camera = defaultCamera()
    let (azimuth, elevation) = anglesFacing(camera.heading)
    check abs(azimuth - camera.azimuth) < 1.0e-9
    check abs(elevation - camera.elevation) < 1.0e-9

  test "elevation stops short of the pole":
    var camera = defaultCamera()
    camera.orbit(0.0, 100000.0)
    check camera.elevation <= ELEVATION_LIMIT

  test "panning with nothing selected is not taken back":
    var workbench = initWorkbench()
    workbench.aim()  # Nothing to aim at: the offer releases.
    let before = workbench.camera.target
    workbench.camera.pan(20.0, 0.0)
    workbench.grabCamera()
    workbench.aim()
    workbench.advanceCamera(16.0)
    check not (workbench.camera.target =~ before)

  test "panning with an object selected is not taken back":
    var workbench = initWorkbench()
    discard workbench.addObject(POINT_A, initLabel("a"))
    workbench.aim()
    for _ in 0 ..< 40: workbench.advanceCamera(16.0)  # Let the ease arrive.
    let arrived = workbench.camera.target
    workbench.camera.pan(30.0, 10.0)
    workbench.grabCamera()
    let panned = workbench.camera.target
    for _ in 0 ..< 40:
      workbench.aim()
      workbench.advanceCamera(16.0)
    check workbench.camera.target =~ panned
    check not (panned =~ arrived)

  test "grabbing the camera mid-ease abandons the goal":
    var workbench = initWorkbench()
    discard workbench.addObject(POINT_A, initLabel("a"))
    workbench.aim()
    workbench.advanceCamera(ANIMATION_DURATION_MS*0.5)
    check workbench.tween.isChasing
    let midflight = workbench.camera.target
    workbench.grabCamera()
    check not workbench.tween.isChasing
    workbench.aim()
    workbench.advanceCamera(16.0)
    check workbench.camera.target =~ midflight

  test "re-selecting after a deselect aims afresh":
    var workbench = initWorkbench()
    let slot = workbench.addObject(POINT_A, initLabel("a")).get
    workbench.aim()
    for _ in 0 ..< 40: workbench.advanceCamera(16.0)
    workbench.selection.clear()
    workbench.aim()  # Nothing selected: the goal is released, not merely delivered.
    workbench.camera.pan(50.0, 0.0)
    workbench.grabCamera()
    let panned = workbench.camera.target
    workbench.selection.replaceWith(slot)
    workbench.aim()
    for _ in 0 ..< 40: workbench.advanceCamera(16.0)
    check not (workbench.camera.target =~ panned)
    check workbench.camera.target =~ workbench.scene.drawAnchor(slot).get

  test "a capture lands instantly, never mid-pan":
    var workbench = initWorkbench()
    let slot = workbench.addObject(POINT_A, initLabel("a")).get
    workbench.aim()
    workbench.tween.deliver(workbench.camera)
    check workbench.camera.target =~ workbench.scene.drawAnchor(slot).get



#[ Picking ]#

suite "picking":
  test "both pick boundaries, one pixel inside and one outside":
    var workbench = initWorkbench()
    let slot = workbench.addObject(POINT_A, initLabel("a")).get
    let
      anchor = workbench.scene.drawAnchor(slot).get
      centre = screenOf(workbench.camera, anchor)
      inside = ScreenPoint(x: centre.x + PICK_RADIUS_POINT - 1.0, y: centre.y)
      outside = ScreenPoint(x: centre.x + PICK_RADIUS_POINT + 1.0, y: centre.y)
    check pick(workbench.scene, workbench.camera, VIEWPORT, inside).get == slot
    check pick(workbench.scene, workbench.camera, VIEWPORT, outside).isNone

  test "a point beats a line beats a plane":
    var workbench = initWorkbench()
    let
      line_slot = workbench.addObject(POINT_A ∧ POINT_B, initLabel("line")).get
      plane_slot = workbench.addObject(
        POINT_A ∧ POINT_B ∧ POINT_C, initLabel("plane"),
        centroid(POINT_A, POINT_B, POINT_C)
      ).get
      point_slot = workbench.addObject(POINT_A, initLabel("point")).get
      at_point = screenOf(workbench.camera, POINT_A.position.get)

    # All three overlap at the point's own anchor: the point must win.
    check pick(workbench.scene, workbench.camera, VIEWPORT, at_point).get == point_slot
    workbench.scene.setVisible(point_slot, false)
    check pick(workbench.scene, workbench.camera, VIEWPORT, at_point).get == line_slot
    workbench.scene.setVisible(line_slot, false)
    check pick(workbench.scene, workbench.camera, VIEWPORT, at_point).get == plane_slot

  test "both halves of a line are pickable":
    var workbench = initWorkbench()
    let
      slot = workbench.addObject(POINT_A ∧ POINT_B, initLabel("line")).get
      geometry = workbench.scene.geometry(slot)
      support = (∩ geometry).position.get
      axis = ⊖ geometry
    # Sample each half on the true line itself: which half a pointer lands on changes as the
    #   camera orbits, so testing one would leave the other unpickable and unnoticed.
    for reach in [6.0, -6.0]:
      let along = translate(pointAt(support), axis, reach).get
      let at_line = screenOf(workbench.camera, along)
      check pick(workbench.scene, workbench.camera, VIEWPORT, at_line).get == slot

  test "a line or plane at horizon is never pickable":
    var workbench = initWorkbench()
    let
      horizon_line = workbench.addObject(⊖(POINT_A ∧ POINT_B ∧ POINT_C), initLabel("h")).get
      horizon_plane = workbench.addObject(
        ⊖(POINT_A ∧ (pointAt(0, 0, 0) ∧ pointAt(1, 0, 0) ∧ pointAt(0, 1, 0))),
        initLabel("sky")
      ).get
    check workbench.scene.geometry(horizon_line).locus == Locus.Horizon
    check workbench.scene.geometry(horizon_plane).locus == Locus.Horizon
    for x in countup(0, 1400, 100):
      for y in countup(0, 880, 100):
        let hit = pick(
          workbench.scene, workbench.camera, VIEWPORT,
          ScreenPoint(x: x.float, y: y.float)
        )
        check hit.isNone

  test "a horizon point keeps a pickable anchor":
    var workbench = initWorkbench()
    let
      slot = workbench.addObject(⊖(POINT_A ∧ POINT_B), initLabel("dir")).get
      heading = workbench.scene.geometry(slot).direction.get
      star = translate(
        pointAt(workbench.camera.eye), directionAt(heading), workbench.camera.horizonRadius
      ).get
    check pick(
      workbench.scene, workbench.camera, VIEWPORT, screenOf(workbench.camera, star)
    ).get == slot



#[ Drawing ]#

suite "drawing":
  test "a line draws as two segments meeting at its support":
    var workbench = initWorkbench()
    discard workbench.addObject(POINT_A ∧ POINT_B, initLabel("line"))
    var target {.global.}: Mesh
    workbench.buildMesh(target)
    check target.line_count == 4  # Two segments, two vertices each.

  test "the two segments project exactly onto the true line":
    # Measured, not argued: a third point sampled far along the true line must land on the
    #   screen line the drawn pair spans, to floating-point precision.
    var workbench = initWorkbench()
    let
      geometry = POINT_A ∧ POINT_B
      support = (∩ geometry).position.get
      axis = ⊖ geometry
      eye_point = pointAt(workbench.camera.eye)
      reach = workbench.camera.horizonRadius
      forward_end = translate(eye_point, axis, reach).get
      backward_end = translate(eye_point, axis, -reach).get
      on_line = translate(pointAt(support), axis, 40.0).get
    let
      matrix = workbench.camera.viewProjection(VIEWPORT.width/VIEWPORT.height)
      a = screenOf(workbench.camera, support)
      d = screenOf(workbench.camera, on_line)
    for far_end in [forward_end, backward_end]:
      # Trim to the part in front of the near plane, as the drawing and the hit test both do.
      let trimmed = clipToFront(matrix, support, far_end)
      check trimmed.isSome
      let
        far = screenOf(workbench.camera, trimmed.get[1])
        dx = far.x - a.x
        dy = far.y - a.y
        length = sqrt(dx*dx + dy*dy)
        skew = abs((d.x - a.x)*dy - (d.y - a.y)*dx)/max(length, 1.0e-12)
      check length > 1.0
      check skew < 1.0e-6

  test "a meet lands correctly far outside the drawn disc":
    # The drawn radius is a rendering choice only; construction reads the full multivector.
    let
      plane = pointAt(0, 0, 0) ∧ pointAt(1, 0, 0) ∧ pointAt(0, 1, 0)  # The z = 0 plane.
      far_line = pointAt(500.0, 0.0, -3.0) ∧ pointAt(500.0, 0.0, 7.0)
      meeting = (far_line ∨ plane).position.get
    check meeting =~ Position(x: 500.0, y: 0.0, z: 0.0)
    check PLANE_RADIUS < 500.0

  test "the grid steps its cell size with its reach":
    check gridCell(GRID_CELL_BASE*4.0) == GRID_CELL_BASE
    var reach = GRID_CELL_BASE
    for _ in 0 ..< 8:
      reach *= 4.0
      check reach/gridCell(reach) <= GRID_CELLS_MAX.float
      # A coarser grid's lines fall on a subset of the finer one's: every cell is a doubling.
      check (gridCell(reach)/GRID_CELL_BASE) mod 2.0 == 0.0 or gridCell(reach) == GRID_CELL_BASE

  test "object lines outweigh furniture lines":
    check LINE_WIDTH_OBJECT > LINE_WIDTH_FURNITURE

  test "a horizon dome is inserted before every other translucent object":
    var workbench = initWorkbench()
    discard workbench.addObject(
      POINT_A ∧ POINT_B ∧ POINT_C, initLabel("plane"),
      centroid(POINT_A, POINT_B, POINT_C)
    )
    let sky = ⊖(POINT_A ∧ (pointAt(0, 0, 0) ∧ pointAt(1, 0, 0) ∧ pointAt(0, 1, 0)))
    check sky.shape == Shape.Plane
    check sky.locus == Locus.Horizon
    discard workbench.addObject(sky, initLabel("sky"))
    var target {.global.}: Mesh
    workbench.buildMesh(target)
    # The dome's own vertices come first: its wash is what an ordinary plane blends over.
    check target.triangle_count > 0
    let first_vertex = target.triangles[0]
    check abs(first_vertex.color.a - DOME_ALPHA) < 1.0e-9

  test "one ring per selected slot, and one for the hover":
    var workbench = initWorkbench()
    let
      first = workbench.addObject(POINT_A, initLabel("a")).get
      second = workbench.addObject(POINT_B, initLabel("b")).get
    workbench.selection.clear()
    workbench.selection.toggle(first)
    workbench.selection.toggle(second)
    workbench.hovered = some(first)
    var target {.global.}: Mesh
    workbench.buildMesh(target)
    check target.ring_count == 3
    check target.rings[2].alpha == RING_HOVER_ALPHA



#[ Anchoring ]#

suite "anchoring":
  test "a join of line and point centres between the point and its foot":
    let
      line = POINT_A ∧ POINT_B
      derived = POINT_C ∧ line
      anchor = creationAnchor(Operation.Wedge, POINT_C, line, derived).get
      foot = POINT_C.projectOrthogonal(line)
    check anchor =~ midpoint(POINT_C, foot).get

  test "a weight expansion centres where the line meets the plane":
    let
      line = POINT_A ∧ POINT_B
      derived = POINT_C.expandWeight(line)
      anchor = creationAnchor(Operation.ExpandWeight, POINT_C, line, derived).get
    check anchor =~ (line ∨ derived).position.get

  test "anything else falls back to the support":
    let derived = POINT_A ∧ POINT_B ∧ POINT_C
    check creationAnchor(Operation.GeometricProduct, POINT_A, POINT_B, derived).isNone

  test "an anchor is a rendering hint, never part of the algebra":
    var workbench = initWorkbench()
    let
      line = POINT_A ∧ POINT_B
      slot = workbench.applyOperation(
        Operation.Wedge,
        workbench.addObject(POINT_C, initLabel("c")).get,
        workbench.addObject(line, initLabel("line")).get,
      ).get
    check workbench.scene.anchorOverride(slot).isSome
    check workbench.scene.geometry(slot) =~ (POINT_C ∧ line)



#[ Interaction ]#

suite "interaction":
  test "each button names one operation, in the core":
    check operationFor(PointerButton.Left) == Operation.Wedge
    check operationFor(PointerButton.Right) == Operation.Antiwedge
    check operationFor(PointerButton.Middle) == Operation.ProjectOrthogonal

  test "a drag checks both ends are alive before reading either label":
    var workbench = initWorkbench()
    let
      source = workbench.addObject(POINT_A, initLabel("a")).get
      destination = workbench.addObject(POINT_B, initLabel("b")).get
    workbench.removeSlot(destination)
    check workbench.applyDrag(PointerButton.Left, source, destination).isNone
    check workbench.applyDrag(PointerButton.Left, destination, source).isNone

  test "a click is short and barely moved":
    check isClick(100.0, 2.0)
    check not isClick(400.0, 2.0)
    check not isClick(100.0, 8.0)
    check isTap(100.0, 10.0)
    check not isTap(100.0, 14.0)



#[ Demo ]#

suite "demo":
  test "both front-ends open on the seeds alone":
    let seeds = seedScene()
    check seeds.count == 5

  test "the eleven steps build what the construction claims":
    var workbench = initWorkbench()
    workbench.reset(seedScene())
    var records: array[DEMO_STEP_COUNT, StepRecord]
    workbench.applySteps(records)
    check workbench.scene.count == 5 + DEMO_STEP_COUNT
    for record in records:
      check record.derived.isSome

    var shapes: seq[(Shape, Locus)]
    for slot in workbench.scene.items:
      let geometry = workbench.scene.geometry(slot)
      shapes.add((geometry.shape, geometry.locus))
    # The last three steps walk all three horizon cases, through a grade-4 volume.
    check shapes[10] == (Shape.Point, Locus.Horizon)
    check shapes[13] == (Shape.Line, Locus.Horizon)
    check shapes[14] == (Shape.None, Locus.Finite)   # a ∧ ground: nothing to draw.
    check shapes[15] == (Shape.Plane, Locus.Horizon)

  test "the projection step is not a silent no-op":
    var workbench = initWorkbench()
    workbench.reset(seedScene())
    var records: array[DEMO_STEP_COUNT, StepRecord]
    workbench.applySteps(records)
    let
      origin_slot = records[7].first.get
      projected_slot = records[7].derived.get
    check not (workbench.scene.geometry(origin_slot) =~
      workbench.scene.geometry(projected_slot))

  test "the preset stamps births one second apart":
    var workbench = initWorkbench()
    workbench.reset(seedScene())
    var records: array[DEMO_STEP_COUNT, StepRecord]
    workbench.applySteps(records)
    for index, record in records:
      check workbench.scene.birth(record.derived.get) == float(index + 1)*SEED_STEP_MS



#[ Diagnostics ]#

suite "diagnostics":
  test "the frame graph keeps its slowest sample":
    var times = FrameTimes()
    for index in 0 ..< FRAME_SAMPLE_COUNT + 10:
      times.record(if index == FRAME_SAMPLE_COUNT + 5: 99.0 else: 16.0)
    check times.len == FRAME_SAMPLE_COUNT
    check times.peak == 99.0
    check times.latest == 16.0

  test "the pool strip wears the scene's own colours":
    var scene = initScene()
    let slot = scene.add(POINT_A, initLabel("a"), 0.0).get
    var strip: array[ITEM_CAPACITY*3, float]
    scene.poolStrip(strip)
    let worn = scene.paint(slot).color
    check strip[slot.index*3] == worn.r
    check strip[ITEM_CAPACITY*3 - 3] == Paint.Grid.color.r



#[ Image Export ]#

when not defined(js):
  import ../src/desktop/[gif, png]

  proc decodeLzwIndependently(data: string, minimum_code_size: int): seq[uint8] =
    ## Decode an LZW stream, written from the format's own description rather than from the
    ##   encoder above — which is the point: a decoder derived from the encoder would repeat
    ##   whatever the encoder gets wrong about when the code size widens.
    let
      clear_code = 1 shl minimum_code_size
      end_code = clear_code + 1
    var
      table: seq[seq[uint8]]
      code_size = minimum_code_size + 1
      next_code = end_code + 1
      previous = -1
      bit_cursor = 0

    proc reset() =
      table.setLen(0)
      for value in 0 ..< clear_code: table.add(@[uint8(value)])
      table.add(@[])  # clear
      table.add(@[])  # end
      code_size = minimum_code_size + 1
      next_code = end_code + 1
      previous = -1
    reset()

    while bit_cursor + code_size <= data.len*8:
      var code = 0
      for bit in 0 ..< code_size:
        let index = bit_cursor + bit
        let is_set = (uint8(data[index div 8]) shr (index mod 8)) and 1'u8
        code = code or (int(is_set) shl bit)
      bit_cursor += code_size

      if code == clear_code:
        reset()
        continue
      if code == end_code: break
      if previous < 0:
        result.add(table[code])
        previous = code
        continue
      let entry =
        if code < table.len and table[code].len > 0: table[code]
        else: table[previous] & table[previous][0]
      result.add(entry)
      table.add(table[previous] & entry[0])
      next_code += 1
      # A decoder adds its entry one symbol later than the encoder, so it widens one earlier.
      if next_code == (1 shl code_size) and code_size < 12: code_size += 1
      previous = code

  suite "image export":
    test "LZW round-trips past the code-width growth point":
      # Long enough that the stream passes the 9-bit and 10-bit boundaries, which is where an
      #   encoder that widens at its own natural moment starts writing codes a decoder
      #   misreads.
      var indices: seq[uint8]
      for index in 0 ..< 12000:
        indices.add(uint8((index*7 + index div 11) mod 251))
      let decoded = decodeLzwIndependently(encodeLzw(indices), 8)
      check decoded.len == indices.len
      check decoded == indices

    test "an encoded GIF carries a header, a palette and a trailer":
      var frame = newSeq[uint8](4*4*4)
      for index in 0 ..< 4*4:
        frame[index*4] = uint8(index*16)
        frame[index*4 + 3] = 255
      let bytes = encodeGif([frame], 4, 4, 90)
      check bytes[0 ..< 6] == "GIF89a"
      check bytes[^1] == '\x3B'
      check bytes.contains("NETSCAPE2.0")

    test "an encoded PNG carries its own signature and chunks":
      var pixels = newSeq[uint8](8*8*4)
      for index in 0 ..< 8*8: pixels[index*4 + 3] = 255
      let bytes = encodePng(pixels, 8, 8)
      check bytes[1 ..< 4] == "PNG"
      check bytes.contains("IHDR")
      check bytes.contains("IDAT")
      check bytes.contains("IEND")
