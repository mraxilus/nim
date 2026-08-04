Provenance — RGA Workbench
===

| | |
|---|---|
| **Agent** | Claude Code (Anthropic), run headless in a container |
| **Author** | Written end to end by that agent; no human wrote any line of it |
| **Date** | 12026-08-03 (Holocene), from the brief in `REQUIREMENTS.md` |
| **Style contract** | `STYLE.md`, followed for every line |
| **Where it lives** | Kept locally, deliberately unpushed: its own git repository at `~/rga_workbench`, with no remote. It sits **beside** the Nim checkout rather than inside it, so that repository's working tree stays pristine; the compiler change it needs lives here as `tools/nim_dot_call.patch`. |
| **Review line** | **No human has read this code line by line, and no human has driven either build.** Every claim below is either marked as measured — with the measurement named — or marked as assumed. |

This file describes what the code **currently does** and why, organised by subsystem. It is not
a changelog: superseded experiments are gone, except where a rejected alternative is still a
live trap and earns one terse line.


Layout
---

```
src/core/      One geometry core, read by both front-ends.
src/browser/   Boundary layer (Nim → JS), page shell, and browser-only glue.
src/desktop/   Window, GL renderer, immediate-mode panel, image export, capture mode.
tests/         Two entry points, one shared suite, run on both backends.
tools/         Vendor fetch, font subsetter, codepoint enumerator, bundler, headless driver.
vendor/        Never committed; `tools/fetch_vendor.sh` restores it.
```


Vendored Dependencies
---

| What | Where from | Commit | Licence |
|------|-----------|--------|---------|
| PGA library | `https://gitlab.com/mraxilus/replications.git`, path `lengyel/projective_geometric_algebra_illuminated` | `f8861e0b5ab6e868382126aa7b109503f2fe16d3` | Prosperity Public License 3.0.0 (noncommercial). The fetch script copies `LICENSE.md` alongside the source, as its notice clause requires. |
| `stb_truetype.h` | `https://raw.githubusercontent.com/nothings/stb/master/stb_truetype.h` | master at fetch time | MIT / public domain (dual) |
| Noto faces | `https://raw.githubusercontent.com/notofonts/notofonts.github.io`, `fonts/*/hinted/ttf` | main at fetch time | SIL Open Font License 1.1; licence text fetched beside them |
| Commit Mono | `https://commitmono.com/src/fonts/fontlab/CommitMonoV143-VF.woff2` — the variable font the project's own page loads | V143 (1.143) | SIL Open Font License 1.1, carried in the face's own name table |

Neither is committed. System packages are listed in `dependencies.list`, each with what it is
for.

**Compiler dependency, measured.** The vendored library's façade writes `m.⟑ n` — a dot call
on a Unicode operator — which Nim lexed as the dot-like operator `.⟑`, so `pga.nim` did not
compile at all. Building this workbench therefore needs a two-line compiler change
(`compiler/lexer.nim`, `compiler/parser.nim`) that stops a lone `.` from absorbing a Unicode
operator and accepts an operator as the routine name after a dot. **That change is kept as a
local patch, not committed to any Nim branch**; `tools/nim_dot_call.patch` holds it. Verified
by running Nim's own `lexer`, `parser` and `macros` test categories against a compiler built
with it: 169 tests, no failures. A dot-like Unicode operator can still be declared and used
with a longer prefix, e.g. `..⟑`, which the patch's own test asserts.


Algebra
---

`core/algebra.nim` is the only module that reads geometry out of the vendored library, and the
only place algebra becomes coordinates.

- **Shape from grade**: grade 1 point, 2 line, 3 plane; grades 0 and 4, and mixed grade, report
  "nothing to draw". That is a displayable outcome, not an error — the demo's `a ∧ ground` step
  exists to show it.
- **Locus** is read from the weight norm: `‖𝐦‖∘ ≈ 0` is at horizon.
- **`unitPoint` divides by the signed weight coefficient**, not by the weight *norm*. Chosen
  because the library's `^` divides by a magnitude, so a point built with negative weight stays
  negative and reads as its own reflection through the origin. Cost: one place in this project
  that reads a single basis coefficient by name. Measured: without it, the meet of a line at
  x = 500 with the z = 0 plane read as x = −500, which is what the "meet outside the drawn
  disc" test now pins.
- **Tangents of a plane are derived through the algebra**: an axis direction is projected
  orthogonally into the plane for the first, then the plane is met with a plane perpendicular
  to that first direction — through weight expansion — for the second. Rejected: reading the
  normal and crossing it with an axis, which is the hand-rolled vector arithmetic this project
  does without. Cost: four algebra products per plane per frame.
