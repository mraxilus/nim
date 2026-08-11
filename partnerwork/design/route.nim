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

import std/[math, options, sequtils, strformat, strutils]

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
  BOX_ROOM* = 24.0    ## How wide the diamond a wound pair holds opens at
                      ## its middle.
  BRAID_STEPS* = 96   ## Points along a braided reach, before resampling.
  BAND_STEPS* = 120   ## Points along a reach relaxed past marks, before it.
  CROSS_NEAR* = 2.0   ## How close two reaches pass to count as crossing.

const
  BAND_PASSES* = 240    ## Turns of pulling tight and pushing clear.
    ## Enough for a band round the marks a figure holds to stop moving: the
    ##   pull travels one point a pass, so a band of `BAND_STEPS` needs
    ##   several times its own length to settle end to end.
  SHOVES* = 8           ## Shoves a point gets per pass to leave every mark.
  BAND_PULL* = 0.5      ## How far a point goes towards its neighbours' middle.
    ## Half way is the most that stays steady; further and the band shivers
    ##   instead of settling.
  CLEAR_PASSES* = 12    ## Times a band may be widened to what it left clear.
    ## Widening a mark moves the band, which can hand the shortfall to the
    ##   mark next door, so the settling takes a few goes; `checks` measures
    ##   the line that comes out rather than trusting that it did.
  CLEAR_ENOUGH* = 0.01  ## Shortfall small enough to stop widening at.
    ## A hundredth of a unit is a fiftieth of the thinnest thing drawn, so a
    ##   band that is this close is as clear as the picture can show.

const
  BOW_SWELL* = 2.0      ## Where a bezier's control point starts, in apexes.
    ## Twice the apex is what puts a bezier's own middle on it, so this is
    ##   the least swelling that could clear what the hull touched.
  BOW_MORE* = 0.35      ## And how much further out each try reaches.
  BOW_TRIES* = 12       ## Tries before the hull is kept after all.

const
  BEND_MIN* = 12.0      ## Degrees a turn must add up to before it is a bend.
    ## Under this is the wander of a curve drawn as `ROUTE_N` straight bits,
    ##   which nobody reads as a change of direction.
  BEND_COST* = 14.0     ## Line a second bend must save to be worth making.
    ## About the width of a hand mark: a turn a reader has to follow should
    ##   buy at least as much as the thing it is going round.
  SHARP_MAX* = 15.0     ## Degrees at one corner past which a bend is a break.
    ## A curve sampled at `ROUTE_N` turns a few degrees a corner however far
    ##   round it goes, so anything this sharp is a change of direction made
    ##   at a point -- which is what rule 24 rules out.


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


type Mark* = tuple ## Something a settled reach must not run through.
  centre: Point
  clear: float


func nearestOn*(pts: seq[Point]; q: Point): float =
  ## Measure how close a drawn line comes to a point, segments and all.
  ##   Sampled points alone would miss the sag between them, which is the
  ##     very place a line that looks clear stops being clear.
  result = Inf
  for i in 0 ..< pts.high:
    let
      (a, b) = (pts[i], pts[i + 1])
      run = (x: b.x - a.x, y: b.y - a.y)
      square = run.x * run.x + run.y * run.y
      along = if square < 1e-12: 0.0
              else: clamp(((q.x - a.x) * run.x + (q.y - a.y) * run.y) / square,
                          0.0, 1.0)
      near: Point = (a.x + run.x * along, a.y + run.y * along)
    result = min(result, dist(near, q))


