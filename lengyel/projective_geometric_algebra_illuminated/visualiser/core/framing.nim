## Frame whatever is being worked on: point the camera so every selected object is in view.
##
## One rule, applied once a frame by both front-ends rather than at each event, so no path
## that changes the scene has to know the camera exists. What it watches, in order:
##
##   |----------------------|-----------------------------------------------------------|
##   | Staged preview       | The thing being made, whatever is selected -- an open     |
##   |                      |   edit session's geometry alone, or an apply picker's own |
##   |                      |   answer together with the operands it names.             |
##   | Selection            | Every picked object, together.                            |
##   | Neither              | Nothing; the standing offer is withdrawn (`release`).     |
##   |----------------------|-----------------------------------------------------------|
##
## **In view** is `picking.isShownCentrally`: a point's dot and a finite plane's whole disc
## inside the centred box, a line merely crossing it. **Framed** means the camera's target
## moves to the middle of everything finite that was picked, and its orbit distance grows --
## only if it must, and never shrinks -- until every one of them satisfies that test.
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
import ./[camera, mesh, objects, picking, scene, selection]



#[ Framing Configuration ]#

const
  ROUNDS_DISTANCE_FIT* = 8
    ## Halvings run when searching for the least orbit distance that brings a whole
    ## selection into view.
    ##   Eight lands within 1/256 of the bracket, and the bracket is the distance at which
    ##   the selection exactly fills the box, so the residue is a fraction of a percent of
    ##   the spread being framed -- far finer than a reader could see, and each halving
    ##   costs a projection of every selected object.
  STEPS_PLACEMENT_LEAST* = 12
    ## Fractions of the full framing move tried, evenly spaced, when cutting it back to
    ## the least that already shows the selection. Coarse on purpose: they only have to
    ## bracket the crossing, which the halvings below then close on, and each step costs a
    ## projection of every selected object.
  ROUNDS_PLACEMENT_LEAST* = 5
    ## Halvings run inside the bracketed step. Five puts the answer within 1/384 of the
    ## full move -- under a pixel of any pan or turn made here, so the selection lands on
    ## the edge of the box rather than measurably inside it.



#[ What Is Being Watched ]#

iterator watched*(
  scene: Scene; picked: Selection; staged: Option[Preview]
): (Multivector, Option[Position]) =
  ## Walk whatever the camera is being asked to show, in the order stated in this module's
  ## own doc comment, each alongside the anchor its own disc is drawn about where it has
  ## one -- a plane's stored creation anchor; see `scene.creationAnchor`.
  ##   Something staged takes the whole offer: it is the thing being made, and the
  ##   selection standing beside it is not what the reader is looking at.
  ##   **What goes with it depends on where it came from**, which is what `Preview.operands`
  ##   is for. A preview named its operands, so they are framed *with* it: an operation's
  ##   result judged without the objects it was applied to is half a picture. An open edit
  ##   session names none, and must not -- its staged geometry *replaces* the object
  ##   selected beside it, and framing both would frame the edit against its own former
  ##   self.
  ##   Skips slots gone dead since the selection was made -- a selection outlives the
  ##   removal of what it names, and every reader here has to survive that. An operand can
  ##   go the same way, with a picker left open across a delete.
  if staged.isSome:
    yield (staged.get.geometry, staged.get.anchor)
    if staged.get.operands.isSome:
      let (first, second) = staged.get.operands.get
      # A unary operation names its own operand twice, and it is yielded **once**. It used
      #   to be yielded twice on the grounds that framing the same thing twice costs a
      #   projection and changes no answer -- true of a bound, which cannot be widened by a
      #   ball it already holds, but not of a middle, which a place folded twice would pull
      #   toward. The camera turns about that middle, so the duplicate has to go here
      #   rather than be tolerated downstream.
      for slot in (if first == second: @[first] else: @[first, second]):
        if scene.isAlive(slot):
          yield (scene.geometryOf(slot), scene.anchorOverrideAt(slot))
  else:
    for position in 0 ..< picked.len:
      let slot = picked.at(position)
      if scene.isAlive(slot):
        yield (scene.geometryOf(slot), scene.anchorOverrideAt(slot))