- **Midpoints and offsets are sums of unit-weight points** read back through the same position
  projection everything else uses.
- **Element names are derived** from the basis enumeration, not transcribed. A test asserts
  each derived name equals what the library prints for that element alone, so a build of
  another dimension names its own elements.

The projection pipeline — `core/transform.nim` — is the one module doing linear algebra of its
own. A projection matrix is a property of the graphics pipeline, not of the algebra under
study; everything that reaches it is already a world position.


Operation Catalogue
---

Twenty-seven operations, one table, read by both front-ends. **Notation is extracted at compile
time from each operator's own declaration in the vendored library** — the `docs` argument of the
generating call, or the doc comment of a hand-written operator — never from the summary tables
at the top of those files. The two compound projections carry no notation in their own
documentation, so theirs is composed from the one-line body each is declared with, by
substituting operands into the notation of the operators that body names.

Two deliberate departures from the extracted text, both marked in the source:

1. **Combining marks become spacing modifier letters** (U+0302→U+02C6, U+0332→U+02CD,
   U+0305→U+00AF, U+0303→U+02DC, U+0330→U+02F7). An immediate-mode GUI has no text shaper and
   advances by each glyph's own width, so a combining accent lands beside the operand instead
   of over it.
2. **`attitude` is written postfix** though its declaration reads prefix, for consistency with
   the other twelve unary entries.

Binary spacing is normalised, so `𝐦∙𝐧` reads as `𝐦 ∙ 𝐧`. Only spacing: every symbol is the
declaration's own.

**Measured against the brief's own table**: 26 of 27 labels are identical, character for
character, compared by codepoint rather than by eye. The one difference is `subtract`: the
library's declaration writes `𝐦 − 𝐧` with U+2212, and the brief's table writes `𝐦 - 𝐧` with a
hyphen. The declaration wins, per the brief's own rule that notation comes from the
declaration and its warning that the two are indistinguishable in an editor. A test pins the
U+2212.

Derived labels substitute operand names into the notation's symbolic part only — the English
name is cut off first — through two sentinel passes, so an operand whose own name contains a
bold operand letter is not re-substituted, and a template naming the second operand twice
substitutes both.


Scene, Selection, Sessions, History
---

- **Slots are assigned once and never moved.** Structure-of-arrays with an intrusive free list;
  add and remove are O(1). Rejected: a shift-on-delete array, which renumbers every cross-frame
  index — hovered, dragged, selected, operand. Cost: `ITEM_CAPACITY` (64) slots are always
  resident.
- Three liveness guards, all tested: `drawAnchor` reports nothing for a dead slot; a drag
  checks both ends before reading either label; removing an item clears the highlight.
- **Labels are capped in characters, stored in bytes.** `LABEL_CAPACITY` (40) characters, four
  bytes each. Measured: a byte cap cut `a ∧ a ∧ b☆ ∨ (o ∧ …` mid-character at 14 glyphs.
- **Selection is an ordered list**, never a set, never saved, never on the timeline, cleared by
  undo and redo, pruned after any removal. One pick means unary, two or more binary — one rule,
  read by both front-ends.
- **A session is one type in two modes**, its slot an optional inside an optional session. No
  sentinel slot stands for "new". Nothing is written to the scene before `save`; the preview is
  a ghost drawn through the same dispatch a real object uses, which is why an all-zero ghost
  degrades to "nothing to draw" with no special case.
- **History is one array plus one cursor**, capacity 32, recording a value copy of the whole
  scene. The entry under the cursor is always the live scene. Recording past capacity drops the
  oldest. Tested by walking to capacity and back.


Demo Construction
---

Five seeds — `a` (3, −2, 2.5), `b` (−2.5, 2, 5.5), `c` (1, 4, 3), `o` at the world origin, and
`ground` joined from three points at z = 0 and centred on their centroid — then eleven derived
steps. Both front-ends open on the seeds alone; the eleven steps are a one-click preset that
populates ordinary, fully editable items, with birth times stamped one second apart. The seed
count is read from the scene, never hardcoded.

**One instruction in the brief cannot hold as written, and this is how it was resolved.** The
brief asks that `o` stay off `ground` while also placing `o` at the world origin and building
`ground` from three points at z = 0 — and every plane through three points at z = 0 contains
the origin. The seeds are kept exactly as specified, and the constraint's purpose is met
another way: the step it protects is step 8, the orthogonal projection of `o`, and that step
projects onto the **perpendicular plane built in step 7**, not onto `ground`. `o` does not lie
on that plane, so the projection is not a silent no-op — which a test asserts by comparing the
projected point against `o` itself rather than by inspection.

