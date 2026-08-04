## Encode a run of captured frames as an animated GIF.
##
## **The format's LZW has a trap worth a permanent regression test**: the code size widens one
## symbol earlier on decode than on encode, because a decoder is always one entry behind the
## encoder that wrote the stream. An encoder that grows at its own natural point produces a
## stream a conforming decoder misreads from the first widening onward. `tests/suite.nim`
## round-trips a real encoded frame past that point through an independently written decoder.
##
## Colours are quantised to a fixed 6×6×6 cube plus a grey ramp, not to a per-frame optimal
## palette: the captured frames share one dark scene palette, a fixed table keeps every frame
## on the same colours — so an object does not shift hue between steps — and it needs no
## histogram pass. The cost is banding on the translucent washes, which is accepted.
##
## The dictionary is a fixed-capacity open-addressed table rather than a third arena: it needs
## random-access probing within a frame, and arenas are bump-only append.

{.experimental: "strictFuncs".}



#[ Palette ]#

const
  CUBE_STEPS* = 6
    ## Step each channel this many times in the fixed colour cube.
  GREY_STEPS* = 40
    ## Extend the cube with this many greys, where the dark UI spends most of its range.
  PALETTE_SIZE* = 256
    ## Size the global colour table, as the format's largest.

func paletteEntry*(index: int): (uint8, uint8, uint8) =
  ## Read one colour of the fixed table.
  if index < CUBE_STEPS*CUBE_STEPS*CUBE_STEPS:
    let
      r = index div (CUBE_STEPS*CUBE_STEPS)
      g = (index div CUBE_STEPS) mod CUBE_STEPS
      b = index mod CUBE_STEPS
      step = 255 div (CUBE_STEPS - 1)
    return (uint8(r*step), uint8(g*step), uint8(b*step))
  let grey = index - CUBE_STEPS*CUBE_STEPS*CUBE_STEPS
  if grey < GREY_STEPS:
    let value = uint8(grey*255 div max(GREY_STEPS - 1, 1))
    return (value, value, value)
  (0'u8, 0'u8, 0'u8)


func quantize*(r, g, b: uint8): uint8 =
  ## Map a colour to its nearest table entry, by squared distance.
  var
    best = 0
    best_distance = high(int)
  for index in 0 ..< PALETTE_SIZE:
    let (pr, pg, pb) = paletteEntry(index)
    let distance =
      (int(r) - int(pr))*(int(r) - int(pr)) +
      (int(g) - int(pg))*(int(g) - int(pg)) +
      (int(b) - int(pb))*(int(b) - int(pb))
    if distance < best_distance:
      best_distance = distance
      best = index
  uint8(best)



#[ Bit Packing ]#

type BitWriter = object
  ## Accumulate codes of varying width into the format's own sub-block stream.
  bytes: string
  accumulator: uint32
  bits: int

proc write(writer: var BitWriter, code: int, width: int) =
  ## Append one code of a given width, least significant bit first.
  writer.accumulator = writer.accumulator or (uint32(code) shl writer.bits)
  writer.bits += width
  while writer.bits >= 8:
    writer.bytes.add(char(writer.accumulator and 0xFF))
    writer.accumulator = writer.accumulator shr 8
    writer.bits -= 8


proc flush(writer: var BitWriter) =
  ## Append whatever bits are left, padded.
  if writer.bits > 0:
    writer.bytes.add(char(writer.accumulator and 0xFF))
    writer.accumulator = 0
    writer.bits = 0



#[ Dictionary ]#

const DICTIONARY_CAPACITY = 8192
  ## Size the string table's open-addressed storage, above the format's 4096 codes.

type Dictionary = object
  ## Hold LZW string-table entries for random-access probing within one frame.
  keys: array[DICTIONARY_CAPACITY, uint32]
  values: array[DICTIONARY_CAPACITY, int32]

proc clear(dictionary: var Dictionary) =
  ## Empty the table.
  for index in 0 ..< DICTIONARY_CAPACITY:
    dictionary.keys[index] = 0
    dictionary.values[index] = -1


proc find(dictionary: Dictionary, key: uint32): int =
  ## Look a key up, reporting its code or nothing.
  var slot = int((key*2654435761'u32) mod DICTIONARY_CAPACITY)
  for _ in 0 ..< DICTIONARY_CAPACITY:
    if dictionary.values[slot] < 0: return -1
    if dictionary.keys[slot] == key: return int(dictionary.values[slot])
    slot = (slot + 1) mod DICTIONARY_CAPACITY
  -1


proc insert(dictionary: var Dictionary, key: uint32, value: int) =
  ## Record a key's code.
  var slot = int((key*2654435761'u32) mod DICTIONARY_CAPACITY)
  for _ in 0 ..< DICTIONARY_CAPACITY:
    if dictionary.values[slot] < 0:
      dictionary.keys[slot] = key
      dictionary.values[slot] = int32(value)
      return
    slot = (slot + 1) mod DICTIONARY_CAPACITY



#[ Encoding ]#

proc encodeLzw*(indices: openArray[uint8]): string =
  ## Compress one frame's palette indices, as the format's image data.
  ##   Widens the code size **one entry before** the width it is about to overflow, because a
  ##   decoder adds its own entry one symbol later and would otherwise read the next code at
  ##   the narrower width.
  const
    MINIMUM_CODE_SIZE = 8
    CLEAR_CODE = 1 shl MINIMUM_CODE_SIZE
    END_CODE = CLEAR_CODE + 1
  var
    writer = BitWriter()
    dictionary = Dictionary()
    code_size = MINIMUM_CODE_SIZE + 1
    next_code = END_CODE + 1
  dictionary.clear()
  writer.write(CLEAR_CODE, code_size)
  if indices.len == 0:
    writer.write(END_CODE, code_size)
    writer.flush()
    return writer.bytes

  var prefix = int(indices[0])
  for position in 1 ..< indices.len:
    let
      next = int(indices[position])
      key = (uint32(prefix) shl 8) or uint32(next)
      found = dictionary.find(key)
    if found >= 0:
      prefix = found
      continue
    writer.write(prefix, code_size)
    dictionary.insert(key, next_code)
    next_code += 1
    # Widen one entry later than the table's own width suggests: the decoder adds its entry
    #   one symbol after the encoder does, so it reaches each width first. An encoder that
    #   widens at its own natural point writes codes a conforming decoder misreads from the
    #   first widening onward — the trap `tests/suite.nim` round-trips a real stream through.
    if next_code > (1 shl code_size) and code_size < 12:
      code_size += 1
    if next_code >= 4096:
      writer.write(CLEAR_CODE, code_size)
      dictionary.clear()
      code_size = MINIMUM_CODE_SIZE + 1
      next_code = END_CODE + 1
    prefix = next
  writer.write(prefix, code_size)
  writer.write(END_CODE, code_size)
  writer.flush()
  writer.bytes


proc subBlocks(data: string): string =
  ## Cut a byte stream into the format's length-prefixed sub-blocks.
  var cursor = 0
  while cursor < data.len:
    let size = min(255, data.len - cursor)
    result.add(char(size))
    result.add(data[cursor ..< cursor + size])
    cursor += size
  result.add(char(0))


proc littleEndian(value: int): string =
  ## Write a 16-bit field in the byte order the format requires.
  result = newString(2)
  result[0] = char(value and 0xFF)
  result[1] = char((value shr 8) and 0xFF)


proc encodeGif*(
  frames: openArray[seq[uint8]], width, height, delay_hundredths: int
): string =
  ## Encode RGBA frames as one looping animated GIF.
  result = "GIF89a" & littleEndian(width) & littleEndian(height)
  result.add(char(0xF7))  # Global colour table, 256 entries.
  result.add(char(0))
  result.add(char(0))
  for index in 0 ..< PALETTE_SIZE:
    let (r, g, b) = paletteEntry(index)
    result.add(char(r))
    result.add(char(g))
    result.add(char(b))

  # Loop forever, through the application extension every reader knows by name.
  result.add("\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00")

  for frame in frames:
    result.add("\x21\xF9\x04\x00")
    result.add(littleEndian(delay_hundredths))
    result.add("\x00\x00")
    result.add("\x2C")
    result.add(littleEndian(0))
    result.add(littleEndian(0))
    result.add(littleEndian(width))
    result.add(littleEndian(height))
    result.add(char(0))
    var indices = newSeq[uint8](width*height)
    for pixel in 0 ..< width*height:
      indices[pixel] = quantize(
        frame[pixel*4], frame[pixel*4 + 1], frame[pixel*4 + 2]
      )
    result.add(char(8))
    result.add(subBlocks(encodeLzw(indices)))
  result.add("\x3B")
