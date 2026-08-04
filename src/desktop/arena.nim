## Hand out scratch memory by bumping a pointer, never by freeing one.
##
## Two arenas: a permanent one that is never reset, sized to the capture run's own measured
## requirement, and a frame one reset after each throwaway unit of work. The interactive draw
## loop asks neither for anything — it draws out of fixed storage — so these exist for image
## export, GIF quantisation and compression alone.
##
## A compression dictionary needing random-access probing within a frame is **not** a third
## arena: arenas are bump-only append, and that table lives in `gif.nim` as its own
## fixed-capacity open-addressed storage.

{.experimental: "strictFuncs".}



#[ Type Definitions ]#

type Arena* = object
  ## Hold one bump allocator's storage and how much of it is spent.
  storage: seq[uint8]
  used: int
  high_water: int
  name*: string



#[ Construction ]#

proc initArena*(name: string, capacity_bytes: int): Arena =
  ## Reserve an arena's whole storage once, at startup.
  result.storage = newSeq[uint8](capacity_bytes)
  result.name = name


proc reset*(arena: var Arena) =
  ## Hand the whole arena back, keeping the high-water reading.
  ##   Instantaneous usage reads near-empty almost any time it could be sampled, which is why
  ##   the diagnostics bar shows the high water rather than the current fill.
  arena.used = 0



#[ Allocation ]#

proc take*(arena: var Arena, bytes: int): ptr uint8 =
  ## Take a run of bytes, or nothing where the arena is spent.
  ##   Signals rather than growing: a silent grow would hide the sizing this arena exists to
  ##   make measurable.
  if arena.used + bytes > arena.storage.len: return nil
  result = addr arena.storage[arena.used]
  arena.used += bytes
  if arena.used > arena.high_water: arena.high_water = arena.used


func capacity*(arena: Arena): int {.inline.} = arena.storage.len
  ## Read how many bytes the arena reserved.

func used*(arena: Arena): int {.inline.} = arena.used
  ## Read how many bytes are handed out right now.

func highWater*(arena: Arena): int {.inline.} = arena.high_water
  ## Read the most bytes ever handed out at once.
