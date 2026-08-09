# The rotation mark workbench

The visual language for the rotation half of the ontology, worked out as
published pages of mock-ups before any of it is built into the app.  The app
deliberately excludes rotation until these marks are settled and the ontology
is finished — see `../src/partnerwork/rotation.nim` for what the model already
knows, and the repository README for why the views came out.

Two pages, because they are two explorations that happen to be related:
`frames.html` is the frame picture (what a held pair of hands looks like, and
how a move changes it) and `signs.html` is the turn sign (how to label an
*edge* with an amount of turning).  They share the palette, the level fills and
the two arm inks, which live in `page.py` and `body.py` so they cannot drift.

```
python3 -m design        # from partnerwork/: checks everything, writes both pages
nimble marks             # the same, as a task
```

The build refuses to write a page whose claims fail: the checks in `checks.py`
run first, and several figures are asserted during their own construction.
Both pages are committed like `doc/review.html` is, so their git history is the
history of what the marks have been claimed to be.  Each is published as a
Claude artifact at a fixed URL; republishing the rebuilt files to those URLs is
the whole release step.

To screenshot them (the animations need a browser):

```
node design/shot.js design/frames.html out-prefix
```


## What is settled

Decisions the pages record, each with the reason it went that way.  These are
the compact form of a long design conversation; changing one should change the
page and this list together.

**The frame picture.**

- Every hand is drawn in **its own side's colour** — `--left` blue, `--right`
  orange — for both dancers, and in **its owner's shade** of it: the lead's
  deep, the follow's plain.  Which column a hand occupies is decided by which
  way its owner faces, so a row read across is that dancer's orientation, and
  the four facings (face to face, either turned, back to back) are distinct
  without a new mark.
- **Shape says whose hand it is**: the lead's are squares, the follow's
  circles.  This is the vocabulary's own convention, carried by the mark
  itself so it survives any size.
- A **connection keeps the lead's arm ink**, because move names depend on which
  of the lead's arms acts.  So the colour pair at its two ends names which
  hands are joined (`Left to left` is blue-to-blue whoever faces where), while
  its geometry says whether the hold is crossed *now*.
- A connection is **two shades of that one hue, meeting at its middle**: deep
  from the lead's hand, plain from the follow's.  So the line says which end is
  whose at the scale where the hand marks have gone too small to read.
- **Level is a fill** on both ends of a connection: hollow = unsaid, solid =
  low (under the other arm), centre dot = high (over it), hatched = above (over
  the head — the only level that names a height).  The under-arm's drawn break
  stays: it reinforces the fill and survives node size.
- A hand nobody holds **fades to half strength but keeps its hue**, because
  `open` is four free hands and greying them would erase orientation exactly
  where nothing else can say it.
- A **body is a plain circle with a small chevron at its centre** for the
  facing — the centre is the one part of a dancer nothing else uses.  The
  boundary stays one polar function (`outline_r`) so the routing and the
  drawing cannot disagree about it.
- The **rim says nothing but *here is a body***: one quiet stroke, drawn once,
  breaking around every hand mark (`HAND_GAP`, the reach's own clearance turned
  into arc).  It used to fill up in an arm's colour as that arm wound — a
  progress ring round the outside — and that is gone, because the connection
  already wraps.  One indicator, not two.  What that costs is in the open
  questions.
- A **reach is a taut string**: it starts on the border of the hand's own mark,
  hugs the rim exactly where the straight way would cross a body, and is
  straight everywhere else.  A way that sets off round a dancer's back pays
  `BACK_BIAS` against one that crosses their front, so near-ties cross the
  chest while a hold that belongs behind the back still goes there.
- **The lead always faces up.**  Poses live in world coordinates and are drawn
  through `canonicalise`, which turns the world until the lead faces up — so
  every pose that is the same configuration is the same picture, and the whole
  state is two numbers: where the follow is round from the lead, and how the
  follow faces.
- A move animates in **two stages** — travel, then canonicalise — and a cycle
  (go, home, back, home) closes exactly, so animations loop without a snap.
  Bodies are rigid and are carried by transforms, on a **continuous** facing
  sequence (`geometry.continuous`): a wrapped one steps from 179 to −179 at a
  half turn and is interpolated as most of a turn backwards, which is a body
  spinning the wrong way while its own hands travel the right way.  Only the
  reach re-routes per frame, keeping the previous frame's way round a body
  unless a new route is decisively shorter.
- An **orbit goes round the other dancer**; a dashed ring appears only while
  one is happening, centred on whoever stands still.  Nothing else is dashed.
- **The collapse** (checked, not argued): a locked quarter-orbit lands on the
  byte-identical picture of the matching quarter axis turn.  So axis-against-
  orbit is a property of the *move*, not the *state* — an edge label, never a
  node's concern.  Likewise both dancers going round each other is a picture
  no-op, which matches the model: a couple rotation stores no twist.

**The turn sign.**

- A leaning box that holds **exactly one full turn**; rows are **quarter
  turns**, packed up from the foot, so amount reads as fullness before it
  reads as a count.
- Columns are the **lead's two arms**, in the frame picture's own order and
  inks; a pip's **shape** says whose quarter it is (leaning square = lead,
  circle = follow), its **shade** says the same thing a second time (deep for
  the lead, plain for the follow, as the hands do), and its **fill** is that
  arm's level, reusing the hand fills.
- Rows may **mix dancers** (follow's rows always on top), so a turn shared
  between the two is one sign.
- A **dashed outline** marks a turn that travels round the couple — an edge
  label, consistent with the collapse above.
- There is **no refused sign**: a turn that cannot be danced is an edge that
  is not drawn.


## What is still open

The user's side of the table, as of the last iteration:

- **Where an amount of winding lives.**  The rim's progress ring is gone and
  the connection's hug replaces it, but a hug is not a measure: it grows while
  the hand rounds the far side and falls away once the hand comes out past the
  back.  A ceiling like `armCapacity` would need something monotone — a mark at
  the hand, or a number on the edge.  The `wind` plate draws the failure.
- The mark for **any amount** of turn: five candidates are drawn on the sign
  page (open-ended box — recommended; open with a spilling pip; ellipsis row;
  music's repeat colon; a loop arrow).  None chosen yet.
- Whether the turn sign **survives at all** now that axis-against-orbit is an
  edge property the frame pictures can animate.
- Whether `rotation.nim` gains **per-dancer facing**: the four orientations are
  two bits and `twist` carries only their parity, so `isFacing` cannot tell
  face-to-face from back-to-back.  The two relative facings the canonical
  picture is built on are exactly the pair the model would need.
- The **wrap side weighting**: `BACK_BIAS` in `route.py` decides how strongly
  a reach prefers crossing the front over rounding the back; the page draws
  both readings of a near-tie, and the number is explicitly unsettled.
- The **bow** for contact with the body, the **staff** for sequences, what an
  orbit stores, and when an arm above the head blocks.


## Layout

```
geometry.py    scalars and vectors, in the drawing's conventions
style.py       the palette, two shades a side, and the connection stroke
pose.py        the couple in world coordinates, and every rotation
body.py        one dancer: outline, hands, captions
route.py       the taut string a connection is routed as
figure.py      whole pictures, still and moving
sign.py        the quarter-turn sign
parts.py       every figure both pages place, keyed as they use them
checks.py      every claim the pages make, asserted
page.py        the chrome the two pages share: style sheet, key, wrapper
frame_page.py  the frame page's prose and layout
sign_page.py   the turn-sign page's prose and layout
__main__.py    build: parts, checks, pages, files
shot.js        screenshot helper (light and dark, full page)
```
