## Draw a frame, once, for every place that shows one.
##
## The picture is the couple seen from above, with the lead on the left.  The
## lead's left hand and the follow's right hand share the upper edge, so a
## connection between them is a straight line and one that crosses the midline
## is a diagonal: the dashed line down the middle is that midline, and whether a
## link crosses it is the whole of what `crossed` means.
##
## Where both links cross they overlap, and the one underneath is drawn with a
## break in it.  A break rather than a masking stroke, because a mask has to know
## the colour of the ground it sits on and these pictures are also written out as
## standalone files, to be shown on grounds this module cannot see.
##
## Colours come through custom properties with fallbacks, for the same reason:
## inside a page that defines `--left` and `--right` the picture follows the
## page, including its light and dark themes, and on its own it falls back to
## ink that reads on either.

{.experimental: "strictFuncs".}

import std/[math, options, strutils]

import ./frame



#[ Geometry ]#

const
  WIDTH = 120
  HEIGHT = 100
  LEAD_X = 26      ## Column the lead's hands are drawn in.
  FOLLOW_X = 94    ## Column the follow's hands are drawn in.
  UPPER_Y = 32     ## Row shared by the lead's Left and the follow's right.
  LOWER_Y = 72     ## Row shared by the lead's Right and the follow's left.
  MIDLINE_X = 60
  RADIUS = 6
  BREAK_WIDTH = 11.0 ## Gap left in the link that passes underneath.


const
  COLOUR_LEFT = "var(--left, #a85f22)"
  COLOUR_RIGHT = "var(--right, #2b6c8c)"
  COLOUR_QUIET = "var(--rule-strong, #b9bfba)"
  COLOUR_CAPTION = "var(--faint, #9aa19d)"
  CAPTION_FONT = "font: 8px ui-sans-serif, system-ui, sans-serif"


func leadPoint(side: Side): (int, int) =
  ## Get where a hand of the lead is drawn.
  case side
  of Side.Left: (LEAD_X, UPPER_Y)
  of Side.Right: (LEAD_X, LOWER_Y)


func followPoint(site: Site): (int, int) =
  ## Get where a hand of the follow is drawn.
  case site
  of Site.RightHand: (FOLLOW_X, UPPER_Y)
  of Site.LeftHand: (FOLLOW_X, LOWER_Y)


func colour(side: Side): string =
  ## Get the ink one arm of the lead is drawn in.
  case side
  of Side.Left: COLOUR_LEFT
  of Side.Right: COLOUR_RIGHT



#[ Elements ]#

func number(value: float): string =
  ## Write a coordinate, at a fixed precision so that output is reproducible.
  value.formatFloat(ffDecimal, 1)


func line(x1, y1, x2, y2: float; style: string): string =
  ## Draw one straight segment.
  "<line x1=\"" & number(x1) & "\" y1=\"" & number(y1) & "\" x2=\"" &
    number(x2) & "\" y2=\"" & number(y2) & "\" style=\"" & style & "\"/>"


func link(side: Side; site: Site; is_under: bool): string =
  ## Draw one connection, broken at the crossing where it passes underneath.
  let
    (x1, y1) = leadPoint(side)
    (x2, y2) = followPoint(site)
    style = "stroke: " & colour(side) & "; stroke-width: 3.4; stroke-linecap: round"
  if not is_under:
    return line(x1.float, y1.float, x2.float, y2.float, style)

  # The two crossing links meet at their shared midpoint, so the break is half a
  # gap either side of the halfway parameter.
  let
    length = hypot((x2 - x1).float, (y2 - y1).float)
    step = BREAK_WIDTH / (2 * length)
    near = 0.5 - step
    far = 0.5 + step
  func at(t: float; a, b: int): float = a.float + t * (b - a).float
  line(x1.float, y1.float, at(near, x1, x2), at(near, y1, y2), style) &
    line(at(far, x1, x2), at(far, y1, y2), x2.float, y2.float, style)


func hand(point: (int, int); held: Option[Side]): string =
  ## Draw one hand: filled in the colour of the arm holding it, or left open.
  let style =
    if held.isSome:
      "fill: " & colour(held.get) & "; stroke: " & colour(held.get)
    else:
      "fill: none; stroke: " & COLOUR_QUIET
  "<circle cx=\"" & $point[0] & "\" cy=\"" & $point[1] & "\" r=\"" & $RADIUS &
    "\" style=\"" & style & "; stroke-width: 1.5\"/>"


func caption(x, y: int; text: string): string =
  ## Draw one edge label.
  "<text class=\"caption\" x=\"" & $x & "\" y=\"" & $y &
    "\" text-anchor=\"middle\" style=\"" & CAPTION_FONT & "; fill: " &
    COLOUR_CAPTION & "\">" & text & "</text>"



#[ Frames ]#

func holder(target: Frame; site: Site): Option[Side] =
  ## Get which hand of the lead holds this hand of the follow, if either does.
  for side in Side:
    if target.hold[side] == some(site):
      return some(side)
  none(Side)


func renderFrame*(target: Frame): string =
  ## Draw a frame as a self-contained picture.
  ##
  ## The under-arm is drawn first so that the reading order of the markup is the
  ## reading order of the picture, from the ground up.
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " & $WIDTH &
    " " & $HEIGHT & "\" class=\"frame\" role=\"img\">" &
    "<title>" & target.describe & "</title>"
  result.add line(MIDLINE_X.float, 18.0, MIDLINE_X.float, 86.0,
    "stroke: " & COLOUR_QUIET & "; stroke-width: 1; stroke-dasharray: 3 4")

  var order = @[Side.Left, Side.Right]
  if target.over == some(Side.Left):
    order = @[Side.Right, Side.Left]
  for side in order:
    if target.hold[side].isSome:
      result.add link(side, target.hold[side].get, target.over == some(other(side)))

  for side in Side:
    result.add hand(leadPoint(side),
      if target.hold[side].isSome: some(side) else: none(Side))
  for site in Site:
    result.add hand(followPoint(site), target.holder(site))

  result.add caption(LEAD_X, UPPER_Y - 17, "Left")
  result.add caption(LEAD_X, LOWER_Y + 21, "Right")
  result.add caption(FOLLOW_X, UPPER_Y - 17, "right")
  result.add caption(FOLLOW_X, LOWER_Y + 21, "left")
  result.add "</svg>"
