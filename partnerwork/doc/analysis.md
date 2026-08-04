# Reading the partner-work ontology back

This is what the model in `src/` found when it was checked against
`ontology.partnerwork.xlsx`. Everything asserted here is also a test, so if the
model changes and this document goes stale, `nimble test` says so.

The short version: the `base` sheet is right. All 25 of its single-helper cells
name exactly the primitive the physics gives for the same pair of frames, which
is not a small thing for a hand-written 9x9 matrix. What it is missing is two
states, one cell, and a distinction between a move and a route.


## 1. What the base sheet turns out to mean

The nine states of the `base` sheet are not nine hand positions. Two of them
involve the follow's torso, and this is forced by the matrix rather than chosen:

- `half-closed` --slide--> `Right to left`
- `closed` --slide--> `Left-to-right and Right-to-left`

A `slide` keeps contact, and contact can only travel along a body. There is no
path from one of the follow's hands to the other, because the space between them
is empty air. So in both `closed` and `half-closed` the lead's right hand must
already be resting on the follow, and sliding down the arm it is touching brings
it to the follow's *left* hand — which is exactly what both cells say. Hence:

| workbook state | lead's Left | lead's Right |
| --- | --- | --- |
| `closed` | follow's right hand | follow's torso |
| `half-closed` | free | follow's torso |

This reading also makes `closed` --drop--> `half-closed`, `closed` --drop-->
`Left to right`, and `Left to right` --collect--> `closed` all come out right,
and it is the only reading that does. Under the alternative reading — the one the
`vocabulary` sheet implies, where `closed` is `Left-to-left and Right-to-right`
and `half-closed` is `Left to right` — the sheet contradicts itself in six cells
and has two pairs of duplicate rows. See finding 5.

So the ontology already has a third kind of place a hand can go, alongside the
follow's two hands: the torso. It just has not been named. The model calls it
`Site.Torso`, and with it the state space is generated rather than listed.


## 2. The state space, derived

A frame is: what each of the lead's two hands holds, plus which arm is on top
where the forearms overlap. Two laws close it:

- a hand of the follow cannot be held by both of the lead's hands;
- an arm order is recorded exactly where the forearms overlap.

The second law is worth stating carefully, because it answers a question written
in the workbook. Partners facing each other are shoulder-to-shoulder in mirror,
so the lead's Left faces the follow's *right*. A connection is therefore
**parallel** when it joins opposite-named hands (`Left-to-right`,
`Right-to-left`) and **crossed** when it joins same-named hands (`Left-to-left`,
`Right-to-right`). Two connections overlap only when both are crossed, which
happens for exactly one pair of holds: `Left-to-left and Right-to-right`.

That is why the over/under distinction belongs to `Left-to-left and
Right-to-right` and not to `Left-to-right and Right-to-left` — and the workbook
already has it exactly that way. Nothing has to remember the rule; it falls out
of who faces whom.

Enumerating gives **15 frames**. Eleven of them are frames a salsa lead would
use; the other four put the follow's torso in the lead's *left* hand, which is
physical but not idiomatic, so the model keeps them behind a `Convention` switch
rather than deleting them.


## 3. Findings

### 1. There is no `open` state

Every single-connection state in the sheet has a `drop` available that leads
nowhere, because a frame with no connection is not in the sheet. `open` is a
real position — it is where every dance begins and where every shine lives — and
it carries five moves in the salsa convention. Without it the graph is not
closed under `drop`, which means the sheet cannot express "let go".

### 2. There is no `Left-to-left and Right-to-torso`

The lead's left hand holds the follow's left, the lead's right rests on their
back. It is one `collect` from `half-closed` and one `collect` from `Left to
left`, both of which are already rows in the sheet, and it is the frame most
cuddle and cross-body preparations pass through. Adding these two states takes
the salsa graph from 26 directed edges to 40.

### 3. One cell is missing its reverse

`half-closed` --slide--> `Right to left` is filled; `Right to left` -->
`half-closed` is blank. Every primitive is reversible — `collect` and `drop`
undo each other, and `trace`, `pass` and `cut` undo themselves — so the matrix
should be symmetric up to that swap. This is the only asymmetry in the sheet.

