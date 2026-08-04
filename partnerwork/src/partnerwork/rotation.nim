## Model the rotation axis of the ontology, which is not finished.
##
## The workbook has twelve turn sheets, one for each combination of who turns
## (lead or follow), which way (left or right) and how far (half, one, or one and
## a half turns), and all twelve are empty.  This module is what the base model
## says about them before any of them is filled in, kept separate so that nothing
## uncertain leaks into `frame.nim` or `transition.nim`.
##
## The one quantity a rotation adds is *twist*: the rotation of the follow's body
## relative to the lead's.  It is one number for the couple rather than one per
## arm, because both bodies are rigid, so both arms see the same relative
## rotation.  Two consequences follow without any measurement:
##
## - a rotation of the whole couple stores no twist, which is why a couple can
##   travel round the floor in closed position all night;
## - the parity of the twist decides the geometry the base model rests on.  At
##   half a turn the follow's back is to the lead, their left hand is now on the
##   lead's left, and every connection that was crossed is parallel.
##
## What needs measurement is how much twist a frame can hold and what the arms
## do while holding it.  The calibration below comes from two sentences: "if
## you're hand to hand you can only do 1 full rotation comfortably", and the two
## filled cells of the workbook's `rotations` sheet.

{.experimental: "strictFuncs".}

import std/options

import ./frame



#[ Concepts ]#

type
  Dancer* {.pure.} = enum ## Name the two roles, which rotate independently.
    Lead, Follow

  Level* {.pure.} = enum ## Name the height a connection is held at.
    Low, High

  Modifier* {.pure.} = enum ## Name what an arm does while it holds twist.
    Wrap, ## Carry the arm across the front of a body.
    Lock  ## Carry the arm behind the back of a body.

  HalfTurns* = int ## Count rotation in half turns, the granularity the workbook uses.

  Turn* = object ## Hold one rotation of the couple, one entry for each dancer.
    turns*: array[Dancer, HalfTurns] ## Half turns, positive to that dancer's right.

  Posture* = object ## Hold a frame together with the rotation stored in it.
    frame*: Frame
    level*: array[Side, Level] ## Height of each connection, where there is one.
    twist*: HalfTurns          ## Follow's rotation less the lead's, in half turns.


const
  CAPACITY_SINGLE* = 2 ## Hold one full turn on one hand-to-hand connection.
  CAPACITY_PAIR* = 1   ## Hold half a turn on two hand-to-hand connections.
  CAPACITY_TORSO* = 0  ## Hold nothing while a hand is on the partner's torso.



#[ Geometry ]#

func isFacing*(twist: HalfTurns): bool = twist mod 2 == 0
  ## Test whether the partners still face each other after a rotation.


func crossedSite*(side: Side; twist: HalfTurns): Site =
  ## Get the follow hand this lead hand reaches only across the midline, after a
  ## rotation.
  ##
  ## This is the whole of the base model's dependence on rotation.  At half a
  ## turn the follow has turned their back, so the hand that was across the
  ## midline is now the near one and every reading of a frame flips with it.
  if isFacing(twist): crossedSite(side) else: parallelSite(side)


func parallelSite*(side: Side; twist: HalfTurns): Site =
  ## Get the follow hand this lead hand reaches without crossing, after a rotation.
  if isFacing(twist): parallelSite(side) else: crossedSite(side)



#[ Capacity ]#

func capacity*(target: Frame): HalfTurns =
  ## Get how much twist a frame can store before the couple must change it.
  ##
  ## An arm around a partner's torso is already wrapped around them, so it gives
  ## no twist away: a follow's turn out of closed position needs the lead's right
  ## hand to leave the back first, which is what the base matrix already says.
  ## A single hand-to-hand connection is the roomiest, because both dancers can
  ## share the turn between their two arms.  A pair binds at half that, which is
  ## why a wrap is led from two hands and a lock from one.
  for side in Side:
    if target.hold[side] == some(Site.Torso):
      return CAPACITY_TORSO
  case target.countHolds
  of 0: high(HalfTurns) # Nothing joins the bodies, so nothing limits the turn.
  of 1: CAPACITY_SINGLE
  else: CAPACITY_PAIR


func modifier*(twist: HalfTurns): Option[Modifier] =
  ## Get what the arms are doing at a given twist.
  ##
  ## The workbook's `rotations` sheet fills two cells, both for `Left to left`
  ## held low: half a turn to the left gives a `wrap`, and a full turn to the
  ## right gives a `lock`.  Read by magnitude alone, one half turn wraps and two
  ## lock, and both cells fit.
  ##
  ## TODO: decide whether the direction of the turn matters as well as its size.
  ## The two cells are also fitted by a rule where turning one way carries the
  ## arm across the front and so wraps, and turning the other way carries it
  ## behind the back and so locks, at either size.  The two rules disagree about
  ## four cells that nobody has filled in: `Left to left` held low, at half and
  ## at one turn, in each direction.  Dancing those four and writing down what
  ## the arm does settles it; until then this module reports the magnitude rule,
  ## which is the one that keeps `wrap` and `lock` as stages of the same motion
  ## rather than as two different motions.
  case abs(twist)
  of 0: none(Modifier)
  of 1: some(Modifier.Wrap)
  else: some(Modifier.Lock)



#[ Turning ]#

func rest*(target: Frame): Posture =
  ## Get the posture of a frame that has not turned, which is where the base
  ## ontology lives.
  Posture(frame: target, level: [Level.Low, Level.Low], twist: 0)


func rotates*(who: Dancer; amount: HalfTurns): Turn =
  ## Form the turn where one dancer rotates and the other holds their facing.
  result.turns[who] = amount


func together*(amount: HalfTurns): Turn =
  ## Form the turn where the couple rotates as one, which stores no twist.
  Turn(turns: [amount, amount])


func turn*(posture: Posture; motion: Turn): Option[Posture] =
  ## Turn the couple, refusing a turn the arms cannot hold.
  ##
  ## The refusal is the point: a turn beyond a frame's capacity is not a turn the
  ## couple can do, it is a turn plus a change of frame, and the change of frame
  ## has to be led.  A turn is taken as one motion rather than as one dancer
  ## after the other, because the couple does not pass through the state where
  ## only one of them has moved.
  let stored = posture.twist + motion.turns[Dancer.Follow] -
    motion.turns[Dancer.Lead]
  if abs(stored) > posture.frame.capacity:
    return none(Posture)
  var turned = posture
  turned.twist = stored
  some(turned)
