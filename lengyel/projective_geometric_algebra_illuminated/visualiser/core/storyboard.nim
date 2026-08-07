## Script a construction, one operation at a time, for capture without a hand on the mouse.
##
## Storyboard exists so a build can be checked by looking at it: each step goes through the
## same `applyOperation` and `addItem` the GUI's apply button calls, so what a reader sees
## in the exported frames is what clicking would have produced.
##   Doubles as a visual regression harness: the frames are comparable between builds.
##
## Steps name their operands by index into the scene, which is dense and grows by one per
## step, so an index is stable once written.
##   Seeds occupy indices 0 to 4; every later index is the step that produced it.
##
##   |-------|-------------------|--------------------------------------------------|
##   | Index | Object            | Origin                                           |
##   |-------|-------------------|--------------------------------------------------|
##   | 0,1,2 | a, b, c           | Seed points, placed by hand.                     |
##   | 3     | o                 | The world origin, placed by hand -- kept off `G` |
##   |       |                   |   (see step 08's own comment) purely so it has   |
##   |       |                   |   something non-trivial to project onto it.      |
##   | 4     | ground            | Seed plane, joined from three points at z = 0.   |
##   | 5+    | one per step      | Result of the step's own operation.              |
##   |-------|-------------------|--------------------------------------------------|
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import ../../pga
import ./[mesh, objects, scene]



#[ Type Definitions ]#

type Step* = object ## Hold one scripted construction step.
  stem*: string ## File name stem the frame after this step is written under.
  label*: string ## Name the derived object carries in the scene.
  operation*: Operation ## Operation applied to the operands below.
  index_first*: int ## Scene index of left operand.
  index_second*: int ## Scene index of right operand; ignored where operation is unary.
  ink*: Ink ## Palette slot the derived object is drawn with.



#[ Scripted Construction ]#

const STEPS*: array[11, Step] = [
  Step(stem: "01_join_line", label: "L = a ∧ b",
    operation: Operation.Wedge, index_first: 0, index_second: 1, ink: Ink.Jade),
  Step(stem: "02_join_plane", label: "G = L ∧ c",
    operation: Operation.Wedge, index_first: 5, index_second: 2, ink: Ink.Cobalt),
  Step(stem: "03_meet_line", label: "ground v G",
    operation: Operation.WedgeAnti, index_first: 4, index_second: 6, ink: Ink.Copper),
  Step(stem: "04_meet_point", label: "L v ground",
    operation: Operation.WedgeAnti, index_first: 5, index_second: 4, ink: Ink.Rose),
  Step(stem: "05_support", label: "sup(L)",
    operation: Operation.Support, index_first: 5, index_second: 0, ink: Ink.Rose),
  Step(stem: "06_attitude", label: "att(L)",
    operation: Operation.Attitude, index_first: 5, index_second: 0, ink: Ink.Cobalt),
  Step(stem: "07_expand_weight", label: "a ∧ L☆  perp plane",
    operation: Operation.ExpandWeight, index_first: 0, index_second: 5, ink: Ink.Olive),
  # `a` (and `b`, and `c`) already lie on `G` by construction -- `G` is joined from a
  #   line through `a` and `b`, plus `c` -- so projecting any of them onto `G` is a
  #   no-op with nothing new to show. `o`, the world origin, is the one seed placed
  #   specifically to sit off `G` (see the module doc comment's own table), so its
  #   projection actually lands somewhere else, visibly.
  Step(stem: "08_project", label: "o onto G",
    operation: Operation.ProjectOrthogonal, index_first: 3, index_second: 6, ink: Ink.Rose),
  # Attitude always drops one grade and always lands at horizon (see
  #   `objects.directionNormalHorizon`'s own doc comment): applied to a line it gave a
  #   point at horizon above (06); applied to a plane it gives a line at horizon; applied
  #   to a grade-4 volume (built here from a point wedged with a plane it does not lie
  #   on) it gives a plane at horizon -- the unique universal object every plane at
  #   horizon is, regardless of which points produced it.
  Step(stem: "09_attitude_line_horizon", label: "Lh = att(G)",
    operation: Operation.Attitude, index_first: 6, index_second: 0, ink: Ink.Jade),
  Step(stem: "10_wedge_volume", label: "a ∧ ground",
    operation: Operation.Wedge, index_first: 0, index_second: 4, ink: Ink.Copper),
  Step(stem: "11_attitude_plane_horizon", label: "Ph = att(a ∧ ground)",
    operation: Operation.Attitude, index_first: 14, index_second: 0, ink: Ink.Cobalt),
] ## Build a line from two points, a plane from that line, then meet, measure and
  ## project; close with attitude taken down to a line, then a plane, at horizon.


