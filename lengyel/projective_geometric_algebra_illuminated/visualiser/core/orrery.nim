## Build a scene shaped like a solar system, filled to the last slot, for stress testing.
##
## Orrery exists so the build can be looked at under its own worst case. The scene it makes
## occupies **every** item slot, carries every drawable kind including one of each object at
## horizon, and spreads its objects into clusters at very different distances -- so one
## camera move swings the tessellation load by an order of magnitude, which the flat helix
## `visualiser.fillSceneForBenchmark` builds for `--timings` deliberately does not.
##   A solar system is the arrangement, not the subject: clusters of small objects orbiting
## larger ones, at radii spanning a decade, is exactly the distribution that makes a draw
## loop's culling, fading and level-of-detail decisions all matter at once. Nothing here
## models gravity, and no object moves.
##
## Everything is **derived**, not placed: after the star, its two nodes, its pole and each
## cluster's own points, every line and plane in the scene is a join of points already in
## it, and the three objects at horizon are attitudes of objects already in it. Placing a
## plane by writing its coefficients would be shorter and would say nothing.
##
##   |------------------------|-------|------------------------------------------------|
##   | Cluster                | Items | What it contributes                            |
##   |------------------------|-------|------------------------------------------------|
##   | Star                   |     6 | Star, two ecliptic nodes, pole; the ecliptic   |
##   |                        |       |   plane joined from star and nodes; the spin   |
##   |                        |       |   axis joined from star and pole.              |
##   | Planets (six)          |    39 | A planet, its moons, the radius line to the    |
##   |                        |       |   star, a moon plane, and a moon line where it |
##   |                        |       |   carries two moons or more.                   |
##   | Comets (four)          |    16 | A head and a tail point, the orbit line through|
##   |                        |       |   the star, and the sheet plane those three    |
##   |                        |       |   points span.                                 |
##   | Horizon                |     3 | att(axis) is a point at horizon, att(ecliptic) |
##   |                        |       |   a line at horizon, and att of the pole       |
##   |                        |       |   wedged with the ecliptic a plane at horizon. |
##   |------------------------|-------|------------------------------------------------|
##   | Total                  |    64 | 34 points, 16 lines, 11 planes, 3 at horizon.  |
##   |------------------------|-------|------------------------------------------------|
##
## The total is `scene.ITEMS_MAX` and is asserted, not hoped for: a build compiled with
## `--define:visualiser.items_max` set elsewhere gets an error naming both numbers rather
## than a scene that quietly stops part-way through the outer planets.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]
import ../../pga
import ./[boundary, objects, scene, tessellate]



#[ Type Definitions ]#

type
  Orbit* = object ## Describe one planet and the moon system it carries.
    radius*: float ## How far the planet stands from the star, in world units.
    phase*: float ## Where on its orbit it stands, in radians around the ecliptic.
    tilt*: float ## How far its moon system leans out of the ecliptic, in radians.
    spread*: float ## How far its moons stand from it, in world units.
    moons*: int ## How many moons it carries; two or more also earn a moon line.

  Comet* = object ## Describe one comet: a head far out, and a tail pointing away.
    radius*: float ## How far the head stands from the star, in world units.
    phase*: float ## Where around the ecliptic it stands, in radians.
    inclination*: float ## How far its orbit leans out of the ecliptic, in radians.
    tail*: float ## How long its tail runs, in world units.



#[ Layout ]#

