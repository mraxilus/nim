# partner work

An executable ontology of the frames a couple can hold in partner dance, and the
moves between them. Written for salsa, but nothing in it is salsa-specific: it is
two humanoid bodies, four hands and the geometry of facing each other.

Hands only. A hand resting on a partner's body is real and deliberately absent:
it adds no frame, it takes a turn away, and it is where a wound arm lands, so it
belongs with rotation rather than here.

The model has one state and one relation. A **frame** is what each of the lead's
hands holds and how the arms lie where they overlap. A **move** exists between
two frames exactly when the difference between them is one primitive. Everything
else — the names, the routes, the audit of the source workbook, the browser app
— is derived from those two things.

```
                   Right to left               Right-to-right over Left-to-left
                          ^                              ^
                        pass                            cut
                          │                              │
open ── collect ──> Left to left ── collect ──> Left-to-left over Right-to-right
```

The drawings stack this as a tower: `open` at the foot, both hands held at the
head, so a collect climbs and a drop falls.


## The app

`app/index.html` is a validator. It shows the frame you are in, every frame one
primitive away with the phrase that leads it, and every frame that is *not*,
with the way there spelled out a move at a time. Only what is offered can be
clicked, so a move the ontology does not derive cannot be danced.

Open `app/index.html` in a browser. To rebuild it after a change:

```
nimble app          # compiles app/app.js, then bundles app/artifact.html
```

`app/artifact.html` is the same page as one self-contained file, for publishing
or for sending to someone who should not have to keep two files together.

Three views, in the order a reader wants them. **Atlas** is every frame there is,
drawn, named and counted, and is where the page opens: what the ontology *is*
comes before what you can do with it, and clicking a frame starts the dance from
it. **Dance** walks the state machine. **Matrix** is every move there is at once,
which is the thing you consult once you know what a frame is rather than the
thing you meet first.

The matrix is drawn rather than tabulated. Both axes carry the frames' pictures,
the same size down the side as across the top, so that following a row and
reading a column are the same act of recognition and the vocabulary can be
checked rather than trusted. The names beside them are abbreviated — `L-to-l
over R-to-r` — which loses nothing, because a hand's case is the whole of what
says whose it is and a letter has a case. A cell carries the move's
direction as a mark and the lead's arm as its ink, which is what the map says
and how it says it. Both axes run down the tower, taking their order from the
drawing that owns it (`towerOrder`), so reading the matrix top to bottom and
reading the map top to bottom are the same reading. Every collect then falls
below the diagonal and every drop above it, and the two compounds — which change
what is held without changing how much — fall in the blocks along it: the
structure is in the picture rather than in the paragraph under it. A pair no
single move joins used to be a blank cell, which is half the chart saying
nothing; it now carries how far apart the two frames are. There is no grid, and
what ruled lines were for — knowing which column you are in — is done by lighting
the row and column under the pointer instead.

What the model has to say about the spreadsheet is deliberately not in the app.
It is a finding about a document rather than a fact about two bodies, it does not
change as you dance, and it wants reading rather than clicking through: it lives
in `doc/review.html` and in `nimble audit`.

The Dance view starts at `open`, which is where a couple starts and the one
frame nothing has to lead up to: from there every way out is a collect, which is
the ladder seen from the bottom of it.

A frame further off is named a step at a time, in the words the panel above uses
for the same move. `collect, then collect` is the shape of an answer rather than
an answer, and from `open` it was what all three frames two moves away said —
the same seven words for three different places, while four collects sat
unlabelled above, two of which lead away from any one of those places rather
than towards it. The route always knew which two. Each step is named against the
frame it leaves rather than the frame you stand in, because that is the frame it
is a move out of; on a shortest route the two read the same, and there is a law
for each half of why.

It draws the frame two ways, one at a time. **Dynamic** puts the frame in the
middle and every way out of it as a spoke, and nothing else — take a spoke and
the drawing recentres on it. **Overview** is the whole ontology with the couple
standing somewhere in it, every line named, and the frames within reach brought
forward while the rest go quiet.

