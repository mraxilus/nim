## Own OpenGL resources, and draw meshes through them.
##
## One program per record kind, and plain one for points.
##   Each record type in `mesh` has vertex shader here that widens it over static corner
##   geometry (see each `SOURCE_VERTEX_*` and reference proc it names).
##   CPU hands over compact records and no per-frame expansion.
## Buffers are reuploaded whole each frame rather than tracked for changes.
##   Upload is far below any budget, and nothing can be stale after user edits
##   coefficient.
## Draw order is opaque first, translucent second, with depth writes off for translucent.
##   Ribbons and points occlude correctly against each other.
##   Plane washes never occlude anything, so objects stay visible through them.
##   Cost is that two washes crossing look order-dependent.
##
## Desktop-only; unreachable from browser build. See `visualiser.nim`'s "Render Paths".

{.experimental: "strictFuncs".}

import std/[options, strformat]

import ../core/[camera, mesh]
import ./opengl as gl



#[ Renderer Configuration ]#

# Read `SIZE_POINT`, `WIDTH_LINE_FURNITURE` and `WIDTH_LINE_OBJECT` from `mesh`.
#   `marker` derives selection marker's clearance from them and cannot import module
#   binding straight to OpenGL; one home, read by both render paths.
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
  ##   Nothing is lit or textured, so colour passes straight through otherwise.


const SOURCE_VERTEX_RIBBON = """
#version 330 core
layout (location = 0) in vec2 in_corner;
layout (location = 1) in vec3 in_tail;
layout (location = 2) in vec3 in_head;
layout (location = 3) in float in_width;
layout (location = 4) in float in_fog;
layout (location = 5) in vec4 in_tint_tail;
layout (location = 6) in vec4 in_tint_head;
uniform mat4 view_projection;
uniform vec3 eye;
uniform vec3 forward;
uniform float depth_near;
uniform float tangent_half_view;
uniform float height_pixels;
out vec4 vertex_colour;
out vec3 vertex_world;
out float vertex_fog;
void main() {
  vertex_fog = in_fog;
  float depth_tail = dot(in_tail - eye, forward);
  float depth_head = dot(in_head - eye, forward);
  vec3 across_raw = cross(in_head - in_tail, eye - in_tail);
  float across_length = length(across_raw);
  if (max(depth_tail, depth_head) < depth_near || across_length < 1e-12) {
    gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
    vertex_colour = vec4(0.0);
    vertex_world = in_tail;
    return;
  }
  vec3 near_end = in_tail;
  vec3 far_end = in_head;
  vec4 tint_near = in_tint_tail;
  vec4 tint_far = in_tint_head;
  if (depth_tail < depth_near) {
    float fraction = (depth_near - depth_tail)/(depth_head - depth_tail);
    near_end = in_tail + fraction*(in_head - in_tail);
    tint_near = mix(in_tint_tail, in_tint_head, fraction);
  } else if (depth_head < depth_near) {
    float fraction = (depth_near - depth_head)/(depth_tail - depth_head);
    far_end = in_head + fraction*(in_tail - in_head);
    tint_far = mix(in_tint_head, in_tint_tail, fraction);
  }
  vec3 across = across_raw/across_length;
  vec3 at = mix(near_end, far_end, in_corner.x);
  float depth_at = max(dot(at - eye, forward), depth_near);
  float world_per_pixel = 2.0*depth_at*tangent_half_view/height_pixels;
  at += in_corner.y*0.5*in_width*world_per_pixel*across;
  gl_Position = view_projection*vec4(at, 1.0);
  vertex_world = at;
  vertex_colour = mix(tint_near, tint_far, in_corner.x);
}
""" ## Widen one ribbon record into corner this invocation is, on GPU.
  ##   Sibling copy of `mesh.expandRibbon`, reference suite pins to algebra, and of WebGL
  ##   source in `glue.js`; change to any one is not finished until other two are checked.
  ##   Line for line: reject segment wholly behind near plane (six coincident clipped
  ##   corners), clip end crossing it and blend tint by same fraction, derive across as
  ##   cross join reduces to, step corner off by half width of its end's world-per-pixel.
  ##   `in_corner` is (end, side).
  ##   `in_fog` and world position pass through for fragment stage's fog; see
  ##   `SOURCE_FRAGMENT_RIBBON`.


const SOURCE_FRAGMENT_RIBBON = """
#version 330 core
in vec4 vertex_colour;
in vec3 vertex_world;
in float vertex_fog;
uniform vec3 eye;
uniform float fog_radius_full;
uniform float fog_radius_gone;
out vec4 out_colour;
void main() {
  float fade = 1.0 - clamp(
    (distance(vertex_world, eye) - fog_radius_full)/(fog_radius_gone - fog_radius_full),
    0.0, 1.0
  );
  out_colour = vec4(
    vertex_colour.rgb, vertex_colour.a*mix(1.0, fade, clamp(vertex_fog, 0.0, 1.0))
  );
}
""" ## Shade one ribbon fragment, fading fogged record by its distance from eye.
  ##   Sibling copy of `mesh.alphaGridFade` and of WebGL source in `glue.js`; change to
  ##   any one is not finished until other two are checked.
  ##   Per fragment rather than per vertex, so fade is exact along record of any length,
  ##   which lets lattice line be one record.
  ##   Record with `fog` zero passes through untouched, which is every scene ribbon.


