## Ask the rope which of the ontology's modifier states are physically real.
##
##   This is the sim doing the job it is for: not a page to look at, an
##     instrument to measure with.  The ontology's WIP sheet enumerates
##     states -- a hold, a level, an arm carried as a wrap or a lock -- with
##     a `validated` column that is almost entirely unfilled, and one
##     rotation row claiming that from a same-hand hold held low, half a
##     turn one way makes a wrap and half a turn the other makes a lock.
##     Every one of those is a claim about two bodies and a rope, so the
##     rope is asked directly and the answers are written to a report.
##   The sim's own words are physical: a rope lies across the *front* of a
##     body or behind its *back*, on the *torso* or the *neck*, carrying so
##     many whole *laps*.  The report translates once, in one visible table:
##     front = wrap, back = lock, torso = low, neck = high, over the crown =
##     above.  Translation lives here in the report and nowhere in the
##     model, so the sim still shares no vocabulary with the ontology.
##     Cost of translating in the report: a reader of `rope.nim` never meets
##       the words the sheet uses.  Accepted -- that separation is what
##       makes the answers evidence rather than an echo.
##   What the instrument cannot say, said plainly: a rope has no elbow, so
##     "bent to the shoulder of the same arm" reads here only as *behind,
##     on the upper band*; the neck stands in for the whole above-shoulder
##     body; and the couple never step apart to ease a bind.  Verdicts are
##     therefore conservative about lengths and silent about joints.

{.experimental: "strictFuncs".}

import std/[math, options, strformat, strutils]

import ./rope


const
  APART = 0.40      ## The stance every question is asked at, in metres.
  LOW = 1.20        ## Hands at the torso: the sheet's "low".
  HIGH = 1.53       ## Hands at the neck band: the sheet's "high".
  ABOVE = 1.82      ## Hands over both crowns: the sheet's "above".
  LEVELS = [("low", LOW), ("high", HIGH), ("above", ABOVE)]
  HALVES = [-4, -3, -2, -1, 1, 2, 3, 4] ## Turns asked, in half turns.


func joined(a, b: Arm; height: float): State =
  ## Stand the couple square with one connection, body One's hand to Two's.
  result = facing(HUMAN, APART)
  result.links = @[Link(ends: [(Body.One, a), (Body.Two, b)],
                        height: height)]


func said(lying: Option[Lying]): string =
  ## Write where a wound arm lies, in the sheet's own words.
  ##   The one translation table: Fore = wrap, Aft = lock, Torso = low,
  ##     Head = high.  Laps past the first are said as such, because the
  ##     sheet has no word for them yet.
  if lying.isNone:
    return "open"
  let
    way = if lying.get.aspect == Aspect.Fore: "wrap" else: "lock"
    band = if lying.get.band == Band.Torso: "low" else: "high"
    laps = if lying.get.laps > 0: &" +{lying.get.laps} lap" else: ""
    held = if lying.get.wound: "" else: " (led, clear of the body)"
  &"{way} {band}{laps}{held}"


func verdict(state: State): string =
  ## Say whether the rope allows a state, and what refuses it if not.
  let refusing = refusal(state, swan = false)
  if refusing.isNone:
    return "holds"
  case refusing.get
  of Fault.Tangent: "refused: cannot be laid"
  of Fault.Through: "refused: through a body"
  of Fault.Budget: "refused: out of rope"
  of Fault.Braided: "refused: rope through rope"
  of Fault.Swan: "refused: past the swan"


