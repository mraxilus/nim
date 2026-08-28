## Draw the physical rig: the bodies and the rope, at the size they really are.
##
##   `sim.nim` referees in metres and hands back the solved taut path as a
##     polyline.  This turns that into the workbench's own marks, so what the
##     page shows is the solver's output and not an illustration of it.
##     Cost of drawing the solved path rather than a tidy curve: a hug reads
##       as the 0.09-radian sampling it is, and a rope that hugs nothing is
##       exactly straight.  Accepted -- a drawing that smoothed the solver
##       would be shorthand again, which is the thing this page is against.
##   One unit of scale, taken on the torso: a body is drawn at `BODY_R`, the
##     size every other page draws it, and only the distance between the two
##     changes.  So these figures are the same dancers seen from the same
##     height, standing where the model says rather than where the shorthand
##     put them.
##   The couple always stand at the smallest gap two bodies can hold, rims in
##     light contact.  Distance is a real axis in the model -- a wrap needs
##     the couple close and the referee knows by how much -- but it is not
##     what this page is about, so it is pinned and the numbers that depend
##     on it are said in words.
##
## The head is drawn here and nowhere else: `draw/body.nim` has never had one,
## because until there was a rope to carry over it there was nothing a head
## did.  It is the neck the `rise` is measured up, so the page that spends
## that rope is the page that shows what it climbs.

{.experimental: "strictFuncs".}

import std/[math, sequtils, strformat, strutils]

import ../src/partnerwork/[frame, rotation, sim]
import ../src/partnerwork/draw/[body, figure, geometry, route, style, terms]


const
  PX* = BODY_R / HUMAN.torso
    ## Drawing units to the metre, taken on the torso so a body comes out at
    ## `BODY_R` and only the standing distance is new.
  GAP* = touching(HUMAN)
    ## The one distance every figure on the page is drawn at.
  HEAD_R* = HUMAN.head * PX
    ## The head and neck disc, concentric with the torso.
  ROPE_N* = ROUTE_N
    ## Points a drawn rope is resampled to, matching every other reach.


const PI_TORSO* = PI * HUMAN.torso
  ## What half a turn wound low costs: half the girth of the torso it winds.


func at*(p: Point): Point =
  ## Put a point of the model on the page.
  ##   The model measures from the lead, up the y axis towards the follow;
  ##     the page measures down, and centres the couple.  So y flips and the
  ##     midpoint of the two bodies lands on the origin, which is what
  ##     `figure.view` frames about.
  (p.x * PX, (GAP / 2.0 - p.y) * PX)


func half*(): float =
  ## Get the half-box every figure on this page is framed to.
  ##   One box for the whole page, so a rope in one figure is the same length
  ##     on the screen as the same rope in the next and the eye can compare
  ##     them.  Taken from the couple's own reach plus a hand and its stroke.
  GAP / 2.0 * PX + BODY_R + R + 4.0


func bodyAt*(centre: Point; facing: float): seq[string] =
  ## Draw one dancer: the torso rim, the head stacked on it, the way they face.
  ##   A plain circle, not `body.border`, because nothing here is broken for a
  ##     hand: the hands are on the rim at the shoulders and the rope leaves
  ##     from them rather than crossing the outline.
  @[&"""<circle cx="{n(centre.x)}" cy="{n(centre.y)}" r="{n(BODY_R)}"""" &
      &""" fill="none" stroke="{QUIET}" stroke-width="{RIM_W}"/>""",
    &"""<circle cx="{n(centre.x)}" cy="{n(centre.y)}" r="{n(HEAD_R)}"""" &
      &""" fill="none" stroke="{QUIET}" stroke-width="1"/>""",
    chevron(centre, facing)]


func armOf*(side: Side): Arm =
  ## Read a hand of the lead as the arm the drawing knows it by.
  if side == Side.Left: Arm.L else: Arm.R


func armOf*(site: Site): Arm =
  ## Read a hand of the follow as the arm the drawing knows it by.
  if site == Site.LeftHand: Arm.L else: Arm.R


func drawn*(laid: Lie): seq[Point] =
  ## Put a solved lie on the page, at the sampling every reach is drawn at.
  resample(laid.trace.mapIt(at(it)), ROPE_N)


