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
##   | Anything at      | none -- all three draw fixed to the eye rather than anywhere   |
##   |   horizon        |   a marker could surround (a point at horizon keeps its star). |
##   |------------------|---------------------------------------------------------------|
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

import ../pga
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

  Marker* = object ## Hold one object's marker, ready to draw on the foreground layer.
    case kind*: MarkerKind
    of MarkerKind.Ring:
      centre*: ScreenPosition ## Where the point itself projects.
      radius*: float ## Ring radius, in pixels.
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



#[ Point And Line ]#

func markerRing(
  geometry: Multivector; scale: DrawExtent; view_projection: Matrix4; width, height: int
): Option[Marker] =
  ## Build a point's own ring, about wherever that point is drawn.
  ##   Screen-space rather than a world-space circle facing the camera, because a point
  ##   has no orientation to echo: any world circle would have to pick a facing, and
  ##   every choice looks the same from the one angle it is seen from anyway.
  let anchor = anchorFor(geometry, scale)
  if anchor.isNone: return
  let centre = projectToScreen(view_projection, width, height, anchor.get)
  if not centre.isInFront: return
  some(Marker(kind: MarkerKind.Ring, centre: centre, radius: RADIUS_MARKER_POINT))


func worldPerPixel*(
  place: Position; scale: DrawExtent; placement: Camera; height: int
): float =
  ## Measure how much world distance one screen pixel spans at `place`'s own depth.
  ##   How a marker turns a clearance stated in pixels into the world offset it has to
  ##   use, wherever it is anchored in space rather than on screen.
  ##   Depth along the sight axis, not distance from the eye: perspective divides by the
  ##   former, and the two differ by the cosine of how far off-axis the point sits --
  ##   over a percent even near the middle of the frame, which is a visible fraction of
  ##   a gap this tight.
  let
    depth = dot(place - scale.eye, placement.frame(scale.eye).forward)
    half_height = tan(0.5*degToRad(placement.degrees_field_of_view))
  2.0*depth*half_height/float(height)


func offsetMarkerRail*(
  anchor: Position; scale: DrawExtent; placement: Camera; height: int
): float =
  ## Size how far to each side of a line its rails stand, in world units.
  ##   Reads as `OFFSET_MARKER_RAIL` pixels where the line's own support is, and closes
  ##   with distance from there exactly as the line's own foreshortening does. That is
  ##   the point of a world offset: parallel lines share a vanishing point, so the rails
  ##   converge on the same one the line runs to and the three read as one object seen
  ##   in perspective. A constant screen offset instead holds the pair open all the way
  ##   to the horizon, where the line has long since narrowed to nothing.
  OFFSET_MARKER_RAIL*worldPerPixel(anchor, scale, placement, height)


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
  view_projection: Matrix4; width, height: int
): Option[Marker] =
  ## Build a line's own pair of rails: two lines parallel to it in world space, one to
  ## each side, converging with it toward its own vanishing points.
  ##   Each rail is drawn exactly as `mesh.addLine` draws the line itself -- its own
  ##   anchor out to each of the two vanishing points, which parallel lines share -- so
  ##   the three meet at the same two points on screen rather than merely running near
  ##   one another, and each rail projects onto its own true line for the same reason
  ##   the drawn line does.
  ##   None at horizon, where a line draws as a great circle fixed to the eye, and none
  ##   where the eye lies on the line (see `directionAcross`).
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
    across = directionAcross(geometry, scale.eye)
  if anchor.isNone or axis.isNone or across.isNone: return

  let
    offset = offsetMarkerRail(anchor.get, scale, placement, height)
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
      marker.segments[marker.count_segment] = [tail, head]
      inc marker.count_segment
  if marker.count_segment == 0: return
  some(marker)



#[ Plane ]#

func radiusMarkerLoop*(
  centre: Position; scale: DrawExtent; placement: Camera; height: int
): float =
  ## Size a plane's own marker circle so its gap reads as `GAP_MARKER` pixels at the
  ## disc's own depth.
  ##   The circle lies on the plane, so its clearance has to be a world distance; that
  ##   distance is only worth one fixed pixel count at one depth, and the disc's centre
  ##   is the depth a reader judges the gap at. Everywhere else around the ellipse the
  ##   gap foreshortens exactly as the disc does, which is the point -- a constant pixel
  ##   ring would sit off the plane and read as floating above it.
  EXTENT_PLANE_F + GAP_MARKER*worldPerPixel(centre, scale, placement, height)


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
  placement: Camera; view_projection: Matrix4; width, height: int
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
  ##   None at horizon, where a plane draws as a dome fixed to the eye.
  let
    anchor = if anchor_override.isSome: anchor_override else: positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isNone or axes.isNone: return

  let positions = positionsMarkerLoop(
    anchor.get, axes.get, radiusMarkerLoop(anchor.get, scale, placement, height)
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



#[ Marker Dispatch ]#

func markerFor*(
  geometry: Multivector; anchor_override: Option[Position]; scale: DrawExtent;
  placement: Camera; view_projection: Matrix4; width, height: int
): Option[Marker] =
  ## Shape the marker for one object, dispatching on the geometry its grade stands for.
  ##   `anchor_override` is the item's own stored creation anchor, used for a plane and
  ##   ignored for a point or line, matching `mesh.addObject`'s own treatment of it.
  ##   None where the object has no drawable geometry, or where it lies at horizon and
  ##   is drawn fixed to the eye with nothing a marker could surround. Both are the same
  ##   "nothing to draw" answer every overlay caller already handles.
  let shape = shape(geometry)
  if shape.isNone: return
  case shape.get
  of Shape.Point: markerRing(geometry, scale, view_projection, width, height)
  of Shape.Line: markerRails(geometry, scale, placement, view_projection, width, height)
  of Shape.Plane:
    markerLoop(
      geometry, anchor_override, scale, placement, view_projection, width, height
    )