func aimFor*(
  scene: Scene; picked: Selection; staged: Option[Preview]; scale: DrawExtent
): Option[CameraAim] =
  ## Resolve what the camera is being asked to bring into view, or none where nothing is.
  ##   A pure function of the geometry: see `CameraAim`, whose whole worth is that a caller
  ##   re-offering the same selection every frame offers something that compares equal.
  result = none(CameraAim)
  for (m, anchor) in watched(scene, picked, staged):
    result = result.aimIncluding(m, scale, anchor)


func isShownAll*(
  scene: Scene; picked: Selection; staged: Option[Preview];
  placement: Camera; width, height: int
): bool =
  ## Report whether every watched object is in view at once, each by its own criterion.
  ##   True of nothing at all: a camera asked to show no objects is showing all of them,
  ##   and the callers below never reach here without an aim anyway.
  for (m, anchor) in watched(scene, picked, staged):
    if not isShownCentrally(m, placement, width, height, anchor): return false
  true



#[ Where That Puts The Camera ]#

func placementFor*(
  aim: CameraAim; scene: Scene; picked: Selection; staged: Option[Preview];
  camera: Camera; width, height: int
): CameraPlacement =
  ## Resolve `aim` against the camera as it stands into the placement an ease should end
  ## at: the **least movement** -- pan, zoom and orbit taken together -- that puts every
  ## picked object in view. Not at all where they all already are.
  ##   The full move it is cut back from: **target** to the middle of everything finite
  ##   that was picked, **angles** facing the horizon objects only where nothing finite
  ##   was, **distance** pulled back only as far as fitting demands and never in. Orbit is
  ##   preferred *against* by construction, not by weighing: a finite selection's full move
  ##   carries no turn at all, so no fraction of it does either, and a horizon-only
  ##   selection's move is a turn because pan and zoom cannot bring a star into view.
  ##   Finite framing wins outright over facing a star because the two can disagree: a
  ##   star behind the reader and a point in front of them have no placement showing both,
  ##   and a selection with something finite in it is overwhelmingly the one a reader is
  ##   working on. A star picked alongside a point may therefore stay out of view; there
  ##   is no placement that would have helped.
  # Everything already in view costs no *fitting* movement: the distance and the orbit are
  #   left exactly as the reader set them. Judged where the camera *is*, not at the centred
  #   placement -- judging there was the bug that pulled the view about on every pick of
  #   something already plainly visible.
  #   **The target still comes to the middle of what was picked.** Turning about a point
  #   is what an orbit is, and a reader who picks an object and turns means to turn about
  #   *it*; leaving the target where it was swings the picked object around the screen
  #   instead. This is not the old bug in new clothes: nothing about the reader's own
  #   framing moves, and the aim compares equal from the next frame on, so the ease runs
  #   once for the pick and never re-arms -- see `CameraAim` and `CameraTween.abandon`.
  if isShownAll(scene, picked, staged, camera, width, height):
    var held = camera.placementOf
    if aim.centroid.isSome: held.target = aim.centroid.get
    return held

  let angles =
    if aim.sphere.isSome or aim.heading.isNone: (camera.azimuth, camera.elevation)
    else: azimuthElevationFor(aim.heading.get)
  var settled = CameraPlacement(
    # The middle of what was picked, not the middle of the bound holding it: a bound's
    #   centre sits whereever enclosing everything put it, which is not where a reader
    #   pointing at those objects is looking. The bound still decides the *distance*.
    target: if aim.centroid.isSome: aim.centroid.get else: camera.target,
    distance: camera.distance,
    azimuth: angles[0],
    # Clamped exactly as an orbit drag is: past the pole the camera's own up direction
    #   would run along its sight axis and the frame it derives collapses.
    elevation: clamp(angles[1], -ELEVATION_LIMIT, ELEVATION_LIMIT),
  )
  if aim.sphere.isSome and
      not isShownAll(scene, picked, staged, camera.placed(settled), width, height):
    # Bracket with the distance at which the whole sphere fits, then halve into it for the
    #   least that will actually do. The closed form alone would over-dolly: a point at
    #   the middle picked with a line whose support stands a hundred units away needs no
    #   pulling back at all if that line already crosses the frame, and the closed form
    #   would drag its support into the box regardless. It over-dollies for a plane too,
    #   and by a lot: the sphere it solves holds the disc from every side, while the disc
    #   itself is flat and, seen at an angle, needs far less room than that.
    var
      near = camera.distance
      far = max(
        camera.distance,
        distanceFitting(aim.sphere.get.radius, camera, width, height, INSET_POINT_SHOWN),
      )
    settled.distance = far
    # Sound because the test is monotone in distance: everything converges on the middle
    #   of the frame as the eye pulls back, so a distance that shows the selection is not
    #   undone by a greater one.
    if isShownAll(scene, picked, staged, camera.placed(settled), width, height):
      for _ in 1 .. ROUNDS_DISTANCE_FIT:
        let middle = 0.5*(near + far)
        settled.distance = middle
        if isShownAll(scene, picked, staged, camera.placed(settled), width, height):
          far = middle
        else: near = middle
      settled.distance = far

  # Where even the full move shows nothing -- a selection spread wider than the world may
  #   be viewed from, or two stars facing opposite ways -- it stands whole rather than a
  #   wrong answer being reported as a right one.
  if not isShownAll(scene, picked, staged, camera.placed(settled), width, height):
    return settled

  # Cut the whole move back to the least fraction of itself that already shows everything,
  #   searched along the very path the ease travels (`toward`, geometric distance
  #   included) so what remains reads as the same movement stopped early. Each candidate
  #   is verified with the full test at its own trial placement, so the interaction
  #   between a partial pan and a partial zoom -- the fitted distance was solved at the
  #   *centred* target -- cannot admit a fraction that fails; the step-then-halve
  #   first-crossing shape is what handles the path not being strictly monotone.
  # Started from where the camera stands **but already centred**, so the fraction searched
  #   over is a fraction of the zoom and the turn alone. The re-centring is not a
  #   concession to fitting and is not cut back with it: were it in the path, the search
  #   would find that a fraction of nothing already shows everything and quietly drop the
  #   very move this is here to make.
  var start = camera.placementOf
  start.target = settled.target
  var (lower, upper) = (0.0, 1.0)
  for step in 1 .. STEPS_PLACEMENT_LEAST:
    let fraction = float(step)/float(STEPS_PLACEMENT_LEAST)
    if isShownAll(
      scene, picked, staged, camera.placed(start.toward(settled, fraction)), width, height
    ):
      (lower, upper) = (float(step - 1)/float(STEPS_PLACEMENT_LEAST), fraction)
      break
  for _ in 1 .. ROUNDS_PLACEMENT_LEAST:
    let middle = 0.5*(lower + upper)
    if isShownAll(
      scene, picked, staged, camera.placed(start.toward(settled, middle)), width, height
    ):
      upper = middle
    else: lower = middle
  start.toward(settled, upper)



#[ The Standing Offer ]#

proc offerAim*(
  tween: var CameraTween; camera: Camera; scene: Scene; picked: Selection;
  staged: Option[Preview]; width, height: int; now, duration: float
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
  ##   The empty scene and selection below are never read -- `previewStaging` names no
  ##   operands, so `watched` yields the one object and stops before reaching either -- and
  ##   they cost one zeroed `Scene` per capture, which is a storyboard's own cost and not a
  ##   frame loop's.
  var alone: Scene
  offerAim(
    tween, camera, alone, Selection(), some(previewStaging(m)),
    width, height, now, duration,
  )
