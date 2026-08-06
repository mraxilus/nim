Requirements — RGA Visualiser
===

_A brief for building this tool from nothing. Not a description maintained alongside the
code: `PROVENANCE.md` is that. Everything here is a requirement on the finished artifact,
stated so an implementer who has never seen the source or a screenshot can satisfy it._

Read the whole document before writing any code. Sections 1–3 are constraints that decide
the shape of everything after them.


1. What To Build
---

An interactive visualiser for the **rigid geometric algebra of 3D space** — the degenerate
4D projective geometric algebra Eric Lengyel writes as RGA. A user places points, lines and
planes in a 3D scene, selects them, applies the algebra's operations to derive new objects,
and watches what those operations mean geometrically.

Two front-ends ship, and they are the same program:

| Target | Runs as | Presentation |
|--------|---------|--------------|
| Desktop | native binary | immediate-mode GUI over a native windowing/GL stack |
| Browser | single self-contained HTML file | DOM/CSS panels over a WebGL canvas |

Plus a **storyboard**: a scripted construction the desktop build runs headless, writing one
image per step and an animated GIF, so a build can be checked by looking at it.

The tool is a **testbed for the algebra library**, not a product built on top of one. That
inverts the usual priority: where a rendering convenience and a faithful use of the algebra
conflict, the algebra wins and the convenience is documented as a rendering-only choice.


2. Non-Negotiable Constraints
---

These are the rules a reviewer will check first. Each has cost the project real bugs.

1. **One geometry core, two presentation layers.** Every domain rule — the operation
   catalogue, picking, drag semantics, selection order, palette lookup, number formatting,
   camera aiming, the scene model, the file format — is written **once**, in the core
   language, and both front-ends call it. The browser's hand-written script layer is
   permitted only genuinely browser-only concerns: buffer upload and draw calls, DOM
   construction, event wiring, binary packing through the platform's own facilities, file
   download. **Anything that derives a value from domain data belongs in the core**, exposed
   across the boundary. Repeated audits of this project found drift here every time: a grade
   computed by counting digits in a name, a button-to-operation mapping reimplemented, render
   constants hand-copied. Each was a bug waiting.
   **Make the boundary structural, not documentary.** Put the core, the desktop-only modules
   and the browser-only modules in three sibling directories, so which path may reach a module
   is read off its import path rather than off a table someone has to keep in step. This
   project kept that table in a module doc for many rounds; every audit found it stale. A core
   module needing something only one path has states that as a conditional compilation guard,
   so a shared caller reaching for it fails to build rather than failing at run time.
2. **Never depend on what the project exists to understand.** The algebra is the subject;
   derive it. External concerns — windowing, GL, codecs, fonts — are fine, and each is
   justified where it is used. There is **no hand-rolled vector arithmetic** anywhere in the
   application: a midpoint is a sum of unit-weight points read back through the algebra's own
   position projection, not an averaged coordinate triple.
3. **Duplicate only what a real constraint forces.** Where one target cannot share the
   other's dependencies, a second copy is allowed — in the *core* language, marked with a
   comment naming its sibling. A fix to one copy is not finished until the other is checked.
4. **Verify by running, not by reasoning.** Compiling is not evidence. Render the output and
   look at it; drive the UI with real synthetic events at the platform's event layer, not by
   calling handlers directly; read exported bytes back with an independently written decoder.
   Several bugs here passed review and passed tests because a test called a handler and
   bypassed the wiring that was actually broken.
5. **Measure, don't argue.** Colour separation, glyph coverage, frame cost and gesture
   behaviour are all measurable. Every claim of that kind in the delivered documentation must
   say whether it was measured or assumed.
6. **No allocation in the interactive frame loop.** Fixed-capacity storage of statically known
   extent; dynamic allocation confined to setup, to compile time, or to once-per-click paths.


3. Language, Toolchain, Dependencies
---

- Pick one systems language that compiles both to a native binary and to browser-executable
  code from the same sources. The whole two-target design rests on it. (This build uses Nim,
  compiling to C++ for the desktop and to JavaScript for the browser.)
- The algebra library is **vendored, not written inline** — a separate library layer with its
  own tests, consumed by the application. If none is available, write it as a library first
  and keep the boundary clean.
- System packages needed: a windowing/input/GL-context library, OpenGL headers, a deflate
  library for image export, and the text faces named in §21. Record each in a
  `dependencies.list` file, one per line, each with a trailing comment saying what it is for.
  Anything compiled from source rather than linked carries its fetch command in a comment there.
- Compile-time configuration lives in a config file beside each entry point, not in
  command-line flags a future session has to rediscover. The algebra's dimension and metric
  are compile-time defines; a build asserts them and fails with a message naming the correct
  flags if they are wrong.


4. The Algebra
---

4D rigid (degenerate) projective GA, 16 basis elements. Written in the source's own notation:

| Grade | Elements | Geometry it represents |
|-------|----------|------------------------|
| 0 | `𝟏` | scalar |
| 1 | `𝐞₁ 𝐞₂ 𝐞₃ 𝐞₄` | **point** |
| 2 | `𝐞₄₁ 𝐞₄₂ 𝐞₄₃ 𝐞₂₃ 𝐞₃₁ 𝐞₁₂` | **line** |
| 3 | `𝐞₄₂₃ 𝐞₄₃₁ 𝐞₄₁₂ 𝐞₃₂₁` | **plane** |
| 4 | `𝟙` | antiscalar |

That element order is load-bearing: it is the order coefficients are stored, saved and
displayed in. Grade 4 is one-dimensional, which is why every plane at infinity is the same
universal object.

An object's **shape** is read from the grade of the multivector: grade 1 point, grade 2 line,
grade 3 plane. A multivector spanning several grades has no shape and reports "mixed grade,
nothing to draw" — that is a legitimate, displayable outcome, not an error.

An object is at **horizon** (infinity) when its weight vanishes: only a direction remains.
The three horizon cases are distinct and all three must be drawable (§10).


5. Operation Catalogue
---

Exactly 27 operations, in this order, with these labels. Each label is the operation's
notation, then **two spaces**, then its English name. `𝐦` and `𝐧` are the first and second
operands.

| # | Label | Arity |
|---|-------|-------|
| 1 | `𝐦⊖  attitude` | 1 |
| 2 | `𝐦∩  support` | 1 |
| 3 | `𝐦∪  antisupport` | 1 |
| 4 | `𝐦∙  bulk` | 1 |
| 5 | `𝐦∘  weight` | 1 |
| 6 | `𝐦ˆ  unitize` | 1 |
| 7 | `𝐦ˍ  left complement` | 1 |
| 8 | `𝐦¯  right complement` | 1 |
| 9 | `𝐦★  bulk dual` | 1 |
| 10 | `𝐦☆  weight dual` | 1 |
| 11 | `𝐦˜  reverse` | 1 |
| 12 | `𝐦˷  antireverse` | 1 |
| 13 | `−𝐦  negate` | 1 |
| 14 | `𝐦 + 𝐧  add` | 2 |
| 15 | `𝐦 - 𝐧  subtract` | 2 |
| 16 | `𝐦 ∧ 𝐧  wedge (join)` | 2 |
| 17 | `𝐦 ∨ 𝐧  antiwedge (meet)` | 2 |
| 18 | `𝐦 ⟑ 𝐧  geometric product` | 2 |
| 19 | `𝐦 ⟇ 𝐧  geometric antiproduct` | 2 |
| 20 | `𝐦 ∙ 𝐧  inner product` | 2 |
| 21 | `𝐦 ∘ 𝐧  inner antiproduct` | 2 |
| 22 | `𝐦 ∧ 𝐧★  bulk expansion` | 2 |
| 23 | `𝐦 ∧ 𝐧☆  weight expansion` | 2 |
| 24 | `𝐦 ∨ 𝐧★  bulk contraction` | 2 |
| 25 | `𝐦 ∨ 𝐧☆  weight contraction` | 2 |
| 26 | `𝐧 ∨ (𝐦 ∧ 𝐧★)  central projection` | 2 |
| 27 | `𝐧 ∨ (𝐦 ∧ 𝐧☆)  orthogonal projection` | 2 |

Requirements on this table:

- **It is one table, read by both front-ends.** Do not keep a second plain-ASCII copy for a
  GUI whose font cannot render these glyphs — fix the font (§21). Two tables drift; this one
  did, in boldness, in symbol placement and in whether an English name existed at all.
- Notation comes from **each operator's own declaration in the algebra library**, never from
  a summary table at the top of a file. Summary tables drift; this exact trap produced wrong
  operator notation twice, including prefix where the declaration says postfix. Verify by
  extracting codepoints, not by eye — a proper minus sign U+2212 against a hyphen is
  invisible in an editor.
