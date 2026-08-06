## Shape a selection or hover marker to the object it marks, in screen pixels.
##
## A marker says "this one", and it says it best when its own outline echoes the thing it
## surrounds: a ring reads as *that point*, a pair of rails as *that line*, a circle lying
## on the plane as *that plane*. One screen-space circle for all three said only "something
## here", and on a plane it said it in the wrong place -- centred on a support the disc is
## not even drawn around.
##
## Every marker keeps the same clear space, `GAP_MARKER` pixels, between the object's own
## drawn edge and its own outline, so the three read as one family at one weight rather
## than three unrelated decorations. That gap is measured out from the sizes the object is
## actually drawn at (`mesh.SIZE_POINT`, `mesh.WIDTH_LINE_OBJECT`, `mesh.EXTENT_PLANE_F`),
## so changing a draw size moves its marker with it.
##
##   |------------------|---------------------------------------------------------------|
##   | Shape            | Marker                                                        |
##   |------------------|---------------------------------------------------------------|
##   | Point            | `Ring`  -- circle in screen space, about the drawn point.     |
##   | Line             | `Rails` -- two screen-space segments flanking its projection. |
##   | Plane            | `Loop`  -- circle lying *on the plane*, outside its own rim.  |
##   | Line at horizon  | `Bands` -- two small circles on the sky flanking the great    |
##   |                  |   circle the line itself is drawn as.                         |
##   | Plane at horizon | `Frame` -- rectangle around the whole viewport, since the     |
##   |                  |   object it marks is the whole sky.                           |
##   | Point at horizon | `Ring`, about the star it is drawn as.                        |
##   |------------------|---------------------------------------------------------------|
##
## The last two shapes had no marker at all until this round: both draw fixed to the eye
## rather than around a point in the scene, so neither offered anything to surround. The
## answer is that what a marker surrounds is *whatever is drawn*, and both are drawn --
## a great circle and a whole sky -- so a marker wraps each exactly as it is drawn.
##
## Markers are described here and drawn by each render path's own foreground layer
## (`visualiser.drawSelectionMarker`, `glue.js`'s SVG overlay), never as scene geometry: a
## loop lying exactly on a plane would z-fight with that plane's own fill, and a marker
## that can be occluded by the object it marks is not a marker.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]

import ../../pga
import ./[camera, mesh, objects, picking]



#[ Marker Configuration ]#

const
  GAP_MARKER* = 6.0
    ## Set clear space between an object's own drawn edge and its marker, in pixels.
    ##   One number for all three shapes: what makes a selection legible is a consistent
    ##   band of untouched background around whatever is selected, and a marker that
    ##   hugged a point more tightly than it hugged a line would read as two mechanisms.
    ##   Held deliberately tight. A wide band reads as a second object rather than as an
    ##   annotation of the first, and on a scene of several selected items the bands
    ##   themselves become the busiest thing on screen.
  WIDTH_MARKER* = 1.5'f32
    ## Set thickness of every marker outline, and of the drag rubber-band beside it, in
    ## pixels.
    ##   Thinner than the object it marks (`WIDTH_LINE_OBJECT`), so the marker reads as
    ##   an annotation drawn over the scene rather than as heavier geometry added to it.
  ALPHA_MARKER_SELECTED* = 0.9'f32
    ## Draw a selection's own marker this much of full opacity.
    ##   Short of full: pure white at full strength is the brightest thing this palette
    ##   can produce, brighter than any object it surrounds, which inverts the emphasis
    ##   it exists to give. A hair of transparency lets the backdrop through and settles
    ##   it behind the geometry without weakening the outline.
  ALPHA_MARKER_HOVER* = 0.6'f32
    ## Draw hover's own marker this much of full opacity.
    ##   Hover wears the same outline a selection does rather than one of its own, so
    ##   hovering a line previews exactly the rails selecting it would draw; weight is
    ##   what tells the two apart, and it is the only thing that does.
  SEGMENTS_MARKER_LOOP* = 64
    ## Cut a plane's own marker circle into this many pieces before projecting.
    ##   Fewer than the rim's own `SEGMENTS_CIRCLE_HORIZON`: the rim is scene geometry
    ##   drawn at any size, while this is a thin overlay whose polygon corners fall below
    ##   a pixel well before they are visible.

