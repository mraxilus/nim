## Measure how far apart two colours read, to typical vision and to dichromat vision.
##
## Exists so the palette's own stated floors are *checked* rather than asserted: every
## number `PROVENANCE.md` and `REQUIREMENTS.md` quote about the palette came from a run of
## `check_palette.nim` beside this, and a change to `mesh.lut_ink_to_rgba` that breaks one
## fails a command rather than waiting to be noticed on screen.
##
## Not part of the visualiser: nothing here is imported by `visualiser.nim` or
## `browser_bridge.nim`, and it draws nothing. It reads the same table they draw from.
##
## Two published models are transcribed here rather than derived, and are the only things
## in this project that are:
##   * **OKLab** (Björn Ottosson, 2020, "A perceptual color space for image processing"),
##     for a distance that tracks perceived difference. Its matrices are a fit to the
##     CIECAM16 appearance model; there is nothing to derive them from.
##   * **Machado, Oliveira and Fernandes (2009)**, "A physiologically-based model for
##     simulation of color vision deficiency", at severity 1.0, for simulating what a
##     colour-deficient reader sees. That model, at that severity, is the one every floor
##     quoted in `REQUIREMENTS.md` was calibrated against; Viénot-1999 and Brettel-1997 are
##     equally respectable and give materially different numbers on borderline pairs, so
##     the choice of model is part of the standard rather than an implementation detail.
##     Changing it means remeasuring every floor.
## Both are cited where they appear. Everything else -- the distances, the hue angles, the
## floors -- is computed here.

{.experimental: "strictFuncs".}

import std/math



#[ Type Definitions ]#

type
  Linear* = object ## Hold one colour with its display encoding undone, in 0 .. 1.
    red*, green*, blue*: float

  Oklab* = object ## Hold one colour in OKLab: lightness, and two opponent axes.
    lightness*: float ## 0 at black, 1 at white.
    green_red*: float ## Ottosson's `a`; negative toward green, positive toward red.
    blue_yellow*: float ## Ottosson's `b`; negative toward blue, positive toward yellow.

  Deficiency* {.pure.} = enum ## Name a form of colour vision deficiency to simulate.
    Protanopia, ## Long-wavelength cone absent.
    Deuteranopia, ## Medium-wavelength cone absent.
    Tritanopia, ## Short-wavelength cone absent.



#[ Display Encoding ]#

func toLinear*(channel: float): float =
  ## Undo the sRGB transfer function on one channel, so channels may be mixed.
  ##   Every colour in the palette is written as what a display is asked to emit, which is
  ##   sRGB-encoded; averaging or projecting those numbers directly is meaningless.
  if channel <= 0.04045: channel/12.92
  else: pow((channel + 0.055)/1.055, 2.4)


func toEncoded*(channel: float): float =
  ## Reapply the sRGB transfer function, inverse of `toLinear`.
  if channel <= 0.0031308: channel*12.92
  else: 1.055*pow(channel, 1.0/2.4) - 0.055


func toLinear*(red, green, blue: float): Linear =
  ## Undo the sRGB transfer function on a whole colour.
  Linear(red: toLinear(red), green: toLinear(green), blue: toLinear(blue))



#[ Perceptual Space ]#

func toOklab*(colour: Linear): Oklab =
  ## Convert a linear-light colour into OKLab.
  ##   Matrices from Ottosson's own reference implementation; see this module's header.
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
  ## Convert an OKLab colour back to linear light, the inverse of `toOklab`.
  ##   Ottosson's own inverse matrices, from the same reference implementation; see this
  ##   module's header. Needed to *build* a colour at a chosen lightness rather than only
  ##   to measure one -- which is what re-lighting a published colour map to this
  ##   project's own text tones asks for; see `check_ramp.nim`.
  ##   The result may fall outside the sRGB cube for a lightness and chroma no display
  ##   can show; the caller decides what to do about that, since clamping a channel and
  ##   reducing chroma are different answers to different questions.
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
  ##   Scaled so the numbers land in the same range CIE ΔE figures do, which is the range
  ##   every floor in `REQUIREMENTS.md` is quoted in.
  100.0*sqrt(
    (first.lightness - second.lightness)^2 +
    (first.green_red - second.green_red)^2 +
    (first.blue_yellow - second.blue_yellow)^2
  )


func degreesHue*(colour: Oklab): float =
  ## Report a colour's hue as an angle in 0 ..< 360 on the OKLab opponent plane.
  let degrees = radToDeg(arctan2(colour.blue_yellow, colour.green_red))
  if degrees < 0.0: degrees + 360.0 else: degrees


func degreesBetween*(first, second: float): float =
  ## Report the shorter arc between two hue angles, in 0 .. 180.
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
] ## Map each deficiency to its Machado-Oliveira-Fernandes severity-1.0 transform over
  ## linear RGB; see this module's header for the citation and for why the model matters.


func toDeficient*(colour: Linear; deficiency: Deficiency): Linear =
  ## Report what `colour` looks like to a reader with the named deficiency.
  ##   Clamped on return: a transform can leave the sRGB cube, and a negative channel is
  ##   not a colour any display shows.
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
  ## Report the smaller of the protan and deutan separations -- the figure a palette floor
  ## is set against.
  ##   Red-green deficiency alone, with tritanopia measured separately rather than folded
  ##   into this minimum: the two are not comparable in prevalence (red-green affects
  ##   roughly one man in twelve, tritanopia fewer than one person in ten thousand), and a
  ##   palette held to the same floor on both collapses to a single arc for no reader's
  ##   benefit. Tritanopia is still reported, and still has a floor of its own.
  min(
    separationDeficient(first, second, Deficiency.Protanopia),
    separationDeficient(first, second, Deficiency.Deuteranopia),
  )
