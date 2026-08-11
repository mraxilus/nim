## Build every figure the two pages place, keyed by the name each page uses.
##
##   Split the way the pages are: the frame picture is one exploration and
##     the turn sign another.
##   The inline assertions are part of the build -- a page whose orientations
##     collide or whose collapse figures differ is refused, not published.
##     Cost of asserting in the builder: a broken figure stops the whole
##       build rather than one plate.  Accepted -- a published page with one
##       wrong plate is worse than no page.

{.experimental: "strictFuncs".}

import std/[algorithm, options, sequtils, sets, strformat, strutils, tables]

import ./[body, figure, geometry, pose, route, rules, sign, style]


type Parts* = OrderedTable[string, string]
  ## Every placed figure, in the order it was built.


const ORIENTATIONS* = [
  (name: "face to face", lead_turn: 0.0, follow_turn: 0.0),
  (name: "the follow faces away", lead_turn: 0.0, follow_turn: 180.0),
  (name: "the lead faces away", lead_turn: 180.0, follow_turn: 0.0),
  (name: "back to back", lead_turn: 180.0, follow_turn: 180.0),
] ## The four ways the couple can face, as the pages walk them.

const
  LOW*: Levels = [some Level.Low, some Level.Low]
  SPLIT*: Levels = [some Level.Low, some Level.High]
  HOLD*: Holds = [some Arm.L, none Arm]
    ## The workhorse hold: the lead's Left to the follow's left.

const SETTLINGS* = [
  (level: none Level, way: none Way, follow_turn: 0.0,
   caption: "no way said<br>— it stays at its side"),
  (level: some Level.Low, way: some Way.Lock, follow_turn: 0.0,
   caption: "<em>low</em> lock<br>face to face"),
  (level: some Level.High, way: some Way.Lock, follow_turn: 0.0,
   caption: "<em>high</em> lock<br>face to face"),
  (level: some Level.Low, way: some Way.Wrap, follow_turn: 180.0,
   caption: "<em>low</em> wrap<br>the follow turned away"),
  (level: some Level.High, way: some Way.Wrap, follow_turn: 180.0,
   caption: "<em>high</em> wrap<br>the follow turned away"),
] ## Each settling drawn in an orientation that admits it, because most do
  ## not: a lock or wrap only exists where the line really goes round.

const GRID_STATES* = [
  (level: Level.High, way: Way.Wrap), (level: Level.Low, way: Way.Wrap),
  (level: Level.Low, way: Way.Lock), (level: Level.High, way: Way.Lock),
] ## The grid rule 7 implies: which states exist in which orientation.

const GRID_TURNS* = [0.0, 90.0, 180.0, 270.0]

const CHART_FACING* = 40.0
  ## The chart's body is turned off the vertical, so the spots visibly
  ## follow the chevron and not the page.


func said*(level: Option[Level]; arm = Arm.L): Levels =
  ## Say one arm's level, or nothing at all where nothing was said.
  result[arm] = level

func said*(way: Option[Way]; arm = Arm.L): Ways =
  ## Say one arm's way, or nothing at all where nothing was said.
  result[arm] = way


func replaceFirst*(s, sub, by: string): string =
  ## Replace only the first occurrence, as the figure post-passes need.
  let at = s.find(sub)
  if at < 0: s
  else: s[0 ..< at] & by & s[at + sub.len .. ^1]


