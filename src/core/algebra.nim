## Read geometry out of the vendored algebra, and build the multivectors the workbench needs.
##
## Every geometric question the tool asks is answered here through the algebra's own
## operators: a shape from a grade, a position from unitization, a midpoint from a sum of
## unit-weight points. Nothing in the application does coordinate arithmetic of its own; the
## only place coordinates appear is where a value crosses into the renderer, and that value is
## read back through `position`.

{.experimental: "strictFuncs".}

import std/[math, options, unicode]

import ../../vendor/pga/pga
import ./config

export pga, config



#[ Type Definitions ]#

type
  Shape* {.pure.} = enum
    ## Name what a multivector draws as, read from its grade.
    None,   ## Mixed grade, scalar or antiscalar: nothing to draw.
    Point,  ## Grade 1.
    Line,   ## Grade 2.
    Plane,  ## Grade 3.

  Position* = object
    ## Carry a point of the rendered world, the one place algebra becomes coordinates.
    x*, y*, z*: float

  Locus* {.pure.} = enum
    ## Distinguish an object with a position from one that only has a direction.
    Finite,  ## Weight is non-zero: the object sits somewhere.
    Horizon, ## Weight vanishes: only a direction remains.



#[ Approximate Comparison ]#

const POSITION_TOLERANCE* = 1.0e-9
  ## Compare positions to this absolute tolerance unless a caller names another.


func `=~`*(a, b: Position, tolerance: float = POSITION_TOLERANCE): bool =
  ## Compare positions approximately, to a configurable tolerance.
  abs(a.x - b.x) <= tolerance and abs(a.y - b.y) <= tolerance and
    abs(a.z - b.z) <= tolerance


func `==`*(a, b: Position): bool {.error:
  "Exact float equality is meaningless here; compare with `=~`, which takes a tolerance."
.}


#[ Multivector Construction ]#

func element*(b: Basis, coefficient: float = 1.0): Multivector {.inline.} =
  ## Build multivector of one basis element.
  initElement(b, coefficient)


func coefficient*(m: Multivector, b: Basis): float {.inline.} = m[b]
  ## Read coefficient of one basis element.
  ##   Kept by value: the library's `var`-returning accessor miscompiles on the JS backend
  ##   when its result is consumed as a value, so the browser reads through here.


func withCoefficient*(m: Multivector, b: Basis, value: float): Multivector =
  ## Build copy of multivector with one basis coefficient replaced.
  ##   Built by subtraction and addition rather than by mutating a copy, for the same
  ##   JS-backend reason `coefficient` exists.
  m - element(b, m[b]) + element(b, value)


func pointAt*(x, y, z: float): Multivector =
  ## Build unit-weight point at world position.
  element(E1, x) + element(E2, y) + element(E3, z) + element(E4, 1.0)


func pointAt*(p: Position): Multivector {.inline.} = pointAt(p.x, p.y, p.z)
  ## Build unit-weight point at world position.


func directionAt*(x, y, z: float): Multivector =
  ## Build horizon point, i.e. a direction, with no weight.
  element(E1, x) + element(E2, y) + element(E3, z)


func directionAt*(p: Position): Multivector {.inline.} = directionAt(p.x, p.y, p.z)
  ## Build horizon point, i.e. a direction, with no weight.



#[ Multivector Queries ]#

func shape*(m: Multivector): Shape =
  ## Name what a multivector draws as.
  ##   Grades 0 and 4 carry no extent to draw, and a mixed-grade multivector has no shape at
  ##   all; both are legitimate outcomes reported as `None`, not errors.
  let g = m.grade
  if g.isNone: return Shape.None
  case int(g.get)
  of 1: Shape.Point
  of 2: Shape.Line
  of 3: Shape.Plane
  else: Shape.None


func locus*(m: Multivector): Locus =
  ## Report whether a multivector has a position or only a direction.
  if abs(( |∘ m)[Basis.scalarAnti]) <= TOLERANCE_ABS: Locus.Horizon else: Locus.Finite


func isZero*(m: Multivector): bool =
  ## Report whether every coefficient is within tolerance of zero.
  for b in Basis:
    if abs(m[b]) > TOLERANCE_ABS: return false
  true


func unitPoint*(m: Multivector): Option[Multivector] =
  ## Scale a point so its weight is exactly one, sign and all.
  ##   The library's unitization divides by the weight *norm*, which is a magnitude, so a
  ##   point built with negative weight stays negative and reads as its own reflection
  ##   through the origin. Dividing by the signed weight is the projection into Euclidean
  ##   space, and it is what keeps a sum of unit-weight points a midpoint rather than a
  ##   direction.
  if m.shape != Shape.Point: return
  let weight = m[Basis.origin]
  if abs(weight) <= TOLERANCE_ABS: return
  some((1.0/weight)*m)


func position*(m: Multivector): Option[Position] =
  ## Project multivector to the world position of its unit-weight form.
  ##   Defined for a finite point only: a line or plane is asked for its support first.
  if m.locus != Locus.Finite: return
  let unit = m.unitPoint
  if unit.isNone: return
  some(Position(x: unit.get[E1], y: unit.get[E2], z: unit.get[E3]))


