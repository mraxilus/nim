## Test the laws of the transition relation over every pair of frames.
##
## The state space is small enough to check exhaustively, so nothing here is a
## sample: each law is asserted for all 64 ordered pairs.

import std/[options, strutils, unittest]

import ../src/partnerwork/frame
import ../src/partnerwork/transition


suite "the relation":
  test "no frame reaches itself":
    for target in FRAMES:
      check classify(target, target).isNone

  test "every primitive reverses, so the relation is symmetric":
    for source in FRAMES:
      for destination in FRAMES:
        let forward = classify(source, destination)
        let backward = classify(destination, source)
        check forward.isSome == backward.isSome
        if forward.isSome:
          check backward.get == forward.get.inverse

  test "reflection is a symmetry of the relation":
    for source in FRAMES:
      for destination in FRAMES:
        check classify(source, destination) ==
          classify(source.reflect, destination.reflect)

  test "the relation is not empty and not everything":
    var edges = 0
    for source in FRAMES:
      for destination in FRAMES:
        if classify(source, destination).isSome:
          inc edges
    check edges == 26
    check edges < FRAMES.len * (FRAMES.len - 1)


suite "the primitives":
  test "collect and drop change the number of connections by one":
    for source in FRAMES:
      for destination in FRAMES:
        let helper = classify(source, destination)
        if helper.isNone:
          continue
        let change = destination.countHolds - source.countHolds
        case helper.get
        of Helper.Collect: check change == 1
        of Helper.Drop: check change == -1
        else: check change == 0

  test "one hand cannot travel from one hand of the follow to the other":
    # That move is a trace, and there is nothing between the follow's hands to
    # trace along. It becomes a move when the arms and body are places to hold.
    for side in Side:
      var source = Frame()
      var destination = Frame()
      source.hold[side] = some(Site.LeftHand)
      destination.hold[side] = some(Site.RightHand)
      check classify(source, destination).isNone
      check route(source, destination).len == 2

  test "a pass keeps the place and changes the hand":
    for source in FRAMES:
      for destination in FRAMES:
        if classify(source, destination) != some(Helper.Pass):
          continue
        check source.countHolds == 1 and destination.countHolds == 1
        let side = actingSide(source, destination, Helper.Pass)
        check destination.hold[side] == source.hold[other(side)]
        check destination.hold[other(side)].isNone

  test "a cut changes only which arm is on top":
    for source in FRAMES:
      for destination in FRAMES:
        if classify(source, destination) != some(Helper.Cut):
          continue
        check source.hold == destination.hold
        check source.hasOverlap and destination.hasOverlap
        check source.over != destination.over


suite "moves":
  test "the offered moves are exactly the frames one primitive away":
    for source in FRAMES:
      var offered: seq[Frame] = @[]
      for move in moves(source):
        check classify(source, move.to) == some(move.helper)
        check move.to notin offered
        check phrase(source, move).len > 0
        offered.add move.to
      for destination in FRAMES:
        if classify(source, destination).isSome:
          check destination in offered

  test "the open frame is where every dance starts and ends":
    let open = fromKey("--.").get
    check open.countHolds == 0
    check moves(open).len == 4
    for move in moves(open):
      check move.helper == Helper.Collect


suite "routes":
  test "every frame reaches every other, and a route is a chain of moves":
    for source in FRAMES:
      for destination in FRAMES:
        if source == destination:
          check route(source, destination).len == 0
          continue
        let steps = route(source, destination)
        check steps.len > 0
        var current = source
        for step in steps:
          check classify(current, step.to) == some(step.helper)
          current = step.to
        check current == destination

  test "a route is one move long exactly where a primitive exists":
    for source in FRAMES:
      for destination in FRAMES:
        if source == destination:
          continue
        let steps = route(source, destination)
        check (steps.len == 1) == classify(source, destination).isSome


suite "the vocabulary":
  test "no two primitives share a mark, a name or a change":
    var marks: seq[char] = @[]
    var names, changes: seq[string] = @[]
    for helper in Helper:
      check HELPER_MARKS[helper] notin marks
      check helper.name notin names
      check HELPER_CHANGES[helper] notin changes
      check helper.manner.startsWith(helper.name)
      marks.add HELPER_MARKS[helper]
      names.add helper.name
      changes.add HELPER_CHANGES[helper]

  test "a primitive with another word says so, and one without does not":
    check HELPER_SYNONYMS[Helper.Drop].len > 0
    check Helper.Drop.manner.contains("flick")
    check HELPER_SYNONYMS[Helper.Cut].len == 0
    check Helper.Cut.manner == "cut"