func bendsIn*(pts: seq[Point]): int =
  ## Count the separate turns a drawn line makes -- what it asks a reader to
  ## follow, rather than how many corners it happens to be drawn from.
  ##   A bend is a sustained turn one way round: it counts once its corners
  ##     have added up to `BEND_MIN`, however many of them there were, so a
  ##     long smooth arc is one bend and not thirty.
  ##   Turning back only starts a new bend once *that* has added up to
  ##     `BEND_MIN` too.  Without that, the hair of opposite wander in a
  ##     curve drawn as straight bits would end the arc it is inside and the
  ##     same arc would be counted again and again.
  var
    way = 0.0
    turned = 0.0
    against = 0.0
    counted = false
  for i in 1 ..< pts.high:
    let
      into = (x: pts[i].x - pts[i - 1].x, y: pts[i].y - pts[i - 1].y)
      away = (x: pts[i + 1].x - pts[i].x, y: pts[i + 1].y - pts[i].y)
      cross = into.x * away.y - into.y * away.x
      dot = into.x * away.x + into.y * away.y
      corner = radToDeg(arctan2(cross, dot))
    if corner == 0:
      continue
    if way == 0:
      way = sgn(corner).float
    if sgn(corner).float == way:
      turned += abs(corner)
      against = 0.0
    else:
      against += abs(corner)
      if against < BEND_MIN:
        continue
      way = -way
      turned = against
      against = 0.0
      counted = false
    if not counted and turned >= BEND_MIN:
      inc result
      counted = true
  result


func sharpestIn*(pts: seq[Point]): float =
  ## Measure the worst break in a drawn line: the most it turns at any one
  ## of its corners (rule 24).
  ##   A curve drawn as `ROUTE_N` straight bits turns a little at every one
  ##     of them; a corner turns a lot at one.  So the sharpest corner, and
  ##     not the total turning, is what tells a break from a bend.
  for i in 1 ..< pts.high:
    let
      into = (x: pts[i].x - pts[i - 1].x, y: pts[i].y - pts[i - 1].y)
      away = (x: pts[i + 1].x - pts[i].x, y: pts[i + 1].y - pts[i].y)
      cross = into.x * away.y - into.y * away.x
      dot = into.x * away.x + into.y * away.y
    result = max(result, abs(radToDeg(arctan2(cross, dot))))


func readingCost*(pts: seq[Point]): float =
  ## Measure what a drawn reach asks of a reader: its length, and its turns.
  ##   A turn is worth `BEND_COST` of line: taking one has to save at least
  ##     that much to be worth following (rule 23).
  polylineLen(pts) + BEND_COST * float(bendsIn(pts))


