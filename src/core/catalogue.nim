## Hold the one operation catalogue both front-ends read, and derive its notation.
##
## Twenty-seven operations, in the order a user meets them: every unary form first, then every
## binary one. A label is the operation's notation, two spaces, then its English name.
##
## Notation is **extracted from each operator's own declaration** in the vendored library at
## compile time, never transcribed and never taken from the summary tables at the top of those
## files. Those tables drift; the declarations are what the compiler obeys. Two deliberate
## departures from the extracted text, both marked where they happen:
##
## - The five accented operands arrive from the library carrying combining marks, which an
##   immediate-mode GUI cannot place — it has no text shaper and advances by each glyph's own
##   width, so a combining accent lands beside the operand instead of over it, and two of the
##   five become indistinguishable. Each is mapped to the spacing modifier letter of the same
##   accent, which carries its own advance and renders identically in both front-ends.
## - `attitude` is written postfix here though its declaration reads prefix, for consistency
##   with the other twelve unary entries.
##
## Spacing around a binary operator is normalised, so `𝐦∙𝐧` and `𝐦 ∧ 𝐧★` read alike. Only
## the spacing is normalised: every symbol, including the U+2212 minus in `subtract` that is
## indistinguishable from a hyphen in an editor, is the declaration's own.

{.experimental: "strictFuncs".}

import std/strutils

import ./algebra



#[ Type Definitions ]#

type
  Arity* {.pure.} = enum
    ## Count operands an operation reads.
    Unary,  ## Reads 𝐦 alone.
    Binary, ## Reads 𝐦 and 𝐧, positionally.

  Operation* {.pure.} = enum
    ## Name every operation of the catalogue, in catalogue order.
    Attitude,             ## 𝐦⊖
    Support,              ## 𝐦∩
    Antisupport,          ## 𝐦∪
    Bulk,                 ## 𝐦∙
    Weight,               ## 𝐦∘
    Unitize,              ## 𝐦ˆ
    ComplementLeft,       ## 𝐦ˍ
    ComplementRight,      ## 𝐦¯
    DualBulk,             ## 𝐦★
    DualWeight,           ## 𝐦☆
    Reverse,              ## 𝐦˜
    Antireverse,          ## 𝐦˷
    Negate,               ## −𝐦
    Add,                  ## 𝐦 + 𝐧
    Subtract,             ## 𝐦 − 𝐧
    Wedge,                ## 𝐦 ∧ 𝐧
    Antiwedge,            ## 𝐦 ∨ 𝐧
    GeometricProduct,     ## 𝐦 ⟑ 𝐧
    GeometricAntiproduct, ## 𝐦 ⟇ 𝐧
    InnerProduct,         ## 𝐦 ∙ 𝐧
    InnerAntiproduct,     ## 𝐦 ∘ 𝐧
    ExpandBulk,           ## 𝐦 ∧ 𝐧★
    ExpandWeight,         ## 𝐦 ∧ 𝐧☆
    ContractBulk,         ## 𝐦 ∨ 𝐧★
    ContractWeight,       ## 𝐦 ∨ 𝐧☆
    ProjectCentral,       ## 𝐧 ∨ (𝐦 ∧ 𝐧★)
    ProjectOrthogonal,    ## 𝐧 ∨ (𝐦 ∧ 𝐧☆)

const
  OPERAND_FIRST* = "𝐦"
    ## Name the first operand as the algebra writes it.
  OPERAND_SECOND* = "𝐧"
    ## Name the second operand as the algebra writes it.



#[ Operand Substitution ]#

func substituteOperands*(notation, first, second: string): string =
  ## Substitute operand names into a notation template.
  ##   Passes through sentinels so an operand name that itself contains an operand letter is
  ##   not substituted a second time, and so a template naming the second operand twice
  ##   substitutes both.
  const
    SENTINEL_FIRST = "\x01"
    SENTINEL_SECOND = "\x02"
  result = notation
    .replace(OPERAND_FIRST, SENTINEL_FIRST)
    .replace(OPERAND_SECOND, SENTINEL_SECOND)
  result = result
    .replace(SENTINEL_FIRST, first)
    .replace(SENTINEL_SECOND, second)



#[ Notation Extraction ]#

