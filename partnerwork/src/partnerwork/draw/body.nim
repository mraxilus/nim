## Draw one dancer: a circle, with a small chevron at its centre for the
## facing.
##
##   The boundary is one polar function, `outlineR`, shared by the drawing,
##     the hands and the routing -- so "on the border" is true by
##     construction rather than by two pieces of code agreeing.
##   The rim is drawn quiet and whole, broken only where a hand mark sits on
##     it: how far an arm has been carried round is said by the connection
##     wrapping the body, not by a second arc filling up around it.
##     Cost of a quiet rim: an arm carried past a full turn looks like one
##       carried less.  Accepted while nothing on the bench stores more than
##       a turn; the README keeps the question open.
##   Hands sit on the rim, each in its own side's colour, the lead's a shade
##     deeper than the follow's.
##   The six spots of rule 3 are bearings off the dancer's own facing, never
##     off the page: turn a dancer and their spots turn too.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]

import ./[geometry, pose, style, terms]


const
  BODY_R* = 20.0     ## A dancer, seen from above; their hands sit on it.
  RIM_W* = 2.2       ## One width for the whole boundary.

const
  CHEV_OUT* = 7.0    ## How far the centred chevron reaches forward.
  CHEV_BACK* = 1.0   ## And how little it reaches back.
  CHEV_HALF* = 5.0   ## Half its width, well inside the rim.
  CHEV_W* = 1.6      ## The width its two legs are drawn at.

const
  RIM_STEP* = 3.0    ## Degrees between samples when a route walks the rim.
  ARM_REST* = 90.0   ## A resting hand, a quarter of the rim from the front.
  R* = 6.0           ## A hand mark's radius, or half its side.
  CAPTION_R* = BODY_R + R + 2   ## Just past the hand a caption names.
  FREE_FADE* = 0.5   ## How far a hand nobody holds fades, keeping its hue.

const SLOT_OFFSET* = 44.0
  ## How far round the rim `front` and `back` sit from a side.
  ##   Wide enough that no two marks ever touch -- two need 34.9 degrees on
  ##     this rim -- and narrow enough that a spot still belongs to its own
  ##     side.  A drawn convention, not something the dance says; the README
  ##     keeps it on the open list.

const HAND_GAP* = radToDeg(arcsin((R + CAP) / BODY_R))
  ## The rim's clearance around a hand mark: the same reach the connection
  ## keeps, turned into arc, so boundary and reach stop at one border.

const
  MARK_STROKE* = 1.5   ## The width a hand mark is outlined at.
  SEEN_GAP* = 1.2      ## Plain daylight between a reach and what it clears.
  CHEVRON_STEPS* = 6   ## Discs along one leg of a chevron, so the V is kept
                       ## clear as the shape it is.

const
  LEAD_CLEAR* = R * sqrt(2.0) + MARK_STROKE / 2 + CAP + SEEN_GAP
    ## How far a settled reach stays off a lead's hand: their mark is a
    ## square, so its corner is the far part of it (rule 22).
  FOLLOW_CLEAR* = R + MARK_STROKE / 2 + CAP + SEEN_GAP
    ## And off a follow's, whose mark is a circle.
  CHEVRON_CLEAR* = CHEV_W / 2 + CAP + SEEN_GAP
    ## And off a chevron's stroke.
    ##   The chevron is kept clear along its own two legs rather than as one
    ##     disc over the whole of it: it is a thin V pointing forward, and a
    ##     disc that covered its apex would swallow the middle of a body and
    ##     send every reach right round the outside -- which is the wrap
    ##     rule 14 forbids.  So the shape is cleared as it is drawn.


type Free* {.pure.} = enum ## Say how a hand nobody holds is drawn.
  Fade,                    ## Half strength, keeping its hue: a free hand.
  Grey                     ## Quiet outline: the ghost of a place a hand left.


#[ The Six Spots ]#

func slotBearing*(arm: Arm; slot: Slot): float =
  ## Get where one of the six spots sits, as a bearing off the body's facing.
  ##   Two sides, and on each the place where the arm hangs, one spot a
  ##     little towards the dancer's front and one a little towards their
  ##     back -- rule 3's six, named for what they are.
  let
    base = if arm == Arm.L: -ARM_REST else: ARM_REST
    forward = if arm == Arm.L: SLOT_OFFSET else: -SLOT_OFFSET
  base + (case slot
          of Slot.Front: forward
          of Slot.Back: -forward
          of Slot.Default: 0.0)


