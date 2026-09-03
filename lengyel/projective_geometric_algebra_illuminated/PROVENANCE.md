Provenance
===

_Who made this, from what, and how far it has been checked._

| Field  | Value |
|--------|-------|
| Agent  | Claude Code |
| Author | Claude Opus 5 and Claude Sonnet 5 |
| Date   | 2026-09-03 |
| Style  | `CONSTITUTION.md` and `STYLE.md`, supplied with the prompt; followed for all code. |
| Review | **Unreviewed.** Nothing here has been read line by line by a human. |

An interactive PGA (rigid metric) object visualiser, built as a testbed for the vendored
`pga` library: a desktop app (SDL3 + OpenGL + Dear ImGui) and a browser app (WebGL)
compiled from the same Nim geometry code, plus a scripted storyboard that exports PNG
frames and an animated GIF.

This file records the **current** design by subsystem and the reasoning behind decisions
that are not obvious from the code: what was chosen, what was rejected, and what the choice
costs. It is not a changelog. Where a rejected alternative is still a live trap it appears
as a terse "not X — Y" note; where a figure justified a constant it is kept beside that
constant, because the comments in the source no longer carry figures (Art. VII.5) and this
file is where they went.

**How claims are marked.** Each subsystem closes with a *Checked* block. *Verified* means
the claim was established by running something — a suite case, a driven check, a render
looked at, a byte read back — and names what. *Assumed* means the claim rests on reasoning
alone. A figure without a *Verified* line beside it is a figure once read off a panel and
not re-measured since; treat it as indicative.

**Verification practice, applies throughout.** Every change is rebuilt and the full suite
rerun (`tests/visualiser/suites.nim`, 296 cases, on the C backend at two capacities and on
the JS backend). The desktop is driven under `xvfb-run` with Mesa `llvmpipe` through SDL's
own event queue, and the storyboard PNGs and GIF are regenerated and looked at. The browser
page is rebuilt with `nim js`, assembled, and driven headless through Playwright
(SwiftShader) with real synthetic events — `page.mouse`, and CDP `Input.dispatchTouchEvent`
for touch, since untrusted `PointerEvent`s fail `setPointerCapture` and calling handlers
directly bypasses the listener wiring where real bugs have hidden. At the revision this file
describes, `tools/verify.sh` passed end to end with 302 driven checks reporting `ok`.
**No human has driven either GUI, clicked a button, or seen the app on real GPU hardware;
every figure and screenshot here is software-rendered**, except two device reports quoted
in Browser Pipeline, which are marked as such.


Render Paths
---
**The directory a module sits in is which render path may reach it.**

| Directory | Reachable from | Holds |
|-----------|----------------|-------|
| `visualiser/core` | Both | `objects`, `euclid`, `boundary`, `mesh`, `tessellate`, `camera`, |
|  |  | `scene`, `selection`, `picking`, `marker`, `framing`, `interaction`, |
|  |  | `storyboard`, `orrery`, `neighbourhood`, `starfield`, `history`, |
|  |  | `format`, `help`, `timings`, `ramp`, `algebra_trace`, `algebra_view` |
| `visualiser/desktop` | `visualiser.nim` | `panel`, `renderer`, `opengl`, `gui`, `gui_shim.cpp`, |
|  |  | `sdl3`, `image`, `gif`, `arena` |
| `visualiser/browser` | `browser_bridge.nim` | `browser_bridge.nim`, `shell.html`, `glue.js` |

`pga` is vendored above all three and shared. `core` imports nothing outside itself and
`pga`; `desktop` and `browser` each import `core` and never each other, readable from the
import paths (`../core/`). `arena` sits in `desktop` despite being general-purpose: only the
PNG and GIF encoders and the desktop draw loop reach it, and the JS backend cannot carve
typed slices from a byte array at all.

A shared module reaching for something only one path has is a **compile error, not a
comment**: `toCstring`, `buildChars`, `appendInt`, `appendFixed`, `saveScene`/`loadScene`
and their `std/os` and `std/syncio` imports are guarded `when not defined(js)`.

*Checked.* Verified: the guard is exercised rather than trusted, because the suite runs on
both backends (see Testing). Assumed: nothing.


Scene Storage
---
`Scene` (`scene.nim`) is a fixed-capacity structure-of-arrays arena — geometries, labels,
inks, visibility, liveness, birth stamps, creation ordinals, placing stamps, anchor
overrides — addressed by a slot assigned once on `addItem` and never moved. Free slots
thread onto an intrusive singly-linked free list, so add and remove are O(1).
`ITEMS_MAX` = 5040 and `LABEL_MAX` = 40, both `{.define.}`-overridable. Chosen over a
shift-on-delete array whose removal renumbers every held cross-frame index; the property
everything else relies on is that **a slot number stays valid until its item is removed**.

**`Scene.bound` is the highest slot ever occupied**, and every per-frame walk runs to it
rather than to capacity. It only rises, so walking to it is safe. Three walks legitimately
run to capacity — the free list and the two object-pool strips, whose subject is how much
room is left — and `bound`'s own doc names them. A walk to capacity over five live objects
cost 13.3 ms a frame on the JS backend; the debug layer's driven pin crept 2.5 → 8.8 →
13.3 ms across three capacity rises before that was found.

**`Scene.revision` counts edits, and every writer is inside `scene.nim`**: `addItem`,
`removeItem`, `setInk`, `setVisible`, `replayFrom`, `setGeometryAt`. There is no
`var`-returning geometry accessor — it was the hole through which a caller could write with
nothing recorded, and twenty-six of its twenty-nine callers were reading anyway. Whole-scene
replacement (undo, redo, clear, every load) goes through `restoreFrom`, which issues a
revision **newer than every revision ever handed out**, `max(live, snapshot) + 1`. Not the
snapshot's own count plus one — a number a state between the two had already worn, so a
placement cache keyed on it drew six objects of the previous demo over the new one.

**Placement is invalidated per slot.** `Scene.revisions_placing` stamps each slot at the
edit that last changed it, and `restoreFrom` stamps every live slot of the snapshot. The
browser's placement cache re-places only slots stamped after the revision it last filled at.
Re-placing the whole scene per edit cost a 42 ms frame at 5,038 objects; a restore still
re-places everything, correct and a whole placement pass per undo at that size. A per-slot
diff against the live scene would cut that and was not done.

**Creation order is recorded explicitly** (`orders`, `count_created`, `slotsCreated`), not
inferred. Slot order stops being creation order the moment anything is removed, since the
free list hands the most recently freed slot to the next arrival. Sorting by `born` was
rejected on three counts that all occur: two objects added in one frame share a clock
reading; a replayed item's `born` is stamped into the future; a reused slot's `born` is
stale until overwritten. `slotsCreated` is a heap sort, O(n log n); as an insertion sort at
5,038 objects it ran 12.7 million comparisons a call. The desktop panel caches its answer
against `scene.revision`, because sorting by `born` every frame was 98% of the desktop's CPU
frame at 5,038 objects.

**`LABEL_MAX` counts bytes, so a label is cut on a character boundary and says it was cut.**
`format.appendChars` copies a UTF-8 sequence only if all of it fits; `scene.toChars` rewinds
far enough to append `…`. A 3-byte operator glyph straddling the limit once left invalid
UTF-8, which the JS backend percent-escapes into a name (`%e2%8a`). Derived names still
compound (`b ^ ground⊖ ∧ b ∨ (o ∧ ground…`) and that is left: the full name is what the
object *is*.

`Item` is a handle, not an assembled copy, and under `nim js` it holds the `Scene` by value;
the per-frame loops use the by-slot accessors instead (see Browser Pipeline).

*Checked.* Verified by suite cases: slot stability across removal; `slotsCreated` on a
scrambled arena of hundreds; `revisionPlacingAt` stamping one slot per edit and every slot
after a restore; `restoreFrom` landing on a revision no earlier state carried; label
truncation never splitting a character at any buffer size. Verified by driven check: undo
while the frame is held redraws the current scene, not the previous one. The 13.3, 42 and
12.7-million figures were read while fixing and not re-measured since.


Memory And Allocation
---
The interactive render loop allocates nothing. `format.nim` wraps C `snprintf` so per-frame
number formatting writes into stack buffers. Button-driven message building still uses
`strformat`: once per click, and the result must become a `string` for `addItem` anyway.

`arena.nim`: a plain `array[N, byte]` carved by `push[T]` and reclaimed by `reset`. Three
instances in `visualiser.nim`:

| Arena | Capacity | Backs | Reset |
|---|---|---|---|
| permanent | `CAPACITY_ARENA_PERMANENT` 160 MiB | pixel readback, every GIF frame | never |
| frame | `CAPACITY_ARENA_FRAME` 64 MiB | one PNG's scanlines, one GIF frame's scratch | per unit |
| swap pair | `CAPACITY_ARENA_SWAP` 256 KiB × 2 | the draw loop's `DrawScratch` | per frame |

Permanent capacity is sized to the storyboard run's own `arena.used + bytes_needed`, not a
round number. The **swap pair** reclaims on the way *in*: what one frame assembled stays
readable through the next while the block being moved to starts empty. A separate pair
rather than a larger frame arena, because an export's scratch is tens of megabytes on a
keypress and a frame's is under 20 KiB (the ground grid's `LINES_GRID_MAX` chords, the
largest carver) sixty times a second. The storyboard's capture loop turns the pair over in
its own `renderAt`; without that, captured sub-frames stacked scratch until the fifth
overflowed.

**The undo timeline is the largest reservation the binary makes.** A `Scene` at 5040 slots
is 1.15 MiB as a C struct (1,204,616 bytes by `sizeof` on the release compiler), a `Step`
is a `Scene` beside a five-float `Camera`, and `CAPACITY_HISTORY` = 32 of them reserve
36.8 MiB (38,549,528 bytes) against 6.2 MiB for both mesh sets. In the browser the same
timeline is roughly 105 MB of JS heap; the live page measured 85 MB at load before the
per-slot placing stamps were added and has not been re-measured since. The depth is left at
32: an edit no longer costs anything per step (see Undo/Redo), so what remains is a flat
reservation, and the lever is linear — about 1.15 MiB of address space and 3.3 MB of JS heap
a step. `BYTES_MEMORY_TOTAL` counts it; a figure omitting its own largest term is worse than
none.

GIF's LZW dictionary is a fixed open-addressed hash table (`CAPACITY_DICT` 8192, Knuth
multiplicative hashing) rather than a third arena — random-access probing within a frame,
not bump-only append. **LZW early change**: the format widens the code size one symbol
earlier on decode than on encode; a from-scratch decoder in the suite round-trips a real
frame past the growth point.

*Checked.* Verified by suite cases: the swap pair keeps last frame's bytes; the GIF
round-trip. Verified by `sizeof`: the struct and timeline sizes. Assumed: the JS heap figure
per step, extrapolated from one measurement at the earlier stamp-less layout.


Colour Palette
---
Five assignable hues — `Rose, Copper, Olive, Jade, Cobalt` — plus `Backdrop`, `AxisX/Y/Z`,
`Grid`, `Guide`, `Outline`, `Algebra` and `Invalid` in one `Ink` enum
(`mesh.lut_ink_to_rgba`).

**`Invalid` is a reserved magenta**: seeing it means an object is wrong. The drag band wears
it over a pair that makes nothing (see Interaction Model); nothing else does. It is never
leaned on alone — magenta reads as *blue* under deuteranopia — and the ghost fails to appear
beside it. Reserving it cost three hues: `Violet` and `Cerise` measured CVD ΔE 10.2 and 8.3
from magenta, and `Cobalt`, 88° of hue away, measured **6.6** because blue and magenta
converge under deuteranopia. `Cobalt` was re-derived lighter and bluer (`#5b90c7`), which
reopens the pair to 14.4.

**Do not fill the remaining arc back up to eight.** A seven-hue set put `Olive` and a new
yellow-green at CVD ΔE 0.4 and two blues at normal-vision ΔE 5.6. The axis hues flank the
reserved arc on both sides, leaving one warm arc and one cool, 162° in total; five is what
fits.

**The structural slots are not offerable as an object's colour.** `mesh` names the boundary
once — `INK_CATEGORICAL_FIRST`, `COUNT_INK_CATEGORICAL`, `inkCategorical`,
`categoricalIndex` — and both pickers and `inkCycled` derive from it. Structural slots are
declared first and the categorical run last so it is one contiguous block; a
`static: doAssert` on the count enforces that, so appending a structural slot after `Cobalt`
fails the build.

Derived under floors `tools/check_palette` measures every run:

1. Every pair among the five clears normal-vision ΔE ≥ 15 and ≥ 20° of hue, so lightness can
   never stand in for a hue difference. `Jade`/`Copper` at CVD ΔE 7.6 sits inside the
   6–8 legal-with-secondary-encoding band; shape and screen position are that encoding.
   `Rose` sits at contrast 2.78 against the backdrop, under 3:1; its always-present row label
   is the relief.
2. Axis safety: each hue clears ≥ 20° and a lower ΔE floor (4.0) against `AxisX/Y/Z`, so a
   thin fixed line is never mistaken for a filled object. Loosened from the object floor on
   purpose — a thin line needs less separation than two adjacent fills — which is what freed
   most of the wheel; the sixteen-slot set that held everything to one floor crammed every
   hue into a teal/blue/violet arc and read as one colour.
3. Every assignable hue clears CVD ΔE ≥ 13 from `Invalid`: worst `Cobalt` 14.4, `Rose` 15.2.
4. Furniture against `Backdrop` ≥ 8.0: the axes land at 15.7–25.3.

**The one declared exception.** `Jade` and `Cobalt` separate by only **3.7 ΔE under
tritanopia**, carried rather than repainted: the pair clears 12.7 under red-green deficiency
and 15.8 to typical vision, tritanopia affects fewer than one reader in ten thousand, and
every object carries shape, position and label. It lives in `check_palette.nim`'s
`EXCEPTIONS` table with a floor of 3.5 pinned just under where it measures, and its reason
prints on every run.

`check_palette` measures under **Machado, Oliveira and Fernandes (2009) at severity 1.0**.
Viénot-1999 moves borderline pairs materially — it puts Jade/Cobalt at 0.9 ΔE where Machado
puts it at 12.7 — so the model is part of the standard, and changing it means remeasuring
every floor. Red-green (the minimum of protan and deutan) carries the floors; tritanopia is
measured separately.

**Axis colours are dimmed and desaturated at compile time** through `axisTinted` from
`MUTE_AXIS_TOWARD_GREY` = 0.45 and `SCALE_AXIS_LUMINANCE` = 0.50 — the constants are the
source, not documentation of hand-applied literals. Settled by the palette gate, not by
eye: 0.62 luminance read well and *failed*, dimming having walked the green and blue axes
onto `Rose`'s own luminance (3.5 and 3.3 ΔE under red-green against the 4.0 floor); further
down clears it, the axes landing below every categorical hue.

**`Ink.Algebra`** is the debug layer's one hue, screened against every assignable slot and
`Invalid` at the assignable floors (worst 8.2 against jade under tritanopia, 9.2 against
cobalt under red-green, floor 6.0).

`Ink.Outline` is retained although nothing draws with it: removing a categorical-adjacent
entry shifts every later ordinal and corrupts the colours of a saved `.rgascene`.

**Seed hues.** `ground` keeps `INK_SEED_GROUND`'s olive and `o` keeps `INK_SEED_ORIGIN`'s
copper — the two seeds that are not arbitrary — and `a`, `b`, `c` take the three that are
left, so nothing collides.

*Checked.* Verified: every floor above, by `check_palette` on each run, and the seven-hue
and sixteen-slot failures by the same tool when those sets were tried. Verified by
rendering: the axis dimming, and that 0.55 grid alpha read as absent (see Geometry). Assumed:
the prevalence figure for tritanopia, taken from the literature.


Geometry And Drawing
---
**Plane.** A solid rim (`RingRecord`) plus a flat translucent fill (`DiscRecord`,
`ALPHA_WASH` = 0.16) bounded by it; no crosshair, no grid, no normal shaft. Flat rather than
fading because the rim already marks the boundary. Fixed radius `EXTENT_PLANE` = 8 world
units about the plane's anchor — not camera-scaled, which visibly resizes a plane as the
camera orbits. The radius is a rendering choice: it appears in `mesh` and `picking` and
nowhere else, and every construction path reads the full `Multivector`, so a meet lands
correctly arbitrarily far outside the drawn disc.

