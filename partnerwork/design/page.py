"""The marks page itself: the prose, and where every figure sits in it.

Presentation only -- every claim a figure makes is generated and asserted
elsewhere, so this module is free to be nothing but the argument's layout.
"""
from .body import FREE, fill_of
from .style import INK
HEAD = """<meta charset="utf-8">
<title>The marks, so far</title>
<style>
:root {
  color-scheme: light dark;
  --paper: #fbfaf8; --card: #ffffff; --ink: #1a1a1a; --dim: #6b6660;
  --faint: #948d85; --rule: #ddd8d0; --rule-strong: #c2bbb0; --wash: #f1eee9;
  --left: #1f5fb4; --right: #b4541f; --block: #b3231b;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
  --sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --paper: #16151a; --card: #1e1d24; --ink: #ece9e4; --dim: #9a948c;
  --faint: #857f8e; --rule: #33313a; --rule-strong: #4a4754; --wash: #232128;
  --left: #6ba4ea; --right: #e8813f; --block: #f2685c; } }
:root[data-theme="dark"] { --paper: #16151a; --card: #1e1d24; --ink: #ece9e4;
  --dim: #9a948c; --faint: #857f8e; --rule: #33313a; --rule-strong: #4a4754;
  --wash: #232128; --left: #6ba4ea; --right: #e8813f;
  --block: #f2685c; }

* { box-sizing: border-box; }
body { margin: 0; padding: 2rem 1.25rem 5rem; background: var(--paper);
  color: var(--ink); font: 16px/1.6 var(--sans); }
.sheet { max-width: 62rem; margin: 0 auto; }
h1, h2, h3 { text-wrap: balance; }
.kicker { font: 500 0.7rem/1 var(--mono); letter-spacing: 0.18em;
  text-transform: uppercase; color: var(--dim); margin: 0; }
h1 { font-size: clamp(1.8rem, 5vw, 2.4rem); line-height: 1.05; margin: 0.7rem 0 0;
  letter-spacing: -0.025em; font-weight: 650; }
.top { border-bottom: 2px solid var(--ink); padding-bottom: 1.25rem;
  margin-bottom: 1.5rem; }
.standfirst { margin: 0.85rem 0 0; color: var(--dim); max-width: 42rem; }

section { margin: 2.75rem 0 0; }
.head { display: flex; align-items: baseline; gap: 0.8rem; flex-wrap: wrap;
  border-bottom: 1px solid var(--rule); padding-bottom: 0.6rem; }
.head .n { font: 600 0.72rem/1 var(--mono); letter-spacing: 0.14em;
  text-transform: uppercase; color: var(--faint); }
.head h2 { margin: 0; font-size: 1.3rem; letter-spacing: -0.015em; }
section > p { max-width: 44rem; }

.plate { border: 1px solid var(--rule); border-radius: 6px; background: var(--card);
  padding: 1.1rem 1.2rem 1.2rem; margin: 1.25rem 0 0; }
.plate.pick { border-color: var(--right); border-width: 1px 1px 1px 3px; }
.plate h3 { margin: 0 0 0.15rem; font-size: 1rem; }
.plate h3 .tag { font: 600 0.62rem/1 var(--mono); letter-spacing: 0.12em;
  text-transform: uppercase; color: var(--right); margin-left: 0.5rem; }
.plate p { font-size: 0.88rem; color: var(--dim); margin: 0.45rem 0 0;
  max-width: 46rem; }
.row { display: flex; gap: 1.15rem; margin: 1.1rem 0 0; flex-wrap: wrap;
  align-items: flex-end; }
.row.mid { align-items: center; }
figure { margin: 0; text-align: center; }
figcaption { font: 0.66rem/1.4 var(--mono); color: var(--faint); margin-top: 0.3rem; }
figcaption b { color: var(--ink); font-weight: 600; }
svg.f { display: block; width: 160px; height: 160px; }
svg.tiny { display: block; width: 84px; height: 84px; }
svg.wide { display: block; width: 152px; height: 152px; }
svg.mv { display: block; }
svg.still { display: none; }
@media (prefers-reduced-motion: reduce) {
  svg.moving { display: none; } svg.still { display: block; } }
table.states { border-collapse: collapse; margin: 1.1rem 0 0; font-size: 0.85rem;
  width: 100%; max-width: 34rem; }
table.states th, table.states td { text-align: left; padding: 0.35rem 0.8rem 0.35rem 0;
  border-bottom: 1px solid var(--rule); }
table.states th { font: 600 0.66rem/1.4 var(--mono); letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--faint); }
table.states td { color: var(--dim); }
table.states td:first-child { color: var(--ink); }
table.states .b { color: var(--left); font-weight: 650; }
table.states .o { color: var(--right); font-weight: 650; }

.key { display: grid; gap: 0.5rem 1rem; margin: 1.1rem 0 0;
  grid-template-columns: auto 1fr; align-items: center; font-size: 0.87rem; }
.key svg { display: block; }
.key span { color: var(--dim); }
.key b { color: var(--ink); font-weight: 620; }

.note { margin: 1.25rem 0 0; padding: 0.9rem 1.1rem; background: var(--wash);
  border-left: 3px solid var(--rule-strong); border-radius: 0 4px 4px 0;
  font-size: 0.89rem; }
.note p { margin: 0; color: var(--dim); }
.note p + p { margin-top: 0.5rem; }
.note b { color: var(--ink); }
.grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(15rem, 1fr));
  gap: 0 1.5rem; margin: 1.1rem 0 0; }
.grid2 p { margin: 0.3rem 0 0; }
code { font: 0.88em var(--mono); background: var(--wash); padding: 0.1em 0.35em;
  border-radius: 3px; }
.foot { margin-top: 3rem; padding-top: 1.25rem; border-top: 1px solid var(--rule);
  font-size: 0.9rem; color: var(--dim); }
.foot b { color: var(--ink); }
</style>
<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
  <pattern id="hL" width="3" height="3" patternTransform="rotate(45)" patternUnits="userSpaceOnUse">
    <line x1="0" y1="0" x2="0" y2="3" stroke="var(--left)" stroke-width="1.4"/>
  </pattern>
  <pattern id="hR" width="3" height="3" patternTransform="rotate(45)" patternUnits="userSpaceOnUse">
    <line x1="0" y1="0" x2="0" y2="3" stroke="var(--right)" stroke-width="1.4"/>
  </pattern>
</defs></svg>
"""


