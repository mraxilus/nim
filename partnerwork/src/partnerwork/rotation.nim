## Model the rotation axis of the ontology, which is not finished.
##
## The workbook has twelve turn sheets, one for each combination of who turns
## (lead or follow), which way (left or right) and how far (half, one, or one and
## a half turns), and all twelve are empty.  This module is what the hand-to-hand
## model says about them before any of them is filled in, kept separate so that
## nothing uncertain leaks into `frame.nim` or `transition.nim`.
##
## The quantity a rotation adds is *twist*: how far the follow's body has turned
## relative to the lead's.  It is one number for the couple rather than one per
## arm, because both bodies are rigid, so both arms see the same relative
## rotation.  Two consequences follow without any measurement:
##
## - a rotation of the whole couple stores no twist, which is why a couple can
##   travel round the floor all night without unwinding;
## - the parity of the twist decides the geometry the hand-to-hand model rests
##   on.  At half a turn the follow's back is to the lead, their left hand is now
##   on the lead's left, and every connection that was crossed is parallel.
##
## This is also where a hand on the partner's body belongs.  It does not add a
## frame: it takes the turn away, because an arm already around a partner has no
## twist left to give.  And it is what a wound arm ends up on, which is what the
## vocabulary's `wrap` and `lock` name.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ./frame



#[ Concepts ]#

type
  Dancer* {.pure.} = enum ## Name the two roles, which rotate independently.
    Lead, Follow

  Level* {.pure.} = enum ## Name the height an arm is carried at.
    Low,   ## At about the waist.
    High,  ## At about the shoulder.
    Above  ## Over the head, on the axis the couple turns about.

  Way* {.pure.} = enum ## Name which way a dancer turns, seen from above.
    Clockwise,
    Anticlockwise

  About* {.pure.} = enum ## Name what a dancer turns around.
    Axis,  ## Their own, so their facing changes where they stand.
    Orbit  ## The couple's centre of mass, so they travel around it.

  BodySite* {.pure.} = enum ## Name a place on a body an arm rests on or wraps around.
    Waist, Torso, Shoulder, Neck

  Blocker* {.pure.} = enum ## Name what stops an arm carrying any more twist.
    Wrap, ## The arm is carried across the front of a body.
    Lock  ## The arm is carried behind the line of a body.

  HalfTurns* = int ## Count rotation in half turns, the granularity the workbook uses.

  Turn* = object ## Hold one rotation of the couple, one entry for each dancer.
    turns*: array[Dancer, HalfTurns] ## Half turns, positive to that dancer's right.

  Contact* = object ## Hold one lead hand resting on the follow's body.
    side*: Side       ## Lead hand that rests.
    where*: BodySite  ## Place it rests on.

  Posture* = object ## Hold a frame together with the rotation stored in it.
    frame*: Frame
    level*: array[Side, Level]  ## Height each arm is carried at.
    contact*: Option[Contact]   ## Hand resting on the follow's body, which stops a turn.
    twist*: HalfTurns           ## Follow's rotation less the lead's, in half turns.


const
  CAPACITY_SINGLE* = 2 ## Hold one full turn on one hand-to-hand connection.
  CAPACITY_PAIR* = 1   ## Hold half a turn on two hand-to-hand connections.
  CAPACITY_CONTACT* = 0 ## Hold nothing while a hand rests on the partner's body.
  CAPACITY_WRAP_LOW* = 1
    ## Hold half a turn while the arm is wrapped low.  Measured, not derived.
  CAPACITY_ARM* = 2
    ## Hold a full turn while the arm is anywhere else.  Measured for a low
    ## lock; assumed for the two high ones, which is the next thing to dance.
  ABOVE_BLOCKS* = false
    ## Whether an arm over the head blocks a turn.  It does in some cases and
    ## nobody has said which, so the model turns freely there and says here that
    ## it is doing so on no authority.



#[ Geometry ]#

