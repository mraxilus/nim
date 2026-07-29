## Script a construction, one operation at a time, for capture without a hand on the mouse.
##
## Storyboard exists so a build can be checked by looking at it: each step goes through the
## same `applyOperation` and `addItem` the GUI's apply button calls, so what a reader sees
## in the exported frames is what clicking would have produced.
##   Doubles as a visual regression harness: the frames are comparable between builds.
##
## Steps name their operands by index into the scene, which is dense and grows by one per
## step, so an index is stable once written.
##   Seeds occupy indices 0 to 3; every later index is the step that produced it.
##
##   |-------|-------------------|--------------------------------------------------|
##   | Index | Object            | Origin                                           |
##   |-------|-------------------|--------------------------------------------------|
##   | 0,1,2 | a, b, c           | Seed points, placed by hand.                     |
##   | 3     | ground            | Seed plane, joined from three points at z = 0.    |
##   | 4+    | one per step      | Result of the step's own operation.               |
##   |-------|-------------------|--------------------------------------------------|

{.experimental: "strictFuncs".}

import ../pga
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
  Step(stem: "01_join_line", label: "L = a ^ b",
    operation: Operation.Wedge, index_first: 0, index_second: 1, ink: Ink.Cyan),
  Step(stem: "02_join_plane", label: "G = L ^ c",
    operation: Operation.Wedge, index_first: 4, index_second: 2, ink: Ink.Teal),
  Step(stem: "03_meet_line", label: "ground v G",
    operation: Operation.WedgeAnti, index_first: 3, index_second: 5, ink: Ink.Violet),
  Step(stem: "04_meet_point", label: "L v ground",
    operation: Operation.WedgeAnti, index_first: 4, index_second: 3, ink: Ink.Coral),
  Step(stem: "05_support", label: "sup(L)",
    operation: Operation.Support, index_first: 4, index_second: 0, ink: Ink.Amber),
  Step(stem: "06_attitude", label: "att(L)",
    operation: Operation.Attitude, index_first: 4, index_second: 0, ink: Ink.Rose),
  Step(stem: "07_expand_weight", label: "a ^ L*  perp plane",
    operation: Operation.ExpandWeight, index_first: 0, index_second: 4, ink: Ink.Lime),
  Step(stem: "08_project", label: "a onto G",
    operation: Operation.ProjectOrthogonal, index_first: 0, index_second: 5, ink: Ink.Coral),
  # Attitude always drops one grade and always lands at horizon (see
  #   `objects.directionNormalHorizon`'s own doc comment): applied to a line it gave a
  #   point at horizon above (06); applied to a plane it gives a line at horizon; applied
  #   to a grade-4 volume (built here from a point wedged with a plane it does not lie
  #   on) it gives a plane at horizon -- the unique universal object every plane at
  #   horizon is, regardless of which points produced it.
  Step(stem: "09_attitude_line_horizon", label: "Lh = att(G)",
    operation: Operation.Attitude, index_first: 5, index_second: 0, ink: Ink.Cyan),
  Step(stem: "10_wedge_volume", label: "a ^ ground",
    operation: Operation.Wedge, index_first: 0, index_second: 3, ink: Ink.Violet),
  Step(stem: "11_attitude_plane_horizon", label: "Ph = att(a ^ ground)",
    operation: Operation.Attitude, index_first: 13, index_second: 0, ink: Ink.Teal),
] ## Build a line from two points, a plane from that line, then meet, measure and
  ## project; close with attitude taken down to a line, then a plane, at horizon.


proc constructSeeds*(scene: var Scene; now: float = 0.0) =
  ## Place the three points and the ground plane every later step is derived from.
  ##   `now` is forwarded to `addItem` untouched, so seeds animate in exactly as any
  ##   other item does where a caller passes a real clock reading.
  let
    point_a = toMultivector(Position(x: 3.0, y: -2.0, z: 0.5))
    point_b = toMultivector(Position(x: -2.5, y: 2.0, z: 3.5))
    point_c = toMultivector(Position(x: 1.0, y: 4.0, z: 1.0))
    ground = (
      toMultivector(Position(x: 0, y: 0, z: 0)) ∧
      toMultivector(Position(x: 1, y: 0, z: 0)) ∧
      toMultivector(Position(x: 0, y: 1, z: 0))
    )
  scene.addItem(point_a, "a", Ink.Amber, now)
  scene.addItem(point_b, "b", Ink.Amber, now)
  scene.addItem(point_c, "c", Ink.Amber, now)
  scene.addItem(ground, "ground", Ink.Lime, now)


proc applyStep*(scene: var Scene; step: Step; now: float = 0.0): Multivector {.discardable.} =
  ## Apply one step, appending its result exactly as the GUI's apply button would.
  ##   Reports the derived geometry directly, since a caller wanting to name what this
  ##   step produced can no longer assume it landed in the last slot of a dense array.
  doAssert scene.isAlive(step.index_first) and scene.isAlive(step.index_second),
    "Storyboard step names an operand the scene has not built yet."
  result = applyOperation(step.operation, scene[step.index_first].geometry,
    scene[step.index_second].geometry)
  scene.addItem(result, step.label, step.ink, now)
