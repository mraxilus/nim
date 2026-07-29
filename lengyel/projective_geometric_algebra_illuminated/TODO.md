# Working notes: plain rim + crosshair planes, fading grid — done

This file mirrors the task tracker I use internally, plus anything worth knowing about
each round. Tracked in git (per your stop-hook check).

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, diagnostics panel, object
pool readouts, refactor/colour/visual-noise audits, scene save/load, unbounded
camera-relative drawing, fading-disc planes made visible, ground grid/axes made
indefinite, categorical palette checked against the axis colours) are summarized in
prior commits on this branch — ask if you want that history restated.

## This round

Feedback: the ruled-disc plane still didn't work. Prototyped five alternatives in
isolation (single-plane scene, env-var-switched variants on one build) and presented
three side by side for a pick: polar grid, rim + crosshair, checkerboard.

Chosen: rim + crosshair, fill dropped entirely.

- [x] `addPlane` now draws a circular rim at the plane's own drawn extent plus a
      crosshair through its centre — same reach a line's segment gets, no fill.
      Removed `addDisc`/`addPlaneGrid` and their now-unused constants
      (`FRACTION_DISC_PLATEAU`, `ALPHA_WASH`, `ALPHA_GRID_PLANE`, `SEGMENTS_DISC`).
- [x] `addGrid` fades each vertex by its own distance from the origin
      (`alphaGridFade`) — full alpha through the camera's usual range, exactly zero
      at the grid's own outer edge — fixing the aliasing noise the converging lines
      caused near the horizon. Per-vertex, not per-piece, so the fade is smooth and
      the true tip of every line reaches zero exactly.
- [x] Updated tests (64 total): rim/crosshair shape, and grid-fade near/far alpha.
- [x] Rebuilt, ran the full suite, regenerated the storyboard, verified visually.
- [x] Commit/push source; sync + rebuild/test delegations copy; update its
      `PROVENANCE.md`; regenerate its storyboard; retar; deliver.

Commits: `5962247` on `claude/rga-visualization-prototype-kbq9kw` (source).
Delegations repo: `28226db` (synced copy + `PROVENANCE.md` + regenerated storyboard).

## Process notes

- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build, stripped back out before each commit.
