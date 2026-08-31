## Build the real solar neighbourhood, filled to the last slot, for stress testing.
##
## Orrery exists so the build can be looked at under its own worst case: **every** item slot
## occupied, every drawable kind present, and the objects scattered through a volume so large
## that one camera move swings the tessellation load by an order of magnitude -- which the
## flat helix `visualiser.fillSceneForBenchmark` builds for `--timings` deliberately does not.
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
## Sol alone also carries Luna, Halley, Halley's sheet, and the **only two finite lines in the
## whole scene**: `sol ∧ earth` and `earth ∧ luna`. A line is infinite, so each one crosses the
## entire frame whatever it joins; an earlier arrangement spent fifteen slots on them and read
## as line traffic with the systems behind it.
##
## **Four objects at horizon, and two of them are points because only one can make the plane.**
## Earth lies in Sol's ecliptic, so `att(sol ∧ earth)` sits *on* the line at horizon that
## ecliptic gives; Luna's ring is tipped out of it, so `att(earth ∧ luna)` sits off that line
## and spans the plane at horizon with it. See the horizon block in `constructOrrery`.
##
## `ITEMS_ORRERY` items on the nose: **886 points, 2 lines, 132 planes and 4 at horizon.**
## The total is folded from the tables and asserted, not hoped for.
##
## **Colour says what a thing is**, not which system it belongs to -- see `lut_role_to_ink`.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]
import ../../pga
import ./[boundary, euclid, neighbourhood, objects, scene, tessellate]



#[ Type Definitions ]#

type
  Role* {.pure.} = enum ## Name what an object in the arrangement *is*.
    Sun, ## The body at a system's own centre.
    Planet, ## A body ringing its sun.
    Moon, ## A body ringing a planet.
    Comet, ## A body standing off its system's own plane.
    Derived, ## Anything joined or taken the attitude of: every line, every plane.

  SolBody* = object ## Describe one body of the modelled solar system.
    name*: string ## What it is called, which is also the label it carries in the scene.
    role*: Role ## What kind of body it is, so nothing has to read that back off the name.
    distance*: float ## How far it really stands from Sol, in astronomical units.

  System* = object ## Describe where one system stands and how wide it is drawn.
    reach*: float ## How far its sun stands from `POSITION_ORRERY`, in world units.
    bearing*: float ## Which way it lies from that centre, in radians about the vertical.
    rise*: float ## How far it stands above or below that centre's own level, in radians.
    radius*: float ## How far its outermost planet rings its sun, in world units.
    lean*: float ## How far its own plane leans out of the horizontal, in radians.
    spin*: float ## Where its first planet stands on its ring, in radians.



#[ Layout ]#

