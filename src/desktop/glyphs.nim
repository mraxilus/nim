## Enumerate every codepoint the desktop build draws, so the atlas carries exactly those.
##
## Derived from the core's own strings — the catalogue's labels, the algebra's element names,
## the shape words, the palette's names — plus the panel's fixed wording. `tools/codepoints.nim`
## reads the same list, so the browser's font subsetter and the desktop's atlas are built from
## one enumeration rather than two.

{.experimental: "strictFuncs".}

import std/[algorithm, sequtils, tables, unicode]

import ../core/[algebra, catalogue, palette]



#[ Panel Wording ]#

const PANEL_WORDS* = [
  ## Name every word the panel writes that does not come from the core.
  "add", "undo", "redo", "axes", "grid", "save", "load", "apply", "diagnostics", "objects",
  "view", "unary", "binary", "edit", "hide", "show", "remove", "✕", "azimuth", "elevation",
  "distance", "field of view", "target x", "target y", "target z", "operation", "frame",
  "peak", "mean", "pool", "active", "free", "permanent", "arena", "reserved", "ms", "MB",
  "◆ RGA Workbench", "⋯", "—", "‹", "›", "−", "+", "✓",
]



#[ Enumeration ]#

proc codepointsWritten*(): seq[int] =
  ## List every codepoint the tool writes, ASCII first, then each non-ASCII one, sorted.
  var seen: Table[int, bool]
  for codepoint in 0x20 .. 0x7E:
    seen[codepoint] = true

  proc collect(text: string) =
    for rune in text.runes:
      seen[int(rune)] = true

  for operation in Operation:
    collect(operation.label)
  for b in Basis:
    collect(b.elementName)
  for shape in Shape:
    collect(shape.shapeWord)
  for paint in Paint:
    collect($paint)
  for word in PANEL_WORDS:
    collect(word)
  collect(OPERAND_FIRST)
  collect(OPERAND_SECOND)
  toSeq(seen.keys).sorted
