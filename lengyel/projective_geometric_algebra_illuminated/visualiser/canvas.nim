## Draw image-space primitives into SVG document.
##
## Canvas keeps no scene buffer: each primitive is written to file at moment it is drawn.
##   Paint order is therefore draw order, and nothing is sorted by depth.
##   Cost is that near object drawn early is overpainted by far object drawn late.
##   SVG chosen over pixel buffer so prototype needs no windowing or image codec.
##
## Two image-space types exist so projection cannot be mistaken for pixel:
##   `PointImage` is normalised device coordinates, y upward, vertical extent -1 .. 1.
##   `PointCanvas` is pixels, y downward, as SVG measures from document's top-left corner.
##   Vertical extent covers whole canvas height, so `toCanvas` preserves aspect ratio.
##   Horizontal overflow is left to `<svg>`, which clips to its viewport by default.
##
##   |--------------|-------------------------|
##   | Identifier   | SVG                     |
##   |--------------|-------------------------|
##   | Canvas       | <svg> document          |
##   | Ink          | stroke and fill colour  |
##   | drawPolyline | <polyline>              |
##   | drawPolygon  | <polygon>               |
##   | drawMarker   | <circle>                |
##   | drawText     | <text>                  |
##   |--------------|-------------------------|

{.experimental: "strictFuncs".}

import std/[strformat, syncio]



#[ Canvas Configuration ]#

# Allow caller to resize output without editing source.
#   E.g. `--define:visualiser.pixels_width=1920 --define:visualiser.pixels_height=1080`.
const
  PIXELS_WIDTH* {.define: "visualiser.pixels_width".} = 1280
  PIXELS_HEIGHT* {.define: "visualiser.pixels_height".} = 800

# Reject sizes too small for legend to occupy, rather than emit unreadable document.
static:
  doAssert PIXELS_WIDTH >= 320 and PIXELS_HEIGHT >= 240,
    &"Canvas must be at least 320x240 pixels; got `{PIXELS_WIDTH}x{PIXELS_HEIGHT}`."

const
  FONTS_LABEL* = "Helvetica, Arial, sans-serif"
    ## Name font stack for object labels.
  FONTS_LEGEND* = "DejaVu Sans Mono, Menlo, Consolas, monospace"
    ## Name font stack for legend, whose multivectors need wide unicode coverage.



#[ Type Definitions ]#

type
  Ink* {.pure.} = enum ## Name palette slot, so every colour in output lives in one table.
    ## Structural slots, spent by canvas and renderer on furniture of drawing itself.
    Backdrop, ## Page behind everything.
    Axis, ## World axes through origin.
    Guide, ## Construction helper, e.g. plane normal.
    Label, ## Text naming object.
    ## Categorical slots, spent by caller on telling one object from another.
    ##   Named by hue rather than by role, as caller alone knows what objects mean.
    ##   Grade is already legible from shape drawn, so colour is free to carry identity.
    Amber, Coral, Cyan, Violet, Lime, Teal, Rose,

  Rgb = object ## Hold 8-bit colour channels of palette entry.
    red, green, blue: uint8

  PointImage* = object ## Hold position on image plane, in normalised device coordinates.
    x*, y*: float

  PointCanvas* = object ## Hold position on canvas, in pixels, measured from top-left.
    x*, y*: float

  Canvas* = object ## Hold SVG document currently being streamed to.
    file: File


# Forbid exact comparison, as both coordinates are accumulated floats.
func `==`*(p, q: PointImage): bool {.error:
  "Use approximate comparison, `=~`, or compare coordinates directly."
.}


func `==`*(p, q: PointCanvas): bool {.error:
  "Use approximate comparison, `=~`, or compare coordinates directly."
.}



#[ Palette ]#

const lut_ink_to_rgb: array[Ink, Rgb] = [
  Ink.Backdrop: Rgb(red: 0x10, green: 0x13, blue: 0x1a),
  Ink.Axis: Rgb(red: 0x5a, green: 0x62, blue: 0x72),
  Ink.Guide: Rgb(red: 0x44, green: 0x4c, blue: 0x5e),
  Ink.Label: Rgb(red: 0xc8, green: 0xce, blue: 0xdb),
  Ink.Amber: Rgb(red: 0xff, green: 0xb4, blue: 0x54),
  Ink.Coral: Rgb(red: 0xff, green: 0x6f, blue: 0x61),
  Ink.Cyan: Rgb(red: 0x6f, green: 0xc3, blue: 0xdf),
  Ink.Violet: Rgb(red: 0xc7, green: 0x92, blue: 0xea),
  Ink.Lime: Rgb(red: 0x8f, green: 0xbc, blue: 0x5a),
  Ink.Teal: Rgb(red: 0x3f, green: 0xb8, blue: 0xa0),
  Ink.Rose: Rgb(red: 0xe0, green: 0x6c, blue: 0x9f),
] ## Map palette slot to colour, chosen for contrast against backdrop and each other.


