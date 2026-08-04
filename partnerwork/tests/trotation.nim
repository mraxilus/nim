## Test the part of the rotation axis that does not need measurement.
##
## The calibrated numbers are hypotheses and are checked only against the two
## sentences they came from; the geometry and the bookkeeping are checked as
## laws, because they follow from the bodies being rigid.

import std/[options, unittest]

import ../src/partnerwork/frame
import ../src/partnerwork/rotation


suite "twist":
  test "a rotation of the whole couple stores nothing":
    # Closed position holds no twist at all, yet a couple travels round the floor
    # in it all night, so a shared rotation cannot be counted as one.
    let closed = fromKey("rt.").get.rest
    check closed.turn(together(2)) == some(closed)
    check closed.turn(together(-1)).isSome
    check closed.turn(rotates(Dancer.Lead, 1)).isNone

  test "a turn one dancer takes alone is stored as twist":
    let hand_to_hand = fromKey("l-.").get.rest
    check hand_to_hand.turn(rotates(Dancer.Follow, 1)).get.twist == 1
    check hand_to_hand.turn(rotates(Dancer.Lead, 1)).get.twist == -1

  test "a turn beyond what the arms hold is refused":
    let hand_to_hand = fromKey("l-.").get.rest
    check hand_to_hand.turn(rotates(Dancer.Follow, 2)).isSome
    check hand_to_hand.turn(rotates(Dancer.Follow, 3)).isNone
    check hand_to_hand.turn(rotates(Dancer.Lead, 3)).isNone

  test "turning is reversible inside the capacity":
    let pair = fromKey("rl.").get.rest
    let turned = pair.turn(rotates(Dancer.Follow, 1))
    check turned.isSome
    check turned.get.turn(rotates(Dancer.Follow, -1)) == some(pair)


suite "capacity":
  test "one full turn is comfortable on one hand-to-hand connection":
    check fromKey("l-.").get.capacity == 2
    check fromKey("-r.").get.capacity == 2

  test "a pair of connections binds at half a turn":
    check fromKey("rl.").get.capacity == 1
    check fromKey("lrL").get.capacity == 1

  test "a hand on the torso gives no turn away":
    check fromKey("rt.").get.capacity == 0
    check fromKey("-t.").get.capacity == 0
    check fromKey("lt.").get.capacity == 0
    check fromKey("rt.").get.rest.turn(rotates(Dancer.Follow, 1)).isNone


suite "geometry":
  test "half a turn exchanges the crossed and the parallel hand":
    for side in Side:
      check crossedSite(side, 0) == crossedSite(side)
      check parallelSite(side, 0) == parallelSite(side)
      check crossedSite(side, 1) == parallelSite(side)
      check parallelSite(side, 1) == crossedSite(side)
      check crossedSite(side, 2) == crossedSite(side)
      check crossedSite(side, -1) == parallelSite(side)
    check isFacing(0) and isFacing(2) and isFacing(-2)
    check not isFacing(1) and not isFacing(-1)


suite "modifiers":
  test "the two filled cells of the rotations sheet are reproduced":
    # `Left to left` held low: half a turn left wraps, a full turn right locks.
    check modifier(0).isNone
    check modifier(-1) == some(Modifier.Wrap)
    check modifier(2) == some(Modifier.Lock)

  test "a wrap is reachable from a pair and a lock is not":
    check modifier(fromKey("rl.").get.capacity) == some(Modifier.Wrap)
    check modifier(fromKey("l-.").get.capacity) == some(Modifier.Lock)
