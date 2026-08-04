## Test the laws of the frame: validity, naming, keys and reflection.

import std/[options, unittest]

import ../src/partnerwork/frame


suite "frames":
  test "every enumerated frame is valid and distinct":
    check FRAMES.len == 15
    for target in FRAMES:
      check target.isValid
    for index, target in FRAMES:
      check target.frameIndex == index

  test "an arm order is recorded exactly where the forearms overlap":
    var overlapping = 0
    for target in FRAMES:
      check target.over.isSome == target.hasOverlap
      if target.hasOverlap:
        inc overlapping
    check overlapping == 2 # Left over Right, and Right over Left.

  test "only the same-named hands cross the midline":
    check isCrossed(Side.Left, Site.LeftHand)
    check isCrossed(Side.Right, Site.RightHand)
    check not isCrossed(Side.Left, Site.RightHand)
    check not isCrossed(Side.Right, Site.LeftHand)
    for side in Side:
      check parallelSite(side) != crossedSite(side)

  test "a frame survives a round trip through its key":
    var keys: seq[string] = @[]
    for target in FRAMES:
      check fromKey(target.key) == some(target)
      check target.key notin keys
      keys.add target.key

  test "a key that is not a valid frame is rejected":
    check fromKey("").isNone
    check fromKey("--").isNone
    check fromKey("zz.").isNone
    check fromKey("ll.").isNone  # One follow hand cannot be held twice.
    check fromKey("lr.").isNone  # Overlapping forearms need an order.
    check fromKey("rl L").isNone # A parallel pair has no order to record.

  test "reflection is an involution and permutes the frames":
    for target in FRAMES:
      check target.reflect.isValid
      check target.reflect.reflect == target
      check target.reflect.frameIndex >= 0
    var seen: seq[Frame] = @[]
    for target in FRAMES:
      check target.reflect notin seen
      seen.add target.reflect

  test "reflection exchanges the crossing orders and fixes the parallel pair":
    let over_left = fromKey("lrL").get
    check over_left.reflect == fromKey("lrR").get
    check fromKey("rl.").get.reflect == fromKey("rl.").get
    check fromKey("l-.").get.reflect == fromKey("-r.").get


suite "conventions":
  test "salsa admits the frames the workbook draws from":
    var salsa = 0
    for target in Convention.Salsa.admitted:
      inc salsa
    check salsa == 11
    var physical = 0
    for target in Convention.Physical.admitted:
      inc physical
    check physical == FRAMES.len

  test "an idiom is not a symmetry, so salsa is not closed under reflection":
    var mirrored_out = 0
    for target in Convention.Salsa.admitted:
      if not Convention.Salsa.admits(target.reflect):
        inc mirrored_out
    # The three frames whose mirror puts the follow's torso in the lead's left
    # hand: half-closed, closed, and Left-to-left with the right hand on the torso.
    check mirrored_out == 3


suite "naming":
  test "every frame is named, and the idiom names three of them":
    var idioms: seq[string] = @[]
    for target in FRAMES:
      check target.describe.len > 0
      check target.title.len > 0
      check target.position.len > 0
      if target.idiom.isSome:
        idioms.add target.idiom.get
    check idioms == @["open", "half-closed", "closed"]

  test "the workbook's names come out of the structure":
    check fromKey("l-.").get.describe == "Left to left"
    check fromKey("r-.").get.describe == "Left to right"
    check fromKey("rl.").get.describe == "Left-to-right and Right-to-left"
    check fromKey("lrL").get.describe == "Left-to-left over Right-to-right"
    check fromKey("lrR").get.describe == "Right-to-right over Left-to-left"

  test "the two crossing orders are one position and two frames":
    let over_left = fromKey("lrL").get
    let over_right = fromKey("lrR").get
    check over_left != over_right
    check over_left.position == over_right.position
    check over_left.position == "Left-to-left and Right-to-right"
