## Build the real solar neighbourhood, at one of three sizes, for stress testing.
##
## Orrery exists so the build can be looked at under load: every drawable kind present, and
## the objects scattered through a volume so large that one camera move swings the
## tessellation load by an order of magnitude -- which the flat helix
## `visualiser.fillSceneForBenchmark` builds for `--timings` deliberately does not.
##
## **Three sizes of one arrangement**, so a cost can be read as a slope rather than as a
## single number: `ScaleOrrery.Nearest` (60), `Neighbourhood` (360, the default) and
## `Catalogue` (5038, two slots short of the pool). Every one is this same construction
## truncated at a different depth -- nothing about *what* is built changes with the size.
##
## **It is also a claim about the world.** Every system but ours is a real star that is known
## to carry planets, standing at its real distance in its real direction, carrying the planets
## it really has at their real relative distances. Those come from `neighbourhood.nim`, a
## shipped snapshot of the NASA Exoplanet Archive; `PROVENANCE.md` records the query, the date
## and the acknowledgement, and says plainly what is checked and what is not.
##   `SOL` is our own, hand-written and modelled the same way, at the origin the rest are
## measured from. Nothing stands at `POSITION_ORRERY`'s coordinate but Sol itself.
##
##   |------------------|-------------------------------------|--------------------------|
##   | Item             | Built from                          | Present when             |
##   |------------------|-------------------------------------|--------------------------|
##   | star             | placed at its real position         | always                   |
##   | planets          | placed, ringing it at real radii    | as many as it has        |
##   | ecliptic plane   | `star ∧ planet[0] ∧ planet[1]`      | it has two planets       |
##   |------------------|-------------------------------------|--------------------------|
##
## Sol alone also carries its moons and the **only two finite lines in the whole scene**:
## `sol ∧ earth` and `earth ∧ luna`. A line is infinite, so each one crosses the entire frame
## whatever it joins; an earlier arrangement spent fifteen slots on them and read as line
## traffic with the systems behind it.
##
## **Four objects at horizon, and two of them are points because only one can make the plane.**
## Earth lies in Sol's ecliptic, so `att(sol ∧ earth)` sits *on* the line at horizon that
## ecliptic gives; Luna's ring is tipped out of it, so `att(earth ∧ luna)` sits off that line
## and spans the plane at horizon with it. See the horizon block in `constructOrrery`.
##
## `itemsOf(scale)` items on the nose at every size, asserted rather than hoped for: the walk
## passes over a system too large for the room left rather than stopping on it, which is what
## lets three unrelated targets each land exactly. Only Sol's own block and the four at
## horizon are fixed; everything between them is however many real stars fit.
##
## **Colour says what a thing is**, not which system it belongs to -- see `lut_role_to_ink`.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]
import ../../pga
import ./[boundary, camera, euclid, neighbourhood, objects, scene, starfield,
  tessellate]



#[ Type Definitions ]#

type
  Role* {.pure.} = enum ## Name what an object in the arrangement *is*.
    Sun, ## The body at a system's own centre.
    Planet, ## A body ringing its sun.
    Moon, ## A body ringing a planet.
    Derived, ## Anything joined or taken the attitude of: every line, every plane.

  SolBody* = object ## Describe one body of the modelled solar system.
    name*: string ## What it is called, which is also the label it carries in the scene.
    role*: Role ## What kind of body it is, so nothing has to read that back off the name.
    distance*: float ## How far it really stands from Sol, in astronomical units.

  SolMoon* = object ## Describe one real moon of the modelled solar system.
    name*: string ## What it is called, which is also the label it carries in the scene.
    parent*: int ## Which entry of `SOL` it rings.
    kilometres*: float ## Its real semi-major axis about that parent, in kilometres.

  System* = object ## Describe where one system stands and how wide it is drawn.
    reach*: float ## How far its sun stands from `POSITION_ORRERY`, in world units.
    bearing*: float ## Which way it lies from that centre, in radians about the vertical.
    rise*: float ## How far it stands above or below that centre's own level, in radians.
    radius*: float ## How far its outermost planet rings its sun, in world units.
    lean*: float ## How far its own plane leans out of the horizontal, in radians.
    spin*: float ## Where its first planet stands on its ring, in radians.



#[ Layout ]#