func `$`(colour: Rgb): string =
  ## Convert colour to SVG hexadecimal notation.
  &"#{colour.red:02x}{colour.green:02x}{colour.blue:02x}"



#[ Image Space Conversion ]#

func toCanvas*(p: PointImage): PointCanvas =
  ## Map normalised device coordinates onto canvas pixels.
  ##   Vertical axis is flipped, as image measures upward and SVG measures downward.
  const HALF_HEIGHT = float(PIXELS_HEIGHT) * 0.5
  PointCanvas(
    x: float(PIXELS_WIDTH) * 0.5 + p.x * HALF_HEIGHT,
    y: HALF_HEIGHT - p.y * HALF_HEIGHT,
  )



#[ Document Lifetime ]#

proc openCanvas*(path: string): Canvas =
  ## Open SVG document at `path`, writing its header and backdrop.
  result = Canvas(file: open(path, fmWrite))
  result.file.write(
    &"<svg xmlns=\"http://www.w3.org/2000/svg\" " &
    &"width=\"{PIXELS_WIDTH}\" height=\"{PIXELS_HEIGHT}\" " &
    &"viewBox=\"0 0 {PIXELS_WIDTH} {PIXELS_HEIGHT}\">\n"
  )
  result.file.write(
    &"<rect width=\"{PIXELS_WIDTH}\" height=\"{PIXELS_HEIGHT}\" " &
    &"fill=\"{lut_ink_to_rgb[Ink.Backdrop]}\"/>\n"
  )


proc closeCanvas*(canvas: var Canvas) =
  ## Close SVG document, writing its footer.
  canvas.file.write("</svg>\n")
  canvas.file.close



#[ Drawing Primitives ]#

proc writePoints(canvas: var Canvas, points: openArray[PointCanvas]) =
  ## Write vertex list shared by `<polyline>` and `<polygon>`.
  canvas.file.write(" points=\"")
  for i, p in points:
    if i > 0: canvas.file.write(" ")
    canvas.file.write(&"{p.x:.2f},{p.y:.2f}")
  canvas.file.write("\"/>\n")


proc drawPolyline*(
  canvas: var Canvas;
  points: openArray[PointCanvas];
  ink: Ink;
  width = 1.6;
  opacity = 1.0;
) =
  ## Draw open polyline through `points`.
  ##   Run of fewer than two vertices is skipped, as `<polyline>` then renders nothing.
  if len(points) < 2: return
  canvas.file.write(
    &"<polyline fill=\"none\" stroke=\"{lut_ink_to_rgb[ink]}\" " &
    &"stroke-width=\"{width:.2f}\" stroke-opacity=\"{opacity:.3f}\" " &
    &"stroke-linecap=\"round\" stroke-linejoin=\"round\""
  )
  canvas.writePoints(points)


proc drawPolygon*(
  canvas: var Canvas;
  points: openArray[PointCanvas];
  ink: Ink;
  opacity = 0.12;
) =
  ## Draw filled polygon through `points`.
  ##   Run of fewer than three vertices is skipped, as `<polygon>` then encloses no area.
  if len(points) < 3: return
  canvas.file.write(
    &"<polygon stroke=\"none\" fill=\"{lut_ink_to_rgb[ink]}\" " &
    &"fill-opacity=\"{opacity:.3f}\""
  )
  canvas.writePoints(points)


proc drawMarker*(canvas: var Canvas, at: PointCanvas, ink: Ink, radius = 4.5) =
  ## Draw filled disc marking single position.
  canvas.file.write(
    &"<circle cx=\"{at.x:.2f}\" cy=\"{at.y:.2f}\" r=\"{radius:.2f}\" " &
    &"fill=\"{lut_ink_to_rgb[ink]}\"/>\n"
  )


proc writeEscaped(canvas: var Canvas, text: string) =
  ## Write text with XML metacharacters replaced by entities.
  for c in text:
    case c
    of '&': canvas.file.write("&amp;")
    of '<': canvas.file.write("&lt;")
    of '>': canvas.file.write("&gt;")
    else: canvas.file.write(c)


proc drawText*(
  canvas: var Canvas;
  at: PointCanvas;
  text: string;
  ink: Ink;
  size = 13.0;
  as_monospace = false;
) =
  ## Draw single line of text with its baseline at `at`.
  let fonts = if as_monospace: FONTS_LEGEND else: FONTS_LABEL
  canvas.file.write(
    &"<text x=\"{at.x:.2f}\" y=\"{at.y:.2f}\" font-family=\"{fonts}\" " &
    &"font-size=\"{size:.2f}\" fill=\"{lut_ink_to_rgb[ink]}\">"
  )
  canvas.writeEscaped(text)
  canvas.file.write("</text>\n")
