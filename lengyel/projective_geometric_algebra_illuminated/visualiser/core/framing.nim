## Frame whatever is being worked on: point camera so every selected object is in view.
##
## One rule, applied once per frame by both front-ends rather than at each event, so no
## path changing scene has to know camera exists. What it watches, in order:
##
##   |----------------------|-----------------------------------------------------------|
##   | Staged preview       | Thing being made, whatever is selected: open edit         |
##   |                      |   session's geometry alone, or apply picker's answer      |
##   |                      |   together with operands it names.                        |
##   | Selection            | Every picked object, together.                            |
##   | Neither              | Nothing; standing offer is withdrawn (`release`).         |
##   |----------------------|-----------------------------------------------------------|
##
## *In view* is `picking.isShownCentrally`: point's dot and finite plane's whole disc
## inside centred box, line merely crossing it.
## *Framed* means camera's target moves to middle of everything finite picked, and orbit
## distance grows until every one satisfies that test.
##   Grows only if it must, never shrinks.
## Lives above `picking` because folding selection needs `Selection`, and `picking` cannot
## import it: `selection` imports `marker`, which imports `picking`.
##
## Shared by desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render paths.
##   Rule was once written out in each, duplication that drifted.

{.experimental: "strictFuncs".}

import std/options

import ../../pga
import ./[boundary, camera, tessellate, picking, scene, selection]



#[ Framing Configuration ]#

const
  ROUNDS_DISTANCE_FIT* = 8
    ## Fix halvings run when searching least orbit distance bringing selection into view.
    ##   Eight lands within 1/256 of bracket, itself distance at which selection exactly
    ##   fills box, so residue is fraction of percent of spread framed.
    ##   Finer than reader sees; each halving costs projection of every selected object.
  STEPS_PLACEMENT_LEAST* = 12
    ## Fix fractions of full framing move tried, evenly spaced, when cutting it back.
    ##   Coarse on purpose: they only bracket crossing, which halvings then close on, and
    ##   each step costs projection of every selected object.
  ROUNDS_PLACEMENT_LEAST* = 5
    ## Fix halvings run inside bracketed step.
    ##   Five puts answer within 1/384 of full move, under pixel of any pan or turn here.



#[ What Is Being Watched ]#

iterator watched*(
  scene: Scene, picked: Selection, staged: Option[Preview]
): (Multivector, Option[Position]) =
  ## Walk whatever camera is asked to show, in order module doc states.
  ##   Each comes beside anchor its disc is drawn about where it has one: plane's creation
  ##   anchor, see `scene.creationAnchor`.
  ##   Something staged takes whole offer: it is thing being made, and selection beside it
  ##   is not what reader looks at.
  ##   What goes with it depends on where it came from, which `Preview.operands` says.
  ##     Preview named operands, so they are framed *with* it: result judged without
  ##     objects it was applied to is half picture.
  ##     Open edit session names none, and must not: its staged geometry *replaces* object
  ##     selected beside it.
  ##   Skips slots gone dead since selection was made.
  ##     Selection outlives removal of what it names, and operand can go same way with
  ##     picker left open across delete.
  if staged.isSome:
    yield (staged.get.geometry, staged.get.anchor)
    if staged.get.operands.isSome:
      let (first, second) = staged.get.operands.get
      # Yield unary operation's operand once.
      #   Bound cannot be widened by ball it holds, but middle folded twice is pulled
      #   toward, and camera turns about that middle.
      for slot in (if first == second: @[first] else: @[first, second]):
        if scene.isAlive(slot):
          yield (scene.geometryOf(slot), scene.anchorOverrideAt(slot))
  else:
    for position in 0 ..< picked.len:
      let slot = picked.at(position)
      if scene.isAlive(slot):
        yield (scene.geometryOf(slot), scene.anchorOverrideAt(slot))