proc singleHolds(): string =
  ## Measure every single hold at every level through four half turns of the
  ## held body, each way.
  ##   The held body is Two; a positive turn is anticlockwise seen from
  ##     above.  Which of those the dance calls "left" is the reader's to
  ##     map, and the mapping is the same in every row.
  result = "## Single holds: turn the held dancer\n\n"
  result.add "One connection, body One's hand to body Two's, hands carried " &
    "at the level named.  Body Two turns; the rope answers.\n\n"
  for (one, two, name) in [
      (Arm.Left, Arm.Left, "L-l (same-name: lead Left to follow left)"),
      (Arm.Right, Arm.Right, "R-r (same-name)"),
      (Arm.Left, Arm.Right, "L-r (cross)"),
      (Arm.Right, Arm.Left, "R-l (cross)")]:
    result.add &"### {name}\n\n"
    result.add "| level | turn | arm lies | verdict |\n"
    result.add "|---|---|---|---|\n"
    for (level, height) in LEVELS:
      for halves in HALVES:
        let
          turn = float(halves) / 2.0
          base = settled(joined(one, two, height))
          spun = turned(base, Body.Two, turn * 2.0 * PI)
          lying = lyingOn(spun, spun.links[0], Body.Two)
        result.add &"| {level} | {turn:+.1f} | {said(lying)} | " &
          &"{verdict(spun)} |\n"
    result.add "\n"


proc sheetSaid(): string =
  ## Answer the sheet's question in the sheet's own shape: for each single
  ## hold, level and modifier on the held arm, is there a turn that makes it?
  ##   The sweep is the same +-2 turns the tables above walk; a modifier is
  ##     *reachable* when some turn lies the arm that way, on that band, with
  ##     no extra lap, and the rope still holds.
  result = "## Scored against the sheet\n\n"
  result.add "The sheet's frames list carries a `validated` column that is " &
    "almost entirely unfilled.  This table is the rope's fill for the " &
    "single-hold rows: each cell says whether any turn in the sweep " &
    "produces that modifier cleanly.\n\n"
  result.add "| hold | level | wrap | lock |\n|---|---|---|---|\n"
  for (one, two, name) in [
      (Arm.Left, Arm.Left, "L-l"), (Arm.Right, Arm.Right, "R-r"),
      (Arm.Left, Arm.Right, "L-r"), (Arm.Right, Arm.Left, "R-l")]:
    for (level, height) in LEVELS:
      var found: array[Aspect, string]
      for aspect in Aspect:
        found[aspect] = "not reached in the sweep"
      for halves in [1, -1, 2, -2, 3, -3, 4, -4]: # Nearest turn first.
        let
          turn = float(halves) / 2.0
          spun = turned(settled(joined(one, two, height)), Body.Two,
                        turn * 2.0 * PI)
          lying = lyingOn(spun, spun.links[0], Body.Two)
        if lying.isNone or lying.get.laps > 0 or not holds(spun, swan = false):
          continue
        let saying = &"at {turn:+.1f} turn" &
          (if lying.get.wound: "" else: " (led)")
        if found[lying.get.aspect].startsWith("not"):
          found[lying.get.aspect] = saying
      let told =
        if height > HUMAN.crown: ["no wrap above the crown",
                                  "no lock above the crown"]
        else: [found[Aspect.Fore], found[Aspect.Aft]]
      result.add &"| {name} | {level} | {told[0]} | {told[1]} |\n"
  result.add "\nAbove the crown the rope clears both bodies whatever the " &
    "turn, so no wrap or lock exists there -- the sheet's own rule, here " &
    "as a measurement.\n\n"


proc liftedLock(): string =
  ## Test the sheet's safety note: a low lock is entered from low.
  ##   Formed low and raised, against formed at height: if the raised rope
  ##     no longer holds, the note has a geometric reading too.
  result = "## The low-lock entry note\n\n"
  result.add "The sheet: *\"To get into low lock, the form must enter from " &
    "a low position only due to physical/safety limitations.\"*  The rope's " &
    "reading:\n\n"
  for (way, way_name) in [(-1, "lock way"), (1, "wrap way")]:
    let low_formed = turned(settled(joined(Arm.Left, Arm.Left, LOW)),
                            Body.Two, float(way) * PI)
    var raised = low_formed
    raised.links[0].height = HIGH
    let at_height = turned(settled(joined(Arm.Left, Arm.Left, HIGH)),
                           Body.Two, float(way) * PI)
    result.add &"- Half a turn the {way_name}, formed low: " &
      &"{said(lyingOn(low_formed, low_formed.links[0], Body.Two))}, " &
      &"{verdict(low_formed)}.  The same wound rope lifted to the neck: " &
      &"{verdict(raised)}.  Formed at the neck directly: " &
      &"{said(lyingOn(at_height, at_height.links[0], Body.Two))}, " &
      &"{verdict(at_height)}.\n"
  result.add "\n"