**A meet is read back as the point it names before anything signed is asked of it.** A
meet's weight carries the orientation of the crossing and `unitize` divides by the weight's
*norm*, so that sign survives; `depthAgainst` is linear in its point, so a meet passed as it
came reports its depth **negated** on every plane met from behind its normal. `rayPlaneHit`
did that for one release: a plane joined from three of the opening scene's points picked at
0 of 462 sampled pixels while the ground plane, whose normal faces the eye, hid the fault.
Held by a suite case from both sides of one plane and by a driven check that sweeps the
canvas for a pixel picking a plane the gesture itself built.

**Line.** Two segments meeting on the line at its support, each running out to one of the
line's two vanishing points `eye ± radius_horizon*axis`. A vanishing point is a property of
the *eye*, which forces this shape: an end anchored a fixed reach from the support stops
short of the vanishing point by roughly eye-to-line separation over reach (≈6.7° for a
support 40 units out). Each segment lies in the plane through the eye containing the line,
so the pair draws exactly over the true line's projection — measured at 1e-16 of screen
skew — while the far ends sit 6–17 world units off the line along the view ray, so occlusion
is approximate there. `picking` tests both halves, through `clipToEyeSide`, a by-hand
near-plane clip mirroring the GPU's, since a screen-space test divides by depth and this
reach puts an endpoint behind the eye.

**Horizon objects** are drawn as sky: a horizon point is a fixed star at
`eye + radius_horizon*heading`, a horizon line a great circle about the eye, a horizon plane
a full-sphere dome (`DomeRecord`, `ALPHA_WASH_SKY` = 0.22). All anchor to the eye every
frame — zero parallax on translation. A full sphere, not a hemisphere: an orbit view sits
elevated and tilted down, so a dome cut at the horizontal loses sky the camera sees. Grade 4
is one-dimensional in this algebra, so every horizon plane is the same universal object.

**Draw-order invariant.** Translucent washes blend in scene order with depth writes off, so
whichever is appended last wins. Both `visualiser.assembleMeshes` and
`browser_bridge.nimBuildFrame` insert any visible horizon plane's dome **first** (via
`objects.isHorizonPlane`), so an ordinary plane's fill blends over the sky whatever slots
they occupy. Two ordinary washes crossing still look order-dependent; accepted.

**Muting.** `mesh.muted()` blends toward the colour's own luminance (`MUTE_DESATURATION`
0.6) rather than replacing it with `Ink.Grid`, which made a muted object indistinguishable
from the grid; `FRACTION_DIMMED_ALPHA` 0.55 so muted objects read as present context.

**Draw sizes** live in `mesh.nim`, not `renderer.nim`: `SIZE_POINT` 9.0, `WIDTH_LINE_OBJECT`
2.5, `WIDTH_LINE_FURNITURE` 1.5 px, with a `static: doAssert` that object lines exceed
furniture lines. `marker` derives every clearance from them and cannot import `renderer`.
A ribbon's width is measured in *framebuffer* pixels, so the bridge hands
`drawExtentFor` the framebuffer's height rather than the window's.

**Furniture** (ground grid, world axes) reaches `extent_furniture`, from the far clip
(`extentFurnitureFor`), and is drawn as **fog about the eye**, not a halo about the origin.
`fogFurnitureFor` solves two radii from `DrawExtent.eye`: full strength within
`FRACTION_GRID_FADE_START` = 0.06 × extent, gone by `FRACTION_GRID_FADE_END` = 0.20 ×
extent. Those are 1.14 and 3.8 orbit distances, so what the camera looks at sits inside the
solid core and the fog's edge is still a fifth of the far clip. Both came from rendering the
alternatives: at 0.03/0.12 the ground at the target read as absent, and a reach of 300
faded out at 36 units, inside the eye's own height above ground. Fog rather than a halo
because a halo makes the origin a place the reader may not leave — pan a hundred units away
and the ground was gone. The fade runs in the fragment shader against the fragment's own
world position and two fog-radius uniforms, exact along a record of any length, held to
`alphaGridFade` as its reference. A per-record `fog` flag (the sixteenth float) says who
fades, so fogged furniture and plain scene ribbons share one buffer in emission order.

`addGrid` lays lines on world multiples of the cell size inside the ground disc the fog
leaves — radius `sqrt(radius_gone² − height²)` about the point below the eye,
`mesh.radiusGroundFor` — one record per lattice line, with whole-line behind-eye cull at
placement (depth is linear along a straight segment, so two behind-eye endpoints put all of
it behind). The two lines through the origin are skipped, coinciding with the X/Y axes.

**The cell is `SIZE_CELL_GRID` = 10.0 at every reach a reader works at.** A cell that walks
with the reach re-scales the ground under a reader as they dolly; a fixed cell is a ruler.
Ten rather than a hundred, by rendering both: at the opening placement the reach is ≈72
units, so a hundred-unit cell put at most one line in view and the ground read as empty.
`CELLS_GRID_HALF_MAX` = 120 bounds the lines laid (`LINES_GRID_MAX` = 241 per family),
**spent on the cell, not on the reach**: `sizeCellGridFor` steps the cell by **decades** —
the smallest power of ten keeping the ground disc inside 120 cells — because decades nest,
so a step coarsens what is drawn without moving a line the reader was measuring against.
The first step is at 1,200 units of reach, orbit distance ≈316, by which point a ten-unit
cell is already the aliasing haze the fade end exists to cut. Cutting the *reach* at 120
cells instead left a camera past 1,200 units with the ground stopping short and past twice
that in a black void, axes included: grid vertices at orbit distance 300 / 1,000 / 5,000 /
10⁶ were 86,142 / 95,088 / 0 / 0 before and 86,142 / 28,392 / 13,818 / 28,392 after.

The grid is dimmed by `ALPHA_GRID` = 0.75 in `addGrid`, not on `Ink.Grid` (which is also
`INK_POOL_FREE`); 0.55 rendered a ground that read as absent.

**The world axes are reference and are drawn that way**: they fade and cut off on the grid's
own schedule, each drawn over the chord of the fog sphere it crosses, so all the furniture
ends at one horizon. Beyond the fog nothing marks the origin; accepted. Before this an axis
was the longest and brightest mark in any frame — no fade, 0.95 of the far clip at full
alpha — and readers took it for a drawn line.

**The scale bar**, bottom left, is what makes the ruled ground measurable: a span of ground
drawn at its true screen length with its distance written under it, and the cell size beside
that. Stepped 1-2-5 by decade (`STEPS_RULER`) to land near `PIXELS_RULER_TARGET` = 130 px,
as every map scale is; a bar tied to one cell ran 11,983 px at orbit distance 3 and 53 px at
120. Both numbers come from `nimGridMetrics`, which reads the same `sizeCellGridAt` that
`addGrid` lays the lattice with, and the bar is measured at the ground point below the eye,
where the reported cell is laid. In CSS pixels, since a bar is read in the pointer's pixels.
Hidden where no ground is drawn. **The drawer draws over it** (`z-index` 3 under the
drawer's 4) rather than displacing or hiding it: on a phone "aside" was off-screen, and a
bar a panel sits on can be read by closing the panel.

*Checked.* Verified by suite cases: a meet far outside the drawn disc; both halves of a line
pickable; the horizon plane's dome inserted first; the great circle's segment count after
the eye cut, computed rather than assumed; the fog radii at an eye inside its own fog.
Verified by driven checks: the plane pick from either side; the scale bar's length against
its label at two distances a decade apart; the bar unmoved and layered under the open
drawer. Verified by rendering: the fade fractions, the cell size, the grid alpha, the axis
dimming, an eye 1,000 units out standing on lit ground, and the far-orbit views before and
after the decade step. The 1e-16 skew and the 6.7° gap are suite-measured; the far-end
occlusion error is assumed to be tolerable, not measured.


Camera
---
`camera.nim` holds an orbit camera: target, distance, azimuth, elevation. `ELEVATION_LIMIT`
= π/2 − 0.02. The opening placement is `initCameraDefault`, read by both entry points and
by `home`.

**An orbit distance has a floor and no ceiling.** `DISTANCE_LIMIT_NEAR` = 0.05 is geometry:
at zero the eye coincides with its target and every direction `camera.frame` derives
collapses. `distanceHeld` is the one statement of it; construction, the dolly, both numeric
fields and `distanceFitting` pass through it. The 500-unit ceiling that stood beside it read
as the camera being bounded to a region — dolly out to look at something a kilometre across
and the view stopped. Nothing downstream needed it: the clip planes are fractions of the
distance and the grid bounds its own line count. What degrades far out is `Vertex`'s
float32 storage, past roughly 10⁶ units; wheeled out to 3 × 10¹⁹ the view empties to a
speck rather than breaking, and `home` returns.

**Clip planes follow orbit distance** — `FACTOR_CLIP_NEAR` 1/400 and `FACTOR_CLIP_FAR` 20
times it — derived, never stored. Not a stored pair set at construction — it kept its value
through every dolly, so dollying past the fixed far plane clipped the whole scene away. Both
scale together, so depth-buffer precision stays constant as the camera pulls back.

**The wheel zooms toward what the pointer is over** — the map reading of a zoom.
`picking.anchorZoomAt` solves the anchor in three answers, in order: the finite object under
the pointer, else the ground at `z = 0`, else the horizontal plane through the target; where
none answers (empty sky above the horizon) the wheel falls back to a centred dolly. The
object comes first because pointing at something means *that thing, at the depth it stands
at*: `positionOnItemUnder` reads a point at its place, a plane where the sight ray crosses
it, a line at the point nearest the ray. Horizon objects are refused — drawn at
`radius_horizon` about the eye, they are not *at* any place, and a horizon plane matches
every ray. The price is the jump: two notches taken either side of an object's edge converge
on different depths. `camera.dollyToward` then moves the eye along its own line to the
anchor, leaving the angles alone, and scales the target toward the anchor by the same factor
(`target' = anchor + s·(target − anchor)`), so the orbit centre settles onto what is being
zoomed into. The scale applied is read back from `distanceHeld`, so a zoom stopped by the
floor moves the eye by exactly what it was allowed.

**A pinch stays centred**, and the exception is deliberate: the two-finger gesture already
pans by its midpoint's travel, so aiming the zoom there translates the view twice for one
gesture; measured, the midpoint-aimed pinch dragged the view 11.4 units where the centred
one holds it.

**A drag pan grabs the level under the pointer and carries it.** `interaction.panAcross`
meets both ends of the pointer's step with the horizontal plane through the target and
translates by the difference. It replaces a rate of `FRACTION_PAN_PIXEL` = 0.0016 of the
distance per pixel, which carried the scene 288 px for a 200 px drag and, sliding within the
plane *facing the eye*, took the target from z 1.00 to 6.40 one way and −2.24 the other, so
every later orbit swung about a point in mid-air. Both hold points lie on one level, so the
height cannot move: 1.000 to 1.000 driven, mouse and two-finger alike, through one rule. The
rate survives only where a ray misses the level — a drag on sky. **The hold point is
bounded at `FACTOR_PAN_REACH_MAX` = 4 orbit distances**, because a level meets a ray aimed
near the horizon a very long way off; the *point* is clamped rather than the movement, so
the rule stays continuous as the cursor crosses the bound, and each hold point is taken to
its foot on the level (`projectOrthogonal`) so the clamp's tilt cannot leak into the step.
Four rather than two: at the opening placement a ray a fifth of the way down the window
already reaches 2.7 distances.

**Keys move by shared rates per second** — `TURN_SECOND` 1.4, `RISE_SECOND` 1.1,
`SLIDE_SECOND` 1.2, `FACTOR_DOLLY_SECOND` 4.0, `FACTOR_HASTE` 4.0 under shift — applied
each frame scaled by elapsed time, so a hold covers the same ground at 60 Hz and 144 Hz; the
dolly compounds as `pow(factor, seconds)`. Drag rates differ per front-end for a real
reason: `visualiser.SPEED_ORBIT` (0.008) is radians per pixel and `glue.js` works in
fractions of canvas width.

*Checked.* Verified by driven wheel events: an object under the pointer drifts 0.000 px
across a 3.2× zoom against 1.957 px with the target-level anchor, and wheeling back out
returns to distance 19.000 and target (0, 0, 1); eight notches over the ground carry the
target from z 1.00 to 0.32. Verified by driven drags: the pan figures above. Verified by
suite: `norm(eye − target)` equals the held distance after a floored dolly; the pan's height
invariance; the clamp's continuity. Verified by driven keys: 500 ms of `w` moved the target
12.8 units with z unchanged to four decimals, shift 49.3. Assumed: that no ceiling is wanted
by any reader, argued from the map reading rather than measured.


Records And Shaders
---
**Every line is a quad, never `GL_LINES`.** A line width is a hint most WebGL targets clamp
to one pixel, so `WIDTH_LINE_OBJECT` and `WIDTH_LINE_FURNITURE` meant nothing in the browser
until width became geometry. Each end is offset half a width along `directionAcross` —
the normal of the plane joining the segment with the eye — scaled by `worldPerPixelAt` at
*that end's own depth*, which is what keeps the on-screen width constant along a receding
line. **The near plane is clipped against first**: a depth clamped at the near plane breaks
the proportionality, and the first frame after the change drew a world axis twenty pixels
wide near the origin. An end behind the near plane moves up to it along the segment with its
tint blended by the same fraction; a segment entirely behind is dropped.

**The widening runs in the vertex shader on both targets.** One fifteen-float
`RibbonRecord` per segment (sixteen with the `fog` flag) crosses the wire against the
forty-two floats six CPU vertices cost, expanded by an instanced draw — GL 3.3 core on the
desktop, `ANGLE_instanced_arrays` on WebGL1. The across is derived per vertex as
`cross(head − tail, eye − tail)`, which for collinear pieces is the per-line hoist it
replaces. **Chain of custody**: the GLSL ships, `mesh.expandRibbon` is its reference in Nim
(sibling-marked with both shader sources), and the suite holds the reference to the
algebra — the near clip equal to `clipToEyeSide`, the across equal to the join
`directionNormal(tail ∧ head ∧ eye)`, sign included. The desktop captured the same frame
under the old CPU expansion and the instanced path: zero of 1,296,000 pixels differed.

**A plane's fill, its rim and the sky are one record each.** A 13-float `DiscRecord`
(centre, two radius-scaled arms, tint) fans over a static unit-circle corner buffer; an
8-float `DomeRecord` (centre, radius, tint) widens over a static unit sphere — a full sphere
has no orientation, so the record carries none; a 14-float `RingRecord` is a disc's thirteen
plus a width, one instance drawing the whole circle over `mesh.ringCorners`. The static
corner tables come from one generator each in `mesh` (`discCorners`, `domeCorners`,
`ringCorners`), read by the desktop directly and by the browser through `nim*Corners`, so
neither target holds a table that could drift from the references (`expandDiscVertex`,
`expandDomeVertex`, `expandRingVertex`), which the suite pins to the multivector sums they
replaced. `ribbonOfRing` derives the very `RibbonRecord` a rim segment would have been and
`expandRingVertex` is `expandRibbon` of it, so a rim is widened by the one rule every line
is. The rim steps off `UNIT_CIRCLE_RIM`, resolved at start-up with the runtime's own
`cos`/`sin` — not at compile time, whose evaluator need not agree with each backend's libm
in the last bit.

The rim was the last to move and it was 85% of the demo frame: `SEGMENTS_CIRCLE_HORIZON`
= 96 ribbon records per plane were 12,672 of 12,772 ribbon records (99.2% of ribbon traffic,
811 KB walked four times a frame) and 45 ms of a 53 ms frame on 132 planes. As a record the
demo's median frame went 239 → 84 ms under SwiftShader.

**Wash order is kept, not assumed away**: two translucent washes still blend in scene
order, so every append extends or opens a `WashRun` and both render paths walk the runs in
sequence rather than drawing one whole array after the other. `markOverlay` seals the current
run. `RingMesh` carries its own `index_overlay`, or a selected plane's second rim would draw
depth-tested behind the fill it highlights. Rims are drawn straight after object lines
rather than interleaved; the only difference is blend order where two translucent strokes
overlap during a plane's fade-in.

**Capacities** are asserted in `scene.nim`, the one module that can see both sides, so
raising `ITEMS_MAX` fails to *compile* rather than `doAssert` at draw time (a dead page):

| Cap | Value | Binding case |
|---|---|---|
| `VERTICES_MAX` | 10080 = 2 × `ITEMS_MAX` | every slot a point, every one selected |
| `DISCS_MAX`, `DOMES_MAX`, `RINGS_MAX` | 10081 = 2 × `ITEMS_MAX` + 1 | every slot a plane, |
|  |  | every one selected, plus a ghost |
| `RIBBONS_MAX` | 20161 = 4 × `ITEMS_MAX` + 1 | every slot a line, two segments, drawn twice |

The furniture set's own binding case is `LINES_GRID_MAX` lattice lines per family. The
desktop asks for a `SAMPLES_MULTISAMPLE` = 4 framebuffer and **falls back to none if no
visual offers it**: `llvmpipe` under `xvfb` refuses the window outright rather than
downgrading, and a visualiser that will not start is worse than one whose thinnest lines
alias. The browser context asks for `antialias: true`.

**The flat buffers are the page's own typed arrays, filled in place.** A `seq[float32]` on
the JS backend is an `Array` of boxed doubles, converted element by element into a staging
`Float32Array` — a fourth pass over bytes nothing else read. `FlatBuffer` is a `Float32Array`
behind three `importjs` lines, allocated once at its mesh's cap (about 1.4 MB in all) and
never grown; `flatten*Into` write into it unchanged and each frame hands back a `subarray`
view — one small object per buffer, seven a frame, no copy. `uploadBuffer` refuses anything
that is not a `Float32Array`. Measured at 0.1 ms a frame once the ring record had taken the
input from 204,352 floats to about 9,000; the win is the class, since the conversion scaled
with the scene.

Draw order in `glue.js` mirrors `renderer.nim` and is kept in step by hand: furniture
ribbons, then scene ribbons and points, then rings, then washes with `depthMask(false)`.

*Checked.* Verified by suite: the widening reference against the algebra; every stepped disc,
dome and ring corner against the sum it replaced; all ninety-six rim segments on the plane
at its radius; the capacity assertions, by building the binding scenes. Verified by desktop
A/B under Xvfb: 0 pixels for the ribbon move, at most 38 of 1,296,000 per storyboard frame
(channel delta ≤ 12) for the disc and dome move, where the record narrows its arms to
float32. Verified by driven check: the demo's ribbon records under 64 against a ring count
over 120. Assumed: that the 0.1 ms flat-buffer figure holds at the current caps; it was
measured at 1,024 objects.


Algebra Boundary And Debug Layer
---
The **algebra owns geometry** — what a thing is and where it stands: construction,
incidence, meets, joins, projections, nearest points, side tests; the world-space camera;
rays cast from the screen; the lattice lines and axes, which are lines; everything at the
horizon. The **picture owns representation** — how geometry becomes GPU primitives: a
plane's disc and rim, a ribbon's across-vector — built with whatever arithmetic is quickest.
A point has no picture to own: one vertex sized by a uniform.

**The boundary is enforced by the compiler.** `mesh.nim` imports `euclid.nim` and nothing
else, so `Multivector` is not a type it can name; `euclid` reaches `pga/algebra.nim` only;
`objects.nim` is the algebra's vocabulary and names no Euclidean type; `boundary.nim` is the
one module speaking both, so every lift and read-out is findable in one file; `tessellate`
is the geometry side of drawing and calls down into `mesh`.

**A PGA equation on the geometry side is never replaced with linear algebra.** The library
is what this project exists to exercise, so a cost it carries there is a finding, restructured
only in PGA's own terms (hoisting an invariant multivector, sharing one join across pieces
that provably share it). What may leave the algebra is the *picture*, and when it does the
algebra becomes the reference the shipped form is proved against: the across-vector cross
product is held equal to the triple join, every stepped disc point to the multivector sum.
The horizon shapes, the lattice lines and the axes stay in the algebra; the dense
16-coefficient `Multivector` copied by value through every operation (~1–2 µs an op on the
JS backend) stays, because changing its storage would change the thing being measured.