def sw(kind):
    """A swatch pair: the lead's square in its side, the follow's circle in its.

    The fills and the fade come from the same code the hands themselves use.
    A key that drew them its own way could drift from the figures it sits
    beside -- and had: it faded at 0.4 against the hands' 0.5.
    """
    faint = f' opacity="{FREE}"' if kind == "free" else ""
    out = ['<svg viewBox="0 0 36 16" width="36" height="16" aria-hidden="true">']
    for shape, arm, cx in (("rect", "L", 7), ("circle", "R", 28)):
        ink = INK[arm]
        fill = fill_of(kind, arm)
        if shape == "rect":
            out.append(f'<rect x="1" y="2" width="12" height="12" rx="1.5"'
                       f' fill="{fill}" stroke="{ink}" stroke-width="1.5"{faint}/>')
        else:
            out.append(f'<circle cx="28" cy="8" r="6" fill="{fill}"'
                       f' stroke="{ink}" stroke-width="1.5"{faint}/>')
        if kind == "high":
            out.append(f'<circle cx="{cx}" cy="8" r="2.7" fill="{ink}"/>')
    return "".join(out) + "</svg>"


def fig(svg, cap):
    return f'<figure>{svg}<figcaption>{cap}</figcaption></figure>'


def render(P):
    """Lay the whole page out around the given figures."""
    def moving(who, cap):
        """The turning figure, with a still one behind it for reduced motion."""
        a = P[f"mv_{who}"].replace('class="mv"', 'class="mv moving"', 1)
        b = P[f"mv_{who}_still"]
        return f'<figure>{a}{b}<figcaption>{cap}</figcaption></figure>'

    body = f"""
<div class="sheet">

<header class="top">
  <p class="kicker">Partner work · rotation · the marks</p>
  <h1>The marks, so far</h1>
  <p class="standfirst">Each dancer is a circle with a small chevron at its
  centre for the facing, and their arms run along the rim rather than across
  the body — which makes an arm a measure of how far round the hand has been
  carried. A move animates in two stages: travel, then turn the world until
  <b>the lead faces up</b> again. That second stage collapses every pose that
  is the same configuration onto one picture, and shows that an orbit lands
  where an axis turn lands. Still open: which way a wrap should go round, and
  the turn sign's mark for <em>any amount</em>.</p>
</header>

<section>
  <div class="head"><span class="n">Settled</span><h2>Level, on the hands</h2></div>
  <p>The fill says level, and <b>the break in the under-arm stays</b> — it
  reinforces the shading rather than repeating it, and it is the mark that
  survives node size when a fill will not. What has changed underneath is the
  ink: each hand is now in its own side's colour, so the swatches come in pairs
  rather than in one hue.</p>
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
  <div class="head"><span class="n">One</span><h2>Circles, arms along the
  rim</h2></div>
  <p><b>The body is a plain circle, and the facing is a small chevron at its
  centre</b> — the one part of a dancer nothing else uses, since the rim is the
  arms and it breaks for the hands. The chevron turns with its dancer, for the
  lead and the follow alike.</p>
  <p><b>An arm is the boundary, not a line on it.</b> The edge of a body is
  drawn <em>once</em>, in stretches at one width: each arm in its own colour
  from the front — where the two arms meet, under the chevron's direction —
  round to its hand, and the back quiet. Every stretch stops short of every
  hand mark, the same clearance the reach keeps, so nothing on the boundary
  runs through a mark. And an arm is inked only while its hand is part of a
  connection — <b>no connection, no line</b> — so an open couple is two quiet
  outlines with four faded hands, and nothing else.</p>
  <p><b>The reach wraps, and it prefers the front.</b> It starts on the edge of
  the hand's own mark, not at its centre, and where the straight way to the
  partner would pass through a body it runs <em>along the rim</em> instead — to
  the first place it can leave on a tangent, then straight, then along the
  other rim to the other hand. A way that sets off round a dancer's back pays a
  penalty against one that crosses their front, because a crossed hold crosses
  the chest — but it is a bias, not a rule, and the choice is still open; the
  comparison below draws both. In the moving figures every frame is routed the
  same way and keeps the same way round from the frame before, so the line
  wraps and unwraps rather than sweeping through a body to the other side.</p>
  <p><b>The lead always faces up.</b> That is what the second stage of a move
  now aims at — not standing the pair upright, but standing the <em>lead</em>
  upright. Everything is read from them, so they hold still and where the follow
  has got to becomes part of what the picture says rather than something the
  framing throws away.</p>
  <p>An orbit goes round the <em>other dancer</em>, so a dashed ring appears
  only while one is happening, centred on whoever is standing still: the lead,
  the follow, or the midpoint when both travel. Nothing else in the picture is
  dashed. Losing the old centre ring cost nothing — crossed against parallel is
  geometric now, and the colour pair at a link's two ends says which hands are
  joined either way.</p>

  <div class="plate">
    <h3>At rest, no ring</h3>
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
    <h3>An arm is also a measure</h3>
    <p>Because the arm runs along the rim, its length says how far round the
    body the hand has been carried — which is what a wrap or a lock <em>is</em>.
    At rest each arm covers a quarter of the rim. Wind it further and the arc
    grows, and past half the rim there is no body left to go round, so it turns
    red. The threshold is a guess and the mapping from winding to twist is
    yours; what is settled is that the picture can hold the quantity at all.</p>
    <div class="row">
      {fig(P['wind_0'], 'at rest<br>a quarter of the rim')}
      {fig(P['wind_1'], 'the Left arm<br>wound 45°')}
      {fig(P['wind_2'], 'wound 90°<br>— half the rim')}
      {fig(P['wind_3'], 'wound 135°<br>— past it')}
    </div>
  </div>

  <div class="plate">
    <h3>Which way round a wrap goes<span class="tag">open</span></h3>
    <p>The follow a quarter turned, holding <em>Left to left</em>: the two
    ways round their body are nearly the same length, and the shortest by a
    whisker rounds their back. The routing now prefers the front — a penalty
    on the back way, one constant (<code>BACK_BIAS</code>), not a rule — so a
    near-tie crosses the chest, while a hold that genuinely belongs behind the
    back (back to back, say) still goes there. Both readings are drawn because
    the weighting is still yours to settle.</p>
    <div class="row">
      {fig(P['wrap_front'], 'preferring <b>the front</b><br>— the current bias')}
      {fig(P['wrap_short'], 'the <b>shortest</b> way<br>— round the back')}
    </div>
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
    <p>Checked rather than claimed — the generator asserts the two relative
    facings are equal, and refuses to build if they are not.</p>
    <p><b>So axis against orbit is a property of the move, not of the state.</b>
    The node never needs to know; only the edge does. Which is why the two
    stages are worth animating: the difference is a path, and only a path can
    show it. It also settles the turn sign's dash — it is describing an edge,
    and the sign labels edges, so it survives.</p>
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
    <p>The line keeps the lead's arm ink — that is what says which arm does the
    work. So the pair of colours at its two ends says <b>which named hands are
    joined</b>: <em>Left to left</em> is blue-to-blue whoever faces where, and
    whether it runs across says whether it is crossed now.</p>
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
    greying, and the arm lines cover the case grey would have broken.</p>
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

<section>
  <div class="head"><span class="n">Two</span><h2>Quarters, and the sign becomes
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
    <p>Unchanged. Square for the lead and round for the follow; the column and
    the ink say which of the lead's arms, in the same order as the frame picture;
    the fill says that arm's level, on the follow's pips too, because the level
    belongs to the arm carrying the connection whoever is turning. An empty
    column is a hand that is not held.</p>
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
    <p><b>A knock-on from the section above, not acted on.</b> The sign's two
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
  <div class="head"><span class="n">Three</span><h2>Mixed, with room to be
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
  <div class="head"><span class="n">Four</span><h2>Five ways to say
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
  <div class="head"><span class="n">Five</span><h2>On its own axis, or round
  the couple</h2></div>
  <p>Unchanged: <b>solid stays on the spot, dashed travels round the couple</b>,
  borrowing the dash every frame picture already draws down the middle for the
  couple's centre line — which is what an orbit goes around.</p>
  <div class="plate">
    <div class="row">
      {fig(P['o_axis'], 'on <b>axis</b>')}
      {fig(P['o_orbit'], 'on <b>orbit</b>')}
      {fig(P['o_orbit_acw'], 'follow · <b>orbit</b><br>anticlockwise')}
      {fig(P['f_over'], 'the centre line<br>the dash is borrowed from')}
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
  and go back when the marks are settled and the ontology is finished. The frame
  pictures are unchanged either way — the break stays, and the hand-to-hand half
  leaves its levels unsaid.</p>
  <p>Yours to settle: which <em>any</em> mark; whether orbit stays on the outline
  or moves to the pips; whether the level fill repeats down every row; the bow
  for contact and the staff for a sequence; what an orbit stores; and when an arm
  above the head blocks.</p>
</div>

</div>
"""
    return HEAD + body
