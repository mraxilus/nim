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
##   | Plane at horizon | `Frame` -- boundary around the whole viewport, since the      |
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
  WIDTH_MARKER_COMET* = 3.5'f32
    ## Swell a comet to this thickness at its head, in pixels, tapering back to
    ## `WIDTH_MARKER` below at its tail.
    ##   Thicker than `WIDTH_MARKER`, which is the whole of how it reads: a comet is a line
    ##   swelling along a stretch of itself, so weight is what separates the lit part from
    ##   the rest. Colour would not do it -- the marker is already pure white at the top of
    ##   this palette, with nowhere brighter to go.
    ##   The tail meets its line at *exactly* that line's width, so the run has no visible
    ##   back end to read as a second mark; only the head is an edge.
    ##   One width for the orientation pulse and the drag band alike. They are the same
    ##   mark saying the same thing, and two constants a tenth of a pixel apart would read
    ##   as an accident rather than as a distinction.
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
    ## Place each of a line's own rails this far from the line, in pixels -- **exactly,
    ## everywhere along it, at every orientation and distance**, because the offset is
    ## applied in screen space rather than as a world step. See `markerRails`.
    ##   A world offset was the first design and read well in the common case: parallel
    ## lines share a vanishing point, so rails offset in world space converge on the same
    ## one the line runs to. What it cost was the *rate* of that convergence, which is
    ## perspective's and not the reader's to choose -- and along the half of a line whose
    ## far point lies behind the eye it is not convergence at all but a flare. Measured on
    ## the demo's own `a ∧ b`, gap from the support out to each drawn end:
    ##
    ##   | camera (azimuth, elevation, distance) | one half | the other |
    ##   |---|---|---|
    ##   | 0.6, 0.2, 19 | 14.8 → 12.9 px | 14.8 → 16.5 px |
    ##   | 1.6, 0.9, 19 | 14.7 → **23.7 px** | 14.7 → 7.9 px |
    ##   | 2.4, 0.4, 30 | 14.5 → **45.6 px** | 14.5 → 0 px |
    ##
    ##   Against a stated pair separation of `2*OFFSET_MARKER_RAIL` = 14.5 px, that is a
    ## flare to three times the gap over 333 px of rail. Re-measured at the same five
    ## cameras once the offset moved into screen space, every flat half reads **14.5 px at
    ## every sample** -- exactly, since a screen offset carries none of the tilt a world
    ## step out of the projection plane did -- and the converging halves still close on
    ## their own vanishing point.
    ##   A ceiling on the gap *at the support* was tried against that and is gone: it left
    ## the flare along a half untouched, and the table that justified it swept only camera
    ## distance at one orientation, which is the one axis the flare does not lie along.
  PASSES_MARKER_RAIL* = 4
    ## Times to settle a line's rails toward the gap they are allowed to read.
    ##   Each pass narrows the offset by exactly the factor the last reading was over by,
    ## which would land it in one were the drawn extent fixed -- but narrowing the pair
    ## moves where each rail leaves the viewport, so the extent shifts under the answer.
    ## Measured on the suite's own fixture over a 45-camera sweep: one pass leaves 15.2 px
    ## against a ceiling of 14.5, and two settle every camera in it exactly. Four rather
    ## than two because the loop stops the moment a reading is inside the ceiling, so the
    ## two it does not need cost nothing and are there for the orientations the sweep does
    ## not name.
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
  SEGMENTS_MARKER_FRAME* = 64
    ## Cut a horizon plane's own boundary into this many even angular steps, before the
    ## four corner directions are merged in.
    ##   A multiple of four, so the four edge midpoints -- the first places the expanding
    ##   circle meets the screen -- are sampled exactly rather than straddled. The rest of
    ##   `SEGMENTS_MARKER_LOOP`'s reasoning applies unchanged: a thin overlay, not scene
    ##   geometry, whose polygon corners fall below a pixel long before they are visible.
  CORNERS_MARKER_FRAME* = 4
    ## Sample this many corner directions on top of the even steps above.
    ##   A rectangle has four, and they are the one place an even sampling cannot be
    ##   trusted to land: a corner missed by a fraction of a step is a corner visibly cut
    ##   off the finished frame. Points on a straight edge lie *on* that edge by
    ##   construction, so nothing else needs extra sampling.
  SEGMENTS_MARKER_PULSE* = 16
    ## Cut the travelling pulse's spine into this many points.
    ##   Enough for the run to bend with a curved outline it is riding; it is a short arc,
    ##   not a shape of its own, and it lies on points already sampled from the outline
    ##   rather than on a curve of its own. Doubled from eight when the run gained a taper:
    ##   the width now changes from point to point, so a coarse spine reads as a run of
    ##   steps rather than as a thinning, and the run itself covers more of the outline.
  SEGMENTS_MARKER_CAP* = 3
    ## Round the pulse's head with this many points between its two sides.
    ##   The head is the one end that is an edge, and a flat cut across the outline at
    ##   `WIDTH_MARKER_COMET` reads as the run having been chopped. Three points is enough
    ##   at that width for the cap to read as round rather than as a bevel; the tail needs
    ##   none, because it ends at the outline's own width and merges into it.
  POINTS_MARKER_PULSE* = 2*SEGMENTS_MARKER_PULSE + SEGMENTS_MARKER_CAP
    ## Bound the points in one run's finished outline: both sides of the spine, plus the
    ## head's cap.
  SEGMENTS_MARKER_OUTLINE* = SEGMENTS_MARKER_LOOP
    ## Bound the segments of any outline a pulse may be laid along.
    ##   A plane's loop is the longest of them; a horizon line's bands are shorter and a
    ## rail is a single segment. Sized here rather than per kind because `samplePulse`
    ## measures whatever it is handed, and the assertion below is what keeps that true.
  RUNS_MARKER_PULSE* = 2
    ## Bound how many separate runs one marker's pulse comes in.
    ##   Two, because the shapes drawn in pieces are drawn in two of them: a line's pair of
    ##   rails, and a horizon line's pair of bands. Both pieces have to pulse, or the one
    ##   that stays still reads as the marker having broken rather than as one signal.
    ##   Was four, when each rail's two halves pulsed separately -- so a selected line wore
    ##   four comets at four unrelated places, which reads as four signals rather than as
    ##   one line with a direction. A rail's halves are now walked as one path.
  LENGTH_MARKER_COMET* = 64.0
    ## Light this much of a line into its head, in pixels, measured back from the point the
    ## head sits at.
    ##   **Pixels rather than a share of whatever it runs along**, and that is the whole
    ##   point of the number. A share makes the mark's size a property of the thing it
    ##   annotates: the drag band's head would grow as the drag went further, and the
    ##   orientation pulse came out 96 px along a line's rail against 334 px round a
    ##   plane's circle seen close up -- a compact comet on one shape and a long gradient
    ##   on another, from one constant. Both were measured before this was a length.
    ##   A line shorter than this lights all of itself; see `FRACTION_MARKER_PULSE`.
  FRACTION_MARKER_PULSE* = 0.35
    ## Never let the pulse cover more than this much of the outline it rides, whatever
    ## `LENGTH_MARKER_COMET` asks for.
    ##   A cap, not the size: on a marker smaller than the run, a fixed length would light
    ##   most of the outline and leave nothing plain for the lit part to be read against,
    ##   and a run that laps its own tail states no direction at all. Around a third leaves
    ##   two thirds of the outline plain, which is enough for the head to be found.
  FALLOFF_MARKER_COMET* = 1.2
    ## Thin a comet down its own tail on this power of the distance from the head.
    ##   Above 1, so the run loses width slowly near the head and quickly at the tail,
    ##   which is what makes the head read as the front rather than the run reading as a
    ##   bar. Chosen against 1.6 and 2.4: the sharper two put nearly all the width in the
    ##   first fifth of the run, leaving the rest indistinguishable from the line under it
    ##   and the run itself looking shorter than it is.
  SPEED_MARKER_PULSE* = 60.0
    ## Carry the pulse along its outline at this many pixels a second.
    ##   **A speed, not a lap time**, for the reason the run is a length and not a share:
    ##   one lap per fixed time makes how fast the mark *moves* a property of the outline
    ##   it rides. Measured, at the 4.8 s lap this replaces: 156 px/s along a line's rail
    ##   against 348 px/s round a plane's circle seen close up, so the same signal read as
    ##   a drift on one shape and a scurry on another.
    ##   Sixty is the speed the lap was chosen at -- the specimens it was judged on were
    ##   about 300 px around, one lap of which in 4.8 s is 62 px/s. Slow enough to read as
    ##   circulation rather than as a spinner, and slow enough that several selected
    ##   objects pulsing at once do not add up to a busy screen. Its *direction* is the
    ##   whole message, and direction needs time to be read.
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
  doAssert SEGMENTS_MARKER_FRAME mod 4 == 0,
    &"A frame's steps must land on the four edge midpoints; got " &
    &"`{SEGMENTS_MARKER_FRAME}`."
  doAssert SEGMENTS_MARKER_BANDS <= SEGMENTS_MARKER_OUTLINE,
    &"A pulse must fit every outline it rides; bands are `{SEGMENTS_MARKER_BANDS}` against " &
    &"`{SEGMENTS_MARKER_OUTLINE}`."
  doAssert FRACTION_MARKER_PULSE < 0.5,
    &"A pulse covering half its outline states no direction; got " &
    &"`{FRACTION_MARKER_PULSE}`."



