## Build diagnostics tree's colour ramp, and hold shipped table to it.
##
## Tree tints each row by **how much of frame that row costs**, on continuous ramp: cyan
## where row is sliver of frame, orange where half or more. Ramp is **CET-I1** (Peter
## Kovesi, "Good Colour Maps: How to Design Them", arXiv:1509.03700; map named
## `isoluminant_cgo_70_c39`, cyan-grey-orange at CIELAB lightness 70, chroma 39),
## transcribed at seventeen samples of its 256. *Isoluminant* by construction, which is
## what ramp painted onto text wants: reader's eye is not asked to read lightness as
## meaning, so tree's type hierarchy survives tint.
##
## Kovesi's lightness is not this drawer's, so each sample is **re-lit** to lightness
## untinted text carries: row's label to `--ink-muted`'s, its value to same small step
## toward `--ink` untinted rows take. Hue and chroma from map, lightness from tokens.
##
## This tool is generator *and* check: reads two lightness tokens out of `shell.html` and
## shipped table out of `ramp.nim`, regenerates every entry, and reports any
## disagreement. `--emit` prints table for pasting into `ramp.nim` when token changes.
##
## Build and run:
##   ../../bin/nim c --hints:off -o:../bin/check_ramp check_ramp.nim && ../bin/check_ramp

import std/[math, os, strformat, strutils]

import ../visualiser/core/ramp
import ./colour



#[ Published Map ]#

const SAMPLES_CET_I1: array[STEPS_RAMP_TREE, (float, float, float)] = [
  (0.21566, 0.71777, 0.92594),
  (0.25081, 0.72253, 0.87117),
  (0.28203, 0.72671, 0.81545),
  (0.31189, 0.73016, 0.75854),
  (0.34269, 0.73270, 0.70018),
  (0.37683, 0.73395, 0.64016),
  (0.41741, 0.73330, 0.57860),
  (0.46800, 0.72965, 0.51719),
  (0.52990, 0.72164, 0.46164),
  (0.59311, 0.71004, 0.42224),
  (0.65809, 0.69492, 0.39229),
  (0.71914, 0.67760, 0.37349),
  (0.77626, 0.65826, 0.36654),
  (0.82935, 0.63720, 0.37041),
  (0.87850, 0.61462, 0.38312),
  (0.92406, 0.59059, 0.40246),
  (0.96644, 0.56505, 0.42674),
] ## Sample CET-I1 at seventeen even points of its 256 entries, sRGB-encoded in 0 .. 1.
  ##   Transcribed, not derived, like OKLab matrices in `colour.nim`: published data.
  ##   Seventeen rather than 256 because shipped ramp is interpolated between them, and
  ##   error that costs is measured below.


