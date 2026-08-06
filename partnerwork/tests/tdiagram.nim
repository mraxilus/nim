## Test that a picture of a frame says what the frame is, at any size.
##
## Every view is built on this drawing, and most of them draw it small: as a
## node on the map, as a header on the matrix, as a card in the atlas.  What the
## picture says has to survive being shrunk, because a reader who cannot read it
## cannot read anything else on the page.

import std/[options, strutils, unittest]

import ../src/partnerwork


suite "the picture":
  test "the lead's hands are squares and the follow's are circles":
    # Which row is whose was said only by the captions over and under the
    # picture, and those are the first thing to go when it is drawn small.  A
    # shape survives any size, so the picture says whose hand it is the way the
    # vocabulary does -- by the mark itself, not by a word beside it.
    for target in FRAMES:
      let picture = renderFrame(target)
      check picture.count("<rect") == 2
      check picture.count("<circle") == 2

  test "a hand being held is filled and a free one is not":
    for target in FRAMES:
      var open = 0
      # The hands, and not everything in the drawing that happens to be unfilled:
      # a picture carries marks that are outlines by nature.
      for element in renderFrame(target).split('<'):
        if (element.startsWith("rect") or element.startsWith("circle")) and
            element.contains("fill: none"):
          inc open
      # Two hands to a connection, one of the lead's and one of the follow's.
      check open == 4 - 2 * target.countHolds

  test "every frame is drawn in the one space, whatever it holds":
    # A coordinate has to mean the same place in every frame, because the views
    # put frames side by side and read one against another.
    var boxes: seq[string] = @[]
    for target in FRAMES:
      let picture = renderFrame(target)
      let start = picture.find("viewBox=\"")
      check start >= 0
      let box = picture[start .. picture.find('"', start + 9)]
      if box notin boxes:
        boxes.add box
    check boxes.len == 1

  test "a picture names the frame it draws, for a reader who cannot see it":
    for target in FRAMES:
      check renderFrame(target).contains("<title>" & target.describe & "</title>")

  test "turned back to front, the follow's hands change columns":
    # The picture's half of `crossedSite`.  At half a turn the hand that was
    # across the midline is the near one, and a drawing that left the follow's
    # hands where they were would contradict the one place the hand-to-hand
    # model reads rotation.
    for target in FRAMES:
      if target.countHolds == 0:
        continue
      let facing = renderFrame(target, 0)
      check renderFrame(target, 2) == facing
      check renderFrame(target, -2) == facing
      check renderFrame(target, 1) != facing
      check renderFrame(target, 1) == renderFrame(target, -1)

  test "the captions travel with the hands they name":
    # Otherwise the picture is right and its labels are wrong, which is worse
    # than either being wrong on its own.
    for twist in [0, 1]:
      let picture = renderFrame(FRAMES[0], twist)
      check picture.count(">right<") == 1
      check picture.count(">left<") == 1

  test "every picture says which way the follow is facing":
    for target in FRAMES:
      for twist in -2 .. 2:
        check renderFrame(target, twist).count("<polyline") == 1
