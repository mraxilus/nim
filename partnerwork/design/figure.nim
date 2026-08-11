## Draw a whole picture: two dancers, their connections, and how it moves.
##
##   A static figure is drawn from a canonical pose.  An animated one samples
##     a cycle of poses on one clock -- the bodies carried rigidly by
##     transforms, the reach re-routed each frame with one way round settled
##     for the whole move -- so everything stays in one piece.
##   A state the rules say does not exist is refused, not drawn: `partsOf`
##     asserts `danceable`, so the build fails rather than publishing a wrap
##     that does not wrap (rule 7).
##     Cost of refusing at build time: a page asking for an impossible state
##       dies with an assertion rather than showing a gap.  Accepted -- the
##       gap is the author's decision to make, not the drawing's.

{.experimental: "strictFuncs".}

import std/[math, options, sequtils, strformat, strutils]

import ./[body, geometry, pose, route, rules, style]


const
  WIDE* = 160.0    ## The box a picture with captions needs.
  SIZE* = 116.0    ## And the box it needs without them.

type
  Twist* = tuple ## How a connection is drawn when the arms have wound.
    over_all: bool ## Drawn straight, passing over whatever it meets.
    loops: int     ## Pigtails at its middle: one per half turn, signed.
    braid: int     ## Crossings with its partner: one per half turn.
  Twists* = array[Arm, Twist]
    ## Per connection, how far its arms have wound past what the frame's own
    ## geometry already says.
    ##   At high the arms are up, so a wound reach never routes round a body
    ##     (rule 14): it goes straight over, and says the wind by crossing --
    ##     its partner where there is one, itself where there is not.
    ##   Cost of a second drawing channel: a figure can now be asked for a
    ##     twist its pose does not have.  Accepted -- the rotation page owns
    ##     both, and `checks` measures what was drawn rather than trusting
    ##     what was asked.

const NO_TWIST*: Twists = [(false, 0, 0), (false, 0, 0)]
  ## Nothing wound and nothing said: every figure but the rotation page's.


func twoTone*(runs: seq[Run]; mid: Point; lead_side, foll_side: Arm):
    seq[string] =
  ## Draw one reach in its two hands' own colours, meeting at its middle
  ## point (rule 9).
  ##   Each half is exactly the mark it ends on: the lead's in their arm's
  ##     ink and the deep shade, the follow's in theirs and the plain one.
  ##   So a line draws the pair of colours that names which hands are joined,
  ##     instead of leaving it to two marks that go too small to read; and
  ##     the shade still says which end is whose when both hands share a hue.
  let (near, far) = splitAt(runs, mid)
  @[reachMarkup(near, DEEP[lead_side]), reachMarkup(far, INK[foll_side])]


func ghosts*(holds: Holds; levels: Levels; ways: Ways):
    seq[tuple[who: Dancer, arm: Arm]] =
  ## List every hand that is not where its arm hangs.
  for arm in Arm:
    if holds[arm].isNone:
      continue
    let held = [(Dancer.Lead, arm), (Dancer.Follow, holds[arm].get)]
    for (who, own) in held:
      if slotOf(own, levels[arm], ways[arm]) != (own, Slot.Default):
        result.add (who, own)


func settled*(pose: Pose; holds: Holds; levels: Levels; ways: Ways): Pose =
  ## Get the same pose with every hand put in the slot its hold settles it
  ## in.
  ##   There is nothing to solve: a settled hand is in one of six places, and
  ##     which one is decided by its own side and by the level and way of the
  ##     hold it is part of (rules 2 to 6).
  ##   A hand that is free, or held by a hold that has not said both, stays
  ##     where the arm hangs.  Hands still move smoothly between slots when a
  ##     picture moves; it is the settled state that is discrete.
  var wind: Winds
  for arm in Arm:
    if holds[arm].isNone:
      continue
    wind[Dancer.Lead][arm] = settledWind(arm, levels[arm], ways[arm])
    let own = holds[arm].get
    wind[Dancer.Follow][own] = settledWind(own, levels[arm], ways[arm])
  result = pose
  result.wind = wind