const
  SEGMENTS_MARKER_RAILS* = 4
    ## Bound how many segments a line's own rails come to: one each side, each cut into
    ## the two halves `mesh.addLine` draws the line itself as.
  RADIUS_MARKER_POINT* = 0.5*float(SIZE_POINT) + GAP_MARKER
    ## Place a point's own ring this far from the point, in pixels.
  OFFSET_MARKER_RAIL* = 0.5*float(WIDTH_LINE_OBJECT) + GAP_MARKER
    ## Place each of a line's own rails this far from the line, in pixels, measured at
    ## the line's own support, to within a fraction of a pixel -- see `offsetMarkerRail`
    ## for what happens elsewhere along it, and `directionAcross` for the fraction.
  CLEARANCE_MARKER_TOUCH* = 54.5
    ## Push every marker outward by up to this many pixels partway through a **touch**
    ## hold, settling back to its true size as the hold completes.
    ##   A fingertip covers what it presses, so a marker that fills underneath one says
    ##   nothing to the person filling it -- the whole point of drawing a hold's progress
    ##   is lost to the hand doing it. Sized from the far end: a point's ring should reach
    ##   a **130-pixel diameter** at the peak, which is 65 of radius less
    ##   `RADIUS_MARKER_POINT`'s own 10.5. That is about twice a thumb's contact patch, so
    ##   the halo stands outside the hand rather than at its edge.
    ##   Was 24, sized against a 44-pixel *minimum* touch target and reported as clearing a
    ##   fingertip. It did not: the measurement compared framebuffer pixels against a
    ##   CSS-pixel target, and the answer came back from a real thumb rather than from the
    ##   suite. Both units now mean the same thing -- see `glue.js`'s own note on the two
    ##   layers -- so this number is what a reader actually sees.
    ##   Added in pixels rather than multiplied, so it means one thing on a point's 10.5-px
    ##   ring and on a plane's rim hundreds of pixels across; each shape converts it into
    ##   its own units. Mouse gestures never see it -- a cursor hides nothing.
  SEGMENTS_MARKER_BANDS* = 48
    ## Cut each of a horizon line's own two flanking circles into this many pieces.
    ##   Fewer than the `SEGMENTS_CIRCLE_HORIZON` the drawn great circle uses, for the
    ##   reason `SEGMENTS_MARKER_LOOP` gives: this is a thin overlay, not scene geometry.
  ANGLE_MARKER_BANDS_OPEN* = 0.5*PI
    ## Start a horizon line's own bands this far off it, in radians, at zero progress.
    ##   A quarter turn is the pole of the very sphere the line's great circle runs
    ##   around: as far from it as the sky goes, and so reliably outside any field of view
    ##   this camera offers. The bands are single points there and open into rings as they
    ##   close, which is what makes them read as arriving from outside rather than growing
    ##   in place -- a line at horizon has no support to grow out from, unlike a finite one.

static:
  doAssert GAP_MARKER > 0, &"Marker clearance must be positive; got `{GAP_MARKER}`."
  doAssert WIDTH_MARKER < WIDTH_LINE_OBJECT,
    &"A marker must draw thinner than the line it marks; got `{WIDTH_MARKER}` >= " &
    &"`{WIDTH_LINE_OBJECT}`."
  doAssert ALPHA_MARKER_HOVER < ALPHA_MARKER_SELECTED,
    &"Hover must read fainter than a selection; got `{ALPHA_MARKER_HOVER}` >= " &
    &"`{ALPHA_MARKER_SELECTED}`."
  doAssert SEGMENTS_MARKER_LOOP >= 12,
    &"A plane's marker needs 12 segments to read as a circle; got " &
    &"`{SEGMENTS_MARKER_LOOP}`."



#[ Type Definitions ]#

