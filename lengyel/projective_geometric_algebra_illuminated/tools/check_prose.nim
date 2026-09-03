## Hold every comment in every authored file to Art. VI of `CONSTITUTION.md`.
##
## Checks three rules, each of which was stated and then drifted until tool held it:
##   Article rule (VI.5): no `the`, `a` or `an` in prose.
##   Summary form (VI.1): lead line of doc comment opens with verb and ends in period.
##   Stage form (VI.4): lead line of stage comment ends in period, colon or question mark.
## Reads comments out of each language's own syntax, masks quoted text and code spans.
##
## Verb list is vocabulary decision, not lexicon: opener absent from it fails, and adding
## one is deliberate edit here. Trailing docs (`field: T ## ...`) take declarative fragment
## and are held to period only.
##
## Prose files (`.md`, `.list`) are not read: rule governs comments in code, and
## `PROVENANCE.md` is written as prose on purpose.
##
## Build and run from project root:
##   bin/nim c --hints:off -o:bin/check_prose tools/check_prose.nim && bin/check_prose

{.experimental: "strictFuncs".}

import std/[options, os, strformat, strutils]

import ./check_columns



#[ Stated Rules ]#

const
  ARTICLES = ["the", "The", "a", "A", "an", "An"]
    ## Forbid every spelling here.
    ##   Case matters: `A` opening sentence is article, `A` naming category is caught by
    ##   punctuation rule below.
  WORDS_AFTER_NAME = ["and", "or", "to", "vs"]
    ## Treat bare `a` after these words as operand name, not article: "vectors a and b".
  SYMBOLS_NAME = {'-', '+', '=', '<', '>', '/', '\\', '|', '&', '^', '%', '$', '#', '@',
    '!', '~'}
    ## Treat `a` before token opening with these as name: "a + b", "a -> b".
  ENDINGS_SUMMARY = {'.', ':'}
    ## Allow summary line to end in these: period, or colon introducing table or list.
  ENDINGS_STAGE = {'.', ':', '?'}
    ## Allow stage comment's lead line to end in these.
  VERBS = [
    "Abandon", "Accept", "Accumulate", "Add", "Advance", "Aim", "Alias", "Align", "Allocate",
    "Allow", "Animate", "Answer", "Append", "Apply", "Ask", "Assemble", "Assert", "Assign",
    "Attach", "Audit", "Begin", "Bind", "Blank", "Blend", "Bound", "Bridge", "Bring", "Build",
    "Cache", "Capture", "Carry", "Carve", "Charge", "Check", "Choose", "Clamp", "Clear", "Clip",
    "Close", "Collect", "Colour", "Commit", "Compare", "Compile", "Compose", "Compress",
    "Compute", "Configure", "Construct", "Continue", "Convert", "Copy", "Count", "Create",
    "Cross", "Cull", "Cut", "Decide", "Decode", "Define", "Deflate", "Delete", "Derive",
    "Describe", "Detect", "Determine", "Dim", "Disable", "Discard", "Dispatch", "Dolly", "Drag",
    "Draw", "Drive", "Drop", "Ease", "Echo", "Emit", "Empty", "Enable", "Encode", "End",
    "Enumerate", "Exempt", "Expand", "Expect", "Explain", "Export", "Expose", "Extract", "Fade",
    "Fill", "Filter", "Find", "Finish", "Fit", "Fix", "Flatten", "Fold", "Forbid", "Format",
    "Forward", "Frame", "Gate", "Generate", "Get", "Group", "Grow", "Guard", "Hand", "Handle",
    "Hash", "Hide", "Highlight", "Hold", "Import", "Initialize", "Insert", "Interleave",
    "Interpolate", "Invalidate", "Invert", "Join", "Judge", "Keep", "Label", "Lay", "Leave",
    "Let", "Lift", "Light", "Limit", "Link", "List", "Load", "Look", "Make", "Map", "Mark",
    "Match", "Measure", "Meet", "Merge", "Mirror", "Move", "Multiply", "Name", "Negate",
    "Normalize", "Note", "Offer", "Offset", "Open", "Orbit", "Order", "Own", "Pack", "Pad",
    "Pan", "Parse", "Perform", "Pick", "Pin", "Place", "Point", "Poison", "Pop", "Populate",
    "Prepare", "Present", "Print", "Probe", "Project", "Pulse", "Push", "Put", "Quantize",
    "Rank", "Reach", "Read", "Rebuild", "Reclaim", "Recompute", "Record", "Recover", "Reduce",
    "Refill", "Refresh", "Register", "Reject", "Release", "Remember", "Remove", "Render",
    "Replace", "Replay", "Report", "Request", "Require", "Reserve", "Reset", "Resolve",
    "Restore", "Retire", "Return", "Reveal", "Reverse", "Rewrite", "Rotate", "Round", "Run",
    "Sample", "Save", "Say", "Scale", "Schedule", "Script", "Seal", "Seed", "Select", "Send",
    "Separate", "Set", "Shape", "Shift", "Show", "Shrink", "Shut", "Sift", "Sign", "Simulate",
    "Size", "Skip", "Slide", "Snap", "Solve", "Sort", "Space", "Split", "Spread", "Stage",
    "Stamp", "Start", "State", "Step", "Stop", "Store", "Strip", "Stroke", "Stub", "Subtract",
    "Sum", "Swap", "Sweep", "Sync", "Take", "Tally", "Tear", "Tell", "Tessellate", "Test",
    "Tint", "Toggle", "Trace", "Track", "Translate", "Treat", "Trim", "Turn", "Undo", "Unpack",
    "Update", "Upload", "Validate", "Verify", "Visualise", "Wait", "Walk", "Wedge", "Widen",
    "Wire", "Withdraw", "Wrap", "Write", "Yield", "Zero", "Zoom",
  ] ## Allow doc summary to open with any of these verbs.
    ##   Imperative, capitalised, alphabetical.
  WORDS_SUMMARY_EXEMPT = ["TODO:"]
    ## Exempt these openers from verb rule: `## TODO: Document.` is honest placeholder (VI.1).
  EXTENSIONS_HASH = [".nim", ".nims", ".cfg", ".sh"]
    ## Name file kinds whose comment runs from `#` to end of line.
  EXTENSIONS_SLASH = [".js", ".mjs", ".html", ".css", ".cpp", ".h"]
    ## Name file kinds with `//`, `/* */` and `<!-- -->` comments.