const
  POSITION_ORRERY* = Position(x: 0.0, y: 0.0, z: 0.0)
    ## The coordinate every system's placement is measured from, and what the demo's own
    ## camera aims at.
    ##   **Sol stands here**, at the world origin, where the axes cross and the grid is
    ## ruled from. The neighbourhood is a real map measured from our own star, so the star
    ## it is measured from belongs at the point every other coordinate is relative to.
    ##   It used to sit 18 units up, to keep systems with a southern declination from being
    ## drawn through the ground plane. They now stand below it, which is where they are: the
    ## grid is the plane of Sol's own ecliptic, and half the sky is under it.

  SOL*: array[9, SolBody] = [
    SolBody(name: "sol", role: Role.Sun, distance: 0.0),
    SolBody(name: "mercury", role: Role.Planet, distance: 0.39),
    SolBody(name: "venus", role: Role.Planet, distance: 0.72),
    SolBody(name: "earth", role: Role.Planet, distance: 1.00),
    SolBody(name: "mars", role: Role.Planet, distance: 1.52),
    SolBody(name: "jupiter", role: Role.Planet, distance: 5.20),
    SolBody(name: "saturn", role: Role.Planet, distance: 9.58),
    SolBody(name: "uranus", role: Role.Planet, distance: 19.20),
    SolBody(name: "neptune", role: Role.Planet, distance: 30.05),
  ] ## The one system in the arrangement that models a real one: **ours, not to scale.**
    ##   Distances are the real semi-major axes in astronomical units, and
    ## `radiusOfSolBody` says what is done to them to fit a system a reader can look at. The
    ## true numbers are kept here rather than pre-squashed ones because they are the thing
    ## worth being able to check, and because the compression is then one function rather
    ## than nine hand-tuned constants.
    ##   Sol and its eight planets, and nothing else: the moons are a table of their own
    ## below, because a moon's distance is measured from its parent rather than from Sol and
    ## storing both in one field meant one column holding two units.
    ##   This is the only system whose bodies are named, and it is the only one whose
    ## planets stand at different radii, so it gets its own constructor rather than a bent
    ## version of the generic template.

  MOONS*: array[21, SolMoon] = [
    SolMoon(name: "luna", parent: 3, kilometres: 384_400.0),
    SolMoon(name: "phobos", parent: 4, kilometres: 9_376.0),
    SolMoon(name: "deimos", parent: 4, kilometres: 23_463.0),
    SolMoon(name: "io", parent: 5, kilometres: 421_800.0),
    SolMoon(name: "europa", parent: 5, kilometres: 671_100.0),
    SolMoon(name: "ganymede", parent: 5, kilometres: 1_070_400.0),
    SolMoon(name: "callisto", parent: 5, kilometres: 1_882_700.0),
    SolMoon(name: "mimas", parent: 6, kilometres: 185_540.0),
    SolMoon(name: "enceladus", parent: 6, kilometres: 238_040.0),
    SolMoon(name: "tethys", parent: 6, kilometres: 294_670.0),
    SolMoon(name: "dione", parent: 6, kilometres: 377_420.0),
    SolMoon(name: "rhea", parent: 6, kilometres: 527_070.0),
    SolMoon(name: "titan", parent: 6, kilometres: 1_221_870.0),
    SolMoon(name: "iapetus", parent: 6, kilometres: 3_560_840.0),
    SolMoon(name: "miranda", parent: 7, kilometres: 129_900.0),
    SolMoon(name: "ariel", parent: 7, kilometres: 190_900.0),
    SolMoon(name: "umbriel", parent: 7, kilometres: 266_000.0),
    SolMoon(name: "titania", parent: 7, kilometres: 436_300.0),
    SolMoon(name: "oberon", parent: 7, kilometres: 583_500.0),
    SolMoon(name: "triton", parent: 8, kilometres: 354_760.0),
    SolMoon(name: "nereid", parent: 8, kilometres: 5_513_800.0),
  ] ## The major named satellites of the modelled system, each ringing the planet it really
    ## rings at its real semi-major axis in kilometres.
    ##   **The major ones, not all of them.** Some three hundred satellites are known and
    ## most are unnamed kilometre-scale rocks; these are the ones a reader recognises, and
    ## the set is stated here rather than filtered out of a larger table so that what is
    ## drawn is exactly what is written down.
    ##   `radiusOfMoon` says what is done to the kilometres. The spread is enormous -- Phobos
    ## rings Mars 588 times nearer than Nereid rings Neptune -- so the same logarithm
    ## `radiusOfSolBody` uses squashes it, for the same reason.
    ##   `parent` indexes `SOL`, so a moon cannot name a body that is not there; the static
    ## block below checks every one of them is a planet.

  INDEX_SOL_EARTH = 3
    ## Which entry of `SOL` is Earth.
    ##   Named rather than searched for at every use: it is the one body the arrangement's
    ## single orbit line joins, and the horizon point is that line's own attitude, so it is
    ## load-bearing in three places and a search that quietly found nothing would be silent.
    ## Held to `SOL`'s own name by a compile-time check below.

  INDEX_SOL_URANUS = 7
  INDEX_SOL_NEPTUNE = 8
    ## Which entries of `SOL` are the two outermost planets, and so which pair the ecliptic
    ## is spanned from and which body sets the system's own scale.
    ##   **Named, because they used to be counted from the end** -- `placed[len(SOL) - 3]`
    ## and `- 4` -- and so did Luna's tether at `- 2`. That arithmetic was correct only
    ## while Halley sat last in the table: removing it slid the ecliptic onto Saturn and
    ## Uranus and the tether onto Neptune, silently and with nothing to catch it. Each is
    ## held to the body it names by a compile-time check below, so the next edit to `SOL`
    ## fails to compile rather than drawing the wrong thing.

  INDEX_MOON_LUNA = 0
    ## Which entry of `MOONS` is Luna.
    ##   The arrangement's second finite line joins it to Earth, and the *only* reason the
    ## plane at horizon exists is that Luna's ring is tipped out of the ecliptic while Earth
    ## lies in it -- so this is load-bearing in the same way `INDEX_SOL_EARTH` is.

  SYSTEM_SOL = System(reach: 0.0, bearing: 0.0, rise: 0.0, radius: 12.0, lean: 0.0,
    spin: 0.4)
    ## Where Sol stands, and how wide it is drawn.
    ##   **At `POSITION_ORRERY` itself**, reach zero, because the arrangement is the real
    ## solar neighbourhood and everything in it is placed by where it really stands *from
    ## Sol*. Sol is therefore the one system that is not placed at all -- it is the origin
    ## the other eleven thousand are measured from.
    ##   **Lean zero: its ecliptic lies flat on the ground grid.** With Sol at the origin
    ## that plane *is* z = 0, the plane the grid is ruled on, so the system a reader
    ## recognises is laid out on the reference surface rather than tilted across it.
    ##   That is also why moons have a tilt of their own (`TILT_MOON`): this lean used to
    ## tip both the system's plane and Luna's ring out of it, and the plane at horizon is
    ## built from the difference between them. Zeroing one without separating the other
    ## collapses that plane to nothing.

  UNITS_PER_PARSEC* = 100.0
    ## How many world units one parsec stands for.
    ##   The single number that turns the real neighbourhood into a scene. At this scale
    ## Proxima, 1.30 parsecs out, stands **130 units** from Sol -- fourteen times the width a
    ## neighbour system is drawn, so the nearest one is a real journey -- and the outermost
    ## star in the catalogue, at 31.5 parsecs, stands about **3,153 units** out.
    ##   Chosen rather than derived: it is the knob for "how far apart", and it is what makes
    ## crossing the neighbourhood a real camera move rather than a nudge.
    ##   **It was 18 units a parsec** (written as its own reciprocal, `PARSECS_PER_UNIT` =
    ## 0.055) and the field read as a clump: a neighbour stood two system-widths away, so
    ## thousands of them piled into one frame with no space between. What reads as clustered
    ## is the *ratio* of spacing to system size, which is why `RADIUS_NEIGHBOUR` and
    ## `SYSTEM_SOL.radius` did not move with it -- scaling those too would be a pure zoom and
    ## would change nothing. The cost is stated where it lands: `RADIUS_ORRERY` below.
    ##   Stated as units-per-parsec rather than its reciprocal because that is the question
    ## anyone asks of it. The old spelling answered "how far is a parsec" with 0.055.

  RADIUS_NEIGHBOUR* = 9.0
    ## How wide a neighbour system is drawn, in world units.
    ##   One width for all of them. Real stars differ enormously in the extent of their
    ## planetary systems, but at this scale the difference is invisible and pretending to it
    ## would be a fiction dressed as data -- the *positions* are real, and that is the claim
    ## being made. Sol is drawn wider (`SYSTEM_SOL.radius`) because it is the one system a
    ## reader is meant to look into.

  FACTOR_ISOLATION_ORRERY* = 2.0
    ## How many times their combined width two systems' suns must stand apart.
    ##   The concrete meaning of "isolated", so it is checkable rather than a hope: two
    ## systems nearer than this would have their bodies interleave, and neither could be
    ## read as a system of its own. Held by a suite case over the built scene, not over the
    ## table above.
    ##   Two, not three. At two, the clear gap between the outer edges of two systems is
    ## still as wide as both systems put together, which is unambiguously separate to look
    ## at -- and every unit of separation demanded here is paid for by shrinking the systems
    ## against the framed view, which is the fault this whole round is fixing.
    ##   The table above measures **2.20** at its tightest pair, so this floor is pinned
    ## just under what the layout achieves, the same way `check_palette` pins its one
    ## declared exception: an edit that eats a tenth of the margin fails the run rather than
    ## quietly interleaving two systems.

  FRAMED_ORRERY* = 2
    ## How many systems, nearest first, the demo's opening camera is fitted to -- Sol and
    ## Proxima, its actual nearest neighbour.
    ##   Two out of three hundred and thirty-two. Fitted to more, the opening view holds so
    ## much of the neighbourhood that there is nothing left to go and find, which is the
    ## whole point of placing the systems at their real distances: measured at four, the
    ## camera stood 273 units off and a hundred and fifty systems were on screen at once.
    ##   Distant stars stay *visible* whatever this is -- a point is drawn at a fixed pixel
    ## size, so a star at 500 units is still a dot -- and that is right for a star field.
    ## What this controls is how much of it is close enough to read.

