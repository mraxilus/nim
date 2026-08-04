## Model the frame two dancers hold, and name it in the vocabulary of the dance.
##
## A *frame* is everything the two bodies hold at one instant: which hand of the
## lead holds which hand of the follow, and how the arms lie where they overlap.
## It is the state of the ontology.  Every non-rotating move is a change of
## frame, and every change is derived from three physical facts:
##
## - a hand holds at most one hand, and a hand of the follow is held by at most
##   one hand of the lead;
## - the partners face each other, so a lead hand reaches the *opposite* hand of
##   the follow without crossing the midline between the bodies, and the
##   *same-named* hand only by crossing it;
## - when both connections cross, the forearms overlap, so one arm lies over the
##   other and which one is part of the state, not decoration.
##
## The third fact is why `Left-to-left and Right-to-right` has an over/under
## distinction and `Left-to-right and Right-to-left` does not: only the first
## pair crosses.
##
## Only hands connect here.  A hand resting on a partner's body is real and is
## deliberately absent: nothing in the hand-to-hand ontology depends on it, and
## where it does matter is in stopping a turn, so it belongs with the rotation
## axis in `rotation.nim`.

{.experimental: "strictFuncs".}

import std/options



#[ Concepts ]#

type
  Side* {.pure.} = enum ## Name a side of a body, and so one hand of the lead.
    Left, Right

  Site* {.pure.} = enum ## Name a hand of the follow that one lead hand can hold.
    LeftHand, RightHand

  Frame* = object ## Hold every connection between the two bodies at one instant.
    hold*: array[Side, Option[Site]] ## Hand each lead hand holds, where it holds one.
    over*: Option[Side]              ## Lead arm lying over the other, where they overlap.


const SITE_OPTIONS = [
  none(Site),
  some(Site.LeftHand),
  some(Site.RightHand),
]


const OVER_OPTIONS = [
  none(Side),
  some(Side.Left),
  some(Side.Right),
]



#[ Geometry Facing Partners ]#

func parallelSite*(side: Side): Site =
  ## Get the follow hand this lead hand reaches without crossing the midline.
  case side
  of Side.Left: Site.RightHand
  of Side.Right: Site.LeftHand


func crossedSite*(side: Side): Site =
  ## Get the follow hand this lead hand reaches only by crossing the midline.
  case side
  of Side.Left: Site.LeftHand
  of Side.Right: Site.RightHand


func isCrossed*(side: Side; site: Site): bool = site == crossedSite(side)
  ## Test whether a connection crosses the midline between the bodies.


func other*(side: Side): Side =
  ## Get the opposite side of the same body.
  case side
  of Side.Left: Side.Right
  of Side.Right: Side.Left


func hasOverlap*(frame: Frame): bool =
  ## Test whether both forearms cross the midline and so lie on top of each other.
  frame.hold[Side.Left] == some(crossedSite(Side.Left)) and
    frame.hold[Side.Right] == some(crossedSite(Side.Right))



#[ Laws ]#

func countHolds*(frame: Frame): int =
  ## Count the connections a frame carries.
  for side in Side:
    if frame.hold[side].isSome:
      inc result


func isValid*(frame: Frame): bool =
  ## Test the two laws every frame obeys.
  ##
  ## No hand is shared.  One hand of the follow cannot be held by both hands of
  ## the lead, and the ontology leaves out `Left-to-all` for the mirrored reason:
  ## a hand joined to two things is an ambiguous lead, and it is what makes the
  ## state space finite.  The law is what sends a hand-off through the open frame
  ## rather than through a moment where two hands hold one.
  ##
  ## An arm order is recorded exactly where the forearms overlap, so two frames
  ## that a dancer cannot tell apart cannot be different values.
  if frame.hold[Side.Left].isSome and frame.hold[Side.Left] == frame.hold[Side.Right]:
    return false
  frame.over.isSome == frame.hasOverlap


