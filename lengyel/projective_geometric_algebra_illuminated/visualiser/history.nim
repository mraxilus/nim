## Undo/redo over scene-content edits, as a single timeline array plus a cursor.
##
## `Scene` is already a plain, fixed-size value type -- arrays of `Multivector`/
## `Label`/`Ink`/`bool`/`float`/`Option`, no pointers or refs -- so recording a step is
## a plain value copy, not a diff or an inverse-operation log. Undo and redo do not need
## separate stacks either: one fixed-size array holding the whole edit timeline, plus
## one cursor into it, does both jobs. `entries[cursor]` is always exactly equal to the
## live `Scene`; undo/redo just move the cursor and copy that entry back out; a fresh
## edit truncates anything past the cursor (the redo-able future a new edit invalidates)
## before appending.
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

import ./scene



#[ History Configuration ]#

const CAPACITY_HISTORY* {.define: "visualiser.history_capacity".} = 32
  ## Steps of timeline retained; a round number past what one editing session
  ## plausibly needs. Costs CAPACITY_HISTORY * sizeof(Scene) of fixed reservation --
  ## Scene is already small and fixed-size, so this is cheap; see
  ## panel.layoutDiagnosticsObjectPool's own BYTES_SCENE figure.
  ##   Settable alongside `visualiser.items_max` and `visualiser.label_max`, so the suite
  ## can run once at these defaults and once at capacities small enough that a test
  ## reaches them, e.g. `--define:visualiser.history_capacity=8`.

static:
  doAssert CAPACITY_HISTORY >= 2,
    &"History must hold an initial state and one edit; got `{CAPACITY_HISTORY}`."



#[ Type Definitions ]#

type History* = object ## Fixed-capacity timeline of scene snapshots, plus a cursor
  ## onto the entry equal to the live scene right now.
  entries: array[CAPACITY_HISTORY, Scene] ## Snapshot recorded at each committed edit.
  count: int    ## Valid timeline entries so far, <= CAPACITY_HISTORY.
  cursor: int   ## Index of the entry equal to the live scene right now.



#[ History Editing ]#

proc initHistory*(scene: Scene): History =
  ## Start a fresh one-entry timeline anchored at scene's own current state -- call
  ## whenever scene itself is reset (program start, load, clear), so undo never
  ## reaches earlier than the moment tracking began.
  result.entries[0] = scene
  result.count = 1
  result.cursor = 0


proc record*(history: var History; scene: Scene) =
  ## Commit scene's current (post-edit) state as the timeline's new latest entry,
  ## discarding any redo-able future beyond the cursor first -- call once, right after
  ## an edit settles, never before it.
  history.cursor.inc
  if history.cursor >= CAPACITY_HISTORY:
    # Oldest entry drops off the front rather than the array growing, to keep history
    # within its fixed capacity.
    for index in 0 ..< CAPACITY_HISTORY - 1:
      history.entries[index] = history.entries[index + 1]
    history.cursor = CAPACITY_HISTORY - 1
  history.entries[history.cursor] = scene
  history.count = history.cursor + 1


func canUndo*(history: History): bool = history.cursor > 0
  ## Report whether an earlier entry exists to undo back to.


func canRedo*(history: History): bool = history.cursor < history.count - 1
  ## Report whether a later entry exists to redo forward to.


proc undo*(history: var History; scene: var Scene): bool {.discardable.} =
  ## Move cursor one entry earlier and copy it back into scene; report whether there
  ## was an earlier entry to move to.
  if not history.canUndo: return false
  history.cursor.dec
  scene = history.entries[history.cursor]
  true


proc redo*(history: var History; scene: var Scene): bool {.discardable.} =
  ## Move cursor one entry later and copy it back into scene; report whether there was
  ## a later entry to move to.
  if not history.canRedo: return false
  history.cursor.inc
  scene = history.entries[history.cursor]
  true
