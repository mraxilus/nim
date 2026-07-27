## Check invariants of visualiser against deterministically sampled pool of RGA objects.
##
## Suites are named after visualiser's modules rather than after Lengyel's chapters,
## since visualiser is tool built on library rather than replication of published equations.
##
## Pool is drawn once from seeded generator, so failure reproduces from test name alone.
##   Points are sampled inside box the drawn extent covers, so nothing is degenerate.
##   Lines and planes are joined from those points, so collinear cases stay improbable.
##
## `renderer`, `gui` and `panel` are absent, and deliberately so: every one of them needs
## a live OpenGL context, which a test runner has no business opening.
##   What they would test is pushed below them instead — `mesh` holds the tessellation,
##   `scene` holds the operations and formatting, `camera` holds the transforms.

when compileOption("profiler"):
  import std/nimprof

import std/[math, options, os, random, strutils, unittest]

import ../../pga
import ../../visualiser/[camera, image, interaction, mesh, objects, picking, scene]

randomize(0)


const
  SAMPLES = 64
  EXTENT_SAMPLE = 5.0
  TOLERANCE_PLACES_TEST {.define: "visualiser.tolerance_places".} = 9
  TOLERANCE_TEST = 10.0.pow(-float(TOLERANCE_PLACES_TEST))
  TOLERANCE_SINGLE = 1.0e-5
    ## Loosen tolerance for values that passed through 32-bit storage.
    ##   Matrices and vertices are single precision, as that is what a GPU consumes,
    ##   so comparing them against double-precision geometry at full tolerance is wrong.


let ORIGIN = Position(x: 0, y: 0, z: 0)


proc randPosition(): Position =
  Position(
    x: rand(-EXTENT_SAMPLE .. EXTENT_SAMPLE),
    y: rand(-EXTENT_SAMPLE .. EXTENT_SAMPLE),
    z: rand(-EXTENT_SAMPLE .. EXTENT_SAMPLE),
  )

var
  PLACES: array[SAMPLES, Position]
  POINTS: array[SAMPLES, Multivector]
  LINES: array[SAMPLES, Multivector]
  PLANES: array[SAMPLES, Multivector]
for i in 0 ..< SAMPLES:
  PLACES[i] = randPosition()
  POINTS[i] = toMultivector(PLACES[i])
for i in 0 ..< SAMPLES:
  let (j, k) = ((i + 1) mod SAMPLES, (i + 2) mod SAMPLES)
  LINES[i] = POINTS[i] ∧ POINTS[j]
  PLANES[i] = POINTS[i] ∧ POINTS[j] ∧ POINTS[k]

# Mesh storage is far too large for a stack frame, exactly as it is in the application.
var MESHES: MeshSet


func `=~`(a, b: float): bool =
  ## Compare approximate equality between scalars.
  abs(a - b) <= TOLERANCE_TEST * max(1.0, max(abs(a), abs(b)))


func `=~`(p, q: Position): bool =
  ## Compare approximate equality between positions.
  p.x =~ q.x and p.y =~ q.y and p.z =~ q.z


func `=~`(d, e: Direction): bool =
  ## Compare approximate equality between directions.
  d.x =~ e.x and d.y =~ e.y and d.z =~ e.z


func isNear(a, b: float): bool =
  ## Compare scalars that passed through 32-bit storage.
  abs(a - b) <= TOLERANCE_SINGLE * max(1.0, max(abs(a), abs(b)))


func isNear(p, q: Position): bool =
  ## Compare positions that passed through 32-bit storage.
  isNear(p.x, q.x) and isNear(p.y, q.y) and isNear(p.z, q.z)


func toPosition(vertex: Vertex): Position =
  ## Read vertex back as position, for checking where tessellation put it.
  Position(x: float(vertex.x), y: float(vertex.y), z: float(vertex.z))


func transform(matrix: Matrix4; p: Position; weight: float): array[4, float] =
  ## Apply transform to homogeneous point, so matrices can be checked by what they do.
  let coordinates = [p.x, p.y, p.z, weight]
  for row in 0 .. 3:
    for column in 0 .. 3:
      result[row] += float(matrix.at(row, column)) * coordinates[column]



