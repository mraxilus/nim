## Hit-test scene items against the cursor, so a mouse action knows which object it touched.
##
## Point and line are tested in screen space, by pixel distance: that answers where a pixel
## is, a rasterisation question, not an algebraic one, exactly as the camera's own clip
## volume is written out directly rather than derived. A line's own endpoints are computed
## the same way `mesh.addLine` draws them -- `radius_horizon` backward from support, the
## same radius forward from the eye instead -- so a hit always agrees with what is drawn.
##
## Plane is tested differently, through the algebra rather than around it: cursor's own
## sight ray is built as an RGA line (eye ∧ heading) and met with the plane directly,
## `ray ∨ plane`, giving the exact point struck. Screen-space quad-projection was tried first
## and discarded — a corner near the eye sends its projected position to infinity, and the
## point-in-polygon test on that blown-up quad can then accept a cursor nowhere near the
## plane at all. Meeting in 3D has no such singularity nearby: it fails cleanly (ray parallel
## to plane, or the hit behind the eye) instead of failing wrongly.
##
##   |------------|-------------------------------------------------------------------|
##   | Shape      | Tested against                                                    |
##   |------------|-------------------------------------------------------------------|
##   | Point      | Projected marker, by pixel distance.                              |
##   | Line       | Projected drawn segment, by distance to its nearest point.        |
##   | Plane      | Sight ray met with the plane, by whether that point falls inside  |
##   |            |   the drawn quad, and by distance from eye if it does.            |
##   |------------|-------------------------------------------------------------------|
##
## A point wins a tie over a line, and a line over a plane: the smaller target should not
## be swallowed by a larger one drawn behind or through it.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options]

import ../../pga
import ./[camera, mesh, objects, scene]



#[ Picking Configuration ]#

const
  RADIUS_PICK_POINT* = 34.0
    ## Bound how far, in pixels, cursor may sit from a point's marker and still hit it.
    ##   Raised 14 -> 20 -> 34 across two rounds on reported difficulty selecting points
    ##   and lines -- both drawn thin (a marker a few pixels across, a one-pixel-wide
    ##   segment), so a pick radius close to the mark itself left little room for cursor
    ##   imprecision or a fingertip's own contact area on touch (a real fingertip's
    ##   contact patch is roughly this wide at typical phone screen density, well past
    ##   what the first widening left room for). The shape priority below (point beats
    ##   line beats plane) is what keeps a more generous radius from misfiring where
    ##   targets overlap on screen, rather than a tight radius doing that job instead --
    ##   confirmed still exactly in effect (`consider`'s own priority-then-distance
    ##   ordering, untouched) before widening further a second time.
  RADIUS_PICK_LINE* = 24.0
    ## Bound how far, in pixels, cursor may sit from a line's drawn segment and still hit
    ## it; see `RADIUS_PICK_POINT`'s own doc comment for why both were widened together,
    ## twice now (9 -> 14 -> 24).


#[ Aim Configuration ]#

const
  FRACTION_VIEW_CENTRED* = 2.0/3.0
    ## Fraction of the frame, across and down alike, that counts as being looked at. The
    ## box is centred, so it runs from a sixth of the way in to five sixths.
    ##   Why a box at all rather than the whole frame: an object clinging to the very edge
    ##   is on screen without being what the view is about, and the marker ringing it is
    ##   half off-frame. Why not the exact centre, which is what the camera used to move
    ##   to: an object the reader can already see perfectly well does not justify swinging
    ##   the whole view, and doing it anyway is the lurch this constant exists to stop.
  STEPS_AIM_LEAST* = 12
    ## Fractions of a full aim tried, evenly spaced, before the search gives up and lets
    ## the aim stand whole. Coarse on purpose: it only has to bracket the crossing, which
    ## the halvings below then close on, and each step costs a projection of the object.
  ROUNDS_AIM_LEAST* = 5
    ## Halvings run inside the bracketed step. Five puts the answer within 1/384 of a full
    ## aim -- under a pixel of the pan any camera here makes, so the object lands on the
    ## edge of the box rather than measurably inside it.



#[ Type Definitions ]#