### 4. Two cells are routes, not moves

`Left to left` --place, collect--> `half-closed` and `Left-to-left over
Right-to-right` --place, drop, collect--> `half-closed` name sequences. The model
derives routes of exactly 2 and 3 primitives for those pairs, so the cells are
correct — but a matrix that mixes single moves with compounds cannot be counted,
inverted or searched. Better to leave those cells blank and let the shortest
route be computed, which is what the app's "not from here" panel shows.

### 5. The vocabulary sheet disagrees with the base sheet

`vocabulary` lists `half-closed` as a variant of `Left to right`, and `closed` as
a variant of `Left-to-left and Right-to-right`. `base` uses all four as separate
states. Both cannot be true: if `half-closed` were `Left to right` the matrix
would have two identical columns with different contents. Section 1 shows which
one to change — the vocabulary needs a torso site and two new frame positions.

### 6. The two sheets use different helper words

`base` uses `slide` and `pass`, which the vocabulary does not define. The
vocabulary defines `trace` and `place`, which `base` never uses. Reading them as
the same pairs (`slide` = `trace`, `place` = `pass`) makes every cell check out,
so this is naming drift rather than a real difference. `flick` is `drop` led with
momentum and changes no state, so it is a manner, not a helper.

Five primitives change the frame, and this is the complete list:

| primitive | what changes | synonyms |
| --- | --- | --- |
| `collect` | a free hand takes a place | |
| `drop` | a held place is released | `flick` |
| `trace` | one hand moves along the partner | `slide` |
| `pass` | a place changes which lead hand holds it | `place` |
| `cut` | an arm re-routes around the arm obstructing it | |

`cut` turns out to be needed for exactly one thing in the base ontology:
exchanging which arm is on top. Every other re-routing has an unobstructed path.

### 7. The variant lists mix two axes

`Left-to-left around Right-to-right` sits in the same list as `Left-to-left over
Right-to-right`. But `over` is a property of a *frame position* — which arm is on
top, part of the state — while `around` is a wrap, which is a *frame modifier*,
the thing the `rotations` sheet produces. Keeping them in one list means the
position list grows every time an arm does something. Section 5 keeps them apart.


## 4. Questions the workbook asks itself

**"Unsure if it is correct to either separate or combine these positions? I'm
leaning heavily towards them being the same thing. Perhaps I need a clearer
definition of what a frame position is."**

They are one position and two states, and both readings are worth keeping:

- a **frame position** is which hands hold which places — `Left-to-left and
  Right-to-right`. It is what you call out on the floor.
- a **frame** is a position plus the arm order. It is what the state machine
  moves between.

The test is whether a dancer can pass between them for free. They cannot: going
from `Left-to-left over Right-to-right` to `Right-to-right over Left-to-left`
takes a `cut`. A machine that merged them would offer a move the arms forbid, so
they have to be separate states. But naming them separately at every mention
would report a new position every time an arm changed height, so the position is
worth keeping as a name. `describe` gives the state, `position` gives the class.

**"Technically you can wrap around neck or torso. Need to find a way to
incorporate it into the taxonomy. Possibly can have lower and upper wrap as
separate frame modifiers?"**

No new axis is needed — the `cut` variants in the same sheet already name it:
*wrist, torso, neck*. That is the site axis, the same one that `Site.Torso` was
just added to. A wrap is (which arm, around which site, at which level), so
extending `Site` with `Neck` — and `Waist` if it earns its place — covers wraps,
cuts and holds with one vocabulary instead of three. `lower`/`upper` is then the
level axis (section 5), not a new kind of wrap.

**"Technically there's also Left-to-all and Right-to-all; I think I'll leave them
out of this ontology as it's an ambiguous lead and they are limiting."**

Worth keeping out, and the reason is stronger than ambiguity: allowing one lead
hand to hold both of the follow's hands breaks the law that a hand holds one
place, which is what makes the state space finite and the matrix countable. If
they are ever wanted, they are two extra frames plus the moves into them, not a
change to the model's shape.


