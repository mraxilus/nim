# Working notes: ruled discs, palette checked against the axes — done

This file mirrors the task tracker I use internally (visible to me as a todo list, not
otherwise visible to you), plus anything else worth knowing about how each round went.
Tracked in git (per your stop-hook check), so it stays part of the branch's own history.

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, live diagnostics panel, object
pool + total memory readouts, refactor/colour/visual-noise audits, the Item-copying
correction, scene save/load, unbounded camera-relative drawing with fading-disc planes
and skybox horizons, then a follow-up making those discs actually visible and the
ground grid/axes genuinely indefinite) are all done and summarized in prior commits on
this branch — ask if you want that history restated here.

## This round: task list (final state)

Feedback on the previous round's own storyboard frames: a finite plane's disc, even
holding flat alpha across most of its own radius, still just looked like a cloud —
nothing about it read as a surface with any scale or orientation. Separately: object
colours needed to be visibly different from the axis colours, to avoid confusing the
two.

- [x] Added `addPlaneGrid` (`mesh.nim`): rules a square grid across the disc's own
      flat plateau (`FRACTION_DISC_PLATEAU` of its radius), each line clipped to a
      chord of that plateau's own circle rather than drawn full length and cut off —
      a line never appears to end abruptly inside the fade band beyond it. Fixed cell
      size, matching the ground reference grid's own (`SIZE_CELL_GRID`); tinted the
      plane's own hue at a bolder alpha (`ALPHA_GRID_PLANE`, 0.55) than the wash
      beneath it.
- [x] Checked the categorical palette against the three axis colours directly, not
      just against itself — something no earlier round had done, since axis colours
      are structural furniture rather than data and had never been part of the
      dataviz skill's own validator run. Built the axis hues as OKLCH fixtures and ran
      them through that validator alongside the seven categorical ones (`--pairs
      all`): found `Coral` only 3.8 ΔE from `AxisX`'s red (i.e. indistinguishable),
      `Cyan` 5.8 from `AxisZ`'s blue, `Lime` 10.3 from `AxisY`'s green, and (previously
      unnoticed) `Rose` and `Violet` both under the 15 floor too.
- [x] Re-derived the categorical set: generated OKLCH candidates across the hue
      circle, screened for normal-vision ΔE ≥ 15 against all three axes first, then
      searched that screened pool for seven that also clear the skill's own mutual
      thresholds (CVD ΔE ≥ 8, normal-vision ΔE ≥ 15) against each other, checking
      lightness-band and chroma-floor survive sRGB gamut clipping rather than trusting
      the input target. True "coral" turned out to live in the same neighbourhood
      `AxisX` itself claims, with no lightness or chroma the validator accepts opening
      enough distance from it — retired that slot as `Orchid`, at a hue the search
      could actually clear; the other six keep their old names over new, validated
      hues. Re-picked declaration order for spacing once the hues themselves changed.
- [x] Updated tests: `plane becomes a disc...` extended to check the grid's own
      vertex count, plateau-circle placement and alpha (still 62 tests).
- [x] Rebuilt, ran the full test suite, and regenerated the storyboard under Xvfb:
      confirmed the ground seed's disc now shows a clear ruled grid from the first
      frame, and every categorical object reads as visibly its own colour next to the
      axis lines rather than blending into one.
- [x] Commit/push source; sync + rebuild/test standalone in the delegations copy;
      update its `PROVENANCE.md`; regenerate its storyboard assets; retar; deliver.

Commits: `c9bfc74` on `claude/rga-visualization-prototype-kbq9kw` (source).
Delegations repo: `715b046` (synced copy + `PROVENANCE.md` + regenerated storyboard
assets).

## Process notes

- The palette fix used the dataviz skill's own computed validator throughout rather
  than eyeballing hues — the same discipline that skill itself insists on. The axis
  colours were treated as a third set of fixed points the categorical palette had to
  clear, alongside the two checks (mutual CVD/normal separation, lightness/chroma
  bounds) the palette was already validated against.
- Finding seven categorical hues that simultaneously clear separation from three
  saturated primary axis colours *and* from each other is a real, non-trivial
  constraint — several naive hand-picked candidates failed the mutual or axis checks
  before a systematic OKLCH-space search (screen for axis separation, then search the
  screened pool for a mutually-compatible seven) found a working set.
- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build, stripped back out before each commit.
