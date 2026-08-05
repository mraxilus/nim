## Draw the whole ontology as one picture: the frames as places, the moves as
## the ways between them.
##
## The graph is laid out in rows by how many connections a frame carries, which
## makes the direction of a move readable from the drawing alone: every step down
## the page adds a connection and is a `collect`, every step up releases one and
## is a `drop`.  So an edge needs to say only which arm acts, and the row it
## moves between says the rest.
##
## Each edge stands for the pair of moves that cross it, because every move
## reverses.  Twenty moves are ten lines.  The compounds are drawn too, dashed
## and curved, because they join frames that no single move joins: they are the
## shape of the graph rather than an edge of it.

{.experimental: "strictFuncs".}

import std/[algorithm, math, options, strutils]

import ./diagram
import ./frame
import ./motion
import ./transition



#[ Layout ]#

const
  MAP_WIDTH* = 780
  MAP_HEIGHT* = 640
  MARGIN = 44
  ROW_Y = [70, 265, 510] ## Row for each number of connections a frame can carry.
  NODE_WIDTH* = 74
  NAME_RISE = 12 ## Distance from the top of a picture up to its name.
  ARC_DIP = 100  ## How far a compound curve hangs below the row it joins.


const NODE_ORDER* = ["--.", "-r.", "l-.", "-l.", "r-.", "lrL", "lrR", "rl."]
  ## Order the frames along their rows, left to right.
  ##
  ## This is a drawing decision rather than a fact about dancing: the order is
  ## the one that leaves the fewest lines crossing.  `tests/tmap.nim` holds it to
  ## naming every frame exactly once, so a frame cannot be added to the ontology
  ## and quietly left out of the picture.


func rowOf(target: Frame): int = target.countHolds
  ## Get the row a frame is drawn in.


func placeOf(target: Frame): int =
  ## Get the position of a frame along its row, counting from the left.
  for key in NODE_ORDER:
    let candidate = fromKey(key)
    if candidate.isNone or candidate.get == target:
      break
    if rowOf(candidate.get) == rowOf(target):
      inc result


func rowSize(row: int): int =
  ## Count the frames drawn in one row.
  for key in NODE_ORDER:
    let candidate = fromKey(key)
    if candidate.isSome and rowOf(candidate.get) == row:
      inc result


func centreOf*(target: Frame): (int, int) =
  ## Get the middle of the place a frame is drawn in.
  let
    span = MAP_WIDTH - 2 * MARGIN
    size = rowSize(rowOf(target))
    step = span div size
  (MARGIN + step * placeOf(target) + step div 2, ROW_Y[rowOf(target)])



#[ Ink ]#

const
  COLOUR_LEFT = "var(--left, #2b6c8c)"
  COLOUR_RIGHT = "var(--right, #a85f22)"
  COLOUR_INK = "var(--ink, #1a1f1e)"
  COLOUR_DIM = "var(--dim, #6b716e)"
  LABEL_FONT = "font: 11px ui-sans-serif, system-ui, sans-serif"
  LINE_HEIGHT = 12
  NAME_FONT = "font: 11px ui-sans-serif, system-ui, sans-serif"


func armColour(side: Side): string =
  ## Get the ink one arm of the lead is drawn in.
  case side
  of Side.Left: COLOUR_LEFT
  of Side.Right: COLOUR_RIGHT



#[ Elements ]#

func text(x, y: int; body, style: string; classes = "map-label"): string =
  ## Draw one label, centred on a point.
  "<text class=\"" & classes & "\" x=\"" & $x & "\" y=\"" & $y &
    "\" text-anchor=\"middle\" style=\"" & style & "\">" & body & "</text>"


func widest(lines: seq[string]): int =
  ## Get the length of the longest line, in characters.
  for line in lines:
    result = max(result, line.len)


func stack(x, y: int; lines: seq[string]; style, plate_class: string): string =
  ## Draw a label of several short lines, centred on a point, over a plate.
  ##
  ## Stacking is what lets a label sit beside a line without reaching across the
  ## drawing: three short words are a third of the width of one long phrase.
  let
    height = lines.len * LINE_HEIGHT + 4
    width = widest(lines) * 6 + 14
    top = y - height div 2
  result = "<rect class=\"" & plate_class & "\" x=\"" & $(x - width div 2) &
    "\" y=\"" & $top & "\" width=\"" & $width & "\" height=\"" & $height &
    "\" rx=\"3\"/>"
  for index, line in lines:
    result.add text(x, top + LINE_HEIGHT * (index + 1) - 1, line, style)


