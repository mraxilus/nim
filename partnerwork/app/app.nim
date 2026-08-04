## Drive the partner-work ontology from a browser, as a check on the model.
##
## The page is a validator before it is a toy: it shows the frame the couple is
## in, every frame one primitive away, and every frame that is *not*, with the
## number of primitives it would take to get there.  Nothing outside the offered
## list can be clicked, so a move the ontology does not derive cannot be danced.
##
## Only the rendering lives here.  The frames, the moves and the audit come from
## `partnerwork`, unchanged, so the page cannot quietly disagree with the tests.

import std/[options, strutils]
import std/dom except Frame ## Exclude the browser's own `Frame`, which is a window.

import ../src/partnerwork



#[ Session ]#

type
  View {.pure.} = enum ## Select what the page is showing.
    Dance, Atlas, Audit

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


const STEP_PAUSE = 560
  ## Wait between the two moves of a compound, in milliseconds.
  ##
  ## Long enough for the marker to finish travelling, which is what makes the
  ## frame between the two moves something the eye can catch.


func startFrame(): Frame =
  ## Get the frame the page opens in: the plain one-hand hold.
  fromKey("r-.").get


var
  origin = startFrame()
  current = startFrame()
  before = startFrame() ## Frame the couple left, so the map can animate away from it.
  view = View.Dance
  vis = Vis.Dynamic
  filter = Filter()
  history: seq[Step] = @[]



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
  ##
  ## A compound is offered as one button because a lead leads it as one thing,
  ## and taking it dances both of its moves in turn rather than jumping the frame
  ## in between.  It is grouped and counted apart from the moves so that the page
  ## never says two things are one.
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
  ## List every frame that is not one primitive away, and how far away it is.
  ##
  ## This half of the panel is what makes the page a validator: a frame here can
  ## be seen but not danced, and the route says exactly what is missing.
  var rows = ""
  var count = 0
  for target in FRAMES:
    if target == source or classify(source, target).isSome or
        compound(source, target).isSome:
      continue
    inc count
    var detail = ""
    let steps = route(source, target)
    for step in steps:
      if detail.len > 0:
        detail.add " &rarr; "
      detail.add esc(step.helper.name)
    rows.add tag("div", "class=\"far\"",
      tag("span", "class=\"phrase\"", esc(target.describe)) &
      tag("span", "class=\"target\"", $steps.len & " moves: " & detail))
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
    tag("ol", "class=\"history\"", rows))


func renderVisSwitch(vis: Vis): string =
  ## Show the choice between the two drawings.
  var tabs = ""
  for candidate in Vis:
    let classes = if candidate == vis: "tab on" else: "tab"
    tabs.add button("vis", $candidate, classes, esc($candidate))
  tag("div", "class=\"tabs small\"", tabs)


func renderArms(): string =
  ## Say which ink is which arm, since both drawings are inked the same way.
  var swatches = ""
  for side in Side:
    swatches.add tag("span", "class=\"swatch\"",
      "<i class=\"arm-" & (if side == Side.Left: "left" else: "right") & "\"></i>" &
      "the lead's " & esc(leadName(side)) & " arm")
  tag("div", "class=\"legend\"", swatches)


func renderSpokesView(current, before: Frame): string =
  ## Draw where the couple are and every way out, and nothing else.
  tag("div", "class=\"view-spokes\"",
    tag("div", "class=\"scroll\"", renderSpokes(current, before)) &
    tag("p", "class=\"note\"", "The frame in the middle is the one being held. " &
      "Every spoke is a way out of it and nothing else is drawn. A drop " &
      "releases a hand so it points up, a collect takes one so it points down, " &
      "and a compound is two moves so it goes out to the side. Take a spoke and " &
      "it becomes the middle."))


func renderMapView(current, before: Frame): string =
  ## Draw where the couple stand in the whole ontology.
  tag("div", "class=\"view-map\"",
    tag("div", "class=\"scroll\"", renderMap(some(current), some(before))) &
    tag("p", "class=\"note\"", "Each row holds one more connection than the row " &
      "above, so a line down the page is a collect and a line up is a drop. A " &
      "lit line is named for the move away from where you stand; dashed curves " &
      "are the two compounds. A frame ringed in a solid line is one move away " &
      "and a dashed one is a compound, two moves away; both can be clicked, and " &
      "a compound dances its two moves in turn."))