const
  POSITION_STAR* = Position(x: 0.0, y: 0.0, z: 6.0)
    ## Where the star stands.
    ##   Lifted clear of the ground plane rather than centred on the origin: at z = 0 the
    ## ecliptic would lie in the grid and the two would read as one surface, and every
    ## cluster below the star would be drawn through the grid it is standing on.

  RADIUS_NODE_ECLIPTIC = 9.0
    ## How far the two ecliptic nodes stand from the star.
    ##   Only the plane they span matters, not the distance -- but a node too near the star
    ## makes the join numerically poor, and one too far leaves two stray points in the
    ## outer system with nothing around them.

  RISE_NODE_ECLIPTIC = 1.6
    ## How far the second node stands above the first, in world units at `RADIUS_NODE_ECLIPTIC`.
    ##   Tilts the ecliptic off the horizontal, so it is never confused with the ground grid
    ## and so every plane derived against it leans too.

  HEIGHT_POLE = 7.0
    ## How far the pole point stands above the star along z.
    ##   It is off the ecliptic by construction, which is what both the spin axis and the
    ## plane at horizon need of it -- see `constructOrrery`.

  ORBITS: array[6, Orbit] = [
    Orbit(radius: 7.0, phase: 0.4, tilt: 0.25, spread: 2.5, moons: 1),
    Orbit(radius: 11.0, phase: 2.1, tilt: 0.55, spread: 3.6, moons: 2),
    Orbit(radius: 15.5, phase: 3.9, tilt: 0.15, spread: 4.8, moons: 3),
    Orbit(radius: 20.5, phase: 5.2, tilt: 0.85, spread: 6.0, moons: 2),
    Orbit(radius: 26.0, phase: 0.9, tilt: 0.35, spread: 7.5, moons: 4),
    Orbit(radius: 31.0, phase: 2.7, tilt: 0.65, spread: 9.0, moons: 4),
  ] ## Place the six planets, innermost first.
    ##   Radii climb **evenly**, not by the power law a real system follows. Tried that way
    ## first and looked at: at true spacing the inner four planets pile into the middle of
    ## the frame as one knot, and a scene laid out in clusters so that clusters can be told
    ## apart should not hide two thirds of them behind each other. Spacing still widens
    ## slightly outward, which keeps the inner system the denser end.
    ##   Phases are spread around the circle so no two planets line up with the star and hide
    ## each other's radius line.
    ##   Moon systems are **a third of the orbit wide**, not the hundredth a real one is: the
    ## reason to lay a stress scene out in clusters is for the clusters to be legible as
    ## clusters, and only the ratio of the two matters -- scaling every radius together moves
    ## the fitted camera with it and changes nothing on screen. Measured by looking: at a
    ## fifth every cluster still read as a single dot with the whole arrangement in frame.
    ##   Moon counts rise outward, which is both what the arrangement suggests and what fills
    ## the slots: the totals in this module's own table depend on them.

  COMETS: array[4, Comet] = [
    Comet(radius: 18.0, phase: 1.4, inclination: 0.95, tail: 5.0),
    Comet(radius: 27.0, phase: 4.4, inclination: -1.15, tail: 6.5),
    Comet(radius: 38.0, phase: 3.0, inclination: 0.70, tail: 8.0),
    Comet(radius: 50.0, phase: 5.8, inclination: -0.55, tail: 10.0),
  ] ## Place the four comets, nearest first.
    ##   Steeply inclined and alternating in sign, so they stand well off the ecliptic and
    ## their sheet planes cut across every planet plane rather than lying parallel to them
    ## -- which is what makes the translucent wash pass do real work.
    ##   The outermost runs past every planet, and past the frame the demo opens at: a comet
    ## that is always on screen is not doing the job a comet is here to do, which is to be
    ## the thing a reader finds by pulling the camera back.

const
  COUNT_ITEM_STAR = 6
    ## How many items the star's own cluster comes to: the star, two ecliptic nodes and the
    ## pole, plus the ecliptic plane and the spin axis joined from them.

  COUNT_ITEM_COMET = 4
    ## How many items one comet comes to: a head, a tail, an orbit line and a sheet plane.

  COUNT_ITEM_HORIZON = 3
    ## How many items the closing block comes to: one object of each shape, at horizon.

const INK_ORRERY_STAR* = Ink.Copper
  ## Colour the star, its nodes, its pole, its ecliptic and its axis all wear.
  ##   Reserved by hand rather than taken from the cycle, for the reason
  ## `storyboard.INK_SEED_ORIGIN` is: the star is the one object every other cluster is
  ## derived against, and a reader should be able to find it without reading a label.

const COUNT_CLUSTER_ORRERY* = len(ORBITS) + len(COMETS)
  ## How many clusters take a colour from the cycle: one per planet and one per comet.

const ITEMS_ORRERY* = block:
  ## Report how many items the whole arrangement comes to.
  ##   Folded from the tables rather than written down, for the reason `RADIUS_ORRERY` below
  ## is: a second statement of a number derived from the tables is a second thing to keep
  ## true, and editing an orbit is exactly when it would be forgotten. On the capacity this
  ## build ships with it is `scene.ITEMS_MAX` exactly, which is the point -- but a build
  ## compiled with a smaller one is a real case (the suite runs one), so the two are compared
  ## where the scene is filled rather than assumed equal here.
  var total = COUNT_ITEM_STAR + COUNT_ITEM_HORIZON + COUNT_ITEM_COMET*len(COMETS)
  for orbit in ORBITS:
    total += 3 + orbit.moons + (if orbit.moons >= 2: 1 else: 0)
  total

