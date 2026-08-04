## Run the scripted construction headless, writing one image per step and an animated GIF.
##
## The capture distinguishes **reached** — this step has happened, and stays true forever after
## — from **focal**, which is the current step's operands and result, plus the step before it
## for continuity. Reached but not focal draws **muted, as background context rather than
## hidden**: objects disappearing between frames reads as more confusing than informative.
##
## A step that produces a horizon object reorients the camera through the closed-form inverse
## of the orbit camera's own forward-direction formula, then restores the default view. There
## is no field-of-view widening: reorienting suffices, and no field of view can bring back
## content that sits behind the camera.

{.experimental: "strictFuncs".}

import std/[options, os, strutils]

import ../core/[demo, workbench]
import ./[arena, gif, platform, png, renderer]



#[ Sizing ]#

const
  CAPTURE_WIDTH* = 1024
    ## Size a captured frame's width.
  CAPTURE_HEIGHT* = 640
    ## Size a captured frame's height.
  FRAME_DELAY_HUNDREDTHS* = 90
    ## Hold each GIF frame this long, near a second, which is a step's own reading time.

func storyboardArenaBytes*(): int =
  ## Size the permanent arena to the capture run's own requirement.
  ##   One frame of pixels, one frame of palette indices and the compressed bytes they become,
  ##   for every step of the construction plus its opening frame. Measured from the capture's
  ##   own shape rather than rounded to a comfortable number.
  let
    pixels = CAPTURE_WIDTH*CAPTURE_HEIGHT*4
    indices = CAPTURE_WIDTH*CAPTURE_HEIGHT
  (DEMO_STEP_COUNT + 1)*(pixels + indices)


func storyboardFrameArenaBytes*(): int =
  ## Size the frame arena to one throwaway unit of work: a single frame's own buffers.
  CAPTURE_WIDTH*CAPTURE_HEIGHT*5



#[ Capture ]#

proc captureFrame(draw: var Renderer): seq[uint8] =
  ## Read one drawn frame back, top row first.
  var flipped = newSeq[uint8](CAPTURE_WIDTH*CAPTURE_HEIGHT*4)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glFinish()
  glReadPixels(
    0, 0, CAPTURE_WIDTH.GLsizei, CAPTURE_HEIGHT.GLsizei, GL_RGBA, GL_UNSIGNED_BYTE,
    addr flipped[0],
  )
  result = newSeq[uint8](CAPTURE_WIDTH*CAPTURE_HEIGHT*4)
  for row in 0 ..< CAPTURE_HEIGHT:
    let source = (CAPTURE_HEIGHT - 1 - row)*CAPTURE_WIDTH*4
    for index in 0 ..< CAPTURE_WIDTH*4:
      result[row*CAPTURE_WIDTH*4 + index] = flipped[source + index]


proc presentationsFor(
  bench: Workbench, reached: seq[Slot], focal: seq[Slot]
): array[ITEM_CAPACITY, Presentation] =
  ## Decide how every item draws in one captured frame.
  for index in 0 ..< ITEM_CAPACITY:
    result[index] = Presentation.Hidden
  for slot in reached:
    if bench.scene.isLive(slot): result[slot.index] = Presentation.Muted
  for slot in focal:
    if bench.scene.isLive(slot): result[slot.index] = Presentation.Normal


proc drawCapture(
  bench: var Workbench, draw: var Renderer, meshes: var Mesh,
  presentations: array[ITEM_CAPACITY, Presentation],
) =
  ## Draw one captured frame, landing the camera instantly.
  ##   A captured frame must never show a half-finished pan, so the aim is delivered rather
  ##   than eased.
  bench.aim()
  bench.tween.deliver(bench.camera)
  bench.buildMesh(meshes, presentations)
  draw.beginFrame(CAPTURE_WIDTH, CAPTURE_HEIGHT)
  draw.drawScene(meshes, bench.camera)
  draw.drawRings(meshes, bench.camera)



#[ Storyboard ]#

proc runStoryboard*(
  directory: string, draw: var Renderer, meshes: var Mesh,
  permanent: var Arena, frame: var Arena,
) =
  ## Walk the construction, writing one image per step and an animated GIF of the run.
  createDir(directory)
  var
    bench = initWorkbench()
    frames: seq[seq[uint8]]
  bench.reset(seedScene())

  var reached: seq[Slot]
  for slot in bench.scene.items: reached.add(slot)

  # Open on the seeds alone, which is where both front-ends open too.
  bench.selection.clear()
  drawCapture(bench, draw, meshes, presentationsFor(bench, reached, reached))
  var pixels = captureFrame(draw)
  writePng(directory / "step-00-seeds.png", pixels, CAPTURE_WIDTH, CAPTURE_HEIGHT)
  frames.add(pixels)
  discard permanent.take(pixels.len)

  var previous: seq[Slot]
  for index, step in DEMO_STEPS:
    var built: seq[Slot]
    for slot in bench.scene.items: built.add(slot)
    if step.first >= built.len: continue
    let
      first = built[step.first]
      second = if step.second < built.len: built[step.second] else: first
    bench.now_ms = float(index + 1)*SEED_STEP_MS
    let derived = bench.applyOperation(step.operation, first, second)
    if derived.isNone: continue
    reached.add(derived.get)

    var focal = @[first, derived.get]
    if step.operation.arity == Arity.Binary: focal.add(second)
    for slot in previous: focal.add(slot)
    previous = @[first, derived.get]

    drawCapture(bench, draw, meshes, presentationsFor(bench, reached, focal))
    pixels = captureFrame(draw)
    let name = "step-" & align($(index + 1), 2, '0') & "-" &
      ($bench.scene.label(derived.get)).multiReplace(
        [("/", "-"), (" ", "-"), ("∧", "wedge"), ("∨", "vee")]
      )
    writePng(directory / (name & ".png"), pixels, CAPTURE_WIDTH, CAPTURE_HEIGHT)
    frames.add(pixels)
    discard permanent.take(pixels.len)

    # Restore the default view after a step that reoriented to show something at horizon.
    frame.reset()
    if bench.scene.geometry(derived.get).locus == Locus.Horizon:
      bench.camera = defaultCamera()
      bench.tween.release()

  writeFile(directory / "storyboard.gif", encodeGif(
    frames, CAPTURE_WIDTH, CAPTURE_HEIGHT, FRAME_DELAY_HUNDREDTHS
  ))
  echo "storyboard: ", frames.len, " frames into ", directory
