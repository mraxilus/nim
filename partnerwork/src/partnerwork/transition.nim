## Derive every change of frame from the primitive transition helpers.
##
## The ontology names six helpers, and marks two of them with an asterisk:
## `place*` is "collect then drop" and `cut*` is "drop then collect", each
## keeping contact through a trace.  The asterisks are right, so neither is a
## primitive here.  Of the remaining four, `flick` is a `drop` led with momentum
## and changes no frame, and `trace` slides a hand along the partner's body,
## which needs a place on the body to slide to and so waits for the rotation
## axis.
##
## That leaves two primitives, `collect` and `drop`, and one relation: two frames
## are one move apart exactly when one connection separates them.  `place` and
## `cut` are kept as *compounds*, because a lead thinks of each as one move even
## though the arms do two, and because the workbook writes them in single cells.
##
## Nothing here is a table of moves.  A move exists between two frames exactly
## when the difference between them is one primitive, so the transition relation
## is *classified* rather than listed, and the matrix in the workbook becomes
## something to check against rather than the source of truth.
##
## Every primitive is reversible: `collect` undoes `drop`, and `pass` and `cut`
## undo themselves.  The relation is therefore symmetric, which is the strongest
## law the module offers for testing.

{.experimental: "strictFuncs".}

import std/[algorithm, options, strutils]

import ./frame



#[ Concepts ]#

type
  Helper* {.pure.} = enum ## Name a primitive way one frame becomes another.
    Collect,              ## Form a connection with a free hand.
    Drop                  ## Break a connection, releasing the hand.

  Compound* {.pure.} = enum ## Name a pair of primitives the dance calls one move.
    Place,                  ## Hand one connection over to the other lead hand.
    Cut                     ## Re-route an arm around the arm in its way.

  Move* = object ## Hold one primitive change of frame.
    helper*: Helper ## Primitive that carries the change.
    side*: Side     ## Lead hand that acts: the receiver for a pass, the arm that
                    ## ends on top for a cut.
    to*: Frame      ## Frame the couple arrives in.


const HELPER_CHANGES*: array[Helper, string] = [
  Helper.Collect: "a free hand takes a hand",
  Helper.Drop: "a held hand is released",
] ## Say what each primitive changes about the frame.


const HELPER_SYNONYMS*: array[Helper, string] = [
  Helper.Collect: "",
  Helper.Drop: "flick when led with momentum",
] ## Give the workbook's other word for a primitive, where it has one.


const HELPER_MARKS*: array[Helper, char] = [
  Helper.Collect: 'c',
  Helper.Drop: 'd',
] ## Abbreviate each primitive to the one letter a matrix cell has room for.


const COMPOUND_CHANGES*: array[Compound, string] = [
  Compound.Place: "one hand of the follow changes which lead hand holds it",
  Compound.Cut: "the arms exchange which one lies on top",
] ## Say what each compound changes about the frame.


const COMPOUND_ORDERS*: array[Compound, string] = [
  Compound.Place: "collect, then drop",
  Compound.Cut: "drop, then collect",
] ## Give the order the workbook writes each compound in.


const COMPOUND_OBSTRUCTED*: array[Compound, bool] = [
  Compound.Place: false,
  Compound.Cut: true,
] ## Say whether the other arm lies in the path the trace has to take.


const COMPOUND_MARKS*: array[Compound, char] = [
  Compound.Place: 'p',
  Compound.Cut: 'x',
] ## Abbreviate each compound for a matrix cell.
  ##
  ## `cut` takes the letter it does because `collect` has the one it would want.


func name*(helper: Helper): string = ($helper).toLowerAscii
  ## Name a primitive as the ontology writes it.


func manner*(helper: Helper): string =
  ## Name a primitive together with the workbook's other word for it.
  if HELPER_SYNONYMS[helper].len == 0:
    helper.name
  else:
    helper.name & ", or " & HELPER_SYNONYMS[helper]


