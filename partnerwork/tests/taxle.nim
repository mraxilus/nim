## Hold the axle drawing to its own claims.
##
## The axle has no page yet -- the app's Dance view is graph-first and the
## rotation exploration lives in the design workbench -- so these laws are
## what keeps it from rotting while it waits: the drawing still says what
## its header says it says.

{.experimental: "strictFuncs".}

import std/[options, strutils, unittest]

import ../src/partnerwork

suite "the axle":
  test "the axle is one line: a twist's place is affine in the twist":
    # Placed by the twist itself rather than by an index, so the distance
    # between two postures on the drawing is the size of the turn between
    # them, wherever it is taken.
    let stood = FRAMES[1].rest
    let places = standing(stood)
    check places.len > 1
    var gap = 0
    for i in 1 ..< places.len:
      let
        (ax, ay) = centreOf(stood, places[i - 1])
        (bx, by) = centreOf(stood, places[i])
      check bx > ax  # laid out in the order they are turned into
      check ay == by  # one line, one row
      let step = (bx - ax) div (places[i] - places[i - 1])
      if gap == 0: gap = step
      check step == gap

  test "the couple stand on one posture, and a refusal is drawn refused":
    # The header's claim: the drawing can show a turn and refuse it in the
    # same breath, so the refused arcs are present and marked.
    let drawn = renderAxle(FRAMES[1].rest)
    check drawn.count("class=\"node here\"") == 1
    check "class=\"turn refused\"" in drawn
    check "class=\"node reachable\"" in drawn

  test "the axle is as wide as it says it is":
    check ("viewBox=\"0 0 " & $axleWidth() & " ") in renderAxle(FRAMES[1].rest)
