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

import std/[algorithm, options, strutils]

import ./diagram
import ./frame
import ./transition



#[ Layout ]#

const
  MAP_WIDTH* = 780
  MAP_HEIGHT* = 575
  MARGIN = 44
  ROW_Y = [70, 250, 450] ## Row for each number of connections a frame can carry.
  NODE_WIDTH = 74
  NAME_RISE = 12 ## Distance from the top of a picture up to its name.
  ARC_DIP = 130  ## How far a compound curve hangs below the row it joins.


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
  COLOUR_LEFT = "var(--left, #a85f22)"
  COLOUR_RIGHT = "var(--right, #2b6c8c)"
  COLOUR_QUIET = "var(--rule-strong, #b9bfba)"
  COLOUR_INK = "var(--ink, #1a1f1e)"
  COLOUR_PANEL = "var(--panel, #ffffff)"
  LABEL_FONT = "font: 12px ui-sans-serif, system-ui, sans-serif"
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


func plate(x, y, width: int; classes: string): string =
  ## Draw a backing plate, so a label over a line stays readable.
  "<rect class=\"" & classes & "\" x=\"" & $(x - width div 2) & "\" y=\"" &
    $(y - 10) & "\" width=\"" & $width & "\" height=\"14\" rx=\"3\"/>"


func edge(a, b: Frame; side: Side; is_lit: bool): string =
  ## Draw the pair of moves that join two frames, and name the arm that acts.
  let
    (ax, ay) = centreOf(a)
    (bx, by) = centreOf(b)
    lit = if is_lit: " lit" else: ""
    label = leadName(side)
  result = "<line class=\"edge" & lit & "\" x1=\"" & $ax & "\" y1=\"" & $ay &
    "\" x2=\"" & $bx & "\" y2=\"" & $by & "\" style=\"stroke: " &
    (if is_lit: armColour(side) else: COLOUR_QUIET) & "\"/>"
  if not is_lit:
    return
  let
    mx = (ax + bx) div 2
    my = (ay + by) div 2
  result.add plate(mx, my, label.len * 8 + 10, "edge-plate")
  result.add text(mx, my, label, LABEL_FONT & "; fill: " & armColour(side))


func arc(a, b: Frame; name: string; is_lit: bool): string =
  ## Draw a compound as a curve, since no single move joins the two frames.
  let
    (ax, ay) = centreOf(a)
    (bx, by) = centreOf(b)
    mx = (ax + bx) div 2
    dip = ARC_DIP + (abs(ax - bx) div 5)
    lit = if is_lit: " lit" else: ""
  result = "<path class=\"arc" & lit & "\" d=\"M" & $ax & " " & $ay & "Q" & $mx &
    " " & $(max(ay, by) + dip) & " " & $bx & " " & $by & "\"/>"
  # A curve is at its lowest halfway along, which is half the dip below the row.
  let
    label_x = mx
    label_y = max(ay, by) + dip div 2 + 4
  result.add plate(label_x, label_y, name.len * 8 + 10, "arc-plate")
  result.add text(label_x, label_y, name, LABEL_FONT & "; fill: " &
    (if is_lit: COLOUR_INK else: COLOUR_QUIET))


func node(target: Frame; is_here, is_reachable: bool): string =
  ## Draw one frame in its place, with its name beneath it.
  let
    (cx, cy) = centreOf(target)
    height = frameHeight(NODE_WIDTH)
    classes = "node" & (if is_here: " here" else: "") &
      (if is_reachable: " reachable" else: "")
  result = "<g class=\"" & classes & "\" data-frame=\"" & target.key & "\">"
  result.add "<rect class=\"node-plate\" x=\"" & $(cx - NODE_WIDTH div 2 - 8) &
    "\" y=\"" & $(cy - height div 2 - 6) & "\" width=\"" & $(NODE_WIDTH + 16) &
    "\" height=\"" & $(height + 12) & "\" rx=\"8\"/>"
  result.add renderFramePlaced(
    target, cx - NODE_WIDTH div 2, cy - height div 2, NODE_WIDTH)
  # The name goes above the picture, leaving the space below for the curves.
  result.add text(cx, cy - height div 2 - NAME_RISE, target.describe,
    NAME_FONT & "; fill: " & COLOUR_INK, "node-name")
  result.add "</g>"



#[ The Map ]#

func renderMap*(here, before: Option[Frame]): string =
  ## Draw the graph, with the couple standing on one frame if they are dancing.
  ##
  ## The marker is drawn where the couple *were*, and carries where they are
  ## going, so a page that moves it after drawing gets an animation for free and
  ## a page that does not still shows the truth.
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " &
    $MAP_WIDTH & " " & $MAP_HEIGHT & "\" class=\"map\" role=\"img\">" &
    "<title>Every frame, and every move between them</title>"

  var drawn: seq[string] = @[]
  for source in FRAMES:
    for move in moves(source):
      let pair = sorted(@[source.key, move.to.key]).join("-")
      if pair in drawn:
        continue
      drawn.add pair
      let lit = here == some(source) or here == some(move.to)
      result.add edge(source, move.to, move.side, lit)

  drawn = @[]
  for source in FRAMES:
    for target in FRAMES:
      let named = compound(source, target)
      if named.isNone:
        continue
      let pair = sorted(@[source.key, target.key]).join("-")
      if pair in drawn:
        continue
      drawn.add pair
      result.add arc(source, target, ($named.get).toLowerAscii,
        here == some(source) or here == some(target))

  for target in FRAMES:
    let reachable =
      here.isSome and classify(here.get, target).isSome
    result.add node(target, here == some(target), reachable)

  if here.isSome:
    let
      (hx, hy) = centreOf(here.get)
      (fx, fy) = centreOf(if before.isSome: before.get else: here.get)
      height = frameHeight(NODE_WIDTH)
    result.add "<rect id=\"here\" class=\"marker\" x=\"" &
      $(-NODE_WIDTH div 2 - 12) & "\" y=\"" & $(-height div 2 - 10) &
      "\" width=\"" & $(NODE_WIDTH + 24) & "\" height=\"" & $(height + 20) &
      "\" rx=\"10\" transform=\"translate(" & $fx & "," & $fy &
      ")\" data-x=\"" & $hx & "\" data-y=\"" & $hy & "\"/>"
  result.add "</svg>"