const CORNERS_RIBBON: array[12, float32] = [
  0.0'f32, -1.0, 1.0, -1.0, 1.0, 1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0,
] ## Six (end, side) corners of one ribbon instance, in `expandRibbon`'s winding.


const SOURCE_VERTEX_DISC = """
#version 330 core
layout (location = 0) in vec2 in_corner;
layout (location = 1) in vec3 in_centre;
layout (location = 2) in vec3 in_arm_first;
layout (location = 3) in vec3 in_arm_second;
layout (location = 4) in vec4 in_fill;
uniform mat4 view_projection;
out vec4 vertex_colour;
void main() {
  vec3 at = in_centre + in_corner.x*in_arm_first + in_corner.y*in_arm_second;
  gl_Position = view_projection*vec4(at, 1.0);
  vertex_colour = in_fill;
}
""" ## Fan one disc record over static corner buffer, on GPU.
  ##   Sibling copy of `mesh.expandDiscVertex` and of WebGL source in `glue.js`; change to
  ##   any one is not finished until other two are checked.
  ##   Each corner is centre plus two radius-scaled arms weighted by its cosine and sine;
  ##   `(0, 0)` lands centre corner on centre exactly.


const SOURCE_VERTEX_DOME = """
#version 330 core
layout (location = 0) in vec3 in_unit;
layout (location = 1) in vec4 in_centre_radius;
layout (location = 2) in vec4 in_tint;
uniform mat4 view_projection;
out vec4 vertex_colour;
void main() {
  vec3 at = in_centre_radius.xyz + in_centre_radius.w*in_unit;
  gl_Position = view_projection*vec4(at, 1.0);
  vertex_colour = in_tint;
}
""" ## Widen one dome record over static unit sphere, on GPU.
  ##   Sibling copy of `mesh.expandDomeVertex`, under same three-way rule as disc source.
  ##   Centre plus unit direction scaled by radius.


const SOURCE_VERTEX_RING = """
#version 330 core
layout (location = 0) in vec4 in_arc;
layout (location = 1) in vec2 in_corner;
layout (location = 2) in vec3 in_centre;
layout (location = 3) in vec3 in_arm_first;
layout (location = 4) in vec3 in_arm_second;
layout (location = 5) in vec4 in_fill;
layout (location = 6) in float in_width;
uniform mat4 view_projection;
uniform vec3 eye;
uniform vec3 forward;
uniform float depth_near;
uniform float tangent_half_view;
uniform float height_pixels;
out vec4 vertex_colour;
void main() {
  vec3 tail = in_centre + in_arc.x*in_arm_first + in_arc.y*in_arm_second;
  vec3 head = in_centre + in_arc.z*in_arm_first + in_arc.w*in_arm_second;
  float depth_tail = dot(tail - eye, forward);
  float depth_head = dot(head - eye, forward);
  vec3 across_raw = cross(head - tail, eye - tail);
  float across_length = length(across_raw);
  if (max(depth_tail, depth_head) < depth_near || across_length < 1e-12) {
    gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
    vertex_colour = vec4(0.0);
    return;
  }
  vec3 near_end = tail;
  vec3 far_end = head;
  if (depth_tail < depth_near) {
    float fraction = (depth_near - depth_tail)/(depth_head - depth_tail);
    near_end = tail + fraction*(head - tail);
  } else if (depth_head < depth_near) {
    float fraction = (depth_near - depth_head)/(depth_tail - depth_head);
    far_end = head + fraction*(tail - head);
  }
  vec3 across = across_raw/across_length;
  vec3 at = mix(near_end, far_end, in_corner.x);
  float depth_at = max(dot(at - eye, forward), depth_near);
  float world_per_pixel = 2.0*depth_at*tangent_half_view/height_pixels;
  at += in_corner.y*0.5*in_width*world_per_pixel*across;
  gl_Position = view_projection*vec4(at, 1.0);
  vertex_colour = in_fill;
}
""" ## Widen one ring record into whole plane rim, on GPU.
  ##   Sibling copy of `mesh.expandRingVertex` and of WebGL source in `glue.js`; change to
  ##   any one is not finished until other two are checked.
  ##   One instance is entire circle.
  ##     Static corner buffer carries every segment of closed walk, and `in_arc` names
  ##     this invocation's segment as two angles' `(cos, sin)` pairs.
  ##   Two steps, only first ring's: place segment's ends as `SOURCE_VERTEX_DISC` places
  ##   fan corners, then widen pair by ribbon source's body, line for line, since rim is
  ##   line.
  ##     Tint is flat, so ribbon's blend collapses to `in_fill`; fog is zero, so this
  ##     shares plain fragment stage.