const
  COUNT_ITEM_HORIZON = 4
    ## How many items the closing block comes to.
    ##   Four, not three: **two** points at horizon, because one of them cannot make the
    ## plane. See the horizon block in `constructOrrery`.

  RADIUS_MOON_NEAREST = 0.08
  RADIUS_MOON_FURTHEST = 0.32
    ## How far the nearest and furthest moon ring their parents, in world units.
    ##   **Small, and necessarily so.** Sol's planets are drawn across twelve units and the
    ## tightest pair of them -- Venus and Earth -- stands 0.74 apart, so a moon ring wider
    ## than a third of that would reach into the next planet's orbit. A moon is therefore a
    ## dot beside its planet at the opening camera and a separate body once a reader goes and
    ## looks, which is the honest arrangement rather than one that pretends 21 satellites can
    ## be told apart from across the neighbourhood.
    ##   This replaces a single `REACH_MOON` multiple: with one moon there was one distance
    ## to choose, and with twenty-one there is a range to map onto.

  TILT_MOON = 0.0897
    ## How far a moon's ring leans out of its planet's own orbital plane, in radians.
    ##   Luna's real inclination to the ecliptic, 5.14 degrees. One figure for every moon
    ## rather than each one's own: the real inclinations are all small and differ in ways
    ## invisible at this scale, and the one that has to be right is Luna's.
    ##   **The plane at horizon exists only because this is not zero.** Earth lies in the
    ## ecliptic so `att(sol ∧ earth)` sits on the line at horizon that ecliptic gives; Luna
    ## is tipped out of it so `att(earth ∧ luna)` sits off that line and spans the plane at
    ## horizon with it. `addHorizon` refuses the pair if this ever goes flat.

  SHIFT_SOL = 1.0
    ## How far `radiusOfSolBody`'s logarithm is lifted before it is normalised.
    ##   Without it Mercury, being the nearest, lands at radius zero and stands *inside*
    ## Sol. One is chosen so the tightest pair -- Venus and Earth -- still stand about a
    ## sixteenth of the system's radius apart, which is two clear dots at the framed camera.

  AU_NEIGHBOUR_NEAREST = 0.01
    ## The nearest semi-major axis the neighbour ring's own logarithm is scaled from.
    ##   Real planets come far closer to their stars than Mercury does to Sol -- the archive
    ## carries several under a hundredth of an astronomical unit -- so the scale that squashes
    ## them cannot start where Sol's does. Clamped rather than extended further down: below
    ## this a planet is drawn at the ring's inner limit, which is honest about the drawing
    ## being unable to separate it from its star.

  AU_NEIGHBOUR_FURTHEST = 30.0
    ## The furthest semi-major axis that scale runs to, Neptune's own, so a neighbour's ring
    ## and Sol's are read on the same scale.

