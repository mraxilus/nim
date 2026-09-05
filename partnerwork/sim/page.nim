## Drive the body sim from a browser, as a way of poking at the constraints.
##
##   The page exists because a still figure cannot settle the question it
##     is drawn to settle.  Turn a body here and the arms take the pose the
##     solver finds; keep turning and a joint runs out, and the page says
##     which.
##   The controls are the dance's freedoms and none of the rig's: which
##     hands are held, at which level, and a quarter turn at a time for
##     either dancer -- on their own axis, or in orbit round their partner,
##     where the walker keeps facing the centre and so turns as far as they
##     travel (the project's rule 32).  The bodies are the average adult's
##     and do not change.  How far apart the couple stand is not a control
##     either: they stand, and go on standing as they turn, wherever the
##     joints are furthest from their limits -- stepping in or out a
##     centimetre at a time whenever that leaves the arms freer.
##   A quarter is walked in small moves, as the sweeps walk a turn, so a
##     wound arm stays wound; where no small move holds the turn stops
##     there, the tally shows how far it got, and the page says what
##     blocked it.  A pose is never settled afresh mid-turn -- a fresh pose
##     has no memory, and would lay an arm through a body as happily as
##     round it -- except the one re-organisation the sweep allows too, to a
##     pose that goes round the bodies the same way.  Changing the hands or
##     the level settles the pose afresh, face to face.
##   The levels carry the sheet's names -- low, high, above -- which is the
##     one translation this page makes, as `sim/verdicts` makes it; the
##     model underneath knows only the torso, the neck and the crown.

{.experimental: "strictFuncs".}

import std/[dom, math, options, strformat, strutils]

import ./[body, draw, limb, read, rig, solve, sweep, vec]


type
  Hold = object ## One way of holding hands: which of his to which of hers.
    name: string
    links: seq[tuple[a, b: Arm]] ## The lead's hand, the follow's hand.
    away: bool ## Rests with the follow turned away: its connections lie
               ## through each other face to face.

  Way {.pure.} = enum ## The four ways a quarter can be turned.
    LeadAxis, FollowAxis, FollowOrbit, LeadOrbit

  Move = object ## One quarter, one way, one sense.
    way: Way
    sign: float ## Anticlockwise seen from above positive.


const
  HOLDS = [
    Hold(name: "L–l", links: @[(Arm.Left, Arm.Left)]),
    Hold(name: "R–r", links: @[(Arm.Right, Arm.Right)]),
    Hold(name: "L–r", links: @[(Arm.Left, Arm.Right)]),
    Hold(name: "R–l", links: @[(Arm.Right, Arm.Left)]),
    Hold(name: "L–l · R–r", links: @[(Arm.Left, Arm.Left), (Arm.Right, Arm.Right)], away: true),
    Hold(name: "L–r · R–l", links: @[(Arm.Left, Arm.Right), (Arm.Right, Arm.Left)]),
  ] ## The base set: the lead's hand first, in capitals, the follow's after.
  LEVELS = [("low", Band.Torso), ("high", Band.Neck), ("above", Band.Crown)]
  WAYS: array[Way, string] = ["lead turns", "follow turns",
                              "follow orbits the lead", "lead orbits the follow"]
  QUARTER = 0.25 ## Turns per press.
  REST_APART = 0.40 ## Where the couple stand before the arms have a say.
  APART_STEP = 0.01 ## How far they step in or out at a time.
  APART_MOST = 0.90 ## Further than this no hold reaches anyway.
  PER_FRAME = 8 ## Small moves made per frame before the page is redrawn.
  SHIFTS = 3 ## Steps in or out tried after each small move of a turn.
  SETTLING_SHIFTS = 40 ## And from a fresh rest, before the first turn.


var
  hold = 2 ## Into `HOLDS`.
  level = 0 ## Into `LEVELS`.
  carried: Option[Solved] ## The pose the arms are in, where the bodies are.
  carriedKey = "" ## What that pose is of, so a changed hold settles afresh.
  restApart = REST_APART ## Where the couple stood at the last fresh rest.
  tally: array[Way, float] ## Turns made each way since the rest, signed.
  inFlight: Option[Move] ## The quarter being walked, if one is.
  done = 0.0 ## How much of it has been walked, nought to one.
  blocked: Option[Verdict] ## What refused the last small move asked for.
  reseeds = 0 ## Fresh poses taken since the rest where no small move held.


