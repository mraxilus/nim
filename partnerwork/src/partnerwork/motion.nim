## Say when a drawing moves, so the picture and the page agree about it.
##
## A move is not an instant.  It is something the drawing does, and every drawing
## says it the same way at heart: the mark that says *you are here* leaves the
## frame being held and arrives at the frame chosen.  That much is shared, and is
## what makes two drawings of one ontology read as two views of one movement.
##
## How much else a drawing has to do around that is its own business, and differs
## by how much it is showing.  A drawing of one frame and its ways out has to
## clear the ways not taken before the mark can move and grow the new ones after
## it has, and needs time to do it.  A drawing of the whole ontology has every
## frame already in place and nothing to build: the mark moves, what is within
## reach changes, and that is the whole of it.  Giving both the same schedule
## makes the second wait out clauses it has nothing to say.
##
## So a `Tempo` is what a drawing tells the page: when the mark moves, and when
## the drawing has finished saying what it has to say.  The page needs that to
## know when the state may move, and the stylesheet needs the same numbers to run
## the animation, so they are written onto the drawing as custom properties and
## neither can drift from the other.
##
## The whole of a move is told in one drawing.  The page replaces the drawing
## exactly once, at the end, at the one instant when what is on the screen and
## what would replace it are the same picture.  A swap made there cannot be seen,
## which is why it is made there and nowhere else.

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



#[ Tempo ]#

type Tempo* = object ## Say when a drawing moves, and for how long.
  pass_at*: int  ## When the mark leaves the frame held, from the move being asked for.
  pass*: int     ## How long the mark takes to reach the frame chosen.
  settle*: int   ## How long after that before the drawing may be replaced.
  grown*: int    ## How long after *that* before the drawing has finished moving.


func leaveTime*(tempo: Tempo): int = tempo.pass_at + tempo.pass + tempo.settle
  ## Get when the page may replace the drawing and let the state move with it.


func moveTime*(tempo: Tempo): int = tempo.leaveTime + tempo.grown
  ## Get when everything one move set going has finished.


func leadOnTime*(tempo: Tempo): int = tempo.moveTime
  ## Get when the second move of a compound may start.
  ##
  ## Not before the first has finished being told.  A lead thinks of the two as
  ## one thing, but the ontology knows the frame between them is real, and a
  ## drawing that began unsaying it before it had finished saying it would be
  ## claiming the couple were never there.


func passStyle*(tempo: Tempo): string =
  ## Write the shared times onto a drawing, for the stylesheet to spend.
  "--pass-at: " & $tempo.pass_at & "ms; --pass: " & $tempo.pass & "ms"


const SEAM_MARGIN* = 60
  ## Room every drawing leaves between its last movement ending and the page
  ## replacing it.
  ##
  ## An animation's clock starts when the browser first draws the element, a
  ## frame or two after the page asked for the phase, so anything timed to end
  ## exactly when the drawing is replaced is in fact still running then, and is
  ## cut off wherever it had got to.  Nothing is moving during the margin, so it
  ## costs the reader nothing.
