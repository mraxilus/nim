## Draw only where the couple are and where they can go next.
##
##   The map of everything answers "what is there"; this answers "what now".
##     The frame the couple hold sits in the middle, and every move away
##     from it is a spoke: nothing else is drawn.
##     Cost of drawing nothing else: the whole ontology is not visible here
##       -- the map keeps that job.  Accepted -- everything else is a
##       distraction from the one decision being made.
##   The spokes keep the map's sense of direction.  A `collect` takes a
##     hand, so it points up; a `drop` releases one, so it points down; a
##     compound is two moves and goes out to the side.  A dancer who has
##     read one drawing can read the other.
##   The frame the couple came from is remembered so that the drawing can
##     start it where it was and let it arrive: the spoke that was taken
##     becomes the middle, which is what taking it means.
##   Every frame is drawn in one fixed space, so a coordinate means the same
##     place whichever frame is held, and a node can travel from where it
##     was to where it is.  What changes between frames is the *window* on
##     that space, cut to what that frame needs: a frame whose ways out all
##     point up has nothing below it and is seen through a shorter window
##     than one with ways out both ways.
##     Cost of one space for every frame: any one frame fills a corner of
##       it, so each must be seen through its own window, and window and
##       drawing have to move together -- which is what makes a change of
##       frame one movement rather than a cut.

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
  NODE_WIDTH = 112
    ## Width every frame in the drawing is drawn at, the one held included.
    ##   One size for all of them, because the frame chosen stays on the
    ##     screen across the moment the drawing is replaced: drawn at two
    ##     sizes it would have to be scaled from one to the other, and a
    ##     node's plate and its name do not scale with its width, so the two
    ##     would never quite line up.  Which frame is held is said by the
    ##     mark around it instead of by its size.
  SPOKE_RADIUS = 240 ## Length of a lone spoke; a crowded one reaches further.
  SPOKE_STEP = 40.0  ## Angle between two spokes of the same kind, in degrees.
  LINE_HEIGHT = 12   ## Height of one line of a name.
  LABEL_SIZE* = 11   ## Size a name is drawn at, in the drawing's own units.
  LEAST_READABLE* = 8
    ## Smallest a name may end up on a screen, once the drawing has been
    ## shrunk.
    ##   The drawing shrinks to whatever room there is, and the whole of it
    ##     shrinks together, names included.  Past this the names are shapes
    ##     rather than words, and a drawing of your options whose options
    ##     cannot be read is not worth fitting: below it the drawing keeps
    ##     its size and scrolls instead.
  NAME_ROOM = 24     ## Room a frame's own name takes above it.
  LABEL_DROP = 6     ## Gap between a frame and the name of the move that reaches it.
  ##   A move is named under the frame it arrives in rather than along the
  ##     line that leads there.  Along the line, four names leaving one
  ##     middle crowd each other however far out they are put; under the
  ##     frames, they are as far apart as the frames are.
  UP = 270.0        ## Direction a collect points, in degrees clockwise from east.
  DOWN = 90.0       ## Direction a drop points.
  ASIDE = 0.0       ## Direction a compound points.


#[ Tempo ]#

const
  FOLD_SPREAD* = 60
    ## Budget for starting one way folding after another, in milliseconds.
  FOLD_LAG* = 50
    ## How far behind its own leaf a branch begins to fold.
  FOLD_LEAF* = 120
    ## Folding one leaf away: a leaf growing, run backwards.
  FOLD_BRANCH* = 110
    ## Folding one branch back into the middle: a branch growing, run backwards.
  SHRINK_TIME* = 140
    ## Shrinking away the frame left behind, once the mark has left it.
  CENTRE_TIME* = 340
    ## Recentring the drawing on the frame reached, which is now all there is.
  GROW_DELAY* = 50
    ## Wait after the drawing is replaced before the first new way grows.
  GROW_SPREAD* = 90
    ## Budget for starting one way growing after another.
  LEAF_DELAY* = 100
    ## Wait between a branch growing and its own leaf, which is what makes the
    ## drawing read as branches first and leaves after rather than as one bloom.
  GROW_TIME* = 170
    ## Growing one branch, or one leaf once its branch has arrived.


