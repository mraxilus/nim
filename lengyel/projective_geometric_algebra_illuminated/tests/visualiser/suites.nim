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
  camera, format, help, history, interaction, mesh, objects, picking, scene, selection,
  storyboard,
]
# The arena, the PNG encoder and the GIF encoder are desktop-only: each binds a C entry
#   point the JS backend has none of. Their own suites are guarded to match, below.
when not defined(js):
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
  const
    VERTICES_RIBBON = 6 ## Vertices one ribbon is wound from: two triangles over four
      ## corners. Stated here rather than imported so that a change to how `addSegment`
      ## winds a quad has to be noticed here too.
    HEIGHT_SCALE_TEST = 900 ## Framebuffer height `SCALE_TEST` measures its widths in.

  let SCALE_TEST = block:
    let eye = Position(x: 5, y: -3, z: 7)
    DrawExtent(
      extent_furniture: 30.0,
      eye: eye, radius_horizon: 50.0,
      # Looking back at the origin, which is where every fixture below is built around.
      forward: direction(toMultivector(eye) ∧ toMultivector(ORIGIN)).get,
      tangent_half_view: tan(0.5*degToRad(45.0)),
      height_pixels: HEIGHT_SCALE_TEST,
      depth_near: 0.1,
    )
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


  test "world furniture stays within its own, separately tracked extent":
    MESHES.addAxes(SCALE_TEST.extent_furniture, SCALE_TEST)
    MESHES.addGrid(SCALE_TEST.extent_furniture, SCALE_TEST)
    check MESHES[Primitive.Ribbon].count_vertices > 0
    for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
      let at = MESHES[Primitive.Ribbon].vertices[i].toPosition
      check max(abs(at.x), max(abs(at.y), abs(at.z))) <=
        SCALE_TEST.extent_furniture + TOLERANCE_TEST


  test "ground grid holds full alpha near the origin and fades toward its own reach":
    MESHES.clearMeshes
    MESHES.addGrid(SCALE_TEST.extent_furniture, SCALE_TEST)
    let radius_fade_start = FRACTION_GRID_FADE_START*SCALE_TEST.extent_furniture
    var
      alpha_near_min = 1.0
      alpha_far_max = 0.0
    for i in 0 ..< MESHES[Primitive.Ribbon].count_vertices:
      let
        vertex = MESHES[Primitive.Ribbon].vertices[i]
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


    test "a scene file from before the palette changed is refused, not misread":
      # An item's ink is stored as `Ink`'s own ordinal, and reserving `Invalid` renumbered
      #   that enum -- a version 1 file's bytes name different colours now. Refusing it is
      #   the honest outcome; reading it back in the wrong colours silently is not.
      var scene = initScene()
      discard scene.addItem(POINTS[0], "keep", Ink.Rose)
      let path = getTempDir() / "visualiser_suite_scene_v1.rgascene"
      writeFile(path, "RGAS" & char(1) & char(ord(Basis.high) + 1))
      defer: removeFile(path)

      check loadScene(scene, path).contains("version this build cannot read")
      check scene.len == 1


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
  let SCALE_AIM = DrawExtent(
    extent_furniture: 100.0, eye: ORIGIN, radius_horizon: 90.0,
  ) ## No ribbon fields: nothing here tessellates anything, it only aims a camera.

  test "a finite object is aimed at by target, a horizon one by orbit angle":
    let aim_point = aimFor(POINTS[0], SCALE_AIM)
    check aim_point.isSome
    check not aim_point.get.is_horizon
    check aim_point.get.target =~ anchorFor(POINTS[0], SCALE_AIM).get

    let horizon = attitude(LINES[0]) # A line's attitude is a point at the horizon.
    check isHorizon(horizon)
    let aim_horizon = aimFor(horizon, SCALE_AIM)
    check aim_horizon.isSome
    check aim_horizon.get.is_horizon


  test "an object that draws nothing aims at nothing":
    var empty: Multivector
    check aimFor(empty, SCALE_AIM).isNone


  test "a tween eases toward its goal and lands on it exactly at the duration":
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let goal = CameraAim(is_horizon: false, target: Position(x: 10.0, y: 0.0, z: 0.0))
    tween.aimAt(camera, goal, 0.0, DURATION)

    # Partway: strictly between start and goal, and monotonic toward it.
    var previous = 0.0
    for step in 1 .. 4:
      let now = DURATION*float(step)/5.0
      tween.advance(camera, now, easeOutCubic)
      check camera.target.x > previous
      check camera.target.x < goal.target.x
      previous = camera.target.x

    tween.advance(camera, DURATION, easeOutCubic)
    check camera.target.x =~ goal.target.x
    # Arrived, so nothing left to carry -- but the goal is kept, not dropped, so a
    #   caller still offering it every frame is recognised rather than re-armed.
    check tween.is_arrived
    check tween.goal.isSome


  test "retargeting mid-flight continues from where the camera reached":
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    tween.aimAt(camera, CameraAim(is_horizon: false, target: Position(x: 10.0, y: 0, z: 0)),
                0.0, DURATION)
    tween.advance(camera, DURATION*0.5, easeOutCubic)
    let reached = camera.target.x
    check reached > 0.0 and reached < 10.0

    # A goal that moves must not snap the camera back to where the last ease began.
    tween.aimAt(camera, CameraAim(is_horizon: false, target: Position(x: 20.0, y: 0, z: 0)),
                DURATION*0.5, DURATION)
    check tween.target_from.x =~ reached
    tween.advance(camera, DURATION*0.5 + 0.001, easeOutCubic)
    check camera.target.x >= reached # Continues forward, never jumps backward.


  test "offering the goal it already holds does not restart the ease":
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let goal = CameraAim(is_horizon: false, target: Position(x: 10.0, y: 0, z: 0))
    tween.aimAt(camera, goal, 0.0, DURATION)
    tween.advance(camera, DURATION*0.5, easeOutCubic)
    tween.aimAt(camera, goal, DURATION*0.5, DURATION) # Same goal, offered again.
    check tween.started == 0.0 # Clock untouched, so the ease still ends on time.


  test "a horizon tween turns the short way round the azimuth circle":
    # An angle just past -pi is next door to one just short of +pi, not most of a turn.
    const DURATION = 0.35
    var camera = initCamera(ORIGIN, 12.0, 3.0, 0.0)
    var tween: CameraTween
    tween.aimAt(camera, CameraAim(is_horizon: true, azimuth: -3.0, elevation: 0.0),
                0.0, DURATION)
    tween.advance(camera, DURATION*0.5, easeOutCubic)
    check camera.azimuth > 3.0 # Onward past +pi, not back down through zero.


  test "settle puts the camera on its goal at once":
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let goal = CameraAim(is_horizon: true, azimuth: 1.0, elevation: 0.5)
    tween.aimAt(camera, goal, 0.0, 0.35)
    tween.settle(camera)
    check camera.azimuth =~ 1.0
    check camera.elevation =~ 0.5
    check tween.is_arrived


  test "an arrived tween stops writing, so the user's own camera move survives":
    # The bug this pins: the aim rule offers the selected object's goal every frame.
    #   While the tween cleared its goal on arrival, that standing offer re-armed the
    #   ease each frame from wherever the user had just panned to, and dragged the camera
    #   straight back -- panning was dead for as long as anything stayed selected.
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let goal = CameraAim(is_horizon: false, target: Position(x: 4, y: 1, z: 2))
    tween.aimAt(camera, goal, 0.0, 0.35)
    tween.advance(camera, 0.35, easeOutCubic)
    check tween.is_arrived
    check camera.target =~ goal.target

    # The user pans, and the same goal keeps being offered every frame after.
    camera.pan(3.0, 2.0)
    let target_panned = camera.target
    for frame in 1 .. 10:
      tween.aimAt(camera, goal, 0.35 + 0.016*float(frame), 0.35)
      tween.advance(camera, 0.35 + 0.016*float(frame), easeOutCubic)
    check camera.target =~ target_panned


  test "abandon hands the camera to the user without re-arming the standing offer":
    # `release` here would be actively wrong, and was: it clears the goal, so the aim
    #   rule's own standing offer is seen as new on the very next frame and takes the
    #   camera straight back. Keeping the goal and marking it done is what makes that
    #   offer read as already answered.
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let goal = CameraAim(is_horizon: false, target: Position(x: 4, y: 1, z: 2))
    tween.aimAt(camera, goal, 0.0, 0.35)
    tween.advance(camera, 0.10, easeOutCubic) # Mid-flight, nowhere near arrival.
    check not tween.is_arrived

    camera.pan(3.0, 2.0)
    tween.abandon()
    let target_panned = camera.target
    for frame in 1 .. 40:
      let now = 0.10 + 0.016*float(frame)
      tween.aimAt(camera, goal, now, 0.35)
      tween.advance(camera, now, easeOutCubic)
    check camera.target =~ target_panned


  test "release lets the same goal aim the camera again":
    # Withdrawing the offer is what makes picking the same object twice work: the second
    #   pick must aim afresh, not be recognised as one already delivered.
    var camera = initCamera(ORIGIN, 12.0, 0.0, 0.4)
    var tween: CameraTween
    let goal = CameraAim(is_horizon: false, target: Position(x: 4, y: 1, z: 2))
    tween.aimAt(camera, goal, 0.0, 0.35)
    tween.advance(camera, 0.35, easeOutCubic)
    camera.pan(3.0, 2.0)
    let target_panned = camera.target

    tween.release()
    check tween.goal.isNone
    tween.aimAt(camera, goal, 1.0, 0.35)
    check tween.goal.isSome
    check not tween.is_arrived
    tween.advance(camera, 1.0 + 0.35, easeOutCubic)
    check camera.target =~ goal.target
    check not (camera.target =~ target_panned)



