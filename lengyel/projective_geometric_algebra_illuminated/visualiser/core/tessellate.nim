## Turn geometry into a picture: read what an object is through the algebra, place every
## point of its drawing through the algebra, and hand plain places down to `mesh` to be
## packed into vertices.
##
## **This module is the geometry side of drawing.** It owns what a thing is and where it
## stands -- a scene object, a lattice line of the ground grid, a world axis, and everything
## at the horizon, where a point becomes a star, a line becomes the great circle of the
## directions it stands for, and a plane becomes the whole sky. Those are geometric objects
## and they are placed through the library, which is what this project exists to exercise.
##
## What it does *not* own is the picture drawn to stand for them. A disc is not a plane and
## a ribbon is not a line: both are stand-ins sized for an eye, carrying no geometric
## meaning of their own, and both are built in `mesh` out of ordinary arithmetic. See
## `euclid.nim`'s header for the split, and `boundary.nim` for the one place the two
## languages meet.
##
## Finite objects are tessellated about their support point, i.e. point nearest origin;
## objects at the horizon are drawn fixed to `DrawExtent.eye` instead, at
## `DrawExtent.radius_horizon`, so orbiting or dollying leaves each in the same apparent
## direction exactly as a real star at effectively infinite distance would.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`)
## render paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "codeReordering".}
{.experimental: "strictFuncs".}

import std/[math, options]

import ../../pga
import ./[boundary, mesh, timings]

export mesh



#[ Type Definitions ]#

type
  DrawExtent* = object ## Hold a frame's camera in both languages at once.
    ## The Euclidean half is `mesh.DrawScale`, carried whole so a caller holding an extent
    ## still says `scale.eye`; the four multivector twins beside it are the algebra's own
    ## reading of the very same camera, derived once per frame in `camera.drawExtentFor` so
    ## nothing downstream rebuilds `toMultivector(eye)` -- or worse, a whole plane -- per
    ## segment.
    scale*: DrawScale ## Everything the picture is measured against; see `mesh.DrawScale`.
    eye_point*: Multivector ## The eye as a unit-weight point.
    forward_point*: Multivector ## The sight direction as a point at the horizon.
    plane_eye*: Multivector ## The unitized plane through the eye perpendicular to the
      ## sight direction: `depthAgainst` it is view depth, and its sign is "in front".
    plane_near*: Multivector ## The same plane pushed `depth_near` forward: the near clip
      ## as the algebra states it, for `clipToEyeSide`'s own meet.


# Read-through to the Euclidean half, so a caller holding a whole extent writes `scale.eye`
#   rather than `scale.scale.eye`. The split is about which module may *name* a multivector,
#   not about making every site spell out which half a field sits in.
func extent_furniture*(d: DrawExtent): float = d.scale.extent_furniture
func eye*(d: DrawExtent): Position = d.scale.eye
func radius_horizon*(d: DrawExtent): float = d.scale.radius_horizon
func forward*(d: DrawExtent): Direction = d.scale.forward
func tangent_half_view*(d: DrawExtent): float = d.scale.tangent_half_view
func height_pixels*(d: DrawExtent): int = d.scale.height_pixels
func depth_near*(d: DrawExtent): float = d.scale.depth_near

# And the whole half, implicitly, so an extent can be handed to any of `mesh`'s own procs
#   without every call site unwrapping it. Deliberate rather than incidental: an extent
#   *is* a scale with the algebra's reading of the same camera beside it, the conversion
#   only ever runs one way, and there is no second type it could be confused for.
converter toScale*(d: DrawExtent): DrawScale = d.scale



func algebraFilled*(scale: DrawExtent): DrawExtent =
  ## Return the extent with its four multivector twins derived from its own plain fields.
  ##   The one derivation point: `camera.drawExtentFor` goes through here, and so must any
  ##   hand-built extent -- a test fixture, a partial one -- or its twins are zero
  ##   multivectors and everything algebraic downstream silently draws nothing. Found
  ##   exactly that way: the suite's own fixtures built extents fieldwise and the ground
  ##   grid vanished from every one of them.
  result = scale
  result.eye_point = toMultivector(scale.eye)
  result.forward_point = toMultivector(scale.forward)
  result.plane_eye = planeThrough(result.eye_point, result.forward_point)
  result.plane_near = planeThrough(
    add(result.eye_point, wedge(scale.depth_near, result.forward_point)),
    result.forward_point,
  )