const
  SOURCE_OPERATORS = staticRead("../../vendor/pga/pga/operators.nim")
    ## Read the library's operator declarations, the source of truth for their notation.
  SOURCE_MULTIVECTORS = staticRead("../../vendor/pga/pga/multivectors.nim")
    ## Read the library's arithmetic declarations, which carry add, subtract and negate.
  SOURCE_FACADE = staticRead("../../vendor/pga/pga.nim")
    ## Read the library's façade, whose one-line bodies define the compound projections.

func toSpacingModifiers(notation: string): string {.compileTime.} =
  ## Map every combining accent to the spacing modifier letter of the same accent.
  ##   Documented above: a combining mark has no advance of its own, so an immediate-mode
  ##   renderer stacks it beside the operand rather than over it.
  # Written as escapes: a combining mark and its spacing twin are indistinguishable in an
  #   editor, which is exactly the confusion this mapping exists to end.
  const LUT_COMBINING_TO_SPACING = [
    ("\u0302", "\u02C6"), # Combining circumflex to modifier circumflex: unitize.
    ("\u0332", "\u02CD"), # Combining low line to modifier low macron: left complement.
    ("\u0305", "\u00AF"), # Combining overline to macron: right complement.
    ("\u0303", "\u02DC"), # Combining tilde to small tilde: reverse.
    ("\u0330", "\u02F7"), # Combining tilde below to modifier low tilde: antireverse.
  ]
  result = notation
  for (combining, spacing) in LUT_COMBINING_TO_SPACING:
    result = result.replace(combining, spacing)


func normalizeSpacing(notation: string, arity: Arity): string {.compileTime.} =
  ## Space a binary notation evenly around its operator, leaving unary notation alone.
  if arity == Arity.Unary: return notation
  result = ""
  var index = 0
  while index < notation.len:
    if notation.continuesWith(OPERAND_FIRST, index):
      result.add(OPERAND_FIRST)
      index += OPERAND_FIRST.len
      if index < notation.len and notation[index] != ' ': result.add(' ')
    elif notation.continuesWith(OPERAND_SECOND, index):
      if result.len > 0 and result[^1] notin {' ', '('}: result.add(' ')
      result.add(OPERAND_SECOND)
      index += OPERAND_SECOND.len
    else:
      result.add(notation[index])
      index += 1


func extractNotation(text: string): string {.compileTime.} =
  ## Extract the notation a doc line states, i.e. the phrase following its `i.e.`.
  const MARKER = "i.e. "
  var marker_index = -1
  for start in 0 .. text.len - MARKER.len:
    if text.continuesWith(MARKER, start) or text.continuesWith("I.e. ", start):
      marker_index = start + MARKER.len
      break
  if marker_index < 0: return ""
  result = text[marker_index .. ^1].strip()
  # Cut the definition off a notation that goes on to state what it equals.
  let equals_index = result.find(" = ")
  if equals_index >= 0: result = result[0 ..< equals_index]
  result = result.strip(chars = {'.', ' '})


func isCandidate(notation: string, arity: Arity): bool {.compileTime.} =
  ## Report whether an extracted notation is the one an operation of this arity wants.
  ##   Rejects the scalar-operand overloads the library also declares, which read 𝐬.
  if not notation.contains(OPERAND_FIRST): return false
  if notation.contains("𝐬"): return false
  case arity
  of Arity.Unary: not notation.contains(OPERAND_SECOND)
  of Arity.Binary: notation.contains(OPERAND_SECOND)


func declaredKey(line: string): string {.compileTime.} =
  ## Read the declared name a source line introduces, or nothing where it introduces none.
  ##   Covers the library's three declaration forms: a `defineOperator` call naming its
  ##   symbols, an accent-quoted operator definition, and a plain named function.
  let trimmed = line.strip()
  if trimmed.startsWith("symbols = "):
    let opening = trimmed.find('"')
    if opening < 0: return ""
    let closing = trimmed.find('"', opening + 1)
    if closing < 0: return ""
    return trimmed[opening + 1 ..< closing]
  for keyword in ["func ", "template ", "proc "]:
    if not trimmed.startsWith(keyword): continue
    let remainder = trimmed[keyword.len .. ^1]
    if remainder.startsWith("`"):
      let closing = remainder.find('`', 1)
      if closing < 0: return ""
      return remainder[1 ..< closing]
    var name = ""
    for character in remainder:
      if character in {'*', '(', '[', ':', ' '}: break
      name.add(character)
    return name
  ""


