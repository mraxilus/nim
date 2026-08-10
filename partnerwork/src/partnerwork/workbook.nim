## Hold the `base` sheet of the partner-work workbook and audit it against the
## derived model.
##
## The workbook is the source the ontology grew from, so it is treated as
## evidence rather than as truth.
##   Every cell is checked against the primitive that the physics gives for the
##     same pair of frames, and every disagreement is reported with its kind.
##   Cost of transcribing the sheet here as data: twenty-seven cells copied and
##     kept by hand, to re-copy if the workbook is ever re-read.  Accepted --
##     keeping the sheet here as data means the audit is a test, not a memory
##     of one afternoon's reading.
##
##   |-------------------|-------------------------------------------------|
##   | Code              | The Workbook's Own Words                        |
##   |-------------------|-------------------------------------------------|
##   | `Cell`            | one filled cell of the `base` sheet             |
##   | `WORKBOOK_STATES` | the sheet's row/column headings, in sheet order |
##   | `Helper.Collect`  | "collect"                                       |
##   | `Helper.Drop`     | "drop"; "flick" when led with momentum          |
##   | `Compound.Place`  | "pass"; "place"                                 |
##   | `Compound.Cut`    | "cut"                                           |
##   | `DEFERRED_STATES` | "closed", "half-closed"                         |
##   |-------------------|-------------------------------------------------|
##
## The transcription is of the `base` sheet only.
##   The `rotations` sheet and the twelve turn sheets carry headers and no
##     cells, apart from three entries in `rotations`, which `rotation.nim`
##     records instead.
##
## Two of the sheet's nine states, `closed` and `half-closed`, rest a lead hand
## on the follow's body rather than on a hand.
##   So they are outside the hand-to-hand model and are reported as deferred
##     rather than checked.
##   Cost of deferring rather than forcing them into frames: every cell that
##     touches them goes unaudited until the rotation axis arrives -- see
##     `countDeferredCells`.  Accepted -- reading them as hand-to-hand
##     duplicates rows the sheet already has and contradicts six of its cells;
##     see `DEFERRED_STATES`.

{.experimental: "strictFuncs".}

import std/[options, strutils]

import ./frame
import ./transition



#[ Transcription ]#

type
  Cell* = object ## Hold one filled cell of the workbook's transition matrix.
    source*, destination*: string ## Workbook names of the row and the column.
    text*: string                 ## Helpers the cell names, in the cell's words.


const WORKBOOK_STATES*: array[9, string] = [
  "closed",
  "half-closed",
  "Left to left",
  "Left to right",
  "Right to left",
  "Right to right",
  "Left-to-left over Right-to-right",
  "Left-to-right and Right-to-left",
  "Right-to-right over Left-to-left",
] ## Name the rows and columns of the `base` sheet, in the sheet's order.


const CELLS*: array[27, Cell] = [
  Cell(source: "closed", destination: "half-closed", text: "drop"),
  Cell(source: "closed", destination: "Left to right", text: "drop"),
  Cell(source: "closed", destination: "Left-to-right and Right-to-left", text: "slide"),
  Cell(source: "half-closed", destination: "closed", text: "collect"),
  Cell(source: "half-closed", destination: "Right to left", text: "slide"),
  Cell(source: "Left to left", destination: "half-closed", text: "place, collect"),
  Cell(source: "Left to left", destination: "Right to left", text: "pass"),
  Cell(source: "Left to left", destination: "Left-to-left over Right-to-right",
    text: "collect"),
  Cell(source: "Left to left", destination: "Right-to-right over Left-to-left",
    text: "collect"),
  Cell(source: "Left to right", destination: "closed", text: "collect"),
  Cell(source: "Left to right", destination: "Right to right", text: "pass"),
  Cell(source: "Left to right", destination: "Left-to-right and Right-to-left",
    text: "collect"),
  Cell(source: "Right to left", destination: "Left to left", text: "pass"),
  Cell(source: "Right to left", destination: "Left-to-right and Right-to-left",
    text: "collect"),
  Cell(source: "Right to right", destination: "Left to right", text: "pass"),
  Cell(source: "Right to right", destination: "Left-to-left over Right-to-right",
    text: "collect"),
  Cell(source: "Right to right", destination: "Right-to-right over Left-to-left",
    text: "collect"),
  Cell(source: "Left-to-left over Right-to-right", destination: "half-closed",
    text: "place, drop, collect"),
  Cell(source: "Left-to-left over Right-to-right", destination: "Left to left",
    text: "drop"),
  Cell(source: "Left-to-left over Right-to-right", destination: "Right to right",
    text: "drop"),
  Cell(source: "Left-to-left over Right-to-right",
    destination: "Right-to-right over Left-to-left", text: "cut"),
  Cell(source: "Left-to-right and Right-to-left", destination: "closed", text: "slide"),
  Cell(source: "Left-to-right and Right-to-left", destination: "Left to right",
    text: "drop"),
  Cell(source: "Left-to-right and Right-to-left", destination: "Right to left",
    text: "drop"),
  Cell(source: "Right-to-right over Left-to-left", destination: "Left to left",
    text: "drop"),
  Cell(source: "Right-to-right over Left-to-left", destination: "Right to right",
    text: "drop"),
  Cell(source: "Right-to-right over Left-to-left",
    destination: "Left-to-left over Right-to-right", text: "cut"),
] ## Hold every filled cell of the `base` sheet, read row by row.