#[ Representative Point ]#

func anchorFor*(m: Multivector; scale: DrawExtent): Option[Position] =
  ## Resolve one point standing for `m`, for picking a point and for cursor feedback.
  ##   Point uses its own place, or its own star position at horizon where it has none,
  ##   matching exactly where `mesh.addPoint` draws it.
  ##   Line and plane use their support point, matching what mesh actually anchors on.
  ##   Neither needs a horizon anchor: `pickNearest` tests a horizon line against the great
  ##   circle it is drawn as and matches a horizon plane outright, so both are pickable
  ##   without ever asking for one representative point -- which is just as well, since
  ##   neither has one.
  ##   None where `m` carries no drawable geometry at all.
  let shape = shape(m)
  if shape.isNone: return
  case shape.get
  of Shape.Point:
    let place = position(m)
    if place.isSome: return place
    let heading = directionHorizon(m)
    if heading.isNone: return
    position(add(
      scale.eye_point, wedge(scale.radius_horizon, toMultivector(heading.get))
    ))
  of Shape.Line, Shape.Plane:
    positionAnchor(m)


func anchorFor*(
  m: Multivector; anchor_override: Option[Position]; scale: DrawExtent
): Option[Position] =
  ## Resolve one point standing for `m` **as it is actually drawn**, for anything that has
  ## to meet an object on screen: a rubber-band leaving it, a comet aimed from it, a menu
  ## hanging off it.
  ##   Reads `anchor_override` exactly as `addPlane` and `marker.markerFor` read it, so a
  ##   plane's disc has one centre and not two. It matters: on this project's own demo scene
  ##   the stored creation anchor stands 0.5, 2.7 and 3.7 units from the support, against a
  ##   disc of radius 8, so a band drawn from the support leaves from a point nowhere on the
  ##   circle a reader can see.
  ##   Ignored for every other shape, as `addObject` ignores it: a point and a line are
  ##   drawn about their own places whatever an item happens to carry.
  if anchor_override.isSome and shape(m) == some(Shape.Plane): return anchor_override
  anchorFor(m, scale)



#[ Segments and Circles ]#

proc addGreatCircle(
  meshes: var MeshSet; center: Position; axis_first, axis_second: Direction;
  radius: float; tint: Rgba
) =
  ## Append a closed ring of segments around `center`, in the plane `axis_first` and
  ## `axis_second` span, at `radius` -- the great circle a horizon line traces across
  ## the sky, seen from any point, standing for the pencil of directions it names.
  ##   The very walk `mesh.addPlaneRing` steps, delegated to it so the two circles cannot
  ##   drift: which plane the arms span is still the algebra's answer
  ##   (`spanPerpendicular`, at the caller), and the ring itself is arithmetic off the
  ##   fixed table of angles -- it used to be assembled as per-angle multivector sums,
  ##   which the suite holds that arithmetic equal to, and `picking.pickNearest` samples
  ##   its own copy of this circle the same way so a hit still agrees with what is drawn.
  meshes.addPlaneRing(center, axis_first, axis_second, radius, tint)


#[ World Furniture ]#

func alphaGridFade(radius, radius_fade_start, radius_end: float): float =
  ## Fall from full alpha at `radius_fade_start` to none at `radius_end` -- past the
  ## fade start, a grid line's own cells crowd into fewer and fewer screen pixels
  ## under perspective, reading as aliasing noise rather than as a reference; fading
  ## them out trades that noise for a clean horizon instead of fighting it.
  ##   `radius` is a distance **from the eye**, and the two bounds come from
  ##   `fogFurnitureFor`; see it for why the fog is centred there and not on the origin.
  ##   Shared with `addAxes`, which fades on the same schedule so that all the world
  ##   furniture ends at one horizon rather than the grid stopping while the axes run on.
  1.0 - clamp((radius - radius_fade_start) / (radius_end - radius_fade_start), 0.0, 1.0)


