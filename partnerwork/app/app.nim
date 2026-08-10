## Drive the partner-work ontology from a browser, as a check on the model.
##
##   The page is a validator before it is a toy: it shows the frame the couple
##     is in, every frame one primitive away, and every frame that is *not*,
##     with the number of primitives it would take to get there.  Nothing
##     outside the offered list can be clicked, so a move the ontology does not
##     derive cannot be danced.
##   Only the rendering lives here.  The frames and the moves come from
##     `partnerwork`, unchanged, so the page cannot quietly disagree with the
##     tests.
##   Every change of state regenerates the markup from the session state,
##     rather than patching the pieces that changed.
##     Cost of regenerating per interaction: the element under the reader's
##       finger is destroyed with the rest and the browser drops focus to the
##       document, so keyboard standing has to be saved and restored by hand --
##       `holding` and `standAgain` pay it, and `paintStage` narrows a move's
##       redraw so an animation is not rebuilt out from under itself.
##   What the model has to say about the spreadsheet it was read from is not
##     here and should not be: it is a finding about a document rather than a
##     fact about two bodies, it is true whether or not anyone is dancing, and
##     a reader who wants it wants to read it rather than click through it.  It
##     lives in `doc/review.html`, which is written from the same model, and in
##     `nimble audit`.

{.experimental: "strictFuncs".}

import std/[options, strutils]
import std/dom except Frame ## Exclude the browser's own `Frame`, which is a window.

import ../src/partnerwork



#[ Session ]#

type
  View {.pure.} = enum ## Select what the page is showing.
    Atlas,  ## Every frame there is, which is what the ontology *is*.
    Dance,  ## One frame at a time, and what can be done from it.
    Matrix  ## Every move there is, as one table.

  Vis {.pure.} = enum ## Select how the frame is drawn while dancing.
    Dynamic,  ## The frame in the middle and every way out of it.
    Overview  ## The whole ontology, with the couple somewhere in it.

  Filter = object ## Narrow the list of frames to the ones worth looking at.
    holds: Option[int]   ## Number of connections, where that is being asked for.
    lead: Option[Side]   ## Hand of the lead that must be holding something.
    follow: Option[Site] ## Hand of the follow that must be held.

  Step = object ## Hold one danced move, for the history.
    phrase: string
    to: Frame


func startFrame(): Frame =
  ## Get the frame the dance opens in: nothing held.
  ##   Where a couple starts, and the one frame nothing has to lead up to.
  ##   A reader who opens the Dance view without first picking a frame in the
  ##     atlas used to be put down in a one-hand hold, in the middle of the
  ##     ontology, with no account of how they got there.
  ##   From here every way out is a collect, which is the ladder seen from the
  ##     bottom of it.
  fromKey("--.").get


var
  origin = startFrame()
  current = startFrame()
  view = View.Atlas
  vis = Vis.Dynamic
  vis_chosen = false        ## Whether the reader has picked a drawing themselves.
  filter = Filter()
  history: seq[Step] = @[]
  motion = Motion.Still     ## What the drawings are doing at this instant.
  taken = none(Frame)       ## Frame being moved to, while the couple are leaving.
  queued = none(Frame)      ## Second move of a compound, waiting for the first.
  generation = 0            ## Which move is in flight, so an older one can be dropped.


func tempoOf(vis: Vis): Tempo =
  ## Get how long the drawing on show takes to say a move.
  ##   The page waits on whichever drawing the dancer is actually watching.
  ##   The close drawing has to clear its ways out and build the next lot; the
  ##     map has every frame in place already and only has to move the mark.
  ##   Making the map keep the close drawing's time would leave it finished and
  ##     waiting, which reads as the page having stopped rather than as a move
  ##     being made.
  case vis
  of Vis.Dynamic: CLOSE_TEMPO
  of Vis.Overview: WIDE_TEMPO


proc holding(): string =
  ## Remember which control the reader is standing on, before it is replaced.
  ##   Every change of state rewrites the page, so the element under the
  ##     reader's finger is deleted and the browser drops focus to the document.
  ##   For a pointer that costs nothing; for a keyboard it means the next key
  ##     does nothing at all, which on a page whose whole claim is that what it
  ##     refuses is meaningful is a refusal that means nothing.
  let on = document.activeElement
  if on == nil or on.getAttribute("data-action") == nil:
    return ""
  $on.getAttribute("data-action") & " " & $on.getAttribute("data-value")


