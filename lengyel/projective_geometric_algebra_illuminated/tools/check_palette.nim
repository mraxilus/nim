## Hold the palette to the separation floors `REQUIREMENTS.md` states for it.
##
## Reads `mesh.lut_ink_to_rgba` itself rather than a transcription of it, so this cannot
## pass against a table the visualiser no longer draws from. Reports every measurement it
## makes, pass or fail, and exits non-zero on any failure, so it can gate a commit.
##
## The floors are not invented here. Each is quoted from `REQUIREMENTS.md`'s own palette
## section beside the check that enforces it; changing one means changing both, and saying
## in `PROVENANCE.md` what was measured to justify it.
##
## Build and run:
##   ../../bin/nim c --hints:off -o:../bin/check_palette check_palette.nim && ../bin/check_palette

import std/[options, strformat, strutils, wordwrap]

import ../visualiser/core/mesh
import ./colour



#[ Stated Floors ]#

const
  SEPARATION_ASSIGNABLE_NORMAL = 15.0
    ## Floor every pair of assignable hues clears to typical vision, so lightness can
    ## never stand in for a hue difference.
  DEGREES_ASSIGNABLE = 20.0
    ## Hue-angle floor the same pairs clear, for the same reason.
  SEPARATION_ASSIGNABLE_CVD = 6.0
    ## Floor every pair of assignable hues clears under red-green deficiency. The band
    ## 6 .. 8 is legal only where a secondary encoding carries identity too; here shape and
    ## screen position do, since two objects are never the same shape in the same place.
  SEPARATION_ASSIGNABLE_TRITAN = 6.0
    ## Same floor under tritanopia, measured separately rather than folded into the
    ## red-green minimum; see `colour.separationRedGreen` for why.
  SEPARATION_INVALID_CVD = 13.0
    ## Floor every assignable hue clears against the reserved magenta under red-green
    ## deficiency -- higher than the assignable-to-assignable floor because magenta means
    ## *wrong*, and reading an ordinary object as an invalid one is a worse error than
    ## confusing two ordinary objects.
  SEPARATION_AXIS_CVD = 4.0
    ## Floor every assignable hue clears against each world axis under red-green
    ## deficiency. Deliberately looser than the object-to-object floors: an axis is a thin
    ## fixed line through the origin, never a fill, and tightening this is what once
    ## crushed the whole palette into a single teal-blue arc.





#[ Declared Exceptions ]#

type Exception = object ## Hold one measurement allowed to sit below its stated floor.
  description*: string ## The measurement excused, spelled exactly as `record` names it.
  floor*: float ## What it must still clear, pinned just under where it measures today so
    ## that drifting further fails the run rather than widening the excuse.
  reason*: string ## Why it is tolerable, in the terms the palette's own rules are in.

const EXCEPTIONS = [
  Exception(
    description: "Jade / Cobalt, tritanopia",
    floor: 3.5,
    reason: "teal and blue converge under tritanopia, which no floor covered until this " &
      "tool measured it; carried rather than repainted because tritanopia is rarer than " &
      "one reader in ten thousand, the pair clears 12.7 under red-green deficiency and " &
      "15.8 to typical vision, and every object also carries its own shape, screen " &
      "position and written label",
  ),
] ## Every measurement knowingly below its floor. An exception is a decision recorded in
  ## source, not a floor quietly lowered: the floor still applies to every other pair, the
  ## excused pair still has a floor of its own, and the reason is printed on every run so
  ## it stays argued rather than inherited.


func exceptionFor(description: string): Option[Exception] =
  ## Find the declared exception covering a measurement, if one is declared.
  for excused in EXCEPTIONS:
    if excused.description == description: return some(excused)
  none(Exception)



#[ Measurement ]#

type Finding = object ## Hold one measurement and whether it cleared its floor.
  description: string ## What was measured, named as a reader would name it.
  measured: float ## What it came to.
  floor: float ## What it had to clear.
  units: string ## What the two numbers are in, for the report.

var findings: seq[Finding]
  ## Every measurement made, in the order made. A `seq` rather than a fixed array
  ## because this is a tool run once from a shell, not the visualiser's own hot path --
  ## `STYLE.md`'s ban on runtime `seq` is about the frame loop, and is noted as such.

proc record(description: string; measured, floor: float; units = "ΔE") =
  ## Record one measurement against its floor.
  findings.add(Finding(
    description: description, measured: measured, floor: floor, units: units
  ))


func linearOf(ink: Ink): Linear =
  ## Read one palette slot as linear light, from the visualiser's own table.
  let rgba = ink.colour
  toLinear(float(rgba.red), float(rgba.green), float(rgba.blue))


proc main() =
  ## Measure every stated constraint and report, exiting non-zero if any failed.
  const ASSIGNABLE = [Ink.Rose, Ink.Copper, Ink.Olive, Ink.Jade, Ink.Cobalt]
  const AXES = [Ink.AxisX, Ink.AxisY, Ink.AxisZ]

  for i in 0 ..< len(ASSIGNABLE):
    for j in i + 1 ..< len(ASSIGNABLE):
      let
        (first, second) = (ASSIGNABLE[i], ASSIGNABLE[j])
        (a, b) = (first.linearOf, second.linearOf)
        pair = &"{first} / {second}"
      record(&"{pair}, typical vision", separation(a.toOklab, b.toOklab),
        SEPARATION_ASSIGNABLE_NORMAL)
      record(&"{pair}, hue angle",
        degreesBetween(a.toOklab.degreesHue, b.toOklab.degreesHue), DEGREES_ASSIGNABLE, "°")
      record(&"{pair}, red-green deficiency", separationRedGreen(a, b),
        SEPARATION_ASSIGNABLE_CVD)
      record(&"{pair}, tritanopia",
        separationDeficient(a, b, Deficiency.Tritanopia), SEPARATION_ASSIGNABLE_TRITAN)

  for ink in ASSIGNABLE:
    record(&"{ink} / Invalid, red-green deficiency",
      separationRedGreen(ink.linearOf, Ink.Invalid.linearOf), SEPARATION_INVALID_CVD)
    for axis in AXES:
      record(&"{ink} / {axis}, red-green deficiency",
        separationRedGreen(ink.linearOf, axis.linearOf), SEPARATION_AXIS_CVD)

  var
    count_failed = 0
    count_excused = 0
  for finding in findings:
    let
      excused = exceptionFor(finding.description)
      floor = if excused.isSome: excused.get.floor else: finding.floor
      is_passing = finding.measured >= floor
    if not is_passing: inc count_failed
    elif excused.isSome: inc count_excused
    let verdict =
      if not is_passing: "FAILED"
      elif excused.isSome: "excused"
      else: "  ok  "
    echo(
      alignLeft(verdict, 8),
      alignLeft(finding.description, 40), " ",
      formatFloat(finding.measured, ffDecimal, 1).align(6),
      " ", alignLeft(finding.units, 2),
      " (floor ", formatFloat(floor, ffDecimal, 1), ")",
    )
    if excused.isSome:
      for line in wrapWords(excused.get.reason, 78).splitLines(): echo "            ", line
  echo(
    &"\n{len(findings)} measurements, {count_excused} excused by a declared exception, " &
    &"{count_failed} below floor."
  )
  if count_failed > 0: quit(1)


main()