func renderStage(current, before: Frame; vis: Vis): string =
  ## Show the frame the couple hold, drawn the way the dancer has asked for.
  let drawing =
    case vis
    of Vis.Dynamic: renderSpokesView(current, before)
    of Vis.Overview: renderMapView(current, before)
  tag("section", "class=\"panel wide\"",
    tag("div", "class=\"stage-head\"",
      tag("h3", "", "frame") & tag("h2", "", esc(current.describe)) &
      renderVisSwitch(vis) & renderArms()) &
    tag("div", "class=\"views\"", drawing))


func renderDance(current, before: Frame; vis: Vis; danced: seq[Step]): string =
  ## Show the current frame, what it allows, and what it does not.
  tag("div", "class=\"stage\"",
    renderStage(current, before, vis) &
    renderMoves(current) & renderElsewhere(current) & renderHistory(danced))



#[ Atlas View ]#

func renderLegend(): string =
  ## Say which letter in the matrix stands for which move.
  for helper in Helper:
    if result.len > 0:
      result.add " &middot; "
    result.add HELPER_MARKS[helper] & " " & helper.name
  for named in Compound:
    result.add " &middot; " & COMPOUND_MARKS[named] & " " &
      ($named).toLowerAscii & " (two moves)"


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
  ##
  ## A name is a claim about a frame; the picture is the frame.  Showing both
  ## means the vocabulary can be read off the drawing rather than trusted, which
  ## is the same reason the review page carries the pictures too.
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
  tag("section", "class=\"panel wide\"",
    tag("h3", "", "every frame &middot; " & $shown & " of " & $FRAMES.len) &
    renderFilters(narrowing) &
    tag("p", "class=\"note\"", "Click a frame to begin the dance from it.") &
    (if shown == 0:
      tag("p", "class=\"note\"", "No frame holds all three of those at once.")
    else:
      tag("div", "class=\"gallery\"", cards)))


func renderAtlas(narrowing: Filter): string =
  ## Show the whole derived transition matrix beside the workbook's cells.
  var head = "<tr><th></th>"
  for target in FRAMES:
    head.add tag("th", "", tag("span", "", esc(target.describe)))
  head.add "</tr>"
  var body = ""
  for source in FRAMES:
    var row = tag("th", "class=\"row\"", esc(source.describe))
    for target in FRAMES:
      let
        helper = classify(source, target)
        named = compound(source, target)
      if source == target:
        row.add tag("td", "class=\"self\"", "")
      elif helper.isNone and named.isNone:
        row.add tag("td", "", "")
      else:
        let known = cellText(
          workbookName(source).get(""), workbookName(target).get(""))
        var classes = if known.isSome: "on" else: "on new"
        if helper.isNone:
          classes.add " two"
        let glyph =
          if helper.isSome: $HELPER_MARKS[helper.get]
          else: $COMPOUND_MARKS[named.get]
        row.add tag("td", "class=\"" & classes & "\"", glyph)
    body.add tag("tr", "", row)
  tag("div", "class=\"stage\"",
    renderGallery(narrowing) &
    tag("section", "class=\"panel wide\"",
      tag("h3", "", "derived transition matrix") &
      tag("p", "class=\"note\"", renderLegend() &
        ". Outlined cells are moves the model derives that the workbook " &
        "leaves blank.") &
      tag("div", "class=\"scroll\"", tag("table", "class=\"matrix\"", head & body)) &
      tag("p", "class=\"note\"", "Rows are the frame danced from, columns the " &
        "frame danced to. Every move reverses, so the matrix is symmetric except " &
        "that collect and drop are each other's mirror. Faded cells are the two " &
        "compounds: a pair of primitives the dance calls one move.")))