suite "Objects":
  test "position inverts toMultivector":
    for place in PLACES:
      let recovered = position(toMultivector(place))
      check recovered.isSome
      check recovered.get =~ place


  test "position ignores scale of homogeneous point":
    for point in POINTS:
      for scale in [-7.5, -1.0, 0.25, 3.0]:
        let (plain, scaled) = (position(point), position(scale * point))
        check plain.isSome and scaled.isSome
        check plain.get =~ scaled.get


  test "shape follows grade":
    for i in 0 ..< SAMPLES:
      check shape(POINTS[i]) == some(Shape.Point)
      check shape(LINES[i]) == some(Shape.Line)
      check shape(PLANES[i]) == some(Shape.Plane)
    check shape(1.0 + POINTS[0]).isNone


  test "support lies on its object":
    for i in 0 ..< SAMPLES:
      for geometry in [LINES[i], PLANES[i]]:
        let anchor = positionAnchor(geometry)
        check anchor.isSome
        check toMultivector(anchor.get) ∧ geometry =~ 0


  test "support of line is perpendicular to its direction":
    for line in LINES:
      let (anchor, axis) = (positionAnchor(line), direction(line))
      check anchor.isSome and axis.isSome
      check dot(anchor.get - ORIGIN, axis.get) =~ 0


  test "direction of line is unit and lies at its horizon":
    for line in LINES:
      let axis = direction(line)
      check axis.isSome
      check norm(axis.get) =~ 1.0
      check toMultivector(axis.get) ∧ line =~ 0


  test "frame of plane is orthonormal, inside plane, and normal to its normal":
    for plane in PLANES:
      let axes = frame(plane)
      check axes.isSome
      let (axis_first, axis_second, normal) =
        (axes.get.axis_first, axes.get.axis_second, axes.get.normal)
      check norm(axis_first) =~ 1.0
      check norm(axis_second) =~ 1.0
      check norm(normal) =~ 1.0
      check dot(axis_first, axis_second) =~ 0
      check dot(axis_first, normal) =~ 0
      check dot(axis_second, normal) =~ 0
      check toMultivector(axis_first) ∧ plane =~ 0
      check toMultivector(axis_second) ∧ plane =~ 0
      # Frame's own normal is the same one `directionNormal` derives independently.
      check normal =~ directionNormal(plane).get


  test "object at horizon yields no anchor":
    for line in LINES:
      let attitude = ⊖ line
      check attitude.isHorizon
      check positionAnchor(attitude).isNone
      check directionHorizon(attitude).isSome



suite "Camera":
  test "frame is orthonormal and perpendicular to sight axis":
    for i in 0 ..< SAMPLES:
      let camera = initCamera(
        target = PLACES[i],
        distance = 2.0 + rand(20.0),
        azimuth = rand(2.0*PI),
        elevation = rand(-1.4 .. 1.4),
      )
      let axes = camera.frame(camera.eye)
      check norm(axes.axis_right) =~ 1.0
      check norm(axes.axis_up) =~ 1.0
      check norm(axes.forward) =~ 1.0
      check dot(axes.axis_right, axes.axis_up) =~ 0
      check dot(axes.axis_right, axes.forward) =~ 0
      check dot(axes.axis_up, axes.forward) =~ 0
      check dot(axes.axis_up, UP_WORLD) > 0


  test "eye stands at orbit distance from target, and looks back at it":
    for i in 0 ..< SAMPLES:
      let camera = initCamera(
        target = PLACES[i], distance = 7.0, azimuth = rand(2.0*PI), elevation = rand(-1.4 .. 1.4)
      )
      check norm(camera.eye - camera.target) =~ camera.distance
      let heading = normalize(camera.target - camera.eye)
      check heading.isSome
      check dot(heading.get, camera.frame(camera.eye).forward) =~ 1.0


  test "view transform carries eye to origin and target down its own negative z":
    let camera = initCamera(
      target = Position(x: 1, y: -2, z: 0.5), distance = 9.0, azimuth = 0.7, elevation = 0.3
    )
    let view = initMatrixView(camera.eye, camera.frame(camera.eye))
    let (at_eye, at_target) = (
      transform(view, camera.eye, 1.0), transform(view, camera.target, 1.0)
    )
    check isNear(at_eye[0], 0) and isNear(at_eye[1], 0) and isNear(at_eye[2], 0)
    check isNear(at_target[0], 0) and isNear(at_target[1], 0)
    check isNear(at_target[2], -camera.distance)


  test "projection carries clip planes to depth bounds":
    const (NEAR, FAR) = (0.25, 60.0)
    let projection = initMatrixProjection(45.0, 1.6, NEAR, FAR)
    for (depth, expected) in [(NEAR, -1.0), (FAR, 1.0)]:
      let clipped = transform(projection, Position(x: 0, y: 0, z: -depth), 1.0)
      check isNear(clipped[3], depth)
      check isNear(clipped[2]/clipped[3], expected)


  test "whole transform carries target to centre of view":
    for i in 0 ..< SAMPLES:
      let camera = initCamera(
        target = PLACES[i], distance = 11.0, azimuth = rand(2.0*PI), elevation = rand(-1.2 .. 1.2)
      )
      let clipped = transform(camera.initMatrixViewProjection(1.6), camera.target, 1.0)
      check clipped[3] > 0
      check isNear(clipped[0]/clipped[3], 0)
      check isNear(clipped[1]/clipped[3], 0)