type
  MarkerKind* {.pure.} = enum ## Name which outline a marker is drawn as.
    Ring, ## Circle in screen space, for a point.
    Rails, ## Pair of world-space lines flanking a line, converging as it does.
    Loop, ## Polyline lying on a plane in world space, projected, for a plane.
    Bands, ## Pair of circles on the sky flanking a horizon line's own great circle.
    Frame, ## Rectangle around the whole viewport, for the whole sky a horizon plane is.

  Marker* = object ## Hold one object's marker, ready to draw on the foreground layer.
    case kind*: MarkerKind
    of MarkerKind.Ring:
      centre*: ScreenPosition ## Where the point itself projects.
      radius*: float ## Ring radius, in pixels.
      fraction*: float ## How much of the circle to stroke, clockwise from twelve o'clock,
        ## in 0 .. 1. A whole ring at 1, which is what every finished marker is; less only
        ## while a hold is filling it. Clockwise and from the top because that is how every
        ## other progress dial a reader has met is drawn, and this one is read the same way.
    of MarkerKind.Rails:
      count_segment*: int ## Segments used of `segments` below.
      segments*: array[SEGMENTS_MARKER_RAILS, array[2, ScreenPosition]]
        ## Endpoints of each drawn piece: one rail each side, each in up to the two
        ## halves the line itself is drawn as. Fewer where a half was clipped away.
    of MarkerKind.Loop:
      count_point*: int ## Points used of `points` below.
      is_closed*: bool ## Whether last point joins back to first.
        ## False where part of the circle fell behind the eye and was cut away, leaving
        ## an arc; a closed loop drawn through a cut would run straight across the view.
      points*: array[SEGMENTS_MARKER_LOOP, ScreenPosition]
        ## Circle's own points, in order around the plane, already projected.
    of MarkerKind.Bands:
      counts_band*: array[2, int] ## Points used of each band below.
      are_closed_band*: array[2, bool] ## Whether each band joins back to its own first
        ## point, false where the eye cut it into an arc -- `Loop`'s own rule, twice.
      points_band*: array[2, array[SEGMENTS_MARKER_BANDS, ScreenPosition]]
        ## Each band's own points, in order around the sky, already projected.
    of MarkerKind.Frame:
      corners*: array[4, ScreenPosition] ## Rectangle's own corners, clockwise from the
        ## top left. Screen space throughout, and the one marker that is: the sky has no
        ## place in the scene to surround, so its marker surrounds the view instead.



#[ Touch Clearance ]#

func clearanceTouch*(progress: float; is_touch: bool): float =
  ## Measure how far outward to push a marker, in pixels, at this point in a hold.
  ##   Zero at both ends and `CLEARANCE_MARKER_TOUCH` halfway, along a half sine: the
  ##   marker leaves and returns to its true size exactly, so a finished marker is the
  ##   same outline whether a finger or a mouse produced it, and nothing has to be undone
  ##   at the end. A curve rather than a step because the swell is meant to read as the
  ##   marker breathing out from under the finger, not as a second marker appearing.
  ##   Zero throughout for a mouse: a cursor hides nothing, and swelling under one would
  ##   be motion with nothing to say.
  if not is_touch: return 0.0
  CLEARANCE_MARKER_TOUCH*sin(PI*clamp(progress, 0.0, 1.0))



#[ Point And Line ]#

func markerRing(
  geometry: Multivector; scale: DrawExtent; view_projection: Matrix4; width, height: int;
  progress, clearance: float
): Option[Marker] =
  ## Build a point's own ring, about wherever that point is drawn.
  ##   Screen-space rather than a world-space circle facing the camera, because a point
  ##   has no orientation to echo: any world circle would have to pick a facing, and
  ##   every choice looks the same from the one angle it is seen from anyway.
  ##   `progress` sweeps the ring rather than growing it: a point is drawn at one fixed
  ##   size, so a ring that grew outward would read as the point itself swelling, and one
  ##   that grew inward would collide with it. A sweep leaves the geometry alone and says
  ##   the one thing a hold needs to say, which is how much of it is left.
  let anchor = anchorFor(geometry, scale)
  if anchor.isNone: return
  let centre = projectToScreen(view_projection, width, height, anchor.get)
  if not centre.isInFront: return
  some(Marker(
    kind: MarkerKind.Ring, centre: centre, radius: RADIUS_MARKER_POINT + clearance,
    fraction: progress,
  ))