func letGo*(a, b: Point; marks: seq[Mark]; side: float): seq[Point] =
  ## Route a settled reach as a string pulled taut past the marks in its
  ## way, and straight everywhere else (rule 22).
  ##   A line through a hand cell it does not end on says that hand is
  ##     held; a line through a chevron hides a facing.  So the line is a
  ##     band, pinned at the two hands, that no mark may be inside.
  ##   It is found the way a band finds its own shape: start it somewhere,
  ##     then take turns pulling it tight -- each point drawn towards the
  ##     midpoint of its neighbours -- and pushing whatever has ended up
  ##     inside a mark back out to that mark's edge.  Where nothing is in
  ##     the way the pulling wins outright and the band is straight; where
  ##     something is, the band lies along its edge and leaves on the side
  ##     it was already passing.
  ##     Cost of relaxing rather than solving: the shape is the settled
  ##       state of a hundred small steps, not a closed form, and a mark
  ##       sitting exactly on the straight line is turned either way by an
  ##       arithmetic hair.  Accepted -- it is what a real band does, and
  ##       the result is measured rather than trusted.
  ##   `side` is where the band is let go from, which is what decides which
  ##     way round each mark it settles: `0` starts it on the straight line,
  ##     `1` and `-1` start it bowed clear over everything on one side or
  ##     the other.  `clearedReach` is what chooses between them.
  ##   A reach is drawn as `ROUTE_N` points joined by straight segments, and
  ##     a segment is a chord across whatever the band is bending round --
  ##     which falls inside the curve it stands on.  So each mark is asked
  ##     for a little more than it needs, by exactly that depth, and the
  ##     drawn line is then measured against what the marks really are.
  let span = dist(a, b)
  if marks.len == 0 or span < 1e-9:
    return straightReach(a, b)
  let
    along = ((b.x - a.x) / span, (b.y - a.y) / span)
    across = (-along[1], along[0])

  func asDrawn(pts: seq[Point]): seq[Point] =
    ## One way past the marks, cut back to the hands' own edges and sampled
    ## the way every reach is, so any two of them can be compared -- and so
    ## an animation can morph between one and a wrapping reach.
    let reach = min(R + CAP, span / 3)
    var cut = trimEnd(pts, a, reach)
    cut = reversed(trimEnd(reversed(cut), b, reach))
    resample(cut, ROUTE_N)

  func placed(x, y: float): Point =
    ## Put a point back where it belongs: so far along the chord, so far off
    ## it.
    (a.x + along[0] * x + across[0] * y, a.y + along[1] * x + across[1] * y)

  func bowedPast(asked: seq[Mark]; side: float): seq[Point] =
    ## The one-bend way past everything: a single curve pinned at the two
    ## hands and held to one side of the chord (rules 23 and 24).
    ##   The marks are read as a sky-line first: how far out a string would
    ##     have to be at each step to clear everything reaching that far.
    ##     Its upper hull is the taut string on that side -- the shortest
    ##     line that turns one way only -- and its apex says where the bulge
    ##     belongs and how far out it has to go.
    ##   The line drawn is not that hull, though.  A hull is a polyline and
    ##     its apex is a corner; rule 24 asks for a curve.  So the hull is
    ##     read as a guide and the reach is **one quadratic bezier** over
    ##     the same apex, swelled until it clears every mark -- which turns
    ##     one way only, as a bezier does, and has no break in it.
    ##     Cost of the curve over the hull: a shade more line, since a
    ##       bezier passes short of its control point and has to reach
    ##       further out to clear what the hull touched exactly.  Accepted
    ##       -- it is the difference between a bend and a break.
    var sky = @[0.0]                   # pinned at the hand it starts from
    for step in 1 ..< BAND_STEPS:
      let x = span * float(step) / float(BAND_STEPS)
      var pushed = 0.0
      for mark in asked:
        let
          to_mark = (mark.centre.x - a.x, mark.centre.y - a.y)
          xc = to_mark[0] * along[0] + to_mark[1] * along[1]
          yc = side * (to_mark[0] * across[0] + to_mark[1] * across[1])
          reach = mark.clear * mark.clear - (x - xc) * (x - xc)
        if reach > 0:
          pushed = max(pushed, yc + sqrt(reach))
      sky.add pushed
    sky.add 0.0                        # and at the hand it ends on
    # The upper hull of the sky-line, walked left to right: a point stays
    # only while the line to it still turns the same way as the one before.
    var hull: seq[int]
    for i in 0 .. sky.high:
      let x = span * float(i) / float(BAND_STEPS)
      while hull.len >= 2:
        let
          (p, q) = (hull[^2], hull[^1])
          (px, qx) = (span * float(p) / float(BAND_STEPS),
                      span * float(q) / float(BAND_STEPS))
        if (qx - px) * (sky[i] - sky[p]) - (sky[q] - sky[p]) * (x - px) <= 0:
          break
        discard hull.pop()
      hull.add i
    result = @[]
    for i in hull:
      result.add placed(span * float(i) / float(BAND_STEPS), side * sky[i])
    # Where the hull stands furthest off the chord is where the curve wants
    # its control point.  A flat hull is a straight reach and wants none.
    var apex = 0
    for i in hull:
      if sky[i] > sky[apex]:
        apex = i
    if sky[apex] < 1e-9:
      return
    let at = span * float(apex) / float(BAND_STEPS)

    func curveWith(swell: float): seq[Point] =
      ## The bezier from hand to hand over a control point this far out.
      let hold = placed(at, side * swell * sky[apex])
      for step in 0 .. BAND_STEPS:
        let
          t = float(step) / float(BAND_STEPS)
          k = (1 - t) * (1 - t)
          m = 2 * (1 - t) * t
          n = t * t
        result.add (k * a.x + m * hold.x + n * b.x,
                    k * a.y + m * hold.y + n * b.y)

    # A bezier sags inside its control point, so it is swelled until it
    # really is clear of everything, and the hull is kept for the case --
    # a mark sitting almost on a hand -- where no swelling does it.
    for try_no in 0 .. BOW_TRIES:
      let
        curve = curveWith(BOW_SWELL + BOW_MORE * float(try_no))
        clear = asked.allIt(nearestOn(curve, it.centre) >= it.clear)
      if clear:
        return curve

  func drawnOver(asked: seq[Mark]): seq[Point] =
    ## The shortest way past the marks: a band let go from the straight line
    ## and left to settle.
    var band: seq[Point]
    for step in 0 .. BAND_STEPS:
      band.add placed(span * float(step) / float(BAND_STEPS), 0.0)
    for pass_no in 1 .. BAND_PASSES:
      for i in 1 ..< band.high:
        let
          pull: Point = ((band[i - 1].x + band[i + 1].x) / 2,
                         (band[i - 1].y + band[i + 1].y) / 2)
        band[i] = (band[i].x + (pull.x - band[i].x) * BAND_PULL,
                   band[i].y + (pull.y - band[i].y) * BAND_PULL)
        # Pushed out of the mark it is deepest inside, and then out of
        # whatever that put it into, and so on.  Marks overlap -- a chevron
        # is a row of them along its own legs -- so a point shoved clear of
        # each in turn ends up inside the one before; the deepest first is
        # what actually leaves the whole huddle.
        for shove in 1 .. SHOVES:
          var
            deepest = -1
            depth = 0.0
          for k, mark in asked:
            let into = mark.clear - dist(band[i], mark.centre)
            if into > depth:
              depth = into
              deepest = k
          if deepest < 0:
            break
          let mark = asked[deepest]
          # Out to the edge, the way it already lay; a point exactly on a
          # mark's centre has no way of its own, so it takes the band's.
          var away = (x: band[i].x - mark.centre.x,
                      y: band[i].y - mark.centre.y)
          if hypot(away.x, away.y) < 1e-9:
            let run = (x: band[i + 1].x - band[i - 1].x,
                       y: band[i + 1].y - band[i - 1].y)
            away = (x: -run.y, y: run.x)
          let length = hypot(away.x, away.y)
          band[i] = (mark.centre.x + away.x / length * mark.clear,
                     mark.centre.y + away.y / length * mark.clear)
    band

  func sagged(asked: seq[Mark]; length: float): seq[Mark] =
    ## The same marks, each grown by how deep the drawn chord across it cuts.
    let step = length / float(ROUTE_N - 1)
    for mark in asked:
      result.add (mark.centre, mark.clear + step * step / (8 * mark.clear))

  # Widened until the line as drawn, and not merely the band behind it,
  # really does clear every mark.
  var
    asked = marks
    length = span
  for pass_no in 0 .. CLEAR_PASSES:
    let grown = sagged(asked, length)
    result = asDrawn(
      if side == 0: drawnOver(grown) else: bowedPast(grown, side))
    length = polylineLen(result)
    var lost = 0.0
    for i, mark in marks:
      let short = mark.clear - nearestOn(result, mark.centre)
      if short > 0:
        asked[i].clear += short
        lost = max(lost, short)
    if lost < CLEAR_ENOUGH:
      break


