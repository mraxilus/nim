## Read drawable quantities out of RGA multivectors.
##
## Module is specialised to 4D RGA, i.e. 3D Euclidean space:
##   Grade 1 is point, grade 2 is line, grade 3 is plane.
##   Grades 0 and 4 are scalar and antiscalar, carrying no geometry to draw.
##
## Quantities are read through library's own operators rather than out of coefficient table,
## so renderer exercises algebra it exists to show:
##
##   |-----------------|--------------|----------------------------------------------|
##   | Identifier      | Lengyel      | Meaning                                      |
##   |-----------------|--------------|----------------------------------------------|
##   | position        | 𝐩 ÷ pʷ       | Euclidean position of point.                 |
##   | positionSupport | sup(𝐦) = 𝐦∩  | Point of object nearest origin.              |
##   | positionAnchor  | derived      | Point to build drawing of object around.     |
##   | direction       | att(𝐦) = ⊖𝐦  | Unit direction line extends along.           |
##   | directionNormal | -𝐦☆          | Unit direction perpendicular to plane.       |
##   | directionHorizon| 𝐩 at pʷ = 0  | Unit direction point at horizon stands for.  |
##   | frame           | derived      | Orthonormal pair of directions inside plane. |
##   |-----------------|--------------|----------------------------------------------|
##
## `Position` and `Direction` are separate types because they do not mix:
##   Difference of two positions is direction; position offset by direction is position.
##   Weight coefficient pʷ decides which of two a grade-1 multivector holds.
##   Confusing them silently drops perspective divide, so type makes that uncompilable.

{.experimental: "strictFuncs".}

import std/[math, options]

import ../pga

# Fail early rather than emit meaningless picture from algebra of wrong dimension.
static:
  doAssert DIMENSIONS == 4 and IS_RIGID,
    "Visualiser draws 3D Euclidean space, so it needs 4D rigid PGA; compile with " &
    "`--define:pga.dimensions=4 --define:pga.is_conformal=false`."



#[ Type Definitions ]#

type
  Shape* {.pure.} = enum ## Name geometry k-vector stands for in 4D RGA.
    Point, ## Grade 1.
    Line, ## Grade 2.
    Plane, ## Grade 3.

  Position* = object ## Hold Euclidean position, in world units.
    x*, y*, z*: float

  Direction* = object ## Hold Euclidean direction, in world units.
    x*, y*, z*: float

  FramePlane* = object ## Hold orthonormal pair of directions spanning plane.
    axis_first*, axis_second*: Direction

  Placement* {.pure.} = enum ## Report what became of object once drawn.
    Finite, ## Object had finite extent and was drawn where it stands.
    Horizon, ## Object lay wholly at horizon; only its direction could be drawn.
    Empty, ## Multivector carried no drawable geometry at all.


# Forbid exact comparison, as every coordinate below is an accumulated float.
func `==`*(p, q: Position): bool {.error:
  "Use approximate comparison, `=~`, or compare coordinates directly."
.}


func `==`*(d, e: Direction): bool {.error:
  "Use approximate comparison, `=~`, or compare coordinates directly."
.}



#[ Euclidean Arithmetic ]#

func `+`*(p: Position, d: Direction): Position =
  ## Offset position by direction.
  Position(x: p.x + d.x, y: p.y + d.y, z: p.z + d.z)


func `-`*(p: Position, d: Direction): Position =
  ## Offset position against direction.
  Position(x: p.x - d.x, y: p.y - d.y, z: p.z - d.z)


func `-`*(p, q: Position): Direction =
  ## Subtract positions to obtain direction separating them.
  Direction(x: p.x - q.x, y: p.y - q.y, z: p.z - q.z)


func `-`*(d: Direction): Direction =
  ## Reverse direction.
  Direction(x: -d.x, y: -d.y, z: -d.z)


func `+`*(d, e: Direction): Direction =
  ## Add directions, e.g. to compose a ray from steps along independent axes.
  Direction(x: d.x + e.x, y: d.y + e.y, z: d.z + e.z)


func `*`*(scale: float, d: Direction): Direction =
  ## Scale direction.
  Direction(x: scale * d.x, y: scale * d.y, z: scale * d.z)


func dot*(d, e: Direction): float = d.x*e.x + d.y*e.y + d.z*e.z
  ## Get inner product of directions.
  ##   Plain arithmetic rather than 𝐝 ∙ 𝐞, as resolving vector against axis does no
  ##   geometric work that algebra would illuminate; RGA is kept for joins and meets.


func norm*(d: Direction): float = sqrt(dot(d, d))
  ## Get magnitude of direction.


func normalize*(d: Direction): Option[Direction] =
  ## Scale direction to unit magnitude.
  ##   None where direction has no magnitude, as it names no direction at all.
  let magnitude = d.norm
  if magnitude <= TOLERANCE_ABS: return
  some(Direction(x: d.x/magnitude, y: d.y/magnitude, z: d.z/magnitude))