**The tessellation assembles before it emits.** Each loop resolves its places through the
algebra into a `DrawScratch` and emits afterwards; for the grid and axes the seam is between
two procs. `placeObject` answers what a drawable is and where — from the multivector alone,
so the answer holds while the camera moves — and `emitObject(placeObject(...))` is what
`addObject` is. Two steps stay on the placing side inside `emitObject` (a horizon marker's
stand-off, a line's two vanishing points) because the cut the panel reports is by kind of
work, not by proc. `tessellate` takes its scratch as a parameter: the desktop hands it swap
arena memory, the browser a fixed buffer.

**The debug layer** (`algebra_trace`, `algebra_view`) records every multivector a frame
computed and draws each as what it is, the way an engine draws its physics world over the
art: a finite plane as a fog-faded lattice over the whole plane (`radiusOnPlaneFor`,
`addGridFamily`, generalised from the ground), plus geometry the scene does not contain —
the sight axis, the eye and near planes, the cursor's ray and where it meets the level. Both
render paths call one `addFrameTrace`. **What it does not reach**: the per-candidate meets
`rayPlaneHit` forms inside `pickNearest` — threading a collector back out would make the
pure `pickNearest` a proc, and re-deriving the meets would show what the drawer computed
rather than what the pick did. The ray the pick casts *is* drawn. Off by default, with its
own diagnostics row beside the scene's. The trace is caller-owned scratch of `TRACED_MAX` =
`ITEMS_MAX` + 16 entries: as a stack local it built ten thousand `Traced` objects a frame
before recording five, 13.3 ms against 4.1 after. Its control reads **debug**, not
"algebra" — a control named algebra read as the subject of the app.

*Checked.* Verified by suite: every moved form pinned to its algebraic reference. Verified by
driven check: the layer draws more than the picture, and its cost band. Assumed: the µs per
op figure, from one profile at 1,024 objects.


Selection And Markers
---
`selection.nim`, shared: an ordered fixed-capacity list of slots, a plain value type.
**Order is the whole point** — an operation reads its operands positionally, so the first
slot picked is `𝐦` and the second `𝐧`. `impliedArity` lives here too. `Selection.revision`
counts real changes (a clear of an empty selection is not one), so the frame record and the
desktop panel compare one integer instead of a 5,040-slot array every frame. Selection is
**not** part of `Scene`: never saved, never on the timeline, cleared outright by a
successful undo or redo, and `pruneDead` runs after a removal because a freed slot goes
straight back to the next add.

**A selected object is drawn over every other object.** One watermark per mesh
(`index_overlay`, an `Option[int]` — an index of zero legitimately means "all of it", so a
mesh nobody marked has to say *none*), set once per frame by `markOverlay`, then a second
pass over **every** primitive kind with the depth test off. A second pass rather than a
tail on each kind: the tail left a selected line tinted by a later wash. A watermark rather
than a third `MeshSet`, because a set reserves every cap up front for a run that is usually
one object. On the desktop marks draw on Dear ImGui's **background** list, beneath the
panels, exactly as the object is; the drag menu alone stays on the foreground list, since it
is a control being steered.

"Just built" and "currently selected" are one mechanism: one marker per selected slot,
plain white, and every construction path replaces the selection with the slot it created.
Hover draws the identical marker at `ALPHA_MARKER_HOVER` 0.6 against `ALPHA_MARKER_SELECTED`
0.9; keyboard focus wears it too. Only a caller passing a time gets a pulse, so motion means
selected.

`marker.nim` shapes the outline to what it marks:

| Shape | Marker | How it fills |
|-------|--------|--------------|
| Point | Circle in screen space about the drawn point. | Sweeps clockwise from twelve. |
| Line | Two rails flanking its projection, one each side. | Runs out from its support. |
| Plane | A circle lying *on the plane*, outside its rim. | Opens from the disc's centre. |
| Line at horizon | Two bands on the sky it circles. | Closes in from a quarter turn. |
| Plane at horizon | The viewport's edge, inset by the gap. | Expands as a circle from the middle. |
| Point at horizon | Circle about the fixed star it draws as. | Sweeps. |

All keep `GAP_MARKER` = 6.0 px between the object's drawn edge and the marker, measured out
from the drawn size: `RADIUS_MARKER_POINT` = `SIZE_POINT`/2 + gap = 10.5 px,
`OFFSET_MARKER_RAIL` = `WIDTH_LINE_OBJECT`/2 + gap = 7.25 px. `WIDTH_MARKER` 1.5 px, asserted
thinner than the line it marks — 2 px of pure white at an 11.5 px gap read as a second
object. Markers are stroked by each render path's foreground layer (`gui.overlayPolyline`,
SVG), never as scene geometry: a loop on a plane would z-fight its fill, and a marker the
object can occlude is not a marker. A 3D-modelling-style outline (oversized silhouette,
depth-write off, its own shader and mesh set) was built and deleted; do not reintroduce it
without being asked.

**A plane's loop lies on the plane**, traced from the plane's frame about the same anchor
`addPlane` centres its disc on, so it is concentric with the drawn disc; its clearance is a
world distance sized through `worldPerPixelAt` at the disc's own depth, so the gap reads as
6 px where a reader judges it and foreshortens with the disc elsewhere. `worldPerPixel`
measures depth along the sight axis, not distance from the eye — the two differ by over a
percent even near the middle of the frame. The loop steps `euclid.unitRing`'s fixed table
through `onCircleAt` with the arms taken through the algebra once, as the bands do.

**A line's rails are two straight world-parallel lines, sized by the widest gap they will
show.** Each runs from an offset at the support to the two vanishing points all three share.
Along the half whose far point lies behind the eye, `clipToEyeSide` cuts it back to the near
plane where depth *falls*, so a world offset flares rather than converging. On the demo's
`a ∧ b`, gap from support to drawn end:

| camera (azimuth, elevation, distance) | one half | the other |
|---|---|---|
| 0.6, 0.2, 19 | 14.8 → 12.9 px | 14.8 → 16.5 px |
| 1.6, 0.9, 19 | 14.7 → **23.7 px** | 14.7 → 7.9 px |
| 0.2, 0.05, 12 | 15.3 → 11.3 px | 15.3 → 20.9 px |
| 2.4, 0.4, 30 | 14.5 → **45.6 px** | 14.5 → 0 px |

So `OFFSET_MARKER_RAIL` means **the widest the pair may read anywhere**: `markerRails` lays
the rails out, measures one rail against the other at every drawn end (`apartWidest`), and
narrows the world offset until the widest reading meets the ceiling; it only ever narrows.
After: 14.5 px at the widest and no flare on any half, 14.2 to 14.5 over a 45-camera sweep.
Three details, each of which cost a round: **settle, do not solve** (`PASSES_MARKER_RAIL` = 4;
one pass lands about five percent over, 15.2 against 14.5, because narrowing moves where
each rail leaves the viewport); **settle against the finished rail, then draw at the
progress asked for**, or the gap widens as a touch hold fills; **measure one rail against
the other, not either against the line between them** — all three meet at one vanishing
point, so a perpendicular from one lands further along the other. Two live traps: a ceiling
on the gap *at the support* caps where the flare is not, and its table swept camera
*distance* at one orientation, the one axis the flare does not lie along — **a marker's
worst case can lie along orientation, and sweeping distance is not sweeping**; a constant
*screen* offset bent every rail at its support (2.66°, 7.3 px of stray at azimuth 2.4). A
floor under the narrowing at four tenths let a 437 px splay through and was unfounded: a
ceiling on the widest reading is itself the guarantee of visibility. Driven over a 720-step
orbit, the largest change in the gap between neighbouring frames is 0.103 px.

**A rail's growth is measured against the edge of the view** (`fractionLeavingView`), not
its own length: the two vanishing points sit at wildly unequal screen distances (1,140,706 px
against 3,634 on the demo's `L = a ^ b`, a ratio of 314), so a fraction of each rail's length
finished one half 314 times sooner and put both off a 900 px screen within the first
percent. Bounded at the viewport, quarter progress reads 142 px against 100. Rails are
shortened **after projecting**, along the screen segment: scaling the world reach walks the
head toward the eye and spends almost the whole range within pixels of the vanishing point.

**The horizon plane's frame is an expanding circle that becomes the screen edge**: at each
angle the radius is `progress × half-diagonal` or the distance to the inset edge, whichever
is smaller, so it is a circle for as long as one fits and then becomes the edge piece by
piece, midpoints first and corners last. `SEGMENTS_MARKER_FRAME` = 64 even steps (a multiple
of four, so the midpoints are sampled exactly) plus `CORNERS_MARKER_FRAME` = 4 corner
directions merged in by angle, since a corner missed by a fraction of a step is a corner cut
off. Scaling a rectangle instead read as a shrunken copy of the screen. **A horizon line's
bands are cut to the viewport, not just to the eye**: uncut, a ring lapped 396,102 px
against the 1,490 on screen and a comet at a fixed screen pace was visible four frames in a
thousand. `markerBands` keeps the longest stretch inside the window, `fractionLeavingView`
placing each end at the edge; the lap is 832 px against a finite line's rails' 870 at the
suite's placement. Costs: a horizon line wholly off screen yields no marker; only the
longest stretch of each ring is kept; the anchor falls back to the arc's start when angle
zero is off screen, which for a horizon line is most of the time.

**On touch every marker swells clear of the finger** (`CLEARANCE_MARKER_TOUCH` = 54.5 px,
added not multiplied, taking a point's 10.5 px ring to a 130-pixel circle, about twice a
thumb's contact patch). Zero for a mouse. It was 24 px, sized against a 44 px minimum touch
target by a measurement that compared framebuffer pixels against a CSS-pixel target; see
Browser UI on the two pixel spaces. **The swell runs on its own clock in four phases**
(`interaction.swellHold`): grows over `SECONDS_SWELL_GROW` 0.12 s, sits at full through the
fill, **stays there for as long as the finger is down past maturity**, and settles over
`SECONDS_SWELL_SHRINK` 0.15 s once it lifts. A half sine over the fill put the marker back at
true size at the very moment the selection landed. `progressHold` starts *after* the grow,
so a press is 0.62 s end to end. The swollen marker is drawn even once its slot is selected
and the plain marker for that slot skipped, or the outline snaps at the moment the selection
lands; the browser retires the hold only once `isHoldSpent` says the settle is over, stated
against `swellHold` rather than the shrink duration a second time — subtracting two large
timestamps measured 0.14999999999997 against 0.15. `cancelHold` snaps away without settling:
that press stopped being one. On a Pixel 5 in CSS pixels: 10.5 → 58.2 → 65.0 through the
grow with the fill at 0, flat 65.0 across the fill and at 2 s and 10 s past maturity, then
64.9 → 17.3 → 10.5 through the settle.

**Orientation is a pulse travelling round the selection marker**, and the normal shaft is
gone (it marked every plane in the scene permanently to answer a question a reader asks
about one object at a time). `markerFor` runs a lit run of `SEGMENTS_MARKER_PULSE` = 16
points spanning `LENGTH_MARKER_COMET` = 64 px of the outline, tapering from
`WIDTH_MARKER_COMET` 3.5 px at its head down `FALLOFF_MARKER_COMET` 1.2 to `WIDTH_MARKER` at
its tail, so it merges into the line behind it and only the head is an edge; the constants
came from thirteen variants drawn side by side against 2.8 and 4.5 px heads and 1.6 and 2.4
falloffs. Fixed pixels, not a share of the outline, walked by arc length: a fraction
measured 96 px along a rail against 334 px round a plane's circle. `FRACTION_MARKER_PULSE`
0.35 survives as a cap for a marker smaller than the run. **Which way it travels is the
orientation**: nothing computes the sense, the projection decides a loop's order (+74,393
from above `ground`, −82,167 from below, as swept angle), a rail is walked as one path from
far horizon through the support to near, a band takes the great circle's normal. Two shapes
get none: a point, and a plane at horizon, whose `frame`, `direction` and `directionNormal`
all report nothing and are unchanged by negation. One comet to a line, not one per drawn
half: the two rails take the phase measured on the first and stay within one comet's length.

**The travel is a distance in pixels from a view-independent anchor.** `PulseClock.travels`
advances by `SPEED_MARKER_PULSE` = 60 px/s × seconds with no camera quantity in the advance,
reduced into the current lap every frame (an unbounded travel read as `travelled mod lap`
amplifies a one-percent lap change by the laps accumulated). `PulseTrack` names the anchor
— a line's support, a ring's angle zero — and `originAfterCut` walks angle zero through an
eye cut. A speed rather than a lap time: one lap per 4.8 s ran 156 px/s along a rail against
348 round a circle; sixty is what the lap was chosen at over 300 px specimens. A gap longer
than `SECONDS_STEP_PULSE_MAX` = 0.1 s is an absence, not a frame (83 px in one frame before
the cap, 1 px after). The advance belongs to "this slot was drawn this frame": a bridge that
returned before advancing when a rails marker at phase 0 produced no run left lines with no
comet for a whole round while planes pulsed. The two exports share one shaped marker
(`g_shaped_marker`, boxed behind a `ref` — held by value the memo's own store and read
deep-copied the variant twice and measured as slow as the shaping it replaced). The desktop
fill needs a **fixed winding** (`gui_shim.guiOverlayRibbon` imposes it): Dear ImGui's fill
offsets each edge outward for one winding and inward for the other, and a ribbon handed the
wrong way came out with its whole fringe under the fill (a column stepped 16 to 248 with
nothing between).

**A drag band swells into its head** (`marker.cometFor`) — the same length, width and
`ribbonAlong` as the pulse, so one vocabulary for direction — because `a ∨ b` and `b ∨ a`
are different operations. Fixed pixels: driven at 61, 125, 200 and 277 px of drag the head
held its size. None where the cursor rests on its own source.

*Checked.* Verified by suite cases: the loop's points on the plane (1.1e-15 on the
antiscalar against 1.0 for a control point one unit off); the rails' straightness over an
orientation sweep and their widest reading on both sides; a growing rail starting where the
finished one does; the frame's 68 points at 296.8 px flat at half progress; the head sitting
exactly its carried travel from its anchor at 45 placements, within a pixel; a rails marker
at phase 0 reporting a positive lap; a matured hold taken once (a 1.62 s hold had selected
its item and lost it within 50 ms of lift). Verified on the shipped browser: the comet's
advance from its anchor at 62.4, 61.7, 62.5 and 63.3 px/s across four orbit rates; 178.3,
179.0 and 179.6 px over three seconds at 36, 60 and 144 fps against 180; the residual at the
two faster rates — a tenth of frames stepping 236–388 px/s, laps and clip transitions, not
drift — is **not explained** to the standard the medians are, and a theory that the shared
rail window shortened the lap was measured to change nothing. Verified on the desktop: the
selected line's pure-ink pixels 2,626 with the second pass against 1,106 with the tail;
marker pixels inside the panel's rectangle 3,453 → 3,059 on the background list. Verified by
driven check: two crossing planes selected change 15,668 canvas pixels against a 0-pixel
noise floor. Assumed: the "twice a thumb's contact patch" sizing, from a rule of thumb.