proc placeFadeLine(
  scratch: var DrawScratch; count_assembled: var int; centre, axis_point: Multivector;
  span: float; pieces: int; tint: Rgba;
  fog: tuple[radius_full, radius_gone: float]; scale: DrawExtent
) =
  ## Resolve one faded line into `scratch.ribbons`: `pieces` ribbon pieces running `span`
  ## either side of `centre` along `axis_point`, each end faded by its own distance from
  ## the eye. Silently stops at the scratch's end, for the reason `placeGridFamily` gives.
  ##   **Each boundary is assembled once.** Adjacent pieces share an end -- piece `j`'s
  ## head is piece `j + 1`'s tail, by the same formula -- and the loops this replaces
  ## assembled every interior boundary twice over: two multivector sums, two reads back
  ## across the language boundary and two fades where one of each suffices. Shared by the
  ## grid and the axes, whose per-piece loops were copies of each other but for the span.
  let count_boundaries = min(pieces, 2*SEGMENTS_GRID_FADE) + 1
  for j in 0 ..< count_boundaries:
    let at = add(centre, wedge(span*(2.0*float(j)/float(pieces) - 1.0), axis_point))
    scratch.places[j] = pointFrom(at)
    scratch.fade_tints[j] = tint.fade(tint.alpha * alphaGridFade(
      distanceBetween(at, scale.eye_point), fog.radius_full, fog.radius_gone))
    scratch.fade_depths[j] = dot(scratch.places[j] - scale.eye, scale.forward)
  for j in 0 ..< count_boundaries - 1:
    # **Whole pieces behind the eye are culled here, not carried.** The shader refuses
    #   them anyway, but a record it refuses still crossed the wire and still counted
    #   against the grid's own segment budget -- which is a budget of what is *drawn*.
    #   The coarse cull is the placement's; the exact per-end clip stays the shader's.
    if scratch.fade_depths[j] < scale.depth_near and
        scratch.fade_depths[j + 1] < scale.depth_near:
      continue
    if count_assembled >= len(scratch.ribbons): return
    scratch.ribbons[count_assembled] = RibbonPiece(
      tail: scratch.places[j],
      head: scratch.places[j + 1],
      tint_tail: scratch.fade_tints[j],
      tint_head: scratch.fade_tints[j + 1],
    )
    count_assembled += 1


proc placeAxes(scratch: var DrawScratch; extent: float; scale: DrawExtent): int =
  ## Resolve the world axes into `scratch` and report how many pieces: one through the
  ## origin along each of x, y and z, in the standard convention -- x red, y green, z
  ## blue -- so orientation reads at a glance regardless of where the camera stands.
  ##   **Draws nothing**; the algebra's half of the seam, as `placeGridFamily` is.
  ##   **Faded out and cut off in the ground grid's own fog**, rather than running the
  ## full furniture extent at flat alpha as they once did. An axis reaching the horizon at
  ## full strength is the longest, brightest mark in the frame, and readers were taking
  ## them for drawn lines -- width alone (`WIDTH_LINE_FURNITURE` against
  ## `WIDTH_LINE_OBJECT`) was never going to carry that on its own. Sharing the grid's own
  ## fog rather than taking radii of their own puts all the furniture inside one horizon,
  ## so reference reads as a neighbourhood around the *reader* and anything outside it is
  ## content.
  ##   Each axis is drawn only over the stretch of it lying inside that fog: a chord of
  ## the sphere of radius `radius_gone` about the eye, solved below. An axis the eye has
  ## flown clear of contributes nothing at all, which is what fog means -- the origin is
  ## a place in the world rather than a place the reader is tied to.
  const AXES_WORLD = [
    (Direction(x: 1, y: 0, z: 0), Ink.AxisX),
    (Direction(x: 0, y: 1, z: 0), Ink.AxisY),
    (Direction(x: 0, y: 0, z: 1), Ink.AxisZ),
  ]
  let fog = fogFurnitureFor(extent)
  var count_assembled = 0
  for (axis, ink) in AXES_WORLD:
    # Chord of the fog sphere along this axis, about the eye's own perpendicular foot on
    #   it: the axis passes the eye at `separation`, so it is inside the fog for `half`
    #   either side of the foot and nowhere else. The foot is the algebra's orthogonal
    #   projection of the eye onto the axis line; the chord half-length stays a scalar
    #   solve, since a sphere has no representative in the rigid algebra -- the one
    #   documented exception, and the incidence feeding it is the library's own.
    let
      axis_line = wedge(toMultivector(ORIGIN_WORLD), toMultivector(axis))
      foot_raw = projectOrthogonal(scale.eye_point, axis_line)
      foot = position(foot_raw)
    if foot.isNone: continue
    let
      separation = distanceBetween(unitize(foot_raw), scale.eye_point)
      half_squared = fog.radius_gone*fog.radius_gone - separation*separation
    if half_squared <= 0.0: continue
    let
      half = sqrt(half_squared)
      tint = ink.colour
      foot_point = unitize(foot_raw)
      axis_point = toMultivector(axis)
    # Cut into the same number of pieces the grid uses, each faded by its own endpoints'
    #   distance from the eye, so the cutoff never reads as a hard edge. No across is
    #   taken any more: which way a ribbon steps off moved to the vertex shader with the
    #   widening itself -- see `mesh.expandRibbon`, whose cross is the very one this
    #   hoisted per line.
    scratch.placeFadeLine(
      count_assembled, foot_point, axis_point, half, 2*SEGMENTS_GRID_FADE,
      tint, fog, scale,
    )

  count_assembled