Two steps are teaching cases rather than bugs: `a ∧ ground` is a grade-4 volume and correctly
reports "nothing to draw", and attitude drops one grade each time, walking a horizon point,
then a horizon line, then the plane at horizon, so all three horizon cases are exercised.


Drawing
---

| Constant | Value | Why |
|---|---|---|
| Point size | 9 px | Brief. Drawn round: the platform draws a square sprite, so the corners are cut in the fragment shader. |
| Ring | 16 px radius, 2 px line, hover at 0.8 alpha | One mechanism for "just built" and "currently selected". |
| Line widths | furniture 1.5 px, objects 2.5 px | Asserted at compile time to keep furniture thinner. Most WebGL implementations clamp line width to 1 px, so the browser's widths are advisory. |
| Plane disc | radius 8 world units, fill alpha 0.16, normal shaft 0.25 × radius | Fixed, not camera-scaled, which visibly resizes a plane as the camera orbits. Rendering only: a meet lands correctly far outside it, which a test pins at x = 500. |
| Dome | full sphere, alpha 0.22 | Full rather than hemispherical: an orbit view sits elevated and tilted down. |
| Horizon reach | 0.45 × far clip | Sky geometry stays inside the frustum through any dolly. |
| Grid | base cell 2.0, doubling until ≤ 24 cells cover the reach; 8 pieces per line; full alpha to 0.03 × far clip, zero by 0.12 × far clip | See below. |
| Vertex budget | 16384 per primitive kind | Fixed and asserted, never grown. |

**A line draws as two segments meeting at its support**, each running out to `eye ± horizon
radius × axis`. Both endpoints of each segment lie in the plane through the eye containing the
line, so the pair projects exactly onto the true line's projection. **Measured**: a third point
sampled 40 units along the true line lies on the drawn screen line to within 1e-6 of a pixel,
after the same by-hand near-plane clip the hit test uses. The 6.7°-of-visible-gap figure for
the rejected fixed-reach anchoring is the brief's measurement, **not re-measured here**.

**The grid stops where its fade reaches zero** (0.12 × far clip), rather than extending to the
far clip. Measured, and it was a real bug: with lines cut into 8 pieces spanning the whole far
clip, every piece was longer than the fade band, so both of its vertices sat at zero alpha and
the entire grid vanished — 1478 vertices, nothing drawn. The fade fractions are still fractions
of the far clip, as the brief states; this is where the geometry stops. Cell size then steps
2 → 4 → 8 … as the camera dollies, and at the default view reads 2.0 world units.

**Draw-order invariant.** Translucent triangles share one unsorted bucket drawn with depth
writes off, so the last appended wins the blend; both front-ends insert any visible horizon
dome first. Two ordinary washes crossing still look order-dependent — a known, accepted limit.

**A visible horizon plane washes the whole view, and that is the drawing, not a defect.** The
plane at infinity is a full sphere around the eye at alpha 0.22 in that object's own hue, so
every other object is seen through it — which is what "the plane at infinity" looks like from
inside. The demo's last step builds one, so any capture taken after that step is tinted. Hiding
that row removes the wash entirely, which is how it was confirmed rather than assumed.

**Plane centring is stored, not recovered.** A join of line and point centres at the midpoint
between the point and its foot on the line; a weight expansion centres where the line meets the
new plane; a three-point seed plane centres on its centroid; everything else falls back to the
support. Many operand sets produce an identical plane multivector, which carries no memory of
what built it. Excluded from save and load.

**A shader trap worth keeping.** The round-point cut is gated on a `u_isPoint` uniform, because
`gl_PointCoord` is undefined for any primitive but a point: on Mesa's llvmpipe it read as zero
and the cut discarded **every line and triangle in the scene**, while points drew correctly.
Measured by drawing the furniture bucket as points, which showed the vertices were reaching the
GPU untouched.


Camera
---

Orbit camera: target, distance, azimuth, elevation, field of view. World up +z; elevation
limit ±(π/2 − 0.02); distance 0.05 … 500; **clip planes derived from the orbit distance, never
stored** — far 20 ×, near ÷ 400 — so the frustum keeps its shape and the depth buffer's
precision stays constant. Default view: target (0, 0, 1), distance 19, azimuth 1.05, elevation
0.42.

Aiming is a standing offer applied once per frame: aim at the open session's staged multivector
if there is one, else at the sole selected object. Horizon point along its own direction;
horizon line along the first axis spanning perpendicular to its normal; horizon plane not at
all; anything finite at the same representative point the ring is drawn on.