const INK_SEED_GROUND* = Ink.Olive
  ## Colour the startup scene's own ground plane wears.
  ##   Reserved by hand rather than taken from the cycle, because `ground` is the one seed
  ## every later step is derived against and a reader learns to find it by colour.

const INK_SEED_ORIGIN* = Ink.Copper
  ## Colour the startup scene's own origin point wears.
  ##   Reserved for the same reason `INK_SEED_GROUND` is: the origin is the one point in
  ## the scene that is not arbitrary, so it is worth being able to recognise it without
  ## reading its label. `a`, `b` and `c` step over both reserved hues, which leaves them
  ## exactly the three the categorical run has left and no two seeds collide.


proc constructSeeds*(scene: var Scene; now: float = 0.0) =
  ## Place the three points and the ground plane every later step is derived from.
  ##   `now` is forwarded to `addItem` untouched, so seeds animate in exactly as any
  ##   other item does where a caller passes a real clock reading.
  let
    point_a = toMultivector(Position(x: 3.0, y: -2.0, z: 2.5))
    point_b = toMultivector(Position(x: -2.5, y: 2.0, z: 5.5))
    point_c = toMultivector(Position(x: 1.0, y: 4.0, z: 3.0))
    point_origin = toMultivector(Position(x: 0, y: 0, z: 0))
    point_x = toMultivector(Position(x: 1, y: 0, z: 0))
    point_y = toMultivector(Position(x: 0, y: 1, z: 0))
    ground = point_origin ∧ point_x ∧ point_y
    # Centre ground's own circle on the three points that built it, not on its own
    #   closest-to-origin support -- the same reasoning `creationAnchor` gives every
    #   later plane, applied here by hand since a plane built from three points at once
    #   goes through no single `Operation` a generic dispatch could recognise. Each
    #   point unitized first, so the sum's own weight is exactly three and reading its
    #   position back out (which divides by weight) gives the plain centroid.
    anchor_ground = position(
      add(add(unitize(point_origin), unitize(point_x)), unitize(point_y))
    )
  # A hue each, as adding them by hand would give them: four objects wearing one colour
  #   say they are one kind of thing, which is the opposite of what a categorical palette
  #   is for. `ground` and `o` keep their own reserved hues, so the three arbitrary points
  #   take the three slots that are neither and nothing collides.
  var index_ink = 0
  proc inkNext(): Ink =
    while inkCycled(index_ink) in [INK_SEED_GROUND, INK_SEED_ORIGIN]: inc index_ink
    result = inkCycled(index_ink)
    inc index_ink
  scene.addItem(point_a, "a", inkNext(), now)
  scene.addItem(point_b, "b", inkNext(), now)
  scene.addItem(point_c, "c", inkNext(), now)
  scene.addItem(point_origin, "o", INK_SEED_ORIGIN, now)
  scene.addItem(ground, "ground", INK_SEED_GROUND, now, anchor_ground)


proc applyStep*(scene: var Scene; step: Step; now: float = 0.0): Multivector {.discardable.} =
  ## Apply one step, appending its result exactly as the GUI's apply button would.
  ##   Reports the derived geometry directly, since a caller wanting to name what this
  ##   step produced can no longer assume it landed in the last slot of a dense array.
  doAssert scene.isAlive(step.index_first) and scene.isAlive(step.index_second),
    "Storyboard step names an operand the scene has not built yet."
  let
    operand_first = scene[step.index_first].geometry
    operand_second = scene[step.index_second].geometry
  result = applyOperation(step.operation, operand_first, operand_second)
  let anchor = creationAnchor(step.operation, operand_first, operand_second, result)
  scene.addItem(result, step.label, step.ink, now, anchor)
