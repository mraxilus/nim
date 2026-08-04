#!/bin/sh
# Fetch every vendored dependency into `vendor/`, which is never committed.
# Re-runnable: each fetch is skipped when its target is already present.

set -e
set -u

root_directory=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vendor_directory="$root_directory/vendor"
mkdir -p "$vendor_directory"

pga_commit=f8861e0b5ab6e868382126aa7b109503f2fe16d3
pga_path=lengyel/projective_geometric_algebra_illuminated

# Fetch the algebra library this workbench is a testbed for.
if [ ! -d "$vendor_directory/pga" ]; then
  work_directory=$(mktemp -d)
  git clone --quiet https://gitlab.com/mraxilus/replications.git "$work_directory/replications"
  git -C "$work_directory/replications" checkout --quiet "$pga_commit"
  cp -r "$work_directory/replications/$pga_path" "$vendor_directory/pga"
  # Carry the licence with the copy, as the Prosperity licence's notice clause requires.
  cp "$work_directory/replications/LICENSE.md" "$vendor_directory/pga/LICENSE.md"
  rm -rf "$work_directory"
  echo "fetched pga at $pga_commit"
fi

# Fetch the glyph rasteriser the desktop font atlas is built with.
if [ ! -f "$vendor_directory/stb_truetype.h" ]; then
  curl -sSL -o "$vendor_directory/stb_truetype.h" \
    https://raw.githubusercontent.com/nothings/stb/master/stb_truetype.h
  echo "fetched stb_truetype.h"
fi

# Fetch every face both targets draw with. Vendored rather than read from the system: a face
# installed on the build machine is a face a viewer may not have, and the two targets must draw
# the same glyphs. All are SIL Open Font License 1.1; the licence text is fetched beside them.
fonts_directory="$vendor_directory/fonts"
fontsource=https://cdn.jsdelivr.net/npm/@fontsource
fontsource_version=5.3.0
mkdir -p "$fonts_directory"
for face in \
  noto-sans/files/noto-sans-latin-400-normal.woff2 \
  noto-sans/files/noto-sans-latin-600-normal.woff2 \
  noto-sans-math/files/noto-sans-math-math-400-normal.woff2 \
  noto-sans-symbols-2/files/noto-sans-symbols-2-symbols-400-normal.woff2 \
  noto-serif/files/noto-serif-latin-400-normal.woff2 \
  commit-mono/files/commit-mono-latin-400-normal.woff2
do
  target="$fonts_directory/$(basename "$face")"
  [ -f "$target" ] && continue
  curl -sSL -o "$target" "$fontsource/$face"
  echo "fetched $(basename "$face")"
done
for notice in \
  "noto-sans@$fontsource_version:NOTO-LICENSE.txt" \
  "commit-mono@$fontsource_version:COMMIT-MONO-LICENSE.txt"
do
  package=${notice%%:*}
  target="$fonts_directory/${notice##*:}"
  [ -f "$target" ] && continue
  curl -sSL -o "$target" "https://unpkg.com/@fontsource/$package/LICENSE"
done

# Convert each face to TrueType for the desktop atlas: the rasteriser reads glyph outlines,
# and a WOFF2 is those outlines under a compression it does not know how to undo.
python3 - "$fonts_directory" <<'PYTHON'
import pathlib
import sys

from fontTools.ttLib import TTFont

directory = pathlib.Path(sys.argv[1])
for source in sorted(directory.glob("*.woff2")):
    target = source.with_suffix(".ttf")
    if target.exists():
        continue
    face = TTFont(source)
    face.flavor = None
    face.save(target)
    print(f"converted {source.name} to {target.name}")
PYTHON
