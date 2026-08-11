# The rotation mark workbench

The visual language for the rotation half of the ontology, worked out as
published pages of mock-ups before any of it is built into the app.  The app
deliberately excludes rotation until these marks are settled and the ontology
is finished — see `../src/partnerwork/rotation.nim` for what the model already
knows, and the repository README for why the views came out.

Three pages, because they are three explorations that happen to be related:
`frames.html` is the frame picture (what a held pair of hands looks like, and
how a move changes it), `signs.html` is the turn sign (how to label an *edge*
with an amount of turning), and `turns-single.html` is the first of the turn
mock-ups (every position a high single-hand hold turns through, and every
transition between them).  They share the palette, the level fills and the
two arm inks, which live in `page.nim` and `body.nim` so they cannot drift.

The turn mock-ups are being drawn one kind at a time and combined only once
each is right: single hands first, then hand to hand, then the crossed
pair.  An earlier `rotations.html` tried all three at once and is retired --
it was built on a ceiling rule 16 has since removed.

```
nimble marks                            # checks everything, writes both pages
nim c -r --hints:off design/marks.nim   # the same, by hand from partnerwork/
```

The build refuses to write a page whose claims fail: the checks in
`checks.nim` run between building a page's parts and writing it, and several
figures are asserted during their own construction.
Both pages are committed like `doc/review.html` is, so their git history is the
history of what the marks have been claimed to be.  Each is published as a
Claude artifact at a fixed URL; republishing the rebuilt files to those URLs is
the whole release step.

To screenshot them (the animations need a browser):

```
nimble shot                                     # builds design/shot.js
node design/shot.js design/frames.html out-prefix
```


## Rules as given

Every rule stated for this drawing, in the words it arrived in, and the check
that holds the drawing to it.  The wordings live as data in `rules.nim`, so
this list, the checks and the pages quote one source; `checks.checkRules`
runs on every build and prints one line per rule.  A rule that is only
implemented and not asserted is a rule that quietly stops being true, which
has happened here more than once.

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
10. **"using only the rotations that allow us to change between just those
    (i.e. assumed all rotations are high so no wraps/locks)."**  The rotation
    page's standing assumption: every held connection carries the high dot,
    no way is ever named, and nothing settles off its side.
11. **"no additional frame positions, just the addition of rotations that
    let us travel between them."**  Every position the rotation page draws is
    one of the app's eight frames, wound.
12. **"hand to hand should have 3 positions allowed by rotation."**  Half a
    turn each way and no further -- two connections halve the ceiling.  A
    single hold gets five, a full turn each way, the model's own measured
    capacity.
13. **"left to left and right to right should technically have 4 (left over
    right, right over left, and the two sides with an extra arm twist, in
    either direction)."**  The twisted states are the ends: the middle edge
    is the full turn that swaps which arm is over.  *That chain shape is the
    implementer's reading of the words, flagged on the page as the thing to
    check.*
14. **"the rotations should be high, such that there should be no body
    wrapping, also make sure any twists are visually clear just like the
    crossover."**  At high the arms are up, so every connection on the
    rotation page runs straight and passes *over* what it meets; no route
    hugs a rim, and the check measures it.  A twist is said as a crossing
    with the crossover's own over-under break -- free from the geometry for
    a pair, since half a turn swaps parallel for crossed; drawn as a rope
    of three crossings where a pair is wound a whole turn; and as a pigtail
    where a lone connection has no partner to cross.  *The pigtail is the
    implementer's invention and is flagged on the page.*  Rule 16 has since
    retired the pigtail for single hands -- see below.
15. **"for each mock up, a static image version of every derived position
    and full set of animated transitions between states."**  One mock-up
    per kind of turn, each holding every position it derives and an
    animation of every edge between them.  The counts are checked against
    the state graph rather than against a number typed in.
16. **"if held high, they can turn infinitely in either direction, so all
    we add is the additional quarter turn orientations for each of the 4
    single hand connections."**  Nothing on the single-hand page is ever
    refused, and the round closes.  It also takes the wind out of the
    state: a hold that turns for ever has no wound-out end, so how far it
    has wound cannot be part of what it is, and only the orientation is
    left.  That retires rule 14's pigtail for single hands.
17. **"all turns should be in the "above" position, not the high. high/low
    causes wraps/locks, so we're currently making the assumption to avoid
    those."**  The turns pages hold every arm above -- over the head, on
    the axis the couple turns about -- which is the one level rule 8 gives
    no lock and no wrap, and the one that draws its connection straight
    over everything.
