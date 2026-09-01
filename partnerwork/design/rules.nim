## Hold every rule the mock-ups were given, in the words it arrived in.
##
##   This module is the authority the workbench replicates: the ledger the
##     README mirrors entry for entry, and the checks cite by number.
##     Cost of keeping it as data nothing loads: the copies can drift, and
##       only a reader diffing them would notice.  Accepted for now -- the
##       checks' printed lines are worded for what was measured, not for
##       the rule's own phrasing, and rewording them to quote this ledger
##       would change what every build prints.
##   The vocabulary the rules speak in -- sides, levels, holds, the settle
##     table -- lives in `partnerwork/draw/terms` now, and this re-exports it
##     so a reader of the ledger still has the words in scope.  It moved
##     because the app draws these marks now: the words belong beside the
##     drawing, and the argument for them belongs here.
##   A rule that is only implemented and not asserted quietly stops being
##     true; the checkers in `checks.nim` verify the standing ones on every
##     build -- twenty-nine lines for forty rules, the superseded six living
##     here with their corrections and the sheet's five (36 to 40) checked
##     by the sim's instrument rather than the workbench's.

# TODO: Make the ledger load-bearing.
#   The checks could assert their rule numbers against `RULES`, or the
#   README's ledger section could be generated from it.  Either buys
#   drift-proofing at the cost of freezing wordings into the build's
#   output; needs a decision on what the printed lines should say.

{.experimental: "strictFuncs".}

import std/options

import ../src/partnerwork/draw/terms
export terms


