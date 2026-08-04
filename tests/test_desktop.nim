discard """
  action: run
  cmd: "nim c --hints:off -d:testing --nimCache:$nimcache $options -r $file"
  matrix: "-d:pga.dimensions=4 -d:pga.is_conformal=false; -d:pga.dimensions=4 -d:pga.is_conformal=false -d:rga.item_capacity=32 -d:rga.history_capacity=8 -d:rga.label_capacity=24"
  targets: "c"
"""
## Run the shared suite as the desktop build compiles it, over two configurations.

include ./suite
