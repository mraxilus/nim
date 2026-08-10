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


suite "what the arm can carry":
  test "the measured table is reproduced, cell by cell":
    # `Left to left`, one hand, danced.  A low wrap holds half a turn; a low
    # lock, a high wrap and a high lock each hold a full one.
    check armCapacity(some(Blocker.Wrap), Level.Low) == 1  # rotations: low wrap, half a turn
    check armCapacity(some(Blocker.Lock), Level.Low) == 2  # rotations: low lock, a full turn
    check armCapacity(some(Blocker.Wrap), Level.High) == 2  # assumed, see `CAPACITY_ARM`
    check armCapacity(some(Blocker.Lock), Level.High) == 2  # assumed, see `CAPACITY_ARM`

  test "a low wrap is the one thing that binds tighter than its hold":
    # Which is the whole finding: the limit is not a property of what joins the
    # couple, it is a property of what the arm is doing.
    let low = fromKey("l-.").get.rest
    for twist in -2 .. 2:
      let arm = armCapacity(blocker(twist), low.level[Side.Left])
      if blocker(twist) == some(Blocker.Wrap):
        check arm < low.capacity
      else:
        check arm >= low.capacity

  test "held low, half a turn wraps and a full turn locks, either way":
    # And not because a rule says so: a low wrap cannot hold a full turn, so an
    # arm carried low that has turned that far has gone behind the back.
    let low = fromKey("l-.").get.rest
    for way in [1, -1]:
      let half = low.turn(rotates(Dancer.Follow, way))
      check half.isSome
      check blocker(half.get.twist) == some(Blocker.Wrap)
      let full = low.turn(rotates(Dancer.Follow, 2 * way))
      check full.isSome
      check blocker(full.get.twist) == some(Blocker.Lock)

  test "one and a half turns is refused, and the hold is what refuses it":
    let low = fromKey("l-.").get.rest
    for way in [1, -1]:
      check low.turn(rotates(Dancer.Follow, 3 * way)).isNone
      # Past the hold's ceiling, which is the one that binds there: the arm is
      # a lock by then, and a lock is the roomier of the two.
      check 3 > low.capacity
      check armCapacity(blocker(3 * way), Level.Low) == CAPACITY_ARM

  test "a posture stands only where both ceilings allow it":
    for target in FRAMES:
      for level in Level:
        var posture = target.rest
        posture.level = [level, level]
        for twist in -4 .. 4:
          let both = abs(twist) <= posture.capacity and
            abs(twist) <= posture.armsCapacity(twist)
          check posture.holds(twist) == both

  test "only an arm that is holding can be the one that runs out":
    # A free arm carries nothing, so the height it happens to be at cannot stop
    # a turn.  Raising the hand that is not holding changes nothing.
    for target in FRAMES:
      for side in Side:
        if target.hold[side].isSome:
          continue
        var lowered = target.rest
        var raised = target.rest
        raised.level[side] = Level.High
        for twist in -4 .. 4:
          check lowered.holds(twist) == raised.holds(twist)

  test "with nobody holding, nothing limits the turn":
    # Two people who are not touching can each face wherever they like.
    let apart = fromKey("--.").get.rest
    for twist in -6 .. 6:
      check apart.holds(twist)


suite "modifiers":
  test "the two filled cells of the rotations sheet are reproduced":
    # `Left to left` held low: half a turn left wraps, a full turn right locks.
    check blocker(0).isNone
    check blocker(-1) == some(Blocker.Wrap)  # rotations: half a turn left wraps
    check blocker(2) == some(Blocker.Lock)  # rotations: a full turn right locks

  test "a wrap is reachable from a pair and a lock is not":
    check blocker(fromKey("rl.").get.rest.capacity) == some(Blocker.Wrap)
    check blocker(fromKey("l-.").get.rest.capacity) == some(Blocker.Lock)

  test "the level an arm is carried at decides where it lands":
    check around(Blocker.Wrap, Level.Low) == some(BodySite.Torso)
    check around(Blocker.Wrap, Level.High) == some(BodySite.Neck)
    check around(Blocker.Lock, Level.Low) == some(BodySite.Waist)
    check around(Blocker.Lock, Level.High) == some(BodySite.Shoulder)

  test "an arm over the head is around nothing, and blocks on nothing":
    # It is on the axis the couple turns about, so there is nothing for it to be
    # across the front of or behind the line of.  That is why it does not run
    # out -- and why a case where it blocks anyway is a thing the model is
    # waiting to be told rather than a thing it has decided.
    for what in Blocker:
      check around(what, Level.Above).isNone
    for twist in -6 .. 6:
      check blockerOf(twist, Level.Above).isNone
      check armCapacity(blockerOf(twist, Level.Above), Level.Above) ==
        high(HalfTurns)
    check not ABOVE_BLOCKS


suite "what there is":
  test "every posture stands, and no posture is counted twice":
    var seen: seq[Posture] = @[]
    for stood in postures():
      check stood.holds(stood.twist)
      check stood notin seen
      seen.add stood
    check postures().len > FRAMES.len

  test "a free hand's height is not a posture of its own":
    # Two postures differing only in where a hand that is holding nothing is
    # carried are one posture, because that height cannot stop a turn.
    for stood in postures():
      check stood == normalised(stood)

  test "every frame at rest is a posture, and is where its turns start from":
    for target in FRAMES:
      check target.rest in postures()

  test "the twelve turn sheets are six":
    # A turn is stored as one number for the couple, and that number does not
    # care which of them moved: the lead turning one way and the follow turning
    # the other leave the couple in the same posture.  So half of the workbook's
    # twelve sheets are the other half read backwards.
    for stood in postures():
      let offers = turnsOf(stood)
      check offers.len == 12
      var landings: seq[Posture] = @[]
      for offer in offers:
        if offer.to notin landings:
          landings.add offer.to
      check landings.len == 6
    let lone = fromKey("l-.").get.rest
    for size in 1 .. MOST_TURN:
      check lone.turn(rotates(Dancer.Lead, size)) ==
        lone.turn(rotates(Dancer.Follow, -size))

  test "a turn is offered exactly when it is not refused":
    for stood in postures():
      for offer in turnsOf(stood):
        let taken = stood.turn(rotates(offer.who, offer.amount))
        check taken.isSome == offer.refused.isNone
        if offer.refused.isNone:
          check taken.get == offer.to

  test "a refusal names the ceiling that refuses, and the hold comes first":
    for stood in postures():
      for offer in turnsOf(stood):
        if offer.refused.isNone:
          continue
        let over = offer.to.twist
        case offer.refused.get
        of Refusal.Hold: check abs(over) > stood.capacity
        of Refusal.Arm:
          # Named only where the hold would have allowed it, so the reason given
          # is the reason, and not merely one of two.
          check abs(over) <= stood.capacity
          check abs(over) > stood.armsCapacity(over)

  test "held low on one hand, it is the arm that refuses first":
    # The finding, read back out of the offers: from `Left to left` held low a
    # turn is never refused by the hold before the arm has already had its say.
    let low = fromKey("l-.").get.rest
    var arm_first = 0
    for offer in turnsOf(low):
      if offer.refused == some(Refusal.Arm):
        inc arm_first
    check arm_first == 0
    # Because the arm's ceiling is not a refusal here -- it is what makes a full
    # turn a lock.  What refuses is the hold, at one and a half.
    for offer in turnsOf(low):
      if abs(offer.to.twist) == 3:
        check offer.refused == some(Refusal.Hold)