Picking
---
`picking.pickNearest`, shared: **point beats line beats plane, strictly**, regardless of
pixel distance once a shape's own radius is met. That priority is what makes generous radii
safe. `RADIUS_PICK_POINT` = 34, `RADIUS_PICK_LINE` = 24 CSS px, sized against a fingertip at
phone density; a plane's test is area-based. **Everything drawn is pickable, horizon
included**, ranked point, finite line, horizon line (tested against the great circle it
draws as, stepped off the same table), finite plane, horizon plane (matches every ray, so
last). A horizon point was silently unpickable while the extent was built fieldwise with its
multivector twins zero; the extent goes through `algebraFilled`, the one derivation point.

**The sky is a click and hold target, never a drag handle.** With a horizon plane visible
the cursor is over *something* almost everywhere, and a press on empty space becomes an
orbit precisely because nothing was hovered. `beginDrag` refuses the sky and `destinationOf`
refuses it; `interaction.is_hover_backdrop` carries the answer from `updateHover`. Clicking
empty space then selects the sky rather than clearing; a tap still treats it as empty space,
since tapping empty space is a finger's only way to dismiss a selection, and touch reaches
the sky by long-press. The selection menu follows the middle of the view for it.

**The pick runs once per frame, not per input event.** A pick walks every live slot, linear
in the scene (11.4 ms p50 over 1,024 objects, 0.2 over five, before the fixes below). Pointer
motion marks hover stale and the frame loop picks once after `nimDriveHeld`; the wheel sums
its notches and the loop applies one dolly, the same zoom since `exp(k·Σdelta)` is the
product of the notches (six notches a frame had cost 83.8 ms of picking). Three paths pick
inside their handler because they must answer before it returns: `pointerdown`, a touch-down
and `handleTap`.

**The pick ranks what was drawn.** It takes the frame's placements and dispatches on
`Placed.kind` rather than asking `position`, `direction`, `frame` and `spanPerpendicular`
again per slot; empty means derive per slot, the desktop path and every suite case. A finite
plane the algebra can span no frame for shares `PlaneEverywhere` with the sky and is not
pickable; a direction point is picked at the horizon, where the eye puts it. **The pick
rejects a plane before meeting it**: `isBeyondDisc` bounds the disc's screen extent by the
silhouette of the sphere containing it, conservative in the depth and off-axis terms — 20,000
random configurations with the centre up to three view-widths off screen and 300 surface
samples each found no silhouette point outside the bound. `geometryOf` hands back a `lent`
view, and the walk reads it inline — `lent` removes the copy only where the result is never
bound. `projectToScreen` is written out as three dot products in local floats (the 4×4
multiply with two typed arrays allocated per call was 43% of a 15.4 ms pick over 10,000
slots), and the point branch reads `pixelsFromCursor` rather than building a
`ScreenPosition` per slot.

**Slot-liveness guards.** Hovered, dragged, focused and selected slots are plain values
carried across frames, so any can name a removed item the frame after a delete: `nimAnchorScreen`
reports nothing for a dead slot; `endDrag` on both paths checks `isAlive` on source and
destination; removing an item clears the highlight on both paths.

*Checked.* Verified by suite: both boundaries of each radius and all three priority pairings;
a horizon point picked at a pixel where the line alone was first asserted picked; the disc
bound sampled from inside the view. Verified by slot-for-slot map: 4,914 cursor positions
across three cameras over the 1,024-object demo answered identically before and after the
placement and copy changes. Verified by driven checks on both builds: dragging bare sky
turns the view and builds nothing, clicking it selects it. Measured then, not since: one pick
11.4 → 3.9 ms p50 at 1,024; 15.4 → 4.7 ms at 10,000; a hover pick 0.7 / 1.6 / 3.5 ms at 60 /
360 / 5038.


Interaction Model
---
**Which button does what, stated once.** `interaction.revealsMenuOn` says whether a click
brings the floating selection menu (right yes, left and middle no); `armingOf` says whether
a drag opens the choice wheel. Both render paths and `help.nim` read them.

| Gesture | Does |
|---|---|
| left click | select just that one, dropping the rest |
| right click | the same, and open the menu |
| shift with either | add it, or drop it again if already picked |
| right click, selection standing, menu down | reveal the menu, selection untouched |

**A click has no time limit**: `isClick` is distance alone, `PIXELS_CLICK_SLOP` = 6 px
(not `PIXELS_TAP_SLOP`'s 12 — a mouse does not roll, and a finger's allowance would swallow
the short deliberate drags between two overlapping objects). A 0.35 s deadline once lost
every click held 600 ms. The stillness reading is latched and false until a press raises it.
A right press that never moved is a click too: the wheel only opens over a target *other*
than the source, so such a press never asked for one.

**The press target chooses the scheme; the button chooses whether you are asked.** Press an
object and you are constructing; press empty space and you are moving the camera (left
orbits, right pans, wheel zooms). Left takes the algebra's own answer on release; right opens
the four-way wheel. **A mouse never waits**: `MenuArming` is `Never` (left), `Always`
(right), `OnDwell` (no button — it belongs to touch, which has no second button and would
otherwise lose `meet`, `project` and `more…`). `SECONDS_DWELL_MENU` = 0.75 measures only a
finger, which pauses far more readily than a mouse, and sits above `SECONDS_LONG_PRESS`
= 0.50 so the two thresholds a stationary finger races are in the right order; timed through
CDP touch on a Pixel 5 profile at 0.93 s from the last movement to the wheel, the extra
0.18 s being the 50 ms poll and SwiftShader's frame latency. The dwell measures stillness:
`updateDrag` restarts it whenever the cursor moves further than `PIXELS_TAP_SLOP` from where
it last settled, since measuring presence opened the menu under a finger moving continuously
for 1.2 s. **Middle is unbound**: it once held `project`, behind hardware most trackpads
lack.

**A press that can construct never moves the camera, not even before its slop is crossed.**
A finger easing into its drag spent its first frames under the slop, fell through to the
orbit, latched the camera-dragging flag that suppresses hover, and then ran blind. `glue.js`
decides at the press, in `is_touch_press_constructing`, the same question `beginDrag`
answers when the slop is crossed, refusal over the sky included.

**The gesture clock is seconds**, on whichever monotonic clock the caller owns, and the
same reading `addItem` stamps a birth with. `glue.js` divides once in its own `now()`. The
desktop's dwell once needed 450 *seconds* because the durations were named in milliseconds.

**What a drag builds is read off the operands, not the button.** `∧` adds grades and is
drawable when the sum ≤ 4; `∨` adds antigrades and is drawable when the sum ≥ 4. Over every
ordered pair of point, line and plane in general position (points off the moment curve
`(t, t², t³)`, where "no three collinear and no four coplanar" is a Vandermonde theorem):

| first → second | join `∧` | meet `∨` | project | plain release takes |
|---|---|---|---|---|
| point → point | line | — | point | join |
| point → line | plane | — | point | join |
| point → plane | — | — | point | project |
| line → point | plane | — | — | join |
| line → line | — | — | line | project |
| line → plane | — | point | line | meet |
| plane → point | — | — | — | **nothing** |
| plane → line | — | point | — | meet |
| plane → plane | — | line | plane | meet |

**At most one of join and meet is ever drawable**, so `proposalFor` is a priority order
(Join → Meet → Project) with no tie. `plane → point` offers nothing and a release refuses
rather than inventing; the table is asymmetric, so drag direction carries meaning. A first
measurement crossed a point lying *on* its paired line and read zeros from the fixture,
which is why `GENERAL_FIRST`/`GENERAL_SECOND` are separate from the random operand sets.

**The drag shows its answer before committing it**: `Interaction.preview` holds what a
release right now would build, drawn as a ghost in `INK_GHOST` (= `Ink.Guide`) through the
same `addObject` an edit session's ghost uses, at `preview_anchor` from the same
`creationAnchor` call the commit makes (or a ghosted plane jumps to its anchor the instant
the release lands). It answers for the wedge being aimed at: `updateDrag` resolves through
`choosing()` where a wheel is open and `proposalFor` where none is, and `choosing` is the
one statement of which wedge the cursor is in, read by the preview, the release and both
highlights. **Three things a release can do, so three tints** (`ReleaseEffect`: `Nothing`,
`Refused`, `Builds`) — neutral `Ink.Guide`, `Ink.Invalid` magenta, the scene's next hue.
`Scene.index_ink` carries how far the cycle has walked (`inkNext`/`takeInk`/`skipInk`), and
**every released construction steps it**, built or not, so a colour the reader watched for
a whole drag is not offered again; a click does not step it, nor `More`; undo restores it;
loading sets it to the item count.

**Everything that meets an object on screen meets it where it is drawn.** `mesh.anchorFor`
reads the stored anchor as `addPlane` and `markerFor` do; the band's start, its comet's aim
and the selection menu's follow all go through it. The support stood 0.5, 2.7 and 3.7 units
from the drawn centre on the demo's planes — 13.7 px for `ground` at the home camera.
`pickNearest` still meets the ray against the support's disc; that divergence is left.

**The choice wheel.** Four wedges at fixed compass points — join north, meet east, project
south, `more…` west — unoffered ones greyed (`ALPHA_MENU_UNOFFERED` 0.45) rather than
packed out, because a menu whose items move is one nobody learns. A wedge is the selection
menu's own button, moved: same surface, hairline, `ROUNDING_MENU_WEDGE` 8 px radius, 12-px
semibold face and `--accent` border on the one in force; the browser takes those from the
same CSS variables, the desktop copies the tones into `drawChoiceMenu` with the siblings
named. **A wedge says what the picker says**: `labelOf` returns `notationSymbolic` (`𝐦 ∧ 𝐧`,
`𝐦 ∨ 𝐧`, `𝐧 ∨ (𝐦 ∧ 𝐧☆)`) and `More` a bare `…`; the words survive in the drawer's legend
only. Symbols made the wheel **15 px narrower** on a 320 px phone (194.7 against 209.8),
because `more…` → `…` takes 31 px off the east–west axis that sets the width, while the
projection's 92 px sits at south, clear of anything. A release commits whatever is under the
cursor, resolved by `endDrag` through `choiceAt` so the two paths cannot disagree; the
centre (`PIXELS_MENU_DEADZONE` 26 px) commits nothing, which is why an unasked dwell wheel is
safe to open. The wheel **latches its destination** when it opens. **An open wheel lets go
when the cursor leaves it** past `PIXELS_MENU_DISENGAGE` = 150 px, sited off
`PIXELS_MENU_CORNER_FURTHEST` = 103.9 px (the furthest wedge corner, read off the drawn rects
over six pairs) leaving 46 px of clear air; travelling on to another object re-aims, never
chains, and a target just let go of is held at arm's length until hover leaves it. This
bounds the overshoot `choiceAt` once left unbounded; re-aiming was chosen, with the user.
**A wheel the reader summoned may veto the release; one that invited itself may not**: a
dwell wheel opens under a finger pausing to aim, and pausing before lifting is the common
touch release, so an *unentered* dwell wheel's centre release falls through to
`proposalFor`; `is_menu_entered` is set the first time the cursor stands in any wedge.
Flick-marks are impossible on this path — a construction drag has spent its direction
reaching the target — so the accelerator is the right button.

`more…` builds nothing and opens **the selection menu's own apply picker** over both
operands in drag order (`panel.openSelectionMenuPicker`, `glue.openApplyPickerOnOperands`),
already showing the operation last applied at that arity. Not the drawer's apply section:
answering a wheel under the cursor by throwing the hand to a side panel buried the two
objects just named. A degenerate construction is **refused**, the message naming what was
degenerate, and a construction on a full scene is refused the same way (the drag commits in
shared code with no panel between it and `addItem`'s assertion; one click on the demo
reached it).

**Touch.** A finger that presses an object constructs; one that presses empty space moves
the camera. Two fingers pinch and pan and cancel any construction. A long press selects; once
a selection exists a tap (`TAP_MAX_MS` 350, in JS because a tap timeout is local) toggles
another in or out; a tap on empty space clears. `pointercancel` cancels. `nimClearHover` runs
once the last finger lifts, or the last reading sits stale forever. Accepted cost: a finger
starting on the ground plane's disc constructs rather than orbiting — the same trade the
mouse makes. `g_selection` (Nim) is the sole source of truth; `glue.js` keeps only a render
snapshot refreshed when the selection changes.

**A picker offers symbols alone** (`notationSymbolic`), not the whole catalogue entry, and
**opens on what was last applied at its own arity** (`OperationMemory`, attitude for one
operand, wedge for two; per arity because the two lists are disjoint). **Every apply control
ghosts its answer while the reader is still choosing**: `scene.Preview` is the one statement
of a construction not yet committed (geometry, anchor, operand slots), built by
`previewApplying`, and the drag's own preview is the same type by the same call. Where a
session and a preview both stand, **the session wins** (`staged`, once per front-end). The
preview is **framed together with the operands it names** (`Preview.operands`,
`framing.watched`); an open edit session names none, since its staged geometry replaces the
object selected beside it.

**Selection menu** (both builds, one row, following its anchor every frame): `apply`
leftmost and never moving, opening a picker to its right via a `max-width` transition
(`width: auto` cannot animate); `edit` shown for exactly one selected, opening the drawer's
objects section onto a session; `hide`, `delete` on every selected slot; `✕` clears. `apply`
is hidden for 3+ selected, since this menu has no operand pickers. **Shown by the gestures
that pick and hidden by the ones that build**, not derived from the selection being
non-empty — every construction leaves its result selected and a menu over each new object
would sit in the way of the next drag. Placed `OFFSET_MENU_SELECTION` = 46 px **above** its
object: a Dear ImGui window makes `wantsMouse()` true wherever it sits, so a menu straddling
its object would swallow the next drag off it. Its screen position is kept between frames so
an object passing behind the camera leaves it where it was. The document-level tap-outside
listener excludes the canvas, the drawer and the chip row, and fires on `pointerdown`,
before the tap resolves.

