## Ask the rope model for a couple at any turn, from the drawn page.
##
##   The whole-cloth page animates a hold turning, and the one honest way to
##     animate two bodies and a rope is to ask the thing that models them.
##     This module compiles to JavaScript and is spliced into the page by
##     `nimble turns`; the page calls it once per frame and draws what comes
##     back -- where the bodies stand, where each hand is anchored, and the
##     rope's plan path as the model lays it.  Nothing about the physics is
##     guessed on the page: which body a rope hugs, how far round, and where
##     it runs out are all read from here.
##   The design directory may import the sim; the sim imports nothing back.
##     The words (wrap, lock, low, high) are put on here, as `sim/verdicts`
##     does, so the model itself stays vocabulary-free.
##   Two rests, both the page's own choice: the cross-name holds rest face
##     to face, and the same-name holds are also built face to face so the
##     turns count as the sheet counts (the away rest is a half turn along).
##     The same-name *pair* is the exception: face to face its two ropes
##     lie through each other and the model refuses it before anything has
##     turned, so it is built at the away rest -- collected there, as a
##     couple would -- and its turns count from that rest.

import std/[json, math, options, strutils]

import ../sim/rope


const
  APART = 0.40 ## The stance, in metres: the same one `sim/verdicts` asks at.
  LOW = 1.20
  HIGH = 1.53
  ABOVE = 1.82
  MOST = 2.5 ## Turns swept each way looking for the block.


func heightOf(level: string): float =
  case level
  of "low": LOW
  of "high": HIGH
  else: ABOVE


func armsOf(hold: string): seq[(Arm, Arm)] =
  ## Read "L-l" or "L-r.R-l": the lead's hand in capitals, the follow's in lower case.
  for part in hold.split('.'):
    let
      a = if part[0] == 'L': Arm.Left else: Arm.Right
      b = if part[2] == 'l': Arm.Left else: Arm.Right
    result.add (a, b)


func sameName(hold: string): bool =
  for (a, b) in armsOf(hold):
    if a != b: return false
  true


func rested(hold, level: string): State =
  ## Build the hold at the rest its turns are counted from.
  result = facing(HUMAN, APART)
  if hold.contains('.') and sameName(hold):
    # Turned away by the half turn that *uncrosses* a same-name pair: the
    # model reads the face-to-face X as crossed anticlockwise, so the
    # parallel rest lies a half turn clockwise of it.  Set the other way
    # the braid would read the pair as crossed twice.
    result.stance[Body.Two].facing = result.stance[Body.Two].facing - PI
  for (a, b) in armsOf(hold):
    result.links.add Link(ends: [(Body.One, a), (Body.Two, b)],
                          height: heightOf(level))
  result = settled(result)


func said(lying: Option[Lying]): string =
  ## Write where a wound arm lies, in the sheet's words -- the one translation.
  if lying.isNone:
    return "open"
  let
    way = if lying.get.aspect == Aspect.Fore: "wrap" else: "lock"
    band = if lying.get.band == Band.Torso: "low" else: "high"
    laps = if lying.get.laps > 0: " +" & $lying.get.laps & " lap" else: ""
    held = if lying.get.wound: "" else: " (led)"
  way & " " & band & laps & held


func short(state: State): string =
  ## Say the verdict in the few words a page can show.
  let refusing = refusal(state)
  if refusing.isNone:
    return "holds"
  case refusing.get
  of Fault.Tangent: "cannot be laid"
  of Fault.Through: "through a body"
  of Fault.Budget: "out of rope"
  of Fault.Braided: "rope through rope"
  of Fault.Swan: "past the swan"


func at(hold, level: string; turn: float): State =
  let base = rested(hold, level)
  if abs(turn) < 1e-9: base
  else: turned(base, Body.Two, turn * 2.0 * PI)


func vecJson(v: Vec): JsonNode = %*[v.x, v.y]


proc turnScene(hold, level: cstring; turn: float): cstring {.exportc.} =
  ## Give the couple at a turn, as JSON the page draws from.
  let s = at($hold, $level, turn)
  var j = %*{
    "verdict": short(s),
    "bodies": [
      {"centre": vecJson(s.stance[Body.One].centre),
       "facing": s.stance[Body.One].facing},
      {"centre": vecJson(s.stance[Body.Two].centre),
       "facing": s.stance[Body.Two].facing}],
    "anchors": {
      "him": {"L": vecJson(anchor(s, (Body.One, Arm.Left))),
              "R": vecJson(anchor(s, (Body.One, Arm.Right)))},
      "her": {"L": vecJson(anchor(s, (Body.Two, Arm.Left))),
              "R": vecJson(anchor(s, (Body.Two, Arm.Right)))}},
    "torso": s.rig.torso,
    "links": []}
  for link in s.links:
    var lj = %*{
      "her": said(lyingOn(s, link, Body.Two)),
      "him": said(lyingOn(s, link, Body.One)),
      "pts": []}
    let laid = lay(s, link)
    if laid.isSome:
      lj["length"] = %laid.get.length
      lj["braided"] = %braidedLie(laid.get)
      for p in traced(s, link, laid.get).at:
        lj["pts"].add vecJson(p)
    j["links"].add lj
  j["budget"] = %budget(s.rig)
  cstring($j)


func limitWay(base: State; sign: float): float =
  ## Sweep one way until a connection refuses; the turn reached, in turns.
  ##   `windLimit` sweeps one way only, so the other way is swept here the
  ##     same way it does: forward in steps, then bisected inside the step
  ##     that failed.
  const STEP = 0.05
  var
    went = 0.0
    here = base
  if not holds(here):
    return 0.0
  while went < MOST * 2.0 * PI:
    let next = turned(here, Body.Two, sign * STEP, STEP)
    if not holds(next):
      var
        lo = 0.0
        hi = STEP
      for _ in 0 ..< 20:
        let mid = (lo + hi) / 2.0
        if holds(turned(here, Body.Two, sign * mid, STEP)): lo = mid
        else: hi = mid
      return (went + lo) / (2.0 * PI)
    here = next
    went += STEP
  MOST


proc turnLimits(hold, level: cstring): cstring {.exportc.} =
  ## Say how far the follow can turn each way before the rope refuses.
  ##   Swept with the swan limit on: the page is asked to block where a
  ##     dancer would be blocked, and the pair's twist is one of those places.
  let base = rested($hold, $level)
  let
    pos = limitWay(base, 1.0)
    neg = limitWay(base, -1.0)
  var why = "holds"
  if pos < MOST:
    why = short(turned(base, Body.Two, (pos + 0.02) * 2.0 * PI))
  var whyNeg = "holds"
  if neg < MOST:
    whyNeg = short(turned(base, Body.Two, -(neg + 0.02) * 2.0 * PI))
  cstring($(%*{"pos": pos, "neg": neg, "why": why, "whyNeg": whyNeg,
               "restVerdict": short(base)}))
