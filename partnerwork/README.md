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

Three views: **Dance** walks the state machine, **Atlas** shows the whole derived
transition matrix with the cells the workbook leaves blank outlined, and
**Audit** reports what the model has to say about the workbook.


## Layout

```
src/partnerwork/frame.nim       frames, their laws, their names, reflection
src/partnerwork/transition.nim  the four primitives and the routes between frames
src/partnerwork/diagram.nim     one drawing of a frame, for everything that shows one
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

Eight frames exist and twenty-six moves join them. The `base` sheet of
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