func isFacing*(twist: HalfTurns): bool = twist mod 2 == 0
  ## Test whether the partners still face each other after a rotation.


func crossedSite*(side: Side; twist: HalfTurns): Site =
  ## Get the follow hand this lead hand reaches only across the midline, after a
  ## rotation.
  ##
  ## This is the whole of the hand-to-hand model's dependence on rotation.  At
  ## half a turn the follow has turned their back, so the hand that was across
  ## the midline is now the near one and every reading of a frame flips with it.
  ## The frames do not change; the way they are read does.
  if isFacing(twist): crossedSite(side) else: parallelSite(side)


func parallelSite*(side: Side; twist: HalfTurns): Site =
  ## Get the follow hand this lead hand reaches without crossing, after a rotation.
  if isFacing(twist): parallelSite(side) else: crossedSite(side)



#[ Capacity ]#

func armCapacity*(blocker: Option[Blocker]; level: Level): HalfTurns =
  ## Get how much twist the arm itself can carry, wherever it has ended up.
  ##
  ## Measured on `Left to left`, one hand: a low wrap holds half a turn and
  ## everything else holds a full one.  The arm has to cross the torso to wrap
  ## low, and it runs out of length before the hold does; carried behind the
  ## back, or up at the shoulder or the neck, it has further to go.
  ##
  ## This is the second of two ceilings, and the reason there are two: the first
  ## is a property of what joins the couple, this one of what the arm is doing.
  ## Which of them binds is what makes a wrap a wrap and a lock a lock -- see
  ## `blocker`.
  ##
  ## An arm above the head is on the axis the couple turns about, so it has
  ## nothing to wind round and nothing to run out of.  There is a case in which
  ## it blocks anyway and this does not know it yet, which is why `ABOVE_BLOCKS`
  ## says so out loud rather than being quietly absent.
  if level == Level.Above:
    return high(HalfTurns)
  if blocker == some(Blocker.Wrap) and level == Level.Low:
    CAPACITY_WRAP_LOW
  else:
    CAPACITY_ARM



func capacity*(posture: Posture): HalfTurns =
  ## Get how much twist a posture can store before the couple must change it.
  ##
  ## A hand on the follow's body gives no turn away: it is already around them.
  ## This is what closed position is, and it is why a follow's turn out of it
  ## needs the lead's right hand to leave the back first.  A single hand-to-hand
  ## connection is the roomiest, because both dancers can share the turn between
  ## their two arms.  A pair binds at half that, which is why a wrap is led from
  ## two hands and a lock from one.
  if posture.contact.isSome:
    return CAPACITY_CONTACT
  case posture.frame.countHolds
  of 0: high(HalfTurns) # Nothing joins the bodies, so nothing limits the turn.
  of 1: CAPACITY_SINGLE
  else: CAPACITY_PAIR


func blocker*(twist: HalfTurns): Option[Blocker] =
  ## Get what the arms are doing at a given twist.
  ##
  ## Size decides, not direction: half a turn wraps and a full turn locks,
  ## whichever way it is danced.
  ##
  ## This was fitted to two cells of the `rotations` sheet and is now a
  ## consequence of a measured one.  A low wrap holds half a turn and no more
  ## (`armCapacity`), so an arm carried low that is asked for a full turn cannot
  ## still be wrapped -- it has to have gone behind the back, which is a lock.
  ## The size of the turn decides because the arm runs out at a size.
  ##
  ## Rejected: the two cells were equally well fitted by a rule where the
  ## direction decides -- one way carrying the arm across the front and so
  ## wrapping, the other behind the back and so locking, at either size.  That
  ## rule has nothing to say about why a low wrap should bind tighter than a low
  ## lock, and it makes a wrap and a lock two different motions rather than two
  ## depths of one.  The measurement is what chose between them.
  case abs(twist)
  of 0: none(Blocker)
  of 1: some(Blocker.Wrap)
  else: some(Blocker.Lock)