proc standAgain(held: string) =
  ## Put the reader back where they were standing, or on the frame if it moved.
  if held.len == 0:
    return
  let
    parts = held.split(' ')
    sought = document.querySelector(cstring("[data-action=\"" & parts[0] &
      "\"][data-value=\"" & parts[1] & "\"]"))
  if sought != nil:
    sought.focus()
    return
  # The control is gone because taking it changed the frame.  Land on the frame
  # itself rather than on whatever move now sits where that button was: a key
  # pressed again should not dance a move nobody chose.
  let stage = document.getElementById("stage")
  if stage != nil:
    stage.focus()


proc say(sentence: string) =
  ## Tell a reader who cannot see the drawing what the drawing now shows.
  ##   The live region lives outside the part of the page that is rewritten,
  ##     because a live region that is itself replaced announces nothing: the
  ##     browser has no old text to compare the new text against.
  let voice = document.getElementById("said")
  if voice != nil:
    voice.textContent = cstring(sentence)


proc atOnce(): bool =
  ## Test whether the reader has asked for no movement.
  ##   A reader who has turned animation off should not be made to wait out an
  ##     animation that is not running: every phase collapses into the one
  ##     change of state that the phases were spelling out.
  window.matchMedia("(prefers-reduced-motion: reduce)").matches


proc roomForMap(): bool =
  ## Test whether the screen has room to draw the map at a legible size.
  ##   Asked of the stylesheet rather than answered here.
  ##     Which widths are wide is a question about the layout, and the layout
  ##       is written there: the answer is the map's own least width plus the
  ##       margins the page is laid out with, and a copy of that sum kept in
  ##       the script would be a second thing to change and a second thing to
  ##       get wrong.
  ##   This is the mirror of `motion.nim`, which owns the times and writes them
  ##     out for the stylesheet to spend.
  ($window.getComputedStyle(document.documentElement)
    .getPropertyValue("--wide")).strip() == "1"


proc setScrollLeft(e: Node; value: int) {.importcpp: "#.scrollLeft = #", nodecl.}
  ## Set how far a scrolling box is scrolled; `std/dom` only reads it.


proc centreOnHeld() =
  ## Slide the close drawing so the frame being held is the part you can see.
  ##   The drawing is cut to the frame, and the widest frame is wider than a
  ##     phone: `open` fans four ways out and wants 728 pixels.
  ##   Left where the browser puts a scrolling box, a narrow screen shows the
  ##     left edge of that fan and not the frame the whole view is about.
  ##   Nothing is unreachable either way -- every way out is a button in the
  ##     list beside the drawing -- so this is only about what you are looking
  ##     at when you arrive.
  let
    scroller = document.querySelector(".view-spokes .scroll")
    held = document.querySelector(".view-spokes .core")
  if scroller == nil or held == nil:
    return
  let
    room = scroller.getBoundingClientRect()
    on = held.getBoundingClientRect()
    off = (on.left + on.width / 2) - (room.left + room.width / 2)
  setScrollLeft(scroller, scroller.scrollLeft + int(off))


proc suitVis() =
  ## Open in whichever drawing the screen has room for.
  ##   The map says more and only wants width; the close drawing is the one
  ##     that survives a phone.
  ##   So the page follows the screen -- and stops the moment the reader picks
  ##     a drawing, because a choice made is worth more than a default, and a
  ##     window dragged narrower should not take it back.
  if not vis_chosen:
    vis = if roomForMap(): Vis.Overview else: Vis.Dynamic



#[ Markup ]#

func esc(text: string): string =
  ## Escape text for placement in markup.
  text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))


func tag(name, attributes, body: string): string =
  ## Wrap a body in one element, with attributes already formed.
  "<" & name & (if attributes.len > 0: " " & attributes else: "") & ">" & body &
    "</" & name & ">"


func button(action, value, classes, body: string): string =
  ## Form a button carrying the action the page should take when it is clicked.
  tag("button", "class=\"" & classes & "\" data-action=\"" & action &
    "\" data-value=\"" & esc(value) & "\"", body)



#[ Dance View ]#