*Checked.* Verified by suite: every cell of the drag table and the at-most-one property,
exhaustively; the click rule; the dwell restarting on movement and surviving a drift under
the slop; the ghost's anchor equal to the created item's; the ink cycle stepping on release
and not on click. Verified by driven checks: the tint table at each wedge stop
(`nimDragTint` reading neutral `(0.286, 0.322, 0.400)`, magenta `(0.612, 0, 0.722)`, the
next hue); shift-clicks held 600 ms selecting; the sub-slop touch drag hovering 2 with the
azimuth unmoved; `more…` landing on `𝐦 ∧ 𝐧` with both operands selected on both builds; a
construction drag off the very object the selection menu follows (`--drive-select`); the
full-scene refusal. Verified by reading computed styles: the wedge's fill, stroke, radius,
font and label identical to the menu button's. Assumed: that 0.75 s is the right dwell for
any hand; it was set by one profile.


Undo/Redo
---
`history.nim`, shared. Scoped to scene-content edits: add, apply (drag and touch flow
included), remove, visibility, ink, and an edit session's `save`, which is the "edit
committed" moment the continuous widgets lacked. One fixed array plus one cursor, not two
stacks: an entry is a `Step {scene, camera}`, both plain value types, so recording is a copy
and `entries[cursor].scene` is exactly the live scene. `CAPACITY_HISTORY` = 32.

**The array is a ring.** `first` names the slot holding the oldest step, `slotOf` is the one
place a timeline position becomes an index, and retiring the oldest entry moves one integer.
Shifting every later entry down was 31 whole scene copies per edit past the thirty-second —
153.5 ms to toggle one object's visibility on the JS backend, scaling with the *capacity*
(26.4 ms at four deep, 39.9 at eight); as a ring one edit costs 11.3 ms and does not move
with the depth (10.7 at four, 11.7 at eight). What remains per edit is the one `Scene` copy
into the timeline, 1.15 MiB through `nimCopy` on the JS backend; not per frame. `initHistory`
fills a timeline the caller owns: returned by value it compiled to a `nimCopy` of thirty-two
whole scenes, 65% of the largest demo's load. `record` writes a `Step`'s fields rather than
assigning a literal, for the same reason.

**The camera rides along; an orbit is never a step of its own.** Each step records where the
view stood when *that step's* edit was made; undo reads it off the entry stepped away from,
redo off the entry arrived at. Restoring the camera of the state arrived at hands back
whatever view the *previous* edit was made from, so undoing the first construction of a
session teleported to the startup view. Not recording an orbit is the accepted cost of not
needing a gesture-settle rule, and **an accidental orbit is still not undoable on its own**.
Both front-ends abandon their camera tween on a successful step, or the standing aim drags
the view straight back off the placement just restored.

Seeded wherever the scene is (re)initialised, so undo never reaches past the moment
tracking began. A successful step clears the selection and any ghost. Bound to Ctrl/Cmd+Z,
Ctrl/Cmd+Shift+Z and Ctrl+Y on both builds, through one function per build rather than the
button — routing through `button_undo.click()` depended on a `disabled` attribute refreshed
on the low-cadence tick.

*Checked.* Verified by suite: recording to capacity and past it, walking every retained step
forward and back and comparing each state (`scenesEqual`, since `Multivector`'s `==` is an
intentional compile error); camera restoration across two edits from two viewpoints.
Verified end to end: `--drive-undo` and the browser drive both build, orbit away, undo, and
hold the view where the construction was made. The 153.5 / 11.3 ms figures were measured on
the JS backend at 5,038 slots and not since.


Storyboard And Seeds
---
`storyboard.constructSeeds` builds five seeds: `a`, `b`, `c` (raised 2 units in z), `o`
(the origin), `ground` (a plane joined from three points at z = 0). `o` must stay off
`ground` — one step projects it onto that plane. `STEPS` is eleven derived steps; both entry
points compute the seed count from `scene.len`. One step (`a ^ ground`) is a grade-4 volume
and correctly reports "mixed grade, nothing to draw" — its documented purpose.

Both apps open on the seeds alone. `runStoryboard` distinguishes "reached" from "focal";
reached-but-not-focal draws muted rather than hidden. Horizon steps aim the capture via
`azimuthElevationFor(heading)`, a closed-form inverse of the orbit camera's forward
direction. `constructSeeds` deliberately does not stagger arrivals (`runStoryboard` sweeps
each step's animation on a clock of its own); the startup paths call `replayFrom` after it.
The GIF is `FRAMES_GIF_GROW` 6 + `FRAMES_GIF_HOLD` 4 frames a step at `STRIDE_GIF` 2
downsampling, `CENTISECONDS_GIF_DELAY` 8.

*Checked.* Verified by regenerating: the storyboard is byte-identical across changes that
should not touch it (the replay, the help-table measurement). Nothing assumed.


Creation-Anchored Plane Centring
---
A plane's rim and fill centre on `scene.creationAnchor(operation, m, n, derived)` rather
than on its closest-to-origin support, which reads wrong for a plane built from operands
that do not straddle the origin. `Wedge` of a line and a point centres at the midpoint
between the point and its projection onto the line; `ExpandWeight` of a point and a line
where the line meets the plane; the three-point ground seed on the centroid; everything else
falls back to the support. Computed at construction and stored (`anchor_overrides`, a
rendering hint excluded from save/load), since many operand sets produce an identical plane
`Multivector`. All anchor arithmetic is RGA-native — summing unit-weight points and reading
`position`, which divides by weight.

*Checked.* Verified by suite: each special case's anchor. Assumed: that no other operation
wants one; none has been asked for.


Save/Load Format (`.rgascene`)
---
Compact binary matching `Scene`'s layout, **little-endian throughout** — a free choice that
had to be *a* choice, because `glue.js` reaches it through `DataView`, and little-endian
because every file already written contained it. The desktop converts through
`std/endians`.

| Bytes | Field |
|-------|-------|
| 4 | Magic `RGAS` |
| 1 | Format version (`VERSION_SCENE` = 3) |
| 1 | Basis count (16 under this build); must match |
| 4 | Item count, little-endian `uint32` |
| per item | Ink (1), visibility (1), label length in bytes (1) + UTF-8, then one |
|  | little-endian `float` per basis term |

`MAGIC_SCENE` and `VERSION_SCENE` are exported and reach `glue.js` through
`nimSceneMagic`/`nimSceneVersion`, so there is no literal to drift; labels go through
`TextEncoder`/`TextDecoder`. Three defects of the same shape — a value derived in Nim and
copied by hand into JavaScript — once left the two builds unable to open each other's files
while the round-trip suite stayed green, because it only ever asked one build to read what
it wrote.

Only live items are written, **in creation order** (`nimSceneSlotsCreated` on the browser
side; `nimSceneSlots` keeps slot order for the combo boxes indexed by position). That order
is the whole of what version 3 added. Omitted on purpose: slot numbers, a per-item ordinal,
fixed-width label padding.

**A loaded scene replays its construction.** `born` is not written, but
`scene.bornReplaying(index, count, now)` stamps the `index`-th of `count` arrivals a beat
after the last, and `animationProgress` reads a `born` the clock has not reached as zero.
`SECONDS_REPLAY_STEP` = 0.12 is shorter than the 350 ms appear animation, so an object is
still growing as the next lands; `SECONDS_REPLAY_WHOLE` = 2.5 caps the whole arrival by
shortening the beat, or a full scene would take minutes. Every arrival a reader did not
build replays — a file, the demo, the opening scene — through one rule in both loaders and
`replayFrom` for callers that assemble first.

**Every version ever written is still readable.** `VERSION_SCENE_LEAST` = 1 and should stay
1: reading an old version costs a mapping func and a suite case, refusing one costs somebody
their scene. Reading is written once against `VERSION_SCENE`; each past version's difference
lives in one `upgradedFrom<n>`, and `itemUpgraded` walks an `ItemSaved` up the chain one
step at a time. Version 2 costs nothing but the sequence guarantee (`upgradedFrom2` is an
explicit no-op kept so the question has an answer); version 1 costs colours only — its
ordinals name a palette that no longer exists, folded by the same cycle `inkCycled` walks,
bounded by `ORDINAL_INK_HIGH_V1` = 14 so a byte version 1 could never have written is
refused. The browser's own version-1-stamped version-2 files read one hue along; **a wrong
hue is recoverable, a refused scene is not**. `loadScene` parses into a staging scene and
replaces the caller's only on complete success; native-only.

*Checked.* Verified by cross-reading, not round-tripping: the sixteen-object demo saved,
reloaded and compared item for item in creation order — label, ink, visibility and all
sixteen coefficients, 304 scalar comparisons exactly equal; the desktop re-saving the
browser-written file byte-identical, all 2245 bytes; hand-built version-1 and version-2
files read the same by both parsers (version 1's ordinals 4/7/11/13 as
`Grid`/`Rose`/`Cobalt`/`Copper`); a file one version ahead refused by both; ordinal 15 in a
version-1 file refused. Verified by watching: seeds arriving over 0.480 s and the demo's
sixteen over 1.84 s in the browser; the desktop's frames 2/8/16/24/45 building the scene.
Verified by suite: the on-disk bytes of a known float. Assumed: the big-endian host path,
never exercised (see Known Limitations).


Browser Pipeline
---
`browser_bridge.nim` compiles the shared modules through `nim js`. `glue.js` is presentation
only — WebGL upload and draw, DOM, pointer wiring, `DataView`, `Blob`. **Every value derived
from domain data sits in Nim behind an `{.exportc.}`.** Audits have repeatedly found drift
here — a grade computed by counting digits in a basis name, a button mapping reimplemented,
five render constants hand-copied — each replaced by an export (`nimBasisGrade`,
`nimDragKindForButton`, `nimRenderLineWidths`, `nimOverlayMetrics`, `nimMenuMetrics`). The
one thing measured on the JS side is the wheel's wedge label widths, which only the browser's
own font layout knows. Where a desktop-only module holds the authoritative value the bridge
duplicates it in **Nim** with a comment naming the original; a fix to one copy is not
finished until the sibling is checked.

**The page is compiled `-d:release`; the JS suite is not.** The flag lives in
`build_browser.sh`, since `verify.sh`'s own JS build must keep its checks and stack traces.
One `nimBuildFrame` on the opening scene: 36.7 ms debug, 21.9 ms released; `-d:danger`
measured 18.4 and was rejected — a further tenth of a frame is not worth removing every
bounds, range and field check from the one build a reader runs.

**JS-backend rules, each found by reading the generated JavaScript**, since a return looks
like a read and none shows up in an allocation grep:

- An `Item` holds its `Scene` **by value**; the per-frame loops use the by-slot readers
  (`geometryOf`, `labelAt`, `inkAt`, `bornAt`, `isVisible`). The `pairs` walk measured
  ~150 ms a frame at 64 items.
- A `var bool` accessor over an `array[N, bool]` miscompiles when consumed as a value; the
  pair is `isVisible`/`setVisible`, plain.
- `MeshSet`s live at module scope and are cleared, never re-declared: re-declaring measured
  ~90 ms a frame regardless of item count.
- **Binding a value type copies it.** `let placed = g_placed[slot]` deep-copies; the slot is
  indexed where used and `emitObject` takes `var Placed` because nothing writes it. Every
  flatten and vertex walk aliases with `template r: untyped = records[i]`. `Ink.colour`
  returns `lent` (returned by value it was 8% of a moving frame at 5,038 objects); a
  marker's fade is passed as an alpha rather than through `fade`.
- **Assigning a literal copies it.** `addMarker` writing seven `Vertex` fields instead of a
  literal took `nimCopy` from 41% of a moving frame's profile to nothing; the points row went
  9.1 → 7.1 ms.
- `slot in 0 ..< ITEMS_MAX` allocates a slice object per call; `isAlive` is two comparisons.
- A returned tuple, an `Option[Marker]`, a `seq` per frame — each a deep copy. The overlay
  view cache is `ensureViewOverlay` over shared globals; `markerFor` fills a caller-supplied
  `var Marker` and reports a bool; the shaped marker is boxed behind a `ref`.
- `lent` removes the copy only where the result is never bound (see Picking).
- A default argument does not survive into the generated signature: a JS caller that omits
  it passes `undefined`, falsy. `nimBuildFrame`'s flag is spelled `is_tally_skipped` so that
  omitting it measures everything.

**The furniture is built once and held while the camera is still** (`SettingsFurniture`).
It is a function of the camera alone. The bridge sends empty furniture records on a held
frame and `glue.js` keeps the buffer it uploaded. The grid and axes were 15 ms of a 21.9 ms
opening-scene build; held, the median fell 34.4 → 5.8 ms over 48 of 48 idle frames.

**A still frame rebuilds nothing.** `SettingsScene` carries the furniture tuple, the
aspect, `scene.revision`, `Selection.revision` and the debug flag; where it matches the last
frame's, the bridge skips the tessellation, **the flattens and the uploads together** (held
separately they buy nothing). Three states refuse the hold: a ghost or drag preview follows
the pointer; the debug layer draws the cursor's ray; an item still inside its appear
animation is drawn differently every frame — read off `g_born_last`, a watermark carried by
`stampBorn`, rather than by scanning every stamp. Refusing costs one rebuilt frame; holding
wrongly freezes the picture. Under the demo, still camera: the bridge's build 18.2 → 0.6 ms.

**Placement is cached per slot across camera moves.** `g_placed` holds `placeObject`'s
answer per slot, refreshed for slots stamped since the last fill (see Scene Storage).
Orbiting the 1,024-object demo the scene phase went 17.1 → 2.6 ms; placing was 12.0 of the
17.1.

**The per-object tally is gated on its reader.** `timed` brackets both halves of one object,
so a 5,038-object scene made about fifteen thousand `performance.now()` calls a frame — 2.8 ms
on their own (0.27 µs a call). `setTallying` is on only while the drawer *and* its
diagnostics section are open: 14.5 ms watched, 9.2 unwatched on a moving frame. Counts are
not gated. **Points are not missing an optimisation the other kinds have**: a point is one
vertex (two when selected) in one mesh, already the minimum the wire can carry; what points
carry is the per-object cost, and they are 4,938 of the 5,038 objects.

**Loading the largest size** was 1,496 ms of frozen page, almost none of it the
arrangement: the timeline copy above (bridge 706 → 95 ms); the objects list built for a
section nobody had open (gated on the section *and* the drawer); the operand pickers
rebuilding an `<option>` per object per picker and spending 5,038 FFI calls just to decide
whether to (keyed on `scene.revision` and gated on the apply section, 119 ms); the row sort
crossing the FFI 124,000 times (`nimSceneSlotsCreated` is that order already). The rows that
remain are built **in slices bounded by time** (`MILLISECONDS_ROWS_SLICE` = 5), drained from
the frame loop rather than a `requestAnimationFrame` of their own, because `recordPhaseTime`
overwrites a phase's reading and work beside the loop is either unmeasured or clobbers it.
Five thousand rows are 820 ms in one block. Now 101 ms, 95 of it the arrangement.

**The objects list reconciles rather than rebuilds**, keyed so a row survives — the shape of
the two-frame record pair, one side of the FFI over. A diff rather than a list of "the cheap
callers", which a thirteenth caller breaks in silence. Only the open row builds its edit
form: every row once carried the whole form hidden by CSS, 76 elements a row and 80,325 on
the 1,024-object page, so a tap on `hide` froze the page for 736 ms. The geometry line
(`nimFormatMultivector`, 11.8 ms across 1,024 rows) is held against `scene.revision`. Tap
736 → 19 ms; an unchanged refresh 570 → 3.7 ms. A visibility toggle still pays about 24 ms
because `setVisible` bumps the revision; a geometry-only counter would remove it and is not
worth the contract.