func esc(text: string): string =
  text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))


#[ The World ]#


proc world(apart = REST_APART): State =
  ## The hold at rest, face to face -- or the follow away, where the hold
  ## rests so -- with nothing solved yet.
  let h = HOLDS[hold]
  result = State(rig: HUMAN, stance: facing(HUMAN, apart), band: LEVELS[level][1])
  if h.away:
    result.stance[Body.Two].facing = result.stance[Body.Two].facing - PI
  for (a, b) in h.links:
    result.links.add Link(ends: [(Body.One, a), (Body.Two, b)])

func keyOf(s: State): string =
  ## What a pose is a pose of, apart from where the bodies are.
  result = &"{ord(s.band)}"
  for link in s.links:
    result.add &"/{ord(link.ends[0].arm)}{ord(link.ends[1].arm)}"

func apartOf(st: array[Body, Stance]): float =
  let
    dx = st[Body.Two].centre.x - st[Body.One].centre.x
    dy = st[Body.Two].centre.y - st[Body.One].centre.y
  sqrt(dx * dx + dy * dy)

func withStance(s: State; st: array[Body, Stance]): State =
  result = s
  result.stance = st

func orbited(st: array[Body, Stance]; who: Body; by: float): array[Body, Stance] =
  ## `who` walked round their partner by `by` radians, keeping whatever
  ## side of them faced the centre facing it: their facing turns as far as
  ## they travel (rule 32).
  let
    pivot = st[if who == Body.One: Body.Two else: Body.One].centre
    dx = st[who].centre.x - pivot.x
    dy = st[who].centre.y - pivot.y
    c = cos(by)
    s = sin(by)
  result = st
  result[who].centre = (pivot.x + dx * c - dy * s, pivot.y + dx * s + dy * c)
  result[who].facing = st[who].facing + by

func stanceAfter(st: array[Body, Stance]; m: Move; frac: float): array[Body, Stance] =
  ## The bodies after `frac` of a quarter the move's way.
  let turns = m.sign * frac * QUARTER
  case m.way
  of Way.LeadAxis: turned(st, Body.One, turns)
  of Way.FollowAxis: turned(st, Body.Two, turns)
  of Way.FollowOrbit: orbited(st, Body.Two, turns * 2.0 * PI)
  of Way.LeadOrbit: orbited(st, Body.One, turns * 2.0 * PI)

func shifted(st: array[Body, Stance]; by: float): array[Body, Stance] =
  ## The follow moved `by` metres away from the lead along the line between
  ## their axes, the lead standing still.
  let
    apart = apartOf(st)
    ux = (st[Body.Two].centre.x - st[Body.One].centre.x) / apart
    uy = (st[Body.Two].centre.y - st[Body.One].centre.y) / apart
  result = st
  result[Body.Two].centre = (st[Body.Two].centre.x + ux * by,
                             st[Body.Two].centre.y + uy * by)


#[ Carrying ]#


func agrees(here: Solved; there: Option[Solved]): bool =
  ## Whether a pose found at the next stance is one the arms can be carried
  ## to from here: it holds, goes round the bodies the same way, and
  ## crosses the same way.
  there.isSome and
    sameRoute(here.state, here.verdict, there.get.state, there.get.verdict) and
    sameCrossings(here.state, here.verdict, there.get.state, there.get.verdict)

func roomOf(rig: Rig; v: Verdict): float =
  ## The least room any held arm's joints have, either way.
  result = Inf
  for i in 0 ..< v.n:
    for k in 0 .. 1:
      result = min(result, room(rig, v.fits[i].joints[k]))

func freer(rig: Rig; a, b: Verdict): bool =
  ## Whether `a` leaves the joints freer than `b`: the nearest joint further
  ## from either end of its range first, and more comfortable where that
  ## is equal.
  ##   Freedom, not comfort, is what the stance is chosen for: a couple who
  ##     stood where the arms hang easiest would stand at arm's length with
  ##     the elbows straight, and a straight elbow is a joint with nowhere
  ##     to go.
  let
    ra = roomOf(rig, a)
    rb = roomOf(rig, b)
  if abs(ra - rb) > 1e-9: ra > rb
  else: a.cost < b.cost - 1e-9


