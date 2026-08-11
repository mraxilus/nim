## Route a connection as a taut string around the two bodies.
##
##   Each end pays out along its own outline until the straight stretch
##     between the free ends clears both bodies, so a reach hugs a rim
##     exactly as far as it must and no further.
##   Every route is resampled to one fixed number of points, which is what
##     lets an animation morph a reach instead of jumping it.
##     Cost of a fixed count: a long reach and a short one spend their points
##       at different densities.  Accepted -- the morph needs like for like.
##   Which way round a whole move goes is settled once, before any of it is
##     drawn (`oneWayRound`), because rule 1 must hold at every instant a
##     browser blends, not merely at the frames the move is sampled at.

{.experimental: "strictFuncs".}

import std/[math, options, strformat, strutils]

import ./[body, geometry, rules, style]


const ROUTE_N* = 33   ## Points in every emitted reach, so frames can morph.

type
  Body* = tuple ## One dancer, as the routing sees them.
    centre: Point
    facing: float
  WayRound* = tuple ## How a reach sets off round each body: one side or the
                    ## other.
    a, b: float
  Run* = seq[Point] ## One unbroken stretch of drawn reach.
  Ends* = tuple ## One connection, as the routing takes it.
    a, b: Point
    A, B: Body

const WAYS*: array[4, WayRound] = [
  (1.0, 1.0), (1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0),
] ## The four ways a reach can set off.  Which one a whole move uses is
  ## settled once, before any of it is drawn -- see `oneWayRound`.

const BREAK* = 11.0   ## Length of the gap cut in an under reach at a crossing.

const
  LOOP_R* = 7.0       ## The radius a wound single reach's pigtail is drawn at.
  LOOP_STEPS* = 24    ## Points per pigtail loop, enough to read as a circle.
  BRAID_R* = 9.0      ## How far a braided pair swings off its straight line.
  BRAID_STEPS* = 96   ## Points along a braided reach, before resampling.
  CROSS_NEAR* = 2.0   ## How close two reaches pass to count as crossing.


func segHits*(p, q: Point; body: Body): bool =
  ## Test whether this straight stretch passes inside a body's outline.
  const steps = 32
  for i in 0 .. steps:
    let
      t = i / steps
      pt: Point = (p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t)
      off = bearing(pt.x - body.centre.x, pt.y - body.centre.y) - body.facing
    if dist(pt, body.centre) < outlineR(off) - 0.05:
      return true
  false


func taut*(ends: Ends; way: WayRound; cap = 90): Option[tuple[pts: seq[Point],
    length: float]] =
  ## Pull a string tight from hand to hand around the two bodies.
  ##   Each end pays out along its own outline, one sample at a time, until
  ##     the straight stretch between the two free ends clears both bodies --
  ##     so the reach hugs a rim exactly as far as it has to, and where the
  ##     straight way is already clear it never hugs at all.
  var
    ta = bearing(ends.a.x - ends.A.centre.x, ends.a.y - ends.A.centre.y)
    tb = bearing(ends.b.x - ends.B.centre.x, ends.b.y - ends.B.centre.y)
    arc_a = @[ends.a]
    arc_b = @[ends.b]
  for _ in 0 ..< cap:
    let
      pa = arc_a[^1]
      pb = arc_b[^1]
      ha = segHits(pa, pb, ends.A)
      hb = segHits(pa, pb, ends.B)
    if not ha and not hb:
      let
        step = degToRad(RIM_STEP) * BODY_R
        length = step * float(arc_a.len + arc_b.len - 2) + dist(pa, pb)
      var pts = arc_a
      for i in countdown(arc_b.high, 0):
        pts.add arc_b[i]
      return some (pts, length)
    if ha:
      ta += way.a * RIM_STEP
      arc_a.add outlinePoint(ends.A.centre, ends.A.facing, ta)
    if hb:
      tb += way.b * RIM_STEP
      arc_b.add outlinePoint(ends.B.centre, ends.B.facing, tb)
  none(tuple[pts: seq[Point], length: float])


func polylineLen*(pts: seq[Point]): float =
  ## Get the drawn length of a run.
  for i in 0 ..< pts.high:
    result += dist(pts[i], pts[i + 1])


func trimEnd(pts: seq[Point]; centre: Point; reach: float): seq[Point] =
  ## Cut the path where it leaves the hand's own mark, so ink starts on the
  ## mark's border rather than under its middle.
  for i, q in pts:
    let d = dist(q, centre)
    if d >= reach:
      if i == 0:
        return pts
      let
        prev = pts[i - 1]
        pd = dist(prev, centre)
        t = if d > pd: (reach - pd) / (d - pd) else: 0.0
        crossing: Point = (prev.x + (q.x - prev.x) * t,
                           prev.y + (q.y - prev.y) * t)
      return @[crossing] & pts[i .. ^1]
  @[pts[^1]]