proc addAxes*(
  meshes: var MeshSet; scratch: var DrawScratch; extent: float; scale: DrawExtent
) =
  ## Append the world axes; `placeAxes` says what each is and how far it runs.
  ##   Two calls, for the reason `addGridFamily`'s own note gives.
  var count_assembled = 0
  timed(Side.Placing): count_assembled = placeAxes(scratch, extent, scale)
  timed(Side.Emitting):
    meshes.addRibbonPieces(
      scratch.ribbons.toOpenArray(0, count_assembled - 1), WIDTH_LINE_FURNITURE,
    )


func radiusOnPlaneFor*(extent: float; scale: DrawExtent; plane: Multivector): Option[float] =
  ## Solve how far a lattice laid on `plane` reaches from the eye's own foot on it.
  ##   The fog is a sphere about the eye, so what it leaves on any plane is a disc about
  ## that foot, of radius `sqrt(radius_gone^2 - height^2)` -- the height being the eye's
  ## depth against the plane, which is the algebra's own answer for any plane and not the
  ## ground's alone. None where the eye stands further off than the fog reaches, and there
  ## is nothing of that plane to draw.
  let
    fog = fogFurnitureFor(extent)
    height = abs(depthAgainst(plane, scale.eye_point))
    radius_squared = fog.radius_gone*fog.radius_gone - height*height
  if radius_squared <= 0.0: return
  some(sqrt(radius_squared))


func radiusGroundFor*(extent: float; scale: DrawExtent): Option[float] =
  ## Solve how far the ground grid reaches from the point directly below the eye, in world
  ## units, for a camera whose furniture extends `extent`.
  ##   Drawn on the ground plane, so what the fog sphere leaves is a **disc** about that
  ## point, of radius `sqrt(radius_gone^2 - height^2)`, the height read as the eye's own
  ## depth against `objects.groundPlane`. None where the eye stands higher than the fog
  ## reaches and there is no ground to draw at all.
  ##   Stated here rather than inside `addGrid` because the cell size a reader is shown on
  ## the scale bar has to be the cell the grid was drawn with, and two derivations of the
  ## same disc are two chances to disagree -- the argument `algebraFilled` and
  ## `extentViewOverlay` already make for their own shared answers.
  radiusOnPlaneFor(extent, scale, groundPlane())


func sizeCellGridAt*(extent: float; scale: DrawExtent): Option[float] =
  ## Report the cell size the ground grid is laid on for this camera, in world units, or
  ## none where no ground is drawn. The one answer both the grid and the scale bar read.
  let radius_ground = radiusGroundFor(extent, scale)
  if radius_ground.isNone: return
  some(sizeCellGridFor(radius_ground.get))


