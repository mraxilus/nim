#!/bin/sh
# Run every check this project can run without a human: both suites, both builds, the capture
# frames, and the browser driven headlessly with real synthetic events.
#
# Usage: tools/verify.sh   (from the project root, after tools/fetch_vendor.sh)

set -e
set -u

nim="${NIM:-nim}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
mkdir -p build

echo "== suite, C backend, default configuration"
$nim c --hints:off -d:pga.dimensions=4 -d:pga.is_conformal=false -r tests/test_desktop.nim

echo "== suite, C backend, second configuration"
$nim c --hints:off -d:pga.dimensions=4 -d:pga.is_conformal=false -d:rga.item_capacity=32 \
  -d:rga.history_capacity=8 -d:rga.label_capacity=24 --nimCache:build/nimcache-alt \
  -o:build/test_alt -r tests/test_desktop.nim

echo "== suite, JS backend"
$nim js --hints:off -d:pga.dimensions=4 -d:pga.is_conformal=false -r tests/test_browser.nim

echo "== palette, measured by this project's validator and by an independent library"
$nim c --hints:off -d:pga.dimensions=4 -d:pga.is_conformal=false -o:build/palette_check \
  tools/palette_check.nim
build/palette_check
python3 tools/palette_reference.py

echo "== desktop build, a screenshot and the capture frames"
$nim c --hints:off --passC:-I"$root/vendor" -o:build/rga src/desktop/main.nim
xvfb-run -a -s "-screen 0 1440x900x24" build/rga --hidden --screenshot:build/desktop.png
rm -rf build/storyboard
xvfb-run -a -s "-screen 0 1440x900x24" build/rga --hidden --storyboard:build/storyboard

echo "== browser bundle, and the parity inputs the driver reads"
$nim js --hints:off -d:pga.dimensions=4 -d:pga.is_conformal=false -d:release \
  -o:build/core.js src/browser/main.nim
$nim c --hints:off -d:pga.dimensions=4 -d:pga.is_conformal=false -o:build/codepoints \
  tools/codepoints.nim
build/codepoints > build/codepoints.list
python3 tools/subset_faces.py build/codepoints.list build/faces
$nim c --hints:off -d:pga.dimensions=4 -d:pga.is_conformal=false -o:build/catalogue \
  tools/catalogue.nim
build/catalogue build/demo.rgascene > build/catalogue.list
$nim c --hints:off -o:build/bundle tools/bundle.nim
build/bundle

echo "== browser, driven with real synthetic mouse and touch events"
RGA_CODEPOINTS=$(python3 -c "
import sys
print([int(line.strip()[2:], 16) for line in open('build/codepoints.list') if line.strip()])
") node tools/verify_browser.mjs build/index.html

echo
echo "Everything that can be checked without a human has been checked."
echo "Look at build/desktop.png and build/storyboard/ before calling a round finished."
