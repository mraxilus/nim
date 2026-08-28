Provenance
===

_Who made this, from what, and how far it has been checked._

| Field  | Value |
|--------|-------|
| Agent  | Claude Code |
| Author | Claude Opus 5 and Claude Sonnet 5 |
| Date   | 2026-08-01 |
| Style  | `STYLE.md`, supplied with the prompt; followed for all code. |
| Review | **Unreviewed.** Nothing here has been read line by line by a human. |

An interactive PGA (rigid metric) object visualiser, built over many turns as a testbed
for the vendored `pga` library: a desktop app (SDL3 + OpenGL + Dear ImGui) and a browser
app (WebGL) compiled from the same Nim geometry code, plus a scripted storyboard that
exports PNG frames and an animated GIF.

This file records the current design and the reasoning behind decisions that are not
obvious from the code — what was chosen, what was rejected and why, and which constraints
a change must not break. Superseded experiments and fixed bugs are not narrated; where a
rejected alternative is a live trap, it appears as a terse "not X — Y" note.

**Verification practice, applies throughout.** Every change is rebuilt and the full
property-test suite rerun (`tests/visualiser/suites.nim`, 210 cases; `renderer`/`gui`/
`panel` are excluded — they need a live GL context). The storyboard is regenerated headless
under `xvfb-run` with Mesa `llvmpipe` and the resulting PNGs/GIF looked at, not just
recompiled. The browser bridge is rebuilt with `nim js`, reassembled, and driven headless
through Playwright (SwiftShader) with real synthetic events — `page.mouse`, and CDP
`Input.dispatchTouchEvent` for touch, since untrusted `PointerEvent`s fail
`setPointerCapture` and calling handlers directly bypasses the listener wiring where real
bugs have hidden. No human has driven either GUI, clicked a button, or seen the app on real
GPU hardware; every number and screenshot here is software-rendered.


Render Paths
---
**The directory a module sits in is which render path may reach it.** The boundary used to
be a table in `visualiser.nim`'s module doc that every other module cross-referenced; it is
now the layout itself, so there is nothing to keep in step.

| Directory | Reachable from | Holds |
|-----------|----------------|-------|
| `visualiser/core` | Both | `objects`, `mesh`, `camera`, `scene`, `selection`,
  `picking`, `marker`, `framing`, `interaction`, `storyboard`, `history`, `format` |
| `visualiser/desktop` | `visualiser.nim` | `panel`, `renderer`, `opengl`, `gui`,
  `gui_shim.cpp`, `sdl3`, `image`, `gif`, `arena` |
| `visualiser/browser` | `browser_bridge.nim` | `browser_bridge.nim`, `shell.html`, `glue.js` |

`pga` is vendored above all three and shared. `core` imports nothing outside itself and
`pga`; `desktop` and `browser` each import `core` and never each other, which is now
readable from the import paths (`../core/`) rather than needing an import-graph audit.
`arena` sits in `desktop` rather than in `core` despite being general-purpose: it is
reached only by the PNG and GIF encoders, and the JS backend has no use for it.
The two entry points share all geometry and never import each other.

A shared module reaching for something only one path has is a **compile error, not a
comment**: `toCstring`, `buildChars`, `appendInt`, `appendFixed`, `saveScene`/`loadScene`
and their `std/os` and `std/syncio` imports are all guarded `when not defined(js)`. The
suite runs on both backends (see Testing), so the guard is exercised rather than trusted.


Scene Storage
---
`Scene` (`scene.nim`) is a fixed-capacity structure-of-arrays arena (`geometries`,
`labels`, `inks`, `are_visible`, `are_alive`, `borns`, `anchor_overrides`), addressed by a
slot assigned once on `addItem` and never moved. Free slots thread onto an intrusive
singly-linked free list (`next_free`, head in `slot_free_first`), so add/remove are O(1).
`ITEMS_MAX` = 64, `LABEL_MAX` = 40, both `{.define.}`-overridable.

Chosen over a shift-on-delete array whose O(n) removal also renumbered every held
cross-frame index (hovered/dragged/operand slot) — the property everything else relies on
is that **a slot number stays valid until its item is removed**.

**`LABEL_MAX` counts bytes, so a label is cut on a character boundary and says it was cut.**
`format.appendChars` reads each lead byte's own sequence length (`bytesCharacter`) and copies
a sequence only if all of it fits, so it can never leave a partial character behind whatever
the caller or the buffer size; `scene.toChars` then rewinds far enough to append `…`. Before
this, a 3-byte operator glyph (`∧ ∨ ⊖`) straddling the 40-byte limit left invalid UTF-8, which
Nim's JS backend percent-escapes — `%e2%8a` appeared in an object's name in the browser, which
is how it was found. Exactly the byte-versus-character bug fixed in the scene file format one
round earlier and not looked for in the label store beside it. Note what the fix does *not*
address: derived names compound, so `b ^ ground⊖ ∧ b ∨ (o ∧ ground…` is unreadable because of
the compounding rather than the cut. That is a deliberate choice to leave — the full name is
what the object *is*.

`Item` is a handle (pointer into `Scene` + slot number), not an assembled copy;
`.geometry`/`.label` resolve via `lent`. Do not hold one across a mutation of its own slot.
By-slot accessors (`geometryOf`/`geometryAt`/`labelAt`/`inkAt`/`bornAt`/`orderOf`/
`anchorOverrideAt`, plus `isVisible`/`setVisible`) exist beside it and are what the browser's
per-frame loop uses — see Browser Pipeline for why constructing an `Item` there is expensive.


Memory And Allocation
---
Explicit constraint: keep the GC out of the hot path, arena-style. The interactive render
loop allocates nothing. `visualiser/core/format.nim` wraps C `snprintf` so per-frame number
formatting writes into stack buffers; `formatMultivector`/`describeShape` append into
caller-owned storage. Button-driven message building (apply, drag release, storyboard step)
still uses `strformat` deliberately — once per click, not once per item per frame, and the
result must become a real `string` for `Scene.addItem` anyway.

`visualiser/desktop/arena.nim`: a plain `array[N, byte]` global, carved by `push[T](arena, count)`,
reclaimed by `reset`. Two instances — **permanent** (`CAPACITY_ARENA_PERMANENT` 160 MiB,
never reset; backs the reused pixel-readback buffer and the storyboard's accumulated GIF
frames) and **frame** (`CAPACITY_ARENA_FRAME` 64 MiB, reset after each throwaway unit — one
PNG write, one GIF sub-frame; backs scanline/quantisation/LZW scratch). Permanent capacity
is sized to the storyboard run's own actual
`arena.used + bytes_needed`, not a round number. The interactive draw loop asks neither
arena for anything (`Scene`/`MeshSet` are already fixed-lifetime arrays).

GIF's LZW dictionary is a separate fixed open-addressed hash table (`LzwDict`, 8192 slots,
Knuth multiplicative hashing) rather than a third arena — it needs random-access probing
within a frame, not bump-only append.

**LZW gotcha, now a permanent regression test:** the format widens code size one symbol
earlier on decode than on encode ("early change"). Caught by an independent from-scratch
decoder round-tripping a real encoded frame past the code-width growth point.


Colour Palette
---
Five assignable hues — `Rose, Copper, Olive, Jade, Cobalt` — plus `Backdrop`,
`AxisX/Y/Z`, `Grid`, `Guide`, `Outline` and `Invalid` in one `Ink` enum
(`mesh.lut_ink_to_rgba`).

**`Invalid` is a reserved magenta**, held out of the assignable run so that seeing it
always means an object is wrong rather than merely coloured. Nothing draws in it yet; it
is reserved so the palette can be held clear of it. Whatever comes to use it must not lean
on the colour alone — magenta reads as *blue* under deuteranopia, which is exactly where
every assignable hue sits furthest from it, so an invalid object needs a word or a marker
too.

Reserving it cost three hues, not one. `Violet` and `Cerise` are the same pink-purple
family by eye and measured CVD ΔE 10.2 and 8.3 from magenta — too close for a status
colour. `Cobalt` is the surprise: 88° of hue away, plainly blue to normal vision, and yet
CVD ΔE **6.6** from magenta, because blue and magenta converge under deuteranopia. Hue
distance alone would have missed it. It is re-derived rather than dropped — lighter and
bluer (`#5b90c7`) — which reopens the pair to 14.4. That 6.6 pair was already documented
here as the palette's one legal-with-secondary-encoding exception; it stopped being
acceptable the moment magenta came to mean "this is wrong".

`Ink.Magenta` was also the *meet* drag rubber-band and three storyboard steps' object
colour. Both moved to `Rose`: a normal interaction must not wear the colour that means
invalid.

**Do not fill the remaining arc back up to eight.** That was tried and measured, not
argued: a seven-hue set spread across what is left put `Olive` and a new yellow-green at
CVD ΔE 0.4 and two blues at normal-vision ΔE 5.6 — the sixteen-slot failure exactly. The
axis hues flank the reserved arc on both sides, so what remains is one warm arc and one
cool, 162° in total. Five is what fits it honestly.

**The structural slots are not offerable as an object's colour**, in either UI: an object
wearing the backdrop, a world axis or the selection outline is either invisible or reads
as something it is not. `mesh` names that boundary once — `INK_CATEGORICAL_FIRST`,
`COUNT_INK_CATEGORICAL`, `inkCategorical`, `categoricalIndex` — and the two pickers and
`inkCycled` all derive from it, so nothing cycles to a colour the user could not have
chosen. Structural slots are declared first and the categorical run last precisely so it
is one contiguous block a picker can walk: ImGui takes `lut_ink_to_name` at the run's own
offset with no second table, and `nimInkChoosableSlots` hands JS the ordinals so it does
no palette arithmetic. That contiguity is load-bearing rather than cosmetic, and a
`static: doAssert` on the count is what enforces it — appending a structural slot after
`Cobalt` fails the build rather than quietly adding it to both pickers.

Derived under two constraints checked with the dataviz skill's validator, not by eye:

1. **Every one of the ten pairs** among the five clears normal-vision ΔE ≥ 15, plus ≥ 20°
   hue separation so lightness/chroma can never stand in for a hue difference. One
   exception: `Jade`/`Copper` at CVD ΔE 7.6, inside the validator's 6–8
   legal-with-secondary-encoding band — these objects already carry shape and screen
   position as secondary encoding. `Rose` sits at contrast 2.78 against the backdrop,
   under the 3:1 the validator wants; its always-present row label in both panels is the
   relief that permits.
2. **Axis safety**: each hue clears a ≥ 20° hue distance plus a lower ΔE floor against
   `AxisX/Y/Z`, so a thin fixed axis line is never mistaken for a filled categorical object.
3. **Distance from `Invalid`**: every assignable hue clears CVD ΔE ≥ 14 from the reserved
   magenta. Worst is `Rose` at 15.2 and `Cobalt` at 14.4; the rest are 23 or better.

Both floors matter. An earlier sixteen-hue set held only *adjacent* pairs to the full floor
and everything else to a much looser ΔE ≥ 5, which crammed every slot into the narrow
teal/blue/violet arc that strict axis-safety leaves available, and read as "all the same
colour." Fewer slots alone does not fix that — the axis-safe arc is a fixed size regardless
of hue count, so the real fix was loosening axis-safety (a thin line needs less separation
than two adjacent filled objects) to free most of the wheel back up.

Axis colours additionally carry a permanent 22% blend toward their own luminance — enough
that a bright RGB trio stops competing with categorical objects, without losing which axis
is which. A compile-time palette literal with no alpha change, unlike `mesh.muted()`.

`Ink.Outline` is retained in the enum although nothing draws with it: removing a
categorical-adjacent entry shifts every later ordinal and silently corrupts the colours of
an already-saved `.rgascene`.


Geometry And Drawing
---
**Plane.** A solid rim (`addPlaneRing`) plus a flat translucent fill (`addPlaneFill`,
`ALPHA_WASH` = 0.16) bounded by that rim; no crosshair, no ruled grid, no anchor marker.
Flat rather than fading because the rim already marks the boundary. Fixed radius
`EXTENT_PLANE` = 8 world units around the plane's support/anchor — **not** camera-distance
scaled, which visibly resizes a plane as the camera orbits. **No normal drawn**: a bare
shaft at 0.25 × extent used to mark one on every plane in the scene, permanently, to answer
a question a reader asks about one object at a time. Orientation moved onto the selection
marker's own pulse instead (see Selection).

The drawn radius is a rendering choice only: `EXTENT_PLANE` appears in `mesh.nim` (drawing)
and `picking.nim` (click bound) and nowhere else — every construction path reads the full
untruncated `Multivector`, so a meet lands correctly arbitrarily far outside the drawn
disc. There is a regression test asserting this.

**Line.** Drawn as **two segments meeting on the line at its support**, each running out to
one of the line's own two vanishing points, `eye ± radius_horizon*axis`. The forward one is
exactly where that line's horizon-attitude marker draws, so a line reaches its own attitude
with no gap.

A vanishing point is a property of the *eye*, not of the line, which is what forces this
shape. An end anchored a fixed reach from the line's own support instead stops short of the
vanishing point by roughly the eye-to-line separation over that reach — measured at ~6.7°
for a line whose support sits 40 units out, which is a plainly visible gap. Anchoring both
ends to the eye closes it at both; one segment cannot, since a segment running eye to eye
passes through the eye and projects to a point.

Each segment has one end on the true line and one off it, so both lie in the plane through
the eye containing the line. That plane projects to a single screen line, so the pair draws
**exactly** over the true line's own projection however far the far ends sit from it in
world space — measured at zero screen skew to floating-point precision (1e-16), not argued
from the geometry. The far ends do sit 6–17 world units off the line, displaced along the
view ray, so occlusion against other objects is approximate there; the meshes are rebuilt
against the current eye every frame, so the screen-exactness holds as the camera orbits.

`picking.nim` tests both halves — testing one would leave the other half of a line on screen
unpickable, and which half that is changes as the camera orbits. It needs `clipToEyeSide`, a
by-hand near-plane clip mirroring what the GPU does when drawing, because a screen-space hit
test divides by each endpoint's depth and this reach can put an endpoint behind the eye.

**Horizon objects** (grade sends them to infinity) are drawn as sky, not as extended finite
geometry: a horizon point is a fixed star at `eye + radius_horizon*heading`, a horizon line
a great circle around `eye`, a horizon plane a full-sphere dome around `eye`
(`ALPHA_WASH_SKY` = 0.22). All three anchor to `eye` every frame — zero parallax on
translation, turning only with rotation. A full sphere, not a hemisphere: an orbit view sits
elevated and tilted down, so cutting the dome at the eye's horizontal removes sky the camera
can actually see. In this 4D algebra grade 4 is one-dimensional, so *every* horizon plane is
the same universal object regardless of what built it and carries no orientation to render.

**Draw-order invariant.** Translucent triangles share one unsorted `Primitive.Triangle`
bucket drawn with depth writes off, so among translucent draws whichever is appended last
wins the blend regardless of true depth. Both `visualiser.assembleMeshes` and
`browser_bridge.nimBuildFrame` therefore insert any visible horizon plane's dome into that
bucket **first**, before every other visible object (via the shared `objects.isHorizonPlane`),
guaranteeing an ordinary plane's fill blends over the dome whatever slots they occupy. Two
ordinary washes crossing still look order-dependent — a known, accepted limit.

**The wheel zooms toward what the pointer is over** — the map reading of a zoom, which is
what Google Maps, Supreme Commander and every strategy game since do. Zooming at the middle
of the frame makes a reader aim in three moves (zoom, pan, zoom again) where one should do.

**A pinch does not**, and that exception is deliberate. It was aimed at the pinch's own
midpoint at first, on the reasoning that a midpoint is a finger's way of pointing; on a phone
it read as wrong, immediately. The two-finger gesture already pans the view by that
midpoint's own travel between events, so aiming the zoom there as well translates the view
*twice* for one gesture, and a pinch anywhere but dead centre slides the scene while it
scales it. A wheel carries no pan beside it, which is exactly why the same rule is right
there and wrong here. The pinch is centred, as it was before the camera pass touched it.

`picking.positionUnderCursor` solves the anchor: where the cursor's own sight ray meets the
**horizontal plane through the camera's target**, and none where it never does. That plane
rather than the ground at `z = 0`, for two reasons — it sits at the height the reader is
working at, which is what they mean when they point at something, and a ground plane far
below a raised target puts the hit wildly far off at a shallow angle. Where there is no hit
(the sky, or a ray running along that level) the wheel falls back to the plain dolly it did
before, which is the right answer there rather than a refusal to zoom.

`camera.dollyToward` then moves the eye **along its own line to that anchor** rather than
straight in, leaving the angles alone. That is the whole trick and it is worth stating: the
sight direction is fixed and the eye stays on the line joining it to the anchor, so that line
is the same line afterwards and the anchor keeps its pixel. The scale actually applied is
read back from `distanceHeld` rather than assumed, so a zoom stopped by the near floor moves
the eye by exactly as much as the distance it was allowed — otherwise the placement stops
describing where the eye is, which the suite checks by comparing `norm(eye - target)` against
the distance.

**Measured through real wheel events**, not by reasoning about the algebra: an object under
the pointer drifted 2 px across a 3.2× zoom (19 → 6.0 units), and wheeling back out returned
the camera to distance 19.000 and target (0, 0, 1) — the opening placement exactly. Those 2
px are the anchor being on the target's level while the object sits above it; a reader cannot
see them, and the alternative (anchoring on whatever object is hovered) makes the zoom jump
between depths as the pointer crosses things.

**An orbit distance has a floor and no ceiling.** `DISTANCE_LIMIT_NEAR` = 0.05 is geometry:
at zero the eye coincides with its target, the line joining them is undefined, and every
direction `camera.frame` derives from it collapses. The 500-unit ceiling that stood beside it
was a round number, and it was the camera reading as bounded to a region — dolly out to look
at something a kilometre across and the view simply stopped moving. It is gone, along with
the `clamp` that had been written out at five sites; `camera.distanceHeld` is the one
statement of the floor, and construction, the dolly, both front-ends' numeric fields and
`distanceFitting` all pass through it. Nothing downstream needed the ceiling: the clip planes
are fractions of the distance, so the frustum keeps its shape at any distance, and the grid
bounds its own line count rather than leaning on the camera's limits.

What does degrade far out is `mesh.Vertex`'s float32 storage: past roughly 10⁶ units a
coordinate carries under a tenth of a unit. Driven by the wheel out to 3 × 10¹⁹ the view
empties to a speck rather than breaking — no NaN, no crash — and Home returns the camera to
where it started. A stated limit, not an imposed one.

**Clip planes follow orbit distance** (`camera.distanceNear`/`distanceFar`, at 1/400 and 20
times it). Derived rather than stored, so they cannot go stale — a stored pair set once at
construction keeps its original value through every dolly, which is exactly the bug this
replaced: the far plane sat at a fixed 400 while the orbit limit was then 500, so dollying past
400 clipped the whole scene away, and well before that a line's own far end came back inside
the frame and read as stopping in mid-air. Both scale together, so the frustum keeps its
shape and depth-buffer precision — a function of the far-to-near ratio — stays constant
instead of decaying as the camera pulls back.

**Furniture** (ground grid, world axes) reaches `extent_furniture`, computed from that far
clip (`extentFurnitureFor`), and is drawn as **fog about the eye** rather than as a halo
about the world origin. `fogFurnitureFor` solves the two radii, both measured from
`DrawExtent.eye`: full strength within `FRACTION_GRID_FADE_START` × extent, gone by
`FRACTION_GRID_FADE_END` × extent. `addGrid` lays lines on world multiples of the cell size
that fall within the ground disc the fog leaves — radius `sqrt(radius_gone² − height²)`
about the point below the eye — and cuts each into `SEGMENTS_GRID_FADE` pieces fading
per-vertex (not per-piece, so GL interpolation stays smooth) by each endpoint's own distance
from the eye. The two lines through the world origin are skipped, coinciding with the X/Y
axes and depth-fighting them. Axes use standard convention (x red, y green, z blue).

Fog, not a halo, because a halo makes the origin a place the reader may not leave: panning a
hundred units away left no ground at all, and the camera read as bounded to a region though
only its orbit distance ever was. **Verified by rendering it**: an eye a thousand units from
the origin now stands on lit ground, with the axes correctly gone.

The **cell size is fixed at `SIZE_CELL_GRID` = 10.0**, replacing a size that doubled with the
reach until at most `CELLS_GRID_HALF_MAX` cells covered it. A stepping cell re-scaled the
ground under a reader as they dollied, so no distance read off it was comparable with the
last; a fixed cell is a ruler. What the doubling was protecting against — a reach that
follows the camera laying lines without limit — is now handled by capping the *reach* at
`CELLS_GRID_HALF_MAX × SIZE_CELL_GRID`, which keeps the outer edge a fade rather than a cut.
A hundred-unit cell was tried first and rendered: at the opening placement the reach is ≈72
units, so it put at most one line in view and usually none, and the ground read as empty
until the camera pulled back past a distance near 30.

`CELLS_GRID_HALF_MAX` = 120 follows from that cell, and the number that matters is the
**capped reach**, 1,200 units. Content sits at the target, one orbit distance from the eye,
so ground stays under it exactly while that cap exceeds the orbit distance. The cap was 24
while the cell was 100; dropping the cell to 10 without raising it left the cap at 240, and
at an orbit distance of 300 the grid rendered as a patch floating in the near field with no
ground at all under the objects being looked at. Where the cap binds it costs ≈23,000 ribbon
vertices against `VERTICES_MAX` = 49,152, which world furniture has a mesh set to itself.

**Past 1,200 the ground stops reaching the content**, which an orbit distance may now do
since it has no ceiling (below). Measured: at 900 the view is a full lattice with the axes
and the scene on it; at 2,000 the scene is a speck with the fog's own disc left behind near
the eye. That is the price of a fixed cell, and it is a limit rather than a bug — the
alternatives are a cell that re-scales, which was rejected, or an unbounded line count.

The **fade fractions were re-tuned with the move to the eye**, 0.03/0.12 → 0.06/0.20, and
the two sets are not comparable: a radius measured from the origin reached that far *past*
the content, while the same radius from the eye is spent getting to it. 0.06 is 1.14 orbit
distances, which puts what the camera is looking at inside the solid core; 0.20 is 3.8, which
puts the fog's edge about 2.8 distances beyond it and still a fifth of the far clip. Both
numbers came from rendering the alternatives: at 0.03/0.12 the ground at the target was
faint enough to read as absent.