const
  COUNT_CORNERS_DISC = 3*SEGMENTS_CIRCLE_HORIZON
    ## Count corners disc fan's static buffer holds.
    ##   `mesh.discCorners` emits exactly this many `(cos, sin)` pairs.
  COUNT_CORNERS_DOME = 6*LATITUDES_HORIZON*LONGITUDES_HORIZON
    ## Count corners dome's static buffer holds.
    ##   `mesh.domeCorners` emits exactly this many unit directions.
  COUNT_CORNERS_RING = 6*SEGMENTS_CIRCLE_HORIZON
    ## Count corners ring's static buffer holds, whole rim at six per segment.
    ##   `mesh.ringCorners` emits exactly this many six-float entries.



#[ Type Definitions ]#

type
  Renderer* = object ## Define every OpenGL name visualiser allocates.
    program: gl.Uint
    location_view_projection: gl.Int
    location_size_point: gl.Int
    location_as_point: gl.Int
    array_points: gl.Uint
    buffer_points: gl.Uint
    program_ribbon: gl.Uint
    location_ribbon_view_projection: gl.Int
    location_ribbon_eye: gl.Int
    location_ribbon_forward: gl.Int
    location_ribbon_depth_near: gl.Int
    location_ribbon_tangent: gl.Int
    location_ribbon_height: gl.Int
    location_ribbon_fog_full: gl.Int
    location_ribbon_fog_gone: gl.Int
    array_ribbon: gl.Uint
    buffer_ribbon_corners: gl.Uint
    buffer_ribbon_records: gl.Uint
    program_disc: gl.Uint
    location_disc_view_projection: gl.Int
    array_disc: gl.Uint
    buffer_disc_corners: gl.Uint
    buffer_disc_records: gl.Uint
    program_dome: gl.Uint
    location_dome_view_projection: gl.Int
    array_dome: gl.Uint
    buffer_dome_corners: gl.Uint
    buffer_dome_records: gl.Uint
    program_ring: gl.Uint
    location_ring_view_projection: gl.Int
    location_ring_eye: gl.Int
    location_ring_forward: gl.Int
    location_ring_depth_near: gl.Int
    location_ring_tangent: gl.Int
    location_ring_height: gl.Int
    array_ring: gl.Uint
    buffer_ring_corners: gl.Uint
    buffer_ring_records: gl.Uint



#[ Program Construction ]#