func reachOfPlaced(placed: Placed): float =
  ## Measure how far one placed object stands from world origin, disc's reach included.
  ##   Zero for horizon kinds and nothing: neither has place to clip.
  case placed.kind
  of PlacedKind.PointAt, PlacedKind.LineThrough:
    norm(placed.at - Position(x: 0, y: 0, z: 0))
  of PlacedKind.PlaneOn:
    norm(placed.at - Position(x: 0, y: 0, z: 0)) + EXTENT_PLANE_F
  else: 0.0


func reachOf*(placed: openArray[Placed], scene: Scene): float =
  ## Measure how far scene's farthest visible finite object stands from origin.
  ##   For `Camera.reach_scene`, from placements caller already holds; browser path.
  ##   Sibling of `reachOf(scene)`, which places for itself.
  result = 0.0
  for slot in 0 ..< scene.bound:
    if not scene.isAlive(slot) or not scene.isVisible(slot): continue
    result = max(result, reachOfPlaced(placed[slot]))


proc reachOf*(scene: Scene): float =
  ## Measure how far scene's farthest visible finite object stands from origin.
  ##   For `Camera.reach_scene` on path holding no placements; desktop, once per scene
  ##   change. Sibling of `reachOf(placed, scene)`.
  result = 0.0
  for slot, item in scene.pairs:
    if not item.isVisible: continue
    result = max(result, reachOfPlaced(placeObject(item.geometry, item.anchorOverride)))


func aimFor*(
  scene: Scene, picked: Selection, staged: Option[Preview], scale: DrawExtent
): Option[CameraAim] =
  ## Resolve what camera is asked to bring into view, or none where nothing is.
  ##   Pure function of geometry: see `CameraAim`, whose worth is that caller re-offering
  ##   same selection every frame offers something comparing equal.
  result = none(CameraAim)
  for (m, anchor) in watched(scene, picked, staged):
    result = result.aimIncluding(m, scale, anchor)


func isShownAll*(
  scene: Scene; picked: Selection; staged: Option[Preview];
  placement: Camera; width, height: int
): bool =
  ## Report whether every watched object is in view at once, each by own criterion.
  ##   True of nothing at all: camera asked to show no objects shows all of them.
  for (m, anchor) in watched(scene, picked, staged):
    if not isShownCentrally(m, placement, width, height, anchor): return false
  true



#[ Resolving Placement ]#