const
  POSITION_ORRERY* = Position(x: 0.0, y: 0.0, z: 18.0)
    ## The coordinate every system's placement is measured from, and what the demo's own
    ## camera aims at.
    ##   **No object stands here**, which is the point: the arrangement this replaced put a
    ## star at its centre and joined two dozen lines and planes through it. A camera aiming
    ## at empty space is ordinary for an orbit camera, and it is what keeps the middle of
    ## the frame empty.
    ##   Lifted well clear of the ground plane so the systems below the centre still stand
    ## over the grid rather than being drawn through it.

  SOL*: array[11, SolBody] = [
    SolBody(name: "sol", role: Role.Sun, distance: 0.0),
    SolBody(name: "mercury", role: Role.Planet, distance: 0.39),
    SolBody(name: "venus", role: Role.Planet, distance: 0.72),
    SolBody(name: "earth", role: Role.Planet, distance: 1.00),
    SolBody(name: "mars", role: Role.Planet, distance: 1.52),
    SolBody(name: "jupiter", role: Role.Planet, distance: 5.20),
    SolBody(name: "saturn", role: Role.Planet, distance: 9.58),
    SolBody(name: "uranus", role: Role.Planet, distance: 19.20),
    SolBody(name: "neptune", role: Role.Planet, distance: 30.05),
    SolBody(name: "luna", role: Role.Moon, distance: 1.00),
    SolBody(name: "halley", role: Role.Comet, distance: 17.80),
  ] ## The one system in the arrangement that models a real one: **ours, not to scale.**
    ##   Distances are the real semi-major axes in astronomical units, and
    ## `radiusOfSolBody` says what is done to them to fit a system a reader can look at. The
    ## true numbers are kept here rather than pre-squashed ones because they are the thing
    ## worth being able to check, and because the compression is then one function rather
    ## than eleven hand-tuned constants.
    ##   `luna` carries Earth's own distance and is placed *around* Earth rather than at
    ## that distance from Sol; its entry names its parent by sharing it. `halley` stands
    ## well off the ecliptic, as it really does -- which is also what lets the plane at
    ## horizon be taken from it, since a body lying *in* the ecliptic wedges with it to
    ## nothing.
    ##   This is the only system whose bodies are named, and it is the only one whose
    ## planets stand at different radii, so it gets its own constructor rather than a bent
    ## version of the generic template.

  INDEX_SOL_EARTH = 3
    ## Which entry of `SOL` is Earth.
    ##   Named rather than searched for at every use: it is the one body the arrangement's
    ## single orbit line joins, and the horizon point is that line's own attitude, so it is
    ## load-bearing in three places and a search that quietly found nothing would be silent.
    ## Held to `SOL`'s own name by a compile-time check below.

  SYSTEM_SOL = System(reach: 0.0, bearing: 0.0, rise: 0.0, radius: 12.0, lean: 0.30,
    spin: 0.4)
    ## Where Sol stands, and how wide it is drawn.
    ##   **At `POSITION_ORRERY` itself**, reach zero, because the arrangement is now the real
    ## solar neighbourhood and everything in it is placed by where it really stands *from
    ## Sol*. Sol is therefore the one system that is not placed at all -- it is the origin
    ## the other three hundred are measured from.

  PARSECS_PER_UNIT* = 0.055
    ## How much of a parsec one world unit stands for.
    ##   The single number that turns the real neighbourhood into a scene. At this scale
    ## Proxima, 1.30 parsecs out, stands about 24 units from Sol -- a little further than a
    ## system is wide, so the nearest neighbour is already a journey -- and the outermost
    ## system in the table, at 31.5 parsecs, stands about 573 units out.
    ##   Chosen rather than derived: it is the knob for "how far apart", and it is what makes
    ## crossing the neighbourhood a real camera move rather than a nudge.

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

  REACH_MOON = 0.32
    ## How far a moon rings its planet, as a multiple of the system's own radius.
    ##   Close enough that a moon reads as belonging to its planet rather than as a second
    ## planet, and far enough that the two are separate dots at the framed camera.

  TILT_COMET = 1.1
    ## How far a comet's own ring leans out of its system's plane, in radians.
    ##   Steeply, so its sheet plane cuts across the ecliptic rather than lying in it --
    ## which is what makes the translucent wash pass do real work -- and so the comet is
    ## told from a planet by where it stands as well as by its hue.

  REACH_COMET = 1.35
    ## How far out a comet stands from its sun, as a multiple of the system's own radius.
    ##   Outside the planets, which ring at exactly the radius, so a comet reads as the far
    ## body it is -- and **this is what a system's own reach actually is**, not the radius
    ## the table names. That matters: `FACTOR_ISOLATION_ORRERY` is checked against the
    ## furthest body a system really has, and a first attempt put comets at 1.55 and failed
    ## it, because a system with comets is half again as wide as its table entry claims.

  MOONS_MAX = 2
    ## How many moons a system may ring its first planet with.

  COMETS_MAX = 2
    ## How many comets a system may carry.

  PLANETS_MAX = 3
    ## How many planets a generic system may ring its sun with. Sol is not one of these.

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

  REACH_HALLEY = 1.25
    ## How far Halley stands from Sol, as a multiple of Sol's own radius.
    ##   Outside Neptune, which sits at exactly the radius, so it reads as the far body it
    ## is -- and, like `REACH_COMET`, this is what Sol's true reach is for the isolation
    ## rule, not the radius its entry names.

  TILT_HALLEY = 1.15
    ## How far Halley stands off Sol's own ecliptic, in radians.
    ##   Steeply, as it really is -- and necessarily: the plane at horizon is the attitude of
    ## Halley wedged with that ecliptic, and a body lying *in* a plane wedges with it to
    ## nothing at all.