- The five accented operands use **spacing modifier letters** (`ˆ` U+02C6, `ˍ` U+02CD,
  `¯` U+00AF, `˜` U+02DC, `˷` U+02F7), never the combining marks the same accents also exist
  as. An immediate-mode GUI has no text shaper and advances by each glyph's own width, so
  combining marks land beside the operand instead of over it, and two of the five become
  indistinguishable. A spacing modifier carries its own advance and both renderers place it
  identically. This was found by rendering all 27 entries and reading them.
- `attitude` is postfix here by deliberate exception, for consistency with the other unary
  entries, even though its declaration reads prefix. Note the exception where you write it.
- **Deriving a label**: applying an operation names the result by substituting the real
  operand names into the notation's symbolic prefix only. Cut the English name off first —
  it is full of ordinary m's and n's. Substitute through two sentinel passes so an operand
  whose own name contains a placeholder is not re-substituted, and so a template using the
  second operand twice substitutes both. Derived labels therefore never contain bold letters.


6. Objects And Scene
---

- **Capacity is fixed**: 64 items, labels up to 40 **bytes**, both overridable at compile
  time. An item carries geometry, label, colour, visibility, a birth timestamp, and an
  optional anchor override (§9).
- **A label is cut on a character boundary, and a cut label says it was cut.** The cap counts
  bytes while a derived name carries three-byte operator glyphs, so copying byte by byte
  leaves a partial character and invalid UTF-8 — which the JS backend prints as a raw percent
  escape in the middle of an object's name. Truncate whole characters only, and append `…`,
  so a shortened name never reads as a complete one. This is the same byte-versus-character
  trap as the scene format's label field (§16); fixing one is not fixing the other.
- Storage is **structure-of-arrays addressed by a slot assigned once and never moved**, with
  free slots on an intrusive free list so add and remove are O(1). The invariant everything
  else relies on: **a slot number stays valid until its item is removed.** A shift-on-delete
  array renumbers every cross-frame index — hovered, dragged, selected, operand — and was
  rejected for exactly that.
- Because slots are held across frames, **three liveness guards are mandatory**: the single
  choke point that projects an anchor to screen reports "nothing to draw" for a dead slot;
  ending a drag checks both source and destination are alive before reading either label;
  removing an item clears the highlight on both render paths.
- Colours are assigned by cycling the categorical run (§8) as objects are added.


7. Number And Element Formatting
---

- Basis element names are **exactly what the algebra library's own printing produces**:
  `𝟏` scalar, `𝟙` antiscalar, bold `𝐞` with subscript digits for the rest. **Derive** them
  from the element enumeration rather than transcribing a table, so a build of another
  dimension names its own elements, and assert in a test that each derived name equals what
  the library prints for that element alone.
- Magnitudes read to **four significant digits, not four decimal places**: `3.5` reads
  `3.5`, not `3.5000`; `1664` keeps its integer part; `1234567` becomes `1.235e+06`. No
  trailing zeros, no trailing point. Every editable number obeys this — coefficients and all
  seven camera fields alike.
- One rule, and if the two targets need two mechanisms to implement it (a C runtime is not
  available in a browser), a test must run both over the same twenty values including edge
  cases and assert they agree. Beware: several standard libraries' `%g` equivalent ignores
  the requested precision on a JS backend and returns the shortest round-tripping form.
- Diagnostics readings are the deliberate exception and stay **fixed-width**: a live number
  that changes width every frame is harder to read than a padded one.


8. Colour
---

Eight structural slots and five assignable hues, in one enumeration, declared in this order —
structural first, categorical last as one contiguous block so a picker can walk it:

| Slot | Role | RGB (0–1) |
|------|------|-----------|
| Backdrop | framebuffer clear | 0.063, 0.075, 0.102 |
| AxisX | world x axis | 0.757, 0.279, 0.279 |
| AxisY | world y axis | 0.360, 0.736, 0.360 |
| AxisZ | world z axis | 0.338, 0.481, 0.830 |
| Grid | ground reference grid | 0.180, 0.204, 0.259 |
| Guide | construction helper, plane normal, edit ghost | 0.286, 0.322, 0.400 |
| Outline | selection ring | 1.0, 1.0, 1.0 |
| **Invalid** | reserved — an object that is *wrong* | 0.612, 0.000, 0.722 |
| Rose | assignable | 0.690, 0.090, 0.373 |
| Copper | assignable | 0.812, 0.451, 0.275 |
| Olive | assignable | 0.341, 0.431, 0.000 |
| Jade | assignable | 0.133, 0.655, 0.478 |
| Cobalt | assignable | 0.357, 0.565, 0.780 |

Constraints these values satisfy, all **measured with a colour-vision validator, not judged
by eye**:

- Every one of the ten pairs among the five assignable hues clears normal-vision ΔE ≥ 15 and
  ≥ 20° hue separation, so lightness can never stand in for a hue difference. One documented
  exception sits in the 6–8 legal-with-secondary-encoding band; the objects wearing it carry
  shape and screen position as that secondary encoding.
- Each assignable hue clears a hue-distance and ΔE floor against all three axis colours, so a
  thin fixed axis line is never mistaken for a filled object. Axis safety is *looser* than
  object-to-object safety on purpose — a thin line needs less separation than two adjacent
  fills — and tightening it is what once crushed the whole palette into one teal-blue arc.
- Every assignable hue clears CVD ΔE ≥ 14 from the reserved magenta.
- **Do not refill the palette back up to eight or sixteen.** It was tried and measured:
  seven hues across the remaining arc put two at CVD ΔE 0.4. The axis hues flank the reserved
  magenta on both sides, leaving one warm arc and one cool, 162° in total. Five is what fits.
- Hue distance alone is the wrong instrument: a blue 88° from magenta measured CVD ΔE 6.6,
  because blue and magenta converge under deuteranopia.

Rules:

- **Structural slots are never offerable as an object's colour** in either front-end — an
  object wearing the backdrop, an axis, or the selection outline is invisible or reads as
  something else. Name that boundary **once** (first categorical slot, count) and derive both
  pickers and the cycler from it, with a compile-time assertion on the count so appending a
  structural slot after the last hue fails the build.
- **Invalid is reserved for what is wrong**, and never assignable to an object. It exists so
  the rest of the palette can be held clear of it, and so seeing magenta always means
  something is wrong. Its one use is the rubber-band of a drag standing over a pair that
  makes nothing (§12). Whatever wears it must add a word or a marker — magenta reads as blue
  under deuteranopia, which is where every assignable hue sits furthest from it.
- **Never remove or reorder an enumeration entry** once scenes have been saved: ordinals are
  written to file, and shifting them silently recolours saved work.
- **Muting** blends a colour toward its own luminance by 0.6 and drops alpha to 0.55 — not
  replacing it with the grid colour, which made muted objects indistinguishable from the
  ground. Axis colours additionally carry a permanent 22% blend toward their own luminance,
  baked into the table rather than computed, so a bright RGB trio stops competing with
  categorical objects.


9. Drawing The Geometry
---

**Point.** A round point, 9 px.

