## Lay out the single-hand turns page: every position, every transition.
##
##   The first of one mock-up per kind of turn (rule 15).  Held above, a
##     single hand turns for ever (rules 16 and 17), so this page has no
##     refusals in it: what it holds is the four quarter-turn orientations
##     of each of the app's four single-hand frames, under each of the four
##     ways of turning (rule 19), and an animation of every edge between
##     them -- a lead's in the two stages rule 18 asks for.
##   The plates are generated rather than written out, because sixty-four
##     positions and sixty-four transitions are a table, not an argument.
##     Cost of generating them: the prose cannot speak to one figure in
##       particular, only to a whole set.  Accepted -- what is being shown
##       here is a pattern, and a pattern read one cell at a time is not
##       read at all.

{.experimental: "strictFuncs".}

import std/[strformat, tables]

import ./[page, parts]


const TITLE* = "Single-hand turns, so far"


const QUARTER_NAMES = ["none", "&#188;", "&#189;", "&#190;"]
  ## How far round from the app's own frame, in quarters.



func plates(P: Parts; way: TurnWay): string =
  ## Lay out one way of turning: a plate per connection, positions then
  ## edges.
  let tag = WAYS_OF_TURNING[way].tag
  for c, single in SINGLES:
    result.add &"""<div class="plate"><h3>{single.name}</h3>"""
    result.add """<p>Every position this way reaches, a quarter turn """ &
      """apart. The fourth quarter comes back to the first: the round """ &
      """closes, and nothing is ever refused.</p>"""
    result.add """<div class="row mid">"""
    for quarter in 0 ..< QUARTERS_ROUND:
      if quarter > 0:
        result.add P["g_quarter"]
      let caption =
        if quarter == 0: "<b>none</b><br>the app's frame"
        else: &"<b>{QUARTER_NAMES[quarter]}</b> turn"
      result.add fig(P[&"st_{tag}_{c}_{quarter}"], caption)
    result.add P["g_quarter"]
    result.add fig(P[&"st_{tag}_{c}_0"], "<b>none</b><br>round again")
    result.add "</div>"
    result.add """<p>And every transition between them, each rocking """ &
      """between its two positions so the turn reads both ways:</p>"""
    result.add """<div class="row mid">"""
    for quarter in 0 ..< QUARTERS_ROUND:
      let
        to = (quarter + 1) mod QUARTERS_ROUND
        moving = P[&"tr_{tag}_{c}_{quarter}_{to}"].replaceFirst(
          "class=\"mv\"", "class=\"mv moving\"")
        still = P[&"tr_{tag}_{c}_{quarter}_{to}_still"]
        caption = &"{QUARTER_NAMES[quarter]} &rarr; {QUARTER_NAMES[to]}"
      result.add &"<figure>{moving}{still}" &
        &"<figcaption>{caption}</figcaption></figure>"
    result.add "</div></div>"


const BODY = """

<div class="sheet">

<header class="top">
  <p class="kicker">Partner work · rotation · single-hand turns</p>
  <h1>Single-hand turns, so far</h1>
  <p class="standfirst">One kind of turn, on its own. The held arm is
  carried <b>above</b> — over the head, on the axis the couple turns about
  — because <em>high</em> and <em>low</em> are the levels a wrap or a lock
  is made at, and above is the one level that has neither. From there a
  single-hand connection turns <b>for ever</b> in either direction, so
  nothing is refused and the round closes. That has a consequence worth
  saying plainly: <b>how far it has wound is not part of the state</b>. If
  the turning never ends there is no wound-out end to be at, and what is
  left is <b>where the pair is pointing</b> — four quarter-turn
  orientations for each of the app's four single-hand frames.</p>
  <p class="sibling"><b>Hand to hand and the crossed pair come next</b>,
  each on its own page, and all of them go together once each is right.</p>
</header>

<section>
  <div class="head"><span class="n">What is here</span><h2>Four ways to
  turn, and two sets of places they reach</h2></div>
  <p><b>A position is a frame plus a quarter.</b> Turning does not change
  which hands are held, so it does not change the frame — it changes which
  way the pair is pointing. The first cell of every row is the frame
  exactly as the app draws it; each step is a quarter turn; the fourth
  brings the round back to the first.</p>
  <p><b>Four ways of turning, not two.</b> Either dancer can turn on their
  own axis, and either can orbit the other — so all four are drawn.
  <b>A dashed ring says an orbit</b>, centred on whoever is standing still;
  it is the same dash the frame picture uses, and nothing else on this page
  is dashed.</p>
  <p><b>A lead's turn is danced in two stages, and animated that way.</b>
  <b>Stage one</b> is the turn itself, seen from where the room stands: the
  lead turns and the picture leans off upright with them. <b>Stage two</b>
  reorients the picture until the lead faces up again, which is what swings
  the follow round. A follow's turn needs no second stage — the lead never
  moved, so there is nothing to bring back.</p>
  <p><b>And the orbits reach no new places.</b> Measured, and asserted on
  every build: a follow orbiting the lead walks the very states the lead's
  own turn reaches, and a lead orbiting the follow walks the follow's own —
  each backwards. So there are four ways of turning and only <b>two sets of
  positions</b>, which is the collapse the frame page argues, met again
  here as a fact about the drawings rather than an argument about them.</p>
</section>

<section>
  <div class="head"><span class="n">One · axis</span><h2>{fa_title}</h2></div>
  <p>{fa_blurb}</p>
  {fa_plates}
</section>

<section>
  <div class="head"><span class="n">Two · axis</span><h2>{la_title}</h2></div>
  <p>{la_blurb}</p>
  {la_plates}
</section>

<section>
  <div class="head"><span class="n">Three · orbit</span><h2>{fo_title}</h2></div>
  <p>{fo_blurb}</p>
  {fo_plates}
</section>

<section>
  <div class="head"><span class="n">Four · orbit</span><h2>{lo_title}</h2></div>
  <p>{lo_blurb}</p>
  {lo_plates}
</section>

<div class="note">
  <p><b>What the collapse costs, and what it buys.</b> If two ways reach
  one set of positions, then a position cannot say which way it was reached
  by — only the edge can. That is the frame page's conclusion arriving
  here with teeth: the four sections above are four ways of leading, and
  the state graph underneath them has two rounds in it, not four. Whether
  the page should be reorganised to say that first — two rounds, four ways
  of walking them — is yours to call.</p>
  <p><b>What is not drawn:</b> anything that runs out. No refusal appears
  on this page because above has no ceiling; the moment a level that locks
  or wraps comes back into scope, ceilings and refusals come with it.</p>
</div>

<div class="foot">
  <p><b>Still not in the app.</b> Same standing as the other pages: the app
  keeps drawing the eight frames and nothing else until the marks are
  settled.</p>
  <p>Yours to settle on this page: whether the two rounds should lead the
  page rather than the four ways; whether a quarter is the right grain, or
  whether an eighth is danced; and what mark, if any, the edges themselves
  should carry — the turn sign was built for exactly this job and these are
  the first edges it could label.</p>
</div>

</div>
"""


func render*(P: Parts): string =
  ## Lay the single-hand turns page out around the given figures.
  var fills: seq[tuple[marker, value: string]]
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    fills.add (&"{w.tag}_title", w.title)
    fills.add (&"{w.tag}_blurb", w.blurb)
    fills.add (&"{w.tag}_plates", plates(P, way))
  document(TITLE, BODY.filled(fills))
