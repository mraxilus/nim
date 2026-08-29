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

import std/[math, options, strformat, strutils, unicode]

import ../../pga
import ./[boundary, format, tessellate]



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
      ## animation. Not written to a scene file -- a clock reading means nothing across
      ## runs -- but a *loaded* item is stamped all the same, so a file replays its own
      ## construction rather than arriving all at once; see `bornReplaying`.
    orders: array[ITEMS_MAX, uint32] ## Per-slot creation ordinal: how many items this
      ## scene had ever been given when this one arrived.
      ##   Separate from `borns` because a clock reading cannot answer this. Two items
      ## added in the same frame share a reading, a loaded scene's readings are stamped
      ## for the replay rather than for when anything was really made, and a slot freed
      ## and refilled keeps whatever its old occupant's reading was until overwritten.
      ## An ordinal is none of those things: it only ever increases, is never reused, and
      ## survives a save and load because the file's own item sequence *is* this order.
      ##   What it buys: `saveScene` writes items in the order they were built, so
      ## reloading replays that construction step by step even after removals have
      ## scrambled slot order. See this module's own format table.
    anchor_overrides: array[ITEMS_MAX, Option[Position]] ## Where a plane's own circle
      ## should centre, for an item whose construction fixes that more specifically than
      ## its own closest-to-origin support does; see `creationAnchor`. None for anything
      ## else, which draws centred on its own support as always. Not saved or loaded:
      ## it is a rendering hint recomputed from how an item was built, not data an item
      ## itself carries.
    next_free: array[ITEMS_MAX, Option[int]] ## Link to next free slot; intrusive free list.
    slot_free_first: Option[int] ## Head of free list; none where scene is full.
    count_live: int ## Number of occupied slots, so `len` need not rescan `are_alive`.
    count_created: uint32 ## Ordinals handed out so far, and the next one to hand out.
      ## Counts additions over the scene's whole life, never removals, so it is not
      ## `count_live` and cannot be derived from it.
    index_ink: int ## How far the categorical cycle has been walked; the next hue to hand out.
      ## Its own counter rather than `len`, because a **drag that built nothing still steps
      ## the palette** -- the reader watched a colour on the band and it should not be
      ## offered again -- and `len` cannot move for an object that was never added. Undo
      ## restores it with the rest of the scene, so undoing a build re-offers that hue; that
      ## is the consistent answer rather than a lapse. Not written to file: `loadScene` sets
      ## it from the item count so a loaded scene carries on rather than repeating.

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


