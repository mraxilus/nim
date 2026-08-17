## Test the picture of the whole ontology against the ontology.
##
## The map is a drawing, so most of it is a matter of taste; what is tested is
## that it is a drawing of *this* model, with every frame in it once, every move
## on it once, and nothing on it that the model does not derive.

{.experimental: "strictFuncs".}

import std/[options, strutils, unittest]

import ../src/partnerwork


func spoken(picture: string): string =
  ## Take the ink back out of a drawing, leaving only the words it says.
  ##   A name is drawn in the hands it names, so `drop left` is three elements
  ##     and not one, and a test that asks what a label *says* would otherwise
  ##     be asking how it is coloured as well.
  ##   How it is coloured is its own test, below.
  result = picture
  while true:
    let at = result.find("<tspan")
    if at < 0:
      break
    result = result[0 ..< at] & result[result.find('>', at) + 1 .. ^1]
  result = result.replace("</tspan>", "")


func attr(chunk, name: string): int =
  ## Read one number out of a drawn element, for measuring what was drawn.
  let key = name & "=\""
  let at = chunk.find(key)
  if at < 0:
    return 0
  let rest = chunk[at + key.len .. ^1]
  parseInt(rest[0 ..< rest.find('"')])


suite "the layout":
  test "the drawing order names every frame exactly once":
    check NODE_ORDER.len == FRAMES.len
    var seen: seq[Frame] = @[]
    for key in NODE_ORDER:
      let target = fromKey(key)
      check target.isSome
      check target.get notin seen
      seen.add target.get
    for target in FRAMES:
      check target in seen

  test "no two frames are drawn in the same place":
    var places: seq[(int, int)] = @[]
    for target in FRAMES:
      let centre = centreOf(target)
      check centre notin places
      check centre[0] > 0 and centre[0] < MAP_WIDTH
      check centre[1] > 0 and centre[1] < MAP_HEIGHT
      places.add centre

  test "frames with the same number of connections share a row":
    for a in FRAMES:
      for b in FRAMES:
        check (centreOf(a)[1] == centreOf(b)[1]) == (a.countHolds == b.countHolds)

  test "a move always runs up the page, from fewer connections to more":
    # Which is the whole of what the rows buy: a reader who knows which way is
    # up knows which primitive a line is without reading its name.
    for source in FRAMES:
      for move in moves(source):
        let rising = move.helper == Helper.Collect
        check (centreOf(move.to)[1] < centreOf(source)[1]) == rising

  test "free is at the foot of the tower and the fullest frames at its head":
    for target in FRAMES:
      for other in FRAMES:
        if target.countHolds < other.countHolds:
          check centreOf(target)[1] > centreOf(other)[1]

  test "the order the tower stacks the frames is the order it draws them in":
    # Anything that puts the frames in a line -- the matrix orders both its axes
    # this way -- takes the order from here, so it cannot drift from the drawing
    # and leave the two saying opposite things about which way the ladder runs.
    let order = towerOrder()
    check order.len == FRAMES.len
    for target in FRAMES:
      check target in order
    for index in 1 ..< order.len:
      check centreOf(order[index - 1])[1] <= centreOf(order[index])[1]