func bodiesOf(pose: Pose): tuple[lead, follow: route.Body] =
  ## See the couple as the routing does.
  ((pose.place[Dancer.Lead], pose.facing[Dancer.Lead]),
   (pose.place[Dancer.Follow], pose.facing[Dancer.Follow]))


func danceable*(pose: Pose; holds: Holds;
    levels: Levels = default(Levels); ways: Ways = default(Ways)): bool =
  ## Test whether every lock and wrap in this hold really is one (rule 7).
  ##   A lock or wrap position may only be used when the line goes round no
  ##     less than just under half the circumference -- it does not mean
  ##     anything to have a wrap without the line actually going round the
  ##     body.  So whether a state exists at all depends on the orientation,
  ##     and this is what says so.
  let
    put = settled(pose, holds, levels, ways)
    p = handsOf(put)
    (lead_body, follow_body) = bodiesOf(put)
  for arm in Arm:
    if holds[arm].isNone:
      continue
    if roundOf(levels[arm], ways[arm]).isNone:
      continue                     # nothing claimed, nothing to hold up
    let ends: route.Ends = (p[Dancer.Lead][arm],
                            p[Dancer.Follow][holds[arm].get],
                            lead_body, follow_body)
    if not wrapsEnough(ends, levels[arm], ways[arm]):
      return false
  true


func clearingMarks*(put: Pose; a, b: Point): seq[Mark] =
  ## List what a settled reach between these two hands has to keep out of
  ## (rule 22).
  ##   Every hand mark but the two it joins -- a line through one says that
  ##     hand is held -- and both chevrons, which a line through hides.
  ##   Each clearance is what that mark actually reaches, so the daylight is
  ##     seen and not guessed; and this is the one list, read by the drawing
  ##     and by the check that measures it.
  ##   A hand is one disc, because a hand's mark is compact.  A chevron is a
  ##     thin V, so it is a string of small discs walked along its own two
  ##     legs -- a single disc over the whole of it would cover the middle
  ##     of the body and push every reach outside it.
  let p = handsOf(put)
  for who in Dancer:
    let drawn = chevronPoints(put.place[who], put.facing[who])
    for leg in 0 .. 1:
      for step in 0 .. CHEVRON_STEPS:
        let part = float(step) / float(CHEVRON_STEPS)
        result.add ((drawn[leg].x + (drawn[leg + 1].x - drawn[leg].x) * part,
                     drawn[leg].y + (drawn[leg + 1].y - drawn[leg].y) * part),
                    CHEVRON_CLEAR)
    for side in Arm:
      let q = p[who][side]
      if min(dist(q, a), dist(q, b)) > 0.01:
        result.add (q, (if who == Dancer.Lead: LEAD_CLEAR else: FOLLOW_CLEAR))


