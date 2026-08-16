## Draw each of the app's frames, through the marks the workbench settled.
##
##   This is the one place the two vocabularies meet.  The model says `Side`
##     and `Site` -- a hand of the lead, a hand of the follow, told apart by
##     their types -- and the drawing says `Arm` for either, told apart by
##     which dancer is holding it.  Translating is the whole of this module.
##   It reaches the model through `../frame` and **never** through
##     `../rotation`, which is not an oversight: rotation names a `Dancer`, a
##     `Level` and a `Way` of its own, and its `Way` is clockwise against
##     anticlockwise where the drawing's is lock against wrap.  A module that
##     imported both would have to say which it meant at every use, and would
##     eventually say the wrong one.  So this takes a plain `facing: bool` and
##     lets `diagram` do the arithmetic that needs rotation's words.
##   Every scene is built **at compile time**.  Nothing here has a side
##     effect, so the whole chain -- settling the hands, routing each
##     connection round the bodies, breaking the one that passes underneath
##     -- runs in the compiler and what ships is sixteen strings.
##     Which is worth more than the speed: the app regenerates its whole page
##       on every interaction, and a router that ran per draw would run
##       thousands of times a second for an answer that never changes.  It
##       also keeps the routing out of the browser bundle entirely, and it
##       formats every coordinate once, in one backend, so the JS build
##       cannot round a last digit differently from the C one.
##     Cost of building them all: every frame is drawn whether the session
##       ever shows it or not.  Accepted -- there are sixteen, and the whole
##       table is smaller than the code that would make one.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ../frame
import ./[figure, pose, terms]


const HOW_MANY = FRAMES.len * 2
  ## Every frame, facing and turned: the whole of what a picture can say.
  ##   The follow's facing is the only rotation a frame picture carries, and
  ##     only its parity, so half a turn and a turn and a half draw alike.


func armOf(side: Side): Arm =
  ## Read a hand of the lead as a side of a body.
  case side
  of Side.Left: Arm.L
  of Side.Right: Arm.R

func armOf(site: Site): Arm =
  ## Read a hand of the follow the same way.
  ##   The two are separate types in the model so that nothing can hold one
  ##     where it means the other; here they land on the one word, because a
  ##     drawing puts them on the same two sides of two bodies.
  case site
  of Site.LeftHand: Arm.L
  of Site.RightHand: Arm.R


func holdsOf(target: Frame): Holds =
  ## Say what each of the lead's arms holds, as the drawing takes it.
  for side in Side:
    if target.hold[side].isSome:
      result[armOf(side)] = some armOf(target.hold[side].get)


func poseFor(facing: bool): Pose =
  ## Stand the couple up: the lead facing up the page, the follow facing them
  ## or facing away.
  ##   Canonicalised like every other pose, though at rest it changes nothing,
  ##     because that is what makes two poses of the same configuration the
  ##     same picture and this should not be the one place it is skipped.
  canonicalise(spinAbout(rest(), Dancer.Follow, if facing: 0.0 else: 180.0))


func sceneOf*(target: Frame; facing: bool): string =
  ## Draw one frame: two bodies, their hands, and what joins them.
  ##   No level is said, because a `Frame` does not carry one -- levels live
  ##     in `rotation.Posture` and nothing hands them here yet.  So every
  ##     hand draws hollow, which is what an unsaid level looks like, and a
  ##     free hand is the same outline at half strength.  What is held is
  ##     said by the connection running out of it.
  ##   No captions: this picture is drawn as small as a node on a map, where
  ##     a word beside a hand is a smudge.  Shape says whose hand it is and
  ##     colour says which side, and both survive any size.
  partsOf(poseFor(facing), holdsOf(target), captions = false,
          over = (if target.over.isSome: some armOf(target.over.get)
                  else: none(Arm))).join("")


func buildScenes(): array[HOW_MANY, string] =
  ## Draw every frame the model has, both ways round, once and for all.
  for i, target in FRAMES:
    for k, facing in [true, false]:
      result[i * 2 + k] = sceneOf(target, facing)


const SCENES* = buildScenes()
  ## Every frame picture, drawn in the compiler and shipped as text.


func sceneFor*(target: Frame; facing: bool): string =
  ## Get the picture of this frame, seen with the follow facing or turned.
  ##   An invalid frame has no picture rather than a blank one: it is not a
  ##     state, so there is nothing to draw and nothing to make up.
  let at = frameIndex(target)
  if at.isNone:
    return ""
  SCENES[at.get * 2 + (if facing: 0 else: 1)]