type ScreenPosition* = object ## Hold projected position, in window pixels, y downward.
  x*, y*: float ## Pixel coordinates.
  depth*: float ## View-space depth; positive and smaller is nearer the eye.


func towards*(start, finish: ScreenPosition; fraction: float): ScreenPosition =
  ## Step `fraction` of the way from `start` to `finish`, along the screen.
  ##   Returns `finish` itself at a fraction of 1 rather than computing
  ##   `start + 1.0*(finish - start)`, which is the same point in arithmetic and not
  ##   always the same bits: an overlay that shortens a segment for an animation has to
  ##   land on exactly the segment it drew before the animation existed, or every frame
  ##   the animation is *not* running moves by a rounding step.
  if fraction >= 1.0: return finish
  ScreenPosition(
    x: start.x + fraction*(finish.x - start.x),
    y: start.y + fraction*(finish.y - start.y),
    depth: start.depth + fraction*(finish.depth - start.depth),
  )



#[ Screen Projection ]#

func projectToScreen*(
  view_projection: Matrix4; width, height: int; position: Position
): ScreenPosition =
  ## Project world position through clip space onto window pixels.
  var clip: array[4, float]
  let coordinates = [position.x, position.y, position.z, 1.0]
  for row in 0 .. 3:
    for column in 0 .. 3:
      clip[row] += float(view_projection.at(row, column)) * coordinates[column]

  let (ndc_x, ndc_y) = (clip[0]/clip[3], clip[1]/clip[3])
  ScreenPosition(
    x: (ndc_x*0.5 + 0.5) * float(width),
    y: (1.0 - (ndc_y*0.5 + 0.5)) * float(height),
    depth: clip[3],
  )


func isInFront*(screen: ScreenPosition): bool = screen.depth > 1.0e-6
  ## Report whether projected position stands in front of eye, where perspective divide
  ## and every pixel distance measured from it are meaningful.



#[ Segment Test ]#

func clipToEyeSide*(
  tail, head: Position; eye: Position; forward: Direction; distance_near: float
): Option[(Position, Position)] =
  ## Clip segment `tail`-`head` to the half-space at least `distance_near` in front of
  ## `eye` -- the same near-side clip the GPU already performs when actually drawing
  ## the segment, done by hand here since a screen-space hit test needs to divide by
  ## each endpoint's own depth, which the far reach `mesh.addLine` now gives a line can
  ## put at or behind the eye from some camera angles even though the near half of the
  ## very same segment stays plainly on screen.
  ##   Exported for `marker.markerRails`, which flanks exactly the run this clips and
  ##   therefore has to clip it the same way; a marker drawn past the eye plane wraps to
  ##   the opposite side of the screen.
  ##   None where the whole segment lies behind `eye`.
  let
    depth_tail = dot(tail - eye, forward)
    depth_head = dot(head - eye, forward)
  if depth_tail <= distance_near and depth_head <= distance_near: return
  if depth_tail > distance_near and depth_head > distance_near: return some((tail, head))
  let crossing =
    tail + ((distance_near - depth_tail) / (depth_head - depth_tail))*(head - tail)
  if depth_tail > distance_near: some((tail, crossing)) else: some((crossing, head))


func distanceToSegment(point, tail, head: ScreenPosition): float =
  ## Measure pixel distance from `point` to nearest point of segment `tail`-`head`.
  let
    (dx, dy) = (head.x - tail.x, head.y - tail.y)
    length_squared = dx*dx + dy*dy
  if length_squared <= 1.0e-9: return hypot(point.x - tail.x, point.y - tail.y)
  let t =
    clamp(((point.x - tail.x)*dx + (point.y - tail.y)*dy) / length_squared, 0.0, 1.0)
  hypot(point.x - (tail.x + t*dx), point.y - (tail.y + t*dy))



#[ Sight Ray ]#

