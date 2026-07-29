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
##   Lines and points therefore occlude correctly against each other.
##   Plane washes never occlude anything, so objects stay visible through them, which is
##   what a geometry viewer wants. Cost is that two washes crossing look order-dependent.

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ./[camera, mesh, objects]
import ./opengl as gl



#[ Renderer Configuration ]#

const
  SIZE_POINT* = 9.0'f32
    ## Set diameter of drawn points, in pixels.
  WIDTH_LINE* = 1.5'f32
    ## Set width of drawn lines, in pixels.
  LOG_MAX = 1024
    ## Bound how much of driver's compile log is reported.


const SOURCE_VERTEX = """
#version 330 core
layout (location = 0) in vec3 in_position;
layout (location = 1) in vec4 in_colour;
uniform mat4 view_projection;
uniform float size_point;
out vec4 vertex_colour;
out vec3 world_pos;
void main() {
  gl_Position = view_projection * vec4(in_position, 1.0);
  gl_PointSize = size_point;
  vertex_colour = in_colour;
  world_pos = in_position;
}
""" ## Transform world position to clip space, carrying vertex colour through, plus the
  ## untransformed world position itself for the highlight pass's own Fresnel term.


const SOURCE_FRAGMENT = """
#version 330 core
in vec4 vertex_colour;
in vec3 world_pos;
uniform float as_point;
uniform bool is_highlight;
uniform vec3 eye;
uniform vec3 highlight_normal;
out vec4 out_colour;
void main() {
  vec4 colour = vertex_colour;
  if (as_point > 0.5) {
    vec2 offset = gl_PointCoord - vec2(0.5);
    float r2 = dot(offset, offset);
    if (r2 > 0.25) discard;
    // Sphere-impostor rim: a point sprite's own gl_PointCoord already gives a free
    //   radial coordinate, so a genuine per-fragment Fresnel term falls out of it with
    //   no extra geometry -- brightest at the sprite's own silhouette edge, none at
    //   its centre, exactly the "highlighted item" glow games render this way for.
    if (is_highlight) colour = mix(colour, vec4(1.0), pow(clamp(sqrt(r2)*2.0, 0.0, 1.0), 2.0));
  } else if (is_highlight) {
    // A line carries no surface normal to be grazing or face-on to, so `highlight_normal`
    //   is left the zero vector for one and this falls back to a fixed, modest rim
    //   instead of a real Fresnel term; a plane's own real, constant normal gives a
    //   genuine one -- brighter near its own silhouette, where the sight line to a
    //   given point on it runs closest to grazing.
    float facing = dot(highlight_normal, highlight_normal) > 0.5
      ? abs(dot(normalize(eye - world_pos), highlight_normal)) : 0.6;
    colour = mix(colour, vec4(1.0), pow(1.0 - facing, 2.0));
  }
  out_colour = colour;
}
""" ## Write interpolated vertex colour, rounding off point sprites into discs, and
  ## brightening the current highlight pass's own fragments toward white at grazing
  ## angles -- a Fresnel rim, the same family of effect a game uses to mark a
  ## teammate, enemy or item, rather than a flat outline independent of view angle.



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
    location_is_highlight: gl.Int
    location_eye: gl.Int
    location_highlight_normal: gl.Int
    buffers: array[Primitive, Buffers]


const lut_primitive_to_mode: array[Primitive, gl.Enum] = [
  Primitive.Triangle: gl.TRIANGLES,
  Primitive.Line: gl.LINES,
  Primitive.Point: gl.POINTS,
] ## Map primitive kind to OpenGL's own mode enumerant.



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
  result.location_is_highlight = gl.getUniformLocation(result.program, "is_highlight")
  result.location_eye = gl.getUniformLocation(result.program, "eye")
  result.location_highlight_normal = gl.getUniformLocation(result.program, "highlight_normal")

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
  gl.enable(gl.LINE_SMOOTH)



#[ Frame Drawing ]#