func waking(now, was, moving: bool): string =
  ## Say how something's standing is changing while the mark is on its way.
  ##
  ## The map is drawn as the frame being reached will have it, and whatever that
  ## changes is faded from how the frame being left had it.  What is left when
  ## the mark lands is then already the drawing for where it landed, so the page
  ## can replace one with the other and nothing moves.
  if not moving or now == was: ""
  elif now: " waking"
  else: " dozing"


type Box* = tuple[x, y, w, h: int] ## Room something takes up in the drawing.


func overlaps*(a, b: Box): bool =
  ## Test whether two things in the drawing would be drawn over each other.
  a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h


func labelBox(x, y: int; lines: seq[string]): Box =
  ## Get the room a name takes up, centred on a point.
  let
    w = widest(lines) * 6 + 14
    h = lines.len * LINE_HEIGHT + 4
  (x - w div 2, y - h div 2, w, h)


func frameBoxes*(): seq[Box] =
  ## Get the room every frame on the map takes up: its picture, and its name.
  ##
  ## Two boxes rather than one around both, because a frame's name is often much
  ## wider than the frame and sits only above it.  One box around the pair would
  ## claim the space either side of the picture that nothing is in, and there is
  ## little enough room on this drawing as it is.
  for target in FRAMES:
    let
      (cx, cy) = centreOf(target)
      h = frameHeight(NODE_WIDTH)
      named = target.describe.len * 6 + 10
    result.add (cx - NODE_WIDTH div 2 - 8, cy - h div 2 - 6,
      NODE_WIDTH + 16, h + 12)
    result.add (cx - named div 2, cy - h div 2 - NAME_RISE - 11, named, 15)


const
  LABEL_ALONGS = [62, 44, 76, 34, 86, 26, 53, 69, 39, 81, 30, 90]
    ## Places along a line a name will sit, in hundredths, in order of preference.
  LABEL_ASIDES = [0, -26, 26, -48, 48, -72, 72, -96, 96]
    ## Distances a name may be nudged off its line, if nowhere on it is clear.
    ##
    ## Naming every line rather than only the ones underfoot means ten names in a
    ## drawing that used to hold three, and at one fixed place along they land on
    ## top of each other where the lines converge.  A name takes the first place
    ## that is clear of everything already drawn, so the drawing spreads them out
    ## itself rather than being hand-placed and going stale the next time a frame
    ## or a word changes.


func isClear(box: Box; used: seq[Box]): bool =
  ## Test whether something can be drawn here without landing on anything else.
  for other in used:
    if overlaps(box, other):
      return false
  true


func placeBelow(x, y: int; lines: seq[string]; used: var seq[Box]): (int, int) =
  ## Get where a curve's name can sit, sinking it until it is clear.
  for drop in [0, 22, -22, 44, -44, 66, 88]:
    let box = labelBox(x, y + drop, lines)
    if box.isClear(used):
      used.add box
      return (x, y + drop)
  used.add labelBox(x, y, lines)
  (x, y)


func placeLabel(ax, ay, bx, by: int; lines: seq[string];
    used: var seq[Box]): (int, int) =
  ## Get where a name can sit near its line without landing on anything else.
  let
    run = bx - ax
    rise = by - ay
    length = max(1, int(sqrt(float(run * run + rise * rise))))
  for aside in LABEL_ASIDES:
    for along in LABEL_ALONGS:
      let
        x = ax + run * along div 100 - rise * aside div length
        y = ay + rise * along div 100 + run * aside div length
        box = labelBox(x, y, lines)
      if box.isClear(used):
        used.add box
        return (x, y)
  # Nowhere is clear, so take the place it would have had and let it crowd: a
  # name in the wrong place still says more than no name at all.
  let
    x = ax + run * LABEL_ALONGS[0] div 100
    y = ay + rise * LABEL_ALONGS[0] div 100
  used.add labelBox(x, y, lines)
  (x, y)