const MAP_CET_I1: array[256, (float, float, float)] = [
  (0.21566, 0.71777, 0.92594),
  (0.21805, 0.71808, 0.92254),
  (0.22040, 0.71839, 0.91913),
  (0.22272, 0.71870, 0.91573),
  (0.22499, 0.71901, 0.91232),
  (0.22727, 0.71931, 0.90891),
  (0.22950, 0.71962, 0.90550),
  (0.23174, 0.71992, 0.90208),
  (0.23392, 0.72022, 0.89866),
  (0.23611, 0.72051, 0.89524),
  (0.23825, 0.72081, 0.89181),
  (0.24038, 0.72110, 0.88838),
  (0.24250, 0.72139, 0.88495),
  (0.24460, 0.72168, 0.88151),
  (0.24668, 0.72196, 0.87807),
  (0.24877, 0.72225, 0.87462),
  (0.25081, 0.72253, 0.87117),
  (0.25284, 0.72281, 0.86772),
  (0.25488, 0.72309, 0.86426),
  (0.25687, 0.72336, 0.86080),
  (0.25887, 0.72363, 0.85734),
  (0.26085, 0.72390, 0.85387),
  (0.26281, 0.72417, 0.85040),
  (0.26477, 0.72444, 0.84692),
  (0.26672, 0.72470, 0.84344),
  (0.26866, 0.72496, 0.83996),
  (0.27061, 0.72522, 0.83647),
  (0.27250, 0.72548, 0.83297),
  (0.27442, 0.72573, 0.82948),
  (0.27635, 0.72598, 0.82598),
  (0.27824, 0.72622, 0.82247),
  (0.28012, 0.72647, 0.81896),
  (0.28203, 0.72671, 0.81545),
  (0.28389, 0.72694, 0.81193),
  (0.28576, 0.72718, 0.80840),
  (0.28764, 0.72741, 0.80487),
  (0.28953, 0.72764, 0.80134),
  (0.29140, 0.72787, 0.79780),
  (0.29325, 0.72809, 0.79426),
  (0.29511, 0.72831, 0.79071),
  (0.29699, 0.72853, 0.78716),
  (0.29885, 0.72875, 0.78360),
  (0.30070, 0.72896, 0.78003),
  (0.30255, 0.72917, 0.77647),
  (0.30443, 0.72937, 0.77289),
  (0.30631, 0.72958, 0.76931),
  (0.30815, 0.72978, 0.76573),
  (0.31004, 0.72997, 0.76213),
  (0.31189, 0.73016, 0.75854),
  (0.31378, 0.73035, 0.75494),
  (0.31565, 0.73053, 0.75133),
  (0.31753, 0.73071, 0.74772),
  (0.31943, 0.73089, 0.74409),
  (0.32131, 0.73106, 0.74047),
  (0.32321, 0.73123, 0.73684),
  (0.32511, 0.73140, 0.73320),
  (0.32703, 0.73156, 0.72956),
  (0.32897, 0.73172, 0.72591),
  (0.33088, 0.73187, 0.72225),
  (0.33284, 0.73202, 0.71859),
  (0.33479, 0.73217, 0.71492),
  (0.33674, 0.73231, 0.71125),
  (0.33871, 0.73244, 0.70756),
  (0.34069, 0.73257, 0.70388),
  (0.34269, 0.73270, 0.70018),
  (0.34469, 0.73282, 0.69648),
  (0.34672, 0.73293, 0.69278),
  (0.34875, 0.73304, 0.68906),
  (0.35081, 0.73315, 0.68534),
  (0.35286, 0.73325, 0.68161),
  (0.35496, 0.73334, 0.67788),
  (0.35706, 0.73343, 0.67413),
  (0.35916, 0.73351, 0.67039),
  (0.36130, 0.73359, 0.66663),
  (0.36345, 0.73366, 0.66287),
  (0.36562, 0.73373, 0.65910),
  (0.36781, 0.73379, 0.65532),
  (0.37003, 0.73384, 0.65155),
  (0.37227, 0.73388, 0.64775),
  (0.37454, 0.73392, 0.64396),
  (0.37683, 0.73395, 0.64016),
  (0.37914, 0.73398, 0.63635),
  (0.38148, 0.73399, 0.63254),
  (0.38384, 0.73400, 0.62872),
  (0.38622, 0.73400, 0.62489),
  (0.38865, 0.73400, 0.62106),
  (0.39110, 0.73398, 0.61722),
  (0.39357, 0.73396, 0.61337),
  (0.39609, 0.73392, 0.60953),
  (0.39863, 0.73388, 0.60567),
  (0.40121, 0.73383, 0.60181),
  (0.40382, 0.73377, 0.59795),
  (0.40646, 0.73370, 0.59409),
  (0.40914, 0.73361, 0.59021),
  (0.41186, 0.73352, 0.58635),
  (0.41461, 0.73342, 0.58247),
  (0.41741, 0.73330, 0.57860),
  (0.42024, 0.73318, 0.57472),
  (0.42310, 0.73304, 0.57084),
  (0.42602, 0.73289, 0.56698),
  (0.42898, 0.73273, 0.56310),
  (0.43199, 0.73255, 0.55923),
  (0.43504, 0.73236, 0.55536),
  (0.43813, 0.73216, 0.55150),
  (0.44125, 0.73194, 0.54764),
  (0.44444, 0.73171, 0.54379),
  (0.44765, 0.73146, 0.53995),
  (0.45093, 0.73119, 0.53612),
  (0.45426, 0.73092, 0.53231),
  (0.45762, 0.73062, 0.52850),
  (0.46104, 0.73032, 0.52471),
  (0.46451, 0.72999, 0.52094),
  (0.46800, 0.72965, 0.51719),
  (0.47157, 0.72928, 0.51346),
  (0.47518, 0.72890, 0.50975),
  (0.47882, 0.72850, 0.50606),
  (0.48251, 0.72809, 0.50241),
  (0.48625, 0.72766, 0.49879),
  (0.49004, 0.72720, 0.49520),
  (0.49386, 0.72673, 0.49165),
  (0.49773, 0.72625, 0.48813),
  (0.50164, 0.72574, 0.48464),
  (0.50557, 0.72521, 0.48121),
  (0.50955, 0.72466, 0.47782),
  (0.51357, 0.72409, 0.47449),
  (0.51761, 0.72351, 0.47120),
  (0.52167, 0.72290, 0.46795),
  (0.52578, 0.72228, 0.46477),
  (0.52990, 0.72164, 0.46164),
  (0.53404, 0.72098, 0.45857),
  (0.53822, 0.72030, 0.45556),
  (0.54240, 0.71961, 0.45262),
  (0.54660, 0.71890, 0.44973),
  (0.55081, 0.71817, 0.44690),
  (0.55503, 0.71743, 0.44415),
  (0.55926, 0.71667, 0.44145),
  (0.56350, 0.71589, 0.43882),
  (0.56773, 0.71509, 0.43627),
  (0.57197, 0.71428, 0.43376),
  (0.57622, 0.71346, 0.43134),
  (0.58045, 0.71262, 0.42898),
  (0.58468, 0.71178, 0.42669),
  (0.58890, 0.71092, 0.42445),
  (0.59311, 0.71004, 0.42224),
  (0.59730, 0.70917, 0.42009),
  (0.60146, 0.70828, 0.41796),
  (0.60561, 0.70738, 0.41587),
  (0.60975, 0.70647, 0.41382),
  (0.61386, 0.70556, 0.41180),
  (0.61796, 0.70463, 0.40983),
  (0.62204, 0.70370, 0.40789),
  (0.62612, 0.70276, 0.40600),
  (0.63017, 0.70181, 0.40413),
  (0.63421, 0.70085, 0.40230),
  (0.63822, 0.69988, 0.40055),
  (0.64223, 0.69891, 0.39880),
  (0.64621, 0.69792, 0.39711),
  (0.65019, 0.69693, 0.39547),
  (0.65415, 0.69593, 0.39385),
  (0.65809, 0.69492, 0.39229),
  (0.66202, 0.69390, 0.39078),
  (0.66593, 0.69288, 0.38930),
  (0.66983, 0.69184, 0.38787),
  (0.67371, 0.69079, 0.38648),
  (0.67758, 0.68974, 0.38515),
  (0.68143, 0.68868, 0.38386),
  (0.68527, 0.68760, 0.38261),
  (0.68910, 0.68652, 0.38142),
  (0.69291, 0.68544, 0.38026),
  (0.69670, 0.68433, 0.37915),
  (0.70047, 0.68324, 0.37809),
  (0.70424, 0.68212, 0.37708),
  (0.70798, 0.68100, 0.37611),
  (0.71172, 0.67987, 0.37518),
  (0.71544, 0.67874, 0.37432),
  (0.71914, 0.67760, 0.37349),
  (0.72282, 0.67644, 0.37271),
  (0.72650, 0.67528, 0.37197),
  (0.73016, 0.67411, 0.37128),
  (0.73380, 0.67294, 0.37065),
  (0.73742, 0.67175, 0.37006),
  (0.74103, 0.67057, 0.36951),
  (0.74462, 0.66937, 0.36902),
  (0.74821, 0.66816, 0.36856),
  (0.75177, 0.66694, 0.36815),
  (0.75531, 0.66573, 0.36778),
  (0.75884, 0.66450, 0.36746),
  (0.76236, 0.66327, 0.36719),
  (0.76586, 0.66203, 0.36696),
  (0.76934, 0.66077, 0.36678),
  (0.77281, 0.65952, 0.36664),
  (0.77626, 0.65826, 0.36654),
  (0.77970, 0.65699, 0.36649),
  (0.78312, 0.65572, 0.36647),
  (0.78653, 0.65443, 0.36650),
  (0.78991, 0.65314, 0.36657),
  (0.79329, 0.65185, 0.36668),
  (0.79664, 0.65055, 0.36682),
  (0.79999, 0.64925, 0.36701),
  (0.80331, 0.64792, 0.36723),
  (0.80662, 0.64661, 0.36750),
  (0.80991, 0.64528, 0.36781),
  (0.81318, 0.64395, 0.36816),
  (0.81645, 0.64261, 0.36854),
  (0.81969, 0.64126, 0.36896),
  (0.82293, 0.63992, 0.36941),
  (0.82614, 0.63856, 0.36989),
  (0.82935, 0.63720, 0.37041),
  (0.83253, 0.63583, 0.37097),
  (0.83570, 0.63446, 0.37156),
  (0.83885, 0.63308, 0.37219),
  (0.84199, 0.63169, 0.37285),
  (0.84511, 0.63030, 0.37355),
  (0.84822, 0.62890, 0.37427),
  (0.85131, 0.62750, 0.37502),
  (0.85439, 0.62609, 0.37580),
  (0.85745, 0.62468, 0.37663),
  (0.86051, 0.62326, 0.37746),
  (0.86354, 0.62183, 0.37833),
  (0.86656, 0.62041, 0.37923),
  (0.86956, 0.61897, 0.38016),
  (0.87256, 0.61752, 0.38112),
  (0.87554, 0.61607, 0.38209),
  (0.87850, 0.61462, 0.38312),
  (0.88145, 0.61316, 0.38414),
  (0.88438, 0.61170, 0.38520),
  (0.88730, 0.61023, 0.38628),
  (0.89021, 0.60876, 0.38740),
  (0.89310, 0.60728, 0.38854),
  (0.89598, 0.60578, 0.38969),
  (0.89885, 0.60429, 0.39088),
  (0.90170, 0.60279, 0.39208),
  (0.90454, 0.60128, 0.39330),
  (0.90737, 0.59978, 0.39455),
  (0.91018, 0.59826, 0.39583),
  (0.91298, 0.59674, 0.39710),
  (0.91577, 0.59521, 0.39842),
  (0.91854, 0.59368, 0.39974),
  (0.92131, 0.59215, 0.40111),
  (0.92406, 0.59059, 0.40246),
  (0.92679, 0.58904, 0.40386),
  (0.92952, 0.58748, 0.40527),
  (0.93223, 0.58593, 0.40669),
  (0.93493, 0.58436, 0.40813),
  (0.93763, 0.58278, 0.40960),
  (0.94030, 0.58120, 0.41108),
  (0.94297, 0.57962, 0.41258),
  (0.94562, 0.57802, 0.41408),
  (0.94826, 0.57644, 0.41561),
  (0.95089, 0.57482, 0.41716),
  (0.95351, 0.57322, 0.41871),
  (0.95612, 0.57159, 0.42029),
  (0.95872, 0.56997, 0.42188),
  (0.96130, 0.56834, 0.42348),
  (0.96388, 0.56671, 0.42511),
  (0.96644, 0.56505, 0.42674),
] ## Hold CET-I1 whole, all 256 entries, for measuring what sampling it seventeen ways costs.
  ##   Kept in this tool alone: nothing ships it.