func blockerOf*(twist: HalfTurns; level: Level): Option[Blocker] =
  ## Get what blocks an arm at a given twist, at the height it is carried.
  ##
  ## Only a low or a high arm is wound round anything: an arm over the head is
  ## on the axis, so there is nothing for it to be across the front of or behind
  ## the line of, and it carries no blocker however far the couple turns.
  if level == Level.Above: none(Blocker) else: blocker(twist)


func armsCapacity*(posture: Posture; twist: HalfTurns): HalfTurns =
  ## Get how much twist the arms of a posture carry between them.
  ##
  ## The tightest arm binds.  A couple is held together by all of its
  ## connections at once, so the first arm to run out is the one that stops the
  ## turn -- and only the arms that are holding count, because a free arm is
  ## carrying nothing and has nothing to run out of.
  ##
  ## With no arm holding at all there is nothing to run out: two people who are
  ## not touching can each face wherever they like.
  if posture.frame.countHolds == 0:
    return high(HalfTurns)
  result = high(HalfTurns)
  for side in Side:
    if posture.frame.hold[side].isSome:
      result = min(result, armCapacity(blockerOf(twist, posture.level[side]),
        posture.level[side]))


func around*(blocker: Blocker; level: Level): Option[BodySite] =
  ## Get the place on the body a wound arm is carried around.
  ##
  ## The workbook asks whether an upper and a lower wrap are separate modifiers.
  ## They are not: the level the arm is already carried at decides where it
  ## lands, so the body site is derived rather than named.  Reading the
  ## vocabulary's own definitions, a low lock is behind the back and a high lock
  ## is at the shoulder of the same arm; a low wrap crosses the torso and a high
  ## wrap goes round the neck.
  ##
  ## Nothing, for an arm over the head: it is on the axis rather than around
  ## anything, which is why it carries no blocker to begin with.
  if level == Level.Above:
    return none(BodySite)
  case blocker
  of Blocker.Wrap:
    case level
    of Level.Low: some(BodySite.Torso)
    of Level.High: some(BodySite.Neck)
    of Level.Above: none(BodySite)
  of Blocker.Lock:
    case level
    of Level.Low: some(BodySite.Waist)
    of Level.High: some(BodySite.Shoulder)
    of Level.Above: none(BodySite)



#[ Turning ]#

func rest*(target: Frame): Posture =
  ## Get the posture of a frame that has not turned, which is where the
  ## hand-to-hand ontology lives.
  Posture(
    frame: target,
    level: [Level.Low, Level.Low],
    contact: none(Contact),
    twist: 0,
  )


func rests*(posture: Posture; side: Side; where: BodySite): Posture =
  ## Rest one lead hand on the follow's body, which takes the turn away.
  result = posture
  result.contact = some(Contact(side: side, where: where))


func rotates*(who: Dancer; amount: HalfTurns): Turn =
  ## Form the turn where one dancer rotates and the other holds their facing.
  result.turns[who] = amount


func together*(amount: HalfTurns): Turn =
  ## Form the turn where the couple rotates as one, which stores no twist.
  Turn(turns: [amount, amount])


func stored*(posture: Posture; motion: Turn): HalfTurns =
  ## Get the twist a turn would leave stored, whether or not it can be.
  ##
  ## A turn is taken as one motion rather than as one dancer after the other,
  ## because the couple does not pass through the state where only one of them
  ## has moved.
  posture.twist + motion.turns[Dancer.Follow] - motion.turns[Dancer.Lead]


func holds*(posture: Posture; twist: HalfTurns): bool =
  ## Test whether a posture can stand at a given twist.
  ##
  ## Two ceilings, and a posture has to be under both: what joins the couple can
  ## only give away so much turn, and the arm can only carry so much wherever it
  ## has wound up.  One definition, so that everything that refuses a turn
  ## refuses it for the same reason.
  ##
  ## On the hold that has been measured neither ceiling is slack: the arm's is
  ## what makes a full turn a lock rather than a wrap, and the hold's is what
  ## refuses one and a half.
  abs(twist) <= posture.capacity and abs(twist) <= posture.armsCapacity(twist)