proc compileShader(kind: gl.Enum; source: string): gl.Uint =
  ## Compile one shader stage, reporting driver's diagnosis on failure.
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
  ## Link vertex and fragment stages into program, reporting failure same way.
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
  ## Build every program, point vertex buffer, and each record kind's instanced array.
  ##   Each array carries its static corner geometry.
  ##   OpenGL context must already be current.
  result.program = linkProgram(SOURCE_VERTEX, SOURCE_FRAGMENT)
  result.location_view_projection =
    gl.getUniformLocation(result.program, "view_projection")
  result.location_size_point = gl.getUniformLocation(result.program, "size_point")
  result.location_as_point = gl.getUniformLocation(result.program, "as_point")

  const
    STRIDE = gl.Sizei(sizeof(Vertex))
    OFFSET_COLOUR = 3*sizeof(float32)
  gl.genVertexArrays(1, addr result.array_points)
  gl.genBuffers(1, addr result.buffer_points)
  gl.bindVertexArray(result.array_points)
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_points)
  gl.enableVertexAttribArray(0)
  gl.vertexAttribPointer(0, 3, gl.FLOAT_TYPE, gl.FALSE, STRIDE, cast[pointer](0))
  gl.enableVertexAttribArray(1)
  gl.vertexAttribPointer(
    1, 4, gl.FLOAT_TYPE, gl.FALSE, STRIDE, cast[pointer](OFFSET_COLOUR)
  )
  gl.bindVertexArray(0)

  result.program_ribbon = linkProgram(SOURCE_VERTEX_RIBBON, SOURCE_FRAGMENT_RIBBON)
  result.location_ribbon_view_projection =
    gl.getUniformLocation(result.program_ribbon, "view_projection")
  result.location_ribbon_eye = gl.getUniformLocation(result.program_ribbon, "eye")
  result.location_ribbon_forward = gl.getUniformLocation(result.program_ribbon, "forward")
  result.location_ribbon_depth_near =
    gl.getUniformLocation(result.program_ribbon, "depth_near")
  result.location_ribbon_tangent =
    gl.getUniformLocation(result.program_ribbon, "tangent_half_view")
  result.location_ribbon_height =
    gl.getUniformLocation(result.program_ribbon, "height_pixels")
  result.location_ribbon_fog_full =
    gl.getUniformLocation(result.program_ribbon, "fog_radius_full")
  result.location_ribbon_fog_gone =
    gl.getUniformLocation(result.program_ribbon, "fog_radius_gone")

  gl.genVertexArrays(1, addr result.array_ribbon)
  gl.genBuffers(1, addr result.buffer_ribbon_corners)
  gl.genBuffers(1, addr result.buffer_ribbon_records)
  gl.bindVertexArray(result.array_ribbon)
  # Upload six fixed corners every instance shares, with one record per instance beside.
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_ribbon_corners)
  gl.bufferData(
    gl.ARRAY_BUFFER, gl.Sizeiptr(sizeof(CORNERS_RIBBON)),
    unsafeAddr CORNERS_RIBBON[0], gl.STATIC_DRAW,
  )
  gl.enableVertexAttribArray(0)
  gl.vertexAttribPointer(0, 2, gl.FLOAT_TYPE, gl.FALSE, gl.Sizei(2*sizeof(float32)),
    cast[pointer](0))
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_ribbon_records)
  const STRIDE_RECORD = gl.Sizei(sizeof(RibbonRecord))
  # Point each of record's six views: (attribute, floats, float offset).
  for (index, floats, offset) in [
    (gl.Uint(1), gl.Int(3), 0), (gl.Uint(2), gl.Int(3), 3), (gl.Uint(3), gl.Int(1), 6),
    (gl.Uint(4), gl.Int(1), 7), (gl.Uint(5), gl.Int(4), 8), (gl.Uint(6), gl.Int(4), 12),
  ]:
    gl.enableVertexAttribArray(index)
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_RECORD,
      cast[pointer](offset*sizeof(float32)))
    gl.vertexAttribDivisor(index, 1)
  gl.bindVertexArray(0)

  # Build two wash programs.
  #   Each has static corner geometry from `mesh`'s generators, same source `glue.js`
  #   uploads through `nimDiscCorners`, and one record buffer of divisor-one instance
  #   attributes beside it.
  result.program_disc = linkProgram(SOURCE_VERTEX_DISC, SOURCE_FRAGMENT)
  result.location_disc_view_projection =
    gl.getUniformLocation(result.program_disc, "view_projection")
  gl.useProgram(result.program_disc)
  gl.uniform1f(gl.getUniformLocation(result.program_disc, "as_point"), 0.0)
  gl.genVertexArrays(1, addr result.array_disc)
  gl.genBuffers(1, addr result.buffer_disc_corners)
  gl.genBuffers(1, addr result.buffer_disc_records)
  gl.bindVertexArray(result.array_disc)
  let corners_disc = discCorners()
  doAssert len(corners_disc) == 2*COUNT_CORNERS_DISC,
    &"Disc corner buffer holds {len(corners_disc)} floats, not {2*COUNT_CORNERS_DISC}."
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_disc_corners)
  gl.bufferData(
    gl.ARRAY_BUFFER, gl.Sizeiptr(len(corners_disc)*sizeof(float32)),
    unsafeAddr corners_disc[0], gl.STATIC_DRAW,
  )
  gl.enableVertexAttribArray(0)
  gl.vertexAttribPointer(0, 2, gl.FLOAT_TYPE, gl.FALSE, gl.Sizei(2*sizeof(float32)),
    cast[pointer](0))
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_disc_records)
  const STRIDE_DISC = gl.Sizei(sizeof(DiscRecord))
  # Point each of record's four views: (attribute, floats, float offset).
  for (index, floats, offset) in [
    (gl.Uint(1), gl.Int(3), 0), (gl.Uint(2), gl.Int(3), 3), (gl.Uint(3), gl.Int(3), 6),
    (gl.Uint(4), gl.Int(4), 9),
  ]:
    gl.enableVertexAttribArray(index)
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_DISC,
      cast[pointer](offset*sizeof(float32)))
    gl.vertexAttribDivisor(index, 1)
  gl.bindVertexArray(0)

  # Build ring program, on same shape.
  #   Static corner geometry from `mesh.ringCorners`, buffer `glue.js` uploads through
  #   `nimRingCorners`, and one record buffer of divisor-one instance attributes.
  #   Takes ribbon program's camera uniforms too, because widening it runs is ribbon's.
  result.program_ring = linkProgram(SOURCE_VERTEX_RING, SOURCE_FRAGMENT)
  result.location_ring_view_projection =
    gl.getUniformLocation(result.program_ring, "view_projection")
  result.location_ring_eye = gl.getUniformLocation(result.program_ring, "eye")
  result.location_ring_forward = gl.getUniformLocation(result.program_ring, "forward")
  result.location_ring_depth_near =
    gl.getUniformLocation(result.program_ring, "depth_near")
  result.location_ring_tangent =
    gl.getUniformLocation(result.program_ring, "tangent_half_view")
  result.location_ring_height =
    gl.getUniformLocation(result.program_ring, "height_pixels")
  gl.useProgram(result.program_ring)
  gl.uniform1f(gl.getUniformLocation(result.program_ring, "as_point"), 0.0)
  gl.genVertexArrays(1, addr result.array_ring)
  gl.genBuffers(1, addr result.buffer_ring_corners)
  gl.genBuffers(1, addr result.buffer_ring_records)
  gl.bindVertexArray(result.array_ring)
  let corners_ring = ringCorners()
  doAssert len(corners_ring) == 6*COUNT_CORNERS_RING,
    &"Ring corner buffer holds {len(corners_ring)} floats, not {6*COUNT_CORNERS_RING}."
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_ring_corners)
  gl.bufferData(
    gl.ARRAY_BUFFER, gl.Sizeiptr(len(corners_ring)*sizeof(float32)),
    unsafeAddr corners_ring[0], gl.STATIC_DRAW,
  )
  # Point two views on one corner entry: segment's two angles, then its (end, side).
  const STRIDE_CORNER_RING = gl.Sizei(6*sizeof(float32))
  for (index, floats, offset) in [(gl.Uint(0), gl.Int(4), 0), (gl.Uint(1), gl.Int(2), 4)]:
    gl.enableVertexAttribArray(index)
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_CORNER_RING,
      cast[pointer](offset*sizeof(float32)))
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_ring_records)
  const STRIDE_RING = gl.Sizei(sizeof(RingRecord))
  # Point each of record's five views: (attribute, floats, float offset).
  for (index, floats, offset) in [
    (gl.Uint(2), gl.Int(3), 0), (gl.Uint(3), gl.Int(3), 3), (gl.Uint(4), gl.Int(3), 6),
    (gl.Uint(5), gl.Int(4), 9), (gl.Uint(6), gl.Int(1), 13),
  ]:
    gl.enableVertexAttribArray(index)
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_RING,
      cast[pointer](offset*sizeof(float32)))
    gl.vertexAttribDivisor(index, 1)
  gl.bindVertexArray(0)

  result.program_dome = linkProgram(SOURCE_VERTEX_DOME, SOURCE_FRAGMENT)
  result.location_dome_view_projection =
    gl.getUniformLocation(result.program_dome, "view_projection")
  gl.useProgram(result.program_dome)
  gl.uniform1f(gl.getUniformLocation(result.program_dome, "as_point"), 0.0)
  gl.genVertexArrays(1, addr result.array_dome)
  gl.genBuffers(1, addr result.buffer_dome_corners)
  gl.genBuffers(1, addr result.buffer_dome_records)
  gl.bindVertexArray(result.array_dome)
  let corners_dome = domeCorners()
  doAssert len(corners_dome) == 3*COUNT_CORNERS_DOME,
    &"Dome corner buffer holds {len(corners_dome)} floats, not {3*COUNT_CORNERS_DOME}."
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_dome_corners)
  gl.bufferData(
    gl.ARRAY_BUFFER, gl.Sizeiptr(len(corners_dome)*sizeof(float32)),
    unsafeAddr corners_dome[0], gl.STATIC_DRAW,
  )
  gl.enableVertexAttribArray(0)
  gl.vertexAttribPointer(0, 3, gl.FLOAT_TYPE, gl.FALSE, gl.Sizei(3*sizeof(float32)),
    cast[pointer](0))
  gl.bindBuffer(gl.ARRAY_BUFFER, result.buffer_dome_records)
  const STRIDE_DOME = gl.Sizei(sizeof(DomeRecord))
  # Point record's two views: (attribute, floats, float offset).
  for (index, floats, offset) in [(gl.Uint(1), gl.Int(4), 0), (gl.Uint(2), gl.Int(4), 4)]:
    gl.enableVertexAttribArray(index)
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_DOME,
      cast[pointer](offset*sizeof(float32)))
    gl.vertexAttribDivisor(index, 1)
  gl.bindVertexArray(0)

  gl.enable(gl.DEPTH_TEST)
  gl.depthFunc(gl.LESS)
  gl.enable(gl.BLEND)
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
  gl.enable(gl.PROGRAM_POINT_SIZE)
  # Smooth ribbon edges by multisampling.
  #   Ribbon is ordinary triangle pair, so nothing smooths its edges as `GL_LINE_SMOOTH`
  #   smoothed line's; without this thin grid ribbon rasterises only where it covers pixel
  #   centre, and whole grid reads as dotted.
  #   Context asks for multisampled framebuffer in `visualiser.main`; this turns it on.
  #   Browser asks `antialias: true`.
  gl.enable(gl.MULTISAMPLE)



