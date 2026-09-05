## Every measurement the sim is built from, each with where it came from.
##
##   A rig is a tape's numbers: the rounds of a torso, a neck and a head, the
##     lengths of an arm's three links, and how far each joint will go before
##     it hurts.  Radii and reaches are derived from them, never entered.
##   The figures are mixed-sex midpoints of ANSUR II (2012) medians, with
##     NASA-STD-3000 and the AAOS tables for the joints.  Male / female:
##       chest round 1.00 / 0.92 and waist 0.94 / 0.86, so a one-cylinder
##         torso takes 0.95;  neck round 0.39 / 0.34 -> 0.37;  head 0.57 / 0.55
##         -> 0.56;  stature 1.76 / 1.62 -> a crown at 1.69;  acromion height
##         1.44 / 1.33 -> shoulders at 1.40;  biacromial breadth 0.40 / 0.36
##         with the joint's centre a couple of centimetres inside the bone
##         -> shoulders 0.18 out from the axis;  acromion to radiale 0.34 /
##         0.31 less that offset -> an upper arm of 0.31;  radiale to stylion
##         0.27 / 0.24 -> a forearm of 0.25;  the grip's centre about 0.08
##         past the wrist crease;  forearm round 0.27 -> a limb radius 0.045.
##       Shoulder extension 50-60 degrees and horizontal abduction 40-45 are
##         held to 45 behind the frontal plane; adduction across the body to
##         45 past the sagittal plane; humeral rotation 70 in and 90 out;
##         elbow flexion 140-150 held to 140; wrist flexion 75 and extension
##         70 taken as one 60 degree cone, since the forearm's own rotation
##         can turn the plane it bends in.
##   The ranges are what a dancer will do without pain, not what a joint can
##     be forced to.  Past a range is refused, and the joint is named; the
##     last stretch before it is reported as strain, so a pose near its edge
##     is seen coming.
##   A torso's section is an ellipse of the tape's round: chest and waist
##     are about three quarters as deep as they are broad (ANSUR chest depth
##     0.25 to breadth 0.31, waist 0.22 to 0.30), and a round section of the
##     same girth stands 3 cm too far out at the front and 3 cm too far in at
##     the flank -- enough to refuse a forearm laid across one's own belly,
##     which is the first thing a crossed hold does.  The neck and head stay
##     round.
##     Cost: one more number in the rig, and a contact test that scales the
##       section to a circle first.  Accepted -- the alternative is a model
##       that calls a handshake a strain.

{.experimental: "strictFuncs".}

import std/math


type
  Part* {.pure.} = enum ## The three cylinders a body is, floor upward.
    Torso, Neck, Head

  Band* {.pure.} = enum ## Where a pair of joined hands is carried.
    ##   Named for the body part, not for a word of the dance: which of
    ##     these is "low" is put on outside the sim.
    Torso, ## About the chest, below the shoulder line.
    Neck,  ## About the neck, between the shoulders and the chin.
    Crown  ## Over the head, clear of it.

  Dof* {.pure.} = enum ## The freedoms of an arm that have an end.
    Extend, ## The upper arm behind the frontal plane, in degrees of angle.
    Across, ## The upper arm across the body, past the sagittal plane.
    Twist,  ## The upper arm turned about its own length: in is negative.
    Bend,   ## The elbow, nought when straight.
    Wrist   ## The hand off the line of the forearm, whichever way.

  Range* = object ## How far one freedom goes, and where it starts to strain.
    lo*, hi*: float     ## The ends, radians.  Past either is refused.
    easeLo*, easeHi*: float ## How far short of each end the strain begins;
                        ## nought where the end is a stop that can be leant on.
    neutral*: float     ## Where the joint rests; the solver prefers it.

  Rig* = object ## The tape's numbers, and the joints' ranges.
    round*: array[Part, float] ## Circumferences, metres.
    flat*: array[Part, float]  ## Depth over breadth of the section: one is
                               ## round; a chest is about three quarters.
    top*: array[Part, float]   ## The height each part stops at.  The torso
                               ## stops under the shoulder joints by the slope
                               ## of the shoulders, so a raised arm clears it.
    hip*: float                ## Where the torso starts.
    shoulderOut*: float        ## Each shoulder joint from the axis, sideways.
    shoulderUp*: float         ## And its height.
    upper*, fore*, hand*: float ## Shoulder to elbow, elbow to wrist, wrist to grip.
    limb*: float               ## Half an arm's thickness.
    range*: array[Dof, Range]
    band*: array[Band, tuple[lo, hi: float]] ## Hand heights offered per band.