**Line.** Drawn as **two segments meeting on the line at its support**, each running from
there out to one of the line's two vanishing points — that is, toward `eye ± horizon radius ×
axis`. Requirements behind this shape:

- A vanishing point is a property of the *eye*, not of the line. Anchoring an end a fixed
  reach from the line's own support stops short of the vanishing point by roughly the
  eye-to-line separation over that reach — measured at ~6.7° of visible gap for a line 40
  units out. Anchoring both ends to the eye closes the gap at both ends.
- One segment cannot do it: a segment running eye to eye passes through the eye and projects
  to a point.
- Each segment has one end on the true line and one off it, so both lie in the plane through
  the eye containing the line; that plane projects to a single screen line, so the pair draws
  **exactly** over the true line's projection however far the far ends sit in world space.
  Verify this numerically (screen skew to floating-point precision), not by argument.
- Meshes rebuild against the current eye every frame, so the exactness survives orbiting.
- The far ends sit several world units off the line along the view ray, so occlusion against
  other objects is approximate there. Accepted.

**Plane.** A solid rim plus a flat translucent fill (alpha 0.16) bounded by that rim. No
crosshair, no ruled grid, no anchor marker. Flat rather than fading, because the rim already
marks the boundary. Fixed radius 8 world units around the plane's anchor — **not**
camera-distance scaled, which visibly resizes a plane as the camera orbits. The normal draws
as a bare shaft at 0.25 × extent, no tip.

The drawn radius is a **rendering choice only**. Every construction path reads the full
untruncated multivector, so a meet lands correctly arbitrarily far outside the drawn disc.
Write a regression test asserting exactly that.

**Horizon objects are drawn as sky, not as extended finite geometry**, all anchored to the
eye every frame so they have zero parallax on translation and turn only with rotation:

- horizon point → a fixed star at `eye + horizon radius × heading`;
- horizon line → a great circle around the eye;
- horizon plane → a **full**-sphere dome around the eye at alpha 0.22. Full, not
  hemispherical: an orbit view sits elevated and tilted down, so cutting the dome at the
  eye's horizontal removes sky the camera can see. Every horizon plane is the same universal
  object and carries no orientation to render.

**Draw-order invariant.** Translucent triangles share one unsorted bucket drawn with depth
writes off, so among translucent draws whichever is appended last wins the blend. Both
front-ends must therefore insert any visible horizon dome **first**, before every other
visible object, so an ordinary plane's wash blends over it whatever slots they occupy. Two
ordinary washes crossing still look order-dependent — a known, accepted limit.

**Furniture** (ground grid, world axes) reaches a distance derived from the far clip plane,
not from orbit distance, so it reads as extending indefinitely however far the camera dollies.

- Grid cell size **steps with reach**: base 2.0 world units, doubled until no more than 24
  cells cover the reach. Doubling rather than dividing evenly, so a coarser grid's lines fall
  exactly on a subset of the finer one's and the change reads as alternate lines dropping out
  rather than the grid sliding. A cell size fixed against a camera-following reach overruns a
  fixed vertex budget outright, long after cells crowd below one screen pixel.
- Each grid line is cut into 8 pieces fading **per vertex** (not per piece, so interpolation
  stays smooth) from full alpha at 0.03 × extent to zero at 0.12 × extent.
- The ground plane skips the two lines that would coincide with the x and y axes, avoiding
  depth fighting. Axes use the standard convention: x red, y green, z blue.

**Line widths**: furniture 1.5 px, scene objects 2.5 px, with a compile-time assertion that
object lines exceed furniture lines so reference geometry recedes. **Draw the width as
geometry, never as a draw-call setting**: a line width is a hint a target may ignore, and
most WebGL implementations clamp it to one pixel, so a build that sets it has two widths on
one target and one on the other. A quad offset at each end by half a width of that end's own
world-per-pixel holds the width constant on screen and converges with the line as it
recedes. **Clip to the near plane before building it** — the proportionality that keeps the
width constant does not survive a depth clamped behind the eye, and the failure is not
subtle. Whatever smoothed lines before (`GL_LINE_SMOOTH`) no longer applies; ask for a
multisampled framebuffer and fall back gracefully where no visual offers one.

**Vertex budget** is fixed per primitive kind and asserted, not grown on demand. Size it from
the worst case a full scene can reach and check that case by building it, not by arithmetic.

**Creation-anchored plane centring.** A plane's rim and fill centre on an anchor chosen at
construction time from the operation and the operand shapes, not always on the plane's own
closest-to-origin support, which reads wrong for operands that do not straddle the origin
symmetrically. Join of a line and a point centres at the midpoint between the point and its
orthogonal projection onto the line; weight expansion of a point and a line centres where the
line meets the resulting plane; a three-point seed plane centres on their centroid; everything
else falls back to the support. **This must be stored, because it is not recoverable
afterwards** — many different operand sets produce an identical plane multivector, which
carries no memory of what built it. It is a rendering hint and is excluded from save/load.


10. Camera
---

Orbit camera: target point, orbit distance, azimuth, elevation, vertical field of view.

| Quantity | Value |
|----------|-------|
| World up | +z |
| Elevation limit | ±(π/2 − 0.02), short of the pole |
| Orbit distance | 0.05 … 500 |
| Far clip plane | 20 × orbit distance |
| Near clip plane | orbit distance / 400 |
| Default view | target (0, 0, 1), distance 19, azimuth 1.05 rad, elevation 0.42 rad |

**Clip planes are derived from orbit distance, never stored.** A stored pair keeps its
construction-time value through every dolly — the far plane sat at a fixed 400 while the
orbit limit is 500, so dollying past it clipped the whole scene away, and well before that a
line's far end came back inside the frame and read as stopping in mid-air. Both scale
together, so the frustum keeps its shape and depth-buffer precision (a function of the
far-to-near ratio) stays constant instead of decaying as the camera pulls back.

**Camera aiming.** The camera moves itself to show what the user is working on. One rule,
shared by both front-ends and applied **once per frame** rather than at each event:

> Aim at the open edit session's staged multivector if there is one, else at the sole
> selected object.

That second clause is what carries applying an operation, releasing a drag and stepping the
demo, since each already leaves its new object solely selected — none of them needs to know
the camera exists. Where to aim, by case: a horizon point along its own direction; a horizon
line along the first axis spanning perpendicular to its normal (no single direction faces a
whole great circle); a horizon plane not at all, since it fills the sky; anything finite at
the same representative point the selection ring is drawn on.

The move is **eased** over the standard animation duration and curve (§22). Retargeting reads
its start off the **live camera**, not off the previous goal, so a goal that moves every frame
— a coefficient being dragged — is one continuous chase rather than a restarting jerk.
Offering a goal already held is ignored, so a caller may aim every frame without the ease
restarting forever and never arriving.

**This standing-offer shape has three subtleties, and getting any of them wrong breaks the
camera.** They are stated as requirements because each was a real bug:

- On arrival the tween **keeps its goal** and marks itself arrived, which is what stops it
  writing to the camera. Clearing the goal on arrival makes the standing offer look new next
  frame and re-arms the ease from wherever the user just panned to, dragging the camera
  straight back — **panning is dead for as long as anything stays selected**, and returns on
  deselect. It presents as a touch bug; it is neither touch- nor browser-specific.
- A camera the user moves must **abandon** the goal — keep it, mark it delivered — not
  release it. Releasing clears the goal, so the offer is simply re-made next frame and the
  camera is taken straight back. Distinguish the two operations explicitly.
- **Releasing** belongs to the offer's own side, called when the rule has nothing to aim at.
  Clearing the goal outright is what lets picking the same object again aim at it afresh
  rather than be recognised as already delivered.

Cover all four cases with driven tests: pan with nothing selected, pan with an object
selected, grabbing the camera mid-ease, and re-selecting after a deselect.

The storyboard aims through the same call but **lands instantly** — a captured frame must
never show a half-finished pan.


11. Selection, Hover, Picking
---

**Selection is an ordered fixed-capacity list of slots, not a set.** Order is the whole point:
an operation reads its operands positionally, so the first slot picked is `𝐦` and the second
`𝐧`. The rule that one pick implies a unary operation and two or more a binary one lives
beside the list and is read by both front-ends, so the two can never disagree about what a
selection means.

Selection is deliberately **not** part of the scene: never saved, never on the undo timeline,
and cleared outright by a successful undo or redo, since a restored snapshot's slot numbers
need not match what was picked. Prune dead slots after any removal — a freed slot goes
straight back to the next add, and a stale pick would silently reattach to an unrelated object.

**"Just built" and "currently selected" are one concept with one mechanism**: a plain white
outline drawn **once per selected slot** in both front-ends, with hover drawing the identical
outline fainter. Weight is the only thing that separates the two, so hovering something
previews exactly what selecting it will draw. Every construction path replaces the selection
with the slot it just created.

**The outline echoes what it surrounds**, because a marker says "this one" best when its own
shape is the shape of the thing: a ring on a point, two flanking rails on a line, a circle
lying *on* a plane, two flanking circles of the sky a horizon line circles, the screen's own
edge for the sky a horizon plane is. All keep one clearance from the object's *drawn* size, so
changing a draw size moves its marker with it. Every shape must have a marker: an object drawn
fixed to the eye still offers something to surround, namely whatever is drawn.

**How a marker fills says which object it is.** A ring sweeps, a plane's circle opens from its
disc's centre, a horizon line's bands close in from outside any view (it has no support to grow
from), and a horizon plane's boundary expands from the middle. Two rules the shapes must obey
while filling:

- **Growth is bounded by the view, never by an object's own projected length.** A line's rails
  run to vanishing points at wildly unequal screen distances — a measured ratio of 314 — so
  growing each by a fraction of itself makes one half finish hundreds of times sooner and puts
  both off screen almost immediately. Growing toward a vanishing point is growing into nothing.
- **The sky's boundary expands as a circle and becomes the screen edge as it reaches it** —
  edge midpoints first, corners last — rather than scaling a rectangle, which arrives at every
  edge at once and reads as a shrunken copy of the screen. Sample the corner directions
  explicitly: a corner missed by a fraction of a sampling step is a corner visibly cut off.

**On touch a marker must clear the finger filling it**, swelling partway through the hold to a
diameter clear of a thumb's contact patch and settling back to its true size exactly, so a
finished marker is the same outline whichever pointer produced it. A mouse never sees it — a
cursor hides nothing. Measure this in the pixels the finger works in (below), on a real phone
profile: the number that was measured in framebuffer pixels and reported as clearing a
fingertip was wrong by the device pixel ratio, and a thumb, not the suite, is what said so.

An oversized-silhouette outline with its own shader and mesh set was built and **deleted
entirely** in favour of this. Do not build one. Among other reasons, browsers clamp line width
to 1 px, so it can never look right there.

**Two pixel spaces, and each layer works in exactly one.** The render layer works in
framebuffer pixels; the interaction and overlay layer — picking, hover, markers, anchors, menu
layout — works in **CSS pixels**, the units a reader's finger and eye actually work in, and is
told the viewport in those units rather than converting per point. Mixing them makes every
length silently scale with device pixel ratio, which is a bug in both directions at once: it
shrank a nominal 34-pixel point target to ~13.6 on a phone, and made "make the marker bigger"
mean nothing stable.

**Picking priority is strict: point beats line beats plane**, regardless of pixel distance,
once a shape's own radius is met. That priority is what makes generous radii safe — a wide
point radius overlapping a line behind it still resolves to the point. Radii: point 34 px,
line 24 px, both sized against a real fingertip's contact patch at phone density; a plane's
test is area-based, inside the drawn rim. Test both boundaries (one pixel inside picks, one
pixel outside does not) and all three priority pairings, so changing a constant fails a test
rather than only feeling different.

**Everything drawn is pickable, horizon included**, ranked so thin things beat wide ones:
point, finite line, horizon line, finite plane, horizon plane. A horizon object is anchored
nowhere in the scene, so test each against *what is drawn* — a horizon line against the great
circle it draws as, sampled the same way it is drawn; a horizon plane against everything,
since it is a dome over every direction.

That last one has a consequence the design must answer, not discover: **the cursor is then
over something almost everywhere.** A press on empty space becomes a camera move precisely
because nothing was under it, so a horizon plane must be a click and hold target and never a
drag handle — refuse it where a drag begins *and* where one lands, or orbit and pan stop
working the moment a sky joins the scene, and a release over nothing quietly takes the whole
sky as an operand. Clicking it selects it, since that is the only route a pointer has left;
a *tap* still counts it as empty space, because tapping empty space is a finger's only way to
dismiss a selection and touch reaches the sky by long-press instead. An object with no place
in the scene also has nowhere to put the floating menu that follows a selection: give it the
middle of the view, matching the marker drawn around the viewport.

Test both halves of a line: testing one leaves the other half unpickable, and which half that
is changes as the camera orbits. The hit test divides by each endpoint's depth, so it needs a
by-hand near-plane clip mirroring what the GPU does when drawing — this reach can put an
endpoint behind the eye.


12. Interaction
---

**Any gesture vocabulary must reveal itself.** A control the reader can only discover by
having been told about it does not count as reachable, however few keystrokes it takes once
known. Every gesture here either shows what it will do before it commits, or offers a menu
that names the alternatives — and a gesture that can build something must have a route to
the operations it cannot build, or it is a dead end.

**The written help is read one line at a time, so every line must survive being read alone.**
A reader opens a tab, finds the line they need, and leaves; they do not read the tab. So no
row may be circular ("drag one object onto another" → "make whatever the two of them make"),
lean on the row above it ("the same choice, without needing the other button"), or name
something internal the reader has never met ("the apply section", "dolly"). What a
two-column row genuinely cannot carry — which menu this is, what a wedge is — belongs in one
sentence above the tab's rows, written for someone who has just opened that tab and nothing
else. Both front-ends read that sentence and those rows from the same table, so neither can
drift from the other.

**One word, one meaning.** Objects are *selected*; operations are *chosen*. A word doing two
jobs tells the reader nothing about which is meant, and the two are adjacent here — the
selection, and the wheel of operations a drag offers.

**Mouse and pen, both front-ends.** Drag from one object onto another to derive a third.

**The press target chooses the scheme; the button chooses whether you are asked.** Press an
object and the drag constructs; press empty space and it moves the camera (left orbits,
right pans, wheel dollies). Orbit 0.008 rad per pixel; pan 0.0016 × orbit distance per
pixel; one wheel notch scales distance by 1.12. A plain click — under 0.35 s and 6 px of
movement — selects instead of dragging; shift-click toggles into a multi-selection; a plain
click on empty space clears it. Both bounds are **one rule in the core**, asked at the
release: a press over an object must start its drag eagerly, so whether it was a click is
not knowable until the release. Six pixels rather than the fingertip slop, because a mouse
on a desk does not roll. Every duration in the gesture vocabulary is in **seconds**, on the
same clock an object's birth is stamped with; a front-end whose own clock reads otherwise
converts once, at its edge.

| Button | Starts |
|--------|--------|
| left | a drag that takes the algebra's own answer on release |
| right | the same drag, with the choice menu open from the moment it reaches a target |
| middle | nothing — no operation may depend on hardware most trackpads lack |

**What a drag builds is derived from the two operands, never from the button.** Join adds
grades and is drawable when they sum to at most the dimension; meet adds antigrades and is
drawable when those sum to at least it. At most one of the two is ever drawable for a given
pair, so a plain priority order — join, then meet, then projection — resolves every pair
with nothing to arbitrate. That property must be pinned by an exhaustive test over operands
in **general position**; a fixture whose operands lie on each other reads zeros that come
from the fixture, not the algebra, and proves nothing.

Some pairs make nothing at all. Such a drag must **refuse**: add no object, and say what was
degenerate. A scene must never gain a slot holding geometry with no shape.

**While dragging, show the answer.** Ghost what a plain release would build, in the same
appearance an uncommitted edit already wears. Tint the rubber-band by that answer, and use
the reserved invalid colour over a pair that makes nothing — the warning belongs before the
release, not in a message after it. That colour is never the only signal; the ghost is
absent at the same time.

**The choice menu** opens on the right button at once, or on holding still over the target.
Its choices sit at **fixed positions** that never move from pair to pair, with unoffered
ones drawn greyed rather than packed out. **One release rule: a release commits whatever is
under the cursor** — a choice if the menu is open, the derived answer if it is not, nothing
at the menu's own centre. The core resolves which choice a release landed on, so no
front-end can hold a second opinion about it. The menu latches its destination when it
opens: reaching a choice takes the cursor off the object.

The menu's fourth choice hands both operands to the full operation catalogue, in drag order.
Without it the gesture reaches three operations out of twenty-seven and stops.

Directional flick-marks are **not available on this path**: a construction drag has already
spent its direction reaching its target. Speed comes from the fixed positions and the second
button instead.

The button→meaning mapping is **one rule in the core**, called by both front-ends. They
number their buttons differently; that translation is the only part either may hold.

**Touch, browser.** The same invariant, not a second vocabulary: a finger that presses an
**object** constructs, one that presses **empty space** moves the camera. Two fingers pinch
to zoom and pan, and cancel any construction in progress. A long press (500 ms) selects an
object; once a selection exists, a tap (under 350 ms) toggles another in or out; a tap on
empty space clears. Show an opening hint naming these gestures.

A press begins as a hold. The first movement past the slop is the one moment it resolves —
into a construction drag where it landed on an object, an orbit where it did not — and it
never resolves twice. Touch has no second button, so the dwell is the only way to open the
choice menu there; that is what the dwell was sized for.

Touch is where a dwell measured on presence rather than stillness actually bites: a finger
crossing a large object is over it for well past the dwell while plainly still moving. Both
front-ends share one gesture core, so fixing the rule there fixed it for both.

Clear the hover reading once the last finger lifts. Touch has no continuous pointer position,
so hover only ever updates at a touch-down point; without the clear, the last reading sits
stale forever and its ring — only 20% dimmer than a selection ring — reads as a second
selected object.

**Keyboard, both front-ends.** Everything must be operable from the keyboard alone
(**WCAG 2.1.1, Level A**), and that includes the 3D view, not merely the panels around it.
The view is **one ordinary tab stop**: reached by Tab and left by Tab, with its own keys
answering only while it holds focus. Show that focus — a focus nobody can see is not one
(2.4.7) — and reuse the marker hover already draws rather than inventing a second.

**Never rebind Tab inside the view.** Cycling objects with it is the tempting binding and
risks a keyboard trap (**2.1.2, also Level A**); fixing one Level A failure by creating
another is not a fix. Traversal takes its own keys.

Where the widget set has its own keyboard navigation, **it must be switched on**. No amount
of binding keys in the application reaches widgets the application does not own.

That navigation will then claim the keyboard far more eagerly than a "does the GUI want this
key" flag suggests. **Measure what that flag actually reports before using it as the guard**:
the view's own keys must still reach the view while the reader is merely looking at the
scene, and must not while a field is taking text or navigation has landed on a widget.

Keys that move the camera move it by **one shared amount per press**, unlike the per-pixel
drag rates, which differ per front-end for a real reason. A press has no pixels in it.

The document-level "tap outside closes the floating menu" listener must **exclude the canvas,
the drawer and the chip row**. It fires on pointer-down, before the tap gesture resolves on
release, so including the canvas clears selection state before the gesture that should use it
has run.


13. Edit Sessions
---

Adding an object and editing one are the same gesture. Both front-ends run **one edit session
at a time**, in one of two modes:

|              | Composing (new)              | Editing (existing)                |
|--------------|------------------------------|-----------------------------------|
| Started by   | the top bar's `add`          | the row's `edit`                  |
| Backing slot | none — nothing in the scene  | the row's own slot                |
| Row shows    | `save` `✕`                   | `save` `✕` `hide` `remove`        |
| `save`       | adds the object              | writes the staged fields back     |
| `✕`          | discards; nothing was added  | reverts; the object never moved   |

Both stage the same things — sixteen coefficients, label, colour — and preview through the
same ghost. `hide`/`remove` are absent while composing because neither means anything for an
object that does not exist. The composing row renders at the top of the list, and `add` is
**disabled while a session is open**, so starting a second cannot silently discard the first.

**A session never writes to the scene before `save`.** That is what makes the preview safe: it
stays invisible to the scene's own item enumeration, and so to undo/redo, save/load and
picking. Writing a half-built object into a real slot breaks all four. The row is therefore
drawn from session state, not from a slot, and the session carries its own label storage
rather than a pointer into the scene's.

**Session state is a nested optional**, honest about the two modes: an optional session whose
own slot is optional while composing. **No sentinel slot standing for "new."**

**Ghost preview.** Editing any session field draws a live muted preview through the same
dispatch a real object uses, tinted with the construction-helper colour. One ghost serves both
modes — a direct consequence of unifying the sessions. An all-zero ghost must degrade to
"nothing to draw" through the existing no-shape branch with no special case. `save`, `✕`,
undo and redo all clear it.

Verify by driving both UIs: editing a coefficient leaves the stored object unchanged until
`save`; the item count is unchanged for a whole composing session; `✕` leaves count and object
untouched; a staged point adds exactly one vertex to the mesh. **Count, don't pixel-diff** —
animation drift between two runs pollutes a pixel diff with thousands of false differences.


14. Undo / Redo
---

Scoped to **scene-content edits** — add, apply (including drag and the touch flow), remove,
visibility toggle, recolour, and an edit session's `save`. One `save` records one entry
covering coefficients, label and colour at once; that committed moment is exactly what the
staged session exists to supply, since the widgets driving those three are continuous
multi-frame inputs that would otherwise flood the timeline.

**One fixed-size array of snapshots plus one cursor**, not separate past and future stacks.
The scene is a plain fixed-size value type, so recording is a value copy and the entry under
the cursor is always exactly the live scene. Undo and redo move the cursor and copy back; a
fresh edit truncates past it. Capacity 32; recording past it drops the oldest rather than
growing.

**Each entry records the camera the view stood at as that entry's own edit was made**, so
crossing a step in either direction restores that one camera and whatever appears or vanishes
does so on screen. Not the camera of the state arrived at, which hands back the view the
*previous* edit was made from — a different moment, arbitrarily long ago. A camera move
records no entry of its own, so an orbit alone is not undoable; say so where a user can read
it. A front-end holding a camera tween must abandon it on a successful step, or the standing
aim pulls the view straight off what was just restored.

Seed the timeline wherever the scene is initialised or replaced — startup, demo load, clear —
so undo never reaches past the moment tracking began. A successful undo or redo **clears the
selection unconditionally**. Expose whether undo and redo are available, and grey the controls
out when they are not.

Test by recording to capacity, walking all the way back and forward, and comparing against the
actually-recorded state at every step — with an approximate comparison, since exact float
equality is a compile error on these types (§24). Test the camera the same way, from two
distinct viewpoints, and verify it by driving each front-end: build, orbit away, undo, and
look at where the view ends up and whether it stays there.


15. Save / Load
---

A compact binary format, `.rgascene`, matching the scene's own layout:

| Bytes | Field |
|-------|-------|
| 4 | magic `RGAS` |
| 1 | format version |
| 1 | basis count (16 here); must match, or the file was saved under a different
      dimension or metric |
| 4 | item count, little-endian unsigned 32-bit |
| per item | colour (1), visibility (1), label length in **bytes** (1) + that many bytes of
             UTF-8, then one little-endian float per basis term |

**State the byte order and hold both implementations to it.** There is no external spec to
match, so the order is a free choice — but it must be a choice, written down and converted
to explicitly on every path, not whatever the host happens to use. Two front-ends write this
format; one of them reaches it through an API that demands an explicit order at every call,
so leaving the other on native layout means they agree only by coincidence of architecture.

**Every constant the format is made of belongs to one definition, exported.** Magic, version
and basis count are derived values, and a second copy in the other language is a copy that
will drift — as it did: a hand-written version literal survived a bump and left neither build
able to open the other's files. A label is bytes, not characters, and the count is a byte
count: a language whose string length counts UTF-16 units will otherwise write a length that
disagrees with the bytes it then emits, and every later field parses from the wrong offset.

Only live items are written, in slot order. **Deliberately omitted**: slot numbers, which are
meaningless once reloaded since a fresh scene assigns its own free-list order; birth time,
meaningless across runs — a loaded item is born at the dawn of time, never partway through an
animation that never happened; the anchor override, a rendering hint; and fixed-width label
padding, since length-prefixing keeps the format independent of the writing build's label cap.

**Loading parses into a staging scene and replaces the caller's only on complete success**, so
a bad path, a foreign file, a wrong dimension, or too many items leaves the existing scene
untouched. Bump the version whenever the meaning of any stored field changes — including a
change to how colours or basis names are derived — and refuse older versions rather than
mis-reading them.

The browser reaches the **identical** format. Expose raw per-item fields across the boundary
and let the platform's own binary view do the float encoding; reinventing IEEE-754 in the core
language would only duplicate what the platform does natively.


16. Demo Construction
---

Five seeds, then eleven derived steps. Both front-ends **open on the seeds alone**, so the
window and the script agree on where a construction starts. The eleven steps are reachable as
a **one-click preset** that populates the scene with ordinary, fully editable items — not a
separate scripted-playback mode.

Seeds: three points `a` (3, −2, 2.5), `b` (−2.5, 2, 5.5), `c` (1, 4, 3), each off the ground
plane; `o` at the world origin; and `ground`, joined from three points at z = 0 and centred on
their centroid. **`o` must stay off `ground`** — one step projects it onto that plane, and a
point already lying on the plane projects to itself, making the step a silent no-op.

The eleven steps, in order: join `a ∧ b` to a line; join that with `c` to a plane; meet
`ground` with it; meet the line with `ground`; the line's support; the line's attitude; weight
expansion of `a` with the line, giving a perpendicular plane; orthogonal projection of `o` onto
the plane; the plane's attitude, giving a line at horizon; `a ∧ ground`, a grade-4 volume; and
that volume's attitude, giving the plane at horizon.

Two of those are load-bearing teaching cases, not bugs: **`a ∧ ground` is mixed/grade-4 and
correctly reports "nothing to draw"** — a point wedged with a plane it does not lie on has
nothing to render, and that is the step's documented purpose. And attitude drops one grade
each time, walking a horizon point → horizon line → horizon plane, which is how all three
horizon cases get exercised.

Compute the seed count from the scene's own length rather than hardcoding it, so inserting a
seed needs no matching edit; step indices are stable because the scene grows by one per step.
The preset stamps birth times one second apart per step, mirroring the capture run's synthetic
clock, so a recency-sorted list reads seeds as oldest and each step as progressively newer.

**Capture mode** (`--storyboard:DIR`) writes one image per step plus an animated GIF. It
distinguishes **reached** (this step has happened; true forever after) from **focal** (the
current step's operands and result, plus the step before, for continuity). Reached-but-not-focal
draws **muted as background context rather than hidden** — objects disappearing reads as more
confusing than informative. Horizon-producing steps reorient the capture through the closed-form
inverse of the orbit camera's own forward-direction formula, then restore the default view. No
field-of-view widening: reorienting suffices, and no FOV can fix content behind the camera.


17. Desktop Front-End
---

An immediate-mode GUI panel drawn over the 3D scene. 1440×900 window, 16 px text. Panel width
440 — close to the browser drawer's 400, and **nothing in the panel carries a hardcoded
width**: fields, plots and bars all size themselves from the available content width. (Beware
that some immediate-mode toolkits read a zero width as their own default *item* width, two
thirds of the window, which puts a graph at two thirds beside a full-width bar.)

**Top bar**, outside every section: `add`, undo/redo, the axes and grid toggles, and the
scene-file save/load controls. `add` has to be able to open the objects section, so it cannot
live inside it.

**Four sections in alphabetical order — apply, diagnostics, objects, view — with only
`objects` open by default.** The browser's drawer mirrors this exactly (§18); the two lists
must not drift.

- **apply** — arity toggle (unary/binary), operation picker over the full catalogue filtered
  by arity, operand pickers for `𝐦` and `𝐧`, and an apply button. This section stays usable
  at three or more selected because it has operand pickers and can say which two it means.
- **objects** — one row per item: `[✓] label` then edit/hide/remove buttons, then
  `shapeWord: coefficients` on one line, then the editor when open.
- **view** — azimuth, elevation, distance, field of view, and the three target components.
- **diagnostics** — §20.

**Object rows.** The leading checkbox toggles selection membership, so a second and third
object join in pick order — that order names the operands. Clicking the name selects that one
object alone — the same two gestures a click and a shift-click in the 3D view reach, offered
here as well because the list is where a reader who has not found the view gestures looks.
Hidden rows dim to 0.45 opacity, independent of
the selection highlight so the two combine. Rows are ordered by recency. Dim through a
style-alpha push, **not** a disabled-scope, which would also make the row's own show button
unclickable. The edit toggle is a **small button over session state**, not a collapsing
header, which spans the full remaining width and would push hide/remove onto their own line.

**Coefficient grid.** The 16 inputs are grouped one line per grade, with the basis element
name **above** its cell, not beside it. Beside charges every cell the width of the longest
name whether it needs it or not, which forced the panel out to 680 px and made opening an
editor the thing that set the window's width; above costs one line of text per grade. Cells
**divide the line they are on** rather than taking a fixed fraction of the panel, so the
scalar's lone cell spans the width and grade 1's four take a quarter each. Wrap at six cells
per line — six because this build's largest grade holds exactly six, which puts every grade on
one line and makes the desktop grid match the browser's grade rows one for one; a
higher-dimension build wraps rather than overflowing. Six is the **wrap point, not the
divisor**.

**Where an immediate-mode toolkit forces care:**

- A name and its widget must advance as a single item for same-line placement to work; most
  such toolkits have no notion of a labelled cell and need an explicit grouping call.
- **An unselected segmented-toggle option is filled and bordered, not transparent.** The
  browser's is transparent because the pill's own track makes it visible; a panel drawn
  straight onto the 3D scene has no track, and a transparent segment disappears into the scene
  entirely — the word reads as a caption rather than an option. Give it the browser's surface
  and border tones.
- **Row buttons end flush against the right edge**, measured before any of the run is placed.
  Names vary in length, so left-packed buttons form a ragged column that moves under the
  pointer from row to row.
- **Names recede and values read.** A control's own name draws in the faint ink; section
  headers carry the raised-surface tone, not the toolkit's default saturated blue — five blue
  bars stacked were the loudest thing in a panel whose job is to sit over the scene without
  burying it.
- An empty widget label may collide with the window's own identifier and abort the process;
  use a hidden identifier.

**Command line**: `--screenshot:PATH` writes one image; `--frames:N` exits after N frames;
`--hidden` never maps the window; `--storyboard:DIR` runs capture mode; `--load-scene:PATH`
opens a saved scene; `--timings` reports frame-time statistics over a `--frames:N` run;
`--novsync` disables vsync for an uncapped reading; `--fill` tops the scene up to capacity
first, for the heaviest case. An unknown option names the valid set in its error.


18. Browser Front-End
---

Ships as **one self-contained HTML file** — shell, compiled core and glue concatenated — that
works with no network access. Dark surface, `#101318` background; the token set the desktop
panel also borrows from:

