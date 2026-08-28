## Hold the body sim to what bodies and rope actually do.
##
## Every law here is about two cylinders and a piece of string.  Nothing in
## this file names a frame, a move, a hold or a hand of a *dancer*, and
## nothing imports the ontology -- which is the point of the module and is
## checkable at a glance from the single import below.  What the sim says
## about the notation is a question for later and for somewhere else.
##
## The laws that matter most are the ones the sim's predecessor could not
## have passed: that turning a body winds the rope onto it, that the winding
## has a length *and a place*, and that turning back gives the rope back.

{.experimental: "strictFuncs".}

import std/[math, options, unittest]

import ./rope


const
  APART = 0.34          ## A stance with the rims a centimetre or two clear.
  LOW = HUMAN.shoulder  ## Hands carried where they hang.


func oneLink(apart: float; a, b: Arm; height = LOW): State =
  ## Stand two bodies facing, joined by one connection.
  result = facing(HUMAN, apart)
  result.links = @[Link(ends: [(Body.One, a), (Body.Two, b)], height: height)]


suite "the rig":
  test "a body is as wide as whatever part of it the rope passes":
    # The whole of what carrying a connection over someone's head is: at a
    # height above the crown there is nothing left to go round.
    check girth(HUMAN, 0.0) == HUMAN.torso
    check girth(HUMAN, HUMAN.shoulder) == HUMAN.torso
    check girth(HUMAN, (HUMAN.shoulder + HUMAN.crown) / 2) == HUMAN.head
    check girth(HUMAN, HUMAN.crown + 0.01) == 0.0

  test "two bodies cannot stand closer than their rims":
    check touching(HUMAN) == 2.0 * HUMAN.torso

  test "a hand is a quarter turn off the way its body faces":
    # Every consequence of two people facing one another comes out of this
    # one line, so it is worth pinning: standing face to face, one body's
    # left hand is across from the other's right.
    let s = facing(HUMAN, APART)
    check abs(anchor(s, (Body.One, Arm.Left)).x + HUMAN.torso) < 1e-12
    check abs(anchor(s, (Body.Two, Arm.Right)).x + HUMAN.torso) < 1e-12
    check abs(anchor(s, (Body.One, Arm.Right)).x - HUMAN.torso) < 1e-12
    check abs(anchor(s, (Body.Two, Arm.Left)).x - HUMAN.torso) < 1e-12


suite "a rope at rest":
  test "a rope between facing shoulders runs straight, and is the gap long":
    let s = oneLink(APART, Arm.Left, Arm.Right)
    let laid = lay(s, s.links[0]).get
    check laid.hugs == 0
    check abs(laid.span - APART) < 1e-12
    check abs(laid.length - APART) < 1e-12

  test "a rope that would run through a chest bends around it instead":
    # Joining two hands on the same side means the straight way passes
    # through both bodies, so there is no straight way and the taut rope
    # hugs what is in the road.  Nothing tells it to; the winding it is
    # carrying is what it caught while the bodies turned into that hold.
    let s = turned(oneLink(APART, Arm.Left, Arm.Right), Body.Two, PI / 2)
    let laid = lay(s, s.links[0]).get
    check laid.hugs > 0
    check clearance(s, s.links[0], laid) > -1e-9

  test "nothing passes through a body at any turn of one":
    for step in 0 .. 20:
      let s = turned(oneLink(APART, Arm.Left, Arm.Right), Body.Two,
        PI * float(step) / 10.0)
      let laid = lay(s, s.links[0])
      if laid.isSome:
        check clearance(s, s.links[0], laid.get) > -1e-6

  test "raising the joined hands costs rope, and costs it as a tent":
    # The hands ride at the middle of the rope, so lifting them is a climb up
    # from one shoulder and down to the other.
    let
      flat = oneLink(APART, Arm.Left, Arm.Right)
      high = oneLink(APART, Arm.Left, Arm.Right, LOW + 0.2)
      a = lay(flat, flat.links[0]).get
      b = lay(high, high.links[0]).get
    check abs(a.span - b.span) < 1e-12
    check b.length > a.length
    check abs(b.length - sqrt(a.span * a.span + 4.0 * 0.2 * 0.2)) < 1e-12


