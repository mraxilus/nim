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
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options]

import ../../pga

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
    normal*: Direction ## Unit direction perpendicular to plane; same as `directionNormal(m)`.

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
  ##   **Boundary vocabulary only.** World-space alignment questions go through the
  ##   algebra -- `depthAgainst`, `distanceBetween`, `projectOrthogonal`, the library's
  ##   own inner product -- and this exists for the one place standard math is licensed:
  ##   where the GPU needs to draw. Its callers are the view matrix, `worldPerPixelAt`,
  ##   and `addSegment`'s ribbon packing; nothing that derives scene geometry may use it.


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


func isHorizonPlane*(m: Multivector): bool = shape(m) == some(Shape.Plane) and isHorizon(m)
  ## Report whether object is specifically a plane at horizon -- the one shape that
  ## draws as a sky dome (`mesh.addDome`) rather than ordinary finite geometry, so a
  ## caller assembling a frame's own meshes can single it out and insert its dome
  ## before anything else shares its own translucent (`Primitive.Triangle`) bucket --
  ## see `visualiser.assembleMeshes`'s own doc comment for why draw order matters here.



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


func directionNormalHorizon*(m: Multivector): Option[Direction] =
  ## Read unit direction normal to the pencil of directions a horizon line stands for.
  ##   A line's own weight lives in its `E41`/`E42`/`E43` terms; `E23`/`E31`/`E12` survive
  ##   at horizon and carry the very same normal a finite plane's own attitude would leave
  ##   there, unnormalized -- confirmed directly by comparing a plane's `directionNormal`
  ##   against `(⊖ that plane)[E23], [E31], [E12]`, which agree component for component.
  ##   None where line has weight, as it then runs along a direction, not perpendicular
  ##   to a pencil of them.
  if not m.isHorizon: return
  normalize(Direction(x: m[Basis.E23], y: m[Basis.E31], z: m[Basis.E12]))


func directionNormal*(m: Multivector): Option[Direction] =
  ## Read unit direction perpendicular to plane.
  ##   Antidual is negated so normal runs along plane's own weight gˣ, gʸ, gᶻ.
  ##   None where plane lies at horizon, as horizon has no normal in Euclidean space.
  let normal = -☆(m)
  normalize(Direction(x: normal[Basis.E1], y: normal[Basis.E2], z: normal[Basis.E3]))



#[ Plane Frame ]#

func spanPerpendicular*(anchor: Position; normal: Direction): Option[(Direction, Direction)] =
  ## Derive orthonormal pair of directions perpendicular to `normal`, through `anchor`.
  ##   Built the same way `frame` spans a plane's own two axes, so a caller holding a
  ##   normal read some other way -- not necessarily `directionNormal` of a multivector
  ##   `frame` could take directly -- still spans it algebraically, through joins and
  ##   antiduals, rather than by a raw cross product outside the library's own operators.
  ##   Pair is arbitrary up to rotation about `normal`; only the plane it spans is
  ##   meaningful. `anchor` only fixes where the spanning joins are built through --
  ##   the two directions found do not depend on which point is chosen.
  ##   None only where library's own antiduals fail to resolve, which does not happen
  ##   for any unit `normal`.

  # Pick world axis least aligned with normal, so joins below stay well conditioned.
  const AXES_WORLD = [
    Direction(x: 1, y: 0, z: 0),
    Direction(x: 0, y: 1, z: 0),
    Direction(x: 0, y: 0, z: 1),
  ]
  let alignments = [abs(normal.x), abs(normal.y), abs(normal.z)]
  var index_least = 0
  for i in 1 .. 2:
    if alignments[i] < alignments[index_least]: index_least = i
  let axis_world = AXES_WORLD[index_least]

  # Span plane through anchor holding both helper axis and normal.
  #   Its own normal is perpendicular to both, so it lies inside the plane `normal` spans.
  let
    point_anchor = toMultivector(anchor)
    point_normal = toMultivector(normal)
    plane_first = point_anchor ∧ toMultivector(axis_world) ∧ point_normal
    axis_first = directionNormal(plane_first)
  if axis_first.isNone: return

  # Repeat against first axis, to obtain second axis perpendicular to it inside the plane.
  let
    plane_second = point_anchor ∧ toMultivector(axis_first.get) ∧ point_normal
    axis_second = directionNormal(plane_second)
  if axis_second.isNone: return

  some((axis_first.get, axis_second.get))


