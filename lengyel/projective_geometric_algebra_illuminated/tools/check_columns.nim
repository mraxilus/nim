## Hold every source file to the layout rules `STYLE.md` states: line width, trailing
## whitespace, tabs, and a final newline.
##
## Width is counted in **characters, not bytes**. The distinction is the whole reason this
## exists as a tool rather than as a shell one-liner: a `wc -L` or an `awk length($0)`
## counts bytes, and this project's sources are full of multi-byte operators (`∧`, `⟑`,
## `𝐦`) and box-drawing table borders. A byte counter reports a compliant line as eleven
## columns too long and is ignored within a day.
##
## Reads the paths it checks from the filesystem rather than from a list kept here, so a
## new module is covered the moment it exists.
##
## Build and run from the project root:
##   bin/nim c --hints:off -o:bin/check_columns tools/check_columns.nim && bin/check_columns

import std/[algorithm, os, strformat, strutils, unicode]



#[ Stated Limits ]#

const
  COLUMNS_MAX = 100
    ## Hard limit on a line's width, in characters. `STYLE.md` states it as hard: not a
    ## guideline, and not a limit a comment may exceed.
  PATHS_SKIPPED = ["bin", "deps", "fonts", "node_modules", "out", "pga", "pga.nim"]
    ## Files and directories holding nothing this project wrote: build output, and
    ## vendored source kept locally but never committed. Checking vendored code would
    ## report failures nobody here may fix. Matched against each path component, so a
    ## directory name here skips everything beneath it.
  EXTENSIONS_CHECKED = [
    ".nim", ".nims", ".cfg", ".cpp", ".h", ".js", ".mjs", ".html", ".css", ".sh", ".md",
    ".list",
  ] ## Every file kind this project authors. A file kind absent here is not exempt; it is
    ## a file kind that does not exist yet, and adding one means adding it here.



#[ Findings ]#

type Complaint = object ## Hold one line that breaks one rule.
  path*: string ## Where, relative to the project root.
  line*: int ## Which line, counting from one, as an editor numbers them.
  rule*: string ## Which rule, named as `STYLE.md` names it.
  detail*: string ## What was measured, where a number makes the complaint actionable.


iterator sourcesUnder(root: string): string =
  ## Walk every file this project authors, under `root`, in a stable order.
  ##   Sorted rather than left to directory order, so two runs on the same tree report in
  ##   the same sequence and a diff of two reports means something.
  var found: seq[string]
  for path in walkDirRec(root, relative = true):
    var is_skipped = false
    for part in path.split(DirSep):
      if part in PATHS_SKIPPED or part.startsWith("."): is_skipped = true
    if is_skipped: continue
    if splitFile(path).ext notin EXTENSIONS_CHECKED: continue
    found.add(path)
  sort(found)
  for path in found: yield path


proc complaintsIn(path: string): seq[Complaint] =
  ## Check one file against every layout rule, reporting each break separately.
  let content = readFile(path)
  if len(content) > 0 and not content.endsWith("\n"):
    result.add(Complaint(
      path: path, line: countLines(content), rule: "final newline",
      detail: "file does not end in a newline",
    ))
  # A testament spec is written in testament's format, not this project's: `cmd` and
  #   `matrix` are each one line by that format's own rules, with nowhere to wrap a long
  #   set of defines to. The spec is the block a test file opens with, and nothing else in
  #   the file is exempt.
  var
    number = 0
    is_inside_spec = false
  for line in content.splitLines():
    inc number
    if number == 1 and line.startsWith("discard \"\"\""):
      is_inside_spec = true
      continue
    if is_inside_spec:
      if line.startsWith("\"\"\""): is_inside_spec = false
      continue
    # A trailing newline splits into a final empty field, which is not a line anyone
    #   wrote; counting it would report a phantom complaint on every well-formed file.
    if number == countLines(content) + 1 and len(line) == 0: break
    let columns = runeLen(line)
    if columns > COLUMNS_MAX:
      result.add(Complaint(
        path: path, line: number, rule: "column limit",
        detail: &"{columns} characters, limit {COLUMNS_MAX}",
      ))
    if len(line) > 0 and line[^1] in {' ', '\t'}:
      result.add(Complaint(
        path: path, line: number, rule: "trailing whitespace", detail: "",
      ))
    if '\t' in line:
      result.add(Complaint(path: path, line: number, rule: "tab", detail: ""))



#[ Self-Test ]#

proc selfTest(): int =
  ## Check the checker against fixtures it writes itself, and report each case pass or fail.
  ## Answers with the number that failed, for `main` to exit on.
  ##   **The rule this exists for**: the column limit is measured in *characters*, and a
  ##   checker counting bytes lies about every line holding non-ASCII -- which this project's
  ##   sources are full of (`∧`, `☆`, `𝐦`, an em dash in every other comment). A checker
  ##   nobody checks is a checker that can quietly start passing everything, and this one
  ##   gates every commit.
  let directory = getTempDir() / "check_columns_self_test"
  createDir(directory)
  defer: removeDir(directory)
  var count_failed = 0

  proc expect(name, content: string; rules: seq[string]) =
    let path = directory / "fixture.nim"
    writeFile(path, content)
    var found: seq[string]
    for complaint in complaintsIn(path): found.add(complaint.rule)
    let is_passing = found == rules
    if not is_passing: inc count_failed
    echo (if is_passing: "  ok   " else: " FAIL  ") & name &
      &" -- reported {found}, wanted {rules}"

  expect(
    "a line of exactly the limit in non-ASCII characters passes",
    "# " & repeat("é", COLUMNS_MAX - 2) & "\n", @[],
  )
  expect(
    "one character past the limit is caught, non-ASCII or not",
    "# " & repeat("é", COLUMNS_MAX - 1) & "\n", @["column limit"],
  )
  expect("trailing whitespace is caught", "let x = 1 \n", @["trailing whitespace"])
  expect("a tab is caught", "let x =\t1\n", @["tab"])
  expect("a file not ending in a newline is caught", "let x = 1", @["final newline"])
  expect(
    "a testament spec is exempt, and only the spec",
    "discard \"\"\"\ncmd: \"" & repeat("x", COLUMNS_MAX) & "\"\n\"\"\"\nlet x = 1\n",
    @[],
  )
  count_failed



#[ Report ]#

proc main() =
  ## Check every source file and report, exiting non-zero on any complaint.
  ##   `--self-test` checks the checker against its own fixtures instead; see `selfTest`.
  if paramCount() >= 1 and paramStr(1) == "--self-test":
    let count_failed = selfTest()
    echo &"\n{count_failed} self-test(s) failed."
    quit(if count_failed > 0: 1 else: 0)
  let root = if paramCount() >= 1: paramStr(1) else: "."
  var
    complaints: seq[Complaint]
    count_files = 0
  for path in sourcesUnder(root):
    inc count_files
    complaints.add(complaintsIn(root / path))
  for complaint in complaints:
    let detail = if len(complaint.detail) > 0: &": {complaint.detail}" else: ""
    echo &"{complaint.path}:{complaint.line}  {complaint.rule}{detail}"
  echo &"\n{count_files} files checked, {len(complaints)} complaint(s)."
  if len(complaints) > 0: quit(1)


main()
