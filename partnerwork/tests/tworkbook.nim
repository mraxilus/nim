## Test the model against the workbook it was read from.
##
## The workbook is an independent reference: it was written by hand, before the
## model existed.  Every filled cell of the `base` sheet must agree with the
## primitive the model derives for the same pair of frames, and the places where
## the two disagree are pinned here so that a change to either is visible.

import std/[options, unittest]

import ../src/partnerwork


suite "the transcription":
  test "every workbook state reads as one distinct valid frame":
    var seen: seq[Frame] = @[]
    for name in WORKBOOK_STATES:
      let target = workbookFrame(name)
      check target.isSome
      check target.get.isValid
      check target.get notin seen
      check workbookName(target.get) == some(name)
      seen.add target.get
    check workbookFrame("shine").isNone

  test "the body-contact states are the only reading the matrix allows":
    # `closed` slides to `Left-to-right and Right-to-left` and `half-closed`
    # slides to `Right to left`; a hand can only travel down the arm it already
    # touches, so in both the lead's right hand must start on the follow's torso.
    check workbookFrame("closed").get.hold[Side.Right] == some(Site.Torso)
    check workbookFrame("half-closed").get.hold[Side.Right] == some(Site.Torso)
    check classify(workbookFrame("closed").get,
      workbookFrame("Left-to-right and Right-to-left").get) == some(Helper.Trace)
    check classify(workbookFrame("half-closed").get,
      workbookFrame("Right to left").get) == some(Helper.Trace)

  test "every cell names a known pair of states, once":
    check CELLS.len == 27
    for index, cell in CELLS:
      check workbookFrame(cell.source).isSome
      check workbookFrame(cell.destination).isSome
      check cell.source != cell.destination
      check cellText(cell.source, cell.destination) == some(cell.text)
      for other in CELLS[index + 1 .. ^1]:
        check not (other.source == cell.source and
          other.destination == cell.destination)

  test "the helper words of the ontology are read, including its synonyms":
    check readHelper("collect") == some(Helper.Collect)
    check readHelper("drop") == readHelper("flick")
    check readHelper("slide") == readHelper("trace")
    check readHelper("pass") == readHelper("place")
    check readHelper(" cut ") == some(Helper.Cut)
    check readHelper("dip").isNone
    check readCell("place, drop, collect").len == 3


suite "the audit":
  test "every single-helper cell agrees with the derived primitive":
    var checked = 0
    for cell in CELLS:
      let words = readCell(cell.text)
      if words.len != 1:
        continue
      inc checked
      let derived = classify(
        workbookFrame(cell.source).get, workbookFrame(cell.destination).get)
      check derived.isSome
      check derived == readHelper(words[0])
    check checked == 25

  test "no cell of the workbook is unsupported or misnamed":
    for finding in audit(Convention.Salsa):
      check finding.kind notin
        {FindingKind.EdgeUnsupported, FindingKind.HelperDiffers}

  test "the disagreements are the five that are known":
    var counted: array[FindingKind, int]
    for finding in audit(Convention.Salsa):
      inc counted[finding.kind]
    check counted[FindingKind.FrameAbsent] == 2    # open, and Left-to-left with
                                                   # the right hand on the torso.
    check counted[FindingKind.ReverseAbsent] == 1  # Right to left -> half-closed.
    check counted[FindingKind.EdgeCompound] == 2   # Cells naming a route.
    check counted[FindingKind.EdgeAbsent] == 0
    check counted[FindingKind.EdgeUnsupported] == 0
    check counted[FindingKind.HelperDiffers] == 0

  test "the frames the workbook is missing carry moves the workbook cannot say":
    for finding in audit(Convention.Salsa):
      if finding.kind != FindingKind.FrameAbsent:
        continue
      check finding.subject in ["open", "Left-to-left and Right-to-torso"]

  test "the compound cells are routes of the length the cell writes out":
    for cell in CELLS:
      let words = readCell(cell.text)
      if words.len < 2:
        continue
      let steps = route(workbookFrame(cell.source).get,
        workbookFrame(cell.destination).get, Convention.Salsa)
      check steps.len == words.len
