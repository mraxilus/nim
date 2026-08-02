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
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table. `saveScene`/
## `loadScene` are native-only (`when not defined(js)`), since a browser has no
## filesystem to target -- the browser side saves/loads via download/upload instead.

{.experimental: "strictFuncs".}

import std/[options, os, strformat, strutils, syncio, unicode]

import ../pga
import ./[format, mesh, objects]



#[ Scene Configuration ]#

# Allow caller to resize scene without editing source.
#   E.g. `--define:visualiser.items_max=128 --define:visualiser.label_max=48`.
const
  ITEMS_MAX* {.define: "visualiser.items_max".} = 64
    ## Max items scene may hold at once.
  LABEL_MAX* {.define: "visualiser.label_max".} = 40
    ## Max characters a label may hold.

static:
  doAssert ITEMS_MAX > 0, &"Scene capacity must be positive; got `{ITEMS_MAX}`."
  doAssert LABEL_MAX >= 8, &"Label must hold 8 characters; got `{LABEL_MAX}`."



#[ Type Definitions ]#

type
  Label* = array[LABEL_MAX, char]
    ## Hold item's display text, terminated by 0, so GUI may edit it without allocating.

  Item* = object ## Handle onto one live slot's data; a view on native builds, a copy
    ## under the JS backend, where a value parameter's own address does not carry
    ## across calls the way it does under the C++ backend.
    ##   Holds a pointer back into `scene`'s own storage plus the slot number -- reading
    ##   `.geometry`, `.label`, `.ink`, `.isVisible` or `.born` off it resolves straight
    ##   into that storage each time, so holding or passing an `Item` around costs no
    ##   more than a pointer and an int, whether or not the caller ends up reading every
    ##   field or just one. Do not hold one across a mutation of its own slot (`removeItem`
    ##   followed by reuse via `addItem`): same discipline as any other live reference
    ##   into a container you do not own.
    when defined(js):
      scene: Scene
    else:
      scene: ptr Scene
    slot: int

  Scene* = object ## Hold fixed-capacity arena of items, addressed by stable slot.
    geometries: array[ITEMS_MAX, Multivector] ## Per-slot geometry.
    labels: array[ITEMS_MAX, Label] ## Per-slot display label.
    inks: array[ITEMS_MAX, Ink] ## Per-slot palette entry.
    are_visible: array[ITEMS_MAX, bool] ## Per-slot visibility.
    are_alive: array[ITEMS_MAX, bool] ## Per-slot occupancy; false where slot is free.
    borns: array[ITEMS_MAX, float] ## Per-slot moment item was added, for its appear
      ## animation; not saved or loaded, same as `anchor_overrides` below.
    anchor_overrides: array[ITEMS_MAX, Option[Position]] ## Where a plane's own circle
      ## should centre, for an item whose construction fixes that more specifically than
      ## its own closest-to-origin support does; see `creationAnchor`. None for anything
      ## else, which draws centred on its own support as always. Not saved or loaded:
      ## it is a rendering hint recomputed from how an item was built, not data an item
      ## itself carries.
    next_free: array[ITEMS_MAX, Option[int]] ## Link to next free slot; intrusive free list.
    slot_free_first: Option[int] ## Head of free list; none where scene is full.
    count_live: int ## Number of occupied slots, so `len` need not rescan `are_alive`.

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
  Operation.Attitude: cstring"𝐦⊖  attitude",
  Operation.Support: cstring"𝐦∩  support",
  Operation.SupportAnti: cstring"𝐦∪  antisupport",
  Operation.Bulk: cstring"𝐦∙  bulk",
  Operation.Weight: cstring"𝐦∘  weight",
  Operation.Unitize: cstring"𝐦ˆ  unitize",
  Operation.ComplementLeft: cstring"𝐦ˍ  left complement",
  Operation.ComplementRight: cstring"𝐦¯  right complement",
  Operation.DualBulk: cstring"𝐦★  bulk dual",
  Operation.DualWeight: cstring"𝐦☆  weight dual",
  Operation.Reverse: cstring"𝐦˜  reverse",
  Operation.ReverseAnti: cstring"𝐦˷  antireverse",
  Operation.Negate: cstring"−𝐦  negate",
  Operation.Add: cstring"𝐦 + 𝐧  add",
  Operation.Subtract: cstring"𝐦 - 𝐧  subtract",
  Operation.Wedge: cstring"𝐦 ∧ 𝐧  wedge (join)",
  Operation.WedgeAnti: cstring"𝐦 ∨ 𝐧  antiwedge (meet)",
  Operation.WedgeDot: cstring"𝐦 ⟑ 𝐧  geometric product",
  Operation.WedgeDotAnti: cstring"𝐦 ⟇ 𝐧  geometric antiproduct",
  Operation.Dot: cstring"𝐦 ∙ 𝐧  inner product",
  Operation.DotAnti: cstring"𝐦 ∘ 𝐧  inner antiproduct",
  Operation.ExpandBulk: cstring"𝐦 ∧ 𝐧★  bulk expansion",
  Operation.ExpandWeight: cstring"𝐦 ∧ 𝐧☆  weight expansion",
  Operation.ContractBulk: cstring"𝐦 ∨ 𝐧★  bulk contraction",
  Operation.ContractWeight: cstring"𝐦 ∨ 𝐧☆  weight contraction",
  Operation.ProjectCentral: cstring"𝐧 ∨ (𝐦 ∧ 𝐧★)  central projection",
  Operation.ProjectOrthogonal: cstring"𝐧 ∨ (𝐦 ∧ 𝐧☆)  orthogonal projection",
] ## Map operation to notation and name GUI offers it under, for both render paths.
  ##   Operands are written in Lengyel's own mathematical bold, and every symbol's
  ##   placement is his, written with spacing modifier letters (`ˆ` U+02C6, `ˍ` U+02CD,
  ##   `¯` U+00AF, `˜` U+02DC, `˷` U+02F7) rather than the combining marks the same five
  ##   accents also exist as. Combining marks need a shaper to position, and Dear ImGui
  ##   has none: rendered, they landed to the right of the operand instead of over it, and
  ##   antireverse's tilde-below came out indistinguishable from left complement's low
  ##   line. A spacing modifier carries its own advance, so both renderers place it the
  ##   same way and the five stay distinguishable. Not a second, plain-ASCII table beside
  ##   this one: the atlas merges faces carrying the astral-plane glyphs (see
  ##   `visualiser.PATH_FONT_MATH`), and one table is what stops the two builds drifting.
  ##   Bound as `let` rather than `const`, since picker needs address of first entry.