const RADIUS_ORRERY* = block:
  ## Report how far the outermost object of the **planet** system stands from the star, so a
  ## caller can frame the arrangement without knowing what is in it.
  ##   Folded from the tables themselves rather than written down beside them: a second
  ## statement of the same number is a second thing to keep true, and editing an orbit is
  ## exactly when it would be forgotten.
  ##   The comets are deliberately **not** folded in. They run half as far again as the
  ## outermost planet, and framing on them would shrink every cluster to a speck to hold four
  ## points and their tails -- which is the same mistake as framing a solar system on its
  ## Oort cloud. A view fitted to the planets leaves the far comets off screen, where a
  ## reader finds them by pulling back, and that is the intended reading.
  var far = max(RADIUS_NODE_ECLIPTIC, HEIGHT_POLE)
  for orbit in ORBITS: far = max(far, orbit.radius + orbit.spread)
  far

const BEND_TAIL_COMET = 0.55
  ## How far a comet's tail leans off the line out from the star, as a fraction of its
  ## length.
  ##   Not decoration. A tail pointing *exactly* away from the star puts the star, the head
  ## and the tail on one line, and three collinear points wedge to nothing: the sheet plane
  ## built from them came out mixed-grade and drew nothing at all, on all four comets, and
  ## was found by counting what the scene actually contained rather than by reading this
  ## code. The lean is along the ecliptic, which is also the direction a real tail is swept.

const ELEVATION_ORRERY_SHOWN* = 0.95
  ## How far above the ecliptic the demo's own camera stands, in radians.
  ##   The opening camera sits at 0.42, which is nearly edge-on to a system laid out on a
  ## plane: every moon rosette collapses to a line, every plane disc to a sliver, and the
  ## arrangement reads as a starburst of lines rather than as clusters. Steeper is also why
  ## the sphere fit below is honest -- fitted edge-on it pulls back to hold a ball the scene
  ## does not fill, and the objects end up at half the radius they were framed for. Not
  ## overhead: at `TAU/4` the ecliptic is a flat disc, the tilts stop reading, and the
  ## ground grid the whole scene stands over disappears into its own horizon.
  ##   Azimuth is left where the reader had it, so this pitches and pulls back rather than
  ## swinging the view round to an orientation they did not ask for.

const INSET_ORRERY_SHOWN* = 24.0
  ## How many pixels of margin the arrangement is framed with, a side.
  ##   Wider than the inset a framed selection takes (`framing.INSET_POINT_SHOWN`), because
  ## what is being fitted here is a bounding sphere around objects that are mostly *not* on
  ## it: fitted tightly, the outermost planet's own marker ring touches the frame edge, and a
  ## marker is drawn at a fixed pixel size the solve knows nothing about.



#[ Construction ]#

func directionsEcliptic(): (Direction, Direction) =
  ## Report the two directions the ecliptic is spanned by, from the star towards each node.
  ##   The one place the plane's own span is written down, so a planet placed "on the
  ## ecliptic" is on the very plane the scene holds rather than on a second one that agrees
  ## with it to within whatever the two definitions happened to share.
  let rise = RISE_NODE_ECLIPTIC/RADIUS_NODE_ECLIPTIC
  (Direction(x: 1.0, y: 0.0, z: 0.0), Direction(x: 0.0, y: 1.0, z: rise))


func onEcliptic(radius, phase: float): Position =
  ## Report where a body stands on the ecliptic, at the given radius and angle.
  let (along, across) = directionsEcliptic()
  Position(
    x: POSITION_STAR.x + radius*(cos(phase)*along.x + sin(phase)*across.x),
    y: POSITION_STAR.y + radius*(cos(phase)*along.y + sin(phase)*across.y),
    z: POSITION_STAR.z + radius*(cos(phase)*along.z + sin(phase)*across.z),
  )


