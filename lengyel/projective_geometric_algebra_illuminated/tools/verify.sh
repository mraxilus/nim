#!/usr/bin/env bash
# Run every check this project has, and fail on first that fails.
#
# One command, so session about to commit has nothing to remember.
#   Each step prints its name before running, so failure names itself.
# Drives real events into built page and asserts what they reached (`drive_browser.mjs`).
#   Handler called directly can never check that.
#   What it does not do is look at anything: page that compiles, answers every gesture
#   and renders blank canvas passes.
#   Passing is necessary, never sufficient; see `PROVENANCE.md` on verifying by running.

set -euo pipefail

DIR_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${DIR_PROJECT}"

# Take compiler built from this tree, never system Nim.
#   Release compiler rejects some of what this project uses, e.g. `var`-returning index
#   operator.
NIM="${NIM:-${DIR_PROJECT}/../../bin/nim}"
# Take Node for both JS suite and driven browser checks; override for build kept elsewhere.
NODE="${NODE:-node}"
DEFINES_PGA="-d:pga.dimensions=4 -d:pga.is_conformal=false"

step() {
  printf '\n\033[1m== %s\033[0m\n' "$1"
}

# Check layout first, cheapest check and one most likely failing.
#   Failing run then fails in second rather than after two compiles.
step 'Layout: line width in characters, trailing whitespace, tabs'
"${NIM}" c --hints:off -o:bin/check_columns tools/check_columns.nim
# Check checker first, against its own fixtures.
#   Measured in characters, and one counting bytes would pass every file while lying
#   about every line holding `∧`.
./bin/check_columns --self-test
./bin/check_columns

# Check prose next: every comment in every language, held to its rules by tool.
#   Cleanup then never has to be ordered by hand again.
step 'Prose: no articles in any comment, in any language'
"${NIM}" c --hints:off -o:bin/check_prose tools/check_prose.nim
./bin/check_prose --self-test
./bin/check_prose

step 'Palette: separation floors under typical and colour-deficient vision'
# shellcheck disable=SC2086  # Word splitting is what carries separate defines.
"${NIM}" c --hints:off ${DEFINES_PGA} -o:bin/check_palette tools/check_palette.nim
./bin/check_palette

step 'Atlas: every codepoint the UI can draw has a glyph range'
# shellcheck disable=SC2086
"${NIM}" c --hints:off ${DEFINES_PGA} -o:bin/check_atlas tools/check_atlas.nim
./bin/check_atlas

step 'Ramp: the timing tree is tinted with CET-I1, re-lit to the drawer text tones'
"${NIM}" c --hints:off -o:bin/check_ramp tools/check_ramp.nim
./bin/check_ramp

step 'Suite, C backend, default capacities'
# shellcheck disable=SC2086
"${NIM}" c --hints:off -d:testing -d:nimUnittestAbortOnError:on ${DEFINES_PGA} \
  -o:bin/test_4d -r tests/visualiser/test_4d.nim

step 'Suite, C backend, reduced capacities'
# Capacities come from entry point's testament matrix, so two cannot drift.
DEFINES_SMALL="$(
  sed -n 's/^matrix: "\(.*\)"$/\1/p' tests/visualiser/test_4d_small.nim
)"
# shellcheck disable=SC2086
"${NIM}" c --hints:off -d:testing -d:nimUnittestAbortOnError:on ${DEFINES_SMALL} \
  -o:bin/test_4d_small -r tests/visualiser/test_4d_small.nim

step 'Suite, JS backend'
# Run suite on browser build's backend.
#   Rule stated once and reached through two mechanisms is held together only where both
#   run; magnitudes differed while C-only run stayed green.
# shellcheck disable=SC2086
"${NIM}" js --hints:off -d:testing -d:nimUnittestAbortOnError:on ${DEFINES_PGA} \
  -o:bin/test_browser.js tests/visualiser/test_4d_browser.nim
"${NODE}" bin/test_browser.js

step 'Build: desktop'
"${NIM}" c --hints:off -o:bin/visualiser visualiser.nim

step 'Build: browser page'
./build_browser.sh

# Drive real events into built artefacts and assert what they reached.
#   Everything above stops at "it compiles and its rules hold".
#   Only way rule wired to wrong event is caught: suites call rules directly and stay
#   green while wheel notch, key release or pinch goes elsewhere.
step 'Drive: desktop, real SDL events under a virtual display'
# Script one kind of gesture per mode into SDL's queue and judge what it reached.
#   `--drive-assert` turns report into verdict and exit code.
#   Frame counts come from each drive's schedule; `--drive-drag` stops at frame its menu
#   is up.
for driven in \
  '--drive-keys --frames:40' \
  '--drive-sky --frames:20' \
  '--drive-undo --frames:44' \
  '--drive-select --frames:24' \
  '--drive-drag --frames:9' \
  '--drive-help:keys --frames:8' \
  '--drive-help:operations --frames:8'
do
  # shellcheck disable=SC2086  # Word splitting is what carries separate options.
  xvfb-run -a -s "-screen 0 1440x900x24" ./bin/visualiser --hidden --drive-assert ${driven}
done

step 'Drive: browser, real key, wheel and touch events'
"${NODE}" tools/drive_browser.mjs

printf '\n\033[1mEvery check passed.\033[0m Now render it and look at it.\n'