const CLOSE_TEMPO* = Tempo(
  ## Hold how long this drawing takes to say a move.
  ##   It has the most to do of any of them: the ways not taken have to be
  ##     out of the way before the mark can move, and the ways out of the
  ##     frame reached have to be built afterwards, so the mark sets off
  ##     late and the drawing is still working long after it has arrived.
  pass_at: FOLD_SPREAD + FOLD_LAG + FOLD_BRANCH,
  pass: 200,
  settle: SHRINK_TIME + CENTRE_TIME + SEAM_MARGIN,
  grown: GROW_DELAY + GROW_SPREAD + LEAF_DELAY + GROW_TIME,
)


const
  SHRINK_AT* = CLOSE_TEMPO.pass_at + CLOSE_TEMPO.pass
    ## When the frame left behind starts to go, which is once the mark has left.
  CENTRE_AT* = SHRINK_AT + SHRINK_TIME
    ## When the drawing starts recentring on the one frame left in it.


func closeStyle*(): string =
  ## Write this drawing's own times onto it, beside the ones every drawing has.
  passStyle(CLOSE_TEMPO) & "; --fold-spread: " & $FOLD_SPREAD &
    "ms; --fold-lag: " & $FOLD_LAG & "ms; --fold-leaf: " & $FOLD_LEAF &
    "ms; --fold-branch: " & $FOLD_BRANCH & "ms; --shrink-at: " & $SHRINK_AT &
    "ms; --shrink: " & $SHRINK_TIME & "ms; --centre-at: " & $CENTRE_AT &
    "ms; --centre: " & $CENTRE_TIME & "ms; --grow-delay: " & $GROW_DELAY &
    "ms; --grow-spread: " & $GROW_SPREAD & "ms; --leaf-delay: " & $LEAF_DELAY &
    "ms; --grow: " & $GROW_TIME & "ms" &
    # The drawing is laid out in numbers rather than lengths so that the
    # stylesheet can divide the room it has by them; these are what it
    # multiplies them back up by, and how far down it may go.
    "; --least-unit: " & formatFloat(LEAST_READABLE / LABEL_SIZE, ffDecimal, 3) &
    "px"



type
  Spoke* = object ## Hold one way out of the frame the couple are holding.
    to*: Frame           ## Frame it arrives in.
    side*: Side          ## Arm that acts, which is the ink it is drawn in.
    lines*: seq[string]  ## Name of the move, a line at a time.
    is_compound*: bool   ## Whether it is two moves rather than one.
    back*: Option[Side]  ## Arm that acts coming the other way, where they differ.
    angle*: float        ## Direction it leaves the middle, in degrees.
    radius*: int         ## How far out it puts the frame it arrives in.
    turn*: int           ## Its place in the order the ways grow and fold.