func reversed(pts: seq[Point]): seq[Point] =
  ## Walk the same run from the other end.
  for i in countdown(pts.high, 0):
    result.add pts[i]


func resample*(pts: seq[Point]; count: int): seq[Point] =
  ## Say the same path as `count` evenly spaced points -- one shape for every
  ## frame of an animation, so a route can morph instead of jumping.
  var cum = @[0.0]
  for i in 0 ..< pts.high:
    cum.add cum[^1] + dist(pts[i], pts[i + 1])
  let total = if cum[^1] > 0: cum[^1] else: 1.0
  var j = 0
  for k in 0 ..< count:
    let target = total * float(k) / float(count - 1)
    while j < pts.len - 2 and cum[j + 1] < target:
      inc j
    let
      gap = cum[j + 1] - cum[j]
      span = if gap > 0: gap else: 1.0
      t = (target - cum[j]) / span
      p = pts[j]
      q = pts[j + 1]
    result.add (p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t)


func frontOf*(hand: Point; body: Body): float =
  ## Get the way round the rim, from this hand, that heads for its own
  ## dancer's front.
  ##   A hand's own side turns "front" or "back" into a direction by itself,
  ##     so this is the whole of what a rule naming one has to work out.
  ##   Zero where the hand is dead ahead or dead behind and neither way is
  ##     more frontward than the other.
  let off = wrap180(
    bearing(hand.x - body.centre.x, hand.y - body.centre.y) - body.facing)
  if abs(off) < 1e-9 or abs(abs(off) - 180) < 1e-9:
    return 0.0
  if off > 0: -1.0 else: 1.0


func wayFor*(ends: Ends; level: Option[Level]; way: Option[Way]):
    Option[WayRound] =
  ## Get which way round both bodies this hold says its line goes.
  ##   Not what is shortest -- what the dance says: both wraps come round the
  ##     front, both locks round the back (rules 4 to 6).  A hold that has
  ##     named no level or no way has no opinion, and `routed` takes the
  ##     short way.
  let sends = roundOf(level, way)
  if sends.isNone:
    return none(WayRound)
  let sides = (a: frontOf(ends.a, ends.A), b: frontOf(ends.b, ends.B))
  if sides.a == 0 or sides.b == 0:
    return none(WayRound)             # dead ahead or behind: neither way
  if sends.get == Sends.FrontWay:
    some (sides.a, sides.b)
  else:
    some (-sides.a, -sides.b)


func wrapArc*(ends: Ends; way: WayRound): Option[tuple[a, b: float]] =
  ## Measure how far round each body the line actually hugs, in degrees.
  ##   `taut` walks these arcs already and throws the count away; this keeps
  ##     it, because a wrap that does not wrap is not a wrap (rule 7) and the
  ##     only way to know is to measure what was drawn.
  var
    ta = bearing(ends.a.x - ends.A.centre.x, ends.a.y - ends.A.centre.y)
    tb = bearing(ends.b.x - ends.B.centre.x, ends.b.y - ends.B.centre.y)
    pa = ends.a
    pb = ends.b
    na = 0
    nb = 0
  for _ in 0 ..< 240:
    let
      ha = segHits(pa, pb, ends.A)
      hb = segHits(pa, pb, ends.B)
    if not ha and not hb:
      return some (float(na) * RIM_STEP, float(nb) * RIM_STEP)
    if ha:
      ta += way.a * RIM_STEP
      pa = outlinePoint(ends.A.centre, ends.A.facing, ta)
      inc na
    if hb:
      tb += way.b * RIM_STEP
      pb = outlinePoint(ends.B.centre, ends.B.facing, tb)
      inc nb
  none(tuple[a, b: float])


func wrapsEnough*(ends: Ends; level: Option[Level]; way: Option[Way]): bool =
  ## Test whether this hold's line really does go round a body far enough to
  ## be the lock or wrap it claims to be (rule 7).
  let asked = wayFor(ends, level, way)
  if asked.isNone:
    return false
  let arcs = wrapArc(ends, asked.get)
  arcs.isSome and max(arcs.get.a, arcs.get.b) >= float(WRAP_MIN)


func straightReach*(a, b: Point): seq[Point] =
  ## Route a reach that goes over everything instead of round it.
  ##   An `above` connection passes over the head, so from overhead there is
  ##     nothing in its way -- no head, no torso -- and it is drawn straight
  ##     across whatever it crosses (rule 1's one exception).
  ##   Trimmed and resampled like any other reach, so it has the same shape
  ##     and an animation can morph between it and a wrapping one.
  let reach = min(R + CAP, dist(a, b) / 3)
  var pts = trimEnd(@[a, b], a, reach)
  pts = reversed(trimEnd(reversed(pts), b, reach))
  resample(pts, ROUTE_N)


