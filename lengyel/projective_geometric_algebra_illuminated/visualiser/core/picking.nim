## Hit-test scene items against the cursor, so a mouse action knows which object it touched.
##
## Every world-space derivation here goes through the algebra -- rays as joins, hits as
## meets, depths as `depthAgainst`, nearest points and clips by the library's own
## operators -- and only the *pixel* half of a test is screen math: a point or line is
## judged by pixel distance to its projection, which answers where a pixel is, a
## rasterisation question. A line's own endpoints are assembled the same way
## `tessellate.addLine` draws them -- `radius_horizon` along its attitude from the eye's own
## point -- so a hit always agrees with what is drawn.
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
import ./[boundary, camera, euclid, tessellate, scene]



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


#[ In-View Configuration ]#

const INSET_POINT_SHOWN* = 0.5*float(SIZE_POINT)
  ## Shrink the centred box by this many pixels when asking whether a *point* is in view,
  ## so its drawn dot fits inside rather than only its middle.
  ##   Half of what `tessellate.addPoint` draws, which is the dot's own radius.
  ##   Deliberately **not** the selection marker's own radius, which would be the wider
  ##   reading of "fits": that ring swells while a touch hold fills (see
  ##   `marker.clearanceTouch`), and a box that breathed with a gesture would re-frame the
  ##   view mid-hold.
  ##   Nothing equivalent for a line, which has only to cross; `INSET_RIM_SHOWN` is the
  ##   plane's own, against a different bound.

const INSET_RIM_SHOWN* = 0.5*float(WIDTH_LINE_OBJECT)
  ## Shrink the **frame** by this many pixels when asking whether a *plane* is in view, so
  ## a rim resting on the very edge has its whole stroke drawn rather than half of it
  ## clipped away.
  ##   Half of what `tessellate.addPlaneRing` strokes the rim at, which is the same relationship
  ##   `INSET_POINT_SHOWN` has to the dot it keeps whole -- and, at 1.25 px, the entire
  ##   price of letting a disc reach the edge instead of stopping short of it.



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
  tail, head: Position; plane_near: Multivector
): Option[(Position, Position)] =
  ## Clip segment `tail`-`head` to the near side of `plane_near` -- the camera's own near
  ## plane, `DrawExtent.plane_near` -- the same near-side clip the GPU performs when
  ## actually drawing the segment, needed here since a screen-space hit test divides by
  ## each endpoint's own depth, which the far reach `tessellate.addLine` gives a line can put
  ## at or behind the eye even while the near half of the same segment fills the screen.
  ##   The crossing is the meet of the segment's own line with the plane -- the algebra's
  ##   statement of the clip -- and each end's side is its `depthAgainst` sign. Held equal
  ##   to the componentwise interpolation `tessellate.addSegment`'s packing still performs (that
  ##   copy is the GPU boundary and is licensed to stay plain) by a suite case, so the
  ##   two clips cannot drift apart.
  ##   Exported for `marker.markerRails`, which flanks exactly the run this clips and
  ##   therefore has to clip it the same way; a marker drawn past the eye plane wraps to
  ##   the opposite side of the screen.
  ##   None where the whole segment lies behind the plane.
  let
    depth_tail = depthAgainst(plane_near, toMultivector(tail))
    depth_head = depthAgainst(plane_near, toMultivector(head))
  if depth_tail <= 0.0 and depth_head <= 0.0: return
  if depth_tail > 0.0 and depth_head > 0.0: return some((tail, head))
  let crossing = position(wedgeAnti(
    wedge(toMultivector(tail), toMultivector(head)), plane_near
  ))
  if crossing.isNone: return # Unreachable with straddling signs; stated for the reader.
  if depth_tail > 0.0: some((tail, crossing.get)) else: some((crossing.get, head))


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