func slotChart*(arm = Arm.L): string =
  ## Draw one body with all six spots on it, and this hand's four marked.
  ##   Drawn rather than tabulated because the table is the thing most likely
  ##     to be wrong -- and drawn on a body turned off the vertical, because
  ##     the spots are measured off the dancer's facing rather than off the
  ##     page, and a body facing up hides the difference (rule 3).
  # Its own box rather than the square every other figure uses: the labels
  # are wide and the body is small, so a square would draw it tiny.
  var bits = @["""<svg viewBox="-80 -46 160 92" width="248" height="143">"""]
  var chart = rest()
  chart.place[Dancer.Lead] = (0.0, 0.0)
  chart.facing[Dancer.Lead] = CHART_FACING
  bits.add border(chart, Dancer.Lead)
  bits.add chevron((0.0, 0.0), CHART_FACING)
  var lands: seq[tuple[arm: Arm, slot: Slot]]
  for s in SETTLINGS:
    let landed = slotOf(arm, s.level, s.way)
    if landed notin lands:
      lands.add landed
  for place in Arm:
    for slot in Slot:
      let
        aim = CHART_FACING + slotBearing(place, slot)
        p = polar(0.0, 0.0, BODY_R, aim)
        # In this hand's own ink wherever it sits, because that is the
        # point: a Left hand carried to the right side is still the Left.
        used = (place, slot) in lands
      bits.add hand(p.x, p.y, true, arm, used, none(Level),
                    if used: Free.Fade else: Free.Grey)
      let
        label = polar(0.0, 0.0, BODY_R + R + 13, aim)
        anchor = if label.x < 0: "end" else: "start"
        text = if slot == Slot.Default: "side" else: word(slot)
      bits.add &"""<text x="{n(label.x)}" y="{n(label.y + 3)}"""" &
        &""" text-anchor="{anchor}"""" &
        " style=\"font: 8px ui-sans-serif, system-ui," &
        &""" sans-serif; fill: {FAINT}">{text}</text>"""
  bits.join("") & "</svg>"


