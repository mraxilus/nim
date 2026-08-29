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


const
  HIGH_LOW = 1.40  ## The lowest a pair of joined hands is offered.
  HIGH_HIGH = 2.05 ## And the highest, which is well over a crown.
  HIGH_STEP = 0.005


var
  dial: array[DIALS.len, float] = [0.0, 0.0, 0.40, 0.62, 0.16]
  joined: array[PAIRS.len, bool] = [true, true, false, false]
  high: array[PAIRS.len, float] = [1.82, 1.82, 1.82, 1.82]
    ## One height per connection, not one for all of them.
    ##   Two hands joined at one height and two at another is an ordinary
    ##     thing to do, and the model was always ready for it: `Link.height`
    ##     is per connection and every reading of it is per connection.  Only
    ##     this page tied them together, through a single slider written into
    ##     every link.
    ##   They start over both crowns, because that is where the braid has
    ##     nothing in the way of it and the twist can be looked at on its own.


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
                          height: max(high[i], rig.shoulder))
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
  of Fault.Braided: "passes through the other rope"
  of Fault.Swan: "twisted past the swan"


func rung(crossings: int): string =
  ## Name the rung of the ladder a braid is standing on.
  ##   Named by the crossings that are actually there, counted off the drawn
  ##     ropes, rather than by the angle turned.  A hold that joins hands of
  ##     the same name starts already crossed, so it starts a rung up -- which
  ##     falls out of counting and would have to be special-cased if the name
  ##     came from the turn.
  case crossings
  of 0: "no twist"
  of 1: "the X, one over the other"
  of 2: "the diamond"
  of 3: "the swan"
  else: "past the swan"


func braid(state: State): string =
  ## Say what the two connections are doing to each other.
  if state.links.len != 2:
    return ""
  let
    a = lay(state, state.links[0])
    b = lay(state, state.links[1])
  if a.isNone or b.isNone:
    return ""
  let
    met = meetings(state, state.links[0], a.get, state.links[1], b.get)
    turns = twist(state) / (2.0 * PI)
  &"""<p class="limit">The two connections are twisted <b>{m(turns)} """ &
    &"""turns</b> against each other and cross <b>{met.len}</b> """ &
    (if met.len == 1: "time. " else: "times. ") &
    (if not braiding(state):
       "A body has got in between, so the two are not braiding here &mdash; " &
         "the winding governs, and this model does not do both at once, so " &
         "the ladder is not being climbed."
     elif braidedLie(a.get) and braidedLie(b.get):
       &"""They are braiding: <b>{rung(met.len)}</b>. Where they cross, the """ &
         "geometry says which is over, and the under one is drawn broken."
     else:
       "Square on, so the braid is a braid of nothing and the two ropes run " &
         "straight past each other. Turn a body and they begin to wind " &
         "about one another.") &
    """</p>"""


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
      cells.add &"<td>{m(link.height)} m</td>" &
        &"<td>{m(spent)} m</td><td>{m(budget(state.rig))} m</td>" &
        &"""<td class="{(if room < 0: "short" else: "spare")}">{m(room)} m</td>""" &
        &"<td>{winds}</td><td>" & (
          if braidedLie(laid.get): "braided"
          elif link.height > state.rig.crown: "over both heads"
          elif link.winds.len > 0: "on the rim"
          else: m(clearance(state, link, laid.get)) & " m") & "</td>"
    else:
      cells.add &"<td>{m(link.height)} m</td>" &
        "<td>&mdash;</td><td>&mdash;</td><td>&mdash;</td>" &
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
  &"""<table class="says"><tr><th>rope</th><th>hands at</th><th>taut</th>""" &
    "<th>has</th><th>spare</th><th>wound on</th><th>lies</th><th></th></tr>" &
    rows & "</table>" & braid(state) &
    (if met.len > 0: &"<ul class=\"met\">{met}</ul>" else: "")


var
  limitFor = ""  ## The state the standing limit below was worked out for.
  limitSaid = "" ## And what it came to, kept so a turn drag need not ask again.


proc limits(state: State): string =
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
  # The sweep starts from rest, so it cannot depend on either turn -- which is
  # the slider being dragged.  Asking it again for every frame of a drag was
  # the whole of what made this page slow, and it is still the dearest thing
  # on it, so it is asked only when one of its own inputs moves.
  var key = &"{base.rig.arm}/{base.rig.torso}/{base.stance[Body.Two].centre.y}"
  for link in base.links:
    key.add &"/{ord(link.ends[0].arm)}{ord(link.ends[1].arm)}:{link.height}"
  if key == limitFor:
    return limitSaid
  let
    rested = settled(base)
    got = windLimit(rested, Body.Two, most = 6.0 * PI, swan = false)
  limitFor = key
  limitSaid = &"""<p class="limit">From rest, and with the couple where they """ &
    """stand, the follow can turn """ &
    &"""<b>{m(got / (2.0 * PI))} turns</b> ({m(got / PI)} half turns) """ &
    """before some rope runs out or two ropes meet. Nothing in the model """ &
    """holds that number &mdash; it is found by turning until something """ &
    """gives, so it moves when the arm or the torso does.""" &
    (if base.links.len < 2: "</p>"
     else:
       &""" The dance says a pair may twist to the swan and no further, """ &
         &"""which is <b>{m(state.rig.swan)} turns</b> each way. <b>That """ &
         """number is asserted, not derived</b> &mdash; it is a report of """ &
         """what dancers manage, and it is kept beside the swept one rather """ &
         """than folded into it, so the two can disagree in the open. """ &
         (if got >= state.rig.swan * 2.0 * PI - 1e-9:
            "Here the geometry reaches it."
          else:
            "Here the geometry falls short of it: lengthen the arm or " &
              "narrow the torso and watch where the two meet.") & "</p>")
  limitSaid


