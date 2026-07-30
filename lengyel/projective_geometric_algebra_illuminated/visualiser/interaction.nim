## Track a drag gesture from one scene item to another, and apply the operation it names.
##
## Each mouse button names one binary operation: left joins, right meets, middle projects.
## A drag begins only when the press itself lands on a pickable item — press on empty space
## is left for camera orbit or pan instead, so the two schemes never compete for one click.
##
## Hover is tracked independently of dragging, every frame, purely so the item a drag would
## start from can be shown before any button is pressed.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ./[camera, format, picking, scene]



#[ Drag Configuration ]#

const WIDTH_SHAPE_WORD = 32
  ## Bound length of the shape word alone, longest being "mixed grade, nothing to draw".



#[ Type Definitions ]#

type
  DragOperation* {.pure.} = enum ## Name operation a mouse button performs while dragging.
    Join, ## Left button; wedge, i.e. join.
    Meet, ## Right button; antiwedge, i.e. meet.
    Project, ## Middle button; orthogonal projection of source onto destination.

  Interaction* = object ## Hold cursor and drag state between frames.
    is_enabled*: bool ## Whether picking and overlay run at all; off during storyboard capture.
    cursor*: ScreenPosition ## Last known cursor position, in window pixels.
    index_hover*: Option[int] ## Item nearest cursor this frame, regardless of dragging.
    operation*: Option[DragOperation] ## Operation of drag in progress, if any.
    index_source*: int ## Item drag started from; meaningful only while `operation` is some.



#[ Operation Vocabulary ]#

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



#[ Cursor And Hover ]#

proc updateCursor*(interaction: var Interaction; x, y: float) =
  ## Record cursor's latest window position.
  interaction.cursor = ScreenPosition(x: x, y: y, depth: 0.0)


proc updateHover*(
  interaction: var Interaction; scene: Scene;
  camera: Camera; view_projection: Matrix4; width, height: int;
) =
  ## Recompute item nearest cursor, so overlay and drag-start agree on what stands under it.
  interaction.index_hover =
    if interaction.is_enabled:
      pickNearest(scene, camera, view_projection, width, height, interaction.cursor)
    else:
      none(int)



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
    label_source = $toCstring(scene.labelAt(interaction.index_source))
    label_destination = $toCstring(scene.labelAt(index_destination))
    operand_source = scene[interaction.index_source].geometry
    operand_destination = scene[index_destination].geometry
    derived = applyOperation(drag.toOperation, operand_source, operand_destination)
    anchor = creationAnchor(drag.toOperation, operand_source, operand_destination, derived)
    index_created = scene.addItem(
      derived, &"{label_source} {drag.notation} {label_destination}", inkCycled(scene.len), now,
      anchor,
    )

  var shape_word: array[WIDTH_SHAPE_WORD, char]
  var cursor_shape = 0
  describeShape(derived, shape_word, cursor_shape)
  finishChars(shape_word, cursor_shape)
  (
    &"{label_source} {drag.notation} {label_destination} gave {$toCstring(shape_word)}.",
    some(index_created),
  )
