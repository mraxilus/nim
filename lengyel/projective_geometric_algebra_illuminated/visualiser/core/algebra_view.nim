## Draw the multivectors a frame computed, each as the thing it actually is.
##
## The ordinary picture draws stand-ins: a plane becomes a disc of fixed radius, because an
## infinite surface filling the screen would bury everything else, and a line becomes a
## ribbon so it has a width at all. Those are good pictures and bad statements. This layer
## is the statement -- switched on when a reader wants to see the algebra rather than the
## illustration of it, the way a game engine draws its physics world in wireframe over the
## art.
##
## Two things change when it is on:
##
##   |------------------|------------------------|-----------------------------------|
##   | Object           | Ordinary picture       | Here                              |
##   |------------------|------------------------|-----------------------------------|
##   | Finite plane     | disc at `EXTENT_PLANE` | lattice over the whole plane      |
##   | Everything else  | as drawn               | as drawn, in `Ink.Algebra`        |
##   |------------------|------------------------|-----------------------------------|
##
## The lattice is how this project already draws an infinite plane: the ground grid *is* a
## plane at `z = 0`, laid as far as the fog reaches and faded out rather than stopped at an
## edge. Drawing every plane that way says "this goes on" in a vocabulary the reader has
## already learnt from the ground, instead of inventing a second one.
##
## And it draws more than the scene: the line joining eye to target, the plane the near clip
## really is, the ray under the cursor and where it meets the level being worked at. Each is
## geometry a frame genuinely derived and never showed anyone. See `algebra_trace`.
##
## **What is recorded is decided here, once.** `addFrameTrace` is the whole layer's entry
## point and both render paths call it rather than each listing what to record: an entry
## reaching one picture and missing the other is exactly the fault this layer exists to
## expose, and it must not be one the layer can itself have.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/options

import ../../pga
import ./[algebra_trace, boundary, camera, mesh, objects, picking, scene, tessellate]



#[ Debug Layer Configuration ]#

const
  ALPHA_ALGEBRA_LATTICE* = 0.55
    ## How strongly a traced plane's own lattice is drawn, against the full-strength ink a
    ## traced point or line takes. Below them deliberately: a plane covers the whole view
    ## once it is drawn infinite, and at full strength one would hide every other thing the
    ## trace is trying to show at the same time.
  ALPHA_ALGEBRA_DERIVED* = 0.75
    ## How strongly the *derived* geometry is drawn -- the sight axis, the eye and near
    ## planes, the cursor's ray. Under the scene's own entries, since a reader opens this
    ## layer asking about their objects first and the camera's own workings second.



#[ Drawing ]#

func inkFor(role: TracedRole): Rgba =
  ## Choose how strongly one traced entry is drawn.
  ##   One hue for the whole layer -- `Ink.Algebra`, screened against every assignable slot
  ##   so nothing here can be mistaken for an object a reader built -- and strength alone
  ##   separates the scene's own geometry from what the frame derived around it. Strength
  ##   rather than a second hue because the distinction is foreground and background, not
  ##   category, and a reader should not have to learn two debug colours.
  let base = Ink.Algebra.colour
  case role
  of TracedRole.SceneObject, TracedRole.Ghost: base
  else: base.fade(base.alpha*ALPHA_ALGEBRA_DERIVED)


proc addLattice*(
  meshes: var MeshSet; scratch: var DrawScratch; plane: Multivector; tint: Rgba;
  scale: DrawExtent
) =
  ## Append a plane drawn as the infinite thing it is: a lattice laid across it, reaching as
  ## far as the fog does and faded out rather than stopped at an edge.
  ##   Exactly what `addGrid` lays on the ground, given a different plane -- the ground is
  ##   one of these, at `z = 0`. `radiusOnPlaneFor` answers how much of this plane the fog
  ##   leaves, `boundary.frame` answers which two directions span it, and
  ##   `positionAnchor` answers where to lay the lattice from, so the lines fall on that
  ##   plane's own multiples rather than on a lattice dragged around by the camera.
  ##   Silently draws nothing for a plane at the horizon -- it spans no Euclidean
  ##   directions, and the whole sky is what `addObject` already draws for it -- or for one
  ##   the eye stands further from than the fog reaches.
  let
    axes = frame(plane)
    anchor = positionAnchor(plane)
  if axes.isNone or anchor.isNone: return
  let reach = radiusOnPlaneFor(scale.extent_furniture, scale, plane)
  if reach.isNone: return
  let
    radius = reach.get
    size_cell = sizeCellGridFor(radius)
    fog = fogFurnitureFor(scale.extent_furniture)
    (first, second) = (axes.get.axis_first, axes.get.axis_second)
  meshes.addGridFamily(
    scratch, scale, tint, fog, radius, size_cell,
    along = first, across = second, origin = anchor.get,
  )
  meshes.addGridFamily(
    scratch, scale, tint, fog, radius, size_cell,
    along = second, across = first, origin = anchor.get,
  )