const COUNT_OPERATION* = ord(Operation.high) + 1
  ## Count operations, for handing whole catalogue to a picker.


proc notationSubstituted*(operation: Operation; name_first, name_second: string): string =
  ## Build the label/message text an applied operation reads as, substituting the
  ## notation template's own `𝐦`/`𝐧` placeholders with the real operand names just
  ## combined -- e.g. `Operation.Wedge` with names "a"/"b" gives "a ∧ b", not the raw
  ## enum identifier "Wedge".
  ##   Matches the bold operands rather than plain ASCII `m`/`n`, which is what the
  ##   shared table now writes. That also removes a hazard the plain form carried: the
  ##   English description after the symbols contains ordinary `m` and `n` constantly,
  ##   and only the isolation step below kept them safe. The isolation stays anyway,
  ##   since the description must not reach a label either way.
  ##   Swaps placeholders through two passes via sentinel bytes no label would contain,
  ##   so an operand name that itself contains the placeholder is never re-touched by the
  ##   second pass, and a template where `𝐧` appears twice (ProjectCentral/
  ##   ProjectOrthogonal) substitutes both occurrences.
  const
    OPERAND_FIRST = "𝐦"
    OPERAND_SECOND = "𝐧"
    SENTINEL_M = "\x01"
    SENTINEL_N = "\x02"
  let full = $lut_operation_to_notation[operation]
  let cutoff = full.find("  ")
  let symbolic = if cutoff >= 0: full[0 ..< cutoff] else: full
  let staged = symbolic.replace(OPERAND_FIRST, SENTINEL_M).replace(OPERAND_SECOND, SENTINEL_N)
  result = staged.replace(SENTINEL_M, name_first).replace(SENTINEL_N, name_second)


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