const lut_operation_to_notation* = [
  Operation.Attitude: "𝐦⊖  attitude",
  Operation.Support: "𝐦∩  support",
  Operation.SupportAnti: "𝐦∪  antisupport",
  Operation.Bulk: "𝐦∙  bulk",
  Operation.Weight: "𝐦∘  weight",
  Operation.Unitize: "𝐦ˆ  unitize",
  Operation.ComplementLeft: "𝐦ˍ  left complement",
  Operation.ComplementRight: "𝐦¯  right complement",
  Operation.DualBulk: "𝐦★  bulk dual",
  Operation.DualWeight: "𝐦☆  weight dual",
  Operation.Reverse: "𝐦˜  reverse",
  Operation.ReverseAnti: "𝐦˷  antireverse",
  Operation.Negate: "−𝐦  negate",
  Operation.Add: "𝐦 + 𝐧  add",
  Operation.Subtract: "𝐦 - 𝐧  subtract",
  Operation.Wedge: "𝐦 ∧ 𝐧  wedge (join)",
  Operation.WedgeAnti: "𝐦 ∨ 𝐧  antiwedge (meet)",
  Operation.WedgeDot: "𝐦 ⟑ 𝐧  geometric product",
  Operation.WedgeDotAnti: "𝐦 ⟇ 𝐧  geometric antiproduct",
  Operation.Dot: "𝐦 ∙ 𝐧  inner product",
  Operation.DotAnti: "𝐦 ∘ 𝐧  inner antiproduct",
  Operation.ExpandBulk: "𝐦 ∧ 𝐧★  bulk expansion",
  Operation.ExpandWeight: "𝐦 ∧ 𝐧☆  weight expansion",
  Operation.ContractBulk: "𝐦 ∨ 𝐧★  bulk contraction",
  Operation.ContractWeight: "𝐦 ∨ 𝐧☆  weight contraction",
  Operation.ProjectCentral: "𝐧 ∨ (𝐦 ∧ 𝐧★)  central projection",
  Operation.ProjectOrthogonal: "𝐧 ∨ (𝐦 ∧ 𝐧☆)  orthogonal projection",
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
  ##   **A `const` of `string`, with the `cstring` array a picker needs built from it
  ##   below.** It was the other way round, and could not be: `help.nim` builds its own
  ##   table at compile time, so a catalogue tab generated from this one needs the text
  ##   before the program runs. Deriving the addresses from the text costs one array;
  ##   deriving the text from the addresses cannot be done at all.


let lut_operation_to_notation_c* = block:
  ## The same entries as `cstring`, which is what a picker offers: Dear ImGui takes the
  ## address of the first one and reads them for the life of the combo, so they have to
  ## outlive the call. Built from the table above rather than written beside it.
  var lut: array[Operation, cstring]
  for operation in Operation: lut[operation] = cstring(lut_operation_to_notation[operation])
  lut


const COUNT_OPERATION* = ord(Operation.high) + 1
  ## Count operations, for handing whole catalogue to a picker.


const lut_operation_split* = block:
  ## Each operation's two halves: the symbols it is written with, and the English name the
  ## catalogue table carries after them. **One split, at one place** -- the double space
  ## between them -- so a caller wanting either half cannot cut at a second place that
  ## drifts from this one.
  ##   A `const`, so `help.nim` can build a catalogue tab out of it at compile time.
  var lut: array[Operation, tuple[symbols, name: string]]
  for operation in Operation:
    let full = lut_operation_to_notation[operation]
    let cutoff = full.find("  ")
    lut[operation] =
      if cutoff >= 0: (symbols: full[0 ..< cutoff], name: full[cutoff + 2 .. ^1].strip())
      else: (symbols: full, name: "")
  lut


func notationSymbolic*(operation: Operation): string =
  ## Report just the symbols an operation is written with, without the English name the
  ## catalogue table carries after them -- `𝐦 ∧ 𝐧`, not `𝐦 ∧ 𝐧  wedge (join)`.
  ##   What a picker offers, on both front-ends. The full entry is three to five times
  ##   wider, which on a phone pushed the selection menu's own popover past what a hand
  ##   can reach; the name it drops is still there for a tooltip to read.
  ##   Split on the double space the table separates the two halves with, so this and
  ##   `notationSubstituted` below cut at exactly one place rather than two that can drift.
  lut_operation_split[operation].symbols


func notationNamed*(operation: Operation): string =
  ## Report the English name an operation is offered under -- `wedge (join)`, not
  ## `𝐦 ∧ 𝐧`. The other half of `notationSymbolic`'s own split, from the same one cut.
  ##   What the help's catalogue tab reads for its outcome column, so that tab says exactly
  ##   what every picker in both builds offers and cannot fall behind it.
  lut_operation_split[operation].name


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
  let staged = notationSymbolic(operation)
    .replace(OPERAND_FIRST, SENTINEL_M).replace(OPERAND_SECOND, SENTINEL_N)
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


const
  WIDTH_TERM = 32
    ## Bound one printed term in *bytes*: a separator (` + `/` - `), a magnitude at
    ## `DIGITS_SIGNIFICANT` significant digits with sign and exponent, a space, and a
    ## basis name, which the library writes in mathematical bold with subscript digits at
    ## up to 13 bytes. Bytes rather than characters, since that is what a buffer holds,
    ## and truncating mid-name would leave the GUI half a codepoint to draw.
  WIDTH_MULTIVECTOR* = (ord(Basis.high) + 1)*WIDTH_TERM + 1
    ## Bound one printed multivector: every basis term this build's metric carries, at
    ## `WIDTH_TERM` each, plus the terminator. Derived from `Basis` rather than fixed, so
    ## a build of another dimension sizes its own buffers rather than silently truncating.


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


const WIDTH_SHAPE_WORD* = 32
  ## Bound the shape word alone, the longest being "mixed grade, nothing to draw".


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


func multivectorText*(m: Multivector): string =
  ## Print `m` as a string, for a caller with nowhere fixed to put it.
  ##   Wraps `formatMultivector` for the same reason `shapeText` wraps `describeShape`:
  ##   the browser's item list showed the library's own `$` here, at the library's `%G`
  ##   rather than this project's four significant digits, so the same object read
  ##   differently in the two front-ends. One writer, one answer.
  var
    storage: array[WIDTH_MULTIVECTOR, char]
    cursor = 0
  formatMultivector(m, storage, cursor)
  finishChars(storage, cursor)
  toText(storage)


func shapeText*(m: Multivector): string =
  ## Name the geometry `m` stands for, as a string, for a caller with nowhere fixed to
  ## put it.
  ##   Wraps `describeShape` rather than restating its words, so a status line, a panel
  ##   row and the browser's own item list cannot drift apart from each other -- three
  ##   copies of this wording is exactly what was there before. Allocating is affordable
  ##   here and not in `describeShape`: this is called on a user action, that one on every
  ##   visible item, every frame.
  var
    storage: array[WIDTH_SHAPE_WORD, char]
    cursor = 0
  describeShape(m, storage, cursor)
  finishChars(storage, cursor)
  toText(storage)



#[ Label Storage ]#

const ELLIPSIS_LABEL = "…"
  ## Mark a label that did not fit with this, so a shortened name says it was shortened.
  ##   Three bytes of the buffer it is warning about, which is the trade: a name reading
  ##   as complete when it is not costs more than three characters of it do. Derived names
  ##   compound -- an operation names its result after both operands -- so a few steps in,
  ##   every name is long enough to be cut, and one that ends mid-word without saying so
  ##   reads as a name someone chose.

proc toChars*(text: string; storage: var openArray[char]) =
  ## Copy text into fixed char storage, marking it with `…` where it will not fit.
  ##   Truncation is deliberate: storage is display only, and GUI must never overrun it.
  ##   The room for the mark is measured by asking `lengthFitting` against the smaller
  ##   capacity rather than by backing up over what was already written, so the
  ##   character-boundary rule is applied by the one function that knows it and a rewind
  ##   can never land inside a character.
  let capacity = len(storage) - 1
  var cursor = 0
  if lengthFitting(text, capacity) == len(text):
    appendChars(storage, cursor, text)
  else:
    let kept = lengthFitting(text, capacity - len(ELLIPSIS_LABEL))
    if kept > 0: appendChars(storage, cursor, text.toOpenArray(0, kept - 1))
    appendChars(storage, cursor, ELLIPSIS_LABEL)
  finishChars(storage, cursor)


when not defined(js):
  template toCstring*(storage: untyped): cstring = cast[cstring](unsafeAddr storage[0])
    ## Point at fixed char storage, for handing to the GUI as the pointer C expects.
    ##   Template rather than function, so address is taken of caller's own storage
    ##   rather than of a copy made for a parameter.
    ##   Desktop-only, and guarded so rather than left for a comment to police: taking an
    ##   address is meaningless on the JS backend, so a shared module reading storage as
    ##   text wants `toText` above. Only a hand-off to a C entry point wants this.



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


func slotStepped*(scene: Scene; slot: Option[int]; step: int): Option[int] =
  ## Walk to the next live slot `step` places on from `slot`, wrapping past both ends.
  ##   None where the scene holds nothing to walk to; the first live slot from the start
  ##   where `slot` is none, so a caller with nothing focused yet gets somewhere to begin
  ##   without a special case of its own.
  ##   Slots are sparse -- items are freed in any order and the free list reuses holes --
  ##   so this cannot be arithmetic on the slot number; it searches. `ITEMS_MAX` is the
  ##   bound, which is what makes the search finite even with a scene full of holes.
  ##   Wraps deliberately: this drives keyboard traversal, and a walk that stopped dead at
  ##   the end would leave a reader pressing a key that has silently stopped working.
  if scene.len == 0: return none(int)
  doAssert step != 0, "Stepping nowhere would search forever; got a step of zero."
  let start = if slot.isSome: slot.get else: -1
  for offset in 1 .. ITEMS_MAX:
    let candidate = floorMod(start + step*offset, ITEMS_MAX)
    if scene.isAlive(candidate): return some(candidate)
  none(int)


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


func geometryOf*(scene: Scene; slot: int): Multivector =
  ## Read item's geometry by value, by slot, without needing a mutable scene.
  ##   Beside `geometryAt` below for the same reason `isVisible` sits beside `setVisible`:
  ##   a reader that only wants to look at an item should not have to hold it mutably, and
  ##   a `var`-returning accessor used for reading is the pattern that miscompiled under
  ##   the JS backend once already.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.geometries[slot]


proc geometryAt*(scene: var Scene; slot: int): var Multivector =
  ## Reach item's geometry for editing, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.geometries[slot]


proc labelAt*(scene: var Scene; slot: int): var Label =
  ## Reach item's label for editing, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.labels[slot]


func isVisible*(scene: Scene; slot: int): bool =
  ## Read item's visibility by value, by slot rather than through an `Item` handle --
  ## see `inkAt`'s own doc comment for why a by-slot reader beside the `Item`-based one
  ## earns its keep.
  ##   Visibility is read and written through this pair of plain accessors and never
  ## through a `var bool`-returning one: confirmed empirically that a proc handing back
  ## `var bool` over an `array[N, bool]` field miscompiles under the JS backend, reading
  ## `undefined` (silently false in every boolean context) and writing to a copy that is
  ## then dropped. `setVisible` below is the writer.
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


func bornAt*(scene: Scene; slot: int): float =
  ## Read the moment item arrived, by slot rather than through an `Item` handle -- see
  ## `inkAt`'s own doc comment for why a by-slot reader beside the `Item`-based one earns
  ## its keep.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.borns[slot]


func orderOf*(scene: Scene; slot: int): uint32 =
  ## Read where item stands in the order this scene's items were created, by slot.
  ##   Comparable only within one scene: it counts additions to *this* arena, and says
  ##   nothing about wall-clock time or about another scene's ordinals.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.orders[slot]


func slotsCreated*(scene: Scene; slots: var array[ITEMS_MAX, int]): int =
  ## Fill `slots` with every live slot, oldest creation first; report how many were filled.
  ##   A caller's own array rather than a `seq`, so walking a scene in creation order
  ##   costs no allocation on either backend -- the same reason `Selection` holds one.
  ##   Insertion sort, as `panel.layoutObjects` sorts its own list: at `ITEMS_MAX` items
  ##   this is a handful of comparisons on a path that runs once per save, and a sort
  ##   written out here is one nobody has to go and find.
  ##   Walks slots directly rather than through `pairs`, for the reason `inkAt` gives:
  ##   that iterator builds an `Item` per live slot, which under the JS backend copies the
  ##   whole scene to hand back a slot number this already has.
  for slot in 0 ..< ITEMS_MAX:
    if not scene.are_alive[slot]: continue
    var position = result
    while position > 0 and scene.orders[slots[position - 1]] > scene.orders[slot]:
      slots[position] = slots[position - 1]
      dec position
    slots[position] = slot
    inc result


func anchorOverrideAt*(scene: Scene; slot: int): Option[Position] =
  ## Read where item's own circle should centre, by slot rather than through an `Item`
  ## handle -- see `inkAt`'s own doc comment for why a by-slot reader beside the
  ## `Item`-based one earns its keep.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.anchor_overrides[slot]



#[ Previewing A Construction ]#

type Preview* = object ## What applying an operation would build, ready to draw and to frame.
  ## The one statement of a construction not yet committed, shared by every path that
  ## offers one: the drag's own rubber-band answer and both apply pickers. Written twice,
  ## the two would agree today and drift the first time either grew a field.
  geometry*: Multivector ## What the operation makes of its operands.
  anchor*: Option[Position] ## Where a plane's disc should centre, from `creationAnchor`;
    ## none for every other shape, and none where the construction fixes no such point.
    ## Carried rather than left to each render path, so a ghosted plane is drawn exactly
    ## where the commit will put it instead of jumping the moment it lands.
  operands*: Option[(int, int)] ## Slots this was derived from, for a camera framing the
    ## preview to keep in view beside it -- a result judged without the objects it came
    ## from is half a picture.
    ##   None where there are none to name: a staged *edit* replaces the very object it
    ## would be framed against, which is the one case that has to stand alone.


func previewApplying*(
  scene: Scene; operation: Operation; first, second: int
): Option[Preview] =
  ## Resolve what applying `operation` to these two slots would build, or none where it
  ## would build nothing worth showing.
  ##   None where either slot is dead -- a picker left open across a delete is an ordinary
  ##   thing rather than an error -- and none where the result has no drawable shape. That
  ##   one test covers both ways a construction comes to nothing: a pair of the wrong
  ##   grades, and a pair already lying on each other, whose result is zero.
  ##   Takes slots rather than bare multivectors so the operands travel with the answer;
  ##   every caller has them already.
  ##   A unary operation ignores `second`; pass the first slot again, exactly as every
  ##   commit path does.
  if not (scene.isAlive(first) and scene.isAlive(second)): return
  let
    m = scene.geometryOf(first)
    n = scene.geometryOf(second)
    derived = applyOperation(operation, m, n)
  if shape(derived).isNone: return
  some(Preview(
    geometry: derived,
    anchor: creationAnchor(operation, m, n, derived),
    operands: some((first, second)),
  ))


func previewStaging*(geometry: Multivector): Preview =
  ## Hold an open edit session's own staged geometry as a preview.
  ##   No anchor and no operands: neither front-end draws that ghost about a stored point,
  ##   and the object it would be framed against is the one it replaces. See `Preview`.
  Preview(geometry: geometry, anchor: none(Position), operands: none((int, int)))



proc setInk*(scene: var Scene; slot: int; ink: Ink) =
  ## Rewrite item's palette slot, by slot.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.inks[slot] = ink


proc setVisible*(scene: var Scene; slot: int; is_visible: bool) =
  ## Rewrite item's visibility, by slot, mirroring `setInk` exactly.
  ##   The only writer: an `isVisibleAt(...) = visible` accessor stood here until the
  ## suite began running on the JS backend, where the assignment silently landed on a
  ## copied primitive rather than the backing array -- see `isVisible` above.
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
  # Stamp when it arrived relative to everything else, which the slot cannot say: a slot
  #   freed and refilled sits wherever the free list put it, not where its occupant
  #   belongs in the order things were built.
  scene.orders[result] = scene.count_created
  inc scene.count_created
  inc scene.count_live


proc removeItem*(scene: var Scene; slot: int) =
  ## Drop item at slot, in constant time: slot returns to the free list, nothing moves.
  doAssert scene.isAlive(slot), &"Item slot must be alive; got `{slot}`."
  scene.are_alive[slot] = false
  scene.next_free[slot] = scene.slot_free_first
  scene.slot_free_first = some(slot)
  dec scene.count_live



#[ Scene Persistence ]#

## Binary format this project invents for itself -- no external spec to match, so the byte
## order is this project's to choose. **Every multi-byte field below is little-endian**,
## and that is a rule rather than a habit: `glue.js` writes and reads the very same file
## through `DataView`, which demands an explicit order at every call and is given `true`
## there. Leaving the desktop on the host's native layout, as it was first written, left
## the two agreeing only because every machine this has run on is little-endian -- on a
## big-endian one the desktop build would write a file its own browser build could not
## read, which is a parity break rather than a portability nicety.
##   Little-endian rather than big-endian precisely because it is what every file written
## so far already contains, so the rule cost no format version and orphaned no saved scene.
##
##   |----------|--------------------------------------------------------------|
##   | Bytes    | Field                                                        |
##   |----------|--------------------------------------------------------------|
##   | 4        | Magic `RGAS`, to catch a wrong file at a glance.             |
##   | 1        | Format version.                                              |
##   | 1        | Basis count (terms per multivector); must match this build's |
##   |          |   own count, or the file was saved under a different PGA     |
##   |          |   dimension or metric and cannot be read here.               |
##   | 4        | Item count, little-endian `uint32`.                          |
##   | per item | Ink (1), visibility (1), label length (1) then that many     |
##   |          |   bytes, then one little-endian `float` per basis term.      |
##   |----------|--------------------------------------------------------------|
##
## Only live items are written, never a dead or free slot, and **in the order they were
## created** -- which is the whole of what version 3 added. Slot numbers themselves are not
## preserved, since they mean nothing once reloaded into a scene that assigns its own
## free-list order; the sequence is what carries the ordering, so no ordinal is written
## beside each item (it would be exactly its own position, every time).
##   `born` is not written: it is a clock reading meaningless across runs (see
## `Item.born`'s own doc comment). A loaded item is stamped by `bornReplaying` instead, so
## the file plays back its own construction one object at a time rather than appearing
## whole. A label is written as exactly as many bytes as it holds rather than padded to
## `LABEL_MAX`, so the format costs nothing for the padding no reader ever wants back and
## does not depend on the `LABEL_MAX` the writing build happened to use.
##
## **Every version ever written is still readable, and that is a promise this project
## keeps rather than a convenience it noticed.** A scene file is a reader's own work; a
## build that refuses it has destroyed it as surely as deleting it would. What each older
## version costs to read:
##
##   |---------|-------------------------------------------------------------------|
##   | Version | Read as                                                           |
##   |---------|-------------------------------------------------------------------|
##   | 3       | Exactly. Items replay in the order they were built.               |
##   | 2       | Exactly, except that the item sequence is slot order, so a scene  |
##   |         |   whose objects were removed and re-added replays in an order     |
##   |         |   that is no longer the one it was built in. Nothing else differs:|
##   |         |   a version-2 file and a version-3 file of an untouched scene are |
##   |         |   byte-identical but for the version itself.                      |
##   | 1       | Geometry, label and visibility exactly; colours one hue along     |
##   |         |   for the three that were retired -- see `upgradedFrom1`.        |
##   |---------|-------------------------------------------------------------------|
##
## **An old file is upgraded to today's shape, never read in an old build's dialect.**
## Reading is written once, against `VERSION_SCENE` alone; everything a past version did
## differently lives in one small `upgradedFrom<n>` per version boundary, and
## `itemUpgraded` walks a file's items up the chain one step at a time. The alternative --
## a reader that branches on the version at each field it touches -- was rejected: it
## spreads every past decision across the whole reader, so the cost of supporting an old
## version is paid again by everyone who ever edits reading, and the version that gets
## broken is the one nobody has a file of to notice with. Here, adding a version means
## adding one func and leaving the rest alone, and deleting one would be the only way to
## drop support (which this project does not do).

const
  MAGIC_SCENE* = "RGAS"
    ## First four bytes of a `.rgascene` file, the format table above documents.
  VERSION_SCENE* = 3'u8
    ## Format version this build writes. Every version down to `VERSION_SCENE_LEAST` is
    ## still read; see the table above for what each older one costs.
    ##   Bumped from 1 when `Ink` gained a reserved `Invalid` slot and lost three
    ##   categorical ones, which moved every categorical ordinal an item's colour is
    ##   stored as. Bumped from 2 when items began to be written in creation order rather
    ##   than slot order: the bytes are shaped identically, so this number is the only
    ##   thing that says whether the sequence a reader is replaying is the order the
    ##   scene was actually built in or merely the order its slots happened to fall in.
  VERSION_SCENE_LEAST* = 1'u8
    ## Oldest format version this build still reads.
    ##   One, and it should stay one: a scene file is a reader's own work, and a version
    ##   floor that rises is a build that throws that work away. Reading an old version
    ##   costs a mapping func and a suite case; refusing it costs somebody their scene.

func inkCycled*(index: int): Ink = inkCategorical(index mod COUNT_INK_CATEGORICAL)
  ## Choose palette slot for item at given position, cycling through categorical slots --
  ## the same run a colour picker offers, so nothing cycles to a colour the user could
  ## not have chosen.


func inkNext*(scene: Scene): Ink = inkCycled(scene.index_ink)
  ## Read the hue the next object built will wear, without taking it.
  ##   What a drag in flight is drawn in, so the band, its comet and the ghost all show the
  ## colour the thing being built will actually be rather than the operation's own -- see
  ## `interaction.inkOfDrag`. Peeking and taking are separate calls because previewing
  ## happens every frame and must not walk the cycle.


proc takeInk*(scene: var Scene): Ink =
  ## Read the hue for an object being built, and step the cycle past it.
  result = scene.inkNext
  inc scene.index_ink


proc skipInk*(scene: var Scene) =
  ## Step the cycle without building anything.
  ##   For a construction gesture that ended in no object: a pair that makes nothing, a
  ## release over empty space, a release back on its own source. The reader was shown a
  ## colour for the whole drag, so offering that same colour again to the next attempt reads
  ## as the gesture having not registered. Stepping costs nothing -- the cycle is endless.
  inc scene.index_ink

const
  ORDINAL_INK_CATEGORICAL_V1* = 7
    ## Where the categorical hues began in the `Ink` a version-1 file was written under.
    ##   That palette ran `Backdrop, AxisX, AxisY, AxisZ, Grid, Guide, Outline` and then
    ##   eight hues `Rose, Copper, Olive, Jade, Cobalt, Violet, Magenta, Cerise`. The
    ##   structural prefix is unchanged to this day; `Invalid` was inserted after it, which
    ##   is what moved every hue along by one. Recorded as a number rather than looked up,
    ##   because the enum it indexes no longer exists to look it up in.
  ORDINAL_INK_HIGH_V1* = 14
    ## Last palette slot a version-1 file could name, being `Cerise`'s.
    ##   Bounded rather than left open because the fold below would otherwise turn any
    ##   number at all into some hue, and quietly colouring a corrupt byte is exactly the
    ##   guessing this format refuses everywhere else.


func readsSceneVersion*(version: uint8): bool =
  ## Report whether this build can read a scene file stamped with this version.
  version >= VERSION_SCENE_LEAST and version <= VERSION_SCENE


type ItemSaved* = object
  ## One item exactly as a scene file holds it, at whatever version wrote that file.
  ##   The shape reading works in, and the thing `upgradedFrom<n>` carries from one
  ##   version's meaning to the next. Distinct from `Item` on purpose: an `Item` is a live
  ##   handle into a scene that already exists, whereas this is a value read off bytes that
  ##   may not describe anything this build can make yet.
  ink_ordinal*: int ## Palette slot, as the writing version's own `Ink` numbered it.
  is_visible*: bool ## Whether the item was hidden when saved.
  label*: string ## Display label, already decoded from the file's UTF-8 bytes.
  geometry*: Multivector ## The object itself, one coefficient per basis term.


func upgradedFrom1(item: ItemSaved): Option[ItemSaved] =
  ## Carry one item from what version 1 meant to what version 2 means. None where version
  ## 1 could not have written it.
  ##   Only the palette moved. Version 1's hues began one slot earlier and ran three
  ##   longer; `Invalid` was then reserved after the structural slots, pushing every hue
  ##   along by one, and `Violet`, `Magenta` and `Cerise` were retired. The structural
  ##   slots are untouched, the five surviving hues shift by exactly one, and the three
  ##   retired ones fold onto hues that exist by the same cycle `inkCycled` walks -- a
  ##   colour the reader could have chosen for themselves, rather than a refusal.
  ##   **The one file this gets wrong** is the browser's own: it stamped version 1 onto
  ##   version-2 content for a while (see `MAGIC_SCENE`'s own note), and nothing in the
  ##   bytes tells such a file apart from a genuine version-1 one. Its colours come back
  ##   one hue along; geometry, labels and visibility are exact, and saving it again
  ##   restamps it. Treating version 1 as though it were already version 2 would fix that
  ##   file and *refuse* a genuine version-1 one outright, whose `Magenta` and `Cerise`
  ##   fall past the end of today's palette -- a wrong hue is recoverable, a refused scene
  ##   is not.
  if item.ink_ordinal < 0 or item.ink_ordinal > ORDINAL_INK_HIGH_V1: return none(ItemSaved)
  var carried = item
  if carried.ink_ordinal >= ORDINAL_INK_CATEGORICAL_V1:
    carried.ink_ordinal = ord(inkCycled(carried.ink_ordinal - ORDINAL_INK_CATEGORICAL_V1))
  some(carried)


func upgradedFrom2(item: ItemSaved): Option[ItemSaved] = some(item)
  ## Carry one item from what version 2 meant to what version 3 means, which is nothing.
  ##   Version 3 changed only what the *sequence* of items promises -- creation order
  ##   rather than slot order -- and an item on its own carries no sequence. A version-2
  ##   file's order is taken as its creation order, which is the closest thing it has:
  ##   for a scene nothing was ever removed from the two are the same order, and for one
  ##   that was, no better answer survives in the bytes.
  ##   Kept as an explicit step that does nothing rather than left out, so the chain has
  ##   one entry per version boundary and a reader asking "what did version 2 mean
  ##   differently?" finds the answer written down instead of finding nothing.


func itemUpgraded*(item: ItemSaved; version: uint8): Option[ItemSaved] =
  ## Carry an item read from a file of `version` up to the shape this build works in, one
  ## version boundary at a time. None where no version could have written it.
  ##   On success every field is at `VERSION_SCENE`'s own meaning, so a caller may take
  ##   `Ink(ink_ordinal)` without a further check -- that is what the last guard here buys,
  ##   and it is checked once at the end rather than by each step, since a step is only
  ##   responsible for the one boundary it names.
  if not readsSceneVersion(version): return none(ItemSaved)
  var carried = item
  for boundary in version ..< VERSION_SCENE:
    let stepped =
      case boundary
      of 1'u8: carried.upgradedFrom1
      of 2'u8: carried.upgradedFrom2
      else: none(ItemSaved) # Unreachable: `readsSceneVersion` bounds the walk above.
    if stepped.isNone: return none(ItemSaved)
    carried = stepped.get
  if carried.ink_ordinal notin ord(Ink.low) .. ord(Ink.high): return none(ItemSaved)
  some(carried)


const
  SECONDS_REPLAY_STEP* = 0.12
    ## Beat between one loaded object appearing and the next.
    ##   Shorter than `tessellate.ANIMATION_SECONDS`, so each object is still growing in as the
    ##   next arrives: the replay reads as one construction unfolding rather than as a
    ##   queue of separate pop-ins.
  SECONDS_REPLAY_WHOLE* = 2.5
    ## Longest the whole replay may take, however many objects arrive.
    ##   Without it a full `ITEMS_MAX` scene would take nearly eight seconds to finish
    ##   appearing, and a reader who just wanted their scene back would be watching a
    ##   progress bar made of geometry. The beat shortens instead, which keeps the order
    ##   legible while bounding the wait.


func bornReplaying*(index, count: int; now: float): float =
  ## Stamp the `index`-th of `count` objects arriving together, so they appear one after
  ## another from `now` rather than all at once.
  ##   The one rule both loaders use -- the desktop's `loadScene` and the browser's
  ##   `browser_bridge.nimSceneAddRaw` -- because a beat computed twice is a beat that
  ##   drifts, which is exactly what happened to this format's own version number.
  ##   `count` is the whole arrival, so the beat can be shortened to fit the cap; a caller
  ##   that does not know the whole may pass its own index plus one and get the unbounded
  ##   beat, which is what a single object arriving alone wants anyway.
  let step =
    if count <= 1: SECONDS_REPLAY_STEP
    else: min(SECONDS_REPLAY_STEP, SECONDS_REPLAY_WHOLE/float(count - 1))
  now + float(index)*step


proc replayFrom*(scene: var Scene; now: float) =
  ## Restamp every live item to arrive one after another from `now`, oldest creation first,
  ## so a scene assembled all at once plays back as the construction it is.
  ##   For the arrivals a reader did not build themselves and is about to be shown whole --
  ##   the opening scene and the demo preset. A scene built by hand never wants this: each
  ##   of its items was already stamped at the moment it actually arrived, and restamping
  ##   would replay a construction the reader just watched.
  ##   `loadScene` and `nimSceneAddRaw` stamp as they add instead, since they are building
  ##   the scene anyway and know each item's position as they go; this is the same rule
  ##   applied after the fact, for callers that are not.
  var slots: array[ITEMS_MAX, int]
  let count = scene.slotsCreated(slots)
  for position in 0 ..< count:
    scene.borns[slots[position]] = bornReplaying(position, count, now)


## The constants above sit **outside** the desktop-only guard below, and are exported,
## because they describe the *format* rather than the file handling: the browser build
## writes and reads the same bytes through `DataView`, and it gets them from here via
## `browser_bridge.nimSceneMagic`/`nimSceneVersion` rather than from literals of its own.
##   That is not decoration. This version was hand-copied into `glue.js` as a `1`, and when
## the bump to 2 landed here nothing updated it -- so the browser stamped every file it
## saved as version 1 while writing version 2 content, and refused every file the desktop
## wrote. Neither build could open the other's scenes, under a comment claiming both could.
## A derived value behind an export cannot drift like that; a literal in the other language
## can, and did.

when not defined(js):
  # Imported here rather than at the top of the module: a filesystem and a file handle are
  #   exactly what the browser build has none of, so the guard that excludes save and load
  #   should exclude what they need too, rather than leaving the JS build to warn about
  #   imports nothing on that path can use. `endians` joins them because the byte order it
  #   converts to is a property of the file, and the file is what this guard is about --
  #   the browser's own reader gets the same order from `DataView` instead.
  import std/[endians, os, syncio]

  proc writeLittle[T](file: File; value: T) =
    ## Write one multi-byte field in the file's own little-endian order.
    ##   Through a staging array rather than straight out of `value`, because
    ##   `littleEndian32`/`64` write into their destination: handing them the caller's own
    ##   variable would byte-swap a live value on a big-endian host as a side effect of
    ##   saving it.
    ##   Sized off `T` rather than taking a length, so a field can never be written at a
    ##   width its own type does not have.
    var bytes: array[sizeof(T), byte]
    when sizeof(T) == 4: littleEndian32(addr bytes[0], unsafeAddr value)
    elif sizeof(T) == 8: littleEndian64(addr bytes[0], unsafeAddr value)
    else: {.error: "Scene fields are written as 4- or 8-byte little-endian values only.".}
    discard file.writeBuffer(addr bytes[0], sizeof(T))


  proc readLittle[T](file: File; value: var T): bool =
    ## Read one multi-byte little-endian field back into host order; report whether the
    ## file actually held that many bytes, so a caller can name the truncation it found.
    var bytes: array[sizeof(T), byte]
    if file.readBuffer(addr bytes[0], sizeof(T)) != sizeof(T): return false
    when sizeof(T) == 4: littleEndian32(addr value, addr bytes[0])
    elif sizeof(T) == 8: littleEndian64(addr value, addr bytes[0])
    else: {.error: "Scene fields are read as 4- or 8-byte little-endian values only.".}
    true


  proc saveScene*(scene: Scene; path: string): string =
    ## Write every live item to `path`, in the format documented above; report outcome.
    if len(path) == 0: return "Save path is empty; nothing written."
    let file = open(path, fmWrite)
    defer: file.close

    discard file.writeChars(MAGIC_SCENE, 0, len(MAGIC_SCENE))
    file.write(char(VERSION_SCENE))
    file.write(char(ord(Basis.high) + 1))
    file.writeLittle(uint32(scene.len))

    # In creation order, which is the whole of what this file's own sequence means from
    #   version 3 on: loading walks it back in the same order, so the file replays the
    #   construction rather than however the free list happened to lay the slots out.
    var slots: array[ITEMS_MAX, int]
    let count = scene.slotsCreated(slots)
    for position in 0 ..< count:
      let item = scene[slots[position]]
      file.write(char(ord(item.ink)))
      file.write(char(ord(item.isVisible)))
      let
        text = toText(item.label)
        geometry = item.geometry
      file.write(char(len(text)))
      discard file.writeChars(text, 0, len(text))
      for b in Basis: file.writeLittle(geometry[b])

    &"Saved {scene.len} object(s) to `{path}`."


  proc loadScene*(scene: var Scene; path: string; now: float = 0.0): string =
    ## Replace scene's contents with what `path` holds; report outcome for display.
    ##   Parses into a scene of its own and only replaces the caller's on complete
    ##   success, so a bad path or a corrupt or foreign file leaves whatever scene
    ##   already held untouched rather than half-overwritten by however far parsing
    ##   got before failing.
    ##   `now` is the clock the arrival is staggered from (see `bornReplaying`), so the
    ##   scene plays its own construction back rather than appearing whole. Left at its
    ##   default by a caller with no clock -- a test, or a batch path with nothing to
    ##   animate for -- which lands every object long in the past, fully grown.
    ##   Reads every version down to `VERSION_SCENE_LEAST`; see the format table above
    ##   for what an older one costs.
    ##   Exceeds the working 60-line default: the format is a strict sequence of
    ##   fixed-size fields, each needing its own guard clause against a truncated or
    ##   foreign file before the next field can be trusted -- splitting the guards
    ##   into a helper would only return partial results across an extra proc
    ##   boundary for no reader benefit.
    if len(path) == 0: return "Load path is empty; nothing read."
    if not fileExists(path): return &"No such file `{path}`."

    let file = open(path, fmRead)
    defer: file.close

    var magic = newString(len(MAGIC_SCENE))
    if file.readChars(magic) != len(MAGIC_SCENE) or magic != MAGIC_SCENE:
      return &"`{path}` is not a scene file."

    var version_byte: array[1, char]
    if file.readChars(version_byte) != 1 or not readsSceneVersion(uint8(version_byte[0])):
      return &"`{path}` is a scene file of a version this build cannot read."
    let version = uint8(version_byte[0])

    let basis_count_here = ord(Basis.high) + 1
    var basis_count: array[1, char]
    if file.readChars(basis_count) != 1 or int(uint8(basis_count[0])) != basis_count_here:
      return &"`{path}` was saved under a different PGA dimension or metric; " &
        &"this build reads {basis_count_here}-term multivectors."

    var count: uint32
    if not file.readLittle(count):
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

      let length = int(uint8(length_byte[0]))
      var label = newString(length)
      if length > 0 and file.readChars(label) != length:
        return &"`{path}` is truncated partway through object {index}'s label."

      var geometry: Multivector
      for b in Basis:
        var coefficient: float
        if not file.readLittle(coefficient):
          return &"`{path}` is truncated partway through object {index}'s geometry."
        geometry[b] = coefficient

      # Read at the file's own version, then carried up to this build's; every field below
      #   this line means what `VERSION_SCENE` says it means, whatever wrote the file.
      let carried = itemUpgraded(
        ItemSaved(
          ink_ordinal: int(uint8(ink_byte[0])),
          is_visible: uint8(visible_byte[0]) != 0,
          label: label,
          geometry: geometry,
        ),
        version,
      )
      if carried.isNone:
        return &"`{path}` names an unknown palette slot for object {index}."

      # Added in file order, so the staging scene's own creation ordinals come out as the
      #   file's sequence -- which is what makes saving it again round-trip the order.
      let slot = staging.addItem(
        carried.get.geometry, carried.get.label, Ink(carried.get.ink_ordinal),
        bornReplaying(index, int(count), now),
      )
      staging.setVisible(slot, carried.get.is_visible)

    # Carry the palette on past what was loaded, rather than restarting it: the next object
    #   built on a reopened scene should not repeat the hue its first object already wears.
    #   Not stored in the file -- the count is enough to place the cycle, and a field nobody
    #   could edit by hand is not worth a format version.
    staging.index_ink = int(count)
    scene = staging
    &"Loaded {count} object(s) from `{path}`."


type OperationMemory* = object ## Remember the operation last applied, one per arity.
  ## So a picker opens on what you last reached for rather than on whatever the catalogue
  ## happens to list first -- a reader applying five wedges in a row should pick the
  ## operation once, not five times.
  ## Kept per *arity* because the two pickers offer disjoint lists: switching from one
  ## operand to two cannot carry a unary choice across, and falling back to the head of the
  ## list there would undo the memory for the arity you did not change.
  ## A plain value type with no refs, like `Selection`, so a GUI holds one by value.
  unary: Operation
  binary: Operation
  is_started: bool ## Whether the two above have been set; false leaves the defaults below.


const
  OPERATION_FIRST_UNARY* = Operation.Attitude
    ## Open a one-operand picker on this until something else is applied.
    ##   Attitude is what a reader reaches for first on a single object -- it is the one
    ##   unary operation whose result is drawn somewhere new rather than on top of its
    ##   own operand.
  OPERATION_FIRST_BINARY* = Operation.Wedge
    ## Open a two-operand picker on this until something else is applied.
    ##   The join, which is what two objects picked in order most often mean.


func lastOf*(memory: OperationMemory; arity: Arity): Operation =
  ## Read the operation a picker of this arity should open on.
  if not memory.is_started:
    return if arity == Arity.One: OPERATION_FIRST_UNARY else: OPERATION_FIRST_BINARY
  if arity == Arity.One: memory.unary else: memory.binary


func remember*(memory: var OperationMemory; operation: Operation) =
  ## Note an operation as the one its arity should open on next.
  ##   Call from every path that applies one, the drag menu's own `more…` handover
  ##   included, or a picker would forget whatever was reached for by another route.
  if not memory.is_started:
    memory.unary = OPERATION_FIRST_UNARY
    memory.binary = OPERATION_FIRST_BINARY
    memory.is_started = true
  if lut_operation_to_arity[operation] == Arity.One: memory.unary = operation
  else: memory.binary = operation