#[ Multivector Conversion ]#

func toMultivector*(p: Position): Multivector =
  ## Convert Euclidean position to unit-weight grade-1 point.
  p.x.e1 + p.y.e2 + p.z.e3 + 1.0.e4


func toMultivector*(d: Direction): Multivector =
  ## Convert Euclidean direction to grade-1 point at horizon.
  ##   Weight is 0, so point stands for direction rather than place.
  d.x.e1 + d.y.e2 + d.z.e3


func shape*(m: Multivector): Option[Shape] =
  ## Name geometry multivector stands for.
  ##   None for mixed grade, and for scalar and antiscalar, which draw nothing.
  let grade = m.grade
  if grade.isNone: return
  case int(grade.get)
  of 1: some(Shape.Point)
  of 2: some(Shape.Line)
  of 3: some(Shape.Plane)
  else: none[Shape]()


func isHorizon*(m: Multivector): bool = abs(( |∘ m)[Basis.scalarAnti]) <= TOLERANCE_ABS
  ## Report whether object lies wholly at horizon, i.e. whether its weight vanishes.



#[ Object Interrogation ]#

func position*(m: Multivector): Option[Position] =
  ## Read Euclidean position of point.
  ##   None where point lies at horizon, as direction has no place.
  ##   Divides by signed weight rather than weight norm, so antipodal points stay distinct.
  let weight = m[Basis.E4]
  if abs(weight) <= TOLERANCE_ABS: return
  some(Position(x: m[Basis.E1]/weight, y: m[Basis.E2]/weight, z: m[Basis.E3]/weight))


func positionSupport*(m: Multivector): Option[Position] =
  ## Read point of object nearest origin, i.e. orthogonal projection of origin onto object.
  ##   None where object passes through origin, as support then vanishes.
  position(∩ m)


func positionAnchor*(m: Multivector): Option[Position] =
  ## Choose point of object to build its drawing around.
  ##   Support point where object misses origin, origin itself where it does not.
  ##   None where object lies at horizon, as it then has no finite point at all.
  let support = positionSupport(m)
  if support.isSome: return support
  if m.isHorizon: return
  some(Position(x: 0, y: 0, z: 0))


func direction*(m: Multivector): Option[Direction] =
  ## Read unit direction line extends along.
  ##   None where line lies at horizon, as its attitude then vanishes.
  let attitude = ⊖ m
  normalize(Direction(x: attitude[Basis.E1], y: attitude[Basis.E2], z: attitude[Basis.E3]))


func directionHorizon*(m: Multivector): Option[Direction] =
  ## Read unit direction point at horizon stands for.
  ##   None where point has weight, as it then names place rather than direction.
  if not m.isHorizon: return
  normalize(Direction(x: m[Basis.E1], y: m[Basis.E2], z: m[Basis.E3]))


func directionNormal*(m: Multivector): Option[Direction] =
  ## Read unit direction perpendicular to plane.
  ##   Antidual is negated so normal runs along plane's own weight gˣ, gʸ, gᶻ.
  ##   None where plane lies at horizon, as horizon has no normal in Euclidean space.
  let normal = -☆(m)
  normalize(Direction(x: normal[Basis.E1], y: normal[Basis.E2], z: normal[Basis.E3]))



#[ Plane Frame ]#

func frame*(m: Multivector): Option[FramePlane] =
  ## Derive orthonormal pair of directions lying inside plane.
  ##   Pair is arbitrary up to rotation about normal; only plane it spans is meaningful.
  ##   None where plane lies at horizon, as it then spans no Euclidean directions.
  let
    normal = directionNormal(m)
    anchor = positionAnchor(m)
  if normal.isNone or anchor.isNone: return

  # Pick world axis least aligned with normal, so joins below stay well conditioned.
  const AXES_WORLD = [
    Direction(x: 1, y: 0, z: 0),
    Direction(x: 0, y: 1, z: 0),
    Direction(x: 0, y: 0, z: 1),
  ]
  let alignments = [abs(normal.get.x), abs(normal.get.y), abs(normal.get.z)]
  var index_least = 0
  for i in 1 .. 2:
    if alignments[i] < alignments[index_least]: index_least = i
  let axis_world = AXES_WORLD[index_least]

  # Span plane through anchor holding both helper axis and normal.
  #   Its own normal is perpendicular to both, so it lies inside `m`.
  let
    point_anchor = toMultivector(anchor.get)
    point_normal = toMultivector(normal.get)
    plane_first = point_anchor ∧ toMultivector(axis_world) ∧ point_normal
    axis_first = directionNormal(plane_first)
  if axis_first.isNone: return

  # Repeat against first axis, to obtain second axis perpendicular to it inside `m`.
  let
    plane_second = point_anchor ∧ toMultivector(axis_first.get) ∧ point_normal
    axis_second = directionNormal(plane_second)
  if axis_second.isNone: return

  some(FramePlane(axis_first: axis_first.get, axis_second: axis_second.get))