const lut_role_to_ink*: array[Role, Ink] = [
  Role.Sun: Ink.Copper,
  Role.Planet: Ink.Cobalt,
  Role.Moon: Ink.Rose,
  Role.Derived: Ink.Olive,
] ## Colour every object by **what it is**, not by which system it belongs to.
  ##   The arrangement this replaced spent a hue per cluster, which meant a sun, its planets,
  ## its moons and its comets were all one colour and no two objects of the same kind ever
  ## shared one -- so a reader could see which system a dot belonged to, which its position
  ## already said, and could not tell a moon from a comet, which nothing else says at all.
  ##   `mesh.Ink` offers exactly **five** assignable slots and `lut_ink_to_rgba` records at
  ## length why widening that set failed twice, so five is the budget and the partition has
  ## to fit inside it. Four go to the four kinds of *body* and the fifth to everything
  ## derived. That collision is the deliberate one: a line and a disc are already told apart
  ## by their shape, so a hue spent separating them would say what a reader can see, while
  ## a moon and a comet are two identical dots and hue is the only thing that can separate
  ## them. It is `Ink`'s own rule -- grade is legible from what is drawn, so colour is free
  ## to carry identity -- applied to this scene.
  ##   **Which body gets which of the four is not free either**, and was settled by
  ## `tools/check_palette`, which already measures every pair of these five. `Olive` is much
  ## the darkest slot, and put on a *body* it disappears: rendered with the moons in it, a
  ## moon was a dark smudge that could not be found against the sky, while the same scene
  ## with `Olive` on the derived objects showed all four kinds plainly. So `Olive` is forced
  ## onto the derived side, which forces the four bodies onto `Rose`, `Copper`, `Jade` and
  ## `Cobalt` -- and `Jade`/`Cobalt` is the one pair in the whole palette carrying a
  ## declared exception, converging to 3.7 under tritanopia. That pair cannot be avoided;
  ## it can only be *placed*. It goes on **planet and comet**, which stand apart on screen
  ## -- planets ring their sun in its own plane, comets sit half again as far out and well
  ## off it -- rather than on planet and moon, which sit right beside each other and would
  ## have put the palette's weakest pair on its most adjacent one. The exception's own
  ## reasoning names screen position as part of what carries the pair, so where the pair
  ## lands is the thing this table gets to decide.



#[ Construction ]#

func sunOf(system: System): Position =
  ## Report where a system's own sun stands.
  ##   Spherical about `POSITION_ORRERY`: `bearing` turns about the vertical and `rise`
  ## lifts out of its level, so spreading the systems is a matter of spreading two angles
  ## and one distance rather than of picking triples of coordinates that happen to be far
  ## apart.
  let flat = system.reach*cos(system.rise)
  Position(
    x: POSITION_ORRERY.x + flat*cos(system.bearing),
    y: POSITION_ORRERY.y + flat*sin(system.bearing),
    z: POSITION_ORRERY.z + system.reach*sin(system.rise),
  )


func spanOf(system: System): (Direction, Direction) =
  ## Report the two directions a system's own plane is spanned by.
  ##   The one place a system's orientation is written down, so a planet placed "on its
  ## ecliptic" is on the very plane the scene ends up holding rather than on a second one
  ## that agrees with it to within whatever the two definitions happened to share.
  ##   `lean` tips the first direction out of the horizontal; the second stays level, so a
  ## lean of zero lays the system flat and every lean between tips it by a readable amount.
  (
    Direction(x: cos(system.bearing)*cos(system.lean),
      y: sin(system.bearing)*cos(system.lean), z: sin(system.lean)),
    Direction(x: -sin(system.bearing), y: cos(system.bearing), z: 0.0),
  )


func normalOf(system: System): Direction =
  ## Report the unit normal of a system's own plane.
  ##   `spanOf` returns an orthonormal pair, so their cross product is already unit and
  ## needs no scaling -- which is the reason that pair is built orthonormal rather than
  ## merely spanning: everything tipped out of the plane below is tipped by a rotation, and
  ## a rotation needs an axis of length one or it stretches what it turns. Comets landing
  ## half again as far out as the table said, and failing the isolation check, is exactly
  ## what that stretching did before this existed.
  let (along, across) = spanOf(system)
  cross(along, across)


func tipped(first, second: Direction; angle: float): Direction =
  ## Turn `first` toward `second` by `angle`, both being unit and perpendicular.
  Direction(
    x: first.x*cos(angle) + second.x*sin(angle),
    y: first.y*cos(angle) + second.y*sin(angle),
    z: first.z*cos(angle) + second.z*sin(angle),
  )


func ringed(centre: Position; along, across: Direction; radius, angle: float): Position =
  ## Report a point on the ring of `radius` about `centre`, at `angle` in the plane the two
  ## directions span.
  Position(
    x: centre.x + radius*(cos(angle)*along.x + sin(angle)*across.x),
    y: centre.y + radius*(cos(angle)*along.y + sin(angle)*across.y),
    z: centre.z + radius*(cos(angle)*along.z + sin(angle)*across.z),
  )


func angleRing(spin: float; index, count: int): float =
  ## Report where one body of a ring of `count` stands, in radians.
  ##   **A ring of `count` is spread over `count + 1` steps, not `count`.** At the even
  ## spacing a ring of two puts its pair diametrically opposite, which makes the parent and
  ## both bodies collinear -- and a plane wedged from three collinear points has no clean
  ## grade and draws nothing at all while still holding a slot. That is exactly what six of
  ## these did in the arrangement this replaced, and it is why `addPlane` below exists. The
  ## odd step means no pair on any ring is ever opposite, for any count.
  spin + TAU*float(index)/float(count + 1)


func radiusOfSolBody(body: SolBody): float =
  ## Report how far a body of `SOL` rings Sol in the scene, in world units.
  ##   **Not to scale, and squashed by a logarithm.** The real distances span 0.39 to 30.05
  ## astronomical units, a range of 77: laid out faithfully, Neptune sets the system's size
  ## and the four inner planets share the innermost fiftieth of it as a single dot. A
  ## logarithm keeps the order and the shape of the real spacing -- the inner planets still
  ## crowd, the outer ones still spread -- while compressing 77 down to about 5.
  ##   Lifted by `SHIFT_SOL` before normalising, or Mercury lands on Sol itself, and scaled
  ## so Neptune sits at exactly the system's own radius.
  let
    nearest = ln(SOL[1].distance)
    furthest = ln(SOL[INDEX_SOL_NEPTUNE].distance)
    span = furthest - nearest + SHIFT_SOL
  SYSTEM_SOL.radius*(ln(body.distance) - nearest + SHIFT_SOL)/span