func renderMoves(source: Frame): string =
  ## List what can be danced from here: every move, then every named compound.
  ##   A compound is offered as one button because a lead leads it as one
  ##     thing, and taking it dances both of its moves in turn rather than
  ##     jumping the frame in between.
  ##   It is grouped and counted apart from the moves so that the page never
  ##     says two things are one.
  let available = moves(source)
  var rows = ""
  var previous = ""
  for move in available:
    let helper = $move.helper
    if helper != previous:
      rows.add tag("h4", "", esc(helper.toLowerAscii) & " &mdash; " &
        esc(manner(move.helper)))
      previous = helper
    rows.add button("move", move.to.key, "move",
      tag("span", "class=\"phrase\"", esc(phrase(source, move))) &
      tag("span", "class=\"target\"", esc(move.to.describe)))
  var shortcuts = ""
  for target in FRAMES:
    let named = compound(source, target)
    if named.isNone:
      continue
    let steps = route(source, target)
    var spelled = ""
    for step in steps:
      if spelled.len > 0:
        spelled.add " &rarr; "
      spelled.add esc(step.helper.name)
    shortcuts.add button("compound", target.key, "move two",
      tag("span", "class=\"phrase\"", esc(compoundPhrase(source, target))) &
      tag("span", "class=\"target\"", esc(target.describe) & " &middot; " &
        spelled))
  if shortcuts.len > 0:
    shortcuts = tag("h4", "", "two moves, led as one") & shortcuts
  tag("section", "class=\"panel\"",
    tag("h3", "", "available now &middot; " & $available.len & " moves") &
    rows & shortcuts)


func renderElsewhere(source: Frame): string =
  ## List every frame that is not one primitive away, and the way to it.
  ##   This half of the panel is what makes the page a validator: a frame here
  ##     can be seen but not danced, and the route says exactly what is missing.
  ##   Named a step at a time, in the words the moves panel uses for the same
  ##     move.
  ##     `collect, then collect` is the shape of an answer rather than an
  ##       answer: from `open` it was what all three frames two moves away
  ##       said, so the panel gave the same seven words for three different
  ##       places, while four collects sat unlabelled above it -- two of which,
  ##       for any one of those places, lead away from it rather than towards
  ##       it.
  ##     The route always knew which two; it was throwing the answer away and
  ##       printing only its shape.
  var rows = ""
  var count = 0
  for target in FRAMES:
    if target == source or classify(source, target).isSome or
        compound(source, target).isSome:
      continue
    inc count
    var detail = ""
    # Each step is named against the frame it departs from, because that is the
    # frame it is a move out of.  It happens to read the same named from here --
    # a drop is the only phrase that looks at the frame it leaves, and no
    # shortest route drops a hand it collected, so a hand a route drops was held
    # before the route began.  `tests/ttransition.nim` holds both of those, so
    # this is written the way it is true rather than the way it is convenient.
    var standing = source
    for step in route(source, target):
      detail.add tag("span", "class=\"step\"",
        esc(phrase(standing, step)) & tag("i", "", esc(step.to.describe)))
      standing = step.to
    rows.add tag("div", "class=\"far\"",
      tag("span", "class=\"phrase\"", esc(target.describe)) &
      tag("span", "class=\"target\"", $route(source, target).len & " moves") &
      detail)
  tag("section", "class=\"panel muted\"",
    tag("h3", "", "not from here &middot; " & $count) & rows)


func renderHistory(danced: seq[Step]): string =
  ## Show the sequence danced so far, with the ways back out of it.
  var rows = ""
  for index in countdown(danced.high, 0):
    rows.add tag("li", "", esc(danced[index].phrase) & " &rarr; " &
      esc(danced[index].to.describe))
  tag("section", "class=\"panel\"",
    tag("h3", "", "danced &middot; " & $danced.len) &
    button("undo", "", "flat", "undo") & button("reset", "", "flat", "reset") &
    # Newest first, because that is the end you are dancing from -- and numbered
    # from the far end, so "1." is the first move danced rather than the last.
    tag("ol", "class=\"history\" reversed", rows))


func renderVisSwitch(vis: Vis): string =
  ## Show the choice between the two drawings.
  var tabs = ""
  for candidate in Vis:
    let classes = if candidate == vis: "tab on" else: "tab"
    tabs.add button("vis", $candidate, classes, esc($candidate))
  tag("div", "class=\"tabs small\"", tabs)