func offsetMarkerRail*(anchor: Position; scale: DrawExtent; clearance: float = 0.0): float =
  ## Size how far to each side of a line its rails stand, in world units.
  ##   Reads as `OFFSET_MARKER_RAIL` pixels where the line's own support is, and closes
  ##   with distance from there exactly as the line's own foreshortening does. That is
  ##   the point of a world offset: parallel lines share a vanishing point, so the rails
  ##   converge on the same one the line runs to and the three read as one object seen
  ##   in perspective. A constant screen offset instead holds the pair open all the way
  ##   to the horizon, where the line has long since narrowed to nothing.
  ##   `clearance` widens the pair by that many further pixels, for a touch hold; it
  ##   converts through the same depth reading, so a swollen rail foreshortens exactly as
  ##   a settled one does rather than reading as a rail at a different distance.
  (OFFSET_MARKER_RAIL + clearance)*worldPerPixelAt(anchor, scale)


func directionAcross(geometry: Multivector; eye: Position): Option[Direction] =
  ## Resolve which way to step off a line so its rails land either side of it on screen.
  ##   Joining the line with the eye gives the one plane containing both; that plane's
  ##   own normal is perpendicular to the line and to every sight ray reaching it, which
  ##   is exactly the direction that shows as sideways from where the camera stands.
  ##   Perpendicular to the sight ray reaching the line rather than to the camera's own
  ##   axis, so the rails straddle the very plane the line's screen projection is: the
  ##   pair reads symmetric about it from any angle. The cost is that the step tilts a
  ##   hair out of the plane perspective divides by, leaving the stated gap a fraction
  ##   of a percent wide -- well under a pixel, and pinned in the suite.
  ##   None where the eye lies on the line itself, which has no such plane -- and no
  ##   side to flank from, since the line is then edge-on to a viewer inside it.
  directionNormal(geometry ∧ toMultivector(eye))


func markerRails(
  geometry: Multivector; scale: DrawExtent; placement: Camera;
  view_projection: Matrix4; width, height: int; progress, clearance: float
): Option[Marker] =
  ## Build a line's own pair of rails: two lines parallel to it in world space, one to
  ## each side, converging with it toward its own vanishing points.
  ##   Each rail is drawn exactly as `mesh.addLine` draws the line itself -- its own
  ##   anchor out to each of the two vanishing points, which parallel lines share -- so
  ##   the three meet at the same two points on screen rather than merely running near
  ##   one another, and each rail projects onto its own true line for the same reason
  ##   the drawn line does.
  ##   `progress` shortens each rail toward its own start, so a filling hold runs both
  ##   rails out from the line's own support toward each horizon.
  ##   Shortened *after* projection, along the screen segment, rather than by scaling the
  ##   world reach: the far end is a point one horizon radius from the *eye* along the
  ##   axis, so scaling that reach walks the head back to the camera rather than in toward
  ##   the support. Interpolating on screen still keeps every partial rail exactly on the
  ##   line's own projection -- both endpoints lie on it and a projected straight segment
  ##   is straight -- and it is what makes the growth read as even, which a world-space
  ##   interpolation toward a point that distant would not: almost the whole parameter
  ##   range would land within a few pixels of the vanishing point.
  ##   None at horizon, where a line draws as a great circle fixed to the eye, and none
  ##   where the eye lies on the line (see `directionAcross`).
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
    across = directionAcross(geometry, scale.eye)
  if anchor.isNone or axis.isNone or across.isNone: return

  let
    offset = offsetMarkerRail(anchor.get, scale, clearance)
    frame_camera = placement.frame(scale.eye)
  var marker = Marker(kind: MarkerKind.Rails)
  for side in [offset, -offset]:
    for reach in [scale.radius_horizon, -scale.radius_horizon]:
      let clipped = clipToEyeSide(
        anchor.get + side*across.get, scale.eye + reach*axis.get, scale.eye,
        frame_camera.forward, placement.distanceNear,
      )
      if clipped.isNone: continue
      let (position_tail, position_head) = clipped.get
      let
        tail = projectToScreen(view_projection, width, height, position_tail)
        head = projectToScreen(view_projection, width, height, position_head)
      if not (tail.isInFront and head.isInFront): continue
      marker.segments[marker.count_segment] = [tail, tail.towards(head, progress)]
      inc marker.count_segment
  if marker.count_segment == 0: return
  some(marker)



#[ Plane ]#