proc clearFrame*(width, height: int) =
  ## Resize viewport and clear colour and depth to backdrop.
  let backdrop = Ink.Backdrop.colour
  gl.viewport(0, 0, gl.Sizei(width), gl.Sizei(height))
  gl.clearColor(backdrop.red, backdrop.green, backdrop.blue, 1.0)
  gl.clear(gl.COLOR_BUFFER_BIT or gl.DEPTH_BUFFER_BIT)


proc drawPrimitive(renderer: Renderer; meshes: MeshSet; primitive: Primitive) =
  ## Upload one mesh and draw it, skipping kinds no vertex was assembled for.
  let count = meshes[primitive].count_vertices
  if count == 0: return

  # Tell fragment stage whether it is shading point sprites, which are rounded off.
  gl.uniform1f(renderer.location_as_point, if primitive == Primitive.Point: 1.0 else: 0.0)
  gl.bindVertexArray(renderer.buffers[primitive].array_object)
  gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffers[primitive].buffer)
  gl.bufferData(
    gl.ARRAY_BUFFER,
    gl.Sizeiptr(count*sizeof(Vertex)),
    unsafeAddr meshes[primitive].vertices[0],
    gl.DYNAMIC_DRAW,
  )
  gl.drawArrays(lut_primitive_to_mode[primitive], 0, gl.Sizei(count))


proc drawMeshes*(renderer: Renderer; meshes: MeshSet; view_projection: Matrix4) =
  ## Draw every mesh, opaque kinds before translucent ones.
  gl.useProgram(renderer.program)
  gl.uniformMatrix4fv(
    renderer.location_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.uniform1f(renderer.location_size_point, SIZE_POINT)
  gl.lineWidth(WIDTH_LINE)

  # Draw opaque kinds first, so they own depth buffer.
  renderer.drawPrimitive(meshes, Primitive.Line)
  renderer.drawPrimitive(meshes, Primitive.Point)

  # Draw washes without writing depth, so objects stay visible through them.
  gl.depthMask(gl.FALSE)
  renderer.drawPrimitive(meshes, Primitive.Triangle)
  gl.depthMask(1)
  gl.uniform1i(renderer.location_is_highlight, 0)
  gl.bindVertexArray(0)


proc drawHighlight*(
  renderer: Renderer; meshes: MeshSet; eye: Position; normal: Option[Direction]
) =
  ## Draw the one object currently highlighted a second time, over the frame `drawMeshes`
  ## already assembled -- `meshes` here holds only that object's own real geometry (see
  ## `mesh.addObject`'s own caller in `visualiser.nim`/`browser_bridge.nim`), tessellated
  ## exactly as it already was for the main pass, not a separate ring or outline shape.
  ##   `is_highlight` switches the fragment shader to brighten toward white at grazing
  ##   angles instead of passing colour through untouched -- a real Fresnel rim for a
  ##   point (`gl_PointCoord` already gives a free sphere-impostor radial coordinate) or
  ##   a plane (its own constant `normal`), and a fixed, modest rim for a line, which has
  ##   no surface normal of its own to be grazing or face-on to.
  # Depth test off for this whole pass: it re-draws the same triangles and lines the
  #   main pass already drew, at literally the same depth, so testing against that
  #   pass's own depth buffer would only invite z-fighting -- flickering per-pixel
  #   pass/fail noise from floating-point rounding on numbers that should tie exactly.
  #   Drawing on top regardless also reads as a deliberate "this one is highlighted"
  #   emphasis, the same way a game's own selection glow usually ignores depth too.
  gl.disable(gl.DEPTH_TEST)
  gl.uniform1i(renderer.location_is_highlight, 1)
  gl.uniform3f(renderer.location_eye, gl.Float(eye.x), gl.Float(eye.y), gl.Float(eye.z))
  let n = if normal.isSome: normal.get else: Direction(x: 0, y: 0, z: 0)
  gl.uniform3f(renderer.location_highlight_normal, gl.Float(n.x), gl.Float(n.y), gl.Float(n.z))
  renderer.drawPrimitive(meshes, Primitive.Line)
  renderer.drawPrimitive(meshes, Primitive.Point)
  renderer.drawPrimitive(meshes, Primitive.Triangle)
  gl.uniform1i(renderer.location_is_highlight, 0)
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
