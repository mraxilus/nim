## Bump-allocate scratch memory from a fixed block, so a short-lived buffer costs an
## offset bump instead of a call to the allocator, and the whole block is reclaimed at
## once by resetting the offset rather than freeing anything individually -- the style
## Casey Muratori and Ryan Fleury both write about.
##
## Three lifetimes cover everything this project still allocates dynamically:
##
##   |-----------|---------------------------------|--------------------------------------|
##   | Arena     | Reset                           | Backs                                |
##   |-----------|---------------------------------|--------------------------------------|
##   | Permanent | Never; lives until process exit | The pixel readback buffer, sized     |
##   |           |                                 | once and reused for every export.    |
##   | Export    | After each throwaway unit of    | PNG's filtered/compressed scanlines, |
##   |           | work: one PNG write, one GIF    | GIF's quantized indices and LZW      |
##   |           | sub-frame.                      | output -- built once, read once.     |
##   | Frame     | On the *next* frame's swap, so  | The draw loop's own scratch: the     |
##   | swap pair | last frame's bytes survive this | points a tessellation step           |
##   |           | one. See `ArenaSwap`.           | assembles before emitting them.      |
##   |-----------|---------------------------------|--------------------------------------|
##
## `Scene` and `MeshSet` are on none of them: both are fixed arrays with their own lifetime,
## permanent and cleared-in-place respectively, and the loop's text formatting writes into
## stack buffers (`format.nim`) that the call stack reclaims on its own.
##
## The export arena and the frame pair are kept apart deliberately, though both are "per
## unit of work": an export's scratch is measured in tens of megabytes and happens once on
## a keypress, a frame's in tens of kilobytes and happens sixty times a second. Sizing one
## block for both would reserve the export's capacity twice over to buy the frame's swap.
##
## Backing storage is a plain global array, not a runtime allocation: reserving the block
## costs one line in the binary's own data segment, never a call to the allocator, and
## every arena described above is exhausted by that same `doAssert` rather than by growing.
##
## Desktop-only; unreachable from the browser build. See `visualiser.nim`'s own "Render
## Paths" table.

{.experimental: "strictFuncs".}

import std/strformat



#[ Type Definitions ]#

type Arena* = object ## Hold a fixed block of bytes and how much of it is in use.
  buffer: ptr UncheckedArray[byte]
  capacity: int
  used: int
  peak_used: int ## Highest `used` has ever reached; never falls back on `reset`.
    ## Exists so a live display can show what an arena's activity actually looks like:
    ## `used` alone reads near zero almost anywhere it would be sampled, since carving
    ## and reset both happen well within one frame, before anything outside this module
    ## gets a chance to look.



#[ Arena Lifetime ]#

proc initArena*(backing: var openArray[byte]): Arena =
  ## Wrap caller-owned backing storage as an arena; nothing is allocated here, as
  ## `backing` is expected to already be a fixed global array.
  Arena(
    buffer: cast[ptr UncheckedArray[byte]](addr backing[0]),
    capacity: len(backing),
    used: 0,
    peak_used: 0,
  )


proc reset*(arena: var Arena) =
  ## Reclaim everything carved from `arena` so far, in one step; nothing is freed
  ## individually, since nothing carved from an arena is ever freed individually.
  ##   `peak_used` is deliberately untouched: it tracks the arena's own high-water mark
  ##   across its whole lifetime, not since the last reset.
  arena.used = 0



#[ Arena Allocation ]#

proc push*[T](arena: var Arena; count: int): ptr UncheckedArray[T] =
  ## Carve `count` elements of `T` from `arena`, uninitialised.
  ##   Never freed on its own; reclaimed only when `reset` reclaims the whole arena.
  let bytes_needed = count * sizeof(T)
  doAssert arena.used + bytes_needed <= arena.capacity,
    &"Arena holds {arena.capacity} bytes; {arena.used + bytes_needed} asked for. " &
    "Raise whichever `--define:visualiser.capacity_arena_*` backs this arena."
  result = cast[ptr UncheckedArray[T]](addr arena.buffer[arena.used])
  arena.used += bytes_needed
  if arena.used > arena.peak_used: arena.peak_used = arena.used



#[ Frame Swap Pair ]#

type ArenaSwap* = object ## Hold two frame arenas and which of them this frame is writing.
  ## **A two-frame lifetime.** What a frame carves stays readable through the next frame as
  ## `previous`, and is reclaimed only when its block comes round again -- so a frame can
  ## read what the one before it worked out without either copying the answer somewhere
  ## safer or keeping it alive forever.
  ##   The swap is what makes that true, and it is the whole mechanism: `swap` moves the
  ## write cursor to the other block **and resets it**, so a frame always begins with an
  ## arena holding nothing. Reclaiming on the way in rather than on the way out is what
  ## leaves the block written last frame intact until the moment it is needed again.
  arenas: array[2, Arena]
  index_current: int ## Which of `arenas` this frame carves from; the other is last frame's.


proc initArenaSwap*(backing_first, backing_second: var openArray[byte]): ArenaSwap =
  ## Wrap two caller-owned blocks as a swap pair, the first of them current.
  ##   Two blocks rather than one twice the size: the point is that last frame's bytes are
  ##   still *there*, which a single arena reset in place cannot promise.
  ArenaSwap(
    arenas: [initArena(backing_first), initArena(backing_second)],
    index_current: 0,
  )


proc swap*(pair: var ArenaSwap) =
  ## Begin a new frame: what was current becomes readable as `previous`, and the block
  ## being moved to is reclaimed so this frame starts clean.
  pair.index_current = 1 - pair.index_current
  pair.arenas[pair.index_current].reset()


proc current*(pair: var ArenaSwap): var Arena = pair.arenas[pair.index_current]
  ## Reach the arena this frame carves from.

proc previous*(pair: var ArenaSwap): var Arena = pair.arenas[1 - pair.index_current]
  ## Reach the arena the *previous* frame carved from, still holding what it wrote.
  ##   Read-only in spirit: carving from it would take memory this frame's `swap` is about
  ##   to reclaim, and nothing here stops that -- the discipline is the caller's.

func usedSwap*(pair: ArenaSwap): int = pair.arenas[pair.index_current].used
  ## Report bytes carved this frame.

func capacitySwap*(pair: ArenaSwap): int = pair.arenas[0].capacity + pair.arenas[1].capacity
  ## Report both blocks together, which is what the pair actually reserves.

func peakUsedSwap*(pair: ArenaSwap): int =
  ## Report the most either block has ever held at once.
  ##   The larger of the two rather than their sum: they hold one frame's work each, not
  ##   halves of one, so a sum would name a quantity no single frame ever reached.
  max(pair.arenas[0].peak_used, pair.arenas[1].peak_used)



#[ Arena Introspection ]#

func used*(arena: Arena): int = arena.used
  ## Report bytes carved from `arena` and not yet reclaimed by a `reset`.

func capacity*(arena: Arena): int = arena.capacity
  ## Report the fixed size `arena` was constructed with.

func peakUsed*(arena: Arena): int = arena.peak_used
  ## Report the most `arena` has ever held at once, across every `reset` so far.
