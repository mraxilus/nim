"""The frame page: what a held pair of hands looks like, and how it moves.

Presentation only -- every claim a figure makes is generated and asserted
elsewhere, so this module is nothing but the argument's layout.  The turn sign
is a separate exploration on a separate page; see `sign_page.py`.
"""
from .page import document, fig, sw
from .parts import SETTLINGS

TITLE = "The frame, so far"


def render(P):
    """Lay the frame page out around the given figures."""
    def moving(who, cap):
        """The turning figure, with a still one behind it for reduced motion."""
        a = P[f"mv_{who}"].replace('class="mv"', 'class="mv moving"', 1)
        b = P[f"mv_{who}_still"]
        return f'<figure>{a}{b}<figcaption>{cap}</figcaption></figure>'

    settlings = "".join(fig(P[f"settle_{k}"], text)
                        for k, (_, _, text) in enumerate(SETTLINGS))

    body = f"""
<div class="sheet">

<header class="top">
  <p class="kicker">Partner work · rotation · the frame</p>
  <h1>The frame, so far</h1>
  <p class="standfirst">Each dancer is a plain circle with a small chevron at
  its centre for the facing. A connection runs hand to hand as a taut string
  that wraps a body rather than crossing it, drawn in <b>its two hands' own
  colours</b>, meeting at the middle. <b>A settled hand is in one of six
  places</b> — its own side or the other one, and on that side a little
  towards the front, a little towards the back, or where the arm hangs — and
  which one is decided by the hold's level and by whether it locks or wraps.
  A move animates in two stages: travel, then turn the world until <b>the lead
  faces up</b> again. That second stage collapses every pose that is the same
  configuration onto one picture, and shows that an orbit lands where an axis
  turn lands. And <b>only an <em>above</em> connection may ever cross a
  body</b> — at every instant a moving picture draws, not merely at the frames
  it is sampled at.</p>
  <p class="sibling"><b>The turn sign is on its own page.</b> It answers a
  different question — how to label an <em>edge</em> — and only meets this one
  at the levels and the arm inks, which the two pages share.</p>
</header>

<section>
  <div class="head"><span class="n">Settled</span><h2>Level, and whose hand it
  is</h2></div>
  <p>The fill says level, and <b>the break in the under-arm stays</b> — it
  reinforces the shading rather than repeating it, and it is the mark that
  survives node size when a fill will not. Each hand is in its own side's
  colour, and in its owner's shade of it: the lead's squares deep, the follow's
  circles plain. So the swatches come in pairs, and a pair is a whole hold.</p>
  <div class="plate">
    <div class="key">
      {sw("free")}
      <span><b>faded</b> — nobody is holding this hand</span>
      {sw("none")}
      <span><b>full, hollow</b> — held, level unsaid</span>
      {sw("low")}
      <span><b>solid</b> — low, under the other arm</span>
      {sw("high")}
      <span><b>dot</b> — high, over the other arm</span>
      {sw("above")}
      <span><b>hatched</b> — above, over the head</span>
    </div>
    <div class="row">
      {fig(P['f_none'], 'held<br><b>no level</b>')}
      {fig(P['f_low'], '<b>low</b>')}
      {fig(P['f_high'], '<b>high</b>')}
      {fig(P['f_above'], '<b>above</b>')}
      {fig(P['f_over'], 'Left <b>high</b>, Right <b>low</b><br>and the break says it too')}
    </div>
  </div>
</section>

<section>
  <div class="head"><span class="n">One</span><h2>Circles, and a line that
  wraps</h2></div>
  <p><b>The body is a plain circle, and the facing is a small chevron at its
  centre.</b> The rim says nothing but <em>here is a body</em>: it is drawn
  once, quiet, at one width, and it breaks around every hand mark so nothing on
  the boundary runs through one. It used to fill up in an arm's colour as that
  arm wound round — a progress ring going the long way round the outside — and
  that is gone. <b>The wrap on the connection is the indicator</b>, and one
  indicator is enough.</p>
  <p><b>The reach wraps, and by default it takes the short way.</b> It starts
  on the edge of the hand's own mark, not at its centre, and where the straight
  way to the partner would pass through a body it runs <em>along the rim</em>
  instead — to the first place it can leave on a tangent, then straight, then
  along the other rim to the other hand. That hug <em>is</em> the wrap: the arm
  going round a body is the thing a lock is made of. Nothing prefers the front
  any more; with nothing said, the line simply takes the shorter way round.</p>
  <p><b>A whole move goes one way round.</b> Which side of each body the line
  passes is settled once, before the first frame is drawn, and every frame of
  that move uses it — the way that every frame can actually be routed, and the
  shortest of those. Not a preference: a rule, and the note below says what it
  is guarding against.</p>
  <p><b>The line is its two hands' own colours.</b> Each half is exactly the
  mark it ends on — the lead's in their arm's ink and the deep shade, the
  follow's in theirs and the plain one, the two meeting at the middle. So
  <em>Left to right</em> is drawn blue-to-orange along its whole length rather
  than only at two marks that vanish at node size, and the shade still says
  which end is the lead's when both hands share a hue.</p>
  <p><b>The lead always faces up.</b> That is what the second stage of a move
  aims at — not standing the pair upright, but standing the <em>lead</em>
  upright. Everything is read from them, so they hold still and where the follow
  has got to becomes part of what the picture says rather than something the
  framing throws away.</p>
  <p>An orbit goes round the <em>other dancer</em>, so a dashed ring appears
  only while one is happening, centred on whoever is standing still: the lead,
  the follow, or the midpoint when both travel. Nothing else in the picture is
  dashed.</p>

  <div class="plate">
    <h3>At rest, no ring</h3>
    <p>Which column a hand sits in is decided by which way its owner faces, so
    a row read across is that dancer's orientation and the four facings are
    distinct without a new mark.</p>
    <div class="row">
      {fig(P['or_open_0'], 'face to face')}
      {fig(P['or_open_1'], 'the follow<br>faces away')}
      {fig(P['or_open_2'], 'the lead<br>faces away')}
      {fig(P['or_open_3'], 'back to back')}
    </div>
    <div class="row">
      {fig(P['or_held_0'], 'holding <em>Left to left</em>')}
      {fig(P['or_tiny_1'], 'node size')}
    </div>
  </div>

  <div class="plate">
    <h3>A settled hand is in one of six places</h3>
    <p><b>Nothing is solved and nothing is asked for.</b> A hand at rest sits
    in one of six slots, and which one is decided by three things and no
    others: the hand's own side, the level of the hold it is part of, and
    whether that hold is a <b>lock</b> or a <b>wrap</b>. The six are the two
    sides, and on each side a place a little towards the front, a little
    towards the back, or where the arm hangs. A picture seen from overhead has
    no height to spend, so <em>above</em> and <em>below</em> are drawn as that
    small offset round the rim.</p>
    <div class="row mid">
      {fig(P['slot_chart'], 'the six, on one body<br>— the four a Left hand uses, in its ink')}
      <figure><table class="slots">
        <tr><th></th><th>Left hand</th><th>Right hand</th></tr>
        <tr><td>no level, or no way said</td><td>left · side</td><td>right · side</td></tr>
        <tr><td><em>high</em> lock</td><td>left · above</td><td>right · above</td></tr>
        <tr><td><em>high</em> wrap</td><td>right · above</td><td>left · above</td></tr>
        <tr><td><em>low</em> wrap</td><td>right · above</td><td>left · above</td></tr>
        <tr><td><em>low</em> lock</td><td>right · below</td><td>left · below</td></tr>
        <tr><td><em>above</em> — as <em>high</em></td><td>left / right · above</td><td>right / left · above</td></tr>
      </table></figure>
    </div>
    <p><b>Lock or wrap is state the hold carries</b>, and it has to be: the six
    slots cannot be chosen without it. A hold that names a level but not which
    of the two it is leaves its hands where the arm hangs — knowing the height
    does not tell you which side the hand went to, so the picture does not
    guess. Here is that, and the four settlings a <em>Left to left</em> hold
    can reach:</p>
    <div class="row">{settlings}</div>
    <p>Discrete at rest, but not discrete in between: a move that changes a
    hold slides its hands from one slot to the next, so the six are where a
    picture <em>settles</em>, not a set of places it jumps between.</p>
  </div>

  <div class="plate">
    <h3>Only <em>above</em> passes through — and what that turned out to
    mean<span class="tag">a finding</span></h3>
    <p>A connection has to go round a body, because a body is in the way. The
    exception is <b><em>above</em>, which is over the head</b>: from overhead
    there is nothing under it — no head, no torso — so it is drawn straight
    across whatever it crosses. It is the one level that names a height, and
    that is what the height buys.</p>
    <p>A <b>wrap</b> is what puts a body in the way: it carries the hand round
    to the far side, so the line has to get there somehow. At <em>low</em> it
    goes round. At <em>above</em> it goes over — same hold, same slot, and the
    only difference is that one of them may cross.</p>
    <div class="row">
      {fig(P['wrap_low'], '<em>low</em> wrap<br>— round the body')}
      {fig(P['wrap_above'], '<em>above</em> wrap<br>— straight over it')}
    </div>
  </div>

  <div class="note">
    <p><b>And in a moving picture, at every instant — not just at the frames.</b>
    A browser draws the states between two sampled frames by blending them
    point by point, so two neighbouring frames that disagree about which side
    of a body the line goes round are drawn, in between, as a line sweeping
    <em>through</em> that body. Which is what was happening: measured, the
    worst of it reached <b>19.9</b> units into a body of radius <b>20</b> — the
    line passed through the centre. The routes at each frame were all clean,
    which is why a check that looked only at those said nothing was wrong.</p>
    <p>The fix is to settle the way round <em>once for a whole move</em>,
    before any of it is routed, so no two frames can disagree. That is
    stronger than the counter-rotation preference it replaces, and the
    preference, its bias constant and the frame-to-frame hysteresis all came
    out with it. The check now samples the blend between every pair of frames,
    with the bodies interpolated too, and the worst incursion anywhere is
    <b>0.15</b> — under a fifth of a unit, well under a drawn pixel.</p>
  </div>

  <div class="plate">
    <h3>An orbit, in two stages</h3>
    <p><b>Stage one</b>: the follow walks the ring round the lead, who stands
    still — so the pair's axis tilts away from upright, which the old picture
    could not show at all. <b>Stage two</b>: the whole drawing turns until the
    <em>lead faces up</em> again. The follow does not have to come back overhead;
    where they have got to is part of what the picture says.</p>
    <p>Here the follow keeps their face to the lead all the way round:</p>
    <div class="row mid">
      {fig(P['walk_locked_0'], 'rest')}
      {fig(P['walk_locked_1'], 'stage one —<br>walking round')}
      {fig(P['walk_locked_2'], 'a quarter round')}
      {fig(P['walk_locked_3'], 'stage two —<br>the world turns')}
      {fig(P['walk_locked_4'], 'home')}
    </div>
    <p>And here they keep their own bearing instead, arriving facing the way
    they set off. Same path, different move, different place to land:</p>
    <div class="row mid">
      {fig(P['walk_drift_0'], 'rest')}
      {fig(P['walk_drift_1'], 'stage one')}
      {fig(P['walk_drift_2'], 'a quarter round')}
      {fig(P['walk_drift_3'], 'stage two')}
      {fig(P['walk_drift_4'], 'home')}
    </div>
  </div>

  <div class="plate pick">
    <h3>What that shows<span class="tag">the point</span></h3>
    <p>Once stage two has run, the picture holds two numbers and nothing else,
    both measured against the lead: <em>where</em> the follow is round from them,
    and <em>how</em> the follow faces. Every rotation moves those two — and
    <b>an orbit lands where an axis turn lands</b>. A follow who walks a quarter
    round the lead keeping their face to them arrives at exactly the state the
    lead reaches by turning a quarter on the spot. Not similar: the same, which
    is why both pictures below have the follow off to one side.</p>
    <div class="row">
      {fig(P['collapse_orbit'], 'the follow walked<br>a quarter round')}
      {fig(P['collapse_axis'], 'the lead turned<br>a quarter on the spot')}
    </div>
    <p>Checked rather than claimed — the generator asserts the two are the same
    drawing, mark for mark, and refuses to build if they are not.</p>
    <p><b>So axis against orbit is a property of the move, not of the state.</b>
    The node never needs to know; only the edge does. Which is why the two
    stages are worth animating: the difference is a path, and only a path can
    show it. It also settles the turn sign's dash on the other page — the dash
    is describing an edge, and the sign labels edges, so it survives.</p>
  </div>

  <div class="plate">
    <h3>Moving<span class="tag">it runs here</span></h3>
    <p>Four moves, each a full cycle: go, come home, go back, come home — so it
    returns to exactly where it started rather than snapping. Watch what the new
    rule does to the first one: <b>a lead turning on the spot now has plenty to
    bring home</b>, because their facing has to come back up — so stage two
    swings the follow round them. It is the <em>follow</em> turning that would
    have nothing to do in stage two. Both dancers going round each other comes
    home to the picture it left, though on the floor they have travelled.</p>
    <div class="row">
      {moving('lead_axis', 'the lead turns<br>on their own axis')}
      {moving('follow_orbits_the_lead', 'the follow orbits<br>the lead')}
      {moving('the_lead_orbits_the_follow', 'the lead orbits<br>the follow')}
      {moving('both_round_each_other', 'both, round each other<br>— a picture no-op')}
    </div>
  </div>

  <div class="plate">
    <h3>What the pair of colours at the two ends says</h3>
    <p>The line is now the pair itself: it starts in the lead's hand's ink and
    ends in the follow's, so it <em>draws</em> <b>which named hands are
    joined</b> rather than leaving it to two marks. <em>Left to left</em> is
    blue all the way, <em>Left to right</em> runs blue into orange, whoever
    faces where — and whether it crosses says whether the hold is crossed now.
    The deep half is always the lead's, so the reading survives a hold turned
    round, and survives both hands sharing a hue.</p>
    <div class="row">
      {fig(P['pair_ll'], '<b>Left to left</b><br>blue to blue · crossed')}
      {fig(P['pair_ll_turned'], 'follow turned<br>still blue to blue · not crossed')}
      {fig(P['pair_lr'], '<b>Left to right</b><br>blue to orange · not crossed')}
      {fig(P['pair_lr_turned'], 'follow turned<br>still blue to orange · crossed')}
    </div>
  </div>

  <div class="plate">
    <h3>A free hand keeps its hue</h3>
    <p>Grey said <em>not held</em>, but colour carries orientation and
    <code>open</code> is four free hands. So a free hand fades rather than
    greying, and there is no line to cover the case grey would have broken.</p>
    <div class="row">
      {fig(P['free_fade'], 'faded')}
      {fig(P['free_grey'], 'grey')}
      {fig(P['free_fade_tiny'], 'faded · node size')}
      {fig(P['free_grey_tiny'], 'grey · node size')}
    </div>
  </div>

  <div class="note">
    <p><b>The couple rotation is a picture no-op, and that is correct.</b> Both
    dancers going round each other changes nothing the drawing holds — which is
    exactly what the model says: a rotation of the whole couple stores no twist.
    It is still a real thing on the floor, and the picture is honest about not
    tracking it: what it draws is the couple, not the room.</p>
    <p><b>Two dancers turning half a turn each still collides.</b> The four
    orientations are two bits and <code>twist</code> is one, its parity, so
    <code>isFacing(twist)</code> cannot tell face to face from back to back. The
    two relative facings this picture is now built on are exactly the pair
    <code>rotation.nim</code> would need.</p>
    <p><b>Knock-on, flagged not acted on.</b> Static frames keep a square
    <code>120 × 120</code> box; the moving ones are given a box fitted to
    everything they touch, which is why they are not all the same size — they
    are all at the same scale instead. <code>frameHeight</code>, the matrix
    cells and the map nodes still assume the old <code>100 × 116</code>.</p>
  </div>
</section>

<div class="foot">
  <p><b>Still not in the app.</b> The rotation views came off the page on purpose
  and go back when the marks are settled and the ontology is finished. The frame
  pictures are unchanged either way — the break stays, and the hand-to-hand half
  leaves its levels unsaid.</p>
  <p>Yours to settle on this page: <b>whether the slot table above is right</b>
  — four of its rows came straight from you, the Right hand's column is those
  mirrored side-for-side, and <em>above</em> was extended to settle where
  <em>high</em> does, so the last two are mine and may be wrong;
  <code>SLOT_OFFSET</code>, how far round the rim <em>above</em> and
  <em>below</em> sit, which is a drawn convention and nothing the dance says;
  the bow for contact with the body; what an orbit stores; and when an arm
  above the head blocks.</p>
</div>

</div>
"""
    return document(TITLE, body)
