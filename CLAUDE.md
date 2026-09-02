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

1. **`CONSTITUTION.md` and `STYLE.md`** — copy both verbatim from
   `lengyel/projective_geometric_algebra_illuminated/`. The constitution is the rule of law:
   design, naming, documentation, cost, tests, form, record. `STYLE.md` is the Nim expression
   guide: how each rule is spelled in Nim, and what each backend does with a value. Read both
   fully before writing code, not after; every decision below cites an article. Adapt only if
   the new project's language genuinely demands it, and say so in `PROVENANCE.md`.

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

## The three documents

**`CONSTITUTION.md`** governs every decision and **`STYLE.md`** its Nim spelling. Follow
both exactly; neither is advisory. The rules most often violated in practice: every
declaration gets a doc comment (Art. VI.1); a stage comment names a step's *goal*, never its
mechanism (VI.4); no sentinel smuggling absence into a value's own range (IV.4); a binding
in a hot path is a copy until the generated output says otherwise (VII.1); the 100-column
limit is measured in *characters*, so a byte-counting checker lies about non-ASCII (X.1).

**`PROVENANCE.md`** records who made this, from what, and how far it has been checked.
Open it with a table:

```
| Field  | Value |
|--------|-------|
| Agent  | Claude Code |
| Author | <model> |
| Date   | <date> |
| Style  | `CONSTITUTION.md` and `STYLE.md`, supplied with the prompt; followed for all code. |
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

Each of these is now an article of the constitution, listed here because every one came
from a real failure on the existing project and cost more to relearn than to follow.

- **Verify by running, not by reasoning** (IX.5, IX.6). Render the output and look at it;
  drive the UI with real events; read the bytes back; rebuild before you drive.
- **A declaration's own doc outranks any summary table** (I.4). This trap produced wrong
  operator notation twice.
- **When one language compiles to another, write the source language** (II.1). Hand-written
  JS only for DOM, WebGL and event wiring; every derived value sits behind an export.
- **Never depend on what the project exists to understand** (II.1); justify each external
  dependency where it is imported.
- **Check the sibling when you fix a duplicated copy** (II.1); each copy names the others.
- **Read the generated output before believing a cost** (VII.1). Seven rounds here each
  found the JS backend's deep copy again in a new place.
- **Instruments are gated on their reader** (VII.4). One round measured a frame whose largest
  cost was measuring it.
- **A restore issues a fresh revision** (II.6). Reusing the snapshot's own counter drew a
  previous scene over the current one.
- **Say "unmeasured" rather than repeat a figure** (VII.5, VII.6).
- **Every comment is telegraphic, and a checker says so** (VI.5): `tools/check_prose.nim`.

## Dependencies and vendoring

Vendored source is **kept locally and never committed**. Record in `PROVENANCE.md` where it
came from, at which commit, and under which licence, and honour that licence's notice
requirements. Keep a copy in the working tree so builds and tests run; just never stage it.
Check `git status` before every commit.

## Committing

Conventional Commits with a fixed scope, lowercase imperative summary, no trailing period;
one intention per commit (Art. XI); join related clauses with `;`.

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
