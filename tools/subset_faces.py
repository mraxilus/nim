#!/usr/bin/env python3
"""Subset each embedded face to exactly what the tool draws, and write a manifest.

The codepoint list is not written here: it comes from `tools/codepoints.nim`, which derives it
from the core's own strings and the two shells' text. This script only asks each face which of
those codepoints it actually carries, subsets it to those, and reports the ranges it kept — so
the bundler's `unicode-range` declarations are measurements rather than guesses.

Usage: subset_faces.py CODEPOINT_FILE OUTPUT_DIRECTORY
"""

import pathlib
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

# Family name, vendored file, weight, and whether the face carries ordinary text.
#   Vendored, not read from the system: a named face installed on this machine is a face the
#   other target may not have, and both targets must draw the same glyphs.
VENDORED = pathlib.Path(__file__).resolve().parent.parent / "vendor" / "fonts"
FACES = [
    ("Noto Sans", VENDORED / "noto-sans-400.woff2", "400", True),
    ("Noto Sans", VENDORED / "noto-sans-600.woff2", "600", True),
    ("Noto Sans", VENDORED / "noto-sans-math-400.woff2", "400", False),
    ("Noto Sans", VENDORED / "noto-sans-symbols2-400.woff2", "400", False),
    ("Commit Mono", VENDORED / "commit-mono-400.woff2", "400", True),
]

TEXT_RANGE = range(0x20, 0x7F)


def covered(font, wanted):
    """Report which of the wanted codepoints a face actually carries."""
    available = set()
    for table in font["cmap"].tables:
        available.update(table.cmap.keys())
    return sorted(set(wanted) & available)


def as_ranges(codepoints):
    """Compress a codepoint list into the CSS `unicode-range` form."""
    parts, start, previous = [], None, None
    for codepoint in codepoints:
        if start is None:
            start = previous = codepoint
        elif codepoint == previous + 1:
            previous = codepoint
        else:
            parts.append((start, previous))
            start = previous = codepoint
    if start is not None:
        parts.append((start, previous))
    return ", ".join(
        f"U+{low:04X}" if low == high else f"U+{low:04X}-{high:04X}" for low, high in parts
    )


def main():
    codepoint_path, output_directory = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    wanted = {
        int(line.strip().removeprefix("U+"), 16)
        for line in codepoint_path.read_text().splitlines()
        if line.strip()
    }
    output_directory.mkdir(parents=True, exist_ok=True)
    manifest = []

    for family, path, weight, is_text in FACES:
        source = pathlib.Path(path)
        if not source.exists():
            print(f"subset: missing face {path}", file=sys.stderr)
            continue
        font = TTFont(source)
        keep = covered(font, wanted | (set(TEXT_RANGE) if is_text else set()))
        if not keep:
            continue
        options = subset.Options(layout_features=["*"], desubroutinize=True)
        options.flavor = "woff2"
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=keep)
        subsetter.subset(font)
        target = output_directory / f"{source.stem}-{weight}.woff2"
        font.flavor = "woff2"
        font.save(target)
        manifest.append(f"{family}|{target}|{weight}|{as_ranges(keep)}")
        print(f"subset {source.name}: {len(keep)} glyphs, {target.stat().st_size // 1024} KB")

    (output_directory / "manifest.list").write_text("\n".join(manifest) + "\n")


if __name__ == "__main__":
    main()
