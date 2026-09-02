# Working in this repository

Read this before starting a new project here. Claude Code loads it automatically; if you
are another tool, read it anyway.

## What this repository is

A fork of the **Nim compiler** used as a workspace for prototypes. Everything at the root
except the project directories — `compiler/`, `lib/`, `tests/`, `testament/`, `koch.nim`,
`doc/`, `tools/`, `nimdoc/` and friends — is upstream Nim. **Do not modify any of it.** It
is here to build the compiler and to read when you need to know how the language actually
behaves; treat it as a vendored dependency that happens to be checked in.

The compiler built from this tree lives at `bin/nim` and is **not on `PATH`**. Always
invoke it by path:

```sh
/home/user/nim/bin/nim c  --hints:off -o:bin/thing  thing.nim     # native
/home/user/nim/bin/nim js --hints:off -o:out/thing.js thing.nim   # JS backend
/home/user/nim/bin/nim c  --hints:off -r tests/thing/test_default.nim
```

A release compiler will reject some of what these projects use (for example a
`var`-returning index operator), so use this one, not a system Nim.

## Prototypes live in their own top-level directory

One existing project: `lengyel/projective_geometric_algebra_illuminated/` — a visualiser
for the projective geometric algebra of Eric Lengyel's book of that name. The grouping is
`<source-author>/<work-being-replicated>/` because that project replicates a published
source. A project that replicates nothing takes a single descriptive directory at the root
(`snake_case`, spelled out, no abbreviations).

**Never put a new project inside an existing one**, and never scatter its files across the
root. One directory, self-contained, with its own tests and its own documents.

## Scaffold, in this order

1. **`STYLE.md`** — copy `lengyel/projective_geometric_algebra_illuminated/STYLE.md`
   verbatim. It is deliberately domain-agnostic: a systems-programmer stance, four naming
   cases, doc-comment rules, design rules, and a Nim appendix. It is the contract for every
   line you write. Read it fully before writing code, not after. Adapt only if the new
   project's language or domain genuinely demands it, and say so in `PROVENANCE.md`.

2. **`PROVENANCE.md`** — see below. Create it at the start with the header table and grow
   it as decisions are made; do not leave it until the end.

3. **`dependencies.list`** — one system package per line, each with a trailing comment
   saying what it is for. Anything compiled from source rather than linked gets its clone
   command in a comment here too:

   ```
   libsdl3-dev  # Provide windowing, input and OpenGL context creation.
   zlib1g-dev  # Provide deflate and CRC used by the PNG export.
   ```

4. **`<entry>.nim.cfg`** beside each entry point, named after it — `nim c thing.nim` picks
   up `thing.nim.cfg` automatically. Put compile-time configuration here rather than in
   command-line flags a future session has to rediscover. Open it with a comment saying
   what this entry point is and why these flags. Library flags (`-lSDL3`, `-lGL`) belong in
   the module that needs them via `{.passL.}`, not here, so a test binary importing that
   module links without repeating anything.

5. **`tests/<name>/`** — a shared `suites.nim` holding every suite, plus one thin entry
   point per configuration carrying a testament spec and nothing else:

   ```nim
   discard """
   action: run
   cmd: "nim c --hints:on -d:testing -d:nimUnittestAbortOnError:on $options -r $file"
   matrix: "-d:pga.dimensions=4 -d:pga.is_conformal=false"
   batchable: true
   joinable: true
   """
   include "./suites.nim"
   ```

6. **`bin/`** for build output. Not committed.

## The two documents

**`STYLE.md`** governs code. Follow it exactly; it is not advisory. The rules most often
violated in practice: every declaration gets a doc comment; body comments name a step's
*goal*, never its mechanism; no sentinel value smuggling absence into a value's own range
(`Option[T]`, not `-1`); the hard 100-column limit is measured in *characters*, so a
byte-counting checker will lie to you about any line containing non-ASCII.

**`PROVENANCE.md`** records who made this, from what, and how far it has been checked.
Open it with a table:

```
| Field  | Value |
|--------|-------|
| Agent  | Claude Code |
| Author | <model> |
| Date   | <date> |
| Style  | `STYLE.md`, supplied with the prompt; followed for all code. |
| Review | **Unreviewed.** Nothing here has been read line by line by a human. |
```

