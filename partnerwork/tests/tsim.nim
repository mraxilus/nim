## Test the physical rig against the ontology it referees.
##
## The names and drawings are shorthand for two bodies with arms of a length;
## these laws hold the shorthand to the bodies.  Everything here is asked of
## the human-proportioned rig: a claim that fails on it is a claim the
## vocabulary should not be making.

{.experimental: "strictFuncs".}

import std/[math, options, unittest]

import ../src/partnerwork


suite "the rig":
  test "every frame can actually be held at arm's length":
    # The first duty of the notation: a frame it names must be a frame two
    # real bodies can stand in, with rope to spare for dancing it.
    for frame in FRAMES:
      let couple = atRest(HUMAN, frame, HUMAN.apart)
      check feasible(HUMAN, couple)
      for held in couple.ropes:
        check slack(HUMAN, HUMAN.apart, held) > 0.05

  test "a parallel connection runs straight and a crossed one bends round both":
    # The drawings draw exactly this, and here it stops being taste: the
    # straight line of a crossed connection would pass through both chests,
    # so its taut lie hugs both rims and is strictly longer.
    for side in Side:
      for site in Site:
        let
          laid = lie(HUMAN, HUMAN.apart, side, site)
          chord = dist(leadShoulder(HUMAN, side),
            followShoulder(HUMAN, HUMAN.apart, site))
        if isCrossed(side, site):
          check laid.bends == 2
          check laid.length > chord + 1e-6
        else:
          check laid.bends == 0
          check abs(laid.length - chord) < 1e-9

  test "a rope crosses the midline exactly when its name says crossed":
    # `isCrossed` is the vocabulary's claim, made from names alone; the trace
    # is where the rope actually goes.  The mirror of facing partners is a
    # physical fact before it is a naming convention.
    for side in Side:
      for site in Site:
        check crossesMidline(lie(HUMAN, HUMAN.apart, side, site)) ==
          isCrossed(side, site)

  test "two crossed ropes must decide an over, and parallel ones never meet":
    # `Frame.over` exists exactly where the physics forces a decision: where
    # two ropes cross on the plan, one must lie above the other.  Where they
    # never meet there is nothing to decide, and the model refuses the field.
    for frame in FRAMES:
      let couple = atRest(HUMAN, frame, HUMAN.apart)
      if couple.ropes.len < 2:
        continue
      let met = crossings(
        lie(HUMAN, HUMAN.apart, couple.ropes[0].side, couple.ropes[0].site),
        lie(HUMAN, HUMAN.apart, couple.ropes[1].side, couple.ropes[1].site))
      check (met == 1) == frame.hasOverlap
      check (met == 1) == frame.over.isSome
      check met <= 1

  test "a rope never passes through a body":
    # The whole point of having the bodies in the model.  A lie's trace never
    # comes nearer a centre than the torso's own radius, at any distance the
    # couple can stand.  The trace is the exact lie sampled into chords, and
    # a chord across a hug dips inside the rim by its sagitta -- for the
    # 0.09-radian sampling step that is r(1 - cos 0.045), under two parts in
    # ten thousand -- so that much and no more is allowed for.
    for apart in [HUMAN.apart, 0.5, touching(HUMAN)]:
      for side in Side:
        for site in Site:
          check clearance(HUMAN, apart, lie(HUMAN, apart, side, site)) >=
            HUMAN.torso - 2e-4

  test "winding is paid for in rope, half a girth at a half turn":
    # The price list of turning danced low.  Winding back is unwinding, so
    # the cost is the size and not the sum; but a wind on one body cannot
    # cancel a wind on the other.
    let held = rope(Side.Left, Site.RightHand)
    for turns in 1 .. 3:
      check abs(slack(HUMAN, 0.5, held) -
        slack(HUMAN, 0.5, wound(held, Dancer.Follow, turns)) -
        float(turns) * PI * HUMAN.torso) < 1e-9
    check cost(HUMAN, 0.5, wound(held, Dancer.Follow, -1)) ==
      cost(HUMAN, 0.5, wound(held, Dancer.Follow, 1))
    check cost(HUMAN, 0.5, wound(wound(held, Dancer.Follow, 1),
      Dancer.Lead, -1)) > cost(HUMAN, 0.5, held) + PI * HUMAN.torso

  test "a wrap pulls the couple together":
    # No hold can be wound where the couple stand at arm's length: the rope
    # is already spent on the distance.  Step in and the same wind fits.
    # Which is why a wrap is danced from close position, and the bound says
    # how close: winding shortens the room the couple have.
    for side in Side:
      for site in Site:
        let once = wound(rope(side, site), Dancer.Follow, 1)
        check not feasible(HUMAN, HUMAN.apart, once)
        check feasible(HUMAN, 0.5, once)
        check bound(HUMAN, once) < bound(HUMAN, rope(side, site)) - 0.3

  test "the rope derives the wrap capacity the axis had to measure":
    # `rotation.nim` holds CAPACITY_WRAP_LOW as measured, not derived: a low
    # wrap takes half a turn and no more.  On the rig it stops being a
    # measurement: half a torso's girth fits the two arms' budget and a full
    # girth does not, even with the bodies touching.  An arm asked for the
    # full turn has run out of rope across the front, which is `blocker`'s
    # account of why a full turn low is a lock and not a deeper wrap.
    for side in Side:
      for site in Site:
        check pinLimit(HUMAN, side, site) == CAPACITY_WRAP_LOW
        check not feasible(HUMAN, touching(HUMAN),
          wound(rope(side, site), Dancer.Follow, CAPACITY_WRAP_LOW + 1))

  test "a turn over the head spends comfort, not rope":
    # Over the head the rope is on the axis the body turns about: nothing to
    # wind round, nothing to run out of -- the axis model says the same with
    # ABOVE_BLOCKS.  What runs out is the grip, and the rig carries the same
    # ceiling the axis holds as CAPACITY_SINGLE, so the two models cannot
    # drift apart in silence.
    let held = rope(Side.Left, Site.RightHand)
    for turns in 1 .. HUMAN.grip:
      check cost(HUMAN, 0.5, twisted(held, turns)) == cost(HUMAN, 0.5, held)
      check comfortable(HUMAN, twisted(held, turns))
    check not comfortable(HUMAN, twisted(held, HUMAN.grip + 1))
    check HUMAN.grip == CAPACITY_SINGLE

  test "a lift over the head is afforded only up close":
    # The gate on everything danced over the head -- the turns that spend
    # twist, and the shedding of a wrap.  At full stretch there is no rope
    # left to climb the neck with, which is why a turn is led after the
    # couple step in.
    for side in Side:
      for site in Site:
        check not liftable(HUMAN, HUMAN.apart, rope(side, site))
        check liftable(HUMAN, 0.5, rope(side, site))

  test "a wrap is shed over the head, and the rope comes back":
    # The way out of a wrap is the way turns avoid making one: carry the
    # connection over the head.  Wound once and stood close, the lift is
    # affordable, and shedding returns exactly the rope the wind had spent.
    let
      held = rope(Side.Left, Site.RightHand)
      wrapped = wound(held, Dancer.Follow, 1)
    check feasible(HUMAN, 0.5, wrapped)
    check liftable(HUMAN, 0.5, wrapped)
    let freed = shed(wrapped, Dancer.Follow)
    check freed.winds[Dancer.Follow] == 0
    check slack(HUMAN, 0.5, freed) == slack(HUMAN, 0.5, held)