#[ Frame Drawing ]#

proc clearFrame*(width, height: int) =
  ## Clear colour and depth to backdrop, resizing viewport first.
  let backdrop = Ink.Backdrop.colour
  gl.viewport(0, 0, gl.Sizei(width), gl.Sizei(height))
  gl.clearColor(backdrop.red, backdrop.green, backdrop.blue, 1.0)
  gl.clear(gl.COLOR_BUFFER_BIT or gl.DEPTH_BUFFER_BIT)


proc uploadPoints(renderer: Renderer; meshes: MeshSet) =
  ## Hand point vertices to driver whole, ready to be drawn as one run or two.
  ##   Separate from drawing because two runs are issued in different passes; see
  ##   `drawMeshes`.
  ##   Mesh uploaded twice per frame would be one real cost of that split.
  let count = meshes.points.count_vertices
  if count == 0: return
  gl.bindVertexArray(renderer.array_points)
  gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_points)
  gl.bufferData(
    gl.ARRAY_BUFFER,
    gl.Sizeiptr(count*sizeof(Vertex)),
    unsafeAddr meshes.points.vertices[0],
    gl.DYNAMIC_DRAW,
  )


proc uploadRibbons(renderer: Renderer; meshes: MeshSet) =
  ## Hand this frame's ribbon records to driver whole; shader does rest.
  if meshes.ribbons.count == 0: return
  gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_ribbon_records)
  gl.bufferData(
    gl.ARRAY_BUFFER,
    gl.Sizeiptr(meshes.ribbons.count*sizeof(RibbonRecord)),
    unsafeAddr meshes.ribbons.records[0],
    gl.DYNAMIC_DRAW,
  )


