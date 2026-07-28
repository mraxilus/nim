# Working notes: scene save/load — done

This file mirrors the task tracker I use internally (visible to me as a todo list, not
otherwise visible to you), plus anything else worth knowing about how each round went.
Tracked in git (per your stop-hook check), so it stays part of the branch's own history.

Earlier rounds (arenas, GC removal, GIF/PNG, storyboard, live diagnostics panel, object
pool + total memory readouts, refactor/colour/visual-noise audits, the Item-copying
correction) are all done and summarized in prior commits on this branch — ask if you
want that history restated here.

## This round: task list (final state)

You asked for the ability to save and load scenes, using efficient data
representations.

- [x] Researched existing conventions first: `Multivector`'s exact layout (an
      `object` wrapping a private `array[Basis, float]`, no bulk accessor, only
      element-by-element `m[b]`), how `image.nim`/`gif.nim` write binary today
      (stream straight to an open `File` via `writeBuffer`/`writeChars`/`write(char)`,
      no intermediate buffer, endianness picked only because PNG/GIF's own specs
      demand a particular one), and the existing "save PNG" panel control's shape, so
      the new feature would match established idiom rather than invent a competing one.
- [x] Designed a compact binary format of this project's own: 4-byte magic, 1-byte
      version, 1-byte basis count (must match this build's own, catching a scene
      saved under a different PGA dimension/metric), 4-byte item count, then one
      record per live item (ink, visibility, length-prefixed label, one native
      `float` per basis term). Every multi-byte field is host-native — no
      endian-conversion code to write or maintain, since this is a private format
      with no external spec and no cross-machine requirement.
      - Deliberately does **not** persist dead slots, slot numbers, or `born` (the
        appear-in-animation clock reading) — none of them mean anything once
        reloaded into a scene with its own free-list order and its own clock.
      - Labels are length-prefixed, not padded to `LABEL_MAX` — costs nothing for
        padding nobody reads back, and decouples the file from whichever `LABEL_MAX`
        the writing build happened to use.
- [x] Implemented `saveScene`/`loadScene` in `scene.nim`. `loadScene` parses into a
      scene of its own and only replaces the caller's on complete success, so a bad
      path, a foreign file, a wrong-dimension file, or a too-large item count all
      leave whatever scene the caller already held untouched, with a specific
      reported reason.
- [x] Wired a "save scene"/"load scene" pair of controls into the top of the Objects
      panel (sharing one path field, mirroring "save PNG"'s own shape), and a new
      `--load-scene:PATH` headless flag that replaces the built-in demo scene.
- [x] Added six property tests: round trip (confirming a hole from a mid-life
      removal is compacted away, not reproduced), an empty scene, a foreign file, a
      wrong-dimension file, a missing path, and an over-capacity item count.
- [x] Rebuilt, ran the full test suite (58 tests now, up from 52), ran both smoke
      tests, and additionally verified end-to-end: built a scene file with a small
      throwaway script calling `saveScene` directly, loaded it through the real
      `--load-scene` flag on the built binary, and confirmed by screenshot that the
      right objects appeared, visible or hidden exactly as saved.
- [x] Commit/push source; sync + rebuild/test standalone in the delegations copy;
      update its `PROVENANCE.md`; regenerate its storyboard assets; retar; deliver.

Commits: `2bba38a` on `claude/rga-visualization-prototype-kbq9kw` (source).
Delegations repo: `1a11ab5` (synced copy + `PROVENANCE.md` + regenerated storyboard
assets).

## Process notes

- "Efficient data representation" was read as: match the format to how the data
  already lives (SoA, not an assembled struct or a generic text format), avoid
  padding or fields that cost bytes for information nothing reads back (slot
  numbers, `born`, `LABEL_MAX`-padded labels), and reuse the host's own memory layout
  directly rather than write conversion code an external spec doesn't require here.
- A spawned research agent read `Multivector`/`Basis`'s exact shape and the existing
  binary-writer conventions before any design decision was made, specifically so the
  format wouldn't guess at library internals or invent a byte-writing idiom this
  codebase doesn't already use elsewhere.
- QA method unchanged from earlier rounds (full suite, screenshot, storyboard), plus
  one addition specific to this feature: a real save-then-load round trip through the
  actual built binary and CLI flag, not just through the unit tests exercising the
  same two procs directly.
- `pga.nim`/`pga/` and `deps/imgui` are vendored/external, deliberately untracked;
  copied in locally to build, stripped back out before each commit.
