discard """
action: run
cmd: "nim c --hints:on -d:testing -d:nimUnittestAbortOnError:on $options -r $file"
matrix: "-d:pga.dimensions=4 -d:pga.is_conformal=false -d:visualiser.items_max=12 -d:visualiser.label_max=12 -d:visualiser.history_capacity=4"
batchable: true
joinable: true
"""
## Run the shared suite at capacities small enough that its own tests reach them.
##
## Every capacity here is a `.define`, so a caller may raise it; at the defaults the suite
## exercises the limits only where a test spells the limit out, and a test that fills the
## scene to `ITEMS_MAX` or the timeline to `CAPACITY_HISTORY` writes sixty-four or thirty-two
## entries to prove one boundary. Shrinking them makes those boundaries cheap to reach and,
## more to the point, makes any constant tuned to the *default* rather than derived from the
## define fail here rather than in a build somebody configured. `LABEL_MAX` at 12 is the
## sharpest of the three: it is under the length of several labels the suite constructs, so
## truncation happens for real rather than only in the one test that asks for it.
##
## Backend is C, matching the desktop entry point beside this one: what varies here is
## capacity, not the render path -- see `test_4d_browser.nim` for the other axis.
include "./suites.nim"
