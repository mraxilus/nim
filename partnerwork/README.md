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
open ── collect ──> Left to left ── collect ──> Left-to-left over Right-to-right
                          │                              │
                        pass                            cut
                          v                              v
                   Right to left               Right-to-right over Left-to-left
```


## The app

`app/index.html` is a validator. It shows the frame you are in, every frame one
primitive away with the phrase that leads it, and every frame that is *not*, with
the number of moves it would take to get there. Only what is offered can be
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
it. **Dance** walks the state machine. **Matrix** is every move there is as one
table, which is the thing you consult once you know what a frame is rather than
the thing you meet first.

What the model has to say about the spreadsheet is deliberately not in the app.
It is a finding about a document rather than a fact about two bodies, it does not
change as you dance, and it wants reading rather than clicking through: it lives
in `doc/review.html` and in `nimble audit`.

The Dance view draws the frame two ways, one at a time. **Dynamic** puts the
frame in the middle and every way out of it as a spoke, and nothing else — take
a spoke and the drawing recentres on it. **Overview** is the whole ontology with
the couple standing somewhere in it, every line named, and the frames within
reach brought forward while the rest go quiet.

A line's ink is the arm that acts as you travel along it. For a primitive that
is one arm whichever way you read it, so the line has one ink; a compound hands
the follow's hand from one of the lead's arms to the other, so it is drawn in
halves, each in the ink of the arm that acts on the way into it, and stays
dashed because it is still two moves. That is what lets a move be named
`collect left` or `place left` and still say which of the lead's arms does it.

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