func ropeInk*(pts: seq[Point]; side: Side; site: Site;
    under: seq[Point] = @[]): seq[string] =
  ## Draw one rope in its two hands' own colours, broken where it dives.
  ##   The break is cut before the two shades are split, so a rope that
  ##     passes under another keeps its gap in whichever half it falls --
  ##     `splitAt` divides the runs rather than rebuilding them.
  let runs = if under.len > 0: cutGap(pts, under) else: @[pts]
  twoTone(runs, pts[pts.len div 2], armOf(side), armOf(site))


func handsOn*(rig: Rig; side: Side; site: Site): seq[string] =
  ## Draw the two hands one rope joins, each at its own shoulder.
  let
    p = at(leadShoulder(rig, side))
    q = at(followShoulder(rig, GAP, site))
  @[hand(p.x, p.y, true, armOf(side)), hand(q.x, q.y, false, armOf(site))]


func spiral*(rig: Rig; centre: Point; from_at: Point; winds: int): seq[Point] =
  ## Draw the rope a wind spends, as the turns it takes round a torso.
  ##   The referee prices a wind and never routes one: half a girth per half
  ##     turn is a length, and a length has no shape.  This gives it one, and
  ##     only here -- the drawing owes the reader a picture of what was spent,
  ##     the model does not.
  ##   It stands a little off the rim so the coils read as coils rather than
  ##     as a thicker outline, and it winds the way the half turns are signed.
  if winds == 0:
    return @[]
  let
    turns = abs(winds).float / 2.0
    steps = max(8, int(ceil(turns * 24.0)))
    way = if winds > 0: 1.0 else: -1.0
    start = arctan2(from_at.y - centre.y, from_at.x - centre.x)
  for step in 0 .. steps:
    let
      t = float(step) / float(steps)
      out_by = BODY_R + 1.5 + 2.6 * t
      at_now = start + way * turns * 2.0 * PI * t
    result.add (centre.x + cos(at_now) * out_by,
                centre.y + sin(at_now) * out_by)


func figureOf*(cls: string; bits: seq[string]; box = half()): string =
  ## Wrap a set of marks as one figure, framed the way the whole page is.
  &"""<svg class="{cls}" {view(box)} role="img">""" & bits.join("") & "</svg>"


func note*(p: Point; text: string; ink = FAINT; anchor = "middle"): string =
  ## Set a word at a point of the drawing.
  ##   `body.caption` only ever writes beside a hand, at a hand's bearing;
  ##     a figure that measures something needs to label the thing measured.
  &"""<text x="{n(p.x)}" y="{n(p.y)}" text-anchor="{anchor}"""" &
    """ style="font: 8px ui-sans-serif, system-ui, sans-serif;""" &
    &""" fill: {ink}">{text}</text>"""


const
  WRAP_CAP* = CAPACITY_WRAP_LOW
  GRIP_CAP* = CAPACITY_SINGLE
    ## The two ceilings `rotation.nim` holds, quoted here so a page can check
    ## itself against the axis model without importing it -- the two modules
    ## each have a `Level`, a `Way` and a `Dancer`, and they do not mean the
    ## same things by them.


func windFollow*(held: Rope; halfTurns: int): Rope =
  ## Wind a connection round the follow, who is the dancer a turn is led on.
  ##   The model's `Dancer` and the drawing's are two different enums that
  ##     happen to share a name, so the model's is named in full here once
  ##     and the pages never have to reach for it.
  wound(held, rotation.Dancer.Follow, halfTurns)


func shedFollow*(held: Rope): Rope =
  ## Carry a connection over the follow's head, letting every wind go.
  shed(held, rotation.Dancer.Follow)


func metres*(v: float; places = 2): string =
  ## Say a measured length, in the units the rig is built in.
  ##   Named for its units rather than for its formatting, because every
  ##     number this page prints is a length and a bare `fmt` beside
  ##     `checks.nim`'s own would be two spellings of one idea.
  formatFloat(v, ffDecimal, places).strip(leading = false, chars = {'.'})


func stance*(rig: Rig): seq[string] =
  ## Draw the two bodies where they stand, before any rope is laid on them.
  bodyAt(at((0.0, 0.0)), 0.0) & bodyAt(at((0.0, GAP)), 180.0)
