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


## Rules as given

Every rule stated for this drawing, in the words it arrived in, and the check
that holds the drawing to it.  `checks.check_rules` runs on every build and
prints one line per rule; a rule that is only implemented and not asserted is a
rule that quietly stops being true, which has happened here more than once.

1. **"the hands should only pass through the circle when the hand positions are
   above."**  And at *every instant a moving picture draws*, not merely at the
   frames it is sampled at: a browser blends two sampled frames point by point,
   so two that disagree about which side of a body the line passes are drawn,
   in between, as a line sweeping straight through it.  `one_way_round` settles
   the way round once for a whole move so no two frames can disagree, and the
   check samples the blend.  *This one got past two rounds of checks that looked
   only at the frames.*
2. **"the hands can only move from their positions at the side of the body only
   if a level is specified"** — and a level alone is not enough: without knowing
   whether the hold locks or wraps there is no knowing which side the hand went
   to, so both must be named.
3. **"the slots are relative to the front facing side of the lead/follow, not
   from the diagram itself."**  Six spots, `{left, right} × {front, default,
   back}`, every one a bearing off that dancer's own facing.  `SLOT_OFFSET` is
   44°, and two marks need 34.9°, so none of them touch.
4. **"high and low wraps go around to the front of the other hand."**
5. **"low lock goes around the back to the back of the other hand."**
6. **"in high lock the line goes around the back of the modified body"**, to the
   back of the current hand.
7. **"lock/wrap positions can only be used when the connecting line goes around
   no less than just under 1/2 of the circumference.  it doesn't make sense to
   have a wrap or a lock without the line actually going around the body."**
   The arcs this geometry makes are quantised, so `WRAP_MIN` at 170° picks out
   the full half and nothing else — and most states stop existing in most
   orientations.  The build refuses to draw one that falls short; the frame page
   draws the whole grid of which exist where.
8. **"above has no locks/wraps and can only transition to upper wrap or back to
   default (physical restrictions)."**  `FROM_ABOVE` records the two.  *Upper
   wrap* is read as the high wrap — that reading is mine, not the rule's.
9. **The connection is drawn in its two hands' own colours**, meeting at its
   middle, the lead's end in the deep shade.

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
- A connection is drawn in **its two hands' own colours, meeting at its
  middle**: the lead's half in their arm's ink and the deep shade, the follow's
  in theirs and the plain one.  So the line *draws* which named hands are
  joined — `Left to right` runs blue into orange along its whole length —
  instead of leaving it to two marks that vanish at node size, and the deep
  half still says which end is the lead's when both hands share a hue.  Its
  geometry says whether the hold is crossed *now*.
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
  straight everywhere else.  With nothing said it takes the **short way** —
  there is no standing preference for a dancer's front.
- A settled hand is in **one of six spots** and the routing follows from the
  hold; both are rules as given, so see the ledger above rather than here.
- `SLOT_OFFSET` is how far round the rim `front` and `back` sit from a side --
  a drawn convention, wide enough that a mark never touches the grey ghost of
  the place it left, which is asserted.
- **Where a hand has left its default, the place it left is drawn as a grey
  outline** (`figure.ghosts`), so a picture says both where the hand is and
  where it came from.
- A move's **way round is settled once, for the whole move** (`one_way_round`),
  and every frame of it uses that one.  A stronger thing than the
  counter-rotation preference it replaced, and it is why `SIDE_BIAS`,
  `HYSTERESIS`, `prefer` and `trailing` are all gone.
- Only **`above` passes through a body**: it is over the head, so from overhead
  nothing is under it and it is drawn straight (`route.straight_reach`).  Every
  other level, and no level, goes round.
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

- **Whether *upper wrap* means the high wrap** in rule 8, which is the one
  reading in the ledger that is mine rather than given.
- **`SLOT_OFFSET`**, how far round the rim *front* and *back* sit from a side.
  A drawn convention rather than anything the dance says, floored by a mark not
  being allowed to touch its own ghost.
- The mark for **any amount** of turn: five candidates are drawn on the sign
  page (open-ended box — recommended; open with a spilling pip; ellipsis row;
  music's repeat colon; a loop arrow).  None chosen yet.
- Whether the turn sign **survives at all** now that axis-against-orbit is an
  edge property the frame pictures can animate.
- Whether `rotation.nim` gains **per-dancer facing**: the four orientations are
  two bits and `twist` carries only their parity, so `isFacing` cannot tell
  face-to-face from back-to-back.  The two relative facings the canonical
  picture is built on are exactly the pair the model would need.
- Whether an arm **carried past some ceiling** is marked at all, now that
  nothing on the rim counts and the quantity lives in where the hand sits.
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
