## Draw a state of the sim, straight from the state.
##
##   Two views of the one value, because a body is a cylinder and a plan view
##     alone cannot say how high a rope is carried -- which is the whole of
##     what decides whether it clears a head, and which of two ropes is over.
##   Nothing here is a symbol standing for something.  A circle is a torso
##     seen from above at the size the torso is, and the line is where the
##     solver put the rope.  If the drawing looks wrong, the model is wrong.

{.experimental: "strictFuncs".}

import std/[math, options, strformat, strutils]

import ./rope


const
  PX* = 250.0     ## Pixels to the metre.
  LEAST_HALF* = 0.34 ## The smallest half-box, so a close couple does not fill it.
  INKS* = ["var(--rope-a, #3d7fd0)", "var(--rope-b, #d0763d)",
           "var(--rope-c, #4f9d69)", "var(--rope-d, #9a6fc0)"]
    ## One colour per connection.  Not per hand and not per dancer: what this
    ## page is about is a rope, and a rope is the thing that has a length.


func n*(v: float): string =
  ## Write a number for markup, without a trailing point or a minus zero.
  result = formatFloat(v, ffDecimal, 2)
  if result == "-0.00": result = "0.00"

func m*(v: float): string = formatFloat(v, ffDecimal, 3)
  ## Write a length in metres, to the millimetre.


func middle(state: State): Vec =
  ((state.stance[Body.One].centre.x + state.stance[Body.Two].centre.x) / 2.0,
   (state.stance[Body.One].centre.y + state.stance[Body.Two].centre.y) / 2.0)


func inkFor*(inks: seq[int]; index: int): string =
  ## Get the colour one rope is drawn in.
  ##   Taken from the caller's list where there is one, because which rope is
  ##     which is the page's business and not the drawing's, and a rope drawn
  ##     in the colour of a pairing it is not would say the wrong thing twice.
  INKS[(if index < inks.len: inks[index] else: index) mod INKS.len]


func reachOf*(state: State): float =
  ## Measure how far from the middle of the couple anything gets.
  ##   The box is fitted to what is in it rather than fixed, because a rope
  ##     that winds on grows well past the bodies and a box big enough for
  ##     that would leave the resting pair a speck in the corner of it.
  let mid = middle(state)
  result = LEAST_HALF
  for who in Body:
    result = max(result, dist(state.stance[who].centre, mid) + state.rig.torso)
  for link in state.links:
    let laid = lay(state, link)
    if laid.isSome:
      for at in trace(laid.get):
        result = max(result, dist(at, mid))
  result += 0.06


func plan*(state: State; inks: seq[int] = @[]): string =
  ## Draw the couple from above: the bodies, and every rope where it lies.
  let mid = middle(state)
  func put(p: Vec): (float, float) =
    ((p.x - mid.x) * PX, -(p.y - mid.y) * PX)
  var bits: seq[string]
  # The bodies: torso, head, and a wedge for the way each is facing.
  for who in Body:
    let
      c = put(state.stance[who].centre)
      face = state.stance[who].facing
      tip = put((state.stance[who].centre.x + cos(face) * state.rig.torso,
                 state.stance[who].centre.y + sin(face) * state.rig.torso))
    bits.add &"""<circle cx="{n(c[0])}" cy="{n(c[1])}" r="{n(state.rig.torso * PX)}"""" &
      """ class="torso"/>"""
    bits.add &"""<circle cx="{n(c[0])}" cy="{n(c[1])}" r="{n(state.rig.head * PX)}"""" &
      """ class="head"/>"""
    bits.add &"""<line x1="{n(c[0])}" y1="{n(c[1])}" x2="{n(tip[0])}"""" &
      &""" y2="{n(tip[1])}" class="face"/>"""
  # The ropes, exactly where the solver put them.
  for index, link in state.links:
    let laid = lay(state, link)
    if laid.isNone:
      continue
    var d = ""
    for i, at in trace(laid.get):
      let p = put(at)
      d.add (if i == 0: "M" else: " L") & n(p[0]) & " " & n(p[1])
    let bad = faultOf(state, link).isSome
    bits.add &"""<path d="{d}" class="rope{(if bad: " bad" else: "")}"""" &
      &""" style="stroke: {inkFor(inks, index)}"/>"""
    for e in 0 .. 1:
      let a = put(anchor(state, link.ends[e]))
      bits.add &"""<circle cx="{n(a[0])}" cy="{n(a[1])}" r="4" class="grip"""" &
        &""" style="fill: {inkFor(inks, index)}"/>"""
  # Where two ropes cross, ring the one that is over.
  for i in 0 ..< state.links.len:
    for j in i + 1 ..< state.links.len:
      let
        a = lay(state, state.links[i])
        b = lay(state, state.links[j])
      if a.isNone or b.isNone:
        continue
      for met in meetings(state, state.links[i], a.get, state.links[j], b.get):
        let
          p = put(met.at)
          top = overOf(state.rig, met)
          ink = if top.isNone: "var(--faint, #948d85)"
                else: inkFor(inks, (if top.get == 0: i else: j))
        bits.add &"""<circle cx="{n(p[0])}" cy="{n(p[1])}" r="7"""" &
          &""" class="met" style="stroke: {ink}"/>"""
  let side = reachOf(state) * PX
  &"""<svg class="view" viewBox="{n(-side)} {n(-side)} {n(2 * side)}""" &
    &""" {n(2 * side)}" role="img">""" & bits.join("") & "</svg>"


