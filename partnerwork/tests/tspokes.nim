## Test that the close drawing shows where the couple are and nothing further.
##
## The map of everything can afford to be wrong about a detail and still be
## useful.  This drawing cannot: it is the answer to "what can I do now", so a
## frame on it that is not reachable would be a claim the ontology does not make.

import std/[math, options, strutils, unittest]

import ../src/partnerwork


suite "the spokes":
  test "a frame has one spoke per move and one per compound, and no others":
    for here in FRAMES:
      var named = 0
      for target in FRAMES:
        if compound(here, target).isSome:
          inc named
      check spokesOf(here).len == moves(here).len + named

  test "every spoke arrives somewhere the ontology derives":
    for here in FRAMES:
      for spoke in spokesOf(here):
        if spoke.is_compound:
          check compound(here, spoke.to).isSome
          check route(here, spoke.to).len == 2
        else:
          check classify(here, spoke.to).isSome
        check spoke.lines.len > 0

  test "no two spokes of a frame arrive in the same place":
    for here in FRAMES:
      var seen: seq[Frame] = @[]
      var places: seq[(int, int)] = @[]
      for spoke in spokesOf(here):
        check spoke.to notin seen
        check endOf(spoke) notin places
        seen.add spoke.to
        places.add endOf(spoke)

  test "a collect points up, a drop points down, and a compound goes aside":
    # The tower is built upwards, so taking a hand climbs and letting one go
    # falls.  A screen's y grows downwards, so climbing is a negative rise.
    for here in FRAMES:
      for spoke in spokesOf(here):
        let rise = sin(spoke.angle * PI / 180)
        if spoke.is_compound:
          check abs(rise) < 0.5
        elif classify(here, spoke.to) == some(Helper.Collect):
          check rise < 0
        else:
          check rise > 0


suite "the space and the window":
  test "every frame is drawn inside the one space":
    # The space is what lets a node travel: a coordinate has to mean the same
    # place in the frame arrived at as it did in the frame left behind.
    let (bx, by, bw, bh) = SPOKES_BOX
    for here in FRAMES:
      let (x, y, w, h) = windowOf(here)
      check x >= bx
      check y >= by
      check x + w <= bx + bw
      check y + h <= by + bh

  test "a window holds the whole of the frame it is cut for":
    for here in FRAMES:
      let (x, y, w, h) = windowOf(here)
      for spoke in spokesOf(here):
        let (sx, sy) = endOf(spoke)
        check sx > x and sx < x + w
        check sy > y and sy < y + h
        let (lx, ly) = labelAt(spoke)
        check lx > x and lx < x + w
        check ly > y and ly < y + h

  test "a window is cut to its frame rather than to the widest one":
    # Every frame in one box would leave the frames with ways out one way only
    # mostly empty, which is the whole reason the window moves at all.
    var sizes: seq[(int, int)] = @[]
    for here in FRAMES:
      let (_, _, w, h) = windowOf(here)
      if (w, h) notin sizes:
        sizes.add (w, h)
    check sizes.len > 1
    for here in FRAMES:
      let (_, _, w, h) = windowOf(here)
      check w <= SPOKES_BOX[2]
      check h <= SPOKES_BOX[3]

  test "the middle is inside every window, with the drawing around it":
    for here in FRAMES:
      let (x, y, w, h) = windowOf(here)
      check MIDDLE[0] > x and MIDDLE[0] < x + w
      check MIDDLE[1] > y and MIDDLE[1] < y + h


