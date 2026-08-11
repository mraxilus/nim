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

import std/[algorithm, math, options, sequtils, sets, strformat, strutils,
            tables]

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
  # Drawn twice -- the orbit itself, which keeps the walker's bearing
  # (rule 20), and the compound of an orbit and an axis turn, which is what
  # keeping the face to the partner all the way round really is.
  for (tag, locked) in [("orbit", false), ("compound", true)]:
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

  # What collapses, and what does not.  An orbit by either dancer lands in
  # one picture: the drawing cannot say who walked.
  var walked_by: array[Dancer, Pose]
  for who in Dancer:
    walked_by[who] = canonicalise(orbit(rest(), who, 90, locked = false))
    walked_by[who].ring = none(Ring)   # the move is over
  result["collapse_follow_walked"] = frame("f", HOLD,
                                           pose = some walked_by[Dancer.Follow])
  result["collapse_lead_walked"] = frame("f", HOLD,
                                         pose = some walked_by[Dancer.Lead])
  doAssert result["collapse_follow_walked"] == result["collapse_lead_walked"],
    "Two orbits draw two pictures; the drawing can say who walked."

  # And the compound -- an orbit and an axis turn together -- lands where
  # the lead's own axis turn lands.  A plain orbit does not, which is why
  # the page had to be corrected.
  var compounded = canonicalise(orbit(rest(), Dancer.Follow, 90, locked = true))
  compounded.ring = none(Ring)
  result["collapse_compound"] = frame("f", HOLD, pose = some compounded)
  result["collapse_axis"] = frame("f", HOLD, lead_turn = -90)
  doAssert relative(compounded) == relative(
    spinAbout(rest(), Dancer.Lead, -90)),
    "The compound does not land on the axis turn's state."
  # Not merely equal numbers: the two are the same drawing, mark for mark.
  doAssert result["collapse_compound"] == result["collapse_axis"],
    "The collapse differs: compound and axis draw two pictures."
  doAssert result["collapse_follow_walked"] != result["collapse_axis"],
    "A plain orbit now lands on the axis turn, which would be rule 20 lost."

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


#[ The Single-Hand Turns Page ]#

const SINGLES*: array[4, tuple[holds: Holds, name: string]] = [
  ([some Arm.L, none Arm], "Left to left"),
  ([some Arm.R, none Arm], "Left to right"),
  ([none Arm, some Arm.L], "Right to left"),
  ([none Arm, some Arm.R], "Right to right"),
] ## The app's four single-hand frames, named as the workbook names them.

const
  ABOVE_ONE*: Levels = [some Level.Above, none Level]
  ABOVE_OTHER*: Levels = [none Level, some Level.Above]
    ## Rule 17's assumption made visible: the held arm is carried over the
    ## head, which is the one level with no lock and no wrap in it (rule 8),
    ## and the one that draws its connection straight over everything.

const
  QUARTERS_ROUND* = 4        ## Quarter turns in the round, and so positions.
  QUARTER* = 90.0            ## Degrees in one of them.

type
  Family* {.pure.} = enum ## Which round of positions a way of turning walks.
    FollowFacing,         ## The follow comes round where they stand.
    PairSwung,            ## The axis swings and the follow's facing with it.
    AxisWalked            ## The axis swings and both bearings hold.
  TurnWay* {.pure.} = enum ## The four ways a couple can turn a quarter.
    FollowAxis, LeadAxis, FollowOrbit, LeadOrbit

const WAYS_OF_TURNING*: array[TurnWay, tuple[
    tag, title, blurb: string; who: Dancer; about: About; family: Family]] = [
  (tag: "fa", title: "The follow turns on the spot",
   blurb: "The follow turns on their own axis and nobody travels. What " &
     "comes round is their <b>chevron</b>, and with it which of their " &
     "hands is nearer. The lead stands still, facing up, so there is " &
     "nothing to reorient afterwards: one stage, and it is over.",
   who: Dancer.Follow, about: About.Axis, family: Family.FollowFacing),
  (tag: "la", title: "The lead turns on the spot",
   blurb: "The lead turns on their own axis, and this is where the two " &
     "stages matter. <b>Stage one</b>: the lead turns and the room holds " &
     "still, so the picture leans off upright. <b>Stage two</b>: the " &
     "picture turns back until the lead faces up, which swings the follow " &
     "round them. Same turn, told in the order it is danced.",
   who: Dancer.Lead, about: About.Axis, family: Family.PairSwung),
  (tag: "fo", title: "The follow orbits the lead",
   blurb: "The follow walks the ring round the lead, who stands still — " &
     "the dashed ring says so, and says who is standing. <b>They keep " &
     "their own bearing</b>: walking round somebody is not the same act " &
     "as turning to keep facing them, so their chevron points the way it " &
     "started the whole way round. The lead never moves and never turns, " &
     "so there is no second stage at all: what you see is the walk.",
   who: Dancer.Follow, about: About.Orbit, family: Family.AxisWalked),
  (tag: "lo", title: "The lead orbits the follow",
   blurb: "The lead walks the ring round the follow, keeping their own " &
     "bearing too. It lands on the very pictures the <em>follow's</em> " &
     "orbit lands on — measured, and asserted on every build. Which " &
     "dancer walked is not something the drawing can say; only the path " &
     "can, which is why both are animated.",
   who: Dancer.Lead, about: About.Orbit, family: Family.AxisWalked),
]