#[ Type Definitions ]#

type
  MarkerKind* {.pure.} = enum ## Name which outline a marker is drawn as.
    Ring, ## Circle in screen space, for a point.
    Rails, ## Pair of world-space lines flanking a line, converging as it does.
    Loop, ## Polyline lying on a plane in world space, projected, for a plane.
    Bands, ## Pair of circles on the sky flanking a horizon line's own great circle.
    Frame, ## Boundary around the whole viewport, for the whole sky a horizon plane is:
      ## a circle while it expands, the viewport's own rectangle once it arrives.

  Marker* = object ## Hold one object's marker, ready to draw on the foreground layer.
    around*: float ## Length of the outline the runs below were laid along, in pixels; 0
      ## where nothing pulses. Reported back because it is what a caller advances the
      ## pulse against -- see `selection.PulseClock`, which needs the length this marker
      ## actually came out at and cannot know it before the marker is shaped.
    count_run_pulse*: int ## Runs used of `pulses` below; 0 where nothing pulses.
    counts_pulse*: array[RUNS_MARKER_PULSE, int] ## Outline points used of each run.
    pulses*: array[
      RUNS_MARKER_PULSE, array[POINTS_MARKER_PULSE, ScreenPosition]
    ] ## Short runs travelling along this marker's own outline, in screen space, for the
      ## render paths to **fill** over it. **Which way they travel is the object's
      ## orientation** -- the thing a plane's normal shaft used to say, said only about the
      ## object being asked about rather than about every plane in the scene at once.
      ## Each run is one closed outline, not a spine: a run tapers from head to tail, and a
      ## stroke carries one width for its whole length. Shaped here rather than in each
      ## render path, because a ribbon worked out twice is a ribbon that drifts -- and
      ## because neither Dear ImGui nor SVG offers a varying-width stroke to hand it to.
      ## Points rather than a span of indices into the outline, because `Rails` is
      ## segments while `Loop`, `Bands` and `Frame` are polylines, and an index range would
      ## leave each render path re-deriving the walk in its own language.
      ## Common to every kind rather than per-variant: what pulses varies, that a marker
      ## may pulse does not, and a renderer fills these without asking which kind it has.
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
      count_frame*: int ## Points used of `points_frame` below.
      points_frame*: array[
        SEGMENTS_MARKER_FRAME + CORNERS_MARKER_FRAME, ScreenPosition
      ] ## Boundary's own points, in order around the centre of the view. Screen space
        ## throughout, and the one marker that is: the sky has no place in the scene to
        ## surround, so its marker surrounds the view instead. Always closed -- nothing in
        ## screen space can be cut away by the eye, unlike `Loop` and `Bands`.



