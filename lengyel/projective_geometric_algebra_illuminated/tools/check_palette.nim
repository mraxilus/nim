## Hold palette to separation floors `REQUIREMENTS.md` states for it.
##
## Reads `mesh.lut_ink_to_rgba` itself rather than transcription.
##   This cannot pass against table visualiser no longer draws from.
##   Reports every measurement, pass or fail, and exits non-zero on any failure, so it
##   can gate commit.
## Floors are not invented here.
##   Each is quoted from `REQUIREMENTS.md`'s palette section beside check enforcing it.
##   Changing one means changing both, and saying in `PROVENANCE.md` what was measured to
##   justify it.
## Build and run:
##   ../../bin/nim c --hints:off -o:../bin/check_palette check_palette.nim && ../bin/check_palette

import std/[options, strformat, strutils, wordwrap]

import ../visualiser/core/mesh
import ./colour



#[ Stated Floors ]#

const
  SEPARATION_ASSIGNABLE_NORMAL = 15.0
    ## Bound below every pair of assignable hues to typical vision.
    ##   Lightness can then never stand in for hue difference.
  DEGREES_ASSIGNABLE = 20.0
    ## Bound below hue angle same pairs clear, for same reason.
  SEPARATION_ASSIGNABLE_CVD = 6.0
    ## Bound below every pair of assignable hues under red-green deficiency.
    ##   Band 6 .. 8 is legal only where secondary encoding carries identity too; here
    ##   shape and screen position do.
  SEPARATION_ASSIGNABLE_TRITAN = 6.0
    ## Bound below same pairs under tritanopia, measured separately.
    ##   See `colour.separationRedGreen`.
  SEPARATION_INVALID_CVD = 13.0
    ## Bound below every assignable hue against reserved magenta under red-green deficiency.
    ##   Higher, because magenta means wrong, and reading ordinary object as invalid is
    ##   worse error than confusing two ordinary objects.
  SEPARATION_FURNITURE_BACKDROP = 8.0
    ## Bound below every piece of world furniture against backdrop, under typical vision.
    ##   Furniture nobody can see is missing.
    ##   Legibility floor, not discrimination one: question is whether mark is there at
    ##   all.
  SEPARATION_AXIS_CVD = 4.0
    ## Bound below every assignable hue against each world axis under red-green deficiency.
    ##   Looser than object-to-object floors: axis is thin fixed line, never fill, and
    ##   tightening this crushes whole palette into single teal-blue arc.





#[ Declared Exceptions ]#

type Exception = object ## Define one measurement allowed to sit below its stated floor.
  description*: string ## Measurement excused, spelled exactly as `record` names it.
  floor*: float ## What it must still clear.
    ## Pinned just under where it measures today, so drifting further fails run rather
    ## than widening excuse.
  reason*: string ## Why it is tolerable, in terms palette's rules are in.

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
] ## Record every measurement knowingly below its floor.
  ##   Exception is decision recorded in source, not floor quietly lowered.
  ##   Excused pair still has floor of its own, and reason is printed on every run so it
  ##   stays argued rather than inherited.


func exceptionFor(description: string): Option[Exception] =
  ## Find declared exception covering measurement, if one is declared.
  for excused in EXCEPTIONS:
    if excused.description == description: return some(excused)
  none(Exception)



#[ Measurement ]#

type Finding = object ## Define one measurement and whether it cleared its floor.
  description: string ## What was measured, named as reader would name it.
  measured: float ## What it came to.
  floor: float ## What it had to clear.
  units: string ## What two numbers are in, for report.

var findings: seq[Finding]
  ## Record every measurement made, in order made.
  ##   `seq` rather than fixed array because this is tool run once from shell, not
  ##   visualiser's hot path; Art. IV.6's ban on runtime `seq` is about frame loop.

proc record(description: string; measured, floor: float; units = "ΔE") =
  ## Record one measurement against its floor.
  findings.add(Finding(
    description: description, measured: measured, floor: floor, units: units
  ))


func linearOf(ink: Ink): Linear =
  ## Read one palette slot as linear light, from visualiser's table.
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

  # Check furniture stays visible on its ground, price of dimming it.
  #   `Algebra` joins them: debug layer draws over same backdrop.
  for ink in [Ink.AxisX, Ink.AxisY, Ink.AxisZ, Ink.Grid, Ink.Algebra]:
    record(&"{ink} / Backdrop, typical vision",
      separation(ink.linearOf.toOklab, Ink.Backdrop.linearOf.toOklab),
      SEPARATION_FURNITURE_BACKDROP)

  # Screen debug layer against every assignable slot and `Invalid` at assignable floors.
  #   It must not be mistaken for object reader built, nor for warning ink.
  for ink in [Ink.Rose, Ink.Copper, Ink.Olive, Ink.Jade, Ink.Cobalt, Ink.Invalid]:
    record(&"Algebra / {ink}, red-green deficiency",
      separationRedGreen(Ink.Algebra.linearOf, ink.linearOf), SEPARATION_ASSIGNABLE_CVD)
    record(&"Algebra / {ink}, tritanopia",
      separationDeficient(Ink.Algebra.linearOf, ink.linearOf, Deficiency.Tritanopia),
      SEPARATION_ASSIGNABLE_TRITAN)

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
