## Undo/redo over scene-content edits, as a single timeline array plus a cursor.
##
## `Scene` and `Camera` are both plain, fixed-size value types -- arrays of `Multivector`/
## `Label`/`Ink`/`bool`/`float`/`Option` and five floats, no pointers or refs -- so
## recording a step is a plain value copy, not a diff or an inverse-operation log. Undo and
## redo do not need separate stacks either: one fixed-size array holding the whole edit
## timeline, plus one cursor into it, does both jobs. `entries[cursor]` is always exactly
## equal to the live state; undo/redo just move the cursor and copy that entry back out; a
## fresh edit truncates anything past the cursor (the redo-able future a new edit
## invalidates) before appending.
##
## **The camera rides along, but never moves the timeline by itself.** Each step records
## where the camera stood when that step's own edit was made, so undoing a construction puts
## the view back where it was made from -- the thing that vanishes or comes back should do
## so on screen. Note which camera that is: a step's camera belongs to the *edit*, not to
## the state, so both stepping off a step and stepping back onto it restore that one camera.
## Restoring instead the camera of the state arrived at would hand back whatever view the
## *previous* edit happened to be made from, however long ago and however far away -- a real
## enough trap that driving the browser build found it before this comment was written.
##   The first entry is the exception that proves it: no edit leads into the seeded state,
## so nothing ever restores the camera it was seeded under. It is kept anyway, so a `Step`
## means one thing everywhere rather than "except this one".
##   What this deliberately does *not* do is make an orbit its own undoable step: a camera
## gesture emits an event per pixel of pointer movement, so recording one would need a
## settle rule to coalesce a drag into a single entry, and this timeline is about scene
## content. **An accidental orbit is therefore still not undoable on its own.** Said out
## loud rather than left to be discovered.
##
## Scoped to scene-content edits -- add, apply-operation, remove, visibility toggle, ink
## recolour -- each a discrete, single-action edit with an obvious moment to commit.
## Not covered: live label text-editing and coefficient-drag widgets, both continuous,
## multi-frame inputs with no clean "edit committed" boundary in the current GUI shim;
## recording every keystroke or drag-frame would flood the timeline uselessly. A known
## limitation, not a silent gap.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/strformat

import ./[camera, scene]



#[ History Configuration ]#

const CAPACITY_HISTORY* {.define: "visualiser.history_capacity".} = 32
  ## Steps of timeline retained; a round number past what one editing session
  ## plausibly needs. Costs CAPACITY_HISTORY * sizeof(Step) of fixed reservation --
  ## a Scene is already small and fixed-size and a Camera is five floats beside it, so
  ## this is cheap; see panel.layoutDiagnosticsObjectPool's own BYTES_SCENE figure.
  ##   Settable alongside `visualiser.items_max` and `visualiser.label_max`, so the suite
  ## can run once at these defaults and once at capacities small enough that a test
  ## reaches them, e.g. `--define:visualiser.history_capacity=8`.

static:
  doAssert CAPACITY_HISTORY >= 2,
    &"History must hold an initial state and one edit; got `{CAPACITY_HISTORY}`."



#[ Type Definitions ]#

type
  Step* = object ## Hold one committed edit: the scene it produced, and where the camera
    ## stood when it was made.
    scene*: Scene
    camera*: Camera ## Where the view stood as *this* step's edit was made -- so it is the
      ## camera to restore in either direction across this step, not the camera to restore
      ## on arriving at this step's scene. The first entry's is the view tracking began
      ## under, and is never restored: no edit leads into it.

  History* = object ## Fixed-capacity timeline of steps, plus a cursor onto the one equal
    ## to the live scene right now.
    entries: array[CAPACITY_HISTORY, Step] ## Snapshot recorded at each committed edit.
    count: int    ## Valid timeline entries so far, <= CAPACITY_HISTORY.
    cursor: int   ## Index of the entry equal to the live scene right now.



#[ History Editing ]#

proc initHistory*(scene: Scene; camera: Camera): History =
  ## Start a fresh one-entry timeline anchored at the current state -- call whenever the
  ## scene itself is reset (program start, load, clear), so undo never reaches earlier
  ## than the moment tracking began.
  ##   `camera` completes the entry rather than being read back: nothing undoes past the
  ##   first step, so no traversal ever restores it. See `Step.camera`.
  result.entries[0] = Step(scene: scene, camera: camera)
  result.count = 1
  result.cursor = 0


proc record*(history: var History; scene: Scene; camera: Camera) =
  ## Commit the current (post-edit) state as the timeline's new latest entry, discarding
  ## any redo-able future beyond the cursor first -- call once, right after an edit
  ## settles, never before it.
  ##   `camera` is where the view stood as the edit was made, so undoing back to this step
  ##   restores it; it never appends a step of its own. See this module's own header.
  history.cursor.inc
  if history.cursor >= CAPACITY_HISTORY:
    # Oldest entry drops off the front rather than the array growing, to keep history
    # within its fixed capacity.
    for index in 0 ..< CAPACITY_HISTORY - 1:
      history.entries[index] = history.entries[index + 1]
    history.cursor = CAPACITY_HISTORY - 1
  history.entries[history.cursor] = Step(scene: scene, camera: camera)
  history.count = history.cursor + 1


func canUndo*(history: History): bool = history.cursor > 0
  ## Report whether an earlier entry exists to undo back to.


func canRedo*(history: History): bool = history.cursor < history.count - 1
  ## Report whether a later entry exists to redo forward to.


proc undo*(history: var History; scene: var Scene; camera: var Camera): bool
  {.discardable.} =
  ## Move cursor one entry earlier and copy that entry's scene back out, under the view the
  ## step just undone was made from; report whether there was an earlier entry to move to.
  ##   Scene and camera come from *different* entries on purpose: the scene is the earlier
  ##   state being returned to, the camera is the one belonging to the step being stepped
  ##   off, which is the view whatever just vanished was last visible in. See `Step.camera`.
  ##   A caller holding a camera tween has to abandon it after this, or the standing aim
  ##   carries the view straight back off the restored placement.
  if not history.canUndo: return false
  camera = history.entries[history.cursor].camera
  history.cursor.dec
  scene = history.entries[history.cursor].scene
  # A whole-scene assignment, which restores that entry's own revision rather than
  #   advancing this one's; see `scene.revision` for why the rule is stated as a bump.
  scene.markEdited()
  true


proc redo*(history: var History; scene: var Scene; camera: var Camera): bool
  {.discardable.} =
  ## Move cursor one entry later and copy it back into the scene and camera; report
  ## whether there was a later entry to move to. Same tween caveat as `undo`.
  ##   Both come from the entry arrived at, which is the same step `undo` reads its camera
  ##   from -- so crossing one step either way puts the view in the same place.
  if not history.canRedo: return false
  history.cursor.inc
  scene = history.entries[history.cursor].scene
  camera = history.entries[history.cursor].camera
  # See `undo` above: a whole-scene assignment says so itself.
  scene.markEdited()
  true