That review line is the point of the file — AI-authored work must carry its own
verification status, and it must stay accurate.

Then document the **current** design, organised by subsystem, not as a changelog. For each
non-obvious decision record what was chosen, what was rejected, and what the choice costs.
State plainly which claims were *verified* and which were assumed — that distinction is the
file's most valuable property, and it is what makes the rationale provenance rather than
just a design doc. Keep every concrete constant and its reasoning; a fresh session must be
able to rebuild the project from this file plus the source.

Do not narrate history. Superseded experiments, fixed bugs and abandoned designs come out.
Where a rejected alternative is still a live trap, one terse line — "not camera-scaled,
which visibly resizes a plane as the camera orbits" — earns its place; a paragraph about
how you got there does not. Prune the file whenever it starts reading as a diary.

## Working practices

These come from real failures on the existing project. They cost more to relearn than to
follow.

- **Verify by running, not by reasoning.** Compiling is not evidence the thing works.
  Render the output and look at it; drive the UI with real synthetic events; read the
  bytes back. Several bugs here survived review and passed tests because a test called a
  handler directly and bypassed the event wiring that was actually broken.
- **A declaration's own doc comment outranks any summary table**, including one in the same
  library's module header. Summary tables drift. This exact trap produced wrong operator
  notation twice.
- **When one language compiles to another, write the source language.** The existing
  project compiles Nim to JavaScript; hand-written JS is a last resort for genuinely
  JS-only concerns (DOM, WebGL, event wiring). Any derived value, lookup or domain rule
  belongs behind an export. Audits keep finding drift here.
- **Never depend on what the project exists to understand.** Derive it. Dependencies are
  for genuinely external concerns, and each is justified where it is imported.
- **Check the sibling when you fix a duplicated copy.** Where a real constraint forces
  duplication, mark each copy with a comment naming the others; a fix to one is not
  finished until the rest are checked.
- **Compare floats through an approximate operator** with configurable tolerance, and make
  exact equality a compile error on those types.
- **Read the generated output before believing a cost.** On the JS backend a `let` of an
  object, a by-value parameter and a by-value return each deep-copy. Six separate rounds on
  the existing project each found this again in a new place. Alias, `lent`, `var`, and read
  the call inline; then check one instance in the emitted JavaScript.
- **Rebuild before you drive.** A driver run against a page built from an older tree reports
  that tree's bugs and hides yours. `tools/verify.sh` builds then drives, in that order; an
  ad-hoc run must do the same or its result is not evidence.
- **Instruments are gated on their reader.** Per-object clock reads, tallies and breakdowns
  run only while the panel that shows them is open. One round here measured a frame whose
  largest cost was measuring it.
- **A restore issues a fresh revision.** Undo, redo, clear and load go through one
  procedure that hands out a revision newer than any ever issued. Reusing the snapshot's own
  counter aliased a cache keyed on it and drew a previous scene over the current one.
- **Say "unmeasured" rather than repeat a figure.** A performance claim carried in
  `PROVENANCE.md` without its before-and-after pair is a story, not a record.
- **Every comment is telegraphic, and a checker says so.** `STYLE.md`'s article rule covers
  headers, body comments and glue in other languages; `tools/check_prose.nim` enforces it, so
  a review never has to.

## Dependencies and vendoring

Vendored source is **kept locally and never committed**. Record in `PROVENANCE.md` where it
came from, at which commit, and under which licence, and honour that licence's notice
requirements. Keep a copy in the working tree so builds and tests run; just never stage it.
Check `git status` before every commit.

## Committing

Conventional Commits with a fixed scope, lowercase imperative summary, no trailing period;
join related clauses with `;`. Use `refactor(scope):` freely.

```
feat(visualiser): add undo/redo over scene-content edits
fix(visualiser): guard endDrag against an operand removed mid-drag
docs(style): require generators to document emissions
```

Commit only your project directory. If a change seems to require touching upstream Nim,
stop and ask — it almost certainly does not.

## Reference implementation

When a convention here is ambiguous, read
`lengyel/projective_geometric_algebra_illuminated/` and follow what it does. Its
`PROVENANCE.md` is the model for the shape and density expected, and its `visualiser.nim`
module doc shows how to document a project split across multiple build targets.
