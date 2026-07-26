## Check invariants of visualiser against deterministically sampled pool of RGA objects.
##
## Suites are named after visualiser's modules rather than after Lengyel's chapters,
## since visualiser is tool built on library rather than replication of published equations.
##
## Pool is drawn once from seeded generator, so failure reproduces from test name alone.
##   Points are sampled inside box well inside camera's view, so visibility is not incidental.
##   Lines and planes are joined from those points, so degenerate cases stay improbable.

when compileOption("profiler"):
  import std/nimprof

import std/[math, options, os, random, strutils, unittest]

import ../../pga
import ../../visualiser/[camera, canvas, objects, scene]

randomize(0)


const
  SAMPLES = 64
  EXTENT_SAMPLE = 5.0
  TOLERANCE_PLACES_TEST {.define: "visualiser.tolerance_places".} = 9
  TOLERANCE_TEST = 10.0.pow(-float(TOLERANCE_PLACES_TEST))

let
  ORIGIN = Position(x: 0, y: 0, z: 0)
  CAMERA = initCamera(
    eye = Position(x: 15.0, y: 12.0, z: 9.0),
    target = Position(x: 0.0, y: 0.0, z: 1.0),
    up = Direction(x: 0.0, y: 0.0, z: 1.0),
  )


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


func `=~`(a, b: float): bool =
  ## Compare approximate equality between scalars.
  abs(a - b) <= TOLERANCE_TEST * max(1.0, max(abs(a), abs(b)))


func `=~`(p, q: Position): bool =
  ## Compare approximate equality between positions.
  p.x =~ q.x and p.y =~ q.y and p.z =~ q.z


func `=~`(d, e: Direction): bool =
  ## Compare approximate equality between directions.
  d.x =~ e.x and d.y =~ e.y and d.z =~ e.z


func `=~`(p, q: PointImage): bool =
  ## Compare approximate equality between image points.
  p.x =~ q.x and p.y =~ q.y



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


  test "point at horizon has no position":
    for place in PLACES:
      let heading = Direction(x: place.x, y: place.y, z: place.z)
      check position(toMultivector(heading)).isNone
      check directionHorizon(toMultivector(heading)).isSome


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


  test "normal of plane is unit and perpendicular to plane":
    for plane in PLANES:
      let (normal, axes) = (directionNormal(plane), frame(plane))
      check normal.isSome and axes.isSome
      check norm(normal.get) =~ 1.0
      check dot(normal.get, axes.get.axis_first) =~ 0
      check dot(normal.get, axes.get.axis_second) =~ 0


  test "frame of plane is orthonormal and lies inside plane":
    for plane in PLANES:
      let axes = frame(plane)
      check axes.isSome
      let (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)
      check norm(axis_first) =~ 1.0
      check norm(axis_second) =~ 1.0
      check dot(axis_first, axis_second) =~ 0
      check toMultivector(axis_first) ∧ plane =~ 0
      check toMultivector(axis_second) ∧ plane =~ 0


  test "object at horizon yields no anchor":
    for line in LINES:
      let attitude = ⊖ line
      check attitude.isHorizon
      check positionAnchor(attitude).isNone



