## Write the review page and the frame pictures from the model.
##
##   The page used to carry its own copy of the frames and the transitions,
##     transcribed by hand from the audit.  Nothing kept that copy honest,
##     which made it the one part of the work that could quietly go wrong.
##   Now the prose lives in `doc/review.template.html` with a marker wherever a
##     number or a picture belongs, and everything a marker stands for is
##     derived here.
##     Cost of a template with markers: a marker is text the compiler never
##       sees, so a misspelt or unfilled one is caught by the generation-time
##       quit in `renderReview` rather than by a compile error.
##   `tests/treview.nim` regenerates the page and compares it with the
##     committed one, so a model change that has not been written up fails the
##     suite.
##     Cost of committing the generated page: every model change must re-run
##       `nimble review`, or the suite fails on the stale copy.

{.experimental: "strictFuncs".}

import std/[options, os, strutils]

import ../src/partnerwork


const
  TEMPLATE_PATH* = "doc/review.template.html"
    ## The prose the page is filled into; `treview` reads it too.
  PAGE_PATH* = "doc/review.html"
    ## The committed page, which `treview` holds to being regenerable.
  FRAME_DIRECTORY* = "doc/frames"
    ## One SVG per frame, for anything that is not HTML.
  DISAGREEMENTS = {
    FindingKind.EdgeAbsent,
    FindingKind.ReverseAbsent,
    FindingKind.EdgeCompound,
    FindingKind.HelperDiffers,
    FindingKind.EdgeUnsupported,
  } ## Name the finding kinds that mean the workbook and the model differ.



#[ Counting ]#

func countMoves(): int =
  ## Count the moves in the whole ontology.
  for source in FRAMES:
    result += moves(source).len


func countDisagreements(): int =
  ## Count the findings that say the workbook and the model differ.
  for finding in audit():
    if finding.kind in DISAGREEMENTS:
      inc result


func longestRoute(): int =
  ## Get the most moves any frame is from any other.
  for source in FRAMES:
    for destination in FRAMES:
      result = max(result, route(source, destination).len)


func countNamedStates(): int =
  ## Count the workbook states the hand-to-hand model can check.
  for name in WORKBOOK_STATES:
    if not name.isDeferred:
      inc result


proc countLaws(): int =
  ## Count the tests, by reading the suite rather than remembering a number.
  var paths: seq[string] = @[]
  for path in walkFiles("tests/t*.nim"):
    paths.add path
  for path in paths:
    for line in readFile(path).splitLines:
      if line.strip().startsWith("test \""):
        inc result



#[ Fragments ]#

func escape(text: string): string =
  ## Escape text for placement in markup.
  ##   Looser than the app's `esc`: nothing here writes user text into
  ##     an attribute, so quotes pass through.
  text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))


func inked(said: string; escaping = true): string =
  ## Say a name with each hand it names written in that dancer's own ink.
  ##   The page's drawings ink their words this way, and a name in the prose
  ##     beside them is the same name; a reader who has learnt the two shades
  ##     from the map should not have to learn them again from the gallery.
  ##   The third renderer of the one reading, after the drawings' `labelled`
  ##     and the app's own: the reading is shared and the markup is not,
  ##     because `<tspan>` and `<span>` are not the same element.
  ##   `escaping` is off for words already lifted out of the page, which are
  ##     markup-ready and would be escaped a second time.
  for run in named(said):
    let text = if escaping: escape(run.text) else: run.text
    if run.lead.isNone and run.follow.isNone:
      result.add text
      continue
    let ink = if run.lead.isSome: armColour(run.lead.get)
              else: followColour(run.follow.get)
    result.add "<span style=\"color: " & ink & "\">" & text & "</span>"


func statCard(number: int; caption: string; is_good = false): string =
  ## Draw one figure in the strip at the head of the page.
  "<div class=\"stat" & (if is_good: " good" else: "") & "\"><b>" & $number &
    "</b><span>" & caption & "</span></div>"


proc renderStats(): string =
  ## Draw the figures the page opens with.
  "<div class=\"stats\">" &
    statCard(FRAMES.len, "frames the model derives") &
    statCard(countMoves(), "moves between them") &
    statCard(CELLS.len - countDeferredCells(), "cells checkable today") &
    statCard(countDisagreements(), "cells that disagree", is_good = true) &
    statCard(countDeferredCells(), "cells waiting on the body") &
    statCard(countLaws(), "laws under test") &
    "</div>"