const FAMILY_OF*: array[TurnWay, Family] = [
  Family.FollowFacing, Family.PairSwung, Family.AxisWalked,
  Family.AxisWalked,
] ## Which round each way walks, measured and asserted below.
  ##   An axis turn moves a facing; an orbit that keeps its bearing moves
  ##     the pair's axis instead, so the orbits walk a round of their own
  ##     and the two of them walk the same one.


func levelsFor*(holds: Holds): Levels =
  ## Say above on whichever single arm is holding.
  if holds[Arm.L].isSome: ABOVE_ONE else: ABOVE_OTHER


func quarterPose*(way: TurnWay; quarter: int): Pose =
  ## Get the pose this way of turning reaches after so many quarters.
  ##   Drawn canonically, with the lead facing up: that is what a position
  ##     is, whatever stages the turning took to arrive at it.
  ##   And without a ring: the dashed ring says *somebody is going round
  ##     somebody*, which is true of a transition and not of a place to
  ##     stand.  It is why the orbit rounds draw as their axis partners do.
  ##   Framed on the lead (rule 25), so they stand in the same spot in
  ##     every cell of a row and it is the follow who is seen to move.
  let w = WAYS_OF_TURNING[way]
  result = canonicalise(turned(rest(), w.who, w.about,
                               QUARTER * float(quarter)), on = Anchor.Lead)
  result.ring = none(Ring)


func placeOf*(pose: Pose): tuple[axis, facing: float] =
  ## Get a position as a pair of numbers that compare cleanly.
  ##   `relative` can hand back 360 where another hands back 0, and a
  ##     negative zero where another hands back a positive one, so both are
  ##     brought into the round before anything is compared.
  let r = relative(pose)
  (floorMod(r.axis, 360.0), floorMod(r.facing, 360.0))


func turnGlyph*(label: string; width = 44.0): string =
  ## Draw one edge of the cycle: a two-headed arrow, since a turn reverses.
  ##   The arrow keeps its length whatever the box; `width` is room for the
  ##     label above it, which a longer name needs more of.
  let
    mid = width / 2
    (tail, head) = (mid - 15, mid + 15)
  &"""<svg viewBox="0 0 {n(width)} 30" width="{n(width)}" height="30"""" &
    " aria-hidden=\"true\">" &
    &"""<text x="{n(mid)}" y="9" text-anchor="middle" style="font: 8px""" &
    &""" ui-sans-serif, system-ui, sans-serif; fill: {FAINT}">{label}""" &
    "</text>" &
    &"""<path d="M{n(tail)} 20 L{n(head)} 20 M{n(tail + 5)} 15""" &
    &""" L{n(tail)} 20 L{n(tail + 5)} 25 M{n(head - 5)} 15 L{n(head)} 20""" &
    &""" L{n(head - 5)} 25" fill="none" stroke="{QUIET}"""" &
    """ stroke-width="1.6" stroke-linecap="round"""" &
    """ stroke-linejoin="round"/></svg>"""