The three subtleties are implemented as three distinct operations, each with a driven test:
`offer` ignores a goal already held and reads its start off the live camera; `abandon` keeps the
goal and marks it delivered, for a camera the user moved; `release` clears it, for a rule with
nothing to aim at. All four cases from the brief are tested — pan with nothing selected, pan
with an object selected, grabbing mid-ease, and re-selecting after a deselect. The storyboard
aims through the same call but lands instantly.


Numbers, Colour, Typography
---

- **Four significant digits**, derived digit by digit in `format.nim`, so both backends run the
  same code. The C runtime's `%.4g` is called through `snprintf` purely as a reference the test
  compares against over twenty values. **Measured**: they agree on all twenty but negative
  zero, where the platform writes `-0` and this tool writes `0`; the test pins that one
  difference rather than hiding it. Nim's own `formatFloat` is not the reference — it keeps
  trailing zeros on one backend and ignores the requested precision on the other.
- **Palette**: thirteen slots, structural first, five assignable hues last as one contiguous
  block, with a compile-time assertion that they are the tail. Muting blends 0.6 toward a
  colour's own luminance and drops alpha to 0.55; axis colours carry their 22% blend baked into
  the table.
- **The palette's separations are measured, by this project's own validator.**
  `core/colorimetry.nim` implements CIEDE2000 and the severity-one deficiency matrices of
  Machado, Oliveira and Fernandes (2009); `tools/palette_check.nim` prints every separation and
  fails a build where one is below its floor; `tests/suite.nim` asserts the floors; and
  `tools/palette_reference.py` recomputes the same table through `colorspacious`, a library
  written by someone else, so the implementation is checked rather than trusted. The formula
  itself is checked against the published test pairs of Sharma, Wu and Dalal (2005).

  What the measurements say about the brief's own RGB values:

  | Claim | Measured |
  |---|---|
  | Ten assignable pairs, ΔE ≥ 15 | Holds; the closest is Olive/Jade at 27.15 |
  | Ten assignable pairs, hue ≥ 20° | Holds; the closest is Olive/Jade at 48.55° |
  | One pair in the 6–8 deficiency band, and only one | Holds exactly: Jade/Cobalt at 7.86, every other pair ≥ 11.02 |
  | Each hue ≥ 14 from the reserved magenta, worst vision | Holds; the closest is Rose at 15.41 |
  | Each hue clears the axis colours at a looser floor | Holds at ΔE ≥ 7.5 and hue ≥ 18°, which is where the palette actually sits; the brief states no number, and the binding pair is Cobalt against the z axis at 7.91 and 18.82° |

  The deficiency model matters and is recorded: the plane-projection model of Viénot, Brettel
  and Mollon (1999) was implemented first and reads Jade/Cobalt at 3.53 and Rose/magenta at
  9.72 — below the brief's floors. The Machado matrices, which is what validators in common use
  apply, put both inside them. Neither model is wrong; the numbers in the brief are the
  Machado-style ones, and this project measures the same way.
- **Typography**: Noto Sans for UI, Noto Sans Math for operators and bold operands, Noto Sans
  Symbols 2 for the stars and the abandon cross, and **Commit Mono for code, data and figures**
  — coefficient readings, camera fields, diagnostics numbers. Every face is **vendored**, from
  the fontsource CDN, rather than read from the machine: a face installed on the build machine
  is a face a viewer may not have, and both targets must draw the same glyphs. The desktop
  atlas merges them by codepoint and carries two families; the page embeds them and declares
  the math and symbol faces under the sans family name, with the mono stack naming the sans
  family after its own, so a bold operand inside monospace text still finds a glyph. Noto Serif
  is vendored but not embedded in the page, because the page writes no prose.
- **Glyph coverage is measured by rendering**, not by asking whether a face loaded: the headless
  driver rasterises each of the 30 non-ASCII codepoints the tool writes against each family and
  compares the bitmap against the notdef and blank glyphs. All 30 pass. The desktop atlas asks
  each face whether it carries a codepoint — `stb_truetype` reports glyph index zero when it
  does not — rather than trusting a range table.
- **Font payload, measured**: subsetting each vendored face to the codepoints the tool writes
  (the list derived from the core, not transcribed) makes 49 KB of faces and a page under
  600 KB, which works with no network access. Embedding the whole faces instead measured
  4.9 MB. Commit Mono arrives as a variable font and is instantiated at weight 400 before
  subsetting: shipping a whole design space to draw one weight is payload for nothing.


Front-Ends
---