func pigtailed*(a, b: Point; loops: int): seq[Point] =
  ## Route a lone reach that has been wound, as a straight line with a
  ## pigtail at its middle: one loop per half turn, the sense from the sign.
  ##   A pair of connections says a twist by crossing each other (rule 14);
  ##     one connection has nothing to cross but itself, so it does.
  ##   Cost of an invented mark: nothing in the dance draws a pigtail, so
  ##     this is the page's own convention and is flagged as such.
  if loops == 0:
    return straightReach(a, b)
  let
    reach = min(R + CAP, dist(a, b) / 3)
    span = dist(a, b)
    turns = abs(loops)
    sense = float(sgn(loops))
    # Along the line, and square to it: a loop is drawn in the reach's own
    # frame so it leans with the reach rather than with the page.
    along = ((b.x - a.x) / span, (b.y - a.y) / span)
    across = (-along[1], along[0])
    radius = min(LOOP_R, span / float(4 * turns + 4))
    middle = span / 2 - float(turns - 1) * radius
  var pts = @[a]
  for k in 0 ..< turns:
    # One loop: a full circle walked beside the line, offset a diameter on
    # so several loops read as a row rather than as one thicker circle.
    let centre_at = middle + float(k) * 2 * radius
    for step in 0 .. LOOP_STEPS:
      let
        turn_by = -PI / 2 + sense * 2 * PI * float(step) / float(LOOP_STEPS)
        out_x = radius * cos(turn_by)
        out_y = radius * sin(turn_by) * sense
      pts.add (a.x + along[0] * (centre_at + out_x) + across[0] * (radius + out_y),
               a.y + along[1] * (centre_at + out_x) + across[1] * (radius + out_y))
  pts.add b
  var trimmed = trimEnd(pts, a, reach)
  trimmed = reversed(trimEnd(reversed(trimmed), b, reach))
  resample(trimmed, ROUTE_N)


func braided*(a, b: Point; crossings: int; phase: float): seq[Point] =
  ## Route one member of a braided pair: the straight line pushed sideways
  ## so the two members swap sides `crossings` times over the middle.
  ##   Two arms wound round each other is a rope, and a rope is drawn as the
  ##     crossings it has -- the crossover's own reading, said as often as
  ##     the wind says it (rule 14).
  if crossings == 0:
    return straightReach(a, b)
  let
    reach = min(R + CAP, dist(a, b) / 3)
    span = dist(a, b)
    along = ((b.x - a.x) / span, (b.y - a.y) / span)
    across = (-along[1], along[0])
    swing = min(BRAID_R, span / 6)
  var pts: seq[Point]
  for step in 0 .. BRAID_STEPS:
    let
      t = float(step) / float(BRAID_STEPS)
      # Held straight at the ends and braided in the middle third, so the
      # crossings sit clear of both hands.
      shape = (if t < 0.2 or t > 0.8: 0.0
               else: sin(PI * (t - 0.2) / 0.6))
      wave = sin(PI * float(crossings) * (t - 0.2) / 0.6 + phase)
      off = swing * shape * wave
    pts.add (a.x + (b.x - a.x) * t + across[0] * off,
             a.y + (b.y - a.y) * t + across[1] * off)
  var trimmed = trimEnd(pts, a, reach)
  trimmed = reversed(trimEnd(reversed(trimmed), b, reach))
  resample(trimmed, ROUTE_N)


func crossingsOf*(one, other: seq[Point]): seq[Point] =
  ## Find where two drawn reaches cross, so each crossing can be broken.
  for i in 0 ..< one.high:
    var nearest = (d: Inf, at: one[i])
    for j in 0 ..< other.high:
      let d = dist(one[i], other[j])
      if d < nearest.d:
        nearest = (d, other[j])
    if nearest.d < CROSS_NEAR:
      # One point per crossing: keep the first of each run of near points.
      if result.len == 0 or dist(result[^1], one[i]) > BREAK:
        result.add one[i]


func cutGapsAt*(pts: seq[Point]; centres: seq[Point]): seq[Run] =
  ## Break a reach at every place it runs under another, not only the first.
  if centres.len == 0:
    return @[pts]
  var cum = @[0.0]
  for i in 0 ..< pts.high:
    cum.add cum[^1] + dist(pts[i], pts[i + 1])
  var breaks: seq[float]
  for centre in centres:
    var nearest = (d: Inf, at: 0.0)
    for i, p in pts:
      let d = dist(p, centre)
      if d < nearest.d:
        nearest = (d, cum[i])
    breaks.add nearest.at
  var run: Run
  for i, q in pts:
    var covered = false
    for at in breaks:
      if abs(cum[i] - at) <= BREAK / 2:
        covered = true
    if covered:
      if run.len > 1:
        result.add run
      run = @[]
    else:
      run.add q
  if run.len > 1:
    result.add run


