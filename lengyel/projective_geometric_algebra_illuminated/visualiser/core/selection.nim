## Which objects are picked right now, as an ordered fixed-capacity list of slots.
##
## Order is the whole point, and the reason this is a list rather than a set: an operation
## reads its operands positionally, so the first slot picked is `m` and the second is `n`.
## A set would answer "is this selected" and lose the only other question anyone asks.
##
## Selection is deliberately **not** part of `Scene`. It is a view of the scene, not
## content: it is never saved to a `.rgascene`, never recorded on the undo timeline, and a
## restored snapshot clears it outright, since a snapshot's slot numbers need not match
## whatever was picked against the live scene.
##
## A plain fixed-size value type with no refs, like `History` beside it -- copying one is a
## value copy, so it can live in a GUI's own state struct without an allocator.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table. The browser drives it through
## `browser_bridge`'s own `nimSelect*` exports rather than keeping a parallel list in
## JavaScript, so every rule about membership, order and arity is written once here.

{.experimental: "strictFuncs".}

import ./scene



#[ Type Definitions ]#

type Selection* = object ## Hold slots picked, in the order they were picked.
  slots: array[ITEMS_MAX, int] ## Picked slots, oldest pick first; only the first `count`
    ## entries carry meaning.
  count: int ## Slots picked so far, <= ITEMS_MAX.



#[ Reading A Selection ]#

func len*(selection: Selection): int = selection.count
  ## Count slots picked.


func at*(selection: Selection; position: int): int = selection.slots[position]
  ## Read the slot picked at a position, oldest pick first. Position 0 is operand `m` and
  ## position 1 is `n`; callers bound themselves against `len`.


func contains*(selection: Selection; slot: int): bool =
  ## Report whether a slot is picked.
  for position in 0 ..< selection.count:
    if selection.slots[position] == slot: return true
  false


func impliedArity*(selection: Selection): Arity =
  ## Read the arity a selection implies: one slot names a unary operation's own operand,
  ## two or more name a binary operation's `m` and `n`.
  ##   Two *or more* rather than exactly two: a picker offering `m` and `n` can still act
  ##   on the first two of a longer selection, and reverting to unary there would silently
  ##   drop the second operand the user picked. An empty selection implies nothing, and
  ##   reports unary only because `Arity` has no way to say "neither" -- callers check
  ##   `len` first.
  if selection.count >= 2: Arity.Two else: Arity.One


func isAllHidden*(selection: Selection; scene: Scene): bool =
  ## Report whether every picked object is hidden, so a control acting on the whole
  ## selection can name what it would do -- `show` where they are all hidden, `hide`
  ## otherwise.
  ##   A rule about a selection rather than about either object, which is why it lives
  ##   here instead of each front-end folding `isVisible` over the list its own way.
  ##   An empty selection is not hidden: there is nothing there to show.
  if selection.count == 0: return false
  for position in 0 ..< selection.count:
    if scene.isVisible(selection.slots[position]): return false
  true



#[ Editing A Selection ]#

func clear*(selection: var Selection) = selection.count = 0
  ## Drop every pick.


func selectOnly*(selection: var Selection; slot: int) =
  ## Replace the whole selection with one slot.
  selection.slots[0] = slot
  selection.count = 1


func toggle*(selection: var Selection; slot: int) =
  ## Add a slot to the end of the selection, or drop it where it is already picked.
  ##   Appending rather than inserting is what makes the order meaningful: pick two
  ##   objects and they become `m` and `n` in the order you picked them.
  for position in 0 ..< selection.count:
    if selection.slots[position] != slot: continue
    for shift in position ..< selection.count - 1:
      selection.slots[shift] = selection.slots[shift + 1]
    selection.count.dec
    return
  if selection.count >= ITEMS_MAX: return # Every slot already picked; nothing to add.
  selection.slots[selection.count] = slot
  selection.count.inc


func pruneDead*(selection: var Selection; scene: Scene) =
  ## Drop every picked slot the scene no longer holds, keeping the rest in pick order.
  ##   Call after removing an object: a freed slot is handed straight back to the next
  ##   add, so a stale pick would silently reattach itself to an unrelated new object.
  var kept = 0
  for position in 0 ..< selection.count:
    if not scene.isAlive(selection.slots[position]): continue
    selection.slots[kept] = selection.slots[position]
    kept.inc
  selection.count = kept