func frame*(m: Multivector): Option[FramePlane] =
  ## Derive orthonormal pair of directions lying inside plane.
  ##   Pair is arbitrary up to rotation about normal; only plane it spans is meaningful.
  ##   None where plane lies at horizon, as it then spans no Euclidean directions.
  let
    normal = directionNormal(m)
    anchor = positionAnchor(m)
  if normal.isNone or anchor.isNone: return
  let axes = spanPerpendicular(anchor.get, normal.get)
  if axes.isNone: return
  let (axis_first, axis_second) = axes.get
  some(FramePlane(axis_first: axis_first, axis_second: axis_second, normal: normal.get))



#[ Incidence Vocabulary ]#

# The named incidence questions the rest of the visualiser asks, each stated once through
#   the library's own operators. Everything here returns either a multivector for further
#   algebra or a scalar read out at the end -- the same shape `isHorizon` above set. Every
#   sign and argument order below is pinned by its own suite case against the classical
#   closed form, which is the project's purpose: the classical form lives in the test, the
#   algebra lives here.

func planeThrough*(point, direction: Multivector): Multivector =
  ## Build the plane through `point` perpendicular to the line through it along
  ## `direction`, unitized so `depthAgainst` reads metric distance straight off it.
  ##   The weight expansion of the point onto its own line: `p ∧ (p ∧ d)☆` is the plane
  ##   containing `p` whose normal is the line's direction -- the library's own
  ##   `expandWeight`, the same operator the apply catalogue exposes as `𝐦 ∧ 𝐧☆`.
  unitize(expandWeight(point, wedge(point, direction)))


func depthAgainst*(plane, point: Multivector): float =
  ## Measure the signed distance of a unit-weight point from a unitized plane: positive on
  ## the side the plane's construction direction points toward, zero on it.
  ##   The meet of a plane and a point is the volume they span, whose one coefficient is
  ##   the point's height over the plane -- antigrades 1 and 3 close to 4, which is the
  ##   *scalar* slot, not `scalarAnti`. **This argument order**: `plane ∨ point`; the other
  ##   order negates, and the suite pins a point one unit along a plane's own direction at
  ##   exactly +1.
  wedgeAnti(plane, point)[Basis.scalar]


func distanceBetween*(p, q: Multivector): float =
  ## Measure the distance between two unit-weight points.
  ##   The weight norm of their joining line: for unitized points the join's moment is
  ##   carried in its bulk and its direction in its weight, and the weight's length is the
  ##   separation itself -- `‖p ∧ q‖∘`, read from the norm's own `scalarAnti` slot.
  normWeight(wedge(p, q))[Basis.scalarAnti]


func levelPlaneThrough*(point: Multivector): Multivector =
  ## Build the horizontal plane through `point` -- the level a reader works at when their
  ## camera targets that point -- oriented so `depthAgainst` reads **up as positive**.
  ##   Joined y-then-x rather than x-then-y, because the blade the joins produce points
  ##   down the other way round: probed, the x∧y join reads a point one unit above at
  ##   -1 and the y∧x join at +1, and height is what every caller means. Unitized for
  ##   `depthAgainst`'s contract, though a join of unit axes is already unit weight.
  unitize(
    point ∧
      toMultivector(Direction(x: 0, y: 1, z: 0)) ∧
      toMultivector(Direction(x: 1, y: 0, z: 0))
  )


func groundPlane*(): Multivector =
  ## Build the ground, `z = 0`, oriented up-positive.
  ##   `levelPlaneThrough` at the origin -- one construction, two heights, so the two
  ##   spellings cannot drift apart. Stated here rather than re-joined at each site that
  ##   needs it: the picker's ground hit, the grid's own height.
  levelPlaneThrough(toMultivector(Position(x: 0, y: 0, z: 0)))