func partsOf*(pose: Pose; holds: Holds; levels: Levels = default(Levels);
    over = none(Arm); free = Free.Fade; captions = true;
    ways: Ways = default(Ways); twist: Twists = NO_TWIST;
    clear_marks = false): seq[string] =
  ## Draw every element of one pose, in the order the picture is read from.
  ##   `clear_marks` asks a straight reach to bend round the marks it does
  ##     not join (rule 22).  It is off by default so that only the pages
  ##     that have been looked at under the rule take it: the frame page's
  ##     straight and wrapping reaches are the next piece of that work, and
  ##     this flag is where it will be turned on for them.
  # A lock or wrap that does not go round the body is not one, and a state
  # that cannot be danced is an edge that is not drawn -- so this refuses
  # rather than drawing something the rules say does not exist.
  doAssert danceable(pose, holds, levels, ways),
    &"Undanceable state asked for; got `{holds}` at `{levels}`, `{ways}`."
  # Every drawing path comes through here, so this is where the hands are
  # put: a pose handed in ready-made is settled exactly like one built below.
  let
    put = settled(pose, holds, levels, ways)
    p = handsOf(put)
    (lead_body, follow_body) = bodiesOf(put)

  var bits = @[ringOf(put), border(put, Dancer.Lead),
               border(put, Dancer.Follow)]
  for who in Dancer:
    bits.add chevron(put.place[who], put.facing[who])
  # Where each displaced hand came from, as a grey outline of its own mark.
  # `back` carries locks, so a hand no longer says by where it sits how far
  # it has been taken -- the ghost of the place it left says it instead, and
  # a hand still at home has no ghost to confuse it with.
  for (who, arm) in ghosts(holds, levels, ways):
    let q = handPoint(put.place[who], put.facing[who], arm)
    bits.add hand(q.x, q.y, who == Dancer.Lead, arm, held = false,
                  free = Free.Grey)
  var routes: array[Arm, seq[Point]]
  for arm in Arm:
    if holds[arm].isNone:
      continue
    let ends: route.Ends = (p[Dancer.Lead][arm],
                            p[Dancer.Follow][holds[arm].get],
                            lead_body, follow_body)
    if levels[arm] == some(Level.Above) or twist[arm].over_all:
      # Over the head, or over a turning body: either way nothing is in the
      # way from above, and the wind is said by crossing rather than by
      # hugging (rules 1 and 14).
      routes[arm] =
        if twist[arm].loops != 0:
          pigtailed(ends.a, ends.b, twist[arm].loops)
        elif twist[arm].braid != 0:
          # The two members of a pair weave in opposition -- same wave, half
          # a period apart -- so where one swings out the other swings in
          # and they cross.  The sign turns the whole weave over, which is
          # what tells one direction of wind from the other.
          braided(ends.a, ends.b, abs(twist[arm].braid),
                  (if arm == Arm.L: 0.0 else: PI) +
                    (if twist[arm].braid > 0: 0.0 else: PI))
        elif clear_marks:
          clearedReach(ends.a, ends.b, clearingMarks(put, ends.a, ends.b))
        else:
          straightReach(ends.a, ends.b)
    else:
      # What the hold says, if it says anything; the short way if not.
      routes[arm] = routed(ends, wayFor(ends, levels[arm], ways[arm])).get.pts
  # A braided pair meets more than once, and a rope alternates: each strand
  # dives under at every second crossing.  So the crossings are found once,
  # in order along the line, and shared out between the two arms.
  let braiding = holds[Arm.L].isSome and holds[Arm.R].isSome and
    twist[Arm.L].braid != 0
  var dives: array[Arm, seq[Point]]
  if braiding:
    let meetings = crossingsOf(routes[Arm.L], routes[Arm.R])
    for i, meeting in meetings:
      # The arm named `over` stays on top at the first meeting, so it is
      # the other one that dives there, and they swap at each one after.
      let under = if (i mod 2 == 0) == (over == some(Arm.L)): Arm.R else: Arm.L
      dives[under].add meeting

  let order = if over == some(Arm.L): [Arm.R, Arm.L] else: [Arm.L, Arm.R]
  for arm in order:
    if holds[arm].isSome:
      let
        pts = routes[arm]
        runs =
          if braiding: cutGapsAt(pts, dives[arm])
          elif over == some(other(arm)): cutGap(pts, routes[other(arm)])
          else: @[pts]
      bits.add twoTone(runs, pts[pts.len div 2], arm, holds[arm].get)
  for arm in Arm:
    let q = p[Dancer.Lead][arm]
    bits.add hand(q.x, q.y, true, arm, holds[arm].isSome, levels[arm], free)
  for own in [Arm.R, Arm.L]:
    let
      q = p[Dancer.Follow][own]
      by = Arm.toSeq.filterIt(holds[it] == some(own))
      level = if by.len > 0: levels[by[0]] else: none(Level)
    bits.add hand(q.x, q.y, false, own, by.len > 0, level, free)
  if captions:
    for arm in Arm:
      bits.add caption(put.place[Dancer.Lead], put.facing[Dancer.Lead], arm,
                       (if arm == Arm.L: "Left" else: "Right"),
                       put.wind[Dancer.Lead][arm])
    for own in [Arm.R, Arm.L]:
      bits.add caption(put.place[Dancer.Follow], put.facing[Dancer.Follow],
                       own, handName(own), put.wind[Dancer.Follow][own])
  bits.filterIt(it.len > 0)