func singleTurnParts*(): Parts =
  ## Build every SVG the single-hand turns page places.
  ##   Rule 16: a single hand held above turns for ever, so no position is
  ##     ever refused and how far it has wound is not part of its state.
  ##     What is left is four quarter-turn orientations per connection.
  ##   Rule 19: four ways of turning reach them -- each dancer's own axis
  ##     turn and each dancer's orbit of the other.
  ##   Rule 15: every position drawn, every edge animated.
  ##   Rule 25: framed on the lead, who therefore falls on the same spot in
  ##     every cell -- which only reads if the cells beside each other hold
  ##     the same box.
  ##     A row of positions takes one box for the whole page, since every
  ##       position stands the same distance apart.  A row of transitions
  ##       takes one box per way of turning, because a lead who walks the
  ##       ring needs room a lead who stands still does not, and spending
  ##       that room on every cell of every row would shrink the lot.
  ##     Each cell is then given what its box needs at the scale its own row
  ##       draws at, so the marks stay the size they were and it is the
  ##       cells that grow.
  const
    PX = 1.0        ## Pixels a unit takes in a moving cell.
    STILL_PX = 0.72 ## And in a still one, where the figures are smaller.
  var
    walks: array[TurnWay, array[QUARTERS_ROUND, Walk]]
    still_half = 0.0
    walk_half: array[TurnWay, float]
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    for quarter in 0 ..< QUARTERS_ROUND:
      still_half = max(still_half,
                       extent(quarterPose(way, quarter), captions = false))
      walks[way][quarter] = turnWalk(quarterPose(way, quarter), w.who,
                                     w.about, QUARTER, on = Anchor.Lead)
      for put in walks[way][quarter].poses:
        walk_half[way] = max(walk_half[way], extent(put, captions = false))

  func sized(svg, cls: string; half, px: float): string =
    ## Give a cell the room its row's box needs at its row's own scale.
    svg.replaceFirst(&"class=\"{cls}\"",
      &"""class="{cls}" style="width: {n(2 * half * px)}px;""" &
        &""" height: {n(2 * half * px)}px"""")

  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    for c, single in SINGLES:
      let levels = levelsFor(single.holds)

      # Every derived position of this way.
      for quarter in 0 ..< QUARTERS_ROUND:
        result[&"st_{w.tag}_{c}_{quarter}"] = sized(frame("tiny",
          single.holds, levels, captions = false,
          pose = some quarterPose(way, quarter), half = some still_half,
          clear_marks = true), "tiny", still_half, STILL_PX)

      # And every edge, walked in the stages rule 18 asks for.
      for quarter in 0 ..< QUARTERS_ROUND:
        let to = (quarter + 1) mod QUARTERS_ROUND
        result[&"tr_{w.tag}_{c}_{quarter}_{to}"] = sized(animatedPoses("mv",
          single.holds, walks[way][quarter].poses, some walk_half[way],
          levels, dur = 5.4, times = walks[way][quarter].times),
          "mv", walk_half[way], PX)
        # The still stands in where motion is turned off, so it is a settled
        # picture and bends by rule 22; the moving figure it replaces is the
        # rule's own exemption and stays straight.
        result[&"tr_{w.tag}_{c}_{quarter}_{to}_still"] = sized(
          frame("mv still", single.holds, levels, captions = false,
                pose = some quarterPose(way, quarter),
                half = some walk_half[way], clear_marks = true),
          "mv still", walk_half[way], PX)

  result["g_quarter"] = turnGlyph("&#188; turn")

  # Every position of a round draws differently, or a position it is not.
  for way in TurnWay:
    for c in 0 ..< SINGLES.len:
      var seen: seq[string]
      for quarter in 0 ..< QUARTERS_ROUND:
        let figure = result[&"st_{WAYS_OF_TURNING[way].tag}_{c}_{quarter}"]
        doAssert figure notin seen,
          &"Two quarters draw alike; got `{quarter}` of {way} on {c}."
        seen.add figure

  # Ways of one family walk one round of positions, and ways of different
  # families never meet except where every round meets, at rest.
  for way in TurnWay:
    for mate in TurnWay:
      var shared = 0
      for quarter in 0 ..< QUARTERS_ROUND:
        for other_quarter in 0 ..< QUARTERS_ROUND:
          if placeOf(quarterPose(way, quarter)) ==
              placeOf(quarterPose(mate, other_quarter)):
            inc shared
      let same_round = FAMILY_OF[way] == FAMILY_OF[mate]
      doAssert shared == (if same_round: QUARTERS_ROUND else: 1),
        &"A way left its family; got `{shared}` shared of {way} and {mate}."

  # And nothing on this page wraps a body: a reach is the connection's own
  # stroke width, and one drawn with an arc has walked round a body.
  for key, figure in result:
    if not (key.startsWith("st_") or key.startsWith("tr_")):
      continue
    for piece in figure.split("<path "):
      if &"stroke-width=\"{LINK_W}\"" in piece:
        doAssert " A" notin piece,
          &"A reach walks round a body; got an arc in `{key}`."


#[ The Hand-to-Hand Turns Page ]#

const
  HAND_TO_HAND*: Holds = [some Arm.R, some Arm.L]
    ## The app's own two-hand frame: the lead's Left in the follow's right
    ## and the lead's Right in the follow's left, uncrossed.
  ABOVE_BOTH*: Levels = [some Level.Above, some Level.Above]
    ## Both arms over the head, this scope's one level (rules 17, 21).
  HALF* = 180.0 ## The turn between one position and the next (rule 28).

const CHAIN*: array[5, tuple[wind: float, name: string, note: string]] = [
  (-1.0, "Right over Left box", "a whole turn, wound one way"),
  (-0.5, "Right over Left X", "a half turn: the same way, facing"),
  (0.0, "Left-to-right and Right-to-left", "the app's frame, nothing wound"),
  (0.5, "Left over Right X", "a half turn: the other way, facing"),
  (1.0, "Left over Right box", "a whole turn, wound the other way"),
] ## The five positions this page holds, in chain order.
  ##   The middle is the app's own frame, the ends are rule 27's boxes, and
  ##     between them are rule 28's half turns -- where the partners face
  ##     the same way and the pair makes a plain X.
  ##   Named for whichever of the lead's arms passes over the other at the
  ##     lead's own crossover, which is the rule's own naming and is
  ##     flagged on the page as preliminary.


func windTwist*(wind: float): Twists =
  ## Say how far a pair has wound, as the drawing channel takes it.
  [(false, 0, 0, wind), (false, 0, 0, wind)]


func handPose*(wind = 0.0): Pose =
  ## Get the pose one position of the chain stands in.
  ##   The follow's own axis turn is what the poses are built from, so a
  ##     half turn faces them away where they stand and a whole turn brings
  ##     everything back.  Which dancer did the turning is not something a
  ##     position can say; the page animates all of them.
  result = canonicalise(turned(rest(), Dancer.Follow, About.Axis,
                               2 * HALF * wind), on = Anchor.Lead)
  result.ring = none(Ring)


func handTurnParts*(): Parts =
  ## Build every SVG the hand-to-hand turns page places.
  ##   Rule 28: five positions, a half turn apart -- the frame, an X either
  ##     side of it, and a box beyond each X.
  ##   Rule 15: every position drawn, every edge animated, by each way of
  ##     turning that can walk the chain at all.
  ##   Rule 28 again: an orbit that keeps its bearing turns nobody, so it
  ##     winds nothing.  The two axis turns walk the chain; the two orbits
  ##     carry the pair around without moving along it, which is drawn once
  ##     rather than claimed.
  const
    PX = 1.0        ## Pixels a unit takes in a moving cell.
    STILL_PX = 0.72 ## And in a still one, where the figures are smaller.
  var
    walks: array[TurnWay, array[CHAIN.len - 1, Walk]]
    still_half = 0.0
    walk_half: array[TurnWay, float]
  for i, position in CHAIN:
    still_half = max(still_half, extent(handPose(position.wind),
                                        captions = false))
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    for i in 0 ..< CHAIN.len - 1:
      # Each edge starts where it starts and turns a half, so a way that
      # winds walks one step along the chain and a way that does not
      # simply carries the pair out and back.
      walks[way][i] = turnWalk(handPose(CHAIN[i].wind), w.who, w.about,
                               HALF, on = Anchor.Lead)
      for put in walks[way][i].poses:
        walk_half[way] = max(walk_half[way], extent(put, captions = false))

  func sized(svg, cls: string; half, px: float): string =
    ## Give a cell the room its row's box needs at its row's own scale.
    svg.replaceFirst(&"class=\"{cls}\"",
      &"""class="{cls}" style="width: {n(2 * half * px)}px;""" &
        &""" height: {n(2 * half * px)}px"""")

  # The chain, drawn once: every way that winds reaches these same five, so
  # drawing them per way would be the same picture over again.
  for i, position in CHAIN:
    result[&"hh_{i}"] = sized(frame("tiny", HAND_TO_HAND, ABOVE_BOTH,
      captions = false, pose = some handPose(position.wind),
      half = some still_half, twist = windTwist(position.wind),
      clear_marks = true), "tiny", still_half, STILL_PX)

  # And every edge of it, walked by every way of turning.
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    for i in 0 ..< CHAIN.len - 1:
      result[&"hw_{w.tag}_{i}"] = sized(animatedPoses("mv", HAND_TO_HAND,
        walks[way][i].poses, some walk_half[way], ABOVE_BOTH, dur = 5.4,
        times = walks[way][i].times, wound = CHAIN[i].wind),
        "mv", walk_half[way], PX)
      # The still stands in where motion is turned off, so it is the
      # picture the move sets off from (rule 22's exemption again).
      result[&"hw_{w.tag}_{i}_still"] = sized(frame("mv still",
        HAND_TO_HAND, ABOVE_BOTH, captions = false,
        pose = some handPose(CHAIN[i].wind), half = some walk_half[way],
        twist = windTwist(CHAIN[i].wind), clear_marks = true),
        "mv still", walk_half[way], PX)

  result["g_half"] = turnGlyph("a half turn", 68.0)

  # The five positions draw differently, or they are not five positions.
  for i in 0 ..< CHAIN.len:
    for j in 0 ..< i:
      doAssert result[&"hh_{i}"] != result[&"hh_{j}"],
        &"Two positions draw alike; got `{i}` and `{j}`."


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
