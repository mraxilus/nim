## Which objects are picked right now, as an ordered fixed-capacity list of slots.
##
## Order is the whole point, and the reason this is a list rather than a set: an operation
## reads its operands positionally, so the first slot picked is `m` and the second is `n`.
## A set would answer "is this selected" and lose the only other question anyone asks.
##
## Selection is deliberately **not** part of `Scene`. It is a view of the scene, not
## content: it is never saved to a `.rgascene`, never recorded on the undo timeline, and a
## restored snapshot clears it outright, since a snapshot's slot numbers need not match
## whatever was picked against the live scene.
##
## A plain fixed-size value type with no refs, like `History` beside it -- copying one is a
## value copy, so it can live in a GUI's own state struct without an allocator.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table. The browser drives it through
## `browser_bridge`'s own `nimSelect*` exports rather than keeping a parallel list in
## JavaScript, so every rule about membership, order and arity is written once here.

{.experimental: "strictFuncs".}

import std/options

import ./[marker, scene]



#[ Type Definitions ]#

type Selection* = object ## Hold slots picked, in the order they were picked.
  slots: array[ITEMS_MAX, int] ## Picked slots, oldest pick first; only the first `count`
    ## entries carry meaning.
  count: int ## Slots picked so far, <= ITEMS_MAX.



#[ Reading A Selection ]#

func len*(selection: Selection): int = selection.count
  ## Count slots picked.


func at*(selection: Selection; position: int): int = selection.slots[position]
  ## Read the slot picked at a position, oldest pick first. Position 0 is operand `m` and
  ## position 1 is `n`; callers bound themselves against `len`.


func contains*(selection: Selection; slot: int): bool =
  ## Report whether a slot is picked.
  for position in 0 ..< selection.count:
    if selection.slots[position] == slot: return true
  false


func impliedArity*(selection: Selection): Arity =
  ## Read the arity a selection implies: one slot names a unary operation's own operand,
  ## two or more name a binary operation's `m` and `n`.
  ##   Two *or more* rather than exactly two: a picker offering `m` and `n` can still act
  ##   on the first two of a longer selection, and reverting to unary there would silently
  ##   drop the second operand the user picked. An empty selection implies nothing, and
  ##   reports unary only because `Arity` has no way to say "neither" -- callers check
  ##   `len` first.
  if selection.count >= 2: Arity.Two else: Arity.One


func isAllHidden*(selection: Selection; scene: Scene): bool =
  ## Report whether every picked object is hidden, so a control acting on the whole
  ## selection can name what it would do -- `show` where they are all hidden, `hide`
  ## otherwise.
  ##   A rule about a selection rather than about either object, which is why it lives
  ##   here instead of each front-end folding `isVisible` over the list its own way.
  ##   An empty selection is not hidden: there is nothing there to show.
  if selection.count == 0: return false
  for position in 0 ..< selection.count:
    if scene.isVisible(selection.slots[position]): return false
  true



#[ Editing A Selection ]#

func clear*(selection: var Selection) = selection.count = 0
  ## Drop every pick.


func selectOnly*(selection: var Selection; slot: int) =
  ## Replace the whole selection with one slot.
  selection.slots[0] = slot
  selection.count = 1


func toggle*(selection: var Selection; slot: int) =
  ## Add a slot to the end of the selection, or drop it where it is already picked.
  ##   Appending rather than inserting is what makes the order meaningful: pick two
  ##   objects and they become `m` and `n` in the order you picked them.
  for position in 0 ..< selection.count:
    if selection.slots[position] != slot: continue
    for shift in position ..< selection.count - 1:
      selection.slots[shift] = selection.slots[shift + 1]
    selection.count.dec
    return
  if selection.count >= ITEMS_MAX: return # Every slot already picked; nothing to add.
  selection.slots[selection.count] = slot
  selection.count.inc


func pruneDead*(selection: var Selection; scene: Scene) =
  ## Drop every picked slot the scene no longer holds, keeping the rest in pick order.
  ##   Call after removing an object: a freed slot is handed straight back to the next
  ##   add, so a stale pick would silently reattach itself to an unrelated new object.
  var kept = 0
  for position in 0 ..< selection.count:
    if not scene.isAlive(selection.slots[position]): continue
    selection.slots[kept] = selection.slots[position]
    kept.inc
  selection.count = kept