func extent*(pose: Pose; captions = true): float =
  ## Measure how far this pose reaches from the origin, ring and captions
  ## included.
  let edge = if captions: CAPTION_R + 20 else: BODY_R + R + 2
  for who in Dancer:
    result = max(result, hypot(pose.place[who].x, pose.place[who].y) + edge)
  if pose.ring.isSome:
    let (centre, radius) = pose.ring.get
    result = max(result, hypot(centre.x, centre.y) + radius + 4)


func view*(half: float): string =
  ## Write the square viewBox a figure fills.
  &"""viewBox="{n(-half)} {n(-half)} {n(2 * half)} {n(2 * half)}""""


func frame*(cls: string; holds: Holds; levels: Levels = default(Levels);
    over = none(Arm); lead_turn = 0.0; follow_turn = 0.0; free = Free.Fade;
    captions = true; pose = none(Pose); half = none(float);
    ways: Ways = default(Ways); twist: Twists = NO_TWIST;
    clear_marks = false): string =
  ## Draw one picture, canonical unless a pose is handed in already turned.
  let
    drawn = if pose.isSome: pose.get
            else: canonicalise(spinAbout(
              spinAbout(rest(), Dancer.Lead, lead_turn),
              Dancer.Follow, follow_turn))
    box = if half.isSome: half.get
          else: (if captions: WIDE else: SIZE) / 2
    bits = partsOf(drawn, holds, levels, over, free, captions, ways, twist,
                   clear_marks)
  &"""<svg class="{cls}" {view(box)}>""" & "\n        " &
    bits.join("\n        ") & "\n      </svg>"


func series*(steps: seq[float]): string =
  ## Say one animated value's frames on one clock.
  steps.mapIt(n(it)).join(";")

func series*(steps: seq[string]): string =
  ## Say one animated pair's frames on one clock, already written out.
  steps.join(";")


func beat*(t: float): string =
  ## Write one moment of an animation's clock, finely enough to keep the
  ## frames in order.
  ##   Not `n`, which writes a tenth: a whole move is one unit long here, so
  ##     a tenth would collapse whole stages of it into the same instant.
  let written = formatFloat(t, ffDecimal, 4)
  result = written.strip(leading = false, chars = {'0'})
                  .strip(leading = false, chars = {'.'})
  if result.len == 0:
    result = "0"


func keyed*(times: seq[float]; count: int): string =
  ## Say when each frame of an animation is due, where they are not evenly
  ## spread (rule 26).
  ##   Evenly spread is what a browser assumes, so nothing is written for
  ##     it: a move that spends its clock evenly says so by saying nothing,
  ##     and only a move that ranks its stages carries the extra attribute.
  if times.len != count or count < 2:
    return ""
  for i, t in times:
    if abs(t - float(i) / float(count - 1)) > 1e-9:
      return &""" keyTimes="{times.mapIt(beat(it)).join(";")}""""
  ""


func animate*(attr: string; steps: seq[float]; dur: float;
    times: seq[float] = @[]): string =
  ## Animate one attribute over the cycle.
  &"""<animate attributeName="{attr}" values="{series(steps)}"""" &
    keyed(times, steps.len) &
    &""" dur="{dur}s" repeatCount="indefinite"/>"""


func paired*(markup, inner: string): string =
  ## Reopen a self-closing element so it can carry its own animations.
  let tag = markup[1 ..< markup.find(' ')]
  markup[0 .. ^3] & ">" & inner & "</" & tag & ">"


