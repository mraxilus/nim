## Hold every comment in every authored file to `STYLE.md`'s article rule.
##
## Rule is stated for doc comments and was honoured nowhere else until this checked it:
## module headers, body comments, shell and JavaScript glue all drifted back to ordinary
## prose, and each cleanup was ordered by hand. Reads comments out of each language's own
## syntax, masks quoted text and code spans, and reports every remaining `the`, `a` or `an`.
##
## Prose files (`.md`, `.list`) are not read: rule governs comments in code, and
## `PROVENANCE.md` is written as prose on purpose.
##
## Build and run from project root:
##   bin/nim c --hints:off -o:bin/check_prose tools/check_prose.nim && bin/check_prose

import std/[options, os, strformat, strutils]

import ./check_columns



#[ Stated Rule ]#

const
  ARTICLES = ["the", "The", "a", "A", "an", "An"]
    ## Every spelling rule forbids. Case matters: `A` opening sentence is article, `A`
    ## naming category is caught by punctuation rule below.
  WORDS_AFTER_NAME = ["and", "or", "to", "vs"]
    ## Words after which bare `a` is operand name, not article: "vectors a and b".
  SYMBOLS_NAME = {'-', '+', '=', '<', '>', '/', '\\', '|', '&', '^', '%', '$', '#', '@',
    '!', '~'}
    ## Characters opening next token that make preceding `a` name: "a + b", "a -> b".
  EXTENSIONS_HASH = [".nim", ".nims", ".cfg", ".sh"]
    ## File kinds whose comment runs from `#` to end of line.
  EXTENSIONS_SLASH = [".js", ".mjs", ".html", ".css", ".cpp", ".h"]
    ## File kinds with `//`, `/* */` and `<!-- -->` comments.



#[ Findings ]#

type
  Language {.pure.} = enum ## Name comment syntax file is read with.
    Hash, ## `#` to end of line, outside strings.
    Slash, ## `//`, `/* */` and `<!-- -->`, outside strings.

  Complaint = object ## Hold one comment line carrying one article.
    path*: string ## Where, relative to project root.
    line*: int ## Which line, counting from one.
    article*: string ## Word found, as written.

  Reader = object ## Carry comment-syntax state across lines of one file.
    is_inside_triple: bool ## Within Nim `"""` string.
    is_inside_block: bool ## Within `/* */`.
    is_inside_html: bool ## Within `<!-- -->`.
    is_inside_template: bool ## Within JavaScript backtick literal.


func languageOf(path: string): Option[Language] =
  ## Name syntax file's extension implies, if rule reads that kind at all.
  let ext = splitFile(path).ext
  if ext in EXTENSIONS_HASH: some(Language.Hash)
  elif ext in EXTENSIONS_SLASH: some(Language.Slash)
  else: none(Language)



#[ Reading Comments ]#

func endOfQuoted(line: string; start: int; is_raw: bool): int =
  ## Report index just past double-quoted string opening at `start`, or line's end.
  var i = start + 1
  while i < len(line):
    if not is_raw and line[i] == '\\': i += 2; continue
    if line[i] == '"':
      if is_raw and i + 1 < len(line) and line[i + 1] == '"': i += 2; continue
      return i + 1
    inc i
  len(line)


func endOfSingleQuoted(line: string; start: int): Option[int] =
  ## Report index just past single-quoted span opening at `start`, if one closes on
  ## this line. Apostrophes in prose never close, so they are not quotes.
  let close = line.find('\'', start + 1)
  if close < 0: none(int) else: some(close + 1)


func commentHash(reader: var Reader; line: string): string =
  ## Extract comment text from one line of `#`-commented source.
  var i = 0
  while i < len(line):
    if reader.is_inside_triple:
      let close = line.find("\"\"\"", i)
      if close < 0: return ""
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
    if c == '#': return line[i .. ^1]
    inc i
  ""


