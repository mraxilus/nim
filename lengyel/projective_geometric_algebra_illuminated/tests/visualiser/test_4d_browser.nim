discard """
action: run
cmd: "nim js --hints:on -d:testing -d:nimUnittestAbortOnError:on $options -r $file"
matrix: "-d:pga.dimensions=4 -d:pga.is_conformal=false"
batchable: true
joinable: true
"""
## Run shared suite as browser build compiles it, on JS backend.
##
## Desktop entry point cannot stand in for it: rule stated once and reached through two
## mechanisms (`format.formatMagnitude` against C's `%.4g`) is held together only where
## both run. Compiled to C alone, that comparison asks C runtime whether it agrees with
## itself. Browser did not, on 330 of 7000 values.
##
## Cases needing C entry point (`snprintf`, PNG and GIF export, arena) guard themselves
## with `when not defined(js)` and are skipped here.
include "./suites.nim"