const RULES* = [
  "the hands should only pass through the circle when the hand positions " &
    "are above",
  "the hands can only move from their positions at the side of the body " &
    "only if a level is specified",
  "the slots are relative to the front facing side of the lead/follow, " &
    "not from the diagram itself",
  "high and low wraps go around to the front of the other hand",
  "low lock goes around the back to the back of the other hand",
  "in high lock the line goes around the back of the modified body",
  "lock/wrap positions can only be used when the connecting line goes " &
    "around no less than just under 1/2 of the circumference",
  "above has no locks/wraps and can only transition to upper wrap or back " &
    "to default (physical restrictions)",
  "the connection is drawn in its two hands' own colours, meeting at its " &
    "middle, the lead's end in the deep shade",
  "using only the rotations that allow us to change between just those " &
    "(i.e. assumed all rotations are high so no wraps/locks)",
  "no additional frame positions, just the addition of rotations that let " &
    "us travel between them",
  "hand to hand should have 3 positions allowed by rotation",
  "left to left and right to right should technically have 4 (left over " &
    "right, right over left, and the two sides with an extra arm twist, " &
    "in either direction)",
  "the rotations should be high, such that there should be no body " &
    "wrapping, also make sure any twists are visually clear just like the " &
    "crossover",
  "for each mock up, a static image version of every derived position and " &
    "full set of animated transitions between states",
  "if held high, they can turn infinitely in either direction, so all we " &
    "add is the additional quarter turn orientations for each of the 4 " &
    "single hand connections",
  "all turns should be in the \"above\" position, not the high. high/low " &
    "causes wraps/locks, so we're currently making the assumption to avoid " &
    "those",
  "the leads' transitions should still be in the 2 stage form, stage 1 is " &
    "the lead turns with the original perspective stage 2 is reorienting " &
    "the perspective",
  "you should also include orbit turns not just the axis turns",
  "make sure orbit turns keep their bearing, youre currently combining " &
    "orbit and axis turns to keep the partner facing the other",
  "also, the animations should also have the above level as that's the " &
    "only valid one for the current scope",
  "an arm shouldn't settle in a hand cell it's not connected to. it " &
    "should bend around all hand cells and chevrons as to not imply " &
    "connection and not obscure direction. it is however fine to animate " &
    "smoothly past it as it would do now for a full turn for example",
  "the current line finding does a good job of finding the shortest line, " &
    "but we also need to balance simplicity. prefer paths that have fewers " &
    "bends (ideally 1) as well as length. in many cases I see, 1 bend can " &
    "be used with minimal change to the overall line",
  "prefer smooth long curves instead of sharp breaks as well. some of " &
    "these can be accomplished with a singular bezier with a more gentle " &
    "curvature just as well as the current sharp direction changes",
  "reposition the lead such that when the follow orbits or the lead turns " &
    "on axis, the 2nd animation stage doesn't have to move the result " &
    "around, i.e. lead position should remain fixed as much as possible " &
    "(obviously this can't really be the case when the lead orbits, a " &
    "reposition/re entering) will still be necessary I think",
  "make the second animation stage quicker or something so it has less " &
    "emphasis. or whatever the recommended UX is to make it less " &
    "noticeable than the actual rotation itself",
  "the two twisted ends in reality the arms make an overlapping box " &
    "shape. on one side of the twist the lead left is over the right " &
    "(reversed for other end of twist). the arms should reflect that " &
    "visual on both ends of the twist. there should be two crossovers one " &
    "on the leads side of the arms, one on the follows. for both sides of " &
    "the twist chain. there should be a visible box/diamond between the " &
    "crossovers (hence the preliminary names, Left over Right box, Right " &
    "over Left box)",
  "the animations are very jankey and tied to the final visual " &
    "representations of the box/diamond state, add the half turns which " &
    "should actually form an X overhead when partners are facing the same " &
    "direction (similar to the existing L-over-R etc. when facing one " &
    "another) as states in-between the outside 2",
  "the animations don't have the proper breaks that the static images do, " &
    "they seem to not be tracking which arms are over/under because of " &
    "this and they are instances where they end up on the wrong z order, " &
    "fix",
  "the boxes/diamonds are the ends of the turn chain this highlighted is " &
    "not allowed. all I'm referring to is that double box is not allowed",
  "both hand to hand and the overs are essentially the same thing but with " &
    "one half turn of offset. the neutral (non crossed) state in hand to " &
    "hand is when partners are facing, and the same state in the other set " &
    "is when a partner is facing away (in between Left over and Right " &
    "over). hand to hand actually has an extra half turn on both ends " &
    "(which I previously thought only the other pattern had). this means " &
    "both patterns follow the same logic, just one starts with the " &
    "partners facing each other, and the other starts with both partners " &
    "facing the same way",
  "orbit should not maintain bearing, but instead keep whatever side faces " &
    "the center, facing the center otherwise we can't equate the 1/2 turns",
  "the swan zig zag is a bit to large, make it tighter so it looks more " &
    "readable. also, the above level hatching appears to be a background " &
    "that moves around a lot as the squares/circles move, it should stay " &
    "visually consistent during animation",
  "the hatching is good, but revert the swan change, it looks worse",
  "they both have the same issue, go back to the tighter version try to " &
    "make the swan arm, even tighter to the straighter arm, but make it " &
    "smoother (a simpler curved, right now it looks jagged/sharp)",
  "above: connection held above head. high: connection held above shoulder " &
    "level (about neck). low: connection held below shoulder level (about " &
    "torso)",
  "lock: where a lead/follow's arm is bent behind their back (low) or bent " &
    "to the shoulder of the same arm. To get into low lock, the form must " &
    "enter from a low position only due to physical/safety limitations",
  "wrap: where a lead/follow's arm is crossed around the front of their " &
    "body under (low) or over (high) their other arm",
  "generated two hand combinations for up to 1 modifier per lead/follow " &
    "(maximum 2 total across all 4 hands); permutations with 2 modifiers " &
    "for a single person are excluded, until deemed necessary",
  "half-closed, Left to left held low: wrap at left@0.5, lock at right@1",
] ## Each rule verbatim, one-indexed in prose as `RULES[i - 1]`.
  ##   Rules 10 to 14 govern the rotation page: rotation as edges over the
  ##     app's eight frames, everything held high.
  ##   In rule 13 the twisted states are the ends of a chain, not a cycle --
  ##     the middle edge is the full turn that swaps which arm is over.
  ##     That chain shape is the implementer's reading of the words, flagged
  ##       on the page as the thing to check.
  ##   Rule 14 rules out the drawing the first draft reached for: at high
  ##     the arms are up, so a connection passes *over* a turning body and
  ##     never routes round one.  A twist is said the way the crossover is
  ##     said -- lines crossing, with the over-under break naming which is
  ##     on top -- and never by which side of a body a line hugs.
  ##   Rules 15 and 16 turn the work into one mock-up per kind of turn, and
  ##     rule 16 takes the ceiling off a high single hand.
  ##     A hold that turns for ever has no wound-out end, so how far it has
  ##       wound is not part of its state; only the orientation is, which is
  ##       why a single hand has exactly four positions and no more.
  ##     That retires rule 14's pigtail for single hands: it was invented to
  ##       tell one wind from its mirror, and with no ceiling there is
  ##       nothing left for it to tell apart.  The crossing convention
  ##       stands for pairs, where the geometry makes the crossing itself.
  ##   Rule 17 moves the assumption from `high` to `above`, and says why:
  ##     high and low are the levels a wrap or a lock is made at, so a turn
  ##     drawn at either invites the very states this work is holding out
  ##     of scope.  Above is over the head, on the axis the couple turns
  ##     about, and has no lock and no wrap by rule 8.
  ##   Rule 18 keeps the two stages the frame page dances a lead's move in:
  ##     the lead turns while the world holds still, and only then does the
  ##     picture turn back to face them up.
  ##   Rule 19 adds the orbit turns beside the axis turns.
  ##   Rule 20 said what an orbit is: the orbiter walks the ring and keeps
  ##     their own bearing, arriving facing the way they set off.
  ##     **Rule 32 has since reversed this**, and the paragraphs below are
  ##       kept for what they measured rather than for what they concluded.
  ##     `pose.orbit` has always had this as `locked = false`; the locked
  ##       form keeps the orbiter's face to their partner, which is an
  ##       orbit and an axis turn danced together, not an orbit.
  ##     Measured with the bearing kept: the two orbits reach one round of
  ##       positions -- the drawing cannot say which dancer walked -- and
  ##       that round is not either axis round.  Four ways of turning,
  ##       three rounds of positions.
  ##   Rule 21 puts the level on a moving hand as well as a still one; on
  ##     the turns pages that is above, the only level in scope.
  ##   Rule 22 keeps a settled reach out of the marks it does not join.
  ##     A line through a hand cell says the hand is held, and a line
  ##       through a chevron hides which way its dancer faces; a settled
  ##       picture must say neither.
  ##     The exemption for a moving reach is the rule's own: passing
  ##       smoothly across a mark is what a turn does, and a bend that
  ##       appeared and vanished mid-move would be a mark of its own.
  ##   Rule 23 says the shortest way past those marks is not the plainest:
  ##     a line that weaves -- one mark on the left, the next on the right --
  ##     costs a reader a turn to follow at every change of direction.
  ##     So length is not the only price a route pays.  A bend is worth
  ##       `route.BEND_COST` of line, and a route is chosen on the two
  ##       together; the rule's own reading of "ideally 1" is that a route
  ##       is left alone once it turns no more than once.
  ##   Rule 24 asks the one bend to be a curve rather than a corner.  Rule
  ##     23's one-bend route was the hull of the marks, and a hull is a
  ##     polyline: its apex is a break.  A quadratic bezier over the same
  ##     apex says the same thing, turns one way only, and has no corner in
  ##     it anywhere.
  ##   Rule 25 frames a picture on the lead rather than on the pair.
  ##     `canonicalise` turned the world about the couple's midpoint, so a
  ##       move that shifts that midpoint carried the lead across the box
  ##       in the second stage, and the reader had to find them again.
  ##     Turning about the lead's own place instead: a follow's orbit needs
  ##       no second stage at all, a lead's axis turn swings only the
  ##       follow, and the lead's own orbit -- the one case the rule allows
  ##       -- comes home as a straight slide.
  ##   Rule 26 makes the second stage subordinate to the first.
  ##     The two stages had a sample each way and so a share of the clock
  ##       each way, which read as one long motion in two halves rather
  ##       than a turn and the picture following it.
  ##     Three things carry the ranking, and they are what motion design
  ##       does with any secondary or camera move: the re-framing takes far
  ##       less of the clock than the turn (`RE_FRAME_PACE`), a beat is
  ##       held on the turn's landing so the two do not blur into one
  ##       (`ARRIVAL_HOLD`), and it still starts and ends softly, because
  ##       an abrupt start is the one thing that would pull an eye back to
  ##       it.
  ##     How long each stage lasts is now the drawing's business rather
  ##       than a side effect of how finely it was sampled: a walk carries
  ##       when each of its frames is due, and the markup says so.
  ##   Rule 27 says what the twisted ends of a two-hand chain look like.
  ##     A parallel pair does not cross; a pair wound a whole turn crosses
  ##       twice, once by each dancer, and what the two crossings enclose
  ##       is the box the rule names.
  ##     Two answers settle how it is read.  *"three positions, full turn
  ##       required between them"*: a step on that page is a whole turn,
  ##       which is what makes rule 12's three a chain -- a whole turn puts
  ##       every place and every facing back where it was, and what it
  ##       leaves behind is the wind.  And *"they alternate"*: whichever
  ##       connection is over at the lead's crossover is under at the
  ##       follow's, because that is what being wound together means.  Two
  ##       crossings the same way round would be one arm lying on another.
  ##     So the two pages are duals.  A single hand turns for ever, so its
  ##       wind is not part of its state and its orientation is all of it
  ##       (rule 16); hold both hands and a whole turn returns every
  ##       orientation, so the wind is all of it instead.
  ##   Rule 28 adds the half turns, and in doing so says where rule 27's
  ##     first drawing went wrong.
  ##     At a half turn the partners face the same way and the pair makes
  ##       an **X**, which is the crossing the geometry itself gives -- the
  ##       same mark the app already uses for a crossed pair.  So the chain
  ##       is five: box, X, the frame, X, box, a half turn apart.
  ##     "tied to the final visual representations" is the fault named: the
  ##       wind was a number handed to the drawing, and the box was swelled
  ##       by it on top of geometry that was not winding at all.  It is now
  ##       **measured** instead -- the angle each held hand makes with the
  ##       pair's own axis, and the difference between the two ends is the
  ##       wind.  A reach is then the shadow of a wound arm: its offset
  ##       from the axis swings as far round as the pair has wound, which
  ##       is straight at none, an X at a half, and a diamond at a whole,
  ##       with nothing imposed and nothing to jump.
  ##     Measured that way, an orbit that keeps its bearing does not wind
  ##       the pair at all: such a walker never turns relative to their
  ##       partner.  The first drawing claimed all four ways wound, which
  ##       was only true because all four were told to.
  ##     **Rule 32 has since made that finding moot** by changing what an
  ##       orbit is.  A walker who keeps their side to the centre does turn
  ##       relative to their partner, so all four ways wind after all --
  ##       and this time it is measured rather than claimed.
  ##   Rule 29 gives a moving crossing the break a still one has.
  ##     A still reach is cut into runs at every crossing it dives under,
  ##       and how many runs that makes depends on how many crossings there
  ##       are -- which is why a moving reach was left whole: a path whose
  ##       number of pieces changes cannot be morphed between frames.  With
  ##       nothing broken, which strand is on top was decided by the order
  ##       the two were written in, so one of them was over at *both*
  ##       crossings.  That is not a twist, and it disagreed with the still
  ##       the move landed on.
  ##     A gap in a stroke is not the same thing as a gap in a path,
  ##       though.  A moving reach keeps its one piece and carries the
  ##       break as a dash instead, which travels with the crossing and
  ##       closes to nothing where there is no crossing to mark -- so the
  ##       markup never changes shape and there is nothing to jump.
  ##     Which arm dives is not a new decision: the crossings are found as
  ##       the stills find them, the diving arm alternates from the first
  ##       as the stills alternate it, and the first is named by the sign
  ##       of the measured wind -- so a moving figure and the still it
  ##       lands on cannot disagree.
  ##   Rule 30 says the chain is a chain and not a cycle, and that its ends
  ##     hold: a whole turn either way is as far as this scope winds, so
  ##     nothing may be drawn wound a turn and a half.
  ##     The fault was in the turning, not the drawing.  Every edge was
  ##       built with the same positive half turn, but the two axis turns
  ##       wind opposite ways -- a positive turn by the lead unwinds what a
  ##       positive turn by the follow winds.  The chain's winds are the
  ##       follow's way round, so the lead's edges were walking backwards
  ##       off the end: from the box at a whole turn out to a turn and a
  ##       half, which drew a third crossing and a second diamond.
  ##     So each way's sense is **measured**, as rule 28 measures the wind
  ##       itself: turn a quarter from the frame and see which way the pair
  ##       wound.  A quarter and not a half, because a half turn's wind is
  ##       exactly the wrap point of `wrap180` and carries no sign.  A way
  ##       that winds nothing -- either orbit, as orbits then were -- takes
  ##       the positive sense, since it has a real half turn to travel and no
  ##       end to walk off.  **Rule 32 has since left no such way**: every one
  ##       of the four winds, so that fallback is unreachable and stands only
  ##       so a way that stopped winding could not silently freeze.
  ##     Rule 31 has since moved those ends: they are the swans, at a turn
  ##       and a half.  The rule was that the chain *has* ends and they
  ##       hold, never that they sat at a whole turn -- and what it refused,
  ##       the double box, is refused still, by the swan being drawn as a
  ##       swan rather than as two diamonds stacked.
  ##   Rule 31 makes the two two-hand patterns one chain, and hands this
  ##     page the two positions it was missing.
  ##     Rule 13 had already said the crossed pair has "the two sides with
  ##       an extra arm twist, in either direction", and that extra twist
  ##       was read as belonging to that pattern alone.  It does not: hand
  ##       to hand has one at each end too, so the chain is seven -- swan,
  ##       diamond, X, the frame, X, diamond, swan.
  ##     What differs between the two holds is only *where the chain sits*.
  ##       A hold is unwound where its two connections run parallel, and
  ##       that falls at a different facing for each: hand to hand face to
  ##       face, the crossed pair with one partner facing away.  So the
  ##       phase is measured -- turn the follow to each candidate and see
  ##       which leaves the hold unwound -- and the crossed page becomes
  ##       this page's code with a different hold rather than a rewrite.
  ##     What a turn and a half looks like is the rule's own answer: *"don't
  ##       draw it as a double box, draw it as one connection being straight
  ##       and the other snaking around it (as that's how it looks in
  ##       reality when I tried it). I'm giving it the preliminary name of
  ##       swan, as it looks like the necks of two mating swans surrounding
  ##       a center straight connection."*
  ##     Which the geometry now does rather than fakes: past a whole turn
  ##       the pair stops sharing its swing evenly and hands it over, so at
  ##       a turn and a half one reach is the plain chord between its own
  ##       hands and the other carries the lot.  Handed *over* and not
  ##       merely given up, or the loops would be too shallow to read as a
  ##       thing going round.
  ##     And the straight one is the one on top at the first crossing, which
  ##       by the alternation dives only once: broken twice, there would be
  ##       no straight line left in the middle for anything to surround.
  ##   Rule 32 corrects rule 20, and says what an orbit is for good: the
  ##     walker keeps **whatever side of them faced the centre facing it**,
  ##     so they turn as far as they travel.
  ##     The reason given is the one that matters, and is about the whole
  ##       scheme rather than about orbits: *"otherwise we can't equate the
  ##       1/2 turns"*.  Rule 20's orbit turned the walker not at all
  ##       relative to their partner, so -- measured, under rule 28 -- it
  ##       wound the pair by nothing.  Half a turn of it was half a turn of
  ##       no quantity, and two of the four ways of turning did not walk the
  ##       chain at all.  Facing the centre, an orbit winds exactly as far
  ##       as it carries, and every way steps one position per half turn.
  ##     `pose.orbit` has always had this as `locked = true`; rule 20 turned
  ##       it off and rule 32 turns it back on.  What rule 20 objected to --
  ##       *"combining orbit and axis turns"* -- is the same arithmetic seen
  ##       from the other side, and it is the bearing-keeping walk that is
  ##       the compound now: an orbit with a counter-turn danced into it.
  ##     The consequence runs through everything.  An orbit lands where the
  ##       *other* dancer's axis turn lands, so the four ways walk **two**
  ##       rounds of positions rather than three, each round reached by one
  ##       axis turn and by the other dancer's orbit.  All four are still
  ##       drawn: which dancer walked is a fact about the path, and only the
  ##       path can say it.
  ##     And on the frame page the two collapse figures swap over.  It is
  ##       the orbit that now lands on the matching axis turn, and the
  ##       bearing-keeping compound that lands somewhere of its own -- the
  ##       one picture either dancer's compound reaches, since only the
  ##       pair's axis has swung.
  ##   Rule 33 tightens the swan and fixes a mark that would not hold still.
  ##     The swan's snake took the whole of the straight connection's swing
  ##       as well as its own, which opened loops wider than the pair they
  ##       belong to.  `route.SWAN_SWING` says how much it ends up carrying
  ##       instead: enough to read as going *round* the straight one, not so
  ##       much that the zig-zag leaves the figure.
  ##     The hatch is the other half, and it was a real fault rather than a
  ##       matter of taste.  An `above` fill is an SVG pattern anchored to
  ##       **user space**, so a mark that animates its own coordinates
  ##       slides across a hatch that is standing still, and the fill swims
  ##       about inside its own outline.  A moving hand is drawn once at the
  ##       origin and carried by a transform now, exactly as a body is: the
  ##       hatch is carried with it and holds its place (rule 21).
  ##   Rule 34 keeps the hatch and takes the tightening back: *"the hatching
  ##     is good, but revert the swan change, it looks worse."*
  ##     So `SWAN_SWING` went back to two, which is the whole of what the
  ##       straight connection gives up, and the check's upper bound on the
  ##       bow dropped back to a backstop -- far enough out to catch a snake
  ##       that has left the figure, and no opinion within that.  **Rule 35
  ##       has since set the width again**; the backstop is what stayed.
  ##     The two halves of rule 33 were one instruction and turned out to be
  ##       two different kinds of thing.  One was a fault the drawing could
  ##       be held to; the other was a matter of looks, and looks are
  ##       settled by looking.  Naming the knob was worth doing anyway --
  ##       what it is set to is the author's call, not the checker's.
  ##   Rule 35 finds what was actually wrong with both swans, and it was
  ##     never the width: *"they both have the same issue ... it looks
  ##     jagged/sharp."*
  ##     A reach is held as `ROUTE_N` points because that is what lets it
  ##       morph, and it was **drawn** between them with straight bits.
  ##       Everywhere else on every page that is invisible -- rule 24 keeps
  ##       a settled reach turning a few degrees a corner -- but a swan's
  ##       lobes double back inside a handful of points, so the polygon it
  ##       is stored as was exactly what was on the screen.  Widening or
  ##       narrowing it only changed how big the facets were.
  ##     So a reach is drawn as quadratics now (`route.smoothed`): the
  ##       sampled points become control points and the midpoints between
  ##       them the places the curve passes through.  Corners round off,
  ##       the ends stay on their hands, a line that hardly turns moves by a
  ##       fraction of its own width -- and the command count still follows
  ##       the point count, so it morphs as before.
  ##     The width comes down as well, and the rule asks for tighter than
  ##       either width that was tried -- so `SWAN_SWING` goes below both,
  ##       and the snake keeps in closer to the straight connection than any
  ##       version before it.  What it is set to remains the author's call
  ##       and not the checker's (rule 34); the check is only the backstop.
  ##   Rules 36 to 40 arrive from the ontology sheet's own vocabulary and
  ##     rotation tables, and 36 corrects a reading this codebase had held:
  ##     **every level is a height**.  Low and high were documented here as
  ##     relative -- which arm lies over which -- and that was wrong: the
  ##     over-under of two arms is part of what a *wrap* is (rule 38, under
  ##     the other arm low, over it high), while the level says only where
  ##     on the body the connection rides.
  ##   Rule 37 settles what a high lock is: the arm bent to the shoulder of
  ##     the *same* arm.  Rule 6 said its line goes around the back of the
  ##     modified body, and the two are one shape -- the hand comes round
  ##     the back up to its own shoulder, a hammerlock -- so the settle
  ##     table's `(Own, Back)` stands.  The entry note is a transition
  ##     fact, the first the ledger has that is about safety rather than
  ##     shape; the sim reads it geometrically in `sim/verdicts.md` and
  ##     finds the wound low lock holds at the height it is formed at.
  ##   Rule 38's under-or-over the *other* arm is a mark no drawing here
  ##     makes yet: a settled reach bends around the hands it does not join
  ##     (rule 22), so the crossing a wrap makes with its dancer's other
  ##     arm -- the very thing that tells a low wrap from a high one -- is
  ##     exactly what the routing avoids drawing.  Recorded as open rather
  ##     than patched: saying it needs the other arm in the picture, and a
  ##     decision about rule 22's scope.
  ##   Rule 39 makes the modifiers per-arm for either dancer, up to one
  ##     each.  The drawing model holds a level and a way per *connection*
  ##     and settles only the follow, which covers the sheet's validated
  ##     rows but not its enumeration; widening it is a restructure, noted
  ##     in the README's open questions rather than done quietly here.
  ##   Rule 40 is the sheet's one filled rotation row, and the sim derives
  ##     it independently (`sim/verdicts.md`): from Left to left held low,
  ##     half a turn one way lies the arm across the front -- the wrap --
  ##     while the lock takes a *whole* turn the other way, the rope
  ##     merely leading the hand behind the back at its half.  The row and
  ##     the rope agree, laps and all, and neither was told the other's
  ##     answer.


const FROM_ABOVE*: array[2, tuple[level: Option[Level], way: Option[Way]]] = [
  (some Level.High, some Way.Wrap),
  (none Level, none Way),
] ## The only transitions out of `above`, per rule 8: an upper wrap, or back
  ## to default.
  ##   *Upper wrap* is read as the high wrap; that reading is the
  ##     implementer's, not the rule's, and the page flags it as such.
