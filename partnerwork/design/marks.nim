## Build the workbench: parts, checks, pages, files.
##
##   The build refuses to write a page whose claims fail: the checks run
##     between building a page's parts and writing it, and several figures
##     are asserted during their own construction.
##     Cost of refusing the whole build: one broken rule stops every page,
##       not just its own.  Accepted -- a workbench that publishes
##       half-checked pages is worse than one that stops.
##   Every page is committed like `doc/review.html` is, so its git history
##     is the history of what the marks have been claimed to be.
##     Each is published as a Claude artifact at a fixed URL; republishing
##     the rebuilt files to those URLs is the whole release step.

{.experimental: "strictFuncs".}

import std/[os, strformat, tables, unicode]

import ./[checks, frame_page, hands_page, parts, sign_page, turns_single_page]


proc checkFrameAndRules() =
  ## Check everything the frame page claims: the drawing, then the ledger.
  checkFrame()
  checkRules()


const PAGES = [
  (name: "frames.html",
   parts_of: proc (): Parts {.nimcall.} = frameParts(),
   check: proc () {.nimcall.} = checkFrameAndRules(),
   render: proc (parts: Parts): string {.nimcall.} = frame_page.render(parts)),
  (name: "signs.html",
   parts_of: proc (): Parts {.nimcall.} = signParts(),
   check: proc () {.nimcall.} = checkSign(),
   render: proc (parts: Parts): string {.nimcall.} = sign_page.render(parts)),
  (name: "turns-single.html",
   parts_of: proc (): Parts {.nimcall.} = singleTurnParts(),
   check: proc () {.nimcall.} = checkSingleTurns(),
   render: proc (parts: Parts): string {.nimcall.} =
     turns_single_page.render(parts)),
  (name: "turns-hands.html",
   parts_of: proc (): Parts {.nimcall.} = handTurnParts(),
   check: proc () {.nimcall.} = checkHandTurns(),
   render: proc (parts: Parts): string {.nimcall.} = hands_page.render(parts)),
] ## Each page: its file, its figures, its checks, its layout.


proc main() =
  ## Check and rebuild every page, into `design/` or a given directory.
  let out_dir = if paramCount() > 0: paramStr(1) else: "design"
  for page in PAGES:
    let built = page.parts_of()
    echo &"{page.name}: {built.len} pieces"
    page.check()
    let
      html = page.render(built)
      path = out_dir / page.name
    writeFile(path, html)
    echo &"  written {html.runeLen} characters to {path}"


main()