func turn*(posture: Posture; motion: Turn): Option[Posture] =
  ## Turn the couple, refusing a turn the arms cannot hold.
  ##
  ## The refusal is the point: a turn beyond a posture's capacity is not a turn
  ## the couple can do, it is a turn plus a change of frame, and the change of
  ## frame has to be led.
  let reached = posture.stored(motion)
  if not posture.holds(reached):
    return none(Posture)
  var turned = posture
  turned.twist = reached
  some(turned)


#[ What There Is ]#

const
  MOST_TURN* = 3
    ## Largest turn the workbook's sheets record, in half turns.
    ##
    ## One and a half turns.  Not a claim that nothing larger is dancable, only
    ## that nothing larger is written down, so it is where enumerating stops.
  TURN_WAYS* = [1, -1] ## To the turning dancer's right, then to their left.


func normalised*(posture: Posture): Posture =
  ## Put the arms that are not holding back down.
  ##
  ## The height of a free arm cannot stop a turn, so two postures differing only
  ## in where a free hand is carried are one posture.  Enumerating without this
  ## would count each of them twice and claim more states than there are.
  result = posture
  for side in Side:
    if posture.frame.hold[side].isNone:
      result.level[side] = Level.Low


func postures*(): seq[Posture] =
  ## Get every posture the model derives: a frame, the heights it is held at,
  ## and every twist those two can stand at.
  ##
  ## The hand-to-hand half has `FRAMES`; this is its opposite number, and the
  ## rotation views are built on it the way the frame views are built on that.
  ## A hand resting on the body is left out: it gives the whole turn away, so it
  ## adds no posture that turning can reach.
  for target in FRAMES:
    for left in Level:
      for right in Level:
        let held = normalised(Posture(frame: target, level: [left, right],
          contact: none(Contact), twist: 0))
        if held.level != [left, right]:
          continue
        for twist in -MOST_TURN .. MOST_TURN:
          if not held.holds(twist):
            continue
          var stood = held
          stood.twist = twist
          result.add stood


type
  Refusal* {.pure.} = enum ## Say what stops a turn that cannot be taken.
    Hold, ## What joins the couple cannot give that much turn away.
    Arm   ## The arm cannot carry that much, wherever it has wound up.

  Offer* = object ## Hold one turn out of a posture, taken or refused.
    who*: Dancer            ## Dancer who turns; the other holds their facing.
    amount*: HalfTurns      ## Half turns, positive to that dancer's right.
    to*: Posture            ## Where it lands, or would land if it could.
    refused*: Option[Refusal] ## Why it cannot be taken, where it cannot.


func refusal*(posture: Posture; twist: HalfTurns): Option[Refusal] =
  ## Say which ceiling refuses a twist, if either does.
  ##
  ## The hold is named first where both would refuse, because it is the one a
  ## dancer can do something about: letting a hand go changes the hold, and
  ## nothing changes how far an arm reaches.
  if abs(twist) > posture.capacity:
    some(Refusal.Hold)
  elif abs(twist) > posture.armsCapacity(twist):
    some(Refusal.Arm)
  else:
    none(Refusal)


func turnsOf*(posture: Posture): seq[Offer] =
  ## Get every turn out of a posture, the refused ones included.
  ##
  ## Every turn the workbook has a sheet for: either dancer, either way, by a
  ## half, a whole or one and a half.  Twelve of them, which is twelve sheets --
  ## and half of them land where the other half do, because a turn is stored as
  ## one number for the couple and it does not care which of them moved.
  ##
  ## The refused ones are carried rather than dropped.  A page that listed only
  ## what can be danced would be a menu; what makes it a validator is that it
  ## can say what cannot be danced, and why.
  ##
  ## On axis only.  A dancer can also turn about the couple's centre of mass
  ## rather than their own -- `About.Orbit` -- and how much twist that stores is
  ## not something this model has been told.  Offering an orbit before knowing
  ## that would be the page inventing a move, which is the one thing it is for
  ## not doing.
  for who in Dancer:
    for way in TURN_WAYS:
      for size in 1 .. MOST_TURN:
        let
          amount = size * way
          motion = rotates(who, amount)
          reached = posture.stored(motion)
        var landing = posture
        landing.twist = reached
        result.add Offer(who: who, amount: amount, to: landing,
          refused: posture.refusal(reached))


