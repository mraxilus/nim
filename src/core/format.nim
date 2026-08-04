## Format every editable number the tool shows, to four significant digits.
##
## Four significant digits, not four decimal places: `3.5` reads `3.5`, `1664` keeps its
## integer part, `1234567` becomes `1.235e+06`. No trailing zeros, no trailing point.
##
## Two mechanisms exist because a C runtime is not available in a browser. `formatRuntime`
## hands the job to the platform's own `%g`; `formatPortable` derives the digits itself and
## runs on both backends. The tool always calls `format`, which is the portable one, so the
## two targets cannot disagree in the field; `tests/suite.nim` runs both over the same values
## and asserts they agree, which is what keeps the runtime path honest as a reference.
##   Nim's own `formatFloat` is not that reference: on the JS backend it ignores the requested
##   precision and returns the shortest round-tripping form instead.
##
## The two agree on every value but one: the platform writes negative zero as `-0`, and this
## tool writes `0`, because a sign on nothing reads as a bug in a coefficient field. The test
## pins that one difference rather than hiding it.

{.experimental: "strictFuncs".}

import std/[math, strutils]



#[ Formatting ]#

const
  SIGNIFICANT_DIGITS* = 4
    ## Count digits every magnitude reads to.
  DIAGNOSTIC_DECIMALS* = 2
    ## Count decimals a diagnostics reading holds, fixed so a live number stops changing width.


func formatPortable*(value: float): string =
  ## Format value to four significant digits, deriving each digit rather than printing floats.
  ##   Follows `%.4g`: scientific below 1e-4 or from 1e4 up, fixed in between, zeros stripped.
  if value.isNaN: return "nan"
  if value == Inf: return "inf"
  if value == -Inf: return "-inf"
  if value == 0.0: return "0"  # Negative zero reads as zero: a sign on nothing reads as a bug.

  let sign = if value < 0: "-" else: ""
  var
    exponent = floor(log10(abs(value))).int
    scaled = (abs(value) / pow(10.0, (exponent - SIGNIFICANT_DIGITS + 1).float)).round

  # Correct the exponent where rounding carried into another digit, e.g. 9999.6 to 10000.
  if scaled >= pow(10.0, SIGNIFICANT_DIGITS.float):
    scaled = scaled / 10.0
    exponent += 1
  elif scaled < pow(10.0, (SIGNIFICANT_DIGITS - 1).float):
    scaled = scaled * 10.0
    exponent -= 1

  var digits = $scaled.int  # Exactly SIGNIFICANT_DIGITS characters, by the correction above.

  # Emit scientific form where the fixed form would be unreadably long.
  if exponent < -4 or exponent >= SIGNIFICANT_DIGITS:
    var mantissa = digits[0 .. 0] & "." & digits[1 .. ^1]
    mantissa = mantissa.strip(leading = false, trailing = true, chars = {'0'})
    mantissa = mantissa.strip(leading = false, trailing = true, chars = {'.'})
    let
      exponent_sign = if exponent < 0: "-" else: "+"
      exponent_digits = align($abs(exponent), 2, '0')
    return sign & mantissa & "e" & exponent_sign & exponent_digits

  # Emit fixed form, placing the point by the exponent.
  if exponent >= 0:
    let integer_digits = exponent + 1
    result = sign & digits[0 ..< integer_digits]
    if integer_digits < digits.len:
      let fraction = digits[integer_digits .. ^1].strip(
        leading = false, trailing = true, chars = {'0'}
      )
      if fraction.len > 0: result &= "." & fraction
  else:
    let leading_zeros = -exponent - 1
    var fraction = repeat('0', leading_zeros) & digits
    fraction = fraction.strip(leading = false, trailing = true, chars = {'0'})
    result = sign & "0." & fraction


when not defined(js):
  proc snprintf(
    buffer: cstring, size: csizeT, format: cstring
  ): cint {.importc, varargs, header: "<stdio.h>", discardable.}
    ## Call the C library's own formatter, the reference the portable path is measured against.
    ##   Nim's `%g` equivalents are reimplementations rather than the platform's: one keeps
    ##   trailing zeros, and on the JS backend another ignores the requested precision and
    ##   returns the shortest round-tripping form. Neither is the thing to agree with.

  func formatRuntime*(value: float): string =
    ## Format value through the platform's own `%g`, as the reference the portable path meets.
    if value.isNaN: return "nan"
    if value == Inf: return "inf"
    if value == -Inf: return "-inf"
    var buffer: array[32, char]
    {.cast(noSideEffect).}:
      discard snprintf(cast[cstring](addr buffer[0]), csizeT(buffer.len), "%.4g", value)
    $cast[cstring](addr buffer[0])


func format*(value: float): string {.inline.} = formatPortable(value)
  ## Format every editable number the tool shows: coefficients and all seven camera fields.


func formatFixed*(value: float): string =
  ## Format diagnostics reading to a fixed width, so a live number stops jumping about.
  if value.isNaN: return "nan"
  if value == Inf: return "inf"
  if value == -Inf: return "-inf"
  let
    scale = pow(10.0, DIAGNOSTIC_DECIMALS.float)
    rounded = (value * scale).round.int
    sign = if rounded < 0: "-" else: ""
    magnitude = abs(rounded)
    whole = magnitude div scale.int
    fraction = magnitude mod scale.int
  sign & $whole & "." & align($fraction, DIAGNOSTIC_DECIMALS, '0')


func parseNumber*(text: string): float =
  ## Read a number back from an edited field, holding the previous value on nonsense.
  ##   Returns zero for empty or unparseable text; callers keep their own previous value
  ##   where that matters.
  try: parseFloat(text.strip()) except ValueError: 0.0
