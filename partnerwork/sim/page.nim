## Drive the body sim from a browser, as a way of poking at the constraints.
##
##   The page exists because a still figure cannot settle the question it
##     is drawn to settle.  Turn a body here and the arms take the pose the
##     solver finds; keep turning and a joint runs out, and the page says
##     which.
##   Every control is a number going into the model, and every readout is a
##     number coming out of it.  Nothing on the page is drawn by the page.
##   A drag of a turn slider carries the pose from the last frame by small
##     moves, as the sweeps do, so a wound arm stays wound; and where no
##     small move holds the slider stops there, snapped back to the turn the
##     arms reached, and the page says what blocked it.  A slider asks for a
##     turn; the model has the turn it has reached; the two agree except
##     while the arms are still creeping towards the ask, or at a block.  A
##     pose is never settled afresh mid-turn -- a fresh pose has no memory,
##     and would lay an arm through a body as happily as round it -- except
##     the one re-organisation the sweep allows too, to a pose that goes
##     round the bodies the same way.  Any other change -- a hand joined, a
##     height, the rig -- settles the pose afresh.

{.experimental: "strictFuncs".}

import std/[dom, math, options, strformat, strutils]

import ./[body, draw, limb, read, rig, solve, sweep, vec]


type
  Knob {.pure.} = enum ## The controls, a closed set the arrays index by.
    FollowTurn, LeadTurn, Apart, ArmLength, TorsoRound

  Dial = object ## What one control says and offers.
    name: string
    low, high, step: float
    unit: string


const DIALS: array[Knob, Dial] = [
  Dial(name: "turn the follow", low: -2.0, high: 2.0, step: 0.005,
       unit: " turns"),
  Dial(name: "turn the lead", low: -2.0, high: 2.0, step: 0.005,
       unit: " turns"),
  Dial(name: "stand apart", low: 0.26, high: 1.30, step: 0.005, unit: " m"),
  Dial(name: "reach, shoulder to grip", low: 0.50, high: 0.80, step: 0.005,
       unit: " m"),
  Dial(name: "torso, round", low: 0.70, high: 1.30, step: 0.01,
       unit: " m"),
] ## The rig's own measurements are controls too, deliberately: every answer
  ## this page gives is a fact about those numbers, and a reader who cannot
  ## move them has to take on trust that they matter.


const PAIRS = [
  (name: "L–r", a: Arm.Left, b: Arm.Right),
  (name: "R–l", a: Arm.Right, b: Arm.Left),
  (name: "L–l", a: Arm.Left, b: Arm.Left),
  (name: "R–r", a: Arm.Right, b: Arm.Right),
] ## The four ways one hand can take another.  Named by which hands, since
  ## this page has no vocabulary of frames to name them with.

const BANDS = [("at the chest", Band.Torso), ("at the neck", Band.Neck),
               ("over the head", Band.Crown)]


const
  TURNS = [Knob.LeadTurn, Knob.FollowTurn] ## The two sliders that are carried.
  PER_FRAME = 8 ## Small moves made per frame before the page is redrawn.

var
  dial: array[Knob, float] = [0.0, 0.0, 0.40, 0.64, 0.95] ## For the turns,
    ## the turn the arms have reached.
  wanted: array[Knob, float] = dial ## What the turn sliders ask for.
  joined: array[PAIRS.len, bool] = [true, false, false, false]
  band = Band.Torso
  carried: Option[Solved] ## The last pose, for a turn to carry on from.
  carriedKey = "" ## What that pose was of, so a changed hold settles afresh.
  blocked: Option[Verdict] ## What refused the last small move asked for.
  reseeds = 0 ## How often, since the pose was last settled afresh, the arms
              ## got on by a fresh pose rather than a small move.


func esc(text: string): string =
  text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))


proc chosen(): seq[int] =
  ## List which pairings are joined, in the order the links are built.
  for i in 0 ..< PAIRS.len:
    if joined[i]: result.add i