func creationAnchor*(operation: Operation; m, n, derived: Multivector): Option[Position] =
  ## Resolve the point a freshly derived plane's own circle should centre on, from how
  ## it was built, rather than always from its own closest-to-origin support -- so it
  ## reads as centred where its construction actually happened. Computed through the
  ## same operators the construction itself used, not around them.
  ##   None for any operation or operand shape not recognised here, so caller falls back
  ##   to the plane's own support (`objects.positionAnchor`) as it always did.
  case operation
  of Operation.Wedge:
    # A line wedged with a point gives a plane the line lies entirely within -- the two
    #   never meet at one point, so there is none to centre on the way ExpandWeight's
    #   own case below can. Centre between the point and the line's own closest
    #   approach to it instead: both unitized first, so their sum's own weight is
    #   exactly two and reading its position back out (which divides by weight) gives
    #   the plain midpoint, not one skewed by whatever weight `projectOrthogonal`
    #   itself happened to leave its own result at.
    let (line, point) =
      if shape(m) == some(Shape.Line) and shape(n) == some(Shape.Point): (m, n)
      elif shape(n) == some(Shape.Line) and shape(m) == some(Shape.Point): (n, m)
      else: return none(Position)
    position(add(unitize(point), unitize(projectOrthogonal(point, line))))

  of Operation.ExpandWeight:
    # A plane built perpendicular to a line meets it at exactly one point; meeting them
    #   directly finds it.
    let line =
      if shape(m) == some(Shape.Line): m
      elif shape(n) == some(Shape.Line): n
      else: return none(Position)
    position(wedgeAnti(line, derived))

  else: none(Position)



#[ Multivector Formatting ]#

const lut_basis_to_name* = block:
  ## Name each basis element the way the library's own `$` names it: `𝟏` for the scalar,
  ## `𝟙` for the antiscalar, and a bold `𝐞` carrying subscript digits for the rest.
  ##   Exported so both GUIs label a coefficient with the basis element it belongs to,
  ##   and read the same as the multivector text printed beside them.
  ##   Derived rather than transcribed, so a build of another dimension names its own
  ##   elements without this table being rewritten. The rule is a second copy of the one
  ##   inside `pga/multivectors.nim`'s `$`, which does not expose it separately; check
  ##   that one whenever this is touched.
  const
    NAME_SCALAR = "\u{1D7CF}" # Mathematical bold digit one.
    NAME_SCALAR_ANTI = "\u{1D7D9}" # Mathematical double-struck digit one.
    NAME_VECTOR = "\u{1D41E}" # Mathematical bold small e.
    CODEPOINT_SUBSCRIPT_ZERO = 0x2080
  var lut: array[Basis, string]
  for b in Basis:
    lut[b] =
      case b
      of Basis.scalar: NAME_SCALAR
      of Basis.scalarAnti: NAME_SCALAR_ANTI
      else:
        # Enum's own name is the index list behind an `E`, one digit per factor.
        var name = NAME_VECTOR
        for digit in ($b)[1 .. ^1]:
          name &= $Rune(CODEPOINT_SUBSCRIPT_ZERO + ord(digit) - ord('0'))
        name
  lut


proc formatMultivector*(m: Multivector; storage: var openArray[char]; cursor: var int) =
  ## Print multivector into fixed storage, in same shape library's own `$` uses.
  ##   Basis elements are named exactly as the library names them, mathematical bold and
  ##   all; both GUIs carry faces covering those codepoints. Magnitudes stay this
  ##   project's own four significant digits rather than the library's `%G`.
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
  if not wrote_any:
    appendChars(storage, cursor, "0 ")
    appendChars(storage, cursor, lut_basis_to_name[Basis.scalar])


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
  when defined(js):
    Item(scene: scene, slot: slot)
  else:
    Item(scene: unsafeAddr scene, slot: slot)


