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

import std/[math, options, os, random, strformat, strutils, tables, unicode, unittest]

import ../../pga
import ../../visualiser/core/[
  boundary, camera, format, framing, help, history, interaction, picking, scene,
  selection, storyboard, tessellate,
]
# The arena, the PNG encoder and the GIF encoder are desktop-only: each binds a C entry
#   point the JS backend has none of. Their own suites are guarded to match, below.
#   `std/endians` joins them because only the desktop cases build scene-file bytes by
#   hand, and they write the format's own byte order rather than the host's.
when not defined(js):
  import std/endians
  import ../../visualiser/desktop/[arena, gif, image]
# `{.all.}` so the suite can check `marker`'s own private helpers directly rather than
#   only through the markers they end up shaping -- `directionAcross` is the whole of why
#   a line's rails converge, and is worth asserting on its own terms.
import ../../visualiser/core/marker {.all.}

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

const COUNT_GENERAL = 12
  ## Points enough for two disjoint families of one point, one line and one plane.

func generalPlace(index: int): Position =
  ## Place one of a family of points in **general position**: no three collinear and no
  ## four coplanar, so a shape built from any of them is incident with none of the rest.
  ##   Read off the moment curve (t, t², t³), where that is a theorem rather than a hope:
  ##   the 4x4 matrix of (1, t, t², t³) over four distinct parameters is Vandermonde and
  ##   so never singular. Scaled to the extent the rest of the suite works at.
  let t = -1.1 + 0.2*float(index)
  Position(x: 4.0*t, y: 4.0*t*t, z: 4.0*t*t*t)

var
  GENERAL_POINTS: array[COUNT_GENERAL, Multivector]
  GENERAL_FIRST: array[3, Multivector] ## Point, line, plane, in grade order.
  GENERAL_SECOND: array[3, Multivector] ## A second such triple, sharing no point with the
    ## first -- so a test walking every ordered pair of shapes crosses two *different*
    ## objects even on the diagonal.
    ##   Kept separate from `POINTS`/`LINES`/`PLANES` above, which are random and whose
    ## `LINES[i]` is built out of neighbouring `POINTS`, so every one of them lies on
    ## points the suite would otherwise pair it against. A first measurement of the drag
    ## proposal table did exactly that -- crossed a point with a line running through it,
    ## and read zeros that came from the fixture rather than from the algebra. Two
    ## families in general position are what make a zero here mean something.
for i in 0 ..< COUNT_GENERAL:
  GENERAL_POINTS[i] = toMultivector(generalPlace(i))
GENERAL_FIRST = [
  GENERAL_POINTS[0],
  GENERAL_POINTS[1] ∧ GENERAL_POINTS[2],
  GENERAL_POINTS[3] ∧ GENERAL_POINTS[4] ∧ GENERAL_POINTS[5],
]
GENERAL_SECOND = [
  GENERAL_POINTS[6],
  GENERAL_POINTS[7] ∧ GENERAL_POINTS[8],
  GENERAL_POINTS[9] ∧ GENERAL_POINTS[10] ∧ GENERAL_POINTS[11],
]

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
  toText(buffer)


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


  test "the incidence vocabulary answers what the classical forms answer, sign included":
    # The classical forms live HERE, in the test, and the algebra lives in `objects.nim`
    #   -- holding the two equal is the project's purpose, and it is also what pins every
    #   sign and argument order before anything downstream leans on them. A deterministic
    #   scatter, so a failure names the same case on every run.
    var seed = 3.0
    proc pseudo(): float =
      seed = (seed*97.31 + 33.77) mod 41.0
      seed - 20.5
    proc somewhere(): Position =
      Position(x: pseudo(), y: pseudo(), z: pseudo())
    proc someway(): Direction =
      var d = Direction(x: 0, y: 0, z: 0)
      while norm(d) < 0.1: d = Direction(x: pseudo(), y: pseudo(), z: pseudo())
      normalize(d).get

    # The one fixed pin first: a point one unit along a plane's own construction
    #   direction reads exactly +1 -- `plane ∨ point`, in that order; the other order
    #   negates and must not be what ships.
    let plane_pin = planeThrough(
      toMultivector(Position(x: 0, y: 0, z: 2)),
      toMultivector(Direction(x: 0, y: 0, z: 1)),
    )
    check depthAgainst(plane_pin, toMultivector(Position(x: 0, y: 0, z: 3))) =~ 1.0
    check depthAgainst(plane_pin, toMultivector(Position(x: 0, y: 0, z: 2))) =~ 0.0
    check depthAgainst(plane_pin, toMultivector(Position(x: 5, y: -4, z: 1))) =~ -1.0
    # A doubled construction direction must change nothing: `planeThrough` unitizes, so
    #   the depth read is metric whatever length the caller's direction happened to have.
    let plane_doubled = planeThrough(
      toMultivector(Position(x: 0, y: 0, z: 2)),
      toMultivector(Direction(x: 0, y: 0, z: 2)),
    )
    check depthAgainst(plane_doubled, toMultivector(Position(x: 0, y: 0, z: 3))) =~ 1.0

    for trial in 0 ..< 100:
      let
        at = somewhere()
        along = someway()
        probe = somewhere()
        other = somewhere()
      # `depthAgainst` a `planeThrough` is the classical signed distance along the normal.
      check depthAgainst(
        planeThrough(toMultivector(at), toMultivector(along)), toMultivector(probe)
      ) =~ dot(probe - at, along)
      # `distanceBetween` is the classical Euclidean distance.
      check distanceBetween(toMultivector(probe), toMultivector(other)) =~
        norm(probe - other)

    # The two ground spellings agree with each other and with what "ground" means.
    check depthAgainst(groundPlane(), toMultivector(Position(x: 3, y: -8, z: 5.5))) =~ 5.5
    let level = levelPlaneThrough(toMultivector(Position(x: 1, y: 2, z: 4)))
    check depthAgainst(level, toMultivector(Position(x: -9, y: 6, z: 7))) =~ 3.0

    # The centroid, folded one place at a time, against the mean written out here. A sum
    #   of unit-weight points carries weight n and the total of the coordinates, so the
    #   division `position` already does *is* the averaging -- which is the claim.
    let places = [
      Position(x: 3.0, y: -1.0, z: 2.0), Position(x: -5.0, y: 4.0, z: 0.5),
      Position(x: 1.0, y: 9.0, z: -3.5), Position(x: 8.0, y: -2.0, z: 6.0),
    ]
    # The fold starts from the first point itself -- one place is its own middle -- and
    #   carries the running sum as a multivector, so nothing has to be told the count.
    var middle = toMultivector(places[0])
    check position(middle).get =~ places[0]
    for counted in 1 .. places.high:
      middle = centroidFolded(middle, toMultivector(places[counted]))
      var (sum_x, sum_y, sum_z) = (0.0, 0.0, 0.0)
      for i in 0 .. counted:
        sum_x += places[i].x
        sum_y += places[i].y
        sum_z += places[i].z
      # Every prefix, not only the whole: an incremental fold that is right at the end and
      #   wrong halfway is right by luck, and the camera reads it at every length.
      check position(middle).get =~ Position(
        x: sum_x/float(counted + 1), y: sum_y/float(counted + 1), z: sum_z/float(counted + 1)
      )
      # And the sum's own weight *is* how many places it is the middle of -- which is what
      #   lets the running total stand in for a count nobody carries.
      check middle[Basis.E4] =~ float(counted + 1)



suite "Camera":
  test "the eye assembled through the algebra is the eye the trig names":
    # `camera.eye` places the point as a multivector sum; the spherical closed form lives
    #   HERE. The angles are parametrization -- what is checked is the placement.
    var seed = 27.0
    proc pseudo(): float =
      seed = (seed*97.31 + 33.77) mod 41.0
      seed - 20.5
    for trial in 0 ..< 100:
      let
        target = Position(x: pseudo(), y: pseudo(), z: pseudo())
        distance = 1.0 + abs(pseudo())
        azimuth = pseudo()/7.0
        elevation = pseudo()/20.0
        camera = initCamera(target, distance, azimuth, elevation)
        radius = distance*cos(camera.elevation)
        classical = target + Direction(
          x: radius*cos(camera.azimuth), y: radius*sin(camera.azimuth),
          z: distance*sin(camera.elevation),
        )
      check camera.eye =~ classical


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


  test "the clip planes follow the orbit distance, rather than where they were built":
    # The bug this guards: the pair was stored at construction and kept its value through
    #   every dolly, so the far plane sat at a fixed 400 while the orbit could reach 500 --
    #   dollying past it clipped the whole scene away, and well before that a line's own far
    #   end came back inside the frame and read as stopping in mid-air. Deriving both is
    #   also what let the orbit ceiling go, so this is load-bearing twice over.
    var camera = initCameraDefault()
    let (near_opened, far_opened) = (camera.distanceNear, camera.distanceFar)
    camera.dolly(4.0)
    check camera.distanceNear =~ 4.0*near_opened
    check camera.distanceFar =~ 4.0*far_opened
    # Scaled together, so the frustum keeps its shape and the depth buffer its precision --
    #   a function of the far-to-near ratio -- however far the camera stands.
    check camera.distanceFar/camera.distanceNear =~ far_opened/near_opened


  test "an orbit distance has a floor and no ceiling":
    # The floor is geometry: at zero the eye coincides with its target and every direction
    #   derived from the line joining them collapses. The ceiling was a round number, and
    #   a reader who dollied out to look at something a kilometre across simply stopped.
    check distanceHeld(0.0) =~ DISTANCE_LIMIT_NEAR
    check distanceHeld(-5.0) =~ DISTANCE_LIMIT_NEAR
    for distance in [1.0, 500.0, 5_000.0, 1.0e6]:
      check distanceHeld(distance) =~ distance
      check initCamera(ORIGIN, distance, 0.7, 0.3).distance =~ distance

    # Holding the dolly out walks straight past where the limit used to sit.
    var camera = initCameraDefault()
    for _ in 1 .. 6: camera.dolly(FACTOR_DOLLY_SECOND)
    check camera.distance > 5_000.0


  test "the camera still derives a frame and a transform a thousand kilometres out":
    # Nothing downstream of the distance has a ceiling of its own: both clip planes are
    #   fractions of it, so the frustum keeps its shape however far the eye stands.
    let camera = initCamera(target = ORIGIN, distance = 1.0e6, azimuth = 0.9, elevation = 0.4)
    check camera.distance =~ 1.0e6
    let axes = camera.frame(camera.eye)
    check isNear(norm(axes.axis_right), 1.0)
    check isNear(norm(axes.axis_up), 1.0)
    check isNear(norm(axes.forward), 1.0)
    check camera.distanceNear > 0.0
    check camera.distanceFar > camera.distanceNear
    let clipped = transform(camera.initMatrixViewProjection(1.6), camera.target, 1.0)
    check clipped[3] > 0
    check isNear(clipped[0]/clipped[3], 0)
    check isNear(clipped[1]/clipped[3], 0)


  test "a zoom aimed at the cursor keeps what is under it under it":
    # The map reading of a wheel: the reader points at something and arrives there, rather
    #   than zooming at the middle of the frame and panning afterwards. Checked where it
    #   has to hold -- in pixels, against the transform the frame is actually drawn with.
    const (WIDTH_ZOOM, HEIGHT_ZOOM) = (1440, 900)
    for cursor in [
      ScreenPosition(x: 200.0, y: 700.0), ScreenPosition(x: 1300.0, y: 120.0),
      ScreenPosition(x: 720.0, y: 450.0),
    ]:
      for factor in [0.5, 2.0]:
        var camera = initCameraDefault()
        let anchor = positionUnderCursor(camera, WIDTH_ZOOM, HEIGHT_ZOOM, cursor)
        check anchor.isSome
        let before = projectToScreen(
          camera.initMatrixViewProjection(float(WIDTH_ZOOM)/float(HEIGHT_ZOOM)),
          WIDTH_ZOOM, HEIGHT_ZOOM, anchor.get,
        )
        camera.dollyToward(factor, anchor.get)
        let after = projectToScreen(
          camera.initMatrixViewProjection(float(WIDTH_ZOOM)/float(HEIGHT_ZOOM)),
          WIDTH_ZOOM, HEIGHT_ZOOM, anchor.get,
        )
        check after.isInFront
        check abs(after.x - before.x) <= 0.5 # Half a pixel: what a reader could not see.
        check abs(after.y - before.y) <= 0.5
        check camera.distance =~ 19.0*factor
        # The angles are what keep the anchor on its own ray; a zoom must not turn.
        check camera.azimuth =~ initCameraDefault().azimuth
        check camera.elevation =~ initCameraDefault().elevation


  test "zooming in and back out returns the camera exactly where it stood":
    # A wheel notch each way has to be a round trip, or a reader who overshoots and corrects
    #   ends up somewhere they never chose -- and an aimed zoom moves the target as well as
    #   the distance, so there is more to come back to than there used to be.
    var camera = initCameraDefault()
    let opening = camera
    let anchor = positionUnderCursor(camera, 1440, 900, ScreenPosition(x: 300.0, y: 640.0))
    check anchor.isSome
    camera.dollyToward(0.5, anchor.get)
    check not (camera.target =~ opening.target) # It really did move the view, not just in.
    camera.dollyToward(2.0, anchor.get)
    check camera.target =~ opening.target
    check camera.distance =~ opening.distance


  test "a zoom with nothing under the cursor falls back to zooming at the middle":
    # Over the sky there is no object, no ground ahead and no level to meet, so there is
    #   no point to aim at. The answer is the plain dolly a wheel did before any of this,
    #   not a refusal to zoom.
    var
      interaction = Interaction(is_enabled: true)
      camera = initCamera(target = ORIGIN, distance = 12.0, azimuth = 0.5, elevation = 0.05)
      scene = initScene()
    let cursor = ScreenPosition(x: 720.0, y: 60.0) # High in the frame, from a camera barely
      # above the level it is looking at: that ray tilts up into the sky and comes back
      # down to neither the ground nor the target's own level.
    check positionUnderCursor(camera, 1440, 900, cursor).isNone
    check positionOnGround(camera, 1440, 900, cursor).isNone
    interaction.updateCursor(cursor.x, cursor.y)
    interaction.dollyAtCursor(camera, scene, 2.0, 1440, 900)
    check camera.distance =~ 24.0
    check camera.target =~ ORIGIN


  test "a zoom aims at the object under the cursor, then the ground, then the level":
    # The order is the rule: a reader pointing at an object means that object, at the depth
    #   it actually stands at. Anchored on a plane through the target instead, a zoom crept
    #   past or short of it and what was under the cursor slid away as the wheel turned.
    const (WIDE, TALL) = (1440, 900)
    let
      camera = initCamera(target = ORIGIN, distance = 20.0, azimuth = 0.4, elevation = 0.5)
      view_projection = camera.initMatrixViewProjection(float(WIDE)/float(TALL))
      # A point standing well above the ground, so aiming at *it* and aiming at the ground
      #   under the cursor are different answers and the test can tell them apart.
      raised = Position(x: 2.0, y: -1.0, z: 6.0)
      on_screen = projectToScreen(view_projection, WIDE, TALL, raised)
    var scene = initScene()
    scene.addItem(toMultivector(raised), "raised", inkCycled(0))

    # Over the point: its own place, not the ground below it nor the target's level.
    let at_object = anchorZoomAt(
      scene, camera, view_projection, WIDE, TALL,
      ScreenPosition(x: on_screen.x, y: on_screen.y),
    )
    check at_object.isSome
    check at_object.get =~ raised

    # A cursor a little off it falls through to the ground, which is `z = 0` itself rather
    #   than the level the target happens to sit on.
    var camera_raised = camera
    camera_raised.target = Position(x: 0.0, y: 0.0, z: 5.0)
    let
      elsewhere = ScreenPosition(x: on_screen.x + 200.0, y: on_screen.y + 160.0)
      at_ground = anchorZoomAt(
        scene, camera_raised, camera_raised.initMatrixViewProjection(
          float(WIDE)/float(TALL)
        ), WIDE, TALL, elsewhere,
      )
    check at_ground.isSome
    check abs(at_ground.get.z) <= 1.0e-6
    # And it is the ground the *cursor* is over, not the ground below the eye.
    check at_ground.get =~ positionOnGround(camera_raised, WIDE, TALL, elsewhere).get

    # A cursor whose ray reaches no ground still meets the level through the target, which
    #   is the last answer rather than the first.
    let
      level = initCamera(target = ORIGIN, distance = 12.0, azimuth = 0.5, elevation = -0.4)
      upward = ScreenPosition(x: 720.0, y: 40.0)
    if positionOnGround(level, WIDE, TALL, upward).isNone:
      let at_level = anchorZoomAt(
        initScene(), level, level.initMatrixViewProjection(float(WIDE)/float(TALL)),
        WIDE, TALL, upward,
      )
      let at_target = positionUnderCursor(level, WIDE, TALL, upward)
      check at_level.isSome == at_target.isSome
      if at_level.isSome: check at_level.get =~ at_target.get


  test "a line is aimed at where the cursor crosses it, not at its stored support":
    # A cursor is a ray and a line is a line, so in three dimensions the two miss. The
    #   point of the line nearest the ray is the only answer both on the line and under
    #   the cursor, and it moves along the line as the cursor slides down it.
    let
      anchor = Position(x: 0.0, y: 0.0, z: 0.0)
      axis = Direction(x: 1.0, y: 0.0, z: 0.0)
      # A ray crossing that line from above, four units along it.
      found = positionOnLineNearest(
        anchor, axis, Position(x: 4.0, y: 0.0, z: 3.0), Direction(x: 0, y: 0, z: -1),
      )
    check found.isSome
    check found.get =~ Position(x: 4.0, y: 0.0, z: 0.0)
    # A ray running along the line has a whole direction of nearest points, not one.
    check positionOnLineNearest(
      anchor, axis, Position(x: 0.0, y: 1.0, z: 0.0), axis
    ).isNone


  test "the algebra's nearest point on a line agrees with the closed form":
    # `positionOnLineNearest` answers through joins and a meet; the classical two-dot
    #   closed form lives HERE, in the test -- checking the algebra against it is the
    #   project's purpose. A deterministic scatter of line/ray pairs, comfortably away
    #   from parallel, so a failure names the same pair on every run.
    var seed = 9.0
    proc pseudo(): float =
      seed = (seed*97.31 + 33.77) mod 41.0
      seed - 20.5
    proc someway(): Direction =
      var d = Direction(x: 0, y: 0, z: 0)
      while norm(d) < 0.1: d = Direction(x: pseudo(), y: pseudo(), z: pseudo())
      normalize(d).get
    for trial in 0 ..< 100:
      let
        anchor = Position(x: pseudo(), y: pseudo(), z: pseudo())
        axis = someway()
        ray_from = Position(x: pseudo(), y: pseudo(), z: pseudo())
        ray_along = someway()
        between = anchor - ray_from
        along_both = dot(axis, ray_along)
        denominator = 1.0 - along_both*along_both
      if abs(denominator) <= 1.0e-3: continue # A near-parallel pair proves nothing here.
      let
        step = (along_both*dot(ray_along, between) - dot(axis, between))/denominator
        classical = anchor + step*axis
        answered = positionOnLineNearest(anchor, axis, ray_from, ray_along)
      check answered.isSome
      if answered.isSome:
        check answered.get =~ classical


  test "the algebra's near clip agrees with the componentwise clip":
    # `clipToEyeSide` clips by plane depths and a meet; the componentwise interpolation
    #   -- the very formula `mesh.addSegment`'s boundary packing still performs -- lives
    #   HERE as the reference, which also pins the two clips to each other so the
    #   deliberate boundary asymmetry cannot drift.
    var seed = 17.0
    proc pseudo(): float =
      seed = (seed*97.31 + 33.77) mod 41.0
      seed - 20.5
    proc someway(): Direction =
      var d = Direction(x: 0, y: 0, z: 0)
      while norm(d) < 0.1: d = Direction(x: pseudo(), y: pseudo(), z: pseudo())
      normalize(d).get
    for trial in 0 ..< 100:
      let
        tail = Position(x: pseudo(), y: pseudo(), z: pseudo())
        head = Position(x: pseudo(), y: pseudo(), z: pseudo())
        eye = Position(x: pseudo(), y: pseudo(), z: pseudo())
        forward = someway()
        near = 0.05 + abs(pseudo())/10.0
        plane_near = planeThrough(
          add(toMultivector(eye), wedge(near, toMultivector(forward))),
          toMultivector(forward),
        )
        answered = clipToEyeSide(tail, head, plane_near)
        # The componentwise reference, exactly as the boundary's own packing clips.
        depth_tail = dot(tail - eye, forward)
        depth_head = dot(head - eye, forward)
      if depth_tail <= near and depth_head <= near:
        check answered.isNone
        continue
      check answered.isSome
      if answered.isNone: continue
      var (expected_tail, expected_head) = (tail, head)
      if depth_tail <= near:
        expected_tail =
          tail + ((near - depth_tail)/(depth_head - depth_tail))*(head - tail)
      elif depth_head <= near:
        expected_head =
          head + ((near - depth_head)/(depth_tail - depth_head))*(tail - head)
      check answered.get[0] =~ expected_tail
      check answered.get[1] =~ expected_head


  test "a pan grabs the level under the pointer and carries it to the cursor":
    # The fault: a pan of so many hundredths of the orbit distance per pixel is right at
    #   one depth and one tilt and wrong everywhere else -- driven, a 200-pixel drag
    #   carried the scene 288 -- and it slid the target within the plane *facing the eye*,
    #   which is tilted, so the same drag lifted the target from z 1.00 to 6.40.
    const (WIDE, TALL) = (1440, 900)
    var camera = initCamera(
      target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05,
      elevation = 0.42,
    )
    let
      before = ScreenPosition(x: 700.0, y: 560.0)
      after = ScreenPosition(x: 940.0, y: 660.0)
      grabbed = positionUnderCursor(camera, WIDE, TALL, before)
      height_opening = camera.target.z
    check grabbed.isSome
    camera.panAcross(before, after, WIDE, TALL)
    # The very point that was under the pointer is now under where the pointer went.
    let landed = projectToScreen(
      camera.initMatrixViewProjection(float(WIDE)/float(TALL)), WIDE, TALL, grabbed.get
    )
    check hypot(landed.x - after.x, landed.y - after.y) < 0.5
    # And the orbit centre keeps its height exactly, whatever direction the drag went.
    check camera.target.z =~ height_opening
    for step in [
      (ScreenPosition(x: 700.0, y: 560.0), ScreenPosition(x: 700.0, y: 260.0)),
      (ScreenPosition(x: 200.0, y: 800.0), ScreenPosition(x: 1300.0, y: 300.0)),
    ]:
      var camera_step = camera
      camera_step.panAcross(step[0], step[1], WIDE, TALL)
      check camera_step.target.z =~ camera.target.z


  test "a pan takes hold no further out than its own bound":
    # A horizontal level meets a ray aimed near the horizon a very long way off, and one
    #   pixel of drag there is hundreds of world units. The hold point is clamped, so a
    #   drag high in the frame is governed rather than thrown across the scene.
    const (WIDE, TALL) = (1440, 900)
    var camera = initCamera(
      target = ORIGIN, distance = 19.0, azimuth = 0.0, elevation = 0.06
    )
    # Walk up the middle of the frame for the first row whose ray grazes the level far
    #   enough out to be governed, rather than naming a pixel that a change in the field of
    #   view would quietly move off the case being checked.
    var grazing = none(ScreenPosition)
    for row in countdown(450, 360):
      let at = ScreenPosition(x: 720.0, y: float(row))
      let hit = positionUnderCursor(camera, WIDE, TALL, at)
      # Four times past the bound, not merely over it: at the bound itself the clamp
      #   barely bites and there is no governing to see.
      if hit.isSome and
          norm(hit.get - camera.eye) > 4.0*FACTOR_PAN_REACH_MAX*camera.distance:
        grazing = some(at)
        break
    check grazing.isSome
    let
      opening = camera
      lower = ScreenPosition(x: 720.0, y: grazing.get.y + 30.0)
      unbounded = norm(
        positionUnderCursor(camera, WIDE, TALL, grazing.get).get -
        positionUnderCursor(camera, WIDE, TALL, lower).get
      )
    camera.panAcross(grazing.get, lower, WIDE, TALL)
    let moved = norm(camera.target - opening.target)
    # It moves -- a governed pan is still a pan -- but by a fraction of what the ungoverned
    #   grab would have thrown the view, and never past what two bounded holds can span.
    check moved > 0.0
    check moved < 0.5*unbounded
    check moved <= 2.0*FACTOR_PAN_REACH_MAX*opening.distance
    check camera.target.z =~ opening.target.z


  test "an aimed zoom draws the target toward what it aimed at":
    # `dollyToward` scales the target toward the anchor by exactly the factor the distance
    #   took, which is the whole of why an aimed zoom settles the orbit centre onto what
    #   the reader is zooming into. Aimed at the ground, the target comes down onto it
    #   rather than staying stranded on the level it started at -- driven in the shipped
    #   browser, eight notches over the ground carried it from z 1.00 to 0.32, where before
    #   this it held at 1.00 however far in the reader went.
    var camera = initCamera(
      target = Position(x: 0, y: 0, z: 4), distance = 20.0, azimuth = 0.3, elevation = 0.5
    )
    let
      opening = camera
      anchor = Position(x: 3.0, y: -2.0, z: 0.0)
    camera.dollyToward(0.5, anchor)
    let scale = camera.distance/opening.distance
    check camera.target =~ anchor + scale*(opening.target - anchor)
    check camera.target.z < opening.target.z
    # And back out along the same line, so a reader who overshoots loses nothing.
    camera.dollyToward(1.0/scale, anchor)
    check camera.target =~ opening.target
    check camera.distance =~ opening.distance


  test "an aimed zoom is held off the near floor, and stays a placement while it is":
    # `dollyToward` reads back what `distanceHeld` allowed rather than assuming its own
    #   factor took, so a zoom stopped by the floor still describes where the eye is.
    var camera = initCamera(target = ORIGIN, distance = 0.1, azimuth = 0.4, elevation = 0.5)
    let anchor = positionUnderCursor(camera, 1440, 900, ScreenPosition(x: 400.0, y: 600.0))
    check anchor.isSome
    camera.dollyToward(0.001, anchor.get)
    check camera.distance =~ DISTANCE_LIMIT_NEAR
    check norm(camera.eye - camera.target) =~ camera.distance


  test "framing a selection wider than the old ceiling pulls back past it":
    # `distanceFitting` used to be clamped to the same 500, so anything larger than the
    #   frame could hold at that distance was framed by giving up rather than by moving.
    let camera = initCamera(target = ORIGIN, distance = 19.0, azimuth = 1.0, elevation = 0.4)
    check distanceFitting(4_000.0, camera, 1440, 900, 0.0) > 500.0


