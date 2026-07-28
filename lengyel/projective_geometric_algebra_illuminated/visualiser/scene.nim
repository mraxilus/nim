## Hold objects visualiser draws, and catalogue of operations that derive new ones.
##
## Scene is fixed-capacity and owned by caller, so nothing is allocated after setup.
##   Storage is structure-of-arrays, one array per field, addressed by slot rather than
##   by dense position: a slot is assigned once, on `addItem`, and never moves again.
##   Label is fixed char storage rather than string, so GUI can edit it in place.
##
## Free slots thread onto an intrusive singly-linked list, `next_free`, so `addItem` and
## `removeItem` both run in constant time regardless of how many items scene holds.
##   "Intrusive" means the link lives inside the slot array itself rather than in some
##   separate bookkeeping structure: a dead slot's `next_free` entry costs nothing beyond
##   what that slot already carries while alive.
##   Removal used to shift every later item down, to keep indices dense; that cost a copy
##   per following item, worth nothing at these counts on its own, except that every
##   cross-frame index the GUI holds (operands picked, item hovered, item mid-drag) then
##   went stale too, since a shift renumbers items it never touched. A stable slot narrows
##   that: only the removed item's own references go stale, not every later item's, still
##   without a generation counter.
##
## Operation catalogue is what makes scene live rather than scripted:
## every entry is one of library's own named aliases, applied to items user picks.
##
##   |---------|--------------------------------|--------------------------------------|
##   | Arity   | Operations                     | Meaning                              |
##   |---------|--------------------------------|--------------------------------------|
##   | One     | ⊖ ∩ ∪ \ / ★ ☆ ~ ~∘ - ^ ∙ ∘     | Attitude, support, duals, norms.     |
##   | Two     | + - ∧ ∨ ⟑ ⟇ ∙ ∘ ∧★ ∧☆ ∨★ ∨☆    | Join, meet, geometric products.      |
##   |---------|--------------------------------|--------------------------------------|

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./[format, mesh, objects]



#[ Scene Configuration ]#

# Allow caller to resize scene without editing source.
#   E.g. `--define:visualiser.items_max=128 --define:visualiser.label_max=48`.
const
  ITEMS_MAX* {.define: "visualiser.items_max".} = 64
  LABEL_MAX* {.define: "visualiser.label_max".} = 40

static:
  doAssert ITEMS_MAX > 0, &"Scene capacity must be positive; got `{ITEMS_MAX}`."
  doAssert LABEL_MAX >= 8, &"Label must hold 8 characters; got `{LABEL_MAX}`."



#[ Type Definitions ]#

type
  Label* = array[LABEL_MAX, char]
    ## Hold item's display text, terminated by 0, so GUI may edit it without allocating.

  Item* = object ## Handle onto one live slot's data; a view, not a copy.
    ##   Holds a pointer back into `scene`'s own storage plus the slot number -- reading
    ##   `.geometry`, `.label`, `.ink`, `.is_visible` or `.born` off it resolves straight
    ##   into that storage each time, so holding or passing an `Item` around costs no
    ##   more than a pointer and an int, whether or not the caller ends up reading every
    ##   field or just one. Do not hold one across a mutation of its own slot (`removeItem`
    ##   followed by reuse via `addItem`): same discipline as any other live reference
    ##   into a container you do not own.
    scene: ptr Scene
    slot: int

  Scene* = object ## Hold fixed-capacity arena of items, addressed by stable slot.
    geometries: array[ITEMS_MAX, Multivector]
    labels: array[ITEMS_MAX, Label]
    inks: array[ITEMS_MAX, Ink]
    are_visible: array[ITEMS_MAX, bool]
    are_alive: array[ITEMS_MAX, bool]
    borns: array[ITEMS_MAX, float]
    next_free: array[ITEMS_MAX, Option[int]] ## Link to next free slot; intrusive free list.
    slot_free_first: Option[int] ## Head of free list; none where scene is full.
    count_live: int

  Arity* {.pure.} = enum ## Count operands operation consumes.
    One, Two

  Operation* {.pure.} = enum ## Name every operation GUI may apply to scene's items.
    ## Unary operations, in order library's own documentation lists them.
    Attitude, Support, SupportAnti, Bulk, Weight, Unitize,
    ComplementLeft, ComplementRight, DualBulk, DualWeight,
    Reverse, ReverseAnti, Negate,
    ## Binary operations, likewise.
    Add, Subtract, Wedge, WedgeAnti, WedgeDot, WedgeDotAnti, Dot, DotAnti,
    ExpandBulk, ExpandWeight, ContractBulk, ContractWeight,
    ProjectCentral, ProjectOrthogonal,



