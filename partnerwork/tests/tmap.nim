## Test the picture of the whole ontology against the ontology.
##
## The map is a drawing, so most of it is a matter of taste; what is tested is
## that it is a drawing of *this* model, with every frame in it once, every move
## on it once, and nothing on it that the model does not derive.

import std/[options, strutils, unittest]

import ../src/partnerwork


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
    let picture = renderMap(none(Frame), none(Frame))
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
    let picture = renderMap(none(Frame), none(Frame))
    for target in FRAMES:
      check picture.contains("data-frame=\"" & target.key & "\"")
      check picture.contains(">" & target.describe & "<")

  test "a map with nobody on it has no marker and lights nothing":
    let picture = renderMap(none(Frame), none(Frame))
    check not picture.contains("id=\"here\"")
    check not picture.contains(" lit")
    check not picture.contains("reachable")

  test "the marker starts where the couple were and carries where they are":
    let
      before = fromKey("r-.").get
      here = fromKey("--.").get
      picture = renderMap(some(here), some(before))
    check picture.contains("translate(" & $centreOf(before)[0] & "," &
      $centreOf(before)[1] & ")")
    check picture.contains("data-x=\"" & $centreOf(here)[0] & "\"")
    check picture.contains("data-y=\"" & $centreOf(here)[1] & "\"")

  test "only the frames one move away are offered":
    for here in FRAMES:
      let picture = renderMap(some(here), some(here))
      check picture.count("reachable") == moves(here).len