#[ Orientation Pulse ]#

func lengthOfOutline*(
  points: openArray[ScreenPosition]; count: int; is_closed: bool
): float =
  ## Measure an outline right round, in screen pixels.
  ##   What a caller needs to turn `SPEED_MARKER_PULSE` into a phase for the outline in
  ##   front of it. `samplePulse` walks the same points again for its own table of where
  ##   each segment starts, which is the price of the phase being the caller's to say --
  ##   and it has to be, or a line's two rails would each keep their own clock.
  if count < 2: return
  let last = if is_closed: count else: count - 1
  for i in 0 ..< last:
    let after = points[(i + 1) mod count]
    result += hypot(after.x - points[i].x, after.y - points[i].y)


func phaseAdvanced*(phase, around, seconds: float): float =
  ## Carry a pulse's phase forward by `seconds` along an outline `around` pixels long,
  ## wrapping into 0 .. 1.
  ##   **An advance, not a position.** A phase read straight off the clock would have to be
  ##   `frac(now·speed ÷ around)`, and `around` changes whenever the camera moves: after a
  ##   few laps `now·speed` is tens of thousands of pixels, so a one-percent change in the
  ##   outline's length throws the wrapped answer most of a lap and the comet teleports.
  ##   Measured on the build that did it: with the camera orbiting, the head moved a median
  ##   of **11.15 px a frame against the 1.0 it should**, and every one of ninety sampled
  ##   frames was more than twice the honest step.
  ##   Integrating instead leaves a camera change altering the *rate* and never the
  ##   position, which is what makes a fixed screen speed and a smooth pulse compatible at
  ##   all. `selection.PulseClock` owns the phase this returns; nothing else may.
  ##   Unchanged for an outline of no length, which has nowhere to travel.
  if around <= 0.0: return phase
  let carried = phase + seconds*SPEED_MARKER_PULSE/around
  carried - floor(carried)


func ribbonAlong(
  spine: openArray[ScreenPosition]; count: int; width_head, width_tail: float;
  outline: var openArray[ScreenPosition]
): int =
  ## Wrap `count` points of a run's spine in one closed outline, tapering from
  ## `width_head` at `spine[0]` to `width_tail` at its last point, and report how many
  ## points of `outline` were filled.
  ##   A ribbon rather than a stroke because the width changes along the run, and no stroke
  ##   either render path offers does that. Shaped once here for both of them.
  ##   The taper is spread over whatever length the run actually came out at, so a run cut
  ##   short by the end of an arc is a shorter comet rather than the front half of one.
  ##   Each point's normal comes from its own neighbours on the spine, not from a second
  ##   sample a guessed step away, which at either end would fall off the run entirely.
  if count < 2 or outline.len < 2*count + SEGMENTS_MARKER_CAP: return
  var
    normal_x = 0.0
    normal_y = 0.0
  for i in 0 ..< count:
    let
      before = spine[max(0, i - 1)]
      after = spine[min(count - 1, i + 1)]
      dx = after.x - before.x
      dy = after.y - before.y
      span = hypot(dx, dy)
    if span > 0.0:
      normal_x = -dy/span
      normal_y = dx/span
    let
      falling = pow(1.0 - float(i)/float(count - 1), FALLOFF_MARKER_COMET)
      half = 0.5*(width_tail + (width_head - width_tail)*falling)
    # Both sides at once, the far one filled from the back so the outline closes as one
    #   loop rather than crossing itself at the tail.
    outline[i] = ScreenPosition(
      x: spine[i].x + normal_x*half, y: spine[i].y + normal_y*half, depth: spine[i].depth,
    )
    outline[2*count - 1 - i] = ScreenPosition(
      x: spine[i].x - normal_x*half, y: spine[i].y - normal_y*half, depth: spine[i].depth,
    )
  result = 2*count

  # Round the head, sweeping from its far side through straight ahead to its near one.
  let
    dx = spine[0].x - spine[1].x
    dy = spine[0].y - spine[1].y
    ahead = hypot(dx, dy)
  var
    forward_x = 0.0
    forward_y = 0.0
  if ahead > 0.0:
    forward_x = dx/ahead
    forward_y = dy/ahead
  let half_head = 0.5*width_head
  # The head normal, which the loop above left behind at `i` of `count - 1`, recovered from
  #   the outline's own first point rather than kept in a variable across the whole walk.
  let
    head_x = (outline[0].x - spine[0].x)/half_head
    head_y = (outline[0].y - spine[0].y)/half_head
  for j in 1 .. SEGMENTS_MARKER_CAP:
    let
      turn = PI*float(j)/float(SEGMENTS_MARKER_CAP + 1)
      swing_x = -head_x*cos(turn) + forward_x*sin(turn)
      swing_y = -head_y*cos(turn) + forward_y*sin(turn)
    outline[result] = ScreenPosition(
      x: spine[0].x + swing_x*half_head, y: spine[0].y + swing_y*half_head,
      depth: spine[0].depth,
    )
    inc result


