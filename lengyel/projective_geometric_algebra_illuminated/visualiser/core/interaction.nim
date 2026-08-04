## Track a drag gesture from one scene item to another, and apply the operation it names.
##
## Each mouse button names one binary operation: left joins, right meets, middle projects.
## A drag begins only when the press itself lands on a pickable item — press on empty space
## is left for camera orbit or pan instead, so the two schemes never compete for one click.
##
## Hover is tracked independently of dragging, every frame, purely so the item a drag would
## start from can be shown before any button is pressed.
##
## A *hold* is the touch counterpart, where there are no buttons to name an operation with:
## press an item and keep still, and once the press has lasted `MILLISECONDS_LONG_PRESS` it
## selects that item. The elapsed fraction lives here rather than in either presentation
## layer, because how long a hold takes and whether one is due are rules about this gesture,
## not about a timer -- and because both are what the item's own marker is drawn part-built
## from, which is the only reason a half-second wait is bearable.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ./[camera, format, picking, scene]



#[ Gesture Configuration ]#

const MILLISECONDS_LONG_PRESS* = 500.0
  ## Hold a touch this long on an item to select it.
  ##   Long enough that a tap, or the first instant of a drag meant to orbit the camera,
  ##   never matures into one; short enough that a deliberate hold does not feel stuck.
  ##   The wait is only tolerable because it is *shown* -- `progressHold` below drives the
  ##   item's own marker being drawn part-built, so a hold reads as filling rather than as
  ##   nothing happening. A hold with no feedback at this duration reads as a broken tap.



#[ Type Definitions ]#

type
  DragOperation* {.pure.} = enum ## Name operation a mouse button performs while dragging.
    Join, ## Left button; wedge, i.e. join.
    Meet, ## Right button; antiwedge, i.e. meet.
    Project, ## Middle button; orthogonal projection of source onto destination.

  Hold* = object ## Hold a press that will select its item once it has lasted long enough.
    slot*: int ## Item pressed, and the one whose marker fills as the press matures.
    started*: float ## When the press landed, on the same clock every caller passes as `now`.

  Interaction* = object ## Hold cursor, drag and press state between frames.
    is_enabled*: bool ## Whether picking and overlay run at all; off during storyboard capture.
    cursor*: ScreenPosition ## Last known cursor position, in window pixels.
    index_hover*: Option[int] ## Item nearest cursor this frame, regardless of dragging.
    operation*: Option[DragOperation] ## Operation of drag in progress, if any.
    index_source*: int ## Item drag started from; meaningful only while `operation` is some.
    hold*: Option[Hold] ## Press maturing into a selection, if one is in progress.



#[ Operation Vocabulary ]#

type PointerButton* {.pure.} = enum ## Name a physical mouse button, however numbered.
  ## Neither backend's own numbering: SDL and the DOM count the three buttons
  ## differently (SDL 1/2/3 left/middle/right, the DOM 0/1/2 left/middle/right), so each
  ## render path translates its own numbers into this and asks `dragForButton` below.
  ## That keeps *which button does what* stated once, while leaving each path the
  ## translation only it can do.
  Left, Middle, Right


func dragForButton*(button: PointerButton): Option[DragOperation] =
  ## Name the operation a button starts a drag with, if it starts one at all.
  case button
  of PointerButton.Left: some(DragOperation.Join)
  of PointerButton.Right: some(DragOperation.Meet)
  of PointerButton.Middle: some(DragOperation.Project)


func toOperation*(drag: DragOperation): Operation =
  ## Translate drag's own vocabulary to library's operation catalogue.
  case drag
  of DragOperation.Join: Operation.Wedge
  of DragOperation.Meet: Operation.WedgeAnti
  of DragOperation.Project: Operation.ProjectOrthogonal


func notation*(drag: DragOperation): string =
  ## Name drag operation for messages, in library's own ASCII notation.
  case drag
  of DragOperation.Join: "^"
  of DragOperation.Meet: "v"
  of DragOperation.Project: "->"


func outcome*(drag: DragOperation): string =
  ## Say what dragging one object onto another with this operation does, in plain words.
  ##   Here beside the operation rather than in the help table that prints it, so the two
  ##   cannot come to disagree, and because only one of the three reads naturally as
  ##   "<verb> them" -- a projection is asymmetric and has to say which way round it goes,
  ##   which is exactly the thing a reader dragging for the first time needs told.
  case drag
  of DragOperation.Join: "join them into a new object"
  of DragOperation.Meet: "meet them, where they cross"
  of DragOperation.Project: "project the first onto the second"



#[ Cursor And Hover ]#

proc updateCursor*(interaction: var Interaction; x, y: float) =
  ## Record cursor's latest window position.
  interaction.cursor = ScreenPosition(x: x, y: y, depth: 0.0)


