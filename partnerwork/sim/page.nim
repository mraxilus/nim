## Drive the body sim from a browser, as a way of poking at the constraints.
##
##   The page exists because a still figure could not settle the question it
##     was drawn to settle.  Turn a body here and the rope winds where the
##     solver puts it; keep turning and it runs out, and says so.
##   Every control is a number going into the model, and every readout is a
##     number coming out of it.  Nothing on the page is drawn by the page.
##   The whole state is rebuilt from the controls on every change -- the turn
##     replayed from rest each time -- so what is on screen depends on where
##     the sliders are and not at all on how they got there.

{.experimental: "strictFuncs".}

import std/[dom, math, options, strformat, strutils]

import ./[draw, rope]


type Dial = object ## One control, and where its value lives.
  key: string
  name: string
  low, high, step: float
  unit: string


const DIALS = [
  Dial(key: "turn2", name: "turn the follow", low: -2.0, high: 2.0,
       step: 0.01, unit: " turns"),
  Dial(key: "turn1", name: "turn the lead", low: -2.0, high: 2.0,
       step: 0.01, unit: " turns"),
  Dial(key: "apart", name: "stand apart", low: 0.32, high: 1.30,
       step: 0.005, unit: " m"),
  Dial(key: "height", name: "raise the joined hands", low: 1.40, high: 2.05,
       step: 0.005, unit: " m"),
  Dial(key: "arm", name: "arm", low: 0.45, high: 0.85, step: 0.005,
       unit: " m"),
  Dial(key: "torso", name: "torso, radius", low: 0.10, high: 0.26,
       step: 0.005, unit: " m"),
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


var
  dial: array[DIALS.len, float] = [0.0, 0.0, 0.40, 1.40, 0.62, 0.16]
  joined: array[PAIRS.len, bool] = [true, false, false, false]


proc valueOf(key: string): float =
  for i, d in DIALS:
    if d.key == key: return dial[i]
  0.0


proc chosen(): seq[int] =
  ## List which pairings are joined, in the order the links are built.
  ##   The links are only the pairings that are on, so a link's place in the
  ##     list is not its pairing's.  Reading a name or a colour off the link
  ##     index labelled the second rope as whichever pairing happened to sit
  ##     second in the menu, which is a caption that quietly lies.
  for i in 0 ..< PAIRS.len:
    if joined[i]: result.add i


proc built(): State =
  ## Build the whole world from where the controls stand.
  var rig = HUMAN
  rig.arm = valueOf("arm")
  rig.torso = valueOf("torso")
  var base = facing(rig, max(valueOf("apart"), touching(rig)))
  for i, pair in PAIRS:
    if joined[i]:
      base.links.add Link(ends: [(Body.One, pair.a), (Body.Two, pair.b)],
                          height: max(valueOf("height"), rig.shoulder))
  # Replayed from rest, both turns, so the picture is a function of the
  # sliders and not of the order they were dragged in.
  result = turned(settled(base), Body.One, valueOf("turn1") * 2.0 * PI)
  result = turned(result, Body.Two, valueOf("turn2") * 2.0 * PI)


func esc(text: string): string =
  text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))


func says(fault: Option[Fault]): string =
  ## Say what refuses a connection, in words rather than a name.
  if fault.isNone:
    return "holds"
  case fault.get
  of Fault.Tangent: "cannot be laid"
  of Fault.Through: "passes through a body"
  of Fault.Budget: "wants more rope than there is"