proc rigNow(): Rig =
  ## The rig as the sliders have it: the reach scales all three links, and
  ## the torso's round is the tape's number.
  result = HUMAN
  let scale = dial[Knob.ArmLength] / reach(HUMAN)
  result.upper = HUMAN.upper * scale
  result.fore = HUMAN.fore * scale
  result.hand = HUMAN.hand * scale
  result.round[Part.Torso] = dial[Knob.TorsoRound]


proc at(lead, follow: float): State =
  ## The world from the controls at these turns, with nothing solved yet.
  let rig = rigNow()
  result = State(rig: rig, stance: facing(rig, max(dial[Knob.Apart], touching(rig))),
                 band: band)
  for i in chosen():
    result.links.add Link(ends: [(Body.One, PAIRS[i].a), (Body.Two, PAIRS[i].b)])
  result.stance = turned(result.stance, Body.One, lead)
  result.stance = turned(result.stance, Body.Two, follow)

proc base(): State =
  ## The world at the turns the arms have reached.
  at(dial[Knob.LeadTurn], dial[Knob.FollowTurn])


proc keyOf(s: State): string =
  ## What a pose is a pose of, apart from the turns.
  result = &"{s.rig.upper}/{s.rig.round[Part.Torso]}/{s.stance[Body.Two].centre.y}/{ord(s.band)}"
  for link in s.links:
    result.add &"/{ord(link.ends[0].arm)}{ord(link.ends[1].arm)}"


func agrees(here: Solved; there: Option[Solved]): bool =
  ## Whether a pose found at the next turn is one the arms can be carried
  ## to from here: it holds, goes round the bodies the same way, and
  ## crosses the same way.
  there.isSome and
    sameRoute(here.state, here.verdict, there.get.state, there.get.verdict) and
    sameCrossings(here.state, here.verdict, there.get.state, there.get.verdict)


proc crept(): bool =
  ## Carry the pose from the turns reached towards the turns wanted, a
  ## small move at a time, a few moves per call; whether it has arrived.
  ##   A move that no small motion reaches is tried once more as the sweep
  ##     tries it, by a fresh search held to the same way round the bodies;
  ##     failing that the ask is pulled back to what was reached, and what
  ##     refused the move is kept for the page to say.
  var moves = 0
  while moves < PER_FRAME:
    let
      dl = wanted[Knob.LeadTurn] - dial[Knob.LeadTurn]
      df = wanted[Knob.FollowTurn] - dial[Knob.FollowTurn]
      far = max(abs(dl), abs(df))
    if far < 1e-9:
      return true
    let
      n = max(1, int(ceil(far / CREEP - 1e-9)))
      lead = dial[Knob.LeadTurn] + dl / n.float
      follow = dial[Knob.FollowTurn] + df / n.float
      next = at(lead, follow)
      here = carried.get
    var got = followed(next, here.state)
    if not agrees(here, got):
      got = settled(next)
      if agrees(here, got):
        inc reseeds
      else:
        blocked = some(reason(next, here.state))
        for k in TURNS: wanted[k] = dial[k]
        return true
    carried = got
    blocked = none(Verdict)
    dial[Knob.LeadTurn] = lead
    dial[Knob.FollowTurn] = follow
    inc moves
  false


proc solved(): tuple[got: Option[Solved], arrived: bool] =
  ## The pose for the controls, with its verdict: carried from the last one
  ## where only a turn has moved, settled afresh otherwise; and whether the
  ## arms have got where the sliders ask, or must go on next frame.
  let s = at(wanted[Knob.LeadTurn], wanted[Knob.FollowTurn])
  if s.links.len == 0:
    carried = none(Solved)
    return (none(Solved), true)
  let key = keyOf(s)
  if carried.isSome and key == carriedKey:
    let arrived = crept()
    return (carried, arrived)
  for k in TURNS: dial[k] = wanted[k]
  blocked = none(Verdict)
  reseeds = 0
  carried = settled(s)
  carriedKey = key
  (carried, true)


func deg(r: float): string = $int(round(r * 180.0 / PI))

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


