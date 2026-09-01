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
  APART = 0.34            ## A stance with the rims a centimetre or two clear.
  LOW = HUMAN.shoulder    ## Hands carried where they hang.
  HIGH = HUMAN.crown + 0.15 ## And carried clear over both crowns.


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
      raised = oneLink(APART, Arm.Left, Arm.Right, LOW + 0.2)
      a = lay(flat, flat.links[0]).get
      b = lay(raised, raised.links[0]).get
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
    # surface, and this is what says it worked: five step sizes across a
    # factor of thirty, one answer.
    #   Asked out to two turns and not just one, because it is the laps that
    #   a coarse step would drop, and at half a turn there are none to drop.
    #   This is also what lets the step be coarse: it is replayed on every
    #   frame of a drag, so a finer one than the answer needs is just a
    #   slower page.
    for turns in [0.5, 1.4, 2.0]:
      var spans: seq[float]
      var laps: seq[int]
      for step in [0.30, 0.15, 0.10, 0.05, 0.01]:
        let s = turned(oneLink(APART, Arm.Left, Arm.Right), Body.Two,
          turns * 2.0 * PI, step)
        spans.add lay(s, s.links[0]).get.span
        var round = 0
        for wind in s.links[0].winds:
          round += wind.turns
        laps.add round
      for i in 0 ..< spans.len:
        # The laps have to match exactly -- they are the memory, and dropping
        # one is the failure this guards against.  The spans match to a
        # tolerance and not to the bit, because a facing is reached by adding
        # `to / steps` that many times, and the last bits of that sum depend
        # on how many steps there were.  Asking for equality here would be
        # asking floating point for something it does not owe.
        check abs(spans[i] - spans[0]) < 1e-9
        check laps[i] == laps[0]


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

  test "two ropes through each other leave the question open":
    # Where a body has got in between, the two ropes are not braiding, and two
    # ropes crossing at one height with no braid to order them are simply in
    # the same place.  The model refuses that state -- and declines to say
    # which of them is over, because there is nothing there to say it with.
    #   Settled first, on purpose: a crossed hold at shoulder height runs
    #   through both chests, so taking it is what puts the winding on and the
    #   winding is what stops the pair braiding.
    var s = facing(HUMAN, APART)
    s.links = @[
      Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Left)], height: LOW),
      Link(ends: [(Body.One, Arm.Right), (Body.Two, Arm.Right)], height: LOW)]
    let
      here = settled(s)
      a = lay(here, here.links[0]).get
      b = lay(here, here.links[1]).get
    check not braidedLie(a)
    check not braidedLie(b)
    let met = meetings(here, here.links[0], a, here.links[1], b)
    check met.len >= 1
    for one in met:
      check overOf(HUMAN, one).isNone
    check refusal(here, swan = false) == some(Fault.Braided)

  test "ropes joining opposite hands never meet at all":
    var s = facing(HUMAN, APART)
    s.links = @[
      Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Right)], height: LOW),
      Link(ends: [(Body.One, Arm.Right), (Body.Two, Arm.Left)], height: LOW)]
    let
      a = lay(s, s.links[0]).get
      b = lay(s, s.links[1]).get
    check meetings(s, s.links[0], a, s.links[1], b).len == 0


