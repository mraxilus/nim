## Lay out the hand-to-hand turns page: seven positions, a half turn apart.
##
##   The second of one mock-up per kind of turn (rule 15), and the dual of
##     the first.  A single hand turns for ever, so its wind is not part of
##     its state and its orientation is all of it (rule 16); hold both hands
##     and a whole turn puts every orientation back where it was, so the
##     wind is all of it instead -- a turn and a half each way, by halves.
##   And the same chain the crossed pair walks, read half a turn along: a
##     hold is unwound where its two connections run parallel, and that
##     falls at a different facing for each of the two (rule 31).
##   What a wound pair looks like is rule 27's: two crossovers, one by each
##     dancer, with a box between them.
##     Cost of a drawn convention: nothing in the geometry makes those two
##       crossings -- two straight reaches between these hands do not cross
##       at all.  Accepted, and flagged on the page as the rule's own
##       reading rather than something the drawing derived.

{.experimental: "strictFuncs".}

import std/[strformat, tables]

import ./[page, parts, pose]


const TITLE* = "Hand-to-hand turns, so far"


const WINDING: array[TurnWay, string] = [
  "The follow turns half a circle where they stand, and the pair winds " &
    "half a turn with them. Nobody travels and nothing needs bringing back " &
    "afterwards, so this is the plainest of the four: one stage, and the " &
    "arms wind as it goes.",
  "The lead turns half a circle on the spot. A lead's turn winds the pair " &
    "the opposite way to a follow's, so to take the <em>same</em> step of " &
    "the chain they turn the other way round — turning both the same " &
    "way sent this row off the end of the chain and drew a second diamond. " &
    "<b>Stage one</b> is the turn with the room held still; <b>stage two</b> " &
    "brings the picture back to the lead facing up, which swings the follow " &
    "round them and leaves the wind exactly where the turn put it.",
  "The follow walks half a circle round the lead, keeping their own " &
    "bearing \u2014 the dashed ring says who is standing still. <b>It winds " &
    "nothing.</b> A walker who keeps their bearing never turns relative to " &
    "their partner, so the pair arrives on the far side in exactly the " &
    "state it set off in.",
  "The lead walks the half circle instead, and it winds nothing either. " &
    "It is the one way of the four that takes the lead off their spot, so " &
    "it is the one whose second stage has anything to do: a straight slide " &
    "home, since an orbit that keeps its bearing has no turning to undo.",
] ## What each way of turning does to a pair, in this page's terms.
  ##   Not `WAYS_OF_TURNING`'s own blurbs: those speak of a single hand
  ##     coming round, and here the orientation is exactly what returns.


func plates(P: Parts): string =
  ## Lay out the four ways of turning, each walking every edge of the chain.
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    result.add &"""<div class="plate"><h3>{w.title}</h3>"""
    result.add &"<p>{WINDING[way]}</p>"
    result.add """<p>Every edge of the chain, each rocking between its two
      ends so the half turn reads both ways:</p>"""
    result.add """<div class="row mid">"""
    for i in 0 ..< CHAIN.len - 1:
      let
        moving = P[&"hw_{w.tag}_{i}"].replaceFirst(
          "class=\"mv\"", "class=\"mv moving\"")
        still = P[&"hw_{w.tag}_{i}_still"]
        landed = if w.about == About.Axis: &"<b>{CHAIN[i + 1].name}</b>"
                 else: "carried, not wound"
      result.add &"<figure>{moving}{still}<figcaption>{CHAIN[i].name}" &
        &"<br>&rarr; {landed}</figcaption></figure>"
    result.add "</div></div>"


