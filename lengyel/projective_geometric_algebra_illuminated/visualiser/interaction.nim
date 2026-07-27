## Track a drag gesture from one scene item to another, and apply the operation it names.
##
## Each mouse button names one binary operation: left joins, right meets, middle projects.
## A drag begins only when the press itself lands on a pickable item — press on empty space
## is left for camera orbit or pan instead, so the two schemes never compete for one click.
##
## Hover is tracked independently of dragging, every frame, purely so the item a drag would
## start from can be shown before any button is pressed.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ./[camera, picking, scene]



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


proc endDrag*(interaction: var Interaction; scene: var Scene): string =
  ## Apply drag's operation between source and hovered item, if both still make sense.
  ##   Always clears drag state; message names outcome, even where nothing was done.
  defer: interaction.operation = none(DragOperation)
  if interaction.operation.isNone: return ""
  let drag = interaction.operation.get

  if interaction.index_hover.isNone:
    return "Drag released over empty space; nothing done."
  let index_destination = interaction.index_hover.get
  if index_destination == interaction.index_source:
    return "Drag released on its own source; nothing done."

  let
    label_source = $toCstring(scene[interaction.index_source].label)
    label_destination = $toCstring(scene[index_destination].label)
    derived = applyOperation(
      drag.toOperation, scene[interaction.index_source].geometry,
      scene[index_destination].geometry,
    )
  scene.addItem(
    derived, &"{label_source} {drag.notation} {label_destination}", inkCycled(scene.len)
  )
  &"{label_source} {drag.notation} {label_destination} gave {describeShape(derived)}."
