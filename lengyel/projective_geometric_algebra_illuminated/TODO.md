# Working notes: swapped Fresnel for a 3D-modelling-style selection outline — done

## Follow-up 2

Fresnel still wasn't it: wanted an outline just outside the object's own edge, like
Blender/3D-modelling-software selection, not a grazing-angle glow -- and lines looked
unchanged. Replaced the Fresnel shader pass (reverted `renderer.nim`'s shader to plain
original) with the classic "oversized silhouette drawn first" technique: the
highlighted object's own geometry, built oversized and in a flat `Ink.Outline` white,
draws *before* the ordinary frame, depth test/write off; the ordinary frame then
redraws everything (including that object at true size) over it, leaving only the
sliver that peeks out past the true-size edge visible as a border. A point gets a
wider `gl_PointSize` for its one draw call; a plane gets a genuinely larger disc rim
(`mesh.addPlane`'s new `outline`/`FRACTION_OUTLINE_PLANE` param, fill and normal shaft
skipped); a line gets a wider `gl.lineWidth`. Native (Mesa) renders all three
correctly, confirmed against the regenerated storyboard. The browser (WebGL/ANGLE)
renders the point and plane outlines correctly too, but most browsers clamp
`gl.lineWidth` to 1px regardless of what's requested -- a WebGL platform limit, not a
bug here -- so a highlighted *line* shows no visible outline there specifically; fixing
that would need a geometry-based thick line (a screen-space quad per segment), not
attempted this round. 69 native tests pass unchanged.

## Follow-up

The ring wasn't what was wanted: asked for a Fresnel outline like a game's teammate/
enemy/item highlight -- brighter at grazing angles, not a flat billboarded circle.
Replaced `mesh.addHighlight` (deleted) with a real shader-based rim: the highlighted
object's own geometry (not a separate shape) is re-tessellated into a second buffer and
redrawn with `is_highlight` on, depth test off (avoids z-fighting the identical
geometry, and reads as deliberate emphasis). Fragment shader: a point gets a genuine
sphere-impostor Fresnel for free from its own `gl_PointCoord`; a plane gets a real one
from its own constant normal plus a new `eye`/`world_pos`; a line, with no surface
normal of its own, falls back to a fixed modest rim. Mirrored exactly in `glue.js`/
WebGL. Native and browser rebuilt, native storyboard and a browser screenshot both
confirm a visible white-hot core fading to the object's own colour at the rim (clearest
on points at larger sizes; subtle but real on the perpendicular-plane's own curved
edge). 69 native tests pass (3 ring-only tests removed, none replaced -- the shader
path isn't unit-testable without a GL context, matching this project's existing rule
that `renderer`/`gui`/`panel` stay out of the suite for the same reason).

This file mirrors the task tracker I use internally, plus anything worth knowing about
each round. Tracked in git (per your stop-hook check).

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, diagnostics panel, object
pool readouts, refactor/colour/visual-noise audits, scene save/load, unbounded
camera-relative drawing, fading-disc planes made visible, ground grid/axes made
indefinite, categorical palette checked against the axis colours, rim+crosshair planes
with a distance-cutoff grid, flat fill back under the rim with a wider grid cutoff, a
browser rendering pipeline through the real library, a fixed plane radius and a longer
line reach, closing the last visible gap between a line and its own attitude and a
style/hacks audit, then creation-anchored plane circles and dimmed-rather-than-hidden
storyboard history) are summarized in prior commits on this branch — ask if you want
that history restated.

## This round

Three asks, the first two follow-ups on the previous round's own explanations: double-
check that a plane's drawn disc is only a rendering choice, not a bound the actual
(infinite) plane geometry is subject to, specifically that a line crossing well outside
the disc still meets it correctly; fix `a onto G`, which the previous round explained
but did not actually fix -- `a` already lies on `G` by construction (`G` is joined from a
line through `a`, plus a third point), so projecting `a` onto `G` is a no-op with nothing
new to see, and needs a point genuinely off `G` instead; and, raised mid-round, ring
whichever object was just constructed in a pleasing, appropriate colour, as if it were
freshly selected by the user.