#[ Naming ]#

const TURN_NAMES* = ["", "half a turn", "one turn", "one and a half turns"]
  ## Name each size of turn as the workbook's sheets name it.


func wayOf*(amount: HalfTurns): Way =
  ## Get which way a turn of this sign goes.
  ##
  ## Clockwise seen from above, which is how the drawings see the couple, and
  ## unlike a dancer's own right and left it means the same thing whichever of
  ## them is turning.
  if amount >= 0: Way.Clockwise else: Way.Anticlockwise


func wayName*(way: Way): string =
  ## Name a way round as the vocabulary names it.
  case way
  of Way.Clockwise: "clockwise"
  of Way.Anticlockwise: "anticlockwise"


func turnName*(amount: HalfTurns): string =
  ## Name a turn by its size and the way it goes.
  if amount == 0:
    return "no turn"
  TURN_NAMES[min(abs(amount), TURN_NAMES.high)] & " " & wayName(wayOf(amount))


func aboutName*(about: About): string =
  ## Name what a dancer turns around, as the vocabulary names it.
  case about
  of About.Axis: "on axis"
  of About.Orbit: "on orbit"


func levelName*(level: Level): string = ($level).toLowerAscii
  ## Name the height an arm is carried at.


func armName*(posture: Posture): string =
  ## Name what the arms are doing, where they are doing anything.
  ##
  ## The height comes first because it is the thing that decides how far the arm
  ## can go: a low wrap and a high wrap are one blocker at two heights, and it
  ## is the height that says which of them runs out first.
  let what = blockerOf(posture.twist, posture.level[Side.Left])
  if what.isNone:
    return ""
  var heights: seq[string] = @[]
  for side in Side:
    if posture.frame.hold[side].isSome and
        levelName(posture.level[side]) notin heights:
      heights.add levelName(posture.level[side])
  (if heights.len == 1: heights[0] & " " else: "") &
    ($what.get).toLowerAscii


func describe*(posture: Posture): string =
  ## Name a posture: the frame it is held in, and what turning has done to it.
  if posture.twist == 0:
    return posture.frame.describe
  result = posture.frame.describe & ", " & turnName(posture.twist)
  let arms = posture.armName
  if arms.len > 0:
    result.add ", " & arms


func key*(posture: Posture): string =
  ## Form an identifier for a posture, for a page to name one by.
  result = posture.frame.key & ":"
  for side in Side:
    result.add(if posture.level[side] == Level.High: "H" else: "L")
  result.add ":" & $posture.twist


func fromPostureKey*(key: string): Option[Posture] =
  ## Decode a posture identifier, rejecting anything the model does not derive.
  ##
  ## Rejecting is the point, as it is for a frame: a posture the model does not
  ## stand at cannot be arrived at by asking for it in a link.
  let parts = key.split(':')
  if parts.len != 3 or parts[1].len != 2:
    return none(Posture)
  let target = fromKey(parts[0])
  if target.isNone:
    return none(Posture)
  var stood = target.get.rest
  for index, side in [Side.Left, Side.Right]:
    stood.level[side] = if parts[1][index] == 'H': Level.High else: Level.Low
  var twist: int
  try:
    twist = parseInt(parts[2])
  except ValueError:
    return none(Posture)
  stood = normalised(stood)
  if not stood.holds(twist):
    return none(Posture)
  stood.twist = twist
  some(stood)
