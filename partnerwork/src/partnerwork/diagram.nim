## Draw a frame, once, for every place that shows one.
##
##   The picture is the couple seen from above, with the lead at the bottom
##     facing up the page.  Seen from there the lead's Left hand and the
##     follow's right hand are in the same column, because the partners are
##     in mirror, so a connection between them runs straight up the picture
##     and one that crosses the midline runs across it.
##   The dashed line down the middle is that midline: not the divide between
##     the two people, which every connection crosses, but the plane between
##     the left and the right of the couple, which only a crossed connection
##     crosses.  Whether a link crosses it is the whole of what `crossed`
##     means, so the picture makes the distinction visible rather than
##     asking to be read.
##   The lead's hands are squares and the follow's are circles, so a picture
##     drawn too small for its captions still says which row is whose.
##   Where both links cross they overlap, and the one underneath is drawn
##     with a break in it.
##     Cost of a break: the under link really is cut -- a stretch of its ink
##       is missing.  Accepted -- a masking stroke has to know the colour of
##       the ground it sits on, and these pictures are also written out as
##       standalone files, to be shown on grounds this module cannot see.
##   Colours come through custom properties with fallbacks, for the same
##     reason: inside a page that defines `--left` and `--right` the picture
##     follows the page, including its light and dark themes.
##     Cost of fallback ink: on its own the picture is tuned to neither
##       ground, only readable on either.  Accepted -- a standalone file
##       cannot know the ground it will be shown on.

{.experimental: "strictFuncs".}

import std/[math, options, strutils]

import ./frame
import ./rotation



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
  FACING_X = 11    ## Column the follow's facing mark sits in, clear of the rest.
  BREAK_WIDTH = 11.0 ## Gap left in the link that passes underneath.


const
  COLOUR_LEFT = "var(--left, #2b6c8c)"
  COLOUR_RIGHT = "var(--right, #a85f22)"
  COLOUR_QUIET = "var(--rule-strong, #b9bfba)"
  COLOUR_CAPTION = "var(--faint, #9aa19d)"
  CAPTION_FONT = "font: 8px ui-sans-serif, system-ui, sans-serif"


func leadPoint(side: Side): (int, int) =
  ## Get where a hand of the lead is drawn.
  case side
  of Side.Left: (LEFT_X, LEAD_Y)
  of Side.Right: (RIGHT_X, LEAD_Y)


func followPoint(site: Site; facing = true): (int, int) =
  ## Get where a hand of the follow is drawn.
  ##   The follow faces the other way, so their right hand shares a column
  ##     with the lead's Left: that shared column is what makes a parallel
  ##     connection parallel.
  ##   Turned back to front, the columns swap.  This is the picture's half
  ##     of `crossedSite`: at half a turn the hand that was across the
  ##     midline is the near one, and a drawing that kept the follow's hands
  ##     where they were would be contradicting the one place the
  ##     hand-to-hand model reads rotation.
  let shown = if facing: site else: (
    case site
    of Site.RightHand: Site.LeftHand
    of Site.LeftHand: Site.RightHand)
  case shown
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


func link(side: Side; site: Site; is_under: bool; facing = true): string =
  ## Draw one connection, broken at the crossing where it passes underneath.
  let
    (x1, y1) = leadPoint(side)
    (x2, y2) = followPoint(site, facing)
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


func hand(point: (int, int); held: Option[Side]; leads: bool): string =
  ## Draw one hand: filled in the colour of the arm holding it, or left open.
  ##   The lead's hands are squares and the follow's are circles.  Which row
  ##     is whose was said only by the captions under and over the picture,
  ##     and those are the first thing to go when a frame is drawn small --
  ##     down the side of the matrix, or as a node on the map, they are a
  ##     smudge.  Shape survives any size, so the picture says it the way
  ##     the vocabulary does: whose hand it is, carried by the mark itself
  ##     rather than by a word beside it.
  ##     Cost of shape-coding: a square of a circle's measurement reads
  ##       larger than the circle, so the square is drawn to the circle's
  ##       width instead.
  let style =
    if held.isSome:
      "fill: " & colour(held.get) & "; stroke: " & colour(held.get)
    else:
      "fill: none; stroke: " & COLOUR_QUIET
  if leads:
    # Drawn to the circle's own width, so a square hand and a round one are the
    # same size on the page rather than the same measurement.
    "<rect x=\"" & $(point[0] - RADIUS) & "\" y=\"" & $(point[1] - RADIUS) &
      "\" width=\"" & $(RADIUS * 2) & "\" height=\"" & $(RADIUS * 2) &
      "\" rx=\"1.5\" style=\"" & style & "; stroke-width: 1.5\"/>"
  else:
    "<circle cx=\"" & $point[0] & "\" cy=\"" & $point[1] & "\" r=\"" & $RADIUS &
      "\" style=\"" & style & "; stroke-width: 1.5\"/>"


