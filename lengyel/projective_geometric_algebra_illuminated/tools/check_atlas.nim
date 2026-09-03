## Hold desktop font atlas to text visualiser can put on screen.
##
## Enumerates every codepoint reachable in UI text from tables that produce it.
##   Operation notation, basis element names, shape words.
##   Then reads glyph ranges `gui_shim.cpp` builds atlas from and reports any codepoint no
##   range covers.
##   Codepoint outside every range renders as tofu box.
## Both sides are read from source rather than transcribed.
##   Codepoints from same `lut_*` tables panel draws, ranges from `gui_shim.cpp` itself.
##   Neither can drift from what is compiled without this noticing.
## Covers desktop atlas only.
##   Browser embeds whole faces; its coverage is question about font files rather than
##   ranges.
## Build and run from project root:
##   bin/nim c --hints:off -o:bin/check_atlas tools/check_atlas.nim && bin/check_atlas

import std/[algorithm, os, sequtils, sets, strformat, strutils, unicode]

import ../pga
import ../visualiser/core/[boundary, scene]



#[ Source Locations ]#

const PATH_SHIM = "visualiser/desktop/gui_shim.cpp"
  ## Name where atlas ranges are declared, relative to project root this is run from.



#[ Reachable Codepoints ]#

proc codepointsReachable(): HashSet[Rune] =
  ## Collect every codepoint desktop UI can draw as part of item's text.
  ##   Drawn from tables themselves, so this grows with them.
  ##   Not covered: text written literally at call site (button caption, section
  ##   heading), plain Latin base range covers wholesale.
  # Bind each table entry to local before walking it.
  #   `runes` takes open array over its argument, and over temporary read from `const`
  #   array that open array outlives what it points at; segfaults on first entry.
  for operation in Operation:
    let notation = $lut_operation_to_notation[operation]
    for rune in runes(notation): result.incl(rune)
  for b in Basis:
    let name = lut_basis_to_name[b]
    for rune in runes(name): result.incl(rune)
  # Take every shape word from writer rather than by listing.
  #   Point, line and plane, each finite and at horizon, plus mixed grade, is every branch
  #   `describeShape` has.
  let
    place = toMultivector(Position(x: 1.0, y: 2.0, z: 3.0))
    other = toMultivector(Position(x: -2.0, y: 1.0, z: 4.0))
    third = toMultivector(Position(x: 0.0, y: -3.0, z: 1.0))
    line = place ∧ other
    plane = line ∧ third
  for m in [place, line, plane, ⊖ place, ⊖ line, ⊖ plane, 1.0 + place]:
    let word = shapeText(m)
    for rune in runes(word): result.incl(rune)
  # Take digits, sign, point and exponent marker from formatter rather than assuming.
  for value in [0.0, -1.5, 6.02e23, 1.0e-7]:
    let printed = multivectorText(initElement(Basis.scalar, value))
    for rune in runes(printed): result.incl(rune)



#[ Declared Ranges ]#

type Range = object ## Define one inclusive span of codepoints atlas builds glyphs for.
  first*, last*: int

proc rangesDeclared(path: string): seq[Range] =
  ## Read every glyph range `gui_shim.cpp` declares, from file itself.
  ##   Parsed rather than mirrored: mirror of C++ array in Nim is second copy of thing
  ##   being checked.
  ##   Looks only at lines inside `ImWchar RANGES...[] = {` block, so hex literal
  ##   elsewhere cannot widen what this believes is covered.
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
    # Skip space and control range below it, never drawn as glyph.
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
