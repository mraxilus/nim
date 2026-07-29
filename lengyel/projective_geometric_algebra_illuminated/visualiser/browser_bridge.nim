## Bridge the fixed fifteen-object storyboard demo to a WebGL front end, compiled through
## Nim's own JS backend rather than reimplemented in JS -- every join, meet, attitude,
## support, expansion and projection the demo draws is computed by the same `pga`,
## `objects`, `mesh`, `camera`, `scene` and `storyboard` modules the desktop app itself
## draws through; only the presentation (WebGL calls, DOM, pointer input) is JS's own,
## exactly as OpenGL/SDL/Dear ImGui are the desktop app's own presentation layer over the
## same CPU-side geometry.
##
## Exported procs are the entire surface a browser needs: build the demo once, drive the
## camera and the current step, then pull one frame's vertex data and view-projection
## matrix out as plain arrays a caller can upload to WebGL directly.

{.experimental: "strictFuncs".}

import ./[objects, mesh, camera, scene, storyboard]



#[ Demo State ]#

var
  g_scene: Scene
  g_camera: Camera
  g_count_seeds: int
  g_are_visible: array[ITEMS_MAX, bool]
  g_borns: array[ITEMS_MAX, float]
  g_step: int = -1 ## -1 names "seeds only", i.e. before the first step applies.


proc operativeSlots(step: int): seq[int] =
  ## Name the slots step `step` touches: the operand(s) it reads plus the slot it writes
  ## into -- empty before the first step, i.e. for `step < 0`.
  ##   Mirrors `runStoryboard`'s own `operative_current`, but computed fresh from `step`
  ##   alone rather than carried step to step, so a caller may jump to any step directly
  ##   (a scrubber drag), not just advance one at a time.
  if step < 0: return @[]
  let this_step = STEPS[step]
  result = @[this_step.index_first, g_count_seeds + step]
  if lut_operation_to_arity[this_step.operation] == Arity.Two:
    result.add(this_step.index_second)


proc toRgbSeq(c: Rgba): seq[float32] = @[c.red, c.green, c.blue]
  ## Format colour as an `[r, g, b]` triple, for a caller that wants a CSS colour string
  ## to format one for itself -- DOM styling is not this module's own job.


proc flatten(mesh: Mesh): seq[float32] =
  ## Interleave one primitive's vertices as `x, y, z, r, g, b, a, x, y, z, r, g, b, a, ...`,
  ## ready for a caller to hand straight to `gl.bufferData`.
  result = newSeqOfCap[float32](mesh.count_vertices * 7)
  for i in 0 ..< mesh.count_vertices:
    let v = mesh.vertices[i]
    result.add(v.x)
    result.add(v.y)
    result.add(v.z)
    result.add(v.red)
    result.add(v.green)
    result.add(v.blue)
    result.add(v.alpha)



#[ Setup ]#

proc nimInit(now: cfloat) {.exportc.} =
  ## Build the fixed demo -- four seeds, then all eleven storyboard steps, applied
  ## through the real `applyOperation` catalogue -- and place the camera at the same
  ## default orbit the desktop app itself opens on.
  g_scene = initScene()
  constructSeeds(g_scene, 0.0)
  g_count_seeds = g_scene.len
  for step in STEPS:
    applyStep(g_scene, step, 0.0)

  g_camera = initCamera(
    target = Position(x: 0, y: 0, z: 1), distance = 19.0, azimuth = 1.05, elevation = 0.42
  )

  for slot in 0 ..< ITEMS_MAX:
    g_are_visible[slot] = slot < g_count_seeds
    g_borns[slot] = float(now)
  g_step = -1



#[ Step Transport ]#

proc nimStepCount(): cint {.exportc.} = cint(STEPS.len)


proc nimCurrentStep(): cint {.exportc.} = cint(g_step)


proc nimStepLabel(step: cint): cstring {.exportc.} =
  ## Name the formula step `step` applies -- "Seeds placed." before the first, i.e. for
  ## `step < 0`, otherwise the label straight out of `storyboard.STEPS`.
  if step < 0: cstring"Seeds placed."
  else: cstring(STEPS[int(step)].label)


proc nimStepColor(step: cint): seq[float32] {.exportc.} =
  ## Report the colour step `step`'s own derived object is drawn with.
  let ink = if step < 0: Ink.Amber else: STEPS[int(step)].ink
  toRgbSeq(ink.colour)


proc nimGotoStep(step: cint, now: cfloat) {.exportc.} =
  ## Move to `step`, updating which slots are visible under the same "pin seeds, roll
  ## the rest" rule `runStoryboard` applies: seeds stay visible throughout; a derived
  ## object is visible only for the step that creates it and the one right after.
  ##   Stamps `born` only for a slot that just became visible, so an object already on
  ##   screen does not restart its appear animation when nothing about its own
  ##   visibility changed.
  let
    stepI = int(step)
    current = operativeSlots(stepI)
    previous = operativeSlots(stepI - 1)
  for slot in 0 ..< ITEMS_MAX:
    let visible = slot < g_count_seeds or slot in current or slot in previous
    if visible and not g_are_visible[slot]: g_borns[slot] = float(now)
    g_are_visible[slot] = visible
  g_step = stepI



#[ Camera ]#

proc nimCameraOrbit(turn, rise: cfloat) {.exportc.} =
  camera.orbit(g_camera, float(turn), float(rise))


proc nimCameraDolly(factor: cfloat) {.exportc.} =
  camera.dolly(g_camera, float(factor))


proc nimCameraPan(across, up: cfloat) {.exportc.} =
  camera.pan(g_camera, float(across), float(up))


proc nimBackdropColor(): seq[float32] {.exportc.} = toRgbSeq(Ink.Backdrop.colour)



#[ Frame Assembly ]#

type FrameData = object
  ## Hold one frame's worth of vertex data plus the transform it is drawn through --
  ## everything a caller needs to issue this frame's `gl.drawArrays` calls.
  tri_verts, line_verts, point_verts: seq[float32]
  view_projection: seq[float32]


proc nimBuildFrame(
  aspect, now: cfloat; show_axes, show_grid: bool
): FrameData {.exportc.} =
  ## Tessellate every visible object at the current step, at the camera's current
  ## placement, through the same `mesh.addObject` dispatch and `camera` transforms the
  ## desktop app draws through.
  var meshes: MeshSet
  clearMeshes(meshes)

  let eye = g_camera.eye
  let scale = DrawExtent(
    extent_furniture: extentFurnitureFor(g_camera.distance_far),
    eye: eye,
    radius_horizon: radiusHorizonFor(g_camera.distance_far),
  )

  if show_grid: addGrid(meshes, scale.extent_furniture)
  if show_axes: addAxes(meshes, scale.extent_furniture)

  for slot, item in g_scene.pairs:
    if slot < ITEMS_MAX and g_are_visible[slot]:
      let progress = animationProgress(float(now), g_borns[slot])
      discard meshes.addObject(item.geometry, item.ink.colour, scale, progress)

  let vp = g_camera.initMatrixViewProjection(float(aspect))
  var view_projection = newSeq[float32](16)
  for row in 0 .. 3:
    for column in 0 .. 3:
      view_projection[4*column + row] = vp.at(row, column)

  FrameData(
    tri_verts: flatten(meshes[Primitive.Triangle]),
    line_verts: flatten(meshes[Primitive.Line]),
    point_verts: flatten(meshes[Primitive.Point]),
    view_projection: view_projection,
  )
