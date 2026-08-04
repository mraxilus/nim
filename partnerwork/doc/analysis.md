# Reading the partner-work ontology back

The model in `src/` was built from `ontology.partnerwork.xlsx` and then checked
against it. Every number below is also a test, so `nimble test` says so if this
document goes stale.

**Verdict.** The hand-to-hand part of the `base` sheet is complete and correct.
All 18 of its cells that hold between two hand-to-hand frames name exactly the
primitive the model derives independently, and those 18 cells are *every* move
that exists between the seven states they name — nothing missing, nothing spare.
Three things are outstanding, and they are listed in §3.

| | |
| --- | --- |
| frames the model derives | 8 |
| moves between them | 26 |
| states named in the `base` sheet | 9 |
| of those, hand-to-hand | 7 |
| cells in the sheet | 27 |
| cells checkable now | 18 |
| cells that disagree with the model | **0** |
| moves missing from the sheet | 8, all of them into or out of `open` |


## 1. The model in one page

**A frame** is what each of the lead's hands holds, plus which arm lies on top
where the forearms overlap. Two laws close it:

1. a hand of the follow is held by at most one hand of the lead;
2. an arm order is recorded exactly where the forearms overlap.

**Crossing is derived, not listed.** Partners facing each other are in mirror, so
the lead's Left faces the follow's *right*. A connection is **parallel** when it
joins opposite-named hands (`Left-to-right`, `Right-to-left`) and **crossed**
when it joins same-named hands (`Left-to-left`, `Right-to-right`). Two
connections overlap only when both cross, which happens for exactly one pair of
holds. That is why `Left-to-left and Right-to-right` has an over/under
distinction and `Left-to-right and Right-to-left` does not — and your sheet
already has it exactly that way.

That gives **8 frames**: `open`, four single holds, the parallel pair, and the
crossed pair in its two orders.

**Four primitives** change a hand-to-hand frame:

| primitive | what changes | your synonyms |
| --- | --- | --- |
| `collect` | a free hand takes a hand | |
| `drop` | a held hand is released | `flick` |
| `pass` | a hand of the follow changes which lead hand holds it | `place` |
| `cut` | an arm re-routes around the arm obstructing it | |

`cut` turns out to be needed for exactly one thing: exchanging which arm is on
top. Every other re-routing has a clear path.

`trace`/`slide` is the fifth, and it has nothing to do here: it slides a hand
*along* the partner, and the space between the follow's two hands is empty air.
It returns with the body sites, in §5.


## 2. What the sheet gets right

Worth stating plainly, because it is the bulk of the work:

- Every one of the 18 checkable cells names the right primitive. Not one is
  mislabelled.
- The over/under split is applied to the correct pair and only to that pair.
- `pass` is used exactly where a hand-off is possible and nowhere else.
- `cut` is used exactly for the over/under exchange.
- The compound cells (`place, collect`) are honest about being sequences.


## 3. What is outstanding

### A. `open` is missing — add one row and column

Every single-hold state in the sheet has a `drop` that leads nowhere, because a
frame with no connection is not in the sheet. `open` carries 4 moves and is the
other end of 4 more; it is 8 of the 26 moves in the ontology, and it is where
every dance begins, where every shine lives, and where every hand change that
passes through nothing goes.

Without it the matrix is not closed under `drop`, which means the sheet cannot
express "let go".

### B. `closed` and `half-closed` need a place on the body

These two are the only states in the sheet that are not hand-to-hand, and they
are what the 9 unchecked cells depend on. The cells reaching them say what they
are:

> `half-closed --slide--> Right to left` and
> `closed --slide--> Left-to-right and Right-to-left`

A `slide` keeps contact, and contact can only travel along a body. There is no
path from one of the follow's hands to the other. So in both of those cells the
lead's right hand must *start on the follow's body* and slide down the arm it is
touching to reach their left hand. That is the classic salsa closed hold: left
hand to the follow's right hand, right hand on their back.

Reading them the way the `vocabulary` sheet does instead — `half-closed` =
`Left to right`, `closed` = `Left-to-left and Right-to-right` — makes them
duplicates of rows the sheet already has, and contradicts six of its cells.

Either way, they need a vocabulary for places on the body, which is §5. Until
then they are held out of the model rather than guessed at.

### C. Two naming drifts between the sheets

- `base` uses `slide` and `pass`; `vocabulary` defines `trace` and `place` and
  never uses `slide` or `pass`. They are the same pairs. Pick one word each.
- `Left-to-left around Right-to-right` sits in the same variant list as
  `Left-to-left over Right-to-right`. `over` is part of the *state* — which arm
  is on top. `around` is a wrap, which is a *modifier* produced by rotation.
  Keeping them in one list means the position list grows every time an arm does
  something. §5 keeps them apart.
- `flick` is `drop` led with momentum. It changes no state, so it is a manner,
  not a helper. Worth marking as such so the helper list stays at five.


