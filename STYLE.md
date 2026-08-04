Coding Style — RGA Workbench
===

_This is a contract, not advice. Every line of this project follows it._


Stance
---

Solve the problem in front of you: no speculative generality, no framework. The reader can see
through code to its cost — no hidden control flow, no hidden allocation. The caller owns
memory; prefer fixed-size storage of statically known extent.

Use the **least powerful construct** that does the job well — constant before variable, pure
function before procedure, plain function before template, template before macro — and escalate
only where you can name, in a comment, the goal the weaker one cannot meet. Metaprogramming is
priced, not forbidden: where a spec genuinely is a table and its operations follow mechanically,
define the table once and generate from it.

Before deriving a value in a wrapper layer, check whether the primary layer already computes it
and expose that instead.


Layout
---

- 2-space indent, never tabs. No trailing whitespace.
- **Hard 100-column limit, measured in characters and not bytes.** A byte-counting checker lies
  about every line holding a non-ASCII character, and this codebase is full of them.
- Functions fit one screen: 60 lines, nesting depth 3. Exceed only where the shape of the data
  demands it, and **say so in a comment** rather than inventing a helper whose only purpose is
  the number.
- Guard clauses and early returns.
- Divide every file into sections with a banner comment, **one tier only**. A file wanting
  sub-sections wants splitting.
- File order: module doc → compiler directives → standard imports, alphabetised → blank line →
  local imports → body.
- One element per line in a multi-line construct gets a trailing separator, so lines reorder
  freely. A pure line-length wrap does not.
- Order definitions so a first-time reader proceeds top to bottom. Alphabetise where nothing
  forces an order.


Naming
---

Four cases, no exceptions, because the case is the signal:

| Kind | Case | Example |
|------|------|---------|
| Types | PascalCase | `Multivector`, `ScreenPoint` |
| Callables | camelCase | `drawAnchor`, `creationAnchor` |
| Constants, compile-time configuration | SCREAMING_SNAKE | `ITEM_CAPACITY`, `PLANE_RADIUS` |
| Locals, parameters, fields | snake_case | `is_visible`, `frame_arena` |

Adopt this even where the language community differs; a mixed scheme destroys the signal.

- Name by what a callable **is**: one that acts opens with a verb, one that names a property
  takes the domain's bare noun — `centroid`, not `getCentroid`.
- **Verb first, discriminator last**, so a family shares the longest common prefix: `normBulk`,
  `normWeight`; `node_left`, `node_right`.
- Booleans carry a kind prefix: `is_`, `as_`, `should_`, `found_`.
- Lookup tables read `lut_<subject>_to_<object>`.
- **Do not truncate a word you coined**: `ctx`, `tmp`, `cfg`, `mgr` are forbidden. Established
  domain jargon (`lut`, `min`, `src`/`dst`) is not truncation.
- Single letters only where the domain's own equations use them.
- Where the domain has canonical notation, mirror it in identifiers and operators, and always
  ship an ASCII-named façade of one-line forwarders alongside, so no caller is forced into the
  notation.


Documentation
---

- **Every declaration gets a doc comment.** Three exceptions only: a run of mechanical
  declarations documented once above the run, test fixtures, and a declaration whose sole
  purpose is to fail at compile time. Never leave the slot empty; write a TODO where you cannot
  write it yet.
- A **generator documents what it emits**, with the doc text a required parameter of the
  emitting helper, so an undocumented emission cannot compile.
- Doc comments are telegraphic: omit articles, end every line with a period, **first line
  imperative** opening with a verb, elaboration declarative.
- **Body comments name the goal of a step, never its mechanism.** Write each as the completion
  of an unwritten "In order to…", open with a bare verb, one line before each logical step.
- Document the decision, not the mechanism: which convention, what was rejected, what it costs.
- **A summary index is a derived view, not a source of truth.** Where a table and a declaration
  disagree, the declaration wins.
- **A doc comment asserting a global property names what enforces it** — a test, a pragma, a
  compile-time check — or marks itself unverified.


Design
---

- Configure by compile-time constant where a whole module specialises on the choice.
- Use a distinct type for every domain quantity that should not be interchangeable with its
  representation.
- **Optional values are an explicit optional type; no sentinels smuggling absence into a
  value's own range** — no −1 index, no NaN, no null, no magic "none". Where a foreign-function
  boundary genuinely cannot carry an optional, keep the optional internally and translate
  through **one named constant at the boundary**; the boundary is where a representation is
  translated, not a licence to use sentinels upstream.
- **No silent identity on degenerate input**: a routine that cannot do its job signals, rather
  than returning its argument.
- **When merging several states or code paths into one, enumerate the old behaviour first** —
  by reading the old code, not by recalling the request. A request naming one behaviour to
  preserve is not licence to drop the rest.
- Bind a case expression to a constant instead of an if/else chain.
- **Make misuse uncompilable, and say what to do instead.**


Prohibited
---

- Inheritance or interfaces for domain modelling.
- Runtime polymorphism in hot paths.
- Exceptions as control flow.
- Failure encoded as an in-range value.
- Coined-word truncations.
- Comments restating code.
- Empty documentation slots.


Commits
---

Conventional Commits with a fixed scope, lowercase imperative summary, no trailing period; join
related clauses with `;`. Use `refactor(scope):` freely.