func radiusMarkerLoop*(
  centre: Position; scale: DrawExtent; placement: Camera; height: int;
  clearance: float = 0.0
): float =
  ## Size a plane's own marker circle so its gap reads as `GAP_MARKER` pixels at the
  ## disc's own depth.
  ##   The circle lies on the plane, so its clearance has to be a world distance; that
  ##   distance is only worth one fixed pixel count at one depth, and the disc's centre
  ##   is the depth a reader judges the gap at. Everywhere else around the ellipse the
  ##   gap foreshortens exactly as the disc does, which is the point -- a constant pixel
  ##   ring would sit off the plane and read as floating above it.
  ##   `clearance` widens that gap by that many further pixels, for a touch hold, through
  ##   the same conversion so the swollen circle still lies on the plane.
  EXTENT_PLANE_F + (GAP_MARKER + clearance)*worldPerPixelAt(centre, scale)


func positionsMarkerLoop*(
  centre: Position; axes: FramePlane; radius: float
): array[SEGMENTS_MARKER_LOOP, Position] =
  ## Trace a plane's own marker circle in world space, in order around it.
  ##   Every point is `centre` plus a combination of the two axes spanning the plane, so
  ##   the whole circle lies *on* the plane by construction rather than by adjustment --
  ##   which is what makes the marker read as painted onto the surface rather than as a
  ##   hoop floating near it. Asserted directly in the suite, point by point.
  for i in 0 ..< SEGMENTS_MARKER_LOOP:
    let angle = (2.0*PI*float(i))/float(SEGMENTS_MARKER_LOOP)
    result[i] = centre + radius*(cos(angle)*axes.axis_first + sin(angle)*axes.axis_second)


func markerLoop(
  geometry: Multivector; anchor_override: Option[Position]; scale: DrawExtent;
  placement: Camera; view_projection: Matrix4; width, height: int;
  progress, clearance: float
): Option[Marker] =
  ## Build a plane's own marker circle, concentric with the disc actually drawn.
  ##   Reads `anchor_override` exactly as `mesh.addPlane` does, so the marker is
  ##   concentric with the drawn disc rather than with the plane's own support -- for a
  ##   plane built from operands that do not straddle the origin those are different
  ##   points, and a marker around the wrong one names nothing.
  ##   Cuts the circle to whatever stays in front of the eye and reports the remainder as
  ##   an arc, rather than dropping the marker outright: a camera close to a large plane
  ##   puts part of its rim behind the eye, which is exactly when the selection still
  ##   needs saying.
  ##   `progress` scales the circle's own radius, so a filling hold opens it outward from
  ##   the disc's centre until it reaches the rim it will finally stand outside. In world
  ##   units on the plane, which keeps every intermediate circle lying on that plane as
  ##   exactly as the finished one does -- growing it on screen instead would lift it off
  ##   the surface for the whole of the animation and only settle at the end.
  ##   None at horizon, where a plane draws as a dome fixed to the eye.
  let
    anchor = if anchor_override.isSome: anchor_override else: positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isNone or axes.isNone: return

  let positions = positionsMarkerLoop(
    anchor.get, axes.get,
    progress*radiusMarkerLoop(anchor.get, scale, placement, height, clearance),
  )
  var
    ring: array[SEGMENTS_MARKER_LOOP, ScreenPosition]
    are_in_front: array[SEGMENTS_MARKER_LOOP, bool]
    count_in_front = 0
  for i in 0 ..< SEGMENTS_MARKER_LOOP:
    ring[i] = projectToScreen(view_projection, width, height, positions[i])
    are_in_front[i] = ring[i].isInFront
    if are_in_front[i]: inc count_in_front
  if count_in_front == 0: return

  var marker = Marker(
    kind: MarkerKind.Loop, is_closed: count_in_front == SEGMENTS_MARKER_LOOP
  )
  # Start the arc at the first point whose predecessor was cut, so the surviving run is
  #   emitted unbroken instead of wrapping the cut and drawing a chord across the view.
  var start = 0
  if not marker.is_closed:
    for i in 0 ..< SEGMENTS_MARKER_LOOP:
      let before = (i + SEGMENTS_MARKER_LOOP - 1) mod SEGMENTS_MARKER_LOOP
      if are_in_front[i] and not are_in_front[before]:
        start = i
        break
  for step in 0 ..< SEGMENTS_MARKER_LOOP:
    let i = (start + step) mod SEGMENTS_MARKER_LOOP
    if not are_in_front[i]: break
    marker.points[marker.count_point] = ring[i]
    inc marker.count_point
  some(marker)