suite "Selection":
  proc ordered(selection: Selection): seq[int] =
    ## Read the whole selection out in pick order, so a test can state the order it
    ## expects in one line rather than indexing position by position.
    for position in 0 ..< selection.len: result.add(selection.at(position))


  test "a pulse covers the same ground however many frames it is cut into":
    # Frame-rate independence, which is the whole reason the phase advances by elapsed
    #   seconds rather than by a step a frame. Driven on the browser too: 3 s of clock
    #   moved the head 178.3 px at 36 fps, 179.0 at 60 and 179.6 at 144, against 180.
    const AROUND = 900.0
    proc phaseAfter(seconds_total: float; frames: int): float =
      var clock: PulseClock
      var seconds = 0.0
      clock.tick(seconds)
      for _ in 0 ..< frames:
        seconds += seconds_total/float(frames)
        let step = clock.secondsStep(seconds)
        clock.tick(seconds)
        clock.advance(0, AROUND, step)
      clock.phaseAt(0)

    # One second at the shared speed is `SPEED_MARKER_PULSE` pixels of a 900-px outline.
    let expected = SPEED_MARKER_PULSE/AROUND
    for frames in [12, 60, 144, 600]:
      check phaseAfter(1.0, frames) =~ expected

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
    check clock.phaseAt(3) > 0.0
    check clock.phaseAt(4) == 0.0 # Untouched, so still at the head of its own lap.
    clock.forget(3)
    check clock.phaseAt(3) == 0.0
    # Out of range is a question with no answer, not a crash.
    check clock.phaseAt(-1) == 0.0
    check clock.phaseAt(ITEMS_MAX) == 0.0


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
    # The drag wedges keep their words: measured on the rendered menu, the projection's
    #   own notation is nearly twice the width of "project", so symbols would widen the one
    #   menu that is read under a thumb.
    check labelOf(DragChoice.Join) == "join"
    check labelOf(DragChoice.Project) == "project"

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
    for path in HelpPath:
      check countOf(path) in 1 .. ENTRIES_MAX_PATH


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
    check "empty space" in outcome.message

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
    let outcome = interaction.endDrag(scene, 10.0 + 0.5*SECONDS_CLICK)
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
    let outcome = interaction.endDrag(scene, 10.0 + 0.5*SECONDS_CLICK)
    check outcome.index_clicked.isNone
    check outcome.index_created == some(2)


  test "a press held past the click window is a drag even if it never moved":
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    scene.addItem(POINTS[1], "b", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 10.0)
    check interaction.beginDrag(arming = MenuArming.OnDwell, now = 10.0)
    interaction.index_hover = some(1)
    let outcome = interaction.endDrag(scene, 10.0 + 2.0*SECONDS_CLICK)
    check outcome.index_clicked.isNone
    check outcome.index_created == some(2)


  test "the button that forces the menu never reports a click instead":
    # It asked for the menu; offering one and then quietly selecting would make the right
    #   button mean two things depending on how fast the reader let go.
    var scene = initScene()
    scene.addItem(POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    interaction.updateCursor(200.0, 200.0)
    interaction.index_hover = some(0)
    interaction.beginPress(now = 10.0)
    check interaction.beginDrag(arming = MenuArming.Always, now = 10.0)
    check interaction.isClick(10.0 + 0.5*SECONDS_CLICK)
    check interaction.endDrag(scene, 10.0 + 0.5*SECONDS_CLICK).index_clicked.isNone


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
    check "empty space" in outcome.message
    check outcome.index_created.isNone


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
    check interaction.proposal == some(DragChoice.Join)
    check interaction.preview.isSome
    # Reaching for a wedge takes the cursor off the item; the destination must survive it.
    interaction.index_hover = none(int)
    let south = anchorOf(interaction.menu.get, DragChoice.Project)
    interaction.updateCursor(south.x, south.y)
    interaction.updateDrag(scene, 0.0)
    check destinationOf(interaction) == some(1)
    let outcome = interaction.endDrag(scene)
    check outcome.choice == some(DragChoice.Project)
    check outcome.index_created == some(2)
    check scene[2].geometry =~ projectOrthogonal(GENERAL_FIRST[0], GENERAL_SECOND[0])


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


  test "an overlay run covers exactly what was added after it was marked":
    # The mechanism a selected object is drawn over everything with. Held here because the
    #   fault it guards against is silent: a mesh nobody marked has to draw *entirely*
    #   depth-tested, and a sentinel index of zero would have said the opposite -- every
    #   line of furniture drawn over the scene, on every frame.
    let scale = DrawExtent(
      extent_furniture: 10.0, radius_horizon: 10.0, tangent_half_view: 0.5,
      height_pixels: 600, depth_near: 0.1, forward: Direction(x: 0, y: 0, z: -1),
    )
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


  test "every key does something in both shift states":
    # The table has to be total: each render path translates its own naming and then trusts
    #   this, so a key with no answer would be a case nobody handled.
    for key in Key:
      for is_shifted in [false, true]:
        discard actionFor(key, is_shifted) # A missing branch is a compile error in Nim;
          # this walks the table so a *runtime* gap could not hide either.
    # Shift is what separates orbiting from panning, and only for the arrows.
    check actionFor(Key.Left, false) == KeyAction.OrbitLeft
    check actionFor(Key.Left, true) == KeyAction.PanLeft
    check actionFor(Key.BracketRight, false) == actionFor(Key.BracketRight, true)


  test "each camera key moves the camera by its own shared step":
    var scene = initScene()
    scene.addItem(GENERAL_POINTS[0], "a", Ink.Rose)
    var interaction = Interaction(is_enabled: true)
    var camera = initCameraDefault()
    let opening = camera

    discard interaction.applyAction(camera, scene, KeyAction.OrbitRight)
    check camera.azimuth =~ opening.azimuth + TURN_PRESS
    discard interaction.applyAction(camera, scene, KeyAction.OrbitLeft)
    check camera.azimuth =~ opening.azimuth # A press each way returns exactly where it was.

    discard interaction.applyAction(camera, scene, KeyAction.OrbitUp)
    check camera.elevation =~ opening.elevation + RISE_PRESS
    discard interaction.applyAction(camera, scene, KeyAction.OrbitDown)
    check camera.elevation =~ opening.elevation

    discard interaction.applyAction(camera, scene, KeyAction.DollyOut)
    check camera.distance =~ opening.distance*FACTOR_DOLLY_PRESS
    discard interaction.applyAction(camera, scene, KeyAction.DollyIn)
    check camera.distance =~ opening.distance

    discard interaction.applyAction(camera, scene, KeyAction.PanRight)
    check not (camera.target.x =~ opening.target.x) or
      not (camera.target.y =~ opening.target.y)
    discard interaction.applyAction(camera, scene, KeyAction.FrameAll)
    check camera.target.x =~ opening.target.x
    check camera.target.y =~ opening.target.y
    check camera.distance =~ opening.distance


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
    check interaction.inkOfDrag == Ink.Guide
    # Standing over a pair that makes nothing wears the reserved magenta, and shows no
    #   ghost -- two signals, so the warning is never colour alone.
    interaction.index_hover = some(1)
    interaction.updateDrag(scene, 0.0)
    check interaction.inkOfDrag == Ink.Invalid
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

  proc setUp(distance = 19.0): (Camera, Matrix4, DrawExtent) =
    ## Build a camera looking at the origin, with the transform and extent a frame carries.
    let placement = initCamera(
      target = Position(x: 0, y: 0, z: 0), distance = distance, azimuth = 0.9,
      elevation = 0.4,
    )
    let scale = placement.drawExtentFor(HEIGHT_MARK)
    (placement, placement.initMatrixViewProjection(WIDTH_MARK/HEIGHT_MARK), scale)

  proc markerOf(
    geometry: Multivector; anchor = none(Position); progress = 1.0;
    phase = none(float)
  ): Option[Marker] =
    let (placement, view_projection, scale) = setUp()
    markerFor(
      geometry, anchor, scale, placement, view_projection, WIDTH_MARK, HEIGHT_MARK,
      progress, is_touch = false, phase = phase,
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


  test "a line's rails stand off it perpendicular to the line and to the sight ray":
    let (placement, _, scale) = setUp()
    let
      across = directionAcross(LINE, scale.eye).get
      support = positionAnchor(LINE).get
    # Perpendicular to the line, so the rails stay parallel to it and share its
    #   vanishing points; perpendicular to the sight ray, so they show as sideways
    #   rather than as one in front of the other.
    check dot(across, direction(LINE).get) =~ 0.0
    check dot(across, support - scale.eye) =~ 0.0
    check norm(across) =~ 1.0


  test "a line's rails close on it with distance, as its own perspective does":
    let (placement, view_projection, scale) = setUp()
    let
      support = positionAnchor(LINE).get
      axis = direction(LINE).get
      across = directionAcross(LINE, scale.eye).get
      offset = offsetMarkerRail(support, scale)
    proc gapAt(along: float): float =
      ## Measure the pixel gap between line and rail at a point `along` the line.
      let place = support + along*axis
      let (on_line, beside) = (
        projectToScreen(view_projection, WIDTH_MARK, HEIGHT_MARK, place),
        projectToScreen(view_projection, WIDTH_MARK, HEIGHT_MARK, place + offset*across),
      )
      hypot(beside.x - on_line.x, beside.y - on_line.y)
    # Strictly shrinking with distance is exactly what convergence means, and is the
    #   whole difference from a constant screen offset, which holds the pair open even
    #   where the line has narrowed to nothing.
    var gap_previous = gapAt(0.0)
    for along in [50.0, 200.0, 1000.0, 5000.0]:
      let gap = gapAt(along)
      check gap < gap_previous
      gap_previous = gap
    check gapAt(5000.0) < 0.1*gapAt(0.0)


  test "a line's rails are drawn in the halves the line itself is drawn in":
    let marker = markerOf(LINE).get
    check marker.count_segment == SEGMENTS_MARKER_RAILS


  test "a line's rails clear it by the shared gap where its support stands":
    let (placement, view_projection, scale) = setUp()
    let
      support = positionAnchor(LINE).get
      across = directionAcross(LINE, scale.eye).get
      offset = offsetMarkerRail(support, scale)
      on_screen = projectToScreen(view_projection, WIDTH_MARK, HEIGHT_MARK, support)
    # Measured at the support, where the offset is stated; the same world offset reads
    #   as fewer pixels further off, which is the convergence the rails exist to show.
    #   Held to a quarter pixel rather than exactly: stepping perpendicular to the sight
    #   ray, which is what puts the rails either side on screen, tilts a hair out of the
    #   plane perspective divides by, so the gap lands a fraction under a percent wide.
    #   Sub-pixel, against a geometry worth keeping -- see `directionAcross`.
    const TOLERANCE_PIXEL = 0.25
    for side in [offset, -offset]:
      let beside = projectToScreen(
        view_projection, WIDTH_MARK, HEIGHT_MARK, support + side*across
      )
      let gap = hypot(beside.x - on_screen.x, beside.y - on_screen.y)
      check abs(gap - OFFSET_MARKER_RAIL) < TOLERANCE_PIXEL


  test "an eye standing on the line has no side to flank it from":
    let scale = setUp()[2]
    let through_eye = toMultivector(scale.eye) ∧
      toMultivector(scale.eye + Direction(x: 1.0, y: 0.0, z: 0.0))
    check directionAcross(through_eye, scale.eye).isNone
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
    # Both bands survive: they are circles about the eye, so whatever the camera faces,
    #   each has points in front of it -- unlike a finite line's rails, which can be
    #   clipped away entirely.
    check marker.counts_band[0] > 0
    check marker.counts_band[1] > 0

    # Only what survives the near plane is reported, so every point handed to an overlay
    #   is one it can actually stroke -- the rule `Loop` already follows, twice over.
    for side in 0 .. 1:
      for i in 0 ..< marker.counts_band[side]:
        check marker.points_band[side][i].isInFront


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
    proc pulsed(geometry: Multivector; phase: float): Marker =
      markerOf(geometry, phase = some(phase)).get

    # A plane's circle and a line's rails both carry one; a point has no orientation and
    #   a plane at horizon carries no normal at all, so neither says anything.
    check pulsed(PLANE, 0.3).count_run_pulse > 0
    check pulsed(LINE, 0.3).count_run_pulse > 0
    check pulsed(LINE_HORIZON, 0.3).count_run_pulse > 0
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
      let shaped = markerOf(geometry, phase = some(0.4)).get
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

  test "one step of phase carries the head one step of the outline, on every shape":
    # The marker's half of a constant speed: a phase is a fraction of the outline, so the
    #   same fraction has to buy the same share of every shape. How many seconds that
    #   fraction takes is `selection.PulseClock`'s half, tested there.
    for geometry in [PLANE, LINE, LINE_HORIZON]:
      let shaped = markerOf(geometry, phase = some(0.4)).get
      proc headAt(phase: float): ScreenPosition =
        headOfRun(markerOf(geometry, phase = some(phase)).get, 0)
      const STEP = 0.01
      let crossed = hypot(
        headAt(0.4 + STEP).x - headAt(0.4).x, headAt(0.4 + STEP).y - headAt(0.4).y
      )
      # A chord, so a hair under the arc actually covered.
      check crossed <= STEP*shaped.around + TOLERANCE_SINGLE
      check crossed > 0.98*STEP*shaped.around


  test "a line wears one comet, not one for every piece it is drawn in":
    # A rail is drawn as two halves either side of the line's support, and each used to
    #   pulse on its own -- four comets at four unrelated places on one selected line.
    let shaped = markerOf(LINE, phase = some(0.4)).get
    check shaped.count_segment == 4
    check shaped.count_run_pulse == 2
    # And the pair travels together rather than each rail keeping its own clock, so the
    #   two read as one comet crossing the line rather than as two chasing each other.
    let heads = [headOfRun(shaped, 0), headOfRun(shaped, 1)]
    check hypot(heads[1].x - heads[0].x, heads[1].y - heads[0].y) < LENGTH_MARKER_COMET


  test "a pulse laps rather than stopping":
    proc headAt(phase: float): ScreenPosition =
      headOfRun(markerOf(PLANE, phase = some(phase)).get, 0)

    let start = headAt(0.0)
    var moved = 0
    for step in 1 .. 5:
      if hypot(headAt(float(step)/6.0).x - start.x,
        headAt(float(step)/6.0).y - start.y) > 1.0: inc moved
    check moved == 5
    # A whole lap on is where it began, so the motion is circulation rather than a run
    #   that ends somewhere.
    let lapped = headAt(1.0)
    check hypot(lapped.x - start.x, lapped.y - start.y) < 1.0
    # And the advance itself wraps rather than growing without bound: three laps' worth of
    #   seconds lands exactly where one moment of it did.
    const AROUND = 300.0
    check phaseAdvanced(0.25, AROUND, 3.0*AROUND/SPEED_MARKER_PULSE) =~ 0.25


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
