## Print the derived ontology and its disagreements with the workbook.
##
## This is the reading tool for the model: the frame list, the transition matrix
## and the audit, in the terms the workbook uses, so the two can be compared by
## eye as well as by test.

import std/[options, strutils]

import ../src/partnerwork


proc printFrames(convention: Convention) =
  ## List the frames one idiom admits, with their names and move counts.
  echo "frames admitted by ", convention, ":"
  for target in convention.admitted:
    let known = if workbookName(target).isSome: "  " else: "* "
    echo "  ", known, target.key, "  ", target.title.alignLeft(34),
      target.describe.alignLeft(38), $moves(target, convention).len, " moves"
  echo "  (* marks a frame the workbook has no row for)"


proc printMatrix(convention: Convention) =
  ## Print every derived move, grouped by the frame it starts from.
  echo "\nderived transitions (", convention, "):"
  for source in convention.admitted:
    echo "  from ", source.title, "  [", source.key, "]"
    for move in moves(source, convention):
      let cell = cellText(
        workbookName(source).get(""), workbookName(move.to).get(""))
      let mark = if cell.isSome: "  " else: "* "
      echo "    ", mark, ($move.helper).alignLeft(9), move.to.title.alignLeft(36),
        phrase(source, move)


proc printAudit(convention: Convention) =
  ## Report the workbook's disagreements with the model, grouped by kind.
  let findings = audit(convention)
  echo "\naudit of the base sheet against the model (", findings.len, " findings):"
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
  printFrames(Convention.Salsa)
  printMatrix(Convention.Salsa)
  printAudit(Convention.Salsa)
  echo "\nframes the physics allows beyond the idiom:"
  for target in Convention.Physical.admitted:
    if not Convention.Salsa.admits(target):
      echo "  ", target.key, "  ", target.describe
