## Lay out the rig page: what the model derives, plate by plate.
##
##   The other four pages settle how a thing is *drawn*.  This one is about
##     whether the thing can be *done*, and every picture on it is the
##     solver's own output rather than an illustration of one.
##   One plate per law, and only laws: the state gallery and the transition
##     table both belong to the app, which already has them, and a page that
##     repeated them would be arguing nothing.
##   Distance is pinned at the smallest gap two bodies can hold.  It is a
##     real axis in the model -- the referee knows to the centimetre how
##     close a wrap has to be led -- but a page that swept it would be about
##     distance, and this one is about the rope.
##     Cost of pinning it: two of the eleven laws are about distance and
##       survive here only as sentences.  Accepted -- they are asserted in
##       `tests/tsim.nim`, which is where a law lives anyway.

{.experimental: "strictFuncs".}

import std/[strformat, tables]

import ./[page, parts, rig]
import ../src/partnerwork/frame as ontology
import ../src/partnerwork/sim


const TITLE* = "The rig, so far"


const BODY = """
<div class="sheet">

<header class="top">
  <p class="kicker">Partner work &middot; the rig</p>
  <h1>The rig, so far</h1>
  <p class="standfirst">Two bodies seen from above, and arms that are rope:
  perfectly flexible, never stretching, tied hand to hand. Everything else in
  this work is notation, and notation cannot be wrong about a body. This can.
  Every picture below is the solver's own answer, drawn where it put it.</p>
  <p class="sibling"><b>The drawing rules are on the other four pages.</b>
  Nothing here settles how a mark is drawn; it settles whether the thing the
  mark stands for can be done at all.</p>
</header>

<section>
  <div class="head"><span class="n">The rig</span><h2>What it is made of</h2></div>
  <p>A torso is a cylinder, drawn as the disc you see it as from above, with a
  narrower cylinder stacked on it for the head and neck &mdash; the inner
  circle. An arm is a rope anchored at the shoulder, on the rim. A connection
  ties the lead's rope to the follow's, so what it has to spend is both arms
  at once, and what it spends them on is the way it has to lie. Nothing passes
  through anything: a path that would run through a chest is not a path, and
  the taut lie bends around instead, hugging the rim exactly as far as it
  must.</p>
  <div class="plate">
    <h3>The measurements everything below is refereed against</h3>
    <table class="slots">{sizes}</table>
    <p>Drawn at {px} units to the metre, taken on the torso &mdash; so a body
    comes out the size every other page draws it, and only the distance
    between the two is new. The couple stand at the closest two bodies can,
    rims touching, in every figure on this page.</p>
  </div>
</section>

<section>
  <div class="head"><span class="n">Law one</span><h2>Every frame is a frame
  a body can hold</h2></div>
  <p>The first duty of a notation is that the states it names can be stood in.
  All eight can, at the smallest gap, with rope to spare in each.</p>
  <div class="plate">
    <div class="row mid">{states}</div>
  </div>
</section>

<section>
  <div class="head"><span class="n">Law two</span><h2>Straight, or round both
  bodies</h2></div>
  <p>A parallel connection joins opposite-named hands and runs straight from
  one shoulder to the other. A crossed one joins same-named hands, and its
  straight line would pass through both chests &mdash; so it cannot take it.
  What you see below is not a stylistic bend: it is the shortest path that
  exists. The rope crosses the midline exactly when the frame's name says
  <em>crossed</em>, which makes the mirror of facing partners a fact about
  bodies before it is a convention about words.</p>
  <div class="plate">
    <div class="row">{lies}</div>
    <div class="note"><p><b>Nothing runs through a body.</b> Measured on every
    figure here, the closest any rope comes to a centre is the torso's own
    radius &mdash; it rides the rim and no further in.</p></div>
  </div>
</section>

<section>
  <div class="head"><span class="n">Law three</span><h2>Why <code>over</code>
  exists at all</h2></div>
  <p>The ontology carries one extra field on a frame: which arm lies on top.
  It is not carried everywhere &mdash; only the frame with two crossed
  connections has it, and the model refuses it to every other. That is not a
  choice about bookkeeping. Two crossed ropes meet, once, and where two ropes
  meet one of them is above the other; two parallel ropes never meet, so there
  is nothing to say. The ring below marks the place the question is asked.</p>
  <div class="plate">
    <div class="row">{pairs}</div>
  </div>
</section>

<section>
  <div class="head"><span class="n">Law four</span><h2>Where the wrap runs
  out</h2></div>
  <p>A turn danced low winds the rope around the turning body, and winding
  costs rope: half a girth for every half turn, whichever way it goes.
  <code>rotation.nim</code> has always held that a low wrap takes half a turn
  and no more &mdash; and held it as something <em>measured</em>, fitted to two
  cells of a spreadsheet. It does not have to be. Two arms afford one half
  turn of girth and refuse the next, with the bodies as close as bodies can
  be. The capacity falls out of arm against girth, and the third picture is
  what running out looks like.</p>
  <div class="plate">
    <div class="row">{winds}</div>
    <p>This is also the whole account of why a full turn low is a
    <em>lock</em> and not a deeper wrap: the arm has run out of rope across
    the front, so it must have gone behind the back instead.</p>
  </div>
  <div class="note"><p><b>And why a wrap is led close.</b> At the distance a
  couple actually stand and dance &mdash; not this one &mdash; there is no
  spare rope at all to wind with, so a lead who wants a wrap has to bring the
  couple together first. The referee knows how close; this page does not show
  it, because it would be a page about distance.</p></div>
</section>

<section>
  <div class="head"><span class="n">Law five</span><h2>Over the head costs
  comfort, not rope</h2></div>
  <p>Carry the connection over a head and the rope is on the axis the body
  turns about: there is nothing to wind round and nothing to run out of, which
  is what the axis model means when it says an arm held <em>above</em> blocks
  no turn. What runs out instead is the grip &mdash; joined hands only swivel
  so far &mdash; and that is anatomy, so the rig takes it as an input rather
  than deriving it. It takes the same number the axis model holds, so the two
  cannot quietly disagree. The lift itself costs rope while it happens, up the
  neck and down the far side, which is the one place the head has a size.</p>
  <div class="plate">
    <div class="row">{head}</div>
    <p>Which is also the way out of a wrap. The pair above is the same
    connection before and after: nothing about the rope changed except
    that it stopped being wound, and the length the wind was holding came
    back whole. The law is the difference between them, not anything visible
    in either one alone.</p>
  </div>
</section>

<div class="foot">
  <p><b>What the rig will not say yet.</b> A rope has no elbow, so nothing here
  is about where an arm bends. The pose never moves, so orbits are not
  modelled. A hammerlock is a longer lie this solver can already price and
  nothing yet asks it to. And the cut &mdash; swapping which crossed rope is on
  top &mdash; is a question about hand heights, which a plan view does not
  hold.</p>
  <p>Yours to settle on this page: whether the grip really stops where the
  axis model puts it, and whether a lift should cost what a head and neck
  actually cost rather than the proportion assumed here.</p>
</div>

</div>
"""