suite "two ropes braid":
  func overhead(a0, b0, a1, b1: Arm; ha = HIGH; hb = HIGH): State =
    ## Two connections carried over both crowns, where nothing is in the way.
    result = facing(HUMAN, APART)
    result.links = @[
      Link(ends: [(Body.One, a0), (Body.Two, b0)], height: ha),
      Link(ends: [(Body.One, a1), (Body.Two, b1)], height: hb)]

  func rope(state: State): float =
    ## Measure the rope the pair is spending between them.
    ##   The pair's, not one rope's.  A braid puts one strand above the
    ##     couple's height and the other below, so at any rung one of the two
    ##     is climbing a little less than it would unbraided -- and asking
    ##     that one alone whether braiding costs rope gets the answer no.
    for link in state.links:
      let laid = lay(state, link)
      if laid.isSome:
        result += laid.get.length

  func crossings(state: State): int =
    ## Count where the two ropes cross, off the drawn paths and nothing else.
    let
      a = lay(state, state.links[0])
      b = lay(state, state.links[1])
    if a.isNone or b.isNone: -1
    else: meetings(state, state.links[0], a.get, state.links[1], b.get).len

  test "the relative turn is read off the facings, laps and all":
    # Nothing carries it.  A facing accumulates without wrapping, so the turn
    # one body has made against the other has been in the state since the
    # beginning -- and it has to survive past a whole turn, which is exactly
    # what a wrapped reading would lose.
    let base = overhead(Arm.Left, Arm.Right, Arm.Right, Arm.Left)
    check abs(twist(base)) < 1e-12
    for turns in [0.5, 1.0, 1.5, 2.0, -1.5]:
      let s = turned(base, Body.Two, turns * 2.0 * PI)
      check abs(twist(s) / (2.0 * PI) - turns) < 1e-9
    # And turning the lead is the same turn the other way.
    let back = turned(base, Body.One, 2.0 * PI)
    check abs(twist(back) / (2.0 * PI) + 1.0) < 1e-9

  test "the ladder: no twist, the X, the diamond, the swan":
    # The rungs of it, counted off the drawn ropes rather than off the angle.
    # Nothing in the module counts crossings; a cosine has that many zeroes.
    let base = overhead(Arm.Left, Arm.Right, Arm.Right, Arm.Left)
    for half in 0 .. 3:
      let s = turned(base, Body.Two, PI * float(half))
      check crossings(s) == half

  test "a hold that joins hands of the same name starts a rung up":
    # It is already crossed over its partner, which is half a turn of braid
    # before anybody has turned at all -- so the same ladder, shifted by one.
    let base = overhead(Arm.Left, Arm.Left, Arm.Right, Arm.Right)
    for half in 0 .. 2:
      let s = turned(base, Body.Two, PI * float(half))
      check crossings(s) == half + 1

  test "turning the lead braids as surely as turning the follow":
    let base = overhead(Arm.Left, Arm.Right, Arm.Right, Arm.Left)
    for half in 0 .. 3:
      check crossings(turned(base, Body.One, -PI * float(half))) == half

  test "no two ropes ever cross closer than they can lie":
    # The braid does not check this and then refuse: it is shaped so that a
    # crossing is a place where one rope is the spiral's own radius above the
    # axis and the other the same below.  Held to over the whole ladder,
    # quarter turn by quarter turn, and both ways round.
    for step in -6 .. 6:
      let s = turned(overhead(Arm.Left, Arm.Right, Arm.Right, Arm.Left),
        Body.Two, PI / 2.0 * float(step))
      let
        a = lay(s, s.links[0])
        b = lay(s, s.links[1])
      check a.isSome and b.isSome
      for one in meetings(s, s.links[0], a.get, s.links[1], b.get):
        check abs(one.high[0] - one.high[1]) > 2.0 * HUMAN.limb - 1e-2
      check refusal(s, swan = false) != some(Fault.Braided)

  test "hands held apart braid wider, and the wider braid costs rope":
    # Decoupled heights are not a drawing: holding one pair of hands higher
    # than the other opens the braid out, which the two ropes then pay for.
    let
      level = turned(overhead(Arm.Left, Arm.Right, Arm.Right, Arm.Left),
        Body.Two, PI)
      apart = turned(overhead(Arm.Left, Arm.Right, Arm.Right, Arm.Left,
        HIGH - 0.09, HIGH + 0.09), Body.Two, PI)
    var least = [9.9, 9.9]
    for k, s in [level, apart]:
      let
        a = lay(s, s.links[0]).get
        b = lay(s, s.links[1]).get
      for one in meetings(s, s.links[0], a, s.links[1], b):
        least[k] = min(least[k], abs(one.high[0] - one.high[1]))
    check least[1] > least[0] + 0.05
    # The same pair of hands, the same height between them, spread apart: the
    # braid opens to the gap and the two ropes pay for the opening.
    check rope(apart) > rope(level)

  test "braiding costs rope, rung after rung":
    let base = overhead(Arm.Left, Arm.Right, Arm.Right, Arm.Left)
    var was = [0.0, 0.0]
    for half in 0 .. 3:
      let s = turned(base, Body.Two, PI * float(half))
      # Both measures, because they answer different questions: the plan span
      # is how far round the rope has had to go, and the length is what it
      # costs once the climb is paid for.
      check lay(s, s.links[0]).get.span > was[0]
      check rope(s) > was[1]
      was = [lay(s, s.links[0]).get.span, rope(s)]

  test "the swan is the limit, both ways, and it is asserted not derived":
    # `Rig.swan` is a report of what dancers manage and is cited to nothing in
    # the model.  So it is kept apart from the geometry: `holds` will apply it
    # and `holds(swan = false)` will not, and the page shows both numbers.
    var rig = HUMAN
    rig.arm = 0.80 # Long enough that the geometry itself reaches past 1.5.
    func pair(rig: Rig): State =
      result = facing(rig, APART)
      result.links = @[
        Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Right)],
             height: rig.crown + 0.15),
        Link(ends: [(Body.One, Arm.Right), (Body.Two, Arm.Left)],
             height: rig.crown + 0.15)]
    let base = pair(rig)
    for way in [1.0, -1.0]:
      let
        under = turned(base, Body.Two, way * (rig.swan - 0.05) * 2.0 * PI)
        over = turned(base, Body.Two, way * (rig.swan + 0.05) * 2.0 * PI)
      check holds(under)
      check refusal(over) == some(Fault.Swan)
      # And the geometry alone says nothing about it either way.
      check refusal(over, swan = false).isNone
    check abs(windLimit(base, Body.Two, most = 8.0 * PI) -
      rig.swan * 2.0 * PI) < 0.05
    check windLimit(base, Body.Two, most = 8.0 * PI, swan = false) >
      rig.swan * 2.0 * PI

  test "a pair of hands binds tighter than one, with nothing told to it":
    # The claim the README makes, which was read off a page rather than
    # measured until now.  Two connections run out sooner than one, at the
    # same height and the same stance, because they must braid past each
    # other as well as reach.
    for height in [LOW, HIGH]:
      var alone = facing(HUMAN, APART)
      alone.links = @[Link(ends: [(Body.One, Arm.Left), (Body.Two, Arm.Right)],
                           height: height)]
      let
        one = windLimit(settled(alone), Body.Two, most = 8.0 * PI, swan = false)
        two = windLimit(settled(overhead(Arm.Left, Arm.Right, Arm.Right,
          Arm.Left, height, height)), Body.Two, most = 8.0 * PI, swan = false)
      check two < one