#[ Pulse Clock ]#

const SECONDS_STEP_PULSE_MAX* = 0.1
  ## Treat any gap longer than this as an absence rather than as a frame, for the pulse.
  ##   Six frames at sixty a second. Long enough that no honestly slow frame is clipped,
  ##   short enough that a tab returning from the background does not hand the comet a
  ##   whole minute of travel in one step.


type PulseClock* = object ## Carry each selected object's orientation pulse between frames.
  ## **A phase per slot, integrated, not a position computed from the clock.** Reading the
  ## phase straight off the time would mean `frac(now·speed ÷ around)`, and the outline's
  ## length changes whenever the camera moves: after a few laps that quotient is tens of
  ## laps, so a one-percent change in the length throws the answer most of a lap and the
  ## comet teleports. Measured on the build that did it -- 11.15 px a frame against the 1.0
  ## it should be, on all ninety sampled frames of an orbit. Carrying the phase instead
  ## leaves a camera change altering the *rate*, which is the only way a fixed screen speed
  ## and a smooth pulse are compatible at all.
  ##
  ## A plain fixed array, like `Scene` and `MeshSet` beside it, not an arena allocation:
  ## one float per slot with a compile-time bound and a lifetime as long as the program's
  ## is exactly what `arena.nim`'s own header says needs no arena. Nor is it double
  ## buffered, for the same reason it needs no allocator -- the update reads and writes one
  ## slot and consults no neighbour, so there is no read-while-writing hazard for a swap to
  ## resolve. `arena.nim` is desktop-only in any case, and this has to serve the browser.
  ##
  ## Kept here rather than in `marker.nim` because it is indexed by *slot* and the pulse
  ## runs on exactly the selected set, which is the view of the scene this module already
  ## is. A plain value type with no refs, like `Selection` above.
  phases: array[ITEMS_MAX, float] ## Each slot's own phase, in 0 .. 1.
  seconds_last: Option[float] ## Clock reading `tick` last saw, for the step between frames.


proc tick*(clock: var PulseClock; now: float) =
  ## Take the frame's own clock reading, so `advance` knows how long the step was.
  ##   Call once a frame, before advancing any slot. The first call establishes a reading
  ##   and advances nothing, since one reading is not yet a step.
  clock.seconds_last = some(now)


func secondsStep*(clock: PulseClock; now: float): float =
  ## Report how long has passed since the reading `tick` last took, in seconds.
  ##   Zero before the first tick and for a step that ran backwards, which a caller
  ##   restarting its clock can produce and which no pulse should answer by rewinding.
  ##   Capped at `SECONDS_STEP_PULSE_MAX`, because a gap longer than that is not a frame:
  ##   it is a backgrounded tab whose animation callbacks stopped, or a caller that moved
  ##   its clock. Carrying such a gap would advance the comet by the whole absence at once
  ##   and land it somewhere arbitrary -- the very teleport this clock exists to prevent,
  ##   arriving by the other door. Measured: a probe stepping the clock from 1.5 s to 400 s
  ##   moved the head 83 px in one frame before this cap, and 1 px after it.
  if clock.seconds_last.isNone: return 0.0
  min(SECONDS_STEP_PULSE_MAX, max(0.0, now - clock.seconds_last.get))


proc advance*(clock: var PulseClock; slot: int; around, seconds: float) =
  ## Carry one slot's pulse forward along an outline `around` pixels long.
  ##   `around` is what the marker just shaped actually measured (`Marker.around`), so the
  ##   rate follows the outline as the camera moves it while the phase never jumps.
  if slot < 0 or slot >= ITEMS_MAX: return
  clock.phases[slot] = phaseAdvanced(clock.phases[slot], around, seconds)


func phaseAt*(clock: PulseClock; slot: int): float =
  ## Read one slot's own pulse phase, in 0 .. 1.
  if slot < 0 or slot >= ITEMS_MAX: 0.0 else: clock.phases[slot]


proc forget*(clock: var PulseClock; slot: int) =
  ## Send a slot's pulse back to the start of its lap.
  ##   Call where a slot is handed to a fresh object, so a new selection begins its comet
  ##   at the head rather than inheriting wherever a since-removed object had got to.
  if slot < 0 or slot >= ITEMS_MAX: return
  clock.phases[slot] = 0.0