func radiusOfMoon(moon: SolMoon): float =
  ## Report how far a moon of `MOONS` rings its own planet in the scene, in world units.
  ##   The same logarithm `radiusOfSolBody` squashes Sol's planets by, and for the same
  ## reason: the real semi-major axes run from Phobos at 9,376 km to Nereid at 5.5 million,
  ## a range of 588, and drawn faithfully every moon but the outermost of each planet would
  ## sit on the planet itself.
  ##   Mapped onto `RADIUS_MOON_NEAREST`..`RADIUS_MOON_FURTHEST` rather than onto a multiple
  ## of the system's radius, because what bounds a moon ring is the gap to the next planet's
  ## orbit and that is a distance in world units, not a fraction of anything.
  var nearest = MOONS[0].kilometres
  var furthest = MOONS[0].kilometres
  for other in MOONS:
    nearest = min(nearest, other.kilometres)
    furthest = max(furthest, other.kilometres)
  let share = (ln(moon.kilometres) - ln(nearest))/(ln(furthest) - ln(nearest))
  RADIUS_MOON_NEAREST + share*(RADIUS_MOON_FURTHEST - RADIUS_MOON_NEAREST)


func radiusOfNeighbourPlanet(planet: NeighbourPlanet; which, count: int): float =
  ## Report how far a real planet rings its star in the scene, in world units.
  ##   The same logarithm `radiusOfSolBody` squashes Sol's own distances by, for the same
  ## reason: real semi-major axes in one system span three orders of magnitude, and drawn
  ## faithfully the inner planets are one dot on the star.
  ##   **Where the archive carries no semi-major axis, the planet is placed by its order
  ## among its siblings instead**, spread evenly over the ring. That is the one place a
  ## number is supplied rather than read, it is confined to the planets `neighbourhood.nim`
  ## stores as `0.0`, and it is visible in the table rather than hidden here.
  if planet.au <= 0.0:
    return RADIUS_NEIGHBOUR*(0.35 + 0.65*float(which + 1)/float(max(count, 1)))
  let
    nearest = ln(AU_NEIGHBOUR_NEAREST)
    span = ln(AU_NEIGHBOUR_FURTHEST) - nearest + SHIFT_SOL
  RADIUS_NEIGHBOUR*clamp((ln(planet.au) - nearest + SHIFT_SOL)/span, 0.12, 1.0)


static:
  doAssert SOL[INDEX_SOL_EARTH].name == "earth",
    "`INDEX_SOL_EARTH` must name Earth: the arrangement's one orbit line joins it to Sol, " &
      "and the point at horizon is that line's own attitude."
  doAssert SOL[INDEX_SOL_URANUS].name == "uranus" and
      SOL[INDEX_SOL_NEPTUNE].name == "neptune",
    "`INDEX_SOL_URANUS` and `INDEX_SOL_NEPTUNE` must name the two outermost planets: the " &
      "ecliptic is spanned from that pair and Neptune sets the system's own scale."
  doAssert MOONS[INDEX_MOON_LUNA].name == "luna",
    "`INDEX_MOON_LUNA` must name Luna: the arrangement's second finite line joins it to " &
      "Earth, and the plane at horizon is built from that line's attitude."
  doAssert SOL[0].role == Role.Sun, "`SOL` opens with the star every other entry rings."
  for moon in MOONS:
    doAssert moon.parent > 0 and moon.parent < len(SOL) and
        SOL[moon.parent].role == Role.Planet,
      "Every moon must ring a planet of `SOL`; check `MOONS`' own `parent` column."


proc addHorizon(
  scene: var Scene; geometry: Multivector; label: string; expected: Shape; now: float
) =
  ## Add one of the closing objects at horizon, refusing anything that is not one.
  ##   The same guard `addPlane` is, for the same reason and against a second way of getting
  ## it wrong: the attitude of a **grade-4 volume** is a plane at horizon, but only if the
  ## point and the plane wedged to make that volume are genuinely apart. Wedging a point
  ## that already lies *on* the plane gives zero, whose attitude is nothing to draw -- which
  ## is what taking `planet[0] ∧ ecliptic` did, `ecliptic` being the plane `planet[0]` was
  ## used to build. `storyboard`'s own seeds carry the same warning about `o` and `ground`.
  doAssert shape(geometry) == some(expected) and isHorizon(geometry),
    &"Orrery's `{label}` should be a {expected} at horizon; check that the operands it is " &
      "taken from are genuinely apart."
  scene.addItem(geometry, label, lut_role_to_ink[Role.Derived], now)


proc addPlane(
  scene: var Scene; geometry: Multivector; label: string; now: float; anchor: Position
) =
  ## Add a derived plane, refusing anything that is not one.
  ##   Every plane here is wedged from three placed points, and three points that happen to
  ## be collinear wedge to a multivector of no clean grade, which `objects.shape` reports as
  ## nothing to draw -- so the item takes a slot and never appears. That is exactly what six
  ## of these did before this check existed, silently. Checked here rather than trusted,
  ## because the collinearity comes from the layout table above and any edit to it can
  ## reintroduce it; `angleRing` says what the edit to avoid is.
  doAssert shape(geometry) == some(Shape.Plane),
    &"Orrery derives `{label}` from three points that do not span a plane; " &
      "check the layout for a collinear triple."
  scene.addItem(geometry, label, lut_role_to_ink[Role.Derived], now, some(anchor))


func itemsOf*(star: Star): int =
  ## Report how many scene items one real star comes to.
  ##   Exported because the suite bounds how far the fill may depart from nearest-first with
  ## it, and the rule for what a star costs belongs here rather than in a second copy there.
  ##   Itself, its known planets, and the ecliptic plane it earns when it has two of them to
  ## span one. Nothing else: a real star is placed and the planets the archive records for it
  ## are placed, and every further object would be an invention. The great majority carry no
  ## known planet and come to one item -- a star.
  1 + star.planets + (if star.planets >= 2: 1 else: 0)


