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
property-test suite rerun (`tests/visualiser/suites.nim`, 152 assertions; `renderer`/`gui`/
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
  `picking`, `marker`, `interaction`, `storyboard`, `history`, `format` |
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

`Item` is a handle (pointer into `Scene` + slot number), not an assembled copy;
`.geometry`/`.label` resolve via `lent`. Do not hold one across a mutation of its own slot.
By-slot accessors (`geometryAt`/`labelAt`/`isVisibleAt`/`inkAt`/`anchorOverrideAt`, plus
non-`var` `isVisible`/`setVisible`) exist beside it and are what the browser's per-frame
loop uses — see Browser Pipeline for why constructing an `Item` there is expensive.


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
scaled, which visibly resizes a plane as the camera orbits. Normal drawn as a bare shaft,
`FRACTION_NORMAL_SHAFT` (0.25) × extent, no tip marker.

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

**Clip planes follow orbit distance** (`camera.distanceNear`/`distanceFar`, at 1/400 and 20
times it). Derived rather than stored, so they cannot go stale — a stored pair set once at
construction keeps its original value through every dolly, which is exactly the bug this
replaced: the far plane sat at a fixed 400 while the orbit limit is 500, so dollying past
400 clipped the whole scene away, and well before that a line's own far end came back inside
the frame and read as stopping in mid-air. Both scale together, so the frustum keeps its
shape and depth-buffer precision — a function of the far-to-near ratio — stays constant
instead of decaying as the camera pulls back.

**Furniture** (ground grid, world axes) reaches `extent_furniture`, computed from that far
clip (`extentFurnitureFor`). The grid's cell size steps with its reach (`sizeCellGridFor`):
`SIZE_CELL_GRID` = 2.0 doubled until no more than `CELLS_GRID_HALF_MAX` = 24 cells cover it.
Doubling rather than dividing the reach evenly, so a coarser grid's lines fall exactly on a
subset of the finer one's and the change reads as alternate lines dropping out rather than
the grid sliding to new positions. A cell size fixed against a reach that now follows the
camera would multiply without limit — it overran the 16384-vertex budget outright at a
400-unit orbit, long after cells had crowded below one screen pixel. `addGrid` cuts each
line into `SEGMENTS_GRID_FADE` pieces fading per-vertex (not per-piece, so GL
interpolation stays smooth) from full alpha at
`FRACTION_GRID_FADE_START` × extent to zero at `FRACTION_GRID_FADE_END` × extent — 0.03 /
0.12, tuned by direct visual comparison. The ground plane skips the two lines that would
coincide with the X/Y axes, avoiding depth-fighting. Axes use standard convention (x red,
y green, z blue).

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
window outright rather than downgrading, and a workbench that will not start is worse than
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

| Shape | Marker |
|-------|--------|
| Point | Circle in screen space about the drawn point. |
| Line | Two straight segments flanking its projection, one to each side. |
| Plane | A circle lying *on the plane*, outside its own rim. |
| Anything at horizon | None — all three draw fixed to the eye, with nothing to surround. |

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

**A line's rails are offset in world space, so they converge exactly as the line does.**
Two lines parallel to it, one each side, drawn the same way `mesh.addLine` draws the line
itself — own anchor out to each of the two vanishing points, which parallel lines share —
so the three meet at the same two points on screen rather than merely running near one
another. A constant screen offset instead holds the pair open all the way to the horizon,
where the line has long since narrowed to nothing; that was the first attempt and it was
wrong on the geometry. This is why `picking.clipToEyeSide` is exported: a marker drawn past
the eye plane wraps to the opposite side of the screen.

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
world distance, and `radiusMarkerLoop` sizes it through `worldPerPixel` so the gap reads
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
different. A line or plane at horizon is never pickable — neither is anchored anywhere a
screen-space or ray test could land, since both draw fixed to the eye. A horizon point (a
fixed star) keeps a pickable anchor.

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
**Desktop / mouse and pen.** Drag from an object onto another to derive a third. **The
press target chooses the scheme; the button chooses whether you are asked.** Press an object
and you are constructing; press empty space and you are moving the camera (left orbits,
right pans, wheel dollies). Left then takes the algebra's own answer on release; right opens
a four-way choice menu instead, as does holding still over the target for
`SECONDS_DWELL_MENU` (0.45). Both buttons reach the same choices, so this is redundancy
for different expertise rather than a mode split — which is exactly why it is safe where the
button-per-operation mapping it replaced was not. `interaction.isMenuForcedBy` states it
once; `visualiser.isMenuForcedFor` maps SDL button numbers and
`browser_bridge.nimDragKindForButton` maps DOM `PointerEvent.button` numbers (0/1/2, a
different numbering for the same three buttons) into it. **Middle is unbound**: `project`
used to live there, which put a third of the vocabulary behind hardware most trackpads lack.
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
reason: it showed nothing. The workbench lists every operation and the selection menu shows
what applies, but a drag's whole vocabulary lived in a button mapping the reader had to have
been told. So the drag now *shows its answer before committing it*: `interaction.preview`
holds what a plain release would build, drawn as a ghost in `INK_GHOST` through the same
`addObject` dispatch an open edit session's ghost uses — one "not committed yet" appearance,
not two. The rubber-band is tinted by `inkOfDrag`: the operation's own colour over a pair
that makes something, `Ink.Invalid` magenta over one that makes nothing, neutral crossing
empty space. That magenta is what the palette reserved a slot for and had no use for until
now; it is never leaned on alone, since the ghost simultaneously fails to appear.

**The choice menu.** Four wedges at fixed compass points — join north, meet east, project
south, `more…` west — with unoffered ones drawn greyed rather than packed out, because a
menu whose items move is one nobody learns to reach without reading it. **One release rule:
a release commits whatever is under the cursor.** `endDrag` resolves the wedge itself
through `choiceAt`, rather than each render path resolving it, so the two cannot disagree
about where a release landed; back at the centre (inside `PIXELS_MENU_DEADZONE`, 26 px)
commits nothing, which is also why a dwell menu is safe to open unasked — it opens *centred
on the cursor*, so a reader who did not want it is already in the deadzone. The menu
**latches its destination** when it opens (`destinationOf`): reaching out to a wedge
necessarily takes the cursor off the item, and a destination read from hover would go none
at exactly the moment the release needs it.

`more…` is the ramp from this gesture to the other twenty-four operations: it builds nothing
itself and instead selects both operands in drag order and opens the apply section, which
fills its own m and n from the selection. Without it the gesture is a dead end at three
operations out of twenty-seven.

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
(`selectionSlots`), refreshed whenever the selection changes, so the per-frame overlay loop
does not cross the boundary — a cache of Nim's answer, carrying no rule of its own. An
earlier design kept the ordered list in JavaScript because Nim held a single scalar; that
put pick order, the thing that names operands, in the wrong language.

`nimClearHover()` is called once the last finger lifts. Touch has no continuous pointer
position, so `nimUpdateHover` only ever runs at a touch-down point; without this the last
reading sits stale forever and its ring (only 20% dimmer than a selection ring) reads as a
second selected object.

**Selection menu** (both builds, one row, following its anchor object every frame — the
browser through `nimAnchorScreen`, the desktop through `visualiser.anchorOfSelection`, both
projecting the same `picking.anchorFor` the rubber-band uses): `apply` sits leftmost and
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
session on that slot, scrolls its row into view and hides the menu — the workbench owns the
interaction from there — while keeping the selection itself. It shares `openWorkbenchTo`
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


Undo/Redo
---
`visualiser/core/history.nim`, shared. Scoped to scene-content edits — add, apply (including
drag and the touch flow), remove, visibility toggle, ink recolour, and an edit session's
`save` — and deliberately **not** camera moves. Coefficients, label and ink used to be
excluded too, because the widgets driving them are continuous multi-frame inputs and
recording every keystroke would flood the timeline; the staged edit session (see Edit
Sessions) supplies the "edit committed" moment they lacked, so one `save` records one
entry covering all three at once.

One fixed-size array plus one cursor, not separate past/future stacks: `Scene` is a plain
fixed-size value type (arrays of `Multivector`/`Label`/`Ink`/`bool`/`float`/`Option`, no
pointers), so recording is a value copy and `entries[cursor]` is always exactly the live
scene. Undo/redo move the cursor and copy back; a fresh edit truncates past the cursor.
Halves the memory of a two-stack design and collapses two invariants into one.
`CAPACITY_HISTORY` = 32; recording past it drops the oldest entry rather than growing.

Seeded via `initHistory(scene)` wherever the scene is (re)initialised — desktop startup;
browser `nimInit`/`nimLoadDemo`/`nimSceneClear` — so undo never reaches past the moment
tracking began. A successful undo/redo clears the selection unconditionally, since a
restored snapshot's slot numbers need not match. `nimCanUndo`/`nimCanRedo` drive the
browser's disabled-button state. No keyboard shortcut: SDL3 modifier state is not currently
bound.

Tested by recording to capacity, walking all the way back and forward, and comparing against
the actually-recorded state at every step. `Scene` embeds `Multivector`, whose `==` is an
intentional compile error, so `scenesEqual` compares item by item using `=~` for geometry.


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
Compact binary matching `Scene`'s SoA layout, native-endian throughout — there is no
external spec to match, unlike PNG/GIF which follow their own required endianness. A file
saved on a big-endian machine will not load on a little-endian one; acceptable for a
single-desktop tool.

| Bytes    | Field |
|----------|-------|
| 4        | Magic `RGAS` |
| 1        | Format version (currently 1) |
| 1        | Basis count (16 under this build's 4D rigid metric); must match, or the
             file was saved under a different PGA dimension or metric |
| 4        | Item count, native `uint32` |
| per item | Ink (1), visibility (1), label length (1) + that many bytes, then one
             native `float` per basis term |

Only live items are written, in slot order. Deliberately omitted: slot numbers (meaningless
once reloaded — a fresh scene assigns its own free-list order); `born` (meaningless across
runs — a loaded item is born at the dawn of time, never partway through an animation that
never happened); fixed-width label padding (length-prefixed, so the format does not depend
on the writing build's `LABEL_MAX`).

`loadScene` parses into a staging scene and replaces the caller's only on complete success,
so a bad path, a foreign file, a wrong dimension, or too many items leaves the existing
scene untouched. Native-only (`when not defined(js)`) — a browser has no filesystem.
The browser reaches the identical format through `nimSceneAddRaw` plus a hand-written
`DataView` pack/unpack in `glue.js`; `browser_bridge.nim` exposes raw per-item fields rather
than bytes, since reinventing IEEE-754 encoding in Nim would only duplicate what `DataView`
does natively.


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
2. `isVisibleAt` returns `var bool` over an `array[N, bool]`, which `panel.nim`'s ImGui
   checkbox binds by address. That exact combination miscompiles under `nim js` whenever the
   result is consumed as a *value*: the generated code indexes a primitive boolean with a
   stray compound key, yielding `undefined` — falsy everywhere. Hence the ordinary non-`var`
   `isVisible`/`setVisible` pair, used only by the browser; `isVisibleAt` is untouched and
   still correct on the C++ backend it was written for.
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

**Chip row** (always visible): brand/drawer toggle, then undo and redo as plain bordered
`.btn` rectangles, axes and grid as a segmented `.toggles` pill, then a `☰` menu button.
The visual grammar is deliberate — a pill shows state you can read at a glance, a bordered
rectangle is a momentary action. Sorting by frequency matters: undo/redo and the view
toggles are reached constantly and must not cost an extra click, while the menu holds only
the genuinely rare file actions (save scene/image, load scene/demo, under `save` and `load`
titles). Below 480px the brand label drops to its mark alone, or five controls plus the full
label overflow a narrow phone.

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
`workbench.session` (desktop), drawing a live muted preview through the same
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
`camera.aimFor(geometry, scale)` answers where a camera should look to see one object: a
point at horizon along its own direction, a line at horizon along the first axis spanning
perpendicular to its normal (no single direction faces a whole great circle), a plane at
horizon not at all (it fills the sky), and anything finite at `mesh.anchorFor`'s
representative point — the same point the selection ring is drawn on.

`camera.CameraTween` carries the camera there, eased. **Retargeting reads the start off the
live camera**, not off the previous goal, which is what makes a goal that moves every frame
— a coefficient being dragged — one continuous chase instead of a restarting jerk. Offering
a goal already held is ignored, so a caller may aim every frame without the ease restarting
forever and never arriving.

Both builds aim from **one rule**, applied once per frame rather than at each event: the
open edit session's staged multivector if there is one, else the sole selected object.
That second clause is what carries applying an operation, releasing a drag and stepping the
storyboard, since each already leaves its new object solely selected — none of them needs
to know the camera exists. `runStoryboard` aims through the same call but calls `settle`,
which lands instantly: a captured frame must never show a half-finished pan.

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


Diagnostics Panel (desktop)
---
A closed-by-default section holding: a raw (not smoothed — smoothing hides exactly the rare
slow frame this exists for) per-frame-ms line graph over ~4 s from a ring buffer on
`Workbench`; a fill-fraction bar for the permanent arena; a `peak_used` high-water bar for
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
- The `when defined(js)` seams in `scene.nim` and the `shapeDescription`/`labelString`
  duplicates in `browser_bridge.nim` are documented backend-compatibility necessities, not
  shortcuts. Leave them.
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

**Tabbed by how you are working, not by what the control is** — `drag`, `choose`, `menu`,
`workbench`, `camera`, `keys`. A reader opens this in the middle of one thing, and only that
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
— and the measurement is what split `menu` out of `choose`: ten rows did not fit, because at
that width the outcome column wraps onto second lines, so a count of rows is not a count of
lines. It sits exactly at what the largest tab holds, so the next row added to a full tab
fails the build; the answer is nearly always to split that tab.

The desktop draws the tabs through four new shim calls (`BeginTabBar`/`BeginTabItem` and
their ends) with each tab's rows inside a `childBegin` region bounded to what the window
actually has. That region scrolls, and is the safety net rather than the design: no tab may
ever again lose rows off the top, whatever the window height. Its height comes from
`guiChildHeightForRows` rather than from a hand-picked row height — Dear ImGui's own line
spacing, window padding and border, asked for rather than restated, so a tab is exactly as
tall as its own rows and `workbench`'s two do not float in a panel sized for eight. Its
*width* is measured from both columns: a bounded region asked to fill nothing inside an
auto-sizing window collapses to its widest item, and every outcome placed past that by
`sameLineAt` is then clipped away — which is what the first attempt did, and looking at the
capture is what caught it.

The browser draws a wrapping button strip plus `data-path` on every row, with only the rows
scrolling so the strip stays reachable, and the panel widened from 360 px to `min(560px,
100vw - 28px)`. Rows are hidden by attribute rather than rebuilt per tab, which needs
`.help-row[hidden] { display: none }`: an author `display: flex` beats the UA stylesheet's
own `[hidden]` rule, and without that line every tab reported the whole table's height —
measured, and it is why the check compares `scrollHeight` to `clientHeight` per tab rather
than trusting the markup.

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

**Tab is deliberately not rebound.** Cycling objects with it inside the view is the tempting
binding and risks a **keyboard trap — WCAG 2.1.2, also Level A**. Fixing 2.1.1 by creating
2.1.2 is not a fix, so the view is one ordinary tab stop and traversal took the brackets:

| Key | Does |
|---|---|
| arrows | orbit |
| shift+arrows | pan |
| `-` / `+` | dolly out / in |
| `[` / `]` | focus the previous / next object |
| `enter` | select it, or add it where shift is held |
| `home` | put the camera back where it started |

`interaction.actionFor` is that table; each path translates only its own naming (SDL
scancodes, DOM `KeyboardEvent.key`) exactly as each already does for mouse buttons, and
`help.nim` renders its keyboard rows out of it rather than transcribing them.

**Focus is its own state, not hover.** `updateHover` recomputes hover from the cursor every
frame, so a keyboard focus stored there would be erased before it could be drawn once.
`interaction.index_focus` is separate, pruned against liveness like every other slot carried
across frames, and **drawn with the marker hover already uses** — which satisfies 2.4.7 with
machinery already built and already tested rather than a second indicator invented beside it.
The browser adds a `:focus-visible` ring on the canvas itself, inset rather than outset
because the canvas fills the viewport and an outside ring would fall off every edge.

Camera keys move by one **shared** amount per press (`camera.TURN_PRESS` and friends),
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
- Undo/redo does not cover camera moves.
- Conformal metric (`IS_CONFORMAL`) is unfinished in the library; this build is rigid 4D.
- `.rgascene` is native-endian and will not cross endianness.

[replications]: https://gitlab.com/mraxilus/replications