Which one you get is whichever the screen has room for: the map says more and
only wants width, the close drawing is the one that survives a phone. The page
keeps following the screen until you pick a drawing, and then leaves your choice
alone — a window dragged narrower should not take it back. The threshold is the
map's own least width plus the page's margins, and it is written once, in the
stylesheet, as `--wide`: which widths are wide is a question about the layout,
so the script asks the layout rather than keeping a second copy of the number.

The close drawing is cut to the frame, and the widest frame wants more room than
a phone has — `open` fans four ways out over 728 pixels. So it shrinks to the
room there is, and stops shrinking when its names reach 8 pixels, because the
whole drawing shrinks together and a drawing of your options whose options
cannot be read is not worth fitting. Below that it keeps its size and scrolls,
opening on the frame being held rather than on the left edge of the fan.

It shrinks by handing its geometry to the stylesheet as bare numbers rather than
lengths. The one thing that has to be worked out is the room there is divided by
the width the drawing wants, and a length cannot be divided by a length — so the
drawing gives numbers and takes back a unit, and everything it is made of is a
multiple of that one unit. Those numbers are registered with `@property`, so the
recentring animates them and the scale follows on its own; and because the
drawing being left ends at exactly the width the frame reached is drawn at, it
ends at exactly that frame's scale, which is what keeps the swap invisible at
every size. Measured at 390, 600 and 1200 pixels: the mark and the frame reached
land in the same place either side of it.

A picture of a frame is the couple seen from above: two plain circles, each
with a small chevron at its centre for the way that dancer faces, the lead at
the bottom facing up. The lead's hands are squares and the follow's are
circles, sitting on their own bodies' rims. Which hand is whose used to be said
only by captions over and under the picture, and those are the first thing to go
when a frame is drawn small — as a node on the map, or down the side of the
matrix. A shape survives any size, so the picture says whose hand it is the way
the vocabulary does: by the mark itself rather than by a word beside it. Colour
says the rest — every hand is in its own side's hue, deep for the lead and plain
for the follow, and a connection carries both, meeting at its middle, so the
line itself draws which named hands are joined.

A connection goes **round** a body rather than through one, so a hold that
crosses is drawn crossing and nothing has to be read off a convention. This
picture was worked out as published mock-ups before it went in
(`design/README.md`), and the drawing it is made of lives in
`src/partnerwork/draw/`, which the mock-up workbench and the app both read so
the two cannot drift. Every frame's picture is built at compile time, so what
the browser ships is the finished markup and none of the routing.

A line's ink is the arm that acts as you travel along it. For a primitive that
is one arm whichever way you read it, so the line has one ink; a compound hands
the follow's hand from one of the lead's arms to the other, so it is drawn in
halves, each in the ink of the arm that acts on the way into it, and stays
dashed because it is still two moves. That is what lets a move be named
`collect left` or `place left` and still say which of the lead's arms does it.

Every line on the map goes down before a single word does. A name carries a plate
to keep the drawing out from under it, and a plate can only hide what is already
there: written as each line was drawn, a name was struck through by the next line
to cross it, which is a wrong drawing rather than an ugly one — the reader is
told the wrong move. The names are still *placed* in the other order, curves
first, because a curve has only the one place it can be named.

Both drawings say a move the same way — the mark passes along the line to the
frame chosen — and each takes its own time over it. The close drawing has to clear the
ways not taken before the mark can move and build the new ones after, so a move
there is about a second. The map has every frame in place already and nothing to
build, so its move is the mark going and the dimming changing around it, and is
over in a third of that. Each drawing tells the page its own `Tempo`
(`src/partnerwork/motion.nim`) and the page waits on whichever one is on show;
giving the map the close drawing's schedule left it finished and waiting, which
reads as the page having stopped.

In the close drawing a move is told one clause at a time: the ways not taken fold
away, leaves before branches; the mark that says *you are here* passes along the
way that was taken; the frame left behind shrinks away; the drawing recentres on
the frame reached, which by then is all there is; and only then do its own ways
grow out of it, branches first and leaves after.

The whole of that happens in one drawing. The page replaces the drawing exactly
once, at the end, at the one instant when what is on the screen and what would
replace it are the same picture — one frame, marked, with nothing around it yet —
so the swap cannot be seen. `tests/tspokes.nim` holds it to that: the window a
move ends in, and where it leaves the frame standing, have to be the window and
the place that frame is given when it is standing still.

