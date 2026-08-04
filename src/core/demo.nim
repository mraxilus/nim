## Build the construction both front-ends open on, and the eleven steps that follow it.
##
## Five seeds, then eleven derived steps. Both front-ends open on the **seeds alone**, so the
## window and the capture script agree on where a construction starts. The eleven steps are a
## one-click preset that populates the scene with ordinary, fully editable items — not a
## separate scripted-playback mode.
##
## Two steps are load-bearing teaching cases rather than bugs. `a ∧ ground` is a grade-4
## volume and correctly reports "nothing to draw": a point wedged with a plane it does not lie
## on has nothing to render, and that is the step's documented purpose. And attitude drops one
## grade each time, walking a horizon point, then a horizon line, then the plane at horizon,
## which is how all three horizon cases get exercised.

{.experimental: "strictFuncs".}

import std/options

import ./[algebra, catalogue, scene, workbench]



#[ Type Definitions ]#

type
  DemoStep* = object
    ## Name one derived step of the construction, by the items it reads.
    operation*: Operation
    first*: int   ## Ordinal of the first operand among the items built so far.
    second*: int  ## Ordinal of the second operand; ignored by a unary step.

  StepRecord* = object
    ## Record what one applied step actually touched, for a capture run to focus on.
    first*: Option[Slot]
    second*: Option[Slot]
    derived*: Option[Slot]



#[ Seeds ]#

const
  SEED_STEP_MS* = 1000.0
    ## Stamp each preset step this far after the last, mirroring the capture run's clock.
  DEMO_STEP_COUNT* = 11
    ## Count derived steps of the construction.

func seedScene*(): Scene =
  ## Build the five seeds every run opens on.
  ##   The three points sit off the ground plane, so each join and meet below has something to
  ##   show. `ground` is joined from three points at z = 0 and centred on their centroid,
  ##   which is the one plane anchor no operation can imply afterwards.
  result = initScene()
  let
    a = pointAt(3.0, -2.0, 2.5)
    b = pointAt(-2.5, 2.0, 5.5)
    c = pointAt(1.0, 4.0, 3.0)
    o = pointAt(0.0, 0.0, 0.0)
    ground_first = pointAt(4.0, -4.0, 0.0)
    ground_second = pointAt(-4.0, -1.0, 0.0)
    ground_third = pointAt(0.0, 5.0, 0.0)
    ground = ground_first ∧ ground_second ∧ ground_third
  for (geometry, name, anchor) in [
    (a, "a", none(Position)),
    (b, "b", none(Position)),
    (c, "c", none(Position)),
    (o, "o", none(Position)),
    (ground, "ground", centroid(ground_first, ground_second, ground_third)),
  ]:
    discard result.add(
      geometry = geometry, label = initLabel(name), born_ms = 0.0, anchor = anchor
    )



#[ Steps ]#

const DEMO_STEPS*: array[DEMO_STEP_COUNT, DemoStep] = [
  ## Name the eleven derived steps, by the ordinals of the items they read.
  ##   Ordinals count from the first seed, and the scene grows by exactly one per step, so
  ##   these stay stable while the seed count is read from the scene itself.
  DemoStep(operation: Operation.Wedge, first: 0, second: 1),               # a ∧ b
  DemoStep(operation: Operation.Wedge, first: 5, second: 2),               # that line ∧ c
  DemoStep(operation: Operation.Antiwedge, first: 4, second: 6),           # ground ∨ plane
  DemoStep(operation: Operation.Antiwedge, first: 5, second: 4),           # line ∨ ground
  DemoStep(operation: Operation.Support, first: 5, second: 5),             # line's support
  DemoStep(operation: Operation.Attitude, first: 5, second: 5),            # line's attitude
  DemoStep(operation: Operation.ExpandWeight, first: 0, second: 5),        # a ∧ line☆
  DemoStep(operation: Operation.ProjectOrthogonal, first: 3, second: 11),  # o onto plane
  DemoStep(operation: Operation.Attitude, first: 11, second: 11),          # plane's attitude
  DemoStep(operation: Operation.Wedge, first: 0, second: 4),               # a ∧ ground
  DemoStep(operation: Operation.Attitude, first: 14, second: 14),          # volume's attitude
]



#[ Application ]#

func applySteps*(
  workbench: var Workbench, records: var array[DEMO_STEP_COUNT, StepRecord]
) =
  ## Apply every derived step to the scene, stamping births one second apart.
  ##   Populates ordinary items: each is editable, undoable and saveable like any other, and a
  ##   recency-sorted list reads the seeds as oldest and each step as progressively newer.
  var
    built: array[64, Slot]
    count = 0
  for slot in workbench.scene.items:
    built[count] = slot
    count += 1
  let seed_count = count  # Read from the scene, so inserting a seed needs no edit here.

  for index, step in DEMO_STEPS:
    if step.first >= count: continue
    if step.operation.arity == Arity.Binary and step.second >= count: continue
    workbench.now_ms = float(index + 1)*SEED_STEP_MS
    let
      first = built[step.first]
      second = built[step.second]
      derived = workbench.applyOperation(step.operation, first, second)
    records[index] = StepRecord(
      first: some(first),
      second: if step.operation.arity == Arity.Binary: some(second) else: none(Slot),
      derived: derived,
    )
    if derived.isNone: continue
    built[count] = derived.get
    count += 1
  discard seed_count


func loadDemo*(workbench: var Workbench) =
  ## Replace the scene with the seeds and run every step, as the preset control does.
  workbench.reset(seedScene())
  var records: array[DEMO_STEP_COUNT, StepRecord]
  workbench.applySteps(records)