#[ Operation Catalogue ]#

const lut_operation_to_arity*: array[Operation, Arity] = [
  Operation.Attitude: Arity.One,
  Operation.Support: Arity.One,
  Operation.SupportAnti: Arity.One,
  Operation.Bulk: Arity.One,
  Operation.Weight: Arity.One,
  Operation.Unitize: Arity.One,
  Operation.ComplementLeft: Arity.One,
  Operation.ComplementRight: Arity.One,
  Operation.DualBulk: Arity.One,
  Operation.DualWeight: Arity.One,
  Operation.Reverse: Arity.One,
  Operation.ReverseAnti: Arity.One,
  Operation.Negate: Arity.One,
  Operation.Add: Arity.Two,
  Operation.Subtract: Arity.Two,
  Operation.Wedge: Arity.Two,
  Operation.WedgeAnti: Arity.Two,
  Operation.WedgeDot: Arity.Two,
  Operation.WedgeDotAnti: Arity.Two,
  Operation.Dot: Arity.Two,
  Operation.DotAnti: Arity.Two,
  Operation.ExpandBulk: Arity.Two,
  Operation.ExpandWeight: Arity.Two,
  Operation.ContractBulk: Arity.Two,
  Operation.ContractWeight: Arity.Two,
  Operation.ProjectCentral: Arity.Two,
  Operation.ProjectOrthogonal: Arity.Two,
] ## Map operation to number of operands it consumes.


let lut_operation_to_notation*: array[Operation, cstring] = [
  Operation.Attitude: cstring"⊖m  attitude",
  Operation.Support: cstring"∩m  support",
  Operation.SupportAnti: cstring"∪m  antisupport",
  Operation.Bulk: cstring"∙m  bulk",
  Operation.Weight: cstring"∘m  weight",
  Operation.Unitize: cstring"^m  unitize",
  Operation.ComplementLeft: cstring"\\m  left complement",
  Operation.ComplementRight: cstring"/m  right complement",
  Operation.DualBulk: cstring"★m  bulk dual",
  Operation.DualWeight: cstring"☆m  weight dual",
  Operation.Reverse: cstring"~m  reverse",
  Operation.ReverseAnti: cstring"~∘m  antireverse",
  Operation.Negate: cstring"-m  negate",
  Operation.Add: cstring"m + n  add",
  Operation.Subtract: cstring"m - n  subtract",
  Operation.Wedge: cstring"m ∧ n  wedge (join)",
  Operation.WedgeAnti: cstring"m ∨ n  antiwedge (meet)",
  Operation.WedgeDot: cstring"m ⟑ n  geometric product",
  Operation.WedgeDotAnti: cstring"m ⟇ n  geometric antiproduct",
  Operation.Dot: cstring"m ∙ n  inner product",
  Operation.DotAnti: cstring"m ∘ n  inner antiproduct",
  Operation.ExpandBulk: cstring"m ∧ n★  bulk expansion",
  Operation.ExpandWeight: cstring"m ∧ n☆  weight expansion",
  Operation.ContractBulk: cstring"m ∨ n★  bulk contraction",
  Operation.ContractWeight: cstring"m ∨ n☆  weight contraction",
  Operation.ProjectCentral: cstring"n ∨ (m ∧ n★)  central projection",
  Operation.ProjectOrthogonal: cstring"n ∨ (m ∧ n☆)  orthogonal projection",
] ## Map operation to notation and name GUI offers it under.
  ##   Operands are written `m` and `n` rather than in Lengyel's bold, since bold letters
  ##   live outside the Basic Multilingual Plane and no GUI font here carries them.
  ##   Bound as `let` rather than `const`, since picker needs address of first entry.


const COUNT_OPERATION* = ord(Operation.high) + 1
  ## Count operations, for handing whole catalogue to a picker.


