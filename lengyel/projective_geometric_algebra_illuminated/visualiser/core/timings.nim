## Measure what each side of the algebra boundary cost this frame, and carry the few
## figures that cannot be measured inside one.
##
## **Why this exists.** The panel could say what each *stage* of a frame cost -- the
## scenery, the scene's objects, the flatten -- but not how much of any of it went on the
## geometric algebra rather than on turning the algebra's answers into triangles. That is
## the question this project exists to ask, and no arrangement of the old rows could
## answer it, because the two languages met in the middle of a statement. They no longer
## do: `tessellate` resolves every place through the algebra and emits afterwards (see
## `mesh.RibbonPiece`), so there is a seam with two sides to bracket.
##
## **What the two sides honestly mean.** `Placing` is working out where things are, and
## `Emitting` is turning those places into vertices. Emitting is pure by construction --
## it is reached through `mesh`, which imports `euclid` alone and so cannot name a
## multivector. Placing is dominated by the algebra but is **not** free of Euclidean
## arithmetic: a lattice line's across-vector is one cross product, and each piece's two
## fade colours are scalar work, both of which sit inside the assemble loop and are
## charged here. On a full grid that is roughly one cross per lattice line and two fades
## per piece against a `distanceBetween` -- a wedge and a norm -- for every one of those
## same pieces. The algebra dominates, and saying so is better than claiming a purity the
## loop does not have.
##
## **The clock is chosen at compile time**, not installed at run time: the two builds share
## no clock, and a proc variable would put an indirect call inside every bracket for a
## choice that is already made when the module is compiled.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

when defined(js):
  proc nowMilliseconds*(): float {.importjs: "performance.now()".}
    ## Read the page's own monotonic clock, in milliseconds.
else:
  import std/monotimes
  proc nowMilliseconds*(): float =
    ## Read the process's own monotonic clock, in milliseconds.
    float(getMonoTime().ticks) / 1_000_000.0



#[ Type Definitions ]#

type Side* {.pure.} = enum ## Name which side of the boundary a stretch of work sat on.
  Placing, ## Working out where geometry is: the algebra, and the little that rides along.
  Emitting ## Turning places into vertices: `mesh`, which cannot reach the algebra at all.


type FrameRecord* = object
  ## Hold what a frame measured that the *next* frame is the one to report.
  ##   Only for work that genuinely happens outside a frame's own build. On the browser
  ## hover picking runs from event handlers rather than the frame loop, so no bracket
  ## inside `nimBuildFrame` can ever see it; measured where it happens and read where it
  ## can be shown.
  ms_hover_pick*: float ## What picking under the cursor cost since the last frame.



#[ Frame State ]#

var SPENT_SIDE: array[Side, float]
  ## What each side has cost since `openFrameTimings`. Module state because that is what
  ## instrumentation is: threading an accumulator through every tessellation proc would
  ## put the measurement into signatures that exist to describe drawing.

var RECORDS_FRAME: array[2, FrameRecord]
var INDEX_RECORD_CURRENT = 0

proc openFrameTimings*() =
  ## Begin a frame: forget both sides' totals, and turn the record pair over.
  ##   The same two-frame lifetime the draw scratch has (`arena.ArenaSwap`), and turned
  ##   the same way -- the incoming record is cleared on the way *in*, so what the last
  ##   frame wrote stays readable right up to the moment this frame replaces it.
  for side in Side: SPENT_SIDE[side] = 0.0
  INDEX_RECORD_CURRENT = 1 - INDEX_RECORD_CURRENT
  RECORDS_FRAME[INDEX_RECORD_CURRENT] = FrameRecord()


var IS_TALLYING = true
  ## Whether anyone is reading the per-side and per-kind breakdowns right now.
  ##   **Instrumentation this fine has to be switchable, because it runs per object.**
  ## `timed` brackets the placing and emitting halves of *one object*, so a scene of five
  ## thousand points reads the clock ten thousand times a frame before `chargeTally` reads
  ## it once more each. Measured on the JS backend: fifteen thousand `performance.now()`
  ## calls cost **2.8 ms**, against a whole moving frame's build of 16 -- so a reader with
  ## the drawer shut was paying a sixth of the frame for numbers nothing displayed.
  ##   The *counts* are not gated: they are an increment each, and a row that says how many
  ## points were drawn should not depend on whether anyone was watching.
  ##   Defaults on, so a front-end that never says otherwise measures everything, which is
  ## what the desktop build and every suite case want.

proc setTallying*(is_wanted: bool) =
  ## Say whether the per-side and per-kind breakdowns are being read.
  ##   Call once a frame, before `openFrameTimings`; see `IS_TALLYING`.
  IS_TALLYING = is_wanted


proc isTallying*(): bool = IS_TALLYING
  ## Report whether the fine breakdowns are being gathered this frame.


template timed*(side: Side; body: untyped) =
  ## Charge whatever `body` does to one side of the boundary.
  ##   **Never nest two of these**: the inner stretch would be counted by both, and
  ##   nothing here can detect that. The call sites bracket disjoint halves of one proc,
  ##   which is the shape the seam was made to have.
  ##   The body runs either way; only the two clock reads are skipped. Written as one body
  ##   with a guarded pair rather than two branches, so there is exactly one copy of the
  ##   drawing code and no way for the measured and unmeasured paths to differ.
  let ms_entered_timed = (if IS_TALLYING: nowMilliseconds() else: 0.0)
  body
  if IS_TALLYING: SPENT_SIDE[side] += nowMilliseconds() - ms_entered_timed


proc spentOn*(side: Side): float = SPENT_SIDE[side]
  ## Report what one side has cost this frame, in milliseconds.


proc recordThisFrame*(): var FrameRecord = RECORDS_FRAME[INDEX_RECORD_CURRENT]
  ## Reach the record this frame is writing.

proc recordLastFrame*(): FrameRecord = RECORDS_FRAME[1 - INDEX_RECORD_CURRENT]
  ## Read what the previous frame measured, which is where anything happening between
  ## frames has to be reported from.
