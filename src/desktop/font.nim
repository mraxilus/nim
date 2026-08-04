## Build one glyph atlas out of several faces, merged by codepoint, in two families.
##
## **No single face covers what this UI writes**, so each family is merged by codepoint: a text
## face for Latin, punctuation, subscripts and spacing modifiers; a math face for the operators
## and the bold operands; a symbols face for the dual stars and the abandon cross. Each
## codepoint is rasterised from the first face that actually carries it, which is a measurement
## — `stb_truetype` reports glyph index zero for a codepoint a face lacks — rather than a range
## table that can drift from the file.
##
## Two families, because the style guide names two: **Noto Sans for UI text and Commit Mono for
## code, data and figures**. Both are vendored — a named face installed on the machine is a
## face the other target may not have, and the two must draw the same glyphs.
##
## Every glyph the tool writes is rasterised at startup into one texture and never again; the
## frame loop reads metrics out of fixed storage and allocates nothing.

{.experimental: "strictFuncs".}

import std/[os, tables, unicode]

import ../core/palette



#[ Rasteriser ]#

{.compile: "stb_truetype_impl.c".}

type FontInfo {.importc: "stbtt_fontinfo", header: "stb_truetype.h", bycopy.} = object
  ## Hold one parsed face, as the rasteriser sees it.

proc stbtt_InitFont(
  info: ptr FontInfo, data: ptr uint8, offset: cint
): cint {.importc, header: "stb_truetype.h".}
proc stbtt_ScaleForPixelHeight(
  info: ptr FontInfo, pixels: cfloat
): cfloat {.importc, header: "stb_truetype.h".}
proc stbtt_FindGlyphIndex(
  info: ptr FontInfo, codepoint: cint
): cint {.importc, header: "stb_truetype.h".}
proc stbtt_GetCodepointHMetrics(
  info: ptr FontInfo, codepoint: cint, advance, bearing: ptr cint
) {.importc, header: "stb_truetype.h".}
proc stbtt_GetFontVMetrics(
  info: ptr FontInfo, ascent, descent, gap: ptr cint
) {.importc, header: "stb_truetype.h".}
proc stbtt_GetCodepointBitmapBox(
  info: ptr FontInfo, codepoint: cint, scale_x, scale_y: cfloat,
  x0, y0, x1, y1: ptr cint
) {.importc, header: "stb_truetype.h".}
proc stbtt_MakeCodepointBitmap(
  info: ptr FontInfo, output: ptr uint8, width, height, stride: cint,
  scale_x, scale_y: cfloat, codepoint: cint
) {.importc, header: "stb_truetype.h".}



#[ Constants ]#

const
  ATLAS_SIZE* = 1024
    ## Size the glyph atlas, square, in pixels.
  TEXT_SIZE* = 16.0
    ## Draw UI text at this pixel height.
  FONT_DIRECTORY* {.strdefine: "rga.font_directory".} = "vendor/fonts"
    ## Read vendored faces from here, relative to the working directory or absolute.



#[ Type Definitions ]#

type
  Family* {.pure.} = enum
    ## Name the two families the style guide asks for.
    Text, ## Noto Sans: every label, name and word.
    Mono, ## Commit Mono: code, data and figures — coefficients, camera fields, readings.

  Glyph* = object
    ## Hold one glyph's place in the atlas and its metrics.
    u0*, v0*, u1*, v1*: float  ## Texture coordinates.
    width*, height*: float     ## Size in pixels.
    bearing_x*, bearing_y*: float
    advance*: float

  Atlas* = object
    ## Hold every glyph the tool writes, in both families, rasterised once.
    pixels*: array[ATLAS_SIZE*ATLAS_SIZE, uint8]
    glyphs*: array[Family, Table[int, Glyph]]
    line_height*: float
    ascent*: float
    solid_u*, solid_v*: float  ## Address a fully covered texel, for untextured quads.
    cursor_x, cursor_y, row_height: int



#[ Faces ]#

const LUT_FAMILY_TO_FACES*: array[Family, seq[string]] = [
  ## Name the faces each family merges, in the order a codepoint is looked for.
  ##   Sibling of the browser bundler's own list in `tools/bundle.nim`: a fix to one is not
  ##   finished until the other is checked. Both targets ship the faces they draw with, or the
  ##   two stop matching, which is the whole point of having the rule.
  Family.Text: @[
    "noto-sans-latin-400-normal.ttf",
    "noto-sans-math-math-400-normal.ttf",
    "noto-sans-symbols-2-symbols-400-normal.ttf",
  ],
  Family.Mono: @[
    "commit-mono-latin-400-normal.ttf",
    "noto-sans-math-math-400-normal.ttf",
    "noto-sans-symbols-2-symbols-400-normal.ttf",
  ],
]



#[ Atlas Construction ]#

proc place(atlas: var Atlas, width, height: int): (int, int) =
  ## Reserve a rectangle in the atlas, in rows.
  if atlas.cursor_x + width + 1 >= ATLAS_SIZE:
    atlas.cursor_x = 0
    atlas.cursor_y += atlas.row_height + 1
    atlas.row_height = 0
  let position = (atlas.cursor_x, atlas.cursor_y)
  atlas.cursor_x += width + 1
  if height > atlas.row_height: atlas.row_height = height
  position


