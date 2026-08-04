## Stage an object being added or edited, without writing it to the scene.
##
## Adding an object and editing one are the same gesture, so they are one type in two modes:
## composing, which has no backing slot, and editing, which has the row's own. That is why the
## session's slot is itself optional — a **nested optional**, honest about the two modes, with
## no sentinel slot standing for "new".
##
## A session never writes to the scene before `save`. That is what makes the preview safe: it
## stays invisible to the scene's own item enumeration, and so to undo/redo, save/load and
## picking. Writing a half-built object into a real slot breaks all four.

{.experimental: "strictFuncs".}

import std/options

import ./[algebra, palette, scene]



#[ Type Definitions ]#

type
  Session* = object
    ## Stage the sixteen coefficients, the label and the colour of one object.
    slot: Option[Slot]  ## Backing slot while editing; nothing while composing.
    staged: Multivector
    label: Label
    paint: Paint

  SessionMode* {.pure.} = enum
    ## Name which of the two modes a session is in.
    Composing, ## No backing slot: nothing is in the scene yet.
    Editing,   ## A backing slot: the row's own object.



#[ Session Construction ]#

func initComposing*(paint: Paint, label: Label): Session =
  ## Start a session for a new object, backed by no slot.
  Session(slot: none(Slot), staged: Multivector(), label: label, paint: paint)


func initEditing*(scene: Scene, slot: Slot): Option[Session] =
  ## Start a session for an existing object, staging a copy of what it holds.
  if not scene.isLive(slot): return
  some(Session(
    slot: some(slot),
    staged: scene.geometry(slot),
    label: scene.label(slot),
    paint: scene.paint(slot),
  ))



#[ Session Queries ]#

func mode*(session: Session): SessionMode {.inline.} =
  ## Name which mode a session is in.
  if session.slot.isSome: SessionMode.Editing else: SessionMode.Composing

func slot*(session: Session): Option[Slot] {.inline.} = session.slot
  ## Read the backing slot, where the session has one.

func staged*(session: Session): Multivector {.inline.} = session.staged
  ## Read the multivector the session has staged, which the ghost previews.

func label*(session: Session): Label {.inline.} = session.label
  ## Read the staged label, which is the session's own storage rather than the scene's.

func paint*(session: Session): Paint {.inline.} = session.paint
  ## Read the staged colour.

func coefficient*(session: Session, b: Basis): float {.inline.} =
  ## Read one staged coefficient.
  session.staged.coefficient(b)



#[ Session Mutation ]#

func setCoefficient*(session: var Session, b: Basis, value: float) =
  ## Write one staged coefficient.
  session.staged = session.staged.withCoefficient(b, value)

func setStaged*(session: var Session, m: Multivector) =
  ## Write every staged coefficient at once.
  session.staged = m

func setLabel*(session: var Session, label: Label) =
  ## Write the staged label.
  session.label = label

func setPaint*(session: var Session, paint: Paint) =
  ## Write the staged colour, refusing a structural slot.
  if not paint.isAssignable: return
  session.paint = paint



#[ Session Commit ]#

func save*(session: Session, scene: var Scene, now_ms: float): Option[Slot] =
  ## Commit a session: add the object while composing, write the fields back while editing.
  ##   One call, so the whole committed moment — coefficients, label and colour — is a single
  ##   entry on the undo timeline rather than a flood from three continuous widgets.
  case session.mode
  of SessionMode.Composing:
    scene.add(
      geometry = session.staged,
      label = session.label,
      born_ms = now_ms,
      paint = some(session.paint),
    )
  of SessionMode.Editing:
    let slot = session.slot.get
    if not scene.isLive(slot): return
    scene.setGeometry(slot, session.staged)
    scene.setLabel(slot, session.label)
    scene.setPaint(slot, session.paint)
    some(slot)