func segmentsGridFadeFor*(count_lines: int): int =
  ## Choose how many pieces each of `count_lines` grid lines is cut into for its fade.
  ##   `SEGMENTS_GRID_FADE` wherever the whole family fits inside its half of
  ## `SEGMENTS_GRID_MAX`, and as few as `SEGMENTS_GRID_FADE_MIN` where it does not. The
  ## budget is halved because the grid is two families laid the same way, and neither
  ## knows what the other will draw.
  ##   A pure function of the count so the rule can be held on its own by the suite,
  ## rather than only observable through a vertex total.
  if count_lines <= 0: return SEGMENTS_GRID_FADE
  let allowed = (SEGMENTS_GRID_MAX div 2) div count_lines
  max(SEGMENTS_GRID_FADE_MIN, min(SEGMENTS_GRID_FADE, allowed))


proc placeGridFamily(
  scratch: var DrawScratch; scale: DrawExtent; tint: Rgba;
  fog: tuple[radius_full, radius_gone: float]; radius_ground, size_cell: float;
  along, across: Direction; origin: Position
): int =
  ## Resolve every piece of one family of lattice lines into `scratch`, and report how
  ## many: every line running along `along`, stepped by `size_cell` along `across`, that
  ## falls within `radius_ground` of the eye's own foot on the plane the two span.
  ##   **Draws nothing.** This is the algebra's half of the seam. Almost all of it is
  ## multivector work, with two Euclidean exceptions that ride along because they sit
  ## inside the loop: a line's across-vector is one cross product, and each piece's two
  ## fade colours are scalar. Both are named where they happen, and both are charged to
  ## this side -- which is worth knowing when reading what the panel says it cost.
  ##   Exported for `algebra_view`, whose debug layer lays this same lattice on an
  ##   arbitrary plane to draw it as the infinite thing it is -- the ground is that case
  ##   with `origin` at the world origin and the two world axes for its span.
  ##   The cell is passed in rather than read from `SIZE_CELL_GRID` so that both families
  ## are laid on the one `sizeCellGridFor` answered for this frame's disc; two calls could
  ## not disagree, but a reader of one family should not have to prove that.
  ##   The two families are laid separately, unlike the single origin-centred loop this
  ## replaced, because each is now centred on a different one of the eye's own ground
  ## coordinates and no longer shares the other's offsets.
  ##   Lines still sit on **world** multiples of the cell size rather than on offsets from
  ## the camera, so what the reader sees slide past as they move is the world going by,
  ## not a grid dragged along with them -- and a line stays where it was when they come
  ## back to it.
  # The eye resolved onto the two lattice axes: its depth against the plane through the
  #   origin perpendicular to each -- the algebra's statement of a coordinate. One plane
  #   per family per frame, hoisted here rather than rebuilt per lattice line.
  let
    origin_point = toMultivector(origin)
    along_point = toMultivector(along)
    across_point = toMultivector(across)
    centre_across = depthAgainst(planeThrough(origin_point, across_point), scale.eye_point)
    centre_along = depthAgainst(planeThrough(origin_point, along_point), scale.eye_point)
    first = int(ceil((centre_across - radius_ground)/size_cell))
    last = int(floor((centre_across + radius_ground)/size_cell))
    # How finely each line is cut for its fade, decided once for the family from how many
    #   lines it is about to lay: the budget is a property of the family, and a per-line
    #   answer would cut neighbouring lines differently and band the fade across the grid.
    segments_fade = segmentsGridFadeFor(last - first + 1)
  var count_assembled = 0
  for i in first .. last:
    # Skips the lattice line through the world origin: it coincides exactly with a world
    #   axis, and would either fight it for the same depth or hide its colour under plain
    #   grid grey, depending on which happened to draw last.
    if i == 0: continue
    let
      offset = float(i)*size_cell
      reach_squared = radius_ground*radius_ground -
        (offset - centre_across)*(offset - centre_across)
    if reach_squared <= 0.0: continue
    let
      reach = sqrt(reach_squared)
      base = add(origin_point,
        add(wedge(offset, across_point), wedge(centre_along, along_point)))
    # Assembled, not drawn -- see `placeFadeLine`, which also stops silently at the
    #   scratch's end: the caller sized it from `SEGMENTS_GRID_MAX`, the same budget
    #   `segmentsGridFadeFor` cuts the fade to, so a full buffer means that budget was
    #   raised and this was not. The across the line used to hoist moved to the vertex
    #   shader with the widening; collinear pieces provably share it there too, since
    #   `cross(along, eye - t*along)` does not depend on `t`.
    scratch.placeFadeLine(
      count_assembled, base, along_point, reach, segments_fade,
      tint, fog, scale,
    )

  count_assembled