func castRay(
  camera: Camera; eye: Position; frame: FrameCamera; width, height: int; cursor: ScreenPosition
): Multivector =
  ## Build RGA line running from eye through cursor's own pixel, into the scene.
  ##   Undoes `initMatrixProjection`'s own construction: cursor becomes NDC again, scaled
  ##   by the same field-of-view tangent, and composed from camera's own right/up/forward.
  ##   Takes eye and frame precomputed, since a cursor position tests against every item
  ##   in the scene with the very same ray; recomputing it per item would repeat the same
  ##   two RGA joins and antiduals up to `ITEMS_MAX` times for one cursor position.
  let
    half_height = tan(0.5 * degToRad(camera.degrees_field_of_view))
    half_width = half_height * (float(width) / float(height))
    ndc_x = (cursor.x / float(width))*2.0 - 1.0
    ndc_y = 1.0 - (cursor.y / float(height))*2.0
    heading = (ndc_x*half_width)*frame.axis_right + (ndc_y*half_height)*frame.axis_up +
      frame.forward
  toMultivector(eye) ∧ toMultivector(heading)


func rayPlaneHit(
  ray: Multivector; eye: Position; forward: Direction;
  plane: Multivector; anchor: Position; axes: FramePlane; extent: float
): Option[float] =
  ## Meet cursor's sight ray with `plane`; report distance from eye where it lands inside
  ## the drawn disc, so a nearer plane can be preferred over a farther one behind it.
  ##   None where the ray misses the plane, the hit falls behind the eye, or it lands
  ##   outside the drawn disc.
  let hit = position(ray ∨ plane)
  if hit.isNone: return

  let distance = dot(hit.get - eye, forward)
  if distance <= 1.0e-6: return

  # Bound is circular, matching `mesh.addPlaneRing` exactly: a plane's own hit test
  #   should agree with what is drawn, not with a square the render no longer produces.
  let local = hit.get - anchor
  if dot(local, local) > extent*extent: return
  some(distance)



#[ Item Hit Testing ]#