suite "Camera":
  test "frame is orthonormal and perpendicular to sight axis":
    let forward = direction(CAMERA.axis_sight)
    check forward.isSome
    check norm(CAMERA.axis_right) =~ 1.0
    check norm(CAMERA.axis_up) =~ 1.0
    check dot(CAMERA.axis_right, CAMERA.axis_up) =~ 0
    check dot(CAMERA.axis_right, forward.get) =~ 0
    check dot(CAMERA.axis_up, forward.get) =~ 0


  test "image plane stands one focal distance ahead of eye":
    check dot(CAMERA.origin_image - CAMERA.eye, direction(CAMERA.axis_sight).get) =~
      DISTANCE_IMAGE
    check depth(CAMERA, toMultivector(CAMERA.eye)).get =~ -DISTANCE_IMAGE


  test "image plane holds every point it pierces":
    for point in POINTS:
      let projection = CAMERA.project(point)
      check projection.isSome
      let pierce = (toMultivector(CAMERA.eye) ∧ toMultivector(position(point).get)) ∨
        CAMERA.plane_image
      check toMultivector(position(pierce).get) ∨ CAMERA.plane_image =~ 0


  test "depth measures separation from image plane":
    let forward = direction(CAMERA.axis_sight).get
    for i, point in POINTS:
      let separation = dot(PLACES[i] - CAMERA.origin_image, forward)
      check depth(CAMERA, point).get =~ separation
      check CAMERA.project(point).get.depth =~ separation


  test "projection ignores scale of homogeneous point":
    for point in POINTS:
      for scale in [0.25, 3.0, 11.0]:
        let (plain, scaled) = (CAMERA.project(point), CAMERA.project(scale * point))
        check plain.isSome and scaled.isSome
        check plain.get.position =~ scaled.get.position


  test "target projects to image origin":
    let camera = initCamera(
      eye = Position(x: 4.0, y: -3.0, z: 6.0),
      target = Position(x: -1.0, y: 2.0, z: 0.5),
      up = Direction(x: 0.0, y: 0.0, z: 1.0),
    )
    let projection = camera.project(toMultivector(Position(x: -1.0, y: 2.0, z: 0.5)))
    check projection.isSome
    check projection.get.position =~ PointImage(x: 0.0, y: 0.0)


  test "collinear points stay collinear once projected":
    for i in 0 ..< SAMPLES:
      let
        j = (i + 1) mod SAMPLES
        midpoint = PLACES[i] + 0.5*(PLACES[j] - PLACES[i])
        first = CAMERA.project(POINTS[i]).get.position
        second = CAMERA.project(POINTS[j]).get.position
        middle = CAMERA.project(toMultivector(midpoint)).get.position
        area = (second.x - first.x)*(middle.y - first.y) -
          (second.y - first.y)*(middle.x - first.x)
      check area =~ 0


  test "point at or behind image plane is culled":
    let forward = direction(CAMERA.axis_sight).get
    for offset in [0.0, 0.5, 4.0]:
      let behind = CAMERA.origin_image - offset*forward
      check CAMERA.project(toMultivector(behind)).isNone
    check CAMERA.project(toMultivector(CAMERA.eye)).isNone


  test "point at horizon is culled":
    for place in PLACES:
      let heading = Direction(x: place.x, y: place.y, z: place.z)
      check CAMERA.project(toMultivector(heading)).isNone
      check depth(CAMERA, toMultivector(heading)).isNone



suite "Canvas":
  test "image origin maps to canvas centre":
    let centre = toCanvas(PointImage(x: 0.0, y: 0.0))
    check centre.x =~ 0.5*float(PIXELS_WIDTH)
    check centre.y =~ 0.5*float(PIXELS_HEIGHT)


  test "vertical axis flips between image and canvas":
    let (above, below) = (
      toCanvas(PointImage(x: 0.0, y: 0.5)), toCanvas(PointImage(x: 0.0, y: -0.5))
    )
    check above.y < below.y
    check above.y + below.y =~ float(PIXELS_HEIGHT)


  test "aspect ratio is preserved":
    let
      centre = toCanvas(PointImage(x: 0.0, y: 0.0))
      along_x = toCanvas(PointImage(x: 1.0, y: 0.0))
      along_y = toCanvas(PointImage(x: 0.0, y: 1.0))
    check along_x.x - centre.x =~ centre.y - along_y.y



suite "Scene":
  test "scene counts items in order added":
    var scene = Scene()
    for i in 0 ..< 3:
      scene.addItem(POINTS[i], "point " & $i, Ink.Amber)
    check scene.len == 3
    var count_seen = 0
    for item in scene:
      check item.geometry =~ POINTS[count_seen]
      inc count_seen
    check count_seen == 3


  test "drawn document is well formed and accounts for every item":
    var scene = Scene()
    scene.addItem(POINTS[0], "𝐚", Ink.Amber)
    scene.addItem(LINES[0], "𝐋", Ink.Cyan)
    scene.addItem(PLANES[0], "𝐆", Ink.Lime)
    scene.addItem(⊖ LINES[0], "att(𝐋)", Ink.Rose)

    let path = getTempDir() / "visualiser_suite.svg"
    var canvas = openCanvas(path)
    let tally = drawScene(canvas, CAMERA, scene)
    canvas.closeCanvas

    var count_tallied = 0
    for placement in Placement:
      count_tallied += tally[placement]
    check count_tallied == scene.len
    check tally[Placement.Horizon] == 1

    let document = readFile(path)
    check document.startsWith("<svg ")
    check document.strip.endsWith("</svg>")
    check document.count("<polyline") > 0
    check document.count("<circle") > 0
    removeFile(path)
