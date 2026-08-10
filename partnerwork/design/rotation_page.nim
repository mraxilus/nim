## Lay out the rotation page: travelling between the frames by turning.
##
##   Presentation only, like the other two pages: every claim a figure makes
##     is generated and asserted elsewhere.
##   The subject is rules 10 to 13: rotation as edges over the app's eight
##     frames, everything held high so no wrap and no lock ever settles, and
##     the position counts the rules give -- three for hand to hand, four
##     for the crossed pair, five for a single hold.

{.experimental: "strictFuncs".}

import std/tables

import ./[page, parts]


const TITLE* = "Rotation between the frames, so far"


const BODY = """

<div class="sheet">

<header class="top">
  <p class="kicker">Partner work · rotation · travelling</p>
  <h1>Rotation between the frames, so far</h1>
  <p class="standfirst">The app's eight frames, and nothing else — rotation
  adds <b>no new frame</b>. What it adds is <b>positions</b>: the same held
  frame with the arms wound further or less far round, and the turns that
  travel between them. Everything here is held <b>high</b> — the dot on
  every hand — so nothing ever settles into a wrap or a lock, and the whole
  lock-and-wrap half of the frame page is out of scope by assumption. A
  position is drawn as the frame it is, with the wind carried by <b>which
  way the line goes round</b>; a turn that cannot be taken is drawn
  <b>dashed</b>, as refusal is drawn everywhere in this project.</p>
  <p class="sibling"><b>The frame picture and the turn sign are on their own
  pages.</b> This page reuses the frame picture whole, and the turns on it
  are the edges the sign was invented to label.</p>
</header>

<section>
  <div class="head"><span class="n">One</span><h2>The same eight frames,
  wound</h2></div>
  <p><b>A position is a frame plus a wind.</b> Turning a dancer half a turn
  does not change which hands are held, so it does not change the frame —
  it changes how far the arms are wound round the bodies, and that is what
  these strips count. The centre of each strip is the frame exactly as the
  app draws it; each step outward is half a turn (or, on the crossed pair,
  a full one), and the ends refuse.</p>
  <p><b>Open has no strip.</b> Nothing joins the bodies, so nothing winds,
  nothing is stored, and either dancer turns freely — there is no position
  to draw and no edge to refuse.</p>

  <div class="plate">
    <h3>A single hold: five positions</h3>
    <p>One connection can carry a full turn in either direction — the
    model's own measured ceiling. The wound ends are drawn with the line
    taking the long way round, which is what a full wind looks like from
    above. The two half-turn positions are five states but <b>four
    pictures</b>: with one connection running down the side, the line
    touches neither body and the hands stay at their sides, so the drawing
    has nowhere to put the wind direction — measured, asserted, and honest:
    <b>which way you wound lives on the edge you took</b>, exactly as
    axis-against-orbit lives on the edge and not the node. <em>Left to
    left</em> is drawn; the other three single holds read the same way.</p>
    <div class="row mid">
      <figure>{rot_single_m2}<figcaption>a full turn<br>wound, one way</figcaption></figure>
      {g_half}
      <figure>{rot_single_m1}<figcaption>half a turn</figcaption></figure>
      {g_half}
      <figure>{rot_single_z}<figcaption><b>at rest</b><br>the app's frame</figcaption></figure>
      {g_half}
      <figure>{rot_single_p1}<figcaption>half a turn<br>the other way</figcaption></figure>
      {g_half}
      <figure>{rot_single_p2}<figcaption>a full turn<br>wound, the other way</figcaption></figure>
    </div>
    <div class="row mid">
      {g_refused}
      <p class="note">beyond either end the arm is out of turn, and the edge
      is not offered</p>
    </div>
  </div>

  <div class="plate">
    <h3>Hand to hand: three positions</h3>
    <p>Two connections halve the ceiling: half a turn each way and no
    further. The two turned positions differ only in which way round the
    lines pass — the wind direction again, and nothing else.</p>
    <div class="row mid">
      <figure>{rot_hand_m1}<figcaption>half a turn,<br>one way</figcaption></figure>
      {g_half}
      <figure>{rot_hand_z}<figcaption><b>at rest</b><br>hand to hand</figcaption></figure>
      {g_half}
      <figure>{rot_hand_p1}<figcaption>half a turn,<br>the other way</figcaption></figure>
    </div>
    <div class="row mid">
      {g_refused}
      <p class="note">beyond either half turn the pair of arms is out, and
      the edge is not offered</p>
    </div>
  </div>

  <div class="plate pick">
    <h3>The crossed pair: four positions<span class="tag">the reading to
    check</span></h3>
    <p><b>The twisted states are the ends.</b> In the middle sit the two
    over-orders — left over right and right over left — joined by the full
    turn that swaps which arm is over: the crossing absorbs that wind, so
    turning through costs nothing and lands in the other crossed hold. One
    further turn from either middle is an <b>extra</b> arm twist, and that
    is an end: its own side wound one more turn, refused beyond.</p>
    <div class="row mid">
      <figure>{rot_cross_end_l}<figcaption>left over right,<br>an extra twist</figcaption></figure>
      {g_full}
      <figure>{rot_cross_over_l}<figcaption><b>left over right</b></figcaption></figure>
      {g_full}
      <figure>{rot_cross_over_r}<figcaption><b>right over left</b></figcaption></figure>
      {g_full}
      <figure>{rot_cross_end_r}<figcaption>right over left,<br>an extra twist</figcaption></figure>
    </div>
    <div class="row mid">
      {g_refused}
      <p class="note">beyond either extra twist the arms are out, and the
      edge is not offered</p>
    </div>
    <p>That chain — over-orders in the middle, twisted states at the ends,
    the middle edge swapping the over — is my reading of your words, and it
    is the thing on this page to check.</p>
  </div>

  <div class="plate">
    <h3>Moving<span class="tag">it runs here</span></h3>
    <p>Hand to hand, rocking through its three positions: half a turn one
    way, home, half a turn the other, home. Both connections are routed with
    one way round settled for the whole move, so nothing sweeps through a
    body at any instant the browser draws — the same rule every moving
    figure on the frame page obeys.</p>
    <div class="row">
      <figure>{rot_moving}{rot_moving_still}<figcaption>hand to hand,<br>rocking half a turn each way</figcaption></figure>
    </div>
  </div>

  <div class="note">
    <p><b>What the ends are made of is not settled here.</b> The strips say
    <em>where</em> rotation stops, not <em>why</em>: the single hold's
    ceiling is the model's measured arm capacity, the crossed pair's ends
    lean on the over-swap reading above, and whether an orbit stores the
    same wind an axis turn does is still an open question on the frame
    page. When the wrap-and-lock half comes back into scope, some of these
    refused ends become settles instead — a half turn at <em>low</em> is
    exactly where the frame page's wraps come from.</p>
  </div>
</section>

<div class="foot">
  <p><b>Still not in the app.</b> Same standing as the other two pages: the
  app keeps drawing the eight frames and nothing else until the marks are
  settled.</p>
  <p>Yours to settle on this page: the crossed pair's chain — whether the
  full turn between the over-orders really costs nothing, and whether its
  ends are one extra <em>full</em> turn or one extra <em>half</em>; whether
  the single hold's wound ends should be drawn some other way than the long
  way round; and what mark, if any, the edges themselves should carry (the
  turn sign was built for exactly this job).</p>
</div>

</div>
"""


func render*(P: Parts): string =
  ## Lay the rotation page out around the given figures.
  var fills: seq[tuple[marker, value: string]]
  for key in ["rot_single_m2", "rot_single_m1", "rot_single_z",
              "rot_single_p1", "rot_single_p2",
              "rot_hand_m1", "rot_hand_z", "rot_hand_p1",
              "rot_cross_end_l", "rot_cross_over_l", "rot_cross_over_r",
              "rot_cross_end_r", "g_half", "g_full", "g_refused",
              "rot_moving_still"]:
    fills.add (key, P[key])
  fills.add ("rot_moving", P["rot_moving"].replaceFirst(
    "class=\"mv\"", "class=\"mv moving\""))
  document(TITLE, BODY.filled(fills))
