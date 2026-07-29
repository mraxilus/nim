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

import std/[math, options, os, random, strformat, strutils, tables, unittest]

import ../../pga
import ../../visualiser/[
  arena, camera, format, gif, image, interaction, mesh, objects, picking, scene,
]

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


proc formatMultivectorString(m: Multivector): string =
  ## Format into a stack buffer exactly as the panel does, then read it back as a
  ## `string` a test can compare against; production code never takes this last step.
  var
    buffer: array[128, char]
    cursor = 0
  formatMultivector(m, buffer, cursor)
  finishChars(buffer, cursor)
  $toCstring(buffer)


proc describeShapeString(m: Multivector): string =
  ## Format into a stack buffer exactly as the panel does; see `formatMultivectorString`.
  var
    buffer: array[32, char]
    cursor = 0
  describeShape(m, buffer, cursor)
  finishChars(buffer, cursor)
  $toCstring(buffer)



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
  let SCALE_TEST = DrawExtent(
    extent_furniture: 30.0,
    eye: Position(x: 5, y: -3, z: 7), radius_horizon: 50.0
  ) ## Eye held off-origin deliberately: horizon geometry anchored to the origin by
    ## mistake, instead of to `eye`, would fail every horizon check below.
    ##   `extent_furniture` held distinct from `EXTENT_PLANE_F` (a plane's own fixed
    ##   radius, no longer part of `DrawExtent` at all), so a line test checking against
    ##   the wrong one of the two would fail rather than pass by coincidence.
    ##   Radius held modest rather than close to a real far clip distance (hundreds of
    ##   units): vertices round-trip through `Vertex`'s own `float32` storage, and
    ##   `isNear`'s tolerance is calibrated for coordinates near the same scale every
    ##   other geometry test in this suite uses, not for the additional rounding a much
    ##   larger radius would carry through unrelated to anything this suite tests here.

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
      check MESHES.addObject(POINTS[i], Ink.Amber.colour, SCALE_TEST) == Placement.Finite
      check MESHES[Primitive.Point].count_vertices == 1
      check MESHES[Primitive.Line].count_vertices == 0
      check isNear(MESHES[Primitive.Point].vertices[0].toPosition, PLACES[i])


  test "line becomes segment whose every vertex lies on it":
    for line in LINES:
      MESHES.clearMeshes
      check MESHES.addObject(line, Ink.Cyan.colour, SCALE_TEST) == Placement.Finite
      check MESHES[Primitive.Line].count_vertices == 2
      check MESHES[Primitive.Point].count_vertices == 1
      # Vertex lies on line exactly when its offset from support runs along the direction,
      #   which holds when that offset's whole magnitude is accounted for along the axis.
      let (anchor, axis) = (positionAnchor(line), direction(line))
      check anchor.isSome and axis.isSome
      for i in 0 ..< MESHES[Primitive.Line].count_vertices:
        let offset = MESHES[Primitive.Line].vertices[i].toPosition - anchor.get
        check isNear(abs(dot(offset, axis.get)), norm(offset))


  test "plane becomes a flat filled disc and a rim, every vertex on it":
    for plane in PLANES:
      MESHES.clearMeshes
      check MESHES.addObject(plane, Ink.Lime.colour, SCALE_TEST) == Placement.Finite
      const
        VERTICES_FILL = 3*SEGMENTS_CIRCLE_HORIZON ## Fan: centre, two rim points each.
        VERTICES_RING = 2*SEGMENTS_CIRCLE_HORIZON
        VERTICES_NORMAL = 2
      check MESHES[Primitive.Triangle].count_vertices == VERTICES_FILL
      check MESHES[Primitive.Line].count_vertices == VERTICES_RING + VERTICES_NORMAL
      # No point marker at all: neither an anchor marker nor a normal arrowhead, so a
      #   plane never adds a scattered dot beyond what the fill, rim and shaft already
      #   draw.
      check MESHES[Primitive.Point].count_vertices == 0
      # Vertex lies on plane exactly when its offset from support is normal to the normal.
      let (anchor, normal) = (positionAnchor(plane), directionNormal(plane))
      check anchor.isSome and normal.isSome
      for i in 0 ..< VERTICES_FILL:
        let vertex = MESHES[Primitive.Triangle].vertices[i]
        check isNear(dot(vertex.toPosition - anchor.get, normal.get), 0)
        check isNear(float(vertex.alpha), ALPHA_WASH)
        # Every fill vertex is either the fan's own centre or out at the plane's own
        #   fixed radius -- flat alpha throughout, so unlike the old fading disc there
        #   is no band strictly between the two to rule out.
        let radius_vertex = norm(vertex.toPosition - anchor.get)
        check isNear(radius_vertex, 0) or isNear(radius_vertex, EXTENT_PLANE_F)
      for i in 0 ..< VERTICES_RING:
        let vertex = MESHES[Primitive.Line].vertices[i]
        check isNear(dot(vertex.toPosition - anchor.get, normal.get), 0)
        check isNear(float(vertex.alpha), Ink.Lime.colour.alpha)
        check isNear(norm(vertex.toPosition - anchor.get), EXTENT_PLANE_F)


  test "point at horizon becomes a star fixed at eye plus its own direction":
    for line in LINES:
      MESHES.clearMeshes
      let attitude = ⊖ line
      check MESHES.addObject(attitude, Ink.Rose.colour, SCALE_TEST) == Placement.Horizon
      check MESHES[Primitive.Point].count_vertices == 1
      let
        heading = directionHorizon(attitude)
        star = MESHES[Primitive.Point].vertices[0].toPosition
      check heading.isSome
      check isNear(star, SCALE_TEST.eye + SCALE_TEST.radius_horizon*heading.get)


  test "line at horizon becomes a great circle around eye, perpendicular to its normal":
    for plane in PLANES:
      MESHES.clearMeshes
      let attitude = ⊖ plane
      check MESHES.addObject(attitude, Ink.Cyan.colour, SCALE_TEST) == Placement.Horizon
      check MESHES[Primitive.Line].count_vertices == 2*SEGMENTS_CIRCLE_HORIZON
      # `directionNormalHorizon` reads straight off the horizon line's own raw
      #   coefficients; confirm it agrees with the finite plane's own normal, read
      #   through a wholly different pair of library operators, before trusting either
      #   to check where the circle itself landed.
      let
        normal_from_plane = directionNormal(plane)
        normal_from_horizon = directionNormalHorizon(attitude)
      check normal_from_plane.isSome and normal_from_horizon.isSome
      check normal_from_plane.get =~ normal_from_horizon.get
      for i in 0 ..< MESHES[Primitive.Line].count_vertices:
        let
          vertex = MESHES[Primitive.Line].vertices[i].toPosition
          offset = vertex - SCALE_TEST.eye
        check isNear(norm(offset), SCALE_TEST.radius_horizon)
        check isNear(dot(offset, normal_from_plane.get), 0)


  test "plane at horizon becomes a dome over the whole sky around eye":
    # Every plane at horizon is the same universal object regardless of source (see
    #   `objects.directionNormalHorizon`'s own doc comment), so two unrelated planes'
    #   own attitudes should both land the dome at exactly the same distance from eye,
    #   with nothing about either plane's own coefficients read to decide it.
    #   Attitude of a plane (grade 3) gives a line at horizon, not a plane: reaching a
    #   plane at horizon needs a grade-4 volume first, built here from a point wedged
    #   with an unrelated plane it does not lie on.
    let
      volume_first = POINTS[10] ∧ PLANES[0]
      volume_second = POINTS[20] ∧ PLANES[7]
      attitude_first = ⊖ volume_first
      attitude_second = ⊖ volume_second
    check shape(attitude_first) == some(Shape.Plane) and isHorizon(attitude_first)
    check shape(attitude_second) == some(Shape.Plane) and isHorizon(attitude_second)

    check MESHES.addObject(attitude_first, Ink.Teal.colour, SCALE_TEST) == Placement.Horizon
    check MESHES[Primitive.Triangle].count_vertices == 6*LATITUDES_HORIZON*LONGITUDES_HORIZON
    let vertices_first = MESHES[Primitive.Triangle].vertices
    for i in 0 ..< MESHES[Primitive.Triangle].count_vertices:
      let offset = vertices_first[i].toPosition - SCALE_TEST.eye
      check isNear(norm(offset), SCALE_TEST.radius_horizon)

    MESHES.clearMeshes
    check MESHES.addObject(attitude_second, Ink.Teal.colour, SCALE_TEST) == Placement.Horizon
    check MESHES[Primitive.Triangle].count_vertices == 6*LATITUDES_HORIZON*LONGITUDES_HORIZON
    # Same dome, vertex for vertex, regardless of which unrelated volume produced it.
    for i in 0 ..< MESHES[Primitive.Triangle].count_vertices:
      check isNear(MESHES[Primitive.Triangle].vertices[i].toPosition, vertices_first[i].toPosition)


  test "multivector of no geometry becomes nothing at all":
    for empty in [1.0 ∧ initElement(Basis.scalar), 1.0 + POINTS[0]]:
      MESHES.clearMeshes
      check MESHES.addObject(empty, Ink.Amber.colour, SCALE_TEST) == Placement.Empty
      for primitive in Primitive:
        check MESHES[primitive].count_vertices == 0


  test "world furniture stays within its own, separately tracked extent":
    MESHES.addAxes(SCALE_TEST.extent_furniture)
    MESHES.addGrid(SCALE_TEST.extent_furniture)
    check MESHES[Primitive.Line].count_vertices > 0
    for i in 0 ..< MESHES[Primitive.Line].count_vertices:
      let at = MESHES[Primitive.Line].vertices[i].toPosition
      check max(abs(at.x), max(abs(at.y), abs(at.z))) <=
        SCALE_TEST.extent_furniture + TOLERANCE_TEST


  test "ground grid holds full alpha near the origin and fades toward its own reach":
    MESHES.clearMeshes
    MESHES.addGrid(SCALE_TEST.extent_furniture)
    let radius_fade_start = FRACTION_GRID_FADE_START*SCALE_TEST.extent_furniture
    var
      alpha_near_min = 1.0
      alpha_far_max = 0.0
    for i in 0 ..< MESHES[Primitive.Line].count_vertices:
      let
        vertex = MESHES[Primitive.Line].vertices[i]
        radius = norm(vertex.toPosition - ORIGIN)
      if radius <= radius_fade_start:
        alpha_near_min = min(alpha_near_min, float(vertex.alpha))
      if radius >= SCALE_TEST.extent_furniture - TOLERANCE_TEST:
        alpha_far_max = max(alpha_far_max, float(vertex.alpha))
    check isNear(alpha_near_min, Ink.Grid.colour.alpha)
    check alpha_far_max <= TOLERANCE_SINGLE


  test "radiusHorizonFor scales with the camera's own far clip distance":
    check radiusHorizonFor(400.0) =~ 400.0*FRACTION_HORIZON


  test "extentFurnitureFor scales with the camera's own far clip distance":
    check extentFurnitureFor(400.0) =~ 400.0*FRACTION_FURNITURE



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
    check formatMultivectorString(initElement(Basis.scalar, 0.0)) == "0 S"
    check formatMultivectorString(toMultivector(Position(x: 2, y: 0, z: -3))) ==
      "2.000 E1 - 3.000 E3 + 1.000 E4"
    for i in 0 ..< SAMPLES:
      check describeShapeString(POINTS[i]) == "point"
      check describeShapeString(LINES[i]) == "line"
      check describeShapeString(PLANES[i]) == "plane"
      # Attitude of a line is its direction, which is a point standing at the horizon.
      check describeShapeString(⊖ LINES[i]) == "point at horizon"
    check describeShapeString(1.0 + POINTS[0]) == "mixed grade, nothing to draw"


  test "save then load reproduces every live item, compacting freed slots":
    var original = initScene()
    discard original.addItem(POINTS[0], "a", Ink.Amber)
    discard original.addItem(POINTS[1], "bb", Ink.Cyan)
    let slot_doomed = original.addItem(POINTS[2], "doomed", Ink.Lime)
    original.removeItem(slot_doomed) # leaves a hole a fresh load must not reproduce
    let slot_last = original.addItem(POINTS[3], "d", Ink.Violet)
    original.isVisibleAt(slot_last) = false

    let path = getTempDir() / "visualiser_suite_scene.rgascene"
    check saveScene(original, path).contains("Saved 3")
    defer: removeFile(path)

    var loaded = initScene()
    discard loaded.addItem(POINTS[9], "stale", Ink.Teal) # load must replace, not merge
    check loadScene(loaded, path).contains("Loaded 3")
    check loaded.len == 3

    # Freed slot 2 is compacted away: loaded items land at slots 0, 1, 2 in save order.
    check loaded[0].geometry =~ POINTS[0]
    check $toCstring(loaded[0].label) == "a"
    check loaded[0].ink == Ink.Amber
    check loaded[0].is_visible
    check loaded[0].born == 0.0 # dawn of time, not mid-appear-in-animation

    check loaded[1].geometry =~ POINTS[1]
    check $toCstring(loaded[1].label) == "bb"
    check loaded[1].ink == Ink.Cyan
    check loaded[1].is_visible

    check loaded[2].geometry =~ POINTS[3]
    check $toCstring(loaded[2].label) == "d"
    check loaded[2].ink == Ink.Violet
    check not loaded[2].is_visible


  test "empty scene round-trips":
    let original = initScene()
    let path = getTempDir() / "visualiser_suite_scene_empty.rgascene"
    check saveScene(original, path).contains("Saved 0")
    defer: removeFile(path)

    var loaded = initScene()
    discard loaded.addItem(POINTS[0], "will be cleared", Ink.Amber)
    check loadScene(loaded, path).contains("Loaded 0")
    check loaded.len == 0


  test "loading a foreign file leaves scene untouched and reports why":
    var scene = initScene()
    discard scene.addItem(POINTS[0], "keep", Ink.Amber)
    let path = getTempDir() / "visualiser_suite_scene_bogus.rgascene"
    writeFile(path, "not a scene file at all")
    defer: removeFile(path)

    check loadScene(scene, path).contains("not a scene file")
    check scene.len == 1
    check $toCstring(scene[0].label) == "keep"


  test "loading a file saved under a different PGA dimension is rejected":
    var scene = initScene()
    discard scene.addItem(POINTS[0], "keep", Ink.Amber)
    let path = getTempDir() / "visualiser_suite_scene_wrongbasis.rgascene"
    writeFile(path, "RGAS" & char(1) & char(99)) # no build here carries 99 basis terms
    defer: removeFile(path)

    check loadScene(scene, path).contains("different PGA dimension")
    check scene.len == 1


  test "loading a missing path reports cleanly and leaves scene untouched":
    var scene = initScene()
    discard scene.addItem(POINTS[0], "keep", Ink.Amber)
    let path = getTempDir() / "visualiser_suite_scene_does_not_exist.rgascene"

    check loadScene(scene, path).contains("No such file")
    check scene.len == 1


  test "loading a file naming more items than this build's capacity is rejected":
    var scene = initScene()
    discard scene.addItem(POINTS[0], "keep", Ink.Amber)

    var
      count = uint32(ITEMS_MAX + 1)
      count_bytes = newString(4)
    copyMem(addr count_bytes[0], addr count, 4)
    let path = getTempDir() / "visualiser_suite_scene_toobig.rgascene"
    writeFile(path, "RGAS" & char(1) & char(ord(Basis.high) + 1) & count_bytes)
    defer: removeFile(path)

    check loadScene(scene, path).contains("more than")
    check scene.len == 1