suite "where a wind lies":
  # `lyingOn` is what the verdicts report is built on, so its own facts are
  # pinned here, still in the sim's words: a rope lies fore or aft of a body,
  # on a band, wound onto it or merely led there.

  test "half a turn lays the arm fore one way and aft the other":
    let base = settled(oneLink(APART, Arm.Left, Arm.Left))
    let fore = turned(base, Body.Two, PI)
    let aft = turned(base, Body.Two, -PI)
    check lyingOn(fore, fore.links[0], Body.Two).get.aspect == Aspect.Fore
    check lyingOn(aft, aft.links[0], Body.Two).get.aspect == Aspect.Aft

  test "a led arm is told apart from a wound one":
    # Half a turn the aft way leaves the rope clear of the body: the hand is
    # led behind the back, and the reading says so rather than claiming a
    # press that is not there.  A whole turn the same way winds it on.
    let base = settled(oneLink(APART, Arm.Left, Arm.Left))
    let led = turned(base, Body.Two, -PI)
    let round = turned(base, Body.Two, -2.0 * PI)
    check not lyingOn(led, led.links[0], Body.Two).get.wound
    check lyingOn(round, round.links[0], Body.Two).get.wound

  test "over the crown, an arm lies nowhere":
    # A rope carried above the crown clears the body on every side at once,
    # so there is no fact of fore-or-aft for a reading to report.
    let up = settled(oneLink(APART, Arm.Left, Arm.Left, HIGH))
    for way in [1.0, -1.0]:
      let spun = turned(up, Body.Two, way * PI)
      check lyingOn(spun, spun.links[0], Body.Two).isNone

  test "laps past the part-turn are counted, not wrapped away":
    let base = settled(oneLink(APART, Arm.Left, Arm.Left))
    let spun = turned(base, Body.Two, 2.0 * PI)
    check lyingOn(spun, spun.links[0], Body.Two).get.laps == 1
