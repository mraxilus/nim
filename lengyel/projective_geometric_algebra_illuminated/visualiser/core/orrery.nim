## Build a scene of isolated solar systems, filled to the last slot, for stress testing.
##
## Orrery exists so the build can be looked at under its own worst case. The scene it makes
## occupies **every** item slot, carries every drawable kind including one of each object at
## horizon, and scatters its objects through a large volume as self-contained systems -- so
## one camera move swings the tessellation load by an order of magnitude, which the flat
## helix `visualiser.fillSceneForBenchmark` builds for `--timings` deliberately does not.
##
## **Nothing here has a centre.** An earlier arrangement was one solar system: a single star,
## its planets and its comets, with every radius line, every comet orbit and every plane
## joined *through* that one point -- 22 of its 27 lines and planes contained it. Lines are
## infinite, so the scene drew as a starburst out of the middle of the frame and the clusters
## read as decoration on it. Each system now derives **only from its own points**, and no
## object stands at `POSITION_ORRERY` at all: that constant is a coordinate the layout is
## measured from and the camera aims at, not a thing in the scene.
##   Lines through a system's *own* sun are wanted and are what makes a system read as one.
## The rule broken before was a single global hub, not local structure.
##
## Everything after the placed bodies is **derived**: every line and plane is a join of points
## already in the scene, and the three objects at horizon are attitudes of objects already in
## it. Placing a plane by writing its coefficients would be shorter and would say nothing.
##
##   |-------------------|--------------------------------|-----------------------------|
##   | Item              | Built from                     | Present when                |
##   |-------------------|--------------------------------|-----------------------------|
##   | sun               | placed                         | always                      |
##   | planets           | placed, ringing the sun        | always, two or three        |
##   | moons             | placed, ringing planet one     | none, one or two            |
##   | comets            | placed, off the system's plane | none, one or two            |
##   | moon line         | `planet[0] ∧ moon[0]`          | the few that ask for one    |
##   | ecliptic plane    | `sun ∧ planet[0] ∧ planet[1]`  | always                      |
##   | comet sheet       | `sun ∧ comet[0] ∧ planet[0]`   | the system carries a comet  |
##   |-------------------|--------------------------------|-----------------------------|
##
## **`SOL` is the exception, and is the one system a reader will recognise**: our own, not to
## scale, with its eight planets in the right order, the Moon around Earth and Halley off the
## ecliptic. It is the nearest system, it carries the only line in the arrangement that joins
## a sun to a planet -- `sol ∧ earth` -- and all three objects at horizon are attitudes of its
## own objects. See `SOL` and `constructSol`.
##
## **Lines are scarce on purpose.** A line is infinite, so every one of them crosses the whole
## frame whatever it joins. An earlier arrangement spent fifteen slots on them and read as
## line traffic with the systems behind it; four are left, and the slots bought a system and
## nine more bodies. No sun is joined to a planet anywhere but in Sol.
##
## Sol and seven systems by that template, then one object of each shape at horizon, comes to
## `scene.ITEMS_MAX` -- 44 points, 4 lines, 13 planes and 3 at horizon. The total is folded
## from the tables and asserted, not hoped for.
##
## **Colour says what a thing is**, not which system it belongs to -- see `lut_role_to_ink`.
##
## Shared between the desktop (`visualiser.nim`) and browser (`browser_bridge.nim`) render
## paths; see `visualiser.nim`'s own "Render Paths" table.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]
import ../../pga
import ./[boundary, euclid, objects, scene, tessellate]



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

  System* = object ## Describe one isolated solar system and where it stands.
    reach*: float ## How far its sun stands from `POSITION_ORRERY`, in world units.
    bearing*: float ## Which way it lies from that centre, in radians about the vertical.
    rise*: float ## How far it stands above or below that centre's own level, in radians.
    radius*: float ## How far its planets ring its sun, in world units.
    lean*: float ## How far its own plane leans out of the horizontal, in radians.
    spin*: float ## Where its first planet stands on its ring, in radians.
    planets*: int ## How many planets it carries; two or three, since its plane needs two.
    moons*: int ## How many moons ring its first planet; none, one or two.
    comets*: int ## How many comets it carries; none, one or two.
    line*: bool ## Whether it also joins its first planet to its first moon.
      ## Few do. A line is infinite, so every one of them crosses the whole frame whatever
      ## it joins, and fifteen of them made the scene read as line traffic with the systems
      ## behind it. Kept on a handful so the kind is exercised by more than the one line
      ## Sol carries, and so the ribbon path is not a single object's curiosity.



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

  SYSTEM_SOL = System(reach: 26.0, bearing: 0.00, rise: 0.26, radius: 12.0, lean: 0.30,
    spin: 0.4, planets: 0, moons: 0, comets: 0)
    ## Where Sol stands, and how wide it is.
    ##   The body counts are zero because `constructSol` reads `SOL` instead; only the
    ## placement fields are its own. **Nearest of them all** on purpose: it is the system a
    ## reader recognises, it is inside the opening frame, and every object at horizon is an
    ## attitude of one of its objects.

  SYSTEMS: array[7, System] = [
    System(reach: 44.0, bearing: 2.40, rise: -0.38, radius: 11.0, lean: 0.85, spin: 2.1,
      planets: 3, moons: 1, comets: 1, line: true),
    System(reach: 58.0, bearing: 4.79, rise: 0.18, radius: 11.0, lean: 0.12, spin: 3.9,
      planets: 2, moons: 0, comets: 0, line: false),
    System(reach: 72.0, bearing: 1.02, rise: -0.52, radius: 12.0, lean: 0.62, spin: 5.2,
      planets: 3, moons: 0, comets: 1, line: false),
    System(reach: 86.0, bearing: 3.42, rise: 0.44, radius: 13.0, lean: 0.20, spin: 0.9,
      planets: 2, moons: 2, comets: 0, line: true),
    System(reach: 100.0, bearing: 5.81, rise: -0.22, radius: 15.0, lean: 1.05, spin: 2.7,
      planets: 2, moons: 0, comets: 1, line: false),
    System(reach: 114.0, bearing: 2.04, rise: 0.56, radius: 16.0, lean: 0.45, spin: 4.4,
      planets: 3, moons: 1, comets: 0, line: false),
    System(reach: 128.0, bearing: 4.44, rise: -0.30, radius: 17.0, lean: 0.72, spin: 1.5,
      planets: 2, moons: 1, comets: 1, line: true),
  ] ## Place the other seven systems, nearest first.
    ##   **Bearings step by 2.4 radians**, a little over three eighths of a turn, so seven
    ## systems land seven different ways round and none is hidden behind another from the
    ## opening camera. An even step would have put systems 1 and 7 nearly in line.
    ##   Rises alternate in sign so the systems sit above and below the centre's level
    ## rather than on one shell, which is what makes a camera move change which of them
    ## overlap.
    ##   **Reaches and radii are traded against each other, and the trade was measured.**
    ## What decides how big a system looks is its radius against the radius the camera is
    ## fitted to, so scaling the whole layout changes nothing on screen -- only the ratio
    ## moves. A first table reached 140 units out with radii near 8, which put a system at
    ## a *ninth* of the framed radius and drew each one as a speck. These reaches are
    ## compressed and these radii are grown until the tightest pair of systems sits at 2.20
    ## times their combined **reach** -- their furthest body, not the radius named here,
    ## which for a system with comets is `REACH_COMET` times wider -- just clear of the
    ## `FACTOR_ISOLATION_ORRERY` floor, which is as far as the trade goes. A system is now
    ## about a fifth of the framed radius.
    ##   Casts vary rather than repeating: three systems have no comet and three no moon, so
    ## a reader who looks at two of them sees two different things. The counts are also what
    ## fills the last slot -- `ITEMS_ORRERY` is folded from this table and from `SOL`.
    ##   **None of them joins its sun to a planet, and only three carry a line at all.** The
    ## arrangement this replaced spent fifteen slots on lines; every one of them ran clear
    ## across the frame, because a line is infinite whatever it joins. Four are left in the
    ## whole scene, and the slots that bought back a system and nine more bodies.

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

  FRAMED_ORRERY = 4
    ## How many systems, nearest first, the demo's opening camera holds -- Sol and the three
    ## nearest of the rest.
    ##   Not all eight. A view fitted to the outermost would shrink every system to a speck
    ## to hold the ones furthest out; the ones past the frame are what a reader finds by
    ## pulling back, and that is the intended reading -- the same rule the previous
    ## arrangement's far comets followed.

