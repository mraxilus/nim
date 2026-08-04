## Draw a frame, once, for every place that shows one.
##
## The picture is the couple seen from above, with the lead at the bottom facing
## up the page.  Seen from there the lead's Left hand and the follow's right hand
## are in the same column, because the partners are in mirror, so a connection
## between them runs straight up the picture and one that crosses the midline
## runs across it.
##
## The dashed line down the middle is that midline: not the divide between the
## two people, which every connection crosses, but the plane between the left
## and the right of the couple, which only a crossed connection crosses.  Whether
## a link crosses it is the whole of what `crossed` means, so the picture makes
## the distinction visible rather than asking to be read.
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
  WIDTH = 100
  HEIGHT = 116
  LEFT_X = 30      ## Column shared by the lead's Left hand and the follow's right.
  RIGHT_X = 70     ## Column shared by the lead's Right hand and the follow's left.
  FOLLOW_Y = 30    ## Row the follow's hands are drawn in, at the top.
  LEAD_Y = 88      ## Row the lead's hands are drawn in, at the bottom.
  MIDLINE_X = 50
  MIDLINE_TOP = 12
  MIDLINE_BOTTOM = 106
  CAPTION_TOP_Y = 16
  CAPTION_BOTTOM_Y = 108
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
  of Side.Left: (LEFT_X, LEAD_Y)
  of Side.Right: (RIGHT_X, LEAD_Y)


func followPoint(site: Site): (int, int) =
  ## Get where a hand of the follow is drawn.
  ##
  ## The follow faces the other way, so their right hand shares a column with the
  ## lead's Left: that shared column is what makes a parallel connection parallel.
  case site
  of Site.RightHand: (LEFT_X, FOLLOW_Y)
  of Site.LeftHand: (RIGHT_X, FOLLOW_Y)


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


func frameBody(target: Frame): string =
  ## Draw the contents of a frame picture, without the frame around them.
  ##
  ## The under-arm is drawn first so that the reading order of the markup is the
  ## reading order of the picture, from the ground up.
  result = "<title>" & target.describe & "</title>"
  result.add line(MIDLINE_X.float, MIDLINE_TOP.float, MIDLINE_X.float,
    MIDLINE_BOTTOM.float,
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

  result.add caption(LEFT_X, CAPTION_TOP_Y, "right")
  result.add caption(RIGHT_X, CAPTION_TOP_Y, "left")
  result.add caption(LEFT_X, CAPTION_BOTTOM_Y, "Left")
  result.add caption(RIGHT_X, CAPTION_BOTTOM_Y, "Right")


func frameHeight*(width: int): int =
  ## Get how tall a frame picture is when drawn to a given width.
  (width * HEIGHT) div WIDTH


func renderFrame*(target: Frame): string =
  ## Draw a frame as a picture that stands on its own.
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " & $WIDTH & " " &
    $HEIGHT & "\" class=\"frame\" role=\"img\">" & frameBody(target) & "</svg>"


func renderFramePlaced*(target: Frame; x, y, width: int): string =
  ## Draw a frame picture at a place inside a larger drawing.
  ##
  ## The same body, given its own viewport: a nested picture keeps its own
  ## coordinates, so the drawing around it never has to know how a frame is made.
  "<svg x=\"" & $x & "\" y=\"" & $y & "\" width=\"" & $width & "\" height=\"" &
    $frameHeight(width) & "\" viewBox=\"0 0 " & $WIDTH & " " & $HEIGHT &
    "\" class=\"frame\">" & frameBody(target) & "</svg>"