suite "Mesh":
  const
    VERTICES_RIBBON = 6 ## Vertices one ribbon is wound from: two triangles over four
      ## corners. Stated here rather than imported so that a change to how `addSegment`
      ## winds a quad has to be noticed here too.
    HEIGHT_SCALE_TEST = 900 ## Framebuffer height `SCALE_TEST` measures its widths in.

  let SCALE_TEST = block:
    let eye = Position(x: 5, y: -3, z: 7)
    # `algebraFilled`, as every hand-built extent must be, or the multivector twins the
    #   tessellation reads are zero and it silently draws nothing.
    algebraFilled(DrawExtent(scale: DrawScale(
      extent_furniture: 30.0,
      eye: eye, radius_horizon: 50.0,
      # Looking back at the origin, which is where every fixture below is built around.
      forward: direction(toMultivector(eye) ∧ toMultivector(ORIGIN)).get,
      tangent_half_view: tan(0.5*degToRad(45.0)),
      height_pixels: HEIGHT_SCALE_TEST,
      depth_near: 0.1,
    )))
  ## Eye held off-origin deliberately: horizon geometry anchored to the origin by
    ## mistake, instead of to `eye`, would fail every horizon check below.
    ##   `extent_furniture` held distinct from `EXTENT_PLANE_F` (a plane's own fixed
    ##   radius, no longer part of `DrawExtent` at all), so a line test checking against
    ##   the wrong one of the two would fail rather than pass by coincidence.
    ##   Radius held modest rather than close to a real far clip distance (hundreds of
    ##   units): vertices round-trip through `Vertex`'s own `float32` storage, and
    ##   `isNear`'s tolerance is calibrated for coordinates near the same scale every
    ##   other geometry test in this suite uses, not for the additional rounding a much
    ##   larger radius would carry through unrelated to anything this suite tests here.

  test "an item's drawn centre is its own anchor, and only a plane's disc moves":
    # The one reader everything that has to meet an object on screen goes through: the
    #   rubber-band leaving it, the comet aimed from it, the menu hanging off it. A plane's
    #   disc is centred on its creation anchor and every other shape ignores one, which is
    #   exactly what `mesh.addObject` does with the same argument.
    let elsewhere = Position(x: -4.0, y: 6.0, z: 2.0)
    let
      point = GENERAL_POINTS[0]
      line = GENERAL_POINTS[1] ∧ GENERAL_POINTS[2]
      plane = GENERAL_POINTS[3] ∧ GENERAL_POINTS[4] ∧ GENERAL_POINTS[5]
    check anchorFor(plane, some(elsewhere), SCALE_TEST).get =~ elsewhere
    for m in [point, line]:
      check anchorFor(m, some(elsewhere), SCALE_TEST).get =~ anchorFor(m, SCALE_TEST).get
    # And with nothing stored, every shape falls back to where it always stood.
    for m in [point, line, plane]:
      check anchorFor(m, none(Position), SCALE_TEST).get =~ anchorFor(m, SCALE_TEST).get


  proc ribbonEnds(mesh: Mesh; index: int): (Position, Position) =
    ## Recover the segment the `index`-th ribbon was built around.
    ##   Each end's own two corners sit an equal step either side of it, so their midpoint
    ##   is the endpoint again -- which is also the property being asserted whenever this
    ##   is used to check where a line was drawn: a ribbon that were not centred on its
    ##   own line would fail every one of those checks.
    proc midpoint(a, b: Vertex): Position =
      Position(
        x: 0.5*(float(a.x) + float(b.x)),
        y: 0.5*(float(a.y) + float(b.y)),
        z: 0.5*(float(a.z) + float(b.z)),
      )
    let base = VERTICES_RIBBON*index
    (
      midpoint(mesh.vertices[base + 0], mesh.vertices[base + 5]),
      midpoint(mesh.vertices[base + 1], mesh.vertices[base + 2]),
    )

  setup:
    MESHES.clearMeshes

  test "clearing drops every vertex":
    MESHES.addMarker(ORIGIN, Ink.Rose.colour)
    MESHES.addSegment(ORIGIN, PLACES[0], Ink.Jade.colour, WIDTH_LINE_OBJECT, SCALE_TEST)
    MESHES.clearMeshes
    for primitive in Primitive:
      check MESHES[primitive].count_vertices == 0


  test "point becomes one marker where it stands":
    for i in 0 ..< SAMPLES:
      MESHES.clearMeshes
      check MESHES.addObject(POINTS[i], Ink.Rose.colour, SCALE_TEST) == Placement.Finite
      check MESHES[Primitive.Point].count_vertices == 1
      check MESHES[Primitive.Ribbon].count_vertices == 0
      check isNear(MESHES[Primitive.Point].vertices[0].toPosition, PLACES[i])


  test "line becomes two segments, each running from support to a vanishing point":
    for line in LINES:
      MESHES.clearMeshes
      check MESHES.addObject(line, Ink.Jade.colour, SCALE_TEST) == Placement.Finite
      check MESHES[Primitive.Ribbon].count_vertices == 2*VERTICES_RIBBON
      # No point marker: a line's own segment already passes through its support, so
      #   marking that point again would only add a stray dot the segment does not need.
      check MESHES[Primitive.Point].count_vertices == 0
      let (anchor, axis) = (positionAnchor(line), direction(line))
      check anchor.isSome and axis.isSome
      let
        (tail_first, head_first) = ribbonEnds(MESHES[Primitive.Ribbon], 0)
        (tail_second, head_second) = ribbonEnds(MESHES[Primitive.Ribbon], 1)
      # Both halves start on the line, at its support, so they meet with no gap.
      check isNear(tail_first, anchor.get)
      check isNear(tail_second, anchor.get)
      # Each runs toward one of the line's own two vanishing points, both fixed to the
      #   eye. It *reaches* that point only where the point is in front of the camera:
      #   a ribbon is clipped to the near plane first, since a width proportional to
      #   depth is meaningless behind the eye (see `addSegment`). So what is asserted is
      #   the direction each half runs in, plus that its end stands in front.
      for (head, vanishing) in [
        (head_first, SCALE_TEST.eye + SCALE_TEST.radius_horizon*axis.get),
        (head_second, SCALE_TEST.eye - SCALE_TEST.radius_horizon*axis.get),
      ]:
        let
          toward = normalize(head - anchor.get)
          reach = normalize(vanishing - anchor.get)
        check toward.isSome and reach.isSome
        # Compared with a tolerance rather than through `=~`: these are read back out of
        #   `Vertex`'s own float32 storage, which `=~`'s exact-math tolerance is tighter
        #   than.
        check abs(toward.get.x - reach.get.x) < 1.0e-4
        check abs(toward.get.y - reach.get.y) < 1.0e-4
        check abs(toward.get.z - reach.get.z) < 1.0e-4
        check dot(head - SCALE_TEST.eye, SCALE_TEST.forward) >= SCALE_TEST.depth_near - 1e-6
        # And it is either the vanishing point itself or short of it, never past.
        check norm(head - anchor.get) <= norm(vanishing - anchor.get)*(1.0 + 1e-5)


  test "a drawn line projects onto the true line, however far its ends leave it":
    # Each half has one end on the line and one at `eye +- radius*axis`, so both lie in
    #   the plane through the eye containing the line. That plane projects to a single
    #   screen line, which is what lets the far ends sit well off the line in world
    #   space -- displaced along the view ray -- without the drawing showing it.
    let camera = initCamera(Position(x: 0, y: 0, z: 1), 19.0, 1.05, 0.42)
    let
      eye = camera.eye
      frame_camera = camera.frame(eye)
      radius = radiusHorizonFor(camera.distanceFar)
    proc screen(p: Position): (float, float) =
      let v = p - eye
      (dot(v, frame_camera.axis_right)/dot(v, frame_camera.forward),
       dot(v, frame_camera.axis_up)/dot(v, frame_camera.forward))
    for line in LINES:
      let (anchor, axis) = (positionAnchor(line).get, direction(line).get)
      let
        (ax, ay) = screen(anchor)
        (bx, by) = screen(anchor + 5.0*axis) # A second point on the TRUE line.
        length = hypot(bx - ax, by - ay)
        (ux, uy) = ((bx - ax)/length, (by - ay)/length)
      for reach in [radius, -radius]:
        let far_end = eye + reach*axis
        # Reject any end that falls behind the eye, where a projection is meaningless.
        if dot(far_end - eye, frame_camera.forward) <= camera.distanceNear: continue
        let (fx, fy) = screen(far_end)
        # Perpendicular screen distance of the drawn end from the true line's own ray.
        check abs((fx - ax)*uy - (fy - ay)*ux) < 1e-9


  test "line's own far end coincides exactly with where its attitude is drawn":
    # The property the "lines look cut off" feedback chased: a line and its own
    #   attitude are two different objects (a finite segment and a horizon point)
    #   drawn through two different branches of `mesh`, so nothing forces them to
    #   agree geometrically unless the segment's own far end is deliberately built to
    #   land on the same point the horizon marker would.
    for line in LINES:
      let attitude = ⊖ line
      MESHES.clearMeshes
      discard MESHES.addObject(attitude, Ink.Cobalt.colour, SCALE_TEST)
      let star = MESHES[Primitive.Point].vertices[0].toPosition

      MESHES.clearMeshes
      discard MESHES.addObject(line, Ink.Jade.colour, SCALE_TEST)
      let (_, far_first) = ribbonEnds(MESHES[Primitive.Ribbon], 0)
      let (_, far_second) = ribbonEnds(MESHES[Primitive.Ribbon], 1)
      # Whichever half runs toward the star has to land on it -- but only where the star
      #   itself stands in front of the near plane. A ribbon is clipped there (see
      #   `mesh.addSegment`), so a star behind the camera is met by a half that stops at
      #   the near plane instead. Nothing is visible there either way; what would be a
      #   real defect is a gap between the two *on screen*, which this still catches.
      if dot(star - SCALE_TEST.eye, SCALE_TEST.forward) >= SCALE_TEST.depth_near:
        check isNear(far_first, star) or isNear(far_second, star)


  test "plane becomes a flat filled disc and a rim, every vertex on it":
    for plane in PLANES:
      MESHES.clearMeshes
      check MESHES.addObject(plane, Ink.Olive.colour, SCALE_TEST) == Placement.Finite
      const
        VERTICES_FILL = 3*SEGMENTS_CIRCLE_HORIZON ## Fan: centre, two rim points each.
        RIBBONS_RING = SEGMENTS_CIRCLE_HORIZON
      check MESHES[Primitive.Triangle].count_vertices == VERTICES_FILL
      # The rim and nothing else. A plane used to add one ribbon more for a normal shaft
      #   out of its anchor; orientation now rides on the selection marker's own pulse,
      #   so an unselected plane draws no such thing.
      check MESHES[Primitive.Ribbon].count_vertices == VERTICES_RIBBON*RIBBONS_RING
      # No point marker at all: neither an anchor marker nor a normal arrowhead, so a
      #   plane never adds a scattered dot beyond what the fill and rim already draw.
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
      # The rim is drawn as ribbons, so its own *corners* stand half a line width off the
      #   plane -- the step sideways is perpendicular to the segment and to the sight ray,
      #   which is only in the plane when the eye happens to lie in it. What is still
      #   exactly on the plane, and at exactly the plane's own radius, is the segment each
      #   ribbon was built around; `ribbonEnds` recovers it.
      for i in 0 ..< RIBBONS_RING:
        let (tail, head) = ribbonEnds(MESHES[Primitive.Ribbon], i)
        for place in [tail, head]:
          check isNear(dot(place - anchor.get, normal.get), 0)
          check isNear(norm(place - anchor.get), EXTENT_PLANE_F)
        # And every corner stays within that half width of the plane, so the bulge is a
        #   fraction of a pixel on screen rather than anything a reader could see.
        let bound = 0.5*float(WIDTH_LINE_OBJECT)*
          max(worldPerPixelAt(tail, SCALE_TEST), worldPerPixelAt(head, SCALE_TEST))
        for j in 0 ..< VERTICES_RIBBON:
          let corner = MESHES[Primitive.Ribbon].vertices[VERTICES_RIBBON*i + j]
          check isNear(float(corner.alpha), Ink.Olive.colour.alpha)
          check abs(dot(corner.toPosition - anchor.get, normal.get)) <= bound + 1e-5


  test "point at horizon becomes a star fixed at eye plus its own direction":
    for line in LINES:
      MESHES.clearMeshes
      let attitude = ⊖ line
      check MESHES.addObject(attitude, Ink.Cobalt.colour, SCALE_TEST) == Placement.Horizon
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
      check MESHES.addObject(attitude, Ink.Jade.colour, SCALE_TEST) == Placement.Horizon
      # At most one ribbon per segment, and fewer in practice: a great circle is drawn
      #   around the eye, so about half of it stands behind the camera and is clipped away
      #   entirely rather than drawn inside out (see `mesh.addSegment`).
      let count_ribbon = MESHES[Primitive.Ribbon].count_vertices div VERTICES_RIBBON
      check MESHES[Primitive.Ribbon].count_vertices == VERTICES_RIBBON*count_ribbon
      check count_ribbon in 1 .. SEGMENTS_CIRCLE_HORIZON
      # `directionNormalHorizon` reads straight off the horizon line's own raw
      #   coefficients; confirm it agrees with the finite plane's own normal, read
      #   through a wholly different pair of library operators, before trusting either
      #   to check where the circle itself landed.
      let
        normal_from_plane = directionNormal(plane)
        normal_from_horizon = directionNormalHorizon(attitude)
      check normal_from_plane.isSome and normal_from_horizon.isSome
      check normal_from_plane.get =~ normal_from_horizon.get
      # Checked on the segment each ribbon was built around rather than on its corners:
      #   a corner stands half a line width off that segment, so it is neither exactly on
      #   the circle's own radius nor exactly in its plane. See the plane rim above.
      var count_at_radius = 0
      for i in 0 ..< count_ribbon:
        let (tail, head) = ribbonEnds(MESHES[Primitive.Ribbon], i)
        for place in [tail, head]:
          let offset = place - SCALE_TEST.eye
          # In the circle's own plane exactly, clipped or not: the clip slides a point
          #   along the chord, which lies in that plane too.
          check isNear(dot(offset, normal_from_plane.get), 0)
          # And out at the circle's own radius, unless the clip pulled it in along that
          #   chord -- never past it.
          check norm(offset) <= SCALE_TEST.radius_horizon*(1.0 + 1e-5)
          if isNear(norm(offset), SCALE_TEST.radius_horizon): inc count_at_radius
      check count_at_radius > 0


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

    check MESHES.addObject(attitude_first, Ink.Cobalt.colour, SCALE_TEST) == Placement.Horizon
    check MESHES[Primitive.Triangle].count_vertices == 6*LATITUDES_HORIZON*LONGITUDES_HORIZON
    let vertices_first = MESHES[Primitive.Triangle].vertices
    for i in 0 ..< MESHES[Primitive.Triangle].count_vertices:
      let offset = vertices_first[i].toPosition - SCALE_TEST.eye
      check isNear(norm(offset), SCALE_TEST.radius_horizon)

    MESHES.clearMeshes
    check MESHES.addObject(attitude_second, Ink.Cobalt.colour, SCALE_TEST) == Placement.Horizon
    check MESHES[Primitive.Triangle].count_vertices == 6*LATITUDES_HORIZON*LONGITUDES_HORIZON
    # Same dome, vertex for vertex, regardless of which unrelated volume produced it.
    for i in 0 ..< MESHES[Primitive.Triangle].count_vertices:
      check isNear(MESHES[Primitive.Triangle].vertices[i].toPosition, vertices_first[i].toPosition)


  test "multivector of no geometry becomes nothing at all":
    for empty in [1.0 ∧ initElement(Basis.scalar), 1.0 + POINTS[0]]:
      MESHES.clearMeshes
      check MESHES.addObject(empty, Ink.Rose.colour, SCALE_TEST) == Placement.Empty
      for primitive in Primitive:
        check MESHES[primitive].count_vertices == 0


  test "a scene filled with planes fits the vertex bound a ribbon mesh reserves":
    # The binding case for `VERTICES_MAX`, and the reason it was tripled: a plane draws
    #   the most ribbons of any object, and `addVertex` asserts rather than overflowing.
    #   Built rather than calculated, so the bound is checked against what is actually
    #   emitted rather than against arithmetic that could drift from it.
    MESHES.clearMeshes
    var built = 0
    for i in 0 ..< ITEMS_MAX:
      let angle = 0.7*float(i)
      let plane =
        toMultivector(Position(x: 6.0*cos(angle), y: 6.0*sin(angle), z: 0.15*float(i))) ∧
        toMultivector(Position(x: 6.0*cos(angle + 0.4), y: 1.0, z: 2.0 + 0.1*float(i))) ∧
        toMultivector(Position(x: 1.0, y: 6.0*sin(angle + 0.9), z: -1.0))
      if MESHES.addObject(plane, Ink.Olive.colour, SCALE_TEST) == Placement.Finite:
        inc built
    check built == ITEMS_MAX
    check MESHES[Primitive.Ribbon].count_vertices <= VERTICES_MAX
    check MESHES[Primitive.Triangle].count_vertices <= VERTICES_MAX


  func scaleFurnitureAt(eye: Position; extent: float): DrawExtent =
    ## Stand an eye somewhere, with a stated furniture reach, for the fog cases below.
    ##   `SCALE_TEST` cannot serve them: its eye is seven units up with a reach of thirty,
    ##   which `fogFurnitureFor` cuts to 3.6 -- shorter than that height, so its fog never
    ##   reaches the ground and no grid is drawn at all. A fog case needs an eye standing
    ##   inside its own fog, and several need it far from the origin, which is the whole
    ##   point of the rule being checked.
    algebraFilled(DrawExtent(scale: DrawScale(
      extent_furniture: extent,
      eye: eye, radius_horizon: extent,
      # Looking a little ahead and down, which every ground fixture below lies under.
      forward: direction(
        toMultivector(eye) ∧ toMultivector(Position(x: eye.x + 1.0, y: eye.y, z: 0.0))
      ).get,
      tangent_half_view: tan(0.5*degToRad(45.0)),
      height_pixels: HEIGHT_SCALE_TEST,
      depth_near: 0.1,
    )))

  let SCALE_FOG = scaleFurnitureAt(Position(x: 103, y: -97, z: 5), 300.0)
    ## Eye inside its own fog: a reach of 300 fades out at 36 units, well past the five
    ## the eye stands above the ground.
    ##   Stood a few units off a lattice crossing rather than anywhere convenient, so that
    ##   a hundred-unit cell actually lays a line through the fog's solid core -- the
    ##   nearest lines are three units away, and an eye parked between crossings would
    ##   leave the core empty and a fade case with nothing to measure.


  test "world furniture stays inside the fog it is drawn in":
    MESHES.clearMeshes
    MESHES.addAxes(SCALE_FOG.extent_furniture, SCALE_FOG)
    MESHES.addGrid(SCALE_FOG.extent_furniture, SCALE_FOG)
    check MESHES[Primitive.Ribbon].count_vertices > 0
    let fog = fogFurnitureFor(SCALE_FOG.extent_furniture)
    for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
      let at = MESHES[Primitive.Ribbon].vertices[i].toPosition
      # Slack of one unit for the ribbon's own half-width, which steps each corner off
      #   the line it draws by half a pixel's worth of world at that depth.
      check norm(at - SCALE_FOG.eye) <= fog.radius_gone + 1.0


  test "world furniture is fog about the camera, not a halo about the origin":
    # The rule this project had before: furniture was laid about the world origin and a
    #   reader who panned away from it lost the ground entirely. Both halves are checked,
    #   since either alone passes under the old behaviour.
    let scale_afar = scaleFurnitureAt(Position(x: 1000, y: -700, z: 6), 300.0)
    MESHES.clearMeshes
    MESHES.addGrid(scale_afar.extent_furniture, scale_afar)
    check MESHES[Primitive.Ribbon].count_vertices > 0
    let fog = fogFurnitureFor(scale_afar.extent_furniture)
    for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
      let at = MESHES[Primitive.Ribbon].vertices[i].toPosition
      check norm(at - scale_afar.eye) <= fog.radius_gone + 1.0
      check norm(at - ORIGIN) > fog.radius_gone


  test "ground grid holds full alpha near the camera and fades to nothing at its reach":
    MESHES.clearMeshes
    MESHES.addGrid(SCALE_FOG.extent_furniture, SCALE_FOG)
    let fog = fogFurnitureFor(SCALE_FOG.extent_furniture)
    var
      alpha_near_min = 1.0
      alpha_far_max = 0.0
    for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
      let
        vertex = MESHES[Primitive.Ribbon].vertices[i]
        radius = norm(vertex.toPosition - SCALE_FOG.eye)
      if radius <= fog.radius_full:
        alpha_near_min = min(alpha_near_min, float(vertex.alpha))
      if radius >= fog.radius_gone - TOLERANCE_TEST:
        alpha_far_max = max(alpha_far_max, float(vertex.alpha))
    check isNear(alpha_near_min, Ink.Grid.colour.alpha*ALPHA_GRID)
    check alpha_far_max <= TOLERANCE_SINGLE


  test "the grid reads as reference: dimmer than the ink an object of that colour takes":
    # `Ink.Grid` is also `INK_POOL_FREE`, so the dimming has to live in the grid rather
    #   than in the palette entry; an object taking that ink must stay opaque.
    check ALPHA_GRID < 1.0
    check isNear(Ink.Grid.colour.alpha, 1.0)


  test "the join's normal is the classical cross product, sign included":
    # `mesh.directionAcross` IS the join -- `directionNormal(tail ∧ head ∧ eye)` -- and
    #   this holds the algebra against the classical cross product computed HERE, in the
    #   test, which is the project's purpose. **Sign included**: agreement up to sign
    #   would let a ribbon's two edges swap sides without a word from the suite.
    var seed = 1.0
    proc pseudo(): float =
      # A deterministic scatter, so a failure names the same triple on every run.
      seed = (seed*97.31 + 33.77) mod 41.0
      seed - 20.5
    for trial in 0 ..< 200:
      let
        tail = Position(x: pseudo(), y: pseudo(), z: pseudo())
        head = Position(x: pseudo(), y: pseudo(), z: pseudo())
        eye = Position(x: pseudo(), y: pseudo(), z: pseudo())
        computed = directionAcross(tail, head, eye)
        # The classical form: the cross product of the two edges from `tail`, normalized.
        (a, b) = (head - tail, eye - tail)
        classical = normalize(Direction(
          x: a.y*b.z - a.z*b.y, y: a.z*b.x - a.x*b.z, z: a.x*b.y - a.y*b.x,
        ))
      check classical.isSome == computed.isSome
      if classical.isSome:
        check computed.get =~ classical.get
    # And the two refusals: a segment of no length, and an eye on the segment's own line,
    #   neither of which has a side to step off toward.
    let (a, b) = (Position(x: 1, y: 2, z: 3), Position(x: 2, y: 4, z: 6))
    check directionAcross(a, a, b).isNone
    check directionAcross(a, b, Position(x: 3, y: 6, z: 9)).isNone


  test "grid cells are one fixed size, at every reach the camera asks for":
    # The size this replaced doubled with the reach, so a reader who dollied out found the
    #   ground silently re-scaled under them and no distance read off it was comparable
    #   with the last. Checked by counting what is actually laid, at two reaches four
    #   doublings apart, against what a fixed cell says should be there.
    check SIZE_CELL_GRID =~ 10.0
    for (extent, height) in [(1000.0, 60.0), (4000.0, 60.0)]:
      # Both reaches are inside what a fixed cell covers, which is the claim being made:
      #   nothing here is the stepped cell `sizeCellGridFor` falls back on far out.
      # Straight down from high above a lattice crossing, so every line the fog reaches is
      #   drawn whole: nothing falls behind the near plane to be clipped, and the count
      #   below is then exact arithmetic rather than a reading of what happened to survive.
      let
        scale_above = scaleFurnitureAt(Position(x: 0, y: 0, z: height), extent)
        fog = fogFurnitureFor(extent)
        radius = sqrt(fog.radius_gone*fog.radius_gone - height*height)
        # Lines each way from the eye, in each of the two families, skipping the one
        #   through the origin that coincides with a world axis.
        lines = 4*int(floor(radius/SIZE_CELL_GRID))
        # ...and how finely each is cut for its fade, which the segment budget decides
        #   from how many lines the family lays. Asked here rather than assumed to be
        #   `SEGMENTS_GRID_FADE`: the count below is exact arithmetic, and the budget is
        #   part of that arithmetic at the wider of these two reaches.
        pieces = segmentsGridFadeFor(2*int(floor(radius/SIZE_CELL_GRID)) + 1)
      MESHES.clearMeshes
      MESHES.addGrid(extent, scale_above)
      check MESHES[Primitive.Ribbon].count_vertices == lines*pieces*6
      for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
        let
          at = MESHES[Primitive.Ribbon].vertices[i].toPosition
          off_x = abs(at.x - SIZE_CELL_GRID*round(at.x/SIZE_CELL_GRID))
          off_y = abs(at.y - SIZE_CELL_GRID*round(at.y/SIZE_CELL_GRID))
        check min(off_x, off_y) <= 1.0


  test "the grid's fade is cut as finely as its budget affords, and no finer":
    # **The regression case for a shipped cost.** The scenery's price is its segment count
    #   and nothing else -- about 50-60 us a segment on the driving container -- and that
    #   count sawtoothed with camera distance, because the cell steps by a decade only
    #   after the line count has climbed a decade's worth. Measured before this rule: 154
    #   segments and 7.3 ms at orbit distance 19, but 2,084 and 126.5 ms at distance 300,
    #   dropping back to 706 once the cell stepped. A reader panning near the top of a
    #   decade met a tenth of a second of scenery, intermittently.
    check SEGMENTS_GRID_FADE_MIN < SEGMENTS_GRID_FADE
    # A family laying few lines is cut as finely as it ever was: the near view, where a
    #   fade has room to band, is exactly what it was before the budget existed.
    check segmentsGridFadeFor(0) == SEGMENTS_GRID_FADE
    check segmentsGridFadeFor(1) == SEGMENTS_GRID_FADE
    check segmentsGridFadeFor((SEGMENTS_GRID_MAX div 2) div SEGMENTS_GRID_FADE) ==
      SEGMENTS_GRID_FADE
    # One line past what the budget affords at full fineness, and the cut coarsens.
    check segmentsGridFadeFor((SEGMENTS_GRID_MAX div 2) div SEGMENTS_GRID_FADE + 1) <
      SEGMENTS_GRID_FADE
    # However many lines are asked for, the cut never falls through its own floor: two
    #   pieces still fade from both ends toward the middle, and one could not fade at all.
    for count in [1, 10, 100, 1_000, 100_000]:
      check segmentsGridFadeFor(count) >= SEGMENTS_GRID_FADE_MIN
      check segmentsGridFadeFor(count) <= SEGMENTS_GRID_FADE
      # And the family's own spend stays inside its half of the budget wherever the floor
      #   is not what is binding.
      let spent = count*segmentsGridFadeFor(count)
      check spent <= SEGMENTS_GRID_MAX div 2 or
        segmentsGridFadeFor(count) == SEGMENTS_GRID_FADE_MIN
    # Monotone: more lines never buys a finer cut, so a reader pulling steadily back never
    #   sees the fade sharpen again.
    var previous = SEGMENTS_GRID_FADE
    for count in 1 .. 400:
      check segmentsGridFadeFor(count) <= previous
      previous = segmentsGridFadeFor(count)


  test "the grid stays inside its segment budget however far the camera pulls back":
    # Held on what is actually laid rather than on the rule alone: the budget is only
    #   worth having if `addGrid` spends it, and the two families each hold half without
    #   knowing what the other drew.
    for (extent, height) in [
      (1.0e3, 6.0e1), (4.0e3, 6.0e1), (1.0e4, 5.0e2), (1.0e6, 5.0e4), (1.0e9, 5.0e7),
    ]:
      let scale_afar = scaleFurnitureAt(Position(x: 0, y: 0, z: height), extent)
      MESHES.clearMeshes
      MESHES.addGrid(extent, scale_afar)
      # Six vertices a segment; see `addSegmentAcross`.
      check MESHES[Primitive.Ribbon].count_vertices div 6 <= SEGMENTS_GRID_MAX
      check MESHES[Primitive.Ribbon].count_vertices > 0

    # And the opening view never reaches the budget at all, which is what "the near view
    #   is untouched" means: nothing there is drawn more coarsely than it was.
    let scale_opening = scaleFurnitureAt(Position(x: 0, y: 0, z: 1.0e1), 2.0e2)
    MESHES.clearMeshes
    MESHES.addGrid(2.0e2, scale_opening)
    check MESHES[Primitive.Ribbon].count_vertices div 6 < SEGMENTS_GRID_MAX div 2


  test "a camera dollied far out still has ground under it, at a coarser cell":
    # The fault: the fog's reach was capped at `CELLS_GRID_HALF_MAX` cells, so past 1,200
    #   units the ground stopped reaching what the camera was looking at, and past twice
    #   that there was nothing drawn at all -- a black void, axes included. The bound now
    #   steps the *cell*, which lays the same count of lines across the reach the camera
    #   actually has.
    check fogFurnitureFor(1.0e9).radius_gone =~ FRACTION_GRID_FADE_END*1.0e9
    check fogFurnitureFor(1.0e9).radius_full < fogFurnitureFor(1.0e9).radius_gone

    # The cell holds at its fixed size right up to the reach it can cover, and steps only
    #   past it -- a reader working at any ordinary distance never meets a step.
    let radius_fixed = float(CELLS_GRID_HALF_MAX)*SIZE_CELL_GRID
    check sizeCellGridFor(0.0) =~ SIZE_CELL_GRID
    check sizeCellGridFor(radius_fixed) =~ SIZE_CELL_GRID
    check sizeCellGridFor(1.5*radius_fixed) =~ 10.0*SIZE_CELL_GRID
    check sizeCellGridFor(15.0*radius_fixed) =~ 100.0*SIZE_CELL_GRID
    # By decades, so every line of the coarser lattice is a line of the finer one and a
    #   step coarsens what is drawn without moving anything a reader was measuring against.
    for radius in [2.0e3, 5.0e4, 3.0e6, 1.0e9]:
      let decades = log10(sizeCellGridFor(radius)/SIZE_CELL_GRID)
      check decades =~ round(decades)
      # And never more lines than the bound, however far out the camera has gone.
      check radius/sizeCellGridFor(radius) <= float(CELLS_GRID_HALF_MAX)

    # Ground is still drawn where it used to be gone entirely, and still within budget.
    for (extent, height) in [(1.0e4, 5.0e2), (1.0e6, 5.0e4), (1.0e9, 5.0e7)]:
      let scale_afar = scaleFurnitureAt(Position(x: 0, y: 0, z: height), extent)
      MESHES.clearMeshes
      MESHES.addGrid(extent, scale_afar)
      check MESHES[Primitive.Ribbon].count_vertices > 0
      check MESHES[Primitive.Ribbon].count_vertices <= VERTICES_MAX
      # Laid on world multiples of the cell this reach asked for, so the lattice is still
      #   the world's rather than one dragged along under the camera.
      let
        fog = fogFurnitureFor(extent)
        size_cell = sizeCellGridFor(sqrt(fog.radius_gone*fog.radius_gone - height*height))
      for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
        let
          at = MESHES[Primitive.Ribbon].vertices[i].toPosition
          off_x = abs(at.x - size_cell*round(at.x/size_cell))
          off_y = abs(at.y - size_cell*round(at.y/size_cell))
        # Within a fiftieth of a cell rather than exactly on it: a line is drawn as a
        #   ribbon, so its vertices stand half its own screen width either side of the
        #   lattice line, which in world units grows with the distance it is drawn at.
        #   Measured at 0.005 of a cell across all three reaches.
        check min(off_x, off_y) <= 0.02*size_cell


  test "the axes fog too: the one the camera stands by is drawn, the far ones are not":
    # Fog applies to the axes as well, so all the furniture ends at one horizon rather
    #   than the grid stopping while the axes run on. An eye a thousand units out along x
    #   stands beside that axis and has flown clear of the other two -- and both halves
    #   matter, since an axis rule that draws nothing at all passes the second alone.
    let
      scale_afar = scaleFurnitureAt(Position(x: 1000, y: 0, z: 6), 300.0)
      fog = fogFurnitureFor(scale_afar.extent_furniture)
    check norm(scale_afar.eye - ORIGIN) > fog.radius_gone
    MESHES.clearMeshes
    MESHES.addAxes(scale_afar.extent_furniture, scale_afar)
    check MESHES[Primitive.Ribbon].count_vertices > 0
    for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
      let at = MESHES[Primitive.Ribbon].vertices[i].toPosition
      # Everything drawn lies on the x axis: the y and z axes are outside the fog, and
      #   the stretch of the x axis that is drawn is the stretch inside it.
      check abs(at.y) <= 1.0 and abs(at.z) <= 1.0
      check norm(at - scale_afar.eye) <= fog.radius_gone + 1.0


  test "radiusHorizonFor scales with the camera's own far clip distance":
    check radiusHorizonFor(400.0) =~ 400.0*FRACTION_HORIZON


  test "extentFurnitureFor scales with the camera's own far clip distance":
    check extentFurnitureFor(400.0) =~ 400.0*FRACTION_FURNITURE


  test "muted colour blends toward its own luminance and cuts opacity by its fixed fraction":
    for ink in Ink:
      let
        base = ink.colour
        luminance = 0.299'f32*base.red + 0.587'f32*base.green + 0.114'f32*base.blue
        dimmed = muted(base)
      check isNear(dimmed.red, base.red + (luminance - base.red)*MUTE_DESATURATION)
      check isNear(dimmed.green, base.green + (luminance - base.green)*MUTE_DESATURATION)
      check isNear(dimmed.blue, base.blue + (luminance - base.blue)*MUTE_DESATURATION)
      check isNear(dimmed.alpha, base.alpha*FRACTION_DIMMED_ALPHA)


  test "the categorical run is contiguous, so a picker can walk it as one block":
    # A colour picker offers `COUNT_INK_CATEGORICAL` entries starting at
    #   `lut_ink_to_name[INK_CATEGORICAL_FIRST]`, which is only correct while every
    #   categorical slot follows every structural one, with no gaps.
    check COUNT_INK_CATEGORICAL == 5
    check inkCategorical(0) == INK_CATEGORICAL_FIRST
    check inkCategorical(COUNT_INK_CATEGORICAL - 1) == Ink.high
    for index in 0 ..< COUNT_INK_CATEGORICAL:
      check categoricalIndex(inkCategorical(index)) == index


  test "a colour picker offers every categorical slot and no structural one":
    var offered: seq[string]
    for index in 0 ..< COUNT_INK_CATEGORICAL: offered.add($inkCategorical(index))
    check offered == @["Rose", "Copper", "Olive", "Jade", "Cobalt"]
    # `Invalid` is structural precisely so it can never be offered: a status colour a
    #   caller could also pick for an ordinary object would say nothing.
    for structural in [Ink.Backdrop, Ink.AxisX, Ink.AxisY, Ink.AxisZ, Ink.Grid,
                       Ink.Guide, Ink.Outline, Ink.Invalid]:
      check categoricalIndex(structural) < 0
    check $Ink.Invalid notin offered


  test "inkCycled stays inside the run a picker offers, and wraps within it":
    # Nothing may cycle to a colour the user could not have chosen themselves.
    for index in 0 ..< 3*COUNT_INK_CATEGORICAL:
      check categoricalIndex(inkCycled(index)) >= 0
      check categoricalIndex(inkCycled(index)) < COUNT_INK_CATEGORICAL
    check inkCycled(0) == INK_CATEGORICAL_FIRST
    check inkCycled(COUNT_INK_CATEGORICAL) == inkCycled(0)


