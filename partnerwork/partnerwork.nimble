import std/strutils

version       = "0.1.0"
author        = "mraxilus"
description   = "An ontology of the frames a couple can hold in partner dance"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"


proc bundleOne(dir: string) =
  ## Fold a page's script into its markup, as one file that carries the whole.
  ##   The bundle drops the document wrapper as well: it is written to be
  ##     embedded in a page that supplies its own, which is what publishing
  ##     it expects.
  ##   The published page is titled for the body of work as well as for
  ##     itself, so a gallery holding several sorts them together; the page
  ##     served locally keeps its own plain name.
  let
    markup = readFile(dir & "/index.html")
    script = readFile(dir & "/" & dir & ".js")
    tag = "<script src=\"" & dir & ".js\"></script>"
  var head = markup[markup.find("<title>") .. markup.find("</style>") + 7]
  head = head.replace("<title>", "<title>Ontology Partnerwork \u2014 ")
  var body = markup[markup.find("<body>") + 6 ..< markup.find("</body>")]
  if not body.contains(tag):
    quit dir & "/index.html no longer loads its script the way the bundle expects"
  body = body.replace(tag, "<script>\n" & script & "\n</script>")
  writeFile(dir & "/artifact.html", head & body)


task test, "Run the law tests":
  for name in ["tframe", "ttransition", "tworkbook", "trotation", "tdiagram",
      "tmap", "tspokes", "taxle", "treview"]:
    exec "nim c -r --hints:off tests/" & name & ".nim"

task app, "Build the browser validator, and bundle it into one file":
  exec "nim js -d:release --hints:off -o:app/app.js app/app.nim"
  bundleOne("app")

task bundle, "Fold the built script into one self-contained page":
  bundleOne("app")

task review, "Write the review page and the frame pictures from the model":
  exec "nim c -r --hints:off tools/review.nim"

task audit, "Print the model and what it says about the workbook":
  exec "nim c -r --hints:off tools/audit.nim"

task marks, "Check and rebuild the mark workbench's four pages":
  # A debug build on purpose: the workbench's doAssert gates are the build.
  exec "nim c -r --hints:off design/marks.nim"

task sim, "Check the body sim's laws, then build its page":
  # The laws first: a page that draws a model which has stopped holding is
  # worse than no page.  Nothing here touches the ontology, which is the
  # whole point of the directory being its own.
  exec "nim c -r --hints:off sim/laws.nim"
  exec "nim js -d:release --hints:off -o:sim/sim.js sim/page.nim"
  bundleOne("sim")

task verdicts, "Ask the sim which of the sheet's modifier states hold":
  # An instrument run, not a build: the answers land in sim/verdicts.md.
  exec "nim c -r --hints:off sim/verdicts.nim"

task turns, "Build the rope model's bridge for the whole-cloth page, and splice it in":
  # The page animates a hold turning by asking the sim itself, compiled to
  # JavaScript; the bridge lives in the page's one generated slot.
  exec "nim js -d:release --hints:off -o:design/turns.js design/turns.nim"
  let
    page = readFile("design/wholecloth.html")
    opening = "<script id=\"turns-sim\">"
    a = page.find(opening)
  if a < 0:
    quit "design/wholecloth.html has no turns-sim slot"
  let b = page.find("</script>", a)
  writeFile("design/wholecloth.html",
    page[0 ..< a + opening.len] & "\n" & readFile("design/turns.js") & "\n" &
    page[b .. ^1])

task shot, "Build the workbench's screenshot helper for node":
  exec "nim js --hints:off -d:nodejs -o:design/shot.js design/shot.nim"