const
  TOLERANCE_CHANNEL = 0.5/255.0
    ## Bound how far regenerated channel may sit from shipped one.
    ##   Half display step, most correct table can differ by through rounding to eight
    ##   bits.
  SEPARATION_INTERPOLATED_MAX = 1.5
    ## Bound how far interpolated ramp may stray from full 256-entry map between samples.
    ##   In OKLab distance `colour.separation` reports.
    ##   Under 2 is below threshold at which difference is noticeable, which makes
    ##   seventeen samples enough.
  SEPARATION_ENDS_MIN = 25.0
    ## Bound below how far apart ramp's two ends must read.
    ##   "Sliver of frame" and "half frame" are then never mistaken.
    ##   Floor catches re-lighting that flattened them.



#[ Re-lighting ]#

func lightnessOf(colour: (float, float, float)): float =
  ## Read one sRGB colour's OKLab lightness.
  toOklab(toLinear(colour[0], colour[1], colour[2])).lightness


func relit(sample: (float, float, float), lightness: float): (float, float, float) =
  ## Rebuild one CET-I1 sample at given OKLab lightness, keeping its hue.
  ##   Keeps as much of its chroma as sRGB shows there.
  ##   Chroma is reduced rather than clamped per channel: clamping bends hue, whole signal
  ##   here.
  ##   Search is bisection on scale factor, exact enough at eight bits.
  let source = toOklab(toLinear(sample[0], sample[1], sample[2]))
  func fits(scale: float): bool =
    let candidate = toLinear(Oklab(
      lightness: lightness,
      green_red: scale*source.green_red,
      blue_yellow: scale*source.blue_yellow,
    ))
    candidate.red >= 0.0 and candidate.red <= 1.0 and
      candidate.green >= 0.0 and candidate.green <= 1.0 and
      candidate.blue >= 0.0 and candidate.blue <= 1.0
  var (low, high) = (0.0, 1.0)
  if not fits(high):
    for _ in 0 ..< 32:
      let middle = 0.5*(low + high)
      if fits(middle): low = middle else: high = middle
  else:
    low = high
  let shown = toLinear(Oklab(
    lightness: lightness,
    green_red: low*source.green_red,
    blue_yellow: low*source.blue_yellow,
  ))
  (toEncoded(shown.red), toEncoded(shown.green), toEncoded(shown.blue))


