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
inextensible, and it may not pass through anybody.

**Turning is real.** The predecessor of this module counted turns and priced
each at half a torso's girth, so a wound rope had a length but no position and
nothing could be checked at any angle but rest. Here a body has a facing;
turning it drags the anchor round the rim and the rope hugs what is in the way.
The hug is an angle, and it may pass a full turn — which a counter can say and
a shortest-path solver cannot, since after a whole turn the shortest path is
the one it was at rest. Only the whole turns are remembered; where the rope
leaves a rim is recomputed every step, so turning out and back returns exactly
what it started with.

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
  heights. Where they are within an arm's thickness the answer is *nothing*,
  because that is a thing dancers settle and not a thing geometry has.
- **That a pair of hands binds tighter than one.** Two crossed connections run
  out at roughly half the turn a single one does, with nothing told to it.

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
moves off its spot, so there are no orbits. The plan path is chosen without
regard to height and the height fitted to it afterwards, which is exact for a
level rope and overstates a steep one — so if the model ever refuses a lift
that dancers do, that is the first thing to suspect. And the measurements are
hand-entered and cited to nothing, which is why the page lets you move them:
every answer is a fact about those numbers until somebody measures a dancer.
