## Write a framebuffer read-back as a PNG.
##
## The format's own byte order is big-endian, unlike the scene file, which has no external
## spec to match and is written native-endian. Compression is the platform's deflate library
## rather than a hand-rolled one: a codec is an external concern, and this project derives the
## algebra, not the codecs.

{.experimental: "strictFuncs".}

import std/os



#[ Deflate ]#

{.passL: "-lz".}

proc compress2(
  destination: ptr uint8, destination_length: ptr culong,
  source: ptr uint8, source_length: culong, level: cint,
): cint {.importc, header: "<zlib.h>".}
  ## Compress a buffer to a zlib stream, which is what a PNG data chunk holds.

proc crc32(
  crc: culong, buffer: ptr uint8, length: cuint
): culong {.importc, header: "<zlib.h>".}
  ## Checksum a chunk, as every PNG chunk carries.



#[ Chunks ]#

proc bigEndian(value: uint32): string =
  ## Write a 32-bit field in the byte order the format requires.
  result = newString(4)
  result[0] = char((value shr 24) and 0xFF)
  result[1] = char((value shr 16) and 0xFF)
  result[2] = char((value shr 8) and 0xFF)
  result[3] = char(value and 0xFF)


proc chunk(kind: string, payload: string): string =
  ## Write one chunk: length, kind, payload, checksum.
  var body = kind & payload
  let checksum = crc32(0, cast[ptr uint8](body[0].addr), body.len.cuint)
  bigEndian(payload.len.uint32) & body & bigEndian(checksum.uint32)



#[ Encoding ]#

proc encodePng*(pixels: openArray[uint8], width, height: int): string =
  ## Encode 8-bit RGBA pixels, top row first, as a PNG.
  ##   Every scanline carries filter type zero: the images this writes are flat UI panels and
  ##   thin geometry, where a filter buys little and costs a pass.
  var raw = newString(height*(1 + width*4))
  for row in 0 ..< height:
    let destination = row*(1 + width*4)
    raw[destination] = char(0)
    for index in 0 ..< width*4:
      raw[destination + 1 + index] = char(pixels[row*width*4 + index])

  var
    bound = culong(raw.len + raw.len div 100 + 64)
    compressed = newString(bound.int)
  let status = compress2(
    cast[ptr uint8](compressed[0].addr), addr bound,
    cast[ptr uint8](raw[0].addr), raw.len.culong, 6,
  )
  if status != 0: raise newException(CatchableError, "deflate failed with " & $status)
  compressed.setLen(bound.int)

  let header =
    bigEndian(width.uint32) & bigEndian(height.uint32) &
    char(8) & char(6) & char(0) & char(0) & char(0)  # 8-bit RGBA, no interlace.
  "\x89PNG\r\n\x1A\n" & chunk("IHDR", header) & chunk("IDAT", compressed) & chunk("IEND", "")


proc writePng*(path: string, pixels: openArray[uint8], width, height: int) =
  ## Write pixels to a PNG file, creating the directory it sits in.
  createDir(path.parentDir)
  writeFile(path, encodePng(pixels, width, height))
