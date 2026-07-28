# Working notes: live diagnostics + usability pass — done

This file mirrors the task tracker I use internally (visible to me as a todo list, not
otherwise visible to you), plus anything else worth knowing about how each round went.
Tracked in git going forward (per your stop-hook check), so it stays part of the
branch's own history rather than living only in this session.

All tasks through this round are done and pushed. Kept below for the record; ask if you
want the full history from earlier rounds (arenas, GC removal, GIF/PNG, storyboard...).

## Task list (final state, this round)

- [x] #26 Add arena peak/usage accessors
- [x] #27 Add ImGui shim widgets for stats viz (progressBar, plotLines, tooltip,
      helpMarker, poolBar)
- [x] #28 Wire live frame-time ring buffer
- [x] #29 Build Diagnostics panel section
- [x] #30 Usability pass over workbench window
- [x] #31 Rebuild, test, smoke-test GUI changes
- [x] #32 Commit, push, refresh delegations tarball
- [x] #33 Add object-pool + total memory usage to diagnostics
- [x] #34 Disambiguate the object-pool memory line's wording (you caught this one: the
      first phrasing, "X KB total, Y KB active", read like Y was a single object's own
      cost rather than every live object added together)

Commits on `claude/rga-visualization-prototype-kbq9kw`: `3a58ddd` (diagnostics panel +
usability pass), `06674a4` (this file, first commit), `65225a3` (object-pool memory +
total memory line), `030e7f3` (disambiguate the wording). Delegations repo: `fe82294`,
`68adfe8`, `b42032a`.

## What shipped, cumulative

- **Diagnostics panel** (collapsible, closed by default): live raw per-frame-time graph,
  vsync + fps/tessellate readout, a fill bar for the permanent arena, a peak-usage bar
  for the frame arena (`arena.nim` tracks a `peak_used` high-water mark since it reads
  empty between exports), a coloured per-slot object-pool bar (green = active, dark =
  free) with an "N active, M free" count, the pool's own fixed memory split into
  total/active KB, and a closing **total** line summing every fixed reservation the
  binary makes for itself (both arenas at full capacity, tessellation storage, the
  object pool, the panel's own state) — computed once as a `const` in `visualiser.nim`
  and handed to the panel through `Workbench`, since `panel.nim` alone can't see the
  arenas' backing arrays or the mesh/timings buffers beside them.
- **Usability pass**: every top-level panel is a collapsing header; tooltips on every
  non-obvious control; the drag rubber-band is colour-coded by operation (join=cyan,
  meet=coral, project=lime) matching a legend at the top of the panel.

## Issues found and fixed during QA (both caught by actually rendering the panel
headless and looking at it or catching a crash, not by inspection)

1. **Crash**: `gui.plotLines("", ...)` — an empty ImGui label collides with the ID Dear
   ImGui assigns the window itself. Fixed with `"##frame_time"`.
2. **Wrong data**: the arena-stats snapshot was only wired into `runInteractive`'s loop,
   so `runStoryboard` (shares the render/panel code, not that loop) showed "0.0 / 0 MB"
   for both arenas in every exported PNG. Fixed by moving the snapshot into
   `renderFrame` itself, the code path both modes share; reverified with a fresh
   storyboard capture showing correct non-zero figures.
3. **Ambiguous wording** (you caught this one, not me): the object-pool memory line
   read "X KB total, Y KB active", which reads like Y is one object's own cost. It's
   actually every currently-live object added together (`count × bytes/slot`), and the
   real per-object cost (~195 B) is well under 1 KB either way. Reworded to lead with
   the explicit per-slot figure so the aggregate can't be misread as a single object's.

All three written up in the delegations copy's `PROVENANCE.md`, including what's still
*not* verified (no human has hovered a tooltip or clicked a header — headless rendering
can't simulate that; the frame-time graph reads flat in storyboard mode since nothing
feeds it there).

## Process notes

- QA method each round: temporarily patch `panel.nim` locally (force the diagnostics
  header open, enlarge the panel/window/arena-capacity defines) to get one screenshot
  showing the whole panel under Xvfb, then revert every throwaway change before the
  real build — confirmed clean each time by diffing against a saved backup.
- Test suite (`nim c ... -r tests/visualiser/test_4d.nim`) doesn't reach panel/gui/
  renderer at all (need a live GL context by the project's own design), so the only
  real verification for GUI work is building the actual binary and rendering headless
  under Xvfb — which is what caught both issues above.
- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked; they
  get copied in locally to build and stripped back out before each commit.