func renderArms(): string =
  ## Say which ink is which arm, and how a hand says whose it is.
  ##   Nothing in the ontology says *whose* hand it means, because the case
  ##     says it: `Left` is the lead's and `left` is the follow's, in a frame's
  ##     name and in a move's alike.
  ##   A reader who has not been told that once cannot read anything else on
  ##     the page, so the drawing tells them here.
  var swatches = ""
  for side in Side:
    swatches.add tag("span", "class=\"swatch\"",
      "<i class=\"arm-" & (if side == Side.Left: "left" else: "right") & "\"></i>" &
      "the lead's " & esc(leadName(side)) & " arm")
  swatches.add tag("span", "class=\"swatch aside\"",
    "&ldquo;Left&rdquo; is the lead's hand, &ldquo;left&rdquo; the follow's")
  tag("div", "class=\"legend\"", swatches)


func renderKey(): string =
  ## Say what the picture of a frame is a picture of.
  ##   Every view is built on it, and until now nothing anywhere said that it
  ##     is the couple seen from above, which row is whose, or what the dashed
  ##     line down the middle is.
  ##   A reader who has not been told cannot read the frames, the names, the
  ##     matrix or the map -- so it is said once, next to the first drawing
  ##     they meet, in the fewest words that will do it.
  tag("p", "class=\"key\"",
    "Seen from above: the lead along the bottom in squares, the follow along " &
    "the top in circles, and the dashed line between them is the couple's " &
    "midline. A filled hand is one being held; a line with a gap in it passes " &
    "under the other.")


func renderSpokesView(current: Frame; motion: Motion;
    taken: Option[Frame]): string =
  ## Draw where the couple are and every way out, and nothing else.
  tag("div", "class=\"view-spokes\"",
    tag("div", "class=\"scroll\"", renderSpokes(current, motion, taken)) &
    tag("p", "class=\"note\"", "The frame in the middle is the one being held. " &
      "Every spoke is a way out of it and nothing else is drawn. A collect " &
      "takes a hand so it points up, a drop releases one so it points down, " &
      "and a compound is two moves so it goes out to the side, inked in both " &
      "the arms it hands a hand between. Take a spoke and it becomes the " &
      "middle."))


func renderMapView(current: Frame; motion: Motion; taken: Option[Frame]): string =
  ## Draw where the couple stand in the whole ontology.
  tag("div", "class=\"view-map\"",
    tag("div", "class=\"scroll\"", renderMap(some(current), motion, taken)) &
    tag("p", "class=\"note\"", "Each row holds one more connection than the row " &
      "below, so a line up the page is a collect and a line down is a drop. " &
      "A line you are standing on is named for the move away from you, which is " &
      "the one you could make; a line you are not is named for the move that " &
      "runs up it. A dashed curve is a compound, and is inked in both " &
      "arms because it hands a hand from one of them to the other: the ink at " &
      "each end is the arm that acts on the way to it. The frames you can " &
      "reach from where you stand come forward and the rest go quiet, and the " &
      "ring moves along the line you take. A frame ringed in a solid line is " &
      "one move away and a dashed one is a compound, two moves away; both can " &
      "be clicked, and a compound dances its two moves in turn."))


func renderStageBody(current: Frame; vis: Vis; motion: Motion;
    taken: Option[Frame]): string =
  ## Show the frame the couple hold, drawn the way the dancer has asked for.
  ##   The name shown is the frame being *left* until the move lands, because
  ##     the drawing is still showing that frame: a heading that changed before
  ##     the picture did would name something nobody can see.
  let drawing =
    case vis
    of Vis.Dynamic: renderSpokesView(current, motion, taken)
    of Vis.Overview: renderMapView(current, motion, taken)
  tag("div", "class=\"stage-head\"",
    tag("h3", "", "frame") & tag("h2", "", esc(current.describe)) &
    renderVisSwitch(vis) & renderArms()) &
    renderKey() & tag("div", "class=\"views\"", drawing)


func renderDance(current: Frame; vis: Vis; motion: Motion;
    taken: Option[Frame]; danced: seq[Step]): string =
  ## Show the current frame, what it allows, and what it does not.
  tag("div", "class=\"stage\"",
    tag("section", "class=\"panel wide\" id=\"stage\" tabindex=\"-1\"",
      renderStageBody(current, vis, motion, taken)) &
    renderMoves(current) & renderElsewhere(current) & renderHistory(danced))



#[ Atlas View ]#

func admits(narrowing: Filter; target: Frame): bool =
  ## Test whether a frame answers everything the dancer has asked to see.
  ##
  ## Every question left unasked admits everything, and the asked ones are read
  ## together: a dancer looking for a two-handed frame that uses the lead's left
  ## wants both to be true of the same frame.
  if narrowing.holds.isSome and target.countHolds != narrowing.holds.get:
    return false
  if narrowing.lead.isSome and not target.usesHand(narrowing.lead.get):
    return false
  if narrowing.follow.isSome and not target.isHeld(narrowing.follow.get):
    return false
  true


