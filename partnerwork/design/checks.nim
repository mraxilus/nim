## Assert the claims the eye cannot check, instead of trusting them.
##
##   Everything the pages argue is here as a test: the hands land where the
##     rules put them, an orbit collapses onto the matching axis turn mark
##     for mark, every cycle closes, no reach enters a body, a bare border
##     carries no arm ink, and the sign's geometry is even to the tenth of a
##     unit.
##   `checkRules` is the ledger made executable: one block per rule, each
##     opening with the rule in the words it was given, each printing one
##     line on every build.  A rule that is only implemented and not asserted
##     is a rule that quietly stops being true, which has happened here more
##     than once.
##     Cost of a spoken ledger: nine lines of build noise on every run.
##       Accepted -- the noise is the receipt.

{.experimental: "strictFuncs".}

import std/[algorithm, math, options, sequtils, sets, strformat, strutils,
            tables]

import ./[body, figure, geometry, parts, pose, route, rules, sign, style]


func fmt(x: float; places: int): string =
  ## Write a float the way the report lines expect it.
  formatFloat(x, ffDecimal, places).strip(leading = false, chars = {'.'})


proc checkFrame*() =
  ## Check the frame picture's claims, and say what was measured.
  let want = [
    (Dancer.Lead, Arm.L, (-20.0, 28.0)), (Dancer.Lead, Arm.R, (20.0, 28.0)),
    (Dancer.Follow, Arm.L, (20.0, -28.0)),
    (Dancer.Follow, Arm.R, (-20.0, -28.0)),
  ]
  let h = handsOf(rest())
  for (who, arm, at) in want:
    let got = h[who][arm]
    doAssert abs(got.x - at[0]) < 0.01 and abs(got.y - at[1]) < 0.01,
      &"A hand at rest sits off its column; got `{got}` for {who} {arm}."

  # The collapse: an orbit lands where an axis turn lands.  A follow who
  # walks a quarter round the lead keeping their face to them arrives at the
  # state the lead reaches by turning a quarter on the spot.
  let
    walked = relative(canonicalise(
      orbit(rest(), Dancer.Follow, 90, locked = true)))
    turned = relative(spinAbout(rest(), Dancer.Lead, -90))
  doAssert walked == turned,
    &"The orbit misses the axis turn; got `{walked}` against `{turned}`."

  # Both going round each other changes nothing about the picture.
  doAssert relative(canonicalise(couple(rest(), 73))) == relative(rest()),
    "A couple rotation moved the picture."

  # And a whole cycle comes back to exactly where it started.
  for m in MOVES:
    let poses = cycle(m.apply)
    doAssert relative(poses[^1]) == relative(rest()),
      &"A cycle does not close; got `{relative(poses[^1])}` for {m.name}."

  # The boundary is a plain circle, and its two stretches tile it once: what
  # is drawn plus the two hand gaps covers the rim exactly, whatever the
  # winding, and every stretch ends a hand-gap short of the hand it meets.
  for d in countup(0, 359, 7):
    doAssert abs(outlineR(float(d)) - BODY_R) < 1e-9,
      &"The boundary is not a circle; got `{outlineR(float(d))}` at {d}."
  for (wl, wr) in [(0.0, 0.0), (45.0, 0.0), (0.0, 90.0)]:
    let
      right = ARM_REST + wr
      left = ARM_REST + wl
      edges = [right + HAND_GAP, 360 - left - HAND_GAP,
               360 - left + HAND_GAP, 360 + right - HAND_GAP]
    for i in 0 ..< edges.high:
      doAssert edges[i + 1] >= edges[i],
        &"The rim's stretches overlap; got `{edges}` at winding {wl}, {wr}."
    let drawn = (edges[1] - edges[0]) + (edges[3] - edges[2])
    doAssert abs(drawn + 4 * HAND_GAP - 360) < 1e-9,
      &"The rim does not tile; got `{drawn}` drawn at winding {wl}, {wr}."
  # Extreme winding squeezes the back away entirely; the border skips the
  # reversed stretch rather than drawing it backwards.
  var squeezed_wind: Winds
  squeezed_wind[Dancer.Lead] = [135.0, 0.0]
  let squeezed = border(rest(squeezed_wind), Dancer.Lead)
  doAssert squeezed.count("<path") == 1,
    &"Extreme winding should squeeze one stretch away; got `{squeezed.count(\"<path\")}`."

  # The centred chevron stays well inside its own rim.
  doAssert CHEV_OUT + RIM_W < BODY_R,
    &"The chevron reaches its rim; got `{CHEV_OUT + RIM_W}`."

  # The rim is quiet, always: no arm colour fills up around a body, because
  # how far the hand has been carried is said by the connection wrapping it.
  for wind in [default(Winds), squeezed_wind]:
    let rimmed = border(rest(wind), Dancer.Lead)
    doAssert "var(--left" notin rimmed and "var(--right" notin rimmed,
      "The rim took an arm's colour."

  # A reach is two shades of one hue meeting at its middle: the lead's end
  # deep, the follow's plain, and the two halves the same length.
  let
    turned_pose = canonicalise(spinAbout(rest(), Dancer.Follow, 90))
    turned_hands = handsOf(turned_pose)
    ends: route.Ends = (
      turned_hands[Dancer.Lead][Arm.L], turned_hands[Dancer.Follow][Arm.L],
      (turned_pose.place[Dancer.Lead], turned_pose.facing[Dancer.Lead]),
      (turned_pose.place[Dancer.Follow], turned_pose.facing[Dancer.Follow]))
    pts = routed(ends).get.pts
    (near, far) = splitAt(@[pts], pts[pts.len div 2])
    lengths = (polylineLen(near[0]), polylineLen(far[0]))
  doAssert abs(lengths[0] - lengths[1]) < 0.05,
    &"The two shades are uneven; got `{lengths}`."
  doAssert near[0][0] == pts[0] and far[0][^1] == pts[^1],
    "The halves are out of order."
  doAssert near[0][^1] == far[0][0], "The halves do not meet."

  # A body turns the way it turned: the facings an animation is handed never
  # step half a turn, so nothing interpolating them can go the long way.
  doAssert continuous(@[170.0, 175.0, -175.0]) == @[170.0, 175.0, 185.0],
    "Continuity breaks at the wrap."
  var biggest = 0.0
  for m in MOVES:
    let poses = cycle(m.apply)
    for who in Dancer:
      let steps = facings(poses, who)
      for i in 0 ..< steps.high:
        biggest = max(biggest, abs(steps[i + 1] - steps[i]))
  doAssert biggest < 90, &"A facing steps too far; got `{biggest}`."

  # And no reach ever crosses into a body: every hold, every quarter-turn
  # orientation, sampled along the route it would actually be drawn with.
  var
    worst = 99.0
    ends_off = 0.0
  const held_sets: array[3, Holds] = [
    [some Arm.L, none Arm], [some Arm.R, none Arm], [some Arm.L, some Arm.R]]
  for holds in held_sets:
    for lead_turn in [0.0, 90.0, 180.0]:
      for follow_turn in [0.0, 90.0, 180.0]:
        let
          pose = canonicalise(spinAbout(
            spinAbout(rest(), Dancer.Lead, lead_turn),
            Dancer.Follow, follow_turn))
          pts_all = handsOf(pose)
        for arm in Arm:
          if holds[arm].isNone:
            continue
          let
            a = pts_all[Dancer.Lead][arm]
            b = pts_all[Dancer.Follow][holds[arm].get]
            span: route.Ends = (a, b,
              (pose.place[Dancer.Lead], pose.facing[Dancer.Lead]),
              (pose.place[Dancer.Follow], pose.facing[Dancer.Follow]))
            run = routed(span).get.pts
          doAssert run.len == ROUTE_N,
            &"A route has the wrong shape; got `{run.len}` points."
          if dist(a, b) > 2 * (R + CAP) + 3:
            ends_off = max(ends_off, max(
              abs(dist(run[0], a) - (R + CAP)),
              abs(dist(run[^1], b) - (R + CAP))))
          for q in run:
            for who in Dancer:
              let
                c = pose.place[who]
                f = pose.facing[who]
                depth = dist(q, c) - outlineR(
                  bearing(q.x - c.x, q.y - c.y) - f)
              worst = min(worst, depth)
  doAssert worst > -0.4, &"A reach enters a body; got `{worst}`."
  doAssert ends_off < 0.3, &"A reach misses its hand; got `{ends_off}`."
  echo &"  frame: hands at rest exact; orbit collapses onto axis at " &
    &"({walked.axis}, {walked.facing}); every cycle closes; every rim is " &
    &"quiet and breaks at its hands; a facing never steps more than " &
    &"{fmt(biggest, 1)} degrees a frame; every reach stays on or outside " &
    &"the bodies (margin {fmt(worst, 2)}) and starts {R + CAP} from its " &
    &"hand (off by {fmt(ends_off, 2)})"