The grid is additionally **dimmed by `ALPHA_GRID` = 0.75** where it is built. Width alone
(1.5 px against a line's 2.5) was not carrying the difference between reference and content.
Applied in `addGrid` rather than to `Ink.Grid`, which is also `INK_POOL_FREE` — dimming the
palette entry would make a scene object taking that colour translucent. 0.55 was tried first
and rendered a ground that read as absent rather than as recessive; the grid's colour already
sits close to the backdrop, so opacity spends fast.

**The world axes are reference, not geometry, and they are drawn that way.** Readers kept
taking them for drawn lines. Measured against the source rather than judged: an axis was the
only piece of furniture with *no* distance fade, running to 0.95 of the far clip at full
alpha, while the ground grid faded out at 0.12 — so an axis was the longest and brightest
mark in any frame. Width already separated them (1.5 px against a line's 2.5, compile-time
asserted) and clearly was not enough on its own.

Two changes. The axes now fade and cut off on **the grid's own schedule**, so all the
furniture ends at one horizon and reference reads as a neighbourhood around the *reader* —
this deliberately reverses an earlier decision to let them reach indefinitely, which bought
orientation at any zoom and cost the confusion above. Each axis is drawn over the chord of
the fog sphere it crosses, so one the camera has flown clear of contributes nothing; the
cost, accepted, is that beyond the fog nothing marks where the origin is. And the three hues
are **dimmed and desaturated**, through `axisTinted` at compile time from
`MUTE_AXIS_TOWARD_GREY` (0.22 → 0.45) and a new `SCALE_AXIS_LUMINANCE` (0.50). Those
constants were previously documentation only — the blend was hand-applied into the literals
and nothing read the constant, so the number and the colours it described could drift apart.
They are the source now.

**The dimming was settled by the palette gate, not by eye.** A first attempt at 0.62
luminance read well and *failed* `tools/check_palette`: dimming had walked the green and
blue axes onto `Rose`'s own luminance and the pairs collapsed under red-green deficiency at
3.5 and 3.3 ΔE against a floor of 4.0. Going further down clears it, the axes landing below
every categorical hue rather than among them — the rare case where the accessible answer and
the quieter one coincide. `check_palette` also gained the floor nobody had: furniture against
`Backdrop`, since dimming has an obvious other end and nothing was watching it (axes now
15.7–25.3 ΔE against a floor of 8.0).

**Muting.** `mesh.muted()` blends a colour toward its own luminance
(`MUTE_DESATURATION` = 0.6) rather than replacing it with `Ink.Grid.colour`, which made a
muted object indistinguishable from the ground grid; `FRACTION_DIMMED_ALPHA` = 0.55 so
muted objects read as present background context, not washed out.

**Draw sizes** live in `mesh.nim`, not in `renderer.nim` where they are actually handed to
OpenGL: `SIZE_POINT` 9.0, `WIDTH_LINE_FURNITURE` 1.5, `WIDTH_LINE_OBJECT` 2.5 px, with a
`static: doAssert` that object lines exceed furniture lines so reference geometry recedes.
`marker` derives every marker's own clearance from them and cannot import `renderer`, which
binds straight to OpenGL — so one shared home, read by both render paths, replacing the
copy `browser_bridge` used to carry.


Ribbons
---
**Every line is drawn as a quad, never as `GL_LINES`.** A line width is a hint a target is
entitled to ignore: most WebGL implementations clamp `gl.lineWidth` to one pixel outright,
and core-profile OpenGL only ever guaranteed one. So `WIDTH_LINE_OBJECT` (2.5) and
`WIDTH_LINE_FURNITURE` (1.5) meant nothing in the browser — scene lines and reference
furniture drew identically there — and worked on the desktop only because Mesa is generous.
`mesh.addSegment` now builds the width as geometry, so both builds draw the same thing and
neither asks a driver for anything.

Each end is offset half a width along `directionAcross` — the normal of the plane joining
the segment with the eye, which is the direction that shows as sideways from where the
camera stands — scaled by `worldPerPixelAt` at *that end's own depth*. Offset proportional
to depth is what makes the on-screen width constant: the quad's straight edges then
interpolate a world offset that stays proportional to a depth which is itself linear along
the segment. Both derivations already existed for a line's own selection rails in
`marker.nim`, which now delegates to them rather than carrying a second copy.

**The near plane has to be clipped against first**, and this is the one part that was not
obvious. A depth clamped at the near plane breaks the proportionality the whole scheme rests
on, and the first frame rendered after the change showed it: a world axis running from far
behind the camera to far in front drew *twenty pixels wide* near the origin. `addSegment`
now moves an end that stands behind the near plane up to it, along the segment, blending its
tint by the same fraction; a segment entirely behind is dropped. A great circle drawn around
the eye loses about half its segments to this, which is why the suite checks a count it
computes rather than one it assumes.

`GL_LINE_SMOOTH` went with `gl.lineWidth`, and a 1.5-pixel quad with nothing smoothing it
rasterises only where it covers a pixel centre — the whole ground grid read as dotted.
The desktop now asks for a 4-sample framebuffer and **falls back to none if no visual
offers it**: `llvmpipe` under `xvfb`, which every headless capture here runs on, refuses the
window outright rather than downgrading, and a visualiser that will not start is worse than
one whose thinnest lines alias. The browser context already asked for `antialias: true`.

`VERTICES_MAX` went from 16,384 to 49,152, because a segment that was two vertices is now
six. The binding case is a scene filled to `ITEMS_MAX` with planes: 64 x 97 ribbons x 6 =
37,248, which the old bound would have asserted on. The suite builds exactly that scene
rather than trusting the arithmetic. Costs about 4 MB per `MeshSet`, of which there are two.

**Measured, on the desktop, by counting lit pixels across a drawn line** and correcting for
the angle it runs at: a scene line asked for 2.5 px measures 2.39–2.73 px, and reference
furniture asked for 1.5 px measures 1.29–1.52 px — each constant along the line's own length
as it recedes, which is the property that fails if `worldPerPixelAt` is fed the wrong depth.


Selection And Picking
---
`visualiser/core/selection.nim`, shared: an ordered fixed-capacity list of slots, held as a plain
value type like `History` beside it. **Order is the whole point, and the reason it is a list
rather than a set** — an operation reads its operands positionally, so the first slot picked
is `m` and the second `n`. `impliedArity` lives here too: one pick names a unary operation,
two or more a binary one. Both UIs read that rule rather than restating it, which is what
keeps the drawer's `apply` section and the browser's floating menu from disagreeing about
what a selection means.

**A selected object is drawn over every other object, until it is deselected.** It is the
one being worked on, and a plane's wash tinting it or a line crossing in front of it is the
view arguing with the reader about what they just asked to look at. The mechanism is one
watermark per mesh — `mesh.Mesh.index_overlay`, an `Option[int]`, set once per frame by
`markOverlay` between the ordinary objects and the selected ones — and then two draws per
primitive instead of one, the tail with `GL_DEPTH_TEST` off. **`Option`, not a sentinel of
zero**: an index of zero legitimately means "all of it is the overlay", so a mesh nobody
marked has to say *none*, and getting that wrong drew every line of world furniture over
the whole scene. A watermark rather than a third `MeshSet`, because a set reserves
`VERTICES_MAX` per primitive up front — the largest single reservation this build makes —
for a run that is usually one object; order already decides what these buckets look like, so
an index into that order costs nothing and says the same thing.

**The overlay is a second pass over every primitive kind, not a tail on each one.** The tail
was written first and measured: a selected line came out over the other lines and *still*
tinted by a plane's wash, because the wash is a later kind and the overlay run, having no
depth test, writes no depth for that wash to be rejected against. On the desktop that showed
up as the selected line's own pure-ink pixel count falling from 2,626 to 1,106; with the
whole ordinary set drawn before any of the overlay it is 2,626 again. Verified on the
browser too, where the marker and its comet are SVG outside the canvas and the WebGL frame is
still once the tweens settle: with two crossing planes selected, **15,668 pixels** change
against a **0**-pixel noise floor between two identical shots — and **0** on the build before
this change, where selecting altered nothing the canvas drew.

**On the desktop, a mark on an object draws beneath the panels, not over them.** Dear ImGui
offers two overlay layers: a background list beneath every window and a foreground list above
them all, both above the 3D scene OpenGL has already rasterised. Every overlay call used the
foreground one, so a selection ring, a hover ring, a line's rails, a plane's loop and the
drag band all floated over the panel — including when the panel was covering the very object
being marked. Reported by the user, and visible in the committed storyboard, where the
selected plane's marker circle crossed the objects list. They are on the background list now;
`gui_shim.overlayList` is the one place that choice is made. **The drag menu alone stays
above**, since it is a control being steered rather than a mark on anything, and a wedge the
reader is reaching for should not slide under chrome. `guiOverlayCircle` takes the layer as a
parameter because it is the only call serving both — a marker's full ring through
`guiOverlayArc`, and the menu's own centre dot. Measured on storyboard frame 02: marker
pixels drawn inside the panel's rectangle fell from **3,453 to 3,059**, and frames whose
marks never crossed the panel are pixel-identical.

Selection is deliberately **not** part of `Scene`: never saved, never recorded on the undo
timeline, and cleared outright by a successful undo or redo, since a restored snapshot's
slot numbers need not match what was picked against the live scene. `pruneDead` runs after
a removal, because a freed slot goes straight back to the next add and a pick left behind
would silently reattach to an unrelated object.

"Just built" and "currently selected" are one concept with one mechanism, **one marker per
selected slot** in both UIs, plain white, 2.0 px, and every construction path replaces the
selection with the slot it just created. Hover draws the identical marker at 80% opacity —
weight is the only thing that tells the two apart, so hovering a line previews exactly what
selecting it will draw.

`marker.nim` shapes that outline to what it marks, because a marker says "this one" best
when its own outline echoes the thing it surrounds:

| Shape | Marker | How it fills |
|-------|--------|--------------|
| Point | Circle in screen space about the drawn point. | Sweeps clockwise. |
| Line | Two segments flanking its projection, one each side. | Runs out from its support. |
| Plane | A circle lying *on the plane*, outside its rim. | Opens from the disc's centre. |
| Line at horizon | Two small circles of the sky it circles. | Closes in from a quarter turn. |
| Plane at horizon | The viewport's edge, inset by the gap. | Expands as a circle from the middle. |
| Point at horizon | Circle, about the fixed star it draws as. | Sweeps, as any point does. |

The last two had no marker at all until this round, on the reasoning that an object drawn
fixed to the eye offers nothing to surround. That was the wrong conclusion from a true
premise: what a marker surrounds is *whatever is drawn*, and both are drawn. A horizon line's
bands are built from the same normal and spanning pair `mesh.addLine` builds its great circle
from, so the three wrap the sky as one family; they settle at the very gap a finite line's
rails keep, read as an angle through `mesh.radiansPerPixel`. They arrive by closing *inward*
because a horizon line has no support to grow outward from — and the horizon plane's frame
opens *outward* from the middle, which is what tells the two apart while they fill.

**The horizon plane's frame is an expanding circle that becomes the screen edge.**
`markerFrame` samples a closed polyline: at each angle the boundary radius is `progress ×
half-diagonal` or the distance to the inset viewport edge along that angle, whichever is
smaller. So it is a circle for as long as the circle fits, and then *becomes* the edge piece
by piece as the circle passes each part of it — the four edge midpoints first, the corners
last, since full reach is the half-diagonal and that is exactly the corners' own distance.
Scaling a rectangle about the centre instead, which is what shipped first, reached every
edge simultaneously and read as a shrunken copy of the screen rather than as something
opening out into it. `SEGMENTS_MARKER_FRAME` = 64 even angular steps, a multiple of four so
the edge midpoints are sampled exactly, plus the four corner directions merged in by angle
(`CORNERS_MARKER_FRAME`): a corner missed by a fraction of a step is a corner visibly cut off
the finished frame, and nothing else needs extra sampling because a sample on a straight edge
lies *on* that edge by construction. Measured in a 900×800 view: 68 points, radius flat at
296.8 px at half progress (a circle), 394.0–445.2 px with 20 points on the edge at three
quarters, and 394.0–593.6 px with all 68 on the edge when finished — read back off the live
`<polygon>` the browser overlay strokes, not off the core alone.

**On touch every marker swells clear of the finger** (`clearanceTouch`): a fingertip covers
what it presses, so a marker filling underneath one says nothing to the person filling it.
54.5 px, added rather than multiplied so one number means the same on a point's 10.5 px ring
and on a plane's rim hundreds of pixels across; it takes the ring to a **130-pixel circle**,
about twice a thumb's contact patch, so the halo stands outside the hand rather than at its
edge. Zero throughout for a mouse, which hides nothing.

**The swell runs on its own clock, in four phases** (`interaction.swellHold`): it grows over
`SECONDS_SWELL_GROW` (0.12 s), sits at full through the whole fill, **stays there for as long
as the finger is down past maturity**, and settles over `SECONDS_SWELL_SHRINK` (0.15 s) once
the finger lifts. Only the middle two phases have anything to do with the fill. It was a half
sine over the fill instead, which put the marker back at its true size at exactly the moment
the selection landed — shrinking while the reader was still deciding, and gone when it
mattered. `progressHold` now starts *after* the grow, so the marker is already at the size it
will fill at before it begins filling and the fill keeps its whole half second; a press is
0.62 s end to end rather than 0.50. Measured on a Pixel 5 in CSS pixels, sampled against the
real clock: 10.5 → 58.2 → 65.0 through the grow with the fill still at 0, flat 65.0 across the
fill, still 65.0 at 2 s and 10 s past maturity with the item already selected, then 64.9 →
17.3 → 10.5 through the settle.

That last property forces a rule the overlay breaks nowhere else: **the swollen marker is
drawn even once its slot is selected**, and the plain selected marker for that slot is
skipped. The plain one is the very size the swell is animating away from, so drawing it too
would snap the outline at the moment the selection lands. The browser therefore keeps the hold
past maturity rather than cancelling it, and retires it only once `isHoldSpent` says the
settle is over. `cancelHold` still snaps away without settling — that is a press which
*stopped* being one (moved into a camera gesture, a second finger, escape), and there is
nothing left for a settle to be about. `isHoldSpent` is stated against `swellHold` rather than
against the shrink duration a second time, which is `isHoldMature`'s own rule and necessary
here: subtracting two large timestamps measured 0.14999999999997 against a 0.15 s shrink.

**One notation, everywhere.** A drag used to name what it built in ASCII — `a ^ b`, `a v b`,
`a -> b` — while the panel named the identical pair through the catalogue's own symbols, so
one object list carried both spellings of the same operation. `commitChoice` now names and
messages its result through `scene.notationSubstituted`, the very call the panel's apply
button makes, so the two paths produce byte-identical labels. The storyboard's own step
captions took the real symbols with them.

**A picker offers symbols alone** (`scene.notationSymbolic`), not the whole catalogue entry:
`𝐦 ∧ 𝐧`, not `𝐦 ∧ 𝐧  wedge (join)`. The English name is three to five times the width and
pushed the selection menu's popover past what a hand can reach on a phone; it stays in the
table for tooltips. The **drag wedges keep their words**, which is the opposite decision on
purpose and was measured rather than assumed: rendered, the projection's own notation
`𝐧 ∨ (𝐦 ∧ 𝐧☆)` is nearly twice the width of "project", so symbols widen the one menu that is
read under a thumb. A picker is a list read at leisure; a wedge is a target.

**A picker opens on what was last applied at its own arity** (`scene.OperationMemory`),
defaulting to attitude for one operand and wedge for two. Per arity because the two lists are
disjoint — a unary choice cannot carry across to a binary picker, and falling back to the head
of the list there would undo the memory for the arity that did not change.

**Every apply control ghosts its own answer while the reader is still choosing it**, rather
than waiting for apply — the rule the edit session already follows on a keystroke and the
drag's rubber-band beside it. `scene.Preview` is the one statement of a construction not yet
committed: the geometry, the anchor its disc will be drawn about, and the operand slots it
came from. `previewApplying` builds it from a scene and two slots, and the drag's own
`Interaction.preview` is the same type built by the same call, so those two cannot drift.

Reaching all four paths took three fixes, not one:

- **The desktop had no preview at all**, in either its drawer's apply section or the
  selection menu's picker. `Panel.preview` is cleared once a frame by `layoutPanel` and
  written by whichever apply control is on screen; a closed section simply never writes,
  which is the whole of "shown while choosing" without a flag saying so.
- **The browser drawer's preview ignored its operands and never cleared**, so choosing an
  operation left a ghost standing after the section collapsed. It also passed each operand
  picker's *position* where a scene *slot* was wanted — the apply button beside it had
  always translated through `nimSceneSlots`, and the preview had not, so the two named
  different objects whenever the two orders differed.
- **A previewed plane sat at its support**, and jumped to its creation anchor when apply
  landed. Fixed by the anchor `Preview` now carries, the same way the drag's ghost was.

`staged` (`panel.staged`, `browser_bridge.staged`) decides which of the two claims shows
where both stand: **the session wins**, since it is being typed into while a preview is a
passive reading of two pickers. Stated once per front-end rather than at the mesh and the
camera separately. Driven: 6,076 vertices without a preview, 6,160 with, before apply is
pressed.

**The preview is framed together with the operands it names.** A result judged without the
objects it was applied to is half a picture, so `Preview.operands` travels with the geometry
and `framing.watched` yields those slots beside it. An open edit session names none, and
must not: its staged geometry *replaces* the object selected beside it, and framing both
would frame the edit against its own former self. Measured on the built page — the camera
pushed to distance 9 with both operands far off screen (a at x = 8417, b at x = 17831),
then the apply section opened: the view pulls back to 13.39 and both land inside the centred
box, at (464, 542) and (1015, 344). The selection menu's own picker does the same.

**Every seed point takes its own hue.** The startup scene gave `a`, `b`, `c` and `o` one rose
between them, which says they are one kind of thing — the opposite of what a categorical
palette is for, and not what adding them by hand would do. **Two of the five categorical
slots are reserved by hand and the other three are cycled**: `ground` keeps
`INK_SEED_GROUND`'s olive and `o` keeps `INK_SEED_ORIGIN`'s copper, for the same reason in
both cases — those are the two seeds that are not arbitrary (one is what every later step is
derived against, the other is the origin), so both are worth recognising without reading a
label. `a`, `b` and `c` take exactly the three that are left, so nothing collides and no
`Ink` is spent twice.

**A drag band swells into its head** (`marker.cometFor`), because a drag is not symmetric —
`a ∨ b` and `b ∨ a` are different operations and the line drawn for either was identical. The
last `LENGTH_MARKER_COMET` of the band thickens to `WIDTH_MARKER_COMET` at the point it aims
at — the same length, the same width and the same `ribbonAlong` as the orientation pulse, so a
reader meets one vocabulary for direction instead of two. **Fixed pixels, not a fraction of
the band**: a fraction would grow the head as the drag went further, and the head is the part
carrying direction — driven at 61, 125, 200 and 277 px of drag, the head held its size. A band
shorter than the comet lights all of itself rather than reaching back past the object the drag
started on. None where the cursor rests on its own source, which points nowhere. The browser
aims it from the *core's* cursor rather than the one the presentation layer holds — both come
from the same pointer events, but only one can be the answer.

**Orientation is a pulse travelling round the selection marker, and the shaft is gone.** A
plane used to draw a bare normal shaft out of its anchor, *always*, on every plane in the
scene, to answer a question a reader asks about one object at a time; a line had nothing at
all. `marker.markerFor` now runs a short lit run along a selected object's own outline
(`SEGMENTS_MARKER_PULSE` points spanning `LENGTH_MARKER_COMET` of it, travelling at
`SPEED_MARKER_PULSE`), and **which way it travels is the orientation**.

The run **tapers**, from `WIDTH_MARKER_COMET` at its head down `FALLOFF_MARKER_COMET` to
`WIDTH_MARKER` at its tail, so the head reads as the front rather than the run reading as a
bar. It ends at exactly the outline's own width, which is why the tail needs no cap and no
alpha ramp: it merges into the line behind it, and only the head is an edge. The constants
were chosen from thirteen variants drawn side by side on a plane's circle and a line's rails;
against 2.8 px and 4.5 px heads, and against 1.6 and 2.4 falloffs.

**The run is `LENGTH_MARKER_COMET` pixels long, not a share of the outline**, and it is walked
by arc length to make that true. A fraction made the mark's size a property of the thing it
annotates: measured, 96 px along a line's rail against 334 px round a plane's circle seen
close up on a phone — a compact comet on one shape and a long gradient on another, from one
constant. Stepping by *index* rather than by pixels would have left a second version of the
same fault, since perspective bunches a tilted circle's points on its far side. Both shapes
now measure 64 px, and so does the drag band's head; `FRACTION_MARKER_PULSE` survives only as
a cap, for a marker smaller than the run itself, where a fixed length would light most of the
outline and leave nothing plain to read the lit part against.

**What the comet carries is a distance in pixels from the object's own anchor, and that
is the second fix here.** The first (below) stopped the phase being recomputed from the
clock; it did not stop the phase being turned back into a *place* by multiplying by a
view-dependent length. `samplePulse` did `head = phase*total`, where `total` was the
outline's screen arc length that frame and the ruler's zero was the outline's first point
— and for a line's rails that first point is **where the rail crosses the edge of the
window**, from `fractionLeavingView`. Both ends of the ruler were the camera's answer, so
holding the phase constant could not hold the head still. A reader reported it, having been
told in this file that the residual was motion the marker was entitled to; they were right
and that claim was wrong.

`PulseClock` now carries `travels`, advanced by `SPEED_MARKER_PULSE*seconds` with **no
camera quantity in the advance at all**, and `PulseTrack` names a view-independent point to
measure from: a line's own support, a ring's own angle zero. `originAfterCut` walks that
angle-zero point back through an eye cut, because `markerLoop` and `markerBands` re-pick
their first emitted point when the near plane slices them — the same fault as a rail's
clipped end, checked rather than assumed.

**The travel is reduced into the current lap every frame, and that is load-bearing rather
than tidy.** An unbounded travel read back as `travelled mod lap` amplifies a one-percent
change in the lap by however many laps have accumulated, which is the original teleport in
new units. Reduced each frame the amplification is exactly one.

**Measured on the shipped browser build**, orbiting at four rates from still to 0.05 rad a
frame, sampling the head every frame: the comet's advance *from its own anchor* is **62.4,
61.7, 62.5 and 63.3 px/s** against the 60 it is asked for — flat across every rate, which
is the property the reader asked for. Absolute screen motion of course rises with the orbit
(73, 83 px/s medians) because the line itself is sweeping and a mark on a moving object
moves with it; the anchor-relative figure is what separates the two.
**The residual, stated plainly:** at the two faster orbit rates a tenth of frames still show
a large step (p90 236 and 388 px/s anchor-relative). Those are laps and clip transitions,
not drift, and they are not yet explained to the standard the medians are. A theory that the
shared rail window was making the lap too short was tried and **measured to change nothing**,
so it was reverted rather than kept as a plausible-sounding fix.

A suite case now shapes one marker at 45 placements and asserts the head sits exactly the
carried travel from its anchor, to within a pixel. **No such case existed**, which is why a
sliding comet shipped twice: `markerOf` pins one camera, so every pulse case was blind to
the only thing that was wrong. `Marker.anchors_pulse` exists so that invariant can be
asserted from outside the module at all.

**The phase is carried between frames, not computed from the clock.** A phase read off the
time has to be `frac(now·speed ÷ around)`, and `around` changes whenever the camera moves:
after a few laps that quotient is tens of laps, so a one-percent change in the outline's
length throws the answer most of a lap and the comet teleports. Measured on the build that
did it — orbiting, the head moved a **median of 11.15 px a frame against the 1.0 it should**,
and all ninety sampled frames exceeded twice the honest step. `selection.PulseClock` carries
one phase per slot instead, advanced by `speed·dt ÷ around` each frame, so a camera change
alters the *rate* and never the position. After: the head's step while orbiting has a median
of 3.76 px and a **worst of 4.01** — worst and median together, which is what "no jumps"
looks like — and of that, 3.06 is the marker itself sweeping under the comet, which is motion
the marker is entitled to.

It is **frame-rate independent** by construction and by measurement: the same three seconds
of clock moved the head 178.3 px at 36 fps, 179.0 at 60 and 179.6 at 144, against 180. A gap
longer than `SECONDS_STEP_PULSE_MAX` is treated as an absence rather than a frame, so a
backgrounded tab resumes where it left off instead of spending the whole absence in one step
— measured, 83 px in a frame before that cap and 1 px after.

**No arena, and no swap buffer.** `arena.nim`'s own header already settles it: the draw loop
asks it for nothing because `Scene` and `MeshSet` are fixed arrays with their own lifetimes,
and this is the same shape — one float per slot, a compile-time bound, alive as long as the
program. An arena earns its keep on variable-sized short-lived scratch. Two further reasons:
`arena.nim` is desktop-only and unreachable from the browser build, so an arena-backed pulse
would serve one front-end and leave the other needing a second mechanism; and a swap buffer
resolves read-last-while-writing-this, where this update reads and writes one slot and
consults no neighbour.

**And it travels at a speed, not a lap time**, for exactly the same reason: one lap per fixed
4.8 s made how fast the mark *moves* a property of the outline too — measured, 156 px/s along
a line's rail against 348 px/s round a plane's circle seen close up, so the same signal read
as a drift on one shape and a scurry on another. `SPEED_MARKER_PULSE` is 60 px/s, which is the
speed the lap was chosen at: the specimens it was judged on were about 300 px around, and one
lap of those in 4.8 s is 62 px/s. Driven, the comet crosses the browser at **61.3 px/s on a
line and 61.3 px/s on a plane** — the same signal on both, which was the point. The phase is
therefore a question about a particular outline rather than one answer shared by every marker,
which is why `phaseAdvanced` takes the length it laps.

**A selected line went a whole round with no comet at all, and the round's own verification
missed it.** `nimSelectionPulse` returned *before* advancing the clock when no run came out,
and every slot's phase starts at exactly 0 — at which `samplePulse` clamps rather than wraps
on an **open** outline, so a line's rails produced nothing, so the clock was never advanced,
so the phase stayed 0 for ever. A plane's loop is closed, wraps at 0, and never entered that
deadlock; that asymmetry is the whole reason planes pulsed and lines did not. Two things let
it ship: the number quoted above was taken on the **desktop**, whose `drawSelectionMarker`
advances right after shaping and was never affected, and the suite shapes a marker directly
and so never asked what a caller did with `around`. The advance now belongs to "this slot was
drawn this frame". Measured against the shipped build: a selected line reports **0 runs, ever**
before and **2 runs at 61.3 px/s** after. The suite case that would have caught it asserts a
rails marker at phase 0 still reports a positive `around` — an empty run and an unmeasured
outline are different things, and only the second is a fault.

That taper is why each run is a **closed outline to fill rather than a path to stroke**: a
stroke carries one width for its whole length. `ribbonAlong` wraps the sampled spine in both
sides plus a rounded head cap, once, for both render paths — a ribbon worked out twice is a
ribbon that drifts, and neither Dear ImGui nor SVG offers a varying-width stroke to hand it
to. Each point's normal comes from its own neighbours on the spine rather than a second sample
an epsilon away, which at either end would fall off the run. A run cut short by the end of an
open arc spreads its taper over what survives, so it is a shorter comet rather than the front
half of one.

The desktop fill needs a **fixed winding**, which `gui_shim.guiOverlayRibbon` imposes rather
than the caller: Dear ImGui's antialiased fill offsets each edge by `(dy, -dx)`, outward for
one winding and inward for the other, and a ribbon handed to it the wrong way round comes out
with the whole transparent fringe under the fill. That was measured, not guessed — a column
across the mark stepped 16 to 248 with nothing between, where every other overlay stroke ramps
through it. It cannot be settled once at the call site, because the pulse's winding flips with
the very orientation it reports. SVG needs none of this.

Nothing computes that sense. A plane's loop is generated around the plane's own frame, so the
*projection* decides whether that order comes out clockwise or anticlockwise, and the pulse
reverses of its own accord as the camera crosses the plane. Measured by orbiting past
`ground` and taking the sign of the swept angle about the outline's centre: +74,393 from
above, −82,167 from below. A line's rails pulse *along*: each rail is **drawn** as two halves
either side of the support but **walked** as one path, from its far horizon through the
support to the near one, so the direction falls out of the walk. A horizon line's bands pulse
round both, sense from the great circle's own normal.

**One comet to a line, not one per piece it is drawn in.** Each of a rail's two halves used to
pulse on its own, so a selected line wore four comets at four unrelated places — four signals
where there is one line with one direction. Walking each rail whole leaves two, one per rail,
and they travel together because both take the phase measured on the first: the pair's
projected lengths differ by a fraction of a percent, invisible in a moment and a slow drift
apart over a long selection. Measured after: the two heads stay within one comet's length of
each other, so they overlap as a single mark crossing the line.

Two shapes get none. A point has no orientation, and its ring's sweep already means something
else. **A plane at horizon has none either**, which was probed rather than assumed: `frame`,
`directionNormal` and `direction` all report nothing for one, and negating it changes none of
that, so there is no sense for a pulse to carry. Only a caller passing a time gets a pulse at
all, which is how "selected" is said — hover and keyboard focus wear the same marker standing
still, so motion means selected rather than merely under the cursor.

The pulse crosses to the browser as `nimSelectionPulse`, its own call rather than a tail on
`nimSelectionMarker`, whose format promises the points are "whatever is left"; appending a
second array behind them would make that false for every kind at once. It costs shaping a
selected item's marker twice, a few dozen projections against a whole frame of mesh.

`CLEARANCE_MARKER_TOUCH` was 24 px, sized against a 44-pixel *minimum* touch target and
reported here as clearing a fingertip; it did not, and the correction came from a thumb rather
than from the suite. The measurement behind the old number compared framebuffer pixels against
a CSS-pixel target — see the two-layer rule below, which had to be fixed before "bigger" meant
anything stable.

All three keep the same clearance, `GAP_MARKER` = 6.0 px, between the object's own drawn
edge and the marker, measured out from the size that object is actually drawn at. That is
where the point's ring radius of 10.5 px comes from (`SIZE_POINT`/2 + gap) rather than
being written down; a line's rails sit at 7.25 px (`WIDTH_LINE_OBJECT`/2 + gap). Changing
a draw size moves its marker with it.

The clearance is deliberately tight, and the outline deliberately light: `WIDTH_MARKER`
1.5 px (asserted thinner than the line it marks) at `ALPHA_MARKER_SELECTED` 0.9, hover at
0.6. An earlier round drew 2 px of pure white at a 11.5 px gap and it read as a second
object rather than as an annotation of the first — white at full strength is the brightest
thing this palette can produce, brighter than anything it surrounds, which inverts the
emphasis it exists to give.

**A line's rails are two straight world-parallel lines, sized by the widest gap they will
actually show.** Each is one straight line parallel to the one it flanks, offset at the
support, running to the two vanishing points all three share — so all three converge exactly
as perspective says, and a rail's two halves are two parts of one line rather than two
things joined at the support.

What a world offset gives away is that **perspective, not the reader, chooses how far apart
the pair ends up**. `offsetMarkerRail` states a gap at the support and leaves the rest to the
projection, and along the half of a line whose far point lies behind the eye — `clipToEyeSide`
cuts that half back to the near plane, where depth *falls*, so the denominator of
`off*(1 - t)/(k*depth(t))` shrinks faster than the numerator — that is not convergence but a
flare. Measured on the demo's own `a ∧ b`, gap from the support out to each drawn end:

| camera (azimuth, elevation, distance) | one half | the other |
|---|---|---|
| 0.6, 0.2, 19 | 14.8 → 12.9 px | 14.8 → 16.5 px |
| 1.6, 0.9, 19 | 14.7 → **23.7 px** | 14.7 → 7.9 px |
| 0.2, 0.05, 12 | 15.3 → 11.3 px | 15.3 → 20.9 px |
| 2.4, 0.4, 30 | 14.5 → **45.6 px** | 14.5 → 0 px |

So `OFFSET_MARKER_RAIL` stopped meaning "the gap at the support" and now means **the widest
the pair may read anywhere**: `markerRails` lays the rails out, measures one rail against the
other at every drawn end (`apartWidest`), and narrows the world offset until the widest
reading meets the ceiling. It only ever narrows, so a view with nothing to spend is drawn
exactly as it always was. The same table after: **14.5 px at the widest and no flare on any
half**, and over a 45-camera sweep the widest reading spans 14.2 to 14.5 — which is the
property the suite now asserts on both sides, since a pair that always reads its stated gap
somewhere can never disappear either.

Three details, each of which cost a round:

- **Settle, do not solve.** Narrowing the pair moves where each rail leaves the viewport, so
  `fractionLeavingView` hands back a different extent and the widest reading moves with it;
  one scale lands about five per cent over. `PASSES_MARKER_RAIL` repeats it, and two passes
  settle every camera of that sweep exactly.
- **Settle against the finished rail, then draw at the progress asked for.** How far apart
  the pair stands is a fact about the line under this camera, not about how far a touch hold
  has got growing it. Settling against the partial rail made the gap widen as the hold
  filled — caught by the case pinning that a growing rail starts where the finished one does,
  which is the only reason it did not ship.
- **Measure one rail against the other, not either against the line between them.** All three
  screen lines meet at the same vanishing point, so a perpendicular dropped from one rail
  lands further along the other; the two measures differ by a few percent where they converge
  hardest, and the one a reader looks at is the one to bound.

**Two rounds went past this before landing on it**, and both are worth keeping as traps. A
*ceiling on the gap at the support* capped where the flare is not — the support reads true at
nearly every orientation — and the table justifying it swept camera **distance** at a single
azimuth and elevation, the one axis the flare does not lie along; its suite case inherited
that camera and passed against a threefold flare. A *constant screen offset* then removed the
flare by making each half's head shed its offset only where it had a vanishing point in front,
which bent every rail at its support: measured, 2.66° and 7.3 px of stray — the whole gap —
at azimuth 2.4, and 0.9 px at the one camera the screenshots were taken from. The suite now
asserts a rail's own straightness over the orientation sweep, which is what neither round
had. **A marker's worst case can lie along orientation, and sweeping distance is not
sweeping.**

A floor under the narrowing was tried too, at four tenths, on the worry that an extreme view
would close the pair onto its own line. It let a **437 px** splay through at a camera eight
units out looking steeply along the line, and the worry was unfounded: a ceiling on the widest
reading is itself the guarantee of visibility.

The gap is continuous as the camera turns, which the settling could have broken — the extent
it reads changes with the view. Driven over a 720-step orbit, the largest change in the gap
between neighbouring frames is **0.103 px**: the rail slides along the viewport edge rather
than snapping across it.

A touch hold widens the pair by `clearance` pixels a side, and the ceiling widens with it, so
a swollen marker is settled by the same rule as a resting one.

**A rail's growth is measured against the edge of the view, not against its own length**
(`fractionLeavingView`). Each rail runs from the line's support to one of the line's two
vanishing points, and those sit at wildly unequal screen distances: measured on the demo's
own `L = a ^ b`, one half's projected length came to 1,140,706 px and the other's to 3,634,
a ratio of 314. Shortening each rail by a fraction of its own length — which is what shipped
first — therefore made one half finish 314 times sooner than the other, and put both wholly
off a 900 px screen within the first percent of the hold. Growing toward a vanishing point
is growing into nothing. Bounding the reach at the viewport fixes both at once: the halves
come out comparable because the same rectangle bounds them, and every pixel of the growth
happens where it can be seen. Re-measured in a 900×800 view: 142 px against 100 px at
quarter progress, a ratio of 1.5. The suite had been green throughout — it checked that a
partial rail lay along the rail it would become, which was true the whole time.

Which way is "sideways" is `marker.directionAcross`, and it stays RGA-native: joining the
line with the eye gives the one plane containing both, and that plane's own normal is
perpendicular to the line and to every sight ray reaching it. The rails then straddle the
very plane the line's screen projection *is*, so the pair reads symmetric about it from any
angle. It reports none where the eye lies on the line — no plane, and no side to flank
from. The cost is that stepping perpendicular to the ray tilts a hair out of the plane
perspective divides by, leaving the stated gap under a percent wide: 7.29 px against a
nominal 7.25, pinned in the suite to a quarter pixel.

`marker.worldPerPixel` turns a clearance stated in pixels into the world offset a
world-anchored marker needs. It measures **depth along the sight axis, not distance from
the eye** — perspective divides by the former, and the two differ by over a percent even
near the middle of the frame, which is a visible fraction of a gap this tight.

**A plane's marker circle genuinely lies on the plane**, traced from the plane's own
spanning frame about the same anchor `mesh.addPlane` centres its disc on — the stored
creation anchor where there is one, so the marker is concentric with the drawn disc rather
than with a support the disc is not even drawn around. Its clearance therefore has to be a
world distance, and `radiusMarkerLoop` sizes it through `worldPerPixelAt` so the gap reads
as `GAP_MARKER` pixels *at the disc's own depth*, the depth a reader judges it at.
Everywhere else around the ellipse the gap foreshortens exactly as the disc does — that
is the point; a constant-pixel ring would sit off the plane and read as floating above
it. Asserted in the suite point by point: a unitized ring point wedged with the unitized
plane leaves 1.1e-15 on the antiscalar, against 1.0 for a control point one unit off.

Markers are described in `marker.nim` and stroked by each render path's own **foreground**
layer — `gui.overlayPolyline` on the desktop (one joined path, so corners do not nick), an
SVG `<circle>`/`<line>`/`<polygon>` in the browser. Never as scene geometry: a loop lying
exactly on a plane would z-fight with that plane's own fill, and a marker that the object
it marks can occlude is not a marker. A circle whose rim crosses the eye plane is cut to
the surviving arc and reported open rather than dropped — a camera close to a large plane
is exactly when the selection still needs saying.

An elaborate 3D-modelling-style outline (oversized silhouette, depth-write off, dedicated
shader uniforms, second mesh set) was built and then **deleted entirely** in favour of this;
do not reintroduce it without being asked. Most WebGL/ANGLE browsers clamp `gl.lineWidth`
to 1px regardless, which is one reason the outline approach could never look right in-browser.

Desktop draws the selection markers from `drawSelectionMarker`, called directly from
`renderFrame` — deliberately **not** folded into `drawInteractionOverlay`, whose first line
is `if not interaction.is_enabled: return` and which is therefore dead during storyboard
capture, where the marker is still wanted. It returns how many it drew, so a probe can
assert that count directly instead of reading pixels; verified 0/1/2/3 against 0/1/2/3
picked.

**Picking** (`picking.pickNearest`, shared): point beats line beats plane, strictly,
regardless of pixel distance, once a shape's own radius is met. That priority is what makes
generous radii safe — a wide point radius overlapping a line behind it still resolves to the
point. `RADIUS_PICK_POINT` = 34, `RADIUS_PICK_LINE` = 24 px, sized against a real
fingertip's contact patch at phone density; a plane's test is area-based (inside the drawn
rim). Tests assert both boundaries (one pixel inside picks, one pixel outside does not) and
all three priority pairings, so changing a constant fails a test rather than only feeling
different.

**Everything drawn is now pickable, horizon included**, ranked point, finite line, horizon
line, finite plane, horizon plane. A horizon line is tested against the great circle it draws
as, sampled the way `mesh.addGreatCircle` samples it. A horizon plane matches every ray, since
it is a dome over every direction — last of all, so anything else under the cursor wins.

That last one costs something the design had to answer rather than discover: **the cursor is
then over *something* almost everywhere.** Scanning a grid over the eleven-step demo, "nothing
hovered" no longer occurs anywhere on screen. And a press on empty space becomes an orbit
*precisely because* nothing was hovered — `beginDrag` failing is the entire mechanism. So the
rule is: **the sky is a click and hold target, never a drag handle.** `beginDrag` refuses it
(the press falls through to the camera, exactly as before) and `destinationOf` refuses it (a
release over it stays "released over empty space; nothing done"). `interaction.is_hover_backdrop`
carries the answer from `updateHover`, where the scene is in hand, so neither has to be handed
a scene. Driven and confirmed on both builds: dragging bare sky turns the view and builds
nothing; clicking it selects it.

Two consequences worth stating. **Clicking empty space no longer clears the selection** when a
visible horizon plane is in the scene — it selects the sky; hiding that object restores the old
behaviour, and the help table's `select` tab says so. And a *tap* still treats the sky as empty
space on purpose: tapping empty space is a finger's only way to dismiss a selection, so touch
reaches the sky by long-press instead — which is where its marker fills anyway. The selection
menu follows the middle of the view for it, since an object filling the sky has no place in the
scene to sit beside; that rule is duplicated by constraint in `visualiser.anchorOfSelection` and
`browser_bridge.nimAnchorScreen`, each naming the other.

A horizon point (a fixed star) keeps the pickable anchor it always had.

**Slot-liveness guards.** Hovered, dragged and selected slots are plain values carried
across frames, not re-picked per frame, so any of them can name a removed item on the very
next frame after a delete. Three guards exist and must stay:
- `nimAnchorScreen` reports "nothing to draw" for a dead slot (the single choke point every
  overlay — selection ring, hover ring, drag line — projects through).
- `interaction.endDrag` and `browser_bridge.nimEndDrag` both check `isAlive` on source and
  destination before reading either label.
- Removing an item clears the highlight on both render paths.


Interaction Model
---
**Which button does what, stated once.** `interaction.revealsMenuOn` says whether a click
brings the floating selection menu with it — right yes, left and middle no — and both render
paths plus `help.nim` read it, exactly as they read `armingOf` for the drag. The left button
used to do both jobs at once, so a reader who only wanted to pick something was answered with
a menu they then had to dismiss, and the menu lived behind the same button that builds.

| Gesture | Does |
|---|---|
| left click | select just that one, dropping the rest |
| right click | the same, and open the menu |
| shift with either | add it, or drop it again if already picked |
| right click, selection standing, menu down | reveal the menu, selection untouched |

That last row is `revealsWithoutPicking(has_selection, is_menu_shown)`, and shift never
reaches it — shift always means "change the selection". With the menu already up the same
click falls through and retargets, which is the way out of having revealed the wrong thing.

**A click has no time limit, and the one it had was a bug.** `isClick` demanded
`now - started < 0.35 s` beside the distance bound. Measured on the shipped page: shift-
clicking three objects with each press held 600 ms picked **none** of them, every release
answering "Released on its own source; nothing done", while the same three at 80 ms picked
all three and a fourth click dropped one back out. The deadline was meant to separate a click
from a press held to open the dwell menu, but the dwell is touch-only and a mouse's wheel
opens on *arriving over another object*, never on time — so it separated nothing and lost
clicks. Distance alone decides now.

**A right press that never moved is a click.** It could not be one before: any drag armed
`Always` was refused a click outright, on the reasoning that it had asked for the wheel. But
the wheel only opens over a target *other* than the source, so such a press never opened one
and there was no offer to withdraw. The test is now on the menu rather than the arming.

**An open wheel lets go when the cursor leaves it.** Past `PIXELS_MENU_DISENGAGE` (150 px)
the menu closes, the drag stops being latched to that destination, and travelling on to
another object opens it there for the original source with the new target — re-aiming, never
chaining. A target just let go of is held at arm's length until hover leaves it, or
`MenuArming.Always` would re-open the menu on it the very next frame and disengaging would
only ever move the menu.
  The radius is sited off a measurement, not off `PIXELS_MENU_REACH`: the furthest wedge
corner sits **103.9 px** from the centre, read off the drawn rects in the browser over six
different pairs, leaving 46 px of clear air. **This bounds `choiceAt`'s overshoot, which was
deliberately unbounded** ("overshooting a wedge still picks it, which is what makes a fast
confident throw work"). Both cannot hold; being able to re-aim was chosen, with the user.

**The drag wears the colour it will build.** `inkOfDrag` keeps its three states — neutral
over empty space, the reserved magenta over a pair that makes nothing, and now the *scene's
next hue* over one that works, rather than the operation's own. The operation is already
named on the wedge and in the label; the colour was the only place the answer could be shown
and it was spent saying something already said.
  `Scene.index_ink` carries how far the cycle has been walked, with `inkNext`/`takeInk`/
`skipInk`, because `inkCycled(scene.len)` cannot move for an object that was never added —
and **every released construction steps it**, built or not, so a colour the reader watched
for a whole drag is not offered again. A click does not step it (selecting is not
constructing) and neither does `More` (the construction is still in flight, and the apply
picker takes the hue the wheel previewed). Undo restores it with the rest of the scene, so
undoing a build re-offers that hue; loading a scene sets it to the item count. The file
format is untouched.

**Desktop / mouse and pen.** Drag from an object onto another to derive a third. **The
press target chooses the scheme; the button chooses whether you are asked.** Press an object
and you are constructing; press empty space and you are moving the camera (left orbits, right
pans, the wheel zooms at the pointer). Left then takes the algebra's own answer on release;
right opens a four-way choice menu instead. Both buttons reach the same choices, so this is
redundancy for different expertise rather than a mode split — which is exactly why it is safe
where the button-per-operation mapping it replaced was not.

**A mouse never waits.** `interaction.MenuArming` is three-valued — `Never`, `OnDwell`,
`Always` — rather than the "forced" flag it replaced, because a flag could only say *now* or
*after a wait* and the left button wants neither: a menu opening under a hand that paused
mid-gesture is the classic dwell-menu failure, and the left button is where nearly every
drag is spent. So left arms `Never`, right arms `Always`, and `OnDwell` is reachable from no
button at all. **It belongs to touch**, which has no second button to ask with and would
otherwise lose `meet`, `project` and `more…` entirely during a drag — that consequence is
the whole reason the flag became an enum instead of just being deleted.
`interaction.armingOf` states the button mapping once; `visualiser.armingFor` maps SDL
button numbers and `browser_bridge.nimDragKindForButton` maps DOM `PointerEvent.button`
numbers (0/1/2, a different numbering for the same three buttons) into it, while
`nimDragArmingOnDwell` names the one arming no button carries so `glue.js` writes no ordinal
of its own. `SECONDS_DWELL_MENU` is **0.75**, and now measures only a finger. It was 0.45
while a mouse could trip it too, which made it a compromise — short enough not to feel like
a wait for a reader who had no other way in. With the mouse deciding by button, the only
requirement left is that a finger which paused mid-drag is not answered with a menu, and a
finger pauses far more readily than a mouse. It also sat *under* `SECONDS_LONG_PRESS`
(0.50), so the two thresholds a stationary finger races were in the wrong order. Timed end
to end through real CDP touch on a Pixel 5 profile: **0.63 s → 0.93 s** from the last
movement to the wheel appearing, the extra ~0.18 s in both being the 50 ms poll granularity
and the frame loop's own latency under SwiftShader.
**Middle is unbound**: `project` used to live there, which put a third of the vocabulary
behind hardware most trackpads lack.
A plain click selects instead of dragging; shift-click toggles into a multi-selection; a
plain click on empty space clears it. The press over an object has to start a drag
*eagerly* — the press target chooses the scheme — so whether it was a click is only
answerable at the release, and `interaction.isClick` answers it there: the press has stayed
inside `PIXELS_CLICK_SLOP` (6 px) and lasted under `SECONDS_CLICK` (0.35). Both bounds lived
in `glue.js` as `MOUSE_CLICK_MAX_MOVE`/`MOUSE_CLICK_MAX_MS` while only the browser had a
click to disambiguate; the desktop had none at all, so its own help table described a
gesture it did not have. Six pixels, not `PIXELS_TAP_SLOP`'s twelve: a mouse on a desk does
not roll, and a fingertip's allowance would swallow the short deliberate drags between two
objects that overlap on screen. The stillness reading is **latched, and false until a press
raises it** — a pointer that swung out and came back is still a drag, and a caller that
never announced a press (a test driving `beginDrag` by hand) gets the behaviour that
predates clicks rather than a spurious click.

**The gesture clock is seconds**, on whichever monotonic clock the caller owns, and it is
the same reading `scene.addItem` stamps a birth with. It had to be said out loud: the
durations were named `MILLISECONDS_*` for the browser's `performance.now()`, the desktop
passed seconds against them, and its dwell menu therefore needed 450 *seconds* to open and
never had. Found while wiring the click rule, which needed the same clock to be right.
`glue.js` now divides once, in its own `now()`, and passes that everywhere.

**What a drag builds is read off the operands, not off the button.** `∧` adds grades and is
drawable when the sum ≤ 4; `∨` adds antigrades and is drawable when the sum ≥ 4. Measured
over every ordered pair of point, line and plane — with two disjoint families of operands in
general position, points off the moment curve (t, t², t³), where "no three collinear and no
four coplanar" is a Vandermonde theorem rather than a hope:

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

**At most one of join and meet is ever drawable**, so `proposalFor` is a plain priority
order (Join → Meet → Project) with no tie to arbitrate. That property is what the whole
design rests on, so the suite pins it exhaustively along with every cell of the table.
Two consequences the first design got wrong: `plane → point` offers **nothing at all**, so
`proposalFor` genuinely returns none and a release on such a pair refuses rather than
inventing something; and the table is **asymmetric** (`point → plane` projects, `plane →
point` makes nothing), so drag direction carries meaning — an argument for the preview
rather than against it.

A first measurement of that table was invalid: it crossed a point lying *on* the line it was
paired with and read zeros that came from the fixture, not the algebra. General position is
what makes a zero here mean something, and it is why the suite's `GENERAL_FIRST` /
`GENERAL_SECOND` are separate from the random `POINTS`/`LINES`/`PLANES`, whose `LINES[i]` is
built out of neighbouring `POINTS` and is therefore incident with them.

**Self-revelation.** The drag was the weakest of the three ways to build something, for one
reason: it showed nothing. The panel lists every operation and the selection menu shows
what applies, but a drag's whole vocabulary lived in a button mapping the reader had to have
been told. So the drag now *shows its answer before committing it*: `interaction.preview`
holds what a release **right now** would build, drawn as a ghost in `INK_GHOST` through the
same `addObject` dispatch an open edit session's ghost uses — one "not committed yet"
appearance, not two.

**The ghost answers for the wedge being aimed at.** `preview` was `proposalFor`'s own answer
whatever the wheel was doing, so a reader reaching for `project` watched a ghost of `join`
and only learned what they had asked for after letting go — the module claimed "one rule,
drawn and then obeyed" while `endDrag` resolved through `choiceAt` and the preview did not.
`updateDrag` now resolves `proposal` in `endDrag`'s own order — `choosing()` where a wheel is
open, `proposalFor` where none is — and `choosing` is the single statement of which wedge the
cursor is in, read by the preview, by the release and by both front-ends' highlights, which
each asked `choiceAt` separately before. The wheel is opened *before* that resolution rather
than after, or the frame it opens on would ghost the plain-release answer while the wheel
already stood over the cursor's own centre, which chooses nothing.

**Three things a release can do, so three tints.** `ReleaseEffect` names them —
`Nothing`, `Refused`, `Builds` — and `inkOfDrag` is a case over it: neutral `Ink.Guide`,
`Ink.Invalid` magenta, the new object's own hue. The two-way test it replaced could not
carry the wheel: with one open, the centre and a greyed wedge both have no answer and want
*opposite* feedback, since one calls the gesture off and the other would be refused. Driven
on the built page over one wheel, at 1440×900, reading `nimDragTint` at each stop:

| cursor | wedge | band |
|---|---|---|
| the wheel's own centre | none | `(0.286, 0.322, 0.400)` neutral, no ghost |
| `𝐦 ∧ 𝐧`, offered | join | next object's hue, ghost is the line |
| `𝐦 ∨ 𝐧`, greyed | meet | `(0.612, 0, 0.722)` magenta, no ghost |
| `𝐧 ∨ (𝐦 ∧ 𝐧☆)`, offered | project | next object's hue, ghost is the point |
| `…` | more | next object's hue, no ghost — the picker takes that hue |

That magenta is what the palette reserved a slot for and had no use for until now; it is
never leaned on alone, since the ghost simultaneously fails to appear.

**Everything that meets an object on screen meets it where it is drawn.** `mesh.anchorFor`
takes an item's stored anchor beside its geometry and reads it exactly as `addPlane` and
`marker.markerFor` do — a plane's disc is centred on its creation anchor, every other shape
ignores one. The rubber-band's start, its comet's aim, and the floating selection menu's own
follow all go through it, on both front-ends. Before, all three answered from the plane's
closest-to-origin *support*: on this project's own demo scene those stand 0.5, 2.7 and 3.7
world units apart from the drawn centre against a disc of radius 8, which is **13.7 px** for
`ground` at the home camera — a band leaving from a point that is nowhere on the circle.
Confirmed on the built page: `nimAnchorScreen` for `ground` now returns (712.9, 512.8), the
projected creation anchor, where the support projects to (720.0, 501.1). `pickNearest` still
meets the ray against the support's disc; that divergence predates this and is left alone.

**The ghost lands where the object will.** `Interaction.preview_anchor` is set beside
`preview` from the same `scene.creationAnchor` call the commit itself makes, and both render
paths hand it to `addObject`. Without it a ghosted plane was drawn about its support and
then *jumped* to its creation anchor the instant the release landed — the one moment a
reader is watching it hardest. The suite holds the property directly, checking the ghost's
anchor against the anchor the created item ends up carrying rather than re-deriving either.

**The choice menu.** Four wedges at fixed compass points — join north, meet east, project
south, `more…` west — with unoffered ones drawn greyed rather than packed out, because a
menu whose items move is one nobody learns to reach without reading it. **A wedge is the
floating selection menu's own button, moved**: same surface (`--surface-raised`), same
hairline `--border`, same 8-px radius, same 12-px semibold face, and the same `--accent`
border on the one in force that `.btn.on` and `.help-tab.on` wear. The two are one control
in two postures — one reached by dragging, one by picking — and they used to look like two
things to learn. Verified by reading both out of the live page: wedge fill `rgb(27,33,43)`,
stroke `rgb(42,50,61)`, radius 8, font `600 12px "Noto Sans UI"`, label `rgb(231,236,241)` —
identical to `.selection-menu button`'s computed style in every one. On the browser the
wedge takes those from the same CSS variables that menu does, so there is nothing to keep in
step; the desktop copies the tones into `visualiser.drawChoiceMenu` with the siblings named,
exactly as `gui_shim.guiButtonToggle` already had to.

**A wedge says what the picker says.** `interaction.labelOf` returns
`scene.notationSymbolic`, so the wheel offers `𝐦 ∧ 𝐧`, `𝐦 ∨ 𝐧` and `𝐧 ∨ (𝐦 ∧ 𝐧☆)` — the
picker's own text, in `--ink`, with `--accent-ink` on the wedge in force. `More` takes a
bare `…`: beside three pieces of notation a word is the odd one out, and no operation is
written with an ellipsis. The words survive in exactly one place, the drawer's own legend,
which prints each beside its symbol (`interaction.wordOf` and `labelOf` on the desktop, the
`.drawer-intro` markup in the browser, each naming the other as its sibling) — a wedge
reading `𝐦 ∧ 𝐧` is only legible to someone told once that it is `join`.

The wheel kept words for one round on a measurement that turned out to be the wrong one:
the projection's notation is indeed near twice the width of `project`, but it sits at
`Compass.South`, clear of the two wedges the width could have collided with, while `more…`
→ `…` takes 31 px off the *east–west* axis that actually sets the wheel's width. Measured on
a 320 px phone, rendered:

| wedge | words | notation |
|---|---|---|
| north | `join` 44.9 px | `𝐦 ∧ 𝐧` 53.6 px |
| east | `meet` 52.6 px | `𝐦 ∨ 𝐧` 53.6 px |
| south | `project` 63.3 px | `𝐧 ∨ (𝐦 ∧ 𝐧☆)` 92.0 px |
| west | `more…` 62.9 px | `…` 32.0 px |
| **whole wheel** | **209.8 × 182 px** | **194.7 × 182 px** |

So the symbols made it **15 px narrower**, not wider. Moving a choice to a different compass
point is therefore a decision about its label too. **One release rule:
a release commits whatever is under the cursor.** `endDrag` resolves the wedge itself
through `choiceAt`, rather than each render path resolving it, so the two cannot disagree
about where a release landed; back at the centre (inside `PIXELS_MENU_DEADZONE`, 26 px)
commits nothing, which is also why a dwell menu is safe to open unasked — it opens *centred
on the cursor*, so a reader who did not want it is already in the deadzone. The menu
**latches its destination** when it opens (`destinationOf`): reaching out to a wedge
necessarily takes the cursor off the item, and a destination read from hover would go none
at exactly the moment the release needs it.

`more…` is the ramp from this gesture to the other twenty-four operations: it builds nothing
itself and instead selects both operands in drag order and opens **the selection menu's own
apply picker**, over those operands, already showing the operation last applied at that
arity. Without it the gesture is a dead end at three operations out of twenty-seven.
It used to open the drawer's apply section instead, and that was the wrong landing: `more…`
is a fifth choice on a wheel that opened under the cursor, and answering it by throwing the
hand across the viewport to a side panel buried the two objects it had just named under
every other control. `panel.openSelectionMenuPicker` is the one proc both the menu's own
`apply` button and the drag's `more…` reach it through; `glue.openApplyPickerOnOperands`
is its browser counterpart. Driven end to end on both builds: the picker comes up on
`𝐦 ∧ 𝐧` with both operands selected and the drawer untouched.

**Flick-marks are impossible on this path**, which is why the menu earns its speed from
fixed positions instead. A marking menu's accelerator is the direction of the stroke, and a
construction drag has already spent its direction reaching the target. The accelerator here
is the right button.

A degenerate construction is **refused**: no item is added and the message names what was
degenerate (Nielsen #5). Without that, a scene fills with invisible slots that still consume
capacity and undo steps. The menu greys the wedges that would be refused, so that path
reaches the refusal only by insisting.

**Browser / touch.** The same invariant reaches touch: **a finger that presses an object
constructs; one that presses empty space moves the camera.** Two fingers pinch to zoom and
pan, and cancel any construction in progress. A long press (`SECONDS_LONG_PRESS` 0.5)
selects an object; once a selection exists, a tap (`TAP_MAX_MS` 350) toggles another in or
out; a tap on empty space clears. Selection is an *ordered* set — first selected becomes
operand m, second operand n.

A press begins as a hold, and the first movement past `PIXELS_TAP_SLOP` is the single moment
it resolves — construction where it landed on an object, orbit where it did not. `beginDrag`
reads the hover reading, so it has to run *before* the cursor starts following the finger;
touch `pointermove` did not update the cursor at all, which is what makes that ordering
available rather than something to engineer. Touch has no second button, so the dwell is the
only way to open the choice menu there. `pointercancel` cancels rather than commits: the
browser taking a gesture over is not the reader letting go.

`PIXELS_TAP_SLOP` moved from `glue.js` into `interaction.nim` when its meaning changed. While
it only separated a tap from an orbit it was a presentation detail; deciding **which scheme a
gesture enters** is the same kind of rule as the two durations it now sits beside. `TAP_MAX_MS`
stayed in JS — a tap timeout really is local.

**Accepted cost:** a finger starting on the ground plane's disc now constructs rather than
orbiting, and that disc covers most of the lower screen. This is the identical trade the mouse
already makes, and the camera is still reachable two other ways, so it is consistency rather
than regression. Measured, not assumed: a point chosen by hand as "empty" for the orbit test
turned out to sit on the disc, which is the cost showing up in the test fixture before it
could show up in anyone's hands.

Touch is also where the dwell's own defect finally bit. The clock restarted only when a drag
*left* a target, so it measured presence rather than stillness; a mouse crosses the screen too
fast for that to matter, but a finger moving continuously for 1.2 s over one object had the
menu open on it mid-gesture, and the construction then released into a menu and built nothing.
Driving it is what found this — the suite was green and the code read fine. `updateDrag` now
restarts `entered` whenever the cursor moves further than `PIXELS_TAP_SLOP` from where it last
settled, with two suite cases: one that a drag which keeps moving never opens its menu however
long it stays on target, and one that a drift smaller than the slop still counts as holding
still, since a dwell any tremor could restart is a dwell nobody reaches.

`g_selection` (Nim) is the sole source of truth in both builds, reached from the browser
through `nimSelectionSlots`/`nimSelectionCount`/`nimSelectionArity` and
`nimSelectOnly`/`nimSelectToggle`/`nimSelectClear`. `glue.js` keeps only a render snapshot
(`slots_selection`), refreshed whenever the selection changes, so the per-frame overlay loop
does not cross the boundary — a cache of Nim's answer, carrying no rule of its own. An
earlier design kept the ordered list in JavaScript because Nim held a single scalar; that
put pick order, the thing that names operands, in the wrong language.

`nimClearHover()` is called once the last finger lifts. Touch has no continuous pointer
position, so `nimUpdateHover` only ever runs at a touch-down point; without this the last
reading sits stale forever and its ring (only 20% dimmer than a selection ring) reads as a
second selected object.

**Selection menu** (both builds, one row, following its anchor object every frame — the
browser through `nimAnchorScreen`, the desktop through `visualiser.anchorOfSelection`, both
projecting the same `mesh.anchorFor` the rubber-band uses): `apply` sits leftmost and
never moves. Pressing it opens an operation
picker to its right via a `max-width` transition on `.selection-menu-reveal`
(`width: auto` cannot animate, which is why a max-width bound is animated instead); pressing
it again commits with whatever is picked. `back` collapses without committing. `hide` and
`delete` are hidden while the picker is open and restored when it closes. `✕` clears the
selection and stays visible throughout. `apply` is hidden entirely for 3+ selected: this
menu has no operand pickers, so it cannot say *which* two of three it would use — unlike the
drawer's `apply` section, which can and therefore stays usable. `hide`/`delete` act on every
selected slot.

`edit` sits immediately right of `apply` and is shown only for exactly one selected object,
since one object has one editor. It opens the drawer and the objects section, starts an edit
session on that slot, scrolls its row into view and hides the menu — the panel owns the
interaction from there — while keeping the selection itself. It shares `openPanelTo`
with the top bar's own `add`, which differs only in opening onto a composing row instead.

The document-level "tap outside closes the menu" listener excludes the canvas, the drawer
and the chip row. It fires on `pointerdown`, before the tap gesture resolves on release, so
including the canvas would clear selection state before the gesture that should use it ran.

The desktop's own copy is `panel.layoutSelectionMenu`, an undecorated `windowBeginPinned`
window over the 3D view laid out from the same rules — the row is `buttonSmall`s and the
picker a `combo` sized to the widest notation offered. It reuses `offerOperationsOfArity`,
`applyPickedOperation`, `beginSession` and `selection.isAllHidden` rather than restating any
of them; `applyPickedOperation` was changed to take operand **slots** instead of positions
in the apply section's own combo lists, since the menu reads its two operands straight off
the selection and neither caller should have to learn the other's indexing.

**It is shown by the gestures that pick and hidden by the ones that build** — not derived
from the selection being non-empty, because every construction path leaves its own result
selected and a menu appearing over each new object would sit in the way of the next drag.
That is the browser's `refreshSelectionMenu`/`adoptConstructionSelection` split, written on
the desktop as `showSelectionMenu`/`hideSelectionMenu`.

Placed `OFFSET_MENU_SELECTION` (46 px) **above** its object, not on it. A Dear ImGui window
makes `gui.wantsMouse()` true wherever it sits and `handleEvent` returns early on that, so a
menu straddling its own object would swallow the next drag off it; the lift also clears the
selection marker drawn around the object. Measured rather than assumed: `--drive-select`
scripts three clicks and then a construction drag off the very object the menu is following,
and that drag builds (`c ^ a gave line`). The menu's screen position is kept between frames
so an object passing behind the camera leaves it where it was instead of flinging it into a
corner.

`--drive-select` also exists because a headless run could not otherwise be caught with the
menu open. It posts to SDL's own queue like `--drive-drag`, splits each gesture across two
frames (hover is recomputed inside `renderFrame`, so a press in the same drain as its motion
reads the previous frame's pick), and sets shift through `sdl3.setModState` — a pushed key
event never reaches the state `SDL_GetModState` reports. Capture one frame *later* than each
step: Dear ImGui hides an auto-sized window for the one frame it measures it in, which cost
an hour of looking at an empty patch of scene.

`--drive-sky` guards the regression making a horizon plane pickable could cause: it drags
across bare sky, which must turn the view and build nothing, and then clicks it, which must
select it. Where the sky is bare it *scans for* rather than hard-codes — which patch of a
window is empty depends on the scene and on wherever the camera was left, and a fixed pixel
would quietly start testing something else the moment either changed.

`--drive-undo` joins the same family, for the one desktop behaviour with no other headless
handle: it drags `a` onto `b` to build, orbits three steps and rises one, then sends Ctrl+Z,
so where undo leaves the view can be looked at. It drags with the **left** button, not the
right: a right release commits the wedge the cursor stands in, and a scripted cursor resting
on its target stands in none of them, so the right button's own release reports "released
without choosing" and builds nothing. Capture frames 6, 10 and 13 or later — 6 and 13 show
the same viewpoint to the pixel, 10 shows how far the orbit went.


Undo/Redo
---
`visualiser/core/history.nim`, shared. Scoped to scene-content edits — add, apply (including
drag and the touch flow), remove, visibility toggle, ink recolour, and an edit session's
`save`. Coefficients, label and ink used to be excluded too, because the widgets driving
them are continuous multi-frame inputs and recording every keystroke would flood the
timeline; the staged edit session (see Edit Sessions) supplies the "edit committed" moment
they lacked, so one `save` records one entry covering all three at once.

One fixed-size array plus one cursor, not separate past/future stacks: an entry is a
`Step {scene, camera}`, and both are plain fixed-size value types (`Scene` is arrays of
`Multivector`/`Label`/`Ink`/`bool`/`float`/`Option` with no pointers; `Camera` is five
floats), so recording is a value copy and `entries[cursor].scene` is always exactly the
live scene. Undo/redo move the cursor and copy back; a fresh edit truncates past the
cursor. Halves the memory of a two-stack design and collapses two invariants into one.
`CAPACITY_HISTORY` = 32; recording past it drops the oldest entry rather than growing.

**The camera rides along; an orbit is never a step of its own.** Each step records where
the view stood when *that step's* edit was made, so crossing a step in either direction
restores that one camera: undo reads it off the entry being stepped away from, redo off the
entry arrived at. Chosen over restoring the camera of the state arrived at, which was the
first implementation and is wrong in a way only running it shows — it hands back whatever
view the *previous* edit happened to be made from, so undoing the first construction of a
session teleports you to the startup view. Driving the browser build found that; the suite
had passed. Not recording an orbit as its own entry is the accepted cost of not needing a
gesture-settle rule (a camera drag emits an event per pixel), and it means **an accidental
orbit is still not undoable on its own**. The first entry's camera is stored but never
restored: no edit leads into the seeded state.

Both front-ends abandon their camera tween on a successful step (`panel.stepHistory`,
`nimUndo`/`nimRedo`). Without it the standing aim — armed by the selection an edit leaves
behind — drags the view straight back off the placement just restored.

Seeded via `initHistory(scene, camera)` wherever the scene is (re)initialised — desktop
startup; browser `nimInit`/`nimLoadDemo`/`nimSceneClear` — so undo never reaches past the
moment tracking began. A successful undo/redo clears the selection unconditionally, since a
restored snapshot's slot numbers need not match. `nimCanUndo`/`nimCanRedo` drive the
browser's disabled-button state. Bound to Ctrl/Cmd+Z and Ctrl/Cmd+Shift+Z (and Ctrl+Y) on
both builds; the desktop reads the modifiers off the key event rather than `getModState`.

Tested by recording to capacity, walking all the way back and forward, and comparing against
the actually-recorded state at every step. `Scene` embeds `Multivector`, whose `==` is an
intentional compile error, so `scenesEqual` compares item by item using `=~` for geometry.
Camera restoration is pinned by a suite case that makes two edits from two distinct
viewpoints and checks both directions across each step, and verified end to end by running:
`--drive-undo` on the desktop and `drive_undo_tween.js` on the browser both build something,
orbit well away, undo, and show the view back where the construction was made from and
holding there while the abandoned tween would otherwise have pulled it off.


Storyboard And Seeds
---
`storyboard.constructSeeds` builds five seeds: `a`, `b`, `c` (each raised 2 units in z, off
the z = 0 ground plane), `o` (the world origin, left exactly at the origin), and `ground`
(a plane joined from three points at z = 0). `o` must stay off `ground` — one step projects
it onto that plane, and a point already lying on the plane projects to itself, making the
step a silent no-op.

`STEPS` is eleven derived steps on top. Both entry points compute the seed count from
`scene.len` rather than a hardcoded constant, so inserting a seed needs no matching edit.
Step indices into the scene are stable once written because the scene grows by one per step.

Both apps open on the seeds alone. The eleven-step construction is reachable as a one-click
preset (`nimLoadDemo` / the desktop's storyboard mode) that populates the scene with
ordinary, fully-editable items — not a separate scripted-playback mode. `nimLoadDemo` stamps
`g_borns` one second apart per step, mirroring `runStoryboard`'s synthetic clock, so the
Objects list's recency sort reads seeds as oldest and each derived step as progressively
newer.

One step (`a ^ ground`) is a grade-4 volume and correctly reports "mixed grade, nothing to
draw" — a point wedged with a plane it does not lie on has nothing to render. That is the
step's documented purpose, not a bug.

`runStoryboard` distinguishes "reached" (this step has happened; true forever after) from
"focal" (the current step's operands and result, plus the step before, for continuity).
Reached-but-not-focal draws muted as background context rather than being hidden — objects
disappearing reads as more confusing than informative. Horizon-producing steps aim the
capture via `azimuthElevationFor(heading)`, a closed-form inverse of the orbit camera's
forward-direction formula (target and distance cancel out), then restore the default view;
no FOV widening — reorienting alone suffices, and no FOV can fix content behind the camera.


Creation-Anchored Plane Centring
---
A plane's rim/fill centres on `scene.creationAnchor(operation, m, n, derived)` rather than
always on its closest-to-origin support, which reads wrong for a plane built from operands
that do not straddle the origin symmetrically. Dispatches on operation plus operand shapes:
`Wedge` of a line and a point centres at the midpoint between the point and its orthogonal
projection onto the line; `ExpandWeight` of a point and a line centres where the line meets
the resulting plane; the three-point ground seed centres on their centroid. Everything else
falls back to the support-based anchor.

Must be computed at construction time and stored — it is not recoverable afterward, since
many different operand sets produce an identical plane `Multivector` which carries no memory
of what built it. Hence `Scene.anchor_overrides: array[ITEMS_MAX, Option[Position]]`, a
rendering hint explicitly excluded from save/load.

All anchor math stays RGA-native (e.g. summing two unit-weight grade-1 points and reading
`position`, which divides by weight, gives the exact average) rather than hand-rolled vector
arithmetic.


Save/Load Format (`.rgascene`)
---
Compact binary matching `Scene`'s SoA layout, **little-endian throughout**. There is no
external spec to match, unlike PNG/GIF which follow their own required endianness, so the
order was a free choice — but it had to be *a* choice, because two builds write this format
and `glue.js` reaches it through `DataView`, which demands an explicit order at every call
and is given `true`. Little-endian rather than big-endian precisely because it is what every
file written so far already contains, so the rule cost no version bump and orphaned nothing.
The desktop converts through `std/endians`, a copy on a little-endian host and a swap on a
big-endian one.

| Bytes    | Field |
|----------|-------|
| 4        | Magic `RGAS` |
| 1        | Format version (currently 3) |
| 1        | Basis count (16 under this build's 4D rigid metric); must match, or the
             file was saved under a different PGA dimension or metric |
| 4        | Item count, little-endian `uint32` |
| per item | Ink (1), visibility (1), label length in bytes (1) + that many bytes of
             UTF-8, then one little-endian `float` per basis term |

**The two builds could not open each other's files at all**, and had not been able to since
the version bump to 2. Three defects, all in the same shape — a value derived in Nim, copied
by hand into JavaScript, and left behind:

1. `glue.js` stamped version `1` and refused anything but `1`, while `scene.nim` wrote and
   demanded `2`. So the browser saved version-2 content under a version-1 label and rejected
   every desktop file, under a comment claiming both directions worked.
2. Labels were written with `String.length` and `charCodeAt` truncated to a byte. Those count
   UTF-16 units and drop everything above U+00FF, so a derived label carrying operator
   notation (`a ∧ b`, `a ⊖ b` — the catalogue's own names) wrote a length shorter than the
   bytes that followed and every field after it parsed from the wrong offset.
3. The endianness above.

Fixed at the root rather than by correcting the copies: `MAGIC_SCENE` and `VERSION_SCENE`
moved out of the desktop-only guard, are exported, and reach `glue.js` through
`nimSceneMagic`/`nimSceneVersion` — so there is no literal left to drift. Labels go through
`TextEncoder`/`TextDecoder`. Found by driving, not by reading: the round-trip suite passed
throughout, because it only ever asked one build to read what that same build wrote.

Only live items are written, **in the order they were created** — which is the whole of what
version 3 added, and the reason it is a version rather than a quiet change: the bytes are
shaped identically to version 2, so nothing but the version number says whether the sequence
a reader walks is the order the scene was built in or merely the order its slots fell in.
Deliberately omitted: slot numbers (meaningless once reloaded — a fresh scene assigns its own
free-list order); a per-item ordinal (it would equal its own position, every time, since the
sequence already carries the ordering); fixed-width label padding (length-prefixed, so the
format does not depend on the writing build's `LABEL_MAX`).

**Creation order is recorded explicitly** (`Scene.orders`, `Scene.count_created`,
`scene.slotsCreated`), not inferred. Slot order stops being creation order the moment
anything is removed: the arena's free list hands the most recently freed slot to the next
arrival, so a removed-then-re-added object sits *before* objects that predate it. Sorting by
`born` was rejected as the ordering key on three counts, each of which happens in practice —
two objects added in one frame share a clock reading; a replayed item's `born` is stamped
into the *future* (below); and a reused slot's `born` is a stale reading until overwritten.
An ordinal counts additions to one arena and answers all three. Cost: two more parallel
arrays, `4 + 4` bytes per slot, on a structure already sized by its multivectors.

**A loaded scene replays its own construction rather than arriving whole.** `born` is still
not written — it is a clock reading meaningless across runs — but a loaded item is no longer
stamped at the dawn of time either. `scene.bornReplaying(index, count, now)` stamps the
`index`-th of `count` arrivals a beat after the last, and `mesh.animationProgress` reads a
`born` the clock has not reached as zero progress, so each object is drawn at nothing until
its turn and then grows in. `SECONDS_REPLAY_STEP = 0.12` is shorter than
`mesh.ANIMATION_SECONDS`, so an object is still growing as the next lands — one construction
unfolding, not a queue of pop-ins. `SECONDS_REPLAY_WHOLE = 2.5` caps the whole arrival by
shortening the beat: without it a full `ITEMS_MAX` scene would take nearly eight seconds and
a reader who just wanted their scene back would be watching a progress bar made of geometry.
One rule, both loaders (`loadScene` and `browser_bridge.nimSceneAddRaw`), for the reason this
format has already been burned by: a beat computed twice is a beat that drifts.

**Every arrival a reader did not build themselves replays** — a loaded file, the demo preset,
and the opening scene both builds start on. They are the same thing to a reader: a
construction handed over whole, and watching it build says what a static arrangement of five
objects does not, that these were placed one at a time and everything else is derived from
them. The two loaders stamp as they add, since they are building the scene anyway and know
each item's position as they go; `scene.replayFrom` is the same rule applied after the fact,
for the two callers that assemble a scene first and only then hand it over. That also
simplified the demo, which had been counting seed and step indices out by hand to reach the
same beat.

**`constructSeeds` deliberately does not stagger**, and the startup paths call `replayFrom`
after it instead. `runStoryboard` calls `constructSeeds` too and sweeps each step's
animation on a clock of its own, which a stagger inside the constructor would fight.
Verified rather than assumed: the whole storyboard — twelve PNGs and the GIF — regenerates
byte-identical to the build before this change.

**Every version ever written is still readable, and that is a promise rather than a
convenience.** A scene file is a reader's own work; a build that refuses it has destroyed it
as surely as deleting it would. `VERSION_SCENE_LEAST` is 1 and should stay 1 — reading an old
version costs a mapping func and a suite case, refusing one costs somebody their scene. What
each older version costs: **version 2**, nothing but the sequence guarantee (a version-2 file
of an untouched scene is byte-identical to a version-3 one but for the version); **version
1**, colours only. `Ink` has since gained a reserved `Invalid` and lost three categorical
hues, so version 1's ordinals name a palette that no longer exists — the structural slots are
unmoved, the five surviving hues shift by exactly one, and `Violet`/`Magenta`/`Cerise` fold
onto hues that exist by the same cycle `inkCycled` walks.

**An old file is upgraded to today's shape, never read in an old build's dialect.** Reading
is written once, against `VERSION_SCENE` alone; everything a past version did differently
lives in one `scene.upgradedFrom<n>` per version boundary, and `scene.itemUpgraded` walks an
item up the chain one step at a time before anything else sees it. `ItemSaved` is the shape
that walk operates on — an item as a file holds it, distinct from the live `Item` handle.
Both loaders go through it, so neither build has a reading of an old version the other lacks.

The rejected alternative is what this replaced: one reader that branched on the version at
each field it touched. It spreads every past decision across the whole reader, so supporting
an old version is paid for again by everyone who edits reading, and the version that breaks
is the one nobody has a file of to notice with. Under the chain, adding a version means
adding one func and leaving the rest alone. The cost is a per-item copy through `ItemSaved`
on the load path, which is not a hot path — a file is read once.

`upgradedFrom2` is an explicit step that does nothing, kept rather than omitted: version 3
changed what the item *sequence* promises, and an item alone carries no sequence. A
version-2 file's order is taken as its creation order, being the closest thing surviving in
the bytes. It is written down so a reader asking what version 2 meant differently finds an
answer rather than a gap. Adding the chain also closed a real hole: version 1's fold had no
upper bound, so any byte at all became some hue. `ORDINAL_INK_HIGH_V1 = 14` now bounds it,
and an ordinal version 1 could never have written is refused as the corrupt file it is —
verified through the shipped browser parser, which reads ordinal 15 in a version-1 file as a
refusal where it previously produced a colour.

The one file this reads wrong is the browser's own: it stamped version 1 onto version-2
content for a while (defect 1 above), and nothing in the bytes distinguishes such a file from
a genuine version-1 one. Read as version 1, its colours come back one hue along; geometry,
labels and visibility are exact, and saving it again restamps it. Reading version 1 as
today's ordinals instead would fix that file and *refuse* a genuine version-1 one outright,
whose `Magenta` and `Cerise` fall past the end of today's palette. **A wrong hue is
recoverable; a refused scene is not** — which is the whole basis of the choice.

`loadScene` parses into a staging scene and replaces the caller's only on complete success,
so a bad path, a foreign file, a wrong dimension, or too many items leaves the existing
scene untouched. Native-only (`when not defined(js)`) — a browser has no filesystem.
The browser reaches the identical format through `nimSceneAddRaw` plus a `DataView`
pack/unpack in `glue.js`; `browser_bridge.nim` exposes raw per-item fields rather than bytes,
since reinventing IEEE-754 encoding in Nim would only duplicate what `DataView` does
natively. What it does *not* expose that way is any constant describing the format — those
are exported and read across, for the reason above.

Checked by cross-reading rather than by round-tripping: a scene the desktop saves is fed to
`glue.js`'s own `parseAndLoadScene` and every coefficient compared, and a scene the browser
saves through its own button is loaded by `--load-scene` and looked at. A round trip within
one build passes under any byte order and any label encoding, which is exactly why it missed
all three defects. A suite case now pins the on-disk bytes of a known float as well.

Version 3 was checked the same way, and the same shape of drift was waiting: the browser
wrote `nimSceneSlots()` — slot order — while stamping the version that promises creation
order. `nimSceneSlotsCreated` was added beside it and `saveScene` moved onto it;
`nimSceneSlots` keeps slot order, since its other callers are combo boxes indexed by dense
position. **Measured on the shipped builds**: a browser scene built as `p0 p1 p2 p3`, with
`p1` removed and `late` added, sits in slots as `p0 late p2 p3` and was written to file as
`p0 p2 p3 late`; loading it back gave `p0 p2 p3 late` with borns 0.000/0.120/0.240/0.360 s
past the load, and the objects were observed reaching full size one at a time. The desktop
was then handed that same browser-written file through `--load-scene` and screenshotted at
frames 2/8/16/24/45: nothing drawn at frame 2, three points at 16 with the first largest, all
six at 45. Hand-built version-1 and version-2 files were fed to both parsers — version 1's
ordinals 4/7/11/13 came back as `Grid`/`Rose`/`Cobalt`/`Copper`, version 2's 4/8/12 as
`Grid`/`Rose`/`Cobalt` — and a file one version *ahead* of this build was refused by both,
leaving the open scene untouched.

**Fidelity, checked field by field rather than by eye.** The round trip above compared
labels, which would pass with every coefficient wrong. The whole sixteen-object demo -- eleven
derived objects, labels carrying `∧`/`☆`, five distinct inks, one item hidden -- was
saved, reloaded and compared item for item in creation order: label, ink, visibility and all
sixteen coefficients, **304 scalar comparisons, exactly equal**, no tolerance. Exact is the
right test here and a tolerance would be the wrong one: these are the same doubles written and
read back, not a recomputation, so anything but equality means the format lost something.

That is still one build agreeing with itself. Across builds: the desktop read the
browser-written file to the same 16 items and the same 304 values, and re-saving it produced a
file **byte-identical** to the browser's, all 2245 bytes -- so the two writers agree on the
bytes and not merely on the meaning. A hand-built version-1 file, written from the format
table rather than by either build so that neither reader is checked against its own writer,
came back identical from both, retired hue folded the same way.

The opening replay was measured the same way. In the browser the five seeds come up spread
over **0.480 s** — four beats of `SECONDS_REPLAY_STEP` — and were watched reaching full size
one at a time from the page's first frames; the demo's sixteen objects arrive over **1.84 s**,
under the cap, with the beat shortened to fit. On the desktop, opening frames 2/10/20/30/45
show the scene building: three points part-grown at frame 20 with `o` and `ground` not yet
arrived, all five settled by 45.


Browser Pipeline
---
`visualiser/browser/browser_bridge.nim` compiles the same shared modules the desktop runs, through
`nim js`. `glue.js` is presentation only — WebGL buffer upload and draw calls, DOM
construction, pointer wiring, `DataView` packing, `Blob` download. Every join, meet,
attitude, support, expansion, projection, pick and drag runs compiled Nim.

**This is the project's central constraint.** An early attempt hand-rolled the demo's vector
math in JS, reasoning that a fixed construction sequence made elementary formulas safe; it
was rejected, because being a testbed for the real library is the point. Anything that
derives a value from domain data belongs in Nim behind an `{.exportc.}`, not in `glue.js`.
Audits have repeatedly found drift here — a grade computed by counting digits in a basis
name, a button-to-operation mapping reimplemented, five render constants hand-copied — each
replaced by an export (`nimBasisGrade`, `nimDragKindForButton`, `nimRenderLineWidths`,
`nimOverlayMetrics`, `nimMenuMetrics`). The choice menu's own wedge label widths are the
one thing measured on the JS side rather than exported: only the browser knows what its own
font actually laid out, and estimating from a character count drifts the moment the face
loaded is not the one the estimate was tuned against.

Where a desktop-only module holds the authoritative value, `browser_bridge.nim` duplicates
it in **Nim** with a comment naming the original (`drawExtentFor`, the render metrics above)
— `renderer.nim` and `visualiser.nim` bind to OpenGL/SDL and cannot compile under `nim js`.
A fix to one copy is not finished until the sibling is checked. One such pair is now gone:
the drag-to-ink table lived in both files, each with a comment telling the reader to check
the other; it moved to `interaction.inkOf`, which both render paths and the desktop panel's
own legend now read.

**Three JS-backend gotchas, all confirmed empirically, all still load-bearing:**

1. `Item` holds `Scene` **by value** under `nim js` (a value parameter's address does not
   survive the call that took it, unlike the C++ backend). Constructing one therefore copies
   the entire scene. The per-frame loop must walk slots with the by-slot `*At` accessors —
   going through the `pairs` iterator measured ~150 ms/frame at 64 items.
2. A `var bool` accessor over an `array[N, bool]`, which an ImGui checkbox binds by address,
   miscompiles under `nim js` whenever the result is consumed as a *value*: the generated
   code indexes a primitive boolean with a stray compound key, yielding `undefined` — falsy
   everywhere. `isVisible`/`setVisible` are the ordinary non-`var` pair that replaced the
   `var`-returning reader this was found on, and both front-ends use them now; the accessor
   itself is gone, so what survives is the rule. `geometryAt`/`labelAt` still return `var`
   and are still correct — they are read by the desktop alone, and neither is a `bool`.
3. `MeshSet`s must live at module scope and be cleared, never re-declared per frame. A
   `MeshSet` reserves `VERTICES_MAX` (16384) vertices per primitive, and `nim js` has no
   stack allocation for a fixed-size array inside a proc — re-declaring measured
   ~90 ms/frame *regardless of item count*, versus ~6 ms hoisted.

`scene.formatMultivector` and `format.nim` bind C `snprintf` and stay desktop-only.
`nimFormatMultivector` calls the library's own `$` directly instead — confirmed by compiling
both that it is pure Nim and byte-identical across backends. The bold Unicode it emits is
fine in a browser; the ImGui font atlas is what cannot render it.

Draw order in `glue.js` mirrors `renderer.nim` and must be kept in sync by hand: furniture
ribbons with normal depth, then scene ribbons and points, then translucent triangles with
`depthMask(false)`. No line width is set on either side any more; see Ribbons below.


Browser UI
---
`visualiser/browser/shell.html` (markup and stylesheet) and its sibling `glue.js`
(presentation), assembled with `browser_bridge.js` by `build_browser.sh` into one
self-contained page.
`shell.html` ends on an opening `<script>` that the two scripts concatenate into, and the
closing tag is appended by the script rather than living in a file that would then not
parse on its own.

Both were untracked for a long stretch, which was an oversight rather than a decision:
neither is generated, and without them the browser target cannot be rebuilt from the
repository at all. What *is* deliberately kept out is the font payload — `shell.html`
carries an `@EMBED:<file>@` token per face and the script substitutes each with that
WOFF2's own base64 data URL, so the tracked source is 26 KB rather than the ~966 KB it
assembles to, and the faces stay vendored under the same rule as `pga` (§ Dependencies).
Family, weight and `unicode-range` stay in the tracked file beside the codepoints they
cover; only the bytes are injected. Verified by assembling both ways and comparing: the
six payloads hash identically and the pages differ only by the comment explaining the
split.

**Two pixel spaces, and each layer works in exactly one of them.** The **render** layer
(`nimBuildFrame`, the WebGL viewport, `gl.viewport`) works in framebuffer pixels —
`canvas.clientWidth × devicePixelRatio`, capped at 2.5. The **interaction and overlay**
layer — `nimUpdateCursor`, `nimUpdateHover`, `nimSelectionMarker`, `nimAnchorScreen`,
`nimDragMenuLayout`, and the SVG whose viewBox they feed — works in **CSS pixels**, and is
handed `canvas.clientWidth`/`clientHeight` to say so. It previously received framebuffer
dimensions and converted marker *positions* back down per point while using every *length*
raw, so a marker's real size scaled with device pixel ratio and any answer to "make it
bigger" was unstable by a factor of the ratio. Asking in CSS pixels throughout deletes the
conversions rather than adding any, and it silently fixed a second bug of the same family:
`picking.RADIUS_PICK_POINT` (34) is now 34 CSS pixels, so a point's real touch target on a
Pixel 5 went from ~13.6 to a measured **34.0** CSS px. Nothing in `picking.nim` changed;
it was always the caller's units that were wrong.

**Chip row** (always visible): brand/drawer toggle, then undo and redo as plain bordered
`.btn` rectangles, axes and grid as a segmented `.toggles` pill, then a `☰` menu button.
The visual grammar is deliberate — a pill shows state you can read at a glance, a bordered
rectangle is a momentary action. Sorting by frequency matters: undo/redo and the view
toggles are reached constantly and must not cost an extra click, while the menu holds only
the genuinely rare file actions (save scene/image, load scene/demo, under `save` and `load`
titles). Below 520px the brand label drops to its mark alone, or five controls plus the full
label overflow a narrow phone. **That breakpoint was 480 and wrong by 39 px**: the row does
not actually fit until 520, so every width from 481 to 519 overflowed. Found by checking the
rename that shortened the label, and measured by sweeping the viewport a pixel at a time
rather than by picking a rounder number — with the old "RGA workbench" label it was 50 px
over, so this predated the rename rather than being caused by it.

**Stacking.** `.veil` (which contains the chip row) is `z-index: 5`, above `.drawer`'s 4 and
below `.selection-menu`/`.top-menu`'s 6. It must be set on `.veil`, not on `.chip-row`:
`position: fixed` always opens a stacking context, so a z-index on a descendant cannot
outrank its ancestor's sibling. Without this the drawer paints over the chip row's buttons
at viewport widths between the 640px bottom-sheet breakpoint and roughly 950px, where the
drawer is a full-height right panel occupying exactly that corner. `.drawer-scroll` gets
extra top padding above 641px so its intro text starts below the chip row.

**Top bar**, outside every section: `add`, the axes/grid toggles and the scene-file
save/load controls. `add` has to be able to open the objects section, so it cannot live
inside it. (On the browser the axes/grid pill and the `☰` file menu occupy the chip row;
Dear ImGui has no equivalent overlay, so the desktop gathers all of it into one bar under
undo/redo.)

**Drawer sections** (alphabetical: apply, diagnostics, objects, view; only `objects`
open by default). Each object row is one line of `[✓] label` + edit/hide/remove buttons,
then `shapeWord: coefficients` on a single line, then the editor when open. The leading
checkbox mirrors the selection highlight, which is single-select on the desktop, so
checking one row releases another. Hidden rows dim to `opacity: 0.45`, independent of the
selection highlight so the two can combine.

**Coefficient grid** (one shared builder, used by whichever row is editing): the 16 inputs
are stacked one flex row per grade, 0 to n, rather than wrapped at a fixed column count
that cuts across grade boundaries. Grade comes from `nimBasisGrade`, so nothing hardcodes
this build's dimension.

The desktop panel (`panel.nim`) mirrors this section for section — same four headers in
the same alphabetical order with only `objects` open, the same coefficient grid grouped by
grade with a live ghost, the same selectable row carrying the item's ink plus inline
edit/hide/remove and one wrapped `shape: coefficients` line, the same 0.45 dimming on a
hidden row, the same recency ordering, the same arity filter, and the same greyed-out
undo/redo. Where Dear ImGui forces a difference:

- **Selection is picked from the object rows, not from the 3D view.** The row checkbox
  toggles membership and the row's name picks that one object alone; the browser gets
  single-select from a plain canvas click, which this build has no equivalent of, so the row
  carries both gestures. Operands additionally stay pickable from named combo boxes.
- **A grade's row wraps explicitly, six cells to a line.** `sameLine` places widgets
  unconditionally with no wrapping of its own, so the grid decides where to break: a new
  line at every grade boundary and again every six coefficients, with cell width divided
  out of `guiContentWidth` so the count holds at any panel width. Six because this build's
  largest grade holds exactly six, which puts every grade on one line and makes the desktop
  grid match the browser's own grade row one for one. A build of higher dimension wraps
  rather than overflowing.
  A basis name sits **above** its cell, not beside it, as the browser's `.coeff-grid` does.
  Beside charges every cell the width of the longest name whether it needs it or not, which
  is what forced the panel out to 680 px and made opening an editor the thing that set the
  window's width; above costs one line of text per grade and lets the panel sit at 440,
  near the browser drawer's own 400. `guiGroupBegin`/`guiGroupEnd` is what makes a name and
  its widget advance `sameLine` as a single item — Dear ImGui has no notion of a labelled
  cell.
  Cells divide the line they are on rather than a fixed sixth of the panel, so a grade
  fills its own row — the scalar's lone cell spans the width, grade 1's four take a quarter
  each. Six is the wrap point, not the divisor. This is the browser's `flex: 1 1 56px`
  written out.
- **An unselected arity segment is filled and bordered, not transparent.** The browser's
  `.toggles` segment is transparent because the pill's own track is what makes it visible;
  a panel drawn straight onto the 3D scene has no track, and a transparent segment
  disappeared into the scene entirely — `binary` read as a caption rather than an option.
  It carries the browser's `--surface` and `--border` tones instead, so both controls still
  read as the same thing.
- **An item row's buttons end flush against the right edge**, as the browser's do, rather
  than following its name — `guiAlignRight` over a run measured with `guiButtonSmallWidth`.
  Names vary in length, so left-packed buttons formed a ragged column that moved under the
  pointer from row to row.
- **Nothing in the panel carries a hardcoded width.** Fields, the frame-time plot and both
  arena bars size themselves from `guiContentWidth`. The fixed widths they used to carry
  were each tuned against a panel that then changed width twice, and every change left
  something stopping short of the edge; `guiPlotLines` was the worst of it, since Dear ImGui
  reads a zero width as its own default *item* width — two thirds of the window — so the
  graph sat at two thirds beside a full-width bar.
- **Names recede and values read.** A control's own name is drawn in the browser's
  `--ink-faint`, and section headers carry `--surface-raised` rather than Dear ImGui's
  default saturated blue: five blue bars stacked were the loudest thing in a panel whose
  job is to sit over the 3D scene without burying it.
- **The row's edit toggle is a small button over session state**, not a `CollapsingHeader`,
  which spans the full remaining width and would push hide/remove onto their own line.
- **Hidden rows dim through a style-alpha push, not `BeginDisabled`**, which would also make
  the row's own show button unclickable.
- **The abandon button needs the Dingbats glyph block.** `✕` is U+2715; the font atlas
  ranges started at 0x27C0 and rendered it as tofu. Widened to 0x2700.

**Diagnostics** shows browser-appropriate stand-ins — frame time from `requestAnimationFrame`
deltas, `performance.memory` where available, live pool slots — rather than fabricating the
desktop build's arena numbers, which describe that build's allocator and have no browser
equivalent worth pretending to.

**The object-pool strip wears the scene's own colours**: an occupied cell is drawn in that
object's ink, a free one in `Ink.Grid`, the palette's recessive furniture colour. It reads
as the scene rather than as an anonymous occupancy count — which slot an object sits in,
and how far `inkCycled` has walked the palette, are both legible at a glance. Both UIs get
the whole strip as one buffer of RGB triples, so neither presentation layer carries a
palette rule: `guiPoolBar` takes `count * 3` floats and knows nothing about occupancy,
and `nimPoolCellColors` hands JS the same array rather than letting it look up inks itself.
Verified by reading the rendered cells back — every live cell matches its own item's ink,
every free cell shares one colour used by no live cell, and adding one object recolours
exactly one cell.

**Handing a file to the reader** — one route, `deliverFile`, for the scene file and the
image alike. It was reported that neither `save → scene` nor `save → image` did anything on
a phone, and that was **two faults presenting as one**, plus a third that hid both:

1. Each path built its own `<a download>` and clicked it **without appending it to the
   document**. A detached anchor's synthetic click is ignored by Safari outright and is
   unreliable elsewhere — which is a phone. The two paths were the same five statements
   written twice, so neither was ever fixed in one place.
2. The PNG was read by `canvas.toBlob` **from the click handler**, a task of its own. The
   context is created without `preserveDrawingBuffer`, so by then the drawing buffer has
   been composited and discarded; `toBlob` then hands back `null`, and the unchecked
   `URL.createObjectURL(null)` threw inside an async callback nobody watched.
3. Neither path had a `try`/`catch` and both toasts were success-worded and unconditional,
   so the page said "Saved 5 object(s)" while delivering nothing. The **load** path, by
   contrast, reported failure two ways. That asymmetry is why the fault survived: the code
   could not tell you it had failed.

The image is now captured **inside the frame that drew it** — a one-shot flag set by the
button, read in `frame()` between the last draw call and the yield, the same
capture-then-yield shape `runStoryboard` uses on the desktop. `preserveDrawingBuffer: true`
was rejected: it makes every frame keep a copy forever, on the device least able to afford
it, to serve a button pressed once in a session.

Delivery then tries three routes in order, and **never asserts a file was written**:

1. **`navigator.share` with the `File`**, where the platform offers one — a phone. It needs
   transient activation, which both callers have, being inside a click. Cancelling the sheet
   is a decision rather than a failure: it says nothing and stops.
2. **An `<a download>` appended to the document**, clicked, removed. The appending is the
   whole of the fix to fault 1.
3. **A link to tap, plus — for an image — the picture itself**, left in a toast that stays
   until dismissed, whenever the page is framed.

Verified by driving, not by reasoning — every claim below is a measurement:

- **Desktop Chromium, unframed.** Both buttons fire a real `download` event. The scene file
  arrives as 675 bytes opening `RGAS`, version 3, 16 basis terms, 5 items; the PNG as
  185,135 bytes opening with the PNG signature. Saved and re-read through the page's own
  load input, the five objects come back in the same creation order (`a`, `b`, `c`, `o`,
  `ground`) — the whole route end to end.
- **The PNG holds the view, not an empty buffer.** A pixel census of the delivered file:
  1000×760, **656 distinct colours**, backdrop 55.6%, plane wash 33.3%, with the axes,
  grid, disc and all five points present. A "did a file arrive" check alone would have
  passed on the blank image fault 2 produced, which is why this one exists.
- **Phone profile (Pixel 7) with `navigator.share`/`canShare` stubbed.** Both buttons take
  the share route and hand it a real `File` — `scene.rgascene`/`application/octet-stream`
  and `rga_visualiser.png`/`image/png` — and no download fires, correctly, since share
  short-circuits.
- **Framed in a sandbox without `allow-downloads`**, which is the artifact's own situation.
  No download fires and none can: measured, **even a genuine user click on a real anchor is
  refused there, in silence**. What the reader gets instead is a toast that says only "A
  900×760 image of this view is ready.", the link, and — for an image — the picture itself
  to press and hold. Drawing a blob into an `<img>` is not a navigation, so it is the one
  route that survives that sandbox; the scene file has no equivalent and cannot be
  delivered there at all.

**The artifact frame refuses downloads, and that is now measured rather than suspected.** An
Android phone in the Claude app reached the framed fallback, meaning the share route had
already failed, and then a real tap on the fallback link did nothing either. Re-running the
framed probe with `sandbox="allow-scripts allow-downloads"` settles who is at fault: in that
frame the automatic anchor fires a real download **and** the reader's own tap fires a second
one. Same page, same code, same tap — only the flag differs. So the anchor mechanics are
sound, nothing of ours swallows the gesture, and **no download route can work in the frame
this page ships in.** For an image the press-and-hold picture remains; for a scene file there
is no route left there at all.

**Every route now reports itself**, in the toast and in the drawer's Diagnostics section:
`framed`, `origin` (opaque or own), `share api`, `web-share` policy, `activation` at the
moment of the attempt, then one line per route. This exists because three rounds were spent
guessing: a download a frame refuses raises no event, and the share sheet's rejection was
being swallowed, so a reader on a phone could only ever report "nothing happened". The
`canShare` gate is part of that fix — it used to be a *precondition*, so a platform with
`share` but no `canShare` skipped the share route entirely and silently.

Two theories about the image path were tested and are **false**; they are recorded so they
are not re-derived from how plausible they sound:

- *An asynchronous `toBlob` spends the transient activation `navigator.share` needs.* It does
  not — the window is about five seconds and spans the task boundary. Measured against a stub
  that refuses unless `navigator.userActivation.isActive`: the existing build passes it.
- *A backgrounded tab strands the capture, since `requestAnimationFrame` stops there.* Did not
  reproduce; tapping and immediately backgrounding the page still delivered the file.

So the capture stays asynchronous and inside the frame loop. A synchronous
`renderFrame` + `toDataURL` in the click handler was written, measured against both theories,
and reverted: with no benefit left it only costs a blocked main thread for the whole encode,
most of a second on a phone-sized canvas. `renderFrame` itself was kept — splitting the draw
out of `frame()` mirrors `visualiser.renderFrame` on the desktop and costs nothing.

**The Android report came back, and it names all three refusals.** In the Claude app the
frame reports `origin: own` -- so it is same-origin, and blob URLs and storage are ordinary --
but `web-share: false` with `share: files no`, `download: no signal`, and `new tab: blocked`.
The frame withholds `allow-downloads`, `allow-popups` and the `web-share` permission policy
together, so **no route from inside it can produce a file**, and no further work on this page
will change that. `canShare` returning false is reported now rather than ending the attempt --
that gate had cost a route twice -- and the toast says the actionable thing: open the page in
its own browser tab, where it downloads normally.

**Deliberately not built**: a route needing no file at all -- the scene as text on the
clipboard, with a paste box on the load side -- which is the only thing that could carry a
scene out of that frame. Rejected because the embedded frame is not where this is meant to be
used; it costs a second serialisation of the format and a load affordance that exists solely
to undo one host's sandbox.

Nothing in this is Nim's to do. The bytes were already correct and tested on both backends;
what failed was delivery, which is `glue.js`'s side of the line by
`REQUIREMENTS.md`'s own split.


Edit Sessions
---
Adding an object and editing one are the same gesture, so both UIs run **one edit session
at a time**, in one of two modes:

|                | Composing (new)             | Editing (existing)              |
|----------------|-----------------------------|---------------------------------|
| Started by     | the top bar's `add`         | the row's `edit`                |
| Backing slot   | none — nothing in the scene | the row's own slot              |
| Row shows      | `save` `✕`                  | `save` `✕` `hide` `remove`      |
| `save`         | adds the object             | writes the four fields back     |
| `✕`            | discards; nothing was added | reverts; the object never moved |

Both stage the same four things — sixteen coefficients, label, ink — and preview through
the same ghost. `hide`/`remove` are absent while composing because neither means anything
for an object that does not exist yet. The composing row renders at the top of the list
(it is the newest thing), and `add` is **disabled while a session is open**, so starting a
second one cannot silently discard the first.

**A session never writes to the scene before `save`.** That is what makes the preview safe:
it stays invisible to `nimSceneSlots`/`nimSceneCount`, and so to undo/redo, save/load and
`picking.pickNearest`. Writing a half-built object into a real slot would break all four.
The row is therefore drawn from session state, not from a slot. Desktop note: passing
`gui.inputText` a pointer into the scene's own label storage would edit it in place, so the
session carries its own `array[LABEL_MAX, char]`.

**Session state is a nested option**, honest about the two modes: `session: Option[EditSession]`
where `EditSession.slot: Option[int]` is `none` while composing — no sentinel slot standing
for "new". In the browser the same state sits at module scope, not on the row: `refreshObjectsUI`
rebuilds every row through `innerHTML = ''`, destroying any closure held there.

**Ghost preview.** Editing any session field fires `nimSetGhost` (browser) or updates
`panel.session` (desktop), drawing a live muted preview through the same
`mesh.addObject` dispatch a real object uses, tinted `INK_GHOST = Ink.Guide` (reusing its
documented "construction helper" meaning). One ghost serves both modes — that is a direct
consequence of unifying the sessions; two independent add/edit previews would have needed
two. An all-zero ghost degrades to "nothing to draw" through `addObject`'s existing
`shape.isNone` branch with no special case. `save` and `✕` both clear it, as do undo and
redo, since a restored snapshot's slot numbers need not match the open session's.

Verified by driving both UIs: editing a coefficient leaves `nimItemCoefficients(slot)`
unchanged until `save`, `nimSceneCount()` is unchanged for the whole composing session,
`✕` leaves the count and the object untouched, and a staged grade-1 point adds exactly one
vertex to the desktop mesh (1964 → 1965) — counted, not pixel-diffed, because animation
drift between two runs pollutes a pixel diff with thousands of false differences.


Operation Notation
---
**One table, `scene.lut_operation_to_notation`, read by both builds.** Each entry is
Lengyel's own bold notation, two spaces, the English name — `𝐦⊖  attitude`. There is no
second table to keep in step: a previous round kept a plain-ASCII desktop copy because the
Dear ImGui atlas carried no astral-plane glyphs, which was a property of the font chosen
(DejaVu), not of the GUI. See Typefaces below.

`scene.notationSubstituted` swaps the bold `𝐦`/`𝐧` for real operand names when a derived
object is labelled. It isolates the symbolic prefix first — the English name after it is
full of ordinary m's and n's — and substitutes through two sentinel passes, so an operand
whose own name contains a placeholder is never re-touched and a template with `𝐧` twice
(the projections) substitutes both. Derived labels therefore never contain bold letters,
which is why `LABEL_MAX` is unaffected.

**Every glyph and its placement comes from that operator's own declaration doc comment in
`pga/operators.nim`/`pga/multivectors.nim`** — never from `pga.nim`'s top-of-file summary
table, whose "Lengyel" column renders several unary operators in a functional shorthand
(`att(𝐦)`, `sup(𝐦)`, `car(𝐦)`) that the declarations do not use. Getting this wrong is a
repeat offence: the table has carried prefix glyphs (`∩m`) where the declaration says
postfix (`𝐦∩`). Verify by extracting codepoints, not by eye — the proper minus sign
(U+2212, not a hyphen) is an invisible difference in a text editor.

The five accented operands use **spacing modifier letters** (`𝐦ˆ` U+02C6 unitize, `𝐦ˍ`
U+02CD left complement, `𝐦¯` U+00AF right complement, `𝐦˜` U+02DC reverse, `𝐦˷` U+02F7
antireverse) rather than the combining marks the same accents also exist as. Rendered, the
combining forms landed to the *right* of the operand rather than over it — Dear ImGui has
no shaper and simply advances by each glyph's own width — and antireverse's tilde-below
came out indistinguishable from left complement's low line. A spacing modifier carries its
own advance, so both renderers place it identically. Caught by rendering all 27 entries at
once and reading them, not by reasoning about the font.

One deliberate exception: `Attitude`'s doc comment reads prefix (`⊖𝐦`) but the table places
it postfix (`𝐦⊖`) on explicit request, for consistency with every other unary entry.


Typefaces
---
**Noto Sans** for UI text, **Noto Serif** for prose, **Commit Mono** for code and figures;
a `STYLE.md` rule, not just this project's habit. All are OFL-1.1 and redistributable with
notice.

No single face covers what the UI writes, so the desktop atlas merges three by codepoint
range (`gui_shim.cpp`, `ImFontConfig.MergeMode`): **Noto Sans** for Latin, punctuation,
subscripts and spacing modifiers; **Noto Sans Math** for the operators and Lengyel's bold
operands; **Noto Sans Symbols 2** for the bulk/weight dual stars and the abandon cross.
`ImWchar` is widened to 32 bits with `-DIMGUI_USE_WCHAR32` passed from `gui.nim` — a 16-bit
`ImWchar` cannot express U+1D426 at all — set as a compiler flag rather than by editing the
vendored checkout's `imconfig.h`, which is never committed and would not survive a reclone.

Coverage was **measured, not assumed**: every non-ASCII codepoint in the source (36 of them)
rendered against each face and compared bitmap-wise against `.notdef`, because a missing
glyph is a box, not an error. That check is also what found the previous font's real bug —
DejaVu lacks `⟑` and `⟇`, so `𝐦 ⟑ 𝐧  geometric product` had been drawing as tofu.

The browser **embeds the faces** as base64 `@font-face`, split by the same `unicode-range`
boundaries the desktop merges on. The maths and symbol faces are declared under the *sans*
family, and `--mono` and `--serif` therefore name that family too, after their own: neither
Commit Mono nor Noto Serif carries one of those codepoints, so without it a bold operand or
a wedge in monospace text falls through to whatever the viewer's system happens to have —
exactly what embedding the faces exists to rule out, and invisible on any machine with
DejaVu installed. Listing the family costs no payload: CSS falls back per character, and a
range-restricted face only ever matches the characters it is declared for.

Embedded rather than named because an artifact page cannot reach an external font host, and
naming a face the viewer might not have installed would leave the two builds looking
different — which is the whole point of the rule. Costs about 940 KB of the ~1.6 MB page.

Faces come from Fontsource (`@fontsource/noto-sans`, `-serif`, `-math`, `-symbols-2`,
`commit-mono`, all 5.3.0) as WOFF2, vendored into `fonts/` — kept locally, never committed,
licence notice beside the copies, fetch commands in `dependencies.list`. The desktop reads
the same Noto families from `fonts-noto-core`; Commit Mono is not packaged at all. All are
OFL-1.1.


Naming And Number Formatting
---
Basis elements are named exactly as the library's own `$` names them — `𝟏` for the scalar,
`𝟙` for the antiscalar, and a bold `𝐞` with subscript digits for the rest — in both UIs and
in the multivector text beside the grid. `scene.lut_basis_to_name` **derives** those names
from the enum rather than transcribing them, so a build of another dimension names its own
elements; a test asserts each entry equals what the library prints for that element alone,
which is what keeps the derivation honest. The rule is a second copy of the one inside
`pga/multivectors.nim`'s `$`, which does not expose it separately — check that one whenever
this is touched. ASCII names (`E423`) were a workaround for the previous font's missing
mathematical bold; the merged atlas removed the constraint, so the workaround went with it.

Magnitudes read to **four significant digits, not four decimal places** (`format.nim`'s
`DIGITS_SIGNIFICANT`), so 3.5 reads `3.5` rather than `3.5000` and 1664 keeps its integer
part. One rule, two mechanisms, because the browser has no C runtime. `appendMagnitude` is
the single entry point and branches inside itself:

- Desktop: `snprintf("%.4g")` into a stack buffer, since it runs once per coefficient, per
  item, per frame, and must not allocate. `guiDragFloat`'s own format string is `%.4g` too.
- Browser: `format.formatMagnitude`, which derives the digits in plain Nim. Every editable
  number goes through it behind `nimFormatNumber` — coefficients and the camera's own
  angles, distance and target — because the desktop draws every one of them with the same
  `%.4g` widget. It allocates one string, which is affordable only because a browser
  rebuilds its number fields when the grid changes rather than every frame.

**`formatMagnitude` derives its own digits rather than delegating.** Measured, not assumed:
`formatBiggestFloat(v, ffScientific, 16)` disagreed with itself across the two backends on
**1655 of 7000** values, so it is no usable primitive to build on. The rule is stated
directly instead — a decimal exponent by `log10`, the digits scaled to `DIGITS_SIGNIFICANT`,
and a **half-to-even** rounding step, which is what C rounds decimal ties by and what Nim's
own `round` does not (it breaks a half away from zero, so 1012.5 reads `1012` here and
`1013` there). Verified over 17,001 values across 25 decades including every exact eighth:
**zero disagreements against C's own `%.4g`, and zero between the backends.**

That divergence shipped, and it shipped because the test that was supposed to catch it —
`magnitudesAgree`, which compares the C path against the Nim path — could only ever run on
the C backend, where it asks the C runtime whether it agrees with itself. **330 of 7000
values** differed between the two front-ends while that test stayed green. The suite now
also runs under `nim js`, and the JS entry point pins the text of the tie cases directly
rather than against a second mechanism.

Both front-ends print a whole multivector through **one writer**, `scene.multivectorText`
over `formatMultivector`, and name a shape through **one writer**, `scene.shapeText` over
`describeShape`. The browser's item list used the library's own `$` for the first of those,
at the library's `%G` rather than at this project's four significant digits, so the same
object read differently in the two UIs; there were four separate transcriptions of the shape
wording. Diagnostics readings deliberately keep `%.*f` through `appendFixed`: a live number
that changes width every frame is harder to read than one padded to a fixed width.

Fixed char storage is read back through `format.toText`, never through `$toCstring`.
`toCstring` casts the storage's *address*, which is exactly what Dear ImGui wants and what
the JS backend has no notion of — measured there, it yields an empty string rather than the
text held, which silently blanked every label a drag produced until the bridge worked around
it by hand. `toCstring`, `buildChars`, `appendInt` and `appendFixed` are now all guarded
`when not defined(js)`, so reaching for one from shared code is a compile error on the
browser build rather than a blank field at run time. Visibility was the same trap in the
other direction: an `isVisibleAt(...): var bool` accessor over an `array[N, bool]` compiled
on both backends and silently wrote to a copy on JS. It is gone; `isVisible` reads and
`setVisible` writes, both plain.

Animation
---
`mesh.ANIMATION_MILLISECONDS` = 350 and `mesh.easeOutCubic` are the one duration and one
curve. A freshly added object grows in over them; the camera tween eases over them; and the
browser reads them across the bridge (`nimAnimationMilliseconds`) into `--anim` / `--ease`
on `:root`, so every CSS transition runs to the same numbers rather than to a second set
written down separately. The CSS curve is `cubic-bezier(0.215, 0.61, 0.355, 1)`, which is
easeOutCubic exactly.

One exception, and it is marked as one: the opening hint is a timed disclosure rather than
a response to anything, and holds for 4 s before a 0.6 s fade. Its delay lives in `glue.js`
alone — a `transition-delay` in the stylesheet ran from the moment the class was added
rather than from load, so the two used to stack and the hint outstayed both numbers.


Camera Aiming
---
`camera.aimIncluding(aim, geometry, scale)` folds one object into what the camera has been
asked to show: a point at horizon contributes its own direction, a line at horizon the first
axis spanning perpendicular to its normal (no single direction faces a whole great circle),
a plane at horizon nothing at all (it fills the sky), and anything finite widens a bounding
sphere by `mesh.anchorFor`'s representative point — the same point the selection ring is
drawn on. A fold rather than a function of one object, so a caller with a whole selection
needs no array to fold over and allocates nothing.

What that aim then asks of the camera is "Framing the whole selection" below.

`camera.CameraTween` carries the camera there, eased. **Retargeting reads the start off the
live camera**, not off the previous goal, which is what makes a goal that moves every frame
— a coefficient being dragged — one continuous chase instead of a restarting jerk. Offering
a goal already held is ignored, so a caller may aim every frame without the ease restarting
forever and never arriving.

Both builds aim from **one rule**, `framing.offerAim`, applied once per frame rather than at
each event: the open edit session's staged multivector if there is one, else every selected
object together. That second clause is what carries applying an operation, releasing a drag
and stepping the storyboard, since each already leaves its new object selected — none of
them needs to know the camera exists. The rule used to be written out in each front-end,
which is exactly the kind of duplication that drifts; it now lives in one module both call.
`runStoryboard` goes through the same rule (`offerAimAt`, for a derived multivector that is
not yet anything a selection could name) but calls `settle`, which lands instantly: a
captured frame must never show a half-finished pan.

That rule is a **standing offer**, re-made every frame for as long as the same thing stays
selected, and every subtlety below comes from that shape:

- The tween **keeps its goal after arriving** and sets `is_arrived`, which is what stops
  `advance` writing to the camera at all. Clearing the goal on arrival instead meant the
  standing offer looked new the next frame and re-armed the ease from wherever the user had
  just panned to, dragging the camera straight back — **panning was dead for as long as
  anything stayed selected**, and returned on deselect. It was reported as a touch bug; it
  was neither touch-specific nor browser-specific, and the desktop had it identically.
- A camera the user moves calls **`abandon`**, not `release`: it keeps the goal and marks it
  done, so the standing offer reads as already answered. `release` is actively wrong here
  and was the first attempt — it clears the goal, so the offer is simply re-made next frame
  and the camera taken straight back. Measured rather than reasoned: a two-finger pan driven
  through CDP moved the target 0.21 units against 4.40 unselected, and it drifted all the
  way back.
- **`release` belongs to the offer's own side**, called when the rule has nothing to aim at.
  Clearing the goal outright is what lets picking the same object again aim at it afresh
  rather than be recognised as already delivered.

`verify_touch_pan.js` holds all four cases with real touch events: pan unselected, pan with
an object selected, a grab mid-ease, and re-selecting after a deselect.

`anchorFor` moved from `picking` to `mesh` to make this possible — `camera` calling
`picking` would close a cycle, and `mesh` is where `DrawExtent` lives and where the doc
comment already pointed ("matching exactly where `mesh.addPoint` draws it").

### Framing the whole selection

The rule (`framing.nim`): on a new creation or a new pick, the camera moves by the **least
of pan, zoom and orbit together** that puts every selected object in view — not at all when
they all already are — where in view means the centred box `camera.reachCentred` shapes:
`FRACTION_VIEW_CENTRED = 2/3` of the frame's height, and two thirds of its width **or its
height, whichever is less**.

**Why the width is capped.** The field of view is vertical, so a fraction of the frame's
*width* is `aspect` times as much world. Measured on the shipped build by driving the
browser page: the acceptance edge stood at two thirds of the way from the middle to the
frame's edge on every axis and every viewport — which is 23.9° off the sight axis across a
1440×900 window against 15.4° down, and 7.3° across a 390×844 phone. One rule behaving as
three. The visible consequence was that **picking an object on a desktop window practically
never moved the camera** while the same pick on a phone did, reported as centring that
"doesn't seem to be working with mouse, only touch". Capping the box's width at its height
makes its reach the same in angle both ways: re-measured after the change, the edge across
1440×900 moved from 0.667 to 0.417 of the half-frame, exactly `2/3 × 900/1440`, and the
vertical edge and both of the phone's stayed where they were.

The cap is **one-sided on purpose**. On a frame taller than it is wide the width is already
the shorter side, so nothing changes and touch keeps the behaviour it had. Taking `min` on
both axes instead would have tightened the phone's vertical band to under a third of its
frame, which nobody asked for.

It was *not* a fault on the mouse path, which was the other live hypothesis: driving the
same pick with a real mouse and with real CDP touch at one viewport gave identical camera
readings on every demo object, at 1440×900 and 390×844 alike. `abandon` is unreachable
between a click and the ease — a mouse press that begins a construction drag returns before
`glue.js`'s orbit branch, and after the release the pointer is out of `pointers`, so a bare
hover returns earlier still.

`camera.reachCentred` is the **one statement of the box's shape**, which `picking`
turns into pixel margins and `camera.halfAngleCentred` into the cone `distanceFitting`
solves. Written twice, those two had already drifted: the cone took the narrower of its axes
while the pixel test took the whole rectangle.

**Pan and zoom are preferred over orbit by construction, not by weighing.** The full move
the least is cut back from carries no turn for a finite selection (target and distance
only), and *only* a turn for a horizon-only one — pan and zoom cannot bring a star into
view. So a finite pick never changes azimuth or elevation, and a star is turned toward only
as far as it takes.

**The cut.** `placementFor` first asks whether everything is already in view *where the
camera stands* — judging that at the centred placement instead was precisely the bug that
swung the view on every pick of something plainly visible. Otherwise it builds the full
placement (centred target, facing angles for horizon-only, bisected least distance) and
searches the least fraction of `camera.toward` — the exact path the ease travels, geometric
distance included — that satisfies `isShownAll`: `STEPS_PLACEMENT_LEAST = 12` even steps to
bracket the crossing, `ROUNDS_PLACEMENT_LEAST = 5` halvings into it (within 1/384 of the
move). Each candidate is verified with the full test at its own trial placement, so the
interaction between a partial pan and a partial zoom — the fitted distance was solved at
the *centred* target — cannot admit a fraction that fails; the step-then-halve
first-crossing shape is what handles the path not being strictly monotone.

Two thirds rather than the whole frame because an object clinging to the very edge is
visible without being what the view is about, and the marker ringing it is half off-frame.

**Three readings, not one, and the split follows what each shape is *drawn at*.**

| Shape | In view when |
|---|---|
| Point | Its dot fits inside the centred box. |
| Line | It merely crosses the centred box. |
| Plane | Its disc is centred in the centred box, and its rim is on screen. |

A point's dot and a plane's disc are both drawn at a size the camera does not set
(`mesh.SIZE_POINT`, `mesh.EXTENT_PLANE = 8` world units), so each is a bounded thing a frame
can hold whole; a line is drawn out to `radius_horizon`, which moves with the camera, so it
has no size to fit and demanding one would mean a camera pulled back until it was a speck.
Each shape is tested against exactly what `mesh.addObject` puts on screen — a line's two
halves clipped to the eye side as `pickNearest` clips them, a plane's whole rim, a horizon
line's great circle, a horizon plane's whole sky. Screen segments meet the box by
Liang–Barsky clipping rather than by sampling: a straight segment either crosses an
axis-aligned box or it does not, and asking exactly is cheaper than sampling densely enough
to be sure of a thin near-miss. A point's box is inset by `INSET_POINT_SHOWN`, half of
`mesh.SIZE_POINT`, so its drawn dot fits rather than only its middle — deliberately *not*
inset by the selection marker, which swells while a touch hold fills, and a box breathing
with a gesture would re-frame the view mid-hold.

**A plane is the one shape whose test splits in two**, because its disc is wide enough that
"fits" and "is what the view is about" want different bounds. Its **centre** answers the
second, against the same centred box every other position answers to. Its **rim** answers
only the first, against the **frame** — inset by `INSET_RIM_SHOWN`, half the width
`mesh.addPlaneRing` strokes it at, so an edge resting on the boundary keeps its whole stroke.
Holding the rim to the box as well was the first attempt and overshot: it threw the camera
from 19 out to 29.9 on the demo's own ground plane where 19 already showed the whole circle,
which was reported as the plane moving too far. Measured across the change, picking that
plane:

| | rim in the centred box | rim on screen |
|---|---|---|
| 1440×900, from the home camera | 19 → 29.90 | 19 → **19** (no movement) |
| 1440×900, dollied in to 8 | 8 → 29.95 | 8 → **15.24** |
| 390×844, from the home camera | 19 → 63.26 | 19 → **42.76** |

The rim lands where it is meant to: at 390×844 it spans x [2, 388] of a 390-wide frame. The
looser rule is **strictly weaker** than the stricter one — a disc inside the box is inside
the frame with its centre centred — so it can never cost more movement than before.

The frame it must fit is the whole canvas, not the canvas minus an open panel. On the desktop
that means a large disc's left edge can pass behind the panel; the centred box avoided that
only by coincidence, its left edge falling near where that panel ends, and teaching the core
where a front-end's chrome sits to preserve the coincidence buys less than it costs.

**Why a plane had to change from crossing to fitting.** Reported as planes not recentring the
way points do — "when clicking on the origin point there's a lot more movement than when
clicking on the ground plane". Measured: at the home camera every seed object was already in
view and cost nothing, but dollied in to distance 8 the ground plane's rim spanned x
[−1367, 2808] and y [288, 4562] of a 1440×900 frame and was still called in view, because
the crossing rule was backed by a sight-axis ray meeting the disc — a disc covering the frame
outright keeps its rim well outside the box, so without that ray a plane filling the view
read as *out* of view. Both halves of that test are gone; what replaced them is the two-bound
rule above, whose rim half is what keeps a covering disc out of view.

**A plane is judged where its disc is drawn, not where its support is.** `mesh.addPlane`
centres the disc on the item's stored creation anchor where it has one (`scene.creationAnchor`
— the construction's own point, not the plane's closest approach to the origin). Measured on
the demo scene, the two stand 0.5, 2.7 and 3.7 units apart on `ground`, `G = L ∧ c` and
`a ∧ L☆`, against a disc radius of 8: judging the support's circle would frame one nobody
sees. So `framing.watched` now yields each object *with* the anchor it is drawn about, and
both `isShownCentrally` and `aimIncluding` take it. Staged geometry yields none, and that is
correct rather than an omission — neither front-end passes an anchor when drawing the ghost.
`pickNearest` still meets the ray against the support's disc; that divergence predates this
and is left alone.

**What the aim is.** `CameraAim` is a *requirement*, not a placement: a bounding
`SphereWorld` over the finite objects, and a merged `heading` for the horizon ones. It is a
pure function of the geometry, which is what lets the standing offer re-made every frame
compare equal every frame — the thing every subtlety below rests on. Horizon objects
contribute no sphere point on purpose: `anchorFor` places a star at `scale.eye`, and an aim
built from where the camera stands would stop comparing equal.

**The sphere is over what has to fit.** The first point *or finite plane* folded in throws
away whatever lines had contributed, and they contribute nothing after
(`CameraAim.is_bound_by_fitted`; which objects contribute does not depend on fold order).
Without this a line whose support happens to stand forty units away drags the view off the
point picked beside it and forces a pull-back to drag that support into frame — measured at
73.8 against a distance of 12 before the rule was added. Where nothing has to fit — a
selection of lines alone — the sphere falls back to their own supports, so the camera still
has somewhere to look.

A plane widens the sphere by its **whole disc**, not by its anchor: `widened` merges balls
rather than points, since a plane bounded by its centre alone leaves the distance search
bracketing from a radius of nothing and never reaching far enough to fit anything. The
swallowing case is written out separately — the sliding arithmetic would push the centre past
the new ball, and two concentric balls give it no direction to slide along at all. The
bracket is loose for a plane on purpose: the sphere holds the disc from every side while the
disc is flat, so a plane seen at an angle needs far less room, and the bisection finds it.

**Distance grows, never shrinks.** Panning alone cannot fit two points spread wider than
the frame, so the eye has to pull back; but a tight selection is *not* zoomed into, because
the reader chose that scale and re-scaling the world on every pick is disorienting in a way
that panning is not. The least sufficient distance is found by **bisection on the test**
(`ROUNDS_DISTANCE_FIT = 8`, 1/256 of the bracket), not by the closed form alone: the closed
form `radius / sin θ` is used only as the upper bracket, since it would over-dolly whenever
a line already crosses the frame. Sound because the test is monotone in distance —
everything converges on the middle of the frame as the eye pulls back. Where even the
bracket fails — two stars facing opposite ways, or a spread the frame cannot hold — the
bracket stands rather than a wrong answer being reported as a right one. It is no longer cut
short by an orbit ceiling: `distanceFitting` pulls back as far as the fit takes.

**Finite framing wins over facing a star.** The angles turn to the merged heading only when
nothing finite was picked. A star behind the reader and a point in front have no placement
showing both, so a star picked alongside a point may stay out of view; there is no
placement that would have helped.

**`goal` and `destination` are separate fields on the tween**, and have to be: `goal` is the
requirement and must depend on the geometry alone, or the standing offer stops comparing
equal frame to frame and re-arms the ease every frame — which is the "panning was dead
while anything stayed selected" bug in a new costume. `destination` is a `CameraPlacement`
(target, distance, azimuth, elevation) resolved once when the goal is armed, against the
camera as it stood then. `advance` eases target and angles linearly and **distance
geometrically**, because distance is multiplicative — the wheel and `FACTOR_DOLLY_PRESS`
both scale it, and a linear ease from 12 to 300 spends most of the visible change in the
first few frames and then crawls.

**Measured on the real page**, not reasoned about. Driving the browser build through
`nimSelectOnly`/`nimSelectToggle`, seven selections × nine starting orientations, reading
every picked object's screen position and the camera's target, angles and distance back
after the ease. Three stages of this rule shipped; the sweep across them:

| | watch one object | centre the selection | least move (current) |
|---|---|---|---|
| worst picked point outside the box | **323.9 px** | 0.0 px | 0.0 px |
| total pan over the 63 trials | — | 277.9 | **97.2** |
| trials moving an in-view selection | — | all of them | **none** |
| orbit turned, finite selections | 0 | 0 | **0.000 in all 63** |
| distance | 12.0 always | 12.0–14.7 | 12.0–13.6, never below |

On the desktop, `--drive-select` frame 5 (a visible point picked) no longer moves the view
at all, and frame 9 (three points) shifts it only slightly to bring the one point at the
box's edge fully inside. The storyboard's horizon captures go through the same rule; a
derived great circle that already crosses the demo angle's box now keeps that angle rather
than turning to face the circle dead on.

**History of the rule, kept because each step answered a real complaint.** Watching one
object left the rest of a selection anywhere, including off screen — the first column.
Centring the whole selection fixed that but swung the view for objects already plainly
visible, because "already shown" was judged at the *centred* placement rather than where
the camera stood — one terse trap: that check must read the live camera, or every pick
moves the view. The least-move rule keeps the in-view guarantee of the second column at a
third of its movement, and restores the horizon least-turn the intermediate rule had
dropped.


Diagnostics Panel (desktop)
---
A closed-by-default section holding: a raw (not smoothed — smoothing hides exactly the rare
slow frame this exists for) per-frame-ms line graph over ~4 s from a ring buffer on
`Panel`; a fill-fraction bar for the permanent arena; a `peak_used` high-water bar for
the frame arena (instantaneous usage reads ~empty almost any time this could sample it,
since carve and reset both happen within one frame); a coloured cell per object-pool slot
plus active/free counts; the pool's fixed memory as "N allocated, M used, per-slot"; and a
total of every fixed reservation the binary makes for itself, computed once in
`visualiser.nim` as the one place that can see every piece.

Two widgets need raw ImGui draw-list C++ (`gui_shim.cpp`): the coloured pool bar and the
arena bars (`ProgressBar` with fill/track colour overridden). An empty ImGui label collides
with the window's own ID and aborts the process — hence the hidden `"##frame_time"` ID. The
arena snapshot must be taken in the shared render function, not the interactive loop, or it
reads zero in every storyboard-exported PNG.


Style Guide
---
`STYLE.md` at the project root: a systems-programmer stance (caller owns memory,
least-powerful construct first, dependencies justified individually, duplicate only what a
real constraint forces), four naming cases applied without exception, a doc-comment
convention (every declaration documented, telegraphic, first line imperative, body comments
naming a step's goal not its mechanism, a summary index never a source of truth), a design
section (no sentinels smuggling absence into a value's own range, no silent identity on
degenerate input, enumerate old behaviour before merging states), and a Nim appendix pinning
existing conventions (`strictFuncs`, `array[EnumType, T]` at runtime, `Option[T]` over
sentinels) as explicit rules.

The codebase was brought into compliance across two audits. Notable outcomes still in force:

- `gif.nim`'s internal `-1`-means-none became `Option[int]`. `browser_bridge.nim`'s
  genuine FFI-boundary cases (`DragResult.created_slot`, `nimDragMenuHighlighted`,
  `nimHoverSlot`) keep `Option[int]` internally and translate through one named
  `SLOT_NONE` at each proc's return — the boundary is where a JS-incompatible
  representation is translated, not a licence to use it upstream.
- `picking.pickNearest` and `visualiser.runInteractive`/`runStoryboard` and
  `scene.loadScene` and `nimBuildFrame` justify exceeding the 60-line default in a comment
  rather than being force-split. `panel.layoutDiagnostics` genuinely qualified and became an
  orchestrator over four helpers.
- `browser_bridge.nim.cfg` pins the same two `pga` defines the browser build previously got
  from undocumented manual flags — verified by breaking one define and confirming the build
  fails at the compile-time assertion naming the correct flags.
- The `when defined(js)` seams in `scene.nim` are documented backend-compatibility
  necessities, not shortcuts. Leave them. What used to sit beside that note — a pair of
  shape/label formatters duplicated in `browser_bridge.nim` — is gone: `nimItemShapeWord`
  and `nimItemLabel` now delegate to `scene.shapeText` and `scene.labelAt`, so there is one
  implementation and the browser reads the words the desktop status line uses.
- `EditSession` owns `geometry`/`stage`, the two directions its staged coefficients and a
  `Multivector` convert between. Both were written out by hand at four sites across two
  files before the audit found them.
- Camera aiming is `visualiser.offerCameraAim`, not a tail block inside `assembleMeshes`:
  where to look is not mesh assembly, and having it there had the staged ghost built twice
  in one function.
- `runStoryboard` tracks which slots a step touched as flags per slot rather than as a
  `seq[int]`, matching the fixed shape `are_dimmed` beside it already had.
- `panel.layoutItem` is an orchestrator over the row's three parts (name, actions,
  description) sharing an `ItemRow` record; `layoutApply` sheds the catalogue filter, the
  selection adoption and the apply itself. `layoutItemButtons` and what remains of
  `layoutApply` justify their length in a comment rather than being split further -- a run
  whose whole width must be measured before any of it is placed cannot be split without
  measuring twice.

**`glue.js` and `shell.html` were audited for the first time** once they became tracked
(see Browser UI): they had never been read against the guide because they were not in the
repository. The naming was uniformly JavaScript-idiomatic camelCase -- 89 data bindings,
none snake_case -- against a guide whose first naming rule is that the case *is* the
signal, adopted "even where the language community differs". Every data binding and
parameter is now snake_case, callables stay camelCase, and the forbidden coined
truncations (`btn`, `cam`, `diag`, `coeff`, `el`, `cur`, `arr`, `lbl`, `opt`, `sel`,
`dist`, `pts`) are spelled out. Shader attribute and uniform *strings* are untouched: they
name GLSL identifiers in the shader source, so only the JS bindings holding their
locations were renamed. Forty-eight lines over the hundred-column limit across the two
files were wrapped.

That rename introduced exactly one bug and the browser drive caught it: a callback
parameter renamed at its use but not at its binding, which `node --check` passes happily
because it is a scope error, not a syntax error. Every control was then driven -- apply,
undo, redo, add, save, both view toggles, a camera field, all four drawer sections, and a
selection through the bridge -- with the scene count checked at each step and no console
errors.

The vendored `pga` library was reviewed against the guide and left unmodified by request.
It is the source of several of the guide's rules and largely complies; known deviations are
mechanical (trailing whitespace, banner spacing, `,` where parameters do not share a type,
a two-tier banner hierarchy in `operators.nim`) plus one substantive: `pga.nim:28` asserts
its own module doc is the source of truth for names and documentation, which is what makes
the notation trap above so easy to fall into.

One library quirk worth knowing: of the four compound operators, only the `★` pair works
infix. `m ∧★ n` compiles; `m ∧☆ n` does not, and must be written `` m.`∧ ☆`n `` (Nim joins
`nnkAccQuoted` children). `pga.nim`'s table presents all four identically.


Dependencies / Vendoring
---
The PGA library is vendored at `pga.nim`/`pga/`, copied unmodified from
[replications][replications] at commit `f8861e0` — **not committed to this repo**. Keep a
local copy in place for building; refresh it only deliberately. Both projects are Prosperity
Public License 3.0.0; `pga/LICENSE.md` names replications as source per the license's
Notices term.

The browser's six WOFF2 faces are vendored the same way, at `fonts/` (see Typefaces).

System packages: `dependencies.list`. Dear ImGui compiles from source, expected at
`deps/imgui`. Needs a Nim from `devel` (uses a `var`-returning index operator release
compilers reject).

**Nothing else is left untracked.** `pga`, `deps/imgui`, `fonts/` and `bin/` are the whole
of what the working tree carries and the repository does not — the first three because
vendoring rules them out, the last because it is build output. Everything consistently
needed to build or test either target is committed: `build_browser.sh` assembles the
browser page from tracked sources plus those vendored faces, and `PROVENANCE.md`,
`STYLE.md`, `REQUIREMENTS.md` and `dependencies.list` are tracked alongside the code.


Hold Feedback, Help And Keys
---
A touch long-press was a 500 ms wait with **no feedback of any kind** -- a `setTimeout` in
`glue.js` and nothing on screen -- so a hold could not be told from a tap that had not
registered. `interaction` now owns it: `SECONDS_LONG_PRESS`, a `Hold`, and
`progressHold`/`isHoldMature` derived from it. The clock moved out of JavaScript because
how long a hold takes and whether one is due are rules about the gesture, and because a
timer that fires on its own cannot draw anything.

**The indicator is the marker itself, drawn part-built.** `markerFor` gained one
`progress` parameter, defaulting to 1, and each outline interprets it in the terms that
outline is read in:

| Shape | Fills by |
|-------|----------|
| Point (`Ring`) | Sweeping clockwise from twelve o'clock. It is drawn at one fixed
  size, so a ring that grew would read as the point swelling. |
| Line (`Rails`) | Both rails running out from the support toward each horizon. |
| Plane (`Loop`) | Its circle opening from the disc's own centre out to the rim gap. |

Rails are shortened **after projecting**, along the screen segment. Scaling the world reach
walks the head back toward the *eye*, because the far end is a point one horizon radius
from the eye along the axis -- that was written first and was wrong. Interpolating on
screen still keeps every partial rail exactly on the line's own projection (both endpoints
lie on it, and a projected straight segment is straight) and is what makes the growth read
as even: a world-space interpolation toward a point that distant spends almost its whole
range within a few pixels of the vanishing point. The plane's circle scales in world units
on the plane, so every intermediate circle lies on it as exactly as the finished one.

**Progress is linear, never eased**, unlike every other animation here. This is a clock
being shown rather than a transition being softened, and an eased clock appears to stall
just before it fires -- precisely where a reader is deciding whether the hold is working.

A line or plane **at horizon** has no marker at all, so a hold on one still fills nothing.
Known, and deliberately not invented around.

Both front-ends carry a `?` in the bottom-right corner, at least 44 px (Apple's guideline;
WCAG 2.5.8 asks 24). It opens the same table, `help.lut_help_entries`, which **both UIs
render** -- the desktop wrote the controls out in its panel and the browser wrote them in a
hint, the two had drifted, and only one could be got back. The construct rows are derived
from `interaction.isMenuForcedBy`, so rebinding a button rewrites the help with it, and a
button that starts no drag (middle) contributes no row at all. Each render path translates
only its own numbering (SDL's and the DOM's differ) into `PointerButton` and asks. The entry
count is asserted against the array length at compile time, which caught a miscount twice.

**Tabbed by how you are working, not by what the control is** — `drag`, `select`, `menu`,
`panel`, `camera`, `keys`. A reader opens this in the middle of one thing, and only that
thing's rows are of any use to them right then. The old grouping was by kind of control and
the whole table rendered at once; it went 18 → 20 → 26 entries across three rounds while the
module's own header still claimed everything in it fit one popup on a phone. It did not: the
desktop panel is `AlwaysAutoResize | NoScrollbar` pinned bottom-right and grows *upward*, so
below roughly 720 px of window height its top rows ran off the screen with no scrollbar to
recover them, and the browser's was a 360 px column scrolling inside 70vh however wide the
window was.

`ENTRIES_MAX_PATH` (8) is what stops a fourth drift, asserted per tab at compile time and
again in the suite. It is a **proxy and named as one**: the real constraint is rendered
height, and a count is what compile time can check. Measured rather than estimated — the
built page driven at 320x568, comparing each tab's `scrollHeight` against its `clientHeight`
— and the measurement is what split `menu` out of `select`: ten rows did not fit, because at
that width the outcome column wraps onto second lines, so a count of rows is not a count of
lines. It sits exactly at what the largest tab holds, so the next row added to a full tab
fails the build; the answer is nearly always to split that tab.

**Every row has to make sense with the rows above it covered up**, because that is how this
is read: a reader opens one tab, finds the line they need, and leaves. Three ways a row
failed that, all found by reading the rendered panel cold rather than by any test — circular
("drag one object onto another" → "make whatever the two of them make"), leaning on its
neighbour ("hold still over the target" → "the same choice, without needing the other
button"), and naming internals a reader has never met ("more… in that choice", "the apply
section", "dolly in and out"). Every row is now written to stand on its own.

What a two-column row genuinely cannot carry — which menu this is, what a wedge is — goes in
`descriptionOf` instead, one sentence above each tab, drawn by `guiTextWrappedAt` on the
desktop and a `<p>` in the browser, both fed from the same `case`. It crosses the bridge as
`nimHelpDescriptions`, its own export rather than a fifth string on `nimHelpEntries`, which
is per *row* and would repeat the sentence once per row of a tab; the two join on the tab
title the rows are already grouped by rather than on a matching order.

One word, one meaning: objects are **selected**, operations are **chosen**. "Choose" was
doing both jobs — the tab now called `select` was about picking objects while "the two of
them choose what it makes" is about picking an operation off the drag wheel — so it said
nothing about which was meant.

Re-measured at 320x568 after all of that, per tab, as overflow of the rows box rather than
by cloning rows into it: `drag` 0, `select` 0, `menu` 0, `panel` 0, `camera` 0, **`keys`
129 px over**. Five fit exactly, two of them only after their descriptions were cut to fewer
wrapped lines — `drag`'s from four lines to two and `panel`'s from two to one, each worth
about 17 px. A count of rows is still not a count of lines, and now a description is worth a
row or two of height as well.

**`keys` is left scrolling on that screen, deliberately.** Its eight rows come to 449 px
against a 320 px box, and fitting them means every outcome under about 39 characters, which
costs `enter`'s "hold shift to add it" and `escape`'s "one step at a time" — the things a
reader cannot discover any other way — on every screen, to serve a 320 px one that has no
keyboard. Two alternatives were tried and measured rather than argued about: stacking each
row's cells into one column made it *worse* (161 px over, because a short action like `tab`
then costs a whole line of its own), and regrouping the keyboard rows onto the tabs whose
work they do — camera keys under `camera`, traversal under `select` — left `camera` 133 px
over and `select` 66 px over. So the cap stays at 8, and what it means has changed: it is no
longer a promise that nothing scrolls, but the bound that forces this measurement to be
re-run. A tab nearing it is a prompt to measure, never to trust the number.

The browser's rows box used to take `calc(min(82vh, 620px) - 82px)`, subtracting a flat
allowance for the tab strip. That was already wrong wherever the strip wrapped to two lines,
which it does on a phone, and a description above the rows made the panel able to grow
taller than the screen. It is now a flex column — the panel caps its own height, the strip
and the description take theirs, and the rows box takes what is left with `min-height: 0` so
it can actually shrink. Nothing about the height is worked out by hand any more.

`guiTextWrappedAt` exists because `guiTextWrapped` pushes wrap position 0, meaning "the
content region's right edge", which in an auto-sizing window is decided by the widest item in
it — a wrapped paragraph is then both an input to that width and a consequence of it. The
help panel already knows the width it wants, so it says so.

The desktop draws the tabs through four new shim calls (`BeginTabBar`/`BeginTabItem` and
their ends) with each tab's rows inside a `childBegin` region bounded to what the window
actually has. That region scrolls, and is the safety net rather than the design: no tab may
ever again lose rows off the top, whatever the window height. Its height comes from
`guiChildHeightForRows` rather than from a hand-picked row height — Dear ImGui's own line
spacing, window padding and border, asked for rather than restated, so a tab is exactly as
tall as its own rows and `panel`'s two do not float in a panel sized for eight. Its
*width* is measured from both columns: a bounded region asked to fill nothing inside an
auto-sizing window collapses to its widest item, and every outcome placed past that by
`sameLineAt` is then clipped away — which is what the first attempt did, and looking at the
capture is what caught it.

The browser draws a wrapping button strip plus `data-path` on every row, with only the rows
scrolling so the strip stays reachable, and the panel widened from 360 px to `min(560px,
100vw - 28px)`. Rows are hidden by attribute rather than rebuilt per tab, which needs
`.help-row[hidden] { display: none }`: an author `display` beats the UA stylesheet's own
`[hidden]` rule, and without that line every tab reported the whole table's height —
measured, and it is why the check compares `scrollHeight` to `clientHeight` per tab rather
than trusting the markup.

Its two columns are **one grid over the whole table** — `.help-rows` is the grid and each
`.help-row` is `display: contents` — because a column has to be one width down the table and
only a shared container can size it from the widest action in it. That is the rule the
desktop panel already follows, where `layoutHelp` measures `offset_outcome` off the widest
action; the browser's flat `44%` was the guess it replaces, and on the 558 px panel it gave
the actions 245 px they did not want while the outcomes beside them wrapped. Measured, both
viewports, wrapped outcomes out of 31 rows: 7 → 1 at 1400x900, tallest tab 213 px → 177 px;
21 → 20 at 320x568, tallest unchanged at 337 px in the fixed 384 px box that sizing then
had. (That box is no longer fixed — see the flex column above — so those two figures are the
comparison that justified the grid, not current heights.)

Both tracks carry a 122 px floor — `minmax(122px, max-content) minmax(122px, 1fr)` — and the
pair was measured, not picked. The action floor keeps a tab of short actions (`menu`,
`panel`) from starting its outcomes hard left of where every other tab starts them. The
outcome floor is what stops `max-content` being greedy where there is nothing to be greedy
with: without it the actions took 208 px of the 262 px a 320 px phone leaves, and `drag`,
`select` and `keys` all grew a scrollbar. Candidates with a larger outcome floor (150–184 px)
read better still until the cells were checked against the container's own right edge —
122 + 122 + the 10 px gap is 254 and fits, 122 + 150 does not, and the difference is invisible
in a screenshot because the overflow scrolls rather than clipping. Re-tested when the rows
were rewritten longer, since `keys` has short actions and looked like it wanted the floor
gone: dropping the action track to bare `max-content` put `drag` 533 px over, `camera` 538 px
over and `select` 461 px over, because a tab with one long action then hands it the whole
width. The floors are load-bearing.

`--drive-help:<tab>` opens the panel on one named tab at startup, since a headless run cannot
click a tab strip and a panel no capture can reach is one whose rows nobody ever checks fit.
It is the only caller of `layoutHelp`'s `path_forced`, and of the shim's `is_forced` flag.

The hint **persists until the reader first acts** -- a gesture that moves the camera or
changes the scene, not a hover -- rather than for four seconds. A timer cuts off whoever
reads slowly, and a first-time reader is exactly who reads slowly.

Keyboard exists at all for the first time; before this there was none in either build
(`grep keydown`, `grep SDLK_`, both empty), which fails **WCAG 2.1.1 at Level A**. `Escape`
sheds what is in progress, innermost first; `ctrl`/`cmd`+`Z` and `ctrl`+`shift`+`Z` step
the timeline. Both reach the timeline through one function per build (`panel.stepHistory`,
`glue.js`'s own `stepHistory`) rather than through the button: routing the browser
shortcut through `button_undo.click()` made it depend on that button's `disabled`
attribute, refreshed on the low-cadence UI tick, so a key pressed in the frames after an
edit did nothing while the timeline plainly had something on it. Measured while driving
it, not suspected.

On the desktop `Escape` **no longer quits** -- `ctrl+Q` does. Pressing escape twice to be
sure a drag had cancelled would otherwise have thrown away an unsaved scene.

**WCAG 2.5.7 (Dragging Movements)** is satisfied and worth stating so it is not re-derived:
every operation the drag reaches is also reachable with no dragging at all, through
tap/click → selection menu → apply, or through the apply section itself. That is what makes it
safe for the drag to be the *fast* path rather than the only one, and it is the route a
regression here would break first, so the touch drive exercises it explicitly.

The canvas is now reachable from the keyboard too, which closes that. Reading the tree first
found **two different gaps, and the desktop's was far worse than the note above admitted**:

- **Desktop: the keyboard reached nothing.** `guiInit` never set `io.ConfigFlags`, so Dear
  ImGui's own keyboard navigation was off. Tab reached no button, no combo, no field — not
  "the canvas is unreachable" but the *entire UI* pointer-only, apart from the four
  accelerators above. One line caused it and one line fixes it, and no amount of binding keys
  in the application could have: the widgets are Dear ImGui's, and only its navigation moves
  between them.
- **Browser: only the canvas.** The drawer is real `<button>`/`<select>`/`<input>`, so Tab
  already reached every control and constructing was *already* keyboard-operable through the
  apply section. `shell.html` simply had no `tabindex` anywhere, so the view could not take
  focus.

**Turning navigation on then swallowed every view key**, and that was measured rather than
suspected: `--drive-keys` reported the camera still at its opening placement with
`WantCaptureKeyboard` reading true. That flag looks like the guard and is the wrong one —
with keyboard navigation enabled it is true from the first frame, nothing focused, nobody
having pressed Tab. `gui.wantsKeys` asks the two things that genuinely mean "these keys are
ImGui's": a field is taking text (`WantTextInput`), or navigation has landed on a widget
(`IsAnyItemFocused`). Neither is true while the reader is simply looking at the scene.

**The help stays open until it is closed.** A tap anywhere outside it used to dismiss it,
canvas included, so a reader who opened it to find out what a gesture does lost it on the
first touch of that gesture — which is the one moment the panel exists for, and the reason it
is cut by way of working rather than by kind of control. The two popovers either side of it
in that guard keep their tap-outside dismissal: those are transient. The browser panel gained
a close button of its own in the same change; it had none, and removing the outside tap
without one would have stranded a phone, which has no escape key.

**The help lists the whole catalogue, generated.** A seventh tab, `operations`, holds one row
per `Operation`: `scene.notationSymbolic` against `scene.notationNamed`, the two halves of
one split at the double space the catalogue table separates them with. Nothing is
transcribed, so the tab cannot fall behind the catalogue — and a suite case says so, since
the day someone hand-writes a row is the day it can. The catalogue table moved from `let` to
`const` to make that possible (`help.nim` builds its table at compile time), with the
`cstring` array a picker needs built from it rather than the other way round: addresses can
be derived from text, text cannot be derived from addresses.

**"Up to date" is a check, not a reading.** Two suite cases hold the help to the build: every
operation appears with the name the pickers offer it under, and every `Key` the view answers
appears in some row. A reading is only true on the day it is made.

**Tab is deliberately not rebound.** Cycling objects with it inside the view is the tempting
binding and risks a **keyboard trap — WCAG 2.1.2, also Level A**. Fixing 2.1.1 by creating
2.1.2 is not a fix, so the view is one ordinary tab stop and traversal took the brackets:

| Key | Does | Kind |
|---|---|---|
| `w` `a` `s` `d` | slide the view across the ground | held |
| `q` / `e` | lower / raise it | held |
| arrows | orbit | held |
| `-` / `+` | dolly out / in | held |
| `shift` | multiply every rate above by `FACTOR_HASTE` | held |
| `[` / `]` | focus the previous / next object | press |
| `enter` | select it, or add it where shift is held | press |
| `f` | frame whatever is selected | press |
| `home` | put the camera back where it started | press |

`interaction.motionFor` and `interaction.actionFor` are that table, split by **kind**: a
motion runs every frame its key is down (`driveHeld`), an action happens once at the press.
One enum would have left every caller asking which kind it had, and an action re-run by the
operating system's own auto-repeat is a bug waiting to happen. Each path translates only its
own naming — SDL scancodes, DOM `KeyboardEvent.code` — exactly as each already does for mouse
buttons, and `help.nim` renders its keyboard rows out of both rather than transcribing them.

**The bindings came from what other software does**, checked rather than guessed. Unity,
Unreal, Godot and Blender's fly mode all bind WASD to *movement* and Q/E to down/up, all four
use shift for *faster*, and three of them put "frame the selection" on F (Blender on numpad
`.`). The one fork is what movement means: those editors *fly* the eye along its sight line,
behind a held mouse button, while a map or an RTS *slides* the view across the ground. This
project slides — the camera orbits a target on the ground plane, and the zoom that goes with
it aims at the cursor — so holding W skims the ground rather than diving into it, and the
height never changes. Measured through the browser's own events: 500 ms of W moved the target
12.8 units with `z` unchanged to four decimals, and shift over the same interval moved 49.3.

**Shift stopped meaning something different per key.** It used to turn an arrow's orbit into
a pan, which is one meaning on four keys and none anywhere else; it is now a rate multiplier
on every movement key, and `Key.Shift` is a key in the held set rather than a flag threaded
through the calls — so letting go of it mid-movement is just another release.

**Movement runs while held, not once per press.** The old per-press steps leaned on the
operating system's auto-repeat: movement began after the repeat delay and arrived in
stutters. Both front-ends now watch key *up* as well as key *down* (neither did before),
`Interaction.keys_held` carries what is down, and `driveHeld` applies each held key once a
frame scaled by that frame's own elapsed time — so a hold covers the same ground at 60 Hz and
144 Hz. The dolly compounds as `pow(FACTOR_DOLLY_SECOND, seconds)` rather than multiplying
per frame, which would have moved a fast machine further for the same hold.

**Releases go missing in three ways, and all three are handled.** The window loses focus
(`SDL_EVENT_WINDOW_FOCUS_LOST`, `blur`), the tab is hidden (`visibilitychange`), or a panel
widget takes the keyboard (`gui.wantsKeys`). In each the release is delivered somewhere else,
and a key left in the held set moves the camera forever with no press able to stop it;
`releaseKeysAll` empties it. Verified by dispatching a blur mid-hold in the browser: the
target moved 0.0000 further.

**Plain `s` had to move.** It was bound to writing a PNG on the desktop, which a movement key
cannot also do; that went to `ctrl+s`, beside the other accelerators, and the panel's own
"save PNG" button is untouched.

**Focus is its own state, not hover.** `updateHover` recomputes hover from the cursor every
frame, so a keyboard focus stored there would be erased before it could be drawn once.
`interaction.index_focus` is separate, pruned against liveness like every other slot carried
across frames, and **drawn with the marker hover already uses** — which satisfies 2.4.7 with
machinery already built and already tested rather than a second indicator invented beside it.
The browser adds a `:focus-visible` ring on the canvas itself, inset rather than outset
because the canvas fills the viewport and an outside ring would fall off every edge.

Camera keys move by one **shared** rate per second (`camera.TURN_SECOND` and friends),
unlike the per-pixel drag rates, which differ per front-end for a real reason —
`visualiser.SPEED_ORBIT` is radians per pixel and `glue.js` works in fractions of canvas
width. A press has no pixels in it. `home` needed the opening placement, which was written
out twice; it became `camera.initCameraDefault` and both entry points now read it.

**What is verified, and what is not.** The view keys reaching the view with navigation on is
measured on both builds — the desktop through `--drive-keys` (focus walked, enter selected,
azimuth/elevation/distance each moved by exactly their own constant), the browser through
real key events. The browser's **no-trap property is measured**: Tab from the canvas moves to
the next control and shift+Tab back. Typing `[]-+` into a label still reaches the label on
both. What is **not** demonstrated is Tab landing on a Dear ImGui widget: a window that never
takes focus gives ImGui no navigation focus, so a synthesised Tab shows nothing under `xvfb`
either hidden or mapped. `gui.isNavEnabled` reports the flag is set, which is the
configuration rather than the behaviour; the behaviour wants a human at a real window.

**The storyboard's old sensitivity to the help table is gone, and was explained on the way
out.** Three rounds running, growing that shared table moved a handful of single pixels of
text inside the desktop panel, and the mechanism had never been pinned down. It was
`layoutHelp` measuring every entry's width *every frame*, open or not, to size its outcome
column: Dear ImGui 1.92 rasterises glyphs on demand and packs them into the atlas as they
are first asked for, so measuring a different set of strings changes where later glyphs land
in the texture and shifts their antialiasing by a subpixel. Measuring only while the panel is
open removes the coupling entirely, and the proof is a bisect: with that one change applied
to *both* the 26-entry table and the 31-entry one, the two storyboards come out
**byte-identical**. The capture did move once more in the process — five subpixels, all
inside the panel, none of them 3D content — because the measurement stopped happening at
all.


Verification Tools
---
`tools/verify.sh` runs everything below, in cheapest-first order, and fails on the first
failure. Passing it is necessary and never sufficient — several bugs here survived a green
run of all of it, so the script closes by saying so.

| Check | What it holds | Reads from |
|-------|---------------|------------|
| `check_columns` | Line width, trailing whitespace, tabs, final newline | The filesystem |
| `check_palette` | Palette separation floors | `mesh.lut_ink_to_rgba` |
| `check_atlas` | Every drawable codepoint has a glyph range | `lut_*` and `gui_shim.cpp` |
| Suite ×3 | Every invariant, on both backends and two capacities | `tests/visualiser/` |

Each reads the thing being checked rather than a transcription of it, which is the whole
point: a mirror of the palette or of the atlas ranges would pass happily while the compiled
build disagreed. `check_atlas` parses the `ImWchar RANGES` arrays out of `gui_shim.cpp`
itself and enumerates the codepoints from the notation table, the basis names, the shape
words and the formatter — 62 printable codepoints today, all covered. `check_columns`
counts **characters, not bytes**, which is why it exists as a tool at all: a `wc -L` reports
a compliant line full of `∧`, `⟑` and `𝐦` as eleven columns too long, and gets ignored
within a day. It skips the testament spec block a test file opens with, whose `matrix` line
is one line by testament's own rules with nowhere to wrap to.

`check_palette` measures under **Machado, Oliveira and Fernandes (2009) at severity 1.0**,
because that is the model every floor quoted in `REQUIREMENTS.md` was calibrated against.
Viénot-1999 is equally respectable and moves borderline pairs materially — measured here,
it puts Jade/Cobalt at 0.9 ΔE where Machado puts it at 12.7 — so the model is part of the
standard rather than an implementation detail, and changing it means remeasuring every
floor. Red-green (the minimum of protan and deutan) carries the floors; tritanopia is
measured separately, since it is rarer by three orders of magnitude and holding both to one
floor collapses the palette to a single arc for no reader's benefit.

**One declared exception, and it is a new finding.** Jade and Cobalt separate by only
**3.7 ΔE under tritanopia** — a case no floor covered before this tool existed, because the
original validation gated on red-green alone. It is carried rather than repainted: the pair
clears 12.7 under red-green deficiency and 15.8 to typical vision, tritanopia affects fewer
than one reader in ten thousand, and every object also carries its own shape, screen
position and written label. The exception lives in `check_palette.nim`'s own `EXCEPTIONS`
table with a floor of 3.5 pinned just under where it measures, so drifting further fails the
run; the reason prints on every run so it stays argued rather than inherited.


Testing
---
The suite is one file, `tests/visualiser/suites.nim`, run from three thin entry points that
differ only in their testament spec:

| Entry point | Backend | Capacities | Why it exists |
|-------------|---------|-----------|---------------|
| `test_4d.nim` | C | Default | The desktop build, as shipped |
| `test_4d_browser.nim` | JS | Default | The browser build's own backend |
| `test_4d_small.nim` | C | 12 items, 12-char labels, 4 steps | Boundaries a test reaches |

The JS row is not a formality. A rule stated once and reached through two mechanisms is only
held together where both mechanisms run; compiled to C alone, `magnitudesAgree` asks the C
runtime whether it agrees with itself, and 330 of 7000 values differed between the front-ends
while it stayed green. Adding that row also found `$toCstring` reading empty, `isVisibleAt`
writing to a copy, and the browser's multivector text coming from the library's `$` — three
divergences that had each been worked around or documented rather than fixed.

The reduced-capacity row makes any constant tuned to the *default* rather than derived from
its `.define` fail here rather than in a build somebody configured. `LABEL_MAX` at 12 is the
sharpest of the three: it is under the length of several labels the suite constructs, so
truncation happens for real.

Cases needing a C entry point — `snprintf`, the PNG and GIF encoders, the arena, and scene
save/load, which needs a filesystem — guard themselves `when not defined(js)` and are skipped
on the JS row. That row runs 104 of the 115 tests; the small-capacity row runs all 115.

**The suites test rules; a second layer drives events.** Every case above calls a rule
directly, so none of them can catch a rule wired to the wrong event — and that is where this
project's bugs actually live. A pinch came to zoom at its own midpoint and slide the view
with it while every suite case stayed green; a ghost was previewed from a picker's *position*
passed through as a *slot*; a rename left a callback bound to nothing. Each was found by
driving the thing by hand, and none of the drives was ever committed.

Both front-ends are now driven by `tools/verify.sh`, and the checks assert rather than
narrate:

| Layer | What runs it | What it covers |
|---|---|---|
| Suites | three entry points, C and JS | the rules, 244 cases |
| Desktop drive | `--drive-assert`, under `xvfb-run` | six gestures, through SDL's queue |
| Browser drive | `drive_browser.mjs`, via Playwright | 23 checks: keys, wheel, touch, DOM |
| Checkers | `check_columns --self-test` and friends | layout, palette floors, glyphs |

**The rule this establishes: a fix is not finished until something checks it at the layer the
bug lived at.** A rule bug earns a suite case; a wiring bug earns a driven check. Writing the
driven layer immediately paid for itself twice — `--drive-undo` had been pushing key presses
with no releases, which became a real fault the moment a held key meant continuous movement,
and `--drive-sky` had never done anything at all, because the scene it scans for a horizon
plane has none in it until one is built. Both had been "passing" for as long as they existed.

Timing-dependent quantities in the browser drive are asserted as **bands**, never as figures:
how far a held key travels depends on how many frames the machine drew while it was down, and
a check written against an exact number flakes. What is exact is asserted exactly — a wheel
notch each way returns the camera to distance 19.000 and target (0, 0, 1).


Measurements
---
Release build, 4 cores @ 2.8 GHz, 1440×900, headless Xvfb + Mesa `llvmpipe` (no GPU here):

| Quantity                   | Cost |
|----------------------------|------|
| Tessellate 64-object scene | 61 µs (~0.95 µs/object) |
| Any catalogued operation   | 80–170 ns |

`--timings`, 2000 frames, `--novsync`:

| Scene                     | Mean | p50 | p95 | p99 | Max |
|---------------------------|------|-----|-----|-----|-----|
| Light (~8 items)          | 10.4 ms (96 fps) | 10.1 ms | 12.9 ms | 15.5 ms | 36.1 ms |
| Full (`--fill`, 64 items) | 39.8 ms (25 fps) | 39.0 ms | 47.1 ms | 50.8 ms | 89.2 ms |

Tessellation is under 0.25% of frame budget either way. **A ">500 fps" target cannot be
assessed in this environment**: rasterisation runs on software `llvmpipe` and dominates the
frame entirely — none of it is `Scene`/arena/RGA code. On real GPU hardware this geometry
(hundreds to low-thousands of vertices) would cost low microseconds, but that needs an
actual driver to confirm.


Known Limitations
---
- No human has run either build. Every result here is software-rendered and machine-driven.
- Dear ImGui's keyboard navigation is enabled and verified enabled, but Tab actually landing
  on a desktop widget is unverified: a window that never takes focus under `xvfb` gives ImGui
  no navigation focus to move. Wants a human at a real window.
- Two crossing translucent washes blend order-dependently (see the draw-order invariant).
- A camera move is not undoable on its own. Undo restores the view each edit was made from,
  but an orbit that changed nothing else leaves no step to step back over.
- Conformal metric (`IS_CONFORMAL`) is unfinished in the library; this build is rigid 4D.
- `.rgascene` is little-endian by rule, but only a little-endian host has ever written or
  read one; the byte-swapping path a big-endian host would take is unexercised.

[replications]: https://gitlab.com/mraxilus/replications
