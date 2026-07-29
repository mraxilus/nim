# Working notes: visible planes, indefinite furniture, reorient not zoom — done

This file mirrors the task tracker I use internally (visible to me as a todo list, not
otherwise visible to you), plus anything else worth knowing about how each round went.
Tracked in git (per your stop-hook check), so it stays part of the branch's own history.

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, live diagnostics panel, object
pool + total memory readouts, refactor/colour/visual-noise audits, the Item-copying
correction, scene save/load, unbounded camera-relative drawing with fading-disc planes
and skybox horizons) are all done and summarized in prior commits on this branch — ask
if you want that history restated here.

## This round: task list (final state)

Feedback on the previous round's own storyboard frames: the finite plane's disc read
as invisible rather than merely translucent (fading from a peak alpha too faint to see
anywhere on it); the ground grid and world axes, despite being camera-relative, still
fell short of reading as indefinite in practice (both still shrank back whenever the
camera dollied in); and the horizon camera-aiming fix should reorient the camera
instead of widening its lens.

- [x] Fixed `addDisc` (`mesh.nim`) to hold a flat, clearly visible alpha (`ALPHA_WASH`
      raised from 0.10 to 0.35) out to `FRACTION_DISC_PLATEAU` (0.7) of its own radius,
      fading to transparent only across the remaining outer band — an inner fan plus
      an outer annulus of quads, rather than one fan faded corner to corner.
- [x] Split world furniture off its own extent: a new `DrawExtent.extent_furniture`,
      computed by `extentFurnitureFor(distance_far)`, tied to the camera's fixed far
      clip distance rather than orbit distance, so the ground grid and world axes keep
      reaching outward regardless of zoom. Gave the grid a fixed cell size
      (`SIZE_CELL_GRID`) while doing so, rather than stretching its existing four cells
      each way over the much larger span — otherwise the grid would have gone coarse
      enough to read as empty ground right around the camera, exactly the reference
      grid's own reason to exist.
- [x] Removed the storyboard's per-step field-of-view widening for horizon-producing
      steps, relying on the existing camera reorientation (`azimuthElevationFor`)
      alone.
- [x] Updated tests for the new disc shape and the split furniture extent (still 62
      tests; existing ones rewritten rather than added to), plus one test-only fix: a
      fixed absolute tolerance rejected a disc centre vertex that had round-tripped
      through `Vertex`'s own `float32` storage and come back `1.25e-8` off zero rather
      than exactly zero — swapped for `isNear`, already calibrated for values that
      passed through that same 32-bit storage.
- [x] Rebuilt, ran the full test suite, and regenerated the storyboard under Xvfb:
      confirmed the ground seed plane's disc is now a clearly visible wash from the
      first frame, the ground grid keeps its original near-camera spacing while
      reaching visibly further out alongside the axes, and the horizon steps (star,
      great circle) still land centred in frame from reorienting alone.
- [x] Commit/push source; sync + rebuild/test standalone in the delegations copy;
      update its `PROVENANCE.md`; regenerate its storyboard assets; retar; deliver.

Commits: `c5db947` on `claude/rga-visualization-prototype-kbq9kw` (source).
Delegations repo: `17afc0f` (synced copy + `PROVENANCE.md` + regenerated storyboard
assets).

## Process notes

- All three fixes were feedback on the previous round's own output, not new requests
  in the abstract — driving each one back to a specific storyboard frame (the invisible
  disc, the grid that hadn't actually grown, the widened lens) before deciding what to
  change kept the fix targeted rather than a broader redesign.
- One test-only false lead: a fixed absolute tolerance rejected a disc centre vertex
  that had round-tripped through `Vertex`'s own `float32` storage and come back
  `1.25e-8` off zero rather than exactly zero. Traced with a throwaway script printing
  every disc vertex's own radius and alpha before touching the test itself, confirming
  the production code was correct and the check was miscalibrated; swapped for
  `isNear`, this suite's own tolerance already built for values that passed through
  that same 32-bit storage.
- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build, stripped back out before each commit.