proc uploadWashes(renderer: Renderer; meshes: MeshSet) =
  ## Hand this frame's disc, ring and dome records to driver whole; shaders fan them.
  ##   Rings ride along on same upload schedule, not because rim is wash: it is drawn
  ##   opaque, with lines.
  if meshes.rings.count > 0:
    gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_ring_records)
    gl.bufferData(
      gl.ARRAY_BUFFER,
      gl.Sizeiptr(meshes.rings.count*sizeof(RingRecord)),
      unsafeAddr meshes.rings.records[0],
      gl.DYNAMIC_DRAW,
    )
  if meshes.discs.count > 0:
    gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_disc_records)
    gl.bufferData(
      gl.ARRAY_BUFFER,
      gl.Sizeiptr(meshes.discs.count*sizeof(DiscRecord)),
      unsafeAddr meshes.discs.records[0],
      gl.DYNAMIC_DRAW,
    )
  if meshes.domes.count > 0:
    gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_dome_records)
    gl.bufferData(
      gl.ARRAY_BUFFER,
      gl.Sizeiptr(meshes.domes.count*sizeof(DomeRecord)),
      unsafeAddr meshes.domes.records[0],
      gl.DYNAMIC_DRAW,
    )


func runOfRibbons(ribbons: RibbonMesh; is_overlay: bool): tuple[first, count: int] =
  ## Say which stretch of ribbon records belongs to which pass; `runOf`'s rule.
  let split =
    if ribbons.index_overlay.isSome: clamp(ribbons.index_overlay.get, 0, ribbons.count)
    else: ribbons.count
  if is_overlay: (first: split, count: ribbons.count - split)
  else: (first: 0, count: split)


proc drawRibbonRun(renderer: Renderer; meshes: MeshSet; is_overlay: bool) =
  ## Draw one run of already-uploaded ribbon records as instanced triangle pairs.
  ##   GL 3.3 has no base instance, so run not starting at first record re-points five
  ##   instance attributes at its first byte.
  ##     Same pointers `initRenderer` set, offset by run's start.
  let run = runOfRibbons(meshes.ribbons, is_overlay)
  if run.count == 0: return
  gl.bindVertexArray(renderer.array_ribbon)
  gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_ribbon_records)
  const STRIDE_RECORD = gl.Sizei(sizeof(RibbonRecord))
  for (index, floats, offset) in [
    (gl.Uint(1), gl.Int(3), 0), (gl.Uint(2), gl.Int(3), 3), (gl.Uint(3), gl.Int(1), 6),
    (gl.Uint(4), gl.Int(1), 7), (gl.Uint(5), gl.Int(4), 8), (gl.Uint(6), gl.Int(4), 12),
  ]:
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_RECORD,
      cast[pointer]((run.first*sizeof(RibbonRecord)) + offset*sizeof(float32)))
  gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, gl.Sizei(run.count))


func runOfRings(rings: RingMesh; is_overlay: bool): tuple[first, count: int] =
  ## Say which stretch of ring records belongs to which pass; `runOf`'s rule.
  let split =
    if rings.index_overlay.isSome: clamp(rings.index_overlay.get, 0, rings.count)
    else: rings.count
  if is_overlay: (first: split, count: rings.count - split)
  else: (first: 0, count: split)


proc drawRingRun(renderer: Renderer; meshes: MeshSet; is_overlay: bool) =
  ## Draw one run of already-uploaded ring records, each instance whole plane rim.
  ##   Re-points instance attributes at run's first byte, `drawRibbonRun`'s rule.
  ##   Mirrors `glue.js`'s `drawRings`.
  let run = runOfRings(meshes.rings, is_overlay)
  if run.count == 0: return
  gl.bindVertexArray(renderer.array_ring)
  gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_ring_records)
  const STRIDE_RING = gl.Sizei(sizeof(RingRecord))
  for (index, floats, offset) in [
    (gl.Uint(2), gl.Int(3), 0), (gl.Uint(3), gl.Int(3), 3), (gl.Uint(4), gl.Int(3), 6),
    (gl.Uint(5), gl.Int(4), 9), (gl.Uint(6), gl.Int(1), 13),
  ]:
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_RING,
      cast[pointer]((run.first*sizeof(RingRecord)) + offset*sizeof(float32)))
  gl.drawArraysInstanced(
    gl.TRIANGLES, 0, gl.Sizei(COUNT_CORNERS_RING), gl.Sizei(run.count)
  )


