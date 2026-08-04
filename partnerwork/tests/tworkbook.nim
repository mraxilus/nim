## Test the model against the workbook it was read from.
##
## The workbook is an independent reference: it was written by hand, before the
## model existed.  Every filled cell of the `base` sheet that holds between two
## hand-to-hand frames must agree with the primitive the model derives for the
## same pair, and the cells that wait for a place on the body are pinned here so
## that the size of what is deferred stays visible.

import std/[options, unittest]

import ../src/partnerwork


suite "the transcription":
  test "every hand-to-hand state reads as one distinct valid frame":
    var seen: seq[Frame] = @[]
    for name in WORKBOOK_STATES:
      if name.isDeferred:
        check workbookFrame(name).isNone
        continue
      let target = workbookFrame(name)
      check target.isSome
      check target.get.isValid
      check target.get notin seen
      check workbookName(target.get) == some(name)
      seen.add target.get
    check seen.len == 7
    check workbookFrame("shine").isNone

  test "the two deferred states are the ones that rest on the body":
    check DEFERRED_STATES == ["closed", "half-closed"]
    check countDeferredCells() == 9
    check CELLS.len - countDeferredCells() == 18

  test "every cell names a known pair of states, once":
    check CELLS.len == 27
    for index, cell in CELLS:
      check cell.source in WORKBOOK_STATES
      check cell.destination in WORKBOOK_STATES
      check cell.source != cell.destination
      check cellText(cell.source, cell.destination) == some(cell.text)
      for other in CELLS[index + 1 .. ^1]:
        check not (other.source == cell.source and
          other.destination == cell.destination)

  test "every cell naming a slide reaches a deferred state":
    # A slide travels along the body, so it needs a place on the body to reach.
    for cell in CELLS:
      if "slide" notin readCell(cell.text):
        continue
      check cell.source.isDeferred or cell.destination.isDeferred

  test "the helper words of the ontology are read, including its synonyms":
    check readHelper("collect") == some(Helper.Collect)
    check readHelper("drop") == readHelper("flick")
    check readHelper("pass") == readHelper("place")
    check readHelper(" cut ") == some(Helper.Cut)
    check readHelper("slide").isNone
    check readHelper("dip").isNone
    check readCell("place, drop, collect").len == 3


suite "the audit":
  test "every checkable cell is exactly the primitive the model derives":
    var checked = 0
    for cell in CELLS:
      if cell.source.isDeferred or cell.destination.isDeferred:
        continue
      inc checked
      let derived = classify(
        workbookFrame(cell.source).get, workbookFrame(cell.destination).get)
      check derived.isSome
      check derived == readHelper(cell.text)
    check checked == 18

  test "the checkable cells are every move between the states they name":
    var derived = 0
    for source in WORKBOOK_STATES:
      for destination in WORKBOOK_STATES:
        if source.isDeferred or destination.isDeferred:
          continue
        if classify(workbookFrame(source).get,
            workbookFrame(destination).get).isSome:
          inc derived
    check derived == 18

  test "nothing in the hand-to-hand part of the sheet disagrees":
    for finding in audit():
      check finding.kind notin {
        FindingKind.EdgeAbsent,
        FindingKind.ReverseAbsent,
        FindingKind.EdgeCompound,
        FindingKind.HelperDiffers,
        FindingKind.EdgeUnsupported,
      }

  test "what is left is two deferred states and one missing frame":
    var counted: array[FindingKind, int]
    for finding in audit():
      inc counted[finding.kind]
    check counted[FindingKind.StateDeferred] == 2
    check counted[FindingKind.FrameAbsent] == 1
    check audit().len == 3

  test "the missing frame is the one where nobody is holding on":
    for finding in audit():
      if finding.kind != FindingKind.FrameAbsent:
        continue
      check finding.subject == "open"
