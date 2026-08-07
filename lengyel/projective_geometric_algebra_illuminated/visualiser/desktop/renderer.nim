## Own OpenGL resources, and draw meshes through them.
##
## One program serves every primitive: vertices carry their own colour, and only transform
## from world to clip space is uniform.
##   Keeps state changes per frame to three buffer uploads and three draw calls.
##
## Buffers are reuploaded whole each frame rather than tracked for changes.
##   Scene holds tens of objects, so upload is thousands of bytes, far below any budget.
##   Buys correctness for free: nothing can be stale after user edits a coefficient.
##
## Draw order is opaque first, translucent second, with depth writes off for translucent:
##   Ribbons and points therefore occlude correctly against each other.
##   Plane washes never occlude anything, so objects stay visible through them, which is
##   what a geometry viewer wants. Cost is that two washes crossing look order-dependent.
##
## Desktop-only; unreachable from the browser build. See `visualiser.nim`'s own "Render
## Paths" table.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../core/[camera, mesh]
import ./opengl as gl



#[ Renderer Configuration ]#

# `SIZE_POINT`, `WIDTH_LINE_FURNITURE` and `WIDTH_LINE_OBJECT` are declared in `mesh`
#   rather than here, though this module is their only OpenGL consumer: `marker` derives
#   a selection marker's own clearance from them and cannot import this module, which
#   binds straight to OpenGL. One home, read by both render paths, instead of the copy
#   `browser_bridge` used to carry.
const LOG_MAX = 1024
  ## Bound how much of driver's compile log is reported.


const SOURCE_VERTEX = """
#version 330 core
layout (location = 0) in vec3 in_position;
layout (location = 1) in vec4 in_colour;
uniform mat4 view_projection;
uniform float size_point;
out vec4 vertex_colour;
void main() {
  gl_Position = view_projection * vec4(in_position, 1.0);
  gl_PointSize = size_point;
  vertex_colour = in_colour;
}
""" ## Transform world position to clip space, carrying vertex colour through.


const SOURCE_FRAGMENT = """
#version 330 core
in vec4 vertex_colour;
uniform float as_point;
out vec4 out_colour;
void main() {
  if (as_point > 0.5) {
    vec2 offset = gl_PointCoord - vec2(0.5);
    if (dot(offset, offset) > 0.25) discard;
  }
  out_colour = vertex_colour;
}
""" ## Write interpolated vertex colour, rounding off point sprites into discs.
  ##   Nothing here is lit or textured, so colour passes straight through otherwise.



#[ Type Definitions ]#

type
  Buffers = object ## Hold vertex array and buffer backing one primitive kind.
    array_object: gl.Uint
    buffer: gl.Uint

  Renderer* = object ## Hold every OpenGL name visualiser allocates.
    program: gl.Uint
    location_view_projection: gl.Int
    location_size_point: gl.Int
    location_as_point: gl.Int
    buffers: array[Primitive, Buffers]


const lut_primitive_to_mode: array[Primitive, gl.Enum] = [
  Primitive.Triangle: gl.TRIANGLES,
  Primitive.Ribbon: gl.TRIANGLES,
  Primitive.Point: gl.POINTS,
] ## Map primitive kind to OpenGL's own mode enumerant.
  ##   A ribbon is a line drawn as triangles -- see `mesh.addSegment` for why a line width
  ##   is not something either of this project's targets can be asked to honour.



#[ Program Construction ]#

proc compileShader(kind: gl.Enum; source: string): gl.Uint =
  ## Compile one shader stage, reporting driver's own diagnosis on failure.
  result = gl.createShader(kind)
  var text = cstring(source)
  gl.shaderSource(result, 1, addr text, nil)
  gl.compileShader(result)

  var status: gl.Int
  gl.getShaderiv(result, gl.COMPILE_STATUS, addr status)
  if status != 0: return

  var log: array[LOG_MAX, char]
  gl.getShaderInfoLog(result, LOG_MAX, nil, addr log[0])
  doAssert false, &"Shader stage {kind:#x} failed to compile: {cast[cstring](addr log[0])}"


