## Draw a frame, once, for every place that shows one.
##
##   The picture is the couple seen from above: two bodies as plain circles,
##     each with a small chevron at its centre saying which way it faces, the
##     lead at the bottom facing up the page.  A connection runs hand to hand
##     as a taut string that goes **round** a body rather than through one, so
##     a hold that crosses is drawn crossing.
##     What this replaces is a schematic: two rows of hands with a dashed
##       midline between them, where whether a connection crossed had to be
##       read off which side of the line it passed.  The bodies are in the
##       picture now, so crossing is a thing you can see instead of a
##       convention you have to know.
##   The lead's hands are squares and the follow's are circles, so a picture
##     drawn too small for a word beside it still says which is whose.  Each
##     is in **its own side's colour** -- a Left hand is blue whoever holds it
##     -- and in **its owner's shade**: the lead's deep, the follow's plain.
##     A connection carries both, meeting at its middle, so the line itself
##     draws which named hands are joined.
##   A held hand is a hollow outline, because hollow is what an unsaid level
##     looks like and a `Frame` says no level.  A free one is the same outline
##     at half strength.  What is held is said by the connection running out
##     of it, which is the mark that survives being shrunk.
##   Where both connections cross they overlap, and the one underneath is
##     drawn with a break in it.
##     Cost of a break: the under connection really is cut -- a stretch of its
##       ink is missing.  Accepted -- a masking stroke has to know the colour
##       of the ground it sits on, and these pictures are also written out as
##       standalone files, to be shown on grounds this module cannot see.
##   Colours come through custom properties with fallbacks, for the same
##     reason: inside a page that defines `--left` and `--right` the picture
##     follows the page, including its light and dark themes.
##     Cost of fallback ink: on its own the picture is tuned to neither
##       ground, only readable on either.  Accepted -- a standalone file
##       cannot know the ground it will be shown on.
##   None of the drawing is here.  The marks were settled in the mock-up
##     workbench and live in `draw/`, which the workbench and the app both
##     read, so the two cannot drift; `draw/scene` builds every frame's
##     picture at compile time and this module is the frame around it.

{.experimental: "strictFuncs".}

import ./frame
import ./rotation
import ./draw/scene



#[ Geometry ]#

const
  WIDTH = 100
  HEIGHT = 116
    ## The shape of a frame picture's box, as everything laid out around one
    ## measures it: twenty-five wide to twenty-nine tall.
  VIEW = "-45 -52.2 90 104.4"
    ## And the box itself, in the drawing's own units, which are centred on
    ## the couple's own middle.
    ##   The same twenty-five to twenty-nine, so nothing that places a
    ##     picture has to move; sized to what the drawing actually reaches,
    ##     which is 58.5 across by 98.2 down, measured over all sixteen
    ##     pictures with every stroke's cap counted in.
    ##   Taller than the drawing is wide, and the air is left at the sides:
    ##     two bodies one above the other make a tall picture, and cropping
    ##     to it would make every node on every map tall and thin.



#[ Frames ]#

func frameBody(target: Frame; twist: HalfTurns): string =
  ## Draw the contents of a frame picture, without the frame around them.
  ##   Only the *parity* of the twist reaches the drawing: a whole turn puts
  ##     the follow back where they were, so a picture can say facing or
  ##     turned and nothing else.  Asking `isFacing` here rather than passing
  ##     the number on is what makes half a turn each way draw alike by
  ##     construction instead of by arithmetic that happens to agree.
  "<title>" & target.describe & "</title>" & sceneFor(target, isFacing(twist))


func frameHeight*(width: int): int =
  ## Get how tall a frame picture is when drawn to a given width.
  (width * HEIGHT) div WIDTH


func renderFrame*(target: Frame; twist: HalfTurns = 0): string =
  ## Draw a frame as a picture that stands on its own.
  ##   Given a twist it draws the posture instead: the same frame, seen with
  ##     the follow turned as far as that twist has turned them.
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"" & VIEW &
    "\" class=\"frame\" role=\"img\">" & frameBody(target, twist) & "</svg>"


func renderFramePlaced*(target: Frame; x, y, width: int;
    twist: HalfTurns = 0): string =
  ## Draw a frame picture at a place inside a larger drawing.
  ##   The same body, given its own viewport: a nested picture keeps its own
  ##     coordinates, so the drawing around it never has to know how a frame
  ##     is made.
  "<svg x=\"" & $x & "\" y=\"" & $y & "\" width=\"" & $width & "\" height=\"" &
    $frameHeight(width) & "\" viewBox=\"" & VIEW &
    "\" class=\"frame\">" & frameBody(target, twist) & "</svg>"