func applyOperation*(operation: Operation; m, n: Multivector): Multivector =
  ## Apply operation to operands, ignoring `n` where operation is unary.
  case operation
  of Operation.Attitude: attitude(m)
  of Operation.Support: support(m)
  of Operation.SupportAnti: supportAnti(m)
  of Operation.Bulk: bulk(m)
  of Operation.Weight: weight(m)
  of Operation.Unitize: unitize(m)
  of Operation.ComplementLeft: complementLeft(m)
  of Operation.ComplementRight: complementRight(m)
  of Operation.DualBulk: dualBulk(m)
  of Operation.DualWeight: dualWeight(m)
  of Operation.Reverse: reverse(m)
  of Operation.ReverseAnti: reverseAnti(m)
  of Operation.Negate: negate(m)
  of Operation.Add: add(m, n)
  of Operation.Subtract: subtract(m, n)
  of Operation.Wedge: wedge(m, n)
  of Operation.WedgeAnti: wedgeAnti(m, n)
  of Operation.WedgeDot: wedgeDot(m, n)
  of Operation.WedgeDotAnti: wedgeDotAnti(m, n)
  of Operation.Dot: dot(m, n)
  of Operation.DotAnti: dotAnti(m, n)
  of Operation.ExpandBulk: expandBulk(m, n)
  of Operation.ExpandWeight: expandWeight(m, n)
  of Operation.ContractBulk: contractBulk(m, n)
  of Operation.ContractWeight: contractWeight(m, n)
  of Operation.ProjectCentral: projectCentral(m, n)
  of Operation.ProjectOrthogonal: projectOrthogonal(m, n)



#[ Multivector Formatting ]#

const lut_basis_to_name* = block:
  ## Name each basis element in ASCII, since fonts carry no mathematical bold.
  ##   Exported so the GUI can label a coefficient with the basis element it belongs to.
  var lut: array[Basis, string]
  for b in Basis: lut[b] = $b
  lut


proc formatMultivector*(m: Multivector; storage: var openArray[char]; cursor: var int) =
  ## Print multivector in ASCII into fixed storage, in same shape library's own `$` uses.
  ##   Library writes basis elements in mathematical bold, which lives outside the Basic
  ##   Multilingual Plane; no font a GUI can load here carries those codepoints.
  ##   Appends from `cursor` onward rather than returning a `string`, so redrawing every
  ##   visible item's coefficients, every one, every frame, never touches the heap.
  var wrote_any = false
  for b in Basis:
    if abs(m[b]) <= TOLERANCE_ABS: continue
    if m[b] < 0: appendChars(storage, cursor, " - ")
    elif wrote_any: appendChars(storage, cursor, " + ")
    appendMagnitude(storage, cursor, abs(m[b]))
    appendChars(storage, cursor, " ")
    appendChars(storage, cursor, lut_basis_to_name[b])
    wrote_any = true
  if not wrote_any: appendChars(storage, cursor, "0 S")


proc describeShape*(m: Multivector; storage: var openArray[char]; cursor: var int) =
  ## Name geometry multivector stands for into fixed storage, for reporting to user.
  ##   Appends from `cursor` onward; see `formatMultivector` for why.
  let shape = shape(m)
  appendChars(storage, cursor,
    if shape.isNone: "mixed grade, nothing to draw"
    else:
      case shape.get
      of Shape.Point: (if m.isHorizon: "point at horizon" else: "point")
      of Shape.Line: (if m.isHorizon: "line at horizon" else: "line")
      of Shape.Plane: (if m.isHorizon: "plane at horizon" else: "plane")
  )



#[ Label Storage ]#

proc toChars*(text: string; storage: var openArray[char]) =
  ## Copy text into fixed char storage, truncating where it will not fit.
  ##   Truncation is deliberate: storage is display only, and GUI must never overrun it.
  var cursor = 0
  appendChars(storage, cursor, text)
  finishChars(storage, cursor)


template toCstring*(storage: untyped): cstring = cast[cstring](unsafeAddr storage[0])
  ## Point at fixed char storage, for handing to GUI or to formatter.
  ##   Template rather than function, so address is taken of caller's own storage
  ##   rather than of a copy made for a parameter.



#[ Scene Editing ]#

