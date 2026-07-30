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

import std/options

import ../pga
import ./[objects, mesh, camera, scene, storyboard]



#[ Demo State ]#

var
  g_scene: Scene
  g_camera: Camera
  g_count_seeds: int
  g_are_visible: array[ITEMS_MAX, bool] ## Whether a slot's own step has been reached
    ## yet at all -- false for one not built up to by the current step, drawn not at
    ## all; true for every seed and every step at or before the current one.
  g_are_dimmed: array[ITEMS_MAX, bool] ## Whether a visible slot is shown muted, as
    ## background context, rather than at full colour; see `mesh.muted`.
  g_borns: array[ITEMS_MAX, float]
  g_step: int = -1 ## -1 names "seeds only", i.e. before the first step applies.
  g_index_highlighted: int = -1 ## Slot the current step just built, ringed as if
    ## freshly selected; -1 before the first step applies, matching `g_step`.


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
    g_are_dimmed[slot] = false
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


proc shapeDescription(m: Multivector): string =
  ## Name what shape `m` stands for, or that it stands for none at all. Built by hand
  ## rather than through `scene.describeShape`: that proc's fixed-buffer, `unsafeAddr`-
  ## based design does not carry over correctly to the JS backend (the same kind of gap
  ## `scene.Item`'s own doc comment already flags for a value parameter's address), and
  ## a plain string costs nothing extra here, called only when the step transport's own
  ## text changes, not once a frame.
  let s = shape(m)
  if s.isNone: return "mixed grade, nothing to draw"
  case s.get
  of Shape.Point: (if isHorizon(m): "point at horizon" else: "point")
  of Shape.Line: (if isHorizon(m): "line at horizon" else: "line")
  of Shape.Plane: (if isHorizon(m): "plane at horizon" else: "plane")


proc nimStepShape(step: cint): cstring {.exportc.} =
  ## Name what step `step`'s own result actually is -- most useful for a step that
  ## draws nothing at all (wedging a point with a plane gives a grade-4 volume, with no
  ## shape to draw), so that reads as "nothing to draw" rather than as a bug.
  if step < 0: return cstring""
  cstring(shapeDescription(g_scene[g_count_seeds + int(step)].geometry))


proc nimGotoStep(step: cint, now: cfloat) {.exportc.} =
  ## Move to `step`. Every slot already reached (a seed, or a step at or before this
  ## one) stays visible from here on -- a construction's own history should stay
  ## legible, not disappear as later steps pass it by -- but only the slots the same
  ## "pin seeds, roll the rest" rule `runStoryboard` uses (seeds, this step's own
  ## operands and result, and the step right before) draw at full colour; everything
  ## else visible draws muted (`mesh.muted`), as background context.
  ##   Stamps `born` only for a slot newly reached, so an object already on screen does
  ##   not restart its appear animation as focus moves on.
  let
    stepI = int(step)
    current = operativeSlots(stepI)
    previous = operativeSlots(stepI - 1)
  for slot in 0 ..< ITEMS_MAX:
    let
      reached = slot < g_count_seeds or slot < g_count_seeds + stepI + 1
      focal = slot < g_count_seeds or slot in current or slot in previous
    if reached and not g_are_visible[slot]: g_borns[slot] = float(now)
    g_are_visible[slot] = reached
    g_are_dimmed[slot] = reached and not focal
  g_step = stepI
  g_index_highlighted = if stepI < 0: -1 else: g_count_seeds + stepI



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
  ol_tri_verts, ol_line_verts, ol_point_verts: seq[float32] ## Current step's own
    ## result, built oversized and in a flat outline colour, for the outline pass --
    ## drawn before the main frame above, so only what peeks out past that object's
    ## own true-size redraw over it shows, reading as a selection border; empty
    ## wherever nothing is currently highlighted.


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
      let tint = if g_are_dimmed[slot]: muted(item.ink.colour) else: item.ink.colour
      discard meshes.addObject(item.geometry, tint, scale, progress, item.anchorOverride)

  # Build the current step's own result a second time, oversized and in a flat outline
  #   colour, into its own buffer the outline pass draws before the frame above -- see
  #   `renderer.drawOutline`'s own doc comment for why this reads as a selection border.
  var meshes_outline: MeshSet
  clearMeshes(meshes_outline)
  if g_index_highlighted >= 0 and g_index_highlighted < ITEMS_MAX and
     g_are_visible[g_index_highlighted]:
    let item = g_scene[g_index_highlighted]
    discard meshes_outline.addObject(
      item.geometry, Ink.Outline.colour, scale,
      animationProgress(float(now), g_borns[g_index_highlighted]), item.anchorOverride,
      outline = true,
    )

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
    ol_tri_verts: flatten(meshes_outline[Primitive.Triangle]),
    ol_line_verts: flatten(meshes_outline[Primitive.Line]),
    ol_point_verts: flatten(meshes_outline[Primitive.Point]),
  )