**The diagnostics tick writes only what moved**, and returns immediately unless the drawer
and its section are open. It ran five times a second regardless — 2.8 ms typical, 5.7 worst,
landing on one frame in twelve against a still frame of about a millisecond, the largest
source of variance left — and both canvases fell back to a made-up 300-pixel width when
unlaid-out, so a canvas inside a closed drawer was drawn at a size it did not have. A tick
costs the frame *after* it, where no row can name the cost: the browser's style, layout and
paint over what was written land in `display wait + browser`. Measured on the demo, still,
drawer and diagnostics open, as the next frame's penalty: +5.2 to +6.3 ms as built (12,741
elements), +2.6 with the objects section collapsed, **+2.4** with `content-visibility: auto`
on each row — over half the cost was the browser and over half of *that* was the objects
rows the tick never writes. **`content-visibility` buys what virtualising would, and its trap
is the box model**: `contain-intrinsic-size` sizes the content box (42 px of a 61 px row); with
`auto` in front the browser remembers each row's real height once laid out. The open row is
exempt, since `scrollIntoView({block: 'nearest'})` against a 42 px placeholder left its
489 px form below the fold; the scroll settles over `PASSES_SCROLL_SETTLE` = 4 frames for the
rows above it that are still estimates. `drawPoolGrid` reads `clientWidth` *before* any write
(a read after the writes forced 0.9 ms of layout in a 1.3 ms tick), gated on revision, ratio
and a `ResizeObserver` flag. Figures are redrawn on the cadence of the window they average:
the exceedance curve and the medians moved to a one-second pass, the 200 ms rows stay.

**What this container cannot see.** Every frame-time figure here is SwiftShader's: on the
demo `renderFrame` takes 0.9 ms and the same call followed by a `readPixels` takes 88.9 ms,
a CPU rasteriser blending 132 translucent discs. Two device reports (an Android tablet, a
real GPU) are the only hardware figures in this file: the demo at a median of 14.50 ms —
plain vsync — with severe periodic spikes, and `ui refresh` the largest row at 3.80 ms.
Measured directly, at the demo's opening camera 98 of 132 discs are entirely off-screen and
the 34 visible cover 0.12 of one screen: fill rate is not the problem on a GPU, and reading
SwiftShader's as a property of the design is the mistake. **Culling was measured and not
done**: overdraw 0.12 screens, the display-wait median vsync, and a cull trades an
object-vanishes bug for a fraction of a millisecond. The remaining device complaint is the
*tail* — 1 frame in 100 at 25 ms against a 16.63 ms body — and under SwiftShader a profile is
98% `(program)`, the rasteriser itself, so no claim is made about it; the hypothesis that the
diagnostics' own once-a-second redraw authors it was tested and killed (0.5 ms). Two things
were ruled out on this container for the periodic spike: the page has no timer of its own,
and the drawer's `backdrop-filter` blur makes no difference (44 spikes against 40 over 30 s).

**Not done, and known.** The frame walk still sweeps `scene.bound` twice (sky planes first,
then everything else); every edit copies a whole `Scene` into the timeline; a restore
re-places every slot. None is per frame. Caching the whole frame, scene included, needs a
"nothing changed" test that is far easier to get subtly wrong than the two holds above.

`nimFormatMultivector` calls the library's own `$`, pure Nim and byte-identical across
backends; `format.nim`'s `snprintf` path stays desktop-only.

*Checked.* Verified by driven checks: the furniture hold over idle frames; the scene hold
through the drawn pixels — the canvas hashed from inside the frame that drew it, across
eight edit paths (hide, show, recolour, move a coefficient, select, remove, undo, redo), each
asserting frames were rebuilt *and* the canvas changed; the per-kind accounting summing to
the scene phase, run twice (opening scene and demo, the demo orbiting since a still window
has nothing to divide) at a 99.5% quantile, guard-run by doubling every part (0 of 857 and 0
of 67 frames account); a placement held across a camera move drawing what a fresh one draws;
element identity across an unchanged refresh and a hide; the tick's write count; the pool
grid covering the capacity with every cell at least a device pixel wide; the rows count
against `nimSceneCount()` after the fill. Verified by profile: the copies named above.
Assumed: every millisecond figure is this container's, and the CPU-side wins carry over to
hardware while the fill-rate cost does not.


Diagnostics
---
**The frame-time breakdown accounts for the whole frame.** Rows are `build + hover + upload
+ overlay + ui` (`PHASES_TOP_DIAGNOSTIC`) plus a leftover row (`display wait + browser`)
computed inside `recordFrameTime`, the one moment a frame's duration and its own phases
occupy the same ring slot. `build` sums from its rows (the prologue and the view matrix are
rows), `hover picking` is a row because on the browser it runs from event handlers and no
bracket inside the build can see it, and the **`of which` pair** — `placing` against
`emitting`, the algebra boundary's own cut — is a second cut through the same milliseconds
drawn as a rule and a label rather than a nested node. `emitting` is pure by construction
(reached only through `mesh`, which cannot name a `Multivector`); `placing` carries a cross
product per lattice line, which `timings.nim` says rather than claiming a purity the loops
do not have. `ms_build` is stamped after the `FrameData` record is built, so the overlay
scans are inside the total. Each counted row carries its count beside its **name** so every
value ends in `ms` in one column. Orbiting at distance 300: placing 20.8 ms against emitting
6.3 — three-quarters of the drawing work is the algebra, which is the number the panel
existed to produce.

**Each row is tinted by its share of the frame, along CET-I1** (`isoluminant_cgo_70_c39`,
Kovesi, arXiv:1509.03700, from colorcet's Python table; the `.csv` paths 404). Isoluminant
because the rows are text and lightness is already spoken for. **The map supplies hue and
chroma; the drawer supplies lightness**: each sample is carried into OKLab, its lightness
replaced by the tone that row wore untinted (`--ink-muted` for a label, lifted
`LIFT_VALUE_RAMP` toward `--ink` for the number), and chroma scaled down by bisection until
the colour fits sRGB — never clamped per channel, which bends the hue. **The ramp ships as a
table**: `ramp.nim` holds `STEPS_RAMP_TREE` = 17 label/value pairs, and `tools/check_ramp`
is both generator (`--emit`) and checker, rebuilding the table from the published map and
the lightness tokens parsed out of `shell.html`. Its floors: reproduces the re-lit map within
0.001 of a display step; interpolation never leaves the 256-entry map by more than 0.09
(`SEPARATION_INTERPOLATED_MAX` 1.5), which is what makes 17 enough; the ends stay 26.4 apart
(`SEPARATION_ENDS_MIN` 25.0). **The denominator is the whole frame**
(`SHARE_RAMP_FULL_DIAGNOSTIC` = 1.0), idle included, so 12% of a 6 ms frame and 12% of a
30 ms frame read the same and the curve above says which session this is; `idle` stays
untinted, being the leftover. **Walked by ratio on a symlog**: `SHARE_RAMP_KNEE_DIAGNOSTIC`
= 0.01 is the knee below which the scale is linear (a logarithm has no zero), and each of the
three regions — under a hundredth, a hundredth to a tenth, a tenth to all — is a third of
the ramp. A symlog proper, not `log1p`, whose decades come out unequal (0.37 against 0.48 of
the ramp). Laid out linearly, a 28.8 ms frame's costliest row at 12.7% and floor at 0.3% sat
one step apart; by ratio the same frame covers nine of seventeen steps. The key is the ramp
drawn as a gradient, sampled across share so it crowds left as the rows do.

**Readings are averaged over 200 ms and rewritten on the same 200 ms**
(`MILLISECONDS_WINDOW_READING`), counted in the frames' own durations, with the ring's median
beside them; six frames was a twelfth of a second on a desktop and a third on a phone. Mean
and deviation hide stutter that percentiles catch — 99% of frames at 2 ms and 1% at 40
reports a fine mean — so the tail past p95 is what answers "does this stutter". **A phase's
absence is recorded beside its time, never inside it**: presence is a parallel `Uint8Array`,
a non-positive reading is clamped to zero (a clock artefact on a phone's coarsened
`performance.now`), a non-finite one left absent so a wiring break still shows an em dash.
This is the no-sentinel rule in the one place the value's range could not spare a member;
the hazard was constructed by a driven check, not observed in a session. A branch reveals its
own rows with `>` selectors, not descendants — descendant rules laid the whole tree bare on
one click while the inner nodes reported closed and never wrote their rows.

**The exceedance curve**: for each duration, the share of the last `FRAMES_EXCEEDANCE` =
1024 frames (about seventeen seconds at 60 fps — long enough to hold a stall, short enough
for it to age out) that came in *under* it. A ring and a histogram (`MILLISECONDS_BUCKET`
0.5) maintained together; the bucket count is folded from the slowest mark
(`RATE_BUDGET_SLOWEST` = 1 fps) plus one, because adding a 1 fps mark to the budget list
alone did nothing, silently, against a histogram that stopped at 128 ms. A sample past the
last bucket lands *in* it. It climbs between its own two ends, linear by default and log over
`DECADES_EXCEEDANCE` = 3 decades of the share still over on a pill in the caption row (a pill
that **keeps a resting border**, since the header chips read as controls only inside their
`.toggles` track; shipped once without and reported missing). Every rule is labelled in both
modes. **The axis follows the window, floored a little past the 30 fps mark**:
`SHARE_MARK_LEAST` = 0.86 is the share of the axis the slowest guaranteed mark stands at, so
the floor is ≈38.8 ms — a share because the canvas is responsive, and at exactly 33.3 ms the
30 fps line landed half a pixel outside the canvas. The whole window is drawn, both extremes
included (a trim off each end was tried and was the wrong tool). **The axis waits, then
glides**: a difference standing `MILLISECONDS_AXIS_WAIT` = 400 ms moves it, eased on a
`MILLISECONDS_AXIS_EASE` = 420 ms constant against elapsed time, stopping inside a
`SHARE_AXIS_DEADBAND` = 2%; while travelling, the curve redraws on the frame loop. Marks at
120/60/30/15/10/5/1 fps, each named twice (rate above, duration below), the 15, 10, 5 and 1
carrying the poor band's token since the list is both the marks and the bands. The four band
colours are a **status** ramp screened against the drawer's surface: jade rather than pure
green (green against amber is ΔE 1.2 under protanopia, jade 7.9), worst adjacent
normal-vision ΔE 16.3. The sparkline beneath holds `FRAMES_HISTORY` = 240 frames.

**The desktop panel** holds a raw per-frame line graph (not smoothed — smoothing hides the
rare slow frame this exists for), a fill bar for the permanent arena, a `peak_used` bar for
the frame arena (instantaneous usage reads empty, since carve and reset happen within one
frame), the pool grid, and `BYTES_MEMORY_TOTAL`. The arena snapshot is taken in the shared
render function, or it reads zero in every storyboard PNG. `--timings` reports mean, p50,
p95, p99 and max over `FRAMES_TIMING_MAX` = 20,000 frames.

*Checked.* Verified by driven checks: every frame's duration reconstructed from its rows
(worst error 0.0000 ms); `build` equal to its rows within the clock's resolution, guard-run
by dropping a row that carries time; a costlier row never wearing an earlier colour, recovered
from the *rendered* colour; the far end reached at the whole frame; the three ramp regions a
third each to 1e-9; the marks appearing only once the window holds a frame that slow; the
presence rule fed nothing but zeros and negatives, guard-run against the old rule; only the
outermost branch laid out after one click (`offsetParent` is null inside a `position: fixed`
drawer, so the check asks the branch's `.diag-children` for its computed `display`).
Verified by `check_ramp` on every run: the four ramp floors. Assumed: that 200 ms is the
right settling window; it is the conventional one.


Demo: The Solar Neighbourhood
---
The demo preset is the build's own load case, in three sizes: `ScaleOrrery.Nearest` (60),
`Neighbourhood` (360, the default everywhere) and `Catalogue` (5038, two slots short of the
pool — the smallest margin that still proves the point of leaving one: add a point, then
join it to something). Every size is the same construction — Sol entire, then real stars
outward, then four objects at horizon — truncated at a different depth, so a cost can be read
as a slope. Measured on one page under SwiftShader: 60 / 360 / 5038 objects cost 1.3 / 1.7 /
3.0 s to build, a frame build 3.1 / 4.6 / 12.8 ms, an edit 9.1 / 8.5 / 8.0 ms — flat, the
ring timeline doing its job. The working rule: `Nearest` for a quick check, `Neighbourhood`
for a final one, `Catalogue` when the change could cost performance. **Each size lands on
its count exactly**: the star walk passes over a system too large for the room left and
keeps walking, so a nearer four-item system gives way to a further single star; the suite
bounds the slack (once a system needing `k` items is passed over, at most `k − 1` stars can
follow it in). `orrery.showOrrery` is the one copy — arrangement, replayed arrival and camera
solve — reached by the bridge and by the desktop's `--demo`.

**Sol at the origin, its ecliptic flat in the ground grid's own plane**, every star, known
planet and major moon that fits at its real distance. `sol` is `1 𝐞₄`; `ecliptic sol` is
`−89.11 𝐞₄₁₂` and nothing else, the z = 0 plane; every planet has z exactly 0, Neptune at
12.000 units, the system radius its own scale claims. `SOL` names its bodies with real
distances in AU; `radiusOfSolBody` compresses them by a **logarithm**, lifted by `SHIFT_SOL`
= 1.0 so Mercury stands clear and normalised so Neptune sits at `SYSTEM_SOL.radius` = 12 —
the real order and the shape of the real spacing, a 77× range squashed to under 10×. The
tail indices are named constants (`INDEX_SOL_EARTH`, `INDEX_SOL_URANUS`,
`INDEX_SOL_NEPTUNE`, `INDEX_MOON_LUNA`) held to their bodies at compile time; positional
indices once put the ecliptic's furthest distance on a comet at 17.8 AU rather than Neptune
at 30.05 while the doc comment said otherwise. `TILT_MOON` = 0.0897 rad carries Luna's real
5.14° inclination, separate from the system's lean; the plane at horizon is
`att(ecliptic) ∧ att(earth ∧ luna)` and exists only because the two differ. Moons map their
real semi-major axes (Phobos at 9,376 km to Nereid at 5.5 million, a range of 588) onto
`RADIUS_MOON_NEAREST` 0.08 to `RADIUS_MOON_FURTHEST` 0.32 by the same logarithm; small
because Venus and Earth stand 0.74 units apart and a wider ring reaches the next orbit.

**Two shipped catalogues, data only, generated.** `neighbourhood.nim` is a snapshot of the
NASA Exoplanet Archive taken 2026-08-31 from its TAP service (`select hostname, pl_name,
sy_dist, ra, dec, pl_orbsmax from ps where sy_dist < 35 and default_flag = 1`, fetched in
distance bands): 331 planet hosts out to 31.5 parsecs. This research has made use of the
NASA Exoplanet Archive, which is operated by the California Institute of Technology under
contract with NASA under the Exoplanet Exploration Program. `starfield.nim` is a snapshot of
SIMBAD, every star within the same 31.53 parsecs, with the query recorded in the file: 11,432
returned, 180 composite entries dropped in favour of their listed components, 11,252 kept.
Each planet host was matched to exactly one star **by sky position alone**, worst separation
161 arcseconds — Barnard's and Kapteyn's stars, the two highest proper motions known, are the
two worst matches, the mechanism confirming itself. Distance is not used to match because it
is what the two archives disagree about: the exoplanet archive puts GJ 411 at 5.676 parsecs
where the truth is 2.55. So the star layer supplies every position and distance and the
archive only which planets exist. **Nothing is generated**: a star with no known planet is a
star. Not claimed as data, and marked so at the code: each neighbour's disc orientation
(`lean`, `spin`) is spread from its coordinates so discs do not stack; 49 of 544 planets with
no recorded semi-major axis are placed by their order among siblings and stored as `0.0`.
**What is not checked is either table against its archive**: no tool re-derives them, so a
hand edit would pass; stated rather than papered over.

**`UNITS_PER_PARSEC` = 100.** At 18 the nearest neighbour stood 24 units out against systems
9 units wide, and thousands piled into one frame; Proxima now stands 130 units out (fourteen
neighbour widths) and the outermost catalogue star 3,153. `RADIUS_NEIGHBOUR` = 9 and Sol's 12
did not move with it, since what reads as clustered is the ratio of spacing to system size.
**The price lands on the opening camera**: `RADIUS_ORRERY` fits the view to Sol and
`FRAMED_ORRERY − 1` = 1 nearest neighbour, about 139 units against Sol's 12, so Sol is a
twenty-pixel smudge until a reader dollies in (it reads at a distance of 48). Fitted to four,
the camera stood 273 units off with a hundred and fifty systems on screen and nothing left to
go and find. The camera is pitched to `ELEVATION_ORRERY_SHOWN` = 0.95 rad (at the opening
0.42 every ring collapses to a line) and pulled back by `camera.distanceFitting`, the same
solve a framed selection uses, azimuth left where the reader had it, `INSET_ORRERY_SHOWN`
24 px. Planet radii use `AU_NEIGHBOUR_NEAREST` 0.01 to `AU_NEIGHBOUR_FURTHEST` 30 on the same
logarithm, clamped rather than extended. `FACTOR_ISOLATION_ORRERY` = 2.0 floors the tightest
pair's separation against their combined reach.

**Colour says what a thing is, not which system it belongs to.** `lut_role_to_ink` maps a
`Role` to an `Ink`: four kinds of body on four slots and everything derived on the fifth,
`Olive`, the darkest — on a body a moon was a smudge that could not be found against the sky.
With comets gone the palette's declared `Jade`/`Cobalt` exception is not in this scene: four
roles, four inks.

**Three suite properties a model of a real system has to get right**: the planets run
strictly outward in the table's order; the squash is real (outermost under ten times the
innermost, where the truth is 77); the line at horizon is proportional to `attitude` of the
scene's own `ecliptic sol`. No point is a hub (lines and planes through any point ≤ 6, worst
`sun 1` at 4, where a star-centred layout scored 22); the one orbit line is `sol ∧ earth`,
asked geometrically rather than by label; three collinear points never wedge to nothing
(held by an assertion at construction and a suite case listing offenders).

