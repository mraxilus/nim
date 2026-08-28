#!/usr/bin/env bash
# Run every check this project has, and fail on the first one that fails.
#
# One command, so a session that is about to commit has nothing to remember. Each step
# prints its own name before running, so a failure names itself without reading the log
# upward.
#
# It now drives real events into the built page and asserts what they reached
# (`drive_browser.mjs`), which is what a handler called directly can never check. What it
# still does NOT do is *look* at anything: a page that compiles, answers every gesture and
# renders a blank canvas passes this. Passing it is necessary, never sufficient; see
# `PROVENANCE.md` on verifying by running.

set -euo pipefail

DIR_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${DIR_PROJECT}"

# The compiler is the one built from this tree, never a system Nim: a release compiler
#   rejects some of what this project uses, e.g. a `var`-returning index operator.
NIM="${NIM:-${DIR_PROJECT}/../../bin/nim}"
# Node runs both the JS suite and the driven browser checks; override for a build kept
#   somewhere other than the path.
NODE="${NODE:-node}"
DEFINES_PGA="-d:pga.dimensions=4 -d:pga.is_conformal=false"

step() {
  printf '\n\033[1m== %s\033[0m\n' "$1"
}

# Layout first: it is the cheapest check and the one most likely to be failing, so a run
#   that is going to fail should fail in a second rather than after two compiles.
step 'Layout: line width in characters, trailing whitespace, tabs'
"${NIM}" c --hints:off -o:bin/check_columns tools/check_columns.nim
./bin/check_columns

step 'Palette: separation floors under typical and colour-deficient vision'
# shellcheck disable=SC2086  # Word splitting is what carries the separate defines.
"${NIM}" c --hints:off ${DEFINES_PGA} -o:bin/check_palette tools/check_palette.nim
./bin/check_palette

step 'Atlas: every codepoint the UI can draw has a glyph range'
# shellcheck disable=SC2086
"${NIM}" c --hints:off ${DEFINES_PGA} -o:bin/check_atlas tools/check_atlas.nim
./bin/check_atlas

step 'Suite, C backend, default capacities'
# shellcheck disable=SC2086
"${NIM}" c --hints:off -d:testing -d:nimUnittestAbortOnError:on ${DEFINES_PGA} \
  -o:bin/test_4d -r tests/visualiser/test_4d.nim

step 'Suite, C backend, reduced capacities'
# The capacities come from the entry point's own testament matrix, so the two cannot drift.
DEFINES_SMALL="$(
  sed -n 's/^matrix: "\(.*\)"$/\1/p' tests/visualiser/test_4d_small.nim
)"
# shellcheck disable=SC2086
"${NIM}" c --hints:off -d:testing -d:nimUnittestAbortOnError:on ${DEFINES_SMALL} \
  -o:bin/test_4d_small -r tests/visualiser/test_4d_small.nim

step 'Suite, JS backend'
# The browser build's own backend. Not a formality: a rule stated once and reached through
#   two mechanisms is only held together where both run, and 330 of 7000 magnitudes once
#   differed between them while the C-only run stayed green.
# shellcheck disable=SC2086
"${NIM}" js --hints:off -d:testing -d:nimUnittestAbortOnError:on ${DEFINES_PGA} \
  -o:bin/test_browser.js tests/visualiser/test_4d_browser.nim
"${NODE}" bin/test_browser.js

step 'Build: desktop'
"${NIM}" c --hints:off -o:bin/visualiser visualiser.nim

step 'Build: browser page'
./build_browser.sh

# Everything above stops at "it compiles and its rules hold". This drives real events into
#   the built page and asserts what they reached, which is the only way a rule wired to the
#   wrong event is caught: the suites call the rules directly and stay green while a wheel
#   notch, a key release or a pinch goes somewhere else. It was a `/tmp` script run by hand
#   until a pinch regression shipped past every green suite.
step 'Drive: browser, real key, wheel and touch events'
"${NODE}" tools/drive_browser.mjs

printf '\n\033[1mEvery check passed.\033[0m Now render it and look at it.\n'