#[ Reading The Workbook ]#

const DEFERRED_STATES* = ["closed", "half-closed"]
  ## Name the states that rest a lead hand on the follow's body.
  ##
  ## Both are forced to be body-contact frames by the cells that reach them.  A
  ## `slide` keeps contact, and contact can only travel along a body: there is no
  ## path from one hand of the follow to the other, because the space between
  ## them is empty air.  So in `half-closed --slide--> Right to left` and in
  ## `closed --slide--> Left-to-right and Right-to-left` the lead's right hand
  ## must start on the follow, not in their hand.  Reading them instead as the
  ## vocabulary sheet does, where `half-closed` is `Left to right` and `closed`
  ## is `Left-to-left and Right-to-right`, makes them duplicates of rows the
  ## sheet already has and contradicts six of its cells.  Either way they need a
  ## place on the body, so they wait for the rotation axis.


func workbookFrame*(name: string): Option[Frame] =
  ## Read a workbook state name as a hand-to-hand frame, where it is one.
  var built = Frame()
  case name
  of "Left to left":
    built.hold[Side.Left] = some(Site.LeftHand)
  of "Left to right":
    built.hold[Side.Left] = some(Site.RightHand)
  of "Right to left":
    built.hold[Side.Right] = some(Site.LeftHand)
  of "Right to right":
    built.hold[Side.Right] = some(Site.RightHand)
  of "Left-to-left over Right-to-right":
    built.hold[Side.Left] = some(Site.LeftHand)
    built.hold[Side.Right] = some(Site.RightHand)
    built.over = some(Side.Left)
  of "Right-to-right over Left-to-left":
    built.hold[Side.Left] = some(Site.LeftHand)
    built.hold[Side.Right] = some(Site.RightHand)
    built.over = some(Side.Right)
  of "Left-to-right and Right-to-left":
    built.hold[Side.Left] = some(Site.RightHand)
    built.hold[Side.Right] = some(Site.LeftHand)
  else:
    return none(Frame)
  some(built)


func workbookName*(target: Frame): Option[string] =
  ## Get the workbook's name for a frame, where the workbook has one.
  for name in WORKBOOK_STATES:
    if workbookFrame(name) == some(target):
      return some(name)
  none(string)


func readHelper*(word: string): Option[Helper] =
  ## Read one primitive from a cell, including the workbook's synonyms.
  ##
  ## `slide` and `trace` are absent because they slide a hand along the partner,
  ## and every cell that names one reaches a deferred state.  `pass`, `place` and
  ## `cut` are absent because they are compounds; `readCompound` reads those.
  case word.strip()
  of "collect": some(Helper.Collect)
  of "drop", "flick": some(Helper.Drop)
  else: none(Helper)


func readCompound*(word: string): Option[Compound] =
  ## Read one compound from a cell, in any of the words the workbook uses.
  case word.strip()
  of "pass", "place": some(Compound.Place)
  of "cut": some(Compound.Cut)
  else: none(Compound)


func readCell*(text: string): seq[string] =
  ## Split a cell into the helper words it names, in order.
  for word in text.split(','):
    let trimmed = word.strip()
    if trimmed.len > 0:
      result.add trimmed


func cellText*(source, destination: string): Option[string] =
  ## Get the text of one cell of the workbook, where the cell is filled.
  for cell in CELLS:
    if cell.source == source and cell.destination == destination:
      return some(cell.text)
  none(string)


func isDeferred*(name: string): bool = name in DEFERRED_STATES
  ## Test whether a workbook state waits for a place on the body.


func countDeferredCells*(): int =
  ## Count the cells that cannot be checked until the body sites arrive.
  for cell in CELLS:
    if cell.source.isDeferred or cell.destination.isDeferred:
      inc result



#[ Audit ]#

