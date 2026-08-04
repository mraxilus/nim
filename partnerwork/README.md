# partner work

An executable ontology of the frames a couple can hold in partner dance, and the
moves between them. Written for salsa, but nothing in it is salsa-specific: it is
two humanoid bodies, four hands and the geometry of facing each other.

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
nimble app          # or: nim js -d:release -o:app/app.js app/app.nim
```

Three views: **Dance** walks the state machine, **Atlas** shows the whole derived
transition matrix with the cells the workbook leaves blank outlined, and
**Audit** lists every disagreement between the workbook and the model. The
**Salsa/Physical** switch chooses whether to admit the four frames that put the
follow's torso in the lead's left hand — physical, but not what a salsa lead
does.


## Layout

```
src/partnerwork/frame.nim       frames, their laws, their names, reflection
src/partnerwork/transition.nim  the five primitives and the routes between frames
src/partnerwork/workbook.nim    the base sheet as data, and the audit against it
src/partnerwork/rotation.nim    the unfinished rotation axis, kept separate
app/                            the browser validator
tools/audit.nim                 the same audit, printed
tests/                          the laws, checked over every pair of frames
doc/analysis.md                 what the workbook says, what it is missing
```

```
nimble test         # the laws
nimble audit        # the model and its disagreements with the workbook, printed
```


## What it says

Fifteen frames exist; eleven of them are idiomatic salsa. Sixty-two directed
moves join them, forty within the salsa convention. The `base` sheet of
`ontology.partnerwork.xlsx` records twenty-five of the twenty-six that fall
between the nine states it names, and every one of those twenty-five names the
same primitive the model derives independently.

The gaps are in `doc/analysis.md`. The two largest: there is no state for having
let go, and none for holding the follow's left hand with a hand on their back.

Rotation is not modelled beyond what the base model forces. What it forces is in
`doc/analysis.md` §6, along with the four cells worth dancing to settle the rest.