func inverse*(helper: Helper): Helper =
  ## Get the primitive that undoes this one.
  case helper
  of Helper.Collect: Helper.Drop
  of Helper.Drop: Helper.Collect



#[ Classification ]#

func classify*(a, b: Frame): Option[Helper] =
  ## Get the primitive taking one frame to another, where a single one does.
  if a == b or not a.isValid or not b.isValid:
    return none(Helper)
  let
    moved_left = a.hold[Side.Left] != b.hold[Side.Left]
    moved_right = a.hold[Side.Right] != b.hold[Side.Right]
  if not moved_left and not moved_right:
    # Same connections, so only the arm order differs, which is a `cut`: the arm
    # underneath has to be released and re-taken over the other one.
    return none(Helper)
  if moved_left != moved_right:
    let side = if moved_left: Side.Left else: Side.Right
    if a.hold[side].isNone:
      return some(Helper.Collect)
    if b.hold[side].isNone:
      return some(Helper.Drop)
    # One hand has moved from one hand of the follow to the other, which is a
    # trace with nothing to trace along: the space between the follow's hands is
    # empty air.  It becomes a move once the arms and body are places to hold.
    return none(Helper)
  none(Helper)


func compound*(a, b: Frame): Option[Compound] =
  ## Get the compound joining two frames, where the ontology names one.
  ##
  ## Both are two primitives with a name.  A `place` hands one connection to the
  ## lead's other hand; a `cut` hands one arm over the other.
  ##
  ## A `place` is routed through the open frame, letting go and taking again,
  ## rather than through a moment where both hands of the lead hold one hand of
  ## the follow.  That moment is the same ambiguity the ontology already refuses
  ## in `Left-to-all`, one hand joined to two things, so it is refused in this
  ## direction too.  A lead who keeps contact through the hand-off is dancing the
  ## quality the workbook means by "maintaining a connection via a trace"; the
  ## frames either side of it are the same either way.
  if a == b or not a.isValid or not b.isValid:
    return none(Compound)
  if a.hold == b.hold:
    return some(Compound.Cut)
  if a.countHolds != 1 or b.countHolds != 1:
    return none(Compound)
  let
    source = if a.hold[Side.Left].isSome: a.hold[Side.Left] else: a.hold[Side.Right]
    destination = if b.hold[Side.Left].isSome: b.hold[Side.Left] else: b.hold[Side.Right]
  if source == destination:
    return some(Compound.Place)
  none(Compound)


func actingSide*(a, b: Frame; helper: Helper): Side =
  ## Get the lead hand that carries a change of frame.
  if a.hold[Side.Left] != b.hold[Side.Left]: Side.Left else: Side.Right



#[ Moves ]#

func compare(a, b: Move): int =
  ## Order moves by primitive, then by the acting hand, for a stable display.
  if a.helper != b.helper:
    return cmp(ord(a.helper), ord(b.helper))
  if a.side != b.side:
    return cmp(ord(a.side), ord(b.side))
  cmp(a.to.key, b.to.key)


func moves*(source: Frame): seq[Move] =
  ## Get every frame one primitive away, with the primitive that reaches it.
  ##
  ## This is the whole answer to "what can we do from here": a frame absent from
  ## the result is not reachable without an intermediate frame.
  for destination in FRAMES:
    let helper = classify(source, destination)
    if helper.isNone:
      continue
    result.add Move(
      helper: helper.get,
      side: actingSide(source, destination, helper.get),
      to: destination,
    )
  result.sort(compare)


func phrase*(source: Frame; move: Move): string =
  ## Say a move the way a teacher would call it, naming both hands.
  ##
  ## Which dancer each hand belongs to is said by its case and by nothing else:
  ## `collect Right to left` is the lead's right hand taking the follow's left.
  ## See `leadName`.
  let hand = leadName(move.side)
  case move.helper
  of Helper.Collect:
    result = "collect " & hand & " to " & followName(move.to.hold[move.side].get)
    if move.to.hasOverlap:
      result.add ", " & (if move.to.over.get == move.side: "over" else: "under") &
        " the " & leadName(other(move.side)) & " arm"
  of Helper.Drop:
    result = "drop " & hand & " from " & followName(source.hold[move.side].get)