*Checked.* Verified by suite at every size: every star at the distance its table gives it
(worst error under `TOLERANCE_SINGLE`), the table ordered outward, the count exact, the
camera solve, every object against the role table with four distinct body inks. Verified by
reading the built scene: the multivectors quoted above, the moons' order (Phobos 0.080,
Triton 0.217, Luna 0.219, Io 0.223, Titan 0.263, Callisto 0.279). Verified by looking, at
three shallow elevations (0.10, 0.25, 0.45 rad): the grid reads cleanly through the coplanar
ecliptic disc, no stipple. Verified by measuring: the page grew 2.17 → 3.64 MB for the star
catalogue (mostly names). Assumed: the archive snapshots themselves.


Browser UI
---
`shell.html` (markup, stylesheet) and `glue.js` are assembled with `browser_bridge.js` by
`build_browser.sh` into one page. `shell.html` ends on an opening `<script>` the two scripts
concatenate into. The font payload is kept out of the tracked file: an `@EMBED:<file>@`
token per face is substituted with that WOFF2's base64 data URL, so the tracked source is
26 KB rather than the ~966 KB it assembles to.

**Two pixel spaces, and each layer works in exactly one.** The render layer (`nimBuildFrame`,
`gl.viewport`) works in framebuffer pixels, `clientWidth × devicePixelRatio` capped at 2.5.
The interaction and overlay layer (`nimUpdateCursor`, `nimUpdateHover`, the markers, the
menus, the SVG viewBox) works in **CSS pixels** and is handed `clientWidth`/`clientHeight`.
Handed framebuffer dimensions it converted positions back down per point while using every
length raw, so a marker's size scaled with the device pixel ratio; `RADIUS_PICK_POINT` on a
Pixel 5 went from ~13.6 to a measured 34.0 CSS px with no change to `picking.nim`.

**Chip row** (always visible): brand/drawer toggle, undo and redo as bordered `.btn`
rectangles, axes and grid as a segmented `.toggles` pill, then a `☰` menu holding the rare
file actions. A pill shows state, a bordered rectangle is a momentary action. Below 520 px the
brand label drops to its mark alone; the breakpoint was 480 and wrong by 39 px, found by
sweeping the viewport a pixel at a time. **Stacking**: `.veil` (containing the chip row) is
`z-index: 5`, above the drawer's 4, below the menus' 6 — set on `.veil`, not `.chip-row`,
because `position: fixed` opens a stacking context and a descendant cannot outrank its
ancestor's sibling.

**Drawer sections** (alphabetical: apply, diagnostics, objects, view; only `objects` open by
default). Each object row is `[✓] label` + edit/hide/remove, then `shapeWord: coefficients`,
then the editor when open. Hidden rows dim to `opacity: 0.45`. The **coefficient grid** stacks
one flex row per grade (`nimBasisGrade`, so nothing hardcodes the dimension).

The desktop panel (`panel.nim`, `WIDTH_PANEL` 440) mirrors this section for section. Where
Dear ImGui forces a difference: selection is picked from the object rows (the row checkbox
toggles membership, the name picks that one alone); a grade's row wraps explicitly at
`COEFFICIENTS_PER_ROW` = 6 with the basis name **above** its cell (beside charged every cell
the width of the longest name and forced the panel to 680 px); cells divide the line they are
on — the browser's `flex: 1 1 56px` written out; an unselected arity segment is filled and
bordered, since a transparent segment on the 3D scene read as a caption; row buttons end flush
right (`guiAlignRight`); nothing carries a hardcoded width (`guiPlotLines` reads a zero width
as two thirds of the window); names recede in `--ink-faint` and section headers carry
`--surface-raised`; the edit toggle is a small button over session state, not a
`CollapsingHeader`; hidden rows dim through a style-alpha push, not `BeginDisabled`; the
atlas ranges start at 0x2700 so `✕` (U+2715) renders.

**The object-pool grid**: one square per slot, wrapped to the panel's width, occupied cells in
their object's ink and free ones in `Ink.Grid` (`INK_POOL_FREE`), so which slot an object sits
in and how far `inkCycled` has walked are legible. Both UIs get the strip as one buffer of RGB
triples and carry no palette rule. The cell size is derived, not constant: both front-ends
pick the largest cell whose wrapped grid fits `HEIGHT_POOL_MAX` = 150 px (`CELLS_POOL`,
`SIZES_POOL_CELL` 14 down to 2), and the gap goes before the cell does, because below four
pixels a one-pixel gap is half the strip. Six pixels over ten thousand slots was 191 rows; the
desktop's original 14 wrapped to 37 rows and 555 px and pushed the byte accounting off the
panel. The browser draws it on **one canvas**, the one scaled by `devicePixelRatio` (a grid of
hard-edged squares loses to a doubled display; 1.5 px strokes do not) — a thousand spans cost
a layout pass every time anything else in the drawer was written, and as flex cells with
`gap: 1px` at 1,024 slots every one of them was 0 px wide while every check passed.

**Handing a file to the reader** — one route, `deliverFile`, for the scene file and the
image. The image is captured **inside the frame that drew it**, a one-shot flag read between
the last draw and the yield (the context has no `preserveDrawingBuffer`, which would keep a
copy of every frame to serve a button pressed once). Delivery tries three routes and never
asserts a file was written: `navigator.share` with the `File` (transient activation, which
a click has); an `<a download>` **appended to the document**, clicked, removed (a detached
anchor's click is ignored by Safari); a link to tap plus, for an image, the picture itself in
a toast that stays, whenever the page is framed. **Every route reports itself** in the toast
and the diagnostics section — `framed`, `origin`, `share api`, `web-share` policy,
`activation`, one line per route — because three rounds were spent guessing at a phone that
could only report "nothing happened". **The artifact frame refuses downloads**: with
`allow-downloads` withheld even a genuine user tap on a real anchor is refused in silence,
and the Android report from inside the Claude app names all three refusals (`web-share:
false`, `download: no signal`, `new tab: blocked`), so no route from inside it can produce a
file; the toast says to open the page in its own tab. Two theories tested false: an
asynchronous `toBlob` spending the activation (the window is about five seconds and spans
the task boundary), and a backgrounded tab stranding the capture. **Deliberately not
built**: the scene as clipboard text with a paste box, the only thing that could carry a
scene out of that frame — a second serialisation to undo one host's sandbox.

*Checked.* Verified by driving: both save buttons fire a real `download` on unframed desktop
Chromium (675 bytes opening `RGAS`; a 185,135-byte PNG with 656 distinct colours, backdrop
55.6%, wash 33.3% — a "did a file arrive" check passes on a blank image); the share route on
a Pixel 7 profile with `share`/`canShare` stubbed; the framed fallback with and without
`allow-downloads`; the pool grid's coverage and cell width; the chip row fitting from 520 px
up; the marker size in CSS pixels on a Pixel 5 profile. Assumed: nothing about Safari beyond
its documented refusal of detached anchors.


Edit Sessions
---
Adding and editing are the same gesture, so both UIs run **one edit session at a time**:

|                | Composing (new)             | Editing (existing)              |
|----------------|-----------------------------|---------------------------------|
| Started by     | the top bar's `add`         | the row's `edit`                |
| Backing slot   | none                        | the row's own slot              |
| Row shows      | `save` `✕`                  | `save` `✕` `hide` `remove`      |
| `save`         | adds the object             | writes the four fields back     |
| `✕`            | discards; nothing was added | reverts; the object never moved |

Both stage sixteen coefficients, label and ink, and preview through the same ghost. `add` is
disabled while a session is open. **A session never writes to the scene before `save`**, so
the preview is invisible to `nimSceneSlots`, undo, save/load and `pickNearest`; the row is
drawn from session state, which carries its own `array[LABEL_MAX, char]` (a pointer into the
scene's label storage would edit it in place). `session: Option[EditSession]` with
`EditSession.slot: Option[int]`, `none` while composing — no sentinel slot. `EditSession`
owns `geometry`/`stage`, the two conversions between staged coefficients and a
`Multivector`. The ghost is `INK_GHOST` through the same `addObject` a real object uses; an
all-zero ghost degrades to "nothing to draw" through the existing `shape.isNone` branch.
`save`, `✕`, undo and redo all clear it.

*Checked.* Verified by driving both UIs: coefficients unchanged until `save`; the count
unchanged for the whole composing session; a staged grade-1 point adding exactly one vertex
to the desktop mesh (counted, not pixel-diffed — animation drift pollutes a pixel diff).
Nothing assumed.


Operation Notation
---
**One table, `scene.lut_operation_to_notation`, read by both builds**, each entry Lengyel's
bold notation, two spaces, the English name (`𝐦⊖  attitude`); `notationSymbolic` and
`notationNamed` are its two halves. `notationSubstituted` swaps `𝐦`/`𝐧` for real operand
names through two sentinel passes, so an operand whose name contains a placeholder is never
re-touched and a template with `𝐧` twice substitutes both.

**Every glyph and its placement comes from that operator's own declaration doc comment in
`pga/operators.nim`/`pga/multivectors.nim`** — never from `pga.nim`'s summary table, whose
"Lengyel" column renders several unary operators in a functional shorthand the declarations
do not use, and which has carried prefix glyphs where the declaration says postfix. Verify by
extracting codepoints, not by eye; U+2212 minus is invisible against a hyphen. One deliberate
exception: `Attitude` reads prefix in its doc comment and is placed postfix (`𝐦⊖`) on explicit
request, for consistency with every other unary entry.

The five accented operands use **spacing modifier letters** (`ˆ` U+02C6, `ˍ` U+02CD, `¯`
U+00AF, `˜` U+02DC, `˷` U+02F7), not combining marks: Dear ImGui has no shaper, so a
combining form landed to the right of its operand, and antireverse's tilde-below read as
left complement's low line. Of the four compound operators only the `★` pair works infix;
`m ∧☆ n` must be written `` m.`∧ ☆`n ``.

*Checked.* Verified by rendering all 27 entries at once and reading them; by
`tools/check_atlas` on every run. Assumed: nothing.


Typefaces
---
**Noto Sans** for UI text, **Noto Serif** for prose, **Commit Mono** for code and figures;
all OFL-1.1. The desktop atlas merges three faces by codepoint range (`ImFontConfig.MergeMode`):
Noto Sans for Latin, punctuation, subscripts and modifiers; **Noto Sans Math** for the
operators and bold operands; **Noto Sans Symbols 2** for the dual stars and the abandon
cross. `ImWchar` is 32 bits via `-DIMGUI_USE_WCHAR32` from `gui.nim`, a compiler flag rather
than an edit to the vendored `imconfig.h`. Coverage was measured: every non-ASCII codepoint
in the source rendered against each face and compared bitmap-wise against `.notdef`, which
is what found DejaVu lacking `⟑` and `⟇`.

The browser **embeds the faces** as base64 `@font-face`, split on the same `unicode-range`
boundaries. The maths and symbol faces are declared under the *sans* family, and `--mono` and
`--serif` name that family after their own, or a bold operand in monospace text falls through
to the system. Embedded rather than named because an artifact page cannot reach a font host;
about 940 KB of the ~1.6 MB page. Faces come from Fontsource (all 5.3.0) as WOFF2, vendored
into `fonts/` and never committed; the desktop reads Noto from `fonts-noto-core`.

*Checked.* Verified: the coverage measurement above; the six embedded payloads hashing
identically whichever way the page is assembled. Assumed: nothing.


Naming And Number Formatting
---
Basis elements are named exactly as the library's `$` names them (`𝟏`, `𝟙`, bold `𝐞` with
subscript digits); `lut_basis_to_name` **derives** them from the enum, and a suite case holds
each entry equal to what the library prints. Magnitudes read to **four significant digits**
(`DIGITS_SIGNIFICANT`): desktop `snprintf("%.4g")` into a stack buffer, browser
`format.formatMagnitude` in plain Nim behind `nimFormatNumber` — a decimal exponent by
`log10`, digits scaled, and **half-to-even** rounding, which C uses and Nim's `round` does not
(1012.5 reads `1012` in C and `1013` from `round`). `formatBiggestFloat` disagreed with itself
across backends on 1655 of 7000 values, so it is no primitive to build on. Both front-ends
print a multivector through one writer (`scene.multivectorText`) and a shape through one
(`scene.shapeText`). Diagnostics readings keep `%.*f` through `appendFixed`, since a live
number that changes width is harder to read.

Fixed char storage is read through `format.toText`, never `$toCstring`, which casts the
storage's *address* and yields an empty string on the JS backend.

*Checked.* Verified by suite on both backends: 17,001 values across 25 decades including every
exact eighth, zero disagreements against C's `%.4g` and zero between backends; the JS entry
point pins the tie cases' text directly. The C-only `magnitudesAgree` once stayed green while
330 of 7000 values differed between the front-ends, which is why the suite runs under `nim js`.


Animation
---
`ANIMATION_MILLISECONDS` = 350 and `easeOutCubic` are the one duration and one curve: a fresh
object grows in over them, the camera tween eases over them, and the browser reads them across
the bridge into `--anim`/`--ease` on `:root` (the CSS curve `cubic-bezier(0.215, 0.61, 0.355,
1)` is easeOutCubic exactly). One exception, marked as one: the opening hint is a timed
disclosure whose delay lives in `glue.js` alone — a stylesheet `transition-delay` ran from the
class being added rather than from load, so the two stacked.

*Checked.* Assumed: that one duration suits every transition; nobody has asked otherwise.


Camera Aiming And Framing
---
`camera.aimIncluding(aim, geometry, scale)` folds one object into what the camera has been
asked to show: a horizon point contributes its direction, a horizon line the first axis
spanning perpendicular to its normal, a horizon plane nothing, and anything finite widens a
bounding sphere by `mesh.anchorFor`'s point. `CameraAim` is a **requirement**, a pure function
of the geometry, which is what lets the standing offer re-made every frame compare equal every
frame. **The sphere is over what has to fit** (`is_bound_by_fitted`): the first point or
finite plane folded in discards whatever lines contributed, since a line whose support stands
forty units off dragged the view off the point beside it (73.8 against a distance of 12). A
plane widens the sphere by its **whole disc** (`widened` merges balls, with the swallowing case
written out).

Both builds aim from **one rule**, `framing.offerAim`, once per frame: the open session's
staged multivector if there is one, else every selected object. **A standing offer** — the
tween keeps its goal after arriving (`is_arrived` stops `advance` writing); a camera the user
moves calls `abandon`, which keeps the goal and marks it done (`release` clears it, so the
offer is re-made next frame and the camera taken straight back — panning was dead while
anything stayed selected, on both builds); `release` belongs to the offer's own side. `goal`
and `destination` are separate fields: the goal depends on geometry alone, the destination is
a `CameraPlacement` resolved once against the camera as it stood. `advance` eases target and
angles linearly and **distance geometrically**. `runStoryboard` goes through the same rule and
calls `settle`.

**Framing** (`framing.nim`): on a new pick, **the orbit target comes to the middle of what
was picked** — `objects.centroidFolded`, a sum of unit-weight points read back through
`position`, over the same objects the bound is over, each yielded **once** by `watched` (a
middle is a tally where a bound is a set) — and the camera moves by the **least zoom and
orbit** on top of that which puts every selected object in view, where in view means the
centred box `camera.reachCentred` shapes: `FRACTION_VIEW_CENTRED` = 2/3 of the height, and
two thirds of the width **or the height, whichever is less**. The width cap because the field
of view is vertical: uncapped, the acceptance edge stood at 23.9° across a 1440×900 window
against 15.4° down, so picking an object on a desktop practically never moved the camera
while the same pick on a phone did; capped, 0.417 of the half-frame across, exactly
`2/3 × 900/1440`. One-sided, since on a tall frame the width is already the shorter side.
`reachCentred` is the one statement of the box, from which `picking` derives pixel margins
and `halfAngleCentred` the cone `distanceFitting` solves.

**Three readings, following what each shape is drawn at**: a point's dot fits inside the
centred box (inset `INSET_POINT_SHOWN`, half of `SIZE_POINT`, deliberately not by the swelling
marker); a line merely crosses it (drawn to `radius_horizon`, it has no size to fit); a
plane's **centre** is in the centred box and its **rim** on screen — against the frame inset
by `INSET_RIM_SHOWN`, half the rim's stroke, 1.25 px, the entire price of letting a disc reach
the edge. Holding the rim to the box threw the camera from 19 to 29.9 on the ground plane
where 19 already showed the whole circle; rim on screen gives 19 → 19 from the home camera,
8 → 15.24 dollied in, 19 → 42.76 on a phone. Screen segments meet the box by Liang–Barsky
clipping. A plane is judged where its disc is drawn (the stored anchor), not at its support.

**The cut.** `placementFor` first asks whether everything is already in view *where the
camera stands* — judged at the centred placement instead, every pick of something plainly
visible pulled the view about. Otherwise it builds the full placement (middle as target,
facing angles for horizon-only, bisected least distance: `ROUNDS_DISTANCE_FIT` = 8, the
closed form `radius / sin θ` as the upper bracket only) and searches the least fraction of
`camera.toward` satisfying `isShownAll`: `STEPS_PLACEMENT_LEAST` = 12 even steps then
`ROUNDS_PLACEMENT_LEAST` = 5 halvings, each candidate verified at its own placement. The
target is not part of the cut; distance grows, never shrinks; a finite pick never changes
azimuth or elevation, and a star is turned toward only when nothing finite was picked.

*Checked.* Verified on the shipped page, seven selections × nine starting orientations: worst
picked point outside the box 0.0 px (323.9 when watching one object); total pan over 63 trials
97.2 (277.9 when centring the selection); trials moving an in-view selection none; orbit turned
0.000 in all 63; distance 12.0–13.6 and never below. Verified by real touch events
(`verify_touch_pan.js`): pan unselected, pan selected (0.21 units against 4.40 with `release`),
a grab mid-ease, re-selecting after deselect. Verified by driven check: the preview framed with
its operands (the camera pulling from 9 to 13.39 with both landing inside the box). Verified
that it was not a mouse-path fault: identical camera readings under mouse and CDP touch at two
viewports. Assumed: nothing.


Hold Feedback, Help And Keys
---
**A touch hold shows itself**: `interaction` owns `SECONDS_LONG_PRESS`, a `Hold`, and
`progressHold`/`isHoldMature`, and the indicator is the marker itself drawn part-built (see
the fills table under Selection). Progress is **linear, never eased** — a clock being shown,
and an eased clock appears to stall just before it fires.

Both front-ends carry a `?` in the bottom-right corner, at least 44 px, opening the same
table `help.lut_help_entries`, which both render. Construct rows derive from `armingOf` and
`revealsMenuOn`; keyboard rows from `motionFor` and `actionFor`; the `operations` tab is
generated from the catalogue (`notationSymbolic` against `notationNamed`), so it cannot fall
behind. **Tabbed by how you are working**: `drag`, `select`, `menu`, `panel`, `camera`,
`keys`, `operations`. `ENTRIES_MAX_PATH` = 8 per tab (`ENTRIES_MAX_PATH_KEYS` = 12,
`ENTRIES_MAX_PATH_CATALOGUE` the operation count), asserted at compile time and in the suite,
a **proxy and named as one**: the real constraint is rendered height. Measured at 320×568 as
overflow of the rows box: `drag`, `select`, `menu`, `panel`, `camera` 0 (two after their
descriptions were cut, about 17 px each), **`keys` 129 px over**, left scrolling deliberately
— fitting it costs `enter`'s "hold shift to add it" on every screen to serve one with no
keyboard; stacking cells was worse (161 over) and regrouping keyboard rows onto other tabs
left `camera` 133 and `select` 66 over. Shift gets one row, not one per button: all four
combinations measured 125 px over. **Every row makes sense with the rows above covered up**;
what a two-column row cannot carry goes in `descriptionOf`, one sentence per tab, crossing as
`nimHelpDescriptions`. One word, one meaning: objects are **selected**, operations **chosen**.

The browser's two columns are one grid over the whole table (`.help-rows` the grid, each row
`display: contents`), so a column is one width down the table; a flat `44%` gave the actions
245 px they did not want. Both tracks carry a 122 px floor, measured: without the outcome
floor the actions took 208 of the 262 px a 320 px phone leaves; 150 px does not fit beside 122
and the 10 px gap; dropping the action track to bare `max-content` put `drag` 533 px over. The
panel is a flex column, capping its own height with `min-height: 0` on the rows box. Rows are
hidden by attribute, which needs `.help-row[hidden] { display: none }`. The desktop measures
its outcome column off the widest action, **only while the panel is open**: measuring every
frame changed which glyphs Dear ImGui rasterised into the atlas and moved single pixels of
panel text in the storyboard across three rounds (bisected: with the fix, two table sizes
give byte-identical storyboards). `guiChildHeightForRows` asks Dear ImGui for its own line
spacing rather than restating it. **The help stays open until it is closed**; the two
popovers keep their tap-outside dismissal.

