## Derive every change of frame from the primitive transition helpers.
##
## The ontology names its helpers `collect`, `drop`, `trace`, `pass`/`place`,
## `cut` and `flick`.  Four of them change a hand-to-hand frame: a `flick` is a
## `drop` led with momentum, `place` is the workbook's `pass`, and a `trace`
## slides a hand along the partner's body, which needs a place on the body to
## slide to and so waits for the rotation axis.
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
    Drop,                 ## Break a connection, releasing the hand.
    Pass,                 ## Hand one connection from one lead hand to the other.
    Cut                   ## Re-route an arm around the arm obstructing it.

  Move* = object ## Hold one primitive change of frame.
    helper*: Helper ## Primitive that carries the change.
    side*: Side     ## Lead hand that acts: the receiver for a pass, the arm that
                    ## ends on top for a cut.
    to*: Frame      ## Frame the couple arrives in.


const HELPER_CHANGES*: array[Helper, string] = [
  Helper.Collect: "a free hand takes a hand",
  Helper.Drop: "a held hand is released",
  Helper.Pass: "a hand of the follow changes which lead hand holds it",
  Helper.Cut: "an arm re-routes around the arm obstructing it",
] ## Say what each primitive changes about the frame.


const HELPER_SYNONYMS*: array[Helper, string] = [
  Helper.Collect: "",
  Helper.Drop: "flick when led with momentum",
  Helper.Pass: "place when named for its shape",
  Helper.Cut: "",
] ## Give the workbook's other word for a primitive, where it has one.


const HELPER_MARKS*: array[Helper, char] = [
  Helper.Collect: 'c',
  Helper.Drop: 'd',
  Helper.Pass: 'p',
  Helper.Cut: 'x',
] ## Abbreviate each primitive to the one letter a matrix cell has room for.
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
  of Helper.Pass: Helper.Pass
  of Helper.Cut: Helper.Cut



#[ Classification ]#

func classify*(a, b: Frame): Option[Helper] =
  ## Get the primitive taking one frame to another, where a single one does.
  if a == b or not a.isValid or not b.isValid:
    return none(Helper)
  let
    moved_left = a.hold[Side.Left] != b.hold[Side.Left]
    moved_right = a.hold[Side.Right] != b.hold[Side.Right]
  if not moved_left and not moved_right:
    return some(Helper.Cut) # Same connections, so only the arm order can differ.
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

  # Both hands changed, so the only single action left is a hand-off, and a
  # hand-off needs the receiving hand free: that leaves the one-connection frames.
  if a.countHolds != 1 or b.countHolds != 1:
    return none(Helper)
  let
    source = if a.hold[Side.Left].isSome: a.hold[Side.Left] else: a.hold[Side.Right]
    destination = if b.hold[Side.Left].isSome: b.hold[Side.Left] else: b.hold[Side.Right]
  if source == destination:
    return some(Helper.Pass)
  none(Helper)


func actingSide*(a, b: Frame; helper: Helper): Side =
  ## Get the lead hand that carries a change of frame.
  case helper
  of Helper.Cut:
    b.over.get
  of Helper.Pass:
    if b.hold[Side.Left].isSome: Side.Left else: Side.Right
  else:
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
  ## Say a move the way a teacher would call it.
  let hand = leadName(move.side)
  case move.helper
  of Helper.Collect:
    result = "collect " & hand & " to the follow's " &
      followName(move.to.hold[move.side].get)
    if move.to.hasOverlap:
      result.add ", " & (if move.to.over.get == move.side: "over" else: "under") &
        " the " & leadName(other(move.side)) & " arm"
  of Helper.Drop:
    result = "drop " & hand & " from the follow's " &
      followName(source.hold[move.side].get)
  of Helper.Pass:
    result = "pass the follow's " & followName(move.to.hold[move.side].get) &
      " from " & leadName(other(move.side)) & " to " & hand
  of Helper.Cut:
    result = "cut " & hand & " over " & leadName(other(move.side))



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
