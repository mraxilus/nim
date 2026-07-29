# Working notes: browser rendering pipeline through the real library — done

This file mirrors the task tracker I use internally, plus anything worth knowing about
each round. Tracked in git (per your stop-hook check).

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, diagnostics panel, object
pool readouts, refactor/colour/visual-noise audits, scene save/load, unbounded
camera-relative drawing, fading-disc planes made visible, ground grid/axes made
indefinite, categorical palette checked against the axis colours, rim+crosshair planes
with a distance-cutoff grid, then flat fill back under the rim with a wider grid
cutoff) are summarized in prior commits on this branch — ask if you want that history
restated.

## This round

Asked for a second, browser-based rendering pipeline so the workbench is reachable from
a phone. First pass wrongly hand-rolled the demo's vector algebra directly in JS; told
to use the actual `pga` library instead, compiled through Nim's own JS backend, since
being a testbed for that library is the whole point.

- [x] `visualiser/browser_bridge.nim`: new module, compiled with `nim js`, that builds
      the fixed fifteen-object demo through the real `pga`/`objects`/`mesh`/`camera`/
      `scene`/`storyboard` modules — same joins, meets, attitudes, supports, expansions
      and orthogonal projections the desktop app runs, same camera orbit math, same
      tessellation. Exports plain functions a browser calls directly: step transport,
      camera orbit/dolly/pan, and one frame's vertex buffers plus view-projection matrix
      as flat arrays ready for `gl.bufferData`/`gl.uniformMatrix4fv`.
- [x] `scene.nim`: two JS-backend compatibility fixes, both gated behind
      `when defined(js)` and inert on the native build (full suite still passes) —
      `Item` holds its `Scene` by value instead of by `ptr` (a value parameter's own
      address does not survive a call the same way under the JS backend as under C++),
      and `saveScene`/`loadScene` (file I/O has nothing to target in a browser) are
      gated to native builds only.
- [x] Rewrote the artifact's own script as two layers: the compiled bridge inlined
      verbatim, then a thin hand-written layer that is WebGL calls, DOM wiring and
      pointer input only — no geometry or camera math of its own, mirroring how
      OpenGL/SDL/Dear ImGui sit over the same CPU-side geometry on the desktop app.
- [x] Verified headlessly (Playwright + swiftshader): no console/page errors across
      storyboard playback, drag-orbit, pinch/wheel-zoom; screenshots match the prior
      (pre-fix) renders pixel-for-pixel in composition, confirming the swap in engines
      changed nothing about what's drawn.
- [x] Rebuilt and reran the native suite (64 tests) and the desktop binary itself after
      the `scene.nim` patch, to confirm zero regression on the C++ backend.
- [x] Republished the same artifact URL with the corrected pipeline.

Artifact: `https://claude.ai/code/artifact/a523f27b-d74e-4987-9b6e-7b1680e469a6`.

## Process notes

- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build (native or `nim js`), stripped back out before each commit.
- Browser build flags: `nim js -d:release --define:pga.dimensions=4
  --define:pga.is_conformal=false --define:visualiser.items_max=16
  -o:browser_bridge.js visualiser/browser_bridge.nim` — `items_max` trimmed from the
  desktop default of 64 since the fixed demo only ever holds fifteen objects, and
  `Item`'s JS-backend value-copy makes `Scene`'s own size worth keeping small.