func commentSlash(reader: var Reader; line: string): string =
  ## Extract comment text from one line of `//`-commented source.
  var i = 0
  while i < len(line):
    if reader.is_inside_block or reader.is_inside_html:
      let closer = if reader.is_inside_block: "*/" else: "-->"
      let close = line.find(closer, i)
      if close < 0: return result & line[i .. ^1]
      result.add(line[i ..< close])
      reader.is_inside_block = false
      reader.is_inside_html = false
      i = close + len(closer)
      continue
    if reader.is_inside_template:
      let close = line.find('`', i)
      if close < 0: return result
      reader.is_inside_template = false
      i = close + 1
      continue
    let c = line[i]
    if line.continuesWith("//", i): return result & line[i .. ^1]
    if line.continuesWith("/*", i): reader.is_inside_block = true; i += 2; continue
    if line.continuesWith("<!--", i): reader.is_inside_html = true; i += 4; continue
    if c == '`': reader.is_inside_template = true; inc i; continue
    if c == '"': i = endOfQuoted(line, i, is_raw = false); continue
    if c == '\'':
      let close = endOfSingleQuoted(line, i)
      if close.isSome: i = close.get; continue
    inc i



#[ Finding Articles ]#

func masked(comment: string): string =
  ## Blank out code spans and quoted text, which are not prose: `` `a ∧ b` ``, paper
  ## titles, UI strings. Length is kept so nothing shifts.
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


proc complaintsIn(path: string): seq[Complaint] =
  ## Check one file, reporting each article on each comment line separately.
  let language = languageOf(path)
  if language.isNone: return
  var
    reader: Reader
    number = 0
  for line in readFile(path).splitLines():
    inc number
    let comment =
      if language.get == Language.Hash: reader.commentHash(line)
      else: reader.commentSlash(line)
    if len(comment) == 0: continue
    for article in articlesIn(comment):
      result.add(Complaint(path: path, line: number, article: article))



#[ Self-Test ]#

proc selfTest(): int =
  ## Check checker against fixtures it writes itself; answer with number that failed.
  let directory = getTempDir() / "check_prose_self_test"
  createDir(directory)
  defer: removeDir(directory)
  var count_failed = 0

  proc expect(name, ext, content: string; articles: seq[string]) =
    let path = directory / ("fixture" & ext)
    writeFile(path, content)
    var found: seq[string]
    for complaint in complaintsIn(path): found.add(complaint.article)
    let is_passing = found == articles
    if not is_passing: inc count_failed
    echo (if is_passing: "  ok   " else: " FAIL  ") & name &
      &" -- reported {found}, wanted {articles}"

  expect("an article in a body comment is caught", ".nim", "# Hold the frame.\n", @["the"])
  expect("a code span is not prose", ".nim", "# Hold `the frame`.\n", @[])
  expect("a string is not a comment", ".nim", "let a = \"the\" # b\n", @[])
  expect("an operand name is not an article", ".nim", "# Join a and b.\n", @[])
  expect("a quoted title is not prose", ".nim", "# \"A model for x\" is cited.\n", @[])
  expect("a sentence opener is caught in JS", ".js", "// A closed row builds nothing.\n",
    @["A"])
  expect("a block comment is read across lines, a string is not", ".js",
    "/* the\n frame */ f(\"the\")\n", @["the"])
  expect("a template literal hides its text", ".js", "const s = `\n the\n`; // an x\n",
    @["an"])
  expect("a testament spec is a string", ".nim", "discard \"\"\"\nthe cmd\n\"\"\"\n# ok\n",
    @[])
  expect("an apostrophe is not a quote", ".nim", "# reader's view of the frame\n", @["the"])
  count_failed



#[ Report ]#

proc main() =
  ## Check every authored file and report, exiting non-zero on any article.
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
    echo &"{complaint.path}:{complaint.line}  article: {complaint.article}"
  echo &"\n{count_files} files checked, {len(complaints)} article(s)."
  if len(complaints) > 0: quit(1)


main()
