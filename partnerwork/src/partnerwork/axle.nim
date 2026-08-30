## Draw the rotation axis as what it is: one line, with the couple on it.
##
##   The hand-to-hand half is a graph, so it is drawn as a graph.  Rotation
##     is not -- it is a single quantity, twist, and every posture of one
##     frame held at one height is somewhere along it.  So it is drawn as an
##     axle: the postures laid out in the order they are turned into, the
##     couple standing on one, and every turn out of it as an arc from where
##     they are to where it would put them.
##   The turns that cannot be taken are drawn too, dashed and dimmed, for
##     the same reason the map draws the frames you cannot reach.
##     Cost of drawing the refused: ink and room spent on turns the couple
##       cannot take.  Accepted -- a drawing that showed only what is
##       allowed would be a menu, and what makes this a validator is that
##       it can show a turn and refuse it in the same breath.
##   Nothing places this drawing yet.  The app's Dance view is graph-first
##     and the rotation exploration moved to the design workbench, so the
##     axle waits for the page that stands postures in links.  `taxle`
##     holds its laws green in the meantime, so the wait cannot rot.

{.experimental: "strictFuncs".}

import std/options

import ./diagram
import ./map
import ./motion
import ./rotation



#[ Layout ]#

const
  AXLE_HEIGHT* = 360 ## The height the axle drawing asks its viewBox for.
  NODE_WIDTH = 84   ## Width a posture is drawn at along the axle.
  STEP = 132       ## Distance along the axle between one half turn and the next.
  AXLE_Y = 250     ## Row the postures are drawn in, under their arcs.
  NAME_RISE = 14   ## Distance from the top of a picture up to its name.
  ARC_RISE = 100   ## How far above the axle the shortest turn's arc reaches.
  LABEL_FONT = "font: 11px ui-sans-serif, system-ui, sans-serif"


func axleWidth*: int =
  ## Get how wide the axle has to be for the postures that stand on it.
  ##   A constant expression today -- every posture stands on the same axle
  ##     -- and a callable so the width can start depending on the posture
  ##     without the callers changing.  It used to take the posture and
  ##     read nothing from it, which promised the dependence untruthfully.
  2 * (MOST_TURN * STEP) + NODE_WIDTH + 60


func centreOf*(stood: Posture; twist: HalfTurns): (int, int) =
  ## Get where a twist sits along the axle.
  ##   Placed by the twist itself rather than by an index, so the distance
  ##     between two postures on the drawing is the size of the turn between
  ##     them.  A half turn is one step wherever it is taken.
  (axleWidth() div 2 + twist * STEP, AXLE_Y)


func standing*(stood: Posture): seq[HalfTurns] =
  ## Get every twist this frame, held at these heights, can stand at.
  for twist in -MOST_TURN .. MOST_TURN:
    if stood.holds(twist):
      result.add twist



#[ The Drawing ]#

func arc(stood: Posture; twist: HalfTurns; refused: bool): string =
  ## Draw one landing as an arc from where the couple are to where it puts
  ## them.
  ##   One arc per place a turn lands, not one per turn.  Twelve turns land
  ##     in six places, because a turn is stored as one number for the
  ##     couple and that number does not care which of them moved -- so
  ##     twelve arcs would be six drawn twice, on top of each other, saying
  ##     the same thing.  Which dancer takes it is in the list beside the
  ##     drawing, where there is room to say it.
  let
    (ax, ay) = centreOf(stood, stood.twist)
    (bx, by) = centreOf(stood, twist)
    reach = abs(twist - stood.twist)
    # Stacked by how far the turn goes, so a long arc clears a short one rather
    # than crossing it twice.
    lift = ARC_RISE + reach * 30
    (mx, my) = ((ax + bx) div 2, ay - lift)
    told = TURN_NAMES[min(reach, TURN_NAMES.high)] &
      (if twist > stood.twist: " right" else: " left")
  result = "<g class=\"turn" & (if refused: " refused" else: "") & "\">" &
    "<path class=\"turn-line\" d=\"M" & $ax & " " & $(ay - 58) & "Q" & $mx &
    " " & $my & " " & $bx & " " & $(by - 58) & "\"/>"
  let (nx, ny) = (mx, ay - lift * 3 div 4)
  result.add "<rect class=\"turn-plate\" x=\"" & $(nx - told.len * 3 - 5) &
    "\" y=\"" & $(ny - 9) & "\" width=\"" & $(told.len * 6 + 10) &
    "\" height=\"15\" rx=\"3\"/>"
  result.add "<text class=\"turn-name\" x=\"" & $nx & "\" y=\"" & $(ny + 3) &
    "\" text-anchor=\"middle\" style=\"" & LABEL_FONT & "\">" & told & "</text>"
  result.add "</g>"