Every frame is drawn at one size for the same reason. A frame chosen stays on the
screen across that swap, and a node's plate and its name do not scale with its
width, so a frame drawn small and scaled up would never quite line up with the
same frame drawn large. Which frame is held is said by the mark around it.

The times live in `src/partnerwork/motion.nim` and the drawing writes them onto
itself for the stylesheet to spend, so the page waits on the same numbers the
animation runs on. A reader who has asked for reduced motion gets the change at
once instead.

The Atlas narrows on three questions — how many connections,
which hand of the lead holds, which hand of the follow is held — which are read
together, so a frame has to answer all of the ones asked.

Only the frames one move away can be clicked, in any of them. A compound is
offered too, dashed, and taking one dances both of its moves in turn rather than
jumping the frame in between.


## The rotation half, on the bench

`src/partnerwork/rotation.nim` and `src/partnerwork/axle.nim` hold what has been
worked out about turning: blockers, the three arm heights, the two ceilings, the
postures those derive, and the measured fact that a low wrap holds half a turn
where everything else holds a full one. `tests/trotation.nim` holds it to all of
that.

None of it is in the app. It was, and it came back out: the drawing is blind to
almost everything the rotation model knows — 148 postures render as 16 distinct
pictures, because level, contact and twist beyond its parity have no marks. A
validator whose picture cannot tell two states apart is not validating, so the
views wait until the marks are decided and the ontology is finished.

The page is usable from the keyboard: Tab reaches every control, the focus ring
is drawn outside the control so a chosen tab does not swallow it, and focus is
put back where it was after each move — on the frame itself when the button that
was pressed no longer exists, so a second keypress cannot dance a move nobody
chose. A live region outside the part of the page that is rewritten says what was
danced and where it landed, for a reader who cannot see the drawing.


## Layout

```
src/partnerwork/frame.nim       frames, their laws, their names, reflection
src/partnerwork/transition.nim  the two primitives, the two compounds, the routes
src/partnerwork/diagram.nim     one drawing of a frame, for everything that shows one
src/partnerwork/map.nim         the whole graph as one picture: frames and moves
src/partnerwork/spokes.nim      the frame held and every way out of it, and no more
src/partnerwork/motion.nim      when a drawing moves: the phases and their times
src/partnerwork/workbook.nim    the base sheet as data, and the audit against it
src/partnerwork/rotation.nim    the unfinished rotation axis: twist, body, wraps
app/                            the browser validator
tools/audit.nim                 the same audit, printed
tools/review.nim                writes the review page from the model
tests/                          the laws, checked over every pair of frames
doc/review.template.html        the prose of the review; every number is a marker
doc/review.html                 the review, generated: what the workbook says and
                                what is outstanding, rewritten each iteration
doc/frames/*.svg                one picture per frame, for anything that is not HTML
```

```
nimble test         # the laws, including that the review page is not stale
nimble audit        # the model and what it says about the workbook, printed
nimble review       # rewrite doc/review.html and doc/frames/ from the model
```


## What it says

Eight frames exist and twenty moves join them, each adding or removing one
connection. Two named compounds -- `place` and `cut`, the two your vocabulary
marks with an asterisk -- are pairs of those moves that a lead thinks of as
one. The `base` sheet of
`ontology.partnerwork.xlsx` names nine states, seven of them hand-to-hand, and
eighteen of its twenty-seven cells hold between those seven. All eighteen name
the same primitive the model derives independently, and they are every move that
exists between those seven states: nothing missing, nothing spare.

Three things are outstanding, set out in `doc/review.html`: `open` has no row,
`closed` and `half-closed` need a vocabulary for places on the body, and two
words have drifted between the `base` and `vocabulary` sheets.

Rotation is not modelled beyond what the hand-to-hand model forces. What it
forces is in `doc/review.html`, along with the four cells worth dancing to
settle the rest.

`doc/review.html` is generated from the model and from the prose in
`doc/review.template.html`, so every figure and every picture in it is derived
rather than transcribed, and a test fails if the committed page has fallen
behind. It is rewritten and republished each time the model changes, so its
history in git is the history of what the ontology has been claimed to say.