#[ Findings ]#

type
  Language {.pure.} = enum ## Define comment syntax file is read with.
    Hash, ## `#` to end of line, outside strings.
    Slash, ## `//`, `/* */` and `<!-- -->`, outside strings.

  Complaint = object ## Define one comment line breaking one rule.
    path*: string ## Where, relative to project root.
    line*: int ## Which line, counting from one.
    rule*: string ## Which rule, as this module's header names it.
    detail*: string ## What was found, so complaint is actionable.

  Comment = object ## Define one line's comment text with what precedes it.
    text: string ## Comment including its marker.
    is_trailing: bool ## Code stands before marker on same line.
    is_lead: bool ## First line of its block: previous line carried no comment.

  Reader = object ## Define comment-syntax state carried across lines of one file.
    is_inside_triple: bool ## Within Nim `"""` string.
    is_inside_block: bool ## Within `/* */`.
    is_inside_html: bool ## Within `<!-- -->`.
    is_inside_template: bool ## Within JavaScript backtick literal.
    has_comment_before: bool ## Previous line carried comment text.


func languageOf(path: string): Option[Language] =
  ## Name syntax file's extension implies, if rule reads that kind at all.
  let ext = splitFile(path).ext
  if ext in EXTENSIONS_HASH: some(Language.Hash)
  elif ext in EXTENSIONS_SLASH: some(Language.Slash)
  else: none(Language)



#[ Reading Comments ]#