func aroundPlanet(planet: Position; orbit: Orbit; index: int): Position =
  ## Report where one moon stands around its planet.
  ##   The moon circle is the ecliptic's own first direction leaned out of the plane by the
  ## orbit's tilt, crossed with its second -- so a tilt of zero puts the moons back in the
  ## ecliptic and every tilt between leans them off it by a readable amount.
  let
    (along, across) = directionsEcliptic()
    angle = orbit.phase + TAU*float(index)/float(orbit.moons)
    leaned = Direction(
      x: cos(orbit.tilt)*along.x,
      y: cos(orbit.tilt)*along.y,
      z: cos(orbit.tilt)*along.z + sin(orbit.tilt),
    )
  Position(
    x: planet.x + orbit.spread*(cos(angle)*leaned.x + sin(angle)*across.x),
    y: planet.y + orbit.spread*(cos(angle)*leaned.y + sin(angle)*across.y),
    z: planet.z + orbit.spread*(cos(angle)*leaned.z + sin(angle)*across.z),
  )


func headOfComet(comet: Comet): Position =
  ## Report where a comet's head stands, on an orbit inclined out of the ecliptic.
  let
    flat = onEcliptic(comet.radius*cos(comet.inclination), comet.phase)
    rise = comet.radius*sin(comet.inclination)
  Position(x: flat.x, y: flat.y, z: flat.z + rise)


func tailOfComet(comet: Comet; head: Position): Position =
  ## Report where a comet's tail point stands: out along the line from the star, leaned off
  ## it by `BEND_TAIL_COMET` so the star, the head and the tail span a plane rather than a
  ## line -- see that constant for what happened when they did not.
  let
    (_, across) = directionsEcliptic()
    away = Direction(
      x: head.x - POSITION_STAR.x, y: head.y - POSITION_STAR.y, z: head.z - POSITION_STAR.z
    )
    length = max(sqrt(away.x*away.x + away.y*away.y + away.z*away.z), TOLERANCE_ABS)
  Position(
    x: head.x + comet.tail*(away.x/length + BEND_TAIL_COMET*across.x),
    y: head.y + comet.tail*(away.y/length + BEND_TAIL_COMET*across.y),
    z: head.z + comet.tail*(away.z/length + BEND_TAIL_COMET*across.z),
  )


proc addPlane(
  scene: var Scene; geometry: Multivector; label: string; ink: Ink; now: float;
  anchor: Position
) =
  ## Add a derived plane, refusing anything that is not one.
  ##   Every plane here is wedged from three placed points, and three points that happen to
  ## be collinear wedge to a multivector of no clean grade, which `objects.shape` reports as
  ## nothing to draw -- so the item takes a slot and never appears. That is exactly what six
  ## of these did before this check existed, silently. Checked here rather than trusted,
  ## because the collinearity comes from the layout tables above and any edit to them can
  ## reintroduce it.
  doAssert shape(geometry) == some(Shape.Plane),
    &"Orrery derives `{label}` from three points that do not span a plane; " &
      "check the layout tables for a collinear triple."
  scene.addItem(geometry, label, ink, now, some(anchor))