proc checkRules*() =
  ## Verify every rule as it was given, and say so, one line per rule.
  ##   The numbering matches the ledger in the README and `rules.RULES`; the
  ##     wording of each heading is the wording the rule arrived in.
  var told: seq[string]

  # RULE 1.  "the hands should only pass through the circle when the hand
  # positions are above" -- and a moving picture is not the frames it is
  # sampled at, it is the blend between them, point by point.  Two
  # neighbouring frames that disagree about which side of a body the line
  # goes round are drawn, in between, as a line sweeping straight through
  # that body.  So this checks what is *drawn*: every consecutive pair, part
  # way between, with the bodies interpolated too because they move as well.
  # The version of this that looked only at the sampled frames let a line
  # through the middle of a dancer, twice.
  var swept = 99.0
  for m in MOVES:
    let
      poses = cycle(m.apply).mapIt(
        settled(it, HOLD, default(Levels), default(Ways)))
      hands = poses.mapIt(handsOf(it))
    var frames: seq[route.Ends]
    for i, hnd in hands:
      frames.add (hnd[Dancer.Lead][Arm.L], hnd[Dancer.Follow][Arm.L],
                  (poses[i].place[Dancer.Lead], poses[i].facing[Dancer.Lead]),
                  (poses[i].place[Dancer.Follow],
                   poses[i].facing[Dancer.Follow]))
    let
      way = oneWayRound(frames)
      runs = frames.mapIt(routed(it, some way).get.pts)
    for k in 0 ..< runs.high:
      let
        qa = poses[k]
        qb = poses[k + 1]
      for part in [0.25, 0.5, 0.75]:
        var drawn: seq[Point]
        for i, a in runs[k]:
          let b = runs[k + 1][i]
          drawn.add (a.x + (b.x - a.x) * part, a.y + (b.y - a.y) * part)
        for who in Dancer:
          let
            c: Point = (
              qa.place[who].x + (qb.place[who].x - qa.place[who].x) * part,
              qa.place[who].y + (qb.place[who].y - qa.place[who].y) * part)
            f = qa.facing[who] + part * (qb.facing[who] - qa.facing[who])
          for i in 0 ..< drawn.high:
            for j in 0 .. 8:
              let
                t = j / 8
                pt: Point = (
                  drawn[i].x + (drawn[i + 1].x - drawn[i].x) * t,
                  drawn[i].y + (drawn[i + 1].y - drawn[i].y) * t)
                deep = dist(pt, c) - outlineR(
                  bearing(pt.x - c.x, pt.y - c.y) - f)
              swept = min(swept, deep)
  doAssert swept > -0.3,
    &"A blended frame sweeps a line through a body; got `{fmt(swept, 2)}`."
  told.add &"only `above` crosses a body, at every instant drawn " &
    &"(worst {fmt(swept, 2)})"

  # RULE 2.  "the hands can only move from their positions at the side of
  # the body only if a level is specified", and a level alone is not enough:
  # the way has to be said too, or there is no knowing which side it went to.
  for (level, way, moves) in [
      (none Level, none Way, false), (some Level.Low, none Way, false),
      (none Level, some Way.Wrap, false),
      (some Level.Low, some Way.Lock, true)]:
    let put = handsOf(settled(rest(), HOLD, said(level),
                              said(way)))[Dancer.Lead][Arm.L]
    doAssert (put != handsOf(rest())[Dancer.Lead][Arm.L]) == moves,
      &"A hand moved on half a say; got level `{level}`, way `{way}`."
  told.add "a hand moves only when a level *and* a way are named"

  # RULE 3.  "the slots are relative to the front facing side of the
  # lead/follow, not from the diagram itself."  Six spots: default, and one
  # a little towards the front and one a little towards the back, measured
  # off the dancer's own facing and never off the page.
  var places: seq[float]
  for arm in Arm:
    for slot in Slot:
      places.add slotBearing(arm, slot)
  var apart = 360.0
  for i, a in places:
    for b in places[i + 1 .. ^1]:
      apart = min(apart, abs(wrap180(a - b)))
  doAssert places.len == 6, &"Six spots expected; got `{places.len}`."
  doAssert apart > 2 * radToDeg(arcsin(R / BODY_R)),
    &"Two spots touch; got `{apart}` degrees apart."
  # And they turn with the dancer: settle a hold, turn the follow, and every
  # hand is still exactly where its spot says relative to its own facing.
  for turn in [0.0, 90.0, 180.0, 270.0]:
    let pose = settled(canonicalise(spinAbout(rest(), Dancer.Follow, turn)),
                       HOLD, said(some Level.Low), said(some Way.Lock))
    for who in Dancer:
      let
        got = handBearing(0.0, Arm.L, pose.wind[who][Arm.L])
        landed = slotOf(Arm.L, some Level.Low, some Way.Lock)
      doAssert abs(wrap180(got - slotBearing(landed.arm, landed.slot))) <
        1e-9, &"A spot is page-relative; got `{got}` at turn {turn} for {who}."
  told.add &"six spots, {fmt(apart, 0)} degrees apart at the closest, " &
    "off each dancer's own facing"

  # RULES 4, 5 and 6.  "high and low wraps go around to the front of the
  # other hand, low lock goes around the back to the back of the other hand"
  # and "in high lock the line goes around the back of the modified body",
  # to the back of the current hand.  The table here is the rules
  # transcribed, held against the settle table the drawing derives from.
  const WHERE = [
    (level: Level.High, way: Way.Wrap, whose: Whose.Other, spot: Slot.Front,
     sends: Sends.FrontWay),
    (level: Level.Low, way: Way.Wrap, whose: Whose.Other, spot: Slot.Front,
     sends: Sends.FrontWay),
    (level: Level.Low, way: Way.Lock, whose: Whose.Other, spot: Slot.Back,
     sends: Sends.BackWay),
    (level: Level.High, way: Way.Lock, whose: Whose.Own, spot: Slot.Back,
     sends: Sends.BackWay),
  ]
  for w in WHERE:
    for arm in Arm:
      let lands = if w.whose == Whose.Own: arm else: other(arm)
      doAssert slotOf(arm, some w.level, some w.way) == (lands, w.spot),
        &"A settle lands wrong; got `{slotOf(arm, some w.level, some w.way)}`."
    doAssert roundOf(some w.level, some w.way) == some w.sends,
      &"A hold sends its line the wrong way; got " &
        &"`{roundOf(some w.level, some w.way)}` for {w.level} {w.way}."
    # And the drawn route really does set off that way, at both ends.
    let
      turn = if w.way == Way.Wrap: 180.0 else: 0.0
      pose = settled(canonicalise(spinAbout(rest(), Dancer.Follow, turn)),
                     HOLD, said(some w.level), said(some w.way))
      p = handsOf(pose)
      ends: route.Ends = (p[Dancer.Lead][Arm.L], p[Dancer.Follow][Arm.L],
        (pose.place[Dancer.Lead], pose.facing[Dancer.Lead]),
        (pose.place[Dancer.Follow], pose.facing[Dancer.Follow]))
      asked = wayFor(ends, some w.level, some w.way)
      towards = if w.sends == Sends.FrontWay: 1.0 else: -1.0
    doAssert asked == some (towards * frontOf(ends.a, ends.A),
                            towards * frontOf(ends.b, ends.B)),
      &"The asked way is not the rule's way for {w.level} {w.way}."
    doAssert routed(ends, asked).get.way == asked.get,
      &"The drawn route disobeys its way for {w.level} {w.way}."
  told.add "both wraps land in front and go round the front; both locks " &
    "land behind and go round the back"

  # RULE 7.  "lock/wrap positions can only be used when the connecting line
  # goes around no less than just under 1/2 of the circumference.  it
  # doesn't make sense to have a wrap or a lock without the line actually
  # going around the body."
  var arc_seen: HashSet[float]
  for w in WHERE:
    for turn in [0.0, 90.0, 180.0, 270.0]:
      let
        pose = canonicalise(spinAbout(rest(), Dancer.Follow, turn))
        p = handsOf(settled(pose, HOLD, said(some w.level),
                            said(some w.way)))
        ends: route.Ends = (p[Dancer.Lead][Arm.L], p[Dancer.Follow][Arm.L],
          (pose.place[Dancer.Lead], pose.facing[Dancer.Lead]),
          (pose.place[Dancer.Follow], pose.facing[Dancer.Follow]))
        asked = wayFor(ends, some w.level, some w.way)
        arcs = if asked.isSome: wrapArc(ends, asked.get)
               else: none(tuple[a, b: float])
        ok = danceable(pose, HOLD, said(some w.level), said(some w.way))
      doAssert ok == (arcs.isSome and
                      max(arcs.get.a, arcs.get.b) >= float(WRAP_MIN)),
        &"Danceable and the measured arc disagree for {w.level} {w.way}."
      if arcs.isSome:
        arc_seen.incl max(arcs.get.a, arcs.get.b)
  # The arcs are quantised, and the threshold sits in the gap below a half.
  for v in arc_seen:
    doAssert v <= 141 or v >= 180,
      &"An arc falls between the quanta; got `{v}`."
  doAssert 141 < WRAP_MIN and WRAP_MIN < 180,
    &"The threshold left the gap; got `{WRAP_MIN}`."
  let quanta = arc_seen.toSeq.mapIt(int(it)).sorted
  told.add &"a lock or wrap needs {WRAP_MIN} degrees of wrap; the arcs " &
    &"this geometry makes are [{quanta.mapIt($it).join(\", \")}]"

  # RULE 8.  "above has no locks/wraps and can only transition to upper wrap
  # or back to default (physical restrictions)."  `upper wrap` is read as
  # the high wrap; that reading is the implementer's and not the rule's.
  for way in [some Way.Lock, some Way.Wrap, none(Way)]:
    doAssert slotOf(Arm.L, some Level.Above, way) == (Arm.L, Slot.Default),
      &"Above settled away from home; got way `{way}`."
    doAssert roundOf(some Level.Above, way).isNone,
      &"Above sent its line round; got way `{way}`."
  doAssert FROM_ABOVE[0] == (some Level.High, some Way.Wrap) and
    FROM_ABOVE[1] == (none Level, none Way),
    &"The transitions out of above drifted; got `{FROM_ABOVE}`."
  told.add "`above` takes no lock or wrap, and leads only to high wrap " &
    "or default"

  # RULE 9.  The connecting line's two halves are its two hands' own
  # colours.
  let crossed = frame("f", [some Arm.R, none Arm], said(some Level.Low))
  doAssert "var(--left-deep)" in crossed and "var(--right)" in crossed,
    "A crossed connection lost one of its two hands' colours."
  told.add "a connection is drawn in its two hands' own colours"

  for line in told:
    echo &"  rule: {line}"