```
--bg #101318   --surface rgba(22,27,34,.82)   --surface-solid #161b22
--surface-raised #1b212b   --border #2a323d
--ink #e7ecf1   --ink-muted #8b96a3   --ink-faint #5b6673
--accent #00a7a5   --accent-ink #bdf3f0   --danger #e0577a
```

**Chip row** (always visible): brand/drawer toggle, undo and redo as plain bordered
rectangles, axes and grid as a segmented pill, then a menu button. **The visual grammar is
deliberate** — a pill shows state you can read at a glance, a bordered rectangle is a momentary
action. Sorting by frequency matters: undo/redo and the view toggles are reached constantly and
must not cost an extra click, while the menu holds only the genuinely rare file actions (save
scene/image, load scene/demo, under `save` and `load` headings). Below 520 px the brand label
drops to its mark alone, or five controls plus the label overflow a narrow phone. **Sweep for
that breakpoint rather than picking one**: it was set at a round 480 while the row needed 520,
so a 40 px band of viewport widths overflowed unnoticed.

**Stacking.** The chip row's container sits above the drawer and below the floating menus, and
the z-index must be set on that **container**, not on the row: fixed positioning always opens a
stacking context, so a z-index on a descendant cannot outrank its ancestor's sibling. Without
this the drawer paints over the chip row's buttons at the viewport widths where the drawer is a
full-height right panel occupying that corner.

