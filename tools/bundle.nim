## Assemble the browser build into one self-contained HTML file.
##
## Shell, embedded faces, compiled core and glue, concatenated. The result works with no
## network access: every face is a base64 data URI, and there is no external script or
## stylesheet. Nothing here derives a domain value; it is a file-concatenation step.

import std/[base64, os, strutils]



#[ Faces ]#

type Face = object
  ## Name one embedded face and the codepoint ranges it is declared for.
  family: string
  path: string
  ranges: string
  weight: string

const FACES = [
  ## Embed the vendored faces every render target ships, so a named face never falls back.
  ##   Vendored rather than read from the system: a face installed on the build machine is a
  ##   face a viewer may not have, and both targets must draw the same glyphs. The math and
  ##   symbol faces are declared **under the sans family name**, restricted to the codepoints
  ##   they carry, and the mono stack names the sans family after its own: CSS falls back per
  ##   character, so a bold operand or a wedge inside monospace text finds them without the
  ##   mono face carrying either.
  ##   Used only where `tools/subset_faces.py` has not run; the subsets are a fiftieth the size.
  Face(
    family: "Noto Sans",
    path: "vendor/fonts/noto-sans-latin-400-normal.woff2",
    ranges: "",
    weight: "400",
  ),
  Face(
    family: "Noto Sans",
    path: "vendor/fonts/noto-sans-latin-600-normal.woff2",
    ranges: "",
    weight: "600",
  ),
  Face(
    family: "Noto Sans",
    path: "vendor/fonts/noto-sans-math-math-400-normal.woff2",
    ranges: "U+2200-22FF, U+27C0-27EF, U+2A00-2AFF, U+1D400-1D7FF",
    weight: "400",
  ),
  Face(
    family: "Noto Sans",
    path: "vendor/fonts/noto-sans-symbols-2-symbols-400-normal.woff2",
    ranges: "U+2190-21FF, U+2500-259F, U+25A0-25FF, U+2600-27BF",
    weight: "400",
  ),
  Face(
    family: "Commit Mono",
    path: "vendor/fonts/commit-mono-latin-400-normal.woff2",
    ranges: "",
    weight: "400",
  ),
]


proc faceDeclaration(face: Face): string =
  ## Write one `@font-face` rule with the face embedded as a data URI.
  if not fileExists(face.path):
    stderr.writeLine("bundle: missing face " & face.path & "; the page will fall back.")
    return ""
  let
    encoded = encode(readFile(face.path))
    format = if face.path.endsWith(".woff2"): "woff2" else: "truetype"
  result = "@font-face{font-family:\"" & face.family & "\";font-style:normal;font-weight:" &
    face.weight & ";src:url(data:font/" & format & ";base64," & encoded & ") format(\"" &
    format & "\");"
  if face.ranges.len > 0:
    result &= "unicode-range:" & face.ranges & ";"
  result &= "}\n"


proc subsetFaces(root: string): seq[Face] =
  ## Read the subsetter's manifest, where a subsetting run has left one.
  ##   Each line names a family, a file, a weight and the ranges that file was measured to
  ##   carry, so the declarations below state coverage rather than assume it.
  let manifest = root / "build" / "faces" / "manifest.list"
  if not fileExists(manifest): return
  for line in readFile(manifest).splitLines():
    if line.len == 0: continue
    let fields = line.split('|')
    if fields.len != 4: continue
    result.add(Face(
      family: fields[0],
      path: (if fields[1].isAbsolute: fields[1] else: root / fields[1]),
      weight: fields[2],
      ranges: fields[3],
    ))



#[ Assembly ]#

when isMainModule:
  let
    root = currentSourcePath().parentDir.parentDir
    shell = readFile(root / "src" / "browser" / "shell.html")
    glue = readFile(root / "src" / "browser" / "glue.js")
    core_path =
      if paramCount() >= 1: paramStr(1) else: root / "build" / "core.js"
    output_path =
      if paramCount() >= 2: paramStr(2) else: root / "build" / "index.html"
    core = readFile(core_path)

  # Prefer subset faces where the build made them: the full faces are ~2.8 MB of payload for
  #   the hundred-odd glyphs this UI writes, and the subsets are measured at a fiftieth of it.
  var
    chosen = subsetFaces(root)
    faces = ""
  if chosen.len == 0:
    stderr.writeLine("bundle: no subset manifest; embedding whole faces.")
    for face in FACES:
      chosen.add(Face(
        family: face.family,
        path: root / face.path,
        ranges: face.ranges,
        weight: face.weight,
      ))
  for face in chosen:
    faces &= face.faceDeclaration

  var page = shell.replace("/* FONT_FACES */", faces)
  page = page.replace(
    "</body>",
    "<script>\n" & core & "\n</script>\n<script>\n" & glue & "\n</script>\n</body>",
  )
  createDir(output_path.parentDir)
  writeFile(output_path, page)
  echo "bundled ", output_path, " (", page.len div 1024, " KB)"

  # Write the same page again without its document wrapper, for a host that supplies one.
  #   An artifact host wraps what it is given in its own doctype, head and body, so a second
  #   copy of those tags would nest a document inside a document. Everything else — the faces,
  #   the compiled core, the glue — is byte for byte the page above.
  let
    style_start = page.find("<style>")
    style_end = page.find("</style>") + "</style>".len
    body_start = page.find("<body>") + "<body>".len
    body_end = page.find("</body>")
  if style_start < 0 or body_end < 0:
    stderr.writeLine("bundle: the shell no longer has the shape the artifact copy expects.")
    quit(1)
  let embedded =
    page[style_start ..< style_end] & "\n" & page[body_start ..< body_end]
  writeFile(output_path.parentDir / "artifact.html", embedded)
  echo "bundled ", output_path.parentDir / "artifact.html",
    " (", embedded.len div 1024, " KB, no document wrapper)"