proc steppedIn(here: var Solved): bool =
  ## Step the couple in or out by one step where that leaves the arms
  ## freer; whether they did.
  ##   Each way is first judged cheaply -- the pose as it is, with the
  ##     bodies moved -- and only the way that promises is followed for
  ##     real, and taken only if it delivers.
  let
    apart = apartOf(here.state.stance)
    least = touching(here.state.rig) + 0.02
  var
    best = here.verdict
    by = 0.0
  for step in [-APART_STEP, APART_STEP]:
    if apart + step < least or apart + step > APART_MOST:
      continue
    let guess = evaluate(withStance(here.state, shifted(here.state.stance, step)))
    if freer(here.state.rig, guess, best):
      best = guess
      by = step
  if by == 0.0:
    return false
  let got = followed(withStance(here.state, shifted(here.state.stance, by)), here.state)
  if agrees(here, got) and freer(here.state.rig, got.get.verdict, here.verdict):
    here = got.get
    return true
  false


proc settleFresh() =
  ## The hold at rest, solved from nothing, and the couple stepped in or
  ## out from there until the arms are as free as they get.
  let s = world()
  carried = settled(s)
  carriedKey = keyOf(s)
  for w in Way: tally[w] = 0.0
  inFlight = none(Move)
  done = 0.0
  blocked = none(Verdict)
  reseeds = 0
  if carried.isSome:
    var here = carried.get
    for i in 0 ..< SETTLING_SHIFTS:
      if not steppedIn(here):
        break
    carried = some(here)
    restApart = apartOf(here.state.stance)


proc walked(): bool =
  ## Walk the quarter in flight on by a few small moves; whether it has
  ## arrived or stopped.
  ##   A small move that no small motion reaches is tried once more as the
  ##     sweep tries it, by a fresh search held to the same way round the
  ##     bodies; failing that the quarter stops where it got to, and what
  ##     refused the move is kept for the page to say.
  if inFlight.isNone or carried.isNone:
    return true
  let m = inFlight.get
  var moves = 0
  while moves < PER_FRAME:
    if done >= 1.0 - 1e-9:
      inFlight = none(Move)
      return true
    let
      here = carried.get
      frac = min(1.0, done + CREEP / QUARTER)
      next = withStance(here.state, stanceAfter(here.state.stance, m, frac - done))
    var got = followed(next, here.state)
    if not agrees(here, got):
      got = settled(next)
      if agrees(here, got):
        inc reseeds
      else:
        blocked = some(reason(next, here.state))
        inFlight = none(Move)
        return true
    var now = got.get
    tally[m.way] += m.sign * (frac - done) * QUARTER
    done = frac
    blocked = none(Verdict)
    for i in 0 ..< SHIFTS:
      if not steppedIn(now):
        break
    carried = some(now)
    inc moves
  false


#[ Words ]#


func deg(r: float): string = $int(round(r * 180.0 / PI))

func turns(x: float): string = formatFloat(x, ffDecimal, 2)

func whoseName(s: State; link, arm: int): string =
  if s.links[link].ends[arm].body == Body.One: "the lead" else: "the follow"

func dofName(dof: Dof): string =
  case dof
  of Dof.Extend: "shoulder, behind"
  of Dof.Across: "shoulder, across"
  of Dof.Twist: "shoulder, twist"
  of Dof.Bend: "elbow"
  of Dof.Wrist: "wrist"

func says(s: State; v: Verdict): string =
  ## Say what refuses, in words rather than a name.
  case v.reason
  of Reason.None: "holds"
  of Reason.Reach: whoseName(s, v.link, v.arm) & "'s reach"
  of Reason.Shoulder, Reason.Twist, Reason.Elbow, Reason.Wrist:
    whoseName(s, v.link, v.arm) & "'s " & dofName(v.dof)
  of Reason.Through:
    let part = case v.part
      of Part.Torso: "torso"
      of Part.Neck: "neck"
      of Part.Head: "head"
    whoseName(s, v.link, v.arm) & "'s arm through " &
      (if v.whose == Body.One: "the lead's " else: "the follow's ") & part
  of Reason.Arms: "arm through arm"
  of Reason.Band: "the hands out of their height"

func lies(l: Option[Lying]): string =
  ## Where an arm lies on its own body, in the body's words.
  if l.isNone:
    return "out in front"
  (if l.get.aspect == Aspect.Fore: "across the front" else: "behind the back") &
    (if l.get.pressing: ", pressing" else: ", clear of the body") &
    (if l.get.elbowFore: ", elbow forward" else: "")

