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
  GAP_MARKER* = 11.5
    ## Set clear space between an object's own drawn edge and its marker, in pixels.
    ##   One number for all three shapes: what makes a selection legible is a consistent
    ##   band of untouched background around whatever is selected, and a marker that
    ##   hugged a point more tightly than it hugged a line would read as two mechanisms.
    ##   Chosen so a point's own ring lands at 16 px, where it has always sat.
  WIDTH_MARKER* = 2.0'f32
    ## Set thickness of every marker outline, and of the drag rubber-band beside it, in
    ## pixels.
  ALPHA_MARKER_HOVER* = 0.8'f32
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
  RADIUS_MARKER_POINT* = 0.5*float(SIZE_POINT) + GAP_MARKER
    ## Place a point's own ring this far from the point, in pixels.
  OFFSET_MARKER_RAIL* = 0.5*float(WIDTH_LINE_OBJECT) + GAP_MARKER
    ## Place each of a line's own rails this far from the line's own projection, in
    ## pixels, measured perpendicular to it on screen.

static:
  doAssert GAP_MARKER > 0, &"Marker clearance must be positive; got `{GAP_MARKER}`."
  doAssert SEGMENTS_MARKER_LOOP >= 12,
    &"A plane's marker needs 12 segments to read as a circle; got " &
    &"`{SEGMENTS_MARKER_LOOP}`."



#[ Type Definitions ]#

type
  MarkerKind* {.pure.} = enum ## Name which outline a marker is drawn as.
    Ring, ## Circle in screen space, for a point.
    Rails, ## Pair of straight segments in screen space, for a line.
    Loop, ## Polyline lying on a plane in world space, projected, for a plane.

  Marker* = object ## Hold one object's marker, ready to draw on the foreground layer.
    case kind*: MarkerKind
    of MarkerKind.Ring:
      centre*: ScreenPosition ## Where the point itself projects.
      radius*: float ## Ring radius, in pixels.
    of MarkerKind.Rails:
      rail_first*, rail_second*: array[2, ScreenPosition]
        ## Endpoints of each rail; the two run parallel on screen, one to each side.
    of MarkerKind.Loop:
      count*: int ## Points used of `points` below.
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


func markerRails(
  geometry: Multivector; scale: DrawExtent; placement: Camera;
  view_projection: Matrix4; width, height: int
): Option[Marker] =
  ## Build a line's own pair of rails, flanking its projection at a constant pixel gap.
  ##   Offset in screen space rather than in world space: a world offset foreshortens,
  ##   so the two rails would converge toward the line's own vanishing point and meet it,
  ##   which reads as an arrowhead rather than as a highlight. Perpendicular on screen
  ##   holds the gap even along the whole visible run.
  ##   Spans exactly what `mesh.addLine` draws -- both halves, support out to each of the
  ##   line's own two vanishing points -- found by projecting each half's clipped ends and
  ##   keeping the two furthest apart. Those ends are collinear on screen to floating-point
  ##   precision (see `mesh.addLine`), so the furthest-apart pair is the visible run and
  ##   the rails cover the line exactly however the clip fell.
  ##   None at horizon, where a line draws as a great circle fixed to the eye.
  let (anchor, axis) = (positionAnchor(geometry), direction(geometry))
  if anchor.isNone or axis.isNone: return

  var
    ends: array[4, ScreenPosition]
    count = 0
  let frame_camera = placement.frame(scale.eye)
  for reach in [scale.radius_horizon, -scale.radius_horizon]:
    let clipped = clipToEyeSide(
      anchor.get, scale.eye + reach*axis.get, scale.eye, frame_camera.forward,
      placement.distanceNear,
    )
    if clipped.isNone: continue
    let (position_tail, position_head) = clipped.get
    let
      tail = projectToScreen(view_projection, width, height, position_tail)
      head = projectToScreen(view_projection, width, height, position_head)
    if not (tail.isInFront and head.isInFront): continue
    ends[count] = tail
    ends[count + 1] = head
    count += 2

  # Take the widest-separated pair as the run to flank, so a line whose halves were
  #   clipped unevenly still gets one rail each side over its whole visible length.
  var
    index_tail, index_head = 0
    separation = 0.0
  for i in 0 ..< count:
    for j in i + 1 ..< count:
      let reach = hypot(ends[j].x - ends[i].x, ends[j].y - ends[i].y)
      if reach > separation: (index_tail, index_head, separation) = (i, j, reach)
  if separation <= 1.0e-6: return

  let
    (tail, head) = (ends[index_tail], ends[index_head])
    across_x = -(head.y - tail.y)/separation*OFFSET_MARKER_RAIL
    across_y = (head.x - tail.x)/separation*OFFSET_MARKER_RAIL
  func shifted(point: ScreenPosition; x, y: float): ScreenPosition =
    ScreenPosition(x: point.x + x, y: point.y + y, depth: point.depth)
  some(Marker(
    kind: MarkerKind.Rails,
    rail_first: [shifted(tail, across_x, across_y), shifted(head, across_x, across_y)],
    rail_second: [shifted(tail, -across_x, -across_y), shifted(head, -across_x, -across_y)],
  ))



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
  let
    distance_eye = norm(centre - scale.eye)
    half_height = tan(0.5*degToRad(placement.degrees_field_of_view))
  EXTENT_PLANE_F + GAP_MARKER*(2.0*distance_eye*half_height/float(height))


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
    marker.points[marker.count] = ring[i]
    inc marker.count
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