func systemAt(star: Star): System =
  ## Report where a real star stands and how wide its system is drawn.
  ##   **Right ascension and declination are a real direction**, and distance is a real
  ## length: the placement here is a coordinate conversion, not a layout. Declination
  ## measures up from the celestial equator and ascension around it, which is exactly the
  ## `rise`/`bearing` pair `sunOf` already takes, so the conversion is two conversions to
  ## radians and one scale.
  ##   `lean` and `spin` are the one thing here that is *not* real: no orientation for these
  ## systems' planes is being claimed. They are spread by the star's own coordinates so that
  ## no two systems lie parallel and the arrangement does not read as a stack of discs -- a
  ## deterministic spread, stated as arbitrary rather than dressed up as data.
  System(
    reach: star.parsecs*UNITS_PER_PARSEC,
    bearing: degToRad(star.ascension),
    rise: degToRad(star.declination),
    radius: RADIUS_NEIGHBOUR,
    lean: 0.25 + 0.9*abs(sin(star.ascension)),
    spin: star.declination,
  )


const ITEMS_SOL* = len(SOL) + len(MOONS) + 3
  ## How many scene items Sol comes to: its star and planets, its moons, its ecliptic, and
  ## the two lines that are the only finite lines in the whole arrangement.


type ScaleOrrery* = enum
  ## How deep into the catalogue one build of the arrangement reaches.
  ##   **Three sizes of the same scene, not three scenes.** Every one of them is the same
  ## construction -- Sol entire, then real stars outward, then the four objects at horizon --
  ## truncated at a different depth. Nothing about what is built changes with the size; only
  ## how far the star walk gets, which is what makes the three comparable to each other.
  ##   They exist to be *benchmarked against each other*: one build holds all three, so the
  ## cost of a change can be read as a slope across them rather than as one number.
  Nearest       ## Sol entire, and about a dozen of its nearest real neighbours.
  Neighbourhood ## The default everywhere: a scene worth looking at, quick to build.
  Catalogue     ## The load case, two slots short of the pool.


func itemsOf*(scale: ScaleOrrery): int =
  ## Report how many items the arrangement fills at this size.
  ##   **Which size to use is a working rule, not a build setting.** `Nearest` for a quick
  ## check, `Neighbourhood` for a final one, `Catalogue` when the change could cost
  ## performance: prefer the smaller for work unlikely to touch the frame, the larger for
  ## anything that could regress it. Everything that does not say otherwise takes
  ## `SCALE_ORRERY_DEFAULT`.
  ##   `Catalogue` stops two short of `scene.ITEMS_MAX` rather than filling it. Two is the
  ## smallest margin that still proves the point of leaving one: a reader can add a point and
  ## then join it to something, which is the shortest construction this build has, so a full
  ## scene is still one to build on rather than one that refuses.
  case scale
  of Nearest: 60
  of Neighbourhood: 360
  of Catalogue: 5038


const SCALE_ORRERY_DEFAULT* = ScaleOrrery.Neighbourhood
  ## Which size everything opens on unless it was asked for another.
  ##   Both demo buttons, the desktop's `--demo`, and every suite case that does not name a
  ## size of its own. One default, in one place, so the two front-ends cannot disagree about
  ## what "the demo" means.


const ITEMS_FIXED_ORRERY* = COUNT_ITEM_HORIZON + ITEMS_SOL
  ## How many items the arrangement comes to before a single neighbour is placed.
  ##   Folded from the tables rather than written down beside them, for the reason
  ## `RADIUS_ORRERY` below is: a second statement of a number derived from a table is a
  ## second thing to keep true, and editing `MOONS` is exactly when it would be forgotten.

const ITEMS_ORRERY_MIN* = ITEMS_FIXED_ORRERY + itemsOf(STARS[0])
  ## The smallest arrangement there is: Sol entire, the block at horizon, and the one
  ## neighbour the opening camera is fitted to.
  ##   **A floor rather than a preference.** Below `ITEMS_FIXED_ORRERY` the scene cannot hold
  ## Sol, and the block at horizon takes attitudes of Sol's own objects, so there would be no
  ## arrangement left. One neighbour beyond that is what `RADIUS_ORRERY` needs to be true:
  ## it fits the opening camera to Sol and `FRAMED_ORRERY - 1` nearest stars, and a scene too
  ## small to hold them would be framed for a neighbour that is not in it.
  ##   Folded, so it moves when `SOL`, `MOONS` or the catalogue's nearest entry does.

static:
  for scale in ScaleOrrery:
    doAssert itemsOf(scale) >= ITEMS_ORRERY_MIN,
      &"`ScaleOrrery.{scale}` asks for `{itemsOf(scale)}` items where the smallest " &
        &"arrangement is `{ITEMS_ORRERY_MIN}`: Sol, the block at horizon, and the one " &
        "neighbour the opening camera is fitted to."
  doAssert FRAMED_ORRERY == 2,
    &"`ITEMS_ORRERY_MIN` folds in one neighbour because `FRAMED_ORRERY` is 2; it is now " &
      &"`{FRAMED_ORRERY}`, so the floor has to fold in that many less one."

const RADIUS_ORRERY* = block:
  ## Report how far out the demo's own camera has to stand back to hold the systems it is
  ## meant to hold, so a caller can frame the arrangement without knowing what is in it.
  ##   Folded from the table itself rather than written down beside it, for the reason
  ## `ITEMS_FIXED_ORRERY` above is.
  ##   Only the nearest `FRAMED_ORRERY` are folded in. See that constant for why the rest
  ## are deliberately left outside the opening frame. One figure for every size, because
  ## every size holds those systems -- which is what `ITEMS_ORRERY_MIN` is there to keep true.
  ##   **At 100 units a parsec this comes to about 139**, against Sol's own 12: the system a
  ## reader is meant to look into is now under a tenth of the opening frame's radius, where
  ## at the old spacing it was over a third. That is the price of a field that does not read
  ## as a clump, and it is paid on purpose -- `FRAMED_ORRERY` is the knob if it is ever too
  ## much, not the spacing.
  var far = SYSTEM_SOL.reach + SYSTEM_SOL.radius
  for index, star in STARS:
    if index + 1 < FRAMED_ORRERY:
      far = max(far, star.parsecs*UNITS_PER_PARSEC + RADIUS_NEIGHBOUR)
  far

