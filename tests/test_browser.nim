discard """
  action: run
  cmd: "nim js --hints:off -d:testing --nimCache:$nimcache $options -r $file"
  matrix: "-d:pga.dimensions=4 -d:pga.is_conformal=false"
  targets: "js"
"""
## Run the shared suite as the browser build compiles it, on the JS backend.
##   The formatting case is the one that differs: a C runtime is not available here, so the
##   portable path is the only one, which is why the tool always calls it.

include ./suite
