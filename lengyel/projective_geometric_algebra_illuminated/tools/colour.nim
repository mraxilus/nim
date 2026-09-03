## Measure how far apart two colours read, to typical vision and to dichromat vision.
##
## Exists so palette's stated floors are checked rather than asserted.
##   Every number `PROVENANCE.md` and `REQUIREMENTS.md` quote about palette came from run
##   of `check_palette.nim` beside this.
##   Change to `mesh.lut_ink_to_rgba` breaking one fails command rather than waiting to
##   be noticed on screen.
## Not part of visualiser: nothing here is imported by `visualiser.nim` or
## `browser_bridge.nim`.
##   It reads same table they draw from.
## Two published models are transcribed rather than derived, only things in this project
## that are.
##   OKLab (Björn Ottosson, 2020, "A perceptual color space for image processing"), for
##   distance tracking perceived difference.
##     Its matrices are fit to CIECAM16.
##   Machado, Oliveira and Fernandes (2009), "A physiologically-based model for
##   simulation of color vision deficiency", at severity 1.0.
##     Every floor quoted in `REQUIREMENTS.md` was calibrated against that model.
##     Viénot-1999 and Brettel-1997 give materially different numbers on borderline
##     pairs, so choice of model is part of standard; changing it means remeasuring every
##     floor.
## Everything else (distances, hue angles, floors) is computed here.

{.experimental: "strictFuncs".}

import std/math



#[ Type Definitions ]#

type
  Linear* = object ## Define one colour with display encoding undone, in 0 .. 1.
    red*, green*, blue*: float

  Oklab* = object ## Define one colour in OKLab: lightness, and two opponent axes.
    lightness*: float ## 0 at black, 1 at white.
    green_red*: float ## Ottosson's `a`; negative toward green, positive toward red.
    blue_yellow*: float ## Ottosson's `b`; negative toward blue, positive toward yellow.

  Deficiency* {.pure.} = enum ## Define form of colour vision deficiency to simulate.
    Protanopia, ## Long-wavelength cone absent.
    Deuteranopia, ## Medium-wavelength cone absent.
    Tritanopia, ## Short-wavelength cone absent.



#[ Display Encoding ]#

func toLinear*(channel: float): float =
  ## Undo sRGB transfer function on one channel, so channels may be mixed.
  ##   Every palette colour is written as what display is asked to emit, sRGB-encoded.
  ##   Averaging or projecting those numbers directly is meaningless.
  if channel <= 0.04045: channel/12.92
  else: pow((channel + 0.055)/1.055, 2.4)


func toEncoded*(channel: float): float =
  ## Apply sRGB transfer function again, inverse of `toLinear`.
  if channel <= 0.0031308: channel*12.92
  else: 1.055*pow(channel, 1.0/2.4) - 0.055


func toLinear*(red, green, blue: float): Linear =
  ## Undo sRGB transfer function on whole colour.
  Linear(red: toLinear(red), green: toLinear(green), blue: toLinear(blue))



#[ Perceptual Space ]#

func toOklab*(colour: Linear): Oklab =
  ## Convert linear-light colour into OKLab.
  ##   Matrices from Ottosson's reference implementation; see module header.
  let
    l = 0.4122214708*colour.red + 0.5363325363*colour.green + 0.0514459929*colour.blue
    m = 0.2119034982*colour.red + 0.6806995451*colour.green + 0.1073969566*colour.blue
    s = 0.0883024619*colour.red + 0.2817188376*colour.green + 0.6299787005*colour.blue
    l_root = cbrt(l)
    m_root = cbrt(m)
    s_root = cbrt(s)
  Oklab(
    lightness: 0.2104542553*l_root + 0.7936177850*m_root - 0.0040720468*s_root,
    green_red: 1.9779984951*l_root - 2.4285922050*m_root + 0.4505937099*s_root,
    blue_yellow: 0.0259040371*l_root + 0.7827717662*m_root - 0.8086757660*s_root,
  )


