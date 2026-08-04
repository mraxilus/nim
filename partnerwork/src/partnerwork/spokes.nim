## Draw only where the couple are and where they can go next.
##
## The map of everything answers "what is there"; this answers "what now".  The
## frame the couple hold sits in the middle, and every move away from it is a
## spoke: nothing else is drawn, because everything else is a distraction from
## the one decision being made.
##
## The spokes keep the map's sense of direction.  A `drop` releases a hand, so it
## points up; a `collect` takes one, so it points down; a compound is two moves
## and goes out to the side.  A dancer who has read one drawing can read the
## other.
##
## The frame the couple came from is remembered so that the drawing can start it
## where it was and let it arrive: the spoke that was taken becomes the middle,
## which is what taking it means.

{.experimental: "strictFuncs".}

import std/[math, options, strutils]

import ./diagram
import ./frame
import ./map
import ./transition



#[ Layout ]#

const
  SPOKES_WIDTH* = 660
  SPOKES_HEIGHT* = 640
  CENTRE_X = SPOKES_WIDTH div 2
  CENTRE_Y = 268
  CENTRE_WIDTH = 118 ## Width of the frame in the middle.
  SPOKE_WIDTH = 86  ## Width of a frame the couple could move to.
  SPOKE_RADIUS = 240 ## Length of a lone spoke; a crowded one reaches further.
  SPOKE_STEP = 40.0  ## Angle between two spokes of the same kind, in degrees.
  LINE_HEIGHT = 12   ## Height of one line of a name.
  NAME_ROOM = 24     ## Room a frame's own name takes above it.
  LABEL_DROP = 6     ## Gap between a frame and the name of the move that reaches it.
  ##
  ## A move is named under the frame it arrives in rather than along the line
  ## that leads there.  Along the line, four names leaving one middle crowd each
  ## other however far out they are put; under the frames, they are as far apart
  ## as the frames are.
  UP = 270.0        ## Direction a drop points, in degrees clockwise from east.
  DOWN = 90.0       ## Direction a collect points.
  ASIDE = 0.0       ## Direction a compound points.


type
  Spoke* = object ## Hold one way out of the frame the couple are holding.
    to*: Frame           ## Frame it arrives in.
    side*: Side          ## Arm that acts, which is the ink it is drawn in.
    lines*: seq[string]  ## Name of the move, a line at a time.
    is_compound*: bool   ## Whether it is two moves rather than one.
    angle*: float        ## Direction it leaves the middle, in degrees.
    radius*: int         ## How far out it puts the frame it arrives in.


func spokesOf*(here: Frame): seq[Spoke] =
  ## Get every way out of a frame, in the order they are drawn.
  ##
  ## Drops, then collects, then compounds: the order the eye reads them in, up
  ## the page and then down it and then out to the side.
  for helper in [Helper.Drop, Helper.Collect]:
    var kin: seq[Spoke] = @[]
    for move in moves(here):
      if move.helper != helper:
        continue
      kin.add Spoke(
        to: move.to,
        side: move.side,
        lines: label(here, move),
        is_compound: false,
      )
    # A crowded fan reaches further out, so that its spokes end up as far apart
    # as a pair of them would be.
    let base = if helper == Helper.Drop: UP else: DOWN
    for index, spoke in kin:
      var placed = spoke
      placed.angle = base + (index.float - (kin.len - 1).float / 2) * SPOKE_STEP
      placed.radius = SPOKE_RADIUS + (kin.len - 1) * 30
      result.add placed

  var named: seq[Spoke] = @[]
  for target in FRAMES:
    let compounded = compound(here, target)
    if compounded.isNone:
      continue
    named.add Spoke(
      to: target,
      side: actingSide(here, route(here, target)[0].to, Helper.Drop),
      lines: @[($compounded.get).toLowerAscii, "two moves"],
      is_compound: true,
    )
  for index, spoke in named:
    var placed = spoke
    placed.angle = ASIDE + (index.float - (named.len - 1).float / 2) * SPOKE_STEP
    placed.radius = SPOKE_RADIUS + (named.len - 1) * 30
    result.add placed


func endOf*(spoke: Spoke): (int, int) =
  ## Get where a spoke puts the frame it arrives in.
  let radians = spoke.angle * PI / 180
  (CENTRE_X + int(round(cos(radians) * spoke.radius.float)),
    CENTRE_Y + int(round(sin(radians) * spoke.radius.float)))


func labelAt*(spoke: Spoke): (int, int) =
  ## Get where the name of a spoke sits, under the frame it arrives in.
  let (x, y) = endOf(spoke)
  (x, y + frameHeight(SPOKE_WIDTH) div 2 + LABEL_DROP +
    (spoke.lines.len * LINE_HEIGHT + 4) div 2)


