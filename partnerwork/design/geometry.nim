## Measure scalars and vectors in the drawing's own conventions.
##
##   Bearings run clockwise from straight up the page, because that is how
##     the pictures are read; y grows downward, as SVG's does.
##   A number is written with one decimal and no negative zero, so two poses
##     that are the same pose emit the same markup.
##     Cost of one decimal: two points less than a twentieth apart write as
##       one point.  Accepted -- at drawing scale that distance says nothing.

{.experimental: "strictFuncs".}

import std/[math, strutils]


type Point* = tuple ## A position on the page, in SVG's own axes.
  x, y: float


func n*(v: float): string =
  ## Write one decimal and no negative zero, i.e. `-0.04` comes out as `0`.
  ##   Two poses that are the same pose must emit the same markup, not `0`
  ##     against `-0`.
  let written = formatFloat(v, ffDecimal, 1)
  if written in ["0.0", "-0.0"]:
    return "0"
  written.strip(leading = false, chars = {'0'})
         .strip(leading = false, chars = {'.'})

func n*(v: int): string = $v
  ## Write a whole number as itself; only floats carry the decimal machinery.


func xy*(p: Point): string = n(p.x) & " " & n(p.y)
  ## Write a point as SVG path data expects it.


func polar*(cx, cy, radius, degrees: float): Point =
  ## Get the point at a bearing, measured clockwise from straight up the page.
  let rad = degToRad(degrees)
  (cx + radius * sin(rad), cy - radius * cos(rad))


func bearing*(dx, dy: float): float =
  ## Get the bearing of a vector, in the same clockwise-from-up convention.
  radToDeg(arctan2(dx, -dy))


func dist*(a, b: Point): float =
  ## Get the straight distance between two points.
  sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))


func wrap180*(degrees: float): float =
  ## Take an angle the short way round, into (-180, 180].
  floorMod(degrees + 180.0, 360.0) - 180.0


func continuous*(angles: seq[float]): seq[float] =
  ## Say the same turning without a jump in it.
  ##   Each angle is taken the short way from the one before, so a sequence
  ##     handed to an animation is monotone through a half turn instead of
  ##     stepping from 179 to -179.
  ##     Anything interpolating between two frames reads that step as most of
  ##       a turn backwards, and draws a body spinning the wrong way.
  result = @[wrap180(angles[0])]
  for a in angles[1 .. ^1]:
    result.add result[^1] + wrap180(a - result[^1])


func turn*(point, about: Point; degrees: float): Point =
  ## Rotate a point about another, clockwise on the page.
  let
    rad = degToRad(degrees)
    (dx, dy) = (point.x - about.x, point.y - about.y)
  (about.x + dx * cos(rad) - dy * sin(rad),
   about.y + dx * sin(rad) + dy * cos(rad))
