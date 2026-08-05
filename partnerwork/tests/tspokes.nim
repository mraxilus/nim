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

  test "a drop points up, a collect points down, and a compound goes aside":
    for here in FRAMES:
      for spoke in spokesOf(here):
        let rise = sin(spoke.angle * PI / 180)
        if spoke.is_compound:
          check abs(rise) < 0.5
        elif classify(here, spoke.to) == some(Helper.Drop):
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
    let declared = motionStyle()
    for (name, time) in {"--fold-spread": FOLD_SPREAD, "--fold-lag": FOLD_LAG,
        "--fold-leaf": FOLD_LEAF, "--fold-branch": FOLD_BRANCH,
        "--travel": TRAVEL_TIME, "--grow-delay": GROW_DELAY,
        "--grow-spread": GROW_SPREAD, "--leaf-delay": LEAF_DELAY,
        "--grow": GROW_TIME, "--fold-margin": FOLD_MARGIN}:
      check declared.contains(name & ": " & $time & "ms")
    check LEAD_ON_TIME > LEAVE_TIME
    check MOVE_TIME >= LEAD_ON_TIME

  test "nothing is still folding when the drawing is thrown away":
    # The page replaces the drawing at LEAVE_TIME.  A fold still running then is
    # cut off mid-flight, which reads as a flash rather than as a fold, so every
    # fold has to have finished by the time that happens.
    # With room to spare, because an animation's clock starts a frame or two
    # after the page asks for the phase: ending exactly on time ends late.
    check FOLD_MARGIN > 0
    check FOLD_SPREAD + FOLD_LEAF <= LEAVE_TIME - FOLD_MARGIN
    check FOLD_SPREAD + FOLD_LAG + FOLD_BRANCH <= LEAVE_TIME - FOLD_MARGIN
    # A leaf folds before its own branch, so a way out goes leaf first.
    check FOLD_LEAF <= FOLD_LAG + FOLD_BRANCH

  test "a stagger is shared out, so a crowded frame still finishes on time":
    for here in FRAMES:
      let picture = renderSpokes(here, here)
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
        let picture = renderSpokes(here, here, Motion.Leaving, some(spoke.to))
        check picture.count("spoke taken") + picture.count("spoke two taken") == 1
        check picture.count(" taken\"") == 1
        check picture.count(" going\"") == spokesOf(here).len - 1

  test "a frame standing still is neither taking nor folding":
    for here in FRAMES:
      let picture = renderSpokes(here, here)
      check not picture.contains(" taken\"")
      check not picture.contains(" going\"")

  test "every leaf is grown from the place it occupies":
    for here in FRAMES:
      let picture = renderSpokes(here, here)
      for spoke in spokesOf(here):
        let (x, y) = endOf(spoke)
        check picture.contains("--lx: " & $x & "px; --ly: " & $y & "px")
      # A branch grows from the middle, and the middle is one place for them all.
      check picture.count("--ox: ") == 1

  test "an arriving frame is drawn in the window it is leaving":
    for before in FRAMES:
      for spoke in spokesOf(before):
        let
          picture = renderSpokes(spoke.to, before, Motion.Arriving)
          (_, _, w, h) = windowOf(before)
          (_, _, tw, th) = windowOf(spoke.to)
        # Drawn where the reader can already see it, carrying where it is going:
        # the window and the frame in flight then set off together.
        let
          (px, py) = panOf(windowOf(before))
          (tx, ty) = panOf(windowOf(spoke.to))
        check picture.contains("--w: " & $w & "px; --h: " & $h & "px; --px: " &
          $px & "px; --py: " & $py & "px")
        check picture.contains("data-w=\"" & $tw & "\" data-h=\"" & $th &
          "\" data-px=\"" & $tx & "\" data-py=\"" & $ty & "\"")


suite "the drawing":
  test "only the frame held and the frames it reaches are drawn":
    for here in FRAMES:
      let picture = renderSpokes(here, here)
      for target in FRAMES:
        let drawn = picture.contains("data-frame=\"" & target.key & "\"")
        let reachable = target == here or classify(here, target).isSome or
          compound(here, target).isSome
        check drawn == reachable

  test "the frame held is the one in the middle, and it can travel":
    for here in FRAMES:
      check renderSpokes(here, here).contains("id=\"core\"")
      check renderSpokes(here, here).contains("translate(0,0)")

  test "a frame arrived at travels from where it was drawn to the one middle":
    var middle: seq[(int, int)] = @[]
    for before in FRAMES:
      for spoke in spokesOf(before):
        let
          (x, y) = endOf(spoke)
          (dx, dy) = offsetOf(spoke.to, before)
        # Taking away the travel from where the frame was drawn has to land on
        # the middle, and the middle is the same wherever the couple came from.
        if middle.len == 0:
          middle.add (x - dx, y - dy)
        check (x - dx, y - dy) == middle[0]
        check dx != 0 or dy != 0
        check renderSpokes(spoke.to, before).contains(
          "translate(" & $dx & "," & $dy & ")")

  test "a frame nobody moved from does not travel":
    for here in FRAMES:
      check offsetOf(here, here) == (0, 0)