**Drawer**: 400 px wide (a bottom sheet on narrow viewports), holding the same four sections in
the same alphabetical order with only `objects` open, an intro line naming the drag gestures,
and per-section contents matching §17 field for field.

**Coefficient grid**: the 16 inputs stacked one flexible row per grade, 0 to n, **not** wrapped
at a fixed column count that cuts across grade boundaries. Grade comes from the core, so
nothing hardcodes this build's dimension.

**Floating selection menu**, one row, following its anchor object every frame. **Both
front-ends carry it**, from the same rules; it is specified here because this is where it
was first built.

- `apply` sits **leftmost and never moves**. Pressing it reveals an operation picker to its
  right; pressing it again commits with whatever is picked. `back` collapses without
  committing. Animate the reveal with a max-width transition — `width: auto` cannot animate.
- `edit` sits immediately right of `apply` and shows **only for exactly one selected object**,
  since one object has one editor. It opens the drawer and the objects section, starts an edit
  session on that slot, scrolls the row into view and hides the menu — the panel owns the
  interaction from there — while keeping the selection.
- `hide`/`delete` are hidden while the picker is open and restored when it closes; both act on
  every selected slot. **`hide` is a toggle**: it reads `show` when every picked object is
  already hidden, and sets all of them to that same target. (Whether a selection is entirely
  hidden is a rule about a selection and belongs in the core, not in a script-side `.every()`.)