func placementFor*(
  aim: CameraAim; scene: Scene; picked: Selection; staged: Option[Preview];
  camera: Camera; width, height: int
): CameraPlacement =
  ## Resolve `aim` against camera as it stands into placement ease should end at.
  ##   Least movement, pan, zoom and orbit together, putting every picked object in view;
  ##   none at all where they all already are.
  ##   Full move it is cut back from: target to middle of everything finite picked, angles
  ##   facing horizon objects only where nothing finite was, distance pulled back only as
  ##   far as fitting demands and never in.
  ##     Orbit is preferred *against* by construction: finite selection's full move
  ##     carries no turn, so no fraction of it does; horizon-only selection's move is turn
  ##     because pan and zoom cannot bring star into view.
  ##   Finite framing wins outright over facing star, since two can disagree.
  ##     Star behind reader and point in front have no placement showing both, and
  ##     selection with something finite is one reader works on.
  ##     Star picked beside point may stay out of view.
  # Charge nothing for fitting where everything is already in view, judged where camera is.
  #   Judging at centred placement pulled view about on every pick of something plainly
  #   visible.
  #   Target still comes to middle of what was picked: reader who picks object and turns
  #   means to turn about *it*.
  #   Aim compares equal from next frame on, so ease runs once per pick; see `CameraAim`
  #   and `CameraTween.abandon`.
  if isShownAll(scene, picked, staged, camera, width, height):
    var held = camera.placementOf
    if aim.centroid.isSome: held.target = aim.centroid.get
    return held

  let angles =
    if aim.sphere.isSome or aim.heading.isNone: (camera.azimuth, camera.elevation)
    else: azimuthElevationFor(aim.heading.get)
  var settled = CameraPlacement(
    # Aim at middle of what was picked, not middle of bound holding it.
    #   Bound still decides *distance*.
    target: if aim.centroid.isSome: aim.centroid.get else: camera.target,
    distance: camera.distance,
    azimuth: angles[0],
    # Clamp as orbit drag is.
    #   Past pole camera's up runs along sight axis and frame collapses.
    elevation: clamp(angles[1], -ELEVATION_LIMIT, ELEVATION_LIMIT),
  )
  if aim.sphere.isSome and
      not isShownAll(scene, picked, staged, camera.placed(settled), width, height):
    # Bracket with distance at which whole sphere fits, then halve into it for least.
    #   Closed form alone over-dollies: line whose support stands hundred units away needs
    #   no pulling back if it already crosses frame, and flat disc seen at angle needs far
    #   less room than sphere holding it from every side.
    var
      near = camera.distance
      far = max(
        camera.distance,
        distanceFitting(aim.sphere.get.radius, camera, width, height, INSET_POINT_SHOWN),
      )
    settled.distance = far
    # Halve soundly because test is monotone in distance.
    #   Everything converges on middle of frame as eye pulls back.
    if isShownAll(scene, picked, staged, camera.placed(settled), width, height):
      for _ in 1 .. ROUNDS_DISTANCE_FIT:
        let middle = 0.5*(near + far)
        settled.distance = middle
        if isShownAll(scene, picked, staged, camera.placed(settled), width, height):
          far = middle
        else: near = middle
      settled.distance = far

  # Stand whole where even full move shows nothing.
  #   Selection wider than world may be viewed from, or two stars facing opposite ways.
  if not isShownAll(scene, picked, staged, camera.placed(settled), width, height):
    return settled

  # Cut whole move back to least fraction already showing everything.
  #   Searched along path ease travels (`toward`), each candidate verified at own trial
  #   placement so partial pan and partial zoom cannot admit fraction that fails.
  #   Step-then-halve handles path not being strictly monotone.
  # Start from where camera stands but already centred.
  #   Re-centring is not concession to fitting, and in path search would find fraction of
  #   nothing shows everything.
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



#[ Standing Offer ]#

func offerAim*(
  tween: var CameraTween; camera: Camera; scene: Scene; picked: Selection;
  staged: Option[Preview]; scale: DrawExtent; width, height: int; now, duration: float
) =
  ## Offer camera whatever is being worked on to look at.
  ##   One call both front-ends and storyboard make, once per frame.
  ##   Standing offer, re-made every frame: `aimAt` ignores goal it already holds, so
  ##   unchanged scene costs nothing while moving one (coefficient being dragged) reads as
  ##   one continuous chase.
  ##   Anything drawing nothing, empty selection included, aims at nothing and releases,
  ##   which lets picking same object again aim at it afresh.
  ##   `isGoalHeld` guard keeps `placementFor`'s search off hot path: offer is re-made
  ##   every frame selection stands.
  # Take caller's extent, not second derivation.
  #   Building another here ran `algebraFilled` and `camera.frame`'s joins twice per frame.
  let aim = aimFor(scene, picked, staged, scale)
  if aim.isNone:
    tween.release()
    return
  if tween.isGoalHeld(aim.get): return
  tween.aimAt(
    camera, aim.get,
    placementFor(aim.get, scene, picked, staged, camera, width, height),
    now, duration,
  )


func offerAimAt*(
  tween: var CameraTween; camera: Camera; m: Multivector;
  width, height: int; now, duration: float
) =
  ## Offer camera one object, outside any scene.
  ##   For storyboard, whose captures aim at step's derived multivector before selection
  ##   could name it.
  ##   Same rule, so captured frame and interactive one agree on where object is worth
  ##   looking from.
  ##   Empty scene and selection are never read: `previewStaging` names no operands, so
  ##   `watched` yields one object and stops.
  ##     Cost is one zeroed `Scene` per capture, storyboard's rather than frame loop's.
  var alone: Scene
  offerAim(
    tween, camera, alone, Selection(), some(previewStaging(m)),
    camera.drawExtentFor(height), width, height, now, duration,
  )