#[ Reading What Ships ]#

proc lightnessToken(name: string): float =
  ## Read one CSS custom property out of `shell.html` and report its OKLab lightness.
  ##   Read rather than transcribed: token edited in stylesheet must move ramp with it or
  ##   fail this tool.
  let source = readFile(currentSourcePath().parentDir / ".." /
    "visualiser" / "browser" / "shell.html")
  for line in source.splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith(name & ":"): continue
    let value = trimmed[(name.len + 1) .. ^1].strip().strip(chars = {';'})
    doAssert value.len == 7 and value[0] == '#',
      &"Token `{name}` must be a `#rrggbb` literal; got `{value}`."
    return lightnessOf((
      float(parseHexInt(value[1 .. 2]))/255.0,
      float(parseHexInt(value[3 .. 4]))/255.0,
      float(parseHexInt(value[5 .. 6]))/255.0,
    ))
  doAssert false, &"Token `{name}` was not found in `shell.html`."


proc main() =
  ## Rebuild ramp, compare it to what ships, and report every measurement.
  let
    lightness_label = lightnessToken("--ink-muted")
    lightness_ink = lightnessToken("--ink")
    # Draw row's value one small step brighter than its label.
    #   Step untinted rows take between `--ink-muted` and `--ink`; lifting whole way
    #   would wash hue out of number.
    lightness_value = lightness_label + LIFT_VALUE_RAMP*(lightness_ink - lightness_label)
  var failures = 0

  template report(is_passed: bool, message: string) =
    echo (if is_passed: "  ok   " else: " FAIL  ") & message
    if not is_passed: inc failures

  echo &"Lightness: label {lightness_label:.4f}, value {lightness_value:.4f} " &
    &"(--ink {lightness_ink:.4f}, lift {LIFT_VALUE_RAMP})."

  if paramCount() >= 1 and paramStr(1) == "--emit":
    # Print table as `ramp.nim` wants it, for one case token legitimately moves.
    for (lightness, name) in [(lightness_label, "label"), (lightness_value, "value")]:
      echo &"# {name}"
      for i in 0 ..< STEPS_RAMP_TREE:
        let (red, green, blue) = relit(SAMPLES_CET_I1[i], lightness)
        echo &"  ({red:.5f}, {green:.5f}, {blue:.5f}),"
    return

  # Require shipped table to be this tool's answer, or fail.
  #   Every entry is rebuilt from map and tokens and compared.
  var worst_channel = 0.0
  for i in 0 ..< STEPS_RAMP_TREE:
    for (shipped, lightness) in [
      (RAMP_TREE_LABEL[i], lightness_label), (RAMP_TREE_VALUE[i], lightness_value),
    ]:
      let (red, green, blue) = relit(SAMPLES_CET_I1[i], lightness)
      worst_channel = max(worst_channel, abs(shipped[0] - red))
      worst_channel = max(worst_channel, abs(shipped[1] - green))
      worst_channel = max(worst_channel, abs(shipped[2] - blue))
  report(
    worst_channel <= TOLERANCE_CHANNEL,
    &"the shipped ramp is CET-I1 re-lit to this drawer's own tones " &
      &"-- worst channel differs by {worst_channel*255.0:.3f} of a display step",
  )

  # Check seventeen samples stand for 256.
  #   Holds only if what lies between them is same colour.
  #   Measured against full map at every entry it does not sample.
  var worst_interpolated = 0.0
  for entry in 0 ..< 256:
    let
      position = float(entry)*float(STEPS_RAMP_TREE - 1)/255.0
      below = min(int(floor(position)), STEPS_RAMP_TREE - 2)
      fraction = position - float(below)
    let
      (red_low, green_low, blue_low) = SAMPLES_CET_I1[below]
      (red_high, green_high, blue_high) = SAMPLES_CET_I1[below + 1]
      mixed = toLinear(
        (1.0 - fraction)*red_low + fraction*red_high,
        (1.0 - fraction)*green_low + fraction*green_high,
        (1.0 - fraction)*blue_low + fraction*blue_high,
      )
      (red_map, green_map, blue_map) = MAP_CET_I1[entry]
    worst_interpolated = max(worst_interpolated, separation(
      toOklab(mixed), toOklab(toLinear(red_map, green_map, blue_map)),
    ))
  report(
    worst_interpolated <= SEPARATION_INTERPOLATED_MAX,
    &"interpolating between the samples stays on the map " &
      &"-- worst {worst_interpolated:.2f}, floor {SEPARATION_INTERPOLATED_MAX}",
  )

  # Check two ends still read as different things after re-lighting.
  for (name, ramp) in [("label", RAMP_TREE_LABEL), ("value", RAMP_TREE_VALUE)]:
    let apart = separation(
      toOklab(toLinear(ramp[0][0], ramp[0][1], ramp[0][2])),
      toOklab(toLinear(
        ramp[STEPS_RAMP_TREE - 1][0], ramp[STEPS_RAMP_TREE - 1][1],
        ramp[STEPS_RAMP_TREE - 1][2],
      )),
    )
    report(
      apart >= SEPARATION_ENDS_MIN,
      &"the {name} ramp's ends stay apart -- {apart:.1f}, floor {SEPARATION_ENDS_MIN}",
    )

  if failures == 0: echo "Every ramp check passed."
  else: echo &"{failures} ramp check(s) failed."
  quit(if failures == 0: 0 else: 1)


main()
