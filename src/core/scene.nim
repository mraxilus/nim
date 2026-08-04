## Hold the objects of a scene in fixed slots that are assigned once and never moved.
##
## The invariant everything else relies on: **a slot stays valid until its item is removed.**
## Hovered, dragged, selected and operand slots are all held across frames, so a
## shift-on-delete array — which renumbers every one of them — was rejected outright. Storage
## is structure-of-arrays with free slots on an intrusive free list, so add and remove are both
## O(1) and neither disturbs a slot anyone else is holding.
##
## The whole scene is a plain fixed-size value type. That is what makes an undo snapshot a
## value copy rather than a traversal, and it is why nothing here is a reference.

{.experimental: "strictFuncs".}

import std/[options, unicode]

import ./[algebra, config, palette]



#[ Type Definitions ]#

type
  Slot* = distinct int
    ## Address an item for as long as that item lives.

  Label* = object
    ## Carry an item's name in fixed storage, so a scene copy stays a value copy.
    ##   Capacity is counted in characters, and storage in the bytes those characters can
    ##   take: every label the tool derives is full of multi-byte operators, and a byte cap
    ##   would both cut a name short of its stated length and cut it mid-character.
    bytes: array[LABEL_CAPACITY*4, char]
    length: int

  Scene* = object
    ## Hold every item of a scene, addressed by slot.
    geometries: array[ITEM_CAPACITY, Multivector]
    labels: array[ITEM_CAPACITY, Label]
    paints: array[ITEM_CAPACITY, Paint]
    visibilities: array[ITEM_CAPACITY, bool]
    births_ms: array[ITEM_CAPACITY, float]
    anchors: array[ITEM_CAPACITY, Option[Position]]
    livenesses: array[ITEM_CAPACITY, bool]
    successors: array[ITEM_CAPACITY, Option[Slot]]
    free_head: Option[Slot]
    count: int
    paint_cursor: int


func `==`*(a, b: Slot): bool {.borrow.}
  ## Compare slots, so a held slot can be recognised.

func `$`*(s: Slot): string {.borrow.}
  ## Write slot for diagnostics.

func index*(s: Slot): int {.inline.} = int(s)
  ## Read the position a slot addresses, for storage that parallels the scene's own.



#[ Label Construction ]#

func initLabel*(text: string): Label =
  ## Build label from text, truncating at whole characters rather than refusing.
  var characters = 0
  for rune in text.runes:
    if characters >= LABEL_CAPACITY: break
    for character in $rune:
      result.bytes[result.length] = character
      result.length += 1
    characters += 1


func len*(l: Label): int {.inline.} = l.length
  ## Count bytes a label holds; its character count is capped at `LABEL_CAPACITY`.


func `$`*(l: Label): string =
  ## Read label as text; allocates, so callers keep it out of the frame loop.
  result = newStringOfCap(l.length)
  for i in 0 ..< l.length:
    result.add(l.bytes[i])


func at*(l: Label, i: int): char {.inline.} = l.bytes[i]
  ## Read one byte of a label, for a renderer that will not allocate.



#[ Scene Construction ]#

func initScene*(): Scene =
  ## Build empty scene with every slot on the free list, lowest first.
  for i in countdown(ITEM_CAPACITY - 1, 0):
    result.successors[i] = result.free_head
    result.free_head = some(Slot(i))
  result.count = 0
  result.paint_cursor = 0



#[ Scene Queries ]#

func isLive*(scene: Scene, slot: Slot): bool {.inline.} =
  ## Report whether a slot still addresses an item.
  ##   Every cross-frame slot is checked through here before it is read.
  slot.index >= 0 and slot.index < ITEM_CAPACITY and scene.livenesses[slot.index]


func count*(scene: Scene): int {.inline.} = scene.count
  ## Count live items.


func isFull*(scene: Scene): bool {.inline.} = scene.free_head.isNone
  ## Report whether every slot is taken.


iterator items*(scene: Scene): Slot =
  ## Walk live slots in slot order.
  for i in 0 ..< ITEM_CAPACITY:
    if scene.livenesses[i]: yield Slot(i)


func geometry*(scene: Scene, slot: Slot): Multivector {.inline.} =
  ## Read an item's multivector.
  scene.geometries[slot.index]

func label*(scene: Scene, slot: Slot): Label {.inline.} =
  ## Read an item's label.
  scene.labels[slot.index]

func paint*(scene: Scene, slot: Slot): Paint {.inline.} =
  ## Read an item's colour slot.
  scene.paints[slot.index]