func edge(a, b: Frame; side: Side; standing, was, taken: Option[Frame];
    used: var seq[Box]): string =
  ## Draw the pair of moves that join two frames, and name them.
  ##
  ## Named for the move that runs *down* the page, which is the collect: the rows
  ## say that much on their own, so the drop is the same line read upwards and
  ## needs no second name.  Naming every line rather than only the ones underfoot
  ## means the map can be read as a map, by somebody not standing on it.
  let
    (ax, ay) = centreOf(a)
    (bx, by) = centreOf(b)
    is_lit = standing == some(a) or standing == some(b)
    was_lit = was == some(a) or was == some(b)
    # The line the mark is travelling along, while it is travelling along it.
    is_taken = (was == some(a) and taken == some(b)) or
      (was == some(b) and taken == some(a))
    marks = (if is_lit: " lit" else: "") & (if is_taken: " taking" else: "") &
      waking(is_lit, was_lit, was.isSome)
  # A line and the name of the line are one thing, and dim or come forward as
  # one: a name without its line to belong to says nothing.
  result = "<g class=\"way" & marks & "\">" &
    "<line class=\"edge\" x1=\"" & $ax & "\" y1=\"" & $ay &
    "\" x2=\"" & $bx & "\" y2=\"" & $by & "\" style=\"stroke: " &
    armColour(side) & "\"/>"
  let
    upper = if rowOf(a) < rowOf(b): a else: b
    lower = if rowOf(a) < rowOf(b): b else: a
    helper = classify(upper, lower).get
    naming = label(upper, Move(helper: helper, side: side, to: lower))
    (sx, sy) = centreOf(upper)
    (dx, dy) = centreOf(lower)
  # The name sits along the line, wherever along it there is room.
  let (nx, ny) = placeLabel(sx, sy, dx, dy, naming, used)
  result.add stack(nx, ny, naming,
    LABEL_FONT & "; fill: " & armColour(side), "edge-plate")
  result.add "</g>"


func arc(a, b: Frame; name: string; standing, was: Option[Frame];
    used: var seq[Box]): string =
  ## Draw a compound as a curve, since no single move joins the two frames.
  let
    (ax, ay) = centreOf(a)
    (bx, by) = centreOf(b)
    mx = (ax + bx) div 2
    dip = ARC_DIP + (abs(ax - bx) div 5)
    is_lit = standing == some(a) or standing == some(b)
    was_lit = was == some(a) or was == some(b)
    lit = (if is_lit: " lit" else: "") & waking(is_lit, was_lit, was.isSome)
  result = "<g class=\"join" & lit & "\">" &
    "<path class=\"arc\" d=\"M" & $ax & " " & $ay & "Q" & $mx &
    " " & $(max(ay, by) + dip) & " " & $bx & " " & $by & "\"/>"
  # A curve is at its lowest halfway along, which is half the dip below the row.
  let (nx, ny) = placeBelow(mx, max(ay, by) + dip div 2 + 4, @[name], used)
  result.add stack(nx, ny, @[name],
    LABEL_FONT & "; fill: " & COLOUR_DIM, "arc-plate")
  result.add "</g>"


func nodeAt*(target: Frame; cx, cy, width: int; classes: string;
    extra = ""): string =
  ## Draw one frame at a place, with its name above it.
  ##
  ## Both drawings put frames somewhere; only they know where.  Keeping the
  ## drawing of a node here means the two agree on what a frame looks like even
  ## though they disagree about everything else.
  let height = frameHeight(width)
  result = "<g class=\"node " & classes & "\" data-frame=\"" & target.key &
    "\"" & extra & ">"
  result.add "<rect class=\"node-plate\" x=\"" & $(cx - width div 2 - 8) &
    "\" y=\"" & $(cy - height div 2 - 6) & "\" width=\"" & $(width + 16) &
    "\" height=\"" & $(height + 12) & "\" rx=\"8\"/>"
  result.add renderFramePlaced(target, cx - width div 2, cy - height div 2, width)
  # The name goes above the picture, leaving the space below for the curves.
  result.add text(cx, cy - height div 2 - NAME_RISE, target.describe,
    NAME_FONT & "; fill: " & COLOUR_INK, "node-name")
  result.add "</g>"


func standingOf(target: Frame; where: Option[Frame]): (bool, bool, bool) =
  ## Get how a frame stands to wherever the couple are: held, reachable, or two.
  if where.isNone:
    return (false, false, false)
  (where == some(target), classify(where.get, target).isSome,
    compound(where.get, target).isSome)