suite "Scene":
  test "the startup scene gives every seed point a colour of its own":
    # Four points wearing one hue say they are one kind of thing, which is the opposite of
    #   what a categorical palette is for; a hand-added object takes the next hue, so these
    #   should too. `ground` and `o` keep the hues a reader learns to find them by.
    var scene = initScene()
    constructSeeds(scene)
    var inks: seq[Ink]
    for slot in 0 ..< scene.len:
      case toText(scene.labelAt(slot))
      of "ground": check scene.inkAt(slot) == INK_SEED_GROUND
      of "o": check scene.inkAt(slot) == INK_SEED_ORIGIN
      else: inks.add(scene.inkAt(slot))
    check inks.len == 3
    for i in 0 ..< inks.len:
      check inks[i] notin [INK_SEED_GROUND, INK_SEED_ORIGIN]
      for j in i + 1 ..< inks.len: check inks[i] != inks[j]


  test "items are held in order added":
    var scene = initScene()
    for i in 0 ..< 5:
      scene.addItem(POINTS[i], "p" & $i, inkCycled(i))
    check scene.len == 5
    var count_seen = 0
    for item in scene:
      check item.geometry =~ POINTS[count_seen]
      check item.isVisible
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
    check scene.addItem(POINTS[5 mod SAMPLES], "p5", Ink.Rose) == 0
    check scene.addItem(POINTS[6 mod SAMPLES], "p6", Ink.Rose) == 2


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
    discard scene.addItem(POINTS[0], "a", Ink.Rose)
    check scene.isAlive(0)
    scene.removeItem(0)
    check not scene.isAlive(0)
    check not scene.isAlive(-1)
    check not scene.isAlive(ITEMS_MAX)


  test "scene fills to capacity and reports it":
    var scene = initScene()
    for i in 0 ..< ITEMS_MAX:
      check not scene.isFull
      scene.addItem(POINTS[i mod SAMPLES], "p", Ink.Rose)
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
      check len(lut_operation_to_notation[operation]) > 0
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


  test "meet finds where a line crosses a plane even far outside its own drawn disc":
    # `mesh.addPlane`'s disc is only a rendering choice -- the plane it represents is
    #   the same infinite object algebraically either way, and `WedgeAnti` (meet) reads
    #   straight off that Multivector, never consulting `EXTENT_PLANE_F` or anything
    #   drawn. Crossing a plane three disc-radii out from its own drawn centre, well
    #   outside the circle `mesh.addPlane` actually fills, exercises that directly.
    for i in 0 ..< SAMPLES:
      let
        plane = PLANES[i]
        anchor = positionAnchor(plane)
        axes = frame(plane)
      check anchor.isSome
      check axes.isSome
      let
        far_on_plane = anchor.get + (3.0*EXTENT_PLANE_F)*axes.get.axis_first
        off_plane = toMultivector(far_on_plane + axes.get.normal)
        line = toMultivector(far_on_plane) ∧ off_plane
        crossing = applyOperation(Operation.WedgeAnti, line, plane)
      check shape(crossing) == some(Shape.Point)
      let place = position(crossing)
      check place.isSome
      check place.get =~ far_on_plane


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


  test "creation anchor for a plane wedged from a line and a point sits at their midpoint":
    for i in 0 ..< SAMPLES:
      let
        line = LINES[i]
        point = POINTS[(i + 5) mod SAMPLES]
        plane = applyOperation(Operation.Wedge, line, point)
        anchor = creationAnchor(Operation.Wedge, line, point, plane)
        anchor_swapped = creationAnchor(Operation.Wedge, point, line, plane)
        expected = position(add(unitize(point), unitize(projectOrthogonal(point, line))))
      check anchor.isSome
      check anchor_swapped.isSome
      check expected.isSome
      check anchor.get =~ expected.get
      check anchor_swapped.get =~ expected.get


  test "creation anchor for a perpendicular plane sits where its line pierces it":
    for i in 0 ..< SAMPLES:
      let
        point = POINTS[i]
        line = LINES[(i + 11) mod SAMPLES]
        plane = applyOperation(Operation.ExpandWeight, point, line)
        anchor = creationAnchor(Operation.ExpandWeight, point, line, plane)
        anchor_swapped = creationAnchor(Operation.ExpandWeight, line, point, plane)
        expected = position(wedgeAnti(line, plane))
      check anchor.isSome
      check anchor_swapped.isSome
      check expected.isSome
      check anchor.get =~ expected.get
      check anchor_swapped.get =~ expected.get


  test "creation anchor is none for operations or shapes it does not special-case":
    check creationAnchor(Operation.WedgeAnti, PLANES[0], PLANES[1], LINES[0]).isNone
    check creationAnchor(Operation.Wedge, POINTS[0], POINTS[1], LINES[0]).isNone
    check creationAnchor(Operation.Wedge, PLANES[0], POINTS[0], PLANES[0]).isNone
    check creationAnchor(Operation.ProjectOrthogonal, POINTS[0], PLANES[0], POINTS[0]).isNone


  test "notation substitutes real operand names for the table's own bold placeholders":
    # One table serves both render paths, so this is also what the browser's own
    #   `nimOperationNotation` hands out -- there is no second table to keep in step.
    check notationSubstituted(Operation.Wedge, "a", "b") == "a ∧ b"
    check notationSubstituted(Operation.Attitude, "L", "unused") == "L⊖"
    # The English name after the symbols is full of ordinary m's and n's and must never
    #   reach a label; only the symbolic prefix is substituted.
    check notationSubstituted(Operation.DualWeight, "g", "unused") == "g☆"
    check "weight dual" notin notationSubstituted(Operation.DualWeight, "g", "unused")
    # `𝐧` appears twice in the projections, and both occurrences take the operand name.
    check notationSubstituted(Operation.ProjectCentral, "a", "G") == "G ∨ (a ∧ G★)"
    # An operand whose own name contains the placeholder letters survives untouched.
    check notationSubstituted(Operation.Wedge, "mn", "nm") == "mn ∧ nm"


  test "labels truncate and stay terminated":
    var storage: Label
    toChars("short", storage)
    check toText(storage) == "short"
    toChars('x'.repeat(LABEL_MAX*2), storage)
    check len(toText(storage)) <= LABEL_MAX - 1
    check toText(storage).endsWith("…") # Says it was shortened rather than reading whole.


  test "a truncated label never splits a character, whatever the buffer lands on":
    # The bug this pins: bytes were copied until the buffer filled, so a three-byte
    #   operator could be cut in half. The invalid tail reached the browser as a literal
    #   `%e2%8a` where a glyph belonged -- Nim's JS backend percent-escapes what it cannot
    #   decode -- which is how it was found, in a screenshot of the objects list.
    #   Every offset is walked, so whichever byte of an operator the cut lands on is
    #   covered rather than whichever one this test's own text happens to produce.
    for pad in 0 .. 6:
      var storage: Label
      let text = 'x'.repeat(pad) & "∧∨⊖".repeat(LABEL_MAX)
      toChars(text, storage)
      let kept = toText(storage)
      check kept.validateUtf8 == -1 # -1 is "valid throughout"; any other value is an index.
      check kept.endsWith("…")
      check len(kept) <= LABEL_MAX - 1

    # A text that fits exactly is left alone: no mark, nothing dropped.
    var storage: Label
    let exact = "∧".repeat((LABEL_MAX - 1) div 3)
    toChars(exact, storage)
    check toText(storage) == exact


  # Every magnitude the two front-ends show has to read the same in both, and the values
  #   most likely to break that are exact binary ties -- a coefficient of 10.125 or 12345,
  #   which a user can simply type. C rounds a tie to even and JavaScript rounds it away
  #   from zero, so a formatter that delegates to the runtime disagrees with itself across
  #   backends. Measured before the rule was stated here: 330 of 7000 values differed.
  const MAGNITUDES = [
    0.0, 1.0, -1.0, 3.5, -2.0, 0.25, 1664.0, 1234567.0, 0.00012345, 1e-7, 1e7,
    99999.0, 0.099999, 123.456, -0.0001, 1e-5, 9.9999e-5, 1000.0, 999.95, 6.02e23,
    10.125, 12345.0, 0.125, 1.0005, 9999.6, -10.125, 2.5, 0.5, 1.5, 1012.5,
  ]

  test "magnitudes read the same whichever backend formats them":
    # Pinned as text rather than against a reference the backend supplies, because that is
    #   exactly what differs. These are what C's own `%.4g` writes, verified against it.
    check formatMagnitude(10.125) == "10.12"   # Tie, rounds to even.
    check formatMagnitude(-10.125) == "-10.12"
    check formatMagnitude(12345.0) == "1.234e+04"
    check formatMagnitude(0.125) == "0.125"
    check formatMagnitude(2.5) == "2.5"
    check formatMagnitude(1012.5) == "1012"    # Tie at the fourth digit, rounds to even.
    check formatMagnitude(9999.6) == "1e+04"   # Rounding carries into another digit.
    check formatMagnitude(0.0) == "0"
    check formatMagnitude(-0.0) == "0"         # A sign on nothing reads as a bug.

  test "magnitudesAgree: the browser's own formatter answers what C's does":
    # One rule, two mechanisms: the desktop reaches C's `%.4g` through `snprintf`, which
    #   the browser build has no runtime for, so `formatMagnitude` states the same rule in
    #   plain Nim. Only this test holds the two together -- run it before changing either.
    #   Skipped on the JS backend, which has no `snprintf` to compare against; the test
    #   above is what runs there, and it pins the text rather than a second mechanism.
    when not defined(js):
      for value in MAGNITUDES:
        if value == 0.0: continue  # C signs a zero, this does not; pinned above.
        var
          storage: array[64, char]
          cursor = 0
        appendMagnitude(storage, cursor, value)
        check formatMagnitude(value) == toText(storage)


  test "multivectors print every term they carry, and nothing else":
    # Significant digits, not fixed decimal places: a whole number reads as one, and a
    #   coefficient keeps only the digits it actually carries. Basis elements are named
    #   as the library's own `$` names them, which is what keeps the two GUIs 1-1.
    check formatMultivectorString(initElement(Basis.scalar, 0.0)) == "0 𝟏"
    check formatMultivectorString(toMultivector(Position(x: 2, y: 0, z: -3))) ==
      "2 𝐞₁ - 3 𝐞₃ + 1 𝐞₄"
    check formatMultivectorString(toMultivector(Position(x: 3.5, y: 0, z: 0))) ==
      "3.5 𝐞₁ + 1 𝐞₄"
    check formatMultivectorString(initElement(Basis.scalar, 0.00012345)) == "0.0001234 𝟏"
    # Every basis name matches what the library writes for that element on its own,
    #   rather than being trusted to a table transcribed by hand.
    for b in Basis:
      let named = ($initElement(b, 1.0)).strip()
      check lut_basis_to_name[b] == named
    for i in 0 ..< SAMPLES:
      check shapeText(POINTS[i]) == "point"
      check shapeText(LINES[i]) == "line"
      check shapeText(PLANES[i]) == "plane"
      # Attitude of a line is its direction, which is a point standing at the horizon.
      check shapeText(⊖ LINES[i]) == "point at horizon"
    check shapeText(1.0 + POINTS[0]) == "mixed grade, nothing to draw"


  test "slotsCreated walks creation order, whatever order the slots fell in":
    # The arena reuses the most recently freed slot, so slot order stops being creation
    #   order the moment anything is removed. This is what the save path walks, and what a
    #   `born`-sorted list could not answer: two items added in one frame share a reading,
    #   and a replayed item's own born is stamped into the future.
    var scene = initScene()
    for i in 0 ..< 6:
      discard scene.addItem(POINTS[i], "p" & $i, inkCycled(i))
    scene.removeItem(4)
    scene.removeItem(1)
    let slot_first = scene.addItem(POINTS[6], "seventh", Ink.Rose)  # lands in slot 1
    let slot_second = scene.addItem(POINTS[7], "eighth", Ink.Rose)  # lands in slot 4
    check slot_first == 1
    check slot_second == 4

    var slots: array[ITEMS_MAX, int]
    let count = scene.slotsCreated(slots)
    check count == scene.len
    var labels: seq[string]
    for position in 0 ..< count:
      labels.add(toText(scene.labelAt(slots[position])))
    check labels == @["p0", "p2", "p3", "p5", "seventh", "eighth"]
    # Which is the ordinals in order, and every one of them distinct.
    for position in 1 ..< count:
      check scene.orderOf(slots[position]) > scene.orderOf(slots[position - 1])

    # An empty scene fills nothing rather than reporting a slot that is not there.
    let empty = initScene()
    check empty.slotsCreated(slots) == 0


  proc savedWith(ordinal: int): ItemSaved =
    ## An item that differs from its neighbours only in the palette slot it names, which
    ## is the only field any version boundary has ever changed.
    ItemSaved(ink_ordinal: ordinal, is_visible: true, label: "x", geometry: POINTS[0])


  test "an item already at this version is carried up unchanged":
    # The chain has to be a no-op on a file this build wrote, or every save/load round
    #   trip quietly rewrites something.
    for ordinal in ord(Ink.low) .. ord(Ink.high):
      let carried = itemUpgraded(savedWith(ordinal), VERSION_SCENE)
      check carried.isSome
      check carried.get.ink_ordinal == ordinal
      check carried.get.is_visible
      check carried.get.label == "x"
      check carried.get.geometry =~ POINTS[0]
    # And an ordinal no palette answers to is refused rather than clamped into one.
    check itemUpgraded(savedWith(ord(Ink.high) + 1), VERSION_SCENE).isNone
    check itemUpgraded(savedWith(-1), VERSION_SCENE).isNone


  test "a version-2 item needs nothing doing to it but is walked all the same":
    # Version 2 and 3 differ only in what the item *sequence* promises, so an item's own
    #   fields come through untouched -- and must not be folded by the version-1 step.
    #   Compared field by field rather than through `==`, which `Multivector` makes a
    #   compile error on purpose; the geometry is checked with the approximate operator.
    for ordinal in ord(Ink.low) .. ord(Ink.high):
      let
        from_two = itemUpgraded(savedWith(ordinal), 2'u8)
        from_three = itemUpgraded(savedWith(ordinal), VERSION_SCENE)
      check from_two.isSome
      check from_three.isSome
      check from_two.get.ink_ordinal == ordinal
      check from_two.get.ink_ordinal == from_three.get.ink_ordinal
      check from_two.get.is_visible == from_three.get.is_visible
      check from_two.get.label == from_three.get.label
      check from_two.get.geometry =~ from_three.get.geometry


  test "a version-1 item is carried onto today's palette, hue by hue":
    # Version 1 had no `Invalid` and three more hues, so every ordinal it could hold is
    #   walked here rather than only the two ends.
    for ordinal in 0 ..< ORDINAL_INK_CATEGORICAL_V1:
      # The structural slots are unmoved to this day.
      let carried = itemUpgraded(savedWith(ordinal), 1'u8)
      check carried.isSome
      check carried.get.ink_ordinal == ordinal
    for step in 0 ..< 8:
      # Its eight hues all land on a hue -- never on `Invalid`, never off the end.
      let carried = itemUpgraded(savedWith(ORDINAL_INK_CATEGORICAL_V1 + step), 1'u8)
      check carried.isSome
      let ink = Ink(carried.get.ink_ordinal)
      check ink == inkCycled(step)
      check ink != Ink.Invalid
      check ink in inkCategorical(0) .. inkCategorical(COUNT_INK_CATEGORICAL - 1)
    # The five hues version 1 shares with today shift by exactly one, no more.
    for step in 0 ..< COUNT_INK_CATEGORICAL:
      let carried = itemUpgraded(savedWith(ORDINAL_INK_CATEGORICAL_V1 + step), 1'u8)
      check carried.get.ink_ordinal == ORDINAL_INK_CATEGORICAL_V1 + step + 1
    # Ordinals version 1 could never have written are a corrupt file, not another hue.
    check itemUpgraded(savedWith(ORDINAL_INK_HIGH_V1 + 1), 1'u8).isNone
    check itemUpgraded(savedWith(-1), 1'u8).isNone
    # Everything that is not the palette rides through the whole chain untouched.
    let carried = itemUpgraded(savedWith(ORDINAL_INK_HIGH_V1), 1'u8)
    check carried.get.label == "x"
    check carried.get.geometry =~ POINTS[0]


  test "a version outside what this build reads is refused by the chain itself":
    # The guard lives with the walk rather than only at each call site, so a caller that
    #   forgets to check `readsSceneVersion` still cannot get a half-upgraded item.
    check itemUpgraded(savedWith(ord(Ink.Rose)), 0'u8).isNone
    check itemUpgraded(savedWith(ord(Ink.Rose)), VERSION_SCENE + 1'u8).isNone
    for version in VERSION_SCENE_LEAST .. VERSION_SCENE:
      check readsSceneVersion(version)
      check itemUpgraded(savedWith(ORDINAL_INK_CATEGORICAL_V1), version).isSome


  test "bornReplaying staggers an arrival in order and never runs past the cap":
    const CLOCK = 12.5
    # A handful of objects get the full beat: legible, and short enough to still overlap.
    check bornReplaying(0, 4, CLOCK) =~ CLOCK
    for index in 1 ..< 4:
      check bornReplaying(index, 4, CLOCK) =~ CLOCK + float(index)*SECONDS_REPLAY_STEP
    # A single object arriving alone has nothing to stagger against.
    check bornReplaying(0, 1, CLOCK) =~ CLOCK
    # However many arrive, the last of them lands within the cap -- and in order.
    for count in 1 .. ITEMS_MAX:
      var previous = low(float)
      for index in 0 ..< count:
        let born = bornReplaying(index, count, CLOCK)
        check born > previous
        check born >= CLOCK
        previous = born
      check previous - CLOCK <= SECONDS_REPLAY_WHOLE + TOLERANCE_TEST
    # And the beat only ever shortens to make that fit, never lengthens.
    check bornReplaying(1, ITEMS_MAX, CLOCK) - CLOCK < SECONDS_REPLAY_STEP


  test "replayFrom restamps a whole scene into an arrival, in creation order":
    # What the opening scene and the demo preset both go through: built all at once, then
    #   handed to a reader as the construction it is. Slot order is scrambled first, so
    #   this pins that the restamp follows creation order rather than the arena's layout.
    var scene = initScene()
    for i in 0 ..< 5:
      discard scene.addItem(POINTS[i], "p" & $i, inkCycled(i), 99.0)
    scene.removeItem(1)
    let slot_late = scene.addItem(POINTS[5], "late", Ink.Rose, 99.0)
    check slot_late == 1

    const CLOCK = 7.5
    scene.replayFrom(CLOCK)
    var slots: array[ITEMS_MAX, int]
    let count = scene.slotsCreated(slots)
    check count == 5
    check scene.bornAt(slots[0]) =~ CLOCK
    for position in 1 ..< count:
      check scene.bornAt(slots[position]) > scene.bornAt(slots[position - 1])
    check toText(scene.labelAt(slots[count - 1])) == "late"
    check scene.bornAt(slots[count - 1]) - CLOCK <= SECONDS_REPLAY_WHOLE + TOLERANCE_TEST
    # The same beat a file of this size would arrive on -- one rule, not two.
    for position in 0 ..< count:
      check scene.bornAt(slots[position]) =~ bornReplaying(position, count, CLOCK)

    # An empty scene has nothing to restamp and must not fall over reaching for slot zero.
    var empty = initScene()
    empty.replayFrom(CLOCK)
    check empty.len == 0


  test "the opening scene arrives as a replay rather than all at once":
    # The startup seeds are a construction somebody else made, exactly as a loaded file
    #   is, so both front-ends stagger them. `constructSeeds` itself deliberately does
    #   not: `runStoryboard` calls it too and sweeps each step on a clock of its own.
    const CLOCK = 4.0
    var placed = initScene()
    constructSeeds(placed, CLOCK)
    for slot in 0 ..< placed.len:
      check placed.bornAt(slot) == CLOCK # Untouched by the constructor itself.

    var opened = initScene()
    constructSeeds(opened, CLOCK)
    opened.replayFrom(CLOCK)
    check opened.len >= 2
    for slot in 1 ..< opened.len:
      check opened.bornAt(slot) > opened.bornAt(slot - 1)
    # Still on screen quickly: an opening scene a reader waits through is a worse opening
    #   scene than one that simply appeared.
    check opened.bornAt(opened.len - 1) - CLOCK <= SECONDS_REPLAY_WHOLE + TOLERANCE_TEST


  test "a replay stamp in the future draws its object at no size yet":
    # What makes the stagger visible rather than merely recorded: `mesh.animationProgress`
    #   reads a born the clock has not reached as zero progress, so an object waiting its
    #   turn is drawn at nothing and grows in when its beat arrives.
    const CLOCK = 3.0
    let born_second = bornReplaying(1, 4, CLOCK)
    check animationProgress(CLOCK, born_second) == 0.0
    check animationProgress(born_second, born_second) == 0.0
    check animationProgress(born_second + ANIMATION_SECONDS, born_second) == 1.0
    check animationProgress(CLOCK, bornReplaying(0, 4, CLOCK)) == 0.0


  # Saving and loading name a filesystem, which a browser has none of: `scene.nim`
  #   declares that pair for the desktop backend alone, so their tests are guarded to
  #   match. Every other invariant in this suite holds on both backends and is checked
  #   on both.
  when not defined(js):
    test "save then load reproduces every live item, compacting freed slots":
      var original = initScene()
      discard original.addItem(POINTS[0], "a", Ink.Rose)
      discard original.addItem(POINTS[1], "bb", Ink.Jade)
      let slot_doomed = original.addItem(POINTS[2], "doomed", Ink.Olive)
      original.removeItem(slot_doomed) # leaves a hole a fresh load must not reproduce
      let slot_last = original.addItem(POINTS[3], "d", Ink.Cobalt)
      original.setVisible(slot_last, false)

      let path = getTempDir() / "visualiser_suite_scene.rgascene"
      check saveScene(original, path).contains("Saved 3")
      defer: removeFile(path)

      var loaded = initScene()
      discard loaded.addItem(POINTS[9], "stale", Ink.Cobalt) # load must replace, not merge
      check loadScene(loaded, path).contains("Loaded 3")
      check loaded.len == 3

      # Freed slot 2 is compacted away: loaded items land at slots 0, 1, 2 in save order.
      check loaded[0].geometry =~ POINTS[0]
      check toText(loaded[0].label) == "a"
      check loaded[0].ink == Ink.Rose
      check loaded[0].isVisible
      check loaded[0].born == 0.0 # dawn of time, not mid-appear-in-animation

      check loaded[1].geometry =~ POINTS[1]
      check toText(loaded[1].label) == "bb"
      check loaded[1].ink == Ink.Jade
      check loaded[1].isVisible

      check loaded[2].geometry =~ POINTS[3]
      check toText(loaded[2].label) == "d"
      check loaded[2].ink == Ink.Cobalt
      check not loaded[2].isVisible


    test "every multi-byte field is written little-endian, whatever the host":
      # The bytes themselves, not a round trip: a round trip passes on any byte order as
      #   long as one build writes and reads it, and the second implementation of this
      #   format is `glue.js`, which hands `DataView` an explicit `true` at every call and
      #   cannot be asked what the desktop felt like doing. Pinning the layout here is what
      #   keeps the two from drifting apart on a host that is not little-endian.
      var scene = initScene()
      var geometry: Multivector
      geometry[Basis.low] = 2.0 # 0x4000000000000000, whose bytes are unambiguous either way
      discard scene.addItem(geometry, "e", Ink.Rose)
      let path = getTempDir() / "visualiser_suite_scene_endian.rgascene"
      check saveScene(scene, path).contains("Saved 1")
      defer: removeFile(path)

      let bytes = readFile(path)
      check bytes[0 ..< len(MAGIC_SCENE)] == MAGIC_SCENE
      check uint8(bytes[len(MAGIC_SCENE)]) == VERSION_SCENE

      # Item count, four bytes straight after magic, version and basis count.
      let start_count = len(MAGIC_SCENE) + 2
      check uint8(bytes[start_count]) == 1'u8
      for offset in 1 .. 3: check uint8(bytes[start_count + offset]) == 0'u8

      # First coefficient, past the count and this item's ink, visibility, label length and
      #   the one byte of label itself.
      let start_first = start_count + 4 + 3 + 1
      check uint8(bytes[start_first + 6]) == 0x00'u8
      check uint8(bytes[start_first + 7]) == 0x40'u8 # High byte last: little-endian.


    test "empty scene round-trips":
      let original = initScene()
      let path = getTempDir() / "visualiser_suite_scene_empty.rgascene"
      check saveScene(original, path).contains("Saved 0")
      defer: removeFile(path)

      var loaded = initScene()
      discard loaded.addItem(POINTS[0], "will be cleared", Ink.Rose)
      check loadScene(loaded, path).contains("Loaded 0")
      check loaded.len == 0


    test "loading a foreign file leaves scene untouched and reports why":
      var scene = initScene()
      discard scene.addItem(POINTS[0], "keep", Ink.Rose)
      let path = getTempDir() / "visualiser_suite_scene_bogus.rgascene"
      writeFile(path, "not a scene file at all")
      defer: removeFile(path)

      check loadScene(scene, path).contains("not a scene file")
      check scene.len == 1
      check toText(scene[0].label) == "keep"


    test "loading a file saved under a different PGA dimension is rejected":
      var scene = initScene()
      discard scene.addItem(POINTS[0], "keep", Ink.Rose)
      let path = getTempDir() / "visualiser_suite_scene_wrongbasis.rgascene"
      writeFile(path, "RGAS" & char(2) & char(99)) # no build here carries 99 basis terms
      defer: removeFile(path)

      check loadScene(scene, path).contains("different PGA dimension")
      check scene.len == 1


    proc sceneFileOf(version: uint8; items: seq[(int, bool, string, Multivector)]): string =
      ## Build the bytes of a scene file by hand, at whatever version is asked for.
      ##   Hand-built rather than saved by this build, because the point of the cases
      ##   below is to read a version this build can no longer *write*: asking `saveScene`
      ##   for one would only ever produce today's, and the reading it exercised would be
      ##   its own writing spelled backwards. Ink is taken as a raw ordinal for the same
      ##   reason -- an old file's ordinals name an enum that is gone.
      result = MAGIC_SCENE & char(version) & char(ord(Basis.high) + 1)
      var count = uint32(len(items))
      var count_bytes = newString(4)
      littleEndian32(addr count_bytes[0], addr count)
      result &= count_bytes
      for (ordinal, is_visible, label, geometry) in items:
        result &= char(ordinal) & char(ord(is_visible)) & char(len(label)) & label
        for b in Basis:
          var
            coefficient = geometry[b]
            bytes = newString(8)
          littleEndian64(addr bytes[0], addr coefficient)
          result &= bytes


    test "a scene file from before the palette changed is read, not refused":
      # An item's ink is stored as `Ink`'s own ordinal, and reserving `Invalid` renumbered
      #   that enum -- a version-1 file's bytes name different colours now. Reading it
      #   through the palette it was written under is what keeps somebody's scene; the
      #   three hues that no longer exist fold onto ones that do, which is a recoverable
      #   wrong colour rather than an unrecoverable refusal.
      var scene = initScene()
      discard scene.addItem(POINTS[9], "replaced", Ink.Rose)
      let path = getTempDir() / "visualiser_suite_scene_v1.rgascene"
      writeFile(path, sceneFileOf(1'u8, @[
        (4, true, "grid-hued", POINTS[0]),  # Structural slot, unmoved between palettes.
        (7, true, "was rose", POINTS[1]),   # First categorical hue of the old palette.
        (11, false, "was cobalt", POINTS[2]),
        (13, true, "was magenta", POINTS[3]), # Retired; folds onto a hue that survives.
      ]))
      defer: removeFile(path)

      check loadScene(scene, path).contains("Loaded 4")
      check scene.len == 4
      check scene[0].ink == Ink.Grid
      check scene[1].ink == Ink.Rose
      check scene[2].ink == Ink.Cobalt
      check scene[3].ink == inkCycled(13 - ORDINAL_INK_CATEGORICAL_V1)
      # Everything but the colour of a retired hue comes back exactly.
      for slot in 0 ..< 4:
        check scene[slot].geometry =~ POINTS[slot]
      check toText(scene[1].label) == "was rose"
      check scene[1].isVisible
      check not scene[2].isVisible


    test "a version-2 file is read under today's palette, unshifted":
      # Version 2 and 3 differ only in what the item *sequence* promises, so a version-2
      #   file's ordinals are today's and must not be folded through the version-1 rule.
      var scene = initScene()
      let path = getTempDir() / "visualiser_suite_scene_v2.rgascene"
      writeFile(path, sceneFileOf(2'u8, @[
        (ord(Ink.Grid), true, "structural", POINTS[0]),
        (ord(Ink.Rose), true, "first hue", POINTS[1]),
        (ord(Ink.Cobalt), false, "last hue", POINTS[2]),
      ]))
      defer: removeFile(path)

      check loadScene(scene, path).contains("Loaded 3")
      check scene[0].ink == Ink.Grid
      check scene[1].ink == Ink.Rose
      check scene[2].ink == Ink.Cobalt
      check not scene[2].isVisible


    test "a file from a version this build predates is refused rather than guessed at":
      # The floor never rises, so only the ceiling can refuse: a later format may mean
      #   anything at all by these bytes, and there is nothing honest to do but say so.
      var scene = initScene()
      discard scene.addItem(POINTS[0], "keep", Ink.Rose)
      let path = getTempDir() / "visualiser_suite_scene_ahead.rgascene"
      writeFile(path, sceneFileOf(VERSION_SCENE + 1'u8, @[
        (ord(Ink.Rose), true, "future", POINTS[1]),
      ]))
      defer: removeFile(path)

      check loadScene(scene, path).contains("version this build cannot read")
      check scene.len == 1
      check toText(scene[0].label) == "keep"
      check not readsSceneVersion(0'u8) # A version byte of zero was never written either.


    test "a saved scene keeps creation order however its slots were reused":
      # What version 3 is for. Removing and re-adding drops the new item into the freed
      #   slot, so slot order and creation order disagree -- and it is creation order the
      #   replay has to walk, or a file plays back a construction that never happened.
      var original = initScene()
      for i in 0 ..< 4:
        discard original.addItem(POINTS[i], "p" & $i, inkCycled(i))
      original.removeItem(1)
      discard original.addItem(POINTS[4], "late", Ink.Rose) # reuses slot 1
      check original.len == 4

      let path = getTempDir() / "visualiser_suite_scene_order.rgascene"
      check saveScene(original, path).contains("Saved 4")
      defer: removeFile(path)

      var loaded = initScene()
      check loadScene(loaded, path).contains("Loaded 4")
      check toText(loaded[0].label) == "p0"
      check toText(loaded[1].label) == "p2"
      check toText(loaded[2].label) == "p3"
      check toText(loaded[3].label) == "late"
      # And the order survives a second trip, since loading rebuilds ordinals from the
      #   file's own sequence rather than from wherever the slots landed.
      check saveScene(loaded, path).contains("Saved 4")
      var again = initScene()
      check loadScene(again, path).contains("Loaded 4")
      for slot in 0 ..< 4:
        check toText(again[slot].label) == toText(loaded[slot].label)


    test "a loaded scene arrives one object at a time, replaying its construction":
      # A load stamps borns from the caller's clock forward, which is what makes each
      #   object still be growing in when the next arrives (`mesh.animationProgress` reads
      #   a born in the future as zero size). Checked against the file, not against the
      #   scene it came from: the whole point is that the replay is reconstructed from the
      #   sequence rather than from a clock reading nobody saved.
      var original = initScene()
      for i in 0 ..< 5:
        discard original.addItem(POINTS[i], "p" & $i, inkCycled(i))
      let path = getTempDir() / "visualiser_suite_scene_replay.rgascene"
      check saveScene(original, path).contains("Saved 5")
      defer: removeFile(path)

      const CLOCK = 40.0
      var loaded = initScene()
      check loadScene(loaded, path, CLOCK).contains("Loaded 5")
      check loaded[0].born =~ CLOCK
      for slot in 1 ..< 5:
        check loaded[slot].born > loaded[slot - 1].born
        # Still growing in as the next one lands, rather than a queue of separate pop-ins.
        check loaded[slot].born - loaded[slot - 1].born < ANIMATION_SECONDS
      check loaded[4].born - loaded[0].born <= SECONDS_REPLAY_WHOLE

      # No clock, no replay: a caller with nothing to animate for gets a grown scene.
      var batched = initScene()
      check loadScene(batched, path).contains("Loaded 5")
      check batched[0].born == 0.0


    test "loading a missing path reports cleanly and leaves scene untouched":
      var scene = initScene()
      discard scene.addItem(POINTS[0], "keep", Ink.Rose)
      let path = getTempDir() / "visualiser_suite_scene_does_not_exist.rgascene"

      check loadScene(scene, path).contains("No such file")
      check scene.len == 1


    test "loading a file naming more items than this build's capacity is rejected":
      var scene = initScene()
      discard scene.addItem(POINTS[0], "keep", Ink.Rose)

      var
        count = uint32(ITEMS_MAX + 1)
        count_bytes = newString(4)
      copyMem(addr count_bytes[0], addr count, 4)
      let path = getTempDir() / "visualiser_suite_scene_toobig.rgascene"
      writeFile(path, "RGAS" & char(2) & char(ord(Basis.high) + 1) & count_bytes)
      defer: removeFile(path)

      check loadScene(scene, path).contains("more than")
      check scene.len == 1



suite "History":
  proc scenesEqual(a, b: Scene): bool =
    ## Compare two scenes item by item, rather than through a plain `==`: `Scene`
    ## embeds `Multivector`, whose own `==` is an intentional compile error (see
    ## `pga/multivectors.nim`) steering every other caller toward `=~`'s tolerance --
    ## this is that same comparison, just folded field by field over a whole scene
    ## rather than one multivector at a time.
    if a.len != b.len: return false
    for slot in 0 ..< ITEMS_MAX:
      if a.isAlive(slot) != b.isAlive(slot): return false
      if not a.isAlive(slot): continue
      let (item_a, item_b) = (a[slot], b[slot])
      if not (item_a.geometry =~ item_b.geometry): return false
      if item_a.label != item_b.label: return false
      if item_a.ink != item_b.ink: return false
      if item_a.isVisible != item_b.isVisible: return false
    true


  test "undo and redo retrace every recorded state exactly, and canUndo/canRedo agree":
    var scene = initScene()
    var camera = initCameraDefault()
    var history = initHistory(scene, camera)
    var snapshots = @[scene] # Index 0 is the seeded initial state.
    for i in 0 ..< CAPACITY_HISTORY - 1:
      scene.addItem(POINTS[i mod SAMPLES], "p" & $i, inkCycled(i))
      history.record(scene, camera)
      snapshots.add(scene)

    # Cursor sits at the last recorded state: nothing to redo yet, everything to undo.
    check not history.canRedo
    check history.canUndo

    # Walk all the way back, checking scene equality against what was actually recorded
    #   at each step, and that canUndo agrees with undo's own success, right up to the
    #   seeded state undo can never reach past.
    for i in countdown(len(snapshots) - 1, 1):
      check history.canUndo
      check history.undo(scene, camera)
      check scenesEqual(scene, snapshots[i - 1])
    check not history.canUndo
    check not history.undo(scene, camera)
    check scenesEqual(scene, snapshots[0])

    # Walk all the way forward again, the same way.
    for i in 1 ..< len(snapshots):
      check history.canRedo
      check history.redo(scene, camera)
      check scenesEqual(scene, snapshots[i])
    check not history.canRedo
    check not history.redo(scene, camera)


  test "recording past capacity drops the oldest entry instead of growing":
    var scene = initScene()
    var camera = initCameraDefault()
    var history = initHistory(scene, camera)
    var snapshots = @[scene]
    for i in 0 ..< CAPACITY_HISTORY + 4: # Four states past what the timeline retains.
      scene.addItem(POINTS[i mod SAMPLES], "p" & $i, inkCycled(i))
      history.record(scene, camera)
      snapshots.add(scene)

    # Only the most recent CAPACITY_HISTORY states are still reachable: undoing all the
    #   way back lands on the oldest still-retained one, CAPACITY_HISTORY - 1 steps back
    #   from the latest, not on the very first state ever recorded.
    var count_undone = 0
    while history.undo(scene, camera): inc count_undone
    check count_undone == CAPACITY_HISTORY - 1
    check scenesEqual(scene, snapshots[^CAPACITY_HISTORY])


  test "a fresh record after undo truncates the redo-able future":
    var scene = initScene()
    var camera = initCameraDefault()
    var history = initHistory(scene, camera)
    scene.addItem(POINTS[0], "a", Ink.Rose)
    history.record(scene, camera)
    let state_a = scene

    scene.addItem(POINTS[1], "b", Ink.Rose)
    history.record(scene, camera) # A state undo will later discard, never redone.

    discard history.undo(scene, camera)
    check scenesEqual(scene, state_a)
    check history.canRedo

    scene.addItem(POINTS[2], "c", Ink.Rose) # Diverges from the discarded state above.
    history.record(scene, camera)
    check not history.canRedo
    check not history.redo(scene, camera)

    check history.canUndo
    discard history.undo(scene, camera)
    check scenesEqual(scene, state_a)


  test "crossing a step either way restores the view that step's own edit was made from":
    # The whole point of carrying the camera: whatever a step adds or takes away has to be
    #   on screen as it happens, which means under the view that edit was made from -- not
    #   under wherever the camera has since been orbited to, and not under the view the
    #   *previous* edit happened to be made from however long ago.
    template checkAimedLike(taken, wanted: Camera) =
      check taken.azimuth =~ wanted.azimuth
      check taken.elevation =~ wanted.elevation
      check taken.distance =~ wanted.distance

    var scene = initScene()
    var camera = initCameraDefault()
    var history = initHistory(scene, camera)

    # Two edits, each made from its own distinctly different viewpoint.
    camera.azimuth = 0.25
    camera.distance = 11.0
    scene.addItem(POINTS[0], "a", Ink.Rose)
    history.record(scene, camera)
    let camera_a = camera

    camera.azimuth = 1.75
    camera.distance = 29.0
    camera.elevation = -0.4
    scene.addItem(POINTS[1], "b", Ink.Rose)
    history.record(scene, camera)
    let camera_b = camera

    # Orbiting after the fact records nothing of its own, so a step ignores wherever the
    #   camera has drifted to since.
    camera.azimuth = -2.5
    camera.distance = 3.0
    camera.elevation = 1.1

    # Undoing `b` takes the scene back to one item and the view back to where `b` was
    #   built -- `b` is what vanishes, so `b`'s own view is the one to watch it from.
    check history.undo(scene, camera)
    checkAimedLike(camera, camera_b)
    check scene.len == 1

    # Redoing it crosses the same step the other way, and lands on the same view.
    check history.redo(scene, camera)
    checkAimedLike(camera, camera_b)
    check scene.len == 2

    # Back past `a` in turn: its own view, not the default the timeline was seeded under.
    check history.undo(scene, camera)
    check history.undo(scene, camera)
    checkAimedLike(camera, camera_a)
    check scene.len == 0
    check not (camera.azimuth =~ initCameraDefault().azimuth)



suite "Camera Aim":
  let SCALE_AIM = DrawExtent(scale: DrawScale(
    extent_furniture: 100.0, eye: ORIGIN, radius_horizon: 90.0,
  )) ## No ribbon fields: nothing here tessellates anything, it only aims a camera.

  const
    (WIDTH_AIM, HEIGHT_AIM) = (1440, 900) ## Frame the centred box is measured in.
    AZIMUTHS_AIM = [0.0, 0.7, 1.6, 2.4, 3.1]
    ELEVATIONS_AIM = [-0.6, 0.2, 0.9]
      ## Orientations the framing rule is swept over. Swept, not sampled at one camera:
      ## twice now a rule about screen geometry here passed a single-orientation check and
      ## was plainly wrong from a camera nobody had looked from.

  proc marginsCentred(): (float, float) =
    ## Measure how far in the centred box begins, across and down, in this suite's frame.
    ##   Read out of `camera.reachCentred` rather than written again here, so a case
    ##   checking something *against* the box cannot come to disagree with the box.
    let (reach_across, reach_down) = reachCentred(WIDTH_AIM, HEIGHT_AIM, 0.0)
    (0.5*(float(WIDTH_AIM) - reach_across), 0.5*(float(HEIGHT_AIM) - reach_down))


  proc placementAim(azimuth, elevation: float): Camera =
    ## Build a camera orbiting the origin at the given angles, for the sweeps below.
    initCamera(target = ORIGIN, distance = 12.0, azimuth = azimuth, elevation = elevation)

  proc sceneOf(objects: varargs[Multivector]): (Scene, Selection) =
    ## Build a scene holding exactly these objects, with every one of them picked.
    var (scene, picked) = (initScene(), Selection())
    for m in objects:
      picked.toggle(scene.addItem(m, "m", Ink.Rose))
    (scene, picked)

  proc framedFor(
    scene: Scene; picked: Selection; camera: Camera
  ): CameraPlacement =
    ## Resolve where the framing rule puts a camera for a whole selection.
    let aim = aimFor(scene, picked, none(Preview), camera.drawExtentFor(HEIGHT_AIM))
    check aim.isSome
    placementFor(aim.get, scene, picked, none(Preview), camera, WIDTH_AIM, HEIGHT_AIM)


  test "on screen is not in view: the box is two thirds of the frame, not all of it":
    # What the whole rule rests on. An object clinging to the edge is visible without
    #   being what the view is about, and this is the case that says so.
    let point = toMultivector(Position(x: 9.0, y: -7.0, z: 4.0))
    let camera = placementAim(1.6, 0.2)
    let at = projectToScreen(
      camera.initMatrixViewProjection(WIDTH_AIM/HEIGHT_AIM), WIDTH_AIM, HEIGHT_AIM,
      anchorFor(point, camera.drawExtentFor(HEIGHT_AIM)).get,
    )
    check at.isInFront
    check at.x >= 0.0 and at.x <= float(WIDTH_AIM) # On screen ...
    check at.y >= 0.0 and at.y <= float(HEIGHT_AIM)
    check at.y < 0.5*(1.0 - FRACTION_VIEW_CENTRED)*float(HEIGHT_AIM) # ... above the box.
    check not isShownCentrally(point, camera, WIDTH_AIM, HEIGHT_AIM)


  proc offsetFromTarget(camera: Camera; across, down: float): Multivector =
    ## Build a point standing off the camera's own target, sideways and downward, by these
    ## fractions of its orbit distance -- which is to say by those tangents from the sight
    ## axis, since the offsets are square to it and so leave the depth alone.
    let axes = camera.frame(camera.eye)
    toMultivector(
      camera.target + (across*camera.distance)*axes.axis_right -
        (down*camera.distance)*axes.axis_up
    )


  test "a wider window does not widen what counts as in view":
    # The defect the box's shape exists to prevent. The field of view is vertical, so a
    #   fraction of the frame's *width* is `aspect` times as much world: on the shipped
    #   build the box reached 23.9 degrees off the sight axis across a 1440x900 window
    #   against 15.4 down, and 7.3 across a 390x844 phone. Picking an object on a desktop
    #   therefore almost never moved the camera, which is the whole complaint. Every width
    #   from square to twice the height now returns one verdict.
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        let camera = placementAim(azimuth, elevation)
        for step in 1 .. 12:
          let place = offsetFromTarget(camera, 0.06*float(step), 0.0)
          let verdict = isShownCentrally(place, camera, HEIGHT_AIM, HEIGHT_AIM)
          for width in [HEIGHT_AIM, 1200, WIDTH_AIM, 2*HEIGHT_AIM]:
            check isShownCentrally(place, camera, width, HEIGHT_AIM) == verdict


  test "the box never reaches further across than it reaches down":
    # The property that makes the one above true of *every* frame rather than of wide ones
    #   only: a tall frame keeps its own narrower reach across -- a phone held upright is
    #   deliberately left as it was -- so the rule is an implication, not an equality.
    for (width, height) in [(HEIGHT_AIM, HEIGHT_AIM), (WIDTH_AIM, HEIGHT_AIM), (390, 844)]:
      for azimuth in AZIMUTHS_AIM:
        let camera = placementAim(azimuth, 0.2)
        for step in 1 .. 14:
          let reach = 0.06*float(step)
          if isShownCentrally(offsetFromTarget(camera, reach, 0.0), camera, width, height):
            check isShownCentrally(
              offsetFromTarget(camera, 0.0, reach), camera, width, height
            )


  test "on a wide frame the box is as far across as it is down, to the pixel":
    # The shape itself, measured rather than asserted: walk a point out sideways until it
    #   leaves the box and check where it went. The edge stands at the frame's *height*,
    #   not its width -- 300 px from the middle of a 1440x900 frame rather than 480 -- less
    #   the room the drawn dot takes.
    let camera = placementAim(0.0, 0.0)
    let
      edge_measured = 0.5*FRACTION_VIEW_CENTRED*float(HEIGHT_AIM) - INSET_POINT_SHOWN
      edge_by_width = 0.5*FRACTION_VIEW_CENTRED*float(WIDTH_AIM) - INSET_POINT_SHOWN
    var reach_last = 0.0
    for step in 1 .. 2000:
      let reach = 0.001*float(step)
      if not isShownCentrally(
        offsetFromTarget(camera, reach, 0.0), camera, WIDTH_AIM, HEIGHT_AIM
      ): break
      reach_last = reach
    # Back out of the tangent the sweep stopped at into the pixels it stands for.
    let edge_found = reach_last*0.5*float(HEIGHT_AIM) /
      tan(0.5*degToRad(camera.degrees_field_of_view))
    check abs(edge_found - edge_measured) < 2.0
    check abs(edge_found - edge_by_width) > 100.0


  test "a point and a plane have to fit inside the box; a line only to cross it":
    # The two criteria, stated apart, and the split follows what each shape is *drawn* at.
    #   A line runs out to the horizon, which moves with the camera, so demanding it fit
    #   would demand a camera pulled back until it was a speck. A plane's disc is a fixed
    #   `EXTENT_PLANE_F` across whatever the camera does, so it is a thing a frame can hold.
    let camera = placementAim(0.0, 0.2)
    let
      far_away = Position(x: 26.0, y: 0.0, z: 0.0)
      near_middle = Position(x: 0.0, y: 0.0, z: 0.4)
    let
      point = toMultivector(far_away)
      line = toMultivector(far_away) ∧ toMultivector(near_middle)
      plane = toMultivector(far_away) ∧ toMultivector(near_middle) ∧
        toMultivector(Position(x: 0.0, y: 1.0, z: 0.4))
    # All three reach that same far point; the line alone is in view for merely doing so.
    check not isShownCentrally(point, camera, WIDTH_AIM, HEIGHT_AIM)
    check isShownCentrally(line, camera, WIDTH_AIM, HEIGHT_AIM)
    check not isShownCentrally(plane, camera, WIDTH_AIM, HEIGHT_AIM)


  test "a previewed construction carries where it is drawn and what it came from":
    # The one statement of a construction not yet committed, shared by the drag's own
    #   rubber-band answer and both apply pickers. A line joined with a point is the case
    #   that exercises every field at once: it makes a plane, and that plane's disc is
    #   centred on the construction's own point rather than on its closest approach to the
    #   origin.
    var (scene, picked) = (initScene(), Selection())
    let
      line = GENERAL_FIRST[1]
      point = GENERAL_SECOND[0]
      slot_line = scene.addItem(line, "L", Ink.Rose)
      slot_point = scene.addItem(point, "p", Ink.Rose)
    let previewed = scene.previewApplying(Operation.Wedge, slot_line, slot_point)
    check previewed.get.geometry =~ applyOperation(Operation.Wedge, line, point)
    check previewed.get.operands == some((slot_line, slot_point))
    check previewed.get.anchor.get =~
      creationAnchor(Operation.Wedge, line, point, previewed.get.geometry).get
    check not (previewed.get.anchor.get =~ positionAnchor(previewed.get.geometry).get)

    # Nothing drawable, nothing previewed -- the one test that covers a pair of the wrong
    #   grades and a pair already lying on each other alike.
    check scene.previewApplying(Operation.WedgeAnti, slot_point, slot_point).isNone
    # And nothing at all where a picker is left open across a delete.
    scene.removeItem(slot_point)
    check scene.previewApplying(Operation.Wedge, slot_line, slot_point).isNone

    # An edit session's own staged geometry is the same type with neither field, which is
    #   what keeps it out of the framing rule below.
    check previewStaging(line).anchor.isNone
    check previewStaging(line).operands.isNone
    discard picked


  test "a staged preview is framed with the operands it names; an edit stands alone":
    # What a reader is judging when a picker previews an operation is the *result beside
    #   its inputs*: a plane that fits the frame while the two points that made it sit off
    #   the edge answers nothing. An edit session is the opposite case and must stay that
    #   way -- its staged geometry replaces the very object it would be framed against.
    var scene = initScene()
    let
      slot_first = scene.addItem(
        toMultivector(Position(x: 16.0, y: -13.0, z: 4.0)), "m", Ink.Rose
      )
      slot_second = scene.addItem(
        toMultivector(Position(x: -12.0, y: 14.0, z: -6.0)), "n", Ink.Rose
      )
    let staged = scene.previewApplying(Operation.Wedge, slot_first, slot_second)
    check staged.isSome
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        let camera = placementAim(azimuth, elevation)
        let aim = aimFor(scene, Selection(), staged, camera.drawExtentFor(HEIGHT_AIM))
        let framed = camera.placed(placementFor(
          aim.get, scene, Selection(), staged, camera, WIDTH_AIM, HEIGHT_AIM
        ))
        check isShownAll(
          scene, Selection(), staged, framed, WIDTH_AIM, HEIGHT_AIM
        )
        # Each operand by name, not merely "everything watched" -- that is the property.
        for slot in [slot_first, slot_second]:
          check isShownCentrally(
            scene.geometryOf(slot), framed, WIDTH_AIM, HEIGHT_AIM,
            scene.anchorOverrideAt(slot),
          )
        # Two points that far apart cannot both be framed by panning alone.
        check framed.distance > camera.distance

    # The edit-session case, over the same pair: staging one of those points names no
    #   operands, so the other is left out and no pull-back is owed.
    let alone = some(previewStaging(scene.geometryOf(slot_first)))
    let camera = placementAim(0.7, 0.2)
    let aim = aimFor(scene, Selection(), alone, camera.drawExtentFor(HEIGHT_AIM))
    let framed = camera.placed(placementFor(
      aim.get, scene, Selection(), alone, camera, WIDTH_AIM, HEIGHT_AIM
    ))
    check isShownAll(scene, Selection(), alone, framed, WIDTH_AIM, HEIGHT_AIM)
    check framed.distance == camera.distance
    check not isShownCentrally(
      scene.geometryOf(slot_second), framed, WIDTH_AIM, HEIGHT_AIM
    )


  test "a plane is centred by its middle and bounded by its rim, against two bounds":
    # The two questions a disc's own size forces apart. Its centre says whether the plane is
    #   what the view is about, so it answers to the centred box like any other position;
    #   its rim says only whether the whole circle can be seen, so it answers to the frame.
    #   Holding the rim to the box as well is what made picking the demo's ground plane
    #   throw the camera from 19 out to 29.9 where 19 already showed the whole circle.
    let ground = toMultivector(ORIGIN) ∧ toMultivector(Position(x: 1.0, y: 0.0, z: 0.0)) ∧
      toMultivector(Position(x: 0.0, y: 1.0, z: 0.0))
    let (margin_x, margin_y) = marginsCentred()

    proc rimAt(place: Camera; centre: Position): tuple[past_box, off_frame: bool] =
      ## Walk the drawn rim, reporting whether it reaches past the centred box and whether
      ## any of it leaves the frame -- the two bounds this rule now tells apart.
      let
        axes = frame(ground).get
        view_projection = place.initMatrixViewProjection(WIDTH_AIM/HEIGHT_AIM)
      for step in 0 ..< 96:
        let turn = (2.0*PI*float(step))/96.0
        let at = projectToScreen(
          view_projection, WIDTH_AIM, HEIGHT_AIM,
          centre + EXTENT_PLANE_F*(cos(turn)*axes.axis_first + sin(turn)*axes.axis_second),
        )
        if at.x < margin_x or at.x > float(WIDTH_AIM) - margin_x or
            at.y < margin_y or at.y > float(HEIGHT_AIM) - margin_y:
          result.past_box = true
        if at.x < 0.0 or at.x > float(WIDTH_AIM) or
            at.y < 0.0 or at.y > float(HEIGHT_AIM):
          result.off_frame = true

    # Standing where the rim reaches past the centred box and stays on screen: in view, and
    #   *because* the rim is only held to the frame. Both halves asserted, neither assumed.
    var camera = placementAim(0.0, 0.42)
    camera.distance = 19.0
    let spread = rimAt(camera, positionAnchor(ground).get)
    check spread.past_box
    check not spread.off_frame
    check isShownCentrally(ground, camera, WIDTH_AIM, HEIGHT_AIM)

    # Now far enough back that the whole disc fits well inside the frame, and walk where it
    #   is drawn out sideways until its own centre leaves the centred box. The rim is still
    #   wholly on screen there, so what refuses it is the centre alone -- the half a
    #   rim-only test would miss.
    var afar = camera
    afar.distance = 40.0
    let projection_afar = afar.initMatrixViewProjection(WIDTH_AIM/HEIGHT_AIM)
    # Sideways along the camera's own right, which at any elevation lies flat in the plane
    #   the disc is drawn in -- so this walks where the circle is centred without lifting it
    #   off its own plane, and moves it across the screen rather than into the distance.
    let across = afar.frame(afar.eye).axis_right
    var found_off_centre = false
    for step in 1 .. 60:
      let drawn = ORIGIN + float(step)*across
      let at = projectToScreen(projection_afar, WIDTH_AIM, HEIGHT_AIM, drawn)
      let is_centre_out = at.x < margin_x or at.x > float(WIDTH_AIM) - margin_x or
        at.y < margin_y or at.y > float(HEIGHT_AIM) - margin_y
      if not (is_centre_out and not rimAt(afar, drawn).off_frame): continue
      found_off_centre = true
      check not isShownCentrally(ground, afar, WIDTH_AIM, HEIGHT_AIM, some(drawn))
      break
    check found_off_centre # The walk really did straddle it, so the check above ran.

    # And close in, where the rim leaves the frame, it is out of view however centred it is.
    var near = camera
    near.distance = 6.0
    check rimAt(near, positionAnchor(ground).get).off_frame
    check not isShownCentrally(ground, near, WIDTH_AIM, HEIGHT_AIM)


  test "a plane filling the frame is not in view; framing pulls its whole disc in":
    # The complaint this rule was rewritten for: a disc wide enough to cover the box was
    #   read as in view -- the sight axis struck it, so picking it moved the camera not at
    #   all -- while the reader could see no edge of the circle anywhere.
    let ground = toMultivector(ORIGIN) ∧ toMultivector(Position(x: 1.0, y: 0.0, z: 0.0)) ∧
      toMultivector(Position(x: 0.0, y: 1.0, z: 0.0))
    let (scene, picked) = sceneOf(ground)
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        # Close in, where a disc of radius `EXTENT_PLANE_F` cannot fit at all.
        var camera = placementAim(azimuth, elevation)
        camera.distance = 6.0
        check not isShownCentrally(ground, camera, WIDTH_AIM, HEIGHT_AIM)
        let framed = camera.placed(framedFor(scene, picked, camera))
        check isShownCentrally(ground, framed, WIDTH_AIM, HEIGHT_AIM)
        check framed.distance > camera.distance # Only a pull-back could have done it.
        # Every point of the rim, not just the two the box's own axes happen to catch.
        let axes = frame(ground).get
        let view_projection =
          framed.initMatrixViewProjection(WIDTH_AIM/HEIGHT_AIM)
        let (margin_x, margin_y) = marginsCentred()
        var is_past_box = false
        for step in 0 ..< 96:
          let turn = (2.0*PI*float(step))/96.0
          let at = projectToScreen(
            view_projection, WIDTH_AIM, HEIGHT_AIM,
            positionAnchor(ground).get + EXTENT_PLANE_F*(
              cos(turn)*axes.axis_first + sin(turn)*axes.axis_second
            ),
          )
          check at.isInFront
          check at.x >= 0.0 and at.x <= float(WIDTH_AIM)
          check at.y >= 0.0 and at.y <= float(HEIGHT_AIM)
          # ... and the rim is allowed to reach past the *centred box* on the way, which is
          #   the whole of what this rule loosened. Without this the case would pass just as
          #   well under the stricter one and say nothing about which is in force.
          if at.x < margin_x or at.x > float(WIDTH_AIM) - margin_x or
              at.y < margin_y or at.y > float(HEIGHT_AIM) - margin_y:
            is_past_box = true
        check is_past_box
        # And it costs strictly less than making the disc fit that box would have.
        check framed.distance <
          distanceFitting(EXTENT_PLANE_F, camera, WIDTH_AIM, HEIGHT_AIM, 0.0)


  test "a plane is judged by the disc drawn, not by the one its support would carry":
    # `mesh.addPlane` centres a disc on the item's own creation anchor where it has one,
    #   and on the demo scene's own planes the two stand as far as 3.7 units apart against
    #   a radius of 8 -- so a test ringing the support would frame a circle nobody sees.
    let ground = toMultivector(ORIGIN) ∧ toMultivector(Position(x: 1.0, y: 0.0, z: 0.0)) ∧
      toMultivector(Position(x: 0.0, y: 1.0, z: 0.0))
    var camera = placementAim(0.0, 0.9)
    camera.distance = 32.0
    # Fits about its own support at this distance, and does not once the disc is drawn a
    #   long way off along the plane instead.
    check isShownCentrally(ground, camera, WIDTH_AIM, HEIGHT_AIM)
    check not isShownCentrally(
      ground, camera, WIDTH_AIM, HEIGHT_AIM, some(Position(x: 14.0, y: 0.0, z: 0.0))
    )
    # And the framing rule follows the same anchor, item by item: the same plane in the
    #   same scene at the same camera costs nothing without one and moves the view with it.
    let (scene_support, picked_support) = sceneOf(ground)
    check framedFor(scene_support, picked_support, camera) == camera.placementOf

    var (scene_drawn, picked_drawn) = (initScene(), Selection())
    picked_drawn.toggle(scene_drawn.addItem(
      ground, "ground", Ink.Rose, 0.0, some(Position(x: 14.0, y: 0.0, z: 0.0))
    ))
    let framed = framedFor(scene_drawn, picked_drawn, camera)
    check not (framed == camera.placementOf)
    check framed.target.x > camera.target.x # Panned toward the circle actually drawn.
    check isShownAll(
      scene_drawn, picked_drawn, none(Preview), camera.placed(framed),
      WIDTH_AIM, HEIGHT_AIM,
    )


  test "a bound grows to hold a whole disc, and a disc swallowing it takes over":
    # `widened` over balls rather than points, which is what lets the distance search
    #   bracket a plane at all: bounding a plane by its anchor alone leaves the search
    #   starting from a sphere of radius nothing and never reaching far enough.
    let bound = SphereWorld(centre: ORIGIN, radius: 1.0)
    let held = bound.widened(Position(x: 5.0, y: 0.0, z: 0.0), 2.0)
    check held.radius =~ 4.0 # From -1 to +7 across, so eight wide.
    check held.centre =~ Position(x: 3.0, y: 0.0, z: 0.0)
    # A point is the reach-nothing case, unchanged.
    check bound.widened(Position(x: 5.0, y: 0.0, z: 0.0), 0.0).radius =~ 3.0
    # Contained outright, either way round, including concentric -- where there is no
    #   direction to slide the centre along at all.
    check bound.widened(Position(x: 0.5, y: 0.0, z: 0.0), 0.25) == bound
    let swallowed = bound.widened(ORIGIN, 9.0)
    check swallowed.radius =~ 9.0
    check swallowed.centre =~ ORIGIN


  test "a point fits with its drawn dot inside the box, not only its middle":
    # `INSET_POINT_SHOWN`, stated as the property it exists for: a point whose centre lands
    #   a pixel inside the box is not in view, because half its dot is not.
    let camera = placementAim(0.0, 0.0)
    let margin_y = 0.5*(1.0 - FRACTION_VIEW_CENTRED)*float(HEIGHT_AIM)
    var found_edge = false
    # Walk a point down the frame until it crosses the inset edge, then check that a bare
    #   centre test would have admitted it a little sooner.
    for step in 0 .. 400:
      let place = toMultivector(Position(x: 0.0, y: 0.0, z: 0.02*float(step)))
      let at = projectToScreen(
        camera.initMatrixViewProjection(WIDTH_AIM/HEIGHT_AIM), WIDTH_AIM, HEIGHT_AIM,
        anchorFor(place, camera.drawExtentFor(HEIGHT_AIM)).get,
      )
      if at.y > margin_y and at.y < margin_y + INSET_POINT_SHOWN:
        check not isShownCentrally(place, camera, WIDTH_AIM, HEIGHT_AIM)
        found_edge = true
    check found_edge # The sweep really did straddle the edge, so the check above ran.


  test "every selected object is brought into view, not merely the first":
    # The rule, over orientations. Two points wide apart cannot both be framed by panning
    #   alone, so this is also where the pull-back earns its keep.
    let (scene, picked) = sceneOf(
      toMultivector(Position(x: 14.0, y: -11.0, z: 3.0)),
      toMultivector(Position(x: -9.0, y: 12.0, z: -5.0)),
    )
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        let camera = placementAim(azimuth, elevation)
        let framed = camera.placed(framedFor(scene, picked, camera))
        check isShownAll(scene, picked, none(Preview), framed, WIDTH_AIM, HEIGHT_AIM)
        check framed.distance > camera.distance # Panning alone could not have done it.


  test "a selection already in view keeps the reader's own framing, and re-centres":
    # The least-movement rule, judged where the camera *is*: judging it at the centred
    #   placement instead was the bug that pulled the view about on every pick of
    #   something already plainly visible. What survives of that is the reader's own
    #   framing -- **the distance and the orbit do not move at all** -- while the target
    #   comes to the middle of what was picked, since turning about a point is what an
    #   orbit is and a reader who picks objects means to turn about those.
    let (scene, picked) = sceneOf(
      toMultivector(Position(x: 2.0, y: 0.0, z: 0.0)),
      toMultivector(Position(x: -2.0, y: 0.0, z: 0.0)),
      toMultivector(Position(x: 0.0, y: 2.0, z: 0.0)),
    )
    # The mean of the three, computed here the classical way: the algebra's answer is what
    #   is under test, so the arithmetic it is held against lives in the test.
    let middle = Position(x: (2.0 - 2.0 + 0.0)/3.0, y: (0.0 + 0.0 + 2.0)/3.0, z: 0.0)
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        var camera = placementAim(azimuth, elevation)
        check isShownAll(scene, picked, none(Preview), camera, WIDTH_AIM, HEIGHT_AIM)
        let framed = framedFor(scene, picked, camera)
        check framed.target =~ middle
        check framed.distance == camera.distance
        check framed.azimuth == camera.azimuth
        check framed.elevation == camera.elevation
        # End to end: the ease carries the target there and leaves everything else alone.
        var tween: CameraTween
        tween.offerAim(
          camera, scene, picked, none(Preview), WIDTH_AIM, HEIGHT_AIM, 0.0, 0.35
        )
        tween.settle(camera)
        check camera.target =~ middle
        check camera.distance == placementAim(azimuth, elevation).distance
        check camera.azimuth == placementAim(azimuth, elevation).azimuth


  test "an object picked on its own is carried to the middle, and nothing else moves":
    # A single pick has one middle and it is the object itself, so the target lands on it
    #   exactly -- and once it is centred there is nothing left for a zoom or a turn to
    #   fix, which is the least-movement rule holding over everything the reader set.
    let place = Position(x: 9.0, y: -7.0, z: 4.0)
    let (scene, picked) = sceneOf(toMultivector(place))
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        let camera = placementAim(azimuth, elevation)
        let framed = framedFor(scene, picked, camera)
        check isShownAll(
          scene, picked, none(Preview), camera.placed(framed), WIDTH_AIM, HEIGHT_AIM
        )
        check framed.target =~ place
        check framed.distance == camera.distance
        check framed.azimuth == camera.azimuth
        check framed.elevation == camera.elevation


  test "a finite selection never turns the orbit":
    # The preference for pan and zoom over orbit, stated as the property it is: a finite
    #   selection's move carries no turn at all, so no fraction of it does either.
    let scenes = [
      sceneOf(toMultivector(Position(x: 9.0, y: -7.0, z: 4.0))),
      sceneOf(
        toMultivector(Position(x: 14.0, y: -11.0, z: 3.0)),
        toMultivector(Position(x: -9.0, y: 12.0, z: -5.0)),
      ),
    ]
    for (scene, picked) in scenes:
      for azimuth in AZIMUTHS_AIM:
        for elevation in ELEVATIONS_AIM:
          let camera = placementAim(azimuth, elevation)
          let framed = framedFor(scene, picked, camera)
          check framed.azimuth == camera.azimuth
          check framed.elevation == camera.elevation


  test "the camera pulls back only as far as it must, and never pulls in":
    let (scene, picked) = sceneOf(
      toMultivector(Position(x: 14.0, y: -11.0, z: 3.0)),
      toMultivector(Position(x: -9.0, y: 12.0, z: -5.0)),
    )
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        let camera = placementAim(azimuth, elevation)
        let framed = framedFor(scene, picked, camera)
        check framed.distance >= camera.distance # Never pulls in ...
        # ... and not a step further than it takes, pan and zoom judged together: a tenth
        #   of the way back along the very move fails.
        let short = camera.placementOf.toward(framed, 0.9)
        check not isShownAll(
          scene, picked, none(Preview), camera.placed(short), WIDTH_AIM, HEIGHT_AIM
        )


  test "a selection tight enough to fit already keeps the reader's own scale":
    # The half of "only when it must" that a spread selection cannot show: a distance left
    #   exactly alone, not merely one that did not grow much.
    let (scene, picked) = sceneOf(
      toMultivector(Position(x: 0.7, y: 0.4, z: 0.2)),
      toMultivector(Position(x: -0.6, y: -0.3, z: 0.5)),
    )
    for azimuth in AZIMUTHS_AIM:
      for elevation in ELEVATIONS_AIM:
        let camera = placementAim(azimuth, elevation)
        let framed = framedFor(scene, picked, camera)
        check framed.distance == camera.distance


  test "a line's own support never drags the view off the point beside it":
    # A line has only to cross the box, so where it stands is not where the camera should
    #   centre: a support forty units away would pull the view off the point picked with
    #   it and force a pull-back to drag that support back into frame, for nothing.
    let place = Position(x: 0.5, y: 0.2, z: 0.1)
    let support = Position(x: 0.0, y: 0.0, z: 40.0)
    let (point, line) = (
      toMultivector(place),
      toMultivector(support) ∧ toMultivector(Position(x: 1.0, y: 0.3, z: 40.0)),
    )
    let camera = placementAim(0.0, 0.0)
    # Picked beside a point, the point alone decides where to look and what it costs: the
    #   aim's sphere collapses onto it, so the move is a pan toward the point, cut short
    #   the moment its dot fits -- no dolly toward that distant support, ever.
    let (scene, picked) = sceneOf(point, line)
    let aim = aimFor(scene, picked, none(Preview), camera.drawExtentFor(HEIGHT_AIM))
    check aim.get.is_bound_by_fitted
    check aim.get.sphere.get.radius =~ 0.0
    let framed = framedFor(scene, picked, camera)
    check framed.distance == camera.distance
    check framed.azimuth == camera.azimuth
    check isShownAll(
      scene, picked, none(Preview), camera.placed(framed), WIDTH_AIM, HEIGHT_AIM
    )


  test "a horizon object is turned toward only as far as it takes":
    # A star is drawn fixed to the eye, so pan and zoom cannot bring it into view and the
    #   move is a turn -- the one place orbit is allowed, cut short like every other move.
    let star = attitude(
      toMultivector(Position(x: 4.0, y: 4.0, z: 1.0)) ∧
        toMultivector(Position(x: 5.0, y: 4.5, z: 1.4))
    )
    check isHorizon(star)
    let (scene_star, picked_star) = sceneOf(star)
    for azimuth in AZIMUTHS_AIM:
      let camera = placementAim(azimuth, 0.3)
      let framed = framedFor(scene_star, picked_star, camera)
      check isShownCentrally(star, camera.placed(framed), WIDTH_AIM, HEIGHT_AIM)
      check framed.target =~ camera.target # The orbit turned; what it turns about did not.
      check framed.distance =~ camera.distance
      if isShownCentrally(star, camera, WIDTH_AIM, HEIGHT_AIM): continue
      let short = camera.placementOf.toward(framed, 0.9)
      check not isShownCentrally(star, camera.placed(short), WIDTH_AIM, HEIGHT_AIM)

    # Beside anything finite, the finite framing wins outright and the angles stand: a star
    #   behind the reader and a point in front have no one placement showing both.
    let (scene_both, picked_both) =
      sceneOf(star, toMultivector(Position(x: 3.0, y: -2.0, z: 1.0)))
    let camera = placementAim(0.7, 0.2)
    let framed = framedFor(scene_both, picked_both, camera)
    check framed.azimuth == camera.azimuth
    check framed.elevation == camera.elevation


  test "an empty selection withdraws the offer, and so does geometry that draws nothing":
    var camera = placementAim(0.0, 0.2)
    var tween: CameraTween
    let (scene, picked) = sceneOf(toMultivector(Position(x: 3.0, y: -2.0, z: 1.5)))
    tween.offerAim(
      camera, scene, picked, none(Preview), WIDTH_AIM, HEIGHT_AIM, 0.0, 0.35
    )
    check tween.goal.isSome

    tween.offerAim(
      camera, scene, Selection(), none(Preview), WIDTH_AIM, HEIGHT_AIM, 0.1, 0.35
    )
    check tween.goal.isNone

    var empty: Multivector
    tween.offerAim(
      camera, scene, Selection(), some(previewStaging(empty)),
      WIDTH_AIM, HEIGHT_AIM, 0.2, 0.35,
    )
    check tween.goal.isNone


  test "the whole selection is framed end to end, through the standing offer":
    # Driving the rule the way a front-end does, rather than calling `placementFor`
    #   directly: the offer, the ease, and the arrival, over a whole animation.
    const DURATION = 0.35
    var camera = placementAim(1.6, 0.2)
    var tween: CameraTween
    let (scene, picked) = sceneOf(
      toMultivector(Position(x: 14.0, y: -11.0, z: 3.0)),
      toMultivector(Position(x: -9.0, y: 12.0, z: -5.0)),
    )
    check not isShownAll(scene, picked, none(Preview), camera, WIDTH_AIM, HEIGHT_AIM)

    tween.offerAim(
      camera, scene, picked, none(Preview), WIDTH_AIM, HEIGHT_AIM, 0.0, DURATION
    )
    for frame in 1 .. 30:
      let now = DURATION*float(frame)/20.0
      tween.offerAim( # Re-offered every frame, exactly as a front-end re-offers it.
        camera, scene, picked, none(Preview), WIDTH_AIM, HEIGHT_AIM, now, DURATION
      )
      tween.advance(camera, now, easeOutCubic)
    check tween.is_arrived
    check isShownAll(scene, picked, none(Preview), camera, WIDTH_AIM, HEIGHT_AIM)


  test "an aim widens by exactly the objects folded into it":
    let (a, b) = (Position(x: 3.0, y: 0.0, z: 0.0), Position(x: -3.0, y: 0.0, z: 0.0))
    let aim_one = none(CameraAim).aimIncluding(toMultivector(a), SCALE_AIM)
    check aim_one.get.sphere.get.centre =~ a
    check aim_one.get.sphere.get.radius =~ 0.0

    let aim_two = aim_one.aimIncluding(toMultivector(b), SCALE_AIM)
    check aim_two.get.sphere.get.centre =~ ORIGIN
    check aim_two.get.sphere.get.radius =~ 3.0
    # A bound cannot be widened by a ball it already holds, so folding one in twice leaves
    #   it exactly as it was: as a *bound*, an aim is a set and not a tally.
    check aim_two.aimIncluding(toMultivector(a), SCALE_AIM).get.sphere.get ==
      aim_two.get.sphere.get
    # Its **middle** is a tally, because a middle is: fold `a` again and the mean of the
    #   three leans back toward it. That is why `framing.watched` yields each object once
    #   -- a unary preview naming its own operand twice must not weigh it twice.
    check aim_two.get.centroid.get =~ ORIGIN
    # The sum's weight is the count -- which is what lets one field say both.
    check aim_two.get.centroid_sum.get[Basis.E4] =~ 2.0
    let aim_thrice = aim_two.aimIncluding(toMultivector(a), SCALE_AIM)
    check aim_thrice.get.centroid.get =~ Position(x: 1.0, y: 0.0, z: 0.0)
    check aim_thrice.get.centroid_sum.get[Basis.E4] =~ 3.0

    let horizon = attitude(LINES[0]) # A line's attitude is a point at the horizon.
    check isHorizon(horizon)
    let aim_star = none(CameraAim).aimIncluding(horizon, SCALE_AIM)
    check aim_star.get.heading.isSome
    check aim_star.get.sphere.isNone # A star is nowhere, so it widens nothing.


  test "an object that draws nothing aims at nothing":
    var empty: Multivector
    check aimFor(empty, SCALE_AIM).isNone


  proc aimOn(centre: Position; radius = 0.0): CameraAim =
    ## Name a bare requirement for the tween cases below, which are about the ease rather
    ## than about what any particular geometry asks for.
    CameraAim(sphere: some(SphereWorld(centre: centre, radius: radius)))

  proc placeOn(camera: Camera; target: Position): CameraPlacement =
    ## Move a camera's placement onto a target, leaving its orbit exactly as it stands.
    result = camera.placementOf
    result.target = target


  test "a tween eases toward its destination and lands on it exactly at the duration":
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let arrival = Position(x: 10.0, y: 0.0, z: 0.0)
    tween.aimAt(camera, aimOn(arrival), camera.placeOn(arrival), 0.0, DURATION)

    # Partway: strictly between start and destination, and monotonic toward it.
    var previous = 0.0
    for step in 1 .. 4:
      let now = DURATION*float(step)/5.0
      tween.advance(camera, now, easeOutCubic)
      check camera.target.x > previous
      check camera.target.x < arrival.x
      previous = camera.target.x

    tween.advance(camera, DURATION, easeOutCubic)
    check camera.target.x =~ arrival.x
    # Arrived, so nothing left to carry -- but the goal is kept, not dropped, so a
    #   caller still offering it every frame is recognised rather than re-armed.
    check tween.is_arrived
    check tween.goal.isSome


  test "a tween eases its distance too, geometrically rather than linearly":
    # Distance is a multiplicative quantity -- the wheel and `FACTOR_DOLLY_PRESS` scale it
    #   -- so the midpoint of an ease from 10 to 40 is 20, not 25.
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 10.0, 0.0, 0.4)
    var tween: CameraTween
    var arrival = camera.placementOf
    arrival.distance = 40.0
    tween.aimAt(camera, aimOn(ORIGIN, 3.0), arrival, 0.0, DURATION)
    tween.advance(camera, DURATION*0.4, easeOutCubic)
    check camera.distance =~ 10.0*pow(4.0, easeOutCubic(0.4))
    check not (camera.distance =~ 10.0 + 30.0*easeOutCubic(0.4)) # Not the linear reading.
    tween.advance(camera, DURATION, easeOutCubic)
    check camera.distance =~ 40.0


  test "retargeting mid-flight continues from where the camera reached":
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let first = Position(x: 10.0, y: 0, z: 0)
    tween.aimAt(camera, aimOn(first), camera.placeOn(first), 0.0, DURATION)
    tween.advance(camera, DURATION*0.5, easeOutCubic)
    let reached = camera.target.x
    check reached > 0.0 and reached < 10.0

    # A goal that moves must not snap the camera back to where the last ease began.
    let second = Position(x: 20.0, y: 0, z: 0)
    tween.aimAt(camera, aimOn(second), camera.placeOn(second), DURATION*0.5, DURATION)
    check tween.placement_from.target.x =~ reached
    tween.advance(camera, DURATION*0.5 + 0.001, easeOutCubic)
    check camera.target.x >= reached # Continues forward, never jumps backward.


  test "offering the goal it already holds does not restart the ease":
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let arrival = Position(x: 10.0, y: 0, z: 0)
    tween.aimAt(camera, aimOn(arrival), camera.placeOn(arrival), 0.0, DURATION)
    tween.advance(camera, DURATION*0.5, easeOutCubic)
    # Same goal, offered again -- and with a destination read off the camera as it now
    #   stands, exactly as a standing offer would recompute it.
    tween.aimAt(
      camera, aimOn(arrival), camera.placeOn(arrival), DURATION*0.5, DURATION
    )
    check tween.started == 0.0 # Clock untouched, so the ease still ends on time.


  test "a tween turns the short way round the azimuth circle":
    # An angle just past -pi is next door to one just short of +pi, not most of a turn.
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 3.0, 0.0)
    var tween: CameraTween
    var arrival = camera.placementOf
    arrival.azimuth = -3.0
    tween.aimAt(camera, aimOn(Position(x: 1, y: 0, z: 0)), arrival, 0.0, DURATION)
    tween.advance(camera, DURATION*0.5, easeOutCubic)
    check camera.azimuth > 3.0 # Onward past +pi, not back down through zero.


  test "settle puts the camera on its destination at once":
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    var arrival = camera.placementOf
    (arrival.azimuth, arrival.elevation, arrival.distance) = (1.0, 0.5, 30.0)
    tween.aimAt(camera, aimOn(ORIGIN, 2.0), arrival, 0.0, 0.35)
    tween.settle(camera)
    check camera.azimuth =~ 1.0
    check camera.elevation =~ 0.5
    check camera.distance =~ 30.0
    check tween.is_arrived


  test "an arrived tween stops writing, so the user's own camera move survives":
    # The bug this pins: the aim rule offers the selection's goal every frame. While the
    #   tween cleared its goal on arrival, that standing offer re-armed the ease each frame
    #   from wherever the user had just panned to, and dragged the camera straight back --
    #   panning was dead for as long as anything stayed selected.
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let arrival = Position(x: 4, y: 1, z: 2)
    let goal = aimOn(arrival)
    tween.aimAt(camera, goal, camera.placeOn(arrival), 0.0, 0.35)
    tween.advance(camera, 0.35, easeOutCubic)
    check tween.is_arrived
    check camera.target =~ arrival

    # The user pans, and the same goal keeps being offered every frame after.
    camera.pan(3.0, 2.0)
    let target_panned = camera.target
    for frame in 1 .. 10:
      let now = 0.35 + 0.016*float(frame)
      tween.aimAt(camera, goal, camera.placeOn(arrival), now, 0.35)
      tween.advance(camera, now, easeOutCubic)
    check camera.target =~ target_panned


  test "abandon hands the camera to the user without re-arming the standing offer":
    # `release` here would be actively wrong, and was: it clears the goal, so the aim
    #   rule's own standing offer is seen as new on the very next frame and takes the
    #   camera straight back. Keeping the goal and marking it done is what makes that
    #   offer read as already answered.
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let arrival = Position(x: 4, y: 1, z: 2)
    let goal = aimOn(arrival)
    tween.aimAt(camera, goal, camera.placeOn(arrival), 0.0, 0.35)
    tween.advance(camera, 0.10, easeOutCubic) # Mid-flight, nowhere near arrival.
    check not tween.is_arrived

    camera.pan(3.0, 2.0)
    tween.abandon()
    let target_panned = camera.target
    for frame in 1 .. 40:
      let now = 0.10 + 0.016*float(frame)
      tween.aimAt(camera, goal, camera.placeOn(arrival), now, 0.35)
      tween.advance(camera, now, easeOutCubic)
    check camera.target =~ target_panned


  test "release lets the same goal aim the camera again":
    # Withdrawing the offer is what makes picking the same object twice work: the second
    #   pick must aim afresh, not be recognised as one already delivered.
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let arrival = Position(x: 4, y: 1, z: 2)
    let goal = aimOn(arrival)
    tween.aimAt(camera, goal, camera.placeOn(arrival), 0.0, 0.35)
    tween.advance(camera, 0.35, easeOutCubic)
    camera.pan(3.0, 2.0)
    let target_panned = camera.target

    tween.release()
    check tween.goal.isNone
    tween.aimAt(camera, goal, camera.placeOn(arrival), 1.0, 0.35)
    check tween.goal.isSome
    check not tween.is_arrived
    tween.advance(camera, 1.0 + 0.35, easeOutCubic)
    check camera.target =~ arrival
    check not (camera.target =~ target_panned)



suite "Selection":
  proc ordered(selection: Selection): seq[int] =
    ## Read the whole selection out in pick order, so a test can state the order it
    ## expects in one line rather than indexing position by position.
    for position in 0 ..< selection.len: result.add(selection.at(position))


  test "a pulse covers the same ground however many frames it is cut into":
    # Frame-rate independence, which is the whole reason the travel advances by elapsed
    #   seconds rather than by a step a frame. Driven on the browser too: 3 s of clock
    #   moved the head 178.3 px at 36 fps, 179.0 at 60 and 179.6 at 144, against 180.
    proc travelAfter(seconds_total: float; frames: int; lap: float): float =
      var clock: PulseClock
      var seconds = 0.0
      clock.tick(seconds)
      for _ in 0 ..< frames:
        seconds += seconds_total/float(frames)
        let step = clock.secondsStep(seconds)
        clock.tick(seconds)
        clock.advance(0, lap, step)
      clock.travelAt(0)

    # One second at the shared speed is `SPEED_MARKER_PULSE` pixels, whatever it laps on.
    for frames in [12, 60, 144, 600]:
      check travelAfter(1.0, frames, 900.0) =~ SPEED_MARKER_PULSE

    # **And the same pixels on a short outline as on a long one.** This is what the units
    #   buy and what a phase could not: a phase advanced by `speed/around`, so one second
    #   bought three times the share of a 300-px outline that it bought of a 900-px one,
    #   and the head's screen pace was whatever the camera had most recently made the
    #   outline. The comet is supposed to travel at a speed, not at a lap time.
    check travelAfter(1.0, 60, 300.0) =~ travelAfter(1.0, 60, 900.0)

  test "a pulse ignores an absence, rather than travelling all of it at once":
    # A backgrounded tab stops its animation callbacks; the gap it comes back with is not
    #   a frame, and spending it in one step would land the comet anywhere.
    var clock: PulseClock
    clock.tick(0.0)
    check clock.secondsStep(1.0/60.0) =~ 1.0/60.0
    check clock.secondsStep(90.0) =~ SECONDS_STEP_PULSE_MAX
    # And a clock that ran backwards rewinds nothing.
    check clock.secondsStep(-5.0) == 0.0

  test "each slot keeps its own pulse, and a reused slot starts afresh":
    var clock: PulseClock
    clock.tick(0.0)
    # The step is read before the tick that consumes it, which is the order both frame
    #   loops use: one reading, then every slot advanced by it.
    let step = clock.secondsStep(1.0)
    clock.tick(1.0)
    clock.advance(3, 600.0, step)
    check clock.travelAt(3) > 0.0
    check clock.travelAt(4) == 0.0 # Untouched, so still at the head of its own lap.
    clock.forget(3)
    check clock.travelAt(3) == 0.0
    # Out of range is a question with no answer, not a crash.
    check clock.travelAt(-1) == 0.0
    check clock.travelAt(ITEMS_MAX) == 0.0
    # And the carried travel is kept below one lap rather than accumulating, which is what
    #   stops a change in the lap being multiplied by however many laps have gone by --
    #   the original teleport, which an unreduced pixel offset would have reproduced.
    var carried: PulseClock
    carried.tick(0.0)
    for frame in 1 .. 600:
      let seconds = float(frame)/60.0
      let step = carried.secondsStep(seconds)
      carried.tick(seconds)
      carried.advance(0, 120.0, step)
      check carried.travelAt(0) < 120.0


  test "every operator reads in the library's own symbols, not an ASCII stand-in":
    # A drag used to name what it built with `^`, `v` and `->` while the panel named the
    #   same pair with the catalogue's symbols, so one object list carried both.
    check notationSubstituted(Operation.Wedge, "a", "b") == "a ∧ b"
    check notationSubstituted(Operation.WedgeAnti, "L", "G") == "L ∨ G"
    check notationSymbolic(Operation.Wedge) == "𝐦 ∧ 𝐧"
    # A picker offers the symbols alone; the English name after them is what made the
    #   popover wider than a hand can reach.
    for operation in Operation:
      check not notationSymbolic(operation).contains("  ")
    # The drag wedges carry that same picker text, so the wheel and the picker are one
    #   vocabulary rather than two a reader has to map between. The words survive only
    #   where the three are *taught*, in the drawer's own legend, which prints both.
    check labelOf(DragChoice.Join) == notationSymbolic(Operation.Wedge)
    check labelOf(DragChoice.Project) == notationSymbolic(Operation.ProjectOrthogonal)
    check wordOf(DragChoice.Join) == "join"
    # The way out to the rest of the catalogue is a bare ellipsis: beside three pieces of
    #   notation a word is the odd one out, and no operation is written with one.
    check labelOf(DragChoice.More) == "…"

  test "a picker opens on what was last applied at its own arity":
    var memory: OperationMemory
    check memory.lastOf(Arity.One) == OPERATION_FIRST_UNARY
    check memory.lastOf(Arity.Two) == OPERATION_FIRST_BINARY
    memory.remember(Operation.WedgeAnti)
    check memory.lastOf(Arity.Two) == Operation.WedgeAnti
    # Remembering a binary leaves the unary picker where it was: the two lists are
    #   disjoint, so one arity's choice can say nothing about the other's.
    check memory.lastOf(Arity.One) == OPERATION_FIRST_UNARY
    memory.remember(Operation.Bulk)
    check memory.lastOf(Arity.One) == Operation.Bulk
    check memory.lastOf(Arity.Two) == Operation.WedgeAnti


  test "a selection is hidden only when every one of its objects is":
    # What the one hide/show button on both front-ends reads to name what it would do.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var selection: Selection
    check not selection.isAllHidden(scene) # Nothing picked: nothing to show.
    selection.toggle(0)
    selection.toggle(1)
    check not selection.isAllHidden(scene)
    scene.setVisible(0, false)
    check not selection.isAllHidden(scene) # One of the two still drawn.
    scene.setVisible(1, false)
    check selection.isAllHidden(scene)


  test "toggle appends in pick order, so the first two picks name m and n":
    var selection: Selection
    selection.toggle(4)
    selection.toggle(1)
    selection.toggle(7)
    check ordered(selection) == @[4, 1, 7]
    check selection.at(0) == 4 # Operand m.
    check selection.at(1) == 1 # Operand n.


  test "toggling a picked slot drops it and closes the gap, leaving order intact":
    var selection: Selection
    for slot in [4, 1, 7]: selection.toggle(slot)
    selection.toggle(1)
    check ordered(selection) == @[4, 7]
    check not selection.contains(1)
    selection.toggle(1) # Re-picking appends at the end, not back at its old position.
    check ordered(selection) == @[4, 7, 1]


  test "selectOnly replaces the whole selection, and clear empties it":
    var selection: Selection
    for slot in [4, 1, 7]: selection.toggle(slot)
    selection.selectOnly(2)
    check ordered(selection) == @[2]
    selection.clear()
    check selection.len == 0
    check not selection.contains(2)


  test "every slot can be picked at once, and picking past that adds nothing":
    var selection: Selection
    for slot in 0 ..< ITEMS_MAX: selection.toggle(slot)
    check selection.len == ITEMS_MAX
    selection.toggle(ITEMS_MAX) # Out of range; capacity is already spent.
    check selection.len == ITEMS_MAX


  test "pruneDead drops removed slots and keeps the rest in pick order":
    # A removed slot goes straight back to the free list, so a stale pick left behind
    #   would silently reattach itself to whatever object is added next.
    var scene = initScene()
    for i in 0 ..< 3: discard scene.addItem(POINTS[i], "p" & $i, inkCycled(i))
    var selection: Selection
    for slot in [2, 0, 1]: selection.toggle(slot)
    scene.removeItem(0)
    selection.pruneDead(scene)
    check ordered(selection) == @[2, 1]
    check not selection.contains(0)


  test "implied arity is unary at one pick and binary at two or more":
    var selection: Selection
    selection.toggle(3)
    check selection.impliedArity == Arity.One
    selection.toggle(5)
    check selection.impliedArity == Arity.Two
    selection.toggle(6) # Three picked still names a binary operation, on the first two.
    check selection.impliedArity == Arity.Two



# PNG and GIF encoding, and the arena backing both, are desktop-only: each binds a C
#   entry point the JS backend has none of, so these run on that backend alone.
when not defined(js):
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
      # Signature, logical screen, colour table, application extension.
      const HEADER_LEN = 6 + 7 + 256*3 + 19
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



suite "Help":
  test "every entry lands in exactly one tab, and the tabs account for the whole table":
    # What stops a reflow that quietly drops a row to make the rest fit. `countOf` is what
    #   both front-ends size a tab from, so summing it is summing what is actually drawn.
    var total = 0
    for path in HelpPath: total += countOf(path)
    check total == len(lut_help_entries)


  test "no tab holds more than fits the smallest screen this help supports":
    # Asserted at compile time too, in `help.nim`'s own `static` block; stated here as well
    #   because that assertion is invisible in a passing run, and this is the property the
    #   whole tab split exists to hold.
    #   Two paths have bounds of their own. `keys` describes a keyboard, and the screen this
    #   bound is a proxy for is a phone; `operations` *is* the catalogue, one row per
    #   operation, and the only bound worth holding it to is that size exactly.
    for path in HelpPath:
      let entries_max =
        case path
        of HelpPath.Operations: ENTRIES_MAX_PATH_CATALOGUE
        of HelpPath.Keys: ENTRIES_MAX_PATH_KEYS
        else: ENTRIES_MAX_PATH
      check countOf(path) in 1 .. entries_max


  test "the help records every operation the build offers, by the name it offers it under":
    # Generated from the catalogue rather than transcribed, so this cannot drift -- and the
    #   case is here to say that if anyone ever transcribes it, the drift fails the build.
    for operation in Operation:
      var is_listed = false
      for entry in lut_help_entries:
        if entry.path == HelpPath.Operations and entry.action == notationSymbolic(operation):
          check entry.outcome == notationNamed(operation)
          is_listed = true
      check is_listed
    check countOf(HelpPath.Operations) == COUNT_OPERATION


  test "the help records every key, every motion and every action the view answers":
    # What "up to date" has to mean if it is to stay true: a binding added without a row
    #   fails the build the day it is added, rather than being noticed by a reader who
    #   went looking for it and found nothing.
    let text = block:
      var joined = ""
      for entry in lut_help_entries: joined &= entry.action & " " & entry.outcome & " "
      joined
    for key in Key:
      check nameOf(key) in text
    # Every motion and action is *described* by some row; the rows group them by job, so
    #   this asks for the words a reader would look for rather than the enum's own name.
    for phrase in [
      "slide the view", "lower or raise", "orbit", "further out", "faster",
      "previous or next object", "select", "back into view", "back where it started",
    ]:
      check phrase in text


  test "a tab's entries are contiguous, so neither UI renders one tab twice":
    var
      seen: set[HelpPath]
      path_last = none(HelpPath)
    for entry in lut_help_entries:
      if path_last == some(entry.path): continue
      check entry.path notin seen
      seen.incl(entry.path)
      path_last = some(entry.path)


  test "every action and outcome is written, so no row draws as a blank line":
    for entry in lut_help_entries:
      check len(entry.action) > 0
      check len(entry.outcome) > 0


  test "every tab says what it is about, so none opens on rows with no context":
    # The line above the rows carries what a two-column row cannot -- which menu this is,
    #   what a wedge is. A path added without one would render that line blank, which reads
    #   as a gap rather than as an omission.
    for path in HelpPath:
      check len(descriptionOf(path)) > 0
      # A sentence, not a label: the tab strip already carries the short form.
      check len(descriptionOf(path)) > len(titleOf(path))


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
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Rose)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(0)


  test "cursor far from every item picks nothing":
    var scene = initScene()
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Rose)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    let corner = ScreenPosition(x: 5.0, y: 5.0, depth: 0.0)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, corner).isNone


  test "hidden item is never picked":
    var scene = initScene()
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Rose)
    scene.setVisible(0, false)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE).isNone


  test "line through target is picked at screen centre":
    var scene = initScene()
    let axis_z =
      toMultivector(Position(x: 0, y: 0, z: -1)) ∧ toMultivector(Position(x: 0, y: 0, z: 1))
    scene.addItem(axis_z, "axis_z", Ink.Jade)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(0)


  test "point pick radius tolerates cursor imprecision, not unlimited slack":
    var scene = initScene()
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Rose)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    # Point itself projects exactly to CENTRE; offsetting the cursor instead of the
    #   point is what actually exercises the radius bound.
    let near = ScreenPosition(x: CENTRE.x + RADIUS_PICK_POINT - 1.0, y: CENTRE.y, depth: 0.0)
    let far = ScreenPosition(x: CENTRE.x + RADIUS_PICK_POINT + 1.0, y: CENTRE.y, depth: 0.0)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, near) == some(0)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, far).isNone


  test "line pick radius tolerates cursor imprecision, not unlimited slack":
    var scene = initScene()
    let axis_z =
      toMultivector(Position(x: 0, y: 0, z: -1)) ∧ toMultivector(Position(x: 0, y: 0, z: 1))
    scene.addItem(axis_z, "axis_z", Ink.Jade)
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    let near = ScreenPosition(x: CENTRE.x + RADIUS_PICK_LINE - 1.0, y: CENTRE.y, depth: 0.0)
    let far = ScreenPosition(x: CENTRE.x + RADIUS_PICK_LINE + 1.0, y: CENTRE.y, depth: 0.0)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, near) == some(0)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, far).isNone


  test "point wins a tie over a line through it":
    var scene = initScene()
    let axis_z =
      toMultivector(Position(x: 0, y: 0, z: -1)) ∧ toMultivector(Position(x: 0, y: 0, z: 1))
    scene.addItem(axis_z, "axis_z", Ink.Jade) # Index 0: line, passes straight through origin.
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Rose) # Index 1: point.
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(1)


  test "line wins a tie over a plane behind it":
    var scene = initScene()
    let facing = (
      toMultivector(Position(x: 0, y: -3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 0, z: 3))
    )
    let axis_z =
      toMultivector(Position(x: 0, y: 0, z: -1)) ∧ toMultivector(Position(x: 0, y: 0, z: 1))
    scene.addItem(facing, "facing", Ink.Olive) # Index 0: plane, spans the view straight on.
    scene.addItem(axis_z, "axis_z", Ink.Jade) # Index 1: line, passes straight through origin.
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(1)


  test "point wins a tie over a plane behind it":
    var scene = initScene()
    let facing = (
      toMultivector(Position(x: 0, y: -3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 3, z: -3)) ∧
      toMultivector(Position(x: 0, y: 0, z: 3))
    )
    scene.addItem(facing, "facing", Ink.Olive) # Index 0: plane, spans the view straight on.
    scene.addItem(toMultivector(Position(x: 0, y: 0, z: 0)), "p", Ink.Rose) # Index 1: point.
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
    scene.addItem(facing, "facing", Ink.Olive)
    let camera = cameraFacingOrigin(distance = 30.0)
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(0)
    for (label, cx, cy) in [
      ("top-left corner", 0.0, 0.0),
      ("bottom-right corner", float(WIDTH_PICK), float(HEIGHT_PICK)),
    ]:
      let cursor = ScreenPosition(x: cx, y: cy, depth: 0.0)
      check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, cursor).isNone


  test "a plane is picked from either side of it, whichever way its normal points":
    # **The regression case for a shipped fault.** A plane's hit test read the depth of
    #   the raw `ray ∨ plane` meet, whose weight carries which side the ray crossed from,
    #   not where the crossing is. `unitize` divides by that weight's *norm* and so keeps
    #   its sign, and `depthAgainst` is linear in its point -- so every plane met from
    #   behind its own normal reported its distance ahead of the eye negated, was read as
    #   standing behind the eye, and went unpickable at every pixel of the disc it was
    #   plainly drawn at. Measured on the built page: a plane joined from three of the
    #   opening scene's own points could not be picked anywhere on a 900x800 canvas, so
    #   no drag could reach one; the ground plane, whose normal happens to face the eye,
    #   picked fine and hid the fault.
    #   Held from both sides of one plane rather than on one built to fail: the pair is
    #   what makes the *sign* the subject, and either alone passes on a coin flip.
    for facing in [1.0, -1.0]:
      var scene = initScene()
      # Three points spanning x = 0. Ordered by `facing`, so the two runs differ in
      #   nothing but the orientation of the very same plane.
      let corners = [
        toMultivector(Position(x: 0, y: -3*facing, z: -3)),
        toMultivector(Position(x: 0, y: 3*facing, z: -3)),
        toMultivector(Position(x: 0, y: 0, z: 3)),
      ]
      scene.addItem(corners[0] ∧ corners[1] ∧ corners[2], "spanning", Ink.Olive)
      let camera = cameraFacingOrigin()
      let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
      check pickNearest(
        scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE
      ) == some(0)


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
    scene.addItem(far_plane, "far", Ink.Olive) # Index 0.
    scene.addItem(near_plane, "near", Ink.Cobalt) # Index 1.
    let camera = cameraFacingOrigin()
    let view_projection = camera.initMatrixViewProjection(WIDTH_PICK/HEIGHT_PICK)
    check pickNearest(scene, camera, view_projection, WIDTH_PICK, HEIGHT_PICK, CENTRE) == some(1)