const ELEVATION_ORRERY_SHOWN* = 0.95
  ## How far above the horizontal the demo's own camera stands, in radians.
  ##   The opening camera sits at 0.42, which is nearly edge-on to systems laid out on
  ## planes: every ring collapses to a line, every disc to a sliver, and the arrangement
  ## reads as a starburst of lines rather than as systems. Steeper is also why the sphere
  ## fit is honest -- fitted edge-on it pulls back to hold a ball the scene does not fill,
  ## and the objects end up at half the radius they were framed for. Not overhead: at
  ## `TAU/4` the leans stop reading and the ground grid the whole scene stands over
  ## disappears into its own horizon.
  ##   Azimuth is left where the reader had it, so this pitches and pulls back rather than
  ## swinging the view round to an orientation they did not ask for.

const INSET_ORRERY_SHOWN* = 24.0
  ## How many pixels of margin the arrangement is framed with, a side.
  ##   Wider than the inset a framed selection takes (`framing.INSET_POINT_SHOWN`), because
  ## what is being fitted here is a bounding sphere around objects that are mostly *not* on
  ## it: fitted tightly, the outermost framed system's own marker ring touches the frame
  ## edge, and a marker is drawn at a fixed pixel size the solve knows nothing about.


proc constructSol(
  scene: var Scene; now: float; ecliptic, orbit, tether: var Multivector
) =
  ## Build the modelled solar system, and hand back the three objects the horizon block
  ## takes attitudes of.
  ##   Its planets ring Sol at `radiusOfSolBody`'s own radii rather than at one shared
  ## radius, which is the whole reason this is not the generic template: a model of a real
  ## system whose planets all stood at the same distance would be modelling nothing.
  let
    place_sol = sunOf(SYSTEM_SOL)
    (along, across) = spanOf(SYSTEM_SOL)
    sol = toMultivector(place_sol)
    # A moon's ring is this pair tipped out of the ecliptic; see `TILT_MOON`, which is the
    #   whole reason the plane at horizon can be built at all.
    leaned = tipped(along, normalOf(SYSTEM_SOL), TILT_MOON)
  var placed: array[len(SOL), Multivector]
  var places: array[len(SOL), Position]
  for index, body in SOL:
    # Phases step by the golden angle, as the systems' own bearings do, so no two planets
    #   line up from the opening camera and Earth's line passes through none of them.
    let angle = SYSTEM_SOL.spin + 2.4*float(index)
    let place =
      case body.role
      of Role.Sun: place_sol
      of Role.Planet: ringed(place_sol, along, across, radiusOfSolBody(body), angle)
      of Role.Moon, Role.Derived: place_sol # `SOL` holds a sun and planets; see its check.
    places[index] = place
    placed[index] = toMultivector(place)
    scene.addItem(placed[index], body.name, lut_role_to_ink[body.role], now)
  # Every moon rings the planet it really rings, in that planet's own orbital plane tipped
  #   by `TILT_MOON`. Phases step by the golden angle again, per moon rather than per
  #   planet, so two moons of the same planet never stand together.
  var placed_moons: array[len(MOONS), Multivector]
  for index, moon in MOONS:
    let place = ringed(places[moon.parent], leaned, across, radiusOfMoon(moon),
      SYSTEM_SOL.spin + 2.4*float(index))
    placed_moons[index] = toMultivector(place)
    scene.addItem(placed_moons[index], moon.name, lut_role_to_ink[Role.Moon], now)
  # Spanned by Sol and its two outermost planets, whose separation makes the join the
  #   best conditioned of the eight available -- every planet rings the same plane, so
  #   which pair is used changes nothing but the arithmetic.
  ecliptic = sol ∧ placed[INDEX_SOL_NEPTUNE] ∧ placed[INDEX_SOL_URANUS]
  orbit = sol ∧ placed[INDEX_SOL_EARTH]
  # **The two lines in the whole arrangement**, and the two the horizon block is built from.
  #   Earth lies *in* the ecliptic, so `sol ∧ earth` points along it; Luna's ring is tipped
  #   out of it, so `earth ∧ luna` points off it. That difference is the entire reason there
  #   are two, and it is what makes the plane at horizon constructible -- see the horizon
  #   block in `constructOrrery`.
  tether = placed[INDEX_SOL_EARTH] ∧ placed_moons[INDEX_MOON_LUNA]
  scene.addItem(orbit, "sol ∧ earth", lut_role_to_ink[Role.Derived], now)
  scene.addItem(tether, "earth ∧ luna", lut_role_to_ink[Role.Derived], now)
  addPlane(scene, ecliptic, "ecliptic sol", now, place_sol)


