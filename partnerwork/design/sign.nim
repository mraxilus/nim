## Draw the turn sign: a gauge of quarter turns, read like the frame
## pictures.
##
##   The outline holds exactly one full turn and rows pack up from the foot,
##     so how far a turn goes is how full the sign is.
##     Cost of a fixed height: a sign for more than a full turn needs an
##       ending mark rather than a taller box; the candidates are drawn on
##       the page and none is chosen yet.
##   A column is one of the lead's arms, a pip's shape says whose quarter it
##     is, its fill says that arm's level, and a dashed outline says the turn
##     travels round the couple -- every convention borrowed from the frame
##     picture, so the two read as one vocabulary.

{.experimental: "strictFuncs".}

import std/[math, options, strformat, strutils]

import ./[body, geometry, pose, rules, style]

# What a turn goes round is one idea, and it lives with the turning in
# `pose`; the sign borrows it rather than keeping a second copy.
export About


const
  TAN* = 0.25                    ## The sign's lean, across per down.
  THETA = arctan(TAN)
  LEAN_SIN = sin(THETA)
  LEAN_COS = cos(THETA)

const
  PIP* = 11.0                    ## Pip width, across the sign.
  GAP_X* = 4.0                   ## Margin, and the gutter between arms.
  SIGN_BODY* = 2 * PIP + 3 * GAP_X   ## Width between the slanting edges.
  QUARTERS* = 4                  ## Rows in a full turn.
  HEIGHT* = float(QUARTERS) * PIP + float(QUARTERS + 1) * GAP_X
    ## So a full sign is exactly a full turn.
  OVER* = PIP                    ## How far an open end runs on.
  INSET* = 0.76                  ## How far a dashed pip's fill pulls in.


type
  Row* {.pure.} = enum ## Say what one row of the sign holds.
    Lead,              ## A quarter danced by the lead: a leaning square.
    Follow,            ## A quarter danced by the follow: a circle.
    Ellipsis,          ## A row that counts nothing: the count runs on across.
    Repeat             ## Likewise, said as music's repeat colon.
  Lean* {.pure.} = enum ## Which way the sign leans: the way the turn goes.
    Cw, Acw
  Ending* {.pure.} = enum ## How a sign for an unfixed amount ends.
    Open, Spill, EllipsisEnd, RepeatEnd, Loop
  SignArm* = tuple ## One column of the sign: whether drawn, and its level.
    shown: bool
    level: Option[Level]
  SignArms* = array[Arm, SignArm]

const BOTH_UNSAID*: SignArms = [(true, none(Level)), (true, none(Level))]
  ## Both columns drawn, neither level said -- the default sign.


func dashes*(perimeter: float; count: int; duty = 0.58): string =
  ## Get a dash pattern that closes on itself, so no stub shows at the join.
  let period = perimeter / float(count)
  &"{n(period * duty)} {n(period * (1 - duty))}"


func scaled*(points: seq[Point]; factor: float): seq[Point] =
  ## Pull a polygon in towards its own centre.
  var cx, cy = 0.0
  for p in points:
    cx += p.x
    cy += p.y
  cx = cx / float(points.len)
  cy = cy / float(points.len)
  for p in points:
    result.add (cx + (p.x - cx) * factor, cy + (p.y - cy) * factor)


func poly*(points: seq[Point]; close = true): string =
  ## Write a polygon as path data.
  var joined: seq[string]
  for p in points:
    joined.add &"{n(p.x)} {n(p.y)}"
  let d = "M" & joined.join(" L")
  if close: d & " Z" else: d