func geometry*(item: Item): lent Multivector = item.scene.geometries[item.slot]
  ## Read item's geometry, straight out of the scene the handle points at.


func label*(item: Item): lent Label = item.scene.labels[item.slot]
  ## Read item's label, straight out of the scene the handle points at.


func ink*(item: Item): Ink = item.scene.inks[item.slot]
  ## Read item's palette slot, straight out of the scene the handle points at.


func isVisible*(item: Item): bool = item.scene.are_visible[item.slot]
  ## Read item's visibility, straight out of the scene the handle points at.


func born*(item: Item): float = item.scene.borns[item.slot]
  ## Read item's `born` reading, straight out of the scene the handle points at.


func anchorOverride*(item: Item): Option[Position] = item.scene.anchor_overrides[item.slot]
  ## Read where item's own circle should centre, if its construction fixed that more
  ## specifically than its own support does; see `creationAnchor`.


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


func isVisible*(scene: Scene; slot: int): bool =
  ## Read item's visibility by value, by slot rather than through an `Item` handle --
  ## see `inkAt`'s own doc comment for why a by-slot reader beside the `Item`-based one
  ## earns its keep, and keep this one separate from `isVisibleAt` rather than reusing
  ## it for reads too: confirmed empirically that a `var bool`-returning proc reading
  ## an `array[N, bool]` field miscompiles under the JS backend specifically when its
  ## result is used as a value (an exported proc's own return, or a plain `if`
  ## condition) rather than as an lvalue to assign through -- it reads back `undefined`
  ## there, silently false in every boolean context, which made every object invisible
  ## the moment a caller tried to *read* through `isVisibleAt` instead of write through
  ## it. `isVisibleAt` itself is unaffected for its own real job (`isVisibleAt(...) =
  ## newValue`, an assignment target, not a read) and stays as the setter path;
  ## this is the reader.
  scene.are_visible[slot]


func inkAt*(scene: Scene; slot: int): Ink =
  ## Read item's palette slot, by slot rather than through an `Item` handle.
  ##   Exists beside `Item.ink` for a caller that reads many items a frame and cannot
  ##   afford `Item`'s own per-read cost on every backend: under the JS backend, where
  ##   `Item` holds `Scene` by value rather than by pointer (see `Item`'s own doc
  ##   comment), constructing one to read a single field copies the whole scene, which
  ##   a hot per-frame loop over many items should not pay for just to read one `Ink`.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.inks[slot]


func anchorOverrideAt*(scene: Scene; slot: int): Option[Position] =
  ## Read where item's own circle should centre, by slot rather than through an `Item`
  ## handle -- see `inkAt`'s own doc comment for why a by-slot reader beside the
  ## `Item`-based one earns its keep.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.anchor_overrides[slot]


proc setInk*(scene: var Scene; slot: int; ink: Ink) =
  ## Rewrite item's palette slot, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.inks[slot] = ink


proc setVisible*(scene: var Scene; slot: int; is_visible: bool) =
  ## Rewrite item's visibility, by slot -- a plain setter beside `isVisibleAt`'s own
  ## `addr scene.isVisibleAt(slot)` idiom (which `panel.nim`'s checkbox widget still
  ## uses, and which works fine there), for a caller that cannot use that idiom: under
  ## the JS backend, writing through `isVisibleAt(...) = visible` compiles to the same
  ## miscompiled `var bool`-over-`array[N, bool]` pattern `isVisible`'s own doc comment
  ## already documents breaking reads -- confirmed separately that the write silently
  ## does nothing there either (the assignment lands on a copied primitive, not the
  ## backing array), so a direct, ordinary assignment through a plain setter is the
  ## only path this backend can rely on for both directions, mirroring `setInk` exactly.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.are_visible[slot] = is_visible


iterator items*(scene: Scene): Item =
  ## Yield each live item, in slot order.
  for slot in 0 ..< ITEMS_MAX:
    if scene.are_alive[slot]: yield scene[slot]


