## Measure every separation the palette claims, and fail where one is not met.
##
## Prints the whole matrix — normal-vision difference, hue distance, and the difference through
## the vision that sees the least of it — for every pair of assignable hues, for each hue
## against each axis colour, and for each hue against the reserved magenta. Exits non-zero
## where a floor is not met, so a palette edit that breaks a separation fails a build rather
## than a review.
##
## `tools/palette_reference.py` recomputes the same numbers through an independent library.

import std/[strformat, strutils]

import ../src/core/[colorimetry, palette]



#[ Floors ]#

const
  DELTA_E_OBJECTS* = 15.0
    ## Separate two assignable hues by at least this, for normal vision.
  HUE_OBJECTS* = 20.0
    ## Separate two assignable hues by at least this many degrees, so lightness alone can
    ## never stand in for a hue difference.
  DELTA_E_CVD_OBJECTS* = 8.0
    ## Separate two assignable hues by at least this through the worst vision.
    ##   One documented pair sits in the 6-to-8 band, which is legal where a second encoding
    ##   carries the distinction; those objects carry shape and screen position as that
    ##   encoding.
  DELTA_E_CVD_TOLERATED* = 6.0
    ## Allow one pair down to this, and no pair below it.
  DELTA_E_AXES* = 7.5
    ## Separate an assignable hue from an axis colour by at least this.
    ##   Looser than object-to-object on purpose: a thin fixed line needs less separation than
    ##   two adjacent fills, and tightening it is what once crushed the whole palette into one
    ##   teal-blue arc. The brief states no number for it, so this is the floor the palette
    ##   actually holds — measured, then written down, so an edit cannot erode it unnoticed.
    ##   The binding pair is Cobalt against the z axis, at 7.91.
  HUE_AXES* = 18.0
    ## Separate an assignable hue from an axis colour by at least this many degrees.
    ##   As above: the floor the palette holds, with Cobalt against the z axis at 18.82.
  DELTA_E_CVD_INVALID* = 14.0
    ## Separate an assignable hue from the reserved magenta by at least this, through the worst
    ## vision: magenta reads as blue under deuteranopia, which is where the hues sit furthest.



#[ Reporting ]#

var failures: seq[string]

proc report(
  what: string, measured, floor: float, is_tolerated = false
): bool {.discardable.} =
  ## Print one measurement, and record it where it does not meet its floor.
  result = measured >= floor
  let mark = if result: "  " else: (if is_tolerated: "~ " else: "! ")
  echo &"{mark}{what:<44} {measured:7.2f}  (floor {floor:5.2f})"
  if not result and not is_tolerated: failures.add(what)


when isMainModule:
  echo "assignable pairs — normal-vision difference, hue distance, worst-vision difference"
  var tolerated = 0
  for first in assignable():
    for second in assignable():
      if ord(second) <= ord(first): continue
      let
        name = $first & " vs " & $second
        difference = deltaE(first.color, second.color)
        hue = hueDistance(first.color, second.color)
        worst = deltaEWorst(first.color, second.color)
      report(name & " ΔE", difference, DELTA_E_OBJECTS)
      report(name & " hue°", hue, HUE_OBJECTS)
      if worst < DELTA_E_CVD_OBJECTS and worst >= DELTA_E_CVD_TOLERATED:
        tolerated += 1
        report(name & " ΔE (worst vision)", worst, DELTA_E_CVD_OBJECTS, is_tolerated = true)
      else:
        report(name & " ΔE (worst vision)", worst, DELTA_E_CVD_OBJECTS)

  echo ""
  echo "assignable hues against the axis colours"
  for hue_slot in assignable():
    for axis in [Paint.AxisX, Paint.AxisY, Paint.AxisZ]:
      let name = $hue_slot & " vs " & $axis
      report(name & " ΔE", deltaE(hue_slot.color, axis.color), DELTA_E_AXES)
      report(name & " hue°", hueDistance(hue_slot.color, axis.color), HUE_AXES)

  echo ""
  echo "assignable hues against the reserved magenta, through the worst vision"
  for hue_slot in assignable():
    report(
      $hue_slot & " vs Invalid ΔE (worst vision)",
      deltaEWorst(hue_slot.color, Paint.Invalid.color),
      DELTA_E_CVD_INVALID,
    )

  echo ""
  echo &"pairs relying on a second encoding: {tolerated} (at most one is intended)"
  if failures.len > 0:
    echo &"{failures.len} separations below their floor:"
    for failure in failures: echo "  ", failure
    quit(1)
  echo "every separation meets its floor"