func chip(action, value, label: string; chosen: bool): string =
  ## Offer one answer to one question, marked when it is the one in force.
  button(action, value, (if chosen: "chip on" else: "chip"), esc(label))


func renderFilters(narrowing: Filter): string =
  ## Ask the three questions that narrow the gallery: how many, whose, which.
  var holds = chip("holds", "any", "any", narrowing.holds.isNone)
  for count in 0 .. 2:
    holds.add chip("holds", $count, $count & (if count == 1: " hand" else: " hands"),
      narrowing.holds == some(count))
  var lead = chip("lead", "any", "either", narrowing.lead.isNone)
  for side in Side:
    lead.add chip("lead", $side, leadName(side), narrowing.lead == some(side))
  var follow = chip("follow", "any", "either", narrowing.follow.isNone)
  for site in Site:
    follow.add chip("follow", $site, followName(site), narrowing.follow == some(site))
  tag("div", "class=\"filters\"",
    tag("div", "class=\"question\"", tag("span", "class=\"asks\"", "connections") & holds) &
    tag("div", "class=\"question\"",
      tag("span", "class=\"asks\"", "lead's hand holds") & lead) &
    tag("div", "class=\"question\"",
      tag("span", "class=\"asks\"", "follow's hand held") & follow))


func renderGallery(narrowing: Filter): string =
  ## Show every frame as its own picture, and let one of them be started from.
  ##   A name is a claim about a frame; the picture is the frame.
  ##   Showing both means the vocabulary can be read off the drawing rather
  ##     than trusted, which is the same reason the review page carries the
  ##     pictures too.
  var cards = ""
  var shown = 0
  for target in FRAMES:
    if not narrowing.admits(target):
      continue
    inc shown
    let ways = moves(target).len
    cards.add button("start", target.key, "card",
      renderFrame(target) &
      tag("span", "class=\"phrase\"", esc(target.describe)) &
      tag("span", "class=\"target\"", $ways & " moves &middot; " &
        $target.countHolds & (if target.countHolds == 1: " hand" else: " hands")))
  tag("div", "class=\"stage\"", tag("section", "class=\"panel wide\"",
    tag("h3", "", "every frame &middot; " & $shown & " of " & $FRAMES.len) &
    renderArms() & renderKey() &
    renderFilters(narrowing) &
    tag("p", "class=\"note\"", "Click a frame to begin the dance from it.") &
    (if shown == 0:
      tag("p", "class=\"note\"", "No frame holds all three of those at once.")
    else:
      tag("div", "class=\"gallery\"", cards))))


#[ Matrix View ]#

const
  HELPER_GLYPHS: array[Helper, string] = [
    Helper.Collect: "&uarr;",
    Helper.Drop: "&darr;",
  ] ## Point a primitive the way every other drawing points it.
    ##   A collect adds a connection and a drop takes one away, and both the
    ##     map and the close drawing say that by direction: up the page for a
    ##     collect, since a collect builds the frame up, and down for a drop.
    ##   A cell that said `c` and `d` made the reader learn the same fact a
    ##     second way.
  COMPOUND_GLYPHS: array[Compound, string] = [
    Compound.Place: "&#8644;",
    Compound.Cut: "&times;",
  ] ## Draw a compound as what it does: a place hands a hand across, a cut
    ## crosses one arm over the other.


func toneOf(side: Side): string =
  ## Name the custom property holding the ink of one of the lead's arms.
  if side == Side.Left: "var(--left)" else: "var(--right)"


func cell(classes, tone, told, body: string): string =
  ## Form one cell of the matrix, inked and named for what it says.
  ##   The ink is carried as a property rather than a class because the thing a
  ##     cell varies by is which arm dances it, and that is one value, not a
  ##     set of states the stylesheet has to enumerate.
  tag("td", "class=\"" & classes & "\" style=\"--tone: " & tone & "\"" &
    (if told.len > 0: " title=\"" & esc(told) & "\"" else: ""), body)


func renderMark(kind, tone, glyph: string): string =
  ## Draw the mark a cell carries, in the ink of the arm that dances it.
  tag("span", "class=\"tile " & kind & "\" style=\"--tone: " & tone & "\"", glyph)