func pickNearest*(
  scene: Scene; camera: Camera; view_projection: Matrix4; width, height: int;
  cursor: ScreenPosition
): Option[int] =
  ## Find visible item nearest cursor, preferring points over lines over planes.
  ##   None where nothing visible falls within its shape's pick radius.
  ##   **Every drawn shape is pickable, horizon or not**, ranked point, finite line,
  ##   horizon line, finite plane, horizon plane. Thin things beat wide ones, and the sky
  ##   comes last of all: it is drawn as a dome filling every direction, so it matches
  ##   every ray and would swallow the scene from any other rank.
  ##   A horizon plane being pickable at all has one consequence worth stating here,
  ##   because it is easy to reach this proc while chasing it: **the cursor is now over
  ##   *something* almost everywhere.** `interaction.beginDrag` refuses to start a drag on
  ##   it for exactly that reason -- a press on empty space has to keep falling through to
  ##   the camera, or orbit and pan stop working the moment a sky is in the scene.
  ##   Exceeds the working 60-line default: the three shape branches below are
  ##   irreducibly different geometry (point/line/plane hit-testing), each already
  ##   minimal, and all three share the `eye`/`frame_camera`/`ray`/`scale` setup computed
  ##   once above rather than per-candidate -- extracting a branch into its own proc
  ##   would mean threading all four back in as parameters for no simplification.

  # Eye, camera frame and sight ray depend only on camera and cursor, not on which item is
  #   being tested, so each is built once here rather than once per plane candidate below.
  let
    eye = camera.eye
    frame_camera = camera.frame(eye)
    ray = castRay(camera, eye, frame_camera, width, height, cursor)
    scale = DrawExtent(eye: eye, radius_horizon: radiusHorizonFor(camera.distanceFar))

  var
    slot_best = none(int)
    priority_best = high(int)
    distance_best = Inf

  template consider(priority: int; distance: float) =
    if priority < priority_best or (priority == priority_best and distance < distance_best):
      priority_best = priority
      distance_best = distance
      slot_best = some(slot)

  for slot, item in scene.pairs:
    if not item.isVisible: continue
    let geometry = item.geometry
    let shape = shape(geometry)
    if shape.isNone: continue

    case shape.get
    of Shape.Point:
      let anchor = anchorFor(geometry, scale)
      if anchor.isNone: continue
      let screen = projectToScreen(view_projection, width, height, anchor.get)
      if not screen.isInFront: continue
      let distance = hypot(cursor.x - screen.x, cursor.y - screen.y)
      if distance <= RADIUS_PICK_POINT: consider(0, distance)

    of Shape.Line:
      if geometry.isHorizon:
        # Drawn as a great circle on the sky, so tested against that circle -- sampled the
        #   way `mesh.addGreatCircle` samples it, so a hit agrees with what is drawn, the
        #   rule this module already follows for a finite line's two halves.
        let normal = directionNormalHorizon(geometry)
        if normal.isNone: continue
        let axes = spanPerpendicular(ORIGIN_WORLD, normal.get)
        if axes.isNone: continue
        let (axis_first, axis_second) = axes.get
        var
          distance_nearest = Inf
          previous = none(ScreenPosition)
        for i in 0 .. SEGMENTS_CIRCLE_HORIZON:
          let turn = (2.0*PI*float(i mod SEGMENTS_CIRCLE_HORIZON))/
            float(SEGMENTS_CIRCLE_HORIZON)
          let here = projectToScreen(
            view_projection, width, height,
            eye + scale.radius_horizon*(cos(turn)*axis_first + sin(turn)*axis_second),
          )
          if here.isInFront and previous.isSome:
            distance_nearest = min(
              distance_nearest, distanceToSegment(cursor, previous.get, here)
            )
          previous = if here.isInFront: some(here) else: none(ScreenPosition)
        if distance_nearest <= RADIUS_PICK_LINE: consider(2, distance_nearest)
        continue

      # Test both halves `mesh.addLine` draws -- support out to each of the line's own
      #   two vanishing points. Testing one would leave the other half of a line on
      #   screen unpickable, and which half that is changes as the camera orbits.
      let (anchor, axis) = (positionAnchor(geometry), direction(geometry))
      if anchor.isNone or axis.isNone: continue
      var distance_nearest = Inf
      for reach in [scale.radius_horizon, -scale.radius_horizon]:
        let clipped = clipToEyeSide(
          anchor.get, eye + reach*axis.get, eye, frame_camera.forward, camera.distanceNear,
        )
        if clipped.isNone: continue
        let (position_tail, position_head) = clipped.get
        let
          tail = projectToScreen(view_projection, width, height, position_tail)
          head = projectToScreen(view_projection, width, height, position_head)
        if not (tail.isInFront and head.isInFront): continue
        distance_nearest = min(distance_nearest, distanceToSegment(cursor, tail, head))
      if distance_nearest <= RADIUS_PICK_LINE: consider(1, distance_nearest)

    of Shape.Plane:
      if geometry.isHorizon:
        # The whole sky, drawn as a dome filling every direction, so every ray meets it and
        #   there is no distance to measure -- only a rank. Last of all, so anything else
        #   under the cursor wins and this is what a cursor over nothing else finds.
        consider(4, 0.0)
        continue

      let
        anchor =
          if item.anchorOverride.isSome: item.anchorOverride else: positionAnchor(geometry)
        axes = frame(geometry)
      if anchor.isNone or axes.isNone: continue
      let hit = rayPlaneHit(
        ray, eye, frame_camera.forward, geometry, anchor.get, axes.get, EXTENT_PLANE_F
      )
      if hit.isSome: consider(3, hit.get)

  slot_best



#[ Least Aim ]#

func isWithinCentre(screen: ScreenPosition; width, height: int): bool =
  ## Report whether a projected point falls inside the centred box, in front of the eye.
  if not screen.isInFront: return false
  let
    margin_x = 0.5*(1.0 - FRACTION_VIEW_CENTRED)*float(width)
    margin_y = 0.5*(1.0 - FRACTION_VIEW_CENTRED)*float(height)
  screen.x >= margin_x and screen.x <= float(width) - margin_x and
    screen.y >= margin_y and screen.y <= float(height) - margin_y