proc initScene*(): Scene =
  ## Construct empty scene, threading every slot onto the free list ahead of first use.
  for slot in 0 ..< ITEMS_MAX - 1:
    result.next_free[slot] = some(slot + 1)
  result.slot_free_first = some(0)


func len*(scene: Scene): int = scene.count_live
  ## Count live items held by scene.


func isFull*(scene: Scene): bool = scene.count_live >= ITEMS_MAX
  ## Report whether scene has no room for another item.


func isAlive*(scene: Scene; slot: int): bool =
  ## Report whether slot currently holds a live item.
  ##   Meant for checking a slot read back from across a frame boundary, e.g. an
  ##   operand picked earlier, before trusting it still names something.
  slot in 0 ..< ITEMS_MAX and scene.are_alive[slot]


func `[]`*(scene: Scene; slot: int): Item =
  ## Read item by slot: a handle onto `scene`'s own storage, not a copy of it.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  Item(scene: unsafeAddr scene, slot: slot)


func geometry*(item: Item): lent Multivector = item.scene.geometries[item.slot]
  ## Read item's geometry, straight out of the scene the handle points at.


func label*(item: Item): lent Label = item.scene.labels[item.slot]
  ## Read item's label, straight out of the scene the handle points at.


func ink*(item: Item): Ink = item.scene.inks[item.slot]
  ## Read item's palette slot, straight out of the scene the handle points at.


func is_visible*(item: Item): bool = item.scene.are_visible[item.slot]
  ## Read item's visibility, straight out of the scene the handle points at.


func born*(item: Item): float = item.scene.borns[item.slot]
  ## Read item's `born` reading, straight out of the scene the handle points at.


proc geometryAt*(scene: var Scene; slot: int): var Multivector =
  ## Reach item's geometry for editing, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.geometries[slot]


proc labelAt*(scene: var Scene; slot: int): var Label =
  ## Reach item's label for editing, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.labels[slot]


proc isVisibleAt*(scene: var Scene; slot: int): var bool =
  ## Reach item's visibility for editing, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.are_visible[slot]


proc setInk*(scene: var Scene; slot: int; ink: Ink) =
  ## Rewrite item's palette slot, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.inks[slot] = ink


iterator items*(scene: Scene): Item =
  ## Yield each live item, in slot order.
  for slot in 0 ..< ITEMS_MAX:
    if scene.are_alive[slot]: yield scene[slot]


iterator pairs*(scene: Scene): (int, Item) =
  ## Yield each live item together with the slot it stands at, in slot order.
  for slot in 0 ..< ITEMS_MAX:
    if scene.are_alive[slot]: yield (slot, scene[slot])


proc addItem*(
  scene: var Scene; geometry: Multivector; label: string; ink: Ink; now: float = 0.0
): int {.discardable.} =
  ## Insert object into scene at its first free slot, visible; report slot used.
  ##   Silently refuses nothing: caller must check `isFull` first, as scene cannot grow.
  ##   `now` is stamped as the item's `born` reading and otherwise never inspected here;
  ##   a caller indifferent to appear-in animation may leave it at its default, which
  ##   reads as "born at the dawn of time" and so never animates.
  doAssert not scene.isFull,
    &"Scene holds at most {ITEMS_MAX} items; raise `--define:visualiser.items_max`."
  result = scene.slot_free_first.get
  scene.slot_free_first = scene.next_free[result]
  scene.geometries[result] = geometry
  toChars(label, scene.labels[result])
  scene.inks[result] = ink
  scene.are_visible[result] = true
  scene.are_alive[result] = true
  scene.borns[result] = now
  inc scene.count_live


proc removeItem*(scene: var Scene; slot: int) =
  ## Drop item at slot, in constant time: slot returns to the free list, nothing moves.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.are_alive[slot] = false
  scene.next_free[slot] = scene.slot_free_first
  scene.slot_free_first = some(slot)
  dec scene.count_live


func inkCycled*(index: int): Ink =
  ## Choose palette slot for item at given position, cycling through categorical slots.
  const
    INK_FIRST = int(Ink.Amber)
    COUNT_CATEGORICAL = int(Ink.high) - INK_FIRST + 1
  Ink(INK_FIRST + (index mod COUNT_CATEGORICAL))