func runOf(mesh: Mesh; is_overlay: bool): tuple[first, count: int] =
  ## Say which stretch of one mesh belongs to depth-tested run or to overlay run.
  ##   Empty where mesh has no such run, ordinary case for overlay; see
  ##   `mesh.Mesh.index_overlay`.
  let split =
    if mesh.index_overlay.isSome: clamp(mesh.index_overlay.get, 0, mesh.count_vertices)
    else: mesh.count_vertices
  if is_overlay: (first: split, count: mesh.count_vertices - split)
  else: (first: 0, count: split)


proc drawPointRun(renderer: Renderer; meshes: MeshSet; is_overlay: bool) =
  ## Draw one run of already-uploaded point mesh, skipping empty one.
  let run = runOf(meshes.points, is_overlay)
  if run.count == 0: return
  # Tell fragment stage it is shading point sprites, which are rounded off.
  gl.uniform1f(renderer.location_as_point, 1.0)
  gl.bindVertexArray(renderer.array_points)
  gl.drawArrays(gl.POINTS, gl.Int(run.first), gl.Sizei(run.count))


func runsOfWashes(washes: WashRuns; is_overlay: bool): tuple[begin, until: int] =
  ## Say which stretch of wash runs belongs to which pass: `runOf`'s rule at run grain.
  ##   Run never straddles mark; see `mesh.WashRuns`.
  let split =
    if washes.index_overlay.isSome: clamp(washes.index_overlay.get, 0, washes.count)
    else: washes.count
  if is_overlay: (begin: split, until: washes.count)
  else: (begin: 0, until: split)


proc drawWashRuns(renderer: Renderer; meshes: MeshSet; is_overlay: bool) =
  ## Walk one pass's stretch of wash draw order, drawing each run through its program.
  ##   Two washes then blend in order scene emitted them.
  ##   Re-points instance attributes at run's first byte, as `drawRibbonRun` does.
  ##   Mirrors `glue.js`'s `drawWashRuns`.
  let (begin, until) = runsOfWashes(meshes.washes, is_overlay)
  for i in begin ..< until:
    let run = meshes.washes.runs[i]
    case run.kind
    of WashKind.Disc:
      gl.useProgram(renderer.program_disc)
      gl.bindVertexArray(renderer.array_disc)
      gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_disc_records)
      const STRIDE_DISC = gl.Sizei(sizeof(DiscRecord))
      for (index, floats, offset) in [
        (gl.Uint(1), gl.Int(3), 0), (gl.Uint(2), gl.Int(3), 3),
        (gl.Uint(3), gl.Int(3), 6), (gl.Uint(4), gl.Int(4), 9),
      ]:
        gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_DISC,
          cast[pointer]((int(run.first)*sizeof(DiscRecord)) + offset*sizeof(float32)))
      gl.drawArraysInstanced(
        gl.TRIANGLES, 0, gl.Sizei(COUNT_CORNERS_DISC), gl.Sizei(run.count)
      )
    of WashKind.Dome:
      gl.useProgram(renderer.program_dome)
      gl.bindVertexArray(renderer.array_dome)
      gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_dome_records)
      const STRIDE_DOME = gl.Sizei(sizeof(DomeRecord))
      for (index, floats, offset) in [(gl.Uint(1), gl.Int(4), 0), (gl.Uint(2), gl.Int(4), 4)]:
        gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_DOME,
          cast[pointer]((int(run.first)*sizeof(DomeRecord)) + offset*sizeof(float32)))
      gl.drawArraysInstanced(
        gl.TRIANGLES, 0, gl.Sizei(COUNT_CORNERS_DOME), gl.Sizei(run.count)
      )


func hasOverlay(meshes: MeshSet): bool =
  ## Report whether anything in this set asked to be drawn over rest of it.
  if runOfRibbons(meshes.ribbons, is_overlay = true).count > 0: return true
  if runOfRings(meshes.rings, is_overlay = true).count > 0: return true
  if runOf(meshes.points, is_overlay = true).count > 0: return true
  let (begin, until) = runsOfWashes(meshes.washes, is_overlay = true)
  until > begin