proc rasterise(
  atlas: var Atlas, family: Family, faces: openArray[string], codepoints: openArray[int]
) =
  ## Rasterise one family's glyphs into the shared texture.
  ##   Exceeds the usual function length because it holds the whole per-glyph sequence —
  ##   choose a face, measure, place, rasterise, record — and splitting it would only move
  ##   the rasteriser's five out-parameters across a boundary.
  var
    loaded: seq[string]
    infos: seq[FontInfo]
  for name in faces:
    let path = FONT_DIRECTORY / name
    if not fileExists(path):
      stderr.writeLine("font: missing vendored face " & path & "; run tools/fetch_vendor.sh")
      continue
    loaded.add(readFile(path))
  if loaded.len == 0: return
  infos.setLen(loaded.len)
  for index in 0 ..< loaded.len:
    discard stbtt_InitFont(addr infos[index], cast[ptr uint8](loaded[index][0].addr), 0)

  if family == Family.Text:
    var ascent, descent, gap: cint
    let scale = stbtt_ScaleForPixelHeight(addr infos[0], TEXT_SIZE.cfloat)
    stbtt_GetFontVMetrics(addr infos[0], addr ascent, addr descent, addr gap)
    atlas.ascent = ascent.float*scale
    atlas.line_height = (ascent - descent + gap).float*scale

  for codepoint in codepoints:
    # Ask each face in turn whether it carries this codepoint, rather than trusting a range.
    var chosen = -1
    for index in 0 ..< infos.len:
      if stbtt_FindGlyphIndex(addr infos[index], codepoint.cint) != 0:
        chosen = index
        break
    if chosen < 0: continue

    let face_scale = stbtt_ScaleForPixelHeight(addr infos[chosen], TEXT_SIZE.cfloat)
    var advance, bearing: cint
    stbtt_GetCodepointHMetrics(addr infos[chosen], codepoint.cint, addr advance, addr bearing)
    var x0, y0, x1, y1: cint
    stbtt_GetCodepointBitmapBox(
      addr infos[chosen], codepoint.cint, face_scale, face_scale,
      addr x0, addr y0, addr x1, addr y1,
    )
    let
      width = int(x1 - x0)
      height = int(y1 - y0)
    var glyph = Glyph(
      width: width.float,
      height: height.float,
      bearing_x: x0.float,
      bearing_y: y0.float,
      advance: advance.float*face_scale,
    )
    if width > 0 and height > 0:
      let (x, y) = atlas.place(width, height)
      stbtt_MakeCodepointBitmap(
        addr infos[chosen],
        addr atlas.pixels[y*ATLAS_SIZE + x],
        width.cint, height.cint, ATLAS_SIZE.cint,
        face_scale, face_scale, codepoint.cint,
      )
      glyph.u0 = x.float/ATLAS_SIZE.float
      glyph.v0 = y.float/ATLAS_SIZE.float
      glyph.u1 = (x + width).float/ATLAS_SIZE.float
      glyph.v1 = (y + height).float/ATLAS_SIZE.float
    atlas.glyphs[family][codepoint] = glyph


proc initAtlas*(codepoints: openArray[int]): Atlas =
  ## Rasterise every codepoint the tool writes, in both families, into one texture.
  # Reserve a fully covered block first, so a quad that carries no glyph can sample coverage
  #   of one rather than whatever happens to sit at the atlas origin. Without it every panel
  #   surface draws at the coverage of the first rasterised glyph's corner texel.
  let (solid_x, solid_y) = result.place(4, 4)
  for row in 0 ..< 4:
    for column in 0 ..< 4:
      result.pixels[(solid_y + row)*ATLAS_SIZE + solid_x + column] = 255
  result.solid_u = (solid_x.float + 2.0)/ATLAS_SIZE.float
  result.solid_v = (solid_y.float + 2.0)/ATLAS_SIZE.float

  for family in Family:
    result.rasterise(family, LUT_FAMILY_TO_FACES[family], codepoints)



#[ Atlas Queries ]#

func has*(atlas: Atlas, family: Family, codepoint: int): bool {.inline.} =
  ## Report whether a codepoint was rasterised, which is what a coverage check reads.
  atlas.glyphs[family].hasKey(codepoint)


proc width*(atlas: Atlas, text: string, family = Family.Text): float =
  ## Measure text, so a caller can place it before drawing it.
  for rune in text.runes:
    let codepoint = int(rune)
    if atlas.glyphs[family].hasKey(codepoint):
      result += atlas.glyphs[family][codepoint].advance


func textColor*(is_faint: bool): Color =
  ## Choose the ink a control draws in: a name recedes, a value reads.
  if is_faint: Color(r: 0.545, g: 0.588, b: 0.639, a: 1.0)
  else: Color(r: 0.906, g: 0.925, b: 0.945, a: 1.0)
