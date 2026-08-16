## Test that a picture of a frame says what the frame is, at any size.
##
## Every view is built on this drawing, and most of them draw it small: as a
## node on the map, as a header on the matrix, as a card in the atlas.  What the
## picture says has to survive being shrunk, because a reader who cannot read it
## cannot read anything else on the page.

{.experimental: "strictFuncs".}

import std/[options, sequtils, strutils, unittest]

import ../src/partnerwork


suite "the picture":
  test "the lead's hands are squares and the follow's are circles":
    # Which hand is whose was said only by the captions over and under the
    # picture, and those are the first thing to go when it is drawn small --
    # they are gone from this drawing entirely.  A shape survives any size, so
    # the picture says whose hand it is the way the vocabulary does: by the
    # mark itself, not by a word beside it.  Nothing else in the drawing may
    # be a rect or a circle, which is why the count is exact -- the bodies are
    # arcs and the chevrons are polylines.
    for target in FRAMES:
      let picture = renderFrame(target)
      check picture.count("<rect") == 2
      check picture.count("<circle") == 2

  test "a free hand fades and a held one does not":
    # A fill cannot say this any more, and should not: a fill says the *level*
    # a hand is held at -- solid low, dotted high, hatched above -- and a frame
    # knows no level, so every hand here is the hollow outline that means none
    # was said.  Claiming a level to mean "held" would be drawing something the
    # model does not know.  Half strength says it instead, and the connection
    # running out of the hand says it a second time.
    for target in FRAMES:
      # Two hands to a connection, one of the lead's and one of the follow's.
      check renderFrame(target).count("opacity=\"0.5\"") ==
        4 - 2 * target.countHolds

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

  test "turned back to front, the follow's hands change sides":
    # The picture's half of `crossedSite`.  At half a turn the hand that was
    # across the couple's midline is the near one, and a drawing that left the
    # follow's hands where they were would contradict the one place the
    # hand-to-hand model reads rotation.  The follow's whole body turns now,
    # and their hands ride round on it.
    for target in FRAMES:
      if target.countHolds == 0:
        continue
      let facing = renderFrame(target, 0)
      check renderFrame(target, 2) == facing
      check renderFrame(target, -2) == facing
      check renderFrame(target, 1) != facing
      check renderFrame(target, 1) == renderFrame(target, -1)

  test "a connection is drawn in its two hands' own colours":
    # So the line itself says which named hands are joined -- `Left to right`
    # runs blue into orange along its whole length -- instead of leaving it to
    # two marks that vanish at node size.  The deep half is the lead's, which
    # is what still says whose end is whose when both hands share a hue, as
    # they do in `Left to left`.
    for target in FRAMES:
      var inks: seq[string] = @[]
      for piece in renderFrame(target).split("<path "):
        # A connection is the one thing drawn at the connection's own width;
        # the rims that make up a body are thinner.
        if not piece.contains("stroke-width=\"3.4\""):
          continue
        let at = piece.find("stroke=\"") + 8
        inks.add piece[at ..< piece.find('"', at)]
      # Two halves to every connection, and no half of any other colour.
      check inks.len == 2 * target.countHolds
      check inks.countIt(it.contains("-deep")) == target.countHolds
      for side in Side:
        if target.hold[side].isNone:
          continue
        let
          near = if side == Side.Left: "--left-deep" else: "--right-deep"
          far = if target.hold[side].get == Site.LeftHand: "--left,"
                else: "--right,"
        check inks.anyIt(it.contains(near))
        check inks.anyIt(it.contains(far))

  test "both dancers say which way they face, in every picture":
    # This used to be a mark that appeared only when the follow had turned, on
    # the reasoning that a mark on every picture is furniture.  There are
    # bodies in the picture now, and a body always faces somewhere -- so the
    # chevron is not furniture, it is the one part of a dancer that carries
    # their orientation, and what varies is where it points rather than
    # whether it is there.  Both dancers get one, always.
    for target in FRAMES:
      for twist in [-3, -2, -1, 0, 1, 2, 3]:
        check renderFrame(target, twist).count("<polyline") == 2
      # And the turning shows, in every frame -- including `open`, which the
      # old drawing could not tell apart from itself turned.
      check renderFrame(target, 1) != renderFrame(target, 0)
