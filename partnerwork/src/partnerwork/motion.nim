## Say when a drawing moves, so the picture and the page agree about it.
##
## A move is not an instant.  The ways not taken have to fold away, the frame
## taken has to travel into the middle, and the ways out of it have to grow: the
## drawing is showing a change rather than announcing one, and a change takes
## time the reader can follow.
##
## Both halves of that need the same numbers.  The stylesheet needs them to run
## the animation and the page needs them to know when to advance the state, and
## a stylesheet that ran for longer than the page waited would have its animation
## cut off half-finished.  So the numbers live here once and are written onto the
## drawing as custom properties: the stylesheet spends them, the page waits on
## them, and neither can drift from the other.
##
## Times that stagger are given as a *budget* rather than as a step per thing.
## A step per thing takes longer the more things there are, so a frame with five
## ways out would still be folding them away after the page had moved on and
## thrown them away mid-fold.  A budget divided among however many there are
## finishes when it says it will, whatever the frame.

{.experimental: "strictFuncs".}



#[ Phases ]#

type Motion* {.pure.} = enum ## Name what a drawing is doing at one instant.
  Still,    ## Nothing is moving; the drawing shows the frame the couple hold.
  Leaving,  ## The move is chosen, and the ways not taken are folding away.
  Arriving  ## The frame taken is travelling in, and its own ways are growing.


func phase*(motion: Motion): string =
  ## Name a phase for the stylesheet, which is what selects the animation.
  case motion
  of Motion.Still: "still"
  of Motion.Leaving: "leaving"
  of Motion.Arriving: "arriving"



#[ Folding Away ]#

const
  FOLD_SPREAD* = 90
    ## Budget for starting one way folding after another, in milliseconds.
  FOLD_LAG* = 70
    ## How far behind its own leaf a branch begins to fold.
  FOLD_LEAF* = 160
    ## Folding one leaf away.
  FOLD_BRANCH* = 140
    ## Folding one branch back into the middle.
  FOLD_MARGIN* = 60
    ## Room left between the last fold ending and the drawing being replaced.
    ##
    ## An animation's clock starts when the browser first draws the element, a
    ## frame or two after the page asked for the phase, so a fold timed to end
    ## exactly when the drawing is replaced is in fact still running when that
    ## happens.  Its tail is then cut off at whatever opacity it had reached,
    ## which is seen as a flash.  The margin is what that tail costs; nothing is
    ## visible during it, so it costs the reader nothing.



const LEAVE_TIME* = FOLD_SPREAD + FOLD_LAG + FOLD_BRANCH + FOLD_MARGIN
  ## When the page may throw the drawing away and draw the next one.
  ##
  ## Derived rather than chosen: it is the last fold finishing, plus the room
  ## that fold needs to be sure it has finished.



#[ Travelling and Growing ]#

const
  TRAVEL_TIME* = 480
    ## Carrying the frame taken into the middle, and the window with it.
  GROW_DELAY* = 200
    ## How far into the travel the first new way starts growing.
    ##
    ## Well before the travel is over.  Waiting for the frame to land leaves a
    ## beat with one card alone in an empty drawing, which is read as everything
    ## having vanished rather than as one thing arriving; starting here, the new
    ## ways are unfurling around the frame while it is still on its way in.
  GROW_SPREAD* = 110
    ## Budget for starting one way growing after another.
  LEAF_DELAY* = 130
    ## Wait between a branch growing and its own leaf, which is what makes the
    ## drawing read as branches first and leaves after rather than as one bloom.
  GROW_TIME* = 200
    ## Growing one branch, or one leaf once its branch has arrived.


const
  GROWN_TIME* = GROW_DELAY + GROW_SPREAD + LEAF_DELAY + GROW_TIME
    ## When the last leaf of the frame arrived at has finished growing.
  LEAD_ON_TIME* = LEAVE_TIME + TRAVEL_TIME
    ## When the second move of a compound may start, in milliseconds.
    ##
    ## The waypoint has landed in the middle and its ways are only beginning to
    ## grow, so the second move reads as the rest of one phrase rather than as a
    ## second decision.
  MOVE_TIME* = LEAVE_TIME + max(TRAVEL_TIME, GROWN_TIME)
    ## When everything a move set going has certainly finished.


func motionStyle*(): string =
  ## Write the times onto a drawing, for the stylesheet to spend.
  "--fold-spread: " & $FOLD_SPREAD & "ms; --fold-lag: " & $FOLD_LAG &
    "ms; --fold-leaf: " & $FOLD_LEAF & "ms; --fold-branch: " & $FOLD_BRANCH &
    "ms; --fold-margin: " & $FOLD_MARGIN &
    "ms; --travel: " & $TRAVEL_TIME & "ms; --grow-delay: " & $GROW_DELAY &
    "ms; --grow-spread: " & $GROW_SPREAD & "ms; --leaf-delay: " & $LEAF_DELAY &
    "ms; --grow: " & $GROW_TIME & "ms"