## 5. Axes deliberately outside the state space

These are all real, and none of them belongs in `Frame` — but each is worth
naming so it does not get smuggled in.

- **The follow's free hand.** The ontology is written entirely from the lead's
  hands outward. In closed position the follow's left hand rests on the lead's
  shoulder, and that is a connection the model cannot express. Generalising to
  "any hand of either dancer holds any site on the other" is the one change that
  would make this a true two-body ontology rather than a lead-centric one; it
  costs roughly an order of magnitude in states, and it buys the follow-initiated
  moves and the role-swap symmetry. Recommendation: keep the lead-hand
  projection as the core, and add the follow's free hand as a decorating axis
  only when a move needs to depend on it.
- **Grip.** Palm-to-palm, thumb hook, fingertip, cupped, wrist. Grip does not
  change what is connected, but it changes how much rotation a connection can
  absorb, so it belongs to the rotation axis and will be needed there.
- **Level.** Low and high, which the `rotations` sheet already has columns for.
  No base move depends on it — every collect, drop, trace, pass and cut works at
  either height — which is the justification for leaving it out of `Frame`. Turns
  do depend on it.
- **Proximity.** `closed` and `half-closed` are only available in close
  position; the hand-to-hand frames need arm's length. The base matrix assumes
  the distance changes silently along with the frame, which is fine as long as
  nothing else has to reason about it.
- **Manner.** `flick` versus `drop`, and momentum generally. Same state change,
  different quality, and it affects what can be led *next* rather than what is
  reachable now.


## 6. Rotation: what the base model already implies

The twelve turn sheets are empty, so this is a proposal, not a reading. It is
implemented in `src/partnerwork/rotation.nim` and kept out of the base model.

The quantity a turn adds is **twist**: how far the follow's body has rotated
relative to the lead's. It is one number for the couple, not one per arm,
because both bodies are rigid and both arms see the same relative rotation. Two
things follow with no measurement at all:

- **A rotation of the whole couple stores no twist.** This is why a couple can
  travel round the floor in closed position all night, and why a model that adds
  up each dancer's turns separately would be wrong.
- **The parity of the twist re-reads the whole base matrix.** At half a turn the
  follow's back is to the lead, their left hand is now on the lead's left, and
  every connection that was crossed is parallel. So the base ontology does not
  need to be re-listed for the shadow position — it needs `crossedSite` and
  `parallelSite` to be read with the twist, which is one function.

What needs measurement is how much twist each frame can hold. From the one datum
available — "if you're hand to hand you can only do 1 full rotation comfortably":

| frame | capacity | why |
| --- | --- | --- |
| one hand-to-hand connection | 1 turn | both dancers share the twist across two arms |
| two hand-to-hand connections | 1/2 turn | the arms form a loop and bind |
| any torso connection | none | the arm is already around the partner |

This is a hypothesis with three numbers in it, but it predicts three things that
match the floor: a wrap is led from a two-hand hold and a lock from a one-hand
hold; a follow's underarm turn out of closed position requires the lead's right
hand to leave the back first, which the base matrix already says; and a full
turn on two hands is not comfortable.

The `rotations` sheet has two filled cells, both for `Left to left` held low:
half a turn to the left gives a `wrap`, one full turn to the right gives a
`lock`. Both fit a rule that reads magnitude only — one half-turn of twist wraps,
two lock — and the model uses that. They also fit a rule where the *direction*
decides whether the arm goes across the front (wrap) or behind the back (lock).

**The four cells that settle it:** `Left to left`, held low, at `left@0.5`,
`left@1`, `right@0.5`, `right@1`. If the magnitude rule is right, the two
half-turn cells both say `wrap` and the two full-turn cells both say `lock`. If
the direction rule is right, the two left cells say `wrap` and the two right
cells say `lock`. Dancing those four and writing down what the arm does is the
next piece of evidence the ontology needs, and it is worth more than the other
760 empty cells put together — because with it, the twelve turn sheets stop being
twelve matrices to fill in and become one function of three numbers.