func castRay*(
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


func positionUnderCursor*(
  camera: Camera; width, height: int; cursor: ScreenPosition
): Option[Position] =
  ## Solve the world point the cursor is over: where its sight ray meets the **horizontal
  ## plane through the camera's own target**. None where the ray never meets it -- looking
  ## along that plane, or away from it at the sky.
  ##   That plane rather than the ground at `z = 0`, for two reasons. It always sits at the
  ## height the reader is actually working at, which is what they mean by "there" when they
  ## point at something; and it keeps the hit at a sane distance, where a ground plane far
  ## below a raised target puts it wildly far off at a shallow angle.
  ##   Meant for a zoom that keeps what is under the cursor under the cursor
  ## (`camera.dollyToward`), which is what every map and most strategy games do with a
  ## wheel. Lives here rather than in `camera` because it needs the sight ray, and `camera`
  ## is what this module imports rather than the other way round.
  let
    eye = camera.eye
    frame_camera = camera.frame(eye)
    ray = castRay(camera, eye, frame_camera, width, height, cursor)
    # The horizontal plane through the target -- `objects.levelPlaneThrough`, the one
    #   spelling of what a level means to the algebra.
    hit = position(ray ∨ levelPlaneThrough(toMultivector(camera.target)))
  if hit.isNone: return
  # Behind the eye is not under the cursor: a ray aimed at the sky meets the plane on the
  #   far side of the reader, and zooming toward that point would fly the camera
  #   backwards. Depth read against the eye's own plane.
  let plane_eye = planeThrough(toMultivector(eye), toMultivector(frame_camera.forward))
  if depthAgainst(plane_eye, toMultivector(hit.get)) <= 1.0e-6: return
  hit


func positionOnLineNearest*(
  anchor: Position; axis: Direction; ray_from: Position; ray_along: Direction
): Option[Position] =
  ## Find the point of the line through `anchor` along `axis` standing nearest the ray from
  ## `ray_from` along `ray_along`.
  ##   What "the line, where the cursor is over it" has to mean: a cursor is a ray, a line
  ##   is a line, and in three dimensions the two miss each other. The point of the line
  ##   nearest the ray is the only answer that is on the line and under the cursor at once.
  ##   None where the two run parallel, which has no one nearest point but a whole shared
  ##   direction of them; a caller then has nothing on this line to aim at and says so.
  ##   **The algebra's own answer, in three moves.** The join of the two lines' attitudes
  ##   is the horizon line through both directions, whose normal is their common
  ##   perpendicular -- the very reading `directionNormalHorizon` documents, and it
  ##   vanishes exactly where the lines run parallel, which is the refusal. The plane
  ##   `ray ∧ commonPerpendicular` contains the ray and the segment realising the nearest
  ##   approach, so its meet with the line is that approach's foot on the line. Held
  ##   equal to the classical two-dot closed form -- which lives in the suite, where
  ##   checking the algebra is the point -- over a scatter of line/ray pairs.
  let
    line = wedge(toMultivector(anchor), toMultivector(axis))
    ray = wedge(toMultivector(ray_from), toMultivector(ray_along))
    normal_common = directionNormalHorizon(wedge(attitude(line), attitude(ray)))
  if normal_common.isNone: return
  position(wedgeAnti(line, wedge(ray, toMultivector(normal_common.get))))


func positionOnItemUnder(
  geometry: Multivector; ray: Multivector; plane_eye: Multivector
): Option[Position] =
  ## Solve the world point of one item that the cursor's own sight `ray` is over.
  ##   A point stands where it stands, a plane is met where the ray crosses it, and a line
  ##   is read at its nearest point to the ray -- see `positionOnLineNearest`.
  ##   **Finite shapes only.** An object at horizon is drawn at `radius_horizon` about the
  ##   eye and is not *at* any place in the world, so there is nothing there to fly toward.
  ##   None also for a hit behind the eye -- read as its depth against the eye's own
  ##   plane, `plane_eye` -- and none for a ray with no direction to read.
  if geometry.isHorizon: return
  let
    shaped = shape(geometry)
    heading = direction(ray)
  if shaped.isNone or heading.isNone: return
  var found = none(Position)
  case shaped.get
  of Shape.Point: found = positionAnchor(geometry)
  of Shape.Line:
    let (anchor, axis) = (positionAnchor(geometry), direction(geometry))
    if anchor.isSome and axis.isSome:
      # The ray's own two defining elements are read back off the ray multivector, so the
      #   nearest-point question is asked of exactly the ray that was cast.
      let ray_from = positionSupport(ray)
      if ray_from.isSome:
        found = positionOnLineNearest(anchor.get, axis.get, ray_from.get, heading.get)
  of Shape.Plane: found = position(ray ∨ geometry)
  if found.isNone: return
  if depthAgainst(plane_eye, toMultivector(found.get)) <= 1.0e-6: return
  found


func positionOnGround*(
  camera: Camera; width, height: int; cursor: ScreenPosition
): Option[Position] =
  ## Solve where the cursor's own sight ray meets the ground plane, `z = 0`.
  ##   None where the ray never reaches it: running along the ground, or aimed above the
  ## horizon at the sky, where the meet lands behind the reader.
  let
    eye = camera.eye
    frame_camera = camera.frame(eye)
    ray = castRay(camera, eye, frame_camera, width, height, cursor)
    hit = position(ray ∨ groundPlane())
  if hit.isNone: return
  let plane_eye = planeThrough(toMultivector(eye), toMultivector(frame_camera.forward))
  if depthAgainst(plane_eye, toMultivector(hit.get)) <= 1.0e-6: return
  hit


func rayPlaneHit(
  ray, plane_eye: Multivector; plane: Multivector; anchor: Position; extent: float
): Option[float] =
  ## Meet cursor's sight ray with `plane`; report view depth where it lands inside the
  ## drawn disc, so a nearer plane can be preferred over a farther one behind it.
  ##   None where the ray misses the plane, the hit falls behind the eye -- its depth
  ##   against `plane_eye` -- or it lands outside the drawn disc.
  ##   **The meet is read back as the point it names before anything signed is asked of
  ##   it.** A meet's weight carries the orientation of the crossing -- which side of the
  ##   plane the ray came from -- and `unitize` divides by the weight's *norm*, so that
  ##   sign survives it. `depthAgainst` is linear in its point, so a meet left as it came
  ##   reports the distance ahead of the eye negated on every plane the ray meets from
  ##   behind its normal, and this refused each such plane at every pixel of its own disc.
  ##   `position` divides by the signed weight and `toMultivector` restates the answer at
  ##   weight one, which is the form every other `depthAgainst` in this module passes.
  let met = wedgeAnti(ray, plane)
  let where = position(met)
  if where.isNone: return
  let hit = toMultivector(where.get)

  let distance = depthAgainst(plane_eye, hit)
  if distance <= 1.0e-6: return

  # Bound is circular, matching `tessellate.addPlaneRing` exactly: a plane's own hit test
  #   should agree with what is drawn, not with a square the render no longer produces.
  #   Distance between the hit and the disc's own centre, through the algebra.
  if distanceBetween(hit, toMultivector(anchor)) > extent: return
  some(distance)



#[ Item Hit Testing ]#

proc pickNearest*(
  scene: Scene; camera: Camera; scale: DrawExtent; view_projection: Matrix4;
  width, height: int; cursor: ScreenPosition
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
  # `scale` must be this camera's own extent, as `drawExtentFor` built it this frame --
  #   the branches below read the eye and its planes off it, and an extent from another
  #   camera would rank items against a view nobody is looking through. Taking it beats
  #   deriving a fresh one here, which ran `algebraFilled` a third time per frame.
  let
    eye = scale.eye
    frame_camera = camera.frame(eye)
    ray = castRay(camera, eye, frame_camera, width, height, cursor)

  var
    slot_best = none(int)
    priority_best = high(int)
    distance_best = Inf

  template consider(priority: int; distance: float) =
    if priority < priority_best or (priority == priority_best and distance < distance_best):
      priority_best = priority
      distance_best = distance
      slot_best = some(slot)

  # Walks slots with the by-slot readers rather than through `pairs`: under the JS
  #   backend an `Item` holds its `Scene` by value, so `pairs` copies the whole scene
  #   once per live slot -- the trap `nimBuildFrame`'s walk documents, found again here
  #   costing most of each hover pick, on a proc that runs per pointer move.
  for slot in 0 ..< ITEMS_MAX:
    if not scene.isAlive(slot) or not scene.isVisible(slot): continue
    let geometry = scene.geometryOf(slot)
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
        #   way `tessellate.addGreatCircle` samples it, so a hit agrees with what is drawn, the
        #   rule this module already follows for a finite line's two halves.
        let normal = directionNormalHorizon(geometry)
        if normal.isNone: continue
        let axes = spanPerpendicular(ORIGIN_WORLD, normal.get)
        if axes.isNone: continue
        # Stepped off the same fixed table the drawn circle walks (see
        #   `tessellate.addGreatCircle`): which plane the arms span is still the
        #   algebra's answer above, and the ring itself is arithmetic -- it used to be
        #   ninety-seven multivector sums per horizon candidate per pointer move, the
        #   bulk of what a hover pick cost once the scene copies were gone.
        let
          (axis_first, axis_second) = axes.get
          arm_first = scale.radius_horizon*axis_first
          arm_second = scale.radius_horizon*axis_second
        var
          distance_nearest = Inf
          previous = none(ScreenPosition)
        for i in 0 .. SEGMENTS_CIRCLE_HORIZON:
          let entry = UNIT_CIRCLE_RIM[i mod SEGMENTS_CIRCLE_HORIZON]
          let here = projectToScreen(
            view_projection, width, height,
            onCircleAt(scale.eye, arm_first, arm_second, entry.cos_angle, entry.sin_angle),
          )
          if here.isInFront and previous.isSome:
            distance_nearest = min(
              distance_nearest, distanceToSegment(cursor, previous.get, here)
            )
          previous = if here.isInFront: some(here) else: none(ScreenPosition)
        if distance_nearest <= RADIUS_PICK_LINE: consider(2, distance_nearest)
        continue

      # Test both halves `tessellate.addLine` draws -- support out to each of the line's own
      #   two vanishing points. Testing one would leave the other half of a line on
      #   screen unpickable, and which half that is changes as the camera orbits.
      let (anchor, axis) = (positionAnchor(geometry), direction(geometry))
      if anchor.isNone or axis.isNone: continue
      var distance_nearest = Inf
      for reach in [scale.radius_horizon, -scale.radius_horizon]:
        let clipped = clipToEyeSide(
          anchor.get,
          pointFrom(add(scale.eye_point, wedge(reach, toMultivector(axis.get)))),
          scale.plane_near,
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
        override = scene.anchorOverrideAt(slot)
        anchor = if override.isSome: override else: positionAnchor(geometry)
      # The frame guard survives the hit test no longer taking the axes: a plane the
      #   algebra can span no frame for is one the disc was never drawn for either.
      if anchor.isNone or frame(geometry).isNone: continue
      let hit = rayPlaneHit(ray, scale.plane_eye, geometry, anchor.get, EXTENT_PLANE_F)
      if hit.isSome: consider(3, hit.get)

  slot_best


proc anchorZoomAt*(
  scene: Scene; camera: Camera; scale: DrawExtent; view_projection: Matrix4;
  width, height: int; cursor: ScreenPosition
): Option[Position] =
  ## Solve the world point a zoom aimed at `cursor` should hold still: whatever finite
  ## object the cursor is over, else the ground under it, else the level the target sits
  ## on.
  ##   **In that order, and the order is the rule.** A reader pointing at an object means
  ## that object, at the depth it actually stands at; a zoom anchored instead on a plane
  ## through the target crept past or short of it, and what was under the cursor slid away
  ## as the wheel turned. Failing an object, the ground is what a reader means by "there"
  ## -- the surface the scene is laid out over, and the one every map zooms against.
  ##   The level through the target survives as the last answer rather than the first, for
  ## the case the other two miss: a cursor on empty sky above the horizon, where there is
  ## no ground ahead to meet and the reader has turned the wheel anyway.
  ##   `pickNearest` ranks a horizon plane last and matches it everywhere, so the sky is
  ## "under the cursor" almost always; `positionOnItemUnder` refuses horizon shapes for
  ## exactly that reason, and the fall-through does the work.
  ##   None where none of the three answers, which leaves a caller to zoom at the middle of
  ## the frame.
  # The caller's own extent, not a derivation of this proc's: on the browser the wheel
  #   handler holds the overlay cache's extent for exactly this camera, and deriving a
  #   fresh one here ran `algebraFilled` and `camera.frame`'s joins per wheel notch.
  let slot = pickNearest(scene, camera, scale, view_projection, width, height, cursor)
  if slot.isSome:
    let
      frame_camera = camera.frame(scale.eye)
      ray = castRay(camera, scale.eye, frame_camera, width, height, cursor)
      found = positionOnItemUnder(scene.geometryOf(slot.get), ray, scale.plane_eye)
    if found.isSome: return found
  let ground = positionOnGround(camera, width, height, cursor)
  if ground.isSome: return ground
  positionUnderCursor(camera, width, height, cursor)



#[ In View ]#

func marginCentred(width, height: int; inset: float): (float, float) =
  ## Measure how far in, across and down, the centred box begins.
  ##   `inset` pulls both margins further in by that many pixels, for a caller asking
  ##   whether something of its own size fits rather than whether a bare position lands.
  ##   The box itself is `camera.reachCentred`'s to shape -- including why it is not simply
  ##   the same fraction of each dimension -- so that the pixel test here and the cone
  ##   `camera.distanceFitting` solves cannot come to disagree about what "in view" means.
  let (reach_across, reach_down) = reachCentred(width, height, inset)
  (0.5*(float(width) - reach_across), 0.5*(float(height) - reach_down))


func isWithinCentre(screen: ScreenPosition; width, height: int; inset: float): bool =
  ## Report whether a projected point falls inside the centred box, in front of the eye.
  if not screen.isInFront: return false
  let (margin_x, margin_y) = marginCentred(width, height, inset)
  screen.x >= margin_x and screen.x <= float(width) - margin_x and
    screen.y >= margin_y and screen.y <= float(height) - margin_y


func isWithinFrame(screen: ScreenPosition; width, height: int; inset: float): bool =
  ## Report whether a projected point falls on screen at all, in front of the eye.
  ##   The looser of the two bounds this module tests against, and the one a plane's rim
  ##   answers to: a disc reaching the edge is still wholly *visible*, which is all its rim
  ##   has to be. What makes the plane the thing being looked at is its centre, which is
  ##   held to `isWithinCentre` like anything else.
  if not screen.isInFront: return false
  screen.x >= inset and screen.x <= float(width) - inset and
    screen.y >= inset and screen.y <= float(height) - inset


func isCrossingCentre(tail, head: ScreenPosition; width, height: int): bool =
  ## Report whether any part of screen segment `tail`-`head` falls inside the centred box.
  ##   Both ends are taken as already in front of the eye, since a projected position
  ##   behind it is not a screen position at all; callers clip first.
  ##   Clipped rather than sampled: a straight screen segment either crosses an
  ##   axis-aligned box or it does not, and asking that exactly costs less than asking it
  ##   approximately at enough points to be sure of a thin near-miss.
  # No inset: a line and a plane have only to cross the box, never to fit inside it.
  let
    (margin_x, margin_y) = marginCentred(width, height, 0.0)
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
  let
    centre_point = toMultivector(centre)
    arm_first = wedge(radius, toMultivector(axis_first))
    arm_second = wedge(radius, toMultivector(axis_second))
  var previous = none(ScreenPosition)
  for i in 0 .. SEGMENTS_CIRCLE_HORIZON:
    let turn =
      (2.0*PI*float(i mod SEGMENTS_CIRCLE_HORIZON))/float(SEGMENTS_CIRCLE_HORIZON)
    let here = projectToScreen(
      view_projection, width, height,
      pointFrom(add(centre_point,
        add(wedge(cos(turn), arm_first), wedge(sin(turn), arm_second)))),
    )
    if here.isInFront and previous.isSome and
        isCrossingCentre(previous.get, here, width, height):
      return true
    previous = if here.isInFront: some(here) else: none(ScreenPosition)
  false


func isRingWithinFrame(
  centre: Position; axis_first, axis_second: Direction; radius: float;
  view_projection: Matrix4; width, height: int
): bool =
  ## Report whether every point of a world circle, sampled the way this project draws one,
  ## falls on screen.
  ##   The rim alone answers for the disc it bounds: the disc is flat and the frame is
  ##   convex, so a rim wholly inside carries its own interior in with it.
  ##   False the moment any sample falls behind the eye. A disc reaching past the eye has
  ##   no screen extent to fit, and no distance the camera could stand at would give it
  ##   one without first turning to face the thing.
  let
    centre_point = toMultivector(centre)
    arm_first = wedge(radius, toMultivector(axis_first))
    arm_second = wedge(radius, toMultivector(axis_second))
  for i in 0 ..< SEGMENTS_CIRCLE_HORIZON:
    let turn = (2.0*PI*float(i))/float(SEGMENTS_CIRCLE_HORIZON)
    let here = projectToScreen(
      view_projection, width, height,
      pointFrom(add(centre_point,
        add(wedge(cos(turn), arm_first), wedge(sin(turn), arm_second)))),
    )
    if not isWithinFrame(here, width, height, INSET_RIM_SHOWN): return false
  true


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

  # Both halves `tessellate.addLine` draws, clipped to the eye side exactly as `pickNearest`
  #   clips them: half a line can sit behind the eye while the other half fills the frame.
  let (anchor, axis) = (positionAnchor(m), direction(m))
  if anchor.isNone or axis.isNone: return false
  for reach in [scale.radius_horizon, -scale.radius_horizon]:
    let clipped = clipToEyeSide(
      anchor.get,
      pointFrom(add(scale.eye_point, wedge(reach, toMultivector(axis.get)))),
      scale.plane_near,
    )
    if clipped.isNone: continue
    let
      tail = projectToScreen(view_projection, width, height, clipped.get[0])
      head = projectToScreen(view_projection, width, height, clipped.get[1])
    if tail.isInFront and head.isInFront and isCrossingCentre(tail, head, width, height):
      return true
  false


func isPlaneShownCentrally(
  m: Multivector; anchor_override: Option[Position];
  view_projection: Matrix4; width, height: int
): bool =
  ## Report whether a grade-3 object is in view: its drawn disc **centred** in the centred
  ## box, and the **whole of its rim** on screen.
  ##   Two bounds and not one, because a disc has a middle and an extent and they answer
  ##   different questions. Its centre says whether the plane is what the view is about, so
  ##   it is held to the same box every other object's position is. Its rim says only
  ##   whether the reader can see the whole circle, so it is held to the frame -- a disc
  ##   made to fit the *centred box* has to be pushed a full half again further away than
  ##   one made to fit the frame, and it was: picking the demo's ground plane threw the
  ##   camera from 19 out to 29.9 where 19 already showed the whole circle. An edge resting
  ##   near the edge of the screen is a plane a reader can read.
  ##   A plane at horizon is the whole sky, drawn as a dome around the eye, so it is in
  ##   view from every camera there is.
  ##   `anchor_override` centres the disc there instead of on the plane's own support, read
  ##   exactly as `tessellate.addPlane` reads it, so what is judged is the circle a reader can
  ##   actually see: the two stand as far as 3.7 units apart on the demo scene's own planes,
  ##   against a disc of radius 8.
  if m.isHorizon: return true
  let
    anchor = if anchor_override.isSome: anchor_override else: positionAnchor(m)
    axes = frame(m)
  if anchor.isNone or axes.isNone: return false
  # No inset on the centre: nothing is drawn there. A plane's disc carries no anchor marker
  #   and no crosshair -- the rim alone marks it -- so there is no dot needing room.
  if not isWithinCentre(
    projectToScreen(view_projection, width, height, anchor.get), width, height, 0.0
  ):
    return false
  isRingWithinFrame(
    anchor.get, axes.get.axis_first, axes.get.axis_second, EXTENT_PLANE_F,
    view_projection, width, height,
  )


func isShownCentrally*(
  m: Multivector; camera: Camera; width, height: int;
  anchor_override: Option[Position] = none(Position)
): bool =
  ## Report whether `m` is in view, in the sense a camera framing a selection has to
  ## satisfy, over a `width` x `height` frame seen from `camera`:
  ##
  ##   |--------|---------------------------------------------------------------------|
  ##   | Point  | Its dot fits inside the centred box.                                 |
  ##   | Line   | It merely crosses the centred box.                                   |
  ##   | Plane  | Its disc is centred in the centred box, and its rim is on screen.    |
  ##   |--------|---------------------------------------------------------------------|
  ##
  ##   Three readings and not one, and the split follows what each shape is drawn at rather
  ##   than its grade. A point's dot and a plane's disc are both drawn at a fixed size the
  ##   camera does not set, so each is a bounded thing a frame can hold, and holding it
  ##   whole is what "you can see it" means. A line is drawn out to the horizon, which
  ##   moves with the camera, so it has no size to fit: demanding it fit would demand a
  ##   camera pulled back until it was a speck, and crossing the middle of the frame is
  ##   what seeing it means instead. A plane splits the question in two, since its disc is
  ##   the one drawn thing wide enough that "fits" and "is what the view is about" want
  ##   different bounds; see `isPlaneShownCentrally`.
  ##   Each shape is tested against exactly what `tessellate.addObject` puts on screen for it,
  ##   `anchor_override` included, the rule `pickNearest` already follows and for the same
  ##   reason: what counts as in view has to agree with what a reader can actually see.
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
      projectToScreen(view_projection, width, height, anchor.get),
      width, height, INSET_POINT_SHOWN,
    )
  of Shape.Line: isLineShownCentrally(m, scale, view_projection, width, height)
  of Shape.Plane:
    isPlaneShownCentrally(m, anchor_override, view_projection, width, height)
