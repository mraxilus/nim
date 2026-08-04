## Hold the `base` sheet of the partner-work workbook and audit it against the
## derived model.
##
## The workbook is the source the ontology grew from, so it is treated as
## evidence rather than as truth: every cell is checked against the primitive
## that the physics gives for the same pair of frames, and every disagreement is
## reported with its kind.  Keeping the sheet here as data means the audit is a
## test, not a memory of one afternoon's reading.
##
## The transcription is of the `base` sheet only.  The `rotations` sheet and the
## twelve turn sheets carry headers and no cells, apart from three entries in
## `rotations`, which `rotation.nim` records instead.

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

func workbookFrame*(name: string): Option[Frame] =
  ## Read a workbook state name as a frame.
  ##
  ## The two body-contact names are the reading the matrix forces: `closed`
  ## slides to `Left-to-right and Right-to-left` and `half-closed` slides to
  ## `Right to left`, and only a right hand resting on the follow's torso can do
  ## either, because a hand can only travel down the arm it already touches.
  var built = Frame()
  case name
  of "closed":
    built.hold[Side.Left] = some(Site.RightHand)
    built.hold[Side.Right] = some(Site.Torso)
  of "half-closed":
    built.hold[Side.Right] = some(Site.Torso)
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
  ## Read one helper word from a cell, including the workbook's synonyms.
  case word.strip()
  of "collect": some(Helper.Collect)
  of "drop", "flick": some(Helper.Drop)
  of "slide", "trace": some(Helper.Trace)
  of "pass", "place": some(Helper.Pass)
  of "cut": some(Helper.Cut)
  else: none(Helper)


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



#[ Audit ]#

type
  FindingKind* {.pure.} = enum ## Name a way the workbook and the model disagree.
    FrameAbsent,      ## Frame the idiom admits that the workbook has no row for.
    EdgeAbsent,       ## Single primitive between two workbook states, with an empty cell.
    ReverseAbsent,    ## Filled cell whose mirror cell is empty, though moves reverse.
    EdgeCompound,     ## Cell naming a sequence, so a route rather than a move.
    HelperDiffers,    ## Cell naming a primitive other than the derived one.
    EdgeUnsupported   ## Filled cell the physics gives no route for.

  Finding* = object ## Hold one disagreement between the workbook and the model.
    kind*: FindingKind
    subject*: string ## Frame or pair of frames the finding concerns.
    detail*: string  ## What the model says, in the ontology's vocabulary.


func auditFrames(convention: Convention): seq[Finding] =
  ## Report frames the idiom admits that the workbook never names.
  for target in convention.admitted:
    if workbookName(target).isSome:
      continue
    result.add Finding(
      kind: FindingKind.FrameAbsent,
      subject: target.title,
      detail: target.describe & " is admitted by the idiom and has " &
        $moves(target, convention).len & " moves, but the sheet has no row for it",
    )


func auditCells(convention: Convention): seq[Finding] =
  ## Report cells that disagree with the primitive the physics gives.
  for cell in CELLS:
    let
      source = workbookFrame(cell.source).get
      destination = workbookFrame(cell.destination).get
      helper = classify(source, destination)
      words = readCell(cell.text)
      subject = cell.source & " -> " & cell.destination
    if words.len > 1:
      let steps = route(source, destination, convention)
      result.add Finding(
        kind: FindingKind.EdgeCompound,
        subject: subject,
        detail: "cell names " & $words.len & " helpers; the model derives a route of " &
          $steps.len & " primitives, so this is a path and not a move",
      )
      continue
    if helper.isNone:
      let steps = route(source, destination, convention)
      result.add Finding(
        kind: FindingKind.EdgeUnsupported,
        subject: subject,
        detail: "no single primitive joins these frames; shortest route is " &
          $steps.len & " primitives",
      )
      continue
    let named = readHelper(words[0])
    if named.isNone or named.get != helper.get:
      result.add Finding(
        kind: FindingKind.HelperDiffers,
        subject: subject,
        detail: "cell says '" & cell.text & "'; the model derives " &
          HELPER_MANNERS[helper.get],
      )


func auditEdges(convention: Convention): seq[Finding] =
  ## Report moves between named states that the workbook leaves blank.
  for source_name in WORKBOOK_STATES:
    for destination_name in WORKBOOK_STATES:
      if source_name == destination_name:
        continue
      let
        source = workbookFrame(source_name).get
        destination = workbookFrame(destination_name).get
        helper = classify(source, destination)
        filled = cellText(source_name, destination_name)
      if helper.isNone or filled.isSome:
        continue
      let subject = source_name & " -> " & destination_name
      let reversed = cellText(destination_name, source_name)
      if reversed.isSome:
        result.add Finding(
          kind: FindingKind.ReverseAbsent,
          subject: subject,
          detail: "the sheet fills the opposite cell with '" & reversed.get &
            "'; every primitive reverses, so this one is " &
            HELPER_MANNERS[helper.get],
        )
      else:
        result.add Finding(
          kind: FindingKind.EdgeAbsent,
          subject: subject,
          detail: "the model derives " & HELPER_MANNERS[helper.get] &
            ": " & phrase(source, Move(
              helper: helper.get,
              side: actingSide(source, destination, helper.get),
              to: destination,
            )),
        )


func audit*(convention = Convention.Salsa): seq[Finding] =
  ## Report every disagreement between the workbook's `base` sheet and the model.
  result.add auditFrames(convention)
  result.add auditCells(convention)
  result.add auditEdges(convention)