proc addGridFamily*(
  meshes: var MeshSet; scratch: var DrawScratch; scale: DrawExtent; tint: Rgba;
  fog: tuple[radius_full, radius_gone: float]; radius_ground, size_cell: float;
  along, across: Direction; origin: Position = ORIGIN_WORLD
) =
  ## Append one family of lattice lines; `placeGridFamily` says what a family is.
  ##   **The seam, as two calls.** Where the pieces go is worked out by one proc and drawn
  ##   by another, so the line between the algebra and the picture runs between two
  ##   functions rather than through the middle of one -- and each side can be timed with
  ##   a bracket that encloses none of the other's work. See `timings`.
  var count_assembled = 0
  timed(Side.Placing):
    count_assembled = placeGridFamily(
      scratch, scale, tint, fog, radius_ground, size_cell, along, across, origin,
    )
  timed(Side.Emitting):
    meshes.addRibbonPieces(
      scratch.ribbons.toOpenArray(0, count_assembled - 1), WIDTH_LINE_FURNITURE,
    )


proc addGrid*(
  meshes: var MeshSet; scratch: var DrawScratch; extent: float; scale: DrawExtent
) =
  ## Append reference grid on the ground, so distance and direction stay judgeable, at
  ## `sizeCellGridFor` cells laid around wherever the camera is standing.
  ##   **Fog, not a halo.** Every line is faded by its own endpoints' distance from the
  ## eye and cut off entirely at `fogFurnitureFor`'s outer radius -- so the ground is
  ## solid underfoot and gone in the distance, wherever the reader has flown to. Cutting
  ## the geometry rather than drawing it at ever-fainter alpha is deliberate: past that
  ## radius cells crowd into so few screen pixels under perspective that even a faint line
  ## still aliases.
  ##   Drawn on the ground plane, so what the fog sphere leaves is a **disc** about the
  ## point below the eye, of radius `sqrt(radius_gone^2 - height^2)`: a camera high above
  ## the ground sees less of it than one standing on it, exactly as fog would leave.
  ## An eye higher than the fog reaches sees no ground at all.
  ##   Dimmed by `ALPHA_GRID` on top of that fade, so the ruled ground reads as reference
  ## rather than as content; see that constant for why it is applied here and not to the
  ## palette entry.
  let
    base = Ink.Grid.colour
    tint = base.fade(base.alpha*ALPHA_GRID)
    fog = fogFurnitureFor(extent)
    # The disc the fog leaves on the ground, and the cell laid across it -- both through
    #   `radiusGroundFor`, so what a reader is told the cell is and what the grid is drawn
    #   with cannot come apart.
    reach = radiusGroundFor(extent, scale)
  if reach.isNone: return
  let
    radius_ground = reach.get
    size_cell = sizeCellGridFor(radius_ground)
  # One family at a time through the one scratch: each assembles, emits, and is done with
  #   it before the next begins, so the buffer is sized for the larger family rather than
  #   for both at once.
  meshes.addGridFamily(
    scratch, scale, tint, fog, radius_ground, size_cell,
    along = Direction(x: 0, y: 1, z: 0), across = Direction(x: 1, y: 0, z: 0),
  )
  meshes.addGridFamily(
    scratch, scale, tint, fog, radius_ground, size_cell,
    along = Direction(x: 1, y: 0, z: 0), across = Direction(x: 0, y: 1, z: 0),
  )



#[ Object Tessellation ]#