func renderMarks(): string =
  ## Show what each mark in the matrix means, drawn as the matrix draws it.
  ##   The old legend spelled the four letters out in a sentence, which asked
  ##     the reader to hold a code in their head while they read a grid.
  ##   Drawn, the legend and the cell are the same thing seen twice.
  var items = ""
  for helper in Helper:
    items.add tag("span", "class=\"swatch\"",
      renderMark("one", "var(--dim)", HELPER_GLYPHS[helper]) & helper.name)
  for named in Compound:
    items.add tag("span", "class=\"swatch\"",
      renderMark("two", "var(--dim)", COMPOUND_GLYPHS[named]) &
      ($named).toLowerAscii & ", two moves")
  tag("div", "class=\"legend\"", items)


func renderCrosshair(across: int): string =
  ## Write the rules that light the column under the pointer.
  ##   A row lights itself, because a row is one element; a column is not, so
  ##     it takes one rule per column and the count of them is a fact about the
  ##     model.
  ##   Written here it cannot fall out of step with how many frames there are,
  ##     and a gridless table needs it: without lines to follow, the whole
  ##     difficulty of an eight-by-eight is knowing which column you are in.
  result = "<style>"
  for column in 2 .. across + 1:
    result.add ".matrix:has(td:nth-child(" & $column & "):hover) " &
      ":is(th, td):nth-child(" & $column & ") { background: var(--cross); }"
  result.add "</style>"


func renderMatrix(): string =
  ## Show every move there is, as one chart.
  ##   Its own view, because it answers a different question from the gallery.
  ##     The gallery is what the frames *are*, one picture each, and is where a
  ##       reader starts; the matrix is what joins them, all sixty-four pairs
  ##       at once, and is what you consult once you know what a frame is.
  ##     Under one heading the table was a wall below the pictures that nobody
  ##       scrolled to.
  ##   Drawn rather than tabulated, for the reason the gallery is: a frame's
  ##     name is a claim about it and its picture is the frame, so the axes
  ##     carry the pictures and a reader can check the vocabulary instead of
  ##     trusting it.
  ##     A cell carries the move's direction as a mark and the lead's arm as
  ##       its ink, which is the vocabulary the map already uses, so the same
  ##       three facts are said the same way wherever the page says them.
  ##   Every pair is answered.
  ##     A pair no primitive joins used to be blank, which is half the chart
  ##       saying nothing; it now carries how many moves apart the two frames
  ##       are, which is the question a blank cell provokes.
  ##   Both axes run down the tower, taking their order from the drawing that
  ##     owns it, so that reading the matrix top to bottom and reading the map
  ##     top to bottom are the same reading.
  ##     Down the tower every collect runs from a row to a column *earlier*
  ##       than it and every drop the other way, so the two primitives fall
  ##       either side of the diagonal and the compounds -- which change what
  ##       is held without changing how much -- fall in the blocks on it.
  ##     The structure is then in the picture rather than in the paragraph
  ##       under it.
  ##   What the source spreadsheet has and has not got is not marked here.
  ##     Which cells its author has filled in is a fact about a document being
  ##       written, not about two bodies, and the app is the ontology:
  ##       `doc/review.html` says it, at length and in order, which is how it
  ##       wants to be read.
  let order = towerOrder()
  # A band opens wherever the tower steps down a row, and the gap that marks it
  # has to fall in the same place down the rows as it does across the columns.
  var opens: seq[bool] = @[]
  for index, target in order:
    opens.add index > 0 and order[index - 1].countHolds != target.countHolds
  var head = tag("th", "class=\"corner\"",
    tag("span", "class=\"axis\"", "to &rarr;") &
    tag("span", "class=\"axis\"", "from &darr;"))
  for index, target in order:
    head.add tag("th", "class=\"head" & (if opens[index]: " gap" else: "") &
      "\" title=\"" & esc(target.describe) & "\"",
      renderFrame(target) & tag("span", "class=\"who\"", esc(target.brief)))
  var body = ""
  for down, source in order:
    let step = if opens[down]: " top" else: ""
    # The same picture down the side as across the top, so a reader following a
    # row never has to count columns back to find out what they are reading.
    # It fits beside the name now that the name is short, and it is legible at
    # that size now that the lead's hands are squares: whose row is whose is in
    # the marks, where before it was only in captions too small to read.
    var row = tag("th", "class=\"row" & step & "\" title=\"" &
      esc(source.describe) & "\"",
      tag("span", "class=\"who\"", esc(source.brief)) & renderFrame(source))
    for across, target in order:
      let
        edge = (if opens[across]: " gap" else: "") & step
        helper = classify(source, target)
        named = compound(source, target)
      if source == target:
        row.add cell("self" & edge, "var(--rule-strong)", source.describe,
          tag("span", "class=\"tile here\"", ""))
      elif helper.isSome:
        let move = Move(helper: helper.get, to: target,
          side: actingSide(source, target, helper.get))
        row.add cell("one" & edge, toneOf(move.side), phrase(source, move),
          tag("span", "class=\"tile one\"", HELPER_GLYPHS[move.helper]))
      elif named.isSome:
        row.add cell("two" & edge, toneOf(compoundSide(source, target).get),
          compoundPhrase(source, target),
          tag("span", "class=\"tile two\"", COMPOUND_GLYPHS[named.get]))
      else:
        let far = route(source, target).len
        row.add cell("away" & edge, "var(--faint)",
          (if far > 0: $far & " moves apart" else: ""),
          (if far > 0: $far else: ""))
    body.add tag("tr", "", row)
  tag("div", "class=\"stage\"",
    tag("section", "class=\"panel wide\"",
      tag("h3", "", "derived transition matrix") &
      renderMarks() & renderArms() & renderKey() &
      tag("div", "class=\"scroll\"", renderCrosshair(order.len) &
        tag("table", "class=\"matrix\"",
          tag("thead", "", tag("tr", "", head)) & tag("tbody", "", body))) &
      tag("p", "class=\"note\"", "A cell is the move from its row to its " &
        "column, inked in the arm of the lead that dances it. The frames are " &
        "ordered down the tower, the same way the map stacks them, so every " &
        "collect falls below the diagonal and every drop above it, and the " &
        "compounds &mdash; " &
        "which change what is held without changing how much &mdash; fall in " &
        "the blocks along it. A faded number is a pair no single move joins, " &
        "and is how far apart they are.")))