proc pairStates(): string =
  ## Measure the two-hand holds: the plain state, and the turned ones the
  ## sheet leaves unvalidated.
  result = "## Two-hand holds\n\n"
  result.add "| hold | level | turn | verdict | sweep limit (turns) |\n"
  result.add "|---|---|---|---|---|\n"
  for (pair, name) in [
      (@[(Arm.Left, Arm.Right), (Arm.Right, Arm.Left)], "L-r and R-l"),
      (@[(Arm.Left, Arm.Left), (Arm.Right, Arm.Right)], "L-l and R-r")]:
    for (level, height) in LEVELS:
      var base = facing(HUMAN, APART)
      for (one, two) in pair:
        base.links.add Link(ends: [(Body.One, one), (Body.Two, two)],
                            height: height)
      let rested = settled(base)
      let limit = windLimit(rested, Body.Two, most = 5.0 * PI,
                            swan = false) / (2.0 * PI)
      for halves in [0, 1, 2]:
        let spun = turned(rested, Body.Two, float(halves) * PI)
        result.add &"| {name} | {level} | {float(halves) / 2.0:+.1f} | " &
          &"{verdict(spun)} | {limit:.2f} |\n"
  result.add "\n"


proc bothWound(): string =
  ## Measure the states the sheet rules out wholesale: both dancers' arms
  ## modified at once on one connection.
  result = "## Both arms modified at once\n\n"
  result.add "One connection, half a turn of each body -- each wind on its " &
    "own dancer:\n\n"
  result.add "| level | body One | body Two | verdict |\n"
  result.add "|---|---|---|---|\n"
  for (level, height) in LEVELS:
    for (one_way, two_way) in [(1.0, 1.0), (1.0, -1.0),
                               (-1.0, 1.0), (-1.0, -1.0)]:
      let spun = turned(turned(settled(joined(Arm.Left, Arm.Left, height)),
                               Body.Two, two_way * PI),
                        Body.One, one_way * PI)
      result.add &"| {level} | " &
        &"{said(lyingOn(spun, spun.links[0], Body.One))} | " &
        &"{said(lyingOn(spun, spun.links[0], Body.Two))} | " &
        &"{verdict(spun)} |\n"
  result.add "\n"


proc report(): string =
  ## Write the whole report.
  result = "# What the rope says about the modifier states\n\n"
  result.add "Generated by `nimble verdicts` from `sim/verdicts.nim`; do " &
    "not edit by hand.  The sim answers in its own physical words and this " &
    "report translates once:\n\n"
  result.add "| the rope says | the sheet says |\n|---|---|\n"
  result.add "| lies across the front (Fore) | wrap |\n"
  result.add "| lies behind the back (Aft) | lock |\n"
  result.add "| on the torso band | low |\n"
  result.add "| on the neck band | high |\n"
  result.add "| clears over the crown, winds nothing | above |\n\n"
  result.add "Read with the instrument's limits in mind: a rope has no " &
    "elbow, the neck cylinder stands in for everything above the " &
    "shoulders, and the couple never step apart to ease a bind.  A " &
    "*refused: out of rope* is therefore conservative; a *holds* says the " &
    "shape exists without anybody bending a joint.\n\n"
  result.add singleHolds()
  result.add sheetSaid()
  result.add liftedLock()
  result.add pairStates()
  result.add bothWound()


when isMainModule:
  writeFile("sim/verdicts.md", report())
  echo "verdicts: sim/verdicts.md written"
