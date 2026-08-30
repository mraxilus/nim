## Draw a state of the sim, straight from the state.
##
##   Two views of the one value, because a body is a cylinder and a plan view
##     alone cannot say how high a rope is carried -- which is the whole of
##     what decides whether it clears a head, and which of two ropes is over.
##   Nothing here is a symbol standing for something.  A circle is a torso
##     seen from above at the size the torso is, and the line is where the
##     solver put the rope.  If the drawing looks wrong, the model is wrong.

{.experimental: "strictFuncs".}

import std/[algorithm, math, options, strformat, strutils]

import ./rope


const
  PX* = 250.0     ## Pixels to the metre.
  LEAST_HALF* = 0.34 ## The smallest half-box, so a close couple does not fill it.
  BREAK* = 0.036 ## Half the gap an under rope is drawn with, in metres.
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
      for at in traced(state, link, laid.get).at:
        result = max(result, dist(at, mid))
  result += 0.06


func atAlong(px: seq[(float, float)]; along: seq[float];
    want: float): (float, float) =
  ## Get the pixel point a given plan distance along a traced rope.
  if px.len == 0: return (0.0, 0.0)
  for i in 0 ..< px.high:
    if want <= along[i + 1] or i == px.high - 1:
      let step = along[i + 1] - along[i]
      if step < 1e-12: return px[i]
      let f = clamp((want - along[i]) / step, 0.0, 1.0)
      return (px[i][0] + (px[i + 1][0] - px[i][0]) * f,
              px[i][1] + (px[i + 1][1] - px[i][1]) * f)
  px[^1]


func brokenPath(px: seq[(float, float)]; along: seq[float];
    cuts: seq[float]; gap: float): string =
  ## Draw a rope as an SVG path, with a break wherever another passes over it.
  ##   The break is where the over-under is said.  A ring drawn beside the
  ##     crossing says which rope the reader should believe; a rope that stops
  ##     and starts again says it in the drawing itself, and cannot disagree
  ##     with the geometry because it is cut at the distance the crossing was
  ##     found at.
  if px.len < 2:
    return ""
  var stops: seq[(float, float)]
  var at = 0.0
  for cut in cuts:
    let
      lo = cut - gap
      hi = cut + gap
    if hi <= at:
      continue
    if lo > at:
      stops.add (at, lo)
    at = max(at, hi)
  if at < along[^1]:
    stops.add (at, along[^1])
  for (lo, hi) in stops:
    if hi - lo < 1e-9:
      continue
    var d = ""
    let start = atAlong(px, along, lo)
    d.add "M" & n(start[0]) & " " & n(start[1])
    for i in 0 ..< px.len:
      if along[i] > lo and along[i] < hi:
        d.add " L" & n(px[i][0]) & " " & n(px[i][1])
    let stop = atAlong(px, along, hi)
    d.add " L" & n(stop[0]) & " " & n(stop[1])
    result.add d & " "


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
  # Every rope, traced once: the points, where they are on the page, and how
  # far along the rope each of them is, which is what a crossing is measured in.
  var
    laid: seq[Lie]
    shown: seq[bool]
    inked: seq[seq[(float, float)]]
    along: seq[seq[float]]
    cuts: seq[seq[float]]
  for link in state.links:
    let got = lay(state, link)
    shown.add got.isSome
    laid.add (if got.isSome: got.get else: Lie())
    var
      px: seq[(float, float)]
      run: seq[float]
    if got.isSome:
      let at = traced(state, link, got.get).at
      for i, p in at:
        px.add put(p)
        run.add (if i == 0: 0.0 else: run[i - 1] + dist(at[i - 1], p))
    inked.add px
    along.add run
    cuts.add @[]
  # Where two ropes cross, the lower one gives way: it is the under rope, and
  # it is drawn broken rather than annotated.
  var rings: seq[string]
  for i in 0 ..< state.links.len:
    for j in i + 1 ..< state.links.len:
      if not (shown[i] and shown[j]):
        continue
      for met in meetings(state, state.links[i], laid[i], state.links[j],
          laid[j]):
        let top = overOf(state.rig, met)
        if top.isNone:
          # Nearer than two ropes can lie: the geometry has no answer, and
          # the state is refused elsewhere for the same reason.
          let p = put(met.at)
          rings.add &"""<circle cx="{n(p[0])}" cy="{n(p[1])}" r="7"""" &
            """ class="met" style="stroke: var(--faint, #948d85)"/>"""
        elif top.get == 0:
          cuts[j].add met.along[1]
        else:
          cuts[i].add met.along[0]
  for index, link in state.links:
    if not shown[index]:
      continue
    let
      order = sorted(cuts[index])
      bad = faultOf(state, link).isSome
    bits.add &"""<path d="{brokenPath(inked[index], along[index], order, BREAK)}"""" &
      &"""" class="rope{(if bad: " bad" else: "")}"""" &
      &""" style="stroke: {inkFor(inks, index)}"/>"""
    for e in 0 .. 1:
      let a = put(anchor(state, link.ends[e]))
      bits.add &"""<circle cx="{n(a[0])}" cy="{n(a[1])}" r="4" class="grip"""" &
        &""" style="fill: {inkFor(inks, index)}"/>"""
  let side = reachOf(state) * PX
  &"""<svg class="view" viewBox="{n(-side)} {n(-side)} {n(2 * side)}""" &
    &""" {n(2 * side)}" role="img">""" & bits.join("") & rings.join("") & "</svg>"


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
    # The rope as it is actually carried, point by point: the tent up to the
    # joined hands where there is only a tent, and the braid's own rise and
    # fall where there is a braid.  Drawn against the plan length it spans, so
    # two ropes crossing show here as one passing above the other.
    let
      walk = traced(state, link, laid.get)
      half = laid.get.span / 2.0
    var
      d = ""
      gone = 0.0
    for i, at in walk.at:
      if i > 0:
        gone += dist(walk.at[i - 1], at)
      let (x, y) = put(gone - half, walk.high[i])
      d.add (if i == 0: "M" else: " L") & n(x) & " " & n(y)
    bits.add &"""<path d="{d}" class="rope"""" &
      &""" style="stroke: {inkFor(inks, index)}"/>"""
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