func frameParts*(): Parts =
  ## Build every SVG the frame page places.
  result["f_none"] = frame("f", HOLD)
  result["f_low"] = frame("f", HOLD, said(some Level.Low))
  result["f_high"] = frame("f", HOLD, said(some Level.High))
  result["f_above"] = frame("f", HOLD, said(some Level.Above))
  result["f_over"] = frame("f", [some Arm.L, some Arm.R],
                           [some Level.High, some Level.Low],
                           over = some Arm.L)

  # The four orientations, twice: with nothing held, where only the colours
  # and the chevrons can say it, and holding, where the line is there too.
  var seen: HashSet[string]
  for i, o in ORIENTATIONS:
    result[&"or_open_{i}"] = frame("f", default(Holds),
                                   lead_turn = o.lead_turn,
                                   follow_turn = o.follow_turn)
    result[&"or_held_{i}"] = frame("f", HOLD, lead_turn = o.lead_turn,
                                   follow_turn = o.follow_turn)
    result[&"or_tiny_{i}"] = frame("tiny", HOLD, lead_turn = o.lead_turn,
                                   follow_turn = o.follow_turn,
                                   captions = false)
    seen.incl result[&"or_open_{i}"]
  doAssert seen.len == ORIENTATIONS.len,
    &"Orientations collide; got `{seen.len}` distinct of `{ORIENTATIONS.len}`."

  # Free hands: keep the hue, or go grey and lose the orientation with it.
  result["free_fade"] = frame("f", default(Holds), free = Free.Fade)
  result["free_grey"] = frame("f", default(Holds), free = Free.Grey)
  result["free_fade_tiny"] = frame("tiny", default(Holds), free = Free.Fade,
                                   captions = false)
  result["free_grey_tiny"] = frame("tiny", default(Holds), free = Free.Grey,
                                   captions = false)

  # What the pair of colours at the two ends says.
  result["pair_ll"] = frame("f", HOLD)
  result["pair_ll_turned"] = frame("f", HOLD, follow_turn = 180)
  result["pair_lr"] = frame("f", [some Arm.R, none Arm])
  result["pair_lr_turned"] = frame("f", [some Arm.R, none Arm],
                                   follow_turn = 180)

  # The six spots, and the five settlings that reach four of them.
  result["slot_chart"] = slotChart(Arm.L)
  var reached: seq[tuple[arm: Arm, slot: Slot]]
  for k, s in SETTLINGS:
    result[&"settle_{k}"] = frame("f", HOLD, said(s.level),
                                  ways = said(s.way),
                                  follow_turn = s.follow_turn,
                                  captions = false)
    let landed = slotOf(Arm.L, s.level, s.way)
    if landed notin reached:
      reached.add landed
  # A Left hand reaches four of the six; the other two belong to the Right.
  doAssert reached.sorted == @[(Arm.L, Slot.Default), (Arm.L, Slot.Back),
                               (Arm.R, Slot.Front), (Arm.R, Slot.Back)].sorted,
    &"The settlings reach the wrong spots; got `{reached.sorted}`."
  # The two wraps share a spot and are told apart by their fill alone.
  doAssert result["settle_3"] != result["settle_4"],
    "High and low wrap collide; got one drawing for both."

  # The routing each hold decides, on one orientation that admits all three.
  for (name, level, way) in [("route_wrap", Level.Low, Way.Wrap),
                             ("route_low", Level.Low, Way.Lock),
                             ("route_high", Level.High, Way.Lock)]:
    let turn = if way == Way.Wrap: 180.0 else: 0.0
    result[name] = frame("f", HOLD, said(some level), ways = said(some way),
                         follow_turn = turn, captions = false)
  doAssert toHashSet([result["route_wrap"], result["route_low"],
                      result["route_high"]]).len == 3,
    "The three routes are not three distinct drawings."

  # And the grid the wrap rule implies: most states do not exist most of the
  # time, which is worth drawing rather than asserting on its own.
  var drawn = 0
  for s in GRID_STATES:
    for turn in GRID_TURNS:
      let
        key = &"grid_{word(s.level)}_{word(s.way)}_{int(turn)}"
        pose = canonicalise(spinAbout(rest(), Dancer.Follow, turn))
      if danceable(pose, HOLD, said(some s.level), said(some s.way)):
        result[key] = frame("tiny", HOLD, said(some s.level),
                            ways = said(some s.way), follow_turn = turn,
                            captions = false)
        inc drawn
      else:
        result[key] = ""             # an edge that is not drawn
  doAssert drawn > 0 and drawn < GRID_STATES.len * GRID_TURNS.len,
    &"The grid should be partial; got `{drawn}` cells drawn."
  # The arcs this geometry actually makes, so the page quotes the
  # measurement rather than a number somebody typed.
  var arcs_seen: HashSet[int]
  for s in GRID_STATES:
    for lead_turn in [0.0, 90.0, 180.0, 270.0]:
      for turn in GRID_TURNS:
        let
          pose = canonicalise(spinAbout(
            spinAbout(rest(), Dancer.Lead, lead_turn), Dancer.Follow, turn))
          q = settled(pose, HOLD, said(some s.level), said(some s.way))
          h = handsOf(q)
          ends: route.Ends = (h[Dancer.Lead][Arm.L],
                              h[Dancer.Follow][Arm.L],
                              (q.place[Dancer.Lead], q.facing[Dancer.Lead]),
                              (q.place[Dancer.Follow],
                               q.facing[Dancer.Follow]))
          asked = wayFor(ends, some s.level, some s.way)
        if asked.isNone:
          continue
        let arcs = wrapArc(ends, asked.get)
        if arcs.isSome:
          arcs_seen.incl int(max(arcs.get.a, arcs.get.b))
  result["arc_set"] = arcs_seen.toSeq.sorted.mapIt(&"{it}°").join(", ")

  # `above` has no lock and no wrap, so it stays where the arm hangs.
  result["above_plain"] = frame("f", HOLD, said(some Level.Above),
                                captions = false)
  result["above_asked"] = frame("f", HOLD, said(some Level.Above),
                                ways = said(some Way.Wrap), captions = false)
  doAssert result["above_plain"] == result["above_asked"],
    "Above took a wrap; the two drawings differ."

  # An orbit in two stages: the follow travels, then the world comes home.
  for (tag, locked) in [("locked", true), ("drift", false)]:
    var stage_one = [0.0, 0.5, 1.0].mapIt(
      orbit(rest(), Dancer.Follow, 90 * it, locked = locked))
    stage_one[0].ring = none(Ring)     # nothing is travelling yet
    let landed = stage_one[^1]
    var stage_two = [0.5, 1.0].mapIt(canonicalise(landed, it))
    for q in stage_two.mitems:
      q.ring = none(Ring)
    let
      walk = stage_one & stage_two
      half = walk.mapIt(extent(it, captions = false)).max
    for k, q in walk:
      result[&"walk_{tag}_{k}"] = frame("wide", HOLD, pose = some q,
                                        captions = false, half = some half)

  # The collapse: where the orbit lands, and where the axis turn lands.
  var landed = canonicalise(orbit(rest(), Dancer.Follow, 90, locked = true))
  landed.ring = none(Ring)             # the move is over
  result["collapse_orbit"] = frame("f", HOLD, pose = some landed)
  result["collapse_axis"] = frame("f", HOLD, lead_turn = -90)
  doAssert relative(landed) == relative(
    spinAbout(rest(), Dancer.Lead, -90)),
    "The orbit does not land on the axis turn's state."
  # Not merely equal numbers: the two are the same drawing, mark for mark.
  doAssert result["collapse_orbit"] == result["collapse_axis"],
    "The collapse differs: orbit and axis draw two pictures."

  # And the same four moves, running.
  const PX = 1.3
  for m in MOVES:
    let
      tag = m.name.replace(" ", "_").replace(",", "")
      half = cycle(m.apply).mapIt(extent(it, captions = false)).max
      style = &"""class="mv" style="width: {n(2 * half * PX)}px;""" &
        &""" height: {n(2 * half * PX)}px""""
    result[&"mv_{tag}"] = animated("mv", HOLD, m.apply, some half)
      .replaceFirst("class=\"mv\"", style)
    result[&"mv_{tag}_still"] = frame("mv still", HOLD, captions = false,
                                      half = some half)
      .replaceFirst("class=\"mv still\"",
        &"""class="mv still" style="width: {n(2 * half * PX)}px;""" &
          &""" height: {n(2 * half * PX)}px"""")


#[ The Rotation Page ]#

const
  HAND_TO_HAND*: Holds = [some Arm.R, some Arm.L]
    ## The parallel double hold, Left-to-right and Right-to-left -- the
    ## workbook's "hand to hand".
  CROSSED*: Holds = [some Arm.L, some Arm.R]
    ## The crossed double hold; which arm is over is the frame's own `over`.

const
  HIGH_ONE: Levels = [some Level.High, none Level]
  HIGH_BOTH: Levels = [some Level.High, some Level.High]
    ## Rule 10's assumption made visible: every held connection carries the
    ## high dot, and with no way ever named nothing settles off its side.

const
  OVER_PLAIN: Twist = (over_all: true, loops: 0, braid: 0)
    ## Held high and unwound: straight over, nothing to say.
  OVER_LOOP_ONE: Twist = (over_all: true, loops: 1, braid: 0)
  OVER_LOOP_OTHER: Twist = (over_all: true, loops: -1, braid: 0)
  OVER_LOOP_TWO: Twist = (over_all: true, loops: 2, braid: 0)
  OVER_LOOP_TWO_OTHER: Twist = (over_all: true, loops: -2, braid: 0)
    ## A lone reach's wind, one pigtail per half turn, sense by sign.
  OVER_BRAID: Twists = [(true, 0, 2), (true, 0, 2)]
  OVER_BRAID_OTHER: Twists = [(true, 0, -2), (true, 0, -2)]
    ## A pair's extra full turn: two more crossings, sense by sign.
  OVER_BOTH: Twists = [OVER_PLAIN, OVER_PLAIN]
    ## A pair held high and unwound past what the frame already says.


func rockFollowHalf(pose: Pose; scalar: float): Pose =
  spinAbout(pose, Dancer.Follow, 180 * scalar)


func edgeGlyph(label: string): string =
  ## Draw one rotation edge: a two-headed arrow, since every turn reverses.
  "<svg viewBox=\"0 0 44 34\" width=\"44\" height=\"34\"" &
    " aria-hidden=\"true\">" &
    &"""<text x="22" y="10" text-anchor="middle" style="font: 8px""" &
    &""" ui-sans-serif, system-ui, sans-serif; fill: {FAINT}">{label}""" &
    "</text>" &
    &"""<path d="M7 22 L37 22 M12 17 L7 22 L12 27 M32 17 L37 22 L32 27"""" &
    &""" fill="none" stroke="{QUIET}" stroke-width="1.6"""" &
    """ stroke-linecap="round" stroke-linejoin="round"/></svg>"""


func refusedGlyph(): string =
  ## Draw a turn that cannot be taken: dashed, as refusal is drawn
  ## everywhere in this project.
  "<svg viewBox=\"0 0 34 34\" width=\"34\" height=\"34\"" &
    " aria-hidden=\"true\">" &
    &"""<text x="17" y="10" text-anchor="middle" style="font: 8px""" &
    &""" ui-sans-serif, system-ui, sans-serif; fill: {FAINT}">refused""" &
    "</text>" &
    &"""<path d="M5 22 L29 22 M24 17 L29 22 L24 27" fill="none"""" &
    &""" stroke="{QUIET}" stroke-width="1.6" stroke-dasharray="3 3"""" &
    """ stroke-linecap="round" stroke-linejoin="round"/></svg>"""


func rotationParts*(): Parts =
  ## Build every SVG the rotation page places.
  ##   A position is one of the app's eight frames plus how far the arms
  ##     have wound (rules 11 to 13); the drawing carries the wind as which
  ##     way the line goes round, said outright since no lock or wrap is
  ##     ever named here (rule 10).
  # The single hold: five positions, a full turn each way in half-turn
  # steps.  A half turn moves the follow's hand, so the line itself changes
  # -- but +half and -half move it to the same place, so the wind is said by
  # the pigtail: one loop per half turn, mirrored by direction (rule 14).
  result["rot_single_m2"] = frame("tiny", HOLD, HIGH_ONE, captions = false,
    twist = [OVER_LOOP_TWO_OTHER, OVER_PLAIN])
  result["rot_single_m1"] = frame("tiny", HOLD, HIGH_ONE, captions = false,
    follow_turn = 180, twist = [OVER_LOOP_OTHER, OVER_PLAIN])
  result["rot_single_z"] = frame("tiny", HOLD, HIGH_ONE, captions = false,
    twist = [OVER_PLAIN, OVER_PLAIN])
  result["rot_single_p1"] = frame("tiny", HOLD, HIGH_ONE, captions = false,
    follow_turn = 180, twist = [OVER_LOOP_ONE, OVER_PLAIN])
  result["rot_single_p2"] = frame("tiny", HOLD, HIGH_ONE, captions = false,
    twist = [OVER_LOOP_TWO, OVER_PLAIN])

  # Hand to hand: three positions, half a turn each way (rule 12).  Here the
  # geometry says it by itself -- a half turn swaps the follow's hands, so
  # the parallel pair becomes a crossed one -- and which arm is broken at
  # the crossing says which way it wound.  Nothing is added.
  result["rot_hand_m1"] = frame("wide", HAND_TO_HAND, HIGH_BOTH,
    over = some Arm.R, captions = false, follow_turn = 180,
    twist = OVER_BOTH)
  result["rot_hand_z"] = frame("wide", HAND_TO_HAND, HIGH_BOTH,
    captions = false, twist = OVER_BOTH)
  result["rot_hand_p1"] = frame("wide", HAND_TO_HAND, HIGH_BOTH,
    over = some Arm.L, captions = false, follow_turn = 180,
    twist = OVER_BOTH)

  # The crossed pair: four positions, the twisted states as the ends (rule
  # 13).  The middles already cross once, which is the hold itself; an end
  # is a full turn further, and a full turn returns the hands to where they
  # were -- so the two arms braid, crossing twice more, sense by direction.
  result["rot_cross_end_l"] = frame("wide", CROSSED, HIGH_BOTH,
    over = some Arm.L, captions = false, twist = OVER_BRAID_OTHER)
  result["rot_cross_over_l"] = frame("wide", CROSSED, HIGH_BOTH,
    over = some Arm.L, captions = false, twist = OVER_BOTH)
  result["rot_cross_over_r"] = frame("wide", CROSSED, HIGH_BOTH,
    over = some Arm.R, captions = false, twist = OVER_BOTH)
  result["rot_cross_end_r"] = frame("wide", CROSSED, HIGH_BOTH,
    over = some Arm.R, captions = false, twist = OVER_BRAID)

  # The edges the strips are strung on.
  result["g_half"] = edgeGlyph("½ turn")
  result["g_full"] = edgeGlyph("1 turn")
  result["g_refused"] = refusedGlyph()

  # And one of them moving: hand to hand rocking through its three
  # positions, through the same machinery as every other moving figure, so
  # rule 1's one-way-round and blend discipline hold here too.
  const PX = 1.3
  let half = cycle(rockFollowHalf).mapIt(extent(it, captions = false)).max
  # Straight over, every frame: the follow turns *under* raised arms, so the
  # lines sweep across them and nothing hugs a rim (rule 14).  The pair goes
  # parallel to crossed and back as they turn, which is the twist appearing.
  result["rot_moving"] = animated("mv", HAND_TO_HAND, rockFollowHalf,
      some half, HIGH_BOTH, over_all = true)
    .replaceFirst("class=\"mv\"",
      &"""class="mv" style="width: {n(2 * half * PX)}px;""" &
        &""" height: {n(2 * half * PX)}px"""")
  result["rot_moving_still"] = frame("mv still", HAND_TO_HAND, HIGH_BOTH,
      captions = false, half = some half, twist = OVER_BOTH)
    .replaceFirst("class=\"mv still\"",
      &"""class="mv still" style="width: {n(2 * half * PX)}px;""" &
        &""" height: {n(2 * half * PX)}px"""")

  # Every position of a class draws differently from every other: a twist
  # nobody can see is not a twist (rule 14).
  for class in ["rot_single_", "rot_hand_", "rot_cross_"]:
    var drawn: seq[tuple[key, figure: string]]
    for key, figure in result:
      if key.startsWith(class):
        for seen in drawn:
          doAssert seen.figure != figure,
            &"Two positions draw alike; got `{key}` equal to `{seen.key}`."
        drawn.add (key, figure)

  # And nothing on this page hugs a rim.  A rim is drawn with arcs and may
  # be; a *reach* drawn with one has walked round a body, and there is to be
  # none of that (rule 14).  A reach is the connection's own stroke width.
  for key, figure in result:
    if not key.startsWith("rot_"):
      continue
    for piece in figure.split("<path "):
      if &"stroke-width=\"{LINK_W}\"" in piece:
        doAssert " A" notin piece,
          &"A reach walks round a body; got an arc in `{key}`."


func signParts*(): Parts =
  ## Build every SVG the turn-sign page places.
  let
    low_arms: SignArms = [(true, some Level.Low), (true, some Level.Low)]
    split_arms: SignArms = [(true, some Level.Low), (true, some Level.High)]
  # Quarters, packed up from the foot.
  for k in 1 .. 4:
    result[&"q_lead_{k}"] = sign(newSeqWith(k, Row.Lead), arms = low_arms)
    result[&"q_foll_{k}"] = sign(newSeqWith(k, Row.Follow), arms = low_arms)
    result[&"q_lead_{k}_small"] = sign(newSeqWith(k, Row.Lead),
                                       arms = low_arms, scale = 0.72)
  for k in [1, 3]:                     # the alternative: spread, not packed
    result[&"u_lead_{k}"] = sign(newSeqWith(k, Row.Lead), arms = low_arms,
                                 packed = false)

  # Whose quarter, and the arms inside.
  result["s_split"] = sign(@[Row.Lead, Row.Lead], arms = split_arms)
  result["s_acw"] = sign(newSeqWith(3, Row.Lead), Lean.Acw, low_arms)
  result["s_one_hand"] = sign(@[Row.Follow, Row.Follow],
                              arms = [(true, some Level.Low),
                                      (false, none Level)])
  result["s_above"] = sign(newSeqWith(4, Row.Follow),
                           arms = [(true, some Level.Above),
                                   (true, some Level.Above)])
  result["s_unsaid"] = sign(@[Row.Lead])
  result["s_lead_small"] = sign(@[Row.Lead, Row.Lead], arms = low_arms,
                                scale = 0.72)
  result["s_foll_small"] = sign(@[Row.Follow, Row.Follow], arms = low_arms,
                                scale = 0.72)
  # The shade says whose quarter it is as well as the shape does.
  doAssert result["s_lead_small"] != result["s_foll_small"],
    "Dancers collide: the two shades draw one sign."

  # Mixed, now that there is room for more than one split.
  result["m_11"] = sign(@[Row.Follow, Row.Lead], arms = low_arms)
  result["m_12"] = sign(@[Row.Follow, Row.Lead, Row.Lead], arms = low_arms)
  result["m_22"] = sign(@[Row.Follow, Row.Follow, Row.Lead, Row.Lead],
                        arms = low_arms)
  result["m_31"] = sign(@[Row.Follow, Row.Follow, Row.Follow, Row.Lead],
                        arms = low_arms)
  result["m_22_small"] = sign(@[Row.Follow, Row.Follow, Row.Lead, Row.Lead],
                              arms = low_arms, scale = 0.72)

  # Axis against orbit, on the sign.
  result["o_axis"] = sign(@[Row.Lead, Row.Lead], arms = split_arms,
                          about = some About.Axis)
  result["o_orbit"] = sign(@[Row.Lead, Row.Lead], arms = split_arms,
                           about = some About.Orbit)
  result["o_orbit_acw"] = sign(newSeqWith(3, Row.Follow), Lean.Acw,
                               split_arms, about = some About.Orbit)
  result["o_axis_small"] = sign(@[Row.Lead, Row.Lead], arms = split_arms,
                                about = some About.Axis, scale = 0.72)
  result["o_orbit_small"] = sign(@[Row.Lead, Row.Lead], arms = split_arms,
                                 about = some About.Orbit, scale = 0.72)
  result["p_split"] = sign(@[Row.Follow, Row.Lead], arms = split_arms,
                           pip_about = @[About.Orbit, About.Axis])
  result["p_split_small"] = sign(@[Row.Follow, Row.Lead], arms = split_arms,
                                 pip_about = @[About.Orbit, About.Axis],
                                 scale = 0.72)

  # Five ways to say "any amount".
  result["any_full"] = sign(newSeqWith(4, Row.Lead), arms = low_arms)
  for (name, ending) in [("open", Ending.Open), ("spill", Ending.Spill),
                         ("ellipsis", Ending.EllipsisEnd),
                         ("repeat", Ending.RepeatEnd), ("loop", Ending.Loop)]:
    let
      count = if ending in [Ending.EllipsisEnd, Ending.RepeatEnd]: 3 else: 4
      base = newSeqWith(count, Row.Lead)
      foll = newSeqWith(count, Row.Follow)
    result[&"any_{name}"] = sign(base, arms = low_arms, ending = some ending)
    result[&"any_{name}_small"] = sign(base, arms = low_arms,
                                       ending = some ending, scale = 0.72)
    result[&"any_{name}_foll"] = sign(foll, arms = low_arms,
                                      ending = some ending)
