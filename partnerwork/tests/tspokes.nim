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