suite "Mesh":
  setup:
    MESHES.clearMeshes

  test "clearing drops every vertex":
    MESHES.addMarker(ORIGIN, Ink.Amber.colour)
    MESHES.addSegment(ORIGIN, PLACES[0], Ink.Cyan.colour)
    MESHES.clearMeshes
    for primitive in Primitive:
      check MESHES[primitive].count_vertices == 0


  test "point becomes one marker where it stands":
    for i in 0 ..< SAMPLES:
      MESHES.clearMeshes
      check MESHES.addObject(POINTS[i], Ink.Amber.colour) == Placement.Finite
      check MESHES[Primitive.Point].count_vertices == 1
      check MESHES[Primitive.Line].count_vertices == 0
      check isNear(MESHES[Primitive.Point].vertices[0].toPosition, PLACES[i])


  test "line becomes segment whose every vertex lies on it":
    for line in LINES:
      MESHES.clearMeshes
      check MESHES.addObject(line, Ink.Cyan.colour) == Placement.Finite
      check MESHES[Primitive.Line].count_vertices == 2
      check MESHES[Primitive.Point].count_vertices == 1
      # Vertex lies on line exactly when its offset from support runs along the direction,
      #   which holds when that offset's whole magnitude is accounted for along the axis.
      let (anchor, axis) = (positionAnchor(line), direction(line))
      check anchor.isSome and axis.isSome
      for i in 0 ..< MESHES[Primitive.Line].count_vertices:
        let offset = MESHES[Primitive.Line].vertices[i].toPosition - anchor.get
        check isNear(abs(dot(offset, axis.get)), norm(offset))


  test "plane becomes quad and grid whose every vertex lies on it":
    for plane in PLANES:
      MESHES.clearMeshes
      check MESHES.addObject(plane, Ink.Lime.colour) == Placement.Finite
      # Grid rules both ways across every cell boundary, then normal's arrow follows it.
      const
        VERTICES_GRID = 4*(2*CELLS_PLANE + 1)
        VERTICES_NORMAL = 2
      check MESHES[Primitive.Triangle].count_vertices == 6
      check MESHES[Primitive.Line].count_vertices == VERTICES_GRID + VERTICES_NORMAL
      # Vertex lies on plane exactly when its offset from support is normal to the normal.
      let (anchor, normal) = (positionAnchor(plane), directionNormal(plane))
      check anchor.isSome and normal.isSome
      for primitive in [Primitive.Triangle, Primitive.Line]:
        for i in 0 ..< MESHES[primitive].count_vertices:
          let at = MESHES[primitive].vertices[i].toPosition
          # Normal's own arrow leaves the plane, so it alone is expected to miss.
          if primitive == Primitive.Line and i >= VERTICES_GRID: continue
          check isNear(dot(at - anchor.get, normal.get), 0)


  test "object at horizon becomes arrow from origin":
    for line in LINES:
      MESHES.clearMeshes
      let attitude = ⊖ line
      check MESHES.addObject(attitude, Ink.Rose.colour) == Placement.Horizon
      check MESHES[Primitive.Line].count_vertices == 2
      check isNear(MESHES[Primitive.Line].vertices[0].toPosition, ORIGIN)


  test "multivector of no geometry becomes nothing at all":
    for empty in [1.0 ∧ initElement(Basis.scalar), 1.0 + POINTS[0]]:
      MESHES.clearMeshes
      check MESHES.addObject(empty, Ink.Amber.colour) == Placement.Empty
      for primitive in Primitive:
        check MESHES[primitive].count_vertices == 0


  test "world furniture stays within drawn extent":
    MESHES.addAxes
    MESHES.addGrid
    check MESHES[Primitive.Line].count_vertices > 0
    for i in 0 ..< MESHES[Primitive.Line].count_vertices:
      let at = MESHES[Primitive.Line].vertices[i].toPosition
      check max(abs(at.x), max(abs(at.y), abs(at.z))) <= float(EXTENT_WORLD) + TOLERANCE_TEST