proc addPoint(
  meshes: var MeshSet; geometry: Multivector; tint: Rgba; progress: float; scale: DrawExtent
): Placement =
  ## Append grade-1 object as marker, or, at horizon, as a marker fixed at `scale.eye`
  ## plus its own direction scaled out to `scale.radius_horizon` -- a star effectively
  ## infinitely far away, staying in the same apparent direction as the camera pans or
  ## dollies, moving only as the eye itself does.
  ##   `progress` fades a marker in and, at horizon, also grows how far out it stands.
  var place = none(Position)
  timed(Side.Placing): place = position(geometry)
  if place.isSome:
    timed(Side.Emitting): meshes.addMarker(place.get, tint.fade(tint.alpha*progress))
    return Placement.Finite

  var star = none(Position)
  timed(Side.Placing):
    let heading = directionHorizon(geometry)
    if heading.isSome:
      star = some(pointFrom(add(scale.eye_point,
        wedge(progress*scale.radius_horizon, toMultivector(heading.get)))))
  if star.isNone: return Placement.Empty
  timed(Side.Emitting): meshes.addMarker(star.get, tint.fade(tint.alpha*progress))
  Placement.Horizon


proc addLine(
  meshes: var MeshSet; scratch: var DrawScratch; geometry: Multivector; tint: Rgba;
  progress: float; scale: DrawExtent
): Placement =
  ## Append grade-2 object as two segments meeting on the line at its support, each
  ## running out to one of the line's own two vanishing points, `scale.eye` plus and
  ## minus `scale.radius_horizon` along its attitude. The forward one is exactly where
  ## `addPoint` draws this line's attitude as a horizon marker, so the drawn line
  ## reaches its own attitude with no gap.
  ##   Two segments rather than one because a vanishing point is a property of the
  ## *eye*, not of the line: an end anchored a fixed reach from the support instead
  ## stops short of it by roughly the eye-to-line separation over that reach, which is
  ## a visible gap as soon as the line's support is not close to the camera. Anchoring
  ## both ends to the eye is what closes it at both, and a single segment cannot -- one
  ## running eye-to-eye passes through the eye and projects to a point.
  ##   Each segment has one end on the true line and one at `eye ± radius*axis`, so both
  ## lie in the plane through the eye containing the line. That plane projects to a
  ## single screen line, so the pair draws exactly over the true line's own projection
  ## however far the far ends sit from it in world space -- verified as zero screen skew
  ## to floating-point precision, not argued. What it costs is depth: the far ends are
  ## displaced along the view ray, so occlusion against other objects is approximate
  ## there. Rebuilt every frame against the current eye, so this holds as the camera
  ## orbits.
  ##   Or, at horizon, as a great circle around `scale.eye` -- the pencil of directions
  ##   the line stands for, traced across the sky at `scale.radius_horizon`.
  ##   `progress` grows the segment, or the circle's own radius, out from nothing, and
  ##   fades it in alongside, so a freshly derived line visibly extends rather than
  ##   popping in.
  var
    anchor = none(Position)
    axis = none(Direction)
    far_ahead, far_behind = ORIGIN_WORLD
  timed(Side.Placing):
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
    if anchor.isSome and axis.isSome:
      let
        reach = progress*scale.radius_horizon
        axis_point = toMultivector(axis.get)
      far_ahead = pointFrom(add(scale.eye_point, wedge(reach, axis_point)))
      far_behind = pointFrom(add(scale.eye_point, wedge(-reach, axis_point)))
  if anchor.isSome and axis.isSome:
    let tint_progress = tint.fade(tint.alpha*progress)
    timed(Side.Emitting):
      meshes.addSegment(anchor.get, far_ahead, tint_progress, WIDTH_LINE_OBJECT)
      meshes.addSegment(anchor.get, far_behind, tint_progress, WIDTH_LINE_OBJECT)
    return Placement.Finite

  var axes = none(tuple[first, second: Direction])
  timed(Side.Placing):
    let normal = directionNormalHorizon(geometry)
    if normal.isSome:
      let spanned = spanPerpendicular(ORIGIN_WORLD, normal.get)
      if spanned.isSome:
        axes = some((first: spanned.get[0], second: spanned.get[1]))
  if axes.isNone: return Placement.Empty
  let (axis_first, axis_second) = (axes.get.first, axes.get.second)
  timed(Side.Emitting):
    meshes.addGreatCircle(
      scale.eye, axis_first, axis_second, progress*scale.radius_horizon,
      tint.fade(tint.alpha*progress),
    )
  Placement.Horizon