func renderAxle*(stood: Posture; motion = Motion.Still;
    taken = none(HalfTurns)): string =
  ## Draw the twist axis, the postures on it, and every turn out of the one held.
  let
    width = axleWidth()
    leaving = motion == Motion.Leaving and taken.isSome
    here = if leaving: taken.get else: stood.twist
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " & $width &
    " " & $AXLE_HEIGHT & "\" class=\"axle" & (if leaving: " leaving" else: "") &
    "\" style=\"" & passStyle(WIDE_TEMPO) & "\" role=\"img\">" &
    "<title>" & stood.describe & ", and every turn out of it</title>"

  # The axle itself, drawn the width of what stands on it and no wider.
  let ends = standing(stood)
  if ends.len > 0:
    result.add "<line class=\"axle-line\" x1=\"" &
      $(centreOf(stood, ends[0])[0]) & "\" y1=\"" & $AXLE_Y & "\" x2=\"" &
      $(centreOf(stood, ends[^1])[0]) & "\" y2=\"" & $AXLE_Y & "\"/>"

  # The arcs: one per place a turn can land, refused ones included.
  var drawn: seq[HalfTurns] = @[]
  for offer in turnsOf(stood):
    if offer.to.twist == stood.twist or offer.to.twist in drawn:
      continue
    drawn.add offer.to.twist
    result.add arc(stood, offer.to.twist, offer.refused.isSome)

  # The postures standing on the axle, each named for its turn and its arms.
  for twist in ends:
    var landing = stood
    landing.twist = twist
    let
      (cx, cy) = centreOf(stood, twist)
      reachable = twist != stood.twist
      classes = "node" & (if twist == here: " here" else: "") &
        (if reachable: " reachable" else: "")
    result.add "<g class=\"" & classes & "\" data-posture=\"" & landing.key &
      "\">"
    result.add "<rect class=\"node-plate\" x=\"" & $(cx - NODE_WIDTH div 2 - 5) &
      "\" y=\"" & $(cy - frameHeight(NODE_WIDTH) div 2 - 5) & "\" width=\"" &
      $(NODE_WIDTH + 10) & "\" height=\"" & $(frameHeight(NODE_WIDTH) + 10) &
      "\" rx=\"6\"/>"
    result.add renderFramePlaced(landing.frame, cx - NODE_WIDTH div 2,
      cy - frameHeight(NODE_WIDTH) div 2, NODE_WIDTH, twist)
    let name = turnName(twist)
    result.add "<text class=\"node-name\" x=\"" & $cx & "\" y=\"" &
      $(cy - frameHeight(NODE_WIDTH) div 2 - NAME_RISE) &
      "\" text-anchor=\"middle\" style=\"" & LABEL_FONT & "\">" & name & "</text>"
    let arms = landing.armName
    if arms.len > 0:
      result.add "<text class=\"node-arms\" x=\"" & $cx & "\" y=\"" &
        $(cy + frameHeight(NODE_WIDTH) div 2 + 18) &
        "\" text-anchor=\"middle\" style=\"" & LABEL_FONT & "\">" & arms &
        "</text>"
    result.add "</g>"

  # The mark carries the distance to where it is going, so taking a turn is the
  # mark travelling along the axle, which is what the move is.
  let
    (hx, hy) = centreOf(stood, stood.twist)
    (tx, _) = centreOf(stood, here)
  result.add markAt(hx, hy, NODE_WIDTH, " style=\"--mx: " & $(tx - hx) &
    "px; --my: 0px\"")
  result.add "</svg>"