func direction*(m: Multivector): Option[Position] =
  ## Read the heading of a horizon point, normalized through the algebra's bulk norm.
  if m.shape != Shape.Point or m.locus != Locus.Horizon: return
  if abs(( |∙ m)[Basis.scalar]) <= TOLERANCE_ABS: return
  let unit = ^∙ m
  some(Position(x: unit[E1], y: unit[E2], z: unit[E3]))


func normal*(m: Multivector): Option[Position] =
  ## Read the normal of a plane, or the axis a horizon line circles.
  ##   A horizon line has no direction left, only the moment that names the plane of
  ##   directions it spans, which serves as that circle's axis.
  case m.shape
  of Shape.Plane:
    if abs(( |∘ m)[Basis.scalarAnti]) <= TOLERANCE_ABS: return
    let unit = ^m
    some(Position(x: unit[E423], y: unit[E431], z: unit[E412]))
  of Shape.Line:
    if m.locus != Locus.Horizon: return
    if abs(( |∙ m)[Basis.scalar]) <= TOLERANCE_ABS: return
    let unit = ^∙ m
    some(Position(x: unit[E23], y: unit[E31], z: unit[E12]))
  else: none(Position)


func anchor*(m: Multivector): Option[Position] =
  ## Project multivector to the one point that stands for it on screen.
  ##   A point is itself; a line or plane is its support, the point of it closest to origin.
  ##   Horizon objects have no such point and report nothing.
  if m.locus != Locus.Finite: return
  case m.shape
  of Shape.Point: m.position
  of Shape.Line, Shape.Plane: (∩ m).position
  of Shape.None: none(Position)



#[ Derived Geometry ]#

func translate*(point, heading: Multivector, distance: float): Option[Position] =
  ## Offset point along a direction, through the algebra rather than through coordinates.
  ##   Adding a weightless direction to a unit-weight point moves the point; the result is
  ##   read back through the same position projection everything else uses.
  if heading.locus != Locus.Horizon: return
  let unit = point.unitPoint
  if unit.isNone: return
  (unit.get + distance*(^∙ heading)).position


func midpoint*(m, n: Multivector): Option[Position] =
  ## Find the point halfway between two points, as the sum of their unit-weight forms.
  let (first, second) = (m.unitPoint, n.unitPoint)
  if first.isNone or second.isNone: return
  (first.get + second.get).position


func centroid*(m, n, o: Multivector): Option[Position] =
  ## Find the centre of three points, as the sum of their unit-weight forms.
  let (first, second, third) = (m.unitPoint, n.unitPoint, o.unitPoint)
  if first.isNone or second.isNone or third.isNone: return
  (first.get + second.get + third.get).position


func tangents*(plane: Multivector): Option[(Position, Position)] =
  ## Find two perpendicular directions spanning a plane, for drawing its disc.
  ##   Derived entirely through the algebra: an axis direction projected into the plane gives
  ##   the first; the plane met with a plane perpendicular to that first direction gives the
  ##   second. Reading a normal and crossing it with something would be the hand-rolled
  ##   vector arithmetic this project does without.
  if plane.shape != Shape.Plane or plane.locus != Locus.Finite: return
  let support = ∩ plane
  if support.locus != Locus.Finite: return

  # Pick whichever axis direction survives projection into the plane most strongly, so a
  #   plane parallel to one axis is spanned from another.
  var
    first = directionAt(1.0, 0.0, 0.0)
    strength = -1.0
  for axis in [directionAt(1, 0, 0), directionAt(0, 1, 0), directionAt(0, 0, 1)]:
    let
      projected = axis.projectOrthogonal(plane)
      magnitude = ( |∙ projected)[Basis.scalar]
    if magnitude > strength:
      strength = magnitude
      first = projected
  if strength <= TOLERANCE_ABS: return

  # Meet the plane with a plane perpendicular to the first direction, for the second.
  let
    ruler = support ∧ first                        # Line through the support along `first`.
    perpendicular = support.expandWeight(ruler)    # Plane through support, normal to ruler.
    crossing = plane ∨ perpendicular               # Line in the plane, perpendicular to it.
    second = ⊖ crossing                            # That line's direction.
  let
    heading_first = first.direction
    heading_second = second.direction
  if heading_first.isNone or heading_second.isNone: return
  some((heading_first.get, heading_second.get))



#[ Basis Element Naming ]#

func elementName*(b: Basis): string =
  ## Name basis element exactly as the algebra library prints it alone.
  ##   Derived from the element enumeration rather than transcribed, so a build of another
  ##   dimension names its own elements. `tests/suite.nim` asserts each derived name equals
  ##   what the library prints for that element.
  const SUBSCRIPT_ZERO = 0x2080
  if b == Basis.scalar: return "𝟏"
  if b == Basis.scalarAnti: return "𝟙"
  result = "𝐞"
  for digit in ($b)[1 .. ^1]:
    result.add($Rune(SUBSCRIPT_ZERO + ord(digit) - ord('0')))


func shapeWord*(s: Shape): string =
  ## Name shape in the words the object rows read with.
  case s
  of Shape.None: "mixed grade, nothing to draw"
  of Shape.Point: "point"
  of Shape.Line: "line"
  of Shape.Plane: "plane"