suite "Image":
  var buffer_arena: array[1024*1024, byte]

  test "written file is a PNG carrying the size it was given":
    const (WIDTH, HEIGHT) = (37, 21)
    var pixels = newSeq[uint8](WIDTH*HEIGHT*3)
    for i in 0 ..< len(pixels): pixels[i] = uint8((i*7) mod 256)

    var test_arena = initArena(buffer_arena)
    let path = getTempDir() / "visualiser_suite.png"
    writePng(test_arena, path, WIDTH, HEIGHT, pixels)
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
    var test_arena = initArena(buffer_arena)
    let path = getTempDir() / "visualiser_suite_chunks.png"
    writePng(test_arena, path, WIDTH, HEIGHT, pixels)
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



suite "Gif":
  var buffer_arena: array[1024*1024, byte]

  test "written file carries the size and frame count it was given":
    const (WIDTH, HEIGHT) = (12, 8)
    var frames = newSeq[uint8](3*WIDTH*HEIGHT*3)
    var test_arena = initArena(buffer_arena)
    let path = getTempDir() / "visualiser_suite.gif"
    writeGif(test_arena, path, WIDTH, HEIGHT, frames, 3, 8)
    defer: removeFile(path)
    let document = readFile(path)

    check document[0 .. 5] == "GIF89a"
    check uint8(document[6]) == uint8(WIDTH) and uint8(document[7]) == 0
    check uint8(document[8]) == uint8(HEIGHT) and uint8(document[9]) == 0
    check document[^1] == char(0x3B)

    # Walk every frame's own blocks by their own lengths, landing exactly on the
    #   trailer proves each frame's sub-blocks are sound, exactly as the PNG test does.
    const HEADER_LEN = 6 + 7 + 256*3 + 19 # Signature, logical screen, colour table, app extension.
    var
      offset = HEADER_LEN
      count_frames = 0
    while document[offset] == '\x21':
      offset += 8 # Graphic Control Extension is fixed length.
      check document[offset] == '\x2C' # Image Descriptor.
      offset += 10 + 1 # Image Descriptor fields, then the LZW minimum code size byte.
      while true:
        let length = int(uint8(document[offset]))
        offset += 1
        if length == 0: break
        offset += length
      inc count_frames
    check count_frames == 3
    check offset == len(document) - 1
    check document[offset] == char(0x3B)


  proc decodeGifFrame(data: seq[uint8]): seq[uint8] =
    ## Decode one frame's own LZW sub-block stream back to palette indices, by exactly
    ## the algorithm any GIF89a reader implements -- mirroring `gif.nim`'s encoder, not
    ## calling into it, so this stands as an independent check of what it wrote.
    ##   Widens its own code width one step earlier than the encoder does: GIF's LZW
    ##   is asymmetric here by design ("early change"), since the decoder's dictionary
    ##   always trails the encoder's by the one entry it has not yet been told about.
    const
      BITS_CODE = 8
      COUNT_TABLE = 1 shl BITS_CODE
      CODE_CLEAR = COUNT_TABLE
      CODE_END = CODE_CLEAR + 1
      CODE_MAX = 4096
    var
      pos_bit = 0
      dict: Table[int, seq[uint8]]
      next_code = CODE_END + 1
      width = BITS_CODE + 1
      prev: seq[uint8]
      has_prev = false

    proc readCode(width: int): int =
      for i in 0 ..< width:
        let (byte_index, bit_index) = ((pos_bit + i) div 8, (pos_bit + i) mod 8)
        if byte_index < len(data):
          result = result or (int((data[byte_index].int shr bit_index) and 1) shl i)
      pos_bit += width

    while true:
      let code = readCode(width)
      if code == CODE_CLEAR:
        dict.clear()
        next_code = CODE_END + 1
        width = BITS_CODE + 1
        has_prev = false
        continue
      if code == CODE_END: break

      var entry: seq[uint8]
      if code < COUNT_TABLE: entry = @[uint8(code)]
      elif dict.hasKey(code): entry = dict[code]
      elif code == next_code and has_prev: entry = prev & @[prev[0]]
      else: doAssert false, &"Bad LZW code {code}."
      result.add(entry)
      if has_prev and next_code < CODE_MAX:
        dict[next_code] = prev & @[entry[0]]
        inc next_code
        if next_code >= (1 shl width) and width < 12: inc width
      prev = entry
      has_prev = true


  test "written frame decodes back to what it was quantized to, past a code-width growth":
    ## Regression test for a real bug: growing the LZW code width one symbol too early
    ##   packed bits a real reader disagreed with, corrupting every code from there on.
    ##   A flat or small image never reaches the dictionary sizes where that bites, so
    ##   this drives enough distinct colour pairs to grow the code width at least once.
    const (WIDTH, HEIGHT) = (64, 64)
    var frame = newSeq[uint8](WIDTH*HEIGHT*3)
    for i in 0 ..< WIDTH*HEIGHT:
      frame[i*3] = uint8((i*173) mod 256)
      frame[i*3 + 1] = uint8((i*97) mod 256)
      frame[i*3 + 2] = uint8((i*211) mod 256)

    # `writeGif` takes rows bottom-up and writes them top-down, exactly as `writePng`
    #   does; build the expected indices in that same written order, not the source's.
    var expected: seq[uint8]
    for row_top in 0 ..< HEIGHT:
      let row_source = HEIGHT - 1 - row_top
      for column in 0 ..< WIDTH:
        let at = (row_source*WIDTH + column)*3
        expected.add(paletteIndex(frame[at], frame[at + 1], frame[at + 2]))

    var test_arena = initArena(buffer_arena)
    let path = getTempDir() / "visualiser_suite_growth.gif"
    writeGif(test_arena, path, WIDTH, HEIGHT, frame, 1, 8)
    defer: removeFile(path)
    let document = readFile(path)

    const HEADER_LEN = 6 + 7 + 256*3 + 19
    var offset = HEADER_LEN + 8 + 10 # Past Graphic Control Extension and Image Descriptor.
    let width_code = uint8(document[offset])
    check width_code == 8
    offset += 1

    var sub_blocks: seq[uint8]
    while true:
      let length = int(uint8(document[offset]))
      offset += 1
      if length == 0: break
      for i in 0 ..< length: sub_blocks.add(uint8(document[offset + i]))
      offset += length

    let decoded = decodeGifFrame(sub_blocks)
    check len(decoded) == WIDTH*HEIGHT
    check decoded == expected



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


  test "plane misses where its sight ray lands outside the drawn rim":
    # A window corner is the widest angle any ray reaches, off the sight axis, and the
    #   camera stands far enough back (30 units, against an `EXTENT_PLANE_F` of 8) that
    #   a corner ray's own diagonal reach lands well outside the drawn rim's fixed
    #   radius regardless of how far back the camera stands, while the centre ray still
    #   lands on the support point well within it.
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