- `✕` clears the selection and stays visible throughout.
- **`apply` is hidden entirely at three or more selected**: this menu has no operand pickers,
  so it cannot say *which* two of three it would use. The drawer's apply section can, and
  stays usable.
- It is raised by the gestures that **pick** and lowered by the ones that **build**, rather
  than derived from the selection being non-empty: every construction path leaves its own
  result selected, and a menu appearing over each new object would sit in the way of the
  next drag.
- It sits **above** its object, never on it, by enough to clear the object's own selection
  marker. A menu straddling its object would take the press that should have started the
  next drag off that object — which on the desktop is literal, since a GUI window there
  claims the pointer wherever it sits.

The script layer keeps only a **render snapshot** of the selection, refreshed when the
selection changes, so the per-frame overlay loop does not cross the boundary — a cache of the
core's answer, carrying no rule of its own. An earlier design kept the ordered list in script
because the core held a single scalar; that put pick order, the thing that names operands, in
the wrong language.

Draw order in the glue mirrors the native renderer and must be kept in sync by hand: furniture
at furniture width with normal depth, then scene lines and points, then translucent triangles
with depth writes off.

**Three gotchas that appear when compiling a systems language to JavaScript**, all confirmed
empirically here and worth checking for in any equivalent toolchain:

1. An item handle that holds the scene *by reference* natively may hold it **by value** in the
   JS backend, so constructing one copies the entire scene. Provide by-slot accessors and have
   the per-frame loop use them — going through the handle iterator measured ~150 ms/frame at 64
   items.
2. A mutable-reference return over an array of primitives can miscompile when the result is
   consumed as a *value*, yielding undefined — falsy everywhere. Keep a plain by-value
   accessor pair for the browser's use and leave the native one untouched.
3. Fixed-size mesh storage must live at module scope and be cleared, never re-declared per
   frame — there is no stack allocation for a fixed-size array inside a function, and
   re-declaring measured ~90 ms/frame regardless of item count, versus ~6 ms hoisted.


19. Parity
---

The two front-ends are the same tool. A parity checklist a reviewer can run:

- same four sections, same alphabetical order, only `objects` open;
- same operation catalogue text, character for character;
- same basis element names and the same four-significant-digit numbers;
- same colours, and neither picker offers a structural slot;
- same selection semantics and the same ring, one per selected object;
- same edit-session table (§13), same ghost;
- same undo/redo scope and the same greyed-out controls;
- same keyboard: the same keys, the same amounts, the same focus marker;
- same file format, round-tripping between the two;
- same animation duration and curve;
- same drag: the same proposal, the same preview, the same choice menu, reached by
  mouse or by finger.

Assert the catalogue parity **mechanically**: a test comparing what each front-end reports for
all 27 operations. Trivially true once there is one table — which is the point.


20. Diagnostics
---

A closed-by-default section. The desktop build shows: a **raw**, unsmoothed per-frame
millisecond line graph over roughly four seconds from a ring buffer — smoothing hides exactly
the rare slow frame this exists for; a fill-fraction bar for the permanent allocator; a
high-water bar for the frame allocator, since instantaneous usage reads near-empty almost any
time it could be sampled; a coloured cell per object-pool slot with active and free counts;
the pool's fixed memory as allocated / used / per-slot; and a total of every fixed reservation
the binary makes for itself, computed in the one place that can see every piece.

Take the allocator snapshot in the **shared** render path, not the interactive loop, or it
reads zero in every captured image.

The browser shows **browser-appropriate stand-ins** — frame time from animation-frame deltas,
JS heap where available, live pool slots — rather than fabricating the native build's
allocator numbers, which describe that build's allocator and have no browser equivalent worth
pretending to. Say so in the panel.

**The object-pool strip wears the scene's own colours**: an occupied cell in that object's
colour, a free one in the recessive grid colour. It reads as the scene rather than as an
anonymous occupancy count — which slot an object sits in, and how far the colour cycler has
walked the palette, are both legible at a glance. **Both front-ends receive the whole strip as
one buffer of colour triples**, so neither presentation layer carries a palette rule.


21. Typography
---

**Noto Sans** for UI text, **Noto Serif** for prose, **Commit Mono** for code, data and
figures. This is a project rule, recorded in the style guide, not a per-file habit.

**Every render target ships the faces it draws with.** A named face silently falls back and
the two targets stop matching — which is the whole point of having the rule. The browser
embeds them as base64 font-face declarations (about 940 KB of a ~1.6 MB page); the desktop
loads them from the packaged files.

**No single face covers what this UI writes.** Merge by codepoint range: a text face for
Latin, punctuation, subscripts and spacing modifiers; a **math** face for the operators and
the bold operands; a **symbols** face for the dual stars and the abandon cross. Two mechanical
requirements follow:

- A 16-bit wide-character type **cannot express U+1D426 at all**. Widen it via a compiler
  flag, not by editing the vendored GUI checkout's config header — which is never committed
  and would not survive a reclone.
- Glyph ranges must actually include what is drawn. The abandon cross is U+2715, in the
  Dingbats block; a range starting at U+27C0 renders it as a box.

In the browser, declare the math and symbol faces **under the sans family name**, and have the
mono and serif stacks name that family after their own. Neither Commit Mono nor Noto Serif
carries those codepoints, so without it a bold operand or a wedge in monospace text falls
through to whatever the viewer's system has — invisible on any machine that happens to have a
face with those glyphs installed. It costs no payload: CSS falls back per character, and a
range-restricted face only ever matches the characters it is declared for.

**Verify coverage by rendering.** Enumerate every non-ASCII codepoint the source writes (36 of
them here), render each against each face, and compare bitmap-wise against the notdef glyph.
A missing glyph is a box, not an error, and no API reports it: a font-loading check reports
face *loading*, not glyph coverage, and will confidently tell you the wrong thing. This check
is what caught the previous font's real bug — it lacked `⟑` and `⟇`, so the geometric product
and antiproduct entries had been drawing as tofu.

All the faces above are OFL-1.1 and redistributable with notice. Keep the notice with any
vendored copy.


22. Animation
---

**One duration and one easing curve, named once and derived everywhere**: 350 ms, ease-out
cubic. A freshly added object grows in over them; the camera tween eases over them; and the
browser **reads them across the boundary** into CSS custom properties at startup, so every
transition runs to the same numbers rather than to a second set written down separately. The
equivalent CSS curve is `cubic-bezier(0.215, 0.61, 0.355, 1)`.

A transition with a hand-picked duration is a claim that this one motion is special and needs a
comment saying why. There is exactly one here: the opening hint is a timed disclosure rather
than a response to anything, and holds 4 s before a 0.6 s fade. Put its delay in **one** place
— a stylesheet transition delay runs from the moment the class is added rather than from load,
so the two stack and the hint outstays both numbers.


23. Performance And Memory
---

- The interactive frame loop allocates nothing. Per-frame number formatting writes into
  caller-owned or stack storage. Once-per-click message building may allocate.
- Where the native build needs scratch memory (image export, GIF quantisation and compression),
  use **bump allocators**: a permanent arena that is never reset and a frame arena reset after
  each throwaway unit of work. Size the permanent one to the capture run's own measured
  requirement, not to a round number. The interactive draw loop asks neither for anything.
- A compression dictionary needing random-access probing within a frame is a separate
  fixed-capacity open-addressed table, not a third arena — arenas are bump-only append.
- **GIF LZW has a trap worth a permanent regression test**: the format widens code size one
  symbol earlier on decode than on encode. Catch it with an independently written decoder
  round-tripping a real encoded frame past the code-width growth point.
- Report measurements honestly. On software rasterisation, rasterising dominates the frame
  entirely and a frame-rate target **cannot be assessed** — say that rather than quoting a
  number the hardware did not produce.


24. Testing
---

- **Test properties and invariants, not examples.** Exhaustively enumerate small domains,
  sample a fixed preallocated pool for large ones, seed deterministically.
- Compare floats through an **approximate operator with configurable tolerance**, and make
  **exact equality a compile error** on the domain's own types, with a message naming the
  correct call.
- Test entry points are a minimal spec header plus an include of one shared suite,
  parameterised over configurations by the test runner's matrix mechanism. Keep the suites in
  one file so the configurations cannot drift.
- **Run the suite on both compilation targets, not just the native one.** A rule stated once
  and reached through two mechanisms — the native formatter and the one written for the target
  that has no C runtime — is only held together where both mechanisms run. Compiled natively
  alone, the test comparing them asks the C runtime whether it agrees with itself. Measured on
  this project: 330 of 7000 magnitudes differed between the two front-ends while that test
  stayed green, and adding the second target's row also found a fixed-buffer read returning
  empty and a `var`-returning accessor writing to a copy. Cases genuinely needing a native
  entry point guard themselves and are skipped on the other row.
- **Run it again at capacities small enough that its own tests reach them.** Every capacity is
  a compile-time define; at the defaults a test proving a boundary writes sixty-four entries to
  reach one. A second native row at a twelfth of each makes any constant tuned to the default
  rather than derived from the define fail there rather than in a build somebody configured.
- Suites that need a live GL context (renderer, GUI, panel) are excluded from the unit suite
  and covered by the driven verification below instead.
- The invariants above that are **stated as requirements must each have a test**: slot
  stability across removal, both pick boundaries and all three priority pairings, a meet
  landing outside the drawn plane disc, the line's two-segment projection exactness, the
  derived basis names against the library's own printing, the two number-formatting paths
  agreeing, the palette's categorical count, the tween's mid-flight and arrival behaviour,
  history walked to capacity and back, and a scene file round-trip.
- **Every wait must be shown.** A press that has to be held before it does anything needs
  feedback from the first frame, or it cannot be told from a press that did not register.
  Show it by drawing the *selection outline that press is about to produce*, part-built, in
  whatever way that outline is read: a ring about a point sweeps, a pair of rails flanking a
  line runs outward, a circle on a plane opens from its centre. One progress parameter on
  the one shaper both front-ends already share buys this on both at once, and keeps the
  growth in world space where the geometry is. **Linear, never eased** — this is a clock
  being shown, and an eased clock appears to stall just before it fires.
- **Ship a persistent way to reach the controls**: a `?` in a corner, at least 44 px,
  opening a table of every gesture, button and key. State that table **once, in the core**,
  derived where possible from the bindings themselves, and have both front-ends render it.
  A timed hint is not a substitute — it cuts off whoever reads slowly, which is the reader
  who needs it — and one front-end keeping a legend the other loses is a parity break.
  Dismiss any first-run hint on the reader's first real action, not on a timer.
- **Cut that table by how the reader is working, one tab per way**, not by what kind of
  control each row is: a reader opens it in the middle of one thing, and only that thing's
  rows are of use to them right then. **Bound each tab, not the table**, at compile time, to
  what fits the smallest screen supported — a count of rows is only a proxy for rendered
  height, so derive it by measuring the built page at that size and say in the constant that
  it is a proxy. Growing a full tab must fail the build, and the answer is nearly always to
  split the tab. Whatever region the rows sit in must be *bounded and scrollable* even so:
  scrolling is the net that stops a panel silently losing rows off an edge, never the way
  the reference is meant to be read.