suite "the moving":
  test "the times the drawing declares are the times the page waits on":
    let declared = closeStyle()
    for (name, time) in {"--pass-at": CLOSE_TEMPO.pass_at,
        "--pass": CLOSE_TEMPO.pass, "--fold-spread": FOLD_SPREAD,
        "--fold-lag": FOLD_LAG, "--fold-leaf": FOLD_LEAF,
        "--fold-branch": FOLD_BRANCH, "--shrink-at": SHRINK_AT,
        "--shrink": SHRINK_TIME, "--centre-at": CENTRE_AT,
        "--centre": CENTRE_TIME, "--grow-delay": GROW_DELAY,
        "--grow-spread": GROW_SPREAD, "--leaf-delay": LEAF_DELAY,
        "--grow": GROW_TIME}:
      check declared.contains(name & ": " & $time & "ms")

  test "the move is told one clause at a time, in the one order":
    # The ways not taken go first, so that what the mark does next is the only
    # thing moving; the frame left behind goes only once the mark has left it;
    # the drawing recentres only once that frame has gone.
    check CLOSE_TEMPO.pass_at >= FOLD_SPREAD + FOLD_LAG + FOLD_BRANCH
    check CLOSE_TEMPO.pass_at >= FOLD_SPREAD + FOLD_LEAF
    check SHRINK_AT >= CLOSE_TEMPO.pass_at + CLOSE_TEMPO.pass
    check CENTRE_AT >= SHRINK_AT + SHRINK_TIME
    # A leaf folds before its own branch, so a way out goes leaf first.
    check FOLD_LEAF <= FOLD_LAG + FOLD_BRANCH

  test "nothing is still moving when the drawing is replaced":
    # An animation's clock starts a frame or two after the page asks for the
    # phase, so anything timed to end exactly on time in fact ends late and is
    # cut off wherever it had got to.  That is what a seam looks like.
    check SEAM_MARGIN > 0
    check CENTRE_AT + CENTRE_TIME <= CLOSE_TEMPO.leaveTime - SEAM_MARGIN
    check CLOSE_TEMPO.moveTime > CLOSE_TEMPO.leaveTime
    check CLOSE_TEMPO.leadOnTime >= CLOSE_TEMPO.moveTime

  test "the map says a move in less time, having less to say":
    # Both drawings pass the same mark along the same move, and that is all the
    # map has to do: made to keep the close drawing's time it would stand there
    # finished, which is read as the page having stopped rather than as a move.
    check WIDE_TEMPO.leaveTime < CLOSE_TEMPO.leaveTime
    check WIDE_TEMPO.moveTime < CLOSE_TEMPO.moveTime
    # Nothing is built or torn down on the map, so the mark leaves at once and
    # nothing is left running once it lands.
    check WIDE_TEMPO.pass_at == 0
    check WIDE_TEMPO.grown == 0
    check WIDE_TEMPO.settle == SEAM_MARGIN
    # Both declare the same two times to their stylesheets, in the same words.
    check passStyle(WIDE_TEMPO).contains("--pass: ")
    check closeStyle().contains("--pass: ")

  test "a stagger is shared out, so a crowded frame still finishes on time":
    for here in FRAMES:
      let picture = renderSpokes(here)
      # The last way out is given the whole budget and no more, however many
      # ways there are: a step per way would run past the end of the phase.
      check picture.count("--turn: 0") >= 1
      if spokesOf(here).len > 1:
        check picture.contains("--turn: 1.000")

  test "every phase names itself to the stylesheet, distinctly":
    var named: seq[string] = @[]
    for moving in Motion:
      check phase(moving).len > 0
      check phase(moving) notin named
      named.add phase(moving)

  test "while leaving, the way taken is marked and every other is folding":
    for here in FRAMES:
      for spoke in spokesOf(here):
        let picture = renderSpokes(here, Motion.Leaving, some(spoke.to))
        check picture.count("spoke taken") + picture.count("spoke two taken") == 1
        check picture.count(" taken\"") == 1
        check picture.count(" going\"") == spokesOf(here).len - 1

  test "a frame standing still is neither taking nor folding":
    for here in FRAMES:
      let picture = renderSpokes(here)
      check not picture.contains(" taken\"")
      check not picture.contains(" going\"")

  test "every leaf is grown from the place it occupies":
    for here in FRAMES:
      let picture = renderSpokes(here)
      for spoke in spokesOf(here):
        let (x, y) = endOf(spoke)
        check picture.contains("--lx: " & $x & "px; --ly: " & $y & "px")
      # A branch grows from the middle, and the middle is one place for them all.
      check picture.count("--ox: ") == 1

  test "a move ends on the very drawing the frame reached is given at rest":
    # This is the whole of why the swap cannot be seen.  What the leaving drawing
    # recentres on has to be, to the pixel, what the frame reached is drawn as
    # when it is standing still: same window, same place on the screen.
    for here in FRAMES:
      for spoke in spokesOf(here):
        let
          leaving = renderSpokes(here, Motion.Leaving, some(spoke.to))
          resting = renderSpokes(spoke.to)
          (_, _, tw, th) = windowOf(spoke.to)
          (tx, ty) = panOf(windowOf(spoke.to))
          (ex, ey) = endOf(spoke)
        # The window it ends in is the window the frame reached is given.
        check leaving.contains("--to-w: " & $tw & "px; --to-h: " & $th & "px")
        check resting.contains("--w: " & $tw & "px; --h: " & $th & "px")
        # And it ends panned so that the frame reached, which is standing out
        # where its way out put it, is left exactly where the middle will be.
        check leaving.contains("--to-px: " & $(tx + MIDDLE[0] - ex) &
          "px; --to-py: " & $(ty + MIDDLE[1] - ey) & "px")
        check resting.contains("--px: " & $tx & "px; --py: " & $ty & "px")

  test "the mark carries the distance from the frame held to the one chosen":
    for here in FRAMES:
      for spoke in spokesOf(here):
        let
          picture = renderSpokes(here, Motion.Leaving, some(spoke.to))
          (ex, ey) = endOf(spoke)
        check picture.contains("--mx: " & $(ex - MIDDLE[0]) & "px; --my: " &
          $(ey - MIDDLE[1]) & "px")
    # Standing still it goes nowhere.
    check renderSpokes(FRAMES[0]).contains("--mx: 0px; --my: 0px")


suite "the drawing":
  test "only the frame held and the frames it reaches are drawn":
    for here in FRAMES:
      let picture = renderSpokes(here)
      for target in FRAMES:
        let drawn = picture.contains("data-frame=\"" & target.key & "\"")
        let reachable = target == here or classify(here, target).isSome or
          compound(here, target).isSome
        check drawn == reachable

  test "the frame held is the one in the middle":
    for here in FRAMES:
      let picture = renderSpokes(here)
      # Drawn at the middle of the space, whatever window that frame is seen
      # through: the window moves, the middle does not.
      check picture.contains("<g class=\"core\"><g class=\"node held\" " &
        "data-frame=\"" & here.key & "\">")

  test "one frame is marked, and it is the frame being held":
    for here in FRAMES:
      let picture = renderSpokes(here)
      check picture.count("class=\"mark\"") == 1
      check picture.count("class=\"core\"") == 1