proc linkName(i: int): string =
  ## Which hands connection `i` of the hold joins.
  let (a, b) = HOLDS[hold].links[i]
  (if a == Arm.Left: "L" else: "R") & "–" & (if b == Arm.Left: "l" else: "r")


proc readout(s: State; v: Verdict): string =
  ## Say what the model makes of the pose, arm by arm, and where the couple
  ## have got to.
  var rows = ""
  for i in 0 ..< v.n:
    for k in 0 .. 1:
      let
        j = v.fits[i].joints[k]
        st = strain(s.rig, j)
        who = whoseName(s, i, k)
        ink = draw.INKS[i mod draw.INKS.len]
      rows.add &"""<tr><td><b style="color: {ink}">{esc(linkName(i))}</b> {who}</td>""" &
        &"<td>{deg(j.extend)}&deg; / {deg(j.across)}&deg;</td><td>{deg(j.twist)}&deg;</td>" &
        &"<td>{deg(j.bend)}&deg;</td><td>{deg(j.wrist)}&deg;</td>" &
        &"""<td class="{(if st.most >= 1.0: "short" else: "spare")}">{formatFloat(st.most, ffDecimal, 2)} ({dofName(st.dof)})</td>""" &
        &"<td>{lies(lyingOn(s, v, i, s.links[i].ends[k].body))}</td></tr>"
  var cross = ""
  for c in crossings(s, v):
    cross.add "<li>the connections cross in plan at (" &
      &"{formatFloat(c.at.x, ffDecimal, 2)}, {formatFloat(c.at.y, ffDecimal, 2)}); " &
      &"<b>{esc(linkName(c.over))}</b> is over</li>"
  var made = ""
  for w in Way:
    if abs(tally[w]) > 1e-9:
      made.add (if made.len > 0: ", " else: "") & &"{WAYS[w]} <b>{turns(tally[w])}</b>"
  if made.len == 0:
    made = if HOLDS[hold].away: "at rest, the follow turned away" else: "at rest, face to face"
  &"""<table class="says"><tr><th>arm</th><th>behind / across</th><th>twist</th>""" &
    "<th>elbow</th><th>wrist</th><th>strain</th><th>lies</th></tr>" & rows &
    "</table>" &
    &"""<p class="limit"><b>{esc(HOLDS[hold].name)}</b>, {LEVELS[level][0]}: {made}; """ &
    &"""the couple's twist is <b>{turns(twist(s.stance) / (2.0 * PI))} turns</b>, """ &
    &"""they stand <b>{turns(apartOf(s.stance))} m</b> apart, and the hands are at <b>{turns(s.params[0].g.z)} m</b>. """ &
    &"""The pose <b class="{(if v.ok: "spare" else: "short")}">{says(s, v)}</b>.""" &
    (if reseeds > 0: &" On the way here the arms re-organised {(if reseeds == 1: \"once\" else: $reseeds & \" times\")}: a fresh pose, the same way round the bodies, where no small move held." else: "") &
    (if blocked.isSome: &""" <b class="short">Turning further is blocked here</b>: {says(s, blocked.get)}. The turn stops where the arms do.""" else: "") &
    "</p>" &
    (if cross.len > 0: &"<ul class=\"met\">{cross}</ul>" else: "")


#[ The Page ]#


proc mount() =
  ## Put the controls on the page, once.
  var holds = ""
  for i, h in HOLDS:
    holds.add &"""<button id="hd{i}" data-hold="{i}" class="pick">{esc(h.name)}</button>"""
  var levels = ""
  for i, (name, b) in LEVELS:
    levels.add &"""<button id="lv{i}" data-level="{i}" class="pick">{name}</button>"""
  var turns = ""
  for w in Way:
    turns.add &"""<div class="picks"><span class="way">{WAYS[w]}</span>""" &
      &"""<button data-way="{ord(w)}" data-sign="1" class="pick turn" title="a quarter, anticlockwise seen from above">&#x21BA; &frac14;</button>""" &
      &"""<button data-way="{ord(w)}" data-sign="-1" class="pick turn" title="a quarter, clockwise seen from above">&frac14; &#x21BB;</button></div>"""
  document.getElementById("app").innerHTML = cstring(
    """<div class="stage" id="stage"></div>""" &
    &"""<div class="panel"><div class="picks">{holds}</div>""" &
    &"""<div class="picks">{levels}</div>{turns}""" &
    """<div class="picks"><button id="reset" class="pick">face to face again</button></div>""" &
    """<button id="sweep" class="pick">sweep the follow's turn (about three minutes)</button></div>""" &
    """<div class="says-wrap"><div id="says"></div>""" &
    """<div id="limit"></div></div>""")