#[ Horizon ]#

func angleMarkerBands*(scale: DrawExtent; progress, clearance: float): float =
  ## Size how far off a horizon line its two bands stand, in radians, at this progress.
  ##   Closes from `ANGLE_MARKER_BANDS_OPEN` -- the pole of the sky the line's own great
  ##   circle runs around, and so outside any view of it -- in to the separation that
  ##   reads as `OFFSET_MARKER_RAIL` pixels, the very gap a *finite* line's rails keep. So
  ##   the two kinds of line wear the same marker at the same weight, and only the way it
  ##   arrives differs: a finite line's rails run outward from a support, and a horizon
  ##   line, having none, is enclosed from outside instead.
  ##   An angle rather than a screen offset because horizon geometry is placed by
  ##   direction: `radiansPerPixel` is what converts the pixel gap the rest of the family
  ##   is specified in, and it holds under any camera rather than at one distance.
  let angle_closed = (OFFSET_MARKER_RAIL + clearance)*radiansPerPixel(scale)
  angle_closed + (1.0 - clamp(progress, 0.0, 1.0))*(ANGLE_MARKER_BANDS_OPEN - angle_closed)


func markerBands(
  geometry: Multivector; scale: DrawExtent; view_projection: Matrix4; width, height: int;
  progress, clearance: float
): Option[Marker] =
  ## Build a horizon line's own pair of bands: two circles on the sky, one each side of
  ## the great circle the line itself is drawn as.
  ##   Each band is a *small* circle of the same sphere -- centre stepped along the great
  ##   circle's own normal, radius shrunk to stay on that sphere -- which is what parallel
  ##   to a great circle means there. Built from `directionNormalHorizon` and
  ##   `spanPerpendicular`, the same pair `mesh.addLine` builds its great circle from, so
  ##   the three wrap the sky as one family rather than merely near one another.
  ##   Cuts each band to whatever stays in front of the eye and reports the remainder as
  ##   an arc, exactly as `markerLoop` does -- half the sky is behind the camera at all
  ##   times, so this is the common case here rather than an edge one.
  let normal = directionNormalHorizon(geometry)
  if normal.isNone: return
  let axes = spanPerpendicular(ORIGIN_WORLD, normal.get)
  if axes.isNone: return
  let
    (axis_first, axis_second) = axes.get
    angle = angleMarkerBands(scale, progress, clearance)
    radius = scale.radius_horizon*cos(angle)
    offset = scale.radius_horizon*sin(angle)

  var marker = Marker(kind: MarkerKind.Bands)
  for side in 0 .. 1:
    let centre = scale.eye + (if side == 0: offset else: -offset)*normal.get
    var
      ring: array[SEGMENTS_MARKER_BANDS, ScreenPosition]
      are_in_front: array[SEGMENTS_MARKER_BANDS, bool]
      count_in_front = 0
    for i in 0 ..< SEGMENTS_MARKER_BANDS:
      let turn = (2.0*PI*float(i))/float(SEGMENTS_MARKER_BANDS)
      ring[i] = projectToScreen(
        view_projection, width, height,
        centre + radius*(cos(turn)*axis_first + sin(turn)*axis_second),
      )
      are_in_front[i] = ring[i].isInFront
      if are_in_front[i]: inc count_in_front
    if count_in_front == 0: continue

    marker.are_closed_band[side] = count_in_front == SEGMENTS_MARKER_BANDS
    # Start where the run of surviving points begins, so an arc is emitted unbroken rather
    #   than wrapping the cut and drawing a chord across the view -- `markerLoop`'s rule.
    var start = 0
    if not marker.are_closed_band[side]:
      for i in 0 ..< SEGMENTS_MARKER_BANDS:
        let before = (i + SEGMENTS_MARKER_BANDS - 1) mod SEGMENTS_MARKER_BANDS
        if are_in_front[i] and not are_in_front[before]:
          start = i
          break
    for step in 0 ..< SEGMENTS_MARKER_BANDS:
      let i = (start + step) mod SEGMENTS_MARKER_BANDS
      if not are_in_front[i]: break
      marker.points_band[side][marker.counts_band[side]] = ring[i]
      inc marker.counts_band[side]
  if marker.counts_band[0] == 0 and marker.counts_band[1] == 0: return
  some(marker)


