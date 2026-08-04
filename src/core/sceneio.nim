## Write and read `.rgascene` files, a compact binary format matching the scene's own layout.
##
## | Bytes    | Field                                                                        |
## |----------|------------------------------------------------------------------------------|
## | 4        | magic `RGAS`                                                                 |
## | 1        | format version                                                               |
## | 1        | basis count, 16 here; a mismatch means another dimension or metric           |
## | 4        | item count, native unsigned 32-bit                                           |
## | per item | colour (1), visibility (1), label length (1) + bytes, then a float per basis |
##
## Native-endian throughout: there is no external spec to match, unlike the image formats,
## which follow their own required endianness. **A file will not cross endianness.**
##
## Only live items are written, in slot order. Deliberately omitted: slot numbers, meaningless
## once reloaded since a fresh scene assigns its own free-list order; birth times, meaningless
## across runs, so a loaded item is born at the dawn of time rather than partway through an
## animation that never happened; the anchor override, a rendering hint; and fixed-width label
## padding, since length-prefixing keeps the format independent of the writing build's cap.
##
## The browser reaches the identical format through `toRecords`/`fromRecords`, packing the
## floats with the platform's own binary view rather than reinventing IEEE-754 here.

{.experimental: "strictFuncs".}

import std/options

import ./[algebra, config, palette, scene]



#[ Format ]#

const
  MAGIC* = "RGAS"
    ## Mark the file, so a foreign one is refused rather than misread.
  FORMAT_VERSION* = 1'u8
    ## Version the meaning of the stored fields.
    ##   Bumped whenever any stored field changes meaning, including a change to how colours
    ##   or basis names are derived. Older versions are refused, never guessed at.
  HEADER_SIZE* = MAGIC.len + 1 + 1 + 4
    ## Size the fixed header, for a reader that seeks past it.
  FLOAT_SIZE* = sizeof(float)
    ## Size one stored coefficient, the platform's own native float.



#[ Record Boundary ]#

type ItemRecord* = object
  ## Carry one item's stored fields across a language boundary.
  ##   Exists so the browser writes the same format from the same values, without the core
  ##   encoding floats itself on a backend that has no bytes.
  paint*: int
  is_visible*: bool
  label*: string
  coefficients*: array[BASIS_COUNT, float]


func toRecords*(scene: Scene): seq[ItemRecord] =
  ## Read every live item's stored fields, in slot order.
  for slot in scene.items:
    var record = ItemRecord(
      paint: ord(scene.paint(slot)),
      is_visible: scene.isVisible(slot),
      label: $scene.label(slot),
    )
    let geometry = scene.geometry(slot)
    for b in Basis:
      record.coefficients[ord(b)] = geometry.coefficient(b)
    result.add(record)


func fromRecords*(records: seq[ItemRecord]): Option[Scene] =
  ## Build a scene from stored records, or nothing where they do not fit.
  ##   Parses into a staging scene and hands it back only on complete success, so a bad file
  ##   leaves the caller's scene untouched.
  if records.len > ITEM_CAPACITY: return
  var staging = initScene()
  for record in records:
    if record.paint < ord(CATEGORICAL_FIRST) or record.paint > ord(Paint.high): return
    var geometry = Multivector()
    for b in Basis:
      geometry = geometry.withCoefficient(b, record.coefficients[ord(b)])
    let slot = staging.add(
      geometry = geometry,
      label = initLabel(record.label),
      born_ms = 0.0,  # A loaded item is born at the dawn of time, not mid-animation.
      paint = some(Paint(record.paint)),
    )
    if slot.isNone: return
    staging.setVisible(slot.get, record.is_visible)
  some(staging)



#[ Encoding ]#

when not defined(js):
  func encode*(scene: Scene): string =
    ## Encode scene to the bytes of a `.rgascene` file.
    ##   Allocates: saving is a once-per-click path, never the frame loop.
    result = MAGIC
    result.add(char(FORMAT_VERSION))
    result.add(char(BASIS_COUNT))
    var count = uint32(scene.count)
    var count_bytes = newString(4)
    copyMem(addr count_bytes[0], addr count, 4)
    result.add(count_bytes)
    for record in scene.toRecords:
      result.add(char(record.paint))
      result.add(char(if record.is_visible: 1 else: 0))
      result.add(char(min(record.label.len, 255)))
      result.add(record.label[0 ..< min(record.label.len, 255)])
      for b in Basis:
        var value = record.coefficients[ord(b)]
        var value_bytes = newString(FLOAT_SIZE)
        copyMem(addr value_bytes[0], addr value, FLOAT_SIZE)
        result.add(value_bytes)


  func decode*(bytes: string): Option[Scene] =
    ## Decode `.rgascene` bytes into a scene, or nothing where they are not one.
    ##   Every refusal — short file, wrong magic, wrong version, wrong basis count, too many
    ##   items — leaves the caller's scene untouched, because nothing is written until the
    ##   staging scene is complete.
    if bytes.len < HEADER_SIZE: return
    if bytes[0 ..< MAGIC.len] != MAGIC: return
    if uint8(bytes[4]) != FORMAT_VERSION: return
    if int(uint8(bytes[5])) != BASIS_COUNT: return
    var count: uint32
    var header = bytes
    copyMem(addr count, addr header[6], 4)
    if int(count) > ITEM_CAPACITY: return

    var
      records: seq[ItemRecord]
      cursor = HEADER_SIZE
    for _ in 0 ..< int(count):
      if cursor + 3 > bytes.len: return
      var record = ItemRecord(
        paint: int(uint8(bytes[cursor])),
        is_visible: uint8(bytes[cursor + 1]) != 0,
      )
      let label_length = int(uint8(bytes[cursor + 2]))
      cursor += 3
      if cursor + label_length + BASIS_COUNT*FLOAT_SIZE > bytes.len: return
      record.label = bytes[cursor ..< cursor + label_length]
      cursor += label_length
      for b in Basis:
        var value: float
        copyMem(addr value, addr header[cursor], FLOAT_SIZE)
        record.coefficients[ord(b)] = value
        cursor += FLOAT_SIZE
      records.add(record)
    fromRecords(records)