func slotOf*(arm: Arm; level: Option[Level]; way: Option[Way]):
    tuple[arm: Arm, slot: Slot] =
  ## Get the one of six spots this hand settles in: whose side, how far round.
  ##   `above` never settles anywhere but its own side's default (rule 8).
  let settled = settleOf(level, way)
  if settled.isNone:
    return (arm, Slot.Default)
  ((if settled.get.whose == Whose.Own: arm else: other(arm)),
   settled.get.slot)


func roundOf*(level: Option[Level]; way: Option[Way]): Option[Sends] =
  ## Get which way round the body this hold sends its line, where rules 4 to
  ## 6 say anything; none where nothing is said and the short way is taken.
  let settled = settleOf(level, way)
  if settled.isSome: some settled.get.sends else: none(Sends)


func handBearing*(facing: float; arm: Arm; wind = 0.0): float =
  ## Get the bearing a hand sits at: round from the front, past the rest spot
  ## by however far the arm has been carried.
  facing + (if arm == Arm.L: -1.0 else: 1.0) * (ARM_REST + wind)


func settledWind*(arm: Arm; level: Option[Level]; way: Option[Way]): float =
  ## Get the winding that puts this hand in its slot.
  ##   Winding is measured off the hand's own side and runs towards the back
  ##     for either hand, so this is the one place the two conventions are
  ##     reconciled.
  let
    landed = slotOf(arm, level, way)
    aim = slotBearing(landed.arm, landed.slot)
  if arm == Arm.L: -ARM_REST - aim else: aim - ARM_REST


func handPoint*(centre: Point; facing: float; arm: Arm; wind = 0.0): Point =
  ## Get where one hand is on the rim.
  polar(centre.x, centre.y, BODY_R, handBearing(facing, arm, wind))


func handsOf*(pose: Pose): array[Dancer, array[Arm, Point]] =
  ## Get where all four hands are.
  for who in Dancer:
    for arm in Arm:
      result[who][arm] = handPoint(
        pose.place[who], pose.facing[who], arm, pose.wind[who][arm])


#[ The Boundary ]#

func outlineR*(delta: float): float =
  ## Get how far the boundary is from the centre at this bearing off the
  ## front.
  ##   One function, used by the drawing and by anything that has to stay
  ##     outside a body -- so "on the border" is true by construction.  A
  ##     body is a plain circle now; the function stays because the routing
  ##     reads the boundary through it.
  BODY_R


func outlinePoint*(centre: Point; facing, theta: float): Point =
  ## Get the boundary point at a world bearing.
  polar(centre.x, centre.y, outlineR(theta - facing), theta)


func rim*(centre: Point; facing, a, b: float; width = RIM_W): string =
  ## Draw one stretch of the boundary, once and by one owner.
  let
    span = b - a
    start = outlinePoint(centre, facing, a)
    stop = outlinePoint(centre, facing, b)
    large = if abs(span) > 180: 1 else: 0
    sweep = if span > 0: 1 else: 0
    d = &"M{xy(start)} A{n(BODY_R)} {n(BODY_R)} 0 {large} {sweep} {xy(stop)}"
  &"""<path d="{d}" fill="none" stroke="{QUIET}" stroke-width="{width}"""" &
    " stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"


func chevronPoints*(centre: Point; facing: float): array[3, Point] =
  ## Get the three points a chevron is drawn through: a wing, the apex, the
  ## other wing.
  ##   One source for the shape, so the drawing and anything that has to
  ##     keep off it read the same V (rule 22).
  let
    rad = degToRad(facing)
    fwd = (x: sin(rad), y: -cos(rad))
    across = (x: cos(rad), y: sin(rad))
  [(centre.x - fwd.x * CHEV_BACK - across.x * CHEV_HALF,
    centre.y - fwd.y * CHEV_BACK - across.y * CHEV_HALF),
   (centre.x + fwd.x * CHEV_OUT, centre.y + fwd.y * CHEV_OUT),
   (centre.x - fwd.x * CHEV_BACK + across.x * CHEV_HALF,
    centre.y - fwd.y * CHEV_BACK + across.y * CHEV_HALF)]


func chevron*(centre: Point; facing: float): string =
  ## Say the facing, small and at the centre of the body.
  ##   In the middle rather than on the rim, because the rim breaks for the
  ##     hands and carries nothing else.  The centre is the one part of a
  ##     dancer nothing else uses.
  let
    drawn = chevronPoints(centre, facing)
    (a, apex, b) = (drawn[0], drawn[1], drawn[2])
  &"""<polyline points="{n(a.x)},{n(a.y)} {n(apex.x)},{n(apex.y)}""" &
    &""" {n(b.x)},{n(b.y)}" fill="none" stroke="{QUIET}"""" &
    &" stroke-width=\"{n(CHEV_W)}\" stroke-linecap=\"round\"" &
    " stroke-linejoin=\"round\"/>"


