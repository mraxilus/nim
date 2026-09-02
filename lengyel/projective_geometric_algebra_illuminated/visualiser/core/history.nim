## Undo/redo over scene-content edits, as one timeline ring plus cursor.
##
## `Scene` and `Camera` are plain fixed-size value types, so recording step is value copy,
## not diff or inverse-operation log. One ring holding whole timeline plus one cursor does
## both jobs: entry at cursor always equals live state; undo/redo move cursor and copy
## entry back out; fresh edit truncates redo-able future before appending. `slotOf` is
## only place timeline position becomes array index.
##
## **Camera rides along, never moves timeline by itself.** Each step records where camera
## stood when its edit was made, so undoing construction puts view back where it was made
## from. Step's camera belongs to *edit*, not state: stepping off step and stepping back
## onto it restore that one camera. Restoring camera of state arrived at would hand back
## view *previous* edit was made from -- trap driving browser build found.
##   First entry is exception: no edit leads into seeded state, so its camera is never
## restored. Kept anyway, so `Step` means one thing everywhere.
##   Orbit is deliberately not own undoable step: camera gesture emits event per pixel, so
## recording one needs settle rule, and timeline is about scene content. **Accidental
## orbit is not undoable on its own.**
##
## Scoped to discrete scene-content edits: add, apply-operation, remove, visibility
## toggle, ink recolour. Not covered: live label editing and coefficient drags, continuous
## inputs with no clean commit boundary; recording every keystroke would flood timeline.
##
## Shared by desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render paths.

{.experimental: "strictFuncs".}

import std/strformat

import ./[camera, scene]



#[ History Configuration ]#

const CAPACITY_HISTORY* {.define: "visualiser.history_capacity".} = 32
  ## Steps of timeline retained.
  ##   Costs CAPACITY_HISTORY * sizeof(Step) of fixed reservation, and Step is whole Scene,
  ## so this scales with `scene.ITEMS_MAX`: **not** cheap. At 10,080 slots Scene measured
  ## 2.22 MiB, thirty-two of them 71.1 MiB and 209 MB of JS heap (every slot there is boxed
  ## object); capacity is 5,040 now, halving each. Largest reservation binary makes,
  ## counted by `visualiser.BYTES_MEMORY_TOTAL`.
  ##   Kept at 32: since timeline became ring, depth costs nothing per edit (see `record`),
  ## so what remains is flat reservation, linear per step. One lever to pull if page must
  ## be lighter.
  ##   Settable beside `visualiser.items_max` and `visualiser.label_max`, so suite runs
  ## once at defaults and once at capacities small enough that test reaches them, e.g.
  ## `--define:visualiser.history_capacity=8`.

static:
  doAssert CAPACITY_HISTORY >= 2,
    &"History must hold an initial state and one edit; got `{CAPACITY_HISTORY}`."



#[ Type Definitions ]#

type
  Step* = object ## Hold one committed edit: scene it produced, and where camera stood.
    scene*: Scene
    camera*: Camera ## Where view stood as *this* step's edit was made -- camera to restore
      ## in either direction across this step, not on arriving at its scene. First entry's
      ## is never restored: no edit leads into it.

  History* = object ## Hold fixed-capacity timeline of steps, plus cursor onto one equal to
    ## live scene.
    ##   Array is **ring**: `count` and `cursor` are timeline positions, `first` says which
    ## slot holds oldest, and `slotOf` alone relates them. Dropping oldest step moves one
    ## integer; see `record`.
    entries: array[CAPACITY_HISTORY, Step] ## Snapshot per committed edit, in ring order;
      ## reach one through `slotOf`, never by indexing directly.
    first: int    ## Array slot holding oldest step, timeline position 0.
    count: int    ## Valid timeline entries so far, <= CAPACITY_HISTORY.
    cursor: int   ## Timeline position of entry equal to live scene right now.



#[ Ring Indexing ]#

func slotOf(history: History; position: int): int =
  ## Report array slot holding step at `position` along timeline, 0 being oldest retained.
  ##   Every read and write of `entries` goes through here: position is not array index,
  ## and two must never be spelled same way.
  (history.first + position) mod CAPACITY_HISTORY



#[ History Editing ]#

proc initHistory*(history: var History; scene: Scene; camera: Camera) =
  ## Start fresh one-entry timeline anchored at current state -- call whenever scene is
  ## reset (program start, load, clear), so undo never reaches earlier than tracking began.
  ##   Fills timeline caller holds, field by field. Returning `History` compiled to
  ## `nimCopy` of thirty-two scenes on JS backend, 65% of largest demo load; `Step`
  ## literal copied scene twice. Caller owning storage is what `STYLE.md` asks for.
  ##   `camera` completes entry rather than being read back; see `Step.camera`.
  history.entries[0].scene = scene
  history.entries[0].camera = camera
  history.first = 0
  history.count = 1
  history.cursor = 0


proc record*(history: var History; scene: Scene; camera: Camera) =
  ## Commit current (post-edit) state as timeline's new latest entry, discarding redo-able
  ## future -- call once, right after edit settles.
  ##   `camera` is where view stood as edit was made; it never appends step of own.
  history.cursor.inc
  if history.cursor >= CAPACITY_HISTORY:
    # Retire oldest entry by advancing `first`, handing its slot to step about to be
    #   written. Shifting every entry down was 31 scene copies per edit past capacity:
    #   153.5 ms on JS backend against 11.3 now, and no longer moves with capacity.
    history.first = (history.first + 1) mod CAPACITY_HISTORY
    history.cursor = CAPACITY_HISTORY - 1
  # Copy scene once, field by field; see `initHistory`.
  let slot = history.slotOf(history.cursor)
  history.entries[slot].scene = scene
  history.entries[slot].camera = camera
  history.count = history.cursor + 1


func canUndo*(history: History): bool = history.cursor > 0
  ## Report whether earlier entry exists to undo back to.


func canRedo*(history: History): bool = history.cursor < history.count - 1
  ## Report whether later entry exists to redo forward to.


proc undo*(history: var History; scene: var Scene; camera: var Camera): bool
  {.discardable.} =
  ## Move cursor one entry earlier and copy that entry's scene back out, under view step
  ## just undone was made from; report whether earlier entry existed.
  ##   Scene and camera come from *different* entries on purpose: scene is earlier state,
  ## camera belongs to step being stepped off, view whatever vanished was last visible in.
  ##   Caller holding camera tween abandons it after this, or standing aim carries view
  ## straight back off restored placement.
  if not history.canUndo: return false
  camera = history.entries[history.slotOf(history.cursor)].camera
  history.cursor.dec
  # Restore through `restoreFrom`, never assignment: revision must pass every one drawn.
  scene.restoreFrom(history.entries[history.slotOf(history.cursor)].scene)
  true


proc redo*(history: var History; scene: var Scene; camera: var Camera): bool
  {.discardable.} =
  ## Move cursor one entry later and copy it back into scene and camera; report whether
  ## later entry existed. Same tween caveat as `undo`.
  ##   Both come from entry arrived at, same step `undo` reads its camera from, so
  ## crossing one step either way puts view in same place.
  if not history.canRedo: return false
  history.cursor.inc
  scene.restoreFrom(history.entries[history.slotOf(history.cursor)].scene)
  camera = history.entries[history.slotOf(history.cursor)].camera
  true