func facingMark(facing: bool): string =
  ## Draw which way the follow is facing, out at the edge where nothing else
  ## is.
  ##   Only when they have turned.  Every frame in the hand-to-hand half is
  ##     held facing, so a mark saying so on all of them says nothing on any
  ##     of them -- it is furniture in eight pictures to be information in
  ##     none.  A drawing carries a mark for what varies.
  if facing:
    return ""
  let reach = -5
  "<polyline points=\"" & $(FACING_X - 4) & "," & $(FOLLOW_Y - reach) & " " &
    $FACING_X & "," & $(FOLLOW_Y + reach) & " " & $(FACING_X + 4) & "," &
    $(FOLLOW_Y - reach) & "\" style=\"fill: none; stroke: " & COLOUR_QUIET &
    "; stroke-width: 1.4; stroke-linecap: round; stroke-linejoin: round\"/>"


func caption(x, y: int; text: string): string =
  ## Draw one edge label.
  "<text class=\"caption\" x=\"" & $x & "\" y=\"" & $y &
    "\" text-anchor=\"middle\" style=\"" & CAPTION_FONT & "; fill: " &
    COLOUR_CAPTION & "\">" & text & "</text>"



#[ Frames ]#

func frameBody(target: Frame; twist: HalfTurns): string =
  ## Draw the contents of a frame picture, without the frame around them.
  ##   The under-arm is drawn first so that the reading order of the markup
  ##     is the reading order of the picture, from the ground up.
  let facing = isFacing(twist)
  result = "<title>" & target.describe & "</title>"
  result.add line(MIDLINE_X.float, MIDLINE_TOP.float, MIDLINE_X.float,
    MIDLINE_BOTTOM.float,
    "stroke: " & COLOUR_QUIET & "; stroke-width: 1; stroke-dasharray: 3 4")

  # The links, under-arm first, so the ink stacks from the ground up.
  var order = @[Side.Left, Side.Right]
  if target.over == some(Side.Left):
    order = @[Side.Right, Side.Left]
  for side in order:
    if target.hold[side].isSome:
      result.add link(side, target.hold[side].get,
        target.over == some(other(side)), facing)

  # The hands go over the links they anchor.
  for side in Side:
    result.add hand(leadPoint(side),
      (if target.hold[side].isSome: some(side) else: none(Side)), leads = true)
  for site in Site:
    result.add hand(followPoint(site, facing), target.holder(site), leads = false)

  # The captions travel with the hands they name, so a turned follow reads as
  # turned rather than as a picture whose labels are wrong.
  result.add caption(LEFT_X, CAPTION_TOP_Y, (if facing: "right" else: "left"))
  result.add caption(RIGHT_X, CAPTION_TOP_Y, (if facing: "left" else: "right"))
  result.add caption(LEFT_X, CAPTION_BOTTOM_Y, "Left")
  result.add caption(RIGHT_X, CAPTION_BOTTOM_Y, "Right")
  result.add facingMark(facing)


func frameHeight*(width: int): int =
  ## Get how tall a frame picture is when drawn to a given width.
  (width * HEIGHT) div WIDTH


func renderFrame*(target: Frame; twist: HalfTurns = 0): string =
  ## Draw a frame as a picture that stands on its own.
  ##   Given a twist it draws the posture instead: the same frame, seen with
  ##     the follow turned as far as that twist has turned them.
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " & $WIDTH & " " &
    $HEIGHT & "\" class=\"frame\" role=\"img\">" & frameBody(target, twist) & "</svg>"


func renderFramePlaced*(target: Frame; x, y, width: int;
    twist: HalfTurns = 0): string =
  ## Draw a frame picture at a place inside a larger drawing.
  ##   The same body, given its own viewport: a nested picture keeps its own
  ##     coordinates, so the drawing around it never has to know how a frame
  ##     is made.
  "<svg x=\"" & $x & "\" y=\"" & $y & "\" width=\"" & $width & "\" height=\"" &
    $frameHeight(width) & "\" viewBox=\"0 0 " & $WIDTH & " " & $HEIGHT &
    "\" class=\"frame\">" & frameBody(target, twist) & "</svg>"
