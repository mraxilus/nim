## Project world-space points through pinhole camera onto image plane.
##
## Projection of point 𝐩 is (𝐞 ∧ 𝐩) ∨ 𝐠̂, read as: join eye 𝐞 to 𝐩 to obtain sight ray,
## then meet that ray with image plane 𝐠̂.
##   Chosen over view matrix and perspective divide, so prototype shows library doing work
##   graphics pipeline normally hides. Cost is roughly ten times arithmetic per point.
##   Perspective divide is not written anywhere; it falls out of unitizing pierced point.
##
## Whole camera frame is derived from eye, target and up through RGA alone:
##
##   |-------------|------------------|--------------------------------------------------|
##   | Identifier  | Construction     | Meaning                                          |
##   |-------------|------------------|--------------------------------------------------|
##   | axis_sight  | 𝐞 ∧ 𝐭            | Line joining eye to target.                      |
##   | origin_image| 𝐞 + f·att(𝐋)     | Point where sight axis pierces image plane.      |
##   | plane_image | -(𝐨 ∧ 𝐋☆)        | Plane through 𝐨 perpendicular to sight axis.     |
##   | axis_right  | -(𝐋 ∧ 𝐮)☆        | Direction of image's +x, perpendicular to 𝐋, 𝐮.  |
##   | axis_up     | -(𝐋 ∧ 𝐫)☆        | Direction of image's +y, perpendicular to 𝐋, 𝐫.  |
##   |-------------|------------------|--------------------------------------------------|
##
## Sign of `plane_image` is flipped so its normal runs along sight direction.
##   Signed distance 𝐩 ∨ 𝐠̂ is then positive exactly for points in front of camera,
##   which is same quantity used to reject points at or behind pinhole.

{.experimental: "strictFuncs".}

import std/[math, options, strformat]

import ../pga
import ./[canvas, objects]



#[ Camera Configuration ]#

# Allow caller to widen or narrow view without editing source.
#   E.g. `--define:visualiser.degrees_field_of_view=60`.
const DEGREES_FIELD_OF_VIEW* {.define: "visualiser.degrees_field_of_view".} = 45

static:
  doAssert DEGREES_FIELD_OF_VIEW in 1 .. 179,
    &"Vertical field of view must be in range 1..179 degrees; got `{DEGREES_FIELD_OF_VIEW}`."

const
  DISTANCE_IMAGE* = 1.0
    ## Set distance from pinhole to image plane, in world units.
    ##   Value is arbitrary, as field of view rescales image plane to match.
  DISTANCE_NEAR* = 1.0e-6
    ## Set smallest depth a point may have and still be projected.
    ##   Below it, sight ray runs nearly parallel to image plane and pierce point diverges.
  EXTENT_IMAGE* = DISTANCE_IMAGE * tan(degToRad(0.5 * float(DEGREES_FIELD_OF_VIEW)))
    ## Set half-height of image plane, in world units, spanned by vertical field of view.



#[ Type Definitions ]#

type
  Camera* = object ## Hold pinhole camera and frame derived from its placement.
    eye*: Position ## Position of pinhole.
    origin_image*: Position ## Position where sight axis pierces image plane.
    axis_sight*: Multivector ## Grade-2 line joining eye to target.
    plane_image*: Multivector ## Unitized grade-3 plane points are projected onto.
    axis_right*: Direction ## Unit direction of image's +x.
    axis_up*: Direction ## Unit direction of image's +y.

  Projection* = object ## Hold image-space result of projecting one world point.
    position*: PointImage ## Normalised device coordinates of pierced point.
    depth*: float ## Signed distance in front of image plane, in world units.



#[ Camera Construction ]#

func initCamera*(eye, target: Position; up: Direction): Camera =
  ## Construct camera looking from `eye` towards `target`, with image's +y following `up`.
  let
    point_eye = toMultivector(eye)
    axis_sight = point_eye ∧ toMultivector(target)
    forward = direction(axis_sight)
  doAssert forward.isSome,
    "Camera eye and target must differ, as sight axis is line joining them."

  # Place image plane in front of pinhole, perpendicular to sight axis.
  let
    origin_image = eye + DISTANCE_IMAGE * forward.get
    plane_image = ^(-expandWeight(toMultivector(origin_image), axis_sight))

  # Span image plane by directions perpendicular to sight axis and to each other.
  let
    plane_vertical = axis_sight ∧ toMultivector(up)
    axis_right = directionNormal(plane_vertical)
  doAssert axis_right.isSome,
    "Camera up direction must not run along sight axis, as plane through both collapses."
  let
    plane_horizontal = axis_sight ∧ toMultivector(axis_right.get)
    axis_up = directionNormal(plane_horizontal)
  doAssert axis_up.isSome,
    "Camera sight axis and right direction must span plane; they are perpendicular."

  # Pin image's +y to caller's up, as antidual fixes axis only up to sign.
  let orientation = if dot(axis_up.get, up) < 0: -1.0 else: 1.0

  Camera(
    eye: eye,
    origin_image: origin_image,
    axis_sight: axis_sight,
    plane_image: plane_image,
    axis_right: axis_right.get,
    axis_up: orientation * axis_up.get,
  )



#[ Projection ]#

func depth*(camera: Camera, point: Multivector): Option[float] =
  ## Measure signed distance of point in front of image plane.
  ##   Antiwedge of unitized point with unitized plane is their separation, i.e. 𝐩̂ ∨ 𝐠̂.
  ##   None where point lies at horizon, as direction stands at no distance.
  let place = position(point)
  if place.isNone: return
  some((toMultivector(place.get) ∨ camera.plane_image)[Basis.scalar])


func project*(camera: Camera, point: Multivector): Option[Projection] =
  ## Project point through pinhole onto image plane.
  ##   None where point cannot appear in image, for any of three reasons:
  ##     Point lies at horizon, so it names direction rather than place.
  ##     Point lies at or behind image plane, so pinhole does not see it.
  ##     Sight ray misses image plane, which unitizing pierced point detects.
  let place = position(point)
  if place.isNone: return
  let
    point_unit = toMultivector(place.get)
    depth = (point_unit ∨ camera.plane_image)[Basis.scalar]
  if depth <= DISTANCE_NEAR: return

  # Meet sight ray with image plane, then unitize to perform perspective divide.
  let pierce = position((toMultivector(camera.eye) ∧ point_unit) ∨ camera.plane_image)
  if pierce.isNone: return

  # Resolve pierced point against image axes, scaled so field of view spans -1 .. 1.
  let offset = pierce.get - camera.origin_image
  some(Projection(
    position: PointImage(
      x: dot(offset, camera.axis_right) / EXTENT_IMAGE,
      y: dot(offset, camera.axis_up) / EXTENT_IMAGE,
    ),
    depth: depth,
  ))
