## Say when a drawing moves, so the picture and the page agree about it.
##
## A move is not an instant.  It is a sentence, and the drawing says it a clause
## at a time: the ways not taken fold away, the mark that says *you are here*
## passes along the way that was taken, the frame left behind shrinks away, the
## drawing recentres on the frame reached, and only then do its own ways grow.
## A reader who can follow that can see what the move did; a drawing that cut
## from one picture to the next would only assert it.
##
## The whole sentence is told in one drawing.  The page replaces the drawing
## exactly once, at the end, at the one instant when what is on the screen and
## what would replace it are the same picture: one frame in the middle, marked,
## with nothing around it yet.  A swap made there cannot be seen, which is why
## it is made there and nowhere else.
##
## Both the stylesheet and the page need these numbers -- one to run the
## animation and one to know when the state may move -- so they live here once
## and are written onto the drawing as custom properties.  Times that stagger are
## given as a *budget* rather than as a step per thing: a step per thing takes
## longer the more things there are, so a frame with five ways out would still be
## folding them when the page had moved on.

{.experimental: "strictFuncs".}



#[ Phases ]#

type Motion* {.pure.} = enum ## Name what a drawing is doing at one instant.
  Still,    ## Nothing is moving; the drawing shows the frame the couple hold.
  Leaving,  ## The move is chosen, and the drawing is telling the whole of it.
  Arriving  ## The frame reached is held, and its own ways are growing.


func phase*(motion: Motion): string =
  ## Name a phase for the stylesheet, which is what selects the animation.
  case motion
  of Motion.Still: "still"
  of Motion.Leaving: "leaving"
  of Motion.Arriving: "arriving"



#[ Telling the Move ]#

const
  FOLD_SPREAD* = 60
    ## Budget for starting one way folding after another, in milliseconds.
  FOLD_LAG* = 50
    ## How far behind its own leaf a branch begins to fold.
  FOLD_LEAF* = 120
    ## Folding one leaf away: a leaf growing, run backwards.
  FOLD_BRANCH* = 110
    ## Folding one branch back into the middle: a branch growing, run backwards.

  PASS_TIME* = 200
    ## Carrying the mark along the way taken, from the frame held to the one
    ## chosen.  This is the move itself; what comes before clears the way for it
    ## and what comes after tidies up behind it.
  SHRINK_TIME* = 140
    ## Shrinking away the frame left behind, once the mark has left it.
  CENTRE_TIME* = 340
    ## Recentring the drawing on the frame reached, which is now all there is.
  SEAM_MARGIN* = 60
    ## Room between the last of that finishing and the drawing being replaced.
    ##
    ## An animation's clock starts when the browser first draws the element, a
    ## frame or two after the page asked for the phase, so anything timed to end
    ## exactly when the drawing is replaced is in fact still running then, and is
    ## cut off wherever it had got to.  Nothing is moving during the margin, so
    ## it costs the reader nothing.


const
  PASS_AT* = FOLD_SPREAD + FOLD_LAG + FOLD_BRANCH
    ## When the mark sets off, which is when the ways not taken have all gone.
  SHRINK_AT* = PASS_AT + PASS_TIME
    ## When the frame left behind starts to go, which is once the mark has left.
  CENTRE_AT* = SHRINK_AT + SHRINK_TIME
    ## When the drawing starts recentring on the one frame left in it.
  LEAVE_TIME* = CENTRE_AT + CENTRE_TIME + SEAM_MARGIN
    ## When the page may replace the drawing: when nothing is moving, and the
    ## picture drawn for the frame reached is the picture already on the screen.



#[ Growing Again ]#

const
  GROW_DELAY* = 50
    ## Wait after the drawing is replaced before the first new way grows.
  GROW_SPREAD* = 90
    ## Budget for starting one way growing after another.
  LEAF_DELAY* = 100
    ## Wait between a branch growing and its own leaf, which is what makes the
    ## drawing read as branches first and leaves after rather than as one bloom.
  GROW_TIME* = 170
    ## Growing one branch, or one leaf once its branch has arrived.


const
  GROWN_TIME* = GROW_DELAY + GROW_SPREAD + LEAF_DELAY + GROW_TIME
    ## When the last leaf of the frame reached has finished growing.
  MOVE_TIME* = LEAVE_TIME + GROWN_TIME
    ## When everything one move set going has finished.
  LEAD_ON_TIME* = MOVE_TIME
    ## When the second move of a compound may start.
    ##
    ## Not before the first has finished being told.  A lead thinks of the two as
    ## one thing, but the ontology knows the frame between them is real, and a
    ## drawing that began unsaying it before it had finished saying it would be
    ## claiming the couple were never there.


func motionStyle*(): string =
  ## Write the times onto a drawing, for the stylesheet to spend.
  "--fold-spread: " & $FOLD_SPREAD & "ms; --fold-lag: " & $FOLD_LAG &
    "ms; --fold-leaf: " & $FOLD_LEAF & "ms; --fold-branch: " & $FOLD_BRANCH &
    "ms; --pass-at: " & $PASS_AT & "ms; --pass: " & $PASS_TIME &
    "ms; --shrink-at: " & $SHRINK_AT & "ms; --shrink: " & $SHRINK_TIME &
    "ms; --centre-at: " & $CENTRE_AT & "ms; --centre: " & $CENTRE_TIME &
    "ms; --grow-delay: " & $GROW_DELAY & "ms; --grow-spread: " & $GROW_SPREAD &
    "ms; --leaf-delay: " & $LEAF_DELAY & "ms; --grow: " & $GROW_TIME & "ms"
