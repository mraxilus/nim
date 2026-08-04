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

# Fetch every face both targets draw with, each from the project that makes it: the Noto faces
# from the Noto project's own release repository, and Commit Mono from its own site, which
# serves the variable font the page itself loads. Vendored rather than read from the system: a
# face installed on the build machine is a face a viewer may not have, and the two targets must
# draw the same glyphs. Every face is SIL Open Font License 1.1, and each carries that notice
# in its own name table; the Noto licence text is fetched beside them.
fonts_directory="$vendor_directory/fonts"
noto=https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts
commit_mono_version=V143
mkdir -p "$fonts_directory"

fetch_face() {
  # Fetch one face to a canonical name, skipping a face already present.
  target="$fonts_directory/$2"
  [ -f "$target" ] && return 0
  curl -sSL -o "$target" "$1"
  echo "fetched $2"
}

fetch_face "$noto/NotoSans/hinted/ttf/NotoSans-Regular.ttf" noto-sans-400.ttf
fetch_face "$noto/NotoSans/hinted/ttf/NotoSans-SemiBold.ttf" noto-sans-600.ttf
fetch_face "$noto/NotoSansMath/hinted/ttf/NotoSansMath-Regular.ttf" noto-sans-math-400.ttf
fetch_face "$noto/NotoSansSymbols2/hinted/ttf/NotoSansSymbols2-Regular.ttf" \
  noto-sans-symbols2-400.ttf
fetch_face "$noto/NotoSerif/hinted/ttf/NotoSerif-Regular.ttf" noto-serif-400.ttf
fetch_face "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/LICENSE" \
  NOTO-LICENSE.txt
fetch_face \
  "https://commitmono.com/src/fonts/fontlab/CommitMono$commit_mono_version-VF.woff2" \
  commit-mono-variable.woff2

# Prepare each face in both forms: TrueType for the desktop rasteriser, which reads outlines
# and cannot undo WOFF2 compression, and WOFF2 for the page, which pays for every byte. Commit
# Mono arrives as a variable font, so it is first instantiated at the one weight this tool
# draws — the alternative, shipping the whole design space to draw one weight, is payload for
# nothing.
python3 - "$fonts_directory" <<'PYTHON'
import pathlib
import sys

from fontTools import ttLib
from fontTools.varLib import instancer

directory = pathlib.Path(sys.argv[1])

variable = directory / "commit-mono-variable.woff2"
static = directory / "commit-mono-400.ttf"
if variable.exists() and not static.exists():
    face = ttLib.TTFont(variable)
    instancer.instantiateVariableFont(face, {"wght": 400, "ital": 0}, inplace=True)
    face.flavor = None
    face.save(static)
    print(f"instantiated {variable.name} at weight 400")

for source in sorted(directory.glob("*.ttf")):
    target = source.with_suffix(".woff2")
    if target.exists():
        continue
    face = ttLib.TTFont(source)
    face.flavor = "woff2"
    face.save(target)
    print(f"compressed {source.name} to {target.name}")
PYTHON
