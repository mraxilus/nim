## Hold the desktop font atlas to the text the visualiser can actually put on screen.
##
## Enumerates every codepoint reachable in UI text from the tables that produce it -- the
## operation notation, the basis element names, the shape words -- then reads the glyph
## ranges `gui_shim.cpp` builds the atlas from and reports any codepoint no range covers.
## A codepoint outside every range renders as a tofu box, which is what shipped for the
## geometric product and antiproduct until a check like this one was run by hand.
##
## Both sides are read from source rather than transcribed. The codepoints come from the
## same `lut_*` tables the panel draws, so adding an operation whose symbol falls outside
## the atlas fails here; the ranges come from `gui_shim.cpp` itself, so narrowing one fails
## here too. Neither can drift from what is compiled without this noticing.
##
## Covers the desktop atlas only. The browser has no atlas: it embeds whole faces, and its
## own coverage is a question about those font files rather than about ranges.
##
## Build and run from the project root:
##   bin/nim c --hints:off -o:bin/check_atlas tools/check_atlas.nim && bin/check_atlas

import std/[algorithm, os, sequtils, sets, strformat, strutils, unicode]

import ../pga
import ../visualiser/core/[objects, scene]



#[ Source Locations ]#

const PATH_SHIM = "visualiser/desktop/gui_shim.cpp"
  ## Where the atlas ranges are declared, relative to the project root this is run from.



#[ Reachable Codepoints ]#

proc codepointsReachable(): HashSet[Rune] =
  ## Collect every codepoint the desktop UI can draw as part of an item's own text.
  ##   Drawn from the tables themselves, so this grows with them. What it deliberately
  ##   does not cover is text written literally at a call site -- a button caption, a
  ##   section heading -- which is plain Latin the base range covers wholesale.
  # Each table entry is bound to a local before being walked: `runes` takes an open array
  #   over its argument, and over a temporary read straight out of a `const` array that
  #   open array outlives what it points at -- measured here as a segfault on the first
  #   entry, not a subtle wrong answer.
  for operation in Operation:
    let notation = $lut_operation_to_notation[operation]
    for rune in runes(notation): result.incl(rune)
  for b in Basis:
    let name = lut_basis_to_name[b]
    for rune in runes(name): result.incl(rune)
  # Every shape word, taken from the writer rather than by listing them: a point, a line
  #   and a plane, each finite and each at the horizon, plus a mixed grade that is none of
  #   them, is every branch `describeShape` has.
  let
    place = toMultivector(Position(x: 1.0, y: 2.0, z: 3.0))
    other = toMultivector(Position(x: -2.0, y: 1.0, z: 4.0))
    third = toMultivector(Position(x: 0.0, y: -3.0, z: 1.0))
    line = place ∧ other
    plane = line ∧ third
  for m in [place, line, plane, ⊖ place, ⊖ line, ⊖ plane, 1.0 + place]:
    let word = shapeText(m)
    for rune in runes(word): result.incl(rune)
  # A magnitude contributes digits, a sign, a point and an exponent marker; take them from
  #   the formatter rather than assuming which characters it reaches for.
  for value in [0.0, -1.5, 6.02e23, 1.0e-7]:
    let printed = multivectorText(initElement(Basis.scalar, value))
    for rune in runes(printed): result.incl(rune)



#[ Declared Ranges ]#

type Range = object ## Hold one inclusive span of codepoints the atlas builds glyphs for.
  first*, last*: int

proc rangesDeclared(path: string): seq[Range] =
  ## Read every glyph range `gui_shim.cpp` declares, from the file itself.
  ##   Parsed rather than mirrored: a mirror of a C++ array in Nim is a second copy of the
  ##   thing being checked, and would pass happily while the compiled atlas disagreed.
  ##   Looks only at lines inside an `ImWchar RANGES...[] = {` block, so a hex literal
  ##   anywhere else in the file cannot widen what this believes is covered.
  var is_inside = false
  for line in lines(path):
    let trimmed = line.strip()
    if "ImWchar RANGES" in trimmed and trimmed.endsWith("{"):
      is_inside = true
      continue
    if not is_inside: continue
    if trimmed.startsWith("}"):
      is_inside = false
      continue
    let fields = trimmed.split(',')
    if len(fields) < 2: continue
    let (first, last) = (fields[0].strip(), fields[1].strip())
    if not (first.startsWith("0x") and last.startsWith("0x")): continue
    result.add(Range(first: parseHexInt(first), last: parseHexInt(last)))


func covers(ranges: openArray[Range]; rune: Rune): bool =
  ## Report whether any declared range holds `rune`.
  for span in ranges:
    if int(rune) >= span.first and int(rune) <= span.last: return true
  false



#[ Report ]#

proc main() =
  ## Report coverage of every reachable codepoint, exiting non-zero on any gap.
  if not fileExists(PATH_SHIM):
    echo &"Cannot read `{PATH_SHIM}`; run this from the project root."
    quit(2)
  let ranges = rangesDeclared(PATH_SHIM)
  if len(ranges) == 0:
    echo &"Read no glyph ranges from `{PATH_SHIM}`; its declaration shape has changed."
    quit(2)

  var reachable = toSeq(codepointsReachable())
  reachable.sort(proc (a, b: Rune): int = cmp(int(a), int(b)))

  var missing: seq[Rune]
  for rune in reachable:
    # Space and the control range below it are never drawn as a glyph, so a font that has
    #   no glyph for them is not a gap; every printable codepoint is.
    if int(rune) <= 0x20: continue
    if not ranges.covers(rune): missing.add(rune)

  echo &"{len(ranges)} declared ranges cover {len(reachable)} reachable codepoints:"
  for rune in reachable:
    if int(rune) <= 0x20: continue
    let mark = if rune in missing: "MISSING" else: "  ok   "
    echo &"{mark} U+{int(rune):04X}  {$rune}"
  if len(missing) > 0:
    echo &"\n{len(missing)} codepoint(s) fall outside every declared range."
    quit(1)
  echo &"\nEvery reachable codepoint is covered."


main()