func docText(line: string): string {.compileTime.} =
  ## Read the documentation a source line carries, in either form the library writes it.
  ##   An operator generated from a Cayley table carries its documentation as the `docs`
  ##   argument of the generating call; a hand-written one carries it as a doc comment.
  let trimmed = line.strip()
  if trimmed.startsWith("##"): return trimmed
  if trimmed.startsWith("docs = "):
    let opening = trimmed.find('"')
    if opening < 0: return ""
    let closing = trimmed.rfind('"')
    if closing <= opening: return ""
    return trimmed[opening + 1 ..< closing]
  ""


func notationOf(key: string, arity: Arity): string {.compileTime.} =
  ## Extract the notation the library declares for an operator, by its declared name.
  ##   Walks each declaration and the documentation under it, so the notation read is the one
  ##   written on that declaration and not one from a table elsewhere in the file.
  for source in [SOURCE_OPERATORS, SOURCE_MULTIVECTORS]:
    var current_key = ""
    for line in source.splitLines():
      let declared = declaredKey(line)
      if declared.len > 0: current_key = declared
      if current_key != key: continue
      let documentation = docText(line)
      if documentation.len == 0: continue
      let notation = extractNotation(documentation).toSpacingModifiers
      if notation.isCandidate(arity): return notation.normalizeSpacing(arity)
  raise newException(ValueError, "No declared notation for operator `" & key & "`.")


func bodyOf(key: string): string {.compileTime.} =
  ## Read the one-line body a façade function is declared with.
  for line in SOURCE_FACADE.splitLines():
    if declaredKey(line) != key: continue
    let assignment = line.find(" = ")
    if assignment < 0: return ""
    return line[assignment + 3 .. ^1].strip()
  ""


func notationOfProjection(key: string): string {.compileTime.} =
  ## Render the notation of a compound projection from the body it is declared with.
  ##   The two projections carry no notation in their own documentation, so it is composed
  ##   from the body — `n ∨ (m ∧★ n)` — by substituting operands into the notation of each
  ##   operator the body names. Written for that one body shape, `x ∨ (y OP z)`, rather than
  ##   as a general expression renderer, because those are the only two bodies it reads.
  let body = bodyOf(key)
  doAssert body.len > 0, "No façade body for projection `" & key & "`."
  let
    opening = body.find('(')
    closing = body.rfind(')')
  doAssert opening > 0 and closing > opening,
    "Projection body `" & body & "` is not of the expected `x ∨ (y OP z)` shape."
  let
    outer_key = body[0 ..< opening].strip().split(' ')[^1]
    inner = body[opening + 1 ..< closing].strip()

  # Read the inner operator, which the library writes either infixed or dot-called with an
  #   accent-quoted name, e.g. `m ∧★ n` against ``m.`∧ ☆`n``.
  var inner_key = ""
  if inner.contains('`'):
    let
      first_quote = inner.find('`')
      second_quote = inner.find('`', first_quote + 1)
    inner_key = inner[first_quote + 1 ..< second_quote].replace(" ", "")
  else:
    let fields = inner.split(' ')
    doAssert fields.len == 3, "Inner expression `" & inner & "` is not a single infix."
    inner_key = fields[1]

  let inner_notation = substituteOperands(
    notationOf(inner_key, Arity.Binary), OPERAND_FIRST, OPERAND_SECOND
  )
  substituteOperands(
    notationOf(outer_key, Arity.Binary), OPERAND_SECOND, "(" & inner_notation & ")"
  )


func toPostfix(notation: string): string {.compileTime.} =
  ## Rewrite a prefix unary notation as a postfix one.
  ##   Used once, for `attitude`, whose declaration reads prefix while the catalogue reads
  ##   postfix for consistency with its twelve neighbours.
  doAssert notation.endsWith(OPERAND_FIRST),
    "Notation `" & notation & "` is not prefix, so it cannot be flipped."
  OPERAND_FIRST & notation[0 ..< notation.len - OPERAND_FIRST.len]



#[ Catalogue ]#