func isCrossingCentre(tail, head: ScreenPosition; width, height: int): bool =
  ## Report whether any part of screen segment `tail`-`head` falls inside the centred box.
  ##   Both ends are taken as already in front of the eye, since a projected position
  ##   behind it is not a screen position at all; callers clip first.
  ##   Clipped rather than sampled: a straight screen segment either crosses an
  ##   axis-aligned box or it does not, and asking that exactly costs less than asking it
  ##   approximately at enough points to be sure of a thin near-miss.
  let
    margin_x = 0.5*(1.0 - FRACTION_VIEW_CENTRED)*float(width)
    margin_y = 0.5*(1.0 - FRACTION_VIEW_CENTRED)*float(height)
    (dx, dy) = (head.x - tail.x, head.y - tail.y)
  var (enter, leave) = (0.0, 1.0)
  # Liang-Barsky: each of the box's four edges cuts back the run of the segment that could
  #   still be inside -- entering where the segment heads into that edge, leaving where it
  #   heads back out. An edge the segment runs parallel to admits or rejects it outright.
  for (rate, room) in [
    (-dx, tail.x - margin_x), (dx, float(width) - margin_x - tail.x),
    (-dy, tail.y - margin_y), (dy, float(height) - margin_y - tail.y),
  ]:
    if rate == 0.0:
      if room < 0.0: return false
      continue
    let crossing = room/rate
    if rate < 0.0:
      if crossing > enter: enter = crossing
    elif crossing < leave:
      leave = crossing
    if enter > leave: return false
  true


func isRingCrossingCentre(
  centre: Position; axis_first, axis_second: Direction; radius: float;
  view_projection: Matrix4; width, height: int
): bool =
  ## Report whether a world circle, sampled the way this project draws one, crosses the
  ## centred box anywhere.
  var previous = none(ScreenPosition)
  for i in 0 .. SEGMENTS_CIRCLE_HORIZON:
    let turn =
      (2.0*PI*float(i mod SEGMENTS_CIRCLE_HORIZON))/float(SEGMENTS_CIRCLE_HORIZON)
    let here = projectToScreen(
      view_projection, width, height,
      centre + radius*(cos(turn)*axis_first + sin(turn)*axis_second),
    )
    if here.isInFront and previous.isSome and
        isCrossingCentre(previous.get, here, width, height):
      return true
    previous = if here.isInFront: some(here) else: none(ScreenPosition)
  false


func isLineShownCentrally(
  m: Multivector; scale: DrawExtent; view_projection: Matrix4; width, height: int
): bool =
  ## Report whether a grade-2 object reaches the centred box, at horizon or finite.
  if m.isHorizon:
    let normal = directionNormalHorizon(m)
    if normal.isNone: return false
    let axes = spanPerpendicular(ORIGIN_WORLD, normal.get)
    if axes.isNone: return false
    return isRingCrossingCentre(
      scale.eye, axes.get[0], axes.get[1], scale.radius_horizon,
      view_projection, width, height,
    )

  # Both halves `mesh.addLine` draws, clipped to the eye side exactly as `pickNearest`
  #   clips them: half a line can sit behind the eye while the other half fills the frame.
  let (anchor, axis) = (positionAnchor(m), direction(m))
  if anchor.isNone or axis.isNone: return false
  for reach in [scale.radius_horizon, -scale.radius_horizon]:
    let clipped = clipToEyeSide(
      anchor.get, scale.eye + reach*axis.get, scale.eye, scale.forward, scale.depth_near
    )
    if clipped.isNone: continue
    let
      tail = projectToScreen(view_projection, width, height, clipped.get[0])
      head = projectToScreen(view_projection, width, height, clipped.get[1])
    if tail.isInFront and head.isInFront and isCrossingCentre(tail, head, width, height):
      return true
  false


func isPlaneShownCentrally(
  m: Multivector; scale: DrawExtent; view_projection: Matrix4; width, height: int
): bool =
  ## Report whether a grade-3 object reaches the centred box.
  ##   A plane at horizon is the whole sky, drawn as a dome around the eye, so it is in
  ##   view from every camera there is.
  if m.isHorizon: return true
  let (anchor, axes) = (positionAnchor(m), frame(m))
  if anchor.isNone or axes.isNone: return false
  if isRingCrossingCentre(
    anchor.get, axes.get.axis_first, axes.get.axis_second, EXTENT_PLANE_F,
    view_projection, width, height,
  ):
    return true
  # A disc wide enough to cover the box outright keeps its rim well outside it, so the rim
  #   alone would call a plane filling the whole frame out of view. Meet the sight axis --
  #   the ray through the very middle of the box -- with the plane as well.
  let ray = toMultivector(scale.eye) ∧ toMultivector(scale.forward)
  rayPlaneHit(
    ray, scale.eye, scale.forward, m, anchor.get, axes.get, EXTENT_PLANE_F
  ).isSome