func endOfQuoted(line: string, start: int, is_raw: bool): int =
  ## Report index just past double-quoted string opening at `start`, or line's end.
  var i = start + 1
  while i < len(line):
    if not is_raw and line[i] == '\\': i += 2; continue
    if line[i] == '"':
      if is_raw and i + 1 < len(line) and line[i + 1] == '"': i += 2; continue
      return i + 1
    inc i
  len(line)


func endOfSingleQuoted(line: string, start: int): Option[int] =
  ## Report index just past single-quoted span opening at `start`, if one closes here.
  ##   Apostrophes in prose never close, so they are not quotes.
  let close = line.find('\'', start + 1)
  if close < 0: none(int) else: some(close + 1)


func commentHash(reader: var Reader, line: string): Comment =
  ## Extract comment from one line of `#`-commented source.
  var i = 0
  while i < len(line):
    if reader.is_inside_triple:
      let close = line.find("\"\"\"", i)
      if close < 0: return
      reader.is_inside_triple = false
      i = close + 3
      continue
    let c = line[i]
    if line.continuesWith("\"\"\"", i):
      reader.is_inside_triple = true
      i += 3
      continue
    if c == '"':
      let is_raw = i > 0 and line[i - 1].isAlphaAscii
      i = endOfQuoted(line, i, is_raw)
      continue
    if c == '\'':
      let close = endOfSingleQuoted(line, i)
      if close.isSome: i = close.get; continue
    if c == '#':
      return Comment(text: line[i .. ^1], is_trailing: len(line[0 ..< i].strip()) > 0)
    inc i


func commentSlash(reader: var Reader, line: string): Comment =
  ## Extract comment from one line of `//`-commented source.
  var i = 0
  while i < len(line):
    if reader.is_inside_block or reader.is_inside_html:
      let closer = if reader.is_inside_block: "*/" else: "-->"
      let close = line.find(closer, i)
      if close < 0: result.text.add(line[i .. ^1]); return
      result.text.add(line[i ..< close])
      reader.is_inside_block = false
      reader.is_inside_html = false
      i = close + len(closer)
      continue
    if reader.is_inside_template:
      let close = line.find('`', i)
      if close < 0: return
      reader.is_inside_template = false
      i = close + 1
      continue
    let c = line[i]
    let is_trailing = len(line[0 ..< i].strip()) > 0
    if line.continuesWith("//", i):
      result.text.add(line[i .. ^1]); result.is_trailing = is_trailing; return
    if line.continuesWith("/*", i):
      reader.is_inside_block = true
      result.is_trailing = is_trailing
      result.text.add("/*")
      i += 2
      continue
    if line.continuesWith("<!--", i):
      reader.is_inside_html = true
      result.is_trailing = is_trailing
      result.text.add("<!--")
      i += 4
      continue
    if c == '`': reader.is_inside_template = true; inc i; continue
    if c == '"': i = endOfQuoted(line, i, is_raw = false); continue
    if c == '\'':
      let close = endOfSingleQuoted(line, i)
      if close.isSome: i = close.get; continue
    inc i



#[ Finding Articles ]#

func masked(comment: string): string =
  ## Blank out code spans and quoted text, which are not prose.
  ##   `` `a ∧ b` ``, paper titles, UI strings; length is kept so nothing shifts.
  result = comment
  var i = 0
  while i < len(result):
    let c = result[i]
    if c notin {'`', '"', '\''}: inc i; continue
    # Apostrophe is quote only when it opens word: "reader's" keeps its text.
    if c == '\'' and i > 0 and result[i - 1].isAlphaNumeric: inc i; continue
    let close = result.find(c, i + 1)
    if close < 0: inc i; continue
    if c == '\'' and close + 1 < len(result) and result[close + 1].isAlphaNumeric:
      inc i
      continue
    for k in i .. close: result[k] = ' '
    i = close + 1


func isName(word, next: string): bool =
  ## Report whether bare `a` here names operand rather than opening noun phrase.
  if word notin ["a", "A"]: return false
  if len(next) == 0: return true
  if next[0] in SYMBOLS_NAME: return true
  let following = next.strip(chars = {',', '.', ';', ':', ')', ']'})
  if following in WORDS_AFTER_NAME: return true
  len(following) == 1