func renderGallery(): string =
  ## Draw every frame, marking the ones the workbook has no row for.
  result = "<div class=\"gallery\">"
  for target in FRAMES:
    let absent = workbookName(target).isNone
    result.add "<div class=\"card" & (if absent: " absent" else: "") & "\">" &
      renderFrame(target) & "<div><div class=\"name\">" &
      inked(target.describe) & "</div><div class=\"meta\">" &
      $moves(target).len & " moves" &
      (if absent: " &middot; no row in the sheet" else: "") & "</div></div></div>"
  result.add "</div>"


func renderArms(): string =
  ## Say which ink is which arm, since both drawings are inked the same way.
  result = "<div class=\"legend\">"
  for side in Side:
    result.add "<span class=\"swatch\"><i class=\"arm-" &
      ($side).toLowerAscii & "\"></i>the lead's " & leadName(side) &
      " arm</span>"
  result.add "</div>"


func renderLegend(): string =
  ## Say which letter in the matrix stands for which move.
  for helper in Helper:
    if result.len > 0:
      result.add " &middot; "
    result.add "<b>" & HELPER_MARKS[helper] & "</b> " & helper.name
    if HELPER_SYNONYMS[helper].len > 0:
      result.add " (your <em class=\"term\">" &
        HELPER_SYNONYMS[helper].split(' ')[0] & "</em>)"
  for named in Compound:
    result.add " &middot; <b>" & COMPOUND_MARKS[named] & "</b> " &
      ($named).toLowerAscii & ", two moves"


func renderMatrix(): string =
  ## Draw the whole transition relation, marking what the workbook leaves blank.
  result = "<table class=\"matrix\"><thead><tr><th></th>"
  for target in FRAMES:
    result.add "<th>" & renderFrame(target) & "</th>"
  result.add "</tr></thead><tbody>"
  for source in FRAMES:
    result.add "<tr><th class=\"row\">" & inked(source.describe) & "</th>"
    for target in FRAMES:
      if source == target:
        result.add "<td class=\"self\"></td>"
        continue
      let
        helper = classify(source, target)
        named = compound(source, target)
      if helper.isNone and named.isNone:
        result.add "<td></td>"
        continue
      let known = cellText(
        workbookName(source).get(""), workbookName(target).get(""))
      result.add "<td class=\"on" & (if known.isSome: "" else: " new") &
        (if helper.isNone: " two" else: "") &
        "\" title=\"" & escape(source.describe) & " to " &
        escape(target.describe) & "\">" &
        (if helper.isSome: HELPER_MARKS[helper.get]
         else: COMPOUND_MARKS[named.get]) & "</td>"
    result.add "</tr>"
  result.add "</tbody></table>"


func renderPrimitives(): string =
  ## List the primitives, what each changes, and the workbook's other word.
  result = "<table class=\"plain\"><thead><tr><th>Primitive</th>" &
    "<th>What changes</th><th>Your words</th></tr></thead><tbody>"
  for helper in Helper:
    let synonym =
      if HELPER_SYNONYMS[helper].len == 0: "<span class=\"dim\">&mdash;</span>"
      else: "also <code>" & HELPER_SYNONYMS[helper].split(' ')[0] & "</code>, " &
        HELPER_SYNONYMS[helper].split(' ', 1)[1]
    result.add "<tr><td>" & helper.name & "</td><td>" & HELPER_CHANGES[helper] &
      "</td><td>" & synonym & "</td></tr>"
  result.add "</tbody></table>"


func renderCompounds(): string =
  ## List the compounds, what each does, and why the ontology names it.
  result = "<table class=\"plain\"><thead><tr><th>Compound</th>" &
    "<th>What changes</th><th>The two moves</th><th>Obstructed</th>" &
    "</tr></thead><tbody>"
  for named in Compound:
    result.add "<tr><td>" & ($named).toLowerAscii & "</td><td>" &
      COMPOUND_CHANGES[named] & "</td><td>" & COMPOUND_ORDERS[named] &
      "</td><td>" & (if COMPOUND_OBSTRUCTED[named]:
        "yes, by the other arm" else: "<span class=\"dim\">no</span>") &
      "</td></tr>"
  result.add "</tbody></table>"