func samplePulse(
  points: openArray[ScreenPosition]; count: int; is_closed: bool; phase: float;
  run: var array[SEGMENTS_MARKER_PULSE, ScreenPosition]
): int =
  ## Lay a pulse along `count` points of an outline at `phase`, filling `run` and
  ## reporting how many of it were used.
  ##   Walks the stored order, which is the whole mechanism: a plane's loop is generated
  ##   around its own frame, so *the projection decides* whether that order comes out
  ##   clockwise or anticlockwise on screen, and the pulse reverses of its own accord as
  ##   the camera crosses the plane. Nothing here computes a sense; it inherits one.
  ##   The run trails *behind* the leading point, so the outline it has just covered is
  ##   what is lit -- a head with a tail reads as travel, where an even band reads as a
  ##   gap in the outline.
  ##   An open arc clamps rather than wraps: its two ends are a cut the eye made, and a
  ##   pulse crossing that cut would run straight across the view. It simply shortens
  ##   there, and reports 0 where too little of it survives to draw.
  ##   Walked **by pixels along the outline, not by index into it**. Stepping by index
  ##   would make the run's length a share of the outline -- so a plane's circle seen close
  ##   up would wear a long gradient where a line's rail wore a compact comet -- and would
  ##   stretch it further wherever perspective bunches the points, which is on the far side
  ##   of every tilted circle.
  if count < 2 or count > SEGMENTS_MARKER_OUTLINE: return

  # Where each segment starts, measured along the outline, with the whole length last.
  var starts: array[SEGMENTS_MARKER_OUTLINE + 1, float]
  let last = if is_closed: count else: count - 1
  for i in 0 ..< last:
    let after = points[(i + 1) mod count]
    starts[i + 1] = starts[i] + hypot(after.x - points[i].x, after.y - points[i].y)
  let total = starts[last]
  if total <= 0.0: return

  let
    reach = min(LENGTH_MARKER_COMET, FRACTION_MARKER_PULSE*total)
    head = phase*total
  for i in 0 ..< SEGMENTS_MARKER_PULSE:
    var along = head - reach*(float(i)/float(SEGMENTS_MARKER_PULSE - 1))
    if is_closed: along = along - floor(along/total)*total
    elif along < 0.0 or along > total: continue
    var segment = last - 1
    for j in 0 ..< last:
      if along < starts[j + 1]:
        segment = j
        break
    let width = starts[segment + 1] - starts[segment]
    run[result] = points[segment].towards(
      points[(segment + 1) mod count], (if width > 0.0: (along - starts[segment])/width else: 0.0)
    )
    inc result
  if result < 2: result = 0 # Too little left of it to read as anything.


func addPulse(
  marker: var Marker; points: openArray[ScreenPosition]; count: int; is_closed: bool;
  phase: float
) =
  ## Add one run of the pulse to `marker`, taken along `count` points of one outline.
  ##   Silently adds nothing where the run came out too short to draw or where the marker
  ##   already holds every run it has room for -- both are "there is no more to say here",
  ##   not failures a caller could act on.
  if marker.count_run_pulse >= RUNS_MARKER_PULSE: return
  var spine: array[SEGMENTS_MARKER_PULSE, ScreenPosition]
  let sampled = samplePulse(points, count, is_closed, phase, spine)
  if sampled == 0: return
  let used = ribbonAlong(
    spine, sampled, float(WIDTH_MARKER_COMET), float(WIDTH_MARKER),
    marker.pulses[marker.count_run_pulse],
  )
  if used == 0: return
  marker.counts_pulse[marker.count_run_pulse] = used
  inc marker.count_run_pulse



#[ Drag Comet ]#

func cometFor*(
  tail, head: ScreenPosition
): Option[array[POINTS_MARKER_PULSE, ScreenPosition]] =
  ## Shape the head of the drag band running `tail` -> `head` as a closed outline, in
  ## screen pixels, for a render path to fill over the band itself.
  ##   A drag is not symmetric: `a ∨ b` and `b ∨ a` are different operations, and a bare
  ##   line between two objects draws identically for either. The head is what says which
  ##   way round the pair is being taken, at the end where the answer lands.
  ##   The band swelling into its own last stretch rather than a barbed head sitting at the
  ##   end of it: the same shape the orientation pulse wears, through the same
  ##   `ribbonAlong`, so a reader meets one vocabulary for direction instead of two.
  ##   None where the two coincide, which has no direction to point in. That is an
  ##   ordinary moment in a drag -- the cursor resting on its own source -- rather than an
  ##   error, so it draws nothing and the band, itself zero length, draws nothing either.
  let
    dx = head.x - tail.x
    dy = head.y - tail.y
    length = hypot(dx, dy)
  if length <= 0.0: return
  # A band shorter than the comet lights all of itself rather than reaching past its own
  #   source, which would leave the head hanging off the object the drag started on.
  let reach = min(LENGTH_MARKER_COMET, length)
  var spine: array[SEGMENTS_MARKER_PULSE, ScreenPosition]
  for i in 0 ..< SEGMENTS_MARKER_PULSE:
    let back = reach*float(i)/float(SEGMENTS_MARKER_PULSE - 1)
    spine[i] = ScreenPosition(
      x: head.x - dx/length*back, y: head.y - dy/length*back, depth: head.depth,
    )
  var outline: array[POINTS_MARKER_PULSE, ScreenPosition]
  let used = ribbonAlong(
    spine, SEGMENTS_MARKER_PULSE, float(WIDTH_MARKER_COMET), float(WIDTH_MARKER), outline
  )
  if used == 0: return
  some(outline)



#[ Touch Clearance ]#