suite "Scene":
  test "items are held in order added":
    var scene = initScene()
    for i in 0 ..< 5:
      scene.addItem(POINTS[i], "p" & $i, inkCycled(i))
    check scene.len == 5
    var count_seen = 0
    for item in scene:
      check item.geometry =~ POINTS[count_seen]
      check item.is_visible
      inc count_seen
    check count_seen == 5


  test "removeItem drops one slot without moving any other item":
    var scene = initScene()
    for i in 0 ..< 5:
      scene.addItem(POINTS[i], "p" & $i, inkCycled(i))
    scene.removeItem(2)
    check scene.len == 4
    check not scene.isAlive(2)
    for slot in [0, 1, 3, 4]:
      check scene.isAlive(slot)
      check scene[slot].geometry =~ POINTS[slot]


  test "freed slot is reused by the next addItem, most recently freed first":
    var scene = initScene()
    for i in 0 ..< 5:
      scene.addItem(POINTS[i], "p" & $i, inkCycled(i))
    scene.removeItem(2)
    scene.removeItem(0)
    check scene.addItem(POINTS[5 mod SAMPLES], "p5", Ink.Amber) == 0
    check scene.addItem(POINTS[6 mod SAMPLES], "p6", Ink.Amber) == 2


  test "scene drains to empty regardless of removal order":
    var scene = initScene()
    for i in 0 ..< 5:
      scene.addItem(POINTS[i], "p" & $i, inkCycled(i))
    for slot in [2, 0, 4, 1, 3]:
      scene.removeItem(slot)
    check scene.len == 0
    check not scene.isFull


  test "isAlive rejects a removed slot and any slot out of range":
    var scene = initScene()
    discard scene.addItem(POINTS[0], "a", Ink.Amber)
    check scene.isAlive(0)
    scene.removeItem(0)
    check not scene.isAlive(0)
    check not scene.isAlive(-1)
    check not scene.isAlive(ITEMS_MAX)


  test "scene fills to capacity and reports it":
    var scene = initScene()
    for i in 0 ..< ITEMS_MAX:
      check not scene.isFull
      scene.addItem(POINTS[i mod SAMPLES], "p", Ink.Amber)
    check scene.isFull
    check scene.len == ITEMS_MAX


  test "unary operations ignore their second operand":
    for operation in Operation:
      if lut_operation_to_arity[operation] != Arity.One: continue
      for i in 0 ..< SAMPLES:
        let (m, n, o) = (POINTS[i], LINES[i], PLANES[i])
        check applyOperation(operation, m, n) =~ applyOperation(operation, m, o)


  test "every operation names itself and is offered once":
    var seen: array[Operation, int]
    for operation in Operation:
      check len($lut_operation_to_notation[operation]) > 0
      inc seen[operation]
    for operation in Operation:
      check seen[operation] == 1
    check COUNT_OPERATION == ord(Operation.high) + 1


  test "join and meet recover the geometry they are named for":
    for i in 0 ..< SAMPLES:
      let
        j = (i + 1) mod SAMPLES
        line = applyOperation(Operation.Wedge, POINTS[i], POINTS[j])
        plane = applyOperation(Operation.Wedge, line, POINTS[(i + 2) mod SAMPLES])
        crossed = applyOperation(Operation.WedgeAnti, plane, PLANES[(i + 7) mod SAMPLES])
      check shape(line) == some(Shape.Line)
      check shape(plane) == some(Shape.Plane)
      check shape(crossed) == some(Shape.Line)
      # Both seed points must lie on the line joining them.
      check POINTS[i] ∧ line =~ 0
      check POINTS[j] ∧ line =~ 0


  test "orthogonal projection lands on the object projected onto":
    for i in 0 ..< SAMPLES:
      # Point must not be one of the three that built the plane, or it lies on it already.
      let
        plane = PLANES[i]
        point = POINTS[(i + 9) mod SAMPLES]
        projected = applyOperation(Operation.ProjectOrthogonal, point, plane)
      check shape(projected) == some(Shape.Point)
      let place = position(projected)
      check place.isSome
      check toMultivector(place.get) ∧ plane =~ 0


  test "labels truncate and stay terminated":
    var storage: Label
    toChars("short", storage)
    check $toCstring(storage) == "short"
    toChars('x'.repeat(LABEL_MAX*2), storage)
    check len($toCstring(storage)) == LABEL_MAX - 1


  test "multivectors print every term they carry, and nothing else":
    check formatMultivector(initElement(Basis.scalar, 0.0)) == "0 S"
    check formatMultivector(toMultivector(Position(x: 2, y: 0, z: -3))) ==
      "2.000 E1 - 3.000 E3 + 1.000 E4"
    for i in 0 ..< SAMPLES:
      check describeShape(POINTS[i]) == "point"
      check describeShape(LINES[i]) == "line"
      check describeShape(PLANES[i]) == "plane"
      # Attitude of a line is its direction, which is a point standing at the horizon.
      check describeShape(⊖ LINES[i]) == "point at horizon"
    check describeShape(1.0 + POINTS[0]) == "mixed grade, nothing to draw"