func routed*(ends: Ends; way = none(WayRound)):
    Option[tuple[pts: seq[Point], way: WayRound]] =
  ## Route one reach: hand border to hand border, wrapping wherever it must.
  ##   With nothing said it takes the short way round.  Hand it one of `WAYS`
  ##     and it takes that one instead, whatever the length -- which is how a
  ##     whole move keeps to one side of a body from first frame to last.
  var best = none(tuple[pts: seq[Point], length: float, way: WayRound])
  for combo in (if way.isSome: @[way.get] else: @WAYS):
    let pulled = taut(ends, combo)
    if pulled.isSome and (best.isNone or pulled.get.length < best.get.length):
      best = some (pulled.get.pts, pulled.get.length, combo)
  if best.isNone:
    return none(tuple[pts: seq[Point], way: WayRound])
  let reach = min(R + CAP, polylineLen(best.get.pts) / 3)
  var pts = trimEnd(best.get.pts, ends.a, reach)
  pts = reversed(trimEnd(reversed(pts), ends.b, reach))
  some (resample(pts, ROUTE_N), best.get.way)


func oneWayRound*(frames: seq[Ends]): WayRound =
  ## Settle the single way round a whole move is drawn with.
  ##   A moving reach is interpolated between the frames it is sampled at, so
  ##     two neighbouring frames that disagree about which side of a body the
  ##     line passes are drawn, in between, as a line sweeping straight
  ##     through that body.  One way for the whole move makes that
  ##     impossible: no two frames can disagree if there is only one answer.
  ##   It has to be a way every frame can actually be routed, so the ones
  ##     that fail anywhere are dropped and the shortest of the rest wins.
  var best = none(tuple[way: WayRound, total: float])
  for combo in WAYS:
    var
      total = 0.0
      served = true
    for ends in frames:
      let pulled = taut(ends, combo)
      if pulled.isNone:
        served = false
        break
      total += polylineLen(pulled.get.pts)
    if served and (best.isNone or total < best.get.total):
      best = some (combo, total)
  doAssert best.isSome,
    &"No way round serves every frame of this move; got `{frames.len}` frames."
  best.get.way


func splitAt*(runs: seq[Run]; mid: Point): tuple[near, far: seq[Run]] =
  ## Cut a reach in two at the point nearest `mid`, so it can be drawn in two
  ## shades that meet there.
  ##   The two halves share that point, so the join is a join and not a gap;
  ##     and any break an over-and-under crossing has already cut stays cut,
  ##     because the runs are split rather than rebuilt.
  var best = (d: Inf, i: 0, j: 0)
  for i, run in runs:
    for j, q in run:
      let d = dist(q, mid)
      if d < best.d:
        best = (d, i, j)
  var near = runs[0 ..< best.i] & @[runs[best.i][0 .. best.j]]
  var far = @[runs[best.i][best.j .. ^1]] & runs[best.i + 1 .. ^1]
  for run in near:
    if run.len > 1:
      result.near.add run
  for run in far:
    if run.len > 1:
      result.far.add run


func reachMarkup*(runs: seq[Run]; ink: string): string =
  ## Draw one shade's worth of reach as a single path.
  var pieces: seq[string]
  for run in runs:
    if run.len > 1:
      var d = "M" & xy(run[0])
      for q in run[1 .. ^1]:
        d.add " L" & xy(q)
      pieces.add d
  let d = pieces.join(" ")
  &"""<path d="{d}" fill="none" stroke="{ink}"""" &
    &""" stroke-width="{LINK_W}" stroke-linecap="round"""" &
    """ stroke-linejoin="round"/>"""


func cutGap*(pts: seq[Point]; over: seq[Point]): seq[Run] =
  ## Break the under reach where the over one crosses it.
  var cum = @[0.0]
  for i in 0 ..< pts.high:
    cum.add cum[^1] + dist(pts[i], pts[i + 1])
  var nearest = (d: Inf, i: 0)
  for i, p in pts:
    for q in over:
      let d = dist(p, q)
      if d < nearest.d:
        nearest = (d, i)
  let here = cum[nearest.i]
  var first, second: Run
  for i, q in pts:
    if cum[i] <= here - BREAK / 2:
      first.add q
    if cum[i] >= here + BREAK / 2:
      second.add q
  @[first, second]