const LUT_OPERATION_TO_ARITY*: array[Operation, Arity] = [
  ## Count the operands of every operation.
  Operation.Attitude: Arity.Unary,
  Operation.Support: Arity.Unary,
  Operation.Antisupport: Arity.Unary,
  Operation.Bulk: Arity.Unary,
  Operation.Weight: Arity.Unary,
  Operation.Unitize: Arity.Unary,
  Operation.ComplementLeft: Arity.Unary,
  Operation.ComplementRight: Arity.Unary,
  Operation.DualBulk: Arity.Unary,
  Operation.DualWeight: Arity.Unary,
  Operation.Reverse: Arity.Unary,
  Operation.Antireverse: Arity.Unary,
  Operation.Negate: Arity.Unary,
  Operation.Add: Arity.Binary,
  Operation.Subtract: Arity.Binary,
  Operation.Wedge: Arity.Binary,
  Operation.Antiwedge: Arity.Binary,
  Operation.GeometricProduct: Arity.Binary,
  Operation.GeometricAntiproduct: Arity.Binary,
  Operation.InnerProduct: Arity.Binary,
  Operation.InnerAntiproduct: Arity.Binary,
  Operation.ExpandBulk: Arity.Binary,
  Operation.ExpandWeight: Arity.Binary,
  Operation.ContractBulk: Arity.Binary,
  Operation.ContractWeight: Arity.Binary,
  Operation.ProjectCentral: Arity.Binary,
  Operation.ProjectOrthogonal: Arity.Binary,
]

const LUT_OPERATION_TO_NAME*: array[Operation, string] = [
  ## Name every operation in English, as its label reads after the notation.
  Operation.Attitude: "attitude",
  Operation.Support: "support",
  Operation.Antisupport: "antisupport",
  Operation.Bulk: "bulk",
  Operation.Weight: "weight",
  Operation.Unitize: "unitize",
  Operation.ComplementLeft: "left complement",
  Operation.ComplementRight: "right complement",
  Operation.DualBulk: "bulk dual",
  Operation.DualWeight: "weight dual",
  Operation.Reverse: "reverse",
  Operation.Antireverse: "antireverse",
  Operation.Negate: "negate",
  Operation.Add: "add",
  Operation.Subtract: "subtract",
  Operation.Wedge: "wedge (join)",
  Operation.Antiwedge: "antiwedge (meet)",
  Operation.GeometricProduct: "geometric product",
  Operation.GeometricAntiproduct: "geometric antiproduct",
  Operation.InnerProduct: "inner product",
  Operation.InnerAntiproduct: "inner antiproduct",
  Operation.ExpandBulk: "bulk expansion",
  Operation.ExpandWeight: "weight expansion",
  Operation.ContractBulk: "bulk contraction",
  Operation.ContractWeight: "weight contraction",
  Operation.ProjectCentral: "central projection",
  Operation.ProjectOrthogonal: "orthogonal projection",
]

const LUT_OPERATION_TO_NOTATION*: array[Operation, string] = block:
  ## Extract the notation of every operation from the library's own declarations.
  var lut: array[Operation, string]
  lut[Operation.Attitude] = notationOf("⊖", Arity.Unary).toPostfix
  lut[Operation.Support] = notationOf("∩", Arity.Unary)
  lut[Operation.Antisupport] = notationOf("∪", Arity.Unary)
  lut[Operation.Bulk] = notationOf("∙", Arity.Unary)
  lut[Operation.Weight] = notationOf("∘", Arity.Unary)
  lut[Operation.Unitize] = notationOf("^", Arity.Unary)
  lut[Operation.ComplementLeft] = notationOf("\\", Arity.Unary)
  lut[Operation.ComplementRight] = notationOf("/", Arity.Unary)
  lut[Operation.DualBulk] = notationOf("★", Arity.Unary)
  lut[Operation.DualWeight] = notationOf("☆", Arity.Unary)
  lut[Operation.Reverse] = notationOf("~", Arity.Unary)
  lut[Operation.Antireverse] = notationOf("~∘", Arity.Unary)
  lut[Operation.Negate] = notationOf("-", Arity.Unary)
  lut[Operation.Add] = notationOf("+", Arity.Binary)
  lut[Operation.Subtract] = notationOf("-", Arity.Binary)
  lut[Operation.Wedge] = notationOf("∧", Arity.Binary)
  lut[Operation.Antiwedge] = notationOf("∨", Arity.Binary)
  lut[Operation.GeometricProduct] = notationOf("⟑", Arity.Binary)
  lut[Operation.GeometricAntiproduct] = notationOf("⟇", Arity.Binary)
  lut[Operation.InnerProduct] = notationOf("∙", Arity.Binary)
  lut[Operation.InnerAntiproduct] = notationOf("∘", Arity.Binary)
  lut[Operation.ExpandBulk] = notationOf("∧★", Arity.Binary)
  lut[Operation.ExpandWeight] = notationOf("∧☆", Arity.Binary)
  lut[Operation.ContractBulk] = notationOf("∨★", Arity.Binary)
  lut[Operation.ContractWeight] = notationOf("∨☆", Arity.Binary)
  lut[Operation.ProjectCentral] = notationOfProjection("projectCentral")
  lut[Operation.ProjectOrthogonal] = notationOfProjection("projectOrthogonal")
  lut

