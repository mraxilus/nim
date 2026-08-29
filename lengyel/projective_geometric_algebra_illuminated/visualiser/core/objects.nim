## The algebra's own vocabulary: what an object is, and the named incidence questions the
## rest of the visualiser asks of it.
##
## Module is specialised to 4D RGA, i.e. 3D Euclidean space:
##   Grade 1 is point, grade 2 is line, grade 3 is plane.
##   Grades 0 and 4 are scalar and antiscalar, carrying no geometry to draw.
##
## **Multivector in, multivector or scalar out.** Nothing here names a Euclidean quantity;
## lifting one in or reading one back out is `boundary.nim`'s job, and it is the only module
## that does both. That is what keeps the algebra separable from the picture drawn out of it
## -- see `euclid.nim`'s own header for which side owns what.
##
## Every sign and argument order below is pinned by its own suite case against the classical
## closed form, which is the project's purpose: the classical form lives in the test, the
## algebra lives here.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/options

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



#[ Shape Classification ]#



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


func centroidFolded*(centroid: Multivector; place: Multivector): Multivector =
  ## Fold one more unit-weight point into a running centroid.
  ##   **A sum of unit-weight points is their centroid.** Adding points adds their weights,
  ##   so the sum of `n` unit points carries weight `n` and the total of their coordinates,
  ##   and reading it back through `boundary.position` -- which divides by the signed
  ##   weight -- yields the mean. There is no averaging written anywhere: the division is
  ##   the algebra's own.
  ##   The running sum is carried as a multivector rather than read back to a place and
  ##   lifted again on each fold, so the weight it has accumulated *is* how many points it
  ##   is the middle of, and nothing has to be told the count. A caller starts from the
  ##   first point itself and folds the rest in, allocating nothing -- the same shape
  ##   `camera.widened` takes, and for the same reason.
  add(centroid, place)


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
  ##   The two axes are written as the algebra's own weightless points, `e2` then `e1`,
  ##   rather than lifted from Euclidean directions: a basis element is what a world axis
  ##   *is* here, and stating it directly keeps this module clear of the other language.
  unitize(point ∧ 1.0.e2 ∧ 1.0.e1)


func groundPlane*(): Multivector =
  ## Build the ground, `z = 0`, oriented up-positive.
  ##   `levelPlaneThrough` at the origin -- one construction, two heights, so the two
  ##   spellings cannot drift apart. Stated here rather than re-joined at each site that
  ##   needs it: the picker's ground hit, the grid's own height.
  ##   The origin is the unit-weight point with no bulk at all, `e4`.
  levelPlaneThrough(1.0.e4)
