discard """
action: run
cmd: "nim c --hints:on -d:testing -d:nimUnittestAbortOnError:on $options -r $file"
matrix: "-d:pga.dimensions=4 -d:pga.is_conformal=false"
batchable: true
joinable: true
"""
include "./suites.nim"