proc linkProgram(source_vertex, source_fragment: string): gl.Uint =
  ## Link vertex and fragment stages into program, reporting failure the same way.
  let
    shader_vertex = compileShader(gl.VERTEX_SHADER, source_vertex)
    shader_fragment = compileShader(gl.FRAGMENT_SHADER, source_fragment)
  result = gl.createProgram()
  gl.attachShader(result, shader_vertex)
  gl.attachShader(result, shader_fragment)
  gl.linkProgram(result)
  gl.deleteShader(shader_vertex)
  gl.deleteShader(shader_fragment)

  var status: gl.Int
  gl.getProgramiv(result, gl.LINK_STATUS, addr status)
  if status != 0: return

  var log: array[LOG_MAX, char]
  gl.getProgramInfoLog(result, LOG_MAX, nil, addr log[0])
  doAssert false, &"Program failed to link: {cast[cstring](addr log[0])}"



#[ Renderer Lifetime ]#

proc initRenderer*(): Renderer =
  ## Build program and one vertex buffer per primitive kind.
  ##   OpenGL context must already be current, as every call below needs it.
  result.program = linkProgram(SOURCE_VERTEX, SOURCE_FRAGMENT)
  result.location_view_projection =
    gl.getUniformLocation(result.program, "view_projection")
  result.location_size_point = gl.getUniformLocation(result.program, "size_point")
  result.location_as_point = gl.getUniformLocation(result.program, "as_point")

  const
    STRIDE = gl.Sizei(sizeof(Vertex))
    OFFSET_COLOUR = 3*sizeof(float32)
  for primitive in Primitive:
    gl.genVertexArrays(1, addr result.buffers[primitive].array_object)
    gl.genBuffers(1, addr result.buffers[primitive].buffer)
    gl.bindVertexArray(result.buffers[primitive].array_object)
    gl.bindBuffer(gl.ARRAY_BUFFER, result.buffers[primitive].buffer)
    gl.enableVertexAttribArray(0)
    gl.vertexAttribPointer(0, 3, gl.FLOAT_TYPE, gl.FALSE, STRIDE, cast[pointer](0))
    gl.enableVertexAttribArray(1)
    gl.vertexAttribPointer(
      1, 4, gl.FLOAT_TYPE, gl.FALSE, STRIDE, cast[pointer](OFFSET_COLOUR)
    )
  gl.bindVertexArray(0)

  gl.enable(gl.DEPTH_TEST)
  gl.depthFunc(gl.LESS)
  gl.enable(gl.BLEND)
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
  gl.enable(gl.PROGRAM_POINT_SIZE)
  # A ribbon is an ordinary triangle pair, so nothing smooths its edges the way
  #   `GL_LINE_SMOOTH` once smoothed a line's. Without this a 1.5-pixel grid ribbon is
  #   rasterised only where it covers a pixel centre and the whole ground grid reads as
  #   dotted -- which is exactly what the first capture after the change showed. The
  #   context is asked for a multisampled framebuffer in `visualiser.main`; this is what
  #   turns it on. The browser's own context asks for `antialias: true` and needs no
  #   equivalent line.
  gl.enable(gl.MULTISAMPLE)



#[ Frame Drawing ]#

proc clearFrame*(width, height: int) =
  ## Resize viewport and clear colour and depth to backdrop.
  let backdrop = Ink.Backdrop.colour
  gl.viewport(0, 0, gl.Sizei(width), gl.Sizei(height))
  gl.clearColor(backdrop.red, backdrop.green, backdrop.blue, 1.0)
  gl.clear(gl.COLOR_BUFFER_BIT or gl.DEPTH_BUFFER_BIT)


proc uploadPrimitive(renderer: Renderer; meshes: MeshSet; primitive: Primitive) =
  ## Hand one mesh's vertices to the driver whole, ready to be drawn as one run or two.
  ##   Separate from drawing because the two runs are issued in different *passes* rather
  ##   than back to back -- see `drawMeshes` -- and a mesh uploaded twice a frame would be
  ##   the one real cost of that split.
  let count = meshes[primitive].count_vertices
  if count == 0: return
  gl.bindVertexArray(renderer.buffers[primitive].array_object)
  gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffers[primitive].buffer)
  gl.bufferData(
    gl.ARRAY_BUFFER,
    gl.Sizeiptr(count*sizeof(Vertex)),
    unsafeAddr meshes[primitive].vertices[0],
    gl.DYNAMIC_DRAW,
  )