func clearanceTouch*(swell: float; is_touch: bool): float =
  ## Measure how far outward to push a marker, in pixels, at this much of a swell.
  ##   A plain scaling of `CLEARANCE_MARKER_TOUCH`, because the *shape* of the swell is
  ##   the caller's to say -- `interaction.swellHold` runs it through four phases, of
  ##   which only two have anything to do with how far the hold has filled. This was a
  ##   half sine over the fill, which meant the marker was back to its true size at exactly
  ##   the moment the selection landed: shrinking while the reader was still deciding.
  ##   Zero throughout for a mouse: a cursor hides nothing, and swelling under one would
  ##   be motion with nothing to say.
  if not is_touch: return 0.0
  CLEARANCE_MARKER_TOUCH*clamp(swell, 0.0, 1.0)



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


func offsetMarkerRail(anchor: Position; scale: DrawExtent; clearance: float = 0.0): float =
  ## Size how far to each side of a line its rails stand, in world units.
  ##   A *world* offset, so the two rails are lines genuinely parallel to the one they
  ##   flank: they share its vanishing points, converge on them exactly as it does, and
  ##   each is one straight line rather than something assembled per half. A screen offset
  ##   was tried instead and bought a flat gap at the price of a bend where a rail's own
  ##   halves met -- see `markerRails`.
  ##   What it reads as in pixels is `OFFSET_MARKER_RAIL` at the support and less further
  ##   off, and how much less is perspective's to say. Which is why the caller does not
  ##   take this figure as final: see `apartWidest`.
  ##   `clearance` widens the pair by that many further pixels, for a touch hold.
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
  ##   of a percent wide -- well under a pixel.
  ##   None where the eye lies on the line itself, which has no such plane -- and no
  ##   side to flank from, since the line is then edge-on to a viewer inside it.
  directionNormal(geometry ∧ toMultivector(eye))


func awayFromScreen*(point, first, second: ScreenPosition): float =
  ## Perpendicular distance from a screen point to the infinite line through two others.
  ##   The gap at that point, when the two others are the line's own projection: a
  ##   straight world line projects to a straight screen line, so its distance is defined
  ##   wherever the rail's endpoint happens to have been cut to. **Never the distance
  ##   between the two rails' own drawn endpoints** -- `fractionLeavingView` cuts each at
  ##   its own fraction, so those are not at the same place along the line and the
  ##   distance between them measures nothing.
  let (dx, dy) = (second.x - first.x, second.y - first.y)
  let length = hypot(dx, dy)
  if length <= 0.0: return hypot(point.x - first.x, point.y - first.y)
  abs((point.x - first.x)*dy - (point.y - first.y)*dx)/length


func fractionLeavingView*(tail, head: ScreenPosition; width, height: int): float =
  ## Say how far along `tail` -> `head` the segment is still inside the viewport, as a
  ## fraction in 0 .. 1, taking 1 where it ends inside.
  ##   What a growing marker should measure itself against. A rail runs to one of its
  ##   line's vanishing points, which is *not* a screen distance in any useful sense --
  ##   measured on the demo's own `L = a ^ b`, one half's projected length came to
  ##   1,140,706 pixels and the other's to 3,634, a ratio of 314. Growing each by a
  ##   fraction of its own length made one half finish 314 times sooner than the other,
  ##   and put both wholly off a 900-pixel screen within the first percent of the hold.
  ##   Bounding the reach at the edge of the view fixes both at once: the two halves come
  ##   out comparable because the viewport bounds them, and the whole growth is visible
  ##   because none of it happens past the edge.
  ##   Zero where the segment is heading away from a viewport it already left, which draws
  ##   nothing -- correct, since none of it could be seen.
  result = 1.0
  let (dx, dy) = (head.x - tail.x, head.y - tail.y)
  # Each edge bounds the parameter only when the segment is crossing it *outward*.
  template limit(rate, room: float) =
    if rate > 0.0: result = min(result, room/rate)
  limit(-dx, tail.x)
  limit(dx, float(width) - tail.x)
  limit(-dy, tail.y)
  limit(dy, float(height) - tail.y)
  result = max(result, 0.0)


func railsAt(
  anchor: Position; axis, across: Direction; offset: float; scale: DrawExtent;
  placement: Camera; forward: Direction; view_projection: Matrix4; width, height: int;
  progress: float; marker: var Marker;
  walks: var array[2, array[3, Option[ScreenPosition]]]
) =
  ## Lay both rails out at one world offset: the drawn screen segments, and the walk each
  ## rail is read along for its own pulse.
  ##   Its own routine because `markerRails` runs it twice -- once to find out how wide the
  ##   pair actually comes out on screen, and once at the offset that answer asks for.
  ##   Each rail is **one straight world line**: its two halves start from the same offset
  ##   support and run to the two vanishing points the line shares with it, so they are two
  ##   parts of one line and meet at no angle at all.
  marker.count_segment = 0
  walks = default(array[2, array[3, Option[ScreenPosition]]])
  for index_side, side in [offset, -offset]:
    for index_half, reach in [scale.radius_horizon, -scale.radius_horizon]:
      let clipped = clipToEyeSide(
        anchor + side*across, scale.eye + reach*axis, scale.eye, forward,
        placement.distanceNear,
      )
      if clipped.isNone: continue
      let (position_tail, position_head) = clipped.get
      let
        tail = projectToScreen(view_projection, width, height, position_tail)
        head = projectToScreen(view_projection, width, height, position_head)
      if not (tail.isInFront and head.isInFront): continue
      let drawn =
        [tail, tail.towards(head, progress*fractionLeavingView(tail, head, width, height))]
      marker.segments[marker.count_segment] = drawn
      inc marker.count_segment
      # Ordered along the line: the `-axis` end, the support, then the `+axis` end.
      walks[index_side][1] = some(drawn[0]) # The same point for either half.
      walks[index_side][if index_half == 0: 2 else: 0] = some(drawn[1])


