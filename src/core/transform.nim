## Build the view and projection matrices the renderers hand to GL.
##
## This is the one module that does linear algebra of its own, and it does no geometry: a
## projection matrix is a property of the graphics pipeline, not of the algebra under study.
## Every geometric question — where a point is, which direction spans a plane, what a meet
## lands on — is answered in `algebra.nim` through the library's own operators. What arrives
## here is already a world position.
##
## Matrices are column-major, the order GL uploads them in, so no transpose happens anywhere.

{.experimental: "strictFuncs".}

import std/math

import ./algebra



#[ Type Definitions ]#

type
  Matrix4* = object
    ## Carry a 4×4 transform in the column-major order GL expects.
    columns*: array[16, float]

  Clip* = object
    ## Carry a position after projection, before the perspective divide.
    x*, y*, z*, w*: float



#[ Matrix Construction ]#

func identity*(): Matrix4 =
  ## Build the transform that changes nothing.
  for i in 0 ..< 4: result.columns[i*4 + i] = 1.0


func perspective*(fov_y, aspect, near, far: float): Matrix4 =
  ## Build a perspective projection from a vertical field of view.
  let focal = 1.0 / tan(fov_y*0.5)
  result.columns[0] = focal / aspect
  result.columns[5] = focal
  result.columns[10] = (far + near) / (near - far)
  result.columns[11] = -1.0
  result.columns[14] = (2.0*far*near) / (near - far)


func lookAt*(eye, target, up: Position): Matrix4 =
  ## Build a view transform placing the eye and aiming it at a target.
  # Derive the eye's own frame; three normalizations and two cross products, all of them
  #   pipeline arithmetic rather than statements about the scene.
  var forward = Position(x: target.x - eye.x, y: target.y - eye.y, z: target.z - eye.z)
  let forward_length = sqrt(forward.x*forward.x + forward.y*forward.y + forward.z*forward.z)
  if forward_length > 0:
    forward = Position(
      x: forward.x/forward_length, y: forward.y/forward_length, z: forward.z/forward_length
    )
  var side = Position(
    x: forward.y*up.z - forward.z*up.y,
    y: forward.z*up.x - forward.x*up.z,
    z: forward.x*up.y - forward.y*up.x,
  )
  let side_length = sqrt(side.x*side.x + side.y*side.y + side.z*side.z)
  if side_length > 0:
    side = Position(x: side.x/side_length, y: side.y/side_length, z: side.z/side_length)
  let raised = Position(
    x: side.y*forward.z - side.z*forward.y,
    y: side.z*forward.x - side.x*forward.z,
    z: side.x*forward.y - side.y*forward.x,
  )

  result.columns[0] = side.x
  result.columns[4] = side.y
  result.columns[8] = side.z
  result.columns[1] = raised.x
  result.columns[5] = raised.y
  result.columns[9] = raised.z
  result.columns[2] = -forward.x
  result.columns[6] = -forward.y
  result.columns[10] = -forward.z
  result.columns[12] = -(side.x*eye.x + side.y*eye.y + side.z*eye.z)
  result.columns[13] = -(raised.x*eye.x + raised.y*eye.y + raised.z*eye.z)
  result.columns[14] = forward.x*eye.x + forward.y*eye.y + forward.z*eye.z
  result.columns[15] = 1.0



#[ Matrix Application ]#

func `*`*(a, b: Matrix4): Matrix4 =
  ## Compose transforms, applying `b` first.
  for column in 0 ..< 4:
    for row in 0 ..< 4:
      var sum = 0.0
      for k in 0 ..< 4:
        sum += a.columns[k*4 + row] * b.columns[column*4 + k]
      result.columns[column*4 + row] = sum


func project*(matrix: Matrix4, p: Position): Clip =
  ## Transform a world position into clip space.
  Clip(
    x: matrix.columns[0]*p.x + matrix.columns[4]*p.y + matrix.columns[8]*p.z +
      matrix.columns[12],
    y: matrix.columns[1]*p.x + matrix.columns[5]*p.y + matrix.columns[9]*p.z +
      matrix.columns[13],
    z: matrix.columns[2]*p.x + matrix.columns[6]*p.y + matrix.columns[10]*p.z +
      matrix.columns[14],
    w: matrix.columns[3]*p.x + matrix.columns[7]*p.y + matrix.columns[11]*p.z +
      matrix.columns[15],
  )


func toFloat32*(matrix: Matrix4): array[16, float32] =
  ## Narrow transform for upload, the precision GL takes.
  for i in 0 ..< 16: result[i] = matrix.columns[i].float32