func facings*(poses: seq[Pose]; who: Dancer): seq[float] =
  ## Get a dancer's facing through a cycle, continuous so it turns the way
  ## it turned.
  ##   Wrapped angles step from 179 to -179 at a half turn and are read as
  ##     most of a turn the other way -- a body spinning backwards while its
  ##     own hands, placed absolutely, travel the right way.
  continuous(poses.mapIt(it.facing[who]))


func animatedPoses*(cls: string; holds: Holds; walk: seq[Pose];
    half = none(float); levels: Levels = default(Levels);
    ways: Ways = default(Ways); dur = 9.6; over_all = false;
    times: seq[float] = @[]): string =
  ## Draw one picture moving through a walk of poses handed in.
  ##   Every moving figure comes through here, whether its walk is a whole
  ##     move's cycle or one edge of a state graph rocked back and forth.
  ##   `times` says when each frame is due, for a move that ranks its own
  ##     stages (rule 26); without it the frames are evenly spread, which
  ##     is what a browser does anyway.
  let
    poses = walk.mapIt(settled(it, holds, levels, ways))
    box = if half.isSome: half.get
          else: poses.mapIt(extent(it, captions = false)).max
    hands = poses.mapIt(handsOf(it))

  var bits: seq[string]
  # The ring is drawn only where one is happening.  A move nobody orbits in
  # has no ring at all, rather than a ring of no radius: the mark says
  # *somebody is going round somebody*, and a mark that is always there,
  # invisible, says it of every move.
  if poses.anyIt(it.ring.isSome):
    var ring_cx, ring_cy, ring_r: seq[float]
    for p in poses:
      let ring = p.ring.get((centre: (0.0, 0.0), radius: 0.0))
      ring_cx.add ring.centre.x
      ring_cy.add ring.centre.y
      ring_r.add ring.radius
    bits.add paired(
      &"""<circle cx="0" cy="0" r="0" fill="none" stroke="{QUIET}"""" &
        """ stroke-width="1" stroke-dasharray="3 4"/>""",
      animate("cx", ring_cx, dur, times) & animate("cy", ring_cy, dur, times) &
        animate("r", ring_r, dur, times))

  # A body is rigid: only where it is and which way it faces ever change.  So
  # it is drawn once, at the origin facing up, and carried about by a pair of
  # transforms -- which is exact, and spares the markup a boundary per frame.
  for who in Dancer:
    var still = rest()
    still.place[who] = (0.0, 0.0)
    still.facing[who] = 0.0
    still.wind[who] = poses[0].wind[who]
    let places = poses.mapIt(&"{n(it.place[who].x)} {n(it.place[who].y)}")
    bits.add "<g>" &
      """<animateTransform attributeName="transform" type="translate"""" &
      &""" values="{series(places)}"""" & keyed(times, poses.len) &
      &""" dur="{dur}s" repeatCount="indefinite"/>""" &
      """<animateTransform attributeName="transform" type="rotate"""" &
      &""" additive="sum" values="{series(facings(poses, who))}"""" &
      keyed(times, poses.len) &
      &""" dur="{dur}s" repeatCount="indefinite"/>""" &
      border(still, who) & chevron(still.place[who], still.facing[who]) &
      "</g>"

  # One reach per frame, every frame the same number of points, and -- this
  # is the whole of it -- **one way round both bodies for the entire move**
  # (rule 1).  What a browser draws between two sample frames is the two
  # reaches blended point by point, so two neighbouring frames that disagree
  # about which side of a body the line passes are drawn, in between, as a
  # line sweeping straight through that body.  Only an `above` connection may
  # ever do that.  Settling the way round once, before any frame is routed,
  # makes the disagreement impossible rather than unlikely.  The halves are
  # split at a fixed index, which the even resampling makes the middle of the
  # line, so both shades morph as one shape.
  for arm in Arm:
    if holds[arm].isNone:
      continue
    let site = holds[arm].get
    var frames: seq[route.Ends]
    for i, h in hands:
      frames.add (h[Dancer.Lead][arm], h[Dancer.Follow][site],
                  (poses[i].place[Dancer.Lead],
                   poses[i].facing[Dancer.Lead]),
                  (poses[i].place[Dancer.Follow],
                   poses[i].facing[Dancer.Follow]))
    var routes: seq[seq[Point]]
    if levels[arm] == some(Level.Above) or over_all:
      # Over the head, or over a body that is turning under raised arms:
      # from above nothing is in the way, and nothing hugs (rules 1, 14).
      routes = frames.mapIt(straightReach(it.a, it.b))
    else:
      # A hold that says which way round says it for every frame at once: a
      # slot is fixed relative to its facing, so the direction is too.
      # Where it says nothing, one way is picked for the whole move instead.
      let
        said = wayFor(frames[0], levels[arm], ways[arm])
        way = if said.isSome: said.get else: oneWayRound(frames)
      routes = frames.mapIt(routed(it, some(way)).get.pts)
    let middle = routes[0].len div 2
    for (ink, lo, hi) in [(DEEP[arm], 0, middle), (INK[site], middle,
                          routes[0].high)]:
      var paths: seq[string]
      for pts in routes:
        paths.add "M" & pts[lo .. hi].mapIt(xy(it)).join(" L")
      bits.add paired(
        &"""<path d="{paths[0]}" fill="none" stroke="{ink}"""" &
          &""" stroke-width="{LINK_W}" stroke-linecap="round"""" &
          """ stroke-linejoin="round"/>""",
        &"""<animate attributeName="d" values="{series(paths)}"""" &
          keyed(times, poses.len) &
          &""" dur="{dur}s" repeatCount="indefinite"/>""")

  # A hand's own mark animates its place; a level's dot rides along as its
  # own mark rather than inside it, because `paired` reopens one element
  # and a hand carrying a dot is two.
  func dotOf(pts: seq[Point]; ink: string): string =
    &"""<circle cx="0" cy="0" r="2.7" fill="{ink}">""" &
      animate("cx", pts.mapIt(it.x), dur, times) &
      animate("cy", pts.mapIt(it.y), dur, times) & "</circle>"

  # A moving hand says its level, as a still one does (rule 21): the fill
  # rides on the hand's own mark, so `paired` still has one element to
  # reopen, and only high's dot needs a mark of its own.
  for sd in Arm:
    let pts = hands.mapIt(it[Dancer.Lead][sd])
    bits.add paired(
      hand(pts[0].x, pts[0].y, true, sd, holds[sd].isSome,
           (if levels[sd] == some(Level.High): none(Level) else: levels[sd])),
      animate("x", pts.mapIt(it.x - R), dur, times) &
        animate("y", pts.mapIt(it.y - R), dur, times))
    if holds[sd].isSome and levels[sd] == some(Level.High):
      bits.add dotOf(pts, DEEP[sd])
  for own in [Arm.R, Arm.L]:
    let
      pts = hands.mapIt(it[Dancer.Follow][own])
      by = Arm.toSeq.filterIt(holds[it] == some(own))
      held = by.len > 0
      level = if held: levels[by[0]] else: none(Level)
    bits.add paired(
      hand(pts[0].x, pts[0].y, false, own, held,
           (if level == some(Level.High): none(Level) else: level)),
      animate("cx", pts.mapIt(it.x), dur, times) &
        animate("cy", pts.mapIt(it.y), dur, times))
    if held and level == some(Level.High):
      bits.add dotOf(pts, INK[own])
  &"""<svg class="{cls}" {view(box)}>""" & "\n        " &
    bits.join("\n        ") & "\n      </svg>"


func animated*(cls: string; holds: Holds; move: MoveApply;
    half = none(float); levels: Levels = default(Levels);
    ways: Ways = default(Ways); dur = 9.6; samples = 14;
    over_all = false): string =
  ## Draw the same picture, moving: stage one travels, stage two comes home.
  animatedPoses(cls, holds, cycle(move, samples), half, levels, ways, dur,
                over_all)