func apartWidest(walks: array[2, array[3, Option[ScreenPosition]]]): float =
  ## Report the widest the pair reads apart anywhere a reader can see it, in pixels.
  ##   **One rail against the other**, which is the gap a reader actually sees, rather than
  ##   either rail against the line between them: all three screen lines meet at the same
  ##   vanishing point, so the foot of a perpendicular dropped from one rail lands further
  ##   along the other and the two measures differ by a few percent where they converge
  ##   hardest. Bounding the one that is looked at is the point.
  ##   Each rail's own drawn points against the infinite line through the other's. Distance
  ##   between two straight screen lines is linear along either, so its greatest value over
  ##   a drawn stretch is at one of that stretch's own ends and the walk points settle it.
  var
    points: array[2, array[3, ScreenPosition]]
    counts: array[2, int]
  for side in 0 .. 1:
    for at in walks[side]:
      if at.isNone: continue
      points[side][counts[side]] = at.get
      inc counts[side]
  if counts[0] < 2 or counts[1] < 2: return
  for side in 0 .. 1:
    let other = 1 - side
    for i in 0 ..< counts[side]:
      result = max(result, awayFromScreen(
        points[side][i], points[other][0], points[other][counts[other] - 1],
      ))


func markerRails(
  geometry: Multivector; scale: DrawExtent; placement: Camera;
  view_projection: Matrix4; width, height: int; progress, clearance: float;
  phase: Option[float]
): Option[Marker] =
  ## Build a line's own pair of rails: two straight screen lines flanking it, one to each
  ## side, holding `OFFSET_MARKER_RAIL` pixels of clear space and closing only on a
  ## vanishing point a reader can actually see.
  ##   **Offset in screen pixels, not in world units.** The pair is a marker rather than
  ##   geometry: what it has to say is "this line is selected", and it says that by
  ##   flanking the line at a legible distance. A world offset instead hands the *rate* of
  ##   convergence to perspective, which stretches it to nothing at one end and flares it
  ##   at the other -- see `OFFSET_MARKER_RAIL` for the measurements. So the gap is stated
  ##   in the units it is read in, and holds at every orientation and every distance.
  ##   **It still meets the vanishing point, where there is one to meet.** Each half of
  ##   the line runs to `eye ± radius_horizon*axis`, and exactly one of those two points
  ##   lies in front of the eye unless the line is square on to the camera, when neither
  ##   does. The half that has one sheds its offset at the head and closes on it; the half
  ##   whose head is only a near-plane cut keeps its offset and stays dead parallel, since
  ##   there is nothing that way for a reader to watch it converge on. A line square on to
  ##   the camera therefore stays parallel both ways, which is correct: it has no visible
  ##   vanishing point at all.
  ##   `progress` runs both rails out from the line's own support toward each horizon, and
  ##   **measures that reach against the edge of the view** rather than against each rail's
  ##   own projected length -- see `fractionLeavingView` for the 314-to-1 ratio that fixes,
  ##   and why growing toward a vanishing point is growing into nothing.
  ##   Shortened *after* projection, along the screen segment, rather than by scaling the
  ##   world reach: the far end is a point one horizon radius from the *eye* along the
  ##   axis, so scaling that reach walks the head back to the camera rather than in toward
  ##   the support. Interpolating on screen still keeps every partial rail exactly on the
  ##   rail it will become -- both endpoints lie on it and a straight segment is straight.
  ##   `phase` places **one** pulse along each rail, **in the line's own direction**, which is
  ##   what a line has instead of a face to be on. Each rail is *drawn* as two halves,
  ##   outward from the support toward either horizon, but it is *walked* as one path from
  ##   the far horizon through the support to the near one -- so a selected line wears one
  ##   comet travelling its length rather than four at four unrelated places, and the
  ##   direction falls out of the walk instead of needing the `-axis` half mirrored back.
  ##   Both rails take the one phase they are handed, so the pair cannot drift apart; the
  ##   length reported back is the first rail's, which is what the caller advances against.
  ##   None leaves the rails still.
  ##   None at horizon, where a line draws as a great circle fixed to the eye, and none
  ##   where the line collapses to a point on screen, which is the eye standing on it: a
  ##   line seen end on has no side to be flanked from.
  let
    anchor = positionAnchor(geometry)
    axis = direction(geometry)
    across = directionAcross(geometry, scale.eye)
  if anchor.isNone or axis.isNone or across.isNone: return

  let frame_camera = placement.frame(scale.eye)
  var
    marker = Marker(kind: MarkerKind.Rails)
    walks: array[2, array[3, Option[ScreenPosition]]]
  let offset_stated = offsetMarkerRail(anchor.get, scale, clearance)
  # **Settled against the finished rail, then drawn at the progress asked for.** How far
  #   apart the pair stands is a fact about this line under this camera, not about how far
  #   a hold has got growing it -- so the passes below run at full reach and the caller's
  #   own `progress` is applied once, after. Settling against the partial rail instead made
  #   the gap widen as the hold filled: the drawn extent is what the widest reading is taken
  #   over, so a quarter-grown rail settled on a different offset from a whole one and the
  #   pair breathed sideways while it grew. Caught by the case pinning that a growing rail
  #   starts where the finished one does.
  railsAt(
    anchor.get, axis.get, across.get, offset_stated, scale, placement,
    frame_camera.forward, view_projection, width, height, 1.0, marker, walks,
  )
  if marker.count_segment == 0: return

  # **Sized by the widest the pair will actually read, not by the gap at its support.**
  #   `offsetMarkerRail` states a figure at the support and leaves the rest to perspective,
  #   which along a half whose far point lies behind the eye is not convergence but a
  #   flare -- measured at 45.6 px against a stated 14.5. So the stated figure becomes the
  #   ceiling on what a reader ever sees, and the offset is scaled until the widest reading
  #   meets it. The rails stay world-parallel and straight; only how far apart they start
  #   changes, so the more obliquely a line is viewed the closer to it they run, which is
  #   exactly the distortion being spent down.
  #   Only ever narrows: a pair already inside its ceiling is left alone, so a line viewed
  #   square on is drawn precisely as it always was.
  #   **No floor under the narrowing, and none needed.** A floor was tried, at four tenths,
  #   on the worry that an extreme view would close the pair onto its own line and leave
  #   nothing to see -- and it let a 437-pixel splay through at a camera eight units out
  #   looking steeply along the line, which is the very thing being prevented. The worry was
  #   unfounded: a ceiling on the *widest* reading is itself the guarantee of visibility,
  #   since the pair is that many pixels apart somewhere by construction. What an extreme
  #   view costs is the gap at the narrow end, which is the honest thing for perspective to
  #   take.
  #   **Settled rather than solved in one step.** Narrowing the pair moves where each rail
  #   leaves the viewport, so `fractionLeavingView` hands back a different drawn extent and
  #   the widest reading moves with it -- one scale lands about five per cent over. The gap
  #   falls monotonically as the offset does, so repeating converges: measured, the second
  #   pass settles every camera of a 45-strong sweep exactly. See `PASSES_MARKER_RAIL`.
  let ceiling = 2.0*(OFFSET_MARKER_RAIL + clearance)
  var offset = offset_stated
  for _ in 0 ..< PASSES_MARKER_RAIL:
    let widest = apartWidest(walks)
    if widest <= ceiling: break
    offset = offset*ceiling/widest
    railsAt(
      anchor.get, axis.get, across.get, offset, scale, placement,
      frame_camera.forward, view_projection, width, height, 1.0, marker, walks,
    )
    if marker.count_segment == 0: return

  if progress < 1.0:
    railsAt(
      anchor.get, axis.get, across.get, offset, scale, placement,
      frame_camera.forward, view_projection, width, height, progress, marker, walks,
    )
    if marker.count_segment == 0: return

  for index_side in 0 .. 1:
    let (end_before, support, end_after) =
      (walks[index_side][0], walks[index_side][1], walks[index_side][2])
    # The rail as one walk ordered along the line, from its `-axis` end through the
    #   support to its `+axis` end. Either end may be missing, clipped away by the eye.
    var
      rail: array[3, ScreenPosition]
      count_rail = 0
    for point in [end_before, support, end_after]:
      if point.isNone: continue
      rail[count_rail] = point.get
      inc count_rail

    if phase.isSome and count_rail >= 2:
      if marker.around <= 0.0:
        marker.around = lengthOfOutline(rail, count_rail, false)
      marker.addPulse(rail, count_rail, is_closed = false, phase.get)
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
  progress, clearance: float; phase: Option[float]
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
  ##   `phase` places a pulse round the circle, **anticlockwise on screen exactly when
  ##   the plane's normal points at the eye**. Nothing here computes that sense: the points
  ##   are generated around the plane's own frame, and which way that order comes out on
  ##   screen is the projection's answer, so the pulse reverses of its own accord as the
  ##   camera crosses the plane. This is what a plane's normal shaft used to say, said
  ##   about the object being asked about rather than about every plane at once. None
  ##   leaves the circle still.
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
  if phase.isSome:
    marker.around = lengthOfOutline(marker.points, marker.count_point, marker.is_closed)
    marker.addPulse(marker.points, marker.count_point, marker.is_closed, phase.get)
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
  progress, clearance: float; phase: Option[float]
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
  ##   `phase` places a pulse round both bands, taking its sense from the great
  ##   circle's own normal the way `markerLoop`'s takes it from a plane's: the points are
  ##   laid out around that normal's frame, so the projection answers which way they read.
  ##   Both bands rather than one -- an outline drawn in pieces that pulses in only some of
  ##   them reads as the marker having broken. None leaves them still.
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
    if phase.isSome:
      if marker.around <= 0.0:
        marker.around = lengthOfOutline(
          marker.points_band[side], marker.counts_band[side], marker.are_closed_band[side]
        )
      marker.addPulse(
        marker.points_band[side], marker.counts_band[side],
        marker.are_closed_band[side], phase.get,
      )
  if marker.counts_band[0] == 0 and marker.counts_band[1] == 0: return
  some(marker)