func toLinear*(colour: Oklab): Linear =
  ## Convert OKLab colour back to linear light, inverse of `toOklab`.
  ##   Ottosson's inverse matrices, from same reference implementation.
  ##   Needed to build colour at chosen lightness rather than only measure one; see
  ##   `check_ramp.nim`.
  ##   Result may fall outside sRGB cube for lightness and chroma no display shows.
  ##     Caller decides, since clamping channel and reducing chroma are different answers.
  let
    l_root = colour.lightness + 0.3963377774*colour.green_red +
      0.2158037573*colour.blue_yellow
    m_root = colour.lightness - 0.1055613458*colour.green_red -
      0.0638541728*colour.blue_yellow
    s_root = colour.lightness - 0.0894841775*colour.green_red -
      1.2914855480*colour.blue_yellow
    l = l_root*l_root*l_root
    m = m_root*m_root*m_root
    s = s_root*s_root*s_root
  Linear(
    red: 4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
    green: -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
    blue: -0.0041960863*l - 0.7034186147*m + 1.7076147010*s,
  )


func separation*(first, second: Oklab): float =
  ## Report how far apart two colours read, as OKLab distance scaled by 100.
  ##   Scaled so numbers land in range CIE ΔE figures do, range every floor in
  ##   `REQUIREMENTS.md` is quoted in.
  100.0*sqrt(
    (first.lightness - second.lightness)^2 +
    (first.green_red - second.green_red)^2 +
    (first.blue_yellow - second.blue_yellow)^2
  )


func degreesHue*(colour: Oklab): float =
  ## Report colour's hue as angle in 0 ..< 360 on OKLab opponent plane.
  let degrees = radToDeg(arctan2(colour.blue_yellow, colour.green_red))
  if degrees < 0.0: degrees + 360.0 else: degrees


func degreesBetween*(first, second: float): float =
  ## Report shorter arc between two hue angles, in 0 .. 180.
  let gap = abs(first - second) mod 360.0
  if gap > 180.0: 360.0 - gap else: gap



#[ Deficient Vision Simulation ]#

const lut_deficiency_to_transform: array[Deficiency, array[3, array[3, float]]] = [
  Deficiency.Protanopia: [
    [0.152286, 1.052583, -0.204868],
    [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998],
  ],
  Deficiency.Deuteranopia: [
    [0.367322, 0.860646, -0.227968],
    [0.280085, 0.672501, 0.047413],
    [-0.011820, 0.042940, 0.968881],
  ],
  Deficiency.Tritanopia: [
    [1.255528, -0.076749, -0.178779],
    [-0.078411, 0.930809, 0.147602],
    [0.004733, 0.691367, 0.303900],
  ],
] ## Map each deficiency to its Machado-Oliveira-Fernandes severity-1.0 transform.
  ##   Over linear RGB; see module header for citation.


func toDeficient*(colour: Linear; deficiency: Deficiency): Linear =
  ## Report what `colour` looks like to reader with named deficiency.
  ##   Clamped on return: transform can leave sRGB cube, and negative channel is not
  ##   colour any display shows.
  let m = lut_deficiency_to_transform[deficiency]
  func seen(row: array[3, float]): float =
    clamp(row[0]*colour.red + row[1]*colour.green + row[2]*colour.blue, 0.0, 1.0)
  Linear(red: seen(m[0]), green: seen(m[1]), blue: seen(m[2]))


func separationDeficient*(first, second: Linear; deficiency: Deficiency): float =
  ## Report how far apart two colours read to one deficiency.
  separation(
    first.toDeficient(deficiency).toOklab, second.toDeficient(deficiency).toOklab
  )


func separationRedGreen*(first, second: Linear): float =
  ## Report smaller of protan and deutan separations, figure palette floor is set against.
  ##   Red-green alone, tritanopia measured separately.
  ##     Not comparable in prevalence (red-green affects roughly one man in twelve,
  ##     tritanopia fewer than one person in ten thousand), and palette held to same floor
  ##     on both collapses to single arc.
  min(
    separationDeficient(first, second, Deficiency.Protanopia),
    separationDeficient(first, second, Deficiency.Deuteranopia),
  )
