## The crossing between the algebra and the picture -- the one place both languages are
## spoken.
##
## Everything that lifts a Euclidean quantity into a multivector, or reads one back out of
## it, is here and nowhere else. A reader asking "where does this project leave the
## algebra" has exactly one file to open, and a reader adding a conversion has exactly one
## place to put it.
##
## Quantities are read through the library's own operators rather than out of the
## coefficient table, so the renderer exercises the algebra it exists to show:
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
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/options

import ../../pga
import ./[euclid, objects]

# Re-exported deliberately: a module reaching for the crossing needs both languages by
#   definition, and making it name all three imports would say nothing extra. What the
#   boundary protects is the other direction -- `mesh` imports `euclid` alone and so cannot
#   name a `Multivector` at all.
export euclid, objects

#[ Multivector Conversion ]#

func toMultivector*(p: Position): Multivector =
  ## Convert Euclidean position to unit-weight grade-1 point.
  p.x.e1 + p.y.e2 + p.z.e3 + 1.0.e4


func toMultivector*(d: Direction): Multivector =
  ## Convert Euclidean direction to grade-1 point at horizon.
  ##   Weight is 0, so point stands for direction rather than place.
  d.x.e1 + d.y.e2 + d.z.e3
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

func pointFrom*(m: Multivector): Position =
  ## Read a point assembled through the algebra back out as a place.
  ##   Every caller builds `m` as a unit-weight point plus weightless directions, so the
  ##   weight is exactly one and the read cannot refuse; asserted rather than silently
  ##   defaulted, because a zero weight here means the assembly upstream is wrong.
  let read = position(m)
  doAssert read.isSome, "An assembled point must carry weight; its assembly is wrong."
  read.get
