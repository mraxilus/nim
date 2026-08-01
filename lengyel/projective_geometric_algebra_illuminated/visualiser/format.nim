## Format numbers into fixed char storage without touching the heap.
##
## Nim's own `$` and `strformat` always produce a heap-allocated `string`, refcounted
## like every other Nim `string`; C's own `snprintf` writes into storage the caller
## already owns instead. Every visible item's coefficients are redrawn this way, once
## per item, every frame, so the difference is an allocator call per number, per item,
## per frame, against none at all.
##
## Sits beside `sdl3`, `opengl` and `image` as a binding over something external -- here
## the C runtime's own formatter -- rather than beside `scene` or `mesh`, which hold
## this project's own logic.
##
## `snprintf` is a C entry point, so the browser build cannot reach it. What a magnitude
## should *read* as is this project's own rule rather than C's, so `formatMagnitude`
## states it in plain Nim for that build to use, and `magnitudesAgree` in the test suite
## holds the two to the same answer.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths, transitively through `interaction`; see `visualiser.nim`'s own
## "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[strutils]



#[ Binding Configuration ]#

const HEADER = "<stdio.h>"
  ## Name header the C runtime's own formatter is imported through.

# Mechanical one-to-one import of the C runtime's own formatter; see its manual page.
proc snprintf(buffer: cstring; size: csize_t; format: cstring): cint
  {.importc: "snprintf", header: HEADER, varargs, discardable, noSideEffect.}



#[ Significant Digits Without C ]#

const DIGITS_SIGNIFICANT* = 4
  ## Show a magnitude to this many significant digits, wherever one is shown: enough to
  ## tell coefficients apart, few enough that sixteen of them fit a panel.

func formatMagnitude*(value: float): string =
  ## Format `value` to `DIGITS_SIGNIFICANT` significant digits, as `appendMagnitude`'s own
  ## `%.4g` does, without needing a C runtime to do it.
  ##   For the browser build, which has no `snprintf` to call. Nim's own `g` is no help
  ##   here: under the JS backend it ignores the precision asked for and returns the
  ##   shortest round-tripping form instead, so 1234567 stays 1234567 where C writes
  ##   `1.235e+06`. Its `ffScientific` and `ffDecimal` do honour precision on both
  ##   backends, so the rule is stated over those two.
  ##   Allocates, unlike everything else here: a browser rebuilds its number fields when
  ##   the grid changes rather than once per item per frame, so there is no per-frame
  ##   allocation to avoid. Do not call it from the desktop's draw loop.
  ##   `%g`'s own rule, from the C standard: take the exponent the value rounds to at this
  ##   precision, write it scientifically where that exponent falls outside
  ##   [-4, DIGITS_SIGNIFICANT), and fixed otherwise; either way trailing zeros go.
  func trimmed(text: string): string =
    ## Drop trailing zeros, and a point left bare by dropping them.
    if '.' notin text: return text
    result = text.strip(leading = false, trailing = true, chars = {'0'})
    result = result.strip(leading = false, trailing = true, chars = {'.'})

  let scientific = formatBiggestFloat(value, ffScientific, DIGITS_SIGNIFICANT - 1)
  let split = scientific.rfind('e')
  let exponent = parseInt(scientific[split + 1 .. ^1])
  if exponent < -4 or exponent >= DIGITS_SIGNIFICANT:
    # C writes at least two exponent digits; Nim writes as few as one.
    let magnitude = abs(exponent)
    let sign = if exponent < 0: "-" else: "+"
    let padding = if magnitude < 10: "0" else: ""
    trimmed(scientific[0 ..< split]) & "e" & sign & padding & $magnitude
  else:
    trimmed(formatBiggestFloat(value, ffDecimal, DIGITS_SIGNIFICANT - 1 - exponent))



#[ Fixed Text Buffers ]#

proc appendChars*(storage: var openArray[char]; cursor: var int; text: openArray[char]) =
  ## Copy as much of `text` as still fits after `cursor`, advancing it.
  ##   Silently truncates rather than overrunning `storage`, exactly as `toChars` does;
  ##   storage is display only, and the GUI must never write past its own buffer.
  for ch in text:
    if cursor >= len(storage) - 1: return
    storage[cursor] = ch
    inc cursor


proc appendMagnitude*(storage: var openArray[char]; cursor: var int; value: float) =
  ## Format `value` to `DIGITS_SIGNIFICANT` significant digits straight into `storage`,
  ## through C's own formatter, so printing a coefficient never allocates a Nim string
  ## just to hold it.
  ##   Significant digits, not decimal places, and no `#` flag: a coefficient of 3.5 reads
  ##   `3.5` rather than `3.5000`, and one of 1664 keeps its integer part.
  ##   `formatMagnitude` above states the same rule for the browser build; a change to
  ##   either is not finished until the suite's `magnitudesAgree` still passes.
  var buffer: array[32, char]
  let count = snprintf(
    cast[cstring](addr buffer[0]), csize_t(len(buffer)),
    cstring("%." & $DIGITS_SIGNIFICANT & "g"), value
  )
  appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


proc appendInt*(storage: var openArray[char]; cursor: var int; value: int) =
  ## Format `value` as a plain decimal integer straight into `storage`.
  ##   Every caller here counts something small and bounded (items, vertices, frames
  ##   per second), so narrowing to `cint` never truncates a real value.
  var buffer: array[24, char]
  let count = snprintf(cast[cstring](addr buffer[0]), csize_t(len(buffer)), "%d", cint(value))
  appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


proc appendFixed*(storage: var openArray[char]; cursor: var int; value: float; digits: int) =
  ## Format `value` to a fixed number of digits after the point, matching what
  ## `strformat`'s own `:.Nf` writes, straight into `storage`.
  var buffer: array[32, char]
  let count =
    snprintf(cast[cstring](addr buffer[0]), csize_t(len(buffer)), "%.*f", cint(digits), value)
  appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


proc finishChars*(storage: var openArray[char]; cursor: int) =
  ## Zero every byte from `cursor` onward, so text a longer previous write left behind
  ## can never trail past whatever was written this time.
  for i in cursor ..< len(storage): storage[i] = '\0'



#[ One-Line Assembly ]#

template buildChars*(storage: var openArray[char]; body: untyped): cstring =
  ## Zero a fresh `cursor`, run `body` -- a sequence of `append*` calls against
  ## `storage` and that injected `cursor` -- then terminate and return a pointer
  ## into `storage`, so building one line of text costs only the calls that vary
  ## between call sites, not the `cursor`/`finishChars`/cast boilerplate around them.
  block:
    var cursor {.inject.} = 0
    body
    finishChars(storage, cursor)
    cast[cstring](unsafeAddr storage[0])
