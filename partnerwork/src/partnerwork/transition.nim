## Derive every change of frame from the primitive transition helpers.
##
## The ontology names its helpers `collect`, `drop`, `trace`, `pass`/`place`,
## `cut` and `flick`.  Only five of them change the frame: a `flick` is a `drop`
## led with momentum, and `place` is the workbook's `pass`, so both are recorded
## as manners of the primitive they share rather than as separate states.
##
## Nothing here is a table of moves.  A move exists between two frames exactly
## when the difference between them is one primitive, so the transition relation
## is *classified* rather than listed, and the listing in the workbook becomes
## something to check against rather than the source of truth.
##
## Every primitive is reversible: `collect` undoes `drop`, and `trace`, `pass`
## and `cut` undo themselves.  The relation is therefore symmetric, which is the
## strongest law the module offers for testing.

{.experimental: "strictFuncs".}

import std/[algorithm, options]

import ./frame



#[ Concepts ]#

type
  Helper* {.pure.} = enum ## Name a primitive way one frame becomes another.
    Collect,              ## Form a connection with a free hand.
    Drop,                 ## Break a connection, releasing the hand.
    Trace,                ## Move one connection along the follow, keeping contact.
    Pass,                 ## Hand one connection from one lead hand to the other.
    Cut                   ## Re-route an arm around the arm obstructing it.

  Move* = object ## Hold one primitive change of frame.
    helper*: Helper ## Primitive that carries the change.
    side*: Side     ## Lead hand that acts: the receiver for a pass, the arm that
                    ## ends on top for a cut.
    to*: Frame      ## Frame the couple arrives in.


const HELPER_MANNERS*: array[Helper, string] = [
  Helper.Collect: "collect",
  Helper.Drop: "drop, or flick when led with momentum",
  Helper.Trace: "trace, called slide in the workbook",
  Helper.Pass: "pass, called place when named for its shape",
  Helper.Cut: "cut",
] ## Name each primitive together with the workbook's synonyms for it.


func inverse*(helper: Helper): Helper =
  ## Get the primitive that undoes this one.
  case helper
  of Helper.Collect: Helper.Drop
  of Helper.Drop: Helper.Collect
  of Helper.Trace: Helper.Trace
  of Helper.Pass: Helper.Pass
  of Helper.Cut: Helper.Cut



#[ Classification ]#

func isTraceable*(side: Side; source, destination: Site): bool =
  ## Test whether one lead hand can travel between two places without letting go.
  ##
  ## Contact can only follow the body.  A hand on the follow's torso is already
  ## reaching around one side of them, so it can run down that arm to the hand it
  ## meets there, which is the hand it faces.  There is no path from one hand of
  ## the follow to the other: the gap between them is empty air.
  let pair = [source, destination]
  Site.Torso in pair and parallelSite(side) in pair


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
    if isTraceable(side, a.hold[side].get, b.hold[side].get):
      return some(Helper.Trace)
    return none(Helper)

  # Both hands changed, so the only single action left is a hand-off, and a
  # hand-off needs the receiving hand free: that leaves the one-connection
  # frames.  Handing the torso over means reaching around the partner behind
  # the arm already there, which is two actions and not modelled as one.
  if a.countHolds != 1 or b.countHolds != 1:
    return none(Helper)
  let
    source = if a.hold[Side.Left].isSome: a.hold[Side.Left] else: a.hold[Side.Right]
    destination = if b.hold[Side.Left].isSome: b.hold[Side.Left] else: b.hold[Side.Right]
  if source == destination and source != some(Site.Torso):
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


func moves*(source: Frame; convention = Convention.Physical): seq[Move] =
  ## Get every frame one primitive away, with the primitive that reaches it.
  ##
  ## This is the whole answer to "what can we do from here": a frame absent from
  ## the result is not reachable without an intermediate frame.
  for destination in convention.admitted:
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
    let site = move.to.hold[move.side].get
    result = "collect " & hand & " to the follow's " & followName(site)
    if move.to.hasOverlap:
      result.add ", " & (if move.to.over.get == move.side: "over" else: "under") &
        " the " & leadName(other(move.side)) & " arm"
  of Helper.Drop:
    result = "drop " & hand & " from the follow's " &
      followName(source.hold[move.side].get)
  of Helper.Trace:
    result = "trace " & hand & " from the follow's " &
      followName(source.hold[move.side].get) & " to their " &
      followName(move.to.hold[move.side].get)
  of Helper.Pass:
    result = "pass the follow's " & followName(move.to.hold[move.side].get) &
      " from " & leadName(other(move.side)) & " to " & hand
  of Helper.Cut:
    result = "cut " & hand & " over " & leadName(other(move.side))



#[ Routes ]#

func route*(source, destination: Frame; convention = Convention.Physical): seq[Move] =
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
    for move in moves(FRAMES[current], convention):
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
