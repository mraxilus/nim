"""The turn-sign page: how to label an edge with an amount of turning.

A separate exploration from the frame picture, on a separate page, because it
answers a separate question -- what goes on an *edge*, not what a *node* looks
like.  The two meet only at the levels and the arm inks, which the shared
chrome keeps identical.
"""
from .page import document, fig, sw

TITLE = "The turn sign, so far"


def render(P):
    """Lay the turn-sign page out around the given figures."""
    body = f"""
<div class="sheet">

<header class="top">
  <p class="kicker">Partner work · rotation · the turn sign</p>
  <h1>The turn sign, so far</h1>
  <p class="standfirst">A leaning box that holds exactly one full turn. Rows are
  <b>quarter turns</b>, packed up from the foot, so an amount reads as fullness
  before it reads as a count. Columns are the lead's two arms; a pip's shape
  says whose quarter it is and its fill says that arm's level. Still open: the
  mark for <em>any amount</em>, and whether a sign that only labels edges is
  worth keeping once the frame pictures can animate the move itself.</p>
  <p class="sibling"><b>The frame picture is on its own page.</b> It settles
  what a held pair of hands looks like and what an orbit does to it; this page
  borrows its level fills and its two arm inks and nothing else.</p>
</header>

<section>
  <div class="head"><span class="n">Shared</span><h2>The fills it borrows</h2></div>
  <p>A pip's fill is the fill the hand it stands for would carry, so a sign and
  a frame picture never disagree about a level. The lead's shade is the deep one
  and the follow's the plain one, as on the frame page.</p>
  <div class="plate">
    <div class="key">
      {sw("none")}
      <span><b>hollow</b> — level unsaid</span>
      {sw("low")}
      <span><b>solid</b> — low, under the other arm</span>
      {sw("high")}
      <span><b>dot</b> — high, over the other arm</span>
      {sw("above")}
      <span><b>hatched</b> — above, over the head</span>
    </div>
  </div>
</section>

<section>
  <div class="head"><span class="n">One</span><h2>Quarters, and the sign becomes
  a gauge</h2></div>
  <p>Four rows will not fit the old sign, so it grows to
  <code>4 × 11 + 5 × 4 = 64</code> — and that is worth having rather than
  working around, because once the box is exactly a full turn the rows can
  <b>pack up from the foot</b> and the amount reads as how full it is. Counting
  the pips then confirms the reading instead of being the whole of it, which
  matters more at four than it did at two. Filling upward is also how a Laban
  staff is read.</p>

  <div class="plate">
    <h3>A quarter at a time</h3>
    <div class="row">
      {fig(P['q_lead_1'], 'lead · <b>¼</b>')}
      {fig(P['q_lead_2'], '<b>½</b>')}
      {fig(P['q_lead_3'], '<b>¾</b>')}
      {fig(P['q_lead_4'], '<b>1</b> turn')}
      {fig(P['q_foll_1'], 'follow · <b>¼</b>')}
      {fig(P['q_foll_2'], '<b>½</b>')}
      {fig(P['q_foll_3'], '<b>¾</b>')}
      {fig(P['q_foll_4'], '<b>1</b> turn')}
    </div>
    <p>At the size an edge label ends up, where the fullness has to do the work
    on its own:</p>
    <div class="row mid">
      {fig(P['q_lead_1_small'], '¼')}
      {fig(P['q_lead_2_small'], '½')}
      {fig(P['q_lead_3_small'], '¾')}
      {fig(P['q_lead_4_small'], '1')}
    </div>
  </div>

  <div class="plate">
    <h3>The alternative, for comparison</h3>
    <p>Spread evenly instead of packed, which is what the sign did when it held
    three. It still counts, but a quarter and three quarters no longer look
    different at a glance — the pip just moves rather than the sign filling.</p>
    <div class="row">
      {fig(P['u_lead_1'], 'spread · <b>¼</b>')}
      {fig(P['u_lead_3'], 'spread · <b>¾</b>')}
      {fig(P['q_lead_1'], 'packed · <b>¼</b>')}
      {fig(P['q_lead_3'], 'packed · <b>¾</b>')}
    </div>
  </div>

  <div class="plate">
    <h3>Whose quarter, which arm, at what height</h3>
    <p>Square for the lead and round for the follow; the column and the ink say
    which of the lead's arms, in the same order as the frame picture; the fill
    says that arm's level, on the follow's pips too, because the level belongs
    to the arm carrying the connection whoever is turning. An empty column is a
    hand that is not held.</p>
    <div class="row">
      {fig(P['s_split'], 'lead · <b>½</b><br>Left <b>low</b>, Right <b>high</b>')}
      {fig(P['s_acw'], 'lead · <b>¾</b><br>anticlockwise')}
      {fig(P['s_one_hand'], 'follow · <b>½</b><br>one hand, Left <b>low</b>')}
      {fig(P['s_above'], 'follow · <b>1</b><br>both <b>above</b>')}
      {fig(P['s_unsaid'], 'lead · <b>¼</b><br>levels unsaid')}
      {fig(P['s_lead_small'], 'lead · small')}
      {fig(P['s_foll_small'], 'follow · small')}
    </div>
  </div>

  <div class="note">
    <p><b>A knock-on from the frame page, not acted on.</b> The sign's two
    columns are the <em>lead's</em> arms. Now that the follow's hands carry their
    own sides, a blue column no longer unambiguously means the lead's Left — it
    means the arm that carries that connection, which the frame picture would now
    let you name from either end. Worth revisiting when the sign is redesigned;
    not worth churning the sign for on its own.</p>
    <p><b>One thing to watch at four rows.</b> A column repeats its level fill
    once per row, so a full turn on two hands is eight pips carrying two pieces
    of information. That redundancy was deliberate at two rows — any single row
    reads complete — but at four it is loud. If it reads as noise rather than
    reinforcement, the fix is to fill only the row nearest the foot and leave the
    rest as plain counters. Flagged rather than chosen.</p>
  </div>
</section>

<section>
  <div class="head"><span class="n">Two</span><h2>Mixed, with room to be
  uneven</h2></div>
  <p>And here is where quarters pay for themselves. Last round a mixed sign was
  stuck at half a turn each, and I said that fell out of the model — it did not.
  It fell out of there being three slots. At four, any split is drawable, with
  the follow's rows still on top.</p>
  <div class="plate">
    <div class="row">
      {fig(P['m_11'], '<b>¼</b> each<br>= ½ turn')}
      {fig(P['m_12'], 'follow <b>¼</b>, lead <b>½</b><br>= ¾ turn')}
      {fig(P['m_22'], '<b>½</b> each<br>= 1 turn')}
      {fig(P['m_31'], 'follow <b>¾</b>, lead <b>¼</b><br>= 1 turn')}
      {fig(P['m_22_small'], 'mixed · small')}
    </div>
    <p>The follow's rows always sit on top, so a mixed turn has one picture
    rather than two and there is nothing to read into the order.</p>
  </div>
</section>

<section>
  <div class="head"><span class="n">Three</span><h2>Five ways to say
  <em>any amount</em></h2></div>
  <p>Three rows is three quarters now, so <em>any</em> needs a mark of its own.
  I could not find a Labanotation convention for an indeterminate amount — turn
  signs there carry a measured degree — so this is not a borrowing, except for
  the fourth candidate, which takes music's <em>repeat ad libitum</em>. Each is
  drawn full size, small, and once for the follow, against a plain full turn for
  comparison.</p>

  <div class="plate pick">
    <h3>One — the box never closes<span class="tag">recommended</span></h3>
    <p>The lid is simply not drawn and the two long edges run on past where it
    would be. Nothing added, one stroke removed, and it composes exactly with the
    gauge: a box that never closes can never be full, so it cannot be read as a
    count. It is also the only candidate that costs nothing at small size,
    because what says it is the absence of a line rather than a new mark inside
    an already busy one.</p>
    <div class="row">
      {fig(P['any_full'], 'a plain <b>1</b> turn<br>for comparison')}
      {fig(P['any_open'], '<b>any</b> — open')}
      {fig(P['any_open_foll'], 'follow · <b>any</b>')}
      {fig(P['any_open_small'], 'small')}
    </div>
  </div>

  <div class="plate">
    <h3>Two — open, with the next one showing</h3>
    <p>The same, plus a fifth pip up in the run-on. Says "and it keeps going"
    rather than "and it stops being drawn", at the cost of a taller mark and one
    more thing in it.</p>
    <div class="row">
      {fig(P['any_spill'], '<b>any</b> — spilling')}
      {fig(P['any_spill_foll'], 'follow · <b>any</b>')}
      {fig(P['any_spill_small'], 'small')}
    </div>
  </div>

  <div class="plate">
    <h3>Three — an ellipsis in the top row</h3>
    <p>The box stays closed and the fourth row holds three dots per column
    instead of a pip: three quarters, and so on. Unmistakable at size; the three
    dots merge into one blob small, at which point it reads as a fourth pip.</p>
    <div class="row">
      {fig(P['any_ellipsis'], '<b>any</b> — ellipsis')}
      {fig(P['any_ellipsis_foll'], 'follow · <b>any</b>')}
      {fig(P['any_ellipsis_small'], 'small')}
    </div>
  </div>

  <div class="plate">
    <h3>Four — music's repeat mark</h3>
    <p>The ad-lib colon in the top row: play it as many times as you like. A real
    convention with a long history, and read instantly by anyone who reads music
    — which is not the same set as anyone who dances.</p>
    <div class="row">
      {fig(P['any_repeat'], '<b>any</b> — repeat')}
      {fig(P['any_repeat_foll'], 'follow · <b>any</b>')}
      {fig(P['any_repeat_small'], 'small')}
    </div>
  </div>

  <div class="plate">
    <h3>Five — the loop drawn on its own label</h3>
    <p>An arrow curling from the head back to the foot: the graph's loop edge,
    on the edge's own label. The most explicit of the five and the only one that
    says <em>why</em> the count does not end. It is also the widest, and the curl
    is the first thing to go small.</p>
    <div class="row">
      {fig(P['any_loop'], '<b>any</b> — loop')}
      {fig(P['any_loop_foll'], 'follow · <b>any</b>')}
      {fig(P['any_loop_small'], 'small')}
    </div>
  </div>
</section>

<section>
  <div class="head"><span class="n">Four</span><h2>On its own axis, or round
  the couple</h2></div>
  <p><b>Solid stays on the spot, dashed travels round the couple</b> — the same
  dash the frame page puts on an orbit's ring, and for the same reason: it is
  the mark for going round something. The frame page shows why the distinction
  has to live here rather than on a node: an orbit <em>lands</em> where an axis
  turn lands, so only the edge can tell them apart.</p>
  <div class="plate">
    <div class="row">
      {fig(P['o_axis'], 'on <b>axis</b>')}
      {fig(P['o_orbit'], 'on <b>orbit</b>')}
      {fig(P['o_orbit_acw'], 'follow · <b>orbit</b><br>anticlockwise')}
      {fig(P['o_axis_small'], 'axis · small')}
      {fig(P['o_orbit_small'], 'orbit · small')}
    </div>
  </div>
  <div class="note">
    <p><b>Still colliding with mixed signs.</b> The outline is one value and a
    mixed sign holds two dancers — the lead turning on the spot while the follow
    travels round them is ordinary, not a corner case. Putting it on the pips
    instead writes that case, at the cost of pulling each fill in off its
    outline so a dashed stroke has something to show against.</p>
    <div class="row mid">
      {fig(P['p_split'], 'follow <b>orbits</b>,<br>lead on <b>axis</b>')}
      {fig(P['p_split_small'], 'small')}
    </div>
  </div>
</section>

<div class="foot">
  <p><b>Still not in the app.</b> The rotation views came off the page on purpose
  and go back when the marks are settled and the ontology is finished.</p>
  <p>Yours to settle on this page: which <em>any</em> mark; whether orbit stays
  on the outline or moves to the pips; whether the level fill repeats down every
  row; whether the sign survives at all now that the frame pictures can animate
  the move; and the staff for a sequence.</p>
</div>

</div>
"""
    return document(TITLE, body)
