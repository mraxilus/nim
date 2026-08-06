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

import std/[math, strutils]



#[ Binding Configuration ]#

const HEADER = "<stdio.h>"
  ## Name header the C runtime's own formatter is imported through.

# Mechanical one-to-one import of the C runtime's own formatter; see its manual page.
#   Guarded rather than left to fail at run time: the JS backend happily *compiles* an
#   `importc` it has no definition for and only throws `snprintf is not defined` when the
#   call is finally reached, which is a browser crash rather than a build error. Every
#   appender below that needs it is guarded to match, so shared code reaching for one is a
#   compile error on the browser build instead.
when not defined(js):
  proc snprintf(buffer: cstring; size: csize_t; format: cstring): cint
    {.importc: "snprintf", header: HEADER, varargs, discardable, noSideEffect.}



#[ Significant Digits Without C ]#

const DIGITS_SIGNIFICANT* = 4
  ## Show a magnitude to this many significant digits, wherever one is shown: enough to
  ## tell coefficients apart, few enough that sixteen of them fit a panel.

func roundHalfToEven(value: float): float =
  ## Round to the nearest whole number, breaking an exact half toward the even one.
  ##   The rule C's own formatter rounds decimal digits by, and the reason this exists:
  ##   Nim's `round` breaks a half away from zero instead, so the two answer differently
  ##   on every exact tie -- 1012.5 to 1012 here against 1013 there.
  let
    whole = floor(value)
    fraction = value - whole
  if fraction > 0.5: whole + 1.0
  elif fraction < 0.5: whole
  elif whole mod 2.0 == 0.0: whole
  else: whole + 1.0


func formatMagnitude*(value: float): string =
  ## Format `value` to `DIGITS_SIGNIFICANT` significant digits, as `appendMagnitude`'s own
  ## `%.4g` does, without needing a C runtime to do it.
  ##   For the browser build, which has no `snprintf` to call.
  ##   Allocates, unlike everything else here: a browser rebuilds its number fields when
  ##   the grid changes rather than once per item per frame, so there is no per-frame
  ##   allocation to avoid. Do not call it from the desktop's draw loop.
  ##   `%g`'s own rule, from the C standard: take the exponent the value rounds to at this
  ##   precision, write it scientifically where that exponent falls outside
  ##   [-4, DIGITS_SIGNIFICANT), and fixed otherwise; either way trailing zeros go.
  ##
  ##   **Derives its own digits rather than asking the runtime for them, and that is the
  ##   whole point.** Handing the job to `formatBiggestFloat` lands on whatever decimal
  ##   conversion the backend happens to have, and the two do not agree: measured over
  ##   7000 values, the C and JS backends returned different text for 330 of them --
  ##   10.125 read `10.12` on the desktop and `10.13` in the browser, because C rounds an
  ##   exact tie to even and JavaScript rounds it away from zero. The same value must read
  ##   the same in both front-ends, so the rounding rule is stated here.
  ##   Scales by *multiplying* by a positive power of ten wherever it can rather than
  ##   dividing by a negative one: 10^k is exact as a double for k in 0 .. 22, while 10^-k
  ##   never is, and dividing by an inexact divisor moves a true tie off the half and
  ##   silently rounds it the other way.
  func trimmed(text: string): string =
    ## Drop trailing zeros, and a point left bare by dropping them.
    if '.' notin text: return text
    result = text.strip(leading = false, trailing = true, chars = {'0'})
    result = result.strip(leading = false, trailing = true, chars = {'.'})

  if value != value: return "nan"
  if value == Inf: return "inf"
  if value == -Inf: return "-inf"
  if value == 0.0: return "0"

  let sign = if value < 0.0: "-" else: ""
  var exponent = int(floor(log10(abs(value))))

  func scaledTo(value: float; exponent: int): float =
    ## Carry `value`'s leading `DIGITS_SIGNIFICANT` digits into the whole-number range.
    let shift = DIGITS_SIGNIFICANT - 1 - exponent
    if shift >= 0: abs(value)*pow(10.0, float(shift))
    else: abs(value)/pow(10.0, float(-shift))

  var scaled = roundHalfToEven(scaledTo(value, exponent))

  # Rounding can carry into another digit, taking 9999.6 to 10000; the exponent the text
  #   is written around has to follow it.
  if scaled >= pow(10.0, float(DIGITS_SIGNIFICANT)):
    exponent += 1
    scaled = roundHalfToEven(scaledTo(value, exponent))
  elif scaled < pow(10.0, float(DIGITS_SIGNIFICANT - 1)):
    exponent -= 1
    scaled = roundHalfToEven(scaledTo(value, exponent))

  let digits = $int(scaled)
  if exponent < -4 or exponent >= DIGITS_SIGNIFICANT:
    # C writes at least two exponent digits; Nim writes as few as one.
    let
      magnitude = abs(exponent)
      sign_exponent = if exponent < 0: "-" else: "+"
      padding = if magnitude < 10: "0" else: ""
    sign & trimmed(digits[0 .. 0] & "." & digits[1 .. ^1]) &
      "e" & sign_exponent & padding & $magnitude
  elif exponent >= 0:
    let count_integer = exponent + 1
    sign & trimmed(digits[0 ..< count_integer] & "." & digits[count_integer .. ^1])
  else:
    sign & trimmed("0." & repeat('0', -exponent - 1) & digits)



#[ Fixed Text Buffers ]#