func offsetOf*(here, before: Frame): (int, int) =
  ## Get where the middle frame was drawn a moment ago, relative to the middle.
  ##
  ## When the couple take a spoke, the frame it arrives in becomes the middle.
  ## Starting it out where it was and letting it travel in is the whole of the
  ## animation: the drawing says the move was taken rather than that the world
  ## changed.
  if here == before:
    return (0, 0)
  for spoke in spokesOf(before):
    if spoke.to != here:
      continue
    let (x, y) = endOf(spoke)
    return (x - CENTRE_X, y - CENTRE_Y)
  (0, 0)



#[ Ink ]#

const
  COLOUR_LEFT = "var(--left, #2b6c8c)"
  COLOUR_RIGHT = "var(--right, #a85f22)"
  LABEL_FONT = "font: 11px ui-sans-serif, system-ui, sans-serif"


func armColour(side: Side): string =
  ## Get the ink one arm of the lead is drawn in.
  case side
  of Side.Left: COLOUR_LEFT
  of Side.Right: COLOUR_RIGHT


func widest(lines: seq[string]): int =
  ## Get the length of the longest line, in characters.
  for line in lines:
    result = max(result, line.len)


func naming(x, y: int; lines: seq[string]; colour: string): string =
  ## Draw the name of a spoke, over a plate so that it reads across its line.
  let
    height = lines.len * LINE_HEIGHT + 4
    width = widest(lines) * 6 + 14
    top = y - height div 2
  result = "<rect class=\"spoke-plate\" x=\"" & $(x - width div 2) & "\" y=\"" &
    $top & "\" width=\"" & $width & "\" height=\"" & $height & "\" rx=\"3\"/>"
  for index, line in lines:
    result.add "<text class=\"map-label\" x=\"" & $x & "\" y=\"" &
      $(top + LINE_HEIGHT * (index + 1) - 1) & "\" text-anchor=\"middle\"" &
      " style=\"" & LABEL_FONT & "; fill: " & colour & "\">" & line & "</text>"



#[ The Drawing ]#

func extentOf(here: Frame): (int, int, int, int) =
  ## Get the box the drawing needs, so that it is never mostly empty space.
  ##
  ## A frame with only collects has nothing above it and a frame with only drops
  ## has nothing below; a fixed box would leave half the drawing blank in either
  ## case.  The middle frame starts its travel outside this box, which is why the
  ## page lets the drawing overflow rather than making room for a moment of it.
  const PAD = 14
  var
    left = CENTRE_X - CENTRE_WIDTH div 2 - 8
    right = CENTRE_X + CENTRE_WIDTH div 2 + 8
    top = CENTRE_Y - frameHeight(CENTRE_WIDTH) div 2 - NAME_ROOM
    bottom = CENTRE_Y + frameHeight(CENTRE_WIDTH) div 2 + 6
  for spoke in spokesOf(here):
    let
      (x, y) = endOf(spoke)
      (_, ly) = labelAt(spoke)
      half = widest(spoke.lines) * 3 + 7
    left = min(left, min(x - SPOKE_WIDTH div 2 - 8, x - half))
    right = max(right, max(x + SPOKE_WIDTH div 2 + 8, x + half))
    top = min(top, y - frameHeight(SPOKE_WIDTH) div 2 - NAME_ROOM)
    bottom = max(bottom, ly + (spoke.lines.len * LINE_HEIGHT + 4) div 2)
  (left - PAD, top - PAD, right - left + 2 * PAD, bottom - top + 2 * PAD)


func renderSpokes*(here, before: Frame): string =
  ## Draw the frame the couple hold and every way out of it.
  let
    (dx, dy) = offsetOf(here, before)
    (vx, vy, vw, vh) = extentOf(here)
  # Drawn at its own size rather than stretched to the space it is given, so
  # that a frame is the same size whether it has two ways out of it or five.
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"" & $vx & " " &
    $vy & " " & $vw & " " & $vh & "\" width=\"" & $vw & "\" height=\"" & $vh &
    "\" class=\"spokes\" role=\"img\">" &
    "<title>" & here.describe & ", and every move away from it</title>"

  for index, spoke in spokesOf(here):
    let
      (x, y) = endOf(spoke)
      colour = armColour(spoke.side)
      classes = "spoke" & (if spoke.is_compound: " two" else: "")
      delay = " style=\"animation-delay: " & $(40 * index) & "ms\""
    result.add "<g class=\"" & classes & "\"" & delay & ">"
    result.add "<line class=\"spoke-line\" x1=\"" & $CENTRE_X & "\" y1=\"" &
      $CENTRE_Y & "\" x2=\"" & $x & "\" y2=\"" & $y & "\" style=\"stroke: " &
      colour & "\"/>"
    result.add nodeAt(spoke.to, x, y, SPOKE_WIDTH,
      (if spoke.is_compound: "two" else: "reachable"))
    let (lx, ly) = labelAt(spoke)
    result.add naming(lx, ly, spoke.lines, colour)
    result.add "</g>"

  result.add nodeAt(here, CENTRE_X, CENTRE_Y, CENTRE_WIDTH, "here",
    " id=\"core\" transform=\"translate(" & $dx & "," & $dy & ")\"")
  result.add "</svg>"
