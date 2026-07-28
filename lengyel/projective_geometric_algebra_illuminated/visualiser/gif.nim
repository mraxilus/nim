## Encode a sequence of framebuffer readbacks as a short looping animated GIF.
##
## GIF is written out by hand, as PNG is in `image.nim`: the container below the
## compression is a handful of length- or count-tagged blocks and nothing more.
##   Unlike PNG, GIF's own compression is LZW rather than deflate, so no system codec
##   library carries it; the encoder below is small enough to write directly, matching
##   the same "depend on it only where it is genuinely external" line `image.nim` draws.
##
## Every frame is quantized to one fixed colour cube, six levels per channel, rather
## than searched for its nearest colour: quantizing a channel is one integer divide,
## with no per-pixel search over a palette, so encoding stays cheap however many
## frames a caller asks for. This runs only for the storyboard's own diagnostic
## capture, never in the interactive draw loop, but stays inexpensive on principle.
##
##   |-----------------------|-------------------------------------------------------|
##   | Block                 | Carries                                                |
##   |-----------------------|-------------------------------------------------------|
##   | Logical Screen        | Canvas size and the one global colour table.          |
##   | Application Extension | `NETSCAPE2.0` loop-forever marker.                    |
##   | Graphic Control (each) | This frame's hold time.                               |
##   | Image Descriptor      | This frame's LZW-compressed, quantized pixels.        |
##   |-----------------------|-------------------------------------------------------|
##
## Rows arrive bottom-up, as OpenGL reads them, and are flipped while being quantized,
## exactly as `image.nim` flips them while filtering, so no separate copy of a frame
## exists solely to turn it right side up.

{.experimental: "strictFuncs".}

import std/[strformat, syncio, tables]



#[ Encoder Configuration ]#

const
  CHANNELS = 3
    ## Fix channel count; frames arrive as the same tightly packed RGB triples PNG takes.
  LEVELS_PER_CHANNEL {.define: "visualiser.gif_levels_per_channel".} = 6
    ## Set how many evenly spaced samples each channel is quantized to.
  BITS_CODE = 8
    ## Fix LZW's root code size at 8 bits, so the global colour table is the simplest
    ## legal size, 256, regardless of how few of those entries the colour cube fills.
  COUNT_TABLE = 1 shl BITS_CODE
  COUNT_PALETTE = LEVELS_PER_CHANNEL*LEVELS_PER_CHANNEL*LEVELS_PER_CHANNEL

static:
  doAssert LEVELS_PER_CHANNEL in 2 .. 6,
    &"Colour cube needs 2 to 6 levels per channel to fit 256 entries; got " &
    &"`{LEVELS_PER_CHANNEL}`."
  doAssert COUNT_PALETTE <= COUNT_TABLE,
    &"Colour cube must fit the global colour table; {COUNT_PALETTE} used of {COUNT_TABLE}."



#[ Colour Quantization ]#

func levelToByte(level: int): uint8 =
  ## Map quantized level, 0 up to but under `LEVELS_PER_CHANNEL`, to a channel sample
  ## spanning the full 0..255 range, evenly spaced exactly as a "web-safe" cube is.
  uint8((level * 255) div (LEVELS_PER_CHANNEL - 1))


func byteToLevel(value: uint8): int =
  ## Snap a channel sample to the nearest of `LEVELS_PER_CHANNEL` evenly spaced levels.
  (int(value)*(LEVELS_PER_CHANNEL - 1) + 127) div 255


func paletteIndex*(red, green, blue: uint8): uint8 =
  ## Quantize one pixel straight to its index in the fixed colour cube.
  ##   Exported so a test can compute the same index a written frame quantized to,
  ##   independent of decoding the LZW stream itself.
  uint8(
    (byteToLevel(red)*LEVELS_PER_CHANNEL + byteToLevel(green))*LEVELS_PER_CHANNEL +
      byteToLevel(blue)
  )


func globalColorTable(): array[COUNT_TABLE*3, uint8] =
  ## Build the one colour cube every frame is quantized against; entries beyond the
  ## cube's own `COUNT_PALETTE` stay black, and quantization never produces their index.
  for index in 0 ..< COUNT_PALETTE:
    let
      level_blue = index mod LEVELS_PER_CHANNEL
      level_green = (index div LEVELS_PER_CHANNEL) mod LEVELS_PER_CHANNEL
      level_red = index div (LEVELS_PER_CHANNEL*LEVELS_PER_CHANNEL)
    result[index*3] = levelToByte(level_red)
    result[index*3 + 1] = levelToByte(level_green)
    result[index*3 + 2] = levelToByte(level_blue)



#[ LZW Compression ]#

type BitWriter = object ## Pack variable-width codes into bytes, least significant bit first.
  buffer: seq[uint8]
  pending: uint32
  count_pending: int


proc packCode(writer: var BitWriter; code, width: int) =
  ## Append `code`, `width` bits wide, as GIF's own LZW packs them.
  writer.pending = writer.pending or (uint32(code) shl writer.count_pending)
  writer.count_pending += width
  while writer.count_pending >= 8:
    writer.buffer.add(uint8(writer.pending and 0xFF))
    writer.pending = writer.pending shr 8
    writer.count_pending -= 8