- **Size the reference's action column from the widest action in it, never from a fraction
  of the panel.** A fraction is a guess, and it is wrong at both ends: too wide on a roomy
  panel, so outcomes wrap beside empty space, and too narrow on a phone. Give the outcome
  column a floor of its own as well, or the widest-action rule takes a narrow panel's whole
  width; check both floors against the container's own right edge, since an overflowing
  column scrolls rather than clipping and so looks fine in a screenshot.
- **Make the reference reachable from a headless capture** — a flag naming the tab to open.
  A panel no capture can reach is one whose rows nobody ever checks fit.
- **Bind the keyboard.** Escape sheds what is in progress, innermost first; the platform's
  undo and redo chords step the timeline. Route each through the same function the button
  uses, never through the button itself: a disabled attribute refreshed on a slow UI tick
  will silently swallow the key. Never let Escape do something destructive as a fallback —
  a reader presses it twice to be sure. Note plainly that this is a *partial* keyboard fix
  unless the canvas itself can also be navigated without a pointer.
- **Commit the measurements as runnable checks**, not as numbers in a document: a layout check
  counting **characters, not bytes** (a byte counter reports a compliant line full of multi-byte
  operators as over-long and gets ignored within a day); a palette-separation check that
  imports the palette table itself; a glyph-coverage check that enumerates the codepoints from
  the tables that produce them and parses the ranges out of the font-atlas source. Each must
  read the thing being checked rather than a transcription — a mirror would pass happily while
  the compiled build disagreed. One script runs all of them plus every suite row, fails on the
  first failure, and says on success that passing it is necessary and never sufficient.
- A check whose floor a value cannot meet gets a **declared exception in source**, naming the
  reason and pinning a floor just under where it measures, so drifting further still fails.
  Never lower the floor globally to make one case pass.
- **Driven verification, every round**: regenerate the capture frames and **look at them**;
  drive the browser headlessly with **real synthetic events** at the platform's own input
  layer — untrusted synthetic pointer events fail pointer capture, and calling handlers
  directly bypasses the listener wiring where real bugs hide.


25. Coding Style
---

Ship a `STYLE.md` carrying these rules and follow it for every line. It is a contract, not
advice.

**Stance.** Solve the problem in front of you; no speculative generality, no framework. The
reader can see through code to its cost — no hidden control flow or allocation. Caller owns
memory; prefer fixed-size storage of statically known extent. Use the **least powerful
construct** that does the job well — constant before variable, pure function before procedure,
plain function before template, template before macro — and escalate only where you can name
the goal the weaker one cannot meet, in a comment. Metaprogramming is priced, not forbidden:
where a spec genuinely is a table and its operations follow mechanically, define the table once
and generate from it. Before deriving a value in a wrapper layer, check whether the primary
layer already computes it and expose that instead.

**Layout.** 2-space indent, never tabs, no trailing whitespace. **Hard 100-column limit,
measured in characters not bytes** — a byte-counting checker lies about every line containing
non-ASCII, and this codebase is full of them. Functions fit one screen: 60 lines, nesting
depth 3; exceed only where the shape of the data demands it and **say so in a comment** rather
than inventing a helper whose only purpose is the number. Guard clauses and early returns.
Divide every file into sections with a banner comment, **one tier only** — a file wanting
sub-sections wants splitting. File order: module doc → compiler directives → standard imports,
alphabetised → blank line → local imports → body. One element per line in a multi-line
construct gets a trailing separator so lines reorder freely; a pure line-length wrap does not.
Order definitions so a first-time reader proceeds top to bottom; alphabetise where nothing
forces an order.

**Naming — four cases, no exceptions, because the case is a signal**: types PascalCase,
callables camelCase, constants and compile-time configuration SCREAMING_SNAKE, locals,
parameters and fields snake_case. Adopt this even where the language community differs; a mixed
scheme destroys the signal. Name by what the callable **is**: one that acts opens with a verb,
one that names a property takes the domain's bare noun — `centroid`, not `getCentroid`. **Verb
first, discriminator last**, so a family shares the longest common prefix (`normBulk`,
`normWeight`; `node_left`, `node_right`). Booleans carry a kind prefix: `is_`, `as_`,
`should_`, `found_`. Lookup tables read `lut_<subject>_to_<object>`. **Do not truncate a word
you coined** — `ctx`, `tmp`, `cfg`, `mgr` are forbidden; established domain jargon (`lut`,
`min`, `src`/`dst`) is not truncation. Single letters only where the domain's own equations use
them. Where the domain has canonical notation, mirror it in identifiers and operators, and
always ship an ASCII-named façade of one-line forwarders alongside so no caller is forced into
the notation.

**Documentation.** **Every declaration gets a doc comment** — three exceptions only: a run of
mechanical declarations documented once above the run, test fixtures, and a declaration whose
sole purpose is to fail at compile time. Never leave the slot empty; write a TODO where you
cannot write it yet. A **generator documents what it emits**, with the doc text a required
parameter of the emitting helper so an undocumented emission cannot compile. Doc comments are
telegraphic: omit articles, end every line with a period, **first line imperative** opening
with a verb, elaboration declarative. **Body comments name the goal of a step, never its
mechanism** — write each as the completion of an unwritten "In order to…", open with a bare
verb, one line before each logical step. Document the decision, not the mechanism: which
convention, what was rejected, what it costs. **A summary index is a derived view, not a source
of truth** — where a table and a declaration disagree, the declaration wins. **A doc comment
asserting a global property names what enforces it** — a test, a pragma, a compile-time check —
or marks itself unverified.

**Design.** Configure by compile-time constant where a whole module specialises on the choice.
Use a distinct type for every domain quantity that should not be interchangeable with its
representation. **Optional values are an explicit optional type; no sentinels smuggling
absence into a value's own range** — no −1 index, no NaN, no null, no magic "none". Where a
foreign-function boundary genuinely cannot carry an optional, keep the optional internally and
translate through **one named constant at the boundary** — the boundary is where a
representation is translated, not a licence to use sentinels upstream. **No silent identity on
degenerate input**: a routine that cannot do its job must signal, not return its argument.
**When merging several states or code paths into one, enumerate the old behaviour first** — by
reading the old code, not by recalling the request; a request naming one behaviour to preserve
is not licence to drop the rest. Bind a case expression to a constant instead of an if/else
chain. **Make misuse uncompilable and say what to do instead.**

**Prohibited.** Inheritance or interfaces for domain modelling. Runtime polymorphism in hot
paths. Exceptions as control flow. Failure encoded as an in-range value. Coined-word
truncations. Comments restating code. Empty documentation slots.

**Commits.** Conventional Commits with a fixed scope, lowercase imperative summary, no trailing
period; join related clauses with `;`. Use `refactor(scope):` freely.


26. Documents To Ship
---

Alongside the code:

1. **`STYLE.md`** — §25, in full, as the project's own contract.
2. **`PROVENANCE.md`** — who made this, from what, and how far it has been checked. Open with a
   table naming the agent, the author model, the date, the style contract, and a **review
   line** stating plainly whether a human has read the code line by line. That line is the
   point of the file. Then document the **current** design organised by subsystem — not a
   changelog. For each non-obvious decision record what was chosen, what was rejected, and what
   the choice costs. **State which claims were verified and which were assumed**; that
   distinction is the file's most valuable property and is what makes it provenance rather than
   a design doc. Keep every concrete constant and its reasoning, so a fresh session can rebuild
   the project from this file plus the source. Do not narrate history: superseded experiments
   and fixed bugs come out, except where a rejected alternative is still a live trap and earns
   one terse line.
3. **`dependencies.list`** — §3.
4. A config file beside each entry point, opening with a comment saying what that entry point
   is and why these flags. **Library link flags belong in the module that needs them**, not in
   the config, so a test binary importing that module links without repeating anything.
5. Vendored source is **kept locally and never committed**. Record where it came from, at which
   commit, and under which licence, and honour that licence's notice requirements.


27. Definition Of Done
---

A round is finished when all of these hold, and not before:

1. Both targets build clean.
2. The full suite passes, and every invariant named in §24 has a test.
3. The capture frames and GIF have been **regenerated and looked at**.
4. The browser bundle has been reassembled and **driven headlessly with real synthetic
   events**, mouse and touch.
5. `PROVENANCE.md` matches what the code now does, including which claims are measured.
6. The parity checklist in §19 passes.
7. Anything you could not verify is stated as unverified, in the delivery notes and in
   `PROVENANCE.md`. **No human has driven either build** is a legitimate and required thing to
   say if it is true.