suite "Image":
  test "written file is a PNG carrying the size it was given":
    const (WIDTH, HEIGHT) = (37, 21)
    var pixels = newSeq[uint8](WIDTH*HEIGHT*3)
    for i in 0 ..< len(pixels): pixels[i] = uint8((i*7) mod 256)

    let path = getTempDir() / "visualiser_suite.png"
    writePng(path, WIDTH, HEIGHT, pixels)
    defer: removeFile(path)
    let document = readFile(path)

    check len(document) > 8
    check document[0 .. 7] == "\x89PNG\r\n\x1A\n"
    check document[12 .. 15] == "IHDR"
    check document[16 .. 19] == "\0\0\0" & char(WIDTH)
    check document[20 .. 23] == "\0\0\0" & char(HEIGHT)
    check document[24] == char(8) # Bit depth.
    check document[25] == char(2) # Colour type: truecolour.
    check document.find("IDAT") > 0
    check document[^8 .. ^5] == "IEND"


  test "chunk lengths and checksums agree end to end":
    const (WIDTH, HEIGHT) = (16, 9)
    var pixels = newSeq[uint8](WIDTH*HEIGHT*3)
    let path = getTempDir() / "visualiser_suite_chunks.png"
    writePng(path, WIDTH, HEIGHT, pixels)
    defer: removeFile(path)
    let document = readFile(path)

    # Walk chunks by their own lengths; landing exactly on the end proves each is sound.
    var
      offset = 8
      names: seq[string]
    while offset < len(document):
      var length = 0
      for i in 0 .. 3: length = length*256 + int(uint8(document[offset + i]))
      names.add(document[offset + 4 .. offset + 7])
      offset += 12 + length
    check offset == len(document)
    check names == @["IHDR", "IDAT", "IEND"]



