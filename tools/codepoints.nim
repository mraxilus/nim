## Print every non-ASCII codepoint the tool writes, one per line, as `U+XXXX`.
##
## The list is derived from the core — the catalogue's labels, the algebra's element names,
## the shape words — and from the two shells' own text, rather than transcribed. It feeds two
## things: the font subsetter, so an embedded face carries exactly what is drawn, and the
## coverage check, which renders each codepoint against each face and compares it against the
## notdef glyph. A font-loading check reports face loading, not glyph coverage, and will
## confidently tell you the wrong thing.

import std/[algorithm, os, sequtils, strutils, tables, unicode]

import ../src/core/[algebra, camera, catalogue, palette]



#[ Collection ]#

proc collect(text: string, seen: var Table[int, bool]) =
  ## Record every non-ASCII codepoint of a string.
  for rune in text.runes:
    if int(rune) >= 128: seen[int(rune)] = true


when isMainModule:
  var seen: Table[int, bool]

  # Read what the core writes.
  for operation in Operation:
    operation.label.collect(seen)
  for b in Basis:
    b.elementName.collect(seen)
  for shape in Shape:
    shape.shapeWord.collect(seen)
  for paint in Paint:
    ($paint).collect(seen)
  OPERAND_FIRST.collect(seen)
  OPERAND_SECOND.collect(seen)

  # Read what each shell writes, so a glyph only the page uses is not missed.
  let root = currentSourcePath().parentDir.parentDir
  for relative in [
    "src/browser/shell.html",
    "src/browser/glue.js",
    "src/desktop/panel.nim",
    "src/desktop/main.nim",
  ]:
    let path = root / relative
    if fileExists(path): readFile(path).collect(seen)

  for codepoint in toSeq(seen.keys).sorted:
    echo "U+", toHex(codepoint, if codepoint > 0xFFFF: 5 else: 4)
