# The rotation mark workbench

The visual language for the rotation half of the ontology, worked out as a
published page of mock-ups before any of it is built into the app.  The app
deliberately excludes rotation until these marks are settled and the ontology
is finished — see `../src/partnerwork/rotation.nim` for what the model already
knows, and the repository README for why the views came out.

```
python3 -m design        # from partnerwork/: checks everything, writes design/marks.html
nimble marks             # the same, as a task
```

The build refuses to write a page whose claims fail: the checks in `checks.py`
run first, and several figures are asserted during their own construction.
`marks.html` is committed like `doc/review.html` is, so its git history is the
history of what the marks have been claimed to be.  It is published as a Claude
artifact at a fixed URL; republishing the rebuilt file to that URL is the whole
release step.

To screenshot it (the animations need a browser):

```
node design/shot.js design/marks.html out-prefix
```


## What is settled

Decisions the page records, each with the reason it went that way.  These are
the compact form of a long design conversation; changing one should change the
page and this list together.

**The frame picture.**

- Every hand is drawn in **its own side's colour** — `--left` blue, `--right`
  orange — for both dancers.  Which column a hand occupies is decided by which
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
- An **arm is a stretch of that rim**, in its arm's ink, from the front — where
  the two arms meet, under the chevron — round to its hand, and it is inked
  **only while its hand is part of a connection**.  No connection, no line.
  The rim **breaks around every hand mark** (`HAND_GAP`, the reach's own
  clearance turned into arc), so nothing on the boundary runs through a mark.
  How far round the rim the hand has been carried is drawn, which is what a
  wrap or a lock is; past half the rim the stretch turns `--block` red
  (threshold a guess, see open questions).
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
  Bodies are rigid and are carried by transforms; only the reach re-routes per
  frame, with the previous frame's way round a body kept unless a new route is
  decisively shorter.
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
  circle = follow), its **fill** is that arm's level, reusing the hand fills.
- Rows may **mix dancers** (follow's rows always on top), so a turn shared
  between the two is one sign.
- A **dashed outline** marks a turn that travels round the couple — an edge
  label, consistent with the collapse above.
- There is **no refused sign**: a turn that cannot be danced is an edge that
  is not drawn.


## What is still open

The user's side of the table, as of the last iteration:

- The mark for **any amount** of turn: five candidates are drawn on the page
  (open-ended box — recommended; open with a spilling pip; ellipsis row;
  music's repeat colon; a loop arrow).  None chosen yet.
- Whether the turn sign **survives at all** now that axis-against-orbit is an
  edge property the frame pictures can animate.
- Whether `rotation.nim` gains **per-dancer facing**: the four orientations are
  two bits and `twist` carries only their parity, so `isFacing` cannot tell
  face-to-face from back-to-back.  The two relative facings the canonical
  picture is built on are exactly the pair the model would need.
- The **wrap threshold**: the rim turns red past half a turn of winding, a
  guess standing in for `armCapacity`'s measured ceilings; and whether a
  crossed hold should count against it at all.
- The **wrap side weighting**: `BACK_BIAS` in `route.py` decides how strongly
  a reach prefers crossing the front over rounding the back; the page draws
  both readings of a near-tie, and the number is explicitly unsettled.
- The **bow** for contact with the body, the **staff** for sequences, what an
  orbit stores, and when an arm above the head blocks.


## Layout

```
geometry.py   scalars and vectors, in the drawing's conventions
style.py      the palette and the connection stroke
pose.py       the couple in world coordinates, and every rotation
body.py       one dancer: outline, arms, hands, captions
route.py      the taut string a connection is routed as
figure.py     whole pictures, still and moving
sign.py       the quarter-turn sign
parts.py      every figure on the page, keyed as the page uses them
checks.py     every claim the page makes, asserted
page.py       the prose and plates around the figures
__main__.py   build: parts, checks, page, file
shot.js       screenshot helper (light and dark, full page)
```
