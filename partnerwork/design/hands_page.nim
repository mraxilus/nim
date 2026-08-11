## Lay out the hand-to-hand turns page: three positions, and the box.
##
##   The second of one mock-up per kind of turn (rule 15), and the dual of
##     the first.  A single hand turns for ever, so its wind is not part of
##     its state and its orientation is all of it (rule 16); hold both hands
##     and a whole turn puts every orientation back where it was, so the
##     wind is all of it instead -- one turn each way, and rule 12's three
##     positions.
##   What a wound pair looks like is rule 27's: two crossovers, one by each
##     dancer, with a box between them.
##     Cost of a drawn convention: nothing in the geometry makes those two
##       crossings -- two straight reaches between these hands do not cross
##       at all.  Accepted, and flagged on the page as the rule's own
##       reading rather than something the drawing derived.

{.experimental: "strictFuncs".}

import std/[strformat, tables]

import ./[page, parts]


const TITLE* = "Hand-to-hand turns, so far"


const WINDING: array[TurnWay, string] = [
  "The follow turns a whole circle where they stand. Nobody travels and " &
    "nothing needs bringing back afterwards, so this is the plainest of " &
    "the four: one stage, and the arms wind as it goes.",
  "The lead turns a whole circle on the spot. <b>Stage one</b> is the " &
    "turn with the room held still; <b>stage two</b> brings the picture " &
    "back to the lead facing up, which swings the follow round them and " &
    "leaves the wind exactly where the turn put it.",
  "The follow walks a whole circle round the lead, keeping their own " &
    "bearing the whole way — the dashed ring says who is standing still. " &
    "Going all the way round winds the arms just as turning on the spot " &
    "does, which is not obvious until you watch it.",
  "The lead walks the whole circle instead, and lands on the same box. " &
    "It is the one way of the four that takes the lead off their spot, so " &
    "it is the one whose second stage has anything to do: a straight " &
    "slide home, since an orbit that keeps its bearing has no turning to " &
    "undo.",
] ## What each way of turning does to a pair, in this page's terms.
  ##   Not `WAYS_OF_TURNING`'s own blurbs: those speak of a single hand
  ##     coming round, and here the orientation is exactly what returns.


func plates(P: Parts): string =
  ## Lay out the four ways of turning, each winding the pair both ways.
  for way in TurnWay:
    let w = WAYS_OF_TURNING[way]
    result.add &"""<div class="plate"><h3>{w.title}</h3>"""
    result.add &"<p>{WINDING[way]}</p>"
    result.add """<p>A whole turn each way, rocking between the frame and
      the box it winds into, so the winding reads in both directions:</p>"""
    result.add """<div class="row mid">"""
    for i, winding in [1, -1]:
      let
        moving = P[&"hw_{w.tag}_{i}"].replaceFirst(
          "class=\"mv\"", "class=\"mv moving\"")
        still = P[&"hw_{w.tag}_{i}_still"]
        landed = if winding > 0: CHAIN[2].name else: CHAIN[0].name
      result.add &"<figure>{moving}{still}<figcaption>frame &rarr; " &
        &"<b>{landed}</b></figcaption></figure>"
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
  is pointing is all of it. Hold both and it is the other way about: a
  <b>whole turn</b> puts every facing and every place back exactly where it
  was, so the pointing says nothing and <b>the wind is the state</b>. One
  turn each way, and that is three positions.</p>
  <p class="sibling"><b>The crossed pair comes next</b>, on its own page,
  and all three go together once each is right.</p>
</header>

<section>
  <div class="head"><span class="n">What is here</span><h2>Three positions,
  a whole turn apart</h2></div>
  <p><b>The middle one is the app's own frame</b>, drawn exactly as the app
  draws it: two connections running side by side, crossing nothing. Wind the
  pair a whole turn either way and you reach one of the two ends. There is
  no fourth: winding on from an end is out of this scope, and a half turn
  lands the couple back to front, which is a picture this chain does not
  count.</p>
  <p><b>A wound pair makes a diamond.</b> Two arms wound round each other
  cross <em>twice</em> — once by the lead and once by the follow — and what
  the two crossings enclose is the shape these positions are named for. Each
  connection runs its own side clear of the body it leaves, swings the whole
  way over to its partner's side, and swings back, the two of them at their
  widest apart in the middle: not a four-square box but a diamond, coming to
  a point at each crossover. <b>The two crossings say opposite things</b>:
  whichever
  connection is over at the lead's end is under at the follow's, because
  that is what being wound together means — two crossings the same way round
  would be one arm lying on another and no twist at all.</p>
  <p><b>The names are preliminary and yours.</b> <em>Left over Right box</em>
  is the end where the lead's Left connection passes over the Right at the
  lead's own crossover; <em>Right over Left box</em> is its mirror. The two
  boxes are the same shape and differ only in what they keep on top, which
  is the whole of what winding one way rather than the other does.</p>
  <p><b>What the geometry does not give.</b> Two straight lines between
  these four hands never cross, whatever the pair has wound, because a whole
  turn leaves every hand exactly where it found it. So unlike the crossing
  on the single-hand page, <b>the box is drawn rather than derived</b> — it
  is this page's convention for saying what the arms are doing, and it is
  the first mark here that the geometry does not make by itself.</p>
</section>

<section>
  <div class="head"><span class="n">The chain</span><h2>The three, in
  order</h2></div>
  <p>Every one of the four ways of turning reaches these same three, so they
  are drawn once rather than four times over. Which way was danced is not
  something a position can say — only the path can, which is why all four
  are animated below.</p>
  <div class="row mid">
    {chain}
  </div>
</section>

{plates}

<div class="note">
  <p><b>A moving reach carries no break.</b> The over-and-under is in the
  still pictures and not in the animations: a reach is morphed point by
  point between frames, and cutting a gap in it mid-move would change how
  many pieces it is drawn in from one frame to the next, which is the one
  thing the morph cannot do. So a transition shows the arms winding and the
  box forming, and the still it lands on says which arm ended up on top.
  Same shape of exemption as a settled reach bending round the marks while a
  moving one passes straight across.</p>
  <p><b>What is not drawn:</b> the half turn. It is danced through — every
  transition here passes across it — but the couple is back to front there,
  and this chain counts whole turns. Whether the back-to-back picture
  deserves a position of its own is yours to settle.</p>
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
      chain.add P["g_whole"]
    chain.add fig(P[&"hh_{i}"], &"<b>{position.name}</b><br>{position.note}")
  document(TITLE, BODY.filled(@[("chain", chain), ("plates", plates(P))]))