const BODY = """

<div class="sheet">

<header class="top">
  <p class="kicker">Partner work · rotation · hand-to-hand turns</p>
  <h1>Hand-to-hand turns, so far</h1>
  <p class="standfirst">Both hands held, uncrossed — the lead's Left in the
  follow's right, the lead's Right in the follow's left — and both arms
  carried <b>above</b>, as everything in this scope is. <b>This page is the
  single-hand page turned inside out.</b> One hand held above turns for
  ever, so how far it has wound is not part of its state and where the pair
  is pointing is all of it. Hold both and it is the other way about: a whole
  turn puts every facing and every place back exactly where it was, so the
  pointing says nothing and <b>the wind is the state</b>. A turn and a half
  each way, by halves: seven positions.</p>
  <p class="sibling"><b>The crossed pair comes next</b>, on its own page —
  and it is <em>this</em> chain, read half a turn along, so what is left is
  to draw it.</p>
</header>

<section>
  <div class="head"><span class="n">What is here</span><h2>Seven positions,
  a half turn apart</h2></div>
  <p><b>The middle one is the app's own frame</b>, drawn exactly as the app
  draws it: two connections running side by side, crossing nothing. Each
  half turn from there winds the pair one step further, and the chain runs
  out at a turn and a half each way.</p>
  <p><b>Which way the partners face follows from the wind</b>, so the
  captions leave it out and it is said once here: <b>face to face</b> at a
  whole number of turns — the frame and the diamonds — and <b>both facing
  one way</b> at a half — the X's and the swans.</p>
  <p><b>A half turn makes an X.</b> The partners end up facing the same way,
  and the two connections cross once overhead — the plain crossing the app
  already uses for a crossed pair, with the over-and-under break saying
  which arm is on top. <b>A whole turn makes a diamond</b>: the pair crosses
  <em>twice</em>, once by the lead and once by the follow, and what the two
  crossings enclose is the shape rule 27 named. <b>The two crossings say
  opposite things</b> — whichever connection is over at the lead's end is
  under at the follow's, because that is what being wound together means.</p>
  <p><b>A turn and a half makes a swan</b>, and it is where the pair stops
  being symmetric. Wound that far the two arms cannot both keep swinging:
  one pulls taut and runs straight through the middle while the other wraps
  it, over and under and over, in two long loops — the necks of two mating
  swans round a straight neck between them, which is the picture and the
  name. It crosses three times, and it is emphatically <em>not</em> two
  diamonds stacked; that drawing was refused (rule 30) and this is what
  replaced it.</p>
  <p><b>Nothing here is imposed.</b> How far a pair has wound is
  <em>measured</em>: each held hand sits on its own body's rim and both
  bodies stand on the pair's axis, so the angle a hand makes with that axis
  is what going round means, and the difference between the two ends is the
  wind. A reach is then just the shadow of a wound arm from above — its
  offset from the axis swinging as far round as the pair has. Straight at
  none, an X at a half, a diamond at a whole, and every frame in between
  following from the same measure, which is what stops a turn snapping into
  its final shape.</p>
  <p><b>Only two of the four ways of turning wind anything.</b> An orbit
  that keeps its bearing turns nobody: the walker never turns relative to
  their partner, so a half orbit arrives on the other side of the lead in
  exactly the state it set off in. <b>The axis turns walk this chain; the
  orbits carry the pair around it.</b> An earlier draft of this page claimed
  all four wound the pair, which was only true because all four had been
  told to.</p>
  <p><b>The names are preliminary and yours.</b> <em>Left over Right</em> is
  the position where the lead's Left connection passes over the Right at the
  lead's own crossover; <em>Right over Left</em> is its mirror. The X, the
  diamond and the swan a step apart share a name because they are the same
  winding, carried further.</p>
</section>

<section>
  <div class="head"><span class="n">One chain</span><h2>Both patterns, half
  a turn apart</h2></div>
  <p><b>Hand to hand and the crossed pair are the same chain.</b> A hold has
  one position where its two connections run parallel and cross nothing —
  and that position sits at a different <em>facing</em> for each of them.
  Hand to hand is parallel with the partners <b>face to face</b>; hold left
  to left and right to right instead and it is parallel with one of them
  <b>facing away</b>, which on this page's chain is half a turn along. Every
  step after that is the same step: X, diamond, swan, out to a turn and a
  half each way.</p>
  <p><b>So the phase is measured, not written down.</b> The build turns the
  follow to each candidate and asks which one leaves the hold unwound, using
  the same measure everything else here uses. This page comes out at nothing;
  the crossed pair will come out at a half turn, and it will be this code
  with a different hold rather than a second drawing of the same idea.</p>
  <p><b>What this settles</b> is rule 13's <em>"the two sides with an extra
  arm twist, in either direction"</em>. That extra twist was thought to
  belong to the crossed pair alone. It does not: it is the swan, and hand to
  hand has one at each end too.</p>
</section>

<section>
  <div class="head"><span class="n">The chain</span><h2>The three, in
  order</h2></div>
  <p>Both ways of winding reach these same seven, so they are drawn once
  rather than twice over. Which dancer turned is not something a position
  can say — only the path can, which is why every way is animated below,
  including the two that turn out to wind nothing.</p>
  <div class="row mid">
    {chain}
  </div>
</section>

{plates}

<div class="note">
  <p><b>A moving crossing says which arm is on top, the same as a still
  one.</b> It cannot say it the same way: a still reach is cut into pieces
  at the break, and how many pieces that makes changes with the number of
  crossings — which is the one thing a morph cannot follow. So a moving
  reach keeps its single piece and wears the break as a <em>dash</em>
  instead, travelling with the crossing and closing to nothing where there
  is no crossing to mark. Watch a whole turn wind on and you can see the
  break appear at a hand and slide inward as the crossing does.</p>
  <p><b>What is not drawn:</b> anything past a turn and a half. The swans
  are the ends of the chain and they hold — no frame of any animation is
  wound further, and no position anywhere draws two diamonds stacked. Which
  way a turn goes is chosen for it: whichever way walks the chain
  <em>inward</em>, measured per way rather than assumed. The chain runs out
  where this scope does, not where the dance does — a pair can keep
  winding, and what lies past the swan is yours to settle.</p>
</div>

<div class="foot">
  <p><b>Still not in the app.</b> Same standing as the other pages: the app
  keeps drawing the eight frames and nothing else until the marks are
  settled.</p>
  <p>Yours to settle on this page: whether <em>box</em> is the word, and
  whether the two ends should be named for the lead's crossover as they are
  here or for the whole shape; how wide the box should open; and whether an
  edge should carry the turn sign, which was built for exactly this job.</p>
</div>

</div>
"""


func render*(P: Parts): string =
  ## Lay the hand-to-hand turns page out around the given figures.
  var chain: string
  for i, position in CHAIN:
    if i > 0:
      chain.add P["g_half"]
    chain.add fig(P[&"hh_{i}"], &"<b>{position.name}</b><br>{position.note}")
  document(TITLE, BODY.filled(@[("chain", chain), ("plates", plates(P))]))
