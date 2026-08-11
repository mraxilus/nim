## Lay out the single-hand turns page: every position, every transition.
##
##   The first of one mock-up per kind of turn (rule 15).  A high single
##     hand turns for ever (rule 16), so this page has no refusals in it:
##     what it holds is the four quarter-turn orientations of each of the
##     app's four single-hand frames, under each of the two dancers' own
##     turns, and an animation of every edge between them.
##   The plates are generated rather than written out, because thirty-two
##     positions and thirty-two transitions are a table, not an argument.
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

const SET_PROSE: array[TurnBy, tuple[title, blurb: string]] = [
  (title: "The follow turns on the spot",
   blurb: "The follow turns on their own axis and nobody travels: what " &
     "comes round is their <b>chevron</b>, and with it which of their " &
     "hands is nearer. The lead stands still, facing up, as they do in " &
     "every picture."),
  (title: "The lead turns on the spot",
   blurb: "The lead turns on their own axis. Because every picture is " &
     "drawn with <b>the lead facing up</b>, that same turn is seen as the " &
     "<b>follow swinging round them</b> — the collapse the frame page " &
     "draws, here as a set of positions rather than an argument. The pair " &
     "is the same pair; the framing is what moves."),
]


func plates(P: Parts; kind: TurnBy): string =
  ## Lay out one turn set: a plate per connection, positions then edges.
  for c, single in SINGLES:
    let tag = TURN_SETS[kind].tag
    result.add &"""<div class="plate"><h3>{single.name}</h3>"""
    result.add """<p>Every position, a quarter turn apart. The fourth """ &
      """quarter comes back to the first: the round closes, and nothing """ &
      """is ever refused.</p>"""
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
  <p class="standfirst">One kind of turn, on its own. Held <b>high</b>, a
  single-hand connection can turn <b>for ever</b> in either direction —
  nothing runs out, so nothing is ever refused. That has a consequence
  worth saying plainly: <b>how far it has wound is not part of the
  state</b>. If the turning never ends there is no wound-out end to be at,
  and what is left is <b>where the pair is pointing</b> — the four
  quarter-turn orientations of each of the app's four single-hand frames.
  Below, every one of those positions is drawn, and every transition
  between them animated.</p>
  <p class="sibling"><b>Hand to hand and the crossed pair come next</b>,
  each on its own page, and all three go together once each is right. The
  frame picture and the turn sign stay where they are.</p>
</header>

<section>
  <div class="head"><span class="n">What is here</span><h2>Four
  orientations, twice over</h2></div>
  <p><b>A position is a frame plus a quarter.</b> Turning does not change
  which hands are held, so it does not change the frame — it changes which
  way the pair is pointing, and that is what these rows count. The first
  cell of every row is the frame exactly as the app draws it; each step is
  a quarter turn; the fourth brings the round back to the first.</p>
  <p><b>Two dancers can do the turning, and they are not the same turn.</b>
  So the sets are drawn separately: the follow turning on the spot, and the
  lead turning on the spot. Everything is held high, so every connection
  runs straight and passes over whatever it meets — nothing wraps a body,
  and there is no wind mark on any of it.</p>
</section>

<section>
  <div class="head"><span class="n">One</span><h2>{foll_title}</h2></div>
  <p>{foll_blurb}</p>
  {foll_plates}
</section>

<section>
  <div class="head"><span class="n">Two</span><h2>{lead_title}</h2></div>
  <p>{lead_blurb}</p>
  {lead_plates}
</section>

<div class="note">
  <p><b>Whether these are two sets or one is the open question.</b> The
  frame page shows a collapse: a follow who walks a quarter round the lead
  arrives where the lead reaches by turning a quarter on the spot. If the
  same holds here, the two sets above are two ways of leading one set of
  edges, and the page should say so with one grid and a note about who
  leads it — which would halve what a reader has to hold. They are drawn
  apart until you say.</p>
  <p><b>What is not drawn:</b> anything that runs out. No refusal appears
  on this page because rule 16 says none exists for a high single hand;
  the moment a level other than high comes back into scope, ceilings and
  refusals come with it.</p>
</div>

<div class="foot">
  <p><b>Still not in the app.</b> Same standing as the other pages: the app
  keeps drawing the eight frames and nothing else until the marks are
  settled.</p>
  <p>Yours to settle on this page: whether the two sets collapse into one;
  whether a quarter is the right grain, or whether an eighth is danced;
  and what mark, if any, the edges themselves should carry — the turn sign
  was built for exactly this job and these are the first edges it could
  label.</p>
</div>

</div>
"""


func render*(P: Parts): string =
  ## Lay the single-hand turns page out around the given figures.
  document(TITLE, BODY.filled(@[
    ("foll_title", SET_PROSE[TurnBy.FollowTurns].title),
    ("foll_blurb", SET_PROSE[TurnBy.FollowTurns].blurb),
    ("foll_plates", plates(P, TurnBy.FollowTurns)),
    ("lead_title", SET_PROSE[TurnBy.LeadTurns].title),
    ("lead_blurb", SET_PROSE[TurnBy.LeadTurns].blurb),
    ("lead_plates", plates(P, TurnBy.LeadTurns)),
  ]))
