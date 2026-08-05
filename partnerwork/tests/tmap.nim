## Test the picture of the whole ontology against the ontology.
##
## The map is a drawing, so most of it is a matter of taste; what is tested is
## that it is a drawing of *this* model, with every frame in it once, every move
## on it once, and nothing on it that the model does not derive.

import std/[options, strutils, unittest]

import ../src/partnerwork


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

  test "a move always runs down the page, from fewer connections to more":
    for source in FRAMES:
      for move in moves(source):
        let rising = move.helper == Helper.Collect
        check (centreOf(move.to)[1] > centreOf(source)[1]) == rising


suite "the drawing":
  test "every move is one line and every compound is one curve":
    let picture = renderMap(none(Frame))
    var moved, joined = 0
    for source in FRAMES:
      moved += moves(source).len
      for target in FRAMES:
        if compound(source, target).isSome:
          inc joined
    # Each line and each curve stands for the pair of moves that cross it.
    check picture.count("<line class=\"edge") == moved div 2
    check picture.count("<path class=\"arc") == joined div 2

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
    let picture = renderMap(none(Frame))
    var moved, joined = 0
    for source in FRAMES:
      moved += moves(source).len
      for target in FRAMES:
        if compound(source, target).isSome:
          inc joined
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

  test "the ink of a line is the arm that acts, whichever way it is read":
    # Once a line is unlit the two arms are told apart by colour alone, so every
    # line has to carry an arm's ink and not the quiet ink of the background.
    let picture = renderMap(none(Frame))
    var lines = 0
    for fragment in picture.split("<line class=\"edge"):
      if not fragment.startsWith("\"") and not fragment.startsWith(" lit"):
        continue
      inc lines
      let element = fragment[0 ..< fragment.find("/>")]
      check element.contains("var(--left") or element.contains("var(--right")
    var moved = 0
    for source in FRAMES:
      moved += moves(source).len
    check lines == moved div 2