func border*(pose: Pose; who: Dancer): string =
  ## Draw a dancer's whole boundary: one quiet outline, broken at the hands.
  ##   It says nothing but *here is a body*.  The rim used to fill up in an
  ##     arm's colour as that arm wound round -- a second progress ring
  ##     saying what the connection already says by wrapping -- so the ring
  ##     is gone and the line keeps the job.
  let
    centre = pose.place[who]
    facing = pose.facing[who]
    wind = pose.wind[who]
    right = ARM_REST + wind[Arm.R]
    left = ARM_REST + wind[Arm.L]
    # Every stretch stops a hand-gap short of a hand, so the boundary never
    # runs through a mark -- and a stretch that extreme winding has squeezed
    # away is simply not drawn.
    stretches = [
      (right + HAND_GAP, 360 - left - HAND_GAP),        # behind
      (360 - left + HAND_GAP, 360 + right - HAND_GAP),  # across the front
    ]
  for (a, b) in stretches:
    if b - a > 0.01:
      result.add rim(centre, facing, facing + a, facing + b)


#[ Hands and Furniture ]#

func fillOf*(level: Option[Level]; arm: Arm; deep = false): string =
  ## Get the fill a level draws as -- the one place a level becomes a fill,
  ## so hands and pips cannot drift.
  if level == some(Level.Low):
    return if deep: DEEP[arm] else: INK[arm]
  if level == some(Level.Above):
    return &"url(#h{arm}{(if deep: \"d\" else: \"\")})"
  "none"


func hand*(cx, cy: float; leads: bool; arm: Arm; held = true;
    level = none(Level); free = Free.Fade): string =
  ## Draw one hand, in its own side's ink: the lead's deep, the follow's
  ## plain.
  let
    ink = if leads: DEEP[arm] else: INK[arm]
    stroke = if held or free == Free.Fade: ink else: QUIET
    fill = if held: fillOf(level, arm, leads) else: "none"
    faded = if held or free != Free.Fade: ""
            else: &" opacity=\"{FREE_FADE}\""
    dot = if level == some(Level.High):
            &"""<circle cx="{n(cx)}" cy="{n(cy)}" r="2.7" fill="{stroke}"/>"""
          else: ""
    style = &"fill: {fill}; stroke: {stroke}; stroke-width: 1.5"
    shape =
      if leads:
        &"""<rect x="{n(cx - R)}" y="{n(cy - R)}" width="{n(2 * R)}"""" &
          &""" height="{n(2 * R)}" rx="1.5" style="{style}"{faded}/>"""
      else:
        &"""<circle cx="{n(cx)}" cy="{n(cy)}" r="{n(R)}" style="{style}"""" &
          &"{faded}/>"
  shape & dot


func ringOf*(pose: Pose): string =
  ## Draw the orbit, only while one is happening.
  ##   Nothing else in the picture is dashed, so a dashed circle says one
  ##     thing: somebody is going round somebody.  It is centred on whoever
  ##     is standing still -- a partner, or the midpoint when both travel.
  if pose.ring.isNone:
    return ""
  let (centre, radius) = pose.ring.get
  &"""<circle cx="{n(centre.x)}" cy="{n(centre.y)}" r="{n(radius)}"""" &
    &""" fill="none" stroke="{QUIET}" stroke-width="1"""" &
    """ stroke-dasharray="3 4"/>"""


func caption*(centre: Point; facing: float; arm: Arm; text: string;
    wind = 0.0): string =
  ## Set a hand's name just past it, growing outwards.
  let
    p = polar(centre.x, centre.y, CAPTION_R, handBearing(facing, arm, wind))
    dx = p.x - centre.x
    (anchor, dy) =
      if dx < -2: ("end", 3.0)
      elif dx > 2: ("start", 3.0)
      else: ("middle", if p.y < centre.y: -3.0 else: 8.0)
  &"""<text x="{n(p.x)}" y="{n(p.y + dy)}" text-anchor="{anchor}"""" &
    " style=\"font: 8px ui-sans-serif, system-ui, sans-serif;" &
    &""" fill: {FAINT}">{text}</text>"""
