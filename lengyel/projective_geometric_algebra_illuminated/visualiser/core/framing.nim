## Frame whatever is being worked on: point the camera so every selected object is in view.
##
## One rule, applied once a frame by both front-ends rather than at each event, so no path
## that changes the scene has to know the camera exists. What it watches, in order:
##
##   |----------------------|-----------------------------------------------------------|
##   | Staged multivector   | An open edit session's own geometry, whatever is selected.|
##   | Selection            | Every picked object, together.                            |
##   | Neither              | Nothing; the standing offer is withdrawn (`release`).     |
##   |----------------------|-----------------------------------------------------------|
##
## **In view** is `picking.isShownCentrally`: a point inside the centred two thirds of the
## frame, a line or a plane merely crossing it. **Framed** means the camera's target moves
## to the middle of everything finite that was picked, and its orbit distance grows -- only
## if it must, and never shrinks -- until every one of them satisfies that test.
##
## Lives above `picking` rather than inside it because folding a selection needs `Selection`
## and `picking` cannot import it: `selection` imports `marker`, which imports `picking`.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table. The rule used to be written out
## in each of them, which is exactly the kind of duplication that drifts.

{.experimental: "strictFuncs".}

import std/options

import ../../pga
import ./[camera, mesh, picking, scene, selection]



#[ Framing Configuration ]#

const ROUNDS_DISTANCE_FIT* = 8
  ## Halvings run when searching for the least orbit distance that brings a whole selection
  ## into view.
  ##   Eight lands within 1/256 of the bracket, and the bracket is the distance at which
  ##   the selection exactly fills the box, so the residue is a fraction of a percent of
  ##   the spread being framed -- far finer than a reader could see, and each halving costs
  ##   a projection of every selected object.



#[ What Is Being Watched ]#

iterator watched*(
  scene: Scene; picked: Selection; staged: Option[Multivector]
): Multivector =
  ## Walk whatever the camera is being asked to show, in the order stated in this module's
  ## own doc comment.
  ##   An open session's staged geometry stands alone: it is the thing being made, and the
  ##   object it will replace is usually selected beside it, which would frame the edit
  ##   against its own former self.
  ##   Skips slots gone dead since the selection was made -- a selection outlives the
  ##   removal of what it names, and every reader here has to survive that.
  if staged.isSome:
    yield staged.get
  else:
    for position in 0 ..< picked.len:
      let slot = picked.at(position)
      if scene.isAlive(slot): yield scene.geometryOf(slot)


func aimFor*(
  scene: Scene; picked: Selection; staged: Option[Multivector]; scale: DrawExtent
): Option[CameraAim] =
  ## Resolve what the camera is being asked to bring into view, or none where nothing is.
  ##   A pure function of the geometry: see `CameraAim`, whose whole worth is that a caller
  ##   re-offering the same selection every frame offers something that compares equal.
  result = none(CameraAim)
  for m in watched(scene, picked, staged):
    result = result.aimIncluding(m, scale)


func isShownAll*(
  scene: Scene; picked: Selection; staged: Option[Multivector];
  placement: Camera; width, height: int
): bool =
  ## Report whether every watched object is in view at once, each by its own criterion.
  ##   True of nothing at all: a camera asked to show no objects is showing all of them,
  ##   and the callers below never reach here without an aim anyway.
  for m in watched(scene, picked, staged):
    if not isShownCentrally(m, placement, width, height): return false
  true



#[ Where That Puts The Camera ]#

