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
##
## Every frame is drawn in one fixed space, so a coordinate means the same place
## whichever frame is held, and a node can travel from where it was to where it
## is.  What changes between frames is the *window* on that space, cut to what
## that frame needs: a frame whose ways out all point down has nothing above it
## and is seen through a shorter window than one with ways out both ways.  The
## window and the drawing behind it move together, which is what makes a change
## of frame one movement rather than a cut.

{.experimental: "strictFuncs".}

import std/[math, options, strutils]

import ./diagram
import ./frame
import ./map
import ./motion
import ./transition



#[ Layout ]#

const
  CENTRE_X = 330
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
    turn*: int           ## Its place in the order the ways grow and fold.


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

  for index in 0 ..< result.len:
    result[index].turn = index


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


func textHalf(text: string): int = text.len * 3 + 7
  ## Get how far a line of text reaches either side of the point it is centred on.


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



#[ The Space and the Window ]#

func extentOf(here: Frame): (int, int, int, int) =
  ## Get the box one frame's drawing needs, and no more.
  ##
  ## A frame with only collects has nothing above it and a frame with only drops
  ## has nothing below, so the box that holds one frame is not the box that holds
  ## another.  This is what the window is cut to; it is not what the frame is
  ## drawn in.
  const PAD = 14
  # A frame's name is often wider than the frame it names, and a name is part of
  # the drawing: a box measured to the pictures alone would cut the words off.
  var
    left = CENTRE_X - max(CENTRE_WIDTH div 2 + 8, textHalf(here.describe))
    right = CENTRE_X + max(CENTRE_WIDTH div 2 + 8, textHalf(here.describe))
    top = CENTRE_Y - frameHeight(CENTRE_WIDTH) div 2 - NAME_ROOM
    bottom = CENTRE_Y + frameHeight(CENTRE_WIDTH) div 2 + 6
  for spoke in spokesOf(here):
    let
      (x, y) = endOf(spoke)
      (_, ly) = labelAt(spoke)
      half = max(max(widest(spoke.lines), spoke.to.describe.len) * 3 + 7,
        SPOKE_WIDTH div 2 + 8)
    left = min(left, x - half)
    right = max(right, x + half)
    top = min(top, y - frameHeight(SPOKE_WIDTH) div 2 - NAME_ROOM)
    bottom = max(bottom, ly + (spoke.lines.len * LINE_HEIGHT + 4) div 2)
  (left - PAD, top - PAD, right - left + 2 * PAD, bottom - top + 2 * PAD)


func spokesBox(): (int, int, int, int) {.compileTime.} =
  ## Get the one space every frame is drawn in: the box that holds them all.
  ##
  ## Fitting the space to each frame would move the middle from frame to frame,
  ## and a node travelling in from where it was would be travelling in a
  ## coordinate system that had changed under it.  One space for all of them
  ## means a place is a place, and the window does the fitting instead.
  var (left, top, right, bottom) = (CENTRE_X, CENTRE_Y, CENTRE_X, CENTRE_Y)
  for here in FRAMES:
    let (x, y, w, h) = extentOf(here)
    left = min(left, x)
    top = min(top, y)
    right = max(right, x + w)
    bottom = max(bottom, y + h)
  (left, top, right - left, bottom - top)


const SPOKES_BOX* = spokesBox()
  ## Hold the space every frame is drawn in, as `x`, `y`, `width`, `height`.


const MIDDLE* = (CENTRE_X, CENTRE_Y)
  ## Hold the one place the frame being held is drawn, in every frame.


func windowOf*(here: Frame): (int, int, int, int) =
  ## Get the window one frame is seen through: exactly what that frame needs.
  ##
  ## A frame with only collects has nothing above it, so a window that reserved
  ## room above would be mostly empty.  The window is cut to the drawing and the
  ## drawing slides under it, which is why both have to move together.
  extentOf(here)