proc addPlane(
  meshes: var MeshSet; scratch: var DrawScratch; geometry: Multivector; tint: Rgba;
  progress: float; scale: DrawExtent; anchor_override: Option[Position] = none(Position)
): Placement =
  ## Append grade-3 object as a filled disc and rim about its support point, at a fixed
  ## radius (`EXTENT_PLANE`) independent of the camera, or, at horizon, as a dome
  ## filling the whole sky around `scale.eye` -- the unique universal object every
  ## plane at horizon stands for, regardless of which points produced it.
  ##   `anchor_override`, if given, centres the disc there instead -- some point the
  ##   plane's own construction fixed more specifically than its closest-to-origin
  ##   support does; see `scene.creationAnchor`. `frame`'s own axes do not depend on
  ##   which point anchors the plane (see `spanPerpendicular`'s own doc comment), so
  ##   only where the disc is drawn changes, never how it is oriented.
  ##   `progress` grows the disc and its rim out from nothing, and fades both in
  ##   alongside.
  ##   **No normal is drawn.** A bare shaft out of the anchor used to mark one, which told
  ##   a plane apart from its own reflection -- but it did so on *every* plane in the
  ##   scene, permanently, to answer a question a reader asks about one object at a time.
  ##   Orientation now rides on the selection marker instead, as the direction a pulse
  ##   travels round it; see `marker.markerFor`.
  var
    anchor = none(Position)
    axes = none(FramePlane)
  timed(Side.Placing):
    anchor = if anchor_override.isSome: anchor_override else: positionAnchor(geometry)
    axes = frame(geometry)
  if anchor.isSome and axes.isSome:
    let
      (axis_first, axis_second) = (axes.get.axis_first, axes.get.axis_second)
      extent = progress*EXTENT_PLANE_F
      tint_progress = tint.fade(tint.alpha*progress)

    # Fill first, so plane reads as a surface rather than a bare outline; flat, since
    #   the rim drawn over it already marks the edge crisply on its own. The fill is one
    #   disc record the vertex shader fans out; the rim is stepped off `mesh`'s own fixed
    #   ring of angles: a disc is not a plane, and none of this is algebra.
    timed(Side.Emitting):
      meshes.addDisc(
        anchor.get, axis_first, axis_second, extent, tint.fade(ALPHA_WASH*progress),
      )
      meshes.addPlaneRing(anchor.get, axis_first, axis_second, extent, tint_progress)

    return Placement.Finite

  # One dome record the vertex shader widens over a static unit sphere; what the sphere
  #   looks like and why a full one is drawn is `mesh.addDome`'s own story.
  timed(Side.Emitting):
    meshes.addDome(
      scale.eye, progress*scale.radius_horizon, tint.fade(ALPHA_WASH_SKY*progress),
    )
  Placement.Horizon


proc addObject*(
  meshes: var MeshSet; scratch: var DrawScratch; geometry: Multivector; tint: Rgba;
  scale: DrawExtent; progress: float = 1.0;
  anchor_override: Option[Position] = none(Position)
): Placement =
  ## Append object, dispatching on geometry its grade stands for.
  ##   Empty where multivector carries no drawable geometry at all.
  ##   `progress` is how much of its appear animation the object has completed, from
  ##   `mesh.animationProgress`; defaults to fully appeared, for a caller with nothing
  ##   to animate against.
  ##   `anchor_override` centres a plane's own disc there instead of its own support;
  ##   ignored for a point or line, neither of which is drawn centred on anything else.
  let shape = shape(geometry)
  if shape.isNone: return Placement.Empty
  case shape.get
  of Shape.Point: meshes.addPoint(geometry, tint, progress, scale)
  of Shape.Line: meshes.addLine(scratch, geometry, tint, progress, scale)
  of Shape.Plane: meshes.addPlane(scratch, geometry, tint, progress, scale, anchor_override)
