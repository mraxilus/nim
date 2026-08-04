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
    # A couple travels round the floor without unwinding, so a shared rotation
    # cannot be counted as a turn of each dancer in turn.
    let pair = fromKey("rl.").get.rest
    check pair.turn(together(2)) == some(pair)
    check pair.turn(together(-3)) == some(pair)

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
    check fromKey("l-.").get.rest.capacity == 2
    check fromKey("-r.").get.rest.capacity == 2

  test "a pair of connections binds at half a turn":
    check fromKey("rl.").get.rest.capacity == 1
    check fromKey("lrL").get.rest.capacity == 1

  test "a hand resting on the body gives no turn away":
    # This is what closed position is, and why a turn out of it needs the lead's
    # right hand to leave the follow's back first.
    let closed = fromKey("r-.").get.rest.rests(Side.Right, BodySite.Torso)
    check closed.capacity == 0
    check closed.turn(rotates(Dancer.Follow, 1)).isNone
    check closed.turn(together(2)) == some(closed)


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
    check modifier(fromKey("rl.").get.rest.capacity) == some(Modifier.Wrap)
    check modifier(fromKey("l-.").get.rest.capacity) == some(Modifier.Lock)

  test "the level an arm is carried at decides where it lands":
    check around(Modifier.Wrap, Level.Low) == BodySite.Torso
    check around(Modifier.Wrap, Level.High) == BodySite.Neck
    check around(Modifier.Lock, Level.Low) == BodySite.Waist
    check around(Modifier.Lock, Level.High) == BodySite.Shoulder
