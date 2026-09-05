## Two bodies standing somewhere and facing some way, and where their
## shoulders are.
##
##   A body is a rig's stack of cylinders on a vertical axis, so all it has of
##     its own is a plan position and a facing.  The facing accumulates: two
##     whole turns are not no turns to anyone counting them, and the couple's
##     twist is read off the difference.
##   The sim has its own `Arm` and `Body` on purpose: the ontology next door
##     has enums near these in meaning and this directory shares nothing with
##     it, so that what the sim says is evidence rather than an echo.

{.experimental: "strictFuncs".}

import std/math

import ./[rig, vec]


type
  Arm* {.pure.} = enum ## One of a body's two arms, from its own point of view.
    Left, Right

  Body* {.pure.} = enum ## One of the two bodies.
    One, Two

  Hand* = tuple[body: Body, arm: Arm] ## Names one of the four hands.

  Stance* = object ## Where one body stands and which way it is turned.
    centre*: tuple[x, y: float] ## Plan position of its axis, metres.
    facing*: float ## Radians anticlockwise from the x axis, laps and all.

  Axes* = object ## A body's own directions, in world terms.
    origin*: Vec ## The axis at floor level.
    right*, fore*: Vec ## Unit, horizontal.  Up is up.


func facing*(rig: Rig; apart: float): array[Body, Stance] =
  ## Stand the two face to face, `apart` metres axis to axis: One at the
  ## origin facing +y, Two along +y facing back.
  [Stance(centre: (0.0, 0.0), facing: PI / 2.0),
   Stance(centre: (0.0, apart), facing: -PI / 2.0)]

func axesOf*(st: Stance): Axes =
  ## The body's own right and forward, in the world.
  let
    c = cos(st.facing)
    s = sin(st.facing)
  Axes(origin: (st.centre.x, st.centre.y, 0.0),
       right: (s, -c, 0.0), fore: (c, s, 0.0))

func toBody*(ax: Axes; p: Vec): Vec =
  ## A world point in the body's own terms: x to its right, y forward, z up.
  let d = p - ax.origin
  (dot(d, ax.right), dot(d, ax.fore), d.z)

func toWorld*(ax: Axes; p: Vec): Vec =
  ## The body's own terms back in the world.
  ax.origin + ax.right * p.x + ax.fore * p.y + (0.0, 0.0, p.z)

func mirrored*(p: Vec): Vec = (-p.x, p.y, p.z)
  ## The body's own terms seen in a mirror: the left arm is the right arm here.

func side*(arm: Arm): float = (if arm == Arm.Right: 1.0 else: -1.0)
  ## Which way along the body's right an arm's shoulder lies.

func shoulder*(rig: Rig; st: Stance; arm: Arm): Vec =
  ## The joint's centre in the world.
  toWorld(axesOf(st), (side(arm) * rig.shoulderOut, 0.0, rig.shoulderUp))

func twist*(st: array[Body, Stance]): float =
  ## How far Two has turned relative to One, radians, from face to face.
  st[Body.Two].facing - st[Body.One].facing + PI

func turned*(st: array[Body, Stance]; who: Body; turns: float): array[Body, Stance] =
  ## The stances with one body turned on its spot by `turns` whole turns,
  ## anticlockwise seen from above.
  result = st
  result[who].facing = result[who].facing + turns * 2.0 * PI

func lifted*(p: Vec; dz: float): Vec = (p.x, p.y, p.z + dz)