**Browser.** One self-contained HTML file: shell, subset faces, compiled core, glue. The glue
does buffer upload and draw calls, DOM construction, event wiring, binary packing through
`DataView`, and download — nothing else. The selection is kept in the core; the glue holds only
a render snapshot. Drawer: four sections, alphabetical, only `objects` open. The chip row's
container carries the z-index, because fixed positioning opens a stacking context. The
outside-tap listener excludes the canvas, the drawer and the chip row, since it fires on
pointer-down, before a tap resolves.

**Desktop.** GLFW, GL, and a hand-rolled immediate-mode panel. Chosen over a vendored GUI
toolkit: the panel needs a dozen control kinds and a merged font atlas, and a toolkit would have
brought a C++ build and a vendored config header this project must not edit. Cost: the panel's
controls are plainer than a mature toolkit's, and its operation picker steps with ‹ › rather
than dropping down a list. The panel is 440 px wide and nothing inside it carries a hardcoded
width. An unselected segmented option is filled and bordered, because a transparent one
disappears into the scene. Row buttons are placed from a width measured before the run.

**Parity.** Both front-ends read the same catalogue, the same element names, the same numbers,
the same palette, the same selection semantics, the same session table, the same undo scope,
the same file format, the same animation numbers and the same drag mapping — because each is
one function in the core. The browser reads the animation duration and curve across the
boundary into CSS custom properties at startup.


Image Export And Capture
---

- **PNG** through the platform's deflate library, every scanline filter zero. A codec is an
  external concern; this project derives the algebra, not the codecs.
- **GIF** with a fixed 6×6×6 colour cube plus a 40-step grey ramp, rather than a per-frame
  optimal palette: the frames share one dark scene palette, and a fixed table keeps an object
  on one colour between steps. Cost: banding on the translucent washes.
- **The LZW code-width trap is real and was caught by its test.** The encoder must widen one
  entry later than its own table width suggests, because the decoder adds its entry one symbol
  later and reaches each width first. The first implementation widened at the natural point;
  the independently written decoder in `tests/suite.nim` failed at the first widening, and a
  full-size frame decoded 8042 of 655360 pixels before hitting an out-of-range code. After the
  fix the same frame decodes to exactly 655360 pixels, and **Chromium renders the animation** —
  an independent reader, not this project's own decoder.
- **Capture mode** writes one image per step plus the GIF, distinguishes reached from focal,
  draws reached-but-not-focal muted rather than hidden, lands the camera instantly, and
  reorients through the closed-form inverse of the camera's own forward-direction formula for a
  horizon step before restoring the default view.
- **Arenas**: a permanent one sized to the capture run's own measured requirement — one frame
  of pixels plus one of indices, per step plus the opening frame — and a frame one reset after
  each throwaway unit of work. The interactive loop asks neither for anything.


What Is Verified, And What Is Not
---

**Verified by running:**

- The shared suite passes on the C backend in two configurations (default; and
  `item_capacity=32`, `history_capacity=8`, `label_capacity=24`) and on the JS backend.
- Every invariant the brief names as requiring a test has one: slot stability across removal,
  both pick boundaries and all three priority pairings, a meet outside the drawn disc, the
  line's two-segment projection exactness, derived basis names against the library's printing,
  the two formatting paths agreeing, the palette's categorical count, the tween's mid-flight and
  arrival behaviour, history to capacity and back, and a scene round-trip.
- The browser bundle was driven headlessly with **real synthetic mouse and touch events** at
  the platform's own input layer: 24 checks, all passing, including a drag that derives an
  object, undo and redo, a composing session that writes nothing before save, a long press, a
  tap, and a file round-trip through the page's own encoder.
- The desktop build renders under Xvfb with Mesa's software rasteriser; the screenshots and all
  twelve capture frames were **regenerated and looked at**.
- Nim's own lexer, parser and macros test categories pass with the compiler change.

**Not verified, stated plainly:**

- **No human has read this code line by line, and no human has driven either build.**
- The 6.7° visible-gap figure for the rejected line anchoring, and the ~150 ms/frame and
  ~90 ms/frame browser figures quoted as reasons in the brief, are the brief's measurements and
  were not re-measured.
- **No frame-rate target can be assessed from this container**: there is no GPU, and software
  rasterisation dominates every frame. `--timings` prints the numbers it measures and says so.
- Touch was driven synthetically, never by a finger; the gesture constants are sized against the
  brief's stated contact patch, not against a device.
- The desktop panel's text field commits on Enter or on a click elsewhere; keyboard navigation
  between fields, selection within a field and clipboard are not implemented.