proc readout(s: State; v: Verdict; on: seq[int]): string =
  ## Say what the model makes of the pose, arm by arm.
  var rows = ""
  for i in 0 ..< v.n:
    for k in 0 .. 1:
      let
        j = v.fits[i].joints[k]
        st = strain(s.rig, j)
        who = whoseName(s, i, k)
        ink = draw.INKS[on[i] mod draw.INKS.len]
      rows.add &"""<tr><td><b style="color: {ink}">{esc(PAIRS[on[i]].name)}</b> {who}</td>""" &
        &"<td>{deg(j.extend)}&deg; / {deg(j.across)}&deg;</td><td>{deg(j.twist)}&deg;</td>" &
        &"<td>{deg(j.bend)}&deg;</td><td>{deg(j.wrist)}&deg;</td>" &
        &"""<td class="{(if st.most >= 1.0: "short" else: "spare")}">{formatFloat(st.most, ffDecimal, 2)} ({dofName(st.dof)})</td>""" &
        &"<td>{lies(lyingOn(s, v, i, (if k == 0: s.links[i].ends[0].body else: s.links[i].ends[1].body)))}</td></tr>"
  var cross = ""
  for c in crossings(s, v):
    cross.add "<li>the connections cross in plan at (" &
      &"{formatFloat(c.at.x, ffDecimal, 2)}, {formatFloat(c.at.y, ffDecimal, 2)}); " &
      &"<b>{esc(PAIRS[on[c.over]].name)}</b> is over</li>"
  &"""<table class="says"><tr><th>arm</th><th>behind / across</th><th>twist</th>""" &
    "<th>elbow</th><th>wrist</th><th>strain</th><th>lies</th></tr>" & rows &
    "</table>" &
    &"""<p class="limit">The pose <b class="{(if v.ok: "spare" else: "short")}">{says(s, v)}</b>; """ &
    &"""the hands are at <b>{formatFloat(s.params[0].g.z, ffDecimal, 2)} m</b>, """ &
    &"""and the couple's twist is <b>{formatFloat(twist(s.stance) / (2.0 * PI), ffDecimal, 2)} turns</b>.""" &
    (if reseeds == 1: " On the way here the arms re-organised once: a fresh pose, the same way round the bodies, where no small move held."
     elif reseeds > 1: &" On the way here the arms re-organised {reseeds} times: fresh poses, the same way round the bodies, where no small move held."
     else: "") &
    (if blocked.isSome: &""" <b class="short">Turning further is blocked here</b>: {says(s, blocked.get)}. The slider stops where the arms do.""" else: "") &
    "</p>" &
    (if cross.len > 0: &"<ul class=\"met\">{cross}</ul>" else: "")


proc mount() =
  ## Put the controls on the page, once.
  ##   Once, and never again, because rebuilding them replaces the very
  ##     slider the pointer is holding.
  var controls = ""
  for knob, d in DIALS:
    controls.add &"""<label class="dial"><span>{d.name}""" &
      &"""<b id="dv{ord(knob)}">{formatFloat(dial[knob], ffDecimal, 3)}{d.unit}</b></span>""" &
      &"""<input type="range" data-dial="{ord(knob)}" min="{d.low}"""" &
      &""" max="{d.high}" step="{d.step}" value="{dial[knob]}"></label>"""
  var picks = ""
  for i, pair in PAIRS:
    picks.add &"""<button id="pk{i}" data-pair="{i}" class="pick"""" &
      &"""" style="--ink: {draw.INKS[i mod draw.INKS.len]}">{pair.name}</button>"""
  var heights = ""
  for i, (name, b) in BANDS:
    heights.add &"""<button id="bd{i}" data-band="{i}" class="pick">{name}</button>"""
  document.getElementById("app").innerHTML = cstring(
    """<div class="stage" id="stage"></div>""" &
    &"""<div class="panel"><div class="picks">{picks}</div>""" &
    &"""<div class="picks">{heights}</div>{controls}""" &
    """<button id="sweep" class="pick">sweep the follow's turn (about three minutes)</button></div>""" &
    """<div class="says-wrap"><div id="says"></div>""" &
    """<div id="limit"></div></div>""")