func elevation*(state: State; inks: seq[int] = @[]): string =
  ## Draw the couple from the side: how high everything is carried.
  ##   The plan cannot show this, and it is what settles whether a rope
  ##     clears a head and which of two ropes is on top.
  let mid = middle(state)
  func put(along, up: float): (float, float) =
    (along * PX, (state.rig.crown + 0.25 - up) * PX)
  var bits: seq[string]
  for who in Body:
    let
      c = state.stance[who].centre
      along = (if who == Body.One: -1.0 else: 1.0) * dist(c, mid)
      (x, base) = put(along, 0.0)
      (_, sh) = put(along, state.rig.shoulder)
      (_, crown) = put(along, state.rig.crown)
    bits.add &"""<rect x="{n(x - state.rig.torso * PX)}" y="{n(sh)}"""" &
      &""" width="{n(2 * state.rig.torso * PX)}" height="{n(base - sh)}"""" &
      """ class="torso"/>"""
    bits.add &"""<rect x="{n(x - state.rig.head * PX)}" y="{n(crown)}"""" &
      &""" width="{n(2 * state.rig.head * PX)}" height="{n(sh - crown)}"""" &
      """ class="head"/>"""
  for index, link in state.links:
    let laid = lay(state, link)
    if laid.isNone:
      continue
    # The rope as it is carried: up from one shoulder to the joined hands and
    # down to the other, drawn against the plan length it actually spans.
    let
      half = laid.get.span / 2.0
      (x0, y0) = put(-half, state.rig.shoulder)
      (x1, y1) = put(0.0, link.height)
      (x2, y2) = put(half, state.rig.shoulder)
    bits.add &"""<path d="M{n(x0)} {n(y0)} L{n(x1)} {n(y1)} L{n(x2)}""" &
      &""" {n(y2)}" class="rope" style="stroke: {inkFor(inks, index)}"/>"""
  let
    wide = max(reachOf(state), 0.80) * PX
    tall = (state.rig.crown + 0.35) * PX
  for (up, name) in [(0.0, "floor"), (state.rig.shoulder, "shoulder"),
                     (state.rig.crown, "crown")]:
    let (_, y) = put(0.0, up)
    bits.add &"""<line x1="{n(-wide)}" y1="{n(y)}" x2="{n(wide)}"""" &
      &""" y2="{n(y)}" class="floor"/>"""
    bits.add &"""<text x="{n(-wide + 6)}" y="{n(y - 4)}" class="mark" font-size="13">""" &
      &"""{name} {m(up)} m</text>"""
  &"""<svg class="view side" viewBox="{n(-wide)} 0 {n(2 * wide)} {n(tall)}"""" &
    """ role="img">""" & bits.join("") & "</svg>"