**Keyboard.** `Escape` sheds what is in progress, innermost first, and on the desktop no longer
quits (`ctrl+Q` does). The view is one ordinary tab stop — **Tab is deliberately not rebound**,
which would trap (WCAG 2.1.2) — and traversal took the brackets:

| Key | Does | Kind |
|---|---|---|
| `w` `a` `s` `d` | slide the view across the ground | held |
| `q` / `e` | lower / raise it | held |
| arrows | orbit | held |
| `-` / `+` | dolly out / in | held |
| `shift` | multiply every rate by `FACTOR_HASTE` | held |
| `[` / `]` | focus the previous / next object | press |
| `enter` | select it, or add it where shift is held | press |
| `f` | frame whatever is selected | press |
| `home` | put the camera back where it started | press |

`motionFor` and `actionFor` split by **kind**: a motion runs every frame its key is down
(`driveHeld`), an action once at the press. The bindings follow Unity, Unreal, Godot and
Blender (WASD, Q/E, shift for faster, F to frame), with the one fork made the map's way:
the view *slides* across the ground and the height never changes. Both front-ends watch key
up as well as down; `releaseKeysAll` empties the held set on blur, on the tab being hidden,
and when a panel widget takes the keyboard (`gui.wantsKeys`: `WantTextInput` or
`IsAnyItemFocused` — `WantCaptureKeyboard` is true from the first frame with navigation on).
Plain `s` moved to `ctrl+s`. Dear ImGui's keyboard navigation is enabled (`io.ConfigFlags`);
without it Tab reached nothing on the desktop at all.

**A camera move is not a hover** (`isMovingCamera`: each front-end's own drag flag, plus
`keys_held` through `motionFor`, so shift alone is not movement; a construction drag is
excluded). Raised by the movement, not by the press, or a click read a suppressed hover. The
latched flag is cleared on blur, on the tab being hidden, and at the start of any gesture
that finds no pointer down. **Focus is its own state** (`index_focus`), pruned against
liveness and drawn with the hover marker; the browser adds an inset `:focus-visible` ring.

*Checked.* Verified by `--drive-keys`: focus walked, enter selected, azimuth/elevation/distance
each moved by exactly their own constant. Verified by browser drive: real key events; Tab from
the canvas moving to the next control and back; a blur mid-hold moving the target 0.0000
further; the help table's per-tab overflow at 320×568; `[]-+` typed into a label reaching the
label. **Not demonstrated**: Tab landing on a Dear ImGui widget — a window that never takes
focus under `xvfb` gives ImGui nothing to move; `gui.isNavEnabled` reports the configuration,
not the behaviour.


Style Guide
---
Two documents at the project root. `CONSTITUTION.md` is the rule of law: eleven articles over
exposition, derivation, notation, build-time safety, naming, documentation, cost, honesty,
tests, form and the record, with a precedence clause and three gated mechanisms. `STYLE.md`
is the Nim expression guide: how each rule is spelled in Nim, and what each backend does with
a value.

**Every comment in the project has been reworked to the vendored `pga` library's prose
register**, against both documents: a one-line imperative summary ending in a period (types
open "Define …"), elaboration as a hanging outline one claim per line, stage comments with a
verb-first lead, trailing fragments on fields ending in a period, no articles, no history and
no figures (which moved here). `tools/check_prose` holds the whole of that mechanically —
article rule, summary form, stage form — in every authored language, and runs in `verify.sh`.
Kept from earlier audits and still in force: `gif.nim`'s none is `Option[int]`; the bridge's
FFI-boundary cases translate through one `SLOT_NONE` at each proc's return; the `when
defined(js)` seams in `scene.nim` are backend necessities, not shortcuts; `glue.js` and
`shell.html` use snake_case for data bindings and camelCase for callables with the forbidden
truncations spelled out, shader attribute strings untouched.

The vendored `pga` library was reviewed and left unmodified by request. Known deviations are
mechanical, plus one substantive: `pga.nim:28` asserts its own module doc is the source of
truth for names, which is what makes the notation trap easy to fall into.

*Checked.* Verified: `check_prose` and `check_columns` report zero complaints across 51 and 56
files, and the full suite, both drives and every checker pass on the reworked tree; the rework
changed no code — a code-only diff against the previous revision was empty for every Nim, JS,
HTML, CSS and C++ file. **Unverified**: no human has read the result.


Dependencies / Vendoring
---
The PGA library is vendored at `pga.nim`/`pga/`, copied unmodified from
[replications][replications] at commit `f8861e0`, **not committed**. Both projects are
Prosperity Public License 3.0.0; `pga/LICENSE.md` names replications as source per the
licence's Notices term. The six WOFF2 faces are vendored the same way at `fonts/`. System
packages: `dependencies.list`. Dear ImGui compiles from source at `deps/imgui`. Needs a Nim
from `devel`. `pga`, `deps/imgui`, `fonts/` and `bin/` are the whole of what the working tree
carries and the repository does not.


Verification Tools
---
`tools/verify.sh` runs everything below cheapest first and fails on the first failure. Passing
it is necessary and never sufficient — several bugs here survived a green run — so the script
closes by saying so.

| Check | What it holds | Reads from |
|-------|---------------|------------|
| `check_columns` | Width in **characters**, trailing space, tabs, final newline | The filesystem |
| `check_prose` | Article rule, summary form, stage form of each comment | The filesystem |
| `check_palette` | Palette separation floors under Machado severity 1.0 | `mesh.lut_ink_to_rgba` |
| `check_atlas` | Every drawable codepoint has a glyph range | `lut_*` and `gui_shim.cpp` |
| `check_ramp` | The tint table against the map and the shell's tokens | `ramp.nim`, `shell.html` |
| Suite ×3 | Every invariant, on both backends and two capacities | `tests/visualiser/` |
| Desktop drive | Seven scripted gestures through SDL's queue under `xvfb-run` | `bin/visualiser` |
| Browser drive | Real key, wheel, mouse and touch events through Playwright | `bin/` page |

Each reads the thing being checked rather than a transcription of it. `check_columns` counts
characters because `wc -L` reports a line full of `∧` and `𝐦` as eleven columns too long and
gets ignored within a day; it skips the testament spec block, whose `matrix` line has nowhere
to wrap; it runs in under a tenth of a second (a quadratic line count once cost forty seconds
on the star catalogue). `check_prose` reads comments out of each language's own syntax, masks
code spans and quoted titles, treats a bare `a` before `and`, `or`, an operator or a single
letter as an operand name, requires a summary's lead line to end `.` or `:` and open with a
verb from its list unless it is a trailing doc or a `TODO:`, and a stage lead to end `.`, `:`
or `?`; prose files are deliberately not read. `check_atlas` parses the `ImWchar RANGES`
arrays out of `gui_shim.cpp` and enumerates 62 printable codepoints; each table entry is bound
to a local before being walked, since an open array over a temporary read from a `const`
array outlived what it pointed at (a segfault on the first entry). All three self-testing
tools reuse one file walk.


Testing
---
One file, `tests/visualiser/suites.nim`, 296 cases, from three thin entry points:

| Entry point | Backend | Capacities | Why |
|-------------|---------|-----------|-----|
| `test_4d.nim` | C | Default | The desktop build, as shipped |
| `test_4d_browser.nim` | JS | Default | The browser build's own backend |
| `test_4d_small.nim` | C | 12 items, 12-char labels, 4 steps | Boundaries a test reaches |

The JS row is not a formality: a rule reached through two mechanisms is held together only
where both run. The reduced row makes any constant tuned to the default fail here; `LABEL_MAX`
at 12 is under several labels the suite constructs. Cases needing C — `snprintf`, the encoders,
the arena, save/load — guard themselves `when not defined(js)`. A case that walked every pair
of slots at 10,000 objects ran ten minutes without output and was killed; it gathers the
joiners once now, and the JS suite runs in about two minutes.

**The suites test rules; a second layer drives events.** A rule bug earns a suite case; a
wiring bug earns a driven check, at the layer the bug lived at. The desktop drives are
`--drive-keys`, `--drive-sky`, `--drive-undo`, `--drive-select`, `--drive-drag`,
`--drive-help:<tab>`, each posting to SDL's own queue, splitting each gesture across two frames
(hover is recomputed inside `renderFrame`), setting shift through `sdl3.setModState`, and
capturing one frame later than each step (Dear ImGui hides an auto-sized window for the frame
it measures it in); `--drive-sky` scans for bare sky rather than hard-coding a pixel;
`--drive-undo` drags with the **left** button, since a right release with a scripted cursor
resting on its target stands in no wedge. The browser drive (`drive_browser.mjs`) reported 302
checks `ok` at this revision. Timing-dependent quantities are asserted as **bands**, never
figures, and the bands are stated as what catches the collapse class a reader felt rather than
as this container's timings: identical code has measured 25.0 and 29.8 ms hours apart on the
shared runner, a flat ±1 ms band failed one frame in a hundred and twenty, and a flaky check
gets deleted rather than fixed. Three harness facts worth keeping: a driven check is evidence
only for the page just built, which `verify.sh` guarantees by ordering; one check switches the
debug layer on and never off, so later measurements include ~1,650 lattice records and say
so; a fresh object starts its pulse at zero, so a comet check waits for a head before timing.

*Checked.* Verified: everything in this file marked so was established by one of these
layers. Assumed: nothing about the suite itself.


Measurements
---
Desktop, release build, 4 cores at 2.8 GHz, 1440×900, headless Xvfb + Mesa `llvmpipe`, taken
at 64 objects and not since:

| Quantity | Cost |
|----------|------|
| Tessellate a 64-object scene | 61 µs (~0.95 µs/object) |
| Any catalogued operation | 80–170 ns |

Browser, SwiftShader, on this container, the figures the driven bands were pinned against:
opening-scene `nimBuildFrame` 21.9 ms released; demo at 5,038 orbiting, scene walk 9.2 ms
with the tally off; one hover pick 3.5 ms at 5,038. **No figure in this file has been taken on
real GPU hardware** except the two device readings quoted in Browser Pipeline, and a ">500 fps"
target cannot be assessed here: rasterisation dominates the frame entirely and none of it is
this project's code.


Known Limitations
---
- No human has run either build. Every result here is software-rendered and machine-driven.
- Tab landing on a desktop widget is unverified (see Hold Feedback, Help And Keys).
- Two crossing translucent washes blend order-dependently.
- A camera move is not undoable on its own.
- The comet's residual steps at fast orbit rates are unexplained (see Selection And Markers).
- Neither catalogue is checked against its archive by any tool.
- The frame-time tail on real hardware is undiagnosed; this container cannot see it.
- Conformal metric (`IS_CONFORMAL`) is unfinished in the library; this build is rigid 4D.
- `.rgascene` is little-endian by rule, but only a little-endian host has ever written or
  read one; the byte-swapping path is unexercised.

[replications]: https://gitlab.com/mraxilus/replications