proc paint()


proc render() =
  ## Redraw what the state says, leaving the controls where they are.
  let on = chosen()
  for knob, d in DIALS:
    document.getElementById(cstring(&"dv{ord(knob)}")).textContent =
      cstring(&"{formatFloat(dial[knob], ffDecimal, 3)}{d.unit}")
  for i, pair in PAIRS:
    document.getElementById(cstring(&"pk{i}")).className =
      cstring(if joined[i]: "pick on" else: "pick")
  for i, (name, b) in BANDS:
    document.getElementById(cstring(&"bd{i}")).className =
      cstring(if b == band: "pick on" else: "pick")
  let (got, arrived) = solved()
  for k in TURNS:
    # The label says where the arms are; the slider is put back there too
    # once they have stopped, so a thumb dragged past a block snaps to it.
    document.getElementById(cstring(&"dv{ord(k)}")).textContent =
      cstring(&"{formatFloat(dial[k], ffDecimal, 3)}{DIALS[k].unit}")
    if arrived:
      let input = cast[InputElement](document.querySelector(cstring(&"input[data-dial=\"{ord(k)}\"]")))
      if input != nil and abs(parseFloat($input.value) - dial[k]) > 1e-9:
        input.value = cstring(formatFloat(dial[k], ffDecimal, 3))
  if not arrived:
    paint()
  if got.isNone:
    document.getElementById("stage").innerHTML = cstring(
      draw.plan(base(), Verdict()) & draw.elevation(base(), Verdict()))
    document.getElementById("says").innerHTML = cstring(
      if on.len == 0: """<p class="none">No hands joined. Nothing to work out.</p>"""
      else: """<p class="none">No pose holds here: no way of laying the arms keeps every joint in its range and every arm out of every body.</p>""")
    return
  let
    s = got.get.state
    v = got.get.verdict
  document.getElementById("stage").innerHTML =
    cstring(draw.plan(s, v) & draw.elevation(s, v))
  document.getElementById("says").innerHTML = cstring(readout(s, v, on))


var pending = false ## Whether a redraw is already booked for the next frame.


proc paint() =
  ## Redraw at most once a frame, however fast the controls are moved; and
  ## again after, while the arms are still creeping towards a slider.
  if pending:
    return
  pending = true
  discard window.requestAnimationFrame(proc (time: float) =
    pending = false
    render())


proc sweepNow() =
  ## Turn the follow from rest until something gives, and say where.
  var s = base()
  if s.links.len == 0:
    return
  s.stance = facing(s.rig, max(dial[Knob.Apart], touching(s.rig)))
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
      &"""<p class="limit">From rest, face to face, with the couple where they stand: turning the follow clockwise <b>{line(sw.neg)}</b>; anticlockwise <b>{line(sw.pos)}</b>. Nothing in the model holds those numbers; they are found by turning until something gives, so they move when the reach or the torso does.</p>"""), 30)


proc handle(event: Event) =
  let target = event.target
  if target == nil:
    return
  if target.getAttribute("data-pair") != nil:
    let which = parseInt($target.getAttribute("data-pair"))
    joined[which] = not joined[which]
    paint()
  elif target.getAttribute("data-band") != nil:
    band = BANDS[parseInt($target.getAttribute("data-band"))][1]
    paint()
  elif $target.getAttribute("id") == "sweep":
    sweepNow()


proc slide(event: Event) =
  let target = event.target
  if target == nil or target.getAttribute("data-dial") == nil:
    return
  let which = Knob(parseInt($target.getAttribute("data-dial")))
  let value = parseFloat($cast[InputElement](target).value)
  if which in TURNS:
    wanted[which] = value
  else:
    dial[which] = value
    wanted[which] = value
  paint()


when isMainModule:
  document.addEventListener("click", handle)
  document.addEventListener("input", slide)
  mount()
  render()
