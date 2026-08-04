RGA Workbench
===

_An interactive workbench for the rigid geometric algebra of 3D space — the degenerate 4D
projective geometric algebra Eric Lengyel writes as RGA._

Place points, lines and planes in a 3D scene, select them, apply the algebra's operations to
derive new objects, and watch what those operations mean geometrically. Two front-ends ship,
and they are the same program: a native binary, and a single self-contained HTML file.

The tool is a **testbed for the algebra library**, not a product built on one. Where a
rendering convenience and a faithful use of the algebra conflict, the algebra wins and the
convenience is documented as a rendering-only choice.

- `REQUIREMENTS.md`-shaped brief this was built from: see the task that produced it.
- `STYLE.md` — the coding contract every line follows.
- `PROVENANCE.md` — what the design is, what was measured, and what was assumed.
- `dependencies.list` — every external dependency and what it is for.


Building
---

The vendored algebra library uses a dot call on a Unicode operator, `m.⟑ n`, which stock Nim
lexes as the dot-like operator `.⟑`. Apply `tools/nim_dot_call.patch` to a Nim checkout and
build that compiler first; without it the library does not compile at all.

Fetch what is vendored (never committed), then build either front-end:

```sh
tools/fetch_vendor.sh

# Desktop: a native binary.
nim c --passC:-Ivendor -o:build/rga src/desktop/main.nim
build/rga

# Browser: one self-contained page.
nim js -d:pga.dimensions=4 -d:pga.is_conformal=false -d:release -o:build/core.js \
  src/browser/main.nim
nim c -r tools/codepoints.nim > build/codepoints.list        # every glyph the tool writes
python3 tools/subset_faces.py build/codepoints.list build/faces
nim c -r tools/bundle.nim                                    # writes build/index.html
```

Everything that can be checked without a human — both suites, both builds, the capture frames,
the palette's separations, and the page driven with real synthetic events — runs from
`tools/verify.sh`.

The algebra's dimension and metric are compile-time defines. `src/desktop/nim.cfg` sets them
for the desktop entry point; a wrong pair fails the build with a message naming the flags.


Running
---

The desktop binary takes, all optional:

| Option | Effect |
|---|---|
| `--screenshot:PATH` | Write one image and exit. |
| `--frames:N` | Exit after N frames. |
| `--hidden` | Never map the window. |
| `--storyboard:DIR` | Capture mode: one image per demo step, plus an animated GIF. |
| `--load-scene:PATH` | Open a saved scene instead of the seeds. |
| `--timings` | Report frame-time statistics over a `--frames:N` run. |
| `--novsync` | Disable vsync, for an uncapped reading. |
| `--fill` | Top the scene up to capacity first, for the heaviest case. |

Drag one object onto another to derive a third: left joins, right meets, middle projects
orthogonally. Drag empty space to move the camera. In the browser, one finger orbits, two pinch
to zoom and pan, a long press selects and a tap adds to a selection.


Testing
---

```sh
nim c -d:pga.dimensions=4 -d:pga.is_conformal=false -r tests/test_desktop.nim
nim js -d:pga.dimensions=4 -d:pga.is_conformal=false -r tests/test_browser.nim
node tools/verify_browser.mjs build/index.html    # real synthetic mouse and touch events
```