18. **"the leads' transitions should still be in the 2 stage form, stage 1
    is the lead turns with the original perspective stage 2 is reorienting
    the perspective."**  A lead's turn is animated as the dance has it: the
    room holds still while they turn, and only then does the picture come
    back to facing them up.  A follow's turn leaves the lead facing up
    already, so it needs only the one stage -- measured, not assumed.
19. **"you should also include orbit turns not just the axis turns."**
    Four ways: each dancer's own axis turn and each dancer's orbit of the
    other, the orbits marked by the dashed ring while they happen.
20. **"make sure orbit turns keep their bearing, youre currently combining
    orbit and axis turns to keep the partner facing the other."**  The
    walker arrives facing the way they set off; `pose.orbit`'s `locked`
    form, which keeps their face to their partner, is an orbit *and* an
    axis turn danced together and is named as the compound it is.
    Measured with the bearing kept: the two orbits walk **one** round
    between them -- the drawing cannot say who walked -- and that round is
    neither axis round.  Four ways of turning, three rounds of positions.
21. **"also, the animations should also have the above level as that's the
    only valid one for the current scope."**  A moving hand wears its
    level as a still one does; every transition on the turns page carries
    the above hatch, counted on each build.
22. **"an arm shouldn't settle in a hand cell it's not connected to. it
    should bend around all hand cells and chevrons as to not imply
    connection and not obscure direction. it is however fine to animate
    smoothly past it as it would do now for a full turn for example."**  A
    settled reach is a band pulled taut *past* every mark it does not join
    -- both chevrons and every hand but its own two -- bending locally round
    each and running straight where nothing is in the way.  The clearance is
    taken from what is actually drawn: a square's corner, a circle's edge, a
    chevron's own two strokes, each plus the connection's half width and a
    seen gap.  The exemption for a moving reach is the rule's own, and the
    check asserts *both* halves -- statics clear every mark, animations stay
    straight.  *Carried on the turns pages first; the frame page's straight
    and wrapping reaches are the next piece, and `partsOf`'s `clear_marks`
    is the switch that will do it.*
23. **"the current line finding does a good job of finding the shortest
    line, but we also need to balance simplicity. prefer paths that have
    fewers bends (ideally 1) as well as length. in many cases I see, 1 bend
    can be used with minimal change to the overall line."**  The shortest
    way past the marks is not the plainest: it weaves, one mark passed on
    the left and the next on the right, and a reader has to follow every
    change of direction.  So a reach is judged on **length and turns
    together** -- a turn is worth `BEND_COST` of line -- and beside the
    shortest way two more are worked out: the taut string held to one side
    of the chord, which is the upper hull of the marks on that side and so
    is a single bend by construction.  The rule's "ideally 1" is read as
    *leave alone anything already turning once or not at all*.  Measured:
    every one of the sixteen reaches that bends now bends exactly once, and
    the one-bend way is usually the **shorter** line as well.

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
- **What collapses** (checked, not argued), and it is narrower than this list
  once claimed.  A quarter-orbit by *either* dancer lands on the
  byte-identical picture, so the drawing cannot say **who walked** — that is
  an edge label, never a node's concern.  And the *compound* of an orbit and
  an axis turn lands on the matching quarter axis turn's picture, so which
  two turns a compound was made of is an edge label too.  What does **not**
  collapse: a plain orbit against an axis turn.  They land in different
  places, so a state does tell them apart, and the old claim that
  axis-against-orbit was purely a property of the move was the locked orbit
  speaking.  Likewise both dancers going round each other is a picture no-op,
  which matches the model: a couple rotation stores no twist.

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

All Nim, like the ontology it serves; `marks.nim` is the build and the rest
are modules it reads in this order:

```
geometry.nim    scalars and vectors, in the drawing's conventions
rules.nim       the ledger above as data, and the vocabulary it speaks in
style.nim       the palette, two shades a side, and the connection stroke
pose.nim        the couple in world coordinates, and every rotation
body.nim        one dancer: outline, spots, hands, captions
route.nim       the taut string a connection is routed as
sign.nim        the quarter-turn sign
figure.nim      whole pictures, still and moving
parts.nim       every figure both pages place, keyed as they use them
checks.nim      every claim the pages make, asserted and spoken
page.nim        the chrome the two pages share: style sheet, key, wrapper
frame_page.nim  the frame page's prose and layout
sign_page.nim   the turn-sign page's prose and layout
turns_single_page.nim  the single-hand turns page, generated as a table
marks.nim       build: parts, checks, pages, files
shot.nim        screenshot helper (light and dark, full page), nim js
```