proc updateHover*(
  interaction: var Interaction; scene: Scene;
  camera: Camera; view_projection: Matrix4; width, height: int
) =
  ## Recompute item nearest cursor, so overlay and drag-start agree on what stands under it.
  interaction.index_hover =
    if interaction.is_enabled:
      pickNearest(scene, camera, view_projection, width, height, interaction.cursor)
    else:
      none(int)



#[ Hold Lifecycle ]#

proc beginHold*(interaction: var Interaction; slot: int; now: float) =
  ## Start a press on `slot` that will select it once it has lasted long enough.
  interaction.hold = some(Hold(slot: slot, started: now))


proc cancelHold*(interaction: var Interaction) =
  ## Abandon a press in progress, selecting nothing.
  ##   What the caller reaches for when the finger moved into a camera gesture, a second
  ##   finger landed, the press was released early, or the user pressed escape.
  interaction.hold = none(Hold)


func progressHold*(interaction: Interaction; now: float): float =
  ## Report how far a press in progress has matured, from 0 at the press to 1 once it is
  ## due; 0 where no press is in progress.
  ##   Clamped at both ends, so a caller may keep asking after the press is due and after
  ##   the clock has jumped, and still get something it can draw.
  ##   Linear, deliberately, and not through `mesh.easeOutCubic` as every other animation
  ##   here is: this is a clock being shown rather than a transition being softened, and an
  ##   eased clock reads as stalling just before it fires -- exactly where a user is
  ##   deciding whether the hold is working.
  if interaction.hold.isNone: return 0.0
  let elapsed = now - interaction.hold.get.started
  max(0.0, min(1.0, elapsed/MILLISECONDS_LONG_PRESS))


func isHoldMature*(interaction: Interaction; now: float): bool =
  ## Report whether a press in progress has lasted long enough to select its item.
  ##   Stated against `progressHold` rather than against the elapsed time again, so the
  ##   moment the marker finishes filling is the same moment the selection lands. Two
  ##   comparisons against the same duration would be two chances to disagree.
  interaction.hold.isSome and progressHold(interaction, now) >= 1.0



#[ Drag Lifecycle ]#

proc beginDrag*(interaction: var Interaction; drag: DragOperation): bool =
  ## Start dragging `drag`'s operation from item currently hovered.
  ##   Reports whether a drag actually started, so caller knows whether to fall back to
  ##   camera orbit or pan instead.
  if interaction.index_hover.isNone: return false
  interaction.operation = some(drag)
  interaction.index_source = interaction.index_hover.get
  true


proc cancelDrag*(interaction: var Interaction) =
  ## Abandon drag in progress without applying anything.
  interaction.operation = none(DragOperation)


proc endDrag*(
  interaction: var Interaction; scene: var Scene; now: float = 0.0
): tuple[message: string, index_created: Option[int]] =
  ## Apply drag's operation between source and hovered item, if both still make sense.
  ##   Always clears drag state; message names outcome, even where nothing was done.
  ##   `index_created` names the slot just built, for caller to draw ringed as if freshly
  ##   selected; `none` wherever nothing was actually added.
  ##   `now` is forwarded to the derived item's `addItem` untouched, so it animates in
  ##   exactly as one added through the panel does.
  defer: interaction.operation = none(DragOperation)
  if interaction.operation.isNone: return ("", none(int))
  let drag = interaction.operation.get

  if interaction.index_hover.isNone:
    return ("Drag released over empty space; nothing done.", none(int))
  let index_destination = interaction.index_hover.get
  if index_destination == interaction.index_source:
    return ("Drag released on its own source; nothing done.", none(int))

  # Source or destination may have been removed (or replaced by undo/redo) since the
  #   drag began -- both are slots carried across frames, not re-picked at release
  #   time, so either can go stale without a mouse ever moving. Bail out the same way
  #   as any other drag that resolves to nothing, rather than reading a freed slot.
  if not (scene.isAlive(interaction.index_source) and scene.isAlive(index_destination)):
    return ("Drag's source or destination no longer exists; nothing done.", none(int))

  let
    label_source = toText(scene.labelAt(interaction.index_source))
    label_destination = toText(scene.labelAt(index_destination))
    operand_source = scene[interaction.index_source].geometry
    operand_destination = scene[index_destination].geometry
    derived = applyOperation(drag.toOperation, operand_source, operand_destination)
    anchor = creationAnchor(drag.toOperation, operand_source, operand_destination, derived)
    index_created = scene.addItem(
      derived, &"{label_source} {drag.notation} {label_destination}", inkCycled(scene.len), now,
      anchor,
    )

  (
    &"{label_source} {drag.notation} {label_destination} gave {shapeText(derived)}.",
    some(index_created),
  )