func deg(d: float): float = d * PI / 180.0


const HUMAN* = Rig(
  round: [0.95, 0.37, 0.56],
  flat: [0.75, 1.0, 1.0],
  top: [1.36, 1.50, 1.69],
  hip: 0.80,
  shoulderOut: 0.18, shoulderUp: 1.40,
  upper: 0.31, fore: 0.25, hand: 0.08,
  limb: 0.045,
  range: [
    Range(lo: deg(-90), hi: deg(45), easeLo: 0.0, easeHi: deg(20), neutral: 0.0),
    Range(lo: deg(-90), hi: deg(45), easeLo: 0.0, easeHi: deg(20), neutral: 0.0),
    Range(lo: deg(-70), hi: deg(90), easeLo: deg(25), easeHi: deg(25), neutral: 0.0),
    Range(lo: 0.0, hi: deg(140), easeLo: 0.0, easeHi: deg(35), neutral: deg(30)),
    Range(lo: 0.0, hi: deg(60), easeLo: 0.0, easeHi: deg(20), neutral: 0.0)],
  band: [(1.00, 1.35), (1.40, 1.50), (1.735, 2.00)])
  ## The average adult.  The crown band starts a limb's radius over the head
  ## so a hand carried there clears it by construction.


func halfBreadth*(rig: Rig; part: Part): float =
  ## Side to side, from the axis: what the tape's round makes an ellipse of
  ## the part's flatness (Ramanujan's perimeter, inverted).
  let q = rig.flat[part]
  rig.round[part] / (PI * (3.0 * (1.0 + q) - sqrt((3.0 + q) * (1.0 + 3.0 * q))))

func halfDepth*(rig: Rig; part: Part): float =
  ## Front to back, from the axis.
  halfBreadth(rig, part) * rig.flat[part]

func radius*(rig: Rig; part: Part): float = rig.round[part] / (2.0 * PI)
  ## The round as one number: the radius of the circle of that round.

func bottom*(rig: Rig; part: Part): float =
  ## The height a part starts at: the hip, or the top of the part below.
  case part
  of Part.Torso: rig.hip
  of Part.Neck: rig.top[Part.Torso]
  of Part.Head: rig.top[Part.Neck]

func reach*(rig: Rig): float = rig.upper + rig.fore + rig.hand
  ## Shoulder to grip with everything straight: as far as a hand goes.

func touching*(rig: Rig): float = 2.0 * halfDepth(rig, Part.Torso)
  ## The closest two bodies stand: chest to chest.

func margin*(range: Range; value: float): float =
  ## How far `value` is inside the range, in units of the ease at the nearer
  ## end: one and more is comfortable, nought is the edge, negative is past it.
  ##   An end with no ease is a stop that costs nothing to lean on, so the
  ##     margin there is counted in the other end's ease and is only ever
  ##     negative when the value is past the stop.
  let
    fromLo = value - range.lo
    fromHi = range.hi - value
    unitLo = if range.easeLo > 0.0: range.easeLo else: range.easeHi
    unitHi = if range.easeHi > 0.0: range.easeHi else: range.easeLo
  var
    mLo = if range.easeLo > 0.0: fromLo / unitLo
          elif fromLo < 0.0: fromLo / unitLo
          else: Inf
    mHi = if range.easeHi > 0.0: fromHi / unitHi
          elif fromHi < 0.0: fromHi / unitHi
          else: Inf
  min(mLo, mHi)

func eased*(range: Range; value: float): float =
  ## Distance from the joint's neutral, as a fraction of the way to the
  ## farther end: the smooth cost the solver minimises.
  let span = max(range.hi - range.neutral, range.neutral - range.lo)
  (value - range.neutral) / span