suite "turning winds the rope":
  test "a turn puts the rope on the body, and the rope stays on it":
    # The law the sim exists for, and the one its predecessor could not state:
    # after a turn the rope is somewhere it was not, and it is longer for it.
    let
      base = oneLink(APART, Arm.Left, Arm.Right)
      rest = lay(base, base.links[0]).get
      spun = turned(base, Body.Two, PI)
      after = lay(spun, spun.links[0]).get
    check after.hugs > rest.hugs
    check after.span > rest.span + 0.1

  test "a whole turn costs the girth it wound onto, and no more":
    # The price the old model assumed, now falling out: what a turn adds is
    # the arc it laid on the rim, which is the radius times the angle.
    let base = oneLink(APART, Arm.Left, Arm.Right)
    var last = -1.0
    for turn in 1 .. 3:
      let
        one = turned(base, Body.Two, PI * float(turn))
        two = turned(base, Body.Two, PI * float(turn + 1))
        a = lay(one, one.links[0])
        b = lay(two, two.links[0])
      if a.isNone or b.isNone:
        continue
      let grew = b.get.span - a.get.span
      # Half a turn of the follow lays half that body's circumference on.
      check abs(grew - PI * HUMAN.torso) < 5e-3
      if last > 0.0:
        check abs(grew - last) < 5e-3
      last = grew

  test "the winding is counted, so more turning is always more rope":
    # A shortest path has no memory: at a whole turn it is the path it was at
    # rest, and at two whole turns it is that path again.  This is the
    # regression test against every model that searches for the rope instead
    # of carrying it -- the span has to keep climbing, turn after turn.
    let base = oneLink(APART, Arm.Left, Arm.Right)
    var was = 0.0
    for half in 0 .. 6:
      let s = turned(base, Body.Two, PI * float(half))
      let laid = lay(s, s.links[0]).get
      if half >= 2:
        # Once the rope has caught, every further half turn lays on more.
        check laid.span > was + 0.4
      was = laid.span
    # And past a whole lap of the rim, the count has to have picked it up,
    # because the geometry alone can only ever see the part-lap.
    let far = turned(base, Body.Two, 3.0 * PI)
    var laps = 0
    for wind in far.links[0].winds:
      laps += wind.turns
    check laps >= 1

  test "turning back gives the rope back, to the last decimal":
    # Only the whole turns are remembered; where the rope leaves a rim is
    # worked out afresh every step.  So a turn out and back does not drift,
    # and the same angle always gives the same state however it was reached.
    let
      base = oneLink(APART, Arm.Left, Arm.Right)
      rest = lay(base, base.links[0]).get
      there = turned(base, Body.Two, PI)
      back = turned(there, Body.Two, -PI)
      home = lay(back, back.links[0]).get
    check abs(home.span - rest.span) < 1e-9
    check back.links[0].winds.len == base.links[0].winds.len

  test "the same angle gives the same state, whatever the step":
    # The winding underneath is path-dependent and has to be.  Replaying the
    # whole turn from rest every time is what keeps that from reaching the
    # surface, and this is what says it worked: three step sizes, one answer.
    var seen: seq[float]
    for step in [0.05, 0.02, 0.01]:
      let s = turned(oneLink(APART, Arm.Left, Arm.Right), Body.Two, PI, step)
      seen.add lay(s, s.links[0]).get.span
    for span in seen:
      check abs(span - seen[0]) < 1e-9


suite "what the rope will not do":
  test "there is a turn it runs out at, and it is swept, not assumed":
    # Nothing in the module holds this number.  It is found by turning until
    # a connection first refuses, so it is a consequence of the arm and the
    # girth rather than a constant fitted to them.
    let base = oneLink(APART, Arm.Left, Arm.Right)
    let limit = windLimit(base, Body.Two)
    check limit > 0.0
    check limit < 4.0 * PI
    check holds(turned(base, Body.Two, limit - 0.05))
    check not holds(turned(base, Body.Two, limit + 0.05))

  test "a longer arm reaches further round, and a wider body less far":
    # The limit is a fact about the measurements, not about the model.  If
    # these ever stop moving together, the sweep has stopped depending on
    # the geometry and is reporting something it was told.
    var longer = HUMAN
    longer.arm = HUMAN.arm + 0.1
    var thicker = HUMAN
    thicker.torso = HUMAN.torso + 0.03
    func limitFor(rig: Rig): float =
      var s = facing(rig, APART)
      s.links = @[Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Right)],
                       height: rig.shoulder)]
      windLimit(s, Body.Two)
    check limitFor(longer) > limitFor(HUMAN)
    check limitFor(thicker) < limitFor(HUMAN)

  test "standing further apart spends rope that turning then cannot have":
    let near = windLimit(oneLink(0.34, Arm.Left, Arm.Right), Body.Two)
    let far = windLimit(oneLink(0.80, Arm.Left, Arm.Right), Body.Two)
    check far < near


suite "two ropes":
  test "where two ropes cross, the higher one is over":
    # Over and under is not a field anybody has to keep: two ropes that meet
    # in plan are one above the other in fact, and which is which is read off
    # the heights.
    var s = facing(HUMAN, APART)
    s.links = @[
      Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Left)], height: LOW),
      Link(ends: [(Body.One, Arm.Right), (Body.Two, Arm.Right)],
           height: LOW + 0.25)]
    let
      a = lay(s, s.links[0])
      b = lay(s, s.links[1])
    check a.isSome and b.isSome
    let met = meetings(s, s.links[0], a.get, s.links[1], b.get)
    check met.len >= 1
    for one in met:
      check overOf(HUMAN, one) == some(1)

  test "two ropes at one height leave the question open":
    # Within an arm's thickness they are touching, and which is on top is
    # something the dancers settle.  The model hands the question back
    # rather than inventing an answer to it.
    var s = facing(HUMAN, APART)
    s.links = @[
      Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Left)], height: LOW),
      Link(ends: [(Body.One, Arm.Right), (Body.Two, Arm.Right)], height: LOW)]
    let
      a = lay(s, s.links[0]).get
      b = lay(s, s.links[1]).get
    for one in meetings(s, s.links[0], a, s.links[1], b):
      check overOf(HUMAN, one).isNone

  test "ropes joining opposite hands never meet at all":
    var s = facing(HUMAN, APART)
    s.links = @[
      Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Right)], height: LOW),
      Link(ends: [(Body.One, Arm.Right), (Body.Two, Arm.Left)], height: LOW)]
    let
      a = lay(s, s.links[0]).get
      b = lay(s, s.links[1]).get
    check meetings(s, s.links[0], a, s.links[1], b).len == 0
