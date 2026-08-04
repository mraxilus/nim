discard """
action: run
cmd: "nim js --hints:on -d:testing -d:nimUnittestAbortOnError:on $options -r $file"
matrix: "-d:pga.dimensions=4 -d:pga.is_conformal=false"
batchable: true
joinable: true
"""
## Run the shared suite as the browser build compiles it, on the JS backend.
##
## The desktop entry point beside this one cannot stand in for it. A rule stated once and
## reached through two mechanisms -- `format.formatMagnitude` against C's own `%.4g` -- is
## only held together where both mechanisms run, and one of them exists solely because this
## backend has no C runtime. Compiled to C alone, that comparison asks the C runtime whether
## it agrees with itself. It does; the browser did not, on 330 of 7000 values.
##
## Cases needing a C entry point (`snprintf`, PNG and GIF export, the arena) guard
## themselves with `when not defined(js)` and are skipped here.
include "./suites.nim"
