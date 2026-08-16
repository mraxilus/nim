## Name the things a drawing of a couple is made of: sides, levels, holds.
##
##   This is the vocabulary the rules speak in, and the drawing replicates.
##     It sat beside the rules themselves while the marks were being settled
##     and only the workbench drew them; the app draws them now, so the
##     words move to where the drawing is and the ledger stays where the
##     argument is (`design/rules.nim`, which re-exports this).
##   The settle table encodes rules 4 to 6 once; where a hand lands and which
##     way its line goes round are derived from it, never restated.
##     Cost of one table: a reader of `body` or `route` follows a lookup here
##       to see what the dance says.  Accepted -- the alternative is the same
##       fact written twice, which is how two of these rules were broken.
##   These names deliberately overlap `partnerwork/rotation`'s, and do not
##     mean the same things: `Way` is lock against wrap here and clockwise
##     against anticlockwise there.  No module may import both -- see
##     `draw/scene`, which is the one place the two vocabularies meet and
##     keeps them apart by touching only one of them.

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