const lut_role_to_ink*: array[Role, Ink] = [
  Role.Sun: Ink.Copper,
  Role.Planet: Ink.Cobalt,
  Role.Moon: Ink.Rose,
  Role.Comet: Ink.Jade,
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
    furthest = ln(SOL[len(SOL) - 1].distance)
    span = furthest - nearest + SHIFT_SOL
  SYSTEM_SOL.radius*(ln(body.distance) - nearest + SHIFT_SOL)/span


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
  doAssert SOL[0].role == Role.Sun, "`SOL` opens with the star every other entry rings."


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


func itemsOf(neighbour: Neighbour): int =
  ## Report how many scene items one real system comes to.
  ##   Its star, its planets, and the ecliptic plane it earns when it has two of them to
  ## span one. Nothing else: a real system is placed and its planets are placed, and every
  ## further object would be an invention.
  1 + neighbour.planets + (if neighbour.planets >= 2: 1 else: 0)


func systemAt(neighbour: Neighbour): System =
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
    reach: neighbour.parsecs/PARSECS_PER_UNIT,
    bearing: degToRad(neighbour.ascension),
    rise: degToRad(neighbour.declination),
    radius: RADIUS_NEIGHBOUR,
    lean: 0.25 + 0.9*abs(sin(neighbour.ascension)),
    spin: neighbour.declination,
  )


const ITEMS_SOL* = len(SOL) + 4
  ## How many scene items Sol comes to: its bodies, its ecliptic, Halley's sheet, and the
  ## two lines that are the only finite lines in the whole arrangement.


const ITEMS_ORRERY* = block:
  ## Report how many items the whole arrangement comes to.
  ##   Folded from the table rather than written down beside it, for the reason
  ## `RADIUS_ORRERY` below is: a second statement of a number derived from the table is a
  ## second thing to keep true, and editing a system is exactly when it would be forgotten.
  ## On the capacity this build ships with it is `scene.ITEMS_MAX` exactly, which is the
  ## point -- but a build compiled with a smaller one is a real case (the suite runs one),
  ## so the two are compared where the scene is filled rather than assumed equal here.
  var total = COUNT_ITEM_HORIZON + ITEMS_SOL
  for neighbour in NEIGHBOURS: total += itemsOf(neighbour)
  total

const RADIUS_ORRERY* = block:
  ## Report how far out the demo's own camera has to stand back to hold the systems it is
  ## meant to hold, so a caller can frame the arrangement without knowing what is in it.
  ##   Folded from the table itself rather than written down beside it, for the reason
  ## `ITEMS_ORRERY` above is.
  ##   Only the nearest `FRAMED_ORRERY` are folded in. See that constant for why the rest
  ## are deliberately left outside the opening frame.
  var far = SYSTEM_SOL.reach + REACH_HALLEY*SYSTEM_SOL.radius
  for index, neighbour in NEIGHBOURS:
    if index + 1 < FRAMED_ORRERY:
      far = max(far, neighbour.parsecs/PARSECS_PER_UNIT + RADIUS_NEIGHBOUR)
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
    steep = tipped(across, normalOf(SYSTEM_SOL), TILT_HALLEY)
    leaned = tipped(along, normalOf(SYSTEM_SOL), SYSTEM_SOL.lean)
  var placed: array[len(SOL), Multivector]
  var place_earth: Position
  for index, body in SOL:
    # Phases step by the golden angle, as the systems' own bearings do, so no two planets
    #   line up from the opening camera and Earth's line passes through none of them.
    let angle = SYSTEM_SOL.spin + 2.4*float(index)
    let place =
      case body.role
      of Role.Sun: place_sol
      of Role.Planet: ringed(place_sol, along, across, radiusOfSolBody(body), angle)
      of Role.Moon: ringed(place_earth, leaned, across,
        REACH_MOON*SYSTEM_SOL.radius, angle)
      of Role.Comet: ringed(place_sol, steep, across,
        REACH_HALLEY*SYSTEM_SOL.radius, angle)
      of Role.Derived: place_sol # `SOL` holds bodies only; see its own static check.
    if index == INDEX_SOL_EARTH: place_earth = place
    placed[index] = toMultivector(place)
    scene.addItem(placed[index], body.name, lut_role_to_ink[body.role], now)
  # Spanned by Sol and its two outermost planets, whose separation makes the join the
  #   best conditioned of the eight available -- every planet rings the same plane, so
  #   which pair is used changes nothing but the arithmetic.
  ecliptic = sol ∧ placed[len(SOL) - 3] ∧ placed[len(SOL) - 4]
  orbit = sol ∧ placed[INDEX_SOL_EARTH]
  # **The two lines in the whole arrangement**, and the two the horizon block is built from.
  #   Earth lies *in* the ecliptic, so `sol ∧ earth` points along it; Luna's ring is tipped
  #   out of it, so `earth ∧ luna` points off it. That difference is the entire reason there
  #   are two, and it is what makes the plane at horizon constructible -- see the horizon
  #   block in `constructOrrery`.
  tether = placed[INDEX_SOL_EARTH] ∧ placed[len(SOL) - 2]
  scene.addItem(orbit, "sol ∧ earth", lut_role_to_ink[Role.Derived], now)
  scene.addItem(tether, "earth ∧ luna", lut_role_to_ink[Role.Derived], now)
  addPlane(scene, ecliptic, "ecliptic sol", now, place_sol)
  addPlane(scene, sol ∧ placed[len(SOL) - 1] ∧ placed[INDEX_SOL_EARTH], "halley sheet", now,
    position(placed[len(SOL) - 1]).get(place_sol))