proc mount() =
  ## Put the controls on the page, once.
  ##   Once, and never again, because rebuilding them replaces the very
  ##     slider the pointer is holding: the drag loses its element and stops
  ##     dead after the first event.  Redrawing the picture on every input
  ##     while leaving the controls alone is the whole difference between a
  ##     slider that follows the finger and one that has to be nudged.
  var controls = ""
  for i, d in DIALS:
    controls.add &"""<label class="dial"><span>{d.name}""" &
      &"""<b id="dv{i}">{m(dial[i])}{d.unit}</b></span>""" &
      &"""<input type="range" data-dial="{i}" min="{d.low}" max="{d.high}"""" &
      &""" step="{d.step}" value="{dial[i]}"></label>"""
  # One height slider per connection, all four written once and then only
  # shown or hidden: rebuilding them would replace the very slider a pointer
  # is holding, and the drag would stop dead after its first event.
  for i, pair in PAIRS:
    controls.add &"""<label class="dial" id="hl{i}"><span>""" &
      &"""{esc(pair.name)} hands at<b id="hv{i}">{m(high[i])} m</b></span>""" &
      &"""<input type="range" data-high="{i}" min="{HIGH_LOW}"""" &
      &""" max="{HIGH_HIGH}" step="{HIGH_STEP}" value="{high[i]}"></label>"""
  var picks = ""
  for i, pair in PAIRS:
    picks.add &"""<button id="pk{i}" data-pair="{i}" class="pick"""" &
      &"""" style="--ink: {draw.INKS[i mod draw.INKS.len]}">{pair.name}</button>"""
  document.getElementById("app").innerHTML = cstring(
    """<div class="stage" id="stage"></div>""" &
    &"""<div class="panel"><div class="picks">{picks}</div>{controls}</div>""" &
    """<div class="says-wrap"><div id="says"></div>""" &
    """<div id="limit"></div></div>""")


var
  booked = false ## Whether the limit is booked for once the drag stops.
  later: TimeOut
    ## The free-standing `setTimeout`, not the window's: the window's is
    ## declared to give back an `Interval` that its own `clearTimeout` will
    ## not take.


proc render() =
  ## Redraw what the state says, leaving the controls where they are.
  let
    state = built()
    on = chosen()
  for i, d in DIALS:
    document.getElementById(cstring(&"dv{i}")).textContent =
      cstring(&"{m(dial[i])}{d.unit}")
  for i, pair in PAIRS:
    document.getElementById(cstring(&"pk{i}")).className =
      cstring(if joined[i]: "pick on" else: "pick")
    document.getElementById(cstring(&"hl{i}")).className =
      cstring(if joined[i]: "dial" else: "dial off")
    document.getElementById(cstring(&"hv{i}")).textContent =
      cstring(&"{m(high[i])} m")
  document.getElementById("stage").innerHTML =
    cstring(draw.plan(state, on) & draw.elevation(state, on))
  document.getElementById("says").innerHTML = cstring(readout(state, on))
  # The limit is a sweep from rest, and much the dearest thing on the page --
  # a drag of any slider it depends on would otherwise pay for it on every
  # frame.  So the picture goes up first and the limit follows a moment later,
  # once the finger has stopped moving.  It is a readout and not the model.
  if booked:
    clearTimeout(later)
  booked = true
  later = setTimeout(proc () =
    booked = false
    document.getElementById("limit").innerHTML = cstring(limits(built())), 150)


var pending = false ## Whether a redraw is already booked for the next frame.


proc paint() =
  ## Redraw at most once a frame, however fast the controls are moved.
  ##   A slider fires as fast as the pointer moves, and a redraw is not free:
  ##     wound right up it is some tens of milliseconds.  Drawing every event
  ##     as it lands queues them behind each other, so the picture falls
  ##     further behind the finger the longer the drag goes on -- which is
  ##     the whole of what "the slider takes a second to register" is.
  ##   Booking one frame instead means the events that arrive while a redraw
  ##     is pending are collapsed into it, and the picture always shows where
  ##     the slider is now rather than where it was several events ago.
  if pending:
    return
  pending = true
  discard window.requestAnimationFrame(proc (time: float) =
    pending = false
    render())


proc handle(event: Event) =
  let target = event.target
  if target == nil or target.getAttribute("data-pair") == nil:
    return
  let which = parseInt($target.getAttribute("data-pair"))
  joined[which] = not joined[which]
  paint()


proc slide(event: Event) =
  let target = event.target
  if target == nil or (target.getAttribute("data-dial") == nil and
      target.getAttribute("data-high") == nil):
    return
  # The property, not the attribute: dragging a range moves `value` and
  # leaves the `value=` it was written with exactly where it was, so reading
  # the attribute gives the starting number for ever.
  if target.getAttribute("data-high") != nil:
    high[parseInt($target.getAttribute("data-high"))] =
      parseFloat($cast[InputElement](target).value)
    paint()
    return
  let which = parseInt($target.getAttribute("data-dial"))
  dial[which] = parseFloat($cast[InputElement](target).value)
  paint()


when isMainModule:
  document.addEventListener("click", handle)
  document.addEventListener("input", slide)
  mount()
  render()