proc checkSingleTurns*() =
  ## Verify the single-hand turns page's rules as given, one line each.
  var told: seq[string]
  let built = singleTurnParts()

  # RULE 17.  "all turns should be in the \"above\" position, not the high.
  # high/low causes wraps/locks, so we're currently making the assumption
  # to avoid those."  Every held hand carries the above hatch, and above is
  # the level that cannot lock or wrap however the couple is turned.
  var hatched = 0
  for key, figure in built:
    if not (key.startsWith("st_") or key.startsWith("tr_")):
      continue
    doAssert "r=\"2.7\"" notin figure,
      &"A high dot appears where above was asked for; got `{key}`."
    if "url(#h" in figure:
      inc hatched
  doAssert hatched > 0, "No above hatch drawn anywhere; the level is unsaid."
  for way in [none(Way), some Way.Lock, some Way.Wrap]:
    doAssert roundOf(some Level.Above, way).isNone,
      &"Above sent its line round; got way `{way}`."
    doAssert slotOf(Arm.L, some Level.Above, way) == (Arm.L, Slot.Default),
      &"Above settled off its own side; got way `{way}`."
  told.add &"every turn is held above, hatched on {hatched} figures: the " &
    "one level that cannot lock or wrap whichever way the couple turns"

  # RULE 11.  "no additional frame positions, just the addition of
  # rotations that let us travel between them."
  const APP_SINGLES: array[4, Holds] = [
    [some Arm.L, none Arm], [some Arm.R, none Arm],
    [none Arm, some Arm.L], [none Arm, some Arm.R],
  ]
  for single in SINGLES:
    doAssert single.holds in APP_SINGLES,
      &"A hold outside the app's four appears; got `{single.name}`."
  told.add &"every position is one of the app's {SINGLES.len} single-hand " &
    "frames, turned; nothing new is drawn"

  # RULE 19.  "you should also include orbit turns not just the axis
  # turns."  Four ways: each dancer's own axis turn and each dancer's orbit
  # of the other -- the orbits ringed, since the ring says who is standing
  # still.  Which ways share a round of positions is measured here rather
  # than taken from the table, and the table is held to the measurement.
  var axis_ways, orbit_ways = 0
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    if w.about == About.Axis: inc axis_ways else: inc orbit_ways
    let ringed = built[&"tr_{w.tag}_0_0_1"].contains("stroke-dasharray")
    doAssert ringed == (w.about == About.Orbit),
      &"An orbit's ring is missing or an axis turn has one; got {way}."
  doAssert axis_ways == 2 and orbit_ways == 2,
    &"Four ways expected; got `{axis_ways}` axis and `{orbit_ways}` orbit."

  func roundOfWay(way: TurnWay): HashSet[tuple[axis, facing: float]] =
    for quarter in 0 ..< QUARTERS_ROUND:
      result.incl placeOf(quarterPose(way, quarter))

  var rounds: seq[HashSet[tuple[axis, facing: float]]]
  for way in TurnWay:
    let walked = roundOfWay(way)
    # The table's claim about this way holds: it shares its round with
    # every way of its family, and with no other.
    for mate in TurnWay:
      let shares = roundOfWay(mate) == walked
      doAssert shares == (FAMILY_OF[mate] == FAMILY_OF[way]),
        &"A way left its family; got {way} against {mate}."
    if walked notin rounds:
      rounds.add walked
  doAssert rounds.len == 3,
    &"Three rounds expected of four ways; got `{rounds.len}`."
  told.add &"{axis_ways} axis turns and {orbit_ways} orbits, the orbits " &
    &"ringed; the four ways walk {rounds.len} rounds, the two orbits " &
    "sharing one that neither axis turn reaches"

  # RULE 18.  "the leads' transitions should still be in the 2 stage form,
  # stage 1 is the lead turns with the original perspective stage 2 is
  # reorienting the perspective."  Measured on the walk: stage one leaves
  # the picture off canonical -- leaning, or off centre, or both -- and
  # stage two brings it back.  A turn that leaves the framing exactly as
  # it found it has no second stage to draw, and framed on the lead
  # (rule 25) that is every turn but the lead's own.
  for way in TurnWay:
    let
      w = WAYS_OF_TURNING[way]
      walk = turnWalk(quarterPose(way, 0), w.who, w.about, QUARTER,
                      on = Anchor.Lead)
    var
      leaned = 0.0
      strayed = 0.0
    for put in walk:
      leaned = max(leaned, abs(wrap180(put.facing[Dancer.Lead])))
      for dancer in Dancer:
        let settled_place = canonicalise(put, on = Anchor.Lead).place[dancer]
        strayed = max(strayed, dist(put.place[dancer], settled_place))
    let re_framed = w.who == Dancer.Lead
    if re_framed:
      doAssert leaned > 45 or strayed > 1,
        &"A turn never left the canonical framing; got {way}."
      doAssert abs(wrap180(walk[^1].facing[Dancer.Lead])) < 1e-9,
        &"A turn ended off upright; got {way}."
      doAssert dist(walk[^1].place[Dancer.Lead],
                    canonicalise(walk[^1], on = Anchor.Lead)
                      .place[Dancer.Lead]) < 1e-9,
        &"A turn ended off centre; got {way}."
    else:
      doAssert leaned < 1e-9 and strayed < 1e-9,
        &"A turn moved the framing with nothing to re-frame; got {way}."
  told.add "a turn that moves the framing is danced in two stages -- the " &
    "room holds still while it happens, then the picture is brought back " &
    "to the lead facing up and back on their own spot; framed on the lead, " &
    "only a lead's own move has anything to bring back"

  # RULE 16 and RULE 15.  Four orientations per connection, the round
  # closing rather than refusing; every one of them drawn and every edge
  # between them animated.
  var statics, moving = 0
  for key in built.keys:
    if key.startsWith("st_"): inc statics
    if key.startsWith("tr_") and not key.endsWith("_still"): inc moving
  let want = (TurnWay.high.int + 1) * SINGLES.len * QUARTERS_ROUND
  doAssert statics == want,
    &"A position went undrawn; got `{statics}` of `{want}`."
  doAssert moving == want,
    &"An edge went unanimated; got `{moving}` of `{want}`."
  for way in TurnWay:
    doAssert placeOf(quarterPose(way, QUARTERS_ROUND)) ==
      placeOf(quarterPose(way, 0)),
      &"Four quarters do not close the round; got {way}."
  told.add &"a single hand above turns for ever: {QUARTERS_ROUND} " &
    &"orientations a way, the round closing rather than refusing, all " &
    &"{statics} positions drawn and all {moving} transitions animated"

  # RULE 20.  "make sure orbit turns keep their bearing, youre currently
  # combining orbit and axis turns to keep the partner facing the other."
  # Measured through every orbit walk: the walker's own facing never moves,
  # and the pair's axis does -- which is what tells an orbit from the
  # compound of an orbit and an axis turn.
  var swung = 0.0
  for way in TurnWay:
    let
      w = WAYS_OF_TURNING[way]
      walk = turnWalk(quarterPose(way, 0), w.who, w.about, QUARTER,
                      on = Anchor.Lead)
    var carried = 0.0
    for put in walk:
      carried = max(carried,
        abs(wrap180(put.facing[w.who] - walk[0].facing[w.who])))
    if w.about == About.Orbit:
      doAssert carried < 1e-9,
        &"An orbit turned its walker; got `{fmt(carried, 1)}` for {way}."
      swung = max(swung, abs(wrap180(
        placeOf(quarterPose(way, 1)).axis - placeOf(quarterPose(way, 0)).axis)))
    else:
      doAssert carried > 45,
        &"An axis turn never turned its dancer; got {way}."
  doAssert abs(swung - QUARTER) < 1e-9,
    &"An orbit swung the axis by the wrong amount; got `{fmt(swung, 1)}`."
  told.add &"an orbit keeps its bearing: the walker's facing never moves " &
    &"and the pair's axis swings the whole {fmt(swung, 0)} degrees, so " &
    "an orbit is never an axis turn in disguise"

  # RULE 21.  "also, the animations should also have the above level as
  # that's the only valid one for the current scope."  A moving hand says
  # its level as a still one does: every held hand of every transition
  # carries the above hatch.
  var moving_hatched = 0
  for key, figure in built:
    if not key.startsWith("tr_") or key.endsWith("_still"):
      continue
    doAssert "url(#h" in figure,
      &"A moving hand lost its level; got no hatch in `{key}`."
    inc moving_hatched
  doAssert moving_hatched == want,
    &"A transition went unhatched; got `{moving_hatched}` of `{want}`."
  told.add &"all {moving_hatched} animations carry the above hatch on " &
    "their held hands, as the still figures beside them do"

  # RULE 14.  Nothing wraps a body: measured as how far a reach bows off
  # the chord between its own two hands, standing and turning alike.
  var bowed = 0.0
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    for single in SINGLES:
      for arm in Arm:
        if single.holds[arm].isNone:
          continue
        let walk = turnWalk(quarterPose(way, 0), w.who, w.about, QUARTER,
                            on = Anchor.Lead)
        var runs: seq[seq[Point]]
        for put in walk:
          let p = handsOf(put)
          runs.add straightReach(p[Dancer.Lead][arm],
                                 p[Dancer.Follow][single.holds[arm].get])
          let
            head = runs[^1][0]
            tail = runs[^1][^1]
            reach = dist(head, tail)
          for q in runs[^1]:
            bowed = max(bowed, abs((tail.x - head.x) * (head.y - q.y) -
                                   (head.x - q.x) * (tail.y - head.y)) / reach)
        for k in 0 ..< runs.high:
          for part in [0.25, 0.5, 0.75]:
            var drawn: seq[Point]
            for i, a in runs[k]:
              let b = runs[k + 1][i]
              drawn.add (a.x + (b.x - a.x) * part, a.y + (b.y - a.y) * part)
            let span = dist(drawn[0], drawn[^1])
            for q in drawn:
              bowed = max(bowed,
                abs((drawn[^1].x - drawn[0].x) * (drawn[0].y - q.y) -
                    (drawn[0].x - q.x) * (drawn[^1].y - drawn[0].y)) / span)
  doAssert bowed < 0.5,
    &"A reach bows off its chord, which is a wrap; got `{fmt(bowed, 2)}`."
  told.add &"nothing wraps a body: every turning reach, and every instant " &
    &"drawn between its frames, is straight to within {fmt(bowed, 2)} of " &
    "its own chord"

  # RULE 22.  "an arm shouldn't settle in a hand cell it's not connected to
  # ... it should bend around all hand cells and chevrons as to not imply
  # connection and not obscure direction. it is however fine to animate
  # smoothly past it."  Both halves are measured on the line as drawn: a
  # settled reach keeps daylight from every mark it does not join, and a
  # moving one still runs straight through.
  # RULE 23.  "prefer paths that have fewers bends (ideally 1) as well as
  # length."  Counted on the drawn line: how many turns each settled reach
  # asks a reader to follow, and -- wherever one asks for more than a
  # single turn -- that no other way past the same marks would have asked
  # less, length and turns weighed together.
  # RULE 24.  "prefer smooth long curves instead of sharp breaks."  A curve
  # drawn as straight bits turns a few degrees at each of them; a break
  # turns a lot at one.  So the sharpest single corner on the page is what
  # is measured, over every settled reach.
  var
    turns: array[4, int]
    bought = 0.0
    sharpest = 0.0
  var
    daylight = Inf
    fouled = 0.0
    kept = 0
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    for single in SINGLES:
      for arm in Arm:
        if single.holds[arm].isNone:
          continue
        for quarter in 0 ..< QUARTERS_ROUND:
          let
            put = settled(quarterPose(way, quarter), single.holds,
                          levelsFor(single.holds), default(Ways))
            p = handsOf(put)
            (a, b) = (p[Dancer.Lead][arm], p[Dancer.Follow][single.holds[arm].get])
            marks = clearingMarks(put, a, b)
          let settled_reach = clearedReach(a, b, marks)
          turns[min(bendsIn(settled_reach), turns.high)] += 1
          sharpest = max(sharpest, sharpestIn(settled_reach))
          if bendsIn(settled_reach) > 1:
            # It kept a second turn, so every plainer way past these marks
            # must have cost more line than the turn is worth.
            for side in SIDES:
              let other = letGo(a, b, marks, side)
              doAssert readingCost(settled_reach) <= readingCost(other) + 1e-6,
                &"A plainer reach went untaken; got {way} on {single.name}."
              if bendsIn(other) < bendsIn(settled_reach):
                bought = max(bought,
                             polylineLen(other) - polylineLen(settled_reach))
          for (drawn, moving) in [(settled_reach, false),
                                  (straightReach(a, b), true)]:
            for mark in marks:
              # Measured as plain daylight: what is left between the drawn
              # stroke and the drawn mark once both their widths are taken
              # off, which is what a reader actually sees.
              let gap = nearestOn(drawn, mark.centre) - mark.clear + SEEN_GAP
              if moving:
                fouled = max(fouled, -gap)
              else:
                daylight = min(daylight, gap)
                inc kept
  doAssert daylight > 0,
    &"A settled reach ran through a mark; got `{fmt(daylight, 2)}`."
  # And the exemption is worth having: the straight line these bends replace
  # really does foul something, so this is not a bend drawn for nothing.
  doAssert fouled > SEEN_GAP,
    &"Nothing was ever in a reach's way; got `{fmt(fouled, 2)}`."
  told.add &"a settled reach bends round every mark it does not join: " &
    &"{kept} clearances measured, the tightest leaving {fmt(daylight, 2)} " &
    &"of daylight, where the straight line it replaces buries itself " &
    &"{fmt(fouled, 1)} into a mark; a turning reach stays straight and " &
    "passes smoothly across, as the rule allows"

  doAssert turns[3] == 0,
    &"A reach turned three times or more; got `{turns[3]}` of them."
  told.add &"a settled reach is the plainest way past those marks, not " &
    &"merely the shortest: {turns[0]} run straight, {turns[1]} turn once " &
    &"and {turns[2]} twice, and no plainer way past the same marks was " &
    &"passed over -- a second turn is kept only where going round in one " &
    &"would have cost more than {fmt(BEND_COST, 0)} of line" &
    (if bought > 0: &", which here reaches {fmt(bought, 1)}" else: "")

  doAssert sharpest < SHARP_MAX,
    &"A reach turns at a point rather than over a run; got " &
      &"`{fmt(sharpest, 1)}` degrees at one corner."
  told.add &"and it bends rather than breaks: the sharpest corner anywhere " &
    &"on the page turns {fmt(sharpest, 1)} degrees, so what turns, turns " &
    "over a run of the line and not at a point in it"

  # RULE 25.  "lead position should remain fixed as much as possible ...
  # obviously this can't really be the case when the lead orbits."
  # Measured through every walk: how far the lead's own place travels from
  # first frame to last, and across the four positions of every round.
  var re_entered: seq[string]
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    var moved = 0.0
    for quarter in 0 ..< QUARTERS_ROUND:
      let start = quarterPose(way, quarter)
      doAssert dist(start.place[Dancer.Lead],
                    quarterPose(way, 0).place[Dancer.Lead]) < 1e-9,
        &"The lead stands somewhere else in this position; got {way}."
      for put in turnWalk(start, w.who, w.about, QUARTER, on = Anchor.Lead):
        moved = max(moved, dist(put.place[Dancer.Lead],
                                start.place[Dancer.Lead]))
    # Only the lead's own orbit may move them, and it must: walking round
    # somebody and staying put are not the same act.
    let walks_off = w.who == Dancer.Lead and w.about == About.Orbit
    doAssert (moved > 1) == walks_off,
      &"The lead moved where they should not, or held where they " &
        &"cannot; got `{fmt(moved, 1)}` for {way}."
    if walks_off:
      re_entered.add w.title.toLowerAscii
  let ways = TurnWay.toSeq.len
  told.add &"the lead is the still point: they stand on the same spot in " &
    &"every position of every round, and never move through " &
    &"{ways - re_entered.len} of the {ways} ways of turning -- only " &
    &"""{re_entered.join(" and ")} takes them off it, and there the """ &
    "picture has to bring them back"

  for line in told:
    echo &"  rule: {line}"


