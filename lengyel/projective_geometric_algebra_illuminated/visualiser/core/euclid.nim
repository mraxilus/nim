## Euclidean quantities, and the arithmetic the picture is built out of.
##
## **This module is the far side of the algebra boundary.** Nothing here knows what a
## multivector is, and nothing above it may teach it: `mesh`, which turns geometry into GPU
## primitives, imports this and only this, so a `Multivector` is not a type it can name. The
## crossing between the two languages happens in exactly one place, `boundary.nim`, and the
## geometry that crosses is placed in `objects.nim` and `tessellate.nim`.
##
## The split exists because the two sides answer different questions. *Where an object
## stands* is the algebra's -- a scene object, the world-space camera, a ray cast from the
## screen, a lattice line, an axis, anything at the horizon. *How that geometry becomes
## triangles* is not: a plane's disc and a line's ribbon are stand-ins drawn for the eye,
## carry no geometric meaning of their own, and are built with whatever arithmetic is
## quickest.
##
## `Position` and `Direction` stay separate types because they do not mix:
##   Difference of two positions is direction; position offset by direction is position.
##   A grade-1 multivector's weight coefficient decides which of the two it holds, so
##   confusing them silently drops a perspective divide -- the type makes that uncompilable.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options]

# The **one** thing taken from the algebra's own directory, and deliberately: `algebra.nim`
#   is the metric and grade constants and names no multivector at all (asserted by the
#   layout tool), so this import cannot bring one in. Sharing the tolerance beats declaring
#   a second one that could drift from it.
import ../../pga/algebra



#[ Type Definitions ]#

type
  Position* = object ## Hold Euclidean position, in world units.
    x*, y*, z*: float

  Direction* = object ## Hold Euclidean direction, in world units.
    x*, y*, z*: float

  FramePlane* = object ## Hold orthonormal pair of directions spanning plane.
    axis_first*, axis_second*: Direction
    normal*: Direction ## Unit direction perpendicular to plane; same as `directionNormal(m)`.


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


func cross*(d, e: Direction): Direction =
  ## Get the direction perpendicular to both, right-handed.
  ##   **The picture's own across-vector**, for the ribbon a line is drawn as. Which way a
  ##   line runs is the algebra's answer; how wide the quad standing for it is drawn is
  ##   not, so this is the arithmetic that ribbon is built with. `mesh.directionAcross` is
  ##   its one caller, and the suite holds it equal to the join it replaced --
  ##   `directionNormal(tail ∧ head ∧ eye)` -- sign included, so the two cannot drift.
  Direction(
    x: d.y*e.z - d.z*e.y,
    y: d.z*e.x - d.x*e.z,
    z: d.x*e.y - d.y*e.x,
  )


func norm*(d: Direction): float = sqrt(dot(d, d))
  ## Get magnitude of direction.


func normalize*(d: Direction): Option[Direction] =
  ## Scale direction to unit magnitude.
  ##   None where direction has no magnitude, as it names no direction at all.
  let magnitude = d.norm
  if magnitude <= TOLERANCE_ABS: return
  some(Direction(x: d.x/magnitude, y: d.y/magnitude, z: d.z/magnitude))


type RingAngle* = tuple[cos_angle, sin_angle: float]
  ## One entry of a fixed ring of angles: the cosine and sine a caller weights its two
  ## arms by, for `onCircleAt` below.


proc unitRing*[N: static int](segments: int): array[N, RingAngle] =
  ## Resolve `N` entries of the ring stepped `segments` ways round a circle, entry `i` at
  ## angle `2*PI*i/segments`.
  ##   **One generator for every fixed ring this project walks**: the plane rim and a
  ## horizon line's great circle (`mesh.UNIT_CIRCLE_RIM`, which takes one entry past the
  ## wrap so its closing segment lands on the value `cos(2*PI)` actually takes), a
  ## plane's marker loop, and a horizon line's marker bands. Each of those assembled its
  ## own angles as multivector sums per sample per frame until it was measured; a third
  ## hand-rolled table would have been a third chance to disagree about what "the ring"
  ## means.
  ##   Called at start-up rather than evaluated at compile time: the compile-time `cos`
  ## need not agree with each backend's own in the last bit, and the suites hold these
  ## points equal to the multivector sums they replaced.
  for i in 0 ..< N:
    let angle = (2.0*PI*float(i))/float(segments)
    result[i] = (cos_angle: cos(angle), sin_angle: sin(angle))


func onCircleAt*(
  centre: Position; arm_first, arm_second: Direction; cos_angle, sin_angle: float
): Position =
  ## Step round a circle whose trigonometry the caller already holds: the centre, plus
  ## the two radius-long arms weighted by the given cosine and sine.
  ##   The trig-free core of `onCircle` below, split out for the callers that walk a
  ##   fixed ring of angles -- a rim table, a shader's static corner buffer -- and so pay
  ##   for each angle's trigonometry once rather than once per frame.
  Position(
    x: centre.x + cos_angle*arm_first.x + sin_angle*arm_second.x,
    y: centre.y + cos_angle*arm_first.y + sin_angle*arm_second.y,
    z: centre.z + cos_angle*arm_first.z + sin_angle*arm_second.z,
  )


func onCircle*(centre: Position; arm_first, arm_second: Direction; angle: float): Position =
  ## Step round a circle: the centre, plus the two radius-long arms weighted by the angle.
  ##   **The picture's own circle.** A disc is not a geometric object -- it is the stand-in
  ##   drawn for a plane, which is infinite -- so its rim and its fan are stepped here
  ##   rather than assembled as multivector sums. The arms are handed down already scaled;
  ##   which plane they span is `boundary.frame`'s answer, taken through the algebra.
  ##   Held equal to that multivector sum, point for point, by the suite.
  onCircleAt(centre, arm_first, arm_second, cos(angle), sin(angle))
