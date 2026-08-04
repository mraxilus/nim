## Measure what the tool costs itself, and report it in the scene's own terms.
##
## The frame-time graph is **raw and unsmoothed**: smoothing hides exactly the rare slow frame
## the graph exists for. The object-pool strip wears the scene's own colours, so which slot an
## object sits in — and how far the colour cycler has walked the palette — are both legible at
## a glance. Both front-ends receive that strip as one buffer of colour triples, so neither
## presentation layer carries a palette rule.

{.experimental: "strictFuncs".}

import ./[config, palette, scene]



#[ Constants ]#

const FRAME_SAMPLE_COUNT* = 240
  ## Hold roughly four seconds of frames at sixty a second.



#[ Type Definitions ]#

type
  FrameTimes* = object
    ## Hold the last few seconds of frame times, oldest overwritten first.
    samples_ms: array[FRAME_SAMPLE_COUNT, float]
    cursor: int
    length: int

  ArenaReport* = object
    ## Report one bump allocator's size in bytes.
    name*: string
    capacity_bytes*: int
    used_bytes*: int

  PoolReport* = object
    ## Report the object pool's occupancy and its fixed cost.
    active*: int
    free*: int
    capacity_bytes*: int
    slot_bytes*: int



#[ Frame Times ]#

func record*(times: var FrameTimes, frame_ms: float) =
  ## Record one frame's time, overwriting the oldest sample.
  times.samples_ms[times.cursor] = frame_ms
  times.cursor = (times.cursor + 1) mod FRAME_SAMPLE_COUNT
  if times.length < FRAME_SAMPLE_COUNT: times.length += 1


func len*(times: FrameTimes): int {.inline.} = times.length
  ## Count recorded samples.


func at*(times: FrameTimes, index: int): float =
  ## Read a sample, oldest first, so a graph walks it left to right.
  let start = (times.cursor - times.length + FRAME_SAMPLE_COUNT) mod FRAME_SAMPLE_COUNT
  times.samples_ms[(start + index) mod FRAME_SAMPLE_COUNT]


func latest*(times: FrameTimes): float =
  ## Read the most recent sample.
  if times.length == 0: return 0.0
  times.at(times.length - 1)


func peak*(times: FrameTimes): float =
  ## Read the slowest recorded frame, the reading the graph exists to keep.
  for index in 0 ..< times.length:
    let sample = times.at(index)
    if sample > result: result = sample


func mean*(times: FrameTimes): float =
  ## Read the average frame time over the buffer.
  if times.length == 0: return 0.0
  var total = 0.0
  for index in 0 ..< times.length:
    total += times.at(index)
  total/times.length.float



#[ Pool Strip ]#

func poolStrip*(scene: Scene, strip: var array[ITEM_CAPACITY*3, float]) =
  ## Fill caller's storage with one colour triple per pool slot.
  ##   An occupied cell wears that object's own colour, a free one the recessive grid colour,
  ##   so the strip reads as the scene rather than as an anonymous occupancy count.
  for index in 0 ..< ITEM_CAPACITY:
    let slot = Slot(index)
    let color =
      if scene.isLive(slot): scene.paint(slot).color
      else: Paint.Grid.color
    strip[index*3] = color.r
    strip[index*3 + 1] = color.g
    strip[index*3 + 2] = color.b


func poolReport*(scene: Scene, slot_bytes: int): PoolReport =
  ## Report how full the object pool is, and what it costs.
  PoolReport(
    active: scene.count,
    free: ITEM_CAPACITY - scene.count,
    capacity_bytes: slot_bytes*ITEM_CAPACITY,
    slot_bytes: slot_bytes,
  )


func fillFraction*(report: ArenaReport): float =
  ## Measure how full an arena is, for a bar to draw.
  if report.capacity_bytes <= 0: return 0.0
  report.used_bytes.float/report.capacity_bytes.float
