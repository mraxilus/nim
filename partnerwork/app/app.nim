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

  Step = object ## Hold one danced move, for the history.
    phrase: string
    to: Frame


func startFrame(): Frame =
  ## Get the frame the page opens in: the plain one-hand hold.
  fromKey("r-.").get


var
  origin = startFrame()
  current = startFrame()
  view = View.Dance
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



#[ Diagram ]#

const
  DIAGRAM_WIDTH = 360
  DIAGRAM_HEIGHT = 250
  LEAD_BODY_X = 88
  FOLLOW_BODY_X = 272
  BODY_Y = 125
  BODY_RADIUS = 30
  REACH_X = 56
  REST_X = 24
  UPPER_Y = 66
  LOWER_Y = 184


func handPoint(side: Side; held: bool): (int, int) =
  ## Get where a lead hand is drawn, forward when it holds and back when it does not.
  ##
  ## The couple is seen from above with the lead on the left, so the lead's left
  ## hand and the follow's right hand share the upper edge: a connection between
  ## them is a straight line, and one that crosses the midline is a diagonal.
  let x = LEAD_BODY_X + (if held: REACH_X else: REST_X)
  case side
  of Side.Left: (x, UPPER_Y)
  of Side.Right: (x, LOWER_Y)


func sitePoint(site: Site; held: bool): (int, int) =
  ## Get where a hand of the follow is drawn.
  let x = FOLLOW_BODY_X - (if held: REACH_X else: REST_X)
  case site
  of Site.RightHand: (x, UPPER_Y)
  of Site.LeftHand: (x, LOWER_Y)


func line(from_x, from_y, to_x, to_y: int): string =
  ## Form a straight path between two points.
  "M" & $from_x & " " & $from_y & "L" & $to_x & " " & $to_y


func dot(point: (int, int); classes: string): string =
  ## Draw one hand marker.
  "<circle class=\"" & classes & "\" cx=\"" & $point[0] & "\" cy=\"" & $point[1] &
    "\" r=\"7\"/>"


func label(x, y: int; text: string): string =
  ## Draw one small caption.
  "<text class=\"caption\" x=\"" & $x & "\" y=\"" & $y & "\">" & esc(text) & "</text>"


func isHeld(target: Frame; site: Site): bool =
  ## Test whether either lead hand holds this hand of the follow.
  for side in Side:
    if target.hold[side] == some(site):
      return true
  false


func renderDiagram(target: Frame): string =
  ## Draw the frame from above: two bodies, four hands, and what they hold.
  var parts = "<svg viewBox=\"0 0 " & $DIAGRAM_WIDTH & " " & $DIAGRAM_HEIGHT &
    "\" class=\"diagram\" role=\"img\">"
  for x in [LEAD_BODY_X, FOLLOW_BODY_X]:
    parts.add "<circle class=\"body\" cx=\"" & $x & "\" cy=\"" & $BODY_Y &
      "\" r=\"" & $BODY_RADIUS & "\"/>"
  parts.add label(LEAD_BODY_X, BODY_Y + 5, "lead")
  parts.add label(FOLLOW_BODY_X, BODY_Y + 5, "follow")

  # Arms first, so that the connections are drawn over them.
  for side in Side:
    let (hand_x, hand_y) = handPoint(side, target.hold[side].isSome)
    let shoulder_y = if side == Side.Left: BODY_Y - 21 else: BODY_Y + 21
    parts.add "<path class=\"arm\" d=\"" &
      line(LEAD_BODY_X + 16, shoulder_y, hand_x, hand_y) & "\"/>"
  for site in Site:
    let (site_x, site_y) = sitePoint(site, target.isHeld(site))
    let shoulder_y = if site == Site.RightHand: BODY_Y - 21 else: BODY_Y + 21
    parts.add "<path class=\"arm\" d=\"" &
      line(FOLLOW_BODY_X - 16, shoulder_y, site_x, site_y) & "\"/>"

  # The overlapping pair is drawn under-arm first, then the over-arm masked, so
  # the crossing reads the way it looks from above.
  var order = @[Side.Left, Side.Right]
  if target.over == some(Side.Left):
    order = @[Side.Right, Side.Left]
  for side in order:
    if target.hold[side].isNone:
      continue
    let (hand_x, hand_y) = handPoint(side, true)
    let (site_x, site_y) = sitePoint(target.hold[side].get, true)
    let path = line(hand_x, hand_y, site_x, site_y)
    if target.over == some(side):
      parts.add "<path class=\"mask\" d=\"" & path & "\"/>"
    parts.add "<path class=\"link " & (if side == Side.Left: "left" else: "right") &
      "\" d=\"" & path & "\"/>"

  for side in Side:
    let held = target.hold[side].isSome
    parts.add dot(handPoint(side, held), "hand" & (if held: " held" else: ""))
  for site in Site:
    let held = target.isHeld(site)
    parts.add dot(sitePoint(site, held), "hand" & (if held: " held" else: ""))

  parts.add label(LEAD_BODY_X + REACH_X, UPPER_Y - 16, "Left")
  parts.add label(LEAD_BODY_X + REACH_X, LOWER_Y + 24, "Right")
  parts.add label(FOLLOW_BODY_X - REACH_X, UPPER_Y - 16, "right")
  parts.add label(FOLLOW_BODY_X - REACH_X, LOWER_Y + 24, "left")
  parts.add "</svg>"
  parts



