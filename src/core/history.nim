## Record scene-content edits so they can be walked back and forward.
##
## **One fixed-size array of snapshots plus one cursor**, not separate past and future stacks.
## The scene is a plain fixed-size value type, so recording is a value copy and the entry
## under the cursor is always exactly the live scene. Undo and redo move the cursor and copy
## back; a fresh edit truncates everything past it.
##
## Scope is scene content — add, apply, remove, visibility, recolour, and an edit session's
## save — and deliberately not camera moves.

{.experimental: "strictFuncs".}

import ./[config, scene]



#[ Type Definitions ]#

type History* = object
  ## Hold recorded scenes and the cursor addressing the live one.
  snapshots: array[HISTORY_CAPACITY, Scene]
  length: int
  cursor: int



#[ History Construction ]#

func initHistory*(scene: Scene): History =
  ## Seed the timeline with the scene tracking begins at.
  ##   Seeded wherever the scene is initialised or replaced — startup, demo load, clear — so
  ##   undo never reaches past the moment tracking began.
  result.snapshots[0] = scene
  result.length = 1
  result.cursor = 0



#[ History Queries ]#

func canUndo*(history: History): bool {.inline.} = history.cursor > 0
  ## Report whether there is an earlier scene to return to.

func canRedo*(history: History): bool {.inline.} =
  ## Report whether there is a later scene to return to.
  history.cursor + 1 < history.length

func len*(history: History): int {.inline.} = history.length
  ## Count recorded snapshots.

func current*(history: History): Scene {.inline.} = history.snapshots[history.cursor]
  ## Read the snapshot under the cursor, which is always the live scene.



#[ History Mutation ]#

func record*(history: var History, scene: Scene) =
  ## Record a scene-content edit, truncating any redo path past the cursor.
  ##   Recording past capacity drops the oldest entry rather than growing.
  history.cursor += 1
  if history.cursor >= HISTORY_CAPACITY:
    for i in 0 ..< HISTORY_CAPACITY - 1:
      history.snapshots[i] = history.snapshots[i + 1]
    history.cursor = HISTORY_CAPACITY - 1
  history.snapshots[history.cursor] = scene
  history.length = history.cursor + 1


func undo*(history: var History, scene: var Scene): bool =
  ## Step back one edit, reporting whether there was one.
  if not history.canUndo: return false
  history.cursor -= 1
  scene = history.snapshots[history.cursor]
  true


func redo*(history: var History, scene: var Scene): bool =
  ## Step forward one edit, reporting whether there was one.
  if not history.canRedo: return false
  history.cursor += 1
  scene = history.snapshots[history.cursor]
  true