func isShownCentrally*(m: Multivector; camera: Camera; width, height: int): bool =
  ## Report whether any part of `m`, drawn as this project draws it, reaches the centred
  ## box of a `width` x `height` frame seen from `camera`.
  ##   Each shape is tested against exactly what `mesh.addObject` puts on screen for it,
  ##   the rule `pickNearest` already follows and for the same reason: what counts as in
  ##   view has to agree with what a reader can actually see.
  ##   Only the *ratio* of `width` to `height` matters -- projection and box scale with
  ##   them alike -- so a caller holding an aspect and one dimension may pass any pair in
  ##   that ratio.
  ##   False where `m` draws nothing at all.
  let shape_m = shape(m)
  if shape_m.isNone: return false
  let
    scale = camera.drawExtentFor(height)
    view_projection = camera.initMatrixViewProjection(float(width)/float(height))
  case shape_m.get
  of Shape.Point:
    let anchor = anchorFor(m, scale)
    anchor.isSome and isWithinCentre(
      projectToScreen(view_projection, width, height, anchor.get), width, height
    )
  of Shape.Line: isLineShownCentrally(m, scale, view_projection, width, height)
  of Shape.Plane: isPlaneShownCentrally(m, scale, view_projection, width, height)


func aimLeast*(
  m: Multivector; camera: Camera; goal: CameraAim; width, height: int
): CameraAim =
  ## Cut `goal` back to the least of itself that already brings part of `m` into the
  ## centred box, so the camera moves as little as the request allows -- not at all where
  ## `m` is in view already.
  ##   Searched along the very path `camera.advance` eases through, rather than solved for
  ##   outright. Two reasons, the first decisive: the path is exact under any camera, while
  ##   a solved-for pan would have to assume the move runs perpendicular to the sight axis,
  ##   which an arbitrary shift of the orbit target does not; and stopping short along the
  ##   route the camera was going to take anyway reads as that same movement cut short,
  ##   where sliding off toward the nearest edge of the box instead reads as another
  ##   movement entirely.
  ##   `goal` unchanged where no partial move shows `m` at all: an object that stays
  ##   outside the box the whole way is at least centred, which is what aiming did
  ##   unconditionally before this rule existed.
  if isShownCentrally(m, camera, width, height): return camera.aimOf(goal.is_horizon)
  var
    (lower, upper) = (0.0, 1.0)
    is_bracketed = false
  for step in 1 .. STEPS_AIM_LEAST:
    let fraction = float(step)/float(STEPS_AIM_LEAST)
    if isShownCentrally(m, camera.toward(goal, fraction), width, height):
      (lower, upper) = (float(step - 1)/float(STEPS_AIM_LEAST), fraction)
      is_bracketed = true
      break
  if not is_bracketed: return goal
  # Halve into the bracket, keeping `upper` on the side that shows `m`, so whatever the
  #   search settles on is a fraction that satisfies the rule rather than one just short.
  for _ in 1 .. ROUNDS_AIM_LEAST:
    let middle = 0.5*(lower + upper)
    if isShownCentrally(m, camera.toward(goal, middle), width, height): upper = middle
    else: lower = middle
  camera.toward(goal, upper).aimOf(goal.is_horizon)


proc aimAtLeast*(
  tween: var CameraTween; camera: Camera; m: Multivector; goal: CameraAim;
  width, height: int; now, duration: float
) =
  ## Send the camera toward `goal`, but only as far as it must go to put part of `m` in
  ## view -- what every front-end's own standing aim calls.
  ##   Lives here rather than in `camera.nim` because deciding how far is far enough means
  ##   projecting the object onto the frame, which is this module's own job and not one the
  ##   camera should have to know anything about.
  ##   The `isGoalHeld` guard is not an optimisation to taste: that standing aim re-offers
  ##   the same goal on every frame an object stays selected, and `aimAt` discards the
  ##   answer, so without it the search below would run its eighteen projections a frame
  ##   for ever and change nothing.
  if tween.isGoalHeld(goal): return
  tween.aimAt(camera, goal, aimLeast(m, camera, goal, width, height), now, duration)