func articlesIn(comment: string): seq[string] =
  ## Report every article in one comment's prose, as written.
  let words = masked(comment).splitWhitespace()
  for index, raw in words:
    let word = raw.strip(leading = true, trailing = false, chars = {'(', '[', '*', '_'})
    if word notin ARTICLES: continue
    let next = if index + 1 < len(words): words[index + 1] else: ""
    if isName(word, next): continue
    if len(next) > 0 and next[0] in SYMBOLS_NAME: continue
    result.add(word)



#[ Finding Form ]#

func prose(comment: string): string =
  ## Strip comment marker and surrounding space, leaving what reader reads.
  var text = comment.strip()
  for marker in ["##", "//", "#", "/*", "<!--"]:
    if text.startsWith(marker):
      text = text[len(marker) .. ^1]
      break
  for closer in ["*/", "-->"]:
    if text.endsWith(closer): text = text[0 ..< ^len(closer)]
  text.strip()


func isProse(text: string): bool =
  ## Report whether comment line is sentence rather than table, rule, fence or directive.
  if len(text) == 0: return false
  if text[0] in {'|', '-', '=', '`', '*', '+'}: return false
  if text.startsWith("shellcheck") or text.startsWith("!"): return false
  true


func opener(text: string): string =
  ## Report first word of summary, bare of markup.
  let words = text.splitWhitespace()
  if len(words) == 0: return ""
  words[0].strip(chars = {'`', '*', '_', '(', '"'})


func formOfDoc(comment: Comment): Option[Complaint] =
  ## Check lead line of doc comment: ends in period, opens with verb unless trailing.
  let text = prose(comment.text)
  if not isProse(text): return
  if text[^1] notin ENDINGS_SUMMARY:
    return some(Complaint(rule: "summary form", detail: "does not end in period"))
  if comment.is_trailing: return
  let word = opener(text)
  if word in VERBS or word in WORDS_SUMMARY_EXEMPT: return
  some(Complaint(rule: "summary form", detail: &"opens with `{word}`, not verb in list"))


func formOfStage(comment: Comment): Option[Complaint] =
  ## Check lead line of stage comment: ends in period, colon or question mark.
  ##   Block comment still open at line's end is judged by its closing line, not here.
  let stripped = comment.text.strip()
  if stripped.startsWith("/*") and "*/" notin stripped: return
  if stripped.startsWith("<!--") and "-->" notin stripped: return
  let text = prose(comment.text)
  if not isProse(text): return
  if comment.is_trailing: return
  if text[^1] in ENDINGS_STAGE: return
  some(Complaint(rule: "stage form", detail: "does not end in period"))


func isBanner(text: string): bool =
  ## Report whether comment is section banner, which carries no sentence.
  let stripped = text.strip()
  stripped.startsWith("#[") or stripped.startsWith("/* ---") or stripped == "/*"


func formOf(comment: Comment, language: Language): Option[Complaint] =
  ## Check one lead comment line against form rule its kind carries.
  if not comment.is_lead or isBanner(comment.text): return
  let stripped = comment.text.strip()
  # Continuation of outline is indented under its lead and carries no sentence rule.
  if stripped.startsWith("#   ") or stripped.startsWith("//   "): return
  if stripped.startsWith("##"): return formOfDoc(comment)
  if language == Language.Hash and stripped.startsWith("# TODO"): return formOfStage(comment)
  formOfStage(comment)



#[ Checking Files ]#

proc complaintsIn(path: string): seq[Complaint] =
  ## Check one file, reporting each break on each comment line separately.
  let language = languageOf(path)
  if language.isNone: return
  var
    reader: Reader
    number = 0
  for line in readFile(path).splitLines():
    inc number
    var comment =
      if language.get == Language.Hash: reader.commentHash(line)
      else: reader.commentSlash(line)
    let has_text = len(comment.text.strip()) > 0
    comment.is_lead = has_text and not reader.has_comment_before
    reader.has_comment_before = has_text
    if not has_text: continue
    for article in articlesIn(comment.text):
      result.add(Complaint(path: path, line: number, rule: "article", detail: article))
    let form = formOf(comment, language.get)
    if form.isSome:
      var complaint = form.get
      complaint.path = path
      complaint.line = number
      result.add(complaint)