proc addTraced*(
  meshes: var MeshSet; scratch: var DrawScratch; traced: Traced;
  scale: DrawExtent
): Placement =
  ## Append one recorded multivector, in its true form.
  ##   A finite plane becomes its lattice; everything else goes through the very same
  ##   `tessellate.addObject` the ordinary picture uses, because for a point, a line, and
  ##   anything at the horizon the ordinary drawing *is* the true one -- a star stands where
  ##   the direction points, a line runs to both its vanishing points, the sky is the sky.
  ##   Only the plane had a stand-in worth replacing.
  let tint = inkFor(traced.role)
  if shape(traced.geometry) == some(Shape.Plane) and not isHorizon(traced.geometry):
    meshes.addLattice(
      scratch, traced.geometry, tint.fade(tint.alpha*ALPHA_ALGEBRA_LATTICE), scale,
    )
    return Placement.Finite
  meshes.addObject(scratch, traced.geometry, tint, scale)


proc addTrace*(
  meshes: var MeshSet; scratch: var DrawScratch; trace: AlgebraTrace;
  scale: DrawExtent
) =
  ## Append everything one frame recorded, in the order it was recorded.
  for traced in trace: discard meshes.addTraced(scratch, traced, scale)


proc addFrameTrace*(
  meshes: var MeshSet; scratch: var DrawScratch; scene: Scene; camera: Camera;
  staged: Option[Preview]; cursor: ScreenPosition; scale: DrawExtent; width, height: int
) =
  ## Record everything this frame's geometry rests on, and draw it.
  ##   **Both render paths call this one proc**, rather than each assembling its own list:
  ##   the two would agree today and drift the first time either grew an entry, and an
  ##   entry silently missing from one path is precisely the fault this layer exists to
  ##   make visible. Everything here is read from values the frame already holds -- no
  ##   collector is threaded through the library's own pure funcs, and nothing is
  ##   re-derived by a second spelling that could disagree with the first.
  ##   What it does not reach is the per-candidate meets `picking.rayPlaneHit` forms
  ##   inside `pickNearest`; see `PROVENANCE.md`'s debug-layer note for why.
  var trace: AlgebraTrace
  trace.clear()
  for slot, item in scene.pairs:
    if item.isVisible: trace.record(TracedRole.SceneObject, item.geometry)
  if staged.isSome: trace.record(TracedRole.Ghost, staged.get.geometry)

  # What the camera itself is, which nothing ever draws: where it stands, the line it
  #   looks along, the plane depth is measured against, and the near clip as a plane
  #   rather than as a number in a matrix.
  let eye = camera.eye
  trace.record(TracedRole.EyePoint, scale.eye_point)
  # One `camera.frame` for the layer: its joins are the priciest thing this block asks
  #   for, and it was run twice in two statements for the same eye.
  let frame_camera = camera.frame(eye)
  trace.record(TracedRole.SightAxis, frame_camera.axis_sight)
  trace.record(TracedRole.PlaneEye, scale.plane_eye)
  trace.record(TracedRole.PlaneNear, scale.plane_near)
  trace.record(TracedRole.GroundPlane, groundPlane())

  # The cursor's own ray and where it meets the level being worked at -- what the picker
  #   and the zoom both rest on, and the pair a reader most wants to see.
  let ray = castRay(camera, eye, frame_camera, width, height, cursor)
  trace.record(TracedRole.CursorRay, ray)
  let met = ray ∨ levelPlaneThrough(toMultivector(camera.target))
  if position(met).isSome: trace.record(TracedRole.CursorHit, met)

  meshes.addTrace(scratch, trace, scale)