proc flushBits(writer: var BitWriter) =
  ## Emit whatever partial byte remains, padded with zero bits above it.
  if writer.count_pending > 0:
    writer.buffer.add(uint8(writer.pending and 0xFF))
    writer.pending = 0
    writer.count_pending = 0


proc lzwEncode(indices: openArray[uint8]): seq[uint8] =
  ## Compress quantized pixel indices with GIF's own variable-width LZW.
  ##   Root codes 0 ..< `COUNT_TABLE` are the palette indices themselves; clear and end
  ##   codes follow immediately after, and every code the dictionary invents follows those.
  const
    CODE_CLEAR = COUNT_TABLE
    CODE_END = CODE_CLEAR + 1
    CODE_MAX = 4096
  var
    writer: BitWriter
    dict = initTable[(int, uint8), int]()
    next_code = CODE_END + 1
    width_code = BITS_CODE + 1
    code_current = -1

  writer.packCode(CODE_CLEAR, width_code)
  for value in indices:
    if code_current < 0:
      code_current = int(value)
      continue
    let key = (code_current, value)
    if dict.hasKey(key):
      code_current = dict[key]
      continue

    writer.packCode(code_current, width_code)
    if next_code < CODE_MAX:
      dict[key] = next_code
      inc next_code
      # GIF's own LZW widens a step later than the naive "table is now full" reading
      # would suggest: code 2^width_code still fits the current width, so only the
      # code after that (2^width_code + 1) forces the width to grow.
      if next_code > (1 shl width_code) and width_code < 12: inc width_code
    else:
      writer.packCode(CODE_CLEAR, width_code)
      dict.clear()
      next_code = CODE_END + 1
      width_code = BITS_CODE + 1
    code_current = int(value)

  if code_current >= 0: writer.packCode(code_current, width_code)
  writer.packCode(CODE_END, width_code)
  writer.flushBits()
  writer.buffer



#[ Block Assembly ]#

func toLittleEndian16(value: uint16): array[2, uint8] =
  ## Split unsigned integer into GIF's own byte order, least significant first.
  [uint8(value and 0xFF), uint8(value shr 8)]


proc writeSubBlocks(file: File; data: openArray[uint8]) =
  ## Write compressed stream as GIF's own length-prefixed sub-blocks, at most 255 bytes
  ## each, terminated by a zero-length block.
  var offset = 0
  while offset < len(data):
    let count = min(255, len(data) - offset)
    file.write(char(count))
    discard file.writeBytes(data, offset, count)
    offset += count
  file.write(char(0))


proc writeFrame(
  file: File; width, height: int; row_bottom_up: openArray[uint8]; centiseconds_delay: int
) =
  ## Write one frame's Graphic Control Extension and Image Descriptor.
  let delay = toLittleEndian16(uint16(centiseconds_delay))
  discard file.writeBytes([0x21'u8, 0xF9, 0x04, 0x00, delay[0], delay[1], 0x00, 0x00], 0, 8)

  let (w, h) = (toLittleEndian16(uint16(width)), toLittleEndian16(uint16(height)))
  discard file.writeBytes([0x2C'u8, 0, 0, 0, 0, w[0], w[1], h[0], h[1], 0x00], 0, 10)

  # Quantize while flipping, so no separate right-side-up copy of the frame exists.
  var indices = newSeq[uint8](width*height)
  for row in 0 ..< height:
    let
      source = (height - 1 - row)*width*CHANNELS
      destination = row*width
    for column in 0 ..< width:
      let at = source + column*CHANNELS
      indices[destination + column] =
        paletteIndex(row_bottom_up[at], row_bottom_up[at + 1], row_bottom_up[at + 2])

  file.write(char(BITS_CODE))
  file.writeSubBlocks(lzwEncode(indices))



#[ Animation Encoding ]#

proc writeGif*(
  path: string; width, height: int;
  frames_bottom_up: openArray[seq[uint8]]; centiseconds_delay: int
) =
  ## Write frames as one looping animated GIF, flipping rows so each reads top-down.
  ##   Every frame holds tightly packed RGB triples, first row nearest bottom, exactly
  ##   as `capturePixels` reads them and `writePng` takes them.
  doAssert width > 0 and height > 0,
    &"Image must have positive extent; got `{width}x{height}`."
  doAssert len(frames_bottom_up) > 0, "Animated GIF needs at least one frame."
  doAssert centiseconds_delay > 0,
    &"Hold time must be positive; got `{centiseconds_delay}` centiseconds."
  for frame in frames_bottom_up:
    doAssert len(frame) >= width*height*CHANNELS,
      &"Frame holds {len(frame)} bytes, short of {width*height*CHANNELS}."

  let file = open(path, fmWrite)
  defer: file.close

  discard file.writeChars("GIF89a", 0, 6)
  let (w, h) = (toLittleEndian16(uint16(width)), toLittleEndian16(uint16(height)))
  discard file.writeBytes([w[0], w[1], h[0], h[1], 0xF7'u8, 0, 0], 0, 7)
  let table = globalColorTable()
  discard file.writeBytes(table, 0, len(table))

  # Application Extension: loop forever, as a still storyboard is a poor animated one.
  discard file.writeChars("!\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00", 0, 19)

  for frame in frames_bottom_up:
    file.writeFrame(width, height, frame, centiseconds_delay)

  file.write(char(0x3B)) # Trailer.
