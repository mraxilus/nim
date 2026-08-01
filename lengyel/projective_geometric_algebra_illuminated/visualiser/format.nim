## Format numbers into fixed char storage without touching the heap.
##
## Nim's own `$` and `strformat` always produce a heap-allocated `string`, refcounted
## like every other Nim `string`; C's own `snprintf` writes into storage the caller
## already owns instead. Every visible item's coefficients are redrawn this way, once
## per item, every frame, so the difference is an allocator call per number, per item,
## per frame, against none at all.
##
## Sits beside `sdl3`, `opengl` and `image` as a binding over something external -- here
## the C runtime's own formatter -- rather than beside `scene` or `mesh`, which hold
## this project's own logic.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths, transitively through `interaction`; see `visualiser.nim`'s own
## "Render Paths" table.

{.experimental: "strictFuncs".}



#[ Binding Configuration ]#

const HEADER = "<stdio.h>"
  ## Name header the C runtime's own formatter is imported through.

# Mechanical one-to-one import of the C runtime's own formatter; see its manual page.
proc snprintf(buffer: cstring; size: csize_t; format: cstring): cint
  {.importc: "snprintf", header: HEADER, varargs, discardable, noSideEffect.}



#[ Fixed Text Buffers ]#

proc appendChars*(storage: var openArray[char]; cursor: var int; text: openArray[char]) =
  ## Copy as much of `text` as still fits after `cursor`, advancing it.
  ##   Silently truncates rather than overrunning `storage`, exactly as `toChars` does;
  ##   storage is display only, and the GUI must never write past its own buffer.
  for ch in text:
    if cursor >= len(storage) - 1: return
    storage[cursor] = ch
    inc cursor


proc appendMagnitude*(storage: var openArray[char]; cursor: var int; value: float) =
  ## Format `value` as 4 significant digits straight into `storage`, through C's own
  ## formatter, so printing a coefficient never allocates a Nim string just to hold it.
  ##   The `#` flag keeps trailing zeros, matching what `strformat`'s own `:.4g` writes.
  var buffer: array[32, char]
  let count = snprintf(cast[cstring](addr buffer[0]), csize_t(len(buffer)), "%.4g", value)
  appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


proc appendInt*(storage: var openArray[char]; cursor: var int; value: int) =
  ## Format `value` as a plain decimal integer straight into `storage`.
  ##   Every caller here counts something small and bounded (items, vertices, frames
  ##   per second), so narrowing to `cint` never truncates a real value.
  var buffer: array[24, char]
  let count = snprintf(cast[cstring](addr buffer[0]), csize_t(len(buffer)), "%d", cint(value))
  appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


proc appendFixed*(storage: var openArray[char]; cursor: var int; value: float; digits: int) =
  ## Format `value` to a fixed number of digits after the point, matching what
  ## `strformat`'s own `:.Nf` writes, straight into `storage`.
  var buffer: array[32, char]
  let count =
    snprintf(cast[cstring](addr buffer[0]), csize_t(len(buffer)), "%.*f", cint(digits), value)
  appendChars(storage, cursor, buffer.toOpenArray(0, int(count) - 1))


proc finishChars*(storage: var openArray[char]; cursor: int) =
  ## Zero every byte from `cursor` onward, so text a longer previous write left behind
  ## can never trail past whatever was written this time.
  for i in cursor ..< len(storage): storage[i] = '\0'



#[ One-Line Assembly ]#

template buildChars*(storage: var openArray[char]; body: untyped): cstring =
  ## Zero a fresh `cursor`, run `body` -- a sequence of `append*` calls against
  ## `storage` and that injected `cursor` -- then terminate and return a pointer
  ## into `storage`, so building one line of text costs only the calls that vary
  ## between call sites, not the `cursor`/`finishChars`/cast boilerplate around them.
  block:
    var cursor {.inject.} = 0
    body
    finishChars(storage, cursor)
    cast[cstring](unsafeAddr storage[0])