func radiusToEdge(half_width, half_height, angle: float): float =
  ## Measure how far the edge of an axis-aligned rectangle stands from its own centre
  ## along `angle`, in the same units its half-extents are given in.
  ##   Which of the two edge pairs is met first is whichever bound the ray reaches
  ##   sooner. A ray straight along an axis never reaches the pair parallel to it, so
  ##   that term is dropped rather than divided by zero.
  let (across, down) = (abs(cos(angle)), abs(sin(angle)))
  if across <= 0.0: return half_height/down
  if down <= 0.0: return half_width/across
  min(half_width/across, half_height/down)


func markerFrame(width, height: int; progress, clearance: float): Option[Marker] =
  ## Build a horizon plane's own frame: a boundary around the viewport itself, expanding
  ## from the centre of the view as a circle and settling as the viewport's own rectangle.
  ##   A plane at horizon is the whole sky, the same universal object however it was
  ##   built, and it is drawn as a dome filling every direction -- so there is no place in
  ##   the scene for an outline to surround, and the honest marker surrounds the view. It
  ##   does not move with the camera, which is right rather than a shortcut: what it marks
  ##   does not either.
  ##   `progress` sets one reach in pixels, and each direction's boundary point stands at
  ##   that reach *or* at the screen edge, whichever is nearer. So the marker is a circle
  ##   for as long as the circle fits, and then *becomes* the edge piece by piece as the
  ##   circle passes each part of it -- the four edge midpoints first, the corners last.
  ##   A rectangle scaled about the centre instead reached every edge at once, which read
  ##   as a shrunken copy of the screen rather than as something opening out into it.
  ##   Full reach is the half-diagonal, which is the corners' own distance and so the
  ##   largest `radiusToEdge` can return: at `progress` 1 no direction is still bounded by
  ##   the circle and the whole boundary is the rectangle, to the pixel.
  ##   `clearance` pushes it outward past the inset, which on this shape means past the
  ##   edge of the screen: a frame is never under a finger, and shrinking the inset would
  ##   read as the marker retreating rather than swelling.
  ##   **No pulse, unlike every other shape's marker.** The pulse's whole message is
  ##   orientation, and a plane at horizon has none to read: probed directly, `frame`,
  ##   `directionNormal` and `direction` all report nothing for one, and *negating it
  ##   changes none of that*. So there is no sense to travel in, and a pulse here would be
  ##   motion asserting something the object does not carry.
  ##   None only for a viewport too small to hold the inset at all, which has no room to
  ##   draw a frame in.
  let
    inset = GAP_MARKER - clearance
    (centre_x, centre_y) = (0.5*float(width), 0.5*float(height))
    (half_width, half_height) = (centre_x - inset, centre_y - inset)
  if half_width <= 0.0 or half_height <= 0.0: return
  let
    reach = clamp(progress, 0.0, 1.0)*hypot(half_width, half_height)
    turn_corner = arctan2(half_height, half_width)
    # Ascending, and the corners are the only directions an even sampling cannot be
    #   trusted to land on -- see `CORNERS_MARKER_FRAME`.
    turns_corner = [
      turn_corner, PI - turn_corner, PI + turn_corner, 2.0*PI - turn_corner
    ]
  var marker = Marker(kind: MarkerKind.Frame)
  template emit(angle: float) =
    let radius = min(reach, radiusToEdge(half_width, half_height, angle))
    marker.points_frame[marker.count_frame] = ScreenPosition(
      x: centre_x + radius*cos(angle), y: centre_y + radius*sin(angle), depth: 1.0,
    )
    inc marker.count_frame
  # Merge the two ascending runs of angles into one, so the boundary comes out in order
  #   around the centre and strokes as a simple closed outline.
  var next_corner = 0
  for step in 0 ..< SEGMENTS_MARKER_FRAME:
    let angle = (2.0*PI*float(step))/float(SEGMENTS_MARKER_FRAME)
    while next_corner < CORNERS_MARKER_FRAME and turns_corner[next_corner] <= angle:
      # A corner landing exactly on a step is emitted by the step itself; emitting it
      #   here as well would leave a repeated point in the outline.
      if turns_corner[next_corner] < angle: emit(turns_corner[next_corner])
      inc next_corner
    emit(angle)
  while next_corner < CORNERS_MARKER_FRAME:
    emit(turns_corner[next_corner])
    inc next_corner
  some(marker)