func compoundSide*(source, destination: Frame): Option[Side] =
  ## Get the hand of the lead that moves when a compound is led.
  ##
  ## For a `cut` it is the arm that ends up on top, because that is the one that
  ## let go and came back over the other.  For a `place` it is the hand that ends
  ## up holding, because that is the one that took what the other let go of.
  let named = compound(source, destination)
  if named.isNone:
    return none(Side)
  case named.get
  of Compound.Cut: destination.over
  of Compound.Place:
    some(if destination.hold[Side.Left].isSome: Side.Left else: Side.Right)


func compoundName*(source, destination: Frame): string =
  ## Name a compound and the hand of the follow it moves, as `label` names a move.
  let
    named = compound(source, destination)
    side = compoundSide(source, destination)
  if named.isNone or side.isNone:
    return ""
  ($named.get).toLowerAscii & " " & followName(destination.hold[side.get].get)


func compoundPhrase*(source, destination: Frame): string =
  ## Say a compound the way a teacher would call it, with every hand named.
  let named = compound(source, destination)
  if named.isNone:
    return ""
  let
    side = compoundSide(source, destination).get
    hand = followName(destination.hold[side].get)
  case named.get
  of Compound.Cut:
    "cut " & hand & ": drop " & leadName(side) & ", then collect it back over " &
      "the " & leadName(other(side)) & " arm"
  of Compound.Place:
    "place " & hand & " from " & leadName(other(side)) & " into " &
      leadName(side)


func label*(source: Frame; move: Move): seq[string] =
  ## Name a move in the fewest words that still say what to do, a line at a time.
  ##
  ## A `collect` has to say which hand of the follow it takes, because the same
  ## hand of the lead can reach either, and it has to say over or under where
  ## both arms cross, because that is the whole difference between the two frames
  ## it could arrive in.  A `drop` says neither: the hand that acts is already
  ## holding one thing, so there is nothing left to choose.
  ##
  ## The hand named is the follow's, and is said to be by its case alone: `left`
  ## is the follow's where `Left` would be the lead's, throughout the ontology.
  ## Which hand of the *lead* acts is left to the ink the words are written in,
  ## which is what a drawing has that a sentence does not.
  ##
  ## The lines are short so that the words fit where a drawing has room for them,
  ## which is usually beside a line rather than along it.
  case move.helper
  of Helper.Collect:
    result = @["collect " & followName(move.to.hold[move.side].get)]
    if move.to.hasOverlap:
      result.add(if move.to.over.get == move.side: "over" else: "under")
  of Helper.Drop:
    result = @["drop"]



#[ Routes ]#

func route*(source, destination: Frame): seq[Move] =
  ## Get a shortest sequence of primitives joining two frames, if one exists.
  ##
  ## The workbook records compound cells such as `place, collect`; a route of
  ## length greater than one is the same thing, derived instead of written down.
  if source == destination or source.frameIndex < 0 or destination.frameIndex < 0:
    return @[]
  var
    reached = newSeq[bool](FRAMES.len)
    arrival = newSeq[Move](FRAMES.len)
    origin = newSeq[int](FRAMES.len)
    queue = @[source.frameIndex]
  reached[source.frameIndex] = true
  var head = 0
  while head < queue.len:
    let current = queue[head]
    inc head
    for move in moves(FRAMES[current]):
      let next = move.to.frameIndex
      if reached[next]:
        continue
      reached[next] = true
      arrival[next] = move
      origin[next] = current
      if move.to == destination:
        var step = next
        while step != source.frameIndex:
          result.insert(arrival[step], 0)
          step = origin[step]
        return result
      queue.add next
  @[]