suite "Interaction":
  test "drag operation maps to the catalogue entry it names":
    check DragOperation.Join.toOperation == Operation.Wedge
    check DragOperation.Meet.toOperation == Operation.WedgeAnti
    check DragOperation.Project.toOperation == Operation.ProjectOrthogonal


  test "drag applies the proposal and appends the result":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.index_hover = some(1)
    let outcome = interaction.endDrag(scene)
    check scene.len == 3
    # Two points propose `join`, and the item that lands is that join -- not a button's
    #   choice, which is what this used to be.
    check outcome.choice == some(DragChoice.Join)
    check scene[2].geometry =~ (POINTS[0] ∧ POINTS[1])
    check not interaction.is_dragging
    check "gave" in outcome.message
    check outcome.index_created == some(2)
    check outcome.operands == some((source: 0, destination: 1))


  test "the sky starts no drag, so a press on empty space still reaches the camera":
    # The regression this rule exists to prevent, held directly. `beginDrag` failing when
    #   nothing is hovered is the *entire* mechanism by which a press on empty space
    #   becomes an orbit -- and a plane at horizon is hovered wherever nothing else is,
    #   because it is drawn as a dome over every direction. Were it to start a drag, orbit
    #   and pan would stop working outright the moment a sky joined the scene.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)

    interaction.index_hover = some(0)
    interaction.is_hover_backdrop = true
    check not interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    check not interaction.is_dragging

    # And the same refusal at the far end: a release over the sky commits nothing, rather
    #   than quietly taking the whole sky as an operand.
    interaction.is_hover_backdrop = false
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.is_hover_backdrop = true
    check interaction.destinationOf.isNone
    let outcome = interaction.endDrag(scene)
    check outcome.index_created.isNone
    check outcome.message.len == 0

    # A horizon *line* is an ordinary drag target both ways: it is a curve, not a backdrop.
    interaction.is_hover_backdrop = false
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)


  test "a press that never moves is a click on what it came down on, not a drag":
    # The press over an object has to start a drag eagerly -- the press target chooses the
    #   scheme -- so whether it *was* one is only answerable at the release.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 10.0)
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 10.0)
    let outcome = interaction.endDrag(scene, 10.5)
    check outcome.index_clicked == some(0)
    check outcome.index_created.isNone
    check scene.len == 2 # Nothing built; a click picks, it does not construct.


  test "a press that moves past the click slop is a drag, however briefly it lasted":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 10.0)
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 10.0)
    interaction.updateCursor(200.0 + 2.0*PIXELS_CLICK_SLOP, 200.0)
    # Back where it started: the reading is latched, so a pointer that swung out and
    #   returned is still a drag rather than a click that happened to end where it began.
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(1)
    let outcome = interaction.endDrag(scene, 10.5)
    check outcome.index_clicked.isNone
    check outcome.index_created == some(2)


  test "a press that never moved stays a click however long it is held":
    # **The regression case for a shipped fault.** A 0.35 s deadline stood in `isClick`
    #   beside the distance bound, so shift-clicking with a press held even slightly long
    #   selected nothing at all and answered "Released on its own source; nothing done" --
    #   measured on the built page at 600 ms holds, three objects, none of them picked.
    #   Nothing separates a click from a hold on a mouse: the dwell is touch-only.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 10.0)
    check interaction.beginDrag(arming = MenuArming.Never, now = 10.0)
    for held in [0.05, 0.35, 0.6, 5.0, 60.0]:
      check interaction.isClick(10.0 + held)
    let outcome = interaction.endDrag(scene, 10.0 + 60.0)
    check outcome.index_clicked == some(0)
    check scene.len == 2 # Still a selection, not a construction.


  test "a right press that never opened a wheel reports a click":
    # It could not once: any drag armed `Always` was refused a click outright, on the
    #   reasoning that it had asked for the menu. But the wheel only opens over a target
    #   *other* than the source, so a press that never left its own object never asked for
    #   anything -- and refusing it left the right button doing nothing on a plain click.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 10.0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 10.0)
    check interaction.isClick(10.5)
    check interaction.endDrag(scene, 10.5).index_clicked == some(0)


  test "a release with the wheel open commits the wheel, never a click":
    # The other half of that rule: once a menu *is* open the reader was offered a choice,
    #   and answering with a quiet selection instead would make the button unreliable.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 10.0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 10.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 10.0)
    check interaction.menu.isSome # Armed `Always`, and now over another object.
    check interaction.endDrag(scene, 10.5).index_clicked.isNone


  test "the button that reveals the menu is the right one, and only it":
    # Both render paths and the help panel read this; a fourth copy anywhere is drift.
    check not revealsMenuOn(PointerButton.Left)
    check revealsMenuOn(PointerButton.Right)
    check not revealsMenuOn(PointerButton.Middle)


  test "a revealing click only reveals while a selection stands with its menu down":
    # Total over both booleans, so neither caller has an unhandled case.
    check revealsWithoutPicking(has_selection = true, is_menu_shown = false)
    check not revealsWithoutPicking(has_selection = true, is_menu_shown = true)
    check not revealsWithoutPicking(has_selection = false, is_menu_shown = false)
    check not revealsWithoutPicking(has_selection = false, is_menu_shown = true)


  test "a wheel the cursor walks away from lets go, and re-aims onto the next object":
    # What makes a wheel opened over the wrong object recoverable. Before this it latched
    #   its destination for the rest of the drag, so the only way out was to release.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    scene.addItem(POINTS[2], "c", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 0.0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isSome
    let centre = interaction.menu.get

    # Still inside the radius: an ordinary overshoot past a wedge keeps its menu.
    interaction.updateCursor(centre.x + 0.5*PIXELS_MENU_DISENGAGE, centre.y)
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isSome

    # Past it: the menu goes, and does not come back while the cursor is still over that
    #   same object -- otherwise disengaging would do nothing but move the menu.
    interaction.updateCursor(centre.x + 2.0*PIXELS_MENU_DISENGAGE, centre.y)
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isNone
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isNone

    # On to a third object: open again, for the **original source** with the new
    #   destination. The pair re-aims; it never chains off the object just left.
    interaction.index_hover = some(2)
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isSome
    check interaction.index_source == 0
    check destinationOf(interaction) == some(2)


  test "a wheel opens again on the object it was let go of, once the drag has left it":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 0.0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 0.0)
    let centre = interaction.menu.get
    interaction.updateCursor(centre.x + 2.0*PIXELS_MENU_DISENGAGE, centre.y)
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isNone
    # Off it entirely, then back: the hold at arm's length is released by leaving.
    interaction.index_hover = none(int)
    interaction.updateDrag(scene, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isSome


  test "the palette steps on every released construction, built or not":
    # The reader watched a colour on the band for the whole drag; offering it again to the
    #   next attempt reads as the gesture having never registered.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    let ink_first = scene.inkNext
    check scene.inkNext == ink_first # Peeking never walks the cycle.

    # A release back on its own source builds nothing, and still steps.
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 0.0)
    check interaction.beginDrag(arming = MenuArming.Never, now = 0.0)
    interaction.updateCursor(200.0 + 2.0*PIXELS_CLICK_SLOP, 200.0)
    let refused = interaction.endDrag(scene, 0.0)
    check refused.index_created.isNone
    check scene.inkNext != ink_first
    check scene.len == 2

    # A click is not a construction, so it leaves the cycle alone.
    let ink_after_refusal = scene.inkNext
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 1.0)
    check interaction.beginDrag(arming = MenuArming.Never, now = 1.0)
    check interaction.endDrag(scene, 1.0).index_clicked == some(0)
    check scene.inkNext == ink_after_refusal


  test "a built object wears exactly the hue its drag was drawn in":
    # The band, the comet and the ghost all read `inkOfDrag`, so what a reader watched is
    #   what they get. It used to be the operation's own colour, which said nothing about
    #   the object about to exist.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    check interaction.beginDrag(arming = MenuArming.Never, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 0.0)
    let promised = interaction.inkOfDrag(scene.inkNext)
    check promised == scene.inkNext
    let outcome = interaction.endDrag(scene, 0.0)
    check outcome.index_created.isSome
    check scene[outcome.index_created.get].ink == promised


  test "a drag driven without a press is never mistaken for a click":
    # The safe default `is_press_still` exists for: a caller that never went through
    #   `beginPress` gets the behaviour that predates clicks, whatever the clock reads.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    check not interaction.isClick(0.0)
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.index_hover = some(1)
    check interaction.endDrag(scene, 0.0).index_created == some(2)


  test "drag cannot start without a hovered item":
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = none(int)
    check not interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    check not interaction.is_dragging


  test "releasing over empty space adds nothing":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.index_hover = none(int)
    let outcome = interaction.endDrag(scene)
    check scene.len == 1
    check not interaction.is_dragging
    check outcome.index_created.isNone
    # **And says nothing about it.** A drag let go of over empty space is the commonest
    #   thing a reader does with a gesture they thought better of, and it is plain on the
    #   screen that nothing arrived; a status line for it is a message that fires all day.
    #   The refusals that *land on something* still speak, since those a reader cannot read
    #   off the screen -- see the case below.
    check outcome.message.len == 0

    # A release that lands on an object and still builds nothing does earn its message.
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    let refused = interaction.endDrag(scene)
    check refused.index_created.isNone
    check refused.message.len > 0


  test "releasing on its own source adds nothing":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    let outcome = interaction.endDrag(scene)
    check scene.len == 1
    check "own source" in outcome.message
    check outcome.index_created.isNone


  test "endDrag ignores a drag whose source was removed since it began":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0) # index_source = 0.
    scene.removeItem(0) # Source vanishes mid-drag -- e.g. removed by another input path.
    interaction.index_hover = some(1)
    let outcome = interaction.endDrag(scene)
    check "no longer exists" in outcome.message
    check outcome.index_created.isNone
    check not interaction.is_dragging
    check scene.len == 1


  test "endDrag ignores a drag whose destination was removed since it began":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0) # index_source = 0.
    scene.removeItem(1)
    interaction.index_hover = some(1) # Still reports the now-dead slot as hovered.
    let outcome = interaction.endDrag(scene)
    check "no longer exists" in outcome.message
    check outcome.index_created.isNone
    check scene.len == 1


  test "cancelDrag clears state without applying anything":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.cancelDrag()
    check not interaction.is_dragging
    check scene.len == 2


  test "endDrag with nothing dragging is a harmless no-op":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    let outcome = interaction.endDrag(scene)
    check outcome.message == ""
    check outcome.index_created.isNone
    check outcome.choice.isNone
    check scene.len == 1


  test "a drag onto a pair that makes nothing refuses rather than adding a blank":
    # A plane dragged onto a point: join overflows grade 4, meet falls short of antigrade
    #   4, and projecting a plane onto a point gives nothing drawable. The one pair in the
    #   nine that offers no operation at all, and the reason `proposalFor` is an `Option`.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[2], "G", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "f", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.index_hover = some(1)
    let outcome = interaction.endDrag(scene)
    check scene.len == 2
    check outcome.index_created.isNone
    check outcome.choice.isNone
    check "nothing drawable" in outcome.message


  test "an insisted-on wedge that makes nothing refuses rather than adding a blank":
    # Two points at the same place join to zero. The menu greys that wedge, so this is
    #   only reachable by releasing on it anyway -- and what happens then is a message and
    #   no item, never a slot holding geometry with no shape.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_FIRST[0], "a again", Ink.Rose)
    check not isOffered(DragChoice.Join, GENERAL_FIRST[0], GENERAL_FIRST[0])
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.index_hover = some(1)
    let outcome = interaction.commitChoice(scene, DragChoice.Join, 0.0)
    check scene.len == 2
    check outcome.index_created.isNone
    check "nothing drawable" in outcome.message


  test "at most one of join and meet is offered, over every ordered pair of shapes":
    # The property the whole design rests on: because join and meet are never both
    #   drawable, `proposalFor` can be a plain priority order rather than a table of nine
    #   cases with a tiebreak. Measured here rather than asserted in prose, over operands
    #   in general position -- an earlier measurement used a point lying *on* the line it
    #   was crossed with and read zeros that came from the fixture, not the algebra.
    for m in GENERAL_FIRST:
      for n in GENERAL_SECOND:
        check not (isOffered(DragChoice.Join, m, n) and isOffered(DragChoice.Meet, m, n))
        # Whatever is proposed is drawable, so a plain release never adds a blank item.
        let proposal = proposalFor(m, n)
        if proposal.isSome: check resultOf(proposal.get, m, n).isSome
        # And `more…` is always there, which is what keeps the menu from ever being empty.
        check isOffered(DragChoice.More, m, n)


  test "the proposal for each ordered pair of shapes is the measured one":
    # The table in `PROVENANCE.md`, pinned. A change to the library's grades that moved
    #   any cell would otherwise silently redefine what every plain drag builds.
    const lut_expected = [
      # point -> point, line, plane.
      some(DragChoice.Join), some(DragChoice.Join), some(DragChoice.Project),
      # line -> point, line, plane.
      some(DragChoice.Join), some(DragChoice.Project), some(DragChoice.Meet),
      # plane -> point, line, plane.
      none(DragChoice), some(DragChoice.Meet), some(DragChoice.Meet),
    ]
    var index = 0
    for m in GENERAL_FIRST:
      for n in GENERAL_SECOND:
        check proposalFor(m, n) == lut_expected[index]
        inc index


  test "a menu release picks the wedge the cursor is in, and nothing at its centre":
    for choice in DragChoice:
      let centre = ScreenPosition(x: 400.0, y: 300.0, depth: 0.0)
      check choiceAt(centre, anchorOf(centre, choice)) == some(choice)
    # Back at the middle is how a reader changes their mind without letting go.
    let centre = ScreenPosition(x: 400.0, y: 300.0, depth: 0.0)
    check choiceAt(centre, centre).isNone
    check choiceAt(
      centre, ScreenPosition(x: 400.0, y: 300.0 - 0.9*PIXELS_MENU_DEADZONE, depth: 0.0)
    ).isNone
    # Overshooting a wedge still picks it, so a fast throw is not punished.
    check choiceAt(
      centre, ScreenPosition(x: 400.0, y: 300.0 - 8.0*PIXELS_MENU_REACH, depth: 0.0)
    ) == some(DragChoice.Join)


  test "an open menu commits the wedge under the cursor, over its latched destination":
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(400.0, 300.0)
    interaction.index_hover = some(0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    check interaction.menu.isSome
    # The wheel opened under the cursor, so nothing is chosen yet and nothing is ghosted.
    check interaction.proposal.isNone
    check interaction.preview.isNone
    # Reaching for a wedge takes the cursor off the item; the destination must survive it.
    interaction.index_hover = none(int)
    let south = anchorOf(interaction.menu.get, DragChoice.Project)
    interaction.updateCursor(south.x, south.y)
    interaction.updateDrag(scene, 0.0)
    check destinationOf(interaction) == some(1)
    check interaction.proposal == some(DragChoice.Project)
    let outcome = interaction.endDrag(scene)
    check outcome.choice == some(DragChoice.Project)
    check outcome.index_created == some(2)
    check scene[2].geometry =~ projectOrthogonal(GENERAL_FIRST[0], GENERAL_SECOND[0])


  test "the ghost is the wedge being aimed at, not what a plain release would make":
    # The complaint this answers: with the wheel open, the ghost was `proposalFor`'s own
    #   answer whatever wedge the cursor was in, so a reader reaching for `project` watched
    #   a ghost of `join` and only found out what they had asked for after letting go.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(400.0, 300.0)
    interaction.index_hover = some(0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    let centre = interaction.menu.get
    # Two points: `join` and `project` both make something, and they make different things,
    #   which is what lets the ghost be told apart from the plain-release answer at all.
    check proposalFor(GENERAL_FIRST[0], GENERAL_SECOND[0]) == some(DragChoice.Join)
    check isOffered(DragChoice.Project, GENERAL_FIRST[0], GENERAL_SECOND[0])

    proc aimAt(interaction: var Interaction; scene: Scene; choice: DragChoice) =
      let at = anchorOf(centre, choice)
      interaction.updateCursor(at.x, at.y)
      interaction.updateDrag(scene, 0.0)

    interaction.aimAt(scene, DragChoice.Project)
    check interaction.choosing == some(DragChoice.Project)
    check interaction.preview.get.geometry =~
      projectOrthogonal(GENERAL_FIRST[0], GENERAL_SECOND[0])
    interaction.aimAt(scene, DragChoice.Join)
    check interaction.preview.get.geometry =~ (GENERAL_FIRST[0] ∧ GENERAL_SECOND[0])
    # And each of those is exactly what letting go there commits: one rule, drawn and then
    #   obeyed, checked by actually releasing rather than by re-deriving the answer.
    for choice in [DragChoice.Join, DragChoice.Project]:
      var trial = interaction
      var scene_trial = scene
      trial.aimAt(scene_trial, choice)
      let ghosted = trial.preview.get.geometry
      let outcome = trial.endDrag(scene_trial)
      check outcome.index_created.isSome
      check scene_trial[outcome.index_created.get].geometry =~ ghosted


  test "what a release would do has three answers, and the band's tint has three":
    # A wheel open over one pair reaches all three without the cursor leaving the target,
    #   which is why `inkOfDrag`'s old two-way test could not carry it: the centre and a
    #   greyed wedge both had no answer, and they want opposite feedback.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(400.0, 300.0)
    interaction.index_hover = some(0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    let centre = interaction.menu.get

    # Back at the wheel's own centre: releasing calls the gesture off, so the band goes
    #   neutral rather than warning about a refusal that is not going to happen.
    check interaction.effectOf == ReleaseEffect.Nothing
    check interaction.inkOfDrag(scene.inkNext) == Ink.Guide
    check interaction.preview.isNone

    for (choice, effect) in [
      (DragChoice.Join, ReleaseEffect.Builds),
      (DragChoice.Meet, ReleaseEffect.Refused), # Two points meet in nothing drawable.
      (DragChoice.Project, ReleaseEffect.Builds),
      (DragChoice.More, ReleaseEffect.Builds), # Builds nothing itself; the picker will.
    ]:
      let at = anchorOf(centre, choice)
      interaction.updateCursor(at.x, at.y)
      interaction.updateDrag(scene, 0.0)
      check isOffered(choice, GENERAL_FIRST[0], GENERAL_SECOND[0]) ==
        (effect == ReleaseEffect.Builds)
      check interaction.effectOf == effect
      check interaction.inkOfDrag(scene.inkNext) ==
        (case effect
         of ReleaseEffect.Nothing: Ink.Guide
         of ReleaseEffect.Refused: Ink.Invalid
         of ReleaseEffect.Builds: scene.inkNext)
      # `More` builds nothing itself, so it ghosts nothing while still promising its hue.
      check interaction.preview.isSome ==
        (effect == ReleaseEffect.Builds and choice != DragChoice.More)


  test "with no wheel open the ghost is still the plain-release answer":
    # The left button's own path, unchanged: it never opens a wheel, so what it ghosts is
    #   `proposalFor`'s answer exactly as before.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(400.0, 300.0)
    interaction.index_hover = some(0)
    check interaction.beginDrag(arming = MenuArming.Never, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    check interaction.menu.isNone
    check interaction.proposal == some(DragChoice.Join)
    check interaction.preview.get.geometry =~ (GENERAL_FIRST[0] ∧ GENERAL_SECOND[0])
    check interaction.effectOf == ReleaseEffect.Builds


  test "a ghosted plane is centred where the committed one will be":
    # `mesh.addPlane` centres a disc on the item's own creation anchor, so a ghost drawn
    #   without one sits somewhere the object is about to leave -- measured at 2.1 units
    #   here, against a disc of radius 8, and the jump lands at the moment a reader is
    #   watching hardest.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[1], "L", Ink.Rose) # A line ...
    scene.addItem(GENERAL_SECOND[0], "p", Ink.Rose) # ... joined with a point gives a plane.
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(400.0, 300.0)
    interaction.index_hover = some(0)
    check interaction.beginDrag(arming = MenuArming.Never, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    check interaction.proposal == some(DragChoice.Join)
    check shape(interaction.preview.get.geometry) == some(Shape.Plane)
    check interaction.preview.get.anchor.isSome
    # Read before releasing: `endDrag` clears the drag's whole state on its way out.
    let ghosted = interaction.preview.get.anchor.get
    # Not the support, or there would have been nothing to fix.
    check not (ghosted =~ positionAnchor(interaction.preview.get.geometry).get)
    let outcome = interaction.endDrag(scene)
    check outcome.index_created.isSome
    check scene[outcome.index_created.get].anchorOverride.get =~ ghosted


  test "a menu release back at the centre commits nothing":
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(400.0, 300.0)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    let outcome = interaction.endDrag(scene)
    check scene.len == 2
    check outcome.index_created.isNone
    check "without choosing" in outcome.message


  test "`more…` builds nothing and hands both operands over, in drag order":
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(400.0, 300.0)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    let west = anchorOf(interaction.menu.get, DragChoice.More)
    interaction.updateCursor(west.x, west.y)
    let outcome = interaction.endDrag(scene)
    check scene.len == 2
    check outcome.choice == some(DragChoice.More)
    check outcome.index_created.isNone
    check outcome.operands == some((source: 0, destination: 1))


  test "a touch drag waits out the dwell before offering the menu; a right one never does":
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 1000.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 1000.0)
    check interaction.menu.isNone
    interaction.updateDrag(scene, 1000.0 + 0.99*SECONDS_DWELL_MENU)
    check interaction.menu.isNone
    interaction.updateDrag(scene, 1000.0 + SECONDS_DWELL_MENU)
    check interaction.menu.isSome

    var forced = Interaction(is_enabled: true)
    forced.index_hover = some(0)
    discard forced.beginDrag(arming = MenuArming.Always, now = 1000.0)
    forced.index_hover = some(1)
    forced.updateDrag(scene, 1000.0)
    check forced.menu.isSome

    # And the left button, which is the one a mouse spends nearly every drag on, never
    #   reaches a menu at all -- however long it is held still over its target. The dwell
    #   opening under a hand that paused mid-gesture is exactly what it is for.
    var never = Interaction(is_enabled: true)
    never.index_hover = some(0)
    discard never.beginDrag(arming = MenuArming.Never, now = 1000.0)
    never.index_hover = some(1)
    never.updateDrag(scene, 1000.0)
    check never.menu.isNone
    never.updateDrag(scene, 1000.0 + 10.0*SECONDS_DWELL_MENU)
    check never.menu.isNone


  test "a dwell wheel nobody entered does not veto the release":
    # The touch gesture as a finger actually does it: drag onto the target, pause there
    #   to aim -- the wheel opens under the finger, hidden by it -- and lift. Measured on
    #   a phone before this rule: that release built nothing every time, which read as
    #   the drag itself being broken.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 0.0)
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.updateCursor(400.0, 200.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 0.0)
    interaction.updateDrag(scene, now = SECONDS_DWELL_MENU + 0.1)
    check interaction.menu.isSome
    # The pair's own answer keeps standing under the unentered wheel, ghost included, so
    #   what the band promises and what the lift commits stay one thing.
    check interaction.proposal == some(DragChoice.Join)
    check interaction.preview.isSome
    let outcome = interaction.endDrag(scene, SECONDS_DWELL_MENU + 0.2)
    check outcome.index_created == some(2)
    check scene.len == 3


  test "a wedge walked into and left again cancels the release, dwell wheel included":
    # The other half of the rule: entering the wheel is engaging with it, so coming back
    #   to the centre afterwards is the deliberate way out -- on the dwell wheel exactly
    #   as on the summoned one.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 0.0)
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.updateCursor(400.0, 200.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 0.0)
    interaction.updateDrag(scene, now = SECONDS_DWELL_MENU + 0.1)
    check interaction.menu.isSome
    interaction.updateCursor(400.0 + PIXELS_MENU_REACH, 200.0) # Into the east wedge...
    interaction.updateDrag(scene, now = SECONDS_DWELL_MENU + 0.2)
    interaction.updateCursor(400.0, 200.0) # ...and back to the centre.
    interaction.updateDrag(scene, now = SECONDS_DWELL_MENU + 0.3)
    check interaction.proposal.isNone # No ghost: the band already says this lift cancels.
    let outcome = interaction.endDrag(scene, SECONDS_DWELL_MENU + 0.4)
    check outcome.index_created.isNone
    check scene.len == 2


  test "a summoned wheel still cancels at its own centre":
    # The arming distinction the release rule turns on: a right press asked for the
    #   wheel, so lifting back at its centre withdraws the gesture even though no wedge
    #   was ever entered.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 0.0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 0.0)
    interaction.updateCursor(400.0, 200.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, now = 0.0)
    check interaction.menu.isSome
    let outcome = interaction.endDrag(scene, 0.5)
    check outcome.index_created.isNone
    check scene.len == 2


  test "an overlay run covers exactly what was added after it was marked":
    # The mechanism a selected object is drawn over everything with. Held here because the
    #   fault it guards against is silent: a mesh nobody marked has to draw *entirely*
    #   depth-tested, and a sentinel index of zero would have said the opposite -- every
    #   line of furniture drawn over the scene, on every frame.
    let scale = algebraFilled(DrawExtent(scale: DrawScale(
      extent_furniture: 10.0, radius_horizon: 10.0, tangent_half_view: 0.5,
      height_pixels: 600, depth_near: 0.1, forward: Direction(x: 0, y: 0, z: -1),
    )))
    var meshes: MeshSet
    clearMeshes(meshes)
    for primitive in Primitive: check meshes[primitive].index_overlay.isNone
    discard meshes.addObject(GENERAL_POINTS[0], Ink.Rose.colour, scale)
    let count_under = meshes[Primitive.Point].count_vertices
    check count_under > 0
    check meshes[Primitive.Point].index_overlay.isNone

    markOverlay(meshes)
    discard meshes.addObject(GENERAL_POINTS[1], Ink.Jade.colour, scale)
    check meshes[Primitive.Point].index_overlay == some(count_under)
    check meshes[Primitive.Point].count_vertices > count_under
    # A bucket nothing was added to after the mark still reports the mark, with an empty
    #   overlay -- which is what makes "drawn over" a property of order rather than of
    #   which primitive an object happens to tessellate into.
    check meshes[Primitive.Triangle].index_overlay == some(0)
    check meshes[Primitive.Triangle].count_vertices == 0

    # And clearing forgets it, so one frame's selection cannot outlive its own frame.
    clearMeshes(meshes)
    for primitive in Primitive: check meshes[primitive].index_overlay.isNone


  test "a mouse never waits: left decides, right asks, middle starts nothing":
    # The one rule both render paths and the help panel read, held here rather than left
    #   to three copies agreeing by inspection.
    check armingOf(PointerButton.Left) == some(MenuArming.Never)
    check armingOf(PointerButton.Right) == some(MenuArming.Always)
    check armingOf(PointerButton.Middle).isNone
    # And no button reaches the dwell, which belongs to the one pointer with no second
    #   button to ask with.
    for button in PointerButton:
      check armingOf(button) != some(MenuArming.OnDwell)


  test "stepping walks live slots in both directions and wraps at both ends":
    var scene = initScene()
    for i in 0 ..< 4: scene.addItem(GENERAL_POINTS[i], "p", Ink.Rose)
    check scene.slotStepped(none(int), 1) == some(0) # Nothing focused starts at the first.
    check scene.slotStepped(none(int), -1) == some(3) # ...and backwards, at the last.
    check scene.slotStepped(some(0), 1) == some(1)
    check scene.slotStepped(some(3), 1) == some(0) # Wraps rather than stopping dead: a key
    check scene.slotStepped(some(0), -1) == some(3) #   that quietly stops working is worse.


  test "stepping skips slots whose items have gone":
    var scene = initScene()
    for i in 0 ..< 4: scene.addItem(GENERAL_POINTS[i], "p", Ink.Rose)
    scene.removeItem(1)
    scene.removeItem(2)
    # Slots are sparse -- the free list reuses holes in any order -- so this cannot be
    #   arithmetic on the slot number, and a hole must not be a place the keyboard lands.
    check scene.slotStepped(some(0), 1) == some(3)
    check scene.slotStepped(some(3), 1) == some(0)


  test "stepping an empty scene lands nowhere rather than on a freed slot":
    var scene = initScene()
    check scene.slotStepped(none(int), 1).isNone
    check scene.slotStepped(some(0), 1).isNone
    scene.addItem(GENERAL_POINTS[0], "p", Ink.Rose)
    scene.removeItem(0)
    check scene.slotStepped(none(int), 1).isNone


  test "every key answers the binding table, and answers exactly one half of it":
    # The table has to be total: each render path translates its own naming and then trusts
    #   this, so a key with no answer would be a case nobody handled. The halves also have
    #   to be disjoint -- a key that both moved the view while held and did something at
    #   the press would do the second thing again on every auto-repeat.
    for key in Key:
      let (motion, action) = (motionFor(key), actionFor(key))
      check not (motion.isSome and action.isSome)
      if key == Key.Shift:
        # The one key that is neither: it multiplies every rate rather than binding one.
        check motion.isNone and action.isNone
      else:
        check motion.isSome or action.isSome
    check motionFor(Key.W) == some(Motion.Forward)
    check motionFor(Key.Left) == some(Motion.OrbitLeft)
    check actionFor(Key.F) == some(KeyAction.FrameSelection)
    check actionFor(Key.Home) == some(KeyAction.ViewHome)


  test "a held key slides the view across the ground, never through it":
    # The **map** reading of a movement key rather than the fly one: forward keeps the
    #   camera's height whatever it is looking at. Judged from a camera tilted well down,
    #   where a slide along the raw sight direction would plainly lose height.
    var
      interaction = Interaction(is_enabled: true)
      camera = initCamera(target = ORIGIN, distance = 20.0, azimuth = 0.4, elevation = 0.9)
    let opening = camera
    interaction.holdKey(Key.W)
    interaction.driveHeld(camera, 1.0)
    check camera.target.z =~ opening.target.z
    check camera.distance =~ opening.distance
    check camera.azimuth =~ opening.azimuth
    check camera.elevation =~ opening.elevation
    # Forward is the way the camera faces, flattened: the move lies along it exactly.
    let moved = camera.target - opening.target
    check norm(moved) =~ SLIDE_SECOND*opening.distance
    check dot(moved, opening.headingGround) =~ norm(moved)

    # Sideways is perpendicular to that, and level with it.
    interaction.releaseKey(Key.W)
    interaction.holdKey(Key.D)
    var sideways = initCamera(ORIGIN, 20.0, 0.4, 0.9)
    interaction.driveHeld(sideways, 1.0)
    check sideways.target.z =~ 0.0
    check abs(dot(sideways.target - ORIGIN, sideways.headingGround)) <= TOLERANCE_TEST

    # Up and down are world up, and nothing else.
    interaction.releaseKey(Key.D)
    interaction.holdKey(Key.E)
    var lifted = initCamera(ORIGIN, 20.0, 0.4, 0.9)
    interaction.driveHeld(lifted, 1.0)
    check lifted.target.x =~ 0.0
    check lifted.target.y =~ 0.0
    check lifted.target.z =~ SLIDE_SECOND*lifted.distance


  test "held keys compose, and letting one go leaves the other running":
    var
      interaction = Interaction(is_enabled: true)
      camera = initCamera(target = ORIGIN, distance = 20.0, azimuth = 0.4, elevation = 0.3)
    interaction.holdKey(Key.W)
    interaction.holdKey(Key.E)
    interaction.driveHeld(camera, 1.0)
    let both = camera.target
    check both.z > 0.0
    check norm(Direction(x: both.x, y: both.y, z: 0)) > 0.0

    interaction.releaseKey(Key.E)
    interaction.driveHeld(camera, 1.0)
    check camera.target.z =~ both.z # The lift stopped exactly when its key was let go of.
    check norm(camera.target - both) > 0.0 # The slide did not.


  test "how far a hold travels depends on how long it was held":
    # The whole point of driving movement per frame: a rate stated per second, multiplied
    #   by the frame's own elapsed time, so a fast machine and a slow one agree.
    var interaction = Interaction(is_enabled: true)
    interaction.holdKey(Key.W)
    var
      once = initCamera(ORIGIN, 20.0, 0.0, 0.3)
      twice = initCamera(ORIGIN, 20.0, 0.0, 0.3)
    interaction.driveHeld(once, 0.5)
    interaction.driveHeld(twice, 1.0)
    check norm(twice.target - ORIGIN) =~ 2.0*norm(once.target - ORIGIN)

    # The dolly is the one that compounds rather than adding, so it takes the rate to the
    #   power of the elapsed seconds: two half-seconds must equal one whole one.
    interaction.releaseKey(Key.W)
    interaction.holdKey(Key.Minus)
    var
      halves = initCamera(ORIGIN, 20.0, 0.0, 0.3)
      whole = initCamera(ORIGIN, 20.0, 0.0, 0.3)
    interaction.driveHeld(halves, 0.5)
    interaction.driveHeld(halves, 0.5)
    interaction.driveHeld(whole, 1.0)
    check halves.distance =~ whole.distance
    check whole.distance =~ 20.0*FACTOR_DOLLY_SECOND


  test "shift makes every movement key faster, and changes none of them":
    var interaction = Interaction(is_enabled: true)
    interaction.holdKey(Key.W)
    var
      plain = initCamera(ORIGIN, 20.0, 0.4, 0.3)
      hastened = initCamera(ORIGIN, 20.0, 0.4, 0.3)
    interaction.driveHeld(plain, 0.25)
    interaction.holdKey(Key.Shift)
    interaction.driveHeld(hastened, 0.25)
    check norm(hastened.target - ORIGIN) =~ FACTOR_HASTE*norm(plain.target - ORIGIN)
    # Same direction, not a different binding -- which is what shift+arrow used to mean.
    check dot(hastened.target - ORIGIN, plain.headingGround) > 0.0

    var
      turned = initCamera(ORIGIN, 20.0, 0.4, 0.3)
      turned_fast = initCamera(ORIGIN, 20.0, 0.4, 0.3)
    interaction.releaseKeysAll()
    interaction.holdKey(Key.Left)
    interaction.driveHeld(turned, 0.25)
    interaction.holdKey(Key.Shift)
    interaction.driveHeld(turned_fast, 0.25)
    check (turned_fast.azimuth - 0.4) =~ FACTOR_HASTE*(turned.azimuth - 0.4)


  test "letting go of everything at once stops the camera, however it lost the release":
    # A window that loses focus never sees the key up, and a key left held moves the camera
    #   forever with no press able to stop it.
    var
      interaction = Interaction(is_enabled: true)
      camera = initCamera(target = ORIGIN, distance = 20.0, azimuth = 0.4, elevation = 0.3)
    interaction.holdKey(Key.W)
    interaction.holdKey(Key.Shift)
    check interaction.keys_held.len == 2
    interaction.releaseKeysAll()
    check interaction.keys_held.len == 0
    let standing = camera.target
    interaction.driveHeld(camera, 1.0)
    check camera.target =~ standing


  test "each key that acts at a press does its own thing, and moves nothing while held":
    var scene = initScene()
    scene.addItem(GENERAL_POINTS[0], "a", Ink.Rose)
    var
      interaction = Interaction(is_enabled: true)
      camera = initCameraDefault()
    let opening = camera

    # Home returns to the placement both builds open at, from wherever the reader has gone.
    camera.slideGround(3.0, 2.0, 1.0)
    camera.orbit(0.5, 0.2)
    discard interaction.applyAction(camera, scene, KeyAction.ViewHome)
    check camera.target =~ opening.target
    check camera.distance =~ opening.distance
    check camera.azimuth =~ opening.azimuth
    check camera.elevation =~ opening.elevation

    # Framing is the standing offer's own job, so the key itself moves nothing: each front
    #   end releases its tween's goal and `framing.offerAim` aims afresh the next frame.
    check interaction.applyAction(camera, scene, KeyAction.FrameSelection).isNone
    check camera.target =~ opening.target
    check camera.distance =~ opening.distance

    # And a key held down is not an action at all, however long it is held.
    interaction.holdKey(Key.F)
    interaction.driveHeld(camera, 1.0)
    check camera.target =~ opening.target


  test "enter reports the focused slot for the caller to select, and nothing before then":
    var scene = initScene()
    scene.addItem(GENERAL_POINTS[0], "a", Ink.Rose)
    scene.addItem(GENERAL_POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    var camera = initCameraDefault()
    # Pressing enter before stepping anywhere is a no-op, not a select of slot zero.
    check interaction.applyAction(camera, scene, KeyAction.SelectFocused).isNone
    discard interaction.applyAction(camera, scene, KeyAction.FocusNext)
    check interaction.index_focus == some(0)
    check interaction.applyAction(camera, scene, KeyAction.SelectFocused) == some(0)


  test "a focus whose item is removed is dropped rather than left pointing at freed storage":
    var scene = initScene()
    scene.addItem(GENERAL_POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    var camera = initCameraDefault()
    discard interaction.applyAction(camera, scene, KeyAction.FocusNext)
    check interaction.index_focus == some(0)
    scene.removeItem(0)
    interaction.pruneFocus(scene)
    check interaction.index_focus.isNone


  test "a camera move is not a hover, however much it sweeps the pointer past":
    # Hover is recomputed from the cursor every frame, so a pan drags the ring across every
    #   object it sweeps and a held W lights up whatever slides under a cursor standing
    #   still. Neither gesture is pointing at anything.
    var scene = initScene()
    let target = Position(x: 0, y: 0, z: 0)
    scene.addItem(toMultivector(target), "p", Ink.Rose)
    var
      interaction = Interaction(is_enabled: true)
      camera = initCamera(target = target, distance = 10.0, azimuth = 0.0, elevation = 0.0)
    let view_projection = camera.initMatrixViewProjection(800.0/600.0)
    proc hovering(interaction: var Interaction): Option[int] =
      interaction.updateHover(scene, camera, view_projection, 800, 600)
      interaction.index_hover
    interaction.updateCursor(400.0, 300.0) # Straight at the item.
    check interaction.hovering == some(0)

    interaction.is_dragging_camera = true
    check interaction.hovering.isNone
    interaction.is_dragging_camera = false
    check interaction.hovering == some(0) # And back the frame the gesture ends.

    interaction.holdKey(Key.W)
    check interaction.hovering.isNone
    interaction.releaseKey(Key.W)
    check interaction.hovering == some(0)

    # Shift alone moves nothing, so it is not a camera move and hover stands.
    interaction.holdKey(Key.Shift)
    check interaction.hovering == some(0)
    interaction.releaseKey(Key.Shift)

    # A *construction* drag is the opposite case: what it points at is the whole gesture.
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    check interaction.hovering == some(0)


  test "keyboard focus is not hover, and a pointer moving does not erase it":
    # The whole reason `index_focus` is its own field: `updateHover` recomputes hover from
    #   the cursor every frame, so a focus stored there would be gone before it was drawn.
    var scene = initScene()
    let target = Position(x: 0, y: 0, z: 0)
    scene.addItem(toMultivector(target), "p", Ink.Rose)
    scene.addItem(GENERAL_POINTS[5], "far", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    var camera = initCamera(target = target, distance = 10.0, azimuth = 0.0, elevation = 0.0)
    discard interaction.applyAction(camera, scene, KeyAction.FocusNext)
    check interaction.index_focus == some(0)
    interaction.updateCursor(799.0, 1.0) # A corner, away from everything.
    interaction.updateHover(scene, camera, camera.initMatrixViewProjection(800.0/600.0), 800, 600)
    check interaction.index_hover != interaction.index_focus
    check interaction.index_focus == some(0)


  test "a drag that keeps moving never opens its menu, however long it stays on target":
    # The dwell measures being *still*, not being over something. While it ran on presence
    #   alone, a slow finger crossing one large object -- a plane's disc spans most of a
    #   phone screen -- had the menu open on it mid-gesture, and the construction it was in
    #   the middle of then released into a menu and built nothing. Found by driving a real
    #   touch drag, not by reading the code.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(100.0, 100.0)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.index_hover = some(1)
    for step in 1 .. 20:
      # Three times the dwell, and never still for two frames together.
      interaction.updateCursor(100.0 + 2.0*PIXELS_TAP_SLOP*float(step), 100.0)
      interaction.updateDrag(scene, 0.15*SECONDS_DWELL_MENU*float(step))
      check interaction.menu.isNone
    # Stop moving, and the same drag opens it a dwell later -- the clock is restarted, not
    #   disabled, so the gesture the reader actually wanted still works.
    #   A dwell past the last movement with room to spare: what is being checked here is
    #   that the clock restarts rather than stops, not where its own boundary lies, and the
    #   two tests below pin that boundary exactly.
    interaction.updateDrag(scene, 0.15*SECONDS_DWELL_MENU*20.0 + 1.5*SECONDS_DWELL_MENU)
    check interaction.menu.isSome


  test "a drift smaller than the tap slop still counts as holding still":
    # The other half of the rule: a hand shakes. A dwell that any tremor could restart is
    #   a dwell nobody can ever reach, which is why the threshold is the same fingertip
    #   slop that decides a press from a drag rather than exact equality.
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(100.0, 100.0)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    interaction.index_hover = some(1)
    for step in 1 .. 4:
      interaction.updateCursor(100.0 + 0.2*PIXELS_TAP_SLOP*float(step), 100.0)
      interaction.updateDrag(scene, 0.2*SECONDS_DWELL_MENU*float(step))
    interaction.updateDrag(scene, SECONDS_DWELL_MENU)
    check interaction.menu.isSome


  test "leaving the target restarts the dwell, so pausing on the way across never opens":
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[0], "a", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 1000.0)
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 1000.0 + 0.9*SECONDS_DWELL_MENU)
    check interaction.menu.isNone
    interaction.index_hover = none(int) # Slipped off the target.
    interaction.updateDrag(scene, 1000.0 + 0.95*SECONDS_DWELL_MENU)
    check interaction.preview.isNone
    interaction.index_hover = some(1) # And back on, with the dwell owed in full again.
    interaction.updateDrag(scene, 1000.0 + 1.5*SECONDS_DWELL_MENU)
    check interaction.menu.isNone


  test "the rubber-band warns before the release, never after it":
    var scene = initScene()
    scene.addItem(GENERAL_FIRST[2], "G", Ink.Rose)
    scene.addItem(GENERAL_SECOND[0], "f", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.index_hover = some(0)
    discard interaction.beginDrag(arming = MenuArming.OnDwell, now = 0.0)
    # Crossing empty space says nothing either way.
    interaction.index_hover = none(int)
    interaction.updateDrag(scene, 0.0)
    check interaction.inkOfDrag(scene.inkNext) == Ink.Guide
    # Standing over a pair that makes nothing wears the reserved magenta, and shows no
    #   ghost -- two signals, so the warning is never colour alone.
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    check interaction.inkOfDrag(scene.inkNext) == Ink.Invalid
    check interaction.preview.isNone


  test "disabled interaction never hovers":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: false)
    let camera = initCamera(target = PLACES[0], distance = 10.0, azimuth = 0.0, elevation = 0.0)
    interaction.updateCursor(400.0, 300.0)
    interaction.updateHover(scene, camera, camera.initMatrixViewProjection(800.0/600.0), 800, 600)
    check interaction.index_hover.isNone


  test "enabled interaction hovers the item under the cursor":
    var scene = initScene()
    let target = Position(x: 0, y: 0, z: 0)
    scene.addItem(toMultivector(target), "p", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    let camera = initCamera(target = target, distance = 10.0, azimuth = 0.0, elevation = 0.0)
    interaction.updateCursor(400.0, 300.0)
    interaction.updateHover(scene, camera, camera.initMatrixViewProjection(800.0/600.0), 800, 600)
    check interaction.index_hover == some(0)


  test "a hold reports no progress until one is begun, and none again once cancelled":
    var interaction = Interaction(is_enabled: true)
    check progressHold(interaction, 1000.0) == 0.0
    check not isHoldMature(interaction, 1000.0)
    interaction.beginHold(3, 1000.0)
    # Measured past the grow, which the fill starts after; see `swellHold`.
    const FULL = 1000.0 + SECONDS_SWELL_GROW + SECONDS_LONG_PRESS
    check progressHold(interaction, FULL) == 1.0
    interaction.cancelHold()
    check progressHold(interaction, FULL) == 0.0
    check not isHoldMature(interaction, FULL)


  test "a hold fills linearly, is clamped at both ends, and is due exactly when full":
    var interaction = Interaction(is_enabled: true)
    interaction.beginHold(0, 1000.0)
    # The fill starts once the marker has grown clear of the finger, so every time below is
    #   measured from the end of that grow rather than from the press.
    const FILLING = 1000.0 + SECONDS_SWELL_GROW
    # Linear, not eased: half the wait is half the fill. This is the property that makes
    #   the marker a clock a reader can judge the remaining time from, and it is what an
    #   `easeOutCubic` here would break -- see `progressHold`'s own doc comment.
    check progressHold(interaction, FILLING + 0.5*SECONDS_LONG_PRESS) =~ 0.5
    check progressHold(interaction, FILLING + 0.25*SECONDS_LONG_PRESS) =~ 0.25
    # Nothing fills while the marker is still getting out of the way.
    check progressHold(interaction, 1000.0 + 0.5*SECONDS_SWELL_GROW) == 0.0
    var previous = 0.0
    for step in 0 .. 20:
      let progress = progressHold(
        interaction, FILLING + float(step)/20.0*SECONDS_LONG_PRESS
      )
      check progress >= previous
      previous = progress
    # Clamped below, so a clock that steps backward cannot un-fill a marker, and above, so
    #   a frame arriving late still draws a whole one rather than overshooting past it.
    check progressHold(interaction, 900.0) == 0.0
    check progressHold(interaction, FILLING + 10.0*SECONDS_LONG_PRESS) == 1.0
    # Maturity lands exactly where the fill completes, never a frame either side of it.
    check not isHoldMature(interaction, FILLING + 0.999*SECONDS_LONG_PRESS)
    check isHoldMature(interaction, FILLING + SECONDS_LONG_PRESS)


  test "the swell grows, waits out the whole hold, and settles only once the finger lifts":
    # The defect this pins: the swell used to be a half sine over the fill, so the marker
    #   was back to its true size at exactly the moment the selection landed -- shrinking
    #   while the reader was still deciding, and gone when it mattered.
    var interaction = Interaction(is_enabled: true)
    interaction.beginHold(0, 1000.0)
    check swellHold(interaction, 1000.0) =~ 0.0
    check swellHold(interaction, 1000.0 + SECONDS_SWELL_GROW) =~ 1.0
    # Fully out before the fill starts, so the marker fills at the size it will fill at.
    check swellHold(interaction, 1000.0 + SECONDS_SWELL_GROW) >=
      swellHold(interaction, 1000.0 + 0.5*SECONDS_SWELL_GROW)

    # Out for the whole fill, past maturity, and for as long as the finger stays down --
    #   an unreleased hold never settles, however long it is held.
    const MATURED = 1000.0 + SECONDS_SWELL_GROW + SECONDS_LONG_PRESS
    for now in [MATURED - 0.5*SECONDS_LONG_PRESS, MATURED, MATURED + 60.0]:
      check swellHold(interaction, now) =~ 1.0
      check not isHoldSpent(interaction, now)

    # And settles exactly one shrink after the lift, not before and not later.
    interaction.releaseHold(MATURED + 5.0)
    check swellHold(interaction, MATURED + 5.0) =~ 1.0
    check swellHold(interaction, MATURED + 5.0 + SECONDS_SWELL_SHRINK) =~ 0.0
    check not isHoldSpent(interaction, MATURED + 5.0 + 0.5*SECONDS_SWELL_SHRINK)
    # A frame past the shrink rather than exactly on it: subtracting two large timestamps
    #   does not land on the boundary exactly, and no caller asks at an exact instant --
    #   they ask once a frame. What matters is that it is not spent early and is spent.
    check isHoldSpent(interaction, MATURED + 5.0 + 1.1*SECONDS_SWELL_SHRINK)
    # A second lift is not a second settle: the first one owns the clock.
    interaction.releaseHold(MATURED + 900.0)
    check isHoldSpent(interaction, MATURED + 5.0 + 1.1*SECONDS_SWELL_SHRINK)


  test "a matured hold is taken once, and never again however long it is held":
    # The regression this pins, measured: a hold of 1.62 s selected its item and then lost
    #   it within 50 ms of the lift. The caller asked "is it mature" beside its own flag for
    #   "have I acted on that", cleared the flag on the release, and the still-settling --
    #   still mature -- hold selected a second time and toggled it straight back off.
    var interaction = Interaction(is_enabled: true)
    interaction.beginHold(4, 1000.0)
    const MATURED = 1000.0 + SECONDS_SWELL_GROW + SECONDS_LONG_PRESS
    # Nothing to take while it is still filling.
    check takeHold(interaction, MATURED - 0.01).isNone
    check takeHold(interaction, MATURED) == some(4)
    # Not a second time, at any later moment of the hold...
    for now in [MATURED, MATURED + 0.001, MATURED + 5.0, MATURED + 600.0]:
      check takeHold(interaction, now).isNone
    # ...nor across the release and its whole settle, which is exactly where it fired.
    interaction.releaseHold(MATURED + 5.0)
    for now in [MATURED + 5.0, MATURED + 5.0 + 0.5*SECONDS_SWELL_SHRINK,
                MATURED + 5.0 + 2.0*SECONDS_SWELL_SHRINK]:
      check takeHold(interaction, now).isNone
    # Taking it does not end it: the swell still has a settle to run out.
    check swellHold(interaction, MATURED + 5.0) =~ 1.0

    # And a fresh press is a fresh hold, takeable on its own terms.
    #   Asked a frame past the boundary rather than exactly on it: summing a large base
    #   with two small durations does not land there. The same arithmetic reads
    #   0.9999999999997817 from a base of 2000 and 1.000000000000009 from 1000, and no
    #   caller asks at an instant anyway -- they ask once a frame.
    interaction.beginHold(7, 2000.0)
    check takeHold(interaction, 2000.0).isNone
    check takeHold(
      interaction, 2000.0 + SECONDS_SWELL_GROW + 1.01*SECONDS_LONG_PRESS
    ) == some(7)


  test "a cancelled hold snaps away rather than settling":
    # Cancelling is a press that stopped being one -- moved into a camera gesture, or
    #   interrupted -- so there is nothing left for a settle to be about.
    var interaction = Interaction(is_enabled: true)
    interaction.beginHold(0, 1000.0)
    check swellHold(interaction, 1000.0 + SECONDS_SWELL_GROW) =~ 1.0
    interaction.cancelHold()
    check swellHold(interaction, 1000.0 + SECONDS_SWELL_GROW) =~ 0.0
    check not isHoldSpent(interaction, 1000.0 + 10.0)


suite "Marker":
  const (WIDTH_MARK, HEIGHT_MARK) = (800, 600)

  proc setUpAt(
    azimuth, elevation, distance: float
  ): (Camera, Matrix4, DrawExtent) =
    ## Build a camera looking at the origin from one placement, with the transform and
    ## extent a frame carries.
    ##   Orientation is a parameter because a marker's own worst case can lie along it: a
    ##   line's rails flared threefold at one azimuth while reading true at another, and
    ##   the round that shipped that swept distance alone.
    let placement = initCamera(
      target = Position(x: 0, y: 0, z: 0), distance = distance, azimuth = azimuth,
      elevation = elevation,
    )
    let scale = placement.drawExtentFor(HEIGHT_MARK)
    (placement, placement.initMatrixViewProjection(WIDTH_MARK/HEIGHT_MARK), scale)

  proc setUp(distance = 19.0): (Camera, Matrix4, DrawExtent) =
    ## The placement most of these cases read, at the one orientation they were written
    ## against.
    setUpAt(azimuth = 0.9, elevation = 0.4, distance = distance)

  proc markerOf(
    geometry: Multivector; anchor = none(Position); progress = 1.0;
    travel = none(float); distance = 19.0
  ): Option[Marker] =
    let (placement, view_projection, scale) = setUp(distance)
    markerFor(
      geometry, anchor, scale, placement, view_projection, WIDTH_MARK, HEIGHT_MARK,
      progress, is_touch = false, travel = travel,
    )

  func apartRails(marker: Marker): float =
    ## Widest the two rails read apart anywhere along them, in screen pixels.
    ##   The perpendicular distance from one rail's own points to the *infinite line*
    ##   through the other's, sampled along both -- never the distance between the two
    ##   rails' drawn endpoints, which `fractionLeavingView` cuts at its own fraction per
    ##   rail, so those endpoints are not at the same place along the line and the distance
    ##   between them measures nothing.
    # Segments arrive side 0's two halves then side 1's; each side's halves share a support
    #   and run opposite ways, so either half's own line carries the whole rail.
    if marker.count_segment < 4: return 0.0
    for (own, other) in [(0, 2), (1, 3), (2, 0), (3, 1)]:
      for step in 0 .. 2:
        let along = marker.segments[own][0].towards(
          marker.segments[own][1], float(step)/2.0
        )
        result = max(
          result,
          awayFromScreen(along, marker.segments[other][0], marker.segments[other][1]),
        )

  proc reachRails(marker: Marker): float =
    ## Total screen length of every rail piece, which is what a filling hold grows.
    for i in 0 ..< marker.count_segment:
      let piece = marker.segments[i]
      result += hypot(piece[1].x - piece[0].x, piece[1].y - piece[0].y)

  proc radiusLoop(marker: Marker): float =
    ## Greatest screen distance between two of a loop's own points, which stands in for
    ## its radius without needing the centre it was built around.
    for i in 0 ..< marker.count_point:
      for j in i + 1 ..< marker.count_point:
        result = max(result, hypot(
          marker.points[j].x - marker.points[i].x, marker.points[j].y - marker.points[i].y
        ))

  let
    POINT_A = toMultivector(Position(x: 1.0, y: 0.0, z: 2.0))
    POINT_B = toMultivector(Position(x: 4.0, y: 1.0, z: 2.0))
    POINT_C = toMultivector(Position(x: 2.0, y: 5.0, z: 3.5))
    LINE = POINT_A ∧ POINT_B
    PLANE = POINT_A ∧ POINT_B ∧ POINT_C
    LINE_HORIZON = attitude(PLANE)
      ## A plane's own attitude: the pencil of directions lying in it, at horizon.
    PLANE_HORIZON = attitude(
      toMultivector(Position(x: 0.0, y: 0.0, z: 0.0)) ∧ PLANE
    ) ## The whole sky, built the way `storyboard`'s own step 11 builds it -- the attitude
      ## of a grade-4 volume, which needs a point genuinely *off* the plane or the wedge
      ## vanishes and there is no volume to take the attitude of.

  test "each shape asks for the outline that echoes it":
    check markerOf(POINT_A).get.kind == MarkerKind.Ring
    check markerOf(LINE).get.kind == MarkerKind.Rails
    check markerOf(PLANE).get.kind == MarkerKind.Loop


  test "a point's ring clears the drawn point by the shared gap":
    let marker = markerOf(POINT_A).get
    check marker.radius =~ 0.5*float(SIZE_POINT) + GAP_MARKER


  const TOLERANCE_PIXEL_TILT = 0.25
    ## What `directionAcross`'s own tilt out of the projection plane is worth, in pixels.

  test "a line's rails hold their own gap, at every orientation":
    # The case the previous two rounds needed and did not have. A world offset hands the
    #   *rate* of convergence to perspective, and along the half of a line whose far point
    #   lies behind the eye that is not convergence but a flare -- measured at 45.6 px
    #   against a stated 14.5. The ceiling that was tried against it capped the gap at the
    #   support only, and the table that justified it swept camera *distance* at one
    #   orientation, which is the one axis the flare does not lie along.
    #   So this sweeps orientation, and asserts the bound everywhere along the rails
    #   rather than at one point on them. `OFFSET_MARKER_RAIL` is now the ceiling on what
    #   a reader ever sees rather than the gap at the support, so this is the assertion
    #   that constant is defined by rather than one it happens to satisfy.
    for azimuth in [0.2, 0.6, 1.6, 2.4, 4.0]:
      for elevation in [0.05, 0.4, 0.9]:
        for distance in [8.0, 19.0, 30.0]:
          let (placement, view_projection, scale) = setUpAt(azimuth, elevation, distance)
          let marker = markerFor(
            LINE, none(Position), scale, placement, view_projection, WIDTH_MARK,
            HEIGHT_MARK, progress = 1.0, is_touch = false, travel = none(float),
          )
          if marker.isNone: continue
          # Two-sided, which is the whole property: the pair reads its stated gap at its
          #   widest -- never more, whatever perspective would have made of a fixed world
          #   offset, and never so much less that the marker stops saying anything. Over
          #   this sweep the widest reading spans 14.2 to 14.5 px against a stated 14.5.
          #   A quarter pixel of slack above, not `TOLERANCE_SINGLE`: stepping
          #   perpendicular to the sight ray tilts a hair out of the plane perspective
          #   divides by -- see `marker.directionAcross`.
          let apart = apartRails(marker.get)
          check apart <= 2.0*OFFSET_MARKER_RAIL + TOLERANCE_PIXEL_TILT
          check apart >= 0.95*2.0*OFFSET_MARKER_RAIL


  test "a rail is one straight line, not two halves meeting at an angle":
    # The case that would have caught a round that bought a flat gap by offsetting a rail's
    #   two halves differently: measured on that build, one rail turned 2.66 degrees at its
    #   support and the far end of one half strayed 7.3 px -- the whole gap -- from the
    #   straight continuation of the other. It was invisible at the one camera the shots
    #   were taken from and obvious at another, so this sweeps orientation too.
    #   Straight is structural rather than lucky: a rail's two halves run from one offset
    #   support to the two vanishing points the line shares with it, so they are two parts
    #   of one world line.
    for azimuth in [0.2, 0.6, 1.6, 2.4, 4.0]:
      for elevation in [0.05, 0.4, 0.9]:
        let (placement, view_projection, scale) = setUpAt(azimuth, elevation, 19.0)
        let marker = markerFor(
          LINE, none(Position), scale, placement, view_projection, WIDTH_MARK,
          HEIGHT_MARK, progress = 1.0, is_touch = false, travel = none(float),
        )
        if marker.isNone or marker.get.count_segment < 4: continue
        # Segments 0 and 1 are one side's own two halves, sharing a support at index 0.
        for side in [0, 2]:
          let (before, after) = (marker.get.segments[side], marker.get.segments[side + 1])
          # The far end of one half, against the infinite line through the other.
          check awayFromScreen(after[1], before[0], before[1]) < TOLERANCE_SINGLE


  test "a line's rails spend their spread rather than their visibility":
    # What a world offset costs is that perspective, not the reader, chooses how far apart
    #   the pair ends up: at one camera it read 45.6 px against a stated 14.5. The offset
    #   is now settled until the *widest* reading is the stated gap, so what an oblique
    #   view takes is the gap at the narrow end -- the pair closing on its own line -- and
    #   never the marker itself.
    proc apartAtSupport(azimuth, elevation, distance: float): float =
      let (placement, view_projection, scale) = setUpAt(azimuth, elevation, distance)
      let marker = markerFor(
        LINE, none(Position), scale, placement, view_projection, WIDTH_MARK, HEIGHT_MARK,
        progress = 1.0, is_touch = false, travel = none(float),
      )
      if marker.isNone or marker.get.count_segment < 4: return 0.0
      hypot(
        marker.get.segments[2][0].x - marker.get.segments[0][0].x,
        marker.get.segments[2][0].y - marker.get.segments[0][0].y,
      )
    # The support is where a world offset states its gap, and it is exactly what an oblique
    #   view now gives up: 4.5 px at the camera below against 13.1 at a squarer one.
    check apartAtSupport(0.2, 0.05, 12.0) < apartAtSupport(1.6, 0.9, 19.0)
    check apartAtSupport(0.2, 0.05, 12.0) < 2.0*OFFSET_MARKER_RAIL
    # And the marker is still there to be seen, which the sweep above holds everywhere: it
    #   is the *widest* reading that is pinned, so the pair is that far apart somewhere by
    #   construction. No floor under the narrowing is needed, and one tried at four tenths
    #   let a 437 px splay through at a camera this sweep does contain.
    check apartRails(markerOf(LINE, distance = 12.0).get) > OFFSET_MARKER_RAIL


  test "a line's rails are drawn in the halves the line itself is drawn in":
    let marker = markerOf(LINE).get
    check marker.count_segment == SEGMENTS_MARKER_RAILS


  test "an eye standing on the line has no side to flank it from":
    # Joining the line with the eye gives no plane to take a normal of -- and there is
    #   nothing a pair of rails either side of it could mean to a viewer inside it.
    let scale = setUp()[2]
    let through_eye = toMultivector(scale.eye) ∧
      toMultivector(scale.eye + Direction(x: 1.0, y: 0.0, z: 0.0))
    check markerOf(through_eye).isNone


  test "a plane's marker circle lies on that plane, at every one of its points":
    let (placement, _, scale) = setUp()
    let
      centre = positionAnchor(PLANE).get
      radius = radiusMarkerLoop(centre, scale, placement, HEIGHT_MARK)
      ring = positionsMarkerLoop(centre, frame(PLANE).get, radius)
    # A unitized point wedged with a unitized plane leaves its own signed distance from
    #   that plane on the antiscalar, so this reads as "how far off the surface".
    for point in ring:
      check abs((unitize(toMultivector(point)) ∧ unitize(PLANE))[Basis.scalarAnti]) =~ 0.0


  test "a plane's marker circle clears the drawn rim by the shared gap":
    let (placement, _, scale) = setUp()
    let
      centre = positionAnchor(PLANE).get
      radius = radiusMarkerLoop(centre, scale, placement, HEIGHT_MARK)
      per_pixel = worldPerPixelAt(centre, scale)
    check (radius - EXTENT_PLANE_F)/per_pixel =~ GAP_MARKER


  test "a plane's marker follows its stored creation anchor, as its disc does":
    let elsewhere = positionAnchor(PLANE).get + 3.0*frame(PLANE).get.axis_first
    let
      centred = markerOf(PLANE).get
      shifted = markerOf(PLANE, some(elsewhere)).get
      moved = hypot(
        shifted.points[0].x - centred.points[0].x,
        shifted.points[0].y - centred.points[0].y,
      )
    check moved > 1.0


  test "a line at horizon is flanked by bands, wrapping the sky as its own circle does":
    # A plane's own attitude is a line at horizon -- the pencil of directions lying in it.
    let marker = markerOf(LINE_HORIZON).get
    check marker.kind == MarkerKind.Bands
    # Both bands survive here: this line crosses the view, so each of its two flanking
    #   circles has a stretch of itself on screen.
    check marker.counts_band[0] > 0
    check marker.counts_band[1] > 0

    # Only what survives the near plane *and* the edge of the window is reported, so every
    #   point handed to an overlay is one it can actually stroke and one a reader can
    #   actually see -- `Loop`'s own rule, twice over and one cut further.
    for side in 0 .. 1:
      for i in 0 ..< marker.counts_band[side]:
        check marker.points_band[side][i].isInFront
        check marker.points_band[side][i].isWithinView(WIDTH_MARK, HEIGHT_MARK)

    # And it stops *at* the edge rather than a sample short of it: a band's samples are
    #   even in angle around the sky and hundreds of pixels apart once projected, so the
    #   crossing point is placed rather than rounded to the last one inside.
    for side in 0 .. 1:
      let (first, last) = (
        marker.points_band[side][0],
        marker.points_band[side][marker.counts_band[side] - 1],
      )
      for at in [first, last]:
        check min(min(at.x, WIDTH_MARK.float - at.x), min(at.y, HEIGHT_MARK.float - at.y)) =~ 0.0


  test "a horizon line's bands lap in what the view can show, so its comet is seen":
    # The fault this guards: a band is a circle running out to the line's own vanishing
    #   points, and uncut it laps in hundreds of thousands of pixels of outline no camera
    #   can see -- measured at 396,102 against the 1,490 on screen. A comet travelling at
    #   a fixed screen pace was then off screen for all but four frames in a thousand,
    #   which is what "the pulse does not work on horizon lines" meant.
    let
      bands = markerOf(LINE_HORIZON, travel = some(0.3*LENGTH_MARKER_COMET)).get
      rails = markerOf(LINE, travel = some(0.3*LENGTH_MARKER_COMET)).get
    # Within the same order of magnitude as a finite line's rails, which are bounded by
    #   the very same rule. A window's own diagonal is the scale both are measuring.
    check bands.lap > 0.0
    check bands.lap < 4.0*rails.lap
    check bands.lap < hypot(WIDTH_MARK.float, HEIGHT_MARK.float)*2.0
    # Both bands pulse, and in step: one of a pair lit and the other not reads as the
    #   marker having broken rather than as a direction.
    check bands.count_run_pulse == 2

    # The comet advances along the band at the screen pace, rather than standing still
    #   because almost all of its lap is somewhere a reader cannot look.
    var travel = 0.3*LENGTH_MARKER_COMET
    var heads: seq[ScreenPosition]
    for frame in 0 .. 3:
      let marker = markerOf(LINE_HORIZON, travel = some(travel)).get
      check marker.count_run_pulse > 0
      heads.add(marker.pulses[0][0])
      travel = travelAdvanced(travel, marker.lap, 1.0)
    for i in 1 ..< heads.len:
      let step = hypot(heads[i].x - heads[i - 1].x, heads[i].y - heads[i - 1].y)
      # The chord of a gently curved band rather than the arc along it, so within a
      #   fraction of a percent of the pace rather than exactly it.
      check abs(step - SPEED_MARKER_PULSE) < 0.01*SPEED_MARKER_PULSE
      check heads[i].isWithinView(WIDTH_MARK, HEIGHT_MARK)


  test "a cut arc still measures its pulse from the ring's own angle zero":
    # Twelve samples, the arc emitted from sample 9, five of them surviving: angle zero is
    #   the fourth of those, since 9, 10, 11, 0 walks to it.
    check originAfterCut(12, 9, 5) == 3
    # Points placed ahead of the samples -- the crossing point at the edge a band enters
    #   through -- shift it by however many there are, or the comet would be anchored to
    #   the cut rather than to the object.
    check originAfterCut(12, 9, 5, count_before = 1) == 4
    # Angle zero cut away leaves nothing view-independent to measure from, and the arc's
    #   own start is what is left -- the crossing point itself, where there is one.
    check originAfterCut(12, 9, 2) == 0
    check originAfterCut(12, 9, 2, count_before = 1) == 0


  test "one band is drawn from the longest stretch of it the window holds":
    # A ring can cross the window more than once -- a band seen nearly end on is a circle
    #   about the vanishing point, entering and leaving twice. One outline per band is
    #   what the marker holds, so the largest piece is the one drawn.
    let ring = [
      ScreenPosition(x: 10.0, y: 10.0, depth: 1.0),
      ScreenPosition(x: 20.0, y: 10.0, depth: 1.0),
      ScreenPosition(x: -50.0, y: 10.0, depth: 1.0),
      ScreenPosition(x: 30.0, y: 20.0, depth: 1.0),
      ScreenPosition(x: 420.0, y: 20.0, depth: 1.0),
      ScreenPosition(x: -60.0, y: 20.0, depth: 1.0),
    ]
    # Two stretches of two samples each: samples 0..1 spanning 10 pixels and samples 3..4
    #   spanning 390. The longer one wins, and it is not the one found first.
    check runShownLongest(ring, [true, true, false, true, true, false]) == (3, 2)
    # A stretch straddling sample zero is one stretch, not the two an index walk sees.
    check runShownLongest(ring, [true, false, false, false, true, true]) == (4, 3)
    # A ring wholly shown is one closed stretch from its own first sample.
    check runShownLongest(ring, [true, true, true, true, true, true]) == (0, 6)
    # And nothing shown is no stretch at all, which draws no band.
    check runShownLongest(ring, [false, false, false, false, false, false]) == (0, 0)


  test "a horizon line's bands close inward as its hold fills, from outside any view":
    let (_, _, scale) = setUp()
    let
      opening = angleMarkerBands(scale, 0.0, 0.0)
      midway = angleMarkerBands(scale, 0.5, 0.0)
      settled = angleMarkerBands(scale, 1.0, 0.0)
    # A quarter turn off the line at the start -- the pole of its own sky, and so outside
    #   any field of view this camera offers, which is what "arriving from outside" means
    #   for an object that has no support to grow out from.
    check opening =~ ANGLE_MARKER_BANDS_OPEN
    check midway < opening
    check settled < midway
    # And settles at the very gap a finite line's rails keep, read as an angle.
    check settled =~ OFFSET_MARKER_RAIL*radiansPerPixel(scale)


  test "a plane at horizon is framed by the viewport, arriving as the screen's edge":
    # The attitude of a grade-4 object is the plane at horizon -- the whole sky.
    let marker = markerOf(PLANE_HORIZON).get
    check marker.kind == MarkerKind.Frame

    let
      (centre_x, centre_y) = (0.5*float(WIDTH_MARK), 0.5*float(HEIGHT_MARK))
      (inside_x, inside_y) =
        (float(WIDTH_MARK) - GAP_MARKER, float(HEIGHT_MARK) - GAP_MARKER)
    proc distancesFromCentre(marker: Marker): seq[float] =
      for i in 0 ..< marker.count_frame:
        let point = marker.points_frame[i]
        result.add(hypot(point.x - centre_x, point.y - centre_y))

    # The finished frame *is* the viewport's rectangle, standing `GAP_MARKER` inside it --
    #   the same clear space every other marker in the family keeps from what it surrounds.
    #   Every point lies on that rectangle, and its extremes reach the whole way to it.
    check marker.count_frame >= SEGMENTS_MARKER_FRAME
    var (reached_x, reached_y) = (false, false)
    for i in 0 ..< marker.count_frame:
      let point = marker.points_frame[i]
      check point.x >= GAP_MARKER - TOLERANCE_SINGLE
      check point.x <= inside_x + TOLERANCE_SINGLE
      check point.y >= GAP_MARKER - TOLERANCE_SINGLE
      check point.y <= inside_y + TOLERANCE_SINGLE
      # On the rectangle, not merely within it: one coordinate is pinned to an edge.
      check point.x =~ GAP_MARKER or point.x =~ inside_x or
        point.y =~ GAP_MARKER or point.y =~ inside_y
      if point.x =~ GAP_MARKER or point.x =~ inside_x: reached_x = true
      if point.y =~ GAP_MARKER or point.y =~ inside_y: reached_y = true
    check reached_x and reached_y

    # Barely started, it is a circle about the centre of the view: every point stands the
    #   same distance out, which a scaled rectangle never does. That is the mechanic the
    #   user asked for -- expanding outward from the middle rather than shrinking inward
    #   from the edge -- and it is the opposite of the bands above, which close in from
    #   outside any view at all.
    # Full reach is the corners' own distance, so `progress` of it is the circle's radius
    #   for as long as the circle is the thing bounding it.
    let half_diagonal = hypot(centre_x - GAP_MARKER, centre_y - GAP_MARKER)
    proc reachAt(progress: float): float = progress*half_diagonal
    let opening = distancesFromCentre(markerOf(PLANE_HORIZON, progress = 0.1).get)
    for distance in opening: check distance =~ reachAt(0.1)
    check reachAt(0.1) < centre_y - GAP_MARKER # Still clear of the nearest edge.

    # Part way, the circle has passed the short edges but not the corners, so the boundary
    #   is edge in some directions and still circle in others -- which is what "highlights
    #   each part of the edge as it gets there" means, checked rather than assumed.
    let partial = markerOf(PLANE_HORIZON, progress = 0.75).get
    var (count_on_edge, count_off_edge) = (0, 0)
    for i in 0 ..< partial.count_frame:
      let point = partial.points_frame[i]
      if point.x =~ GAP_MARKER or point.x =~ inside_x or
          point.y =~ GAP_MARKER or point.y =~ inside_y:
        inc count_on_edge
      else:
        inc count_off_edge
    check count_on_edge > 0
    check count_off_edge > 0
    # And the part still short of the edge is circular at that same shared reach, so the
    #   marker really is one expanding circle bitten into by the screen, not two shapes.
    for i in 0 ..< partial.count_frame:
      let point = partial.points_frame[i]
      if point.x =~ GAP_MARKER or point.x =~ inside_x or
          point.y =~ GAP_MARKER or point.y =~ inside_y: continue
      check hypot(point.x - centre_x, point.y - centre_y) =~ reachAt(0.75)

    # A frame's four corners are sampled explicitly, so the finished outline has real
    #   corners rather than corners cut across by wherever the even steps happened to land.
    var count_corner = 0
    for i in 0 ..< marker.count_frame:
      let point = marker.points_frame[i]
      if (point.x =~ GAP_MARKER or point.x =~ inside_x) and
          (point.y =~ GAP_MARKER or point.y =~ inside_y):
        inc count_corner
    check count_corner == CORNERS_MARKER_FRAME


  test "a touch hold swells every marker clear of the finger, and a mouse never sees it":
    # The reason the swell exists: a fingertip covers what it presses, so a marker filling
    #   underneath one says nothing to the person filling it. How far out it stands is now
    #   a plain scaling of the swell, whose *shape* is `interaction.swellHold`'s to decide.
    const RADIUS_FINGER = 22.0 # Half the 44-pixel minimum touch target.
    check clearanceTouch(0.0, is_touch = true) =~ 0.0
    check RADIUS_MARKER_POINT + clearanceTouch(1.0, is_touch = true) > RADIUS_FINGER
    for swell in [0.0, 0.25, 0.5, 0.75, 1.0]:
      check clearanceTouch(swell, is_touch = false) =~ 0.0


  test "a point at horizon keeps its ring, on the star it is drawn as":
    # Its own star stands one horizon radius along its direction, so it is markable only
    #   while the camera is turned toward it -- behind the eye it reports the same
    #   "nothing to draw" every other unmarkable case does.
    proc ringAt(azimuth: float): Option[Marker] =
      let placement = initCamera(
        target = Position(x: 0, y: 0, z: 0), distance = 19.0, azimuth = azimuth,
        elevation = 0.4,
      )
      let scale = placement.drawExtentFor(HEIGHT_MARK)
      markerFor(
        attitude(LINE), none(Position), scale, placement,
        placement.initMatrixViewProjection(WIDTH_MARK/HEIGHT_MARK), WIDTH_MARK, HEIGHT_MARK,
      )
    check ringAt(1.9).get.kind == MarkerKind.Ring
    check ringAt(0.0).isNone


  test "a marker at full progress is exactly the marker drawn with no progress asked for":
    # The property the whole animation rests on: adding `progress` moved nothing for any
    #   caller that is not animating a hold. Held here as well as by the storyboard's own
    #   byte comparison, so a regression names itself rather than showing up as a pixel.
    check markerOf(POINT_A, progress = 1.0).get.fraction == 1.0
    check reachRails(markerOf(LINE, progress = 1.0).get) =~ reachRails(markerOf(LINE).get)
    check radiusLoop(markerOf(PLANE, progress = 1.0).get) =~ radiusLoop(markerOf(PLANE).get)


  test "each shape fills the way its own outline is read":
    # A point sweeps, because it is drawn at one fixed size and has nothing to grow into;
    #   a line runs outward toward its horizons; a plane's circle opens from its centre.
    check markerOf(POINT_A, progress = 0.25).get.fraction =~ 0.25
    check markerOf(POINT_A, progress = 0.25).get.radius =~
      markerOf(POINT_A).get.radius # Swept, never shrunk.
    var
      reach_previous = 0.0
      radius_previous = 0.0
    for step in 1 .. 8:
      let progress = float(step)/8.0
      let (reach, radius) = (
        reachRails(markerOf(LINE, progress = progress).get),
        radiusLoop(markerOf(PLANE, progress = progress).get),
      )
      check reach > reach_previous
      check radius > radius_previous
      (reach_previous, radius_previous) = (reach, radius)


  test "a rail that is only part grown still lies along the rail it will become":
    # Growing a rail must not slide it off the line it flanks. Every partial head sits on
    #   the segment between the finished rail's own two ends, which is the line's own
    #   screen projection -- the reason the shortening is done after projecting, along
    #   that segment, rather than by scaling a world reach anchored at the eye.
    let whole = markerOf(LINE).get
    for step in 1 .. 4:
      let part = markerOf(LINE, progress = float(step)/4.0).get
      check part.count_segment == whole.count_segment
      for i in 0 ..< whole.count_segment:
        let
          (tail, head) = (whole.segments[i][0], whole.segments[i][1])
          grown = part.segments[i][1]
          along = hypot(head.x - tail.x, head.y - tail.y)
          # Distance from the grown head to the whole rail, as twice the triangle's area
          #   over its base: zero exactly when the three points are collinear.
          area_twice = abs(
            (head.x - tail.x)*(grown.y - tail.y) - (head.y - tail.y)*(grown.x - tail.x)
          )
        check part.segments[i][0] == tail # Still starts where the finished rail starts.
        check area_twice/along < TOLERANCE_SINGLE


  test "a line's rails grow across the view, both halves at a comparable rate":
    # The defect this pins: a rail was shortened by a fraction of its *own* projected
    #   length, and that length runs to a vanishing point. Measured on the demo's own
    #   line, one half came to 1,140,706 pixels and the other to 3,634 -- so one finished
    #   314 times sooner than the other, and both were wholly off a 900-pixel screen
    #   within the first percent of the hold. Growing toward a vanishing point is growing
    #   into nothing; the reach is measured against the edge of the view instead.
    proc lengthsAt(progress: float): seq[float] =
      let marker = markerOf(LINE, progress = progress).get
      for i in 0 ..< marker.count_segment:
        let (tail, head) = (marker.segments[i][0], marker.segments[i][1])
        result.add(hypot(head.x - tail.x, head.y - tail.y))

    let whole = lengthsAt(1.0)
    check len(whole) >= 2
    # No rail runs further than the view's own diagonal: the growth is all on screen.
    let diagonal = hypot(float(WIDTH_MARK), float(HEIGHT_MARK))
    for length in whole: check length <= diagonal

    # The halves stay within a small factor of one another rather than a wild one, and
    #   each is a straight multiple of progress -- one speed, from the support, both ways.
    check max(whole)/max(min(whole), 1.0) < 4.0
    for step in 1 .. 3:
      let progress = float(step)/4.0
      let partial = lengthsAt(progress)
      check len(partial) == len(whole)
      for i in 0 ..< len(whole): check partial[i] =~ progress*whole[i]


  test "a rail bounded by the view stops at the edge it leaves through":
    const (WIDE, TALL) = (200.0, 100.0)
    let inside = ScreenPosition(x: 100.0, y: 50.0)
    # Straight out to the right: half the width away, so half of a segment twice as long.
    check fractionLeavingView(
      inside, ScreenPosition(x: 300.0, y: 50.0), int(WIDE), int(TALL)
    ) =~ 0.5
    # Ending inside is not shortened at all.
    check fractionLeavingView(
      inside, ScreenPosition(x: 150.0, y: 60.0), int(WIDE), int(TALL)
    ) =~ 1.0
    # Starting outside and heading further out draws nothing, which is what can be seen.
    check fractionLeavingView(
      ScreenPosition(x: 400.0, y: 50.0), ScreenPosition(x: 900.0, y: 50.0),
      int(WIDE), int(TALL),
    ) =~ 0.0


  test "a pulse rides its own outline, and only where there is an orientation to state":
    proc pulsed(geometry: Multivector; travel: float): Marker =
      markerOf(geometry, travel = some(travel)).get

    # A plane's circle and a line's rails both carry one; a point has no orientation and
    #   a plane at horizon carries no normal at all, so neither says anything.
    check pulsed(PLANE, 0.3).count_run_pulse > 0
    check pulsed(LINE, 0.3).count_run_pulse > 0
    # A horizon line's bands are cut to the view at both ends, and their own angle zero
    #   stands off screen here, so travel is measured from the edge the arc enters
    #   through -- a third of a pixel past which is a comet with no tail yet, by the same
    #   clamp that keeps an arc's run from drawing a chord across the view. Read where
    #   the comet is actually on its way round.
    check pulsed(LINE_HORIZON, 0.3*LENGTH_MARKER_COMET).count_run_pulse > 0
    check pulsed(POINT_A, 0.3).count_run_pulse == 0
    check pulsed(PLANE_HORIZON, 0.3).count_run_pulse == 0
    # Nothing pulses unless a caller says the object is selected by passing a time.
    check markerOf(PLANE).get.count_run_pulse == 0

    # Every point of it lies on the very outline it rides, to within its own half-width:
    #   the run is sampled from the marker's own points rather than traced on a curve of
    #   its own, and then wrapped in a ribbon standing off that spine either side.
    let marker = pulsed(PLANE, 0.3)
    proc distanceToLoop(point: ScreenPosition; marker: Marker): float =
      result = high(float)
      for i in 0 ..< marker.count_point:
        let (first, second) = (marker.points[i], marker.points[(i + 1) mod marker.count_point])
        let (dx, dy) = (second.x - first.x, second.y - first.y)
        let span = dx*dx + dy*dy
        let along =
          if span <= 0.0: 0.0
          else: clamp(((point.x - first.x)*dx + (point.y - first.y)*dy)/span, 0.0, 1.0)
        let on = first.towards(second, along)
        result = min(result, hypot(point.x - on.x, point.y - on.y))
    for run in 0 ..< marker.count_run_pulse:
      # Both sides and the head's cap, so every run is one closed loop of them.
      check marker.counts_pulse[run] mod 2 == SEGMENTS_MARKER_CAP mod 2
      for i in 0 ..< marker.counts_pulse[run]:
        check distanceToLoop(marker.pulses[run][i], marker) <
          0.5*float(WIDTH_MARKER_COMET) + 1.0

    # The run tapers: its head stands off the spine by half `WIDTH_MARKER_COMET`, and its
    #   tail meets the outline at the outline's own width, so only the head is an edge.
    let outline = marker.pulses[0]
    let count = marker.counts_pulse[0]
    let spans = (count - SEGMENTS_MARKER_CAP) div 2
    proc widthAcross(i: int): float =
      hypot(outline[i].x - outline[2*spans - 1 - i].x,
        outline[i].y - outline[2*spans - 1 - i].y)
    check widthAcross(0) =~ float(WIDTH_MARKER_COMET)
    check widthAcross(spans - 1) =~ float(WIDTH_MARKER)
    # And it thins the whole way, never swelling again behind its own head.
    for i in 1 ..< spans:
      check widthAcross(i) <= widthAcross(i - 1) + TOLERANCE_SINGLE


  test "a pulse is the same length whatever shape it rides":
    # The point of measuring the run in pixels. Under a fraction of the outline it came out
    #   96 px along a line's rail against 334 px round a plane's circle -- one constant, a
    #   compact comet on one shape and a long gradient on another.
    proc lengthOfRun(marker: Marker; run: int): float =
      # Down the middle of the ribbon, which recovers the spine it was built around: its
      #   own two edges splay wherever the width changes, and are longer than the run.
      let spans = (marker.counts_pulse[run] - SEGMENTS_MARKER_CAP) div 2
      proc middleAt(i: int): ScreenPosition =
        marker.pulses[run][i].towards(marker.pulses[run][2*spans - 1 - i], 0.5)
      for i in 1 ..< spans:
        let (a, b) = (middleAt(i - 1), middleAt(i))
        result += hypot(b.x - a.x, b.y - a.y)

    # Partway along, so no run is one shortened by the end of an open arc.
    for geometry in [PLANE, LINE, LINE_HORIZON]:
      let lap = markerOf(geometry, travel = some(0.0)).get.lap
      let shaped = markerOf(geometry, travel = some(0.4*lap)).get
      check shaped.count_run_pulse > 0
      for run in 0 ..< shaped.count_run_pulse:
        # A run laid along a curve is a chain of chords, so it falls a hair short of the
        #   arc it covers; nothing else may.
        check lengthOfRun(shaped, run) <= LENGTH_MARKER_COMET + TOLERANCE_SINGLE
        check lengthOfRun(shaped, run) > 0.98*LENGTH_MARKER_COMET


  proc headOfRun(marker: Marker; run: int): ScreenPosition =
    ## Where a run's spine begins, recovered from the middle of the ribbon around it: its
    ##   own edges ride wide of the spine on the outside of any bend.
    let spans = (marker.counts_pulse[run] - SEGMENTS_MARKER_CAP) div 2
    marker.pulses[run][0].towards(marker.pulses[run][2*spans - 1], 0.5)

  test "one step of travel carries the head that many pixels, on every shape":
    # The marker's half of a constant screen speed, and the whole point of the units: a
    #   step of travel buys the same *pixels* on every shape, where a step of phase bought
    #   a share of whatever the outline currently measured -- which is why the same step
    #   moved the head further on a long rail than a short one, and further still once the
    #   camera had stretched it. How many seconds a step takes is `PulseClock`'s half.
    for geometry in [PLANE, LINE, LINE_HORIZON]:
      let lap = markerOf(geometry, travel = some(0.0)).get.lap
      proc headAt(travelled: float): ScreenPosition =
        headOfRun(markerOf(geometry, travel = some(travelled)).get, 0)
      const STEP = 4.0
      let
        start = 0.4*lap
        crossed = hypot(
          headAt(start + STEP).x - headAt(start).x, headAt(start + STEP).y - headAt(start).y
        )
      # A chord, so a hair under the arc actually covered -- and no `lap` on either side of
      #   the comparison, which is the assertion this case exists to make.
      check crossed <= STEP + TOLERANCE_SINGLE
      check crossed > 0.98*STEP


  test "a camera move slides a line's comet with the line, never along it":
    # **The case whose absence let this ship twice.** Every other pulse case pins one
    #   camera, so a head measured as a fraction of a viewport-clipped outline looked
    #   perfect standing still and slid the moment the view moved -- measured at the time
    #   as a median 3.76 px a frame while orbiting, recorded as motion the marker was
    #   "entitled to", and reported by a reader who disagreed.
    #   A rail is straight on screen, so the distance from its anchor to the head *is* the
    #   travel, exactly, with no chord error to allow for. That makes a line the shape this
    #   states most sharply -- and a line is what was reported. A curved outline's chord is
    #   not its arc and its curvature moves with the camera, so the same assertion on a
    #   plane would be measuring the circle, not the comet.
    const TRAVEL_CASE = 37.0
    var count_checked = 0
    for azimuth in [0.2, 0.9, 1.7, 2.6, 3.4]:
      for elevation in [-0.5, 0.4, 1.0]:
        for distance in [9.0, 19.0, 34.0]:
          let (placement, view_projection, scale) =
            setUpAt(azimuth = azimuth, elevation = elevation, distance = distance)
          let shaped = markerFor(
            LINE, none(Position), scale, placement, view_projection,
            WIDTH_MARK, HEIGHT_MARK, 1.0, is_touch = false, travel = some(TRAVEL_CASE),
          )
          if shaped.isNone or shaped.get.count_run_pulse == 0: continue
          # Skip a placement with too little rail left to hold the travel, which laps it.
          if shaped.get.lap <= TRAVEL_CASE: continue
          for run in 0 ..< shaped.get.count_run_pulse:
            let
              head = headOfRun(shaped.get, run)
              anchor = shaped.get.anchors_pulse[run]
              reached = hypot(head.x - anchor.x, head.y - anchor.y)
            check abs(reached - TRAVEL_CASE) < 1.0
            inc count_checked
    # The sweep has to actually have exercised something, or the checks above are vacuous.
    check count_checked >= 30


  test "a line wears one comet, not one for every piece it is drawn in":
    # A rail is drawn as two halves either side of the line's support, and each used to
    #   pulse on its own -- four comets at four unrelated places on one selected line.
    let lap = markerOf(LINE, travel = some(0.0)).get.lap
    let shaped = markerOf(LINE, travel = some(0.4*lap)).get
    check shaped.count_segment == 4
    check shaped.count_run_pulse == 2
    # And the pair travels together rather than each rail keeping its own clock, so the
    #   two read as one comet crossing the line rather than as two chasing each other.
    let heads = [headOfRun(shaped, 0), headOfRun(shaped, 1)]
    check hypot(heads[1].x - heads[0].x, heads[1].y - heads[0].y) < LENGTH_MARKER_COMET


  test "a line's rails pulse from their very first frame, and report a lap to reduce on":
    # The property a browser-side deadlock turned on, kept and inverted. Every slot starts
    #   at travel 0, and while travel was a *fraction* that put a line's head at the very
    #   start of an open outline with nothing behind it to light -- no run, and a marker
    #   that also reported no length left the clock unable to advance, so it never left 0.
    #   It cost a selected line its comet outright on a build whose suite was green.
    #   Measuring from the support instead puts travel 0 in the *middle* of the rail, so a
    #   run exists immediately and the deadlock has no state to occupy at all. The lap must
    #   still be reported, because that is what the clock reduces against.
    let stalled = markerOf(LINE, travel = some(0.0)).get
    check stalled.count_run_pulse == 2 # One per rail, from the first frame.
    check stalled.lap > 0.0
    check travelAdvanced(0.0, stalled.lap, 1.0) > 0.0
    # A closed outline never entered that state and still does not.
    check markerOf(PLANE, travel = some(0.0)).get.count_run_pulse == 1


  test "a pulse laps rather than stopping":
    let lap = markerOf(PLANE, travel = some(0.0)).get.lap
    proc headAt(travelled: float): ScreenPosition =
      headOfRun(markerOf(PLANE, travel = some(travelled)).get, 0)

    let start = headAt(0.0)
    var moved = 0
    for step in 1 .. 5:
      if hypot(headAt(float(step)*lap/6.0).x - start.x,
        headAt(float(step)*lap/6.0).y - start.y) > 1.0: inc moved
    check moved == 5
    # A whole lap on is where it began, so the motion is circulation rather than a run
    #   that ends somewhere.
    let lapped = headAt(lap)
    check hypot(lapped.x - start.x, lapped.y - start.y) < 1.0
    # And the advance itself reduces rather than growing without bound: three laps' worth
    #   of seconds lands exactly where one moment of it did. Reducing every step, rather
    #   than at the point of use, is what stops a change in the lap being amplified by
    #   however many laps have gone by -- see `travelAdvanced`.
    const LAP = 300.0
    check travelAdvanced(0.25*LAP, LAP, 3.0*LAP/SPEED_MARKER_PULSE) =~ 0.25*LAP


  test "the drag band swells into its head, whichever way it runs":
    const SPANS = SEGMENTS_MARKER_PULSE
    for (dx, dy) in [(120.0, 0.0), (-120.0, 0.0), (0.0, 90.0), (-70.0, -70.0)]:
      let
        tail = ScreenPosition(x: 200.0, y: 150.0)
        head = ScreenPosition(x: tail.x + dx, y: tail.y + dy)
        drawn = cometFor(tail, head).get
      # Widest across the point aimed at, thinning to the band's own width behind it, so
      #   the swell itself is what says which end the answer lands at.
      proc widthAcross(i: int): float =
        hypot(drawn[i].x - drawn[2*SPANS - 1 - i].x, drawn[i].y - drawn[2*SPANS - 1 - i].y)
      check widthAcross(0) =~ float(WIDTH_MARKER_COMET)
      check widthAcross(SPANS - 1) =~ float(WIDTH_MARKER)
      # Centred on the band rather than swung to one side of it.
      for i in [0, SPANS div 2, SPANS - 1]:
        let middle = ScreenPosition(
          x: 0.5*(drawn[i].x + drawn[2*SPANS - 1 - i].x),
          y: 0.5*(drawn[i].y + drawn[2*SPANS - 1 - i].y),
        )
        check abs((middle.x - head.x)*dy - (middle.y - head.y)*dx) < TOLERANCE_SINGLE
      # Lying behind the point aimed at, never past it, apart from the head's own cap.
      for i in 0 ..< 2*SPANS:
        check (drawn[i].x - head.x)*dx + (drawn[i].y - head.y)*dy <= TOLERANCE_SINGLE

  test "a drag band shorter than the comet lights all of itself, and no more":
    # Otherwise the head would reach back past the very object the drag started on.
    let
      tail = ScreenPosition(x: 100.0, y: 100.0)
      near = ScreenPosition(x: 100.0 + 0.5*LENGTH_MARKER_COMET, y: 100.0)
      drawn = cometFor(tail, near).get
    for point in drawn: check point.x >= tail.x - TOLERANCE_SINGLE


  test "a band with nowhere to point draws no head":
    # The cursor resting on its own source: an ordinary moment in a drag, not an error.
    let at = ScreenPosition(x: 40.0, y: 90.0)
    check cometFor(at, at).isNone


  test "geometry standing for no shape gets no marker":
    check markerOf(POINT_A + PLANE).isNone