proc checkSign*() =
  ## Check the numbers the eye cannot: equal sides, margins, gaps,
  ## clearance.
  const
    LEAN_SIN = sin(arctan(TAN))
    LEAN_COS = cos(arctan(TAN))
  let
    y_foot = 5.0 + OVER
    y_bot = y_foot + HEIGHT
  for rows in 1 .. QUARTERS:
    var
      sides: HashSet[float]
      margins: HashSet[float]
      clear: HashSet[float]
      gaps: seq[float]
      edges: seq[tuple[top, bottom: float]]
    for place in 0 ..< rows:
      let
        top = y_bot - GAP_X - float(place) * (PIP + GAP_X) - PIP +
          (PIP - PIP * LEAN_COS) / 2
        left = 5.0 + (y_bot - top) * TAN
        ax = left + GAP_X
        pts: array[4, Point] = [
          (ax, top), (ax + PIP, top),
          (ax + PIP - PIP * LEAN_SIN, top + PIP * LEAN_COS),
          (ax - PIP * LEAN_SIN, top + PIP * LEAN_COS)]
      for i in 0 .. 3:
        let
          p = pts[i]
          q = pts[(i + 1) mod 4]
        sides.incl round(hypot(q.x - p.x, q.y - p.y), 3)
      let bottom_left = 5.0 + (y_bot - (top + PIP * LEAN_COS)) * TAN
      margins.incl round(pts[0].x - left, 3)
      margins.incl round(pts[3].x - bottom_left, 3)
      margins.incl round(left + SIGN_BODY - (pts[1].x + PIP + GAP_X), 3)
      # A circle has no corners to tuck under the lean, so its clearance is
      # measured square to the edge rather than across the page.
      for col in [0.0, 1.0]:
        let across = GAP_X + col * (PIP + GAP_X) + PIP / 2
        clear.incl round(
          min(across, SIGN_BODY - across) * LEAN_COS - PIP / 2, 3)
      edges.add (y_bot - GAP_X - float(place) * (PIP + GAP_X) - PIP,
                 y_bot - GAP_X - float(place) * (PIP + GAP_X))
    edges.sort
    gaps.add round(edges[0].top - y_foot, 3)             # to the lid
    for i in 0 ..< edges.high:
      gaps.add round(edges[i + 1].top - edges[i].bottom, 3)
    gaps.add round(y_bot - edges[^1].bottom, 3)          # to the foot
    doAssert sides == toHashSet([11.0]), &"Uneven pip sides; got `{sides}`."
    doAssert margins == toHashSet([4.0]),
      &"Uneven margins; got `{margins}`."
    doAssert clear.toSeq.min > 0, &"A circle touches the lean; got `{clear}`."
    doAssert gaps[^1] == GAP_X and gaps[1 .. ^1].toHashSet ==
      toHashSet([GAP_X]), &"Uneven gaps; got `{gaps}`."
    if rows == QUARTERS:
      doAssert gaps[0] == GAP_X, &"The lid gap is off; got `{gaps[0]}`."
    let
      sides_said = sides.toSeq.sorted.mapIt($it).join(", ")
      margins_said = margins.toSeq.sorted.mapIt($it).join(", ")
      gaps_said = gaps.mapIt($it).join(", ")
      clear_said = clear.toSeq.sorted.mapIt($it).join(", ")
    echo &"  {rows}/4: sides [{sides_said}] margins [{margins_said}] " &
      &"gaps [{gaps_said}] circle clearance [{clear_said}]"