const
  COUNT_ITEM_HORIZON = 3
    ## How many items the closing block comes to: one object of each shape, at horizon.

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
      "check `SYSTEMS` for a collinear triple."
  scene.addItem(geometry, label, lut_role_to_ink[Role.Derived], now, some(anchor))


func itemsOf(system: System): int =
  ## Report how many scene items one generic system comes to.
  ##   Its sun, its bodies, the ecliptic plane every system has, the sheet a comet earns,
  ## and the moon line the few that ask for one carry.
  1 + system.planets + system.moons + system.comets + 1 +
    (if system.comets >= 1: 1 else: 0) + (if system.line: 1 else: 0)


const ITEMS_SOL* = len(SOL) + 3
  ## How many scene items Sol comes to: its bodies, its ecliptic, Halley's sheet, and the
  ## one line in the arrangement that joins a sun to a planet.


const ITEMS_ORRERY* = block:
  ## Report how many items the whole arrangement comes to.
  ##   Folded from the table rather than written down beside it, for the reason
  ## `RADIUS_ORRERY` below is: a second statement of a number derived from the table is a
  ## second thing to keep true, and editing a system is exactly when it would be forgotten.
  ## On the capacity this build ships with it is `scene.ITEMS_MAX` exactly, which is the
  ## point -- but a build compiled with a smaller one is a real case (the suite runs one),
  ## so the two are compared where the scene is filled rather than assumed equal here.
  var total = COUNT_ITEM_HORIZON + ITEMS_SOL
  for system in SYSTEMS: total += itemsOf(system)
  total