suite "the drawing":
  test "every move is one line and every compound is one curve":
    let picture = renderMap(none(Frame))
    var moved, joined = 0
    for source in FRAMES:
      moved += moves(source).len
      for target in FRAMES:
        if compound(source, target).isSome:
          inc joined
    # Each line stands for the pair of moves that cross it.  A curve stands for
    # a pair too, but is drawn in halves, because the two moves it stands for
    # are led by different arms and each half is inked for its own.
    check picture.count("<line class=\"edge") == moved div 2
    check picture.count("<path class=\"arc") == joined
    # One group of ink and one of words for each, wearing the same marks, so
    # that dimming and lighting still take them as one thing.
    check picture.count("<g class=\"join\"") + picture.count("<g class=\"join ") -
      picture.count("<g class=\"join naming") == joined div 2
    check picture.count("<g class=\"join naming") == joined div 2
    check picture.count("<g class=\"way naming") == moved div 2

  test "every line is drawn before any name is written":
    # A name carries a plate to keep the drawing out from under it, and a plate
    # can only hide what is already there.  Written as each line was drawn, a
    # name was struck through by the next line to cross it, which is a wrong
    # drawing rather than an ugly one: the reader is told the wrong move.
    for standing in FRAMES:
      let picture = renderMap(some(standing))
      var last_ink = 0
      for mark in ["<line class=\"edge", "<path class=\"arc"]:
        last_ink = max(last_ink, picture.rfind(mark))
      var first_name = picture.len
      for mark in ["<g class=\"way naming", "<g class=\"join naming"]:
        first_name = min(first_name, picture.find(mark))
      check last_ink < first_name

  test "every frame is drawn, with its name":
    let picture = renderMap(none(Frame))
    for target in FRAMES:
      check picture.contains("data-frame=\"" & target.key & "\"")
      check picture.contains(">" & target.describe & "<")

  test "a map with nobody on it has no marker and lights nothing":
    let picture = renderMap(none(Frame))
    check not picture.contains("class=\"mark\"")
    check not picture.contains(" lit")
    check not picture.contains("reachable")

  test "one frame is marked, and the mark is the same ring the close drawing uses":
    for here in FRAMES:
      let picture = renderMap(some(here))
      check picture.count("class=\"mark\"") == 1
      # Both drawings ring the frame held from the same numbers, so that the two
      # say *here* the same way and neither says it twice.
      check picture.contains(markAt(centreOf(here)[0], centreOf(here)[1],
        NODE_WIDTH, " style=\"--mx: 0px; --my: 0px\""))
      check renderSpokes(here).count("class=\"mark\"") == 1

  test "the marker stands on the frame held and carries the way to the next":
    for here in FRAMES:
      # Standing still it goes nowhere; taking a move, it carries exactly the
      # distance along the line to the frame chosen, which is the move itself.
      check renderMap(some(here)).contains("--mx: 0px; --my: 0px")
      for move in moves(here):
        let picture = renderMap(some(here), Motion.Leaving, some(move.to))
        check picture.contains("--mx: " & $(centreOf(move.to)[0] -
          centreOf(here)[0]) & "px; --my: " & $(centreOf(move.to)[1] -
          centreOf(here)[1]) & "px")

  test "only the frames one move away are offered":
    for here in FRAMES:
      let picture = renderMap(some(here))
      check picture.count("reachable") == moves(here).len

  test "a frame a compound away is offered, and marked as two moves":
    for here in FRAMES:
      var named = 0
      for target in FRAMES:
        if compound(here, target).isSome:
          inc named
      check renderMap(some(here)).count(" two\"") == named

  test "every line is named, and no name is drawn over anything else":
    # Naming only the lines underfoot let the rest of the map go unread, and
    # meant the names moved about every time the couple did.  Naming all of them
    # is only useful if they can all be read at once, so the drawing places each
    # one itself and this holds it to having found room.
    var moved, joined = 0
    for source in FRAMES:
      moved += moves(source).len
      for target in FRAMES:
        if compound(source, target).isSome:
          inc joined
    # In every state, not just the unread map: a name is read from where the
    # couple stand, so the words change as they dance and the room they need
    # changes with them.
    var wheres = @[none(Frame)]
    for here in FRAMES:
      wheres.add some(here)
    for where in wheres:
      let picture = renderMap(where)
      var boxes: seq[Box] = @[]
      for chunk in picture.split("<rect class=\""):
        if not (chunk.startsWith("edge-plate") or chunk.startsWith("arc-plate")):
          continue
        let own = chunk[0 ..< chunk.find("/>")]
        boxes.add (own.attr("x"), own.attr("y"), own.attr("width"),
          own.attr("height"))
      check boxes.len == moved div 2 + joined div 2
      for index, box in boxes:
        for other in boxes[index + 1 .. ^1]:
          check not overlaps(box, other)
        for frame in frameBoxes():
          check not overlaps(box, frame)

  test "a line is named for the move away from where the couple stand":
    # A line is two moves, one each way.  Named for the collect either way, a
    # line leaving the frame held upwards would be labelled with the move that
    # comes back down it -- the one thing the reader cannot do from there.
    for here in FRAMES:
      let picture = renderMap(some(here))
      for move in moves(here):
        let naming = label(here, Move(helper: move.helper, side: move.side,
          to: move.to))
        for line in naming:
          check picture.spoken.contains(">" & line & "<")
      # And a drop names the hand it lets go of, as a collect names the hand it
      # takes.  It used to read a bare `drop`, which left the reader to work out
      # what was being released from the ink the word was written in.
      var drops = 0
      for move in moves(here):
        if move.helper != Helper.Drop:
          continue
        inc drops
        check picture.spoken.contains(
          ">drop " & followName(here.hold[move.side].get) & "<")
      check not picture.contains(">drop<")
      if here.countHolds > 0:
        check drops > 0

  test "a compound underfoot names the hand it moves, and one nobody stands on may not":
    # Stood on one end a curve has a direction like any other line.  Stood on
    # neither, a cut carries whichever hand ends up on top -- the other one going
    # the other way -- so naming one of them would be wrong half the time.
    let idle = renderMap(none(Frame))
    check idle.contains(">cut<")
    for here in FRAMES:
      for target in FRAMES:
        if compound(here, target).isNone:
          continue
        let picture = renderMap(some(here))
        check picture.spoken.contains(">" & compoundName(here, target) & "<")

  test "a compound is inked in both the arms it hands a hand between":
    # An ordinary line has one ink because the same arm acts whichever way it is
    # read.  A compound has two, and which one you see depends on which end you
    # are reading from, because that is what a compound is.
    let picture = renderMap(none(Frame))
    for a in FRAMES:
      for b in FRAMES:
        if compound(a, b).isNone or frameIndex(a).get > frameIndex(b).get:
          continue
        let
          near = compoundSide(b, a)
          far = compoundSide(a, b)
        check near.isSome and far.isSome
        check near.get != far.get
        # Both inks are on the drawing, and neither is the quiet ink that would
        # say the line belongs to no arm at all.
        for side in [near.get, far.get]:
          let ink = (if side == Side.Left: "var(--left" else: "var(--right")
          check picture.contains("class=\"arc\" d=\"M") and picture.contains(ink)

  test "every frame's name has a plate to keep the lines off it":
    # Lines leave a frame from its middle, so they run out through the words
    # above it.  Every other name in the drawing has a plate; so does this one.
    let picture = renderMap(none(Frame))
    check picture.count("class=\"name-plate\"") == FRAMES.len
    check renderSpokes(FRAMES[0]).count("class=\"name-plate\"") ==
      spokesOf(FRAMES[0]).len + 1
    for here in FRAMES:
      let (x, y, w, h) = nameBox(here, centreOf(here)[0], centreOf(here)[1], 74)
      check picture.contains("class=\"name-plate\" x=\"" & $x & "\" y=\"" & $y &
        "\" width=\"" & $w & "\" height=\"" & $h & "\"")

  test "the ink of a line is the acting arm, in the lead's own shade":
    # Once a line is unlit the two arms are told apart by colour alone, so every
    # line has to carry an arm's ink and not the quiet ink of the background.
    # And the *deep* shade of it: a line is the lead acting, and deep is theirs
    # wherever the two dancers are told apart.
    #   Checked for the deep shade by name rather than by the hue alone, which
    #   is how the plain one went unnoticed here for as long as it did:
    #   `var(--left` matches `var(--left-deep` just as happily.
    let picture = renderMap(none(Frame))
    var lines = 0
    for fragment in picture.split("<line class=\"edge"):
      if not fragment.startsWith("\"") and not fragment.startsWith(" lit"):
        continue
      inc lines
      let element = fragment[0 ..< fragment.find("/>")]
      check element.contains("var(--left-deep") or
        element.contains("var(--right-deep")
      check not element.contains("var(--left,")
      check not element.contains("var(--right,")
    var moved = 0
    for source in FRAMES:
      moved += moves(source).len
    check lines == moved div 2

  test "a name says the follow's hand in the follow's own ink":
    # A label is the lead acting, so the whole of it used to be the lead's deep
    # shade -- including the word for the hand being taken, which is the
    # *follow's*.  The picture beside it draws that connection deep running into
    # plain, and the words now say it the same way.
    #   The word alone is wrapped, and the space before it left outside, so the
    #   line still reads as one sentence rather than as a row of chips.
    var named_hands = 0
    for here in FRAMES:
      let picture = renderMap(some(here))
      for move in moves(here):
        let hand = case move.helper
                   of Helper.Collect: move.to.hold[move.side]
                   of Helper.Drop: here.hold[move.side]
        if hand.isNone:
          continue
        inc named_hands
        check picture.contains("<tspan style=\"fill: " &
          followColour(hand.get) & "\">" & followName(hand.get) & "</tspan>")
        # The follow's plain shade, never the lead's deep one.
        check not picture.contains("<tspan style=\"fill: " &
          armColour(move.side) & "\">" & followName(hand.get) & "</tspan>")
    check named_hands > 0