proc paint()


proc render() =
  ## Redraw what the state says, leaving the controls where they are.
  for i, h in HOLDS:
    document.getElementById(cstring(&"hd{i}")).className =
      cstring(if i == hold: "pick on" else: "pick")
  for i, (name, b) in LEVELS:
    document.getElementById(cstring(&"lv{i}")).className =
      cstring(if i == level: "pick on" else: "pick")
  if carried.isNone or carriedKey != keyOf(world()):
    settleFresh()
  let arrived = walked()
  let turning = document.querySelectorAll("button.turn")
  for i in 0 ..< turning.len:
    let b = cast[Element](turning[i])
    if arrived: b.removeAttribute("disabled")
    else: b.setAttribute("disabled", "")
  if not arrived:
    paint()
  if carried.isNone:
    let s = world()
    document.getElementById("stage").innerHTML = cstring(
      draw.plan(s, Verdict()) & draw.elevation(s, Verdict()))
    document.getElementById("says").innerHTML = cstring(
      """<p class="none">No pose holds here: no way of laying the arms keeps every joint in its range and every arm out of every body.</p>""")
    return
  let
    s = carried.get.state
    v = carried.get.verdict
  document.getElementById("stage").innerHTML =
    cstring(draw.plan(s, v) & draw.elevation(s, v))
  document.getElementById("says").innerHTML = cstring(readout(s, v))


var pending = false ## Whether a redraw is already booked for the next frame.


proc paint() =
  ## Redraw at most once a frame, however fast the controls are pressed;
  ## and again after, while a quarter is still being walked.
  if pending:
    return
  pending = true
  discard window.requestAnimationFrame(proc (time: float) =
    pending = false
    render())


proc sweepNow() =
  ## Turn the follow from rest until something gives, and say where.
  ##   From the rest the page found: face to face, at the distance the
  ##     couple settled to there, which the sweep then keeps.
  let s = world(restApart)
  document.getElementById("limit").innerHTML = cstring(
    """<p class="limit">Sweeping&hellip; a fiftieth of a turn at a time, each way, until a joint runs out. In a browser this takes about three minutes.</p>""")
  discard setTimeout(proc () =
    let sw = swept(s, Body.Two, most = 1.5)
    if not sw.restHolds:
      document.getElementById("limit").innerHTML = cstring(
        """<p class="limit">No pose holds at the rest, so there is nothing to turn.</p>""")
      return
    func line(b: Block): string =
      if not b.stopped: "no block within a turn and a half"
      else: &"blocks at {formatFloat(b.at, ffDecimal, 2)} turns: {says(sw.rest, b.why)}" &
        (if b.foundAnyway: " (a pose holds a step beyond, but not one the arms can reach)" else: "")
    document.getElementById("limit").innerHTML = cstring(
      &"""<p class="limit">From rest, face to face, standing {turns(restApart)} m apart: turning the follow clockwise <b>{line(sw.neg)}</b>; anticlockwise <b>{line(sw.pos)}</b>. Nothing in the model holds those numbers; they are found by turning until something gives.</p>"""), 30)


proc handle(event: Event) =
  let target = event.target
  if target == nil:
    return
  if target.getAttribute("data-hold") != nil:
    hold = parseInt($target.getAttribute("data-hold"))
    carried = none(Solved)
    paint()
  elif target.getAttribute("data-level") != nil:
    level = parseInt($target.getAttribute("data-level"))
    carried = none(Solved)
    paint()
  elif target.getAttribute("data-way") != nil:
    if inFlight.isNone and carried.isSome:
      inFlight = some(Move(way: Way(parseInt($target.getAttribute("data-way"))),
                           sign: parseFloat($target.getAttribute("data-sign"))))
      done = 0.0
      blocked = none(Verdict)
      paint()
  elif $target.getAttribute("id") == "reset":
    carried = none(Solved)
    paint()
  elif $target.getAttribute("id") == "sweep":
    sweepNow()


when isMainModule:
  document.addEventListener("click", handle)
  mount()
  render()