const SIDES* = [0.0, 1.0, -1.0]
  ## Where a settled reach may be let go from, shortest first (rule 23).


const
  BOX_SWELL* = BODY_R + BOX_ROOM / 2
    ## How far across a wound reach swings to make its half of the box.
    ##   The two reaches of a pair run a body's width apart, so each has to
    ##     cross half of that -- `BODY_R` -- before they meet at all, and
    ##     half the room the box opens beyond it.
  BOX_LEAVE* = 0.12  ## How far along a reach runs its own side before
                     ## swinging over.
  BOX_ACROSS* = 0.5  ## And where it is fully across, which is its middle.
    ## A reach that started crossing at its hand would cross its partner
    ##   over the body it left, where the chevron is, and no swing wide
    ##   enough to make a box could clear it.  Holding its own side clear of
    ##   the body first puts the crossing where the arms really cross: just
    ##   in front of the dancer.
    ## Fully across exactly at the middle, so the two reaches meet their
    ##   widest at one point and what they enclose comes to a point at each
    ##   end: a diamond, which is what the arms make, rather than a
    ##   four-square box (rule 27).


func edged(t, lo, hi: float): float =
  ## Ramp smoothly from nothing at `lo` to all of it at `hi`.
  ##   Smooth at both ends, so a reach shaped by it has no corner where the
  ##     swinging starts or stops (rule 24).
  if t <= lo:
    return 0.0
  if t >= hi:
    return 1.0
  let u = (t - lo) / (hi - lo)
  u * u * (3 - 2 * u)