const RADIUS_ORRERY* = block:
  ## Report how far out the demo's own camera has to stand back to hold the systems it is
  ## meant to hold, so a caller can frame the arrangement without knowing what is in it.
  ##   Folded from the table itself rather than written down beside it, for the reason
  ## `ITEMS_ORRERY` above is.
  ##   Only the nearest `FRAMED_ORRERY` are folded in. See that constant for why the rest
  ## are deliberately left outside the opening frame.
  var far = SYSTEM_SOL.reach + REACH_HALLEY*SYSTEM_SOL.radius
  for index, system in SYSTEMS:
    if index + 1 < FRAMED_ORRERY: far = max(far, system.reach + system.radius)
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
  scene: var Scene; now: float; ecliptic, orbit, halley: var Multivector
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
  halley = placed[len(SOL) - 1]
  scene.addItem(orbit, "sol ∧ earth", lut_role_to_ink[Role.Derived], now)
  addPlane(scene, ecliptic, "ecliptic sol", now, place_sol)
  addPlane(scene, sol ∧ halley ∧ placed[INDEX_SOL_EARTH], "halley sheet", now,
    position(halley).get(place_sol))


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
  var ecliptic_sol, orbit_sol, halley: Multivector
  constructSol(scene, now, ecliptic_sol, orbit_sol, halley)

  for index, system in SYSTEMS:
    doAssert system.planets in 2 .. PLANETS_MAX,
      &"A system rings its sun with two or three planets; got `{system.planets}`."
    doAssert system.moons in 0 .. MOONS_MAX,
      &"A system rings its first planet with at most {MOONS_MAX} moons; got `{system.moons}`."
    doAssert system.comets in 0 .. COMETS_MAX,
      &"A system carries at most {COMETS_MAX} comets; got `{system.comets}`."
    let
      name = index + 2 # Sol is the first system; these are numbered after it.
      place_sun = sunOf(system)
      (along, across) = spanOf(system)
      sun = toMultivector(place_sun)
    scene.addItem(sun, &"sun {name}", lut_role_to_ink[Role.Sun], now)

    # The planets, ringing their sun on the system's own plane.
    var planets: array[PLANETS_MAX, Multivector]
    var place_planets: array[PLANETS_MAX, Position]
    for which in 0 ..< system.planets:
      place_planets[which] = ringed(place_sun, along, across, system.radius,
        angleRing(system.spin, which, system.planets))
      planets[which] = toMultivector(place_planets[which])
      scene.addItem(planets[which], &"planet {name}.{which + 1}",
        lut_role_to_ink[Role.Planet], now)

    # The moons, ringing the first planet on a ring tipped out of the system's own plane by
    #   its lean again -- so a moon never lies on the ecliptic its planet rings in, and the
    #   moon line it earns crosses that plane rather than lying in it.
    var moons: array[MOONS_MAX, Multivector]
    let leaned = tipped(along, normalOf(system), system.lean)
    for which in 0 ..< system.moons:
      moons[which] = toMultivector(ringed(place_planets[0], leaned, across,
        REACH_MOON*system.radius, angleRing(system.spin, which, system.moons)))
      scene.addItem(moons[which], &"moon {name}.{which + 1}",
        lut_role_to_ink[Role.Moon], now)

    # The comets, standing well off the system's own plane and further out than its planets
    #   -- which is what makes their sheets cut across every ecliptic rather than lie in it.
    var comets: array[COMETS_MAX, Multivector]
    var place_comets: array[COMETS_MAX, Position]
    let steep = tipped(across, normalOf(system), TILT_COMET)
    for which in 0 ..< system.comets:
      place_comets[which] = ringed(place_sun, steep, across, REACH_COMET*system.radius,
        angleRing(system.spin + 0.7, which, system.comets))
      comets[which] = toMultivector(place_comets[which])
      scene.addItem(comets[which], &"comet {name}.{which + 1}",
        lut_role_to_ink[Role.Comet], now)

    # The lines and the planes, every one joined from this system's own bodies alone.
    #   **No sun is joined to anything.** Sol carries the one orbit line in the scene, and
    #   these systems carry only what a moon earns -- see `System.line` for why so few.
    if system.line:
      doAssert system.moons >= 1,
        &"System {name} asks for a moon line and carries no moon."
      scene.addItem(planets[0] ∧ moons[0], &"moon orbit {name}",
        lut_role_to_ink[Role.Derived], now)
    addPlane(scene, sun ∧ planets[0] ∧ planets[1], &"ecliptic {name}", now, place_sun)
    if system.comets >= 1:
      addPlane(scene, sun ∧ comets[0] ∧ planets[0], &"comet sheet {name}", now,
        place_comets[0])

  # Close with one object of each kind at horizon, each the attitude of something standing
  #   in the first system already. Attitude always drops one grade and always lands at
  #   horizon, so a line gives a point there, a plane gives a line, and a grade-4 volume
  #   gives a plane -- see `storyboard.STEPS`' own steps 09 and 11, which say the same thing
  #   at length. The volume is wedged here rather than added as an item: it is grade 4,
  #   which draws nothing at all, and a stress scene has no slot to spend on an invisible
  #   object.
  #   **All three come from Sol**, which is the system a reader recognises: the direction
  #   Earth lies in from its star, the attitude of Sol's own ecliptic disc, and the plane
  #   that ecliptic gives when wedged with a body standing off it.
  #   The volume is wedged from **Halley** and not from one of Sol's planets: a planet lies
  #   on the very ecliptic it rings, and a point wedged with a plane it lies on gives zero.
  #   They wear the derived hue because that is what they are -- three attitudes.
  addHorizon(scene, attitude(orbit_sol), "att(sol ∧ earth)", Shape.Point, now)
  addHorizon(scene, attitude(ecliptic_sol), "att(ecliptic sol)", Shape.Line, now)
  addHorizon(scene, attitude(halley ∧ ecliptic_sol), "att(halley ∧ ecliptic sol)",
    Shape.Plane, now)

  doAssert scene.len == ITEMS_ORRERY,
    &"Orrery built `{scene.len}` items where its own table comes to `{ITEMS_ORRERY}`. " &
      "The two counts are derived from the same table, so they can only differ if the " &
      "construction above stopped agreeing with `itemsOf` about what it emits."