proc drawMeshes*(
  renderer: Renderer; meshes: MeshSet; view_projection: Matrix4; scale: DrawScale
) =
  ## Draw every mesh, opaque kinds before translucent ones, then overlay over both.
  ##   Takes frame's `DrawScale` because ribbon program needs camera.
  ##     Widening, near clip and screen-constant width run in its vertex shader, fed by
  ##     fields `mesh.expandRibbon` reads.
  ##   Overlay is second pass over every kind, not tail on each one.
  ##     Tail leaves selected line over other lines and still tinted by plane's wash,
  ##     because wash is later kind and overlay run writes no depth for it to be rejected
  ##     against.
  gl.useProgram(renderer.program_ribbon)
  gl.uniformMatrix4fv(
    renderer.location_ribbon_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.uniform3f(renderer.location_ribbon_eye,
    gl.Float(scale.eye.x), gl.Float(scale.eye.y), gl.Float(scale.eye.z))
  gl.uniform3f(renderer.location_ribbon_forward,
    gl.Float(scale.forward.x), gl.Float(scale.forward.y), gl.Float(scale.forward.z))
  gl.uniform1f(renderer.location_ribbon_depth_near, gl.Float(scale.depth_near))
  gl.uniform1f(renderer.location_ribbon_tangent, gl.Float(scale.tangent_half_view))
  gl.uniform1f(renderer.location_ribbon_height, gl.Float(scale.height_pixels))
  # Set furniture fog's two radii, for fragment stage's fade.
  #   One schedule per frame, from same rule placement cuts chords with.
  let fog = fogFurnitureFor(scale.extent_furniture)
  gl.uniform1f(renderer.location_ribbon_fog_full, gl.Float(fog.radius_full))
  gl.uniform1f(renderer.location_ribbon_fog_gone, gl.Float(fog.radius_gone))
  renderer.uploadRibbons(meshes)

  gl.useProgram(renderer.program)
  gl.uniformMatrix4fv(
    renderer.location_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.uniform1f(renderer.location_size_point, SIZE_POINT)
  renderer.uploadPoints(meshes)

  # Give both wash programs this frame's matrix before run walk.
  #   Walk switches between them per run.
  gl.useProgram(renderer.program_disc)
  gl.uniformMatrix4fv(
    renderer.location_disc_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.useProgram(renderer.program_dome)
  gl.uniformMatrix4fv(
    renderer.location_dome_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  # Give ring program ribbon program's whole camera.
  #   Rim is widened in screen space by very rule line is.
  gl.useProgram(renderer.program_ring)
  gl.uniformMatrix4fv(
    renderer.location_ring_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.uniform3f(renderer.location_ring_eye,
    gl.Float(scale.eye.x), gl.Float(scale.eye.y), gl.Float(scale.eye.z))
  gl.uniform3f(renderer.location_ring_forward,
    gl.Float(scale.forward.x), gl.Float(scale.forward.y), gl.Float(scale.forward.z))
  gl.uniform1f(renderer.location_ring_depth_near, gl.Float(scale.depth_near))
  gl.uniform1f(renderer.location_ring_tangent, gl.Float(scale.tangent_half_view))
  gl.uniform1f(renderer.location_ring_height, gl.Float(scale.height_pixels))
  renderer.uploadWashes(meshes)

  # Draw opaque kinds first, so they own depth buffer.
  gl.useProgram(renderer.program_ribbon)
  renderer.drawRibbonRun(meshes, is_overlay = false)
  gl.useProgram(renderer.program_ring)
  renderer.drawRingRun(meshes, is_overlay = false)
  gl.useProgram(renderer.program)
  renderer.drawPointRun(meshes, is_overlay = false)

  # Draw washes without writing depth, so objects stay visible through them.
  gl.depthMask(gl.FALSE)
  renderer.drawWashRuns(meshes, is_overlay = false)
  gl.depthMask(gl.TRUE)

  # Draw overlay over all of it, with no depth test.
  #   Turns writes off with it, so same kind order decides what is over what among
  #   selected objects.
  if meshes.hasOverlay:
    gl.disable(gl.DEPTH_TEST)
    gl.useProgram(renderer.program_ribbon)
    renderer.drawRibbonRun(meshes, is_overlay = true)
    gl.useProgram(renderer.program_ring)
    renderer.drawRingRun(meshes, is_overlay = true)
    gl.useProgram(renderer.program)
    renderer.drawPointRun(meshes, is_overlay = true)
    renderer.drawWashRuns(meshes, is_overlay = true)
    gl.enable(gl.DEPTH_TEST)
  gl.bindVertexArray(0)



#[ Frame Capture ]#

proc capturePixels*(width, height: int; pixels: var openArray[uint8]) =
  ## Read framebuffer back as tightly packed RGB triples, first row nearest bottom.
  ##   Caller owns fixed storage, sized to largest export this build allows.
  ##   Window resized past that bound fails loudly rather than silently reallocating.
  let count = width*height*3
  doAssert len(pixels) >= count,
    &"Readback buffer holds {len(pixels)} bytes, short of {count}."
  gl.pixelStorei(gl.PACK_ALIGNMENT, 1)
  gl.readPixels(
    0, 0, gl.Sizei(width), gl.Sizei(height), gl.RGB, gl.UNSIGNED_BYTE, addr pixels[0]
  )