func pip*(dancer: Dancer; ax, ay, dxs, dys: float; arm: Arm;
    level: Option[Level]; about = none(About)): string =
  ## Draw one quarter turn: shape says whose, column and ink which arm, fill
  ## its level.
  ##   Given an `about` the pip carries axis-against-orbit itself, which
  ##     needs the fill pulled in off the outline -- a low pip is filled in
  ##     the arm's own ink, and a dashed stroke of that ink on top of it
  ##     would be no stroke at all.
  ##   A pip takes the shade of the hand it stands for, the lead's deep and
  ##     the follow's plain, so a sign and a frame picture read the same way
  ##     round.
  let
    leads = dancer == Dancer.Lead
    ink = if leads: DEEP[arm] else: INK[arm]
    fill = fillOf(level, arm, leads)
    cx = ax + PIP / 2 + dxs / 2
    cy = ay + dys / 2
    pts: seq[Point] = @[(ax, ay), (ax + PIP, ay), (ax + PIP + dxs, ay + dys),
                        (ax + dxs, ay + dys)]
    perimeter = if leads: 2 * PIP + 2 * hypot(dxs, dys)
                else: 2 * PI * (PIP / 2)

  func shape(inset: float; style: string): string =
    ## One outline or fill, as the dancer's own mark: path or circle.
    if leads:
      let d = if inset == 1.0: poly(pts) else: poly(scaled(pts, inset))
      &"""<path d="{d}" {style}/>"""
    else:
      &"""<circle cx="{n(cx)}" cy="{n(cy)}" r="{n(PIP / 2 * inset)}" {style}/>"""

  var bits: seq[string]
  if about.isNone:
    bits.add shape(1.0,
      &"""fill="{fill}" stroke="{ink}" stroke-width="1.4"""" &
        """ stroke-linejoin="round"""")
  else:
    if fill != "none":
      bits.add shape(INSET, &"""fill="{fill}" stroke="none"""")
    let dash = if about == some(About.Orbit):
                 &""" stroke-dasharray="{dashes(perimeter, 8)}""""
               else: ""
    bits.add shape(1.0,
      &"""fill="none" stroke="{ink}" stroke-width="1.4"""" &
        &""" stroke-linejoin="round"{dash}""")
  if level == some(Level.High):
    bits.add &"""<circle cx="{n(cx)}" cy="{n(cy)}" r="2.5" fill="{ink}"/>"""
  bits.join("")


func marker*(kind: Row; ax, ay, dxs, dys: float; arm: Arm): string =
  ## Draw a row that counts nothing: it says the count does not end.
  let
    ink = INK[arm]
    cx = ax + PIP / 2 + dxs / 2
    cy = ay + dys / 2
  if kind == Row.Ellipsis:               # and so on, across
    for d in [-3.7, 0.0, 3.7]:
      result.add &"""<circle cx="{n(cx + d)}" cy="{n(cy)}" r="1.7"""" &
        &""" fill="{ink}"/>"""
  else:
    for d in [-3.1, 3.1]:
      result.add &"""<circle cx="{n(cx)}" cy="{n(cy + d)}" r="1.9"""" &
        &""" fill="{ink}"/>"""


func signBody*(slots: seq[Row]; lean: Lean; arms: SignArms; x0, y_foot: float;
    about: Option[About]; pip_about: seq[About]; ending: Option[Ending];
    packed = true): tuple[markup: string, box: tuple[x0, y0, x1, y1: float]] =
  ## Draw the sign at a place, returning markup and the box it fills.
  ##   `slots` reads downwards, one entry per quarter turn, the follow's
  ##     first, so a mixed sign has one picture rather than two.
  ##   The stack packs up from the foot: the outline holds a full turn, so
  ##     how full it is is how far it goes, and the count is a check on the
  ##     reading rather than the whole of it.
  let
    y_bot = y_foot + HEIGHT
    y_top = y_foot
    slope = HEIGHT * TAN
    over = if ending in [some(Ending.Open), some(Ending.Spill)]: OVER else: 0.0
    slant = if lean == Lean.Cw: -LEAN_SIN else: LEAN_SIN

  func leftAt(y: float): float =
    ## The slanting left edge, at a height.
    if lean == Lean.Cw: x0 + (y_bot - y) * TAN    # leans right going up
    else: x0 + (y - y_top) * TAN

  func slotTop(place: int): float =
    ## Top of the slot `place` rows up from the foot.
    y_bot - GAP_X - float(place) * (PIP + GAP_X) - PIP

  let
    foot: seq[Point] = @[(leftAt(y_bot), y_bot),
                         (leftAt(y_bot) + SIGN_BODY, y_bot)]
    head: seq[Point] = @[(leftAt(y_top), y_top),
                         (leftAt(y_top) + SIGN_BODY, y_top)]
    perimeter = 2 * SIGN_BODY + 2 * hypot(slope, HEIGHT)
    # The couple's centre line is dashed in every frame picture, so a turn
    # that goes round that centre is dashed too, not a new mark.
    dash = if about == some(About.Orbit):
             &""" stroke-dasharray="{dashes(perimeter, 20)}""""
           else: ""
    style = """fill="none" stroke="var(--ink)" stroke-width="2"""" &
      &""" stroke-linejoin="round" stroke-linecap="round"{dash}"""
    outline =
      if over > 0:
        # No lid, and the sides run on past where one would be: a box that
        # never closes is a count that never finishes.
        let tips: seq[Point] = @[(leftAt(y_top - over), y_top - over),
                                 (leftAt(y_top - over) + SIGN_BODY,
                                  y_top - over)]
        poly(@[tips[0], foot[0], foot[1], tips[1]], close = false)
      else:
        poly(@[foot[0], head[0], head[1], foot[1]])
  var bits = @[&"""<path d="{outline}" {style}/>"""]

  if ending == some(Ending.Loop):
    # The graph's own loop edge, drawn on its label.
    let
      (ax0, ay0) = head[0]
      (bx0, by0) = foot[0]
      reach = 15.0
    bits.add &"""<path d="M{n(ax0 - 2)} {n(ay0 + 5)} C{n(ax0 - reach)}""" &
      &""" {n(ay0 + 6)} {n(bx0 - reach)} {n(by0 - 6)} {n(bx0 - 3)}""" &
      &""" {n(by0 - 5)}" fill="none" stroke="var(--ink)"""" &
      """ stroke-width="1.6" stroke-linecap="round"/>"""
    bits.add &"""<path d="M{n(bx0 - 8)} {n(by0 - 8.5)} L{n(bx0 - 3)}""" &
      &""" {n(by0 - 5)} L{n(bx0 - 8.5)} {n(by0 - 2.5)}" fill="none"""" &
      """ stroke="var(--ink)" stroke-width="1.6"""" &
      """ stroke-linecap="round" stroke-linejoin="round"/>"""

  let
    total = slots.len
    spread = (HEIGHT - float(total) * PIP) / float(total + 1)
  for i, what in slots:
    var top = if packed: slotTop(total - 1 - i)
              else: y_top + spread + float(i) * (PIP + spread)
    top += (PIP - PIP * LEAN_COS) / 2
    for col, arm in [Arm.L, Arm.R]:
      if not arms[arm].shown:
        continue
      let ax = leftAt(top) + GAP_X + float(col) * (PIP + GAP_X)
      if what in [Row.Lead, Row.Follow]:
        let row_about = if pip_about.len > 0: some(pip_about[i])
                        else: none(About)
        bits.add pip(
          (if what == Row.Lead: Dancer.Lead else: Dancer.Follow),
          ax, top, PIP * slant, PIP * LEAN_COS, arm, arms[arm].level,
          row_about)
      else:
        bits.add marker(what, ax, top, PIP * slant, PIP * LEAN_COS, arm)

  var
    xs: seq[float]
    ys = @[y_bot, y_top - over]
  for y in ys:
    xs.add leftAt(y)
  for y in ys:
    xs.add leftAt(y) + SIGN_BODY
  if ending == some(Ending.Loop):
    xs.add min(foot[0].x, head[0].x) - 16
  (bits.join("\n        "), (min(xs), y_top - over, max(xs), y_bot))


func sign*(slots: seq[Row]; lean = Lean.Cw; arms = BOTH_UNSAID;
    about = none(About); pip_about: seq[About] = @[];
    ending = none(Ending); scale = 1.2; packed = true): string =
  ## Draw one turn sign: quarter turns up from the foot, arms across, one
  ## height for every sign.
  let rows =
    if ending == some(Ending.EllipsisEnd): @[Row.Ellipsis] & slots
    elif ending == some(Ending.RepeatEnd): @[Row.Repeat] & slots
    elif ending == some(Ending.Spill):
      # The pip cut by the missing lid repeats whoever the top quarter is.
      @[slots[0]] & slots
    else: slots
  const pad = 5.0
  let
    (markup, box) = signBody(rows, lean, arms, pad, pad + OVER, about,
                             pip_about, ending, packed)
    w = box.x1 - box.x0 + 2 * pad
    h = box.y1 - box.y0 + 2 * pad
  &"""<svg viewBox="{n(box.x0 - pad)} {n(box.y0 - pad)} {n(w)} {n(h)}"""" &
    &""" width="{n(w * scale)}" height="{n(h * scale)}">""" &
    &"\n        {markup}\n      </svg>"
