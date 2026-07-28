# Working notes: SoA-to-Item copy minimization pass — done

This file mirrors the task tracker I use internally (visible to me as a todo list, not
otherwise visible to you), plus anything else worth knowing about how each round went.
Tracked in git (per your stop-hook check), so it stays part of the branch's own history.

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, live diagnostics panel, object
pool + total memory readouts, refactor/colour/visual-noise audits) are all done and
summarized in prior commits on this branch — ask if you want that history restated here.

## This round: task list (final state)

You asked why `Scene`'s structure-of-arrays slots get copied into full `Item` objects
on the stack whenever read, and to minimise data copying that has no good reason
behind it. First pass shipped, then you rejected its design (see below) and asked for
something cleaner; second pass is what's actually in the tree now.

- [x] Diagnose why: `scene[slot]`, `items`, and `pairs` all assemble a full `Item` —
      copying every field, `geometry` (128-byte `Multivector`, 4D rigid PGA) and
      `label` (40-byte array) included — whether or not the caller wanted them.
- [x] **First pass (commit `12b50b2`), rejected:** added five standalone field
      accessors (`geometry`/`label`/`ink`/`isVisible`/`born`) plus a `liveSlots`
      iterator to `scene.nim`, and migrated all seven identified call sites across six
      files to use them. Worked, tests passed — but left two ways to read the same
      slot (an `Item` copy and the new accessors) side by side, for a problem that
      didn't need a second API. You called this out directly and asked for a cleaner
      design.
- [x] **Second pass (commit `dce1dc7`), shipped:** redefined `Item` itself as a
      16-byte handle (a `ptr Scene` plus the slot number) instead of an assembled
      value. `.geometry`/`.label` resolve via `lent`; `.ink`/`.is_visible`/`.born` are
      trivial pointer-relative reads. Because `` `[]` ``, `items`, and `pairs` already
      construct an `Item` internally, every existing call site — `scene[slot].geometry`,
      `for item in scene`, `for slot, item in scene.pairs` — became zero-copy
      automatically, with no call site needing to change at all. Reverted all six
      files from the first pass back to their original form (`picking.nim` and
      `panel.nim` keep one small "cache the repeated read into a local" tweak,
      unrelated to the copying fix); deleted the five standalone accessors and
      `liveSlots` as redundant now that the thing they routed around no longer copies.
- [x] Checked, before converting `Item` to a view: no test anywhere holds an `Item`
      across a scene mutation (`removeItem` then a slot's reuse via `addItem`) — so
      nothing relied on `Item`'s old copy semantics, and the conversion is safe.
- [x] Considered Nim's second index operator, `` `{}` `` (`a{i}` → `` `{}`(a, i) ``,
      distinct from `` `[]` ``), as a way to offer a real owned-copy variant alongside
      a zero-copy `[]`. Nothing in this codebase currently needs a frozen copy of an
      item across a mutation, so didn't add it — that would have been exactly the kind
      of speculative surface the rejection above was about. Worth revisiting only if a
      genuine future need (undo/redo, before/after comparison) shows up.
- [x] Rebuild, re-run the full test suite, re-run both smoke tests (screenshot +
      storyboard) under Xvfb and confirm every frame renders identically to before —
      a pure internal representation change, so no visible difference is expected or
      found. `sizeof(Item)`: 178 bytes (assembled struct) → 16 bytes (pointer + int).
- [x] Commit/push source (both passes); sync + rebuild/test standalone in the
      delegations copy; update its `PROVENANCE.md` to narrate the rejected first pass
      honestly, not just the final design; regenerate its storyboard assets; retar;
      deliver.

Commits: `12b50b2` (first pass, superseded), `dce1dc7` (shipped) on
`claude/rga-visualization-prototype-kbq9kw` (source). Delegations repo: `a65faed`
(first pass sync), `1ccbdfa` (shipped design sync + corrected `PROVENANCE.md` +
regenerated storyboard assets).

## Process notes

- The correction that mattered this round: "additive, don't touch existing call
  sites" is not automatically the right instinct. Here the *representation* of `Item`
  was the actual bug; fixing that representation once made every existing call site
  correct for free, which is strictly better than adding a parallel API and migrating
  callers to it. Generalizes past this project: before reaching for "add a new
  accessor/path and route hot callers to it," check whether the type at the root can
  just stop lying about its own cost instead.
- `lent` used only where it earns its keep (the two large fields, now living on
  `Item`'s own accessor procs rather than on `Scene`); small scalar fields return by
  plain value.
- QA method unchanged from earlier rounds: full test suite plus a headless screenshot
  and storyboard regeneration under Xvfb, compared visually against the pre-change
  renders (expecting, and finding, no difference at all) — done for both passes, not
  just the final one.
- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build, stripped back out before each commit.