#[ Marker Dispatch ]#

func markerFor*(
  geometry: Multivector; anchor_override: Option[Position]; scale: DrawExtent;
  placement: Camera; view_projection: Matrix4; width, height: int; progress: float = 1.0;
  is_touch: bool = false; phase: Option[float] = none(float); swell: float = 0.0
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
  ##   `is_touch` says the hold is a finger's, and `swell` how far clear of it every
  ##   outline is pushed right now; see `clearanceTouch`, and `interaction.swellHold` for
  ##   the four phases that number comes from. One flag rather than a per-shape rule,
  ##   because what it compensates for -- a fingertip over the thing being marked -- does
  ##   not vary by what is under it.
  ##   `phase` places the orientation pulse round the outline, and **is what a caller
  ##   passes to say this object is selected**: hover and keyboard focus wear the same
  ##   marker and pass none, so motion means "selected" rather than "went past". It is a
  ##   *phase*, not a time, and it comes from `selection.PulseClock` -- see there for why
  ##   a comet's place cannot be a pure function of the clock and the camera together. Its
  ##   direction carries the orientation a plane's normal shaft used to -- see
  ##   `markerLoop` for why the projection, not this module, decides which way that reads.
  ##   None where an object has no orientation to state: a point either way, and a plane
  ##   at horizon, which carries no normal at all (see `markerFrame`).
  ##   None only where the object has no drawable geometry at all. Every shape that *is*
  ##   drawn now has a marker, horizon or not.
  let shape = shape(geometry)
  if shape.isNone: return
  let
    is_horizon = geometry.isHorizon
    clearance = clearanceTouch(swell, is_touch)
  case shape.get
  # A point at horizon is drawn as a fixed star, which `anchorFor` already places, so its
  #   ring needs no horizon branch of its own -- unlike the two below, which are drawn as
  #   a great circle and a whole sky and have no anchor at all.
  of Shape.Point:
    markerRing(geometry, scale, view_projection, width, height, progress, clearance)
  of Shape.Line:
    if is_horizon:
      markerBands(
        geometry, scale, view_projection, width, height, progress, clearance, phase
      )
    else:
      markerRails(
        geometry, scale, placement, view_projection, width, height, progress, clearance,
        phase,
      )
  of Shape.Plane:
    if is_horizon: markerFrame(width, height, progress, clearance)
    else:
      markerLoop(
        geometry, anchor_override, scale, placement, view_projection, width, height,
        progress, clearance, phase,
      )