#[ Page ]#

func renderControls(view: View): string =
  ## Show the view switches.
  var views = ""
  for candidate in View:
    let classes = if candidate == view: "tab on" else: "tab"
    views.add button("view", $candidate, classes, esc($candidate))
  tag("header", "", tag("h1", "", "partner work") & tag("div", "class=\"tabs\"", views))


proc paintStage() =
  ## Draw the frame and its ways out again, and nothing else on the page.
  ##   A move changes only the drawing.
  ##   Leaving the lists alone keeps the button under the pointer from being
  ##     rebuilt out from under it, and keeps the page from being laid out
  ##     again in the middle of an animation.
  let stage = document.getElementById("stage")
  if stage == nil:
    return
  let held = holding()
  stage.innerHTML = cstring(renderStageBody(current, vis, motion, taken))
  standAgain(held)
  centreOnHeld()


proc render() =
  ## Draw the whole page from the session state.
  let body =
    case view
    of View.Dance: renderDance(current, vis, motion, taken, history)
    of View.Atlas: renderGallery(filter)
    of View.Matrix: renderMatrix()
  let held = holding()
  document.getElementById("app").innerHTML = cstring(renderControls(view) & body)
  standAgain(held)
  centreOnHeld()


proc arrive(target: Frame) =
  ## Stand in the frame a move reached, and remember the way there.
  for move in moves(current):
    if move.to != target:
      continue
    history.add Step(phrase: phrase(current, move), to: move.to)
    current = move.to
    say(history[^1].phrase & ". Now " & current.describe & ", with " &
      $moves(current).len & " moves out of it.")
    return


proc dance(key: string)


proc leadOn() =
  ## Take the second move of a compound, if one is waiting on the first.
  let next = queued
  queued = none(Frame)
  if next.isSome:
    dance(next.get.key)


