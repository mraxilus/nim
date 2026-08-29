# The body sim

Two bodies and two ropes, and nothing else. This directory shares no code and
no vocabulary with the ontology next door: it has its own `Arm` and `Body`
enums, its own vector type, and it imports nothing from `../src`. That is the
point of it. The notation is a shorthand for two people with arms of a length,
and a shorthand cannot check itself — so this is the thing it is a shorthand
*for*, kept separate so that what it says is evidence rather than an echo.

## What it models

A body is a torso cylinder with a head and neck stacked on it, standing
somewhere and facing some way. A hand is anchored on the torso rim at the
shoulder. A connection is a rope of two arms' length tied between two hands,
inextensible, and it may not pass through anybody — nor through the other
connection.

**Turning is real.** The predecessor of this module counted turns and priced
each at half a torso's girth, so a wound rope had a length but no position and
nothing could be checked at any angle but rest. Here a body has a facing;
turning it drags the anchor round the rim and the rope hugs what is in the way.
The hug is an angle, and it may pass a full turn — which a counter can say and
a shortest-path solver cannot, since after a whole turn the shortest path is
the one it was at rest. Only the whole turns are remembered; where the rope
leaves a rim is recomputed every step, so turning out and back returns exactly
what it started with.

**Braiding is real.** Two connections between the same pair are not
strangers: turn one body and they wind about *each other* as surely as a rope
winds about a chest. They always braid; a torso or a head merely gets in
between sometimes. The braid is described about the couple's axis — along it
the rope runs from one anchor to the other, across it the rope sits at the
torso's radius, at an angle turning steadily from the angle its near hand is
at to the angle its far hand is at. Two connections are half a turn apart in
that angle by construction, because one hand of a pair is across the body from
the other.

Everything else falls out of that. The two cross wherever the cosine is zero,
which is once per half turn of relative rotation: nought, one, two, three
crossings — the frame, the X, the diamond, the swan. Nothing counts them. And
at a crossing the cosine being zero makes the sine one, so the two ropes are
`2·lift` apart in height with one above the other: **they cannot pass through
each other because of the shape they are in, not because of a check that
catches them.** Hands held at different heights simply braid wider.

**Height is real.** A body is a *vertical* cylinder, so it obstructs the plan
and nothing else — which lets the plan and the height be solved separately, the
height costing `sqrt(span² + 4·rise²)` for a rope tented over its joined hands.
A body is as wide as whatever part of it the rope passes: torso below the
shoulders, head between shoulders and crown, nothing above. Carrying a
connection over a head is not a special case anywhere in the code; it is what
happens when the width goes to zero.

## What comes out of it, rather than going in

- **Where a rope runs out.** Found by turning until something gives, so it
  moves when the arm or the torso does. Nothing holds the number.
- **Which of two crossing ropes is over.** The higher one, read off the
  heights. Two braiding at one height come out exactly an arm's thickness
  apart, which is as close as the braid will let them lie, and the braid
  settles which took the upper strand. The answer is *nothing* only where they
  are **closer** than that — which is the same reading that refuses the state,
  and rightly so: where two ropes are through each other, which is over is not
  a thing the geometry has.
- **That a pair of hands binds tighter than one.** Two connections run out
  sooner than one, at the same height and the same stance, because they must
  braid past each other as well as reach. Held to as a law now, rather than
  read off a page as it was when this line first said it.
- **Where the ladder's rungs are.** The crossings are counted off the drawn
  ropes and come out 0, 1, 2, 3 at nought, a half, a whole and one and a half
  turns of relative rotation — and a hold joining hands of the same name
  starts a rung up, because it is already crossed.

## What goes in rather than coming out

`Rig.swan` is **1.5 turns**, and it is an input: a report of what dancers
manage, cited to the dance and to nothing in the code. Every other number in
the rig is a measurement of a body. It is applied by `holds` and withheld by
`holds(swan = false)`, and the page shows the swept limit and the asserted one
side by side rather than quietly taking whichever is smaller.

At the hand-entered proportions they disagree, and the disagreement is worth
stating plainly: **the geometry runs out at about three quarters of a turn,
half of what the dance claims.** Lengthen the arm towards 0.70 m or narrow the
torso towards 0.12 m and the swept limit passes 1.5; the page lets you do it.
Two things push the sim's answer low, both of which refuse rather than allow:
the braid holds its strands out at the torso's radius the whole way where real
arms pinch towards the axis, and the couple never step apart to make room.

Published at <https://claude.ai/code/artifact/2944bc6a-551e-4b86-a258-7df1bfa83629>;
republishing `sim/artifact.html` to that URL is the whole release step.

## Reading it

```
rope.nim    the model: bodies, ropes, the taut lie, and turning
draw.nim    a state as two pictures: from above, and from the side
page.nim    the browser page, compiled to JS
laws.nim    what the model is held to, all of it about bodies and rope
index.html  the page's shell and its style
```

```
nimble sim          # the laws, then the page
```

The laws run first and the build stops if any fails: a page drawing a model
that has stopped holding is worse than no page.

## What it will not say yet

A rope has no elbow, so nothing here is about where an arm bends. A body never
moves off its spot, so there are no orbits. **Braiding and winding are not
done at once**: once either rope of a pair has caught on a body, the wind
geometry governs and the braid steps aside — that is the seam in this model,
and the page says so when it happens. The plan path is chosen without
regard to height and the height fitted to it afterwards, which is exact for a
level rope and overstates a steep one — so if the model ever refuses a lift
that dancers do, that is the first thing to suspect. And the measurements are
hand-entered and cited to nothing, which is why the page lets you move them:
every answer is a fact about those numbers until somebody measures a dancer.