func runOf(mesh: Mesh; is_overlay: bool): tuple[first, count: int] =
  ## Say which stretch of one mesh belongs to the depth-tested run or to the overlay run.
  ##   Empty where the mesh has no such run, which is the ordinary case for the overlay:
  ##   nothing is selected on most frames. See `mesh.Mesh.index_overlay`.
  let split =
    if mesh.index_overlay.isSome: clamp(mesh.index_overlay.get, 0, mesh.count_vertices)
    else: mesh.count_vertices
  if is_overlay: (first: split, count: mesh.count_vertices - split)
  else: (first: 0, count: split)


proc drawRun(renderer: Renderer; meshes: MeshSet; primitive: Primitive; is_overlay: bool) =
  ## Draw one run of one already-uploaded mesh, skipping an empty one.
  let run = runOf(meshes[primitive], is_overlay)
  if run.count == 0: return
  # Tell fragment stage whether it is shading point sprites, which are rounded off.
  gl.uniform1f(renderer.location_as_point, if primitive == Primitive.Point: 1.0 else: 0.0)
  gl.bindVertexArray(renderer.buffers[primitive].array_object)
  gl.drawArrays(lut_primitive_to_mode[primitive], gl.Int(run.first), gl.Sizei(run.count))


func hasOverlay(meshes: MeshSet): bool =
  ## Report whether anything in this set asked to be drawn over the rest of it.
  for primitive in Primitive:
    if runOf(meshes[primitive], is_overlay = true).count > 0: return true
  false


proc drawMeshes*(renderer: Renderer; meshes: MeshSet; view_projection: Matrix4) =
  ## Draw every mesh, opaque kinds before translucent ones, then the overlay over both.
  ##   Took a line width once, and passed it to `gl.lineWidth`. It no longer does: a
  ##   width is now geometry, built into the ribbon at `mesh.addSegment` from the same
  ##   `WIDTH_LINE_OBJECT`/`WIDTH_LINE_FURNITURE` this used to hand the driver, so both
  ##   builds draw it rather than asking a driver to.
  ##   **The overlay is a second pass over every kind, not a tail on each one.** A tail was
  ##   tried and measured: a selected line came out over the other lines and still tinted
  ##   by a plane's wash, because the wash is a later kind and the overlay run, having no
  ##   depth test, writes no depth for that wash to be rejected against. A wash over the
  ##   object you just picked is exactly the complaint this answers, so the whole ordinary
  ##   set goes down before any of the overlay goes on top.
  gl.useProgram(renderer.program)
  gl.uniformMatrix4fv(
    renderer.location_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.uniform1f(renderer.location_size_point, SIZE_POINT)
  for primitive in Primitive: renderer.uploadPrimitive(meshes, primitive)

  # Draw opaque kinds first, so they own depth buffer.
  renderer.drawRun(meshes, Primitive.Ribbon, is_overlay = false)
  renderer.drawRun(meshes, Primitive.Point, is_overlay = false)

  # Draw washes without writing depth, so objects stay visible through them.
  gl.depthMask(gl.FALSE)
  renderer.drawRun(meshes, Primitive.Triangle, is_overlay = false)
  gl.depthMask(gl.TRUE)

  # And the overlay over all of it, with no depth test at all -- which turns writes off
  #   with it, so nothing here occludes anything either, and the same kind order decides
  #   what is over what among the selected objects themselves.
  if meshes.hasOverlay:
    gl.disable(gl.DEPTH_TEST)
    renderer.drawRun(meshes, Primitive.Ribbon, is_overlay = true)
    renderer.drawRun(meshes, Primitive.Point, is_overlay = true)
    renderer.drawRun(meshes, Primitive.Triangle, is_overlay = true)
    gl.enable(gl.DEPTH_TEST)
  gl.bindVertexArray(0)



#[ Frame Capture ]#

proc capturePixels*(width, height: int; pixels: var openArray[uint8]) =
  ## Read framebuffer back as tightly packed RGB triples, first row nearest bottom.
  ##   Caller owns fixed storage, sized to the largest export this build allows; nothing
  ##   is grown here, so a window resized past that bound fails loudly rather than
  ##   silently reallocating in what is meant to be a fixed-memory path.
  let count = width*height*3
  doAssert len(pixels) >= count,
    &"Readback buffer holds {len(pixels)} bytes, short of {count}."
  gl.pixelStorei(gl.PACK_ALIGNMENT, 1)
  gl.readPixels(
    0, 0, gl.Sizei(width), gl.Sizei(height), gl.RGB, gl.UNSIGNED_BYTE, addr pixels[0]
  )