func reflect*(frame: Frame): Frame =
  ## Mirror a frame through the plane between the bodies, swapping left and right.
  ##
  ## Reflection is a symmetry of the physics, so the whole ontology is invariant
  ## under it.  Anywhere it is not, the asymmetry has come from an idiom rather
  ## than from the bodies.
  for side in Side:
    result.hold[other(side)] =
      if frame.hold[side].isNone:
        none(Site)
      else:
        case frame.hold[side].get
        of Site.LeftHand: some(Site.RightHand)
        of Site.RightHand: some(Site.LeftHand)
  result.over =
    if frame.over.isNone: none(Side) else: some(other(frame.over.get))



#[ Enumeration ]#

func constructFrames(): seq[Frame] {.compileTime.} =
  ## Enumerate every valid frame, ordered by the lead's left hand then right.
  for left in SITE_OPTIONS:
    for right in SITE_OPTIONS:
      for over in OVER_OPTIONS:
        var frame = Frame(over: over)
        frame.hold[Side.Left] = left
        frame.hold[Side.Right] = right
        if frame.isValid:
          result.add frame


const FRAMES* = constructFrames()
  ## Hold every frame two facing humanoid bodies can take hand to hand.


func frameIndex*(frame: Frame): int =
  ## Get the position of a frame in `FRAMES`, or -1 when it is not valid.
  for index, candidate in FRAMES:
    if candidate == frame:
      return index
  -1



#[ Naming ]#

func leadName*(side: Side): string =
  ## Name a hand of the lead, capitalised as the ontology writes it.
  case side
  of Side.Left: "Left"
  of Side.Right: "Right"


func followName*(site: Site): string =
  ## Name a hand of the follow, in lower case as the ontology writes it.
  case site
  of Site.LeftHand: "left"
  of Site.RightHand: "right"


func describeConnection*(side: Side; site: Site; joiner = "-to-"): string =
  ## Name one connection, as `Left-to-left` or `Left to left`.
  leadName(side) & joiner & followName(site)


func describe*(frame: Frame): string =
  ## Name a frame in the vocabulary of the ontology.
  case frame.countHolds
  of 0:
    "open"
  of 1:
    let side = if frame.hold[Side.Left].isSome: Side.Left else: Side.Right
    describeConnection(side, frame.hold[side].get, " to ")
  else:
    let first = if frame.over.isSome: frame.over.get else: Side.Left
    let joiner = if frame.over.isSome: " over " else: " and "
    describeConnection(first, frame.hold[first].get) & joiner &
      describeConnection(other(first), frame.hold[other(first)].get)


func position*(frame: Frame): string =
  ## Name the frame position: which hands hold what, without the order of the arms.
  ##
  ## The workbook asks whether the two crossing orders are one position or two.
  ## They are one position and two states.  No couple can pass between them
  ## without a `cut`, so a machine that merged them would offer a move the arms
  ## forbid; a naming scheme that separated them would report a new position
  ## every time an arm changed height.  Keeping both readings costs one function.
  var plain = frame
  plain.over = none(Side)
  plain.describe


func key*(frame: Frame): string =
  ## Encode a frame as a short stable identifier for storage and markup.
  for side in Side:
    result.add(
      if frame.hold[side].isNone:
        '-'
      else:
        case frame.hold[side].get
        of Site.LeftHand: 'l'
        of Site.RightHand: 'r'
    )
  result.add(
    if frame.over.isNone: '.'
    elif frame.over.get == Side.Left: 'L'
    else: 'R'
  )


func slug*(frame: Frame): string =
  ## Form a file-safe name for a frame, from the name it is described by.
  for character in frame.describe:
    if character in {'a'..'z', '0'..'9'}:
      result.add character
    elif character in {'A'..'Z'}:
      result.add chr(ord(character) + 32)
    elif result.len > 0 and result[^1] != '-':
      result.add '-'


func fromKey*(key: string): Option[Frame] =
  ## Decode a frame identifier, rejecting anything that is not a valid frame.
  if key.len != 3:
    return none(Frame)
  var frame = Frame()
  for index, side in [Side.Left, Side.Right]:
    frame.hold[side] =
      case key[index]
      of '-': none(Site)
      of 'l': some(Site.LeftHand)
      of 'r': some(Site.RightHand)
      else: return none(Frame)
  frame.over =
    case key[2]
    of '.': none(Side)
    of 'L': some(Side.Left)
    of 'R': some(Side.Right)
    else: return none(Frame)
  if frame.isValid: some(frame) else: none(Frame)
