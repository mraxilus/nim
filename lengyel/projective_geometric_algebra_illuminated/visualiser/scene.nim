## Hold objects visualiser draws, and catalogue of operations that derive new ones.
##
## Scene is fixed-capacity and owned by caller, so nothing is allocated after setup.
##   Item carries multivector, label, palette slot and visibility; nothing is cached.
##   Label is fixed char storage rather than string, so GUI can edit it in place.
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
##
## Removing an item shifts later items down, so indices stay dense.
##   Costs a copy per following item, which is nothing at these counts, and keeps every
##   index the GUI holds meaningful without a generation counter.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../pga
import ./[mesh, objects]



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

  Item* = object ## Hold one RGA object together with its presentation.
    geometry*: Multivector ## Object being visualised.
    label*: Label ## Display text; drawn verbatim, never inspected.
    ink*: Ink ## Palette slot object is drawn with.
    is_visible*: bool ## Whether object is tessellated this frame.

  Scene* = object ## Hold fixed-capacity list of items, kept dense.
    entries: array[ITEMS_MAX, Item]
    count_entries: int

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


func formatMultivector*(m: Multivector): string =
  ## Print multivector in ASCII, in same shape library's own `$` uses.
  ##   Library writes basis elements in mathematical bold, which lives outside the Basic
  ##   Multilingual Plane; no font a GUI can load here carries those codepoints.
  for b in Basis:
    if abs(m[b]) <= TOLERANCE_ABS: continue
    let
      sign = if m[b] < 0: " - " else: (if len(result) == 0: "" else: " + ")
      magnitude = abs(m[b])
    result &= &"{sign}{magnitude:.4g} {lut_basis_to_name[b]}"
  if len(result) == 0: result = "0 S"


func describeShape*(m: Multivector): string =
  ## Name geometry multivector stands for, for reporting back to user.
  let shape = shape(m)
  if shape.isNone: return "mixed grade, nothing to draw"
  case shape.get
  of Shape.Point: (if m.isHorizon: "point at horizon" else: "point")
  of Shape.Line: (if m.isHorizon: "line at horizon" else: "line")
  of Shape.Plane: (if m.isHorizon: "plane at horizon" else: "plane")



#[ Label Storage ]#

proc toChars*(text: string; storage: var openArray[char]) =
  ## Copy text into fixed char storage, truncating where it will not fit.
  ##   Truncation is deliberate: storage is display only, and GUI must never overrun it.
  let count = min(len(text), len(storage) - 1)
  for i in 0 ..< count:
    storage[i] = text[i]
  for i in count ..< len(storage):
    storage[i] = '\0'


template toCstring*(storage: untyped): cstring = cast[cstring](unsafeAddr storage[0])
  ## Point at fixed char storage, for handing to GUI or to formatter.
  ##   Template rather than function, so address is taken of caller's own storage
  ##   rather than of a copy made for a parameter.



#[ Scene Editing ]#

func len*(scene: Scene): int = scene.count_entries
  ## Count items held by scene.


func isFull*(scene: Scene): bool = scene.count_entries >= ITEMS_MAX
  ## Report whether scene has no room for another item.


proc `[]`*(scene: var Scene; index: int): var Item =
  ## Reach item for editing, by dense index.
  doAssert index in 0 ..< scene.count_entries,
    &"Item index must be below {scene.count_entries}; got `{index}`."
  scene.entries[index]


func `[]`*(scene: Scene; index: int): Item =
  ## Read item by dense index.
  doAssert index in 0 ..< scene.count_entries,
    &"Item index must be below {scene.count_entries}; got `{index}`."
  scene.entries[index]


iterator items*(scene: Scene): lent Item =
  ## Yield each item in order it was added.
  for i in 0 ..< scene.count_entries:
    yield scene.entries[i]


proc addItem*(scene: var Scene; geometry: Multivector; label: string; ink: Ink) =
  ## Append object to scene, visible, together with its presentation.
  ##   Silently refuses nothing: caller must check `isFull` first, as scene cannot grow.
  doAssert not scene.isFull,
    &"Scene holds at most {ITEMS_MAX} items; raise `--define:visualiser.items_max`."
  scene.entries[scene.count_entries] = Item(geometry: geometry, ink: ink, is_visible: true)
  toChars(label, scene.entries[scene.count_entries].label)
  inc scene.count_entries


proc removeItem*(scene: var Scene; index: int) =
  ## Drop item, shifting later items down so indices stay dense.
  doAssert index in 0 ..< scene.count_entries,
    &"Item index must be below {scene.count_entries}; got `{index}`."
  for i in index ..< scene.count_entries - 1:
    scene.entries[i] = scene.entries[i + 1]
  dec scene.count_entries
  scene.entries[scene.count_entries] = Item()


func inkCycled*(index: int): Ink =
  ## Choose palette slot for item at given position, cycling through categorical slots.
  const
    INK_FIRST = int(Ink.Amber)
    COUNT_CATEGORICAL = int(Ink.high) - INK_FIRST + 1
  Ink(INK_FIRST + (index mod COUNT_CATEGORICAL))