func render*(P: Parts): string =
  ## Lay the rig page out around the figures the model drew.
  var sizes: string
  for (what, value, unit) in [
      ("torso, radius", metres(HUMAN.torso), "m"),
      ("head and neck, radius", metres(HUMAN.head), "m"),
      ("arm, shoulder to hand", metres(HUMAN.arm), "m"),
      ("one connection, both arms", metres(budget(HUMAN)), "m"),
      ("the couple, centre to centre", metres(GAP), "m"),
      ("a half turn wound low", metres(PI_TORSO), "m"),
      ("a lift, up the neck and down", metres(rise(HUMAN)), "m"),
      ("the grip, in half turns", $HUMAN.grip, "")]:
    sizes.add &"<tr><th>{what}</th><td class=\"num\">{value} {unit}</td></tr>"

  var states: string
  for target in FRAMES:
    let couple = atRest(HUMAN, target, GAP)
    var least = 0.0
    for held in couple.ropes:
      least = (if least == 0.0: slack(HUMAN, GAP, held)
               else: min(least, slack(HUMAN, GAP, held)))
    let spare = if couple.ropes.len == 0: "nothing held"
                else: &"{metres(least)} m spare"
    states.add fig(P[&"state_{target.slug}"],
      &"<b>{target.brief}</b><br>{spare}")

  var lies: string
  for one in LINKS:
    let
      laid = lie(HUMAN, GAP, one.side, one.site)
      how = if isCrossed(one.side, one.site): "crossed &mdash; round both"
            else: "parallel &mdash; straight"
    lies.add fig(P[&"lie_{leadName(one.side)}_{followName(one.site)}"],
      &"<b>{describeConnection(one.side, one.site)}</b><br>{how}" &
      &"<br>{metres(laid.length)} m of rope")

  let pairs =
    fig(P["pair_crossed"], "<b>two crossed connections</b><br>they meet once, " &
      "so one is over") &
    fig(P["pair_parallel"], "<b>two parallel connections</b><br>they never " &
      "meet, so there is no over")

  var winds: string
  for turns in 0 .. 2:
    let
      spent = windFollow(rope(Side.Left, Site.RightHand), turns)
      left = slack(HUMAN, GAP, spent)
      says = if left >= 0.0: &"{metres(left)} m still spare"
             else: &"<b>{metres(-left)} m short</b>"
      name = case turns
             of 0: "at rest"
             of 1: "half a turn, wound low"
             else: "a whole turn"
    winds.add fig(P[&"wind_{turns}"], &"<b>{name}</b><br>{says}")

  # The wound figure is placed twice, once under each law it belongs to, so
  # it rides here under a marker of its own -- `filled` closes a hole once.
  let
    wrapped = windFollow(rope(Side.Left, Site.RightHand), 1)
    head =
      fig(P["wind_1"], "<b>a wrap, wound low</b><br>" &
        &"{metres(slack(HUMAN, GAP, wrapped))} m still spare") &
      fig(P["over_head_shed"], "<b>carried over the head</b><br>" &
        &"the wind's {metres(PI_TORSO)} m comes back whole")

  document(TITLE, BODY.filled(@[
    ("sizes", sizes), ("px", metres(PX, 0)), ("states", states),
    ("lies", lies), ("pairs", pairs), ("winds", winds), ("head", head)]))
