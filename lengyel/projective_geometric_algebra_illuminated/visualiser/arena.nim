## Bump-allocate scratch memory from a fixed block, so a short-lived buffer costs an
## offset bump instead of a call to the allocator, and the whole block is reclaimed at
## once by resetting the offset rather than freeing anything individually -- the style
## Casey Muratori and Ryan Fleury both write about.
##
## Two lifetimes cover everything this project still allocates dynamically:
##
##   |-----------|--------------------------------|-------------------------------------|
##   | Arena     | Reset                          | Backs                                |
##   |-----------|--------------------------------|-------------------------------------|
##   | Permanent | Never; lives until process exit | The pixel readback buffer, sized    |
##   |           |                                  | once and reused for every export.   |
##   | Frame     | After each throwaway unit of    | PNG's filtered/compressed scanlines, |
##   |           | work: one PNG write, one GIF    | GIF's quantized indices and LZW      |
##   |           | sub-frame, one drawn frame.     | output -- built once, read once.     |
##   |-----------|--------------------------------|-------------------------------------|
##
## Neither backs anything in the interactive draw loop itself: `Scene` and `MeshSet` are
## already fixed arrays with their own lifetime (permanent, and cleared in place every
## frame respectively), and the loop's own text formatting already writes into stack
## buffers (`format.nim`), which cost nothing further to reclaim -- the call stack unwinds
## on its own. The frame arena is still reset once per drawn frame regardless, so a future
## per-frame scratch need has somewhere ready to go without another design decision; today
## nothing in the draw loop asks it for anything.
##
## Backing storage is a plain global array, not a runtime allocation: reserving the block
## costs one line in the binary's own data segment, never a call to the allocator, and
## every arena described above is exhausted by that same `doAssert` rather than by growing.

{.experimental: "strictFuncs".}

import std/strformat



#[ Type Definitions ]#

type Arena* = object ## Hold a fixed block of bytes and how much of it is in use.
  buffer: ptr UncheckedArray[byte]
  capacity: int
  used: int



#[ Arena Lifetime ]#

proc initArena*(backing: var openArray[byte]): Arena =
  ## Wrap caller-owned backing storage as an arena; nothing is allocated here, as
  ## `backing` is expected to already be a fixed global array.
  Arena(
    buffer: cast[ptr UncheckedArray[byte]](addr backing[0]),
    capacity: len(backing),
    used: 0,
  )


proc reset*(arena: var Arena) =
  ## Reclaim everything carved from `arena` so far, in one step; nothing is freed
  ## individually, since nothing carved from an arena is ever freed individually.
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
