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