func renderAudit(): string =
  ## Report what the model has to say about the workbook.
  let findings = audit()
  var rows = ""
  var previous = FindingKind.StateDeferred
  var first = true
  for kind in FindingKind:
    for finding in findings:
      if finding.kind != kind:
        continue
      if first or previous != kind:
        rows.add tag("h4", "", esc($kind))
        previous = kind
        first = false
      rows.add tag("div", "class=\"far\"",
        tag("span", "class=\"phrase\"", esc(finding.subject)) &
        tag("span", "class=\"target\"", esc(finding.detail)))
  tag("section", "class=\"panel wide\"",
    tag("h3", "", "workbook audit &middot; " & $findings.len & " findings") &
    tag("p", "class=\"note\"", $(CELLS.len - countDeferredCells()) & " of the " &
      $CELLS.len & " filled cells of the base sheet hold between hand-to-hand " &
      "frames and are checked against the primitive the model derives for the " &
      "same pair. The rest wait for a place on the body.") & rows)



#[ Page ]#

func renderControls(view: View): string =
  ## Show the view switches.
  var views = ""
  for candidate in View:
    let classes = if candidate == view: "tab on" else: "tab"
    views.add button("view", $candidate, classes, esc($candidate))
  tag("header", "", tag("h1", "", "partner work") & tag("div", "class=\"tabs\"", views))


proc render() =
  ## Draw the page from the session state, then let the marker travel.
  ##
  ## The map is drawn with the marker still on the frame the couple left.  Moving
  ## it after the browser has laid the page out is what turns a change of state
  ## into a movement across the picture; a page that never runs this still shows
  ## the couple somewhere true, one frame behind.
  let body =
    case view
    of View.Dance: renderDance(current, before, vis, history)
    of View.Atlas: renderAtlas(filter)
    of View.Audit: renderAudit()
  document.getElementById("app").innerHTML = cstring(renderControls(view) & body)
  let marker = document.getElementById("here")
  if marker != nil:
    discard marker.getBoundingClientRect() # Settle the drawn position first.
    marker.setAttribute("transform", cstring("translate(" &
      $marker.getAttribute("data-x") & "," & $marker.getAttribute("data-y") & ")"))
  let core = document.getElementById("core")
  if core != nil:
    discard core.getBoundingClientRect()
    core.setAttribute("transform", "translate(0,0)")


proc dance(key: string) =
  ## Take one offered move, refusing anything that is not offered.
  ##
  ## The guard is the point of the page: a frame reached any other way would be
  ## a claim the ontology does not make.
  let target = fromKey(key)
  if target.isNone:
    return
  for move in moves(current):
    if move.to != target.get:
      continue
    history.add Step(phrase: phrase(current, move), to: move.to)
    before = current
    current = move.to
    return


proc danceCompound(key: string) =
  ## Take a named compound, one move at a time, so the way through is danced.
  ##
  ## The second move waits for the first to finish crossing the map.  It is only
  ## taken if the couple are still standing where the first move left them, so a
  ## click elsewhere in the meantime cancels the rest rather than teleporting
  ## them out of wherever they went.
  let target = fromKey(key)
  if target.isNone or compound(current, target.get).isNone:
    return
  let steps = route(current, target.get)
  if steps.len != 2:
    return
  let waypoint = steps[0].to
  dance(waypoint.key)
  render()
  discard setTimeout(proc () =
    if current != waypoint:
      return
    dance(target.get.key)
    render(), STEP_PAUSE)


proc start(key: string) =
  ## Begin again from a chosen frame.
  let target = fromKey(key)
  if target.isNone:
    return
  origin = target.get
  before = origin
  current = origin
  history = @[]
  view = View.Dance


proc handle(event: Event) =
  ## Route one click to the session change it asks for.
  let stepped = event.target.closest("g.node.reachable")
  if stepped != nil:
    dance($stepped.getAttribute("data-frame"))
    render()
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
  of "move": dance(value)
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
      discard history.pop()
      before = current
      current = if history.len > 0: history[^1].to else: origin
  of "reset":
    before = current
    current = origin
    history = @[]
  else: return
  render()


when isMainModule:
  document.addEventListener("click", handle)
  render()
