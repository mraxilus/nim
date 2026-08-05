## Say when a drawing moves, so the picture and the page agree about it.
##
## A move is not an instant.  The ways not taken have to fold away, the frame
## taken has to travel into the middle, and the ways out of it have to grow: the
## drawing is showing a change rather than announcing one, and a change takes
## time the reader can follow.
##
## Both halves of that need the same numbers.  The stylesheet needs them to run
## the animation and the page needs them to know when to advance the state, and
## a stylesheet that ran for longer than the page waited would cut its own
## animation off.  So the numbers live here once and are written onto the drawing
## as custom properties: the stylesheet spends them, the page waits on them, and
## neither can drift from the other.

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



#[ Times ]#

const
  LEAVE_TIME* = 200
    ## Folding the ways not taken away, in milliseconds.
  TRAVEL_TIME* = 340
    ## Carrying the frame taken into the middle, and the window with it.
  GROW_DELAY* = 190
    ## How far into the travel the first new way starts growing.
  GROW_TIME* = 160
    ## Growing one branch, or one leaf once its branch has arrived.
  GROW_STEP* = 24
    ## Wait between one way growing and the next, so they come out in order.
  LEAF_DELAY* = 110
    ## Wait between a branch growing and its own leaf, which is what makes the
    ## drawing read as branches first and leaves after rather than as one bloom.


const
  LEAD_ON_TIME* = LEAVE_TIME + TRAVEL_TIME
    ## When the second move of a compound may start, in milliseconds.
    ##
    ## The waypoint has landed in the middle and its ways are only beginning to
    ## grow, so the second move reads as the rest of one phrase rather than as a
    ## second decision.
  MOVE_TIME* = LEAVE_TIME + TRAVEL_TIME + GROW_TIME
    ## When everything a move set going has certainly finished.


func motionStyle*(): string =
  ## Write the times onto a drawing, for the stylesheet to spend.
  "--leave: " & $LEAVE_TIME & "ms; --travel: " & $TRAVEL_TIME &
    "ms; --grow-delay: " & $GROW_DELAY & "ms; --grow: " & $GROW_TIME &
    "ms; --grow-step: " & $GROW_STEP & "ms; --leaf-delay: " & $LEAF_DELAY & "ms"