func markAt*(cx, cy, width: int; extra = ""): string =
  ## Draw the mark that says which frame is being held.
  ##
  ## Its own element rather than a heavier line on the frame's own plate, because
  ## it has to be able to leave one frame and arrive at another: taking a move is
  ## the mark passing along the way taken, and a mark that were part of a frame
  ## could only blink from one to the other.
  ##
  ## Drawn to the shape of a frame's plate, from the same numbers, so that both
  ## drawings say *here* with the same ring in the same place.  A drawing that
  ## also thickened the plate underneath would be saying it twice.
  let height = frameHeight(width)
  "<rect class=\"mark\" x=\"" & $(cx - width div 2 - 8) & "\" y=\"" &
    $(cy - height div 2 - 6) & "\" width=\"" & $(width + 16) & "\" height=\"" &
    $(height + 12) & "\" rx=\"8\"" & extra & "/>"


func node(target: Frame; standing, was: Option[Frame]): string =
  ## Draw one frame in its row, on the map of everything.
  let
    (cx, cy) = centreOf(target)
    (is_here, is_reachable, is_compound) = standingOf(target, standing)
    (was_here, was_reachable, was_compound) = standingOf(target, was)
    within = is_here or is_reachable or is_compound
  nodeAt(target, cx, cy, NODE_WIDTH,
    (if is_here: "here " else: "") & (if is_reachable: "reachable " else: "") &
    (if is_compound: "two" else: "") &
    waking(within, was_here or was_reachable or was_compound, was.isSome))



#[ The Map ]#

const WIDE_TEMPO* = Tempo(
  ## Hold how long this drawing takes to say a move.
  ##
  ## Every frame is already drawn and in its place, so there is nothing to clear
  ## before the mark can move and nothing to build after it: the mark goes, what
  ## is within reach of it changes as it goes, and the drawing has finished.
  ## Made to wait out the close drawing's clauses it would only look stuck.
  pass_at: 0,
  pass: 260,
  settle: SEAM_MARGIN,
  grown: 0,
)


func renderMap*(here: Option[Frame]; motion = Motion.Still;
    taken = none(Frame)): string =
  ## Draw the graph, with the couple standing on one frame if they are dancing.
  ##
  ## While a move is being made this is drawn as the frame being *reached* will
  ## have it, with whatever that changes fading from how the frame being left had
  ## it.  The mark is the exception: it starts where the couple are and carries
  ## the distance to where they are going, which is the move itself.  So what the
  ## drawing settles into is already the drawing for where the mark lands.
  let
    leaving = motion == Motion.Leaving and taken.isSome
    standing = if leaving: taken else: here
    was = if leaving: here else: none(Frame)
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " &
    $MAP_WIDTH & " " & $MAP_HEIGHT & "\" class=\"map" &
    (if leaving: " leaving" else: "") &
    (if here.isNone: " unread" else: "") & "\" style=\"" &
    passStyle(WIDE_TEMPO) & "\" role=\"img\">" &
    "<title>Every frame, and every move between them</title>"

  # Everything already in the drawing, so that no name is put on top of it.  The
  # curves go down first because each has only the one place it can be named.
  var used = frameBoxes()
  var curves = ""
  var drawn: seq[string] = @[]
  for source in FRAMES:
    for target in FRAMES:
      let named = compound(source, target)
      if named.isNone:
        continue
      let pair = sorted(@[source.key, target.key]).join("-")
      if pair in drawn:
        continue
      drawn.add pair
      curves.add arc(source, target, ($named.get).toLowerAscii, standing, was, used)

  drawn = @[]
  for source in FRAMES:
    for move in moves(source):
      let pair = sorted(@[source.key, move.to.key]).join("-")
      if pair in drawn:
        continue
      drawn.add pair
      result.add edge(source, move.to, move.side, standing, was, taken, used)
  result.add curves

  for target in FRAMES:
    result.add node(target, standing, was)

  if here.isSome:
    # The mark sits on the frame held and, while a move is being made, carries
    # the distance to the frame chosen: taking a move is the mark passing along
    # the line between them, which is the same thing the close drawing says.
    let
      (hx, hy) = centreOf(here.get)
      (tx, ty) = if leaving: centreOf(taken.get) else: (hx, hy)
    # Placed by where it is rather than moved to it, so that the distance it
    # carries is a distance to travel and not a place to jump to.
    result.add markAt(hx, hy, NODE_WIDTH, " style=\"--mx: " & $(tx - hx) &
      "px; --my: " & $(ty - hy) & "px\"")
  result.add "</svg>"
