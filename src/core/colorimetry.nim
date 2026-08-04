## Measure colour differences the way an eye does, including an eye with a colour deficiency.
##
## This is the project's own colour-vision validator. It exists because the palette's
## separations are stated as **measured**, and a claim of that kind names what enforces it:
## `tests/suite.nim` walks every pair of assignable hues through the functions here and asserts
## the floors the palette is built to. `tools/palette_check.nim` prints the whole matrix, and
## `tools/palette_reference.py` re-computes it through an independent library so this
## implementation is checked rather than trusted.
##
## Two standard pieces, both named where they are used: **CIEDE2000** for the difference, and
## the severity-one simulation matrices of **Machado, Oliveira and Fernandes (2009)** for
## protanopia, deuteranopia and tritanopia.

{.experimental: "strictFuncs".}

import std/math

import ./palette



#[ Type Definitions ]#

type
  Lab* = object
    ## Carry a colour in CIE L*a*b*, where a difference is meaningful.
    lightness*, a*, b*: float

  Deficiency* {.pure.} = enum
    ## Name the vision a measurement is taken through.
    Normal,       ## Trichromatic.
    Protanopia,   ## No long-wavelength cone.
    Deuteranopia, ## No medium-wavelength cone.
    Tritanopia,   ## No short-wavelength cone.



#[ Conversion ]#

func toLinear(channel: float): float =
  ## Undo the sRGB transfer function, so a channel measures light rather than signal.
  if channel <= 0.04045: channel/12.92
  else: pow((channel + 0.055)/1.055, 2.4)


func toSignal(linear: float): float =
  ## Reapply the sRGB transfer function.
  if linear <= 0.0031308: linear*12.92
  else: 1.055*pow(linear, 1.0/2.4) - 0.055


func toLab*(c: Color): Lab =
  ## Convert an sRGB colour to CIE L*a*b* under the D65 white point.
  let
    r = toLinear(clamp(c.r, 0.0, 1.0))
    g = toLinear(clamp(c.g, 0.0, 1.0))
    b = toLinear(clamp(c.b, 0.0, 1.0))
    x = (0.4124564*r + 0.3575761*g + 0.1804375*b)/0.95047
    y = (0.2126729*r + 0.7151522*g + 0.0721750*b)/1.00000
    z = (0.0193339*r + 0.1191920*g + 0.9503041*b)/1.08883

  func f(t: float): float =
    ## Apply the lightness companding CIE L*a*b* is defined by.
    if t > 216.0/24389.0: cbrt(t) else: (24389.0/27.0*t + 16.0)/116.0

  Lab(
    lightness: 116.0*f(y) - 16.0,
    a: 500.0*(f(x) - f(y)),
    b: 200.0*(f(y) - f(z)),
  )


func hueAngle*(c: Color): float =
  ## Read a colour's hue in degrees, 0 to 360, as CIE L*a*b* places it.
  let lab = c.toLab
  result = radToDeg(arctan2(lab.b, lab.a))
  if result < 0.0: result += 360.0


func hueDistance*(first, second: Color): float =
  ## Measure the shorter way round between two hues, in degrees.
  let difference = abs(first.hueAngle - second.hueAngle)
  min(difference, 360.0 - difference)



#[ Difference ]#