- [x] Confirmed by reading, not just by argument: `EXTENT_PLANE`/`EXTENT_PLANE_F` (the
      disc's own drawn radius) is referenced in exactly two places, `mesh.nim` (drawing
      the disc) and `picking.nim` (bounding a mouse click to what is actually visible to
      click on) -- grepped the whole `visualiser/` tree to be sure. Every construction
      path (`storyboard.applyStep`, `interaction.endDrag`, `panel`'s apply button) reads
      an item's `geometry` (the full, un-truncated `Multivector`) and calls
      `applyOperation` directly, never consulting either constant -- so a meet was
      already correct regardless of disc size before this round touched anything; this
      was verification, not a fix.
- [x] Added a regression test making that concrete rather than leaving it as an
      unexercised property: build a plane, take a point on it three disc-radii out from
      its own drawn centre (well outside `mesh.addPlane`'s own circle), cross it with a
      line built specifically to meet the plane there, and confirm `WedgeAnti` recovers
      that exact point. Passes, as expected -- this documents and locks in the
      already-correct behaviour, not a bug being fixed.
- [x] Fixed the actually-degenerate step: added a fifth seed, `o` (the world origin),
      confirmed off `G` by direct computation before writing any code (`o`'s incidence
      with `G` is nonzero, at roughly 1.8 world units away -- comparable to the scale
      `a`, `b`, `c` themselves sit at, so the projected point lands somewhere legible
      rather than off in the distance). Step 08 now reads `o onto G` and projects `o`
      instead of `a`, landing at a point visibly distinct from `o` itself. Every scene
      index from that point on shifts by one to make room (seeds now occupy 0 to 4, not
      0 to 3) -- `storyboard.nim`'s own module doc comment and every `Step`'s
      `index_first`/`index_second` updated by hand, and re-verified end to end by
      rebuilding rather than by re-deriving the arithmetic a second time: a bad index
      would have tripped `applyStep`'s own `doAssert isAlive` at runtime, and the
      storyboard capture ran clean through all twelve frames. `visualiser.nim`'s
      `runStoryboard` and `browser_bridge.nim` both compute their own seed count from
      `scene.len` after construction rather than a hardcoded constant, so neither needed
      a matching edit.
- [x] Rebuilt and reran the full native suite (69 tests, one new) and the desktop
      binary, regenerated the storyboard under `xvfb-run` and confirmed visually: `o`
      appears as a fifth amber seed point at the world origin, and the step-08 frame
      shows a new point clearly offset from it rather than the previous frame's
      exact-overlap no-op. Rebuilt the browser bridge, reassembled the artifact, and
      smoke-tested headlessly (Playwright, SwiftShader): all eleven steps still report
      through cleanly, `o onto G` reports "point" same as any other, zero console or
      page errors, and a screenshot at that step shows the same visibly distinct pair of
      points as the desktop capture.
- [x] Added a highlight ring for whichever object was just built. Reused the desktop
      editor's own existing precedent rather than inventing a new visual language: the
      hover ring it already draws (a white circle over whatever the cursor rests on) is
      the established "this one is currently of interest" affordance, so the new ring
      matches its colour exactly. Implemented once, in `mesh.addHighlight`, shared by
      both native and browser: a ring spans `spanPerpendicular` around the direction
      from the object's own anchor toward the eye, so it always faces the camera
      (billboarded) without needing a full camera frame passed in, just the eye position
      `DrawExtent` already carries; sized as a fraction of distance from the eye rather
      than a fixed world size, so it holds a constant, comfortable screen size regardless
      of how close or far the camera stands. Empty for a horizon line or plane, which
      has no fixed anchor to ring, matching `picking.anchorFor`'s own established rule
      that neither is pickable either.
- [x] Wired the highlight through every path that constructs something: `runStoryboard`
      and `browser_bridge.nimGotoStep` set it to each step's own result; the desktop
      editor's "add point" and "apply operation" panel buttons and its drag-release
      (`interaction.endDrag`, whose return type changed from a bare message string to a
      `(message, index_created)` pair so the caller can learn which slot to highlight)
      all set it too, so a freshly built object reads as just-selected everywhere it's
      built, not only in the scripted demo.
- [x] Added tests for `mesh.addHighlight`: rings a point, line or plane's own anchor
      exactly, face-on to the eye, at the right radius; honours `anchor_override`; empty
      for a horizon line or plane. Updated the `Interaction` suite's existing `endDrag`
      tests for its new return shape. Rebuilt and reran the full suite (72 tests, three
      new) and the desktop binary, regenerated the storyboard and confirmed visually: a
      clean white ring appears around the point, line, or plane each step just built,
      sized consistently across near and far objects alike, and is properly absent from
      the seeds-only frame before any step has run. Rebuilt the browser bridge,
      reassembled the artifact, and smoke-tested headlessly (Playwright, SwiftShader):
      zero console or page errors across all eleven steps, and a screenshot at the
      perpendicular-plane step shows the same ring, in the same place, as the desktop
      capture.

Artifact: `https://claude.ai/code/artifact/a523f27b-d74e-4987-9b6e-7b1680e469a6`
(same URL, republished).

## Previous round

Three asks: explain what the `a onto G` (`ProjectOrthogonal`) and `a ^ ground` (a
grade-4 pseudoscalar, drawing nothing) steps actually are; replace "hide" for a
rolled-off storyboard step with "gray out and dim" instead, since disappearing objects
read as more confusing than informative; and centre a plane's own drawn circle on how it
was actually built, rather than always on its closest-to-origin support point --
e.g. the perpendicular-plane step should centre where its line pierces the plane, a
plane wedged from a line and a point should centre between them, and the ground seed
should centre on the centroid of the three points that built it.

- [x] `a onto G`: `ProjectOrthogonal` drops `a`'s own component along `G`'s normal,
      landing it on `G` itself -- the point already visible right after the step is the
      whole answer, so nothing new needed drawing to explain it; the browser now also
      names the step's own result shape (see below) so "point" reads explicitly rather
      than needing to be inferred.
- [x] `a ^ ground`: wedging a grade-1 point with a grade-3 plane gives a grade-4
      pseudoscalar -- a signed volume, not a point, line, or plane, so it has no shape to
      draw at all; this was already correctly computed, just silent about it. Added
      `browser_bridge.shapeDescription`/`nimStepShape` so the browser names what a step's
      result actually is, reading "mixed grade, nothing to draw" for exactly this step
      instead of looking like a bug, and surfaced it in `glue.js`/`rga_browser.html` as a
      small caption under the step formula.
- [x] Replaced "hide a rolled-off step" with "gray it out": added `mesh.muted` (grays to
      `Ink.Grid.colour`, cuts alpha by a new `FRACTION_DIMMED_ALPHA = 0.3`) and threaded
      an `are_dimmed` array through `assembleMeshes`/`renderFrame` (default all-false, so
      ordinary interactive rendering is untouched). `runStoryboard` and
      `browser_bridge.nimGotoStep` now distinguish "reached" (drawn at all -- every seed
      and every step up to the current one, permanently, once reached) from "focal" (this
      step's own operands/result plus the step right before -- drawn at full colour;
      everything else reached draws muted, as background context instead of disappearing).
- [x] Plane circles now centre on how they were built, not always on their own
      closest-to-origin support. Added `scene.creationAnchor(operation, m, n, derived)`,
      dispatching on `Operation` and operand `Shape`s: a plane wedged from a line and a
      point (`G = L ^ c`) centres at the midpoint of the point and its own orthogonal
      projection onto the line (`unitize`+`add`+`position` on the two unit-weight points,
      exploiting that `position` divides by weight to give the exact average -- RGA-native,
      no hand-rolled vector arithmetic); a perpendicular plane from a point and a line
      (`ExpandWeight`) centres where the line actually meets it (`wedgeAnti(line, plane)`,
      the real meet operator); the ground seed centres on the arithmetic centroid of its
      three defining points, by the same unitize-sum-position trick extended to three.
      Unrecognised operation/shape combinations return `none`, falling back to the old
      support-based anchor exactly as before. A bare derived `Multivector` carries no
      memory of which operands built it (many different point-triples give the same
      plane), so the anchor has to be computed at construction time, not read back off
      the result -- extended `Scene` with a parallel `anchor_overrides` array (a rendering
      hint, not saved/loaded) and `addItem`'s signature, and wired `creationAnchor`
      through both the scripted storyboard (`applyStep`/`constructSeeds`) and the
      interactive desktop editor's own drag-to-construct and apply-operation paths
      (`interaction.endDrag`, `panel`'s apply button), so the improvement is not
      storyboard-only.
- [x] Added tests: `creationAnchor` for the `Wedge`(line, point) and `ExpandWeight`
      cases (both operand orders), and for operation/shape combinations it doesn't
      special-case (returns `none`); `mesh.muted`'s colour/alpha transform. Rebuilt and
      reran the full native suite (68 tests) and the desktop binary, regenerated the
      storyboard under `xvfb-run` and visually confirmed on the real OpenGL path: the
      perpendicular-plane circle now centres exactly on the point it was built from (the
      line it's perpendicular to happens to pass through that same point), `G = L ^ c`'s
      circle sits between the line and the point rather than off toward the origin, and
      steps rolled past now fade to a barely-visible muted grey instead of vanishing.
      Rebuilt the browser bridge, reassembled the artifact, and smoke-tested headlessly
      (Playwright + SwiftShader): stepped through all eleven storyboard steps checking
      `nimStepShape`'s text against each step's real result, zero console or page errors,
      confirmed the same creation-anchored centring and dimming visually in the browser.

Artifact: `https://claude.ai/code/artifact/a523f27b-d74e-4987-9b6e-7b1680e469a6`
(same URL, republished).

## Process notes

- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build (native or `nim js`), stripped back out before each commit.
- Browser build flags: `nim js -d:release --define:pga.dimensions=4
  --define:pga.is_conformal=false --define:visualiser.items_max=16
  -o:browser_bridge.js visualiser/browser_bridge.nim`.
- Storyboard PNGs/GIF regenerated via `xvfb-run -a ./visualiser --hidden
  --storyboard:DIR` against the delegations copy's own build, to confirm fixes visually
  on the real (Mesa llvmpipe) OpenGL path, not just headless WebGL.
