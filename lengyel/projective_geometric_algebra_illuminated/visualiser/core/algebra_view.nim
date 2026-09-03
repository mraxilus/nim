## Draw multivectors frame computed, each as thing it actually is.
##
## Ordinary picture draws stand-ins: plane becomes disc of fixed radius, since infinite
## surface would bury everything else, and line becomes ribbon so it has width.
##   Good pictures, bad statements.
##   This layer is statement, switched on when reader wants algebra rather than
##   illustration of it, as game engine draws physics world in wireframe over art.
##
##   |------------------|------------------------|-----------------------------------|
##   | Object           | Ordinary picture       | Here                              |
##   |------------------|------------------------|-----------------------------------|
##   | Finite plane     | disc at `EXTENT_PLANE` | lattice over whole plane          |
##   | Everything else  | as drawn               | as drawn, in `Ink.Algebra`        |
##   |------------------|------------------------|-----------------------------------|
##
## Lattice is how project already draws infinite plane.
##   Ground grid *is* plane at `z = 0`, laid as far as fog reaches and faded out.
##   Drawing every plane that way says "this goes on" in vocabulary reader learnt from
##   ground.
## Draws more than scene: line joining eye to target, plane near clip really is, ray
## under cursor and where it meets working level. See `algebra_trace`.
## What is recorded is decided here, once.
##   `addFrameTrace` is whole layer's entry point; both render paths call it rather than
##   listing what to record, since entry reaching one picture and missing other is exactly
##   fault layer exists to expose.
##
## Shared by desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render paths.

{.experimental: "strictFuncs".}

import std/options

import ../../pga
import ./[algebra_trace, boundary, camera, mesh, objects, picking, scene, tessellate]



#[ Debug Layer Configuration ]#

const
  ALPHA_ALGEBRA_LATTICE* = 0.55
    ## Fix strength of traced plane's lattice, against full-strength ink point or line takes.
    ##   Below them deliberately: infinite plane covers whole view, and at full strength
    ##   hides everything else trace shows.
  ALPHA_ALGEBRA_DERIVED* = 0.75
    ## Fix strength of *derived* geometry: sight axis, eye and near planes, cursor's ray.
    ##   Under scene's own entries: reader asks about their objects first.



#[ Drawing ]#

func inkFor(role: TracedRole): Rgba =
  ## Choose how strongly one traced entry is drawn.
  ##   One hue for whole layer, `Ink.Algebra`, screened against every assignable slot.
  ##   Strength alone separates scene's geometry from what frame derived.
  ##     Distinction is foreground and background, not category; reader learns one debug
  ##     colour.
  let base = Ink.Algebra.colour
  case role
  of TracedRole.SceneObject, TracedRole.Ghost: base
  else: base.fade(base.alpha*ALPHA_ALGEBRA_DERIVED)


proc addLattice*(
  meshes: var MeshSet, scratch: var DrawScratch, plane: Multivector, tint: Rgba,
  scale: DrawExtent
) =
  ## Append plane drawn as infinite thing it is: lattice laid across it.
  ##   Reaches as far as fog does and fades out; exactly what `addGrid` lays on ground.
  ##   `radiusOnPlaneFor` answers how much of plane fog leaves, `boundary.frame` which two
  ##   directions span it, `positionAnchor` where to lay lattice from, so lines fall on
  ##   plane's own multiples.
  ##   Silently draws nothing for plane at horizon, or for one further from eye than fog.
  ##     Horizon plane spans no Euclidean directions, and `addObject` already draws whole
  ##     sky for it.
  let
    axes = frame(plane)
    anchor = positionAnchor(plane)
  if axes.isNone or anchor.isNone: return
  let reach = radiusOnPlaneFor(scale.extent_furniture, scale, plane)
  if reach.isNone: return
  let
    radius = reach.get
    size_cell = sizeCellGridFor(radius)
    (first, second) = (axes.get.axis_first, axes.get.axis_second)
  meshes.addGridFamily(
    scratch, scale, tint, radius, size_cell,
    along = first, across = second, origin = anchor.get,
  )
  meshes.addGridFamily(
    scratch, scale, tint, radius, size_cell,
    along = second, across = first, origin = anchor.get,
  )


proc addTraced*(
  meshes: var MeshSet, scratch: var DrawScratch, traced: Traced,
  scale: DrawExtent
): Placement =
  ## Append one recorded multivector, in its true form.
  ##   Finite plane becomes lattice.
  ##   Everything else goes through same `tessellate.addObject` ordinary picture uses.
  ##     For point, line and anything at horizon ordinary drawing *is* true one; only
  ##     plane had stand-in worth replacing.
  let tint = inkFor(traced.role)
  if shape(traced.geometry) == some(Shape.Plane) and not isHorizon(traced.geometry):
    meshes.addLattice(
      scratch, traced.geometry, tint.fade(tint.alpha*ALPHA_ALGEBRA_LATTICE), scale,
    )
    return Placement.Finite
  meshes.addObject(scratch, traced.geometry, tint, scale)


proc addTrace*(
  meshes: var MeshSet, scratch: var DrawScratch, trace: AlgebraTrace,
  scale: DrawExtent
) =
  ## Append everything one frame recorded, in recording order.
  for traced in trace: discard meshes.addTraced(scratch, traced, scale)


proc addFrameTrace*(
  meshes: var MeshSet; scratch: var DrawScratch; trace: var AlgebraTrace; scene: Scene;
  camera: Camera; staged: Option[Preview]; cursor: ScreenPosition; scale: DrawExtent;
  width, height: int
) =
  ## Record everything this frame's geometry rests on, and draw it.
  ##   Both render paths call this one proc: two lists would drift first time either grew
  ##   entry.
  ##   Everything is read from values frame already holds; nothing is re-derived by second
  ##   spelling.
  ##   Does not reach per-candidate meets `picking.rayPlaneHit` forms; see `PROVENANCE.md`.
  ##   `trace` is caller-owned scratch, as `tessellate` takes its own.
  ##     `AlgebraTrace` holds `TRACED_MAX` entries; declaring one here would build them
  ##     all every frame layer was on.
  trace.clear()
  # Read by slot, to `bound`.
  #   `pairs` copies whole scene per live slot on JS backend, and walk to capacity pays
  #   for every empty slot.
  for slot in 0 ..< scene.bound:
    if scene.isAlive(slot) and scene.isVisible(slot):
      trace.record(TracedRole.SceneObject, scene.geometryOf(slot))
  if staged.isSome: trace.record(TracedRole.Ghost, staged.get.geometry)

  # Record what camera itself is, which nothing ever draws.
  #   Where it stands, line it looks along, plane depth is measured against, near clip as
  #   plane.
  let eye = camera.eye
  trace.record(TracedRole.EyePoint, scale.eye_point)
  # Derive camera frame once for layer: its joins are priciest thing here.
  let frame_camera = camera.frame(eye)
  trace.record(TracedRole.SightAxis, frame_camera.axis_sight)
  trace.record(TracedRole.PlaneEye, scale.plane_eye)
  trace.record(TracedRole.PlaneNear, scale.plane_near)
  trace.record(TracedRole.GroundPlane, groundPlane())

  # Record cursor's ray and where it meets working level, what picker and zoom rest on.
  let ray = castRay(camera, eye, frame_camera, width, height, cursor)
  trace.record(TracedRole.CursorRay, ray)
  let met = ray ∨ levelPlaneThrough(toMultivector(camera.target))
  if position(met).isSome: trace.record(TracedRole.CursorHit, met)

  meshes.addTrace(scratch, trace, scale)