func panOf*(window: (int, int, int, int)): (int, int) =
  ## Get where the drawing sits behind a window, so the window shows that part.
  (SPOKES_BOX[0] - window[0], SPOKES_BOX[1] - window[1])


func carrying(window: (int, int, int, int)): string =
  ## Carry the window the drawing is to take, for the page to hand it over.
  let (px, py) = panOf(window)
  " data-w=\"" & $window[2] & "\" data-h=\"" & $window[3] &
    "\" data-px=\"" & $px & "\" data-py=\"" & $py & "\""



#[ The Drawing ]#

func spokeClass(spoke: Spoke; motion: Motion; taken: Option[Frame]): string =
  ## Say what one way out of the frame is doing while the couple move.
  result = "spoke" & (if spoke.is_compound: " two" else: "")
  if motion != Motion.Leaving:
    return
  result.add(if taken == some(spoke.to): " taken" else: " going")


func renderSpokes*(here, before: Frame; motion = Motion.Still;
    taken = none(Frame)): string =
  ## Draw the frame the couple hold, every way out of it, and what is moving.
  ##
  ## An arriving frame is drawn in the window of the frame it came from, and
  ## carries the window it is going to.  Handing that over once the page has been
  ## laid out sends the window and the frame in flight the same way at the same
  ## time: they arrive together, rather than the drawing settling and the window
  ## catching up afterwards.
  let
    (bx, by, bw, bh) = SPOKES_BOX
    (dx, dy) = offsetOf(here, before)
    shut = windowOf(here)
    start = if motion == Motion.Arriving: windowOf(before) else: shut
  # Every number the animation spends is written here, so that the stylesheet
  # holds the shape of the movement and this holds its size.
  let (px, py) = panOf(start)
  result = "<div class=\"viewport " & phase(motion) & "\" style=\"" &
    motionStyle() & "; --w: " & $start[2] & "px; --h: " & $start[3] &
    "px; --px: " & $px & "px; --py: " & $py &
    "px; --ox: " & $CENTRE_X & "px; --oy: " & $CENTRE_Y & "px; --swell: " &
    formatFloat(CENTRE_WIDTH / SPOKE_WIDTH, ffDecimal, 3) & "\"" &
    carrying(shut) & ">"
  result.add "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"" & $bx & " " &
    $by & " " & $bw & " " & $bh & "\" width=\"" & $bw & "\" height=\"" & $bh &
    "\" class=\"spokes\" role=\"img\">" &
    "<title>" & here.describe & ", and every move away from it</title>"

  for spoke in spokesOf(here):
    let
      (x, y) = endOf(spoke)
      (lx, ly) = labelAt(spoke)
      colour = armColour(spoke.side)
    result.add "<g class=\"" & spokeClass(spoke, motion, taken) &
      "\" style=\"--turn: " & $spoke.turn & "\">"
    # A branch grows out of the middle and a leaf out of its own place, so each
    # carries the point it moves about rather than borrowing the drawing's.
    result.add "<g class=\"branch\">" &
      "<line class=\"spoke-line\" x1=\"" & $CENTRE_X & "\" y1=\"" & $CENTRE_Y &
      "\" x2=\"" & $x & "\" y2=\"" & $y & "\" style=\"stroke: " & colour &
      "\"/></g>"
    result.add "<g class=\"leaf\" style=\"--lx: " & $x & "px; --ly: " & $y &
      "px\">"
    result.add "<g class=\"bud\">" & nodeAt(spoke.to, x, y, SPOKE_WIDTH,
      (if spoke.is_compound: "two" else: "reachable")) & "</g>"
    result.add "<g class=\"tag\">" & naming(lx, ly, spoke.lines, colour) & "</g>"
    result.add "</g></g>"

  result.add nodeAt(here, CENTRE_X, CENTRE_Y, CENTRE_WIDTH, "here",
    " id=\"core\" transform=\"translate(" & $dx & "," & $dy & ")\"")
  result.add "</svg></div>"