func isVisible*(scene: Scene, slot: Slot): bool {.inline.} =
  ## Report whether an item draws.
  scene.visibilities[slot.index]

func birth*(scene: Scene, slot: Slot): float {.inline.} =
  ## Read the moment an item was added, in milliseconds.
  scene.births_ms[slot.index]

func anchorOverride*(scene: Scene, slot: Slot): Option[Position] {.inline.} =
  ## Read an item's creation-time drawing anchor, where its construction chose one.
  ##   A rendering hint only: many operand sets produce an identical plane, which carries no
  ##   memory of what built it, so this cannot be recovered later and is stored instead. It is
  ##   excluded from save and load.
  scene.anchors[slot.index]



#[ Scene Mutation ]#

func add*(
  scene: var Scene,
  geometry: Multivector,
  label: Label,
  born_ms: float,
  anchor: Option[Position] = none(Position),
  paint: Option[Paint] = none(Paint),
): Option[Slot] =
  ## Add item to the first free slot, cycling the palette where no colour is named.
  ##   Reports nothing where the scene is full, rather than dropping an item silently.
  if scene.free_head.isNone: return
  let slot = scene.free_head.get
  scene.free_head = scene.successors[slot.index]
  scene.successors[slot.index] = none(Slot)
  scene.geometries[slot.index] = geometry
  scene.labels[slot.index] = label
  scene.visibilities[slot.index] = true
  scene.births_ms[slot.index] = born_ms
  scene.anchors[slot.index] = anchor
  scene.livenesses[slot.index] = true
  if paint.isSome:
    scene.paints[slot.index] = paint.get
  else:
    scene.paints[slot.index] = categorical(scene.paint_cursor)
    scene.paint_cursor += 1
  scene.count += 1
  some(slot)


func remove*(scene: var Scene, slot: Slot) =
  ## Remove item, returning its slot to the free list.
  if not scene.isLive(slot): return
  scene.livenesses[slot.index] = false
  scene.successors[slot.index] = scene.free_head
  scene.free_head = some(slot)
  scene.anchors[slot.index] = none(Position)
  scene.count -= 1


func setGeometry*(scene: var Scene, slot: Slot, geometry: Multivector) =
  ## Write an item's multivector.
  if not scene.isLive(slot): return
  scene.geometries[slot.index] = geometry

func setLabel*(scene: var Scene, slot: Slot, label: Label) =
  ## Write an item's label.
  if not scene.isLive(slot): return
  scene.labels[slot.index] = label

func setPaint*(scene: var Scene, slot: Slot, paint: Paint) =
  ## Write an item's colour slot, refusing a structural one.
  if not scene.isLive(slot): return
  if not paint.isAssignable: return
  scene.paints[slot.index] = paint

func setVisible*(scene: var Scene, slot: Slot, is_visible: bool) =
  ## Write whether an item draws.
  if not scene.isLive(slot): return
  scene.visibilities[slot.index] = is_visible

func setBirth*(scene: var Scene, slot: Slot, born_ms: float) =
  ## Write the moment an item counts as added, for a preset stamping its own clock.
  if not scene.isLive(slot): return
  scene.births_ms[slot.index] = born_ms

func setAnchorOverride*(scene: var Scene, slot: Slot, anchor: Option[Position]) =
  ## Write an item's drawing anchor.
  if not scene.isLive(slot): return
  scene.anchors[slot.index] = anchor



#[ Scene Ordering ]#

func recentOrder*(scene: Scene, order: var array[ITEM_CAPACITY, Slot]): int =
  ## Fill caller's storage with live slots, newest first, and report how many.
  ##   Insertion sort over a fixed array: the list is short, the caller owns the memory, and
  ##   nothing here allocates.
  var length = 0
  for slot in scene.items:
    var position = length
    while position > 0 and scene.birth(order[position - 1]) < scene.birth(slot):
      order[position] = order[position - 1]
      position -= 1
    order[position] = slot
    length += 1
  length



#[ Derived Anchors ]#

func drawAnchor*(scene: Scene, slot: Slot): Option[Position] =
  ## Project an item to the one point it is drawn and picked at.
  ##   The single choke point for anchoring: it reports nothing for a dead slot, which is what
  ##   keeps a stale hovered, dragged or selected slot from reading another item's geometry.
  if not scene.isLive(slot): return
  let override = scene.anchorOverride(slot)
  if override.isSome: return override
  scene.geometry(slot).anchor