func placementFor*(
  aim: CameraAim; scene: Scene; picked: Selection; staged: Option[Multivector];
  camera: Camera; width, height: int
): CameraPlacement =
  ## Resolve `aim` against the camera as it stands into the placement an ease should end
  ## at: centred on what was picked, and pulled back far enough to show all of it.
  ##   **Target** is the middle of everything finite that was picked, or where the camera
  ##   already looks where nothing finite was.
  ##   **Angles** face the horizon objects, and only where nothing finite was picked.
  ##   Finite framing wins outright because the two can disagree: a star behind the reader
  ##   and a point in front of them have no placement showing both, and a selection with
  ##   something finite in it is overwhelmingly the one a reader is working on. A star
  ##   picked alongside a point may therefore stay out of view; there is no placement that
  ##   would have helped.
  ##   **Distance** never shrinks. A tight selection is not zoomed into -- the reader chose
  ##   that scale, and re-scaling the world on every pick is disorienting in a way that
  ##   panning is not.
  let angles =
    if aim.sphere.isSome or aim.heading.isNone: (camera.azimuth, camera.elevation)
    else: azimuthElevationFor(aim.heading.get)
  var settled = CameraPlacement(
    target: if aim.sphere.isSome: aim.sphere.get.centre else: camera.target,
    distance: camera.distance,
    azimuth: angles[0],
    # Clamped exactly as an orbit drag is: past the pole the camera's own up direction
    #   would run along its sight axis and the frame it derives collapses.
    elevation: clamp(angles[1], -ELEVATION_LIMIT, ELEVATION_LIMIT),
  )
  if aim.sphere.isNone: return settled
  if isShownAll(scene, picked, staged, camera.placed(settled), width, height):
    return settled

  # Bracket with the distance at which the whole sphere fits, then halve into it for the
  #   least that will actually do. The closed form alone would over-dolly: a point at the
  #   middle picked with a line whose support stands a hundred units away needs no
  #   pulling back at all if that line already crosses the frame, and the closed form would
  #   drag its support into the box regardless.
  var
    near = camera.distance
    far = max(
      camera.distance,
      distanceFitting(aim.sphere.get.radius, camera, width, height, INSET_POINT_SHOWN),
    )
  settled.distance = far
  # Sound because the test is monotone in distance: everything converges on the middle of
  #   the frame as the eye pulls back, so a distance that shows the selection is not undone
  #   by a greater one. Where even the bracket fails -- a selection spread wider than the
  #   world may be viewed from, or two stars facing opposite ways -- the bracket stands.
  if not isShownAll(scene, picked, staged, camera.placed(settled), width, height):
    return settled
  for _ in 1 .. ROUNDS_DISTANCE_FIT:
    let middle = 0.5*(near + far)
    settled.distance = middle
    if isShownAll(scene, picked, staged, camera.placed(settled), width, height): far = middle
    else: near = middle
  settled.distance = far
  settled



#[ The Standing Offer ]#

proc offerAim*(
  tween: var CameraTween; camera: Camera; scene: Scene; picked: Selection;
  staged: Option[Multivector]; width, height: int; now, duration: float
) =
  ## Offer the camera whatever is being worked on to look at -- the one call both front-ends
  ## and the storyboard make, once a frame.
  ##   A standing offer, re-made every frame rather than at each event: `aimAt` ignores a
  ##   goal it already holds, so an unchanged scene costs nothing while a moving one -- a
  ##   coefficient being dragged -- reads as one continuous chase.
  ##   Anything that draws nothing, an empty selection included, aims at nothing and
  ##   releases, which is what lets picking the same object again aim at it afresh.
  ##   The `isGoalHeld` guard is not an optimisation to taste: it is what keeps
  ##   `placementFor`'s search off the hot path, since the offer below is re-made on every
  ##   frame a selection stands and the answer would be discarded on all but the first.
  let aim = aimFor(scene, picked, staged, camera.drawExtentFor(height))
  if aim.isNone:
    tween.release()
    return
  if tween.isGoalHeld(aim.get): return
  tween.aimAt(
    camera, aim.get,
    placementFor(aim.get, scene, picked, staged, camera, width, height),
    now, duration,
  )


proc offerAimAt*(
  tween: var CameraTween; camera: Camera; m: Multivector;
  width, height: int; now, duration: float
) =
  ## Offer the camera one object, outside any scene -- for the storyboard, whose captures
  ## aim at a step's own derived multivector before it is anything a selection could name.
  ##   Goes through the very same rule, so a captured frame and an interactive one agree
  ##   on where an object is worth looking from.
  ##   The empty scene and selection below are never read -- a staged multivector stands
  ##   alone, so `watched` returns before it reaches either -- and they cost one zeroed
  ##   `Scene` per capture, which is a storyboard's own cost and not a frame loop's.
  var alone: Scene
  offerAim(tween, camera, alone, Selection(), some(m), width, height, now, duration)