type
  FindingKind* {.pure.} = enum ## Name a way the workbook and the model relate.
    StateDeferred,    ## State that rests a hand on the body, outside this model.
    FrameAbsent,      ## Frame the model derives that the workbook has no row for.
    EdgeAbsent,       ## Single primitive between two checkable states, cell empty.
    ReverseAbsent,    ## Filled cell whose mirror cell is empty, though moves reverse.
    EdgeCompound,     ## Cell naming a sequence, so a route rather than a move.
    HelperDiffers,    ## Cell naming a primitive other than the derived one.
    EdgeUnsupported   ## Filled cell the model gives no single primitive for.

  Finding* = object ## Hold one thing the audit has to say about the workbook.
    kind*: FindingKind
    subject*: string ## Frame, state or pair of states the finding concerns.
    detail*: string  ## What the model says, in the ontology's vocabulary.


func auditStates(): seq[Finding] =
  ## Report the states held back for want of a place on the body.
  for name in DEFERRED_STATES:
    var touched = 0
    for cell in CELLS:
      if cell.source == name or cell.destination == name:
        inc touched
    result.add Finding(
      kind: FindingKind.StateDeferred,
      subject: name,
      detail: "rests the lead's right hand on the follow rather than in their " &
        "hand, so it waits for the rotation axis; " & $touched &
        " of the sheet's " & $CELLS.len & " cells touch it",
    )


func auditFrames(): seq[Finding] =
  ## Report frames the model derives that the workbook never names.
  for target in FRAMES:
    if workbookName(target).isSome:
      continue
    result.add Finding(
      kind: FindingKind.FrameAbsent,
      subject: target.describe,
      detail: "the model derives " & $moves(target).len &
        " moves from it, and the sheet has no row for it",
    )


func auditCells(): seq[Finding] =
  ## Report cells that disagree with the primitive the model gives.
  for cell in CELLS:
    if cell.source.isDeferred or cell.destination.isDeferred:
      continue
    let
      source = workbookFrame(cell.source).get
      destination = workbookFrame(cell.destination).get
      helper = classify(source, destination)
      words = readCell(cell.text)
      subject = cell.source & " -> " & cell.destination
    if words.len > 1:
      result.add Finding(
        kind: FindingKind.EdgeCompound,
        subject: subject,
        detail: "cell names " & $words.len & " helpers; the model derives a route of " &
          $route(source, destination).len & " primitives, so this is a path, not a move",
      )
      continue
    let
      named_helper = readHelper(words[0])
      named_compound = readCompound(words[0])
      derived_compound = compound(source, destination)
    if named_compound.isSome:
      # A cell naming a compound is right when the model derives that compound
      # for the pair, and the compound is two primitives long.
      if derived_compound == named_compound and
          route(source, destination).len == 2:
        continue
      result.add Finding(
        kind: FindingKind.HelperDiffers,
        subject: subject,
        detail: "cell says '" & cell.text & "'; the model derives " &
          (if derived_compound.isSome: $derived_compound.get else: "no compound"),
      )
      continue
    if helper.isNone:
      result.add Finding(
        kind: FindingKind.EdgeUnsupported,
        subject: subject,
        detail: "no primitive and no compound joins these frames; the shortest " &
          "route is " & $route(source, destination).len & " primitives",
      )
      continue
    if named_helper.isNone or named_helper.get != helper.get:
      result.add Finding(
        kind: FindingKind.HelperDiffers,
        subject: subject,
        detail: "cell says '" & cell.text & "'; the model derives " &
          manner(helper.get),
      )


func auditEdges(): seq[Finding] =
  ## Report moves between checkable states that the workbook leaves blank.
  for source_name in WORKBOOK_STATES:
    for destination_name in WORKBOOK_STATES:
      if source_name == destination_name or source_name.isDeferred or
          destination_name.isDeferred:
        continue
      let
        source = workbookFrame(source_name).get
        destination = workbookFrame(destination_name).get
        helper = classify(source, destination)
        named = compound(source, destination)
        filled = cellText(source_name, destination_name)
      if (helper.isNone and named.isNone) or filled.isSome:
        continue
      let
        subject = source_name & " -> " & destination_name
        reversed = cellText(destination_name, source_name)
        derived =
          if helper.isSome:
            manner(helper.get) & ": " & phrase(source, Move(
              helper: helper.get,
              side: actingSide(source, destination, helper.get),
              to: destination,
            ))
          else:
            ($named.get).toLowerAscii & ": " & compoundPhrase(source, destination)
      if reversed.isSome:
        result.add Finding(
          kind: FindingKind.ReverseAbsent,
          subject: subject,
          detail: "the sheet fills the opposite cell with '" & reversed.get &
            "'; every move reverses, so this one is " & derived,
        )
      else:
        result.add Finding(
          kind: FindingKind.EdgeAbsent,
          subject: subject,
          detail: "the model derives " & derived,
        )


func audit*(): seq[Finding] =
  ## Report everything the model has to say about the workbook's `base` sheet.
  result.add auditStates()
  result.add auditFrames()
  result.add auditCells()
  result.add auditEdges()
