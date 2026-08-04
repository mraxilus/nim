version       = "0.1.0"
author        = "mraxilus"
description   = "An ontology of the frames a couple can hold in partner dance"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the law tests":
  for name in ["tframe", "ttransition", "tworkbook", "trotation"]:
    exec "nim c -r --hints:off tests/" & name & ".nim"

task app, "Build the browser validator":
  exec "nim js -d:release --hints:off -o:app/app.js app/app.nim"

task audit, "Print the model and its disagreements with the workbook":
  exec "nim c -r --hints:off tools/audit.nim"