suite "Picking":
  const (WIDTH_PICK, HEIGHT_PICK) = (800, 600)
  let CENTRE = ScreenPosition(x: float(WIDTH_PICK)/2.0, y: float(HEIGHT_PICK)/2.0, depth: 0.0)

  proc cameraFacingOrigin(distance = 10.0): Camera =
    ## Build camera looking at world origin, so target is known to project to screen centre.
    initCamera(
      target = Position(x: 0, y: 0, z: 0), distance = distance, azimuth = 0.0, elevation = 0.0
    )

  test "point at target is picked at screen centre":
    var scene = initScene()
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Amber)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(0)


  test "cursor far from every item picks nothing":
    var scene = initScene()
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Amber)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    let corner = ScreenPosition(x: 5.0, y: 5.0, depth: 0.0)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, corner).isNone


  test "hidden item is never picked":
    var scene = initScene()
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Amber)
    scene.isVisibleAt(0) = false
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE).isNone


  test "line through target is picked at screen centre":
    var scene = initScene()
    let axis_z =
      toMultivector(Position(x: 0, y: 0, z: -1)) ∧ toMultivector(Position(x: 0, y: 0, z: 1))
    scene.addItem(axis_z, "axis_z", Ink.Cyan)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(0)


  test "point wins a tie over a plane behind it":
    var scene = initScene()
    let facing = (
      toMultivector(Position(x: 0, y: -3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 0, z: 3))
    )
    scene.addItem(facing, "facing", Ink.Lime) # Index 0: plane, spans the view straight on.
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Amber) # Index 1: point.
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(1)


  test "plane misses where its sight ray lands outside the drawn quad":
    # Camera stands far enough back that the visible frustum, at the plane's own depth,
    #   spans wider than the fixed EXTENT_WORLD quad mesh actually draws -- so the window's
    #   own corners correspond to rays that land genuinely outside that quad, while the
    #   centre ray still lands on the support point well within it.
    var scene = initScene()
    let facing = (
      toMultivector(Position(x: 0, y: -3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 0, z: 3))
    )
    scene.addItem(facing, "facing", Ink.Lime)
    let camera = cameraFacingOrigin(distance = 30.0)
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(0)
    for (label, cx, cy) in [
      ("top-left corner", 0.0, 0.0),
      ("bottom-right corner", float(WIDTH_PICK), float(HEIGHT_PICK)),
    ]:
      let cursor = ScreenPosition(x: cx, y: cy, depth: 0.0)
      check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, cursor).isNone


  test "nearer plane wins over a farther one behind it":
    # Eye sits at (10, 0, 0) looking toward the origin along -x, so a plane at x=6 stands
    #   nearer the eye (distance 4) than one at x=3 (distance 7).
    var scene = initScene()
    let far_plane = (
      toMultivector(Position(x: 3, y: -3, z: -3)) ∧
      toMultivector(Position(x: 3, y: 3, z: -3)) ∧
      toMultivector(Position(x: 3, y: 0, z: 3))
    )
    let near_plane = (
      toMultivector(Position(x: 6, y: -3, z: -3)) ∧
      toMultivector(Position(x: 6, y: 3, z: -3)) ∧
      toMultivector(Position(x: 6, y: 0, z: 3))
    )
    scene.addItem(far_plane, "far", Ink.Lime) # Index 0.
    scene.addItem(near_plane, "near", Ink.Teal) # Index 1.
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(1)



suite "Interaction":
  test "drag operation maps to the catalogue entry it names":
    check DragOperation.Join.toOperation == Operation.Wedge
    check DragOperation.Meet.toOperation == Operation.WedgeAnti
    check DragOperation.Project.toOperation == Operation.ProjectOrthogonal


  test "drag applies its operation and appends the result":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Amber)
    scene.addItem(POINTS[1], "b", Ink.Amber)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    check interaction.beginDrag(DragOperation.Join)
    interaction.index_hover = some(1)
    let message = interaction.endDrag(scene)
    check scene.len == 3
    check scene[2].geometry =~ (POINTS[0] ∧ POINTS[1])
    check interaction.operation.isNone
    check "gave" in message


  test "drag cannot start without a hovered item":
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = none(int)
    check not interaction.beginDrag(DragOperation.Meet)
    check interaction.operation.isNone


  test "releasing over empty space adds nothing":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Amber)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(DragOperation.Join)
    interaction.index_hover = none(int)
    let message = interaction.endDrag(scene)
    check scene.len == 1
    check interaction.operation.isNone
    check "empty space" in message


  test "releasing on its own source adds nothing":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Amber)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(DragOperation.Meet)
    let message = interaction.endDrag(scene)
    check scene.len == 1
    check "own source" in message


  test "cancelDrag clears state without applying anything":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Amber)
    scene.addItem(POINTS[1], "b", Ink.Amber)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(DragOperation.Project)
    interaction.cancelDrag()
    check interaction.operation.isNone
    check scene.len == 2


  test "endDrag with nothing dragging is a harmless no-op":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Amber)
    var interaction = Interaction(is_enabled: true)
    check interaction.endDrag(scene) == ""
    check scene.len == 1


  test "disabled interaction never hovers":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Amber)
    var interaction = Interaction(is_enabled: false)
    let camera = initCamera(target = PLACES[0], distance = 10.0, azimuth = 0.0, elevation = 0.0)
    interaction.updateCursor(400.0, 300.0)
    interaction.updateHover(scene, camera, camera.initMatrixViewProjection(800.0/600.0), 800, 600)
    check interaction.index_hover.isNone


  test "enabled interaction hovers the item under the cursor":
    var scene = initScene()
    let target = Position(x: 0, y: 0, z: 0)
    scene.addItem(toMultivector(target), "p", Ink.Amber)
    var interaction = Interaction(is_enabled: true)
    let camera = initCamera(target = target, distance = 10.0, azimuth = 0.0, elevation = 0.0)
    interaction.updateCursor(400.0, 300.0)
    interaction.updateHover(scene, camera, camera.initMatrixViewProjection(800.0/600.0), 800, 600)
    check interaction.index_hover == some(0)