## 4. The three questions in your notes

**"Unsure if it is correct to either separate or combine these positions? I'm
leaning heavily towards them being the same thing."**

One position, two states. Keep both readings:

- a **frame position** is which hands hold what — `Left-to-left and
  Right-to-right`. It is what you call out on the floor.
- a **frame** is a position plus the arm order. It is what the state machine
  moves between.

The test is whether a dancer can pass between them for free. They cannot:
`Left-to-left over Right-to-right` to `Right-to-right over Left-to-left` takes a
`cut`. Merge them and the machine offers a move the arms forbid. Name them
separately everywhere and you report a new position every time an arm changes
height. In the code this costs one function: `describe` gives the state,
`position` gives the class.

**"Technically you can wrap around neck or torso. Need to find a way to
incorporate it into the taxonomy. Possibly can have lower and upper wrap as
separate frame modifiers?"**

No — the level you already record does it. Your own definitions in `vocabulary`
say a low lock is behind the back and a high lock is at the shoulder of the same
arm; a low wrap crosses under the other arm and a high wrap over it. So the place
on the body is *derived* from (modifier, level) rather than named separately:

| modifier | level | lands on |
| --- | --- | --- |
| wrap | low | torso |
| wrap | high | neck |
| lock | low | waist, behind the back |
| lock | high | shoulder |

Two modifiers × two levels, not four modifiers. The same vocabulary of body
places also serves the `cut` variants you already list (*wrist, torso, neck*).

**"Technically there's also Left-to-all and Right-to-all; I think I'll leave them
out."**

Agreed, and the reason is stronger than ambiguity: one lead hand holding both of
the follow's hands breaks the law that a hand holds one hand, which is what makes
the state space finite and the matrix countable. If you ever want them, they are
two extra frames and the moves into them, not a change to the model's shape.


## 5. Where the body belongs

A hand on the partner's body does not add a frame. It does two things, both of
which live with rotation:

1. **It stops a turn.** An arm already around a partner has no twist left to
   give. This is exactly why a follow's turn out of closed position needs the
   lead's right hand to leave the back first.
2. **It is where a wound arm lands.** `wrap` and `lock` are named by which body
   place the arm is carried around, per the table in §4.

So the body vocabulary — waist, torso, shoulder, neck, and wrist for the `cut`
variants — enters once, in the rotation layer, and serves the deferred states,
the wraps, the locks and the cuts at the same time. That is also where `trace`
becomes a move again, and where `closed` and `half-closed` come back.


## 6. Rotation: what the hand-to-hand model already implies

The twelve turn sheets are empty, so this is a proposal, not a reading. It is
implemented in `src/partnerwork/rotation.nim`, kept out of the base model.

The quantity a turn adds is **twist**: how far the follow's body has turned
relative to the lead's. It is one number for the couple, not one per arm, because
both bodies are rigid and both arms see the same relative rotation.

Two things follow with no measurement at all:

- **A rotation of the whole couple stores no twist.** This is why you can travel
  round the floor without unwinding, and why a model that added up each dancer's
  turns separately would be wrong.
- **The parity of the twist re-reads the whole base matrix.** At half a turn the
  follow's back is to the lead, their left hand is now on the lead's left, and
  every connection that was crossed is parallel. The frames do not change; the
  way they are read does. That is one function, not a second matrix.

What needs measurement is how much twist each frame can hold. From the one datum
available — *"if you're hand to hand you can only do 1 full rotation
comfortably"*:

| what joins the bodies | capacity | why |
| --- | --- | --- |
| one hand-to-hand connection | 1 turn | both dancers share the twist across two arms |
| two hand-to-hand connections | ½ turn | the arms form a loop and bind |
| a hand on the body | none | the arm is already around the partner |

Three numbers, and they predict three things that match the floor: a wrap is led
from a two-hand hold and a lock from a one-hand hold; a turn out of closed
position needs the back hand to leave first; a full turn on two hands is not
comfortable.

### The four cells worth dancing

The `rotations` sheet has two filled cells, both for `Left to left` held low:
half a turn to the left gives a `wrap`, one full turn to the right gives a
`lock`. Two different rules fit both cells:

- **magnitude only** — one half-turn of twist wraps, two lock;
- **direction decides** — turning one way carries the arm across the front and
  wraps, the other way carries it behind the back and locks, at either size.

They disagree about four cells nobody has filled in: **`Left to left`, held low,
at `left@0.5`, `left@1`, `right@0.5`, `right@1`.**

- If magnitude is right: both half-turn cells say `wrap`, both full-turn cells
  say `lock`.
- If direction is right: both left cells say `wrap`, both right cells say `lock`.

Dance those four, write down what the arm does, and the twelve turn sheets stop
being twelve matrices to fill in and become one function of three numbers. That
is worth more than the other 760 empty cells put together. The model currently
reports the magnitude rule, with the question recorded in the source.
