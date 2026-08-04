## Test the laws of the transition relation over every pair of frames.
##
## The state space is small enough to check exhaustively, so nothing here is a
## sample: each law is asserted for all 225 ordered pairs.

import std/[options, unittest]

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
    check edges == 62
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

  test "a trace keeps the hand and passes through the torso":
    for source in FRAMES:
      for destination in FRAMES:
        if classify(source, destination) != some(Helper.Trace):
          continue
        let side = actingSide(source, destination, Helper.Trace)
        check source.hold[side].isSome and destination.hold[side].isSome
        check source.hold[side] != destination.hold[side]
        check source.hold[side] == some(Site.Torso) or
          destination.hold[side] == some(Site.Torso)
        check source.hold[other(side)] == destination.hold[other(side)]

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

  test "there is no path from one hand of the follow to the other":
    for side in Side:
      check not isTraceable(side, Site.LeftHand, Site.RightHand)
      check isTraceable(side, Site.Torso, parallelSite(side))
      check not isTraceable(side, Site.Torso, crossedSite(side))


suite "moves":
  test "the offered moves are exactly the frames one primitive away":
    for convention in Convention:
      for source in convention.admitted:
        var offered: seq[Frame] = @[]
        for move in moves(source, convention):
          check classify(source, move.to) == some(move.helper)
          check convention.admits(move.to)
          check move.to notin offered
          check phrase(source, move).len > 0
          offered.add move.to
        for destination in convention.admitted:
          if classify(source, destination).isSome:
            check destination in offered

  test "an idiom can only remove moves":
    for source in Convention.Salsa.admitted:
      check moves(source, Convention.Salsa).len <=
        moves(source, Convention.Physical).len

  test "the open frame is where every dance starts and ends":
    let open = fromKey("--.").get
    check open.countHolds == 0
    check moves(open, Convention.Salsa).len == 5
    check moves(open, Convention.Physical).len == 6
    for move in moves(open, Convention.Physical):
      check move.helper == Helper.Collect


suite "routes":
  test "every frame reaches every other, and a route is a chain of moves":
    for convention in Convention:
      for source in convention.admitted:
        for destination in convention.admitted:
          if source == destination:
            check route(source, destination, convention).len == 0
            continue
          let steps = route(source, destination, convention)
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
        let steps = route(source, destination, Convention.Physical)
        check (steps.len == 1) == classify(source, destination).isSome
