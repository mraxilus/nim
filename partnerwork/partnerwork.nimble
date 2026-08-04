import std/strutils

version       = "0.1.0"
author        = "mraxilus"
description   = "An ontology of the frames a couple can hold in partner dance"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"


proc bundleApp() =
  ## Fold the script into the markup, as one file that carries the whole app.
  ##
  ## The bundle drops the document wrapper as well: it is written to be embedded
  ## in a page that supplies its own, which is what publishing it expects.
  const script_tag = "<script src=\"app.js\"></script>"
  let markup = readFile("app/index.html")
  let script = readFile("app/app.js")
  let head = markup[markup.find("<title>") .. markup.find("</style>") + 7]
  var body = markup[markup.find("<body>") + 6 ..< markup.find("</body>")]
  if not body.contains(script_tag):
    quit "app/index.html no longer loads app.js the way the bundle expects"
  body = body.replace(script_tag, "<script>\n" & script & "\n</script>")
  writeFile("app/artifact.html", head & body)


task test, "Run the law tests":
  for name in ["tframe", "ttransition", "tworkbook", "trotation", "tmap", "treview"]:
    exec "nim c -r --hints:off tests/" & name & ".nim"

task app, "Build the browser validator, and bundle it into one file":
  exec "nim js -d:release --hints:off -o:app/app.js app/app.nim"
  bundleApp()

task bundle, "Fold the built script into one self-contained page":
  bundleApp()

task review, "Write the review page and the frame pictures from the model":
  exec "nim c -r --hints:off tools/review.nim"

task audit, "Print the model and what it says about the workbook":
  exec "nim c -r --hints:off tools/audit.nim"
