## Hold what is picked, in the order it was picked.
##
## Selection is an **ordered fixed-capacity list of slots, not a set**. The order is the whole
## point: an operation reads its operands positionally, so the first slot picked is 𝐦 and the
## second 𝐧. The rule that one pick means a unary operation and two or more a binary one lives
## here and is read by both front-ends, so the two can never disagree about what a selection
## means.
##
## Selection is deliberately not part of the scene: never saved, never on the undo timeline,
## and cleared outright by a successful undo or redo, since a restored snapshot's slot numbers
## need not match what was picked.

{.experimental: "strictFuncs".}

import std/options

import ./[catalogue, config, scene]



#[ Type Definitions ]#

type Selection* = object
  ## Hold picked slots in pick order.
  slots: array[SELECTION_CAPACITY, Slot]
  length: int



#[ Selection Queries ]#

func len*(selection: Selection): int {.inline.} = selection.length
  ## Count picked slots.

func at*(selection: Selection, i: int): Slot {.inline.} = selection.slots[i]
  ## Read the slot picked in a given position.

func isEmpty*(selection: Selection): bool {.inline.} = selection.length == 0
  ## Report whether nothing is picked.

func contains*(selection: Selection, slot: Slot): bool =
  ## Report whether a slot is picked.
  for i in 0 ..< selection.length:
    if selection.slots[i] == slot: return true
  false


func sole*(selection: Selection): Option[Slot] =
  ## Read the one picked slot, where exactly one is picked.
  if selection.length != 1: return
  some(selection.slots[0])


func arity*(selection: Selection): Arity =
  ## Name what a selection of this size means: one pick unary, two or more binary.
  if selection.length <= 1: Arity.Unary else: Arity.Binary


func first*(selection: Selection): Option[Slot] =
  ## Read the slot standing for 𝐦.
  if selection.length < 1: return
  some(selection.slots[0])


func second*(selection: Selection): Option[Slot] =
  ## Read the slot standing for 𝐧.
  if selection.length < 2: return
  some(selection.slots[1])


func isEntirelyHidden*(selection: Selection, scene: Scene): bool =
  ## Report whether every picked object is already hidden.
  ##   A rule about a selection, so it belongs beside the selection rather than in a script
  ##   layer's own pass over the picked slots.
  if selection.length == 0: return false
  for i in 0 ..< selection.length:
    let slot = selection.slots[i]
    if scene.isLive(slot) and scene.isVisible(slot): return false
  true



#[ Selection Mutation ]#

func clear*(selection: var Selection) =
  ## Drop every pick.
  selection.length = 0


func replaceWith*(selection: var Selection, slot: Slot) =
  ## Pick one slot alone, as every construction path does with what it just built.
  selection.length = 1
  selection.slots[0] = slot


func toggle*(selection: var Selection, slot: Slot) =
  ## Add a slot to the picks, or drop it where it is already picked.
  ##   Keeps pick order for the survivors, since that order names the operands.
  for i in 0 ..< selection.length:
    if selection.slots[i] != slot: continue
    for j in i ..< selection.length - 1:
      selection.slots[j] = selection.slots[j + 1]
    selection.length -= 1
    return
  if selection.length >= SELECTION_CAPACITY: return
  selection.slots[selection.length] = slot
  selection.length += 1


func prune*(selection: var Selection, scene: Scene) =
  ## Drop picks whose slots no longer address an item.
  ##   Run after any removal: a freed slot goes straight back to the next add, and a stale
  ##   pick would silently reattach to an unrelated object.
  var surviving = 0
  for i in 0 ..< selection.length:
    if not scene.isLive(selection.slots[i]): continue
    selection.slots[surviving] = selection.slots[i]
    surviving += 1
  selection.length = surviving


iterator items*(selection: Selection): Slot =
  ## Walk picked slots in pick order.
  for i in 0 ..< selection.length:
    yield selection.slots[i]