#[ Dance View ]#

func renderMoves(source: Frame): string =
  ## List every frame one primitive away, as the only things that can be danced.
  let available = moves(source)
  var rows = ""
  var previous = ""
  for move in available:
    let helper = $move.helper
    if helper != previous:
      rows.add tag("h4", "", esc(helper.toLowerAscii) & " &mdash; " &
        esc(HELPER_MANNERS[move.helper]))
      previous = helper
    rows.add button("move", move.to.key, "move",
      tag("span", "class=\"phrase\"", esc(phrase(source, move))) &
      tag("span", "class=\"target\"", esc(move.to.describe)))
  tag("section", "class=\"panel\"",
    tag("h3", "", "available now &middot; " & $available.len) & rows)


func renderElsewhere(source: Frame): string =
  ## List every frame that is not one primitive away, and how far away it is.
  ##
  ## This half of the panel is what makes the page a validator: a frame here can
  ## be seen but not danced, and the route says exactly what is missing.
  var rows = ""
  var count = 0
  for target in FRAMES:
    if target == source or classify(source, target).isSome:
      continue
    inc count
    var detail = ""
    let steps = route(source, target)
    for step in steps:
      if detail.len > 0:
        detail.add " &rarr; "
      detail.add esc(($step.helper).toLowerAscii)
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


func renderDance(current: Frame; danced: seq[Step]): string =
  ## Show the current frame, what it allows, and what it does not.
  tag("div", "class=\"stage\"",
    tag("section", "class=\"panel\"",
      tag("h3", "", "frame") &
      tag("h2", "", esc(current.describe)) &
      tag("p", "class=\"note\"", "position: " & esc(current.position) &
        " &middot; connections: " & $current.countHolds &
        " &middot; key: " & esc(current.key)) &
      renderDiagram(current)) &
    renderMoves(current) & renderElsewhere(current) & renderHistory(danced))



#[ Atlas View ]#

func helperMark(helper: Helper): string =
  ## Abbreviate a primitive for the matrix.
  case helper
  of Helper.Collect: "c"
  of Helper.Drop: "d"
  of Helper.Pass: "p"
  of Helper.Cut: "x"


func renderAtlas(): string =
  ## Show the whole derived transition matrix beside the workbook's cells.
  var head = "<tr><th></th>"
  for target in FRAMES:
    head.add tag("th", "", tag("span", "", esc(target.describe)))
  head.add "</tr>"
  var body = ""
  for source in FRAMES:
    var row = tag("th", "class=\"row\"", esc(source.describe))
    for target in FRAMES:
      let helper = classify(source, target)
      if source == target:
        row.add tag("td", "class=\"self\"", "")
      elif helper.isNone:
        row.add tag("td", "", "")
      else:
        let known = cellText(
          workbookName(source).get(""), workbookName(target).get(""))
        let classes = if known.isSome: "on" else: "on new"
        row.add tag("td", "class=\"" & classes & "\"", helperMark(helper.get))
    body.add tag("tr", "", row)
  var starts = ""
  for target in FRAMES:
    starts.add button("start", target.key, "flat", esc(target.describe))
  tag("section", "class=\"panel wide\"",
    tag("h3", "", "derived transition matrix") &
    tag("p", "class=\"note\"",
      "c collect &middot; d drop &middot; p pass (place) &middot; x cut. " &
      "Outlined cells are moves the model derives that the workbook leaves blank.") &
    tag("table", "class=\"matrix\"", head & body) &
    tag("p", "class=\"note\"", "Rows are the frame danced from, columns the frame " &
      "danced to. Every primitive reverses, so the matrix is symmetric except " &
      "that collect and drop are each other's mirror.") &
    tag("div", "class=\"starts\"", starts))


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
  ## Draw the page from the session state.
  let body =
    case view
    of View.Dance: renderDance(current, history)
    of View.Atlas: renderAtlas()
    of View.Audit: renderAudit()
  document.getElementById("app").innerHTML = cstring(renderControls(view) & body)


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
    current = move.to
    return


proc start(key: string) =
  ## Begin again from a chosen frame.
  let target = fromKey(key)
  if target.isNone:
    return
  origin = target.get
  current = origin
  history = @[]
  view = View.Dance


proc handle(event: Event) =
  ## Route one click to the session change it asks for.
  let node = event.target.closest("button")
  if node == nil:
    return
  let action = $node.getAttribute("data-action")
  let value = $node.getAttribute("data-value")
  case action
  of "move": dance(value)
  of "start": start(value)
  of "view":
    for candidate in View:
      if $candidate == value:
        view = candidate
  of "undo":
    if history.len > 0:
      discard history.pop()
      current = if history.len > 0: history[^1].to else: origin
  of "reset":
    current = origin
    history = @[]
  else: return
  render()


when isMainModule:
  document.addEventListener("click", handle)
  render()