#[ Self-Test ]#

proc selfTest(): int =
  ## Check checker against fixtures it writes itself; answer with number that failed.
  let directory = getTempDir() / "check_prose_self_test"
  createDir(directory)
  defer: removeDir(directory)
  var count_failed = 0

  proc expect(name, ext, content: string; details: seq[string]) =
    let path = directory / ("fixture" & ext)
    writeFile(path, content)
    var found: seq[string]
    for complaint in complaintsIn(path): found.add(complaint.detail)
    let is_passing = found == details
    if not is_passing: inc count_failed
    echo (if is_passing: "  ok   " else: " FAIL  ") & name &
      &" -- reported {found}, wanted {details}"

  expect("article in body comment is caught", ".nim", "# Hold the frame.\n", @["the"])
  expect("code span is not prose", ".nim", "# Hold `the frame`.\n", @[])
  expect("string is not comment", ".nim", "let a = \"the\" # Bind.\n", @[])
  expect("operand name is not article", ".nim", "# Join a and b.\n", @[])
  expect("quoted title is not prose", ".nim", "# Cite \"A model for x\".\n", @[])
  expect("sentence opener is caught in JS", ".js", "// A closed row builds nothing.\n",
    @["A"])
  expect("block comment reads across lines, string does not", ".js",
    "/* Hold the\n frame. */ f(\"the\")\n", @["the"])
  expect("template literal hides its text", ".js", "const s = `\n the\n`; // Hold an x.\n",
    @["an"])
  expect("testament spec is string", ".nim", "discard \"\"\"\nthe cmd\n\"\"\"\n# Run.\n",
    @[])
  expect("apostrophe is not quote", ".nim", "# Hold reader's view of the frame.\n",
    @["the"])
  expect("summary without period is caught", ".nim", "## Hold frame\n", @[
    "does not end in period"])
  expect("summary opening with noun is caught", ".nim", "## Sibling copy of x.\n", @[
    "opens with `Sibling`, not verb in list"])
  expect("trailing doc takes fragment", ".nim", "  x*: int ## Where it begins.\n", @[])
  expect("placeholder is honest", ".nim", "## TODO: Document.\n", @[])
  expect("continuation is not lead", ".nim", "## Hold frame.\n##   Detail without stop\n",
    @[])
  expect("stage lead without period is caught", ".nim", "# Construct antiscalar\n", @[
    "does not end in period"])
  expect("stage lead may end in colon", ".nim", "# Two cases:\n#   first, second\n", @[])
  expect("banner carries no sentence", ".nim", "#[ Basis Conversion ]#\n", @[])
  expect("JS lead without period is caught", ".js", "// alias for x\nlet a = 1;\n", @[
    "does not end in period"])
  count_failed



#[ Report ]#

proc main() =
  ## Check every authored file and report, exiting non-zero on any complaint.
  ##   `--self-test` checks checker against its own fixtures instead; see `selfTest`.
  if paramCount() >= 1 and paramStr(1) == "--self-test":
    let count_failed = selfTest()
    echo &"\n{count_failed} self-test(s) failed."
    quit(if count_failed > 0: 1 else: 0)
  let root = if paramCount() >= 1: paramStr(1) else: "."
  var
    complaints: seq[Complaint]
    count_files = 0
  for path in sourcesUnder(root):
    if languageOf(path).isNone: continue
    inc count_files
    complaints.add(complaintsIn(root / path))
  for complaint in complaints:
    echo &"{complaint.path}:{complaint.line}  {complaint.rule}: {complaint.detail}"
  echo &"\n{count_files} files checked, {len(complaints)} complaint(s)."
  if len(complaints) > 0: quit(1)


main()
