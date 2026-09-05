## Arms against bodies, and arms against arms.
##
##   Every link of an arm is a capsule: a segment with the limb's radius round
##     it.  A body is its rig's cylinders.  The test between them is exact on
##     a cylinder's side and on its caps -- the segment is clipped to the
##     part's height band widened by the limb's radius, and the nearest the
##     clipped piece comes to the axis is compared with the part's radius --
##     and over-cautious by at most a centimetre right at a cap's rim.
##   Against its own body an arm is allowed to press: the clearance asked is
##     the part's radius alone, so the link's axis may touch the skin.  The
##     shoulder joint itself sits only three centimetres outside the torso,
##     which is less than a limb's radius, so nothing else lets an arm hang.
##     Cost: an arm can sink half its thickness into its own chest.  Accepted
##       -- flesh gives about that much, and the alternative refuses standing.

{.experimental: "strictFuncs".}

import std/math

import ./[body, rig, vec]


type Touch* = object ## The nearest a link comes to a body, and to which part.
  part*: Part
  gap*: float ## Clearance in metres; negative is through the skin.


func partGap*(rig: Rig; ax: Axes; part: Part; a, b: Vec): float =
  ## The clearance of link `a`-`b` from one part of the body whose axes these
  ## are, before any pad; infinite where the link is not at its height.
  ##   The section is an ellipse, so the link is taken into the body's own
  ##     terms and its depth scaled up until the section is a circle; the
  ##     nearest approach is found there, and the clearance read back along
  ##     the radial line -- exact at the front and at the flank, and a shade
  ##     approximate between.
  let
    q = rig.flat[part]
    la = toBody(ax, a)
    lb = toBody(ax, b)
    near = axisNear((la.x, la.y / q, la.z), (lb.x, lb.y / q, lb.z),
                    bottom(rig, part) - rig.limb, rig.top[part] + rig.limb)
  if near.d == Inf:
    return Inf
  let k = if near.d < 1e-9: 1.0
          else: sqrt(near.nx * near.nx + q * q * near.ny * near.ny) / near.d
  (near.d - halfBreadth(rig, part)) * k


func bodyGap*(rig: Rig; st: Stance; a, b: Vec; own: bool): Touch =
  ## The least clearance of link `a`-`b` from one body's three parts.
  result = Touch(part: Part.Torso, gap: Inf)
  let
    pad = if own: 0.0 else: rig.limb
    ax = axesOf(st)
  for part in Part:
    let d = partGap(rig, ax, part, a, b)
    if d < Inf:
      let gap = d - pad
      if gap < result.gap:
        result = Touch(part: part, gap: gap)


func armGap*(rig: Rig; a, b, c, d: Vec; meet: Vec; excuse: float): float =
  ## The clearance between two links of different arms; infinite where they
  ## come nearest within `excuse` of `meet`, which is how two arms holding
  ## one grip are let converge on it.
  let near = closest(a, b, c, d)
  if excuse > 0.0:
    let
      p = a + (b - a) * near.t
      q = c + (d - c) * near.u
    if dist(p, meet) < excuse and dist(q, meet) < excuse:
      return Inf
  near.gap - 2.0 * rig.limb


func pressing*(rig: Rig; st: Stance; pose: tuple[e, w, g: Vec]): bool =
  ## Whether the forearm or hand lies on its own torso or neck.
  ##   The upper arm always hangs against the flank, so it is not asked;
  ##     what says an arm is wound rather than merely led there is the part
  ##     of it past the elbow.
  const NEAR = 0.01
  let ax = axesOf(st)
  for (a, b) in [(pose.e, pose.w), (pose.w, pose.g)]:
    for part in [Part.Torso, Part.Neck]:
      if partGap(rig, ax, part, a, b) < NEAR:
        return true
  false