func readout(state: State; inks: seq[int]): string =
  ## Say what the model makes of the state, connection by connection.
  if state.links.len == 0:
    return """<p class="none">No hands joined. Nothing to work out.</p>"""
  var rows = ""
  for index, link in state.links:
    let
      laid = lay(state, link)
      fault = faultOf(state, link)
      ink = draw.INKS[inks[index] mod draw.INKS.len]
    var winds = "none"
    if link.winds.len > 0:
      winds = ""
      for w in link.winds:
        let laps = w.turns
        winds.add (if winds.len > 0: ", " else: "") &
          (if w.body == Body.One: "lead" else: "follow") &
          (if laps > 0: &" +{laps} whole" else: "")
    var cells = &"""<td><b style="color: {ink}">""" &
      &"""{esc(PAIRS[inks[index]].name)}</b></td>"""
    if laid.isSome:
      let
        spent = laid.get.length
        room = budget(state.rig) - spent
      cells.add &"<td>{m(spent)} m</td><td>{m(budget(state.rig))} m</td>" &
        &"""<td class="{(if room < 0: "short" else: "spare")}">{m(room)} m</td>""" &
        &"<td>{winds}</td><td>" & (
          if link.height > state.rig.crown: "over both heads"
          elif link.winds.len > 0: "on the rim"
          else: m(clearance(state, link, laid.get)) & " m") & "</td>"
    else:
      cells.add "<td>&mdash;</td><td>&mdash;</td><td>&mdash;</td>" &
        &"<td>{winds}</td><td>&mdash;</td>"
    cells.add &"""<td class="{(if fault.isSome: "short" else: "spare")}">""" &
      &"{says(fault)}</td>"
    rows.add &"<tr>{cells}</tr>"
  var met = ""
  for i in 0 ..< state.links.len:
    for j in i + 1 ..< state.links.len:
      let
        a = lay(state, state.links[i])
        b = lay(state, state.links[j])
      if a.isNone or b.isNone:
        continue
      for one in meetings(state, state.links[i], a.get, state.links[j], b.get):
        let top = overOf(state.rig, one)
        met.add "<li>" & (
          if top.isNone:
            &"{esc(PAIRS[inks[i]].name)} and " &
              &"{esc(PAIRS[inks[j]].name)} cross within an " &
              "arm's thickness &mdash; which is over is not settled by the " &
              "geometry, and the dancers must choose"
          else:
            &"<b>{esc(PAIRS[inks[(if top.get == 0: i else: j)]].name)}" &
              &"</b> passes over " &
              &"{esc(PAIRS[inks[(if top.get == 0: j else: i)]].name)}, by " &
              &"{m(abs(one.high[0] - one.high[1]))} m") & "</li>"
  &"""<table class="says"><tr><th>rope</th><th>taut</th><th>has</th>""" &
    "<th>spare</th><th>wound on</th><th>clears</th><th></th></tr>" &
    rows & "</table>" &
    (if met.len > 0: &"<ul class=\"met\">{met}</ul>" else: "")


func limits(state: State): string =
  ## Say how far the follow could turn from rest before the rope refuses.
  ##   Swept on the spot, from the rig as the sliders have it: the number is
  ##     not held anywhere, it is found by turning until something gives.
  var base = state
  base.stance[Body.One].facing = PI / 2
  base.stance[Body.Two].facing = -PI / 2
  for i in 0 ..< base.links.len:
    base.links[i].winds = @[]
  if base.links.len == 0:
    return ""
  let got = windLimit(settled(base), Body.Two, most = 6.0 * PI, step = 0.05)
  &"""<p class="limit">From rest, and with the couple where they stand, the """ &
    &"""follow can turn <b>{m(got / (2.0 * PI))} turns</b> """ &
    &"""({m(got / PI)} half turns) before some rope runs out. Nothing in the """ &
    """model holds that number &mdash; it is found by turning until """ &
    """something gives, so it moves when the arm or the torso does.</p>"""


proc render() =
  ## Rebuild the page from the controls.
  let
    state = built()
    on = chosen()
  var controls = ""
  for i, d in DIALS:
    controls.add &"""<label class="dial"><span>{d.name}""" &
      &"""<b>{m(dial[i])}{d.unit}</b></span>""" &
      &"""<input type="range" data-dial="{i}" min="{d.low}" max="{d.high}"""" &
      &""" step="{d.step}" value="{dial[i]}"></label>"""
  var picks = ""
  for i, pair in PAIRS:
    picks.add &"""<button data-pair="{i}" class="pick{(if joined[i]: " on" else: "")}"""" &
      &"""" style="--ink: {draw.INKS[i mod draw.INKS.len]}">{pair.name}</button>"""
  document.getElementById("app").innerHTML = cstring(
    &"""<div class="stage">{draw.plan(state, on)}{draw.elevation(state, on)}</div>""" &
    &"""<div class="panel"><div class="picks">{picks}</div>{controls}</div>""" &
    &"""<div class="says-wrap">{readout(state, on)}{limits(state)}</div>""")


proc handle(event: Event) =
  let target = event.target
  if target == nil or target.getAttribute("data-pair") == nil:
    return
  let which = parseInt($target.getAttribute("data-pair"))
  joined[which] = not joined[which]
  render()


proc slide(event: Event) =
  let target = event.target
  if target == nil or target.getAttribute("data-dial") == nil:
    return
  # The property, not the attribute: dragging a range moves `value` and
  # leaves the `value=` it was written with exactly where it was, so reading
  # the attribute gives the starting number for ever.
  let which = parseInt($target.getAttribute("data-dial"))
  dial[which] = parseFloat($cast[InputElement](target).value)
  render()


when isMainModule:
  document.addEventListener("click", handle)
  document.addEventListener("input", slide)
  render()
