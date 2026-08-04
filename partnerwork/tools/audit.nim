## Print the derived ontology and everything it has to say about the workbook.
##
## This is the reading tool for the model: the frame list, the transition matrix
## and the audit, in the terms the workbook uses, so the two can be compared by
## eye as well as by test.

import std/[options, strutils]

import ../src/partnerwork


proc printFrames() =
  ## List every frame, with its name and the number of moves it carries.
  echo "frames (", FRAMES.len, "):"
  for target in FRAMES:
    let known = if workbookName(target).isSome: "  " else: "* "
    echo "  ", known, target.key, "  ", target.describe.alignLeft(38),
      $moves(target).len, " moves"
  echo "  (* marks a frame the workbook has no row for)"


proc printMatrix() =
  ## Print every derived move, grouped by the frame it starts from.
  echo "\nderived transitions, with the compounds beneath the moves:"
  for source in FRAMES:
    echo "  from ", source.describe, "  [", source.key, "]"
    for move in moves(source):
      let cell = cellText(workbookName(source).get(""), workbookName(move.to).get(""))
      let mark = if cell.isSome: "  " else: "* "
      echo "    ", mark, move.helper.name.alignLeft(9),
        move.to.describe.alignLeft(36), phrase(source, move)
    for target in FRAMES:
      let named = compound(source, target)
      if named.isNone:
        continue
      let cell = cellText(workbookName(source).get(""), workbookName(target).get(""))
      let mark = if cell.isSome: "  " else: "* "
      echo "    ", mark, ($named.get).toLowerAscii.alignLeft(9),
        target.describe.alignLeft(36), compoundPhrase(source, target)


proc printAudit() =
  ## Report what the model says about the workbook, grouped by kind.
  let findings = audit()
  echo "\naudit of the base sheet (", findings.len, " findings, ",
    CELLS.len - countDeferredCells(), " of ", CELLS.len, " cells checkable):"
  for kind in FindingKind:
    var shown = false
    for finding in findings:
      if finding.kind != kind:
        continue
      if not shown:
        echo "\n  ", kind, ":"
        shown = true
      echo "    ", finding.subject
      echo "      ", finding.detail


when isMainModule:
  printFrames()
  printMatrix()
  printAudit()