proc constructOrrery*(scene: var Scene; now: float = 0.0) =
  ## Fill scene with the whole arrangement, in the order this module's own table lists it.
  ##   `now` is forwarded to `addItem` untouched, so every object animates in exactly as one
  ##   added by hand does where a caller passes a real clock reading.
  ##   Asserts the scene it was handed is empty and that it leaves it exactly full, since
  ##   both are properties the caller is relying on and neither is visible in the result.
  doAssert scene.len == 0,
    &"Orrery fills a scene to capacity, so it must start empty; got `{scene.len}` items."
  doAssert ITEMS_MAX >= ITEMS_ORRERY,
    &"Orrery needs `{ITEMS_ORRERY}` item slots; this build was compiled with " &
      &"`{ITEMS_MAX}`. Raise `--define:visualiser.items_max`."

  # Stand the star up, with the two nodes and the pole that fix which way its system faces.
  let
    star = toMultivector(POSITION_STAR)
    node_first = toMultivector(onEcliptic(RADIUS_NODE_ECLIPTIC, 0.0))
    node_second = toMultivector(onEcliptic(RADIUS_NODE_ECLIPTIC, TAU/4.0))
    pole = toMultivector(
      Position(x: POSITION_STAR.x, y: POSITION_STAR.y, z: POSITION_STAR.z + HEIGHT_POLE)
    )
    ecliptic = star ∧ node_first ∧ node_second
    axis = star ∧ pole
  scene.addItem(star, "star", INK_ORRERY_STAR, now)
  scene.addItem(node_first, "node, vernal", INK_ORRERY_STAR, now)
  scene.addItem(node_second, "node, autumnal", INK_ORRERY_STAR, now)
  scene.addItem(pole, "pole", INK_ORRERY_STAR, now)
  # Centred on the star rather than on the plane's own closest approach to the origin: the
  #   star is where this construction happened, which is the same reasoning `creationAnchor`
  #   applies to every plane a drag builds.
  scene.addItem(ecliptic, "ecliptic", INK_ORRERY_STAR, now, some(POSITION_STAR))
  scene.addItem(axis, "spin axis", INK_ORRERY_STAR, now)

  # Hang each planet's own cluster off the star, one hue per cluster.
  #   Hue carries the *cluster*, not the shape: a planet, its moons, its radius line and its
  #   moon plane are one thing seen from four sides, and grade is already legible from what
  #   is drawn. Five categorical slots against ten clusters means the cycle wraps twice, so
  #   two clusters do share a hue -- always ones far apart, since the cycle walks outwards.
  for index, orbit in ORBITS:
    let
      ink = inkCycled(index)
      centre = onEcliptic(orbit.radius, orbit.phase)
      planet = toMultivector(centre)
    scene.addItem(planet, &"planet {index + 1}", ink, now)
    var moons: array[4, Multivector]
    doAssert orbit.moons in 1 .. moons.len,
      &"A planet carries one to {moons.len} moons; got `{orbit.moons}`."
    for which in 0 ..< orbit.moons:
      moons[which] = toMultivector(aroundPlanet(centre, orbit, which))
      scene.addItem(moons[which], &"moon {index + 1}.{which + 1}", ink, now)
    scene.addItem(star ∧ planet, &"radius {index + 1}", ink, now)
    if orbit.moons >= 2:
      scene.addItem(moons[0] ∧ moons[1], &"moon line {index + 1}", ink, now)
    # The star stands in as the third point rather than a second moon, for every planet
    #   alike. A two-moon system puts its moons on opposite sides of its planet, so planet
    #   and both moons are collinear and span no plane -- which is what two of these were
    #   doing. Through the star it holds for any moon count, and the plane then contains the
    #   radius line as well, which is visible and worth having.
    addPlane(scene, star ∧ planet ∧ moons[0], &"orbit plane {index + 1}", ink, now, centre)

  # Throw the comets out past the planets, each with the sheet its orbit sweeps.
  for index, comet in COMETS:
    let
      ink = inkCycled(len(ORBITS) + index)
      place_head = headOfComet(comet)
      head = toMultivector(place_head)
      tail = toMultivector(tailOfComet(comet, place_head))
    scene.addItem(head, &"comet {index + 1}", ink, now)
    scene.addItem(tail, &"comet tail {index + 1}", ink, now)
    scene.addItem(star ∧ head, &"comet orbit {index + 1}", ink, now)
    addPlane(scene, star ∧ head ∧ tail, &"comet sheet {index + 1}", ink, now, place_head)

  # Close with one object of each kind at horizon, each the attitude of something standing
  #   in the scene already. Attitude always drops one grade and always lands at horizon, so
  #   a line gives a point there, a plane gives a line, and a grade-4 volume gives a plane
  #   -- see `storyboard.STEPS`' own steps 09 and 11, which say the same thing at length.
  #   The volume is wedged here rather than added as an item: it is grade 4, which draws
  #   nothing at all, and a stress scene has no slot to spend on an invisible object.
  scene.addItem(attitude(axis), "att(spin axis)", INK_ORRERY_STAR, now)
  scene.addItem(attitude(ecliptic), "att(ecliptic)", INK_ORRERY_STAR, now)
  scene.addItem(attitude(pole ∧ ecliptic), "att(pole ∧ ecliptic)", INK_ORRERY_STAR, now)

  doAssert scene.len == ITEMS_ORRERY,
    &"Orrery built `{scene.len}` items where its own tables come to `{ITEMS_ORRERY}`. " &
      "The two counts are derived from the same tables, so they can only differ if the " &
      "construction below stopped agreeing with `ITEMS_ORRERY` about what it emits."
