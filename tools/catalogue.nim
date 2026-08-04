## Print what this build reports for the whole operation catalogue, and write a demo scene.
##
## Two mechanical parity checks read this: the browser driver compares the page's own
## twenty-seven labels against the list printed here, and it loads the scene file written here
## through the page's decoder, so the two targets are shown to reach the identical format.
##
## Usage: catalogue [SCENE_PATH]

import std/os

import ../src/core/[catalogue, demo, sceneio, workbench]

when isMainModule:
  for operation in Operation:
    echo operation.label

  if paramCount() >= 1:
    var bench = initWorkbench()
    bench.loadDemo()
    writeFile(paramStr(1), encode(bench.scene))