proc dance(key: string) =
  ## Take one offered move, refusing anything that is not offered.
  ##   The guard is the point of the page: a frame reached any other way would
  ##     be a claim the ontology does not make.
  ##   What follows the guard is only the telling of it: the ways not taken
  ##     fold away, the frame taken travels into the middle, and the ways out
  ##     of *it* grow.
  ##     Each phase is scheduled against the times the drawing itself declares,
  ##       so the page never advances the state out from under an animation
  ##       that is still running.
  ##   A dancer who changes their mind while the ways not taken are still
  ##     folding is taken at their word: the state has not moved yet, so the
  ##     fold begins again aimed at the new frame.
  ##     Bumping the generation is what drops the first move's remaining
  ##       phases, and is the same guard that stops a compound finishing itself
  ##       after something else has been asked for.
  let target = fromKey(key)
  if target.isNone or classify(current, target.get).isNone:
    return
  if motion == Motion.Leaving and taken == target:
    return # Asked twice for the same move, which is once.
  if atOnce():
    # Every phase collapses into the change of state it was spelling out.  But a
    # compound is two changes of state, and the phase that would have taken its
    # second half has collapsed along with the rest, so it is taken here instead
    # -- or the page offers a move and then does not make it, which is the one
    # thing a validator must never do.
    arrive(target.get)
    leadOn()
    render()
    return

  inc generation
  let
    mine = generation
    tempo = tempoOf(vis)
  motion = Motion.Leaving
  taken = target
  paintStage()

  discard setTimeout(proc () =
    if generation != mine:
      return
    arrive(target.get)
    motion = Motion.Arriving
    taken = none(Frame)
    render(), tempo.leaveTime)

  discard setTimeout(proc () =
    if generation != mine:
      return
    leadOn(), tempo.leadOnTime)

  discard setTimeout(proc () =
    if generation != mine:
      return
    motion = Motion.Still, tempo.moveTime)


proc danceCompound(key: string) =
  ## Take a named compound, one move at a time, so the way through is danced.
  ##   A lead thinks of it as one thing and the ontology knows it is two, so
  ##     the page dances both: the second is queued behind the first rather
  ##     than timed against it, and it starts as the frame between them lands.
  ##   Anything else the dancer does in the meantime is a newer move, and drops
  ##     the queue.
  let target = fromKey(key)
  if target.isNone or compound(current, target.get).isNone:
    return
  # The way the vocabulary means, not any shortest way: a cut can be led with
  # either arm and only one of those is the one the phrase on this very button
  # describes.  Dancing the other would be doing one thing while saying another.
  let steps = compoundWay(current, target.get)
  if steps.len != 2:
    return
  queued = some(target.get)
  dance(steps[0].to.key)


proc rest() =
  ## Stop whatever was moving, for a change of state that is not a move.
  inc generation
  motion = Motion.Still
  taken = none(Frame)
  queued = none(Frame)


proc start(key: string) =
  ## Begin again from a chosen frame.
  let target = fromKey(key)
  if target.isNone:
    return
  rest()
  origin = target.get
  current = origin
  history = @[]
  view = View.Dance


proc handle(event: Event) =
  ## Route one click to the session change it asks for.
  let stepped = event.target.closest("g.node.reachable")
  if stepped != nil:
    dance($stepped.getAttribute("data-frame"))
    return
  let led = event.target.closest("g.node.two")
  if led != nil:
    danceCompound($led.getAttribute("data-frame"))
    return
  let node = event.target.closest("button")
  if node == nil:
    return
  let action = $node.getAttribute("data-action")
  let value = $node.getAttribute("data-value")
  case action
  of "move":
    dance(value)
    return
  of "compound":
    danceCompound(value)
    return
  of "start": start(value)
  of "view":
    for candidate in View:
      if $candidate == value:
        view = candidate
  of "vis":
    for candidate in Vis:
      if $candidate == value:
        vis = candidate
        vis_chosen = true
  of "holds":
    filter.holds = none(int)
    for count in 0 .. 2:
      if $count == value:
        filter.holds = some(count)
  of "lead":
    filter.lead = none(Side)
    for candidate in Side:
      if $candidate == value:
        filter.lead = some(candidate)
  of "follow":
    filter.follow = none(Site)
    for candidate in Site:
      if $candidate == value:
        filter.follow = some(candidate)
  of "undo":
    if history.len > 0:
      rest()
      discard history.pop()
      current = if history.len > 0: history[^1].to else: origin
  of "reset":
    rest()
    current = origin
    history = @[]
  else: return
  render()


proc reflow(event: Event) =
  ## Follow the screen when it changes size, while the reader has not chosen.
  ##   Only when the drawing would actually change.
  ##     The event arrives on every pixel of a drag, and rebuilding the page on
  ##       each one would take the focus ring off whatever the reader was
  ##       standing on and tear any move that was halfway through being told.
  let showing = vis
  suitVis()
  if vis != showing:
    rest()
    render()


when isMainModule:
  document.addEventListener("click", handle)
  window.addEventListener("resize", reflow)
  suitVis()
  render()
