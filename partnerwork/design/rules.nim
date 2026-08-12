## Hold every rule the mock-ups were given, in the words it arrived in.
##
##   This module is the authority the workbench replicates: the wordings are
##     data, and the vocabulary the rules speak in -- levels, ways, slots --
##     lives beside them, so the checks, the pages and the README all quote
##     one source and cannot drift apart.
##   The settle table encodes rules 4 to 6 once; where a hand lands and which
##     way its line goes round are derived from it, never restated.
##     Cost of one table: a reader of `body` or `route` follows a lookup here
##       to see what the dance says.  Accepted -- the alternative is the same
##       fact written twice, which is how two of these rules were broken.
##   A rule that is only implemented and not asserted quietly stops being
##     true; `checks.checkRules` verifies each one on every build and prints
##     one line per rule.

{.experimental: "strictFuncs".}

import std/options


type
  Dancer* {.pure.} = enum ## Name one of the couple.
    Lead, Follow
  Arm* {.pure.} = enum ## Name a side of a body, and so one hand of a dancer.
    L, R               ## The letter is the markup's own key.
  Level* {.pure.} = enum ## Name the height a connection is held at.
    Low,               ## Under the other arm.
    High,              ## Over the other arm.
    Above              ## Over the head -- the only level that names a height.
  Way* {.pure.} = enum ## Name what a held arm does at its level.
    Lock, Wrap
  Slot* {.pure.} = enum ## Name one of the three spots a hand can settle on a side.
    Front,             ## A little towards the dancer's own front.
    Default,           ## Where the arm hangs.
    Back               ## A little towards the dancer's own back.
  Whose* {.pure.} = enum ## Say which dancer's side a settling hand lands on.
    Own, Other
  Sends* {.pure.} = enum ## Say which way round the body a hold sends its line.
    FrontWay, BackWay
  Settle* = tuple ## Hold what one lock or wrap does to its hand and its line.
    whose: Whose       ## Whose side the hand settles on.
    slot: Slot         ## How far round that side it sits.
    sends: Sends       ## Which way round the body the line goes.


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
  ##   Rule 20 says what an orbit is: the orbiter walks the ring and keeps
  ##     their own bearing, arriving facing the way they set off.
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
  ##     Measured that way, **an orbit does not wind the pair at all**: a
  ##       walker who keeps their bearing never turns relative to their
  ##       partner, so the two axis turns walk this chain and the two
  ##       orbits carry the pair around it without moving along it.  The
  ##       first drawing claimed all four wound, which was only true
  ##       because all four were told to.
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


func settleOf*(level: Option[Level]; way: Option[Way]): Option[Settle] =
  ## Get what this hold does to its hand and its line, where rules 4 to 6
  ## say anything.
  ##   Rules 4 and 5 name the *other* hand; rule 6 names the current one.
  ##   A hold that names no level, or a level without lock or wrap, has no
  ##     settle: there is no knowing which spot it means (rule 2's reading).
  ##   `above` never locks or wraps (rule 8), so it has no settle either.
  if level.isNone or way.isNone:
    return none(Settle)
  let settled: Option[Settle] =
    case level.get
    of Level.Low:
      case way.get
      of Way.Wrap: some (Whose.Other, Slot.Front, Sends.FrontWay)  # rule 4
      of Way.Lock: some (Whose.Other, Slot.Back, Sends.BackWay)    # rule 5
    of Level.High:
      case way.get
      of Way.Wrap: some (Whose.Other, Slot.Front, Sends.FrontWay)  # rule 4
      of Way.Lock: some (Whose.Own, Slot.Back, Sends.BackWay)      # rule 6
    of Level.Above:
      none(Settle)                                                 # rule 8
  settled


const FROM_ABOVE*: array[2, tuple[level: Option[Level], way: Option[Way]]] = [
  (some Level.High, some Way.Wrap),
  (none Level, none Way),
] ## The only transitions out of `above`, per rule 8: an upper wrap, or back
  ## to default.
  ##   *Upper wrap* is read as the high wrap; that reading is the
  ##     implementer's, not the rule's, and the page flags it as such.


const WRAP_MIN* = 170 ## Least degrees a line must hug a body for a lock or a
                      ## wrap to be one at all.
  ##   Rule 7 asks for "no less than just under 1/2 of the circumference".
  ##   The arcs this geometry produces are quantised at 0, 51, 90, 141 and
  ##     180 degrees, so any threshold in that last gap picks out the same
  ##     set; 170 sits squarely in it, and `checks` asserts the gap holds.


type
  Holds* = array[Arm, Option[Arm]]
    ## What each lead hand holds: the follow's own side, where one is held.
  Levels* = array[Arm, Option[Level]]
    ## The level of each held connection, where one has been said.
  Ways* = array[Arm, Option[Way]]
    ## Whether each connection locks or wraps, where that has been said.


func other*(arm: Arm): Arm =
  ## Get the opposite side.
  if arm == Arm.L: Arm.R else: Arm.L


func word*(level: Level): string =
  ## Write a level the way the rules and the pages say it.
  case level
  of Level.Low: "low"
  of Level.High: "high"
  of Level.Above: "above"

func word*(way: Way): string =
  ## Write a way the way the rules and the pages say it.
  case way
  of Way.Lock: "lock"
  of Way.Wrap: "wrap"

func word*(slot: Slot): string =
  ## Write a slot the way the pages say it.
  case slot
  of Slot.Front: "front"
  of Slot.Default: "default"
  of Slot.Back: "back"

func handName*(arm: Arm): string =
  ## Write the follow's hand the way a hold names it.
  ##   Lower case, because case carries meaning across the whole project: the
  ##     lead's hands are `Left` and `Right`, the follow's `left` and `right`.
  if arm == Arm.L: "left" else: "right"