iterator pairs*(scene: Scene): (int, Item) =
  ## Yield each live item together with the slot it stands at, in slot order.
  for slot in 0 ..< ITEMS_MAX:
    if scene.are_alive[slot]: yield (slot, scene[slot])


proc addItem*(
  scene: var Scene; geometry: Multivector; label: string; ink: Ink; now: float = 0.0;
  anchor_override: Option[Position] = none(Position)
): int {.discardable.} =
  ## Insert object into scene at its first free slot, visible; report slot used.
  ##   Silently refuses nothing: caller must check `isFull` first, as scene cannot grow.
  ##   `now` is stamped as the item's `born` reading and otherwise never inspected here;
  ##   a caller indifferent to appear-in animation may leave it at its default, which
  ##   reads as "born at the dawn of time" and so never animates.
  ##   `anchor_override` is where a plane's own circle should centre instead of its own
  ##   support, where the caller's own construction fixes that more specifically; see
  ##   `creationAnchor`. Left `none` by a caller with no such point to offer.
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
  scene.anchor_overrides[result] = anchor_override
  inc scene.count_live


proc removeItem*(scene: var Scene; slot: int) =
  ## Drop item at slot, in constant time: slot returns to the free list, nothing moves.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.are_alive[slot] = false
  scene.next_free[slot] = scene.slot_free_first
  scene.slot_free_first = some(slot)
  dec scene.count_live



#[ Scene Persistence ]#

## Binary format this project invents for itself -- no external spec to match, so no
## reason to follow PNG/GIF's own big/little-endian conventions either; every
## multi-byte field below is written in the host's own native layout, straight through
## `writeBuffer`/`readBuffer`. A file saved on a big-endian machine will not load
## correctly on a little-endian one; this tool runs on one desktop at a time, so that
## trade favours simplicity over a portability nothing here needs yet.
##
##   |----------|--------------------------------------------------------------|
##   | Bytes    | Field                                                        |
##   |----------|--------------------------------------------------------------|
##   | 4        | Magic `RGAS`, to catch a wrong file at a glance.             |
##   | 1        | Format version.                                              |
##   | 1        | Basis count (terms per multivector); must match this build's |
##   |          |   own count, or the file was saved under a different PGA     |
##   |          |   dimension or metric and cannot be read here.               |
##   | 4        | Item count, native `uint32`.                                 |
##   | per item | Ink (1), visibility (1), label length (1) then that many     |
##   |          |   bytes, then one `float` per basis term, native layout.     |
##   |----------|--------------------------------------------------------------|
##
## Only live items are written, in slot order, never a dead or free slot; slot numbers
## themselves are not preserved, since they mean nothing once reloaded into a scene
## that assigns its own free-list order. `born` is not written either: it is a clock
## reading meaningless across runs (see `Item.born`'s own doc comment), so a freshly
## loaded item is born at the dawn of time like any other freshly constructed one,
## never partway through an appear-in animation that never happened this run. A label
## is written as exactly as many bytes as it holds rather than padded to `LABEL_MAX`,
## so the format costs nothing for the padding no reader ever wants back and does not
## depend on the `LABEL_MAX` the writing build happened to use.