const LABEL_SEPARATOR* = "  "
  ## Separate a label's notation from its English name by exactly two spaces.

const LUT_OPERATION_TO_LABEL*: array[Operation, string] = block:
  ## Compose the label both front-ends show for every operation.
  var lut: array[Operation, string]
  for operation in Operation:
    lut[operation] = LUT_OPERATION_TO_NOTATION[operation] & LABEL_SEPARATOR &
      LUT_OPERATION_TO_NAME[operation]
  lut

# Assert the catalogue is the size the tool and its documentation both claim.
static:
  doAssert ord(Operation.high) + 1 == 27, "The catalogue holds exactly 27 operations."



#[ Catalogue Queries ]#

func arity*(operation: Operation): Arity {.inline.} = LUT_OPERATION_TO_ARITY[operation]
  ## Count the operands an operation reads.


func label*(operation: Operation): string {.inline.} = LUT_OPERATION_TO_LABEL[operation]
  ## Read the label both front-ends show for an operation.


func notation*(operation: Operation): string {.inline.} = LUT_OPERATION_TO_NOTATION[operation]
  ## Read the notation an operation is written in.


func derivedLabel*(operation: Operation, first, second: string): string =
  ## Name the result of applying an operation to operands of these names.
  ##   Substitutes into the notation alone: the English name is cut off first, because it is
  ##   full of ordinary m's and n's that would be substituted into nonsense.
  substituteOperands(operation.notation, first, second)


iterator operations*(arity: Arity): Operation =
  ## Walk the catalogue filtered by arity, in catalogue order.
  for operation in Operation:
    if operation.arity == arity: yield operation


func operationCount*(arity: Arity): int =
  ## Count the operations of one arity, for a picker sizing itself.
  for operation in Operation:
    if operation.arity == arity: result += 1



#[ Application ]#

func apply*(operation: Operation, m, n: Multivector): Multivector =
  ## Apply an operation to its operands, through the library's own named functions.
  ##   A unary operation ignores its second operand.
  case operation
  of Operation.Attitude: attitude(m)
  of Operation.Support: support(m)
  of Operation.Antisupport: supportAnti(m)
  of Operation.Bulk: bulk(m)
  of Operation.Weight: weight(m)
  of Operation.Unitize: unitize(m)
  of Operation.ComplementLeft: complementLeft(m)
  of Operation.ComplementRight: complementRight(m)
  of Operation.DualBulk: dualBulk(m)
  of Operation.DualWeight: dualWeight(m)
  of Operation.Reverse: reverse(m)
  of Operation.Antireverse: reverseAnti(m)
  of Operation.Negate: negate(m)
  of Operation.Add: add(m, n)
  of Operation.Subtract: subtract(m, n)
  of Operation.Wedge: wedge(m, n)
  of Operation.Antiwedge: wedgeAnti(m, n)
  of Operation.GeometricProduct: wedgeDot(m, n)
  of Operation.GeometricAntiproduct: wedgeDotAnti(m, n)
  of Operation.InnerProduct: dot(m, n)
  of Operation.InnerAntiproduct: dotAnti(m, n)
  of Operation.ExpandBulk: expandBulk(m, n)
  of Operation.ExpandWeight: expandWeight(m, n)
  of Operation.ContractBulk: contractBulk(m, n)
  of Operation.ContractWeight: contractWeight(m, n)
  of Operation.ProjectCentral: projectCentral(m, n)
  of Operation.ProjectOrthogonal: projectOrthogonal(m, n)