func countCells(is_compound: bool): int =
  ## Count the checkable cells that name a compound, or that name a primitive.
  for cell in CELLS:
    if cell.source.isDeferred or cell.destination.isDeferred:
      continue
    if (readCompound(readCell(cell.text)[0]).isSome) == is_compound:
      inc result


func renderAudit(): string =
  ## Show the audit's own report, in the words the tool prints it in.
  var lines = ""
  for kind in FindingKind:
    for finding in audit():
      if finding.kind != kind:
        continue
      lines.add $kind & "\n  " & finding.subject & "\n    " & finding.detail & "\n"
  "<pre>" & escape(lines.strip(leading = false)) & "</pre>"



#[ Assembly ]#

func inkTerms(page: string): string =
  ## Ink the hands in every term of art the prose quotes.
  ##   A term marked up as one -- `Left to left`, `Left-to-right and
  ##     Right-to-left` -- is a name, and a name is written in the hands it
  ##     names wherever the page writes it.  Left alone, the prose would call
  ##     a frame one thing and the gallery two inches below it would call the
  ##     same frame another.
  ##   Done to the finished page rather than by hand in the template, so a
  ##     term written later is inked without anyone remembering to, and so
  ##     the prose stays prose to read and to edit.
  ##   Only inside the mark: a hand named in an ordinary sentence is being
  ##     talked about rather than named, and the sentence around it is doing
  ##     that work already.
  ##   Terms with no hand in them -- `open`, `closed`, `wrap` -- come back
  ##     from `named` as one unmarked stretch and are handed back untouched.
  const
    opens = "<em class=\"term\">"
    shuts = "</em>"
  result = page
  var at = 0
  while true:
    let start = result.find(opens, at)
    if start < 0:
      break
    let
      inner = start + opens.len
      stop = result.find(shuts, inner)
    let said = inked(result[inner ..< stop], escaping = false)
    result = result[0 ..< inner] & said & result[stop .. ^1]
    at = inner + said.len + shuts.len


proc renderReview*(): string =
  ## Fill the prose of the review with what the model says.
  let free_frame = fromKey("--.").get
  var page = readFile(TEMPLATE_PATH)
  let fills = {
    "stats": renderStats(),
    "gallery": renderGallery(),
    "matrix": renderMatrix(),
    "map": renderMap(none(Frame)),
    "arms": renderArms(),
    "primitives": renderPrimitives(),
    "compounds": renderCompounds(),
    "compound_count": $(ord(high(Compound)) + 1),
    "primitive_cells": $countCells(is_compound = false),
    "compound_cells": $countCells(is_compound = true),
    "audit": renderAudit(),
    "legend": renderLegend(),
    "frames": $FRAMES.len,
    "moves": $countMoves(),
    "cells": $CELLS.len,
    "checkable": $(CELLS.len - countDeferredCells()),
    "deferred": $countDeferredCells(),
    "named": $countNamedStates(),
    "free_moves": $(2 * moves(free_frame).len),
    "primitive_count": $(ord(high(Helper)) + 1),
    "laws": $countLaws(),
    "pairs": $(FRAMES.len * FRAMES.len),
    "diameter": $longestRoute(),
  }
  for (marker, value) in fills:
    page = page.replace("{{" & marker & "}}", value)
  if "{{" in page:
    let at = page.find("{{")
    quit "unfilled marker in " & TEMPLATE_PATH & ": " &
      page[at ..< min(at + 24, page.len)]
  inkTerms(page)


proc writeReview*() =
  ## Write the page, and one picture per frame for anything that is not HTML.
  writeFile(PAGE_PATH, renderReview())
  createDir(FRAME_DIRECTORY)
  for target in FRAMES:
    writeFile(FRAME_DIRECTORY / (target.slug & ".svg"), renderFrame(target))
  echo "wrote ", PAGE_PATH, " and ", FRAMES.len, " pictures in ", FRAME_DIRECTORY


when isMainModule:
  writeReview()