proc constructOrrery*(scene: var Scene; now: float = 0.0) =
  ## Fill scene with every system in turn, then the three objects at horizon.
  ##   `now` is forwarded to `addItem` untouched, so every object animates in exactly as one
  ##   added by hand does where a caller passes a real clock reading.
  ##   Asserts the scene it was handed is empty and that it leaves it exactly full, since
  ##   both are properties the caller is relying on and neither is visible in the result.
  doAssert scene.len == 0,
    &"Orrery fills a scene to capacity, so it must start empty; got `{scene.len}` items."
  doAssert ITEMS_MAX >= ITEMS_ORRERY,
    &"Orrery needs `{ITEMS_ORRERY}` item slots; this build was compiled with " &
      &"`{ITEMS_MAX}`. Raise `--define:visualiser.items_max`."

  # Sol first: it is the nearest system, and the horizon block below takes the attitude of
  #   its objects rather than of anything global -- there is nothing global left to take.
  var ecliptic_sol, orbit_sol, tether_sol: Multivector
  constructSol(scene, now, ecliptic_sol, orbit_sol, tether_sol)

  # Every other system is a real star, placed where it really stands and carrying the
  #   planets it really has. Nothing is added to them: no moons, because none of these
  #   planets has a confirmed one; no comets, for the same reason. A system earns an
  #   ecliptic when it has two planets to span one, and that is all.
  for neighbour in NEIGHBOURS:
    let
      system = systemAt(neighbour)
      place_sun = sunOf(system)
      (along, across) = spanOf(system)
      sun = toMultivector(place_sun)
    scene.addItem(sun, neighbour.name, lut_role_to_ink[Role.Sun], now)

    var first_planet, second_planet: Multivector
    for which in 0 ..< neighbour.planets:
      let
        planet = PLANETS[neighbour.first + which]
        place = ringed(place_sun, along, across,
          radiusOfNeighbourPlanet(planet, which, neighbour.planets),
          angleRing(system.spin, which, neighbour.planets))
        body = toMultivector(place)
      if which == 0: first_planet = body
      elif which == 1: second_planet = body
      scene.addItem(body, planet.name, lut_role_to_ink[Role.Planet], now)

    # Two planets span the plane they both ring in; one cannot, and a system with a single
    #   known planet is left as a star and a planet rather than given an invented second.
    if neighbour.planets >= 2:
      addPlane(scene, sun ∧ first_planet ∧ second_planet,
        "ecliptic " & neighbour.name, now, place_sun)

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

  doAssert scene.len == ITEMS_ORRERY,
    &"Orrery built `{scene.len}` items where its own table comes to `{ITEMS_ORRERY}`. " &
      "The two counts are derived from the same table, so they can only differ if the " &
      "construction above stopped agreeing with `itemsOf` about what it emits."