func deltaE*(left, right: Lab): float =
  ## Measure the perceived difference between two colours, in CIEDE2000.
  ##   Exceeds the usual function length because the formula is one published expression and
  ##   splitting it would only hide which term is which. `tests/suite.nim` checks it against
  ##   the published test pairs of Sharma, Wu and Dalal (2005), which exist to catch exactly
  ##   the hue-wrap and rotation-term mistakes this formula invites.
  let
    chroma_left = sqrt(left.a*left.a + left.b*left.b)
    chroma_right = sqrt(right.a*right.a + right.b*right.b)
    chroma_mean = (chroma_left + chroma_right)*0.5
    seventh = pow(chroma_mean, 7.0)
    g_factor = 0.5*(1.0 - sqrt(seventh/(seventh + pow(25.0, 7.0))))
    a_left = left.a*(1.0 + g_factor)
    a_right = right.a*(1.0 + g_factor)
    chroma_left_prime = sqrt(a_left*a_left + left.b*left.b)
    chroma_right_prime = sqrt(a_right*a_right + right.b*right.b)

  func hue(a, b: float): float =
    ## Read a hue angle in degrees, 0 to 360, or zero where there is no chroma.
    if abs(a) < 1e-12 and abs(b) < 1e-12: return 0.0
    result = radToDeg(arctan2(b, a))
    if result < 0.0: result += 360.0

  let
    hue_left = hue(a_left, left.b)
    hue_right = hue(a_right, right.b)
    delta_lightness = right.lightness - left.lightness
    delta_chroma = chroma_right_prime - chroma_left_prime
  var delta_hue = 0.0
  if chroma_left_prime*chroma_right_prime > 1e-12:
    delta_hue = hue_right - hue_left
    if delta_hue > 180.0: delta_hue -= 360.0
    elif delta_hue < -180.0: delta_hue += 360.0
  let
    delta_capital_hue =
      2.0*sqrt(chroma_left_prime*chroma_right_prime)*sin(degToRad(delta_hue*0.5))
    lightness_mean = (left.lightness + right.lightness)*0.5
    chroma_mean_prime = (chroma_left_prime + chroma_right_prime)*0.5
  var hue_mean = hue_left + hue_right
  if chroma_left_prime*chroma_right_prime > 1e-12:
    if abs(hue_left - hue_right) > 180.0: hue_mean += 360.0
    hue_mean *= 0.5
  else:
    hue_mean = hue_left + hue_right
  let
    t = 1.0 - 0.17*cos(degToRad(hue_mean - 30.0)) + 0.24*cos(degToRad(2.0*hue_mean)) +
      0.32*cos(degToRad(3.0*hue_mean + 6.0)) - 0.20*cos(degToRad(4.0*hue_mean - 63.0))
    lightness_offset = (lightness_mean - 50.0)*(lightness_mean - 50.0)
    weight_lightness = 1.0 + 0.015*lightness_offset/sqrt(20.0 + lightness_offset)
    weight_chroma = 1.0 + 0.045*chroma_mean_prime
    weight_hue = 1.0 + 0.015*chroma_mean_prime*t
    mean_seventh = pow(chroma_mean_prime, 7.0)
    rotation = -2.0*sqrt(mean_seventh/(mean_seventh + pow(25.0, 7.0)))*
      sin(degToRad(60.0*exp(-pow((hue_mean - 275.0)/25.0, 2.0))))
    lightness_term = delta_lightness/weight_lightness
    chroma_term = delta_chroma/weight_chroma
    hue_term = delta_capital_hue/weight_hue
  sqrt(
    lightness_term*lightness_term + chroma_term*chroma_term + hue_term*hue_term +
    rotation*chroma_term*hue_term
  )


func deltaE*(first, second: Color): float {.inline.} =
  ## Measure the perceived difference between two colours, in CIEDE2000.
  deltaE(first.toLab, second.toLab)



#[ Colour Vision Deficiency ]#

const LUT_DEFICIENCY_TO_MATRIX: array[Deficiency, array[9, float]] = [
  ## Hold the severity-one simulation matrices of Machado, Oliveira and Fernandes (2009).
  ##   Applied to linear sRGB, which is where that model is defined. Chosen over the
  ##   plane-projection model of Viénot, Brettel and Mollon (1999) because it is what the
  ##   colour-vision validators in common use apply, so a measurement here is comparable with
  ##   one taken elsewhere; `tools/palette_reference.py` checks this against a library that
  ##   implements the same model independently. The projection model was tried first and reads
  ##   several pairs as much closer than any validator does.
  Deficiency.Normal: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
  Deficiency.Protanopia: [
    0.152286, 1.052583, -0.204868,
    0.114503, 0.786281, 0.099216,
    -0.003882, -0.048116, 1.051998,
  ],
  Deficiency.Deuteranopia: [
    0.367322, 0.860646, -0.227968,
    0.280085, 0.672501, 0.047413,
    -0.011820, 0.042940, 0.968881,
  ],
  Deficiency.Tritanopia: [
    1.255528, -0.076749, -0.178779,
    -0.078411, 0.930809, 0.147602,
    0.004733, 0.691367, 0.303900,
  ],
]


func simulate*(c: Color, deficiency: Deficiency): Color =
  ## Simulate how a colour reads to an eye missing one cone response.
  ##   Severity one — complete dichromacy — because the floors a palette must clear are stated
  ##   for the worst case a picker has to survive, not for an average eye.
  if deficiency == Deficiency.Normal: return c
  let
    matrix = LUT_DEFICIENCY_TO_MATRIX[deficiency]
    r = toLinear(clamp(c.r, 0.0, 1.0))
    g = toLinear(clamp(c.g, 0.0, 1.0))
    b = toLinear(clamp(c.b, 0.0, 1.0))
    red = matrix[0]*r + matrix[1]*g + matrix[2]*b
    green = matrix[3]*r + matrix[4]*g + matrix[5]*b
    blue = matrix[6]*r + matrix[7]*g + matrix[8]*b
  Color(
    r: toSignal(clamp(red, 0.0, 1.0)),
    g: toSignal(clamp(green, 0.0, 1.0)),
    b: toSignal(clamp(blue, 0.0, 1.0)),
    a: c.a,
  )


func deltaE*(first, second: Color, deficiency: Deficiency): float {.inline.} =
  ## Measure the perceived difference between two colours through a given vision.
  deltaE(first.simulate(deficiency), second.simulate(deficiency))


func deltaEWorst*(first, second: Color): float =
  ## Measure the difference through the vision that sees the least of it.
  ##   The floor a palette must clear is the worst case, not the average: a pair that only
  ##   separates for normal vision separates for nobody who needs the separation.
  result = deltaE(first, second, Deficiency.Protanopia)
  for deficiency in [Deficiency.Deuteranopia, Deficiency.Tritanopia]:
    result = min(result, deltaE(first, second, deficiency))