when not defined(js):
  const
    MAGIC_SCENE: array[4, char] = ['R', 'G', 'A', 'S']
      ## First four bytes of a `.rgascene` file, the format table above documents.
    VERSION_SCENE = 2'u8
      ## Format version this build writes and the only one it reads back.
      ##   Bumped from 1 when `Ink` gained a reserved `Invalid` slot and lost three
      ##   categorical ones: an item's ink is stored as that enum's own ordinal, so a
      ##   version 1 file's bytes name different colours here. Refusing it outright is
      ##   the honest outcome -- silently reading `Cerise` as `Rose` would be worse.


  proc saveScene*(scene: Scene; path: string): string =
    ## Write every live item to `path`, in the format documented above; report outcome.
    if len(path) == 0: return "Save path is empty; nothing written."
    let file = open(path, fmWrite)
    defer: file.close

    discard file.writeChars(MAGIC_SCENE, 0, 4)
    file.write(char(VERSION_SCENE))
    file.write(char(ord(Basis.high) + 1))
    let count = uint32(scene.len)
    discard file.writeBuffer(unsafeAddr count, 4)

    for item in scene:
      file.write(char(ord(item.ink)))
      file.write(char(ord(item.isVisible)))
      let
        text = $toCstring(item.label)
        geometry = item.geometry
      file.write(char(len(text)))
      discard file.writeChars(text, 0, len(text))
      for b in Basis:
        let coefficient = geometry[b]
        discard file.writeBuffer(unsafeAddr coefficient, 8)

    &"Saved {scene.len} object(s) to `{path}`."


  proc loadScene*(scene: var Scene; path: string): string =
    ## Replace scene's contents with what `path` holds; report outcome for display.
    ##   Parses into a scene of its own and only replaces the caller's on complete
    ##   success, so a bad path or a corrupt or foreign file leaves whatever scene
    ##   already held untouched rather than half-overwritten by however far parsing
    ##   got before failing.
    ##   Exceeds the working 60-line default: the format is a strict sequence of
    ##   fixed-size fields, each needing its own guard clause against a truncated or
    ##   foreign file before the next field can be trusted -- splitting the guards
    ##   into a helper would only return partial results across an extra proc
    ##   boundary for no reader benefit.
    if len(path) == 0: return "Load path is empty; nothing read."
    if not fileExists(path): return &"No such file `{path}`."

    let file = open(path, fmRead)
    defer: file.close

    var magic: array[4, char]
    if file.readChars(magic) != 4 or magic != MAGIC_SCENE:
      return &"`{path}` is not a scene file."

    var version: array[1, char]
    if file.readChars(version) != 1 or uint8(version[0]) != VERSION_SCENE:
      return &"`{path}` is a scene file of a version this build cannot read."

    let basis_count_here = ord(Basis.high) + 1
    var basis_count: array[1, char]
    if file.readChars(basis_count) != 1 or int(uint8(basis_count[0])) != basis_count_here:
      return &"`{path}` was saved under a different PGA dimension or metric; " &
        &"this build reads {basis_count_here}-term multivectors."

    var count: uint32
    if file.readBuffer(addr count, 4) != 4:
      return &"`{path}` is truncated; no item count."
    if int(count) > ITEMS_MAX:
      return &"`{path}` holds {count} objects, more than this build's {ITEMS_MAX}-item " &
        "capacity; raise `--define:visualiser.items_max`."

    var staging = initScene()
    for index in 0 ..< int(count):
      var ink_byte, visible_byte, length_byte: array[1, char]
      if file.readChars(ink_byte) != 1 or file.readChars(visible_byte) != 1 or
          file.readChars(length_byte) != 1:
        return &"`{path}` is truncated partway through object {index}."
      if int(uint8(ink_byte[0])) notin ord(Ink.low) .. ord(Ink.high):
        return &"`{path}` names an unknown palette slot for object {index}."

      let
        ink = Ink(uint8(ink_byte[0]))
        is_visible = uint8(visible_byte[0]) != 0
        length = int(uint8(length_byte[0]))
      var label = newString(length)
      if length > 0 and file.readChars(label) != length:
        return &"`{path}` is truncated partway through object {index}'s label."

      var geometry: Multivector
      for b in Basis:
        var coefficient: float
        if file.readBuffer(addr coefficient, 8) != 8:
          return &"`{path}` is truncated partway through object {index}'s geometry."
        geometry[b] = coefficient

      let slot = staging.addItem(geometry, label, ink)
      staging.isVisibleAt(slot) = is_visible

    scene = staging
    &"Loaded {count} object(s) from `{path}`."


func inkCycled*(index: int): Ink = inkCategorical(index mod COUNT_INK_CATEGORICAL)
  ## Choose palette slot for item at given position, cycling through categorical slots --
  ## the same run a colour picker offers, so nothing cycles to a colour the user could
  ## not have chosen.