func bytesCharacter*(lead: char): int =
  ## Say how many bytes the UTF-8 character starting with this byte occupies.
  ##   One for ASCII and for any byte that is not a valid lead, so a buffer holding
  ##   something that is not UTF-8 at all still advances a byte at a time rather than
  ##   stalling. The three multi-byte widths are what this project actually writes:
  ##   operator notation (`∧`, `∨`, `⊖`) is three bytes each, and subscripts and the
  ##   ellipsis below are too.
  let value = uint8(lead)
  if value < 0x80: 1
  elif value < 0xC0: 1 # A stray continuation byte; not a lead, so not a character start.
  elif value < 0xE0: 2
  elif value < 0xF0: 3
  else: 4


func lengthFitting*(text: openArray[char]; capacity: int): int =
  ## Measure how many leading bytes of `text` fit in `capacity` **without splitting a
  ## character**, which is always a whole number of characters.
  ##   Separate from the copy below so the boundary rule is stated once: `toChars` needs
  ##   the same answer against a smaller capacity, to leave room for the mark it adds.
  let bound = min(capacity, len(text))
  while result < len(text):
    let width = bytesCharacter(text[result])
    if result + width > bound: break
    result += width


proc appendChars*(storage: var openArray[char]; cursor: var int; text: openArray[char]) =
  ## Copy as much of `text` as still fits after `cursor`, advancing it.
  ##   Silently truncates rather than overrunning `storage`, exactly as `toChars` does;
  ##   storage is display only, and the GUI must never write past its own buffer.
  ##   **Truncates whole characters, never part of one.** Copying byte by byte until the
  ##   buffer filled used to cut a three-byte operator in half, and the invalid tail left
  ##   behind reached the browser as a literal `%e2%8a` where a glyph should have been --
  ##   Nim's JS backend percent-escapes what it cannot decode. A buffer measured in bytes
  ##   and a text measured in characters is the same mismatch the `.rgascene` label field
  ##   had; this is the other half of it, in the store beside it.
  for offset in 0 ..< lengthFitting(text, len(storage) - 1 - cursor):
    storage[cursor] = text[offset]
    inc cursor


func toText*(storage: openArray[char]): string =
  ## Read fixed char storage back into a string, stopping at its terminator.
  ##   Inverse of `scene.toChars`, and the only reading of one of these buffers that
  ##   answers the same on both render paths: `$scene.toCstring` reads the storage's
  ##   *address*, which the JS backend has no notion of, and measured there it yields an
  ##   empty string rather than the text held. The suite runs on both backends, so a
  ##   regression to that pattern in shared code fails a test rather than shipping.
  for ch in storage:
    if ch == '\0': return
    result.add(ch)


proc appendMagnitude*(storage: var openArray[char]; cursor: var int; value: float) =
  ## Format `value` to `DIGITS_SIGNIFICANT` significant digits straight into `storage`.
  ##   Significant digits, not decimal places, and no `#` flag: a coefficient of 3.5 reads
  ##   `3.5` rather than `3.5000`, and one of 1664 keeps its integer part.
  ##   Shared, so both render paths print a coefficient identically, and each reaches that
  ##   through whatever costs it least: the desktop redraws every visible item's sixteen
  ##   coefficients every frame and goes through C's own formatter to touch no heap doing
  ##   it, while the browser has no C runtime and states the same rule in `formatMagnitude`
  ##   at the cost of one string. That the two agree is not assumed -- the suite's
  ##   `magnitudesAgree` holds them to the same answer, and a change to either is not
  ##   finished until it still passes.
  when defined(js):
    appendChars(storage, cursor, formatMagnitude(value))
  else:
    var buffer: array[32, char]
    let count = snprintf(
      cast[cstring](addr buffer[0]), csize_t(len(buffer)),
      cstring("%." & $DIGITS_SIGNIFICANT & "g"), value
    )
    appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


when not defined(js):
  proc appendInt*(storage: var openArray[char]; cursor: var int; value: int) =
    ## Format `value` as a plain decimal integer straight into `storage`.
    ##   Every caller here counts something small and bounded (items, vertices, frames
    ##   per second), so narrowing to `cint` never truncates a real value.
    ##   Desktop-only, with `appendFixed` below: both serve the diagnostics panel, which
    ##   has no browser counterpart, so neither has earned a second statement of its rule
    ##   the way `appendMagnitude` above has.
    var buffer: array[24, char]
    let count =
      snprintf(cast[cstring](addr buffer[0]), csize_t(len(buffer)), "%d", cint(value))
    appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


  proc appendFixed*(
    storage: var openArray[char]; cursor: var int; value: float; digits: int
  ) =
    ## Format `value` to a fixed number of digits after the point, matching what
    ## `strformat`'s own `:.Nf` writes, straight into `storage`.
    ##   Desktop-only, with `appendInt` above; see its own doc comment.
    var buffer: array[32, char]
    let count = snprintf(
      cast[cstring](addr buffer[0]), csize_t(len(buffer)), "%.*f", cint(digits), value
    )
    appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


proc finishChars*(storage: var openArray[char]; cursor: int) =
  ## Zero every byte from `cursor` onward, so text a longer previous write left behind
  ## can never trail past whatever was written this time.
  for i in cursor ..< len(storage): storage[i] = '\0'



#[ One-Line Assembly ]#

when not defined(js):
  template buildChars*(storage: var openArray[char]; body: untyped): cstring =
    ## Zero a fresh `cursor`, run `body` -- a sequence of `append*` calls against
    ## `storage` and that injected `cursor` -- then terminate and return a pointer
    ## into `storage`, so building one line of text costs only the calls that vary
    ## between call sites, not the `cursor`/`finishChars`/cast boilerplate around them.
    ##   Desktop-only for the same reason `scene.toCstring` is: it hands back an address,
    ##   which is what Dear ImGui takes and what the JS backend has no notion of. A
    ##   browser caller wanting the text itself wants `toText` on the storage instead.
    block:
      var cursor {.inject.} = 0
      body
      finishChars(storage, cursor)
      cast[cstring](unsafeAddr storage[0])
