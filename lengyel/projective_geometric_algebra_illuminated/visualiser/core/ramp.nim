## Hold the diagnostics tree's own colour ramp, as it ships.
##
## The tree tints each row by how much of the frame that row costs: a continuous ramp from
## cyan at nothing to orange at half the frame or more, rather than the four bands it
## replaced. What the ramp *is* -- **CET-I1**, re-lit to this drawer's own text tones -- and
## why, is `tools/check_ramp.nim`'s doc comment; that tool regenerates every entry below
## from the published map and the stylesheet's own tokens and fails if the two disagree, so
## this table cannot drift from what it claims to be. It is data here and nothing else.
##
## Two ramps because a row is two pieces of text at two weights: its label, and its value.
## Both take hue and chroma from the map and lightness from the tone the untinted text
## already wears, so tinting a row never disturbs the type hierarchy the tree reads by.
##
## A `core` module rather than one inside `browser/` because the tool that verifies it is
## native and must not import the browser bridge; nothing here draws, and nothing here
## depends on anything at all.

const STEPS_RAMP_TREE* = 17
  ## How many samples of the map the ramp ships. The presentation layer interpolates
  ## between them, and `check_ramp` measures what that interpolation costs against the
  ## map's full 256 entries rather than assuming it is free.


const LIFT_VALUE_RAMP* = 0.15
  ## How far a row's value is lifted from its label's lightness toward `--ink`'s.
  ##   Small on purpose, and unchanged from the banded ramp this replaced: lifting the
  ##   whole way desaturates the number, which is the half of the row a reader looks at.


const RAMP_TREE_LABEL*: array[STEPS_RAMP_TREE, (float, float, float)] = [
  (0.06362, 0.63569, 0.84006),
  (0.13402, 0.64230, 0.78837),
  (0.18101, 0.64807, 0.73553),
  (0.22064, 0.65284, 0.68127),
  (0.25832, 0.65637, 0.62523),
  (0.29755, 0.65824, 0.56708),
  (0.34169, 0.65770, 0.50665),
  (0.39411, 0.65342, 0.44518),
  (0.45560, 0.64383, 0.38782),
  (0.51630, 0.62993, 0.34518),
  (0.57713, 0.61192, 0.31085),
  (0.63310, 0.59142, 0.28732),
  (0.68453, 0.56870, 0.27599),
  (0.73156, 0.54407, 0.27623),
  (0.77446, 0.51774, 0.28601),
  (0.81370, 0.48972, 0.30279),
  (0.84972, 0.45984, 0.32453),
]
  ## A row's label, at `--ink-muted`'s own lightness.


const RAMP_TREE_VALUE*: array[STEPS_RAMP_TREE, (float, float, float)] = [
  (0.16958, 0.68668, 0.89344),
  (0.21231, 0.69313, 0.84084),
  (0.24834, 0.69878, 0.78708),
  (0.28164, 0.70349, 0.73188),
  (0.31498, 0.70700, 0.67493),
  (0.35094, 0.70887, 0.61592),
  (0.39255, 0.70831, 0.55479),
  (0.44316, 0.70398, 0.49291),
  (0.50372, 0.69425, 0.43566),
  (0.56440, 0.68013, 0.39354),
  (0.62581, 0.66186, 0.36002),
  (0.68270, 0.64111, 0.33730),
  (0.73520, 0.61815, 0.32638),
  (0.78337, 0.59336, 0.32648),
  (0.82740, 0.56696, 0.33569),
  (0.86772, 0.53902, 0.35173),
  (0.90479, 0.50942, 0.37277),
]
  ## A row's value, one `LIFT_VALUE_RAMP` step brighter.