proc constructOrrery*(
  scene: var Scene; scale: ScaleOrrery = SCALE_ORRERY_DEFAULT; now: float = 0.0
) =
  ## Fill scene with every system in turn, then the four objects at horizon.
  ##   `scale` says how deep into the catalogue to reach; see `ScaleOrrery`. Every size runs
  ##   this same code, so what is built never differs between them -- only how far.
  ##   `now` is forwarded to `addItem` untouched, so every object animates in exactly as one
  ##   added by hand does where a caller passes a real clock reading.
  ##   Asserts the scene it was handed is empty and that it leaves it holding exactly the
  ##   size asked for, since both are properties the caller is relying on and neither is
  ##   visible in the result.
  doAssert scene.len == 0,
    &"Orrery fills a scene to a stated size, so it must start empty; got `{scene.len}`."
  doAssert ITEMS_MAX >= itemsOf(scale),
    &"Orrery at `{scale}` needs `{itemsOf(scale)}` item slots; this build was compiled " &
      &"with `{ITEMS_MAX}`. Raise `--define:visualiser.items_max`, or ask for a smaller size."

  # Sol first: it is the nearest system, and the horizon block below takes the attitude of
  #   its objects rather than of anything global -- there is nothing global left to take.
  var ecliptic_sol, orbit_sol, tether_sol: Multivector
  constructSol(scene, now, ecliptic_sol, orbit_sol, tether_sol)

  # Every other star is a real one, placed where it really stands and carrying the planets
  #   the archive really records for it. Nothing is added to any of them: no moons, because
  #   none of these planets has a confirmed one, and no invented companions of any kind. A
  #   star earns an ecliptic when it has two known planets to span one, and that is all --
  #   which means the great majority of what follows is a single point, a star and nothing
  #   else, because that is all anyone knows about it.
  #   **Walked outward until the scene holds what the size asks for.** The catalogue carries
  #   far more stars than any scene has room for, so the loop stops on the count rather than
  #   on the table, and the nearest are the ones that get in.
  #   The room left is the target less the horizon block, which is added *after* this loop
  #   and so is not there to be counted while it runs.
  #   **A system too large for the room left is passed over, not stopped on.** This used to
  #   `break`, which meant the scene reached its target only where the item counts happened
  #   to sum to it exactly -- true at the one size that then existed, and luck rather than
  #   design. Skipping lets a nearer four-item system give way to a further one-item star, so
  #   the count lands exactly at any size; the great majority of stars are one item, so the
  #   tail always has something to fill it with. The cost is that the last few systems in are
  #   not strictly the nearest ones left, which is invisible in a field of thousands and is
  #   the price of the closing assert being an equality.
  for star in STARS:
    if scene.len + itemsOf(star) > itemsOf(scale) - COUNT_ITEM_HORIZON: continue
    let
      system = systemAt(star)
      place_sun = sunOf(system)
      (along, across) = spanOf(system)
      sun = toMultivector(place_sun)
    scene.addItem(sun, star.name, lut_role_to_ink[Role.Sun], now)
    if star.planets == 0: continue

    var first_planet, second_planet: Multivector
    for which in 0 ..< star.planets:
      let
        planet = PLANETS[star.first + which]
        place = ringed(place_sun, along, across,
          radiusOfNeighbourPlanet(planet, which, star.planets),
          angleRing(system.spin, which, star.planets))
        body = toMultivector(place)
      if which == 0: first_planet = body
      elif which == 1: second_planet = body
      scene.addItem(body, planet.name, lut_role_to_ink[Role.Planet], now)

    # Two planets span the plane they both ring in; one cannot, and a star with a single
    #   known planet is left as a star and a planet rather than given an invented second.
    if star.planets >= 2:
      addPlane(scene, sun ∧ first_planet ∧ second_planet,
        "ecliptic " & star.name, now, place_sun)

  # Close at horizon, every one of them an attitude of one of Sol's own objects -- the
  #   system a reader recognises, and the only one carrying lines to take attitudes of.
  #   Attitude always drops one grade and always lands at horizon: a line gives a point
  #   there, a plane gives a line. They wear the derived hue because that is what they are.
  #
  #   **Two points, and only the second can make the plane.** Earth lies *in* Sol's ecliptic,
  #   so `att(sol ∧ earth)` is a direction lying along that plane -- and therefore a point
  #   sitting *on* the line at horizon the ecliptic gives. Wedging it back with that line
  #   adds nothing and yields nothing to draw. Luna's ring is tipped out of the ecliptic, so
  #   `att(earth ∧ luna)` points off it, and wedging *that* with the line at horizon spans
  #   the plane at horizon. So both points are here because they differ, not for symmetry,
  #   and which of them makes the plane is the fact the arrangement turns on.
  #   `addHorizon` refuses a pair that spans nothing, which is how the two earlier versions
  #   of this same mistake were caught.
  let
    at_horizon_earth = attitude(orbit_sol)
    at_horizon_luna = attitude(tether_sol)
    at_horizon_ecliptic = attitude(ecliptic_sol)
  addHorizon(scene, at_horizon_earth, "att(sol ∧ earth)", Shape.Point, now)
  addHorizon(scene, at_horizon_luna, "att(earth ∧ luna)", Shape.Point, now)
  addHorizon(scene, at_horizon_ecliptic, "att(ecliptic sol)", Shape.Line, now)
  addHorizon(scene, at_horizon_ecliptic ∧ at_horizon_luna,
    "att(ecliptic sol) ∧ att(earth ∧ luna)", Shape.Plane, now)

  doAssert scene.len == itemsOf(scale),
    &"Orrery at `{scale}` built `{scene.len}` items where it fills `{itemsOf(scale)}`. The " &
      "walk passes over what will not fit rather than stopping, so it can only fall short " &
      "by running out of catalogue -- check that `starfield.STARS` still carries more " &
      "stars than the scene has room for."


proc showOrrery*(
  scene: var Scene; camera: var Camera; width, height: int;
  scale: ScaleOrrery = SCALE_ORRERY_DEFAULT; now: float = 0.0
) =
  ## Replace the scene with the arrangement and stand the camera back to hold it: the whole
  ## preset, in one place, because both front-ends open on it and a preset that differs
  ## between them is not a preset.
  ##   Arrives as a replay: `scene.replayFrom` restamps the whole construction, so the
  ## nearest system appears first and then each further one in turn, as a loaded `.rgascene`
  ## file does. The same rule for all three because they are the same thing to a reader --
  ## a construction handed over whole, played back in the order it was made -- and one beat
  ## kept in one place cannot drift from the others. Restamped after the fact rather than as
  ## each object is placed, so the beat is fitted to the whole arrival without this having
  ## to count it out in advance.
  ##   The camera stands back far enough to hold the nearer systems, aims at the
  ## arrangement's own centre, and pitches up over it. Solved rather than guessed:
  ## `distanceFitting` is the same sphere-tangent solve a framed selection uses, so the
  ## preset cannot come to disagree with the rest of the build about what "whole" means.
  ## Pitched first, since the solve reads the camera it is handed; azimuth is left where the
  ## reader had it. `POSITION_ORRERY` holds no object -- it is where the systems are measured
  ## from, and the middle of the frame is deliberately empty. See this module's own header.
  ##   What is *not* here is anything either front-end keeps of its own: the browser's born
  ## stamps, selection and undo timeline, and the desktop's equivalents, all of which are
  ## that side's bookkeeping about a scene rather than part of the scene.
  scene = initScene()
  constructOrrery(scene, scale, now)
  scene.replayFrom(now)
  camera.target = POSITION_ORRERY
  camera.elevation = ELEVATION_ORRERY_SHOWN
  camera.distance =
    distanceFitting(RADIUS_ORRERY, camera, width, height, INSET_ORRERY_SHOWN)