func boxed*(a, b: Point; across: Point; swell: float;
    marks: seq[Mark] = @[]): seq[Point] =
  ## Route one reach of a wound pair: swung out across the pair's axis and
  ## brought back, so the two of them cross twice and enclose a box
  ## (rule 27).
  ##   A parallel pair does not cross at all.  Wound a whole turn it crosses
  ##     once by each dancer, and what lies between those two crossings is
  ##     the box the rule names -- so each reach swings the whole way over
  ##     to its partner's side and back, and the pair makes the box between
  ##     them.
  ##   `across` is the way over, a unit vector square to the pair's axis;
  ##     `swell` is how far, and at zero this is the straight reach, which
  ##     is what lets a turn grow a box rather than jump to one.
  ##   Grown until it clears the marks it does not join (rule 22), exactly
  ##     as a settled reach is.
  if abs(swell) < 1e-9:
    return straightReach(a, b)

  func curveWith(reach: float): seq[Point] =
    for step in 0 .. BAND_STEPS:
      let
        t = float(step) / float(BAND_STEPS)
        off = reach * edged(t, BOX_LEAVE, BOX_ACROSS) *
                      edged(1 - t, BOX_LEAVE, BOX_ACROSS)
      result.add (a.x + (b.x - a.x) * t + across.x * off,
                  a.y + (b.y - a.y) * t + across.y * off)

  func drawn(pts: seq[Point]): seq[Point] =
    let reach = min(R + CAP, dist(a, b) / 3)
    var cut = trimEnd(pts, a, reach)
    cut = reversed(trimEnd(reversed(cut), b, reach))
    resample(cut, ROUTE_N)

  for try_no in 0 .. BOW_TRIES:
    let thrown = drawn(curveWith(swell * (1 + BOW_MORE * float(try_no))))
    if marks.allIt(nearestOn(thrown, it.centre) >= it.clear):
      return thrown
    result = thrown


func clearedReach*(a, b: Point; marks: seq[Mark]): seq[Point] =
  ## Route a settled reach the plainest way past the marks it does not join
  ## (rules 22 and 23).
  ##   A band let go from the straight line finds the *shortest* way past
  ##     the marks -- which can be a weave, one mark passed on the left and
  ##     the next on the right, and a reader has to follow every one of
  ##     those turns.  Length is not the only thing a picture costs.
  ##   So the band is also let go from a bow right over one side, and from
  ##     one right over the other, and the three are judged on **length and
  ##     turns together** (`readingCost`): a turn has to save more than
  ##     `BEND_COST` of line to be worth making a reader follow it.  In most
  ##     of these figures one bend does the whole job for a few units more.
  ##   A reach that already turns once or not at all, and turns smoothly, is
  ##     as plain as a line gets, so nothing else is tried for it.  A break
  ##     is not plain however few of them there are (rule 24), so a reach
  ##     with one in is weighed against the curves all the same.
  result = letGo(a, b, marks, SIDES[0])
  if bendsIn(result) <= 1 and sharpestIn(result) < SHARP_MAX:
    return
  var least = readingCost(result)
  for side in SIDES[1 .. ^1]:
    let tried = letGo(a, b, marks, side)
    if readingCost(tried) < least:
      least = readingCost(tried)
      result = tried


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