func markerFrame(width, height: int; progress, clearance: float): Option[Marker] =
  ## Build a horizon plane's own frame: a rectangle around the viewport itself.
  ##   A plane at horizon is the whole sky, the same universal object however it was
  ##   built, and it is drawn as a dome filling every direction -- so there is no place in
  ##   the scene for an outline to surround, and the honest marker surrounds the view. It
  ##   does not move with the camera, which is right rather than a shortcut: what it marks
  ##   does not either.
  ##   `progress` scales it about the centre of the view, so a filling hold opens it
  ##   outward from the middle -- the same mechanic as a finite plane's circle opening
  ##   from the centre of its disc, and the exact opposite of the bands above, which is
  ##   what tells the two horizon shapes apart while they fill.
  ##   `clearance` pushes it outward past the inset, which on this shape means past the
  ##   edge of the screen: a frame is never under a finger, and shrinking the inset would
  ##   read as the marker retreating rather than swelling.
  let
    inset = GAP_MARKER - clearance
    (centre_x, centre_y) = (0.5*float(width), 0.5*float(height))
    reach = clamp(progress, 0.0, 1.0)
    half_width = reach*(centre_x - inset)
    half_height = reach*(centre_y - inset)
  func at(x, y: float): ScreenPosition = ScreenPosition(x: x, y: y, depth: 1.0)
  some(Marker(kind: MarkerKind.Frame, corners: [
    at(centre_x - half_width, centre_y - half_height),
    at(centre_x + half_width, centre_y - half_height),
    at(centre_x + half_width, centre_y + half_height),
    at(centre_x - half_width, centre_y + half_height),
  ]))



#[ Marker Dispatch ]#

func markerFor*(
  geometry: Multivector; anchor_override: Option[Position]; scale: DrawExtent;
  placement: Camera; view_projection: Matrix4; width, height: int; progress: float = 1.0;
  is_touch: bool = false
): Option[Marker] =
  ## Shape the marker for one object, dispatching on the geometry its grade stands for
  ## and on whether that geometry stands at horizon.
  ##   `anchor_override` is the item's own stored creation anchor, used for a plane and
  ##   ignored for a point or line, matching `mesh.addObject`'s own treatment of it.
  ##   `progress` draws the marker part-built, for a press maturing into a selection: 1
  ##   is the finished marker and is what every caller not animating a hold wants, which
  ##   is why it is the default. How a partial marker is shaped is each outline's own
  ##   business -- a ring sweeps, rails run outward, a circle opens, bands close inward,
  ##   a frame opens from the middle -- because what reads as *filling* differs by shape
  ##   as much as what reads as *surrounding* does.
  ##   `is_touch` says the hold is a finger's, which swells every outline clear of it
  ##   partway through; see `clearanceTouch`. One flag rather than a per-shape rule,
  ##   because what it compensates for -- a fingertip over the thing being marked -- does
  ##   not vary by what is under it.
  ##   None only where the object has no drawable geometry at all. Every shape that *is*
  ##   drawn now has a marker, horizon or not.
  let shape = shape(geometry)
  if shape.isNone: return
  let
    is_horizon = geometry.isHorizon
    clearance = clearanceTouch(progress, is_touch)
  case shape.get
  # A point at horizon is drawn as a fixed star, which `anchorFor` already places, so its
  #   ring needs no horizon branch of its own -- unlike the two below, which are drawn as
  #   a great circle and a whole sky and have no anchor at all.
  of Shape.Point:
    markerRing(geometry, scale, view_projection, width, height, progress, clearance)
  of Shape.Line:
    if is_horizon:
      markerBands(geometry, scale, view_projection, width, height, progress, clearance)
    else:
      markerRails(
        geometry, scale, placement, view_projection, width, height, progress, clearance
      )
  of Shape.Plane:
    if is_horizon: markerFrame(width, height, progress, clearance)
    else:
      markerLoop(
        geometry, anchor_override, scale, placement, view_projection, width, height,
        progress, clearance,
      )