func spokesOf*(here: Frame): seq[Spoke] =
  ## Get every way out of a frame, in the order they are drawn.
  ##   Collects, then drops, then compounds: the order the eye reads them
  ##     in, up the page and then down it and then out to the side.
  for helper in [Helper.Collect, Helper.Drop]:
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
    let base = if helper == Helper.Collect: UP else: DOWN
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
    # A compound hands the follow's hand from one of the lead's arms to the
    # other, so it has an arm going out and a different one coming back.  The
    # drawing is inked in both: one arm for a line that only ever means one.
    named.add Spoke(
      to: target,
      side: compoundSide(here, target).get,
      back: compoundSide(target, here),
      lines: @[compoundName(here, target), "two moves"],
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
  (x, y + frameHeight(NODE_WIDTH) div 2 + LABEL_DROP +
    (spoke.lines.len * LINE_HEIGHT + 4) div 2)



#[ Ink ]#

const
  COLOUR_QUIET = "var(--dim, #6b716e)"
    ## Ink for a name whose line has no one ink of its own to lend it.
  LABEL_FONT = "font: " & $LABEL_SIZE & "px ui-sans-serif, system-ui, sans-serif"

  ## The arm inks come from `map.armColour`, which this drawing shares rather
  ## than repeats: the two views draw one ontology and a reader moves between
  ## them, so a line that changed hue on the way would be saying something.


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
  ##   A frame with only collects has nothing below it and a frame with only
  ##     drops has nothing above, so the box that holds one frame is not the
  ##     box that holds another.  This is what the window is cut to; it is
  ##     not what the frame is drawn in.
  const PAD = 14
  # A frame's name is often wider than the frame it names, and a name is part of
  # the drawing: a box measured to the pictures alone would cut the words off.
  var
    left = CENTRE_X - max(NODE_WIDTH div 2 + 8, textHalf(here.describe))
    right = CENTRE_X + max(NODE_WIDTH div 2 + 8, textHalf(here.describe))
    top = CENTRE_Y - frameHeight(NODE_WIDTH) div 2 - NAME_ROOM
    bottom = CENTRE_Y + frameHeight(NODE_WIDTH) div 2 + 6
  for spoke in spokesOf(here):
    let
      (x, y) = endOf(spoke)
      (_, ly) = labelAt(spoke)
      # Measured at the size a way out grows to when it is the one taken, since
      # it grows where it stands and a window cut any tighter would clip it.
      half = max(max(widest(spoke.lines), spoke.to.describe.len) * 3 + 7,
        NODE_WIDTH div 2 + 8)
    left = min(left, x - half)
    right = max(right, x + half)
    top = min(top, y - frameHeight(NODE_WIDTH) div 2 - NAME_ROOM)
    bottom = max(bottom, max(ly + (spoke.lines.len * LINE_HEIGHT + 4) div 2,
      y + frameHeight(NODE_WIDTH) div 2))
  (left - PAD, top - PAD, right - left + 2 * PAD, bottom - top + 2 * PAD)


func spokesBox(): (int, int, int, int) {.compileTime.} =
  ## Get the one space every frame is drawn in: the box that holds them all.
  ##   Fitting the space to each frame would move the middle from frame to
  ##     frame, and a node travelling in from where it was would be
  ##     travelling in a coordinate system that had changed under it.  One
  ##     space for all of them means a place is a place, and the window does
  ##     the fitting instead.
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
  ##   A frame with only collects has nothing below it, so a window that
  ##     reserved room below would be mostly empty.  The window is cut to
  ##     the drawing and the drawing slides under it, which is why both have
  ##     to move together.
  extentOf(here)


func panOf*(window: (int, int, int, int)): (int, int) =
  ## Get where the drawing sits behind a window, so the window shows that part.
  (SPOKES_BOX[0] - window[0], SPOKES_BOX[1] - window[1])



#[ The Drawing ]#

func spokeClass(spoke: Spoke; motion: Motion; taken: Option[Frame]): string =
  ## Say what one way out of the frame is doing while the couple move.
  result = "spoke" & (if spoke.is_compound: " two" else: "")
  if motion != Motion.Leaving:
    return
  result.add(if taken == some(spoke.to): " taken" else: " going")


func renderSpokes*(here: Frame; motion = Motion.Still;
    taken = none(Frame)): string =
  ## Draw the frame the couple hold, every way out of it, and the move being
  ## made.
  ##   While a move is being told, this draws the frame it is being made
  ##     *from*: the whole sentence -- the ways not taken folding, the mark
  ##     passing along the way taken, the frame left behind going, the
  ##     drawing recentring on the frame reached -- happens in this one
  ##     drawing, without the page touching it again.
  ##   What that leaves at the end is one frame, marked, in the middle of a
  ##     window cut for it, with nothing around it.  That is exactly the
  ##     drawing this function returns for that frame standing still, which
  ##     is why the page can replace the one with the other there and no
  ##     reader can tell.
  let
    (bx, by, bw, bh) = SPOKES_BOX
    leaving = motion == Motion.Leaving and taken.isSome
    window = windowOf(here)
    (px, py) = panOf(window)
  # Where the drawing has to end up for the frame reached to be sitting where a
  # frame it is holding sits: its own window, shifted by the distance from the
  # middle out to wherever along the drawing that frame is standing now.
  var
    reached = window
    (qx, qy) = (px, py)
    (mx, my) = (0, 0)
  if leaving:
    for spoke in spokesOf(here):
      if spoke.to != taken.get:
        continue
      let (ex, ey) = endOf(spoke)
      reached = windowOf(taken.get)
      let (rx, ry) = panOf(reached)
      (qx, qy) = (rx + CENTRE_X - ex, ry + CENTRE_Y - ey)
      (mx, my) = (ex - CENTRE_X, ey - CENTRE_Y)

  # Every number the animation spends is written here, so that the stylesheet
  # holds the shape of the movement and this holds its size.
  # The window and the pan are bare numbers, not lengths.  The stylesheet has to
  # divide the room it has by the width the drawing wants, and a length cannot
  # be divided by a length -- so the drawing hands over the numbers and takes
  # back one unit to multiply them by.  Everything the drawing is made of is a
  # multiple of that one unit, so scaling it is one value changing.
  #
  # `--mx`, `--my`, `--ox` and `--oy` stay lengths: they are read inside the
  # picture, in its own units, and scale with it already.
  result = "<div class=\"viewport " & phase(motion) & "\" style=\"" &
    closeStyle() & "; --bw: " & $bw & "; --bh: " & $bh &
    "; --w: " & $window[2] & "; --h: " & $window[3] &
    "; --px: " & $px & "; --py: " & $py &
    "; --to-w: " & $reached[2] & "; --to-h: " & $reached[3] &
    "; --to-px: " & $qx & "; --to-py: " & $qy &
    "; --mx: " & $mx & "px; --my: " & $my &
    "px; --ox: " & $CENTRE_X & "px; --oy: " & $CENTRE_Y & "px\">"
  result.add "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"" & $bx & " " &
    $by & " " & $bw & " " & $bh & "\" width=\"" & $bw & "\" height=\"" & $bh &
    "\" class=\"spokes\" role=\"img\">" &
    "<title>" & here.describe & ", and every move away from it</title>"

  # Each way out in turn: its branch from the middle, then the frame and
  # name it carries.
  let ways = spokesOf(here)
  for spoke in ways:
    let
      (x, y) = endOf(spoke)
      (lx, ly) = labelAt(spoke)
      colour = armColour(spoke.side)
      # A stagger is a share of one budget rather than a step of its own, so the
      # last way out finishes when the phase does however many there are.
      share =
        if ways.len < 2: "0"
        else: formatFloat(spoke.turn / (ways.len - 1), ffDecimal, 3)
    result.add "<g class=\"" & spokeClass(spoke, motion, taken) &
      "\" style=\"--turn: " & share & "; --lx: " & $x & "px; --ly: " & $y &
      "px\">"
    # A branch grows out of the middle and a leaf out of its own place, so each
    # carries the point it moves about rather than borrowing the drawing's.
    result.add "<g class=\"branch\">"
    if spoke.back.isSome and spoke.back.get != spoke.side:
      # Two moves, two arms: inked from the middle out in the arm that acts
      # coming back, and from the halfway out in the arm that acts going.
      let (hx, hy) = ((CENTRE_X + x) div 2, (CENTRE_Y + y) div 2)
      result.add "<line class=\"spoke-line\" x1=\"" & $CENTRE_X & "\" y1=\"" &
        $CENTRE_Y & "\" x2=\"" & $hx & "\" y2=\"" & $hy & "\" style=\"stroke: " &
        armColour(spoke.back.get) & "\"/>"
      result.add "<line class=\"spoke-line\" x1=\"" & $hx & "\" y1=\"" & $hy &
        "\" x2=\"" & $x & "\" y2=\"" & $y & "\" style=\"stroke: " & colour &
        "\"/>"
    else:
      result.add "<line class=\"spoke-line\" x1=\"" & $CENTRE_X & "\" y1=\"" &
        $CENTRE_Y & "\" x2=\"" & $x & "\" y2=\"" & $y & "\" style=\"stroke: " &
        colour & "\"/>"
    result.add "</g>"
    result.add "<g class=\"leaf\">"
    result.add "<g class=\"bud\">" & nodeAt(spoke.to, x, y, NODE_WIDTH,
      (if spoke.is_compound: "two" else: "reachable")) & "</g>"
    result.add "<g class=\"tag\">" & naming(lx, ly, spoke.lines,
      (if spoke.is_compound: COLOUR_QUIET else: colour)) & "</g>"
    result.add "</g></g>"

  # The frame held, and then the mark on it: the mark is drawn last so that it
  # reads over whatever it is marking, and can leave without taking it along.
  result.add "<g class=\"core\">" &
    nodeAt(here, CENTRE_X, CENTRE_Y, NODE_WIDTH, "held") & "</g>"
  result.add markAt(CENTRE_X, CENTRE_Y, NODE_WIDTH)
  result.add "</svg></div>"
