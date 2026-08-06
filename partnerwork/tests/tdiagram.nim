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
      let picture = renderFrame(target)
      # Two hands to a connection, one of the lead's and one of the follow's.
      check picture.count("fill: none") == 4 - 2 * target.countHolds

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
