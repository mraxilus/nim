# Working notes: fixed plane size, indefinite lines, stray markers gone — done

This file mirrors the task tracker I use internally, plus anything worth knowing about
each round. Tracked in git (per your stop-hook check).

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, diagnostics panel, object
pool readouts, refactor/colour/visual-noise audits, scene save/load, unbounded
camera-relative drawing, fading-disc planes made visible, ground grid/axes made
indefinite, categorical palette checked against the axis colours, rim+crosshair planes
with a distance-cutoff grid, flat fill back under the rim with a wider grid cutoff,
then a browser rendering pipeline through the real library) are summarized in prior
commits on this branch — ask if you want that history restated.

## This round

Feedback on the browser pipeline, present in both it and the desktop app since both
draw through the same `mesh.nim`: two stray points beyond the three seed points (one at
the origin, one just above); lines reading as cut off or swallowed by planes; planes
visibly resizing as the camera zoomed or orbited.

- [x] Traced the two stray points to a plane's own anchor marker and its normal arrow's
      head marker -- both removed. The normal itself still draws as a bare shaft with
      no marker at its tip, so orientation still reads without adding a point.
- [x] Planes now draw at a fixed radius (`EXTENT_PLANE`, 8 world units) around their own
      support, independent of the camera entirely -- replaces the old camera-relative
      `extentFor(camera.distance)`, which grew or shrank a plane as the camera dollied.
      `DrawExtent.extent` and `extentFor` are gone; nothing needed them once planes
      stopped scaling with distance.
- [x] Lines now reach `extent_furniture` either side of their own support -- the same
      camera-far-clip-relative reach world axes and the ground grid already use, so a
      line reads as running out toward the horizon rather than stopping at some
      arbitrary camera-relative length, and dwarfs any plane's now-small fixed radius,
      so a plane crossing it never reads as swallowing the rest of it.
- [x] `picking.nim` updated to match: a line's own pick test now reaches to
      `extent_furniture`, and a plane's own hit bound uses `EXTENT_PLANE` directly,
      matching what is now actually drawn in each case.
- [x] Found and fixed a real bug while checking "hidden by planes": the browser's own
      WebGL draw order drew plane washes before lines/points, with ordinary depth
      writes on, so a plane could occlude a line correctly drawn behind it in the depth
      buffer even at low alpha. `renderer.nim` (the desktop app) already gets this
      right -- opaque kinds first, plane washes last with depth writes off, so a wash
      only tints over what is already drawn rather than hiding it. Rewrote the
      browser's own draw order in `glue.js` to match exactly.
- [x] Verified on the real OpenGL desktop renderer (not just headlessly): a fixed-size
      plane, a line reaching most of the way across the view, and two overlapping
      plane washes with a line clearly legible through both at once, confirming the
      fix in the one shared module (`mesh.nim`) plus the one browser-only draw-order
      fix together resolve all three reports.
- [x] Updated the plane/pick tests for the new fixed radius and the now-empty point
      count on a plane; removed the `extentFor` test, now that the function is gone.
      Rebuilt and reran the full native suite and the desktop binary itself: no
      regressions.
- [x] Rebuilt the browser bridge, reassembled the artifact, and smoke-tested headlessly
      (Playwright + swiftshader) across the full storyboard, drag-orbit and zoom: zero
      console or page errors.

Artifact: `https://claude.ai/code/artifact/a523f27b-d74e-4987-9b6e-7b1680e469a6`
(same URL, republished).

## Process notes

- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build (native or `nim js`), stripped back out before each commit.
- Browser build flags: `nim js -d:release --define:pga.dimensions=4
  --define:pga.is_conformal=false --define:visualiser.items_max=16
  -o:browser_bridge.js visualiser/browser_bridge.nim`.
- Storyboard PNGs/GIF regenerated via `xvfb-run -a ./visualiser --hidden
  --storyboard:DIR` against the delegations copy's own build, to confirm the fix
  visually on the real (Mesa llvmpipe) OpenGL path, not just headless WebGL.
