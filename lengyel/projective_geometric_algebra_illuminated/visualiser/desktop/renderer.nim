## Own OpenGL resources, and draw meshes through them.
##
## One program per record kind, and a plain one for points: each record type in `mesh`
## has a vertex shader here that widens it over static corner geometry (see each
## `SOURCE_VERTEX_*`'s own doc comment and the reference proc it names), so the CPU
## hands over compact records and no per-frame expansion.
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
""" ## Widen one ribbon record into the corner this invocation is, on the GPU.
  ##   **A sibling copy of `mesh.expandRibbon`, the reference the suite pins to the
  ## algebra, and of the WebGL source in `glue.js` -- a change to any one of the three is
  ## not finished until the other two are checked.** Line for line: reject a segment
  ## wholly behind the near plane (six coincident clipped corners), clip an end that
  ## crosses it and blend its tint by the same fraction, derive the across as the cross
  ## the join reduces to, and step this corner off by half a width of its own end's
  ## world-per-pixel. `in_corner` is (end, side): which end of the segment, and which
  ## side of it, this invocation stands for. `in_fog` and the world position pass
  ## through untouched for the fragment stage's fog; see `SOURCE_FRAGMENT_RIBBON`.


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
""" ## Shade one ribbon fragment, fading a fogged record by its own distance from the eye.
  ##   **A sibling copy of `mesh.alphaGridFade`, the reference the fog is held to, and of
  ## the WebGL source in `glue.js` -- a change to any one of the three is not finished
  ## until the other two are checked.** Per fragment rather than per vertex, so the fade
  ## is exact along a record of any length -- which is what lets a lattice line be one
  ## record instead of a chain of fade pieces. A record with `fog` zero passes through
  ## untouched, which is every scene ribbon.


const CORNERS_RIBBON: array[12, float32] = [
  0.0'f32, -1.0, 1.0, -1.0, 1.0, 1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0,
] ## The six (end, side) corners of one ribbon instance, in `expandRibbon`'s own winding.


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
""" ## Fan one disc record over the static corner buffer, on the GPU.
  ##   **A sibling copy of `mesh.expandDiscVertex`, the reference the suite pins, and of
  ## the WebGL source in `glue.js` -- a change to any one of the three is not finished
  ## until the other two are checked.** Each corner is the centre plus the two
  ## radius-scaled arms weighted by its own cosine and sine, with `(0, 0)` landing the
  ## centre corner on the centre exactly.


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
""" ## Widen one dome record over the static unit sphere, on the GPU.
  ##   **A sibling copy of `mesh.expandDomeVertex`**, under the same three-way rule as
  ## the disc source above: the centre plus the unit direction scaled by the radius.


const
  COUNT_CORNERS_DISC = 3*SEGMENTS_CIRCLE_HORIZON
    ## How many corners the disc fan's static buffer holds; `mesh.discCorners` emits
    ## exactly this many `(cos, sin)` pairs.
  COUNT_CORNERS_DOME = 6*LATITUDES_HORIZON*LONGITUDES_HORIZON
    ## How many corners the dome's static buffer holds; `mesh.domeCorners` emits exactly
    ## this many unit directions.



#[ Type Definitions ]#

type
  Renderer* = object ## Hold every OpenGL name visualiser allocates.
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
  ## Build every program, the point vertex buffer, and each record kind's instanced
  ## vertex array with its static corner geometry.
  ##   OpenGL context must already be current, as every call below needs it.
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
  # Six fixed corners every instance shares, and one record per instance beside them.
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
  # (attribute, floats, float offset) for each of the record's six views.
  for (index, floats, offset) in [
    (gl.Uint(1), gl.Int(3), 0), (gl.Uint(2), gl.Int(3), 3), (gl.Uint(3), gl.Int(1), 6),
    (gl.Uint(4), gl.Int(1), 7), (gl.Uint(5), gl.Int(4), 8), (gl.Uint(6), gl.Int(4), 12),
  ]:
    gl.enableVertexAttribArray(index)
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_RECORD,
      cast[pointer](offset*sizeof(float32)))
    gl.vertexAttribDivisor(index, 1)
  gl.bindVertexArray(0)

  # The two wash programs, each with its static corner geometry from mesh.nim's own
  #   generators -- the same one source `glue.js` uploads through `nimDiscCorners` --
  #   and one record buffer of divisor-one instance attributes beside it.
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
  # (attribute, floats, float offset) for each of the record's four views.
  for (index, floats, offset) in [
    (gl.Uint(1), gl.Int(3), 0), (gl.Uint(2), gl.Int(3), 3), (gl.Uint(3), gl.Int(3), 6),
    (gl.Uint(4), gl.Int(4), 9),
  ]:
    gl.enableVertexAttribArray(index)
    gl.vertexAttribPointer(index, floats, gl.FLOAT_TYPE, gl.FALSE, STRIDE_DISC,
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
  # (attribute, floats, float offset) for the record's two views.
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


proc uploadPoints(renderer: Renderer; meshes: MeshSet) =
  ## Hand the point vertices to the driver whole, ready to be drawn as one run or two.
  ##   Separate from drawing because the two runs are issued in different *passes* rather
  ##   than back to back -- see `drawMeshes` -- and a mesh uploaded twice a frame would be
  ##   the one real cost of that split.
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
  ## Hand this frame's ribbon records to the driver whole; the shader does the rest.
  if meshes.ribbons.count == 0: return
  gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffer_ribbon_records)
  gl.bufferData(
    gl.ARRAY_BUFFER,
    gl.Sizeiptr(meshes.ribbons.count*sizeof(RibbonRecord)),
    unsafeAddr meshes.ribbons.records[0],
    gl.DYNAMIC_DRAW,
  )


proc uploadWashes(renderer: Renderer; meshes: MeshSet) =
  ## Hand this frame's disc and dome records to the driver whole; the shaders fan them.
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
  ## Say which stretch of the ribbon records belongs to which pass; `runOf`'s own rule.
  let split =
    if ribbons.index_overlay.isSome: clamp(ribbons.index_overlay.get, 0, ribbons.count)
    else: ribbons.count
  if is_overlay: (first: split, count: ribbons.count - split)
  else: (first: 0, count: split)


proc drawRibbonRun(renderer: Renderer; meshes: MeshSet; is_overlay: bool) =
  ## Draw one run of the already-uploaded ribbon records as instanced triangle pairs.
  ##   GL 3.3 has no base instance, so a run that does not start at the first record
  ##   re-points the five instance attributes at its own first byte instead -- the same
  ##   pointers `initRenderer` set, offset by the run's start.
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


func runOf(mesh: Mesh; is_overlay: bool): tuple[first, count: int] =
  ## Say which stretch of one mesh belongs to the depth-tested run or to the overlay run.
  ##   Empty where the mesh has no such run, which is the ordinary case for the overlay:
  ##   nothing is selected on most frames. See `mesh.Mesh.index_overlay`.
  let split =
    if mesh.index_overlay.isSome: clamp(mesh.index_overlay.get, 0, mesh.count_vertices)
    else: mesh.count_vertices
  if is_overlay: (first: split, count: mesh.count_vertices - split)
  else: (first: 0, count: split)


proc drawPointRun(renderer: Renderer; meshes: MeshSet; is_overlay: bool) =
  ## Draw one run of the already-uploaded point mesh, skipping an empty one.
  let run = runOf(meshes.points, is_overlay)
  if run.count == 0: return
  # Tell fragment stage it is shading point sprites, which are rounded off.
  gl.uniform1f(renderer.location_as_point, 1.0)
  gl.bindVertexArray(renderer.array_points)
  gl.drawArrays(gl.POINTS, gl.Int(run.first), gl.Sizei(run.count))


func runsOfWashes(washes: WashRuns; is_overlay: bool): tuple[begin, until: int] =
  ## Say which stretch of the wash runs belongs to which pass -- `runOf`'s rule, at run
  ## grain: runs before the overlay index are the depth-tested pass, the rest land over
  ## it. A run never straddles the mark; see `mesh.WashRuns`.
  let split =
    if washes.index_overlay.isSome: clamp(washes.index_overlay.get, 0, washes.count)
    else: washes.count
  if is_overlay: (begin: split, until: washes.count)
  else: (begin: 0, until: split)


proc drawWashRuns(renderer: Renderer; meshes: MeshSet; is_overlay: bool) =
  ## Walk one pass's stretch of the wash draw order, drawing each run through its own
  ## kind's program so two washes still blend in the order the scene emitted them.
  ##   GL 3.3 has no base instance, so a run that does not start at the first record
  ##   re-points its instance attributes at its own first byte, exactly as
  ##   `drawRibbonRun` does. Mirrors `glue.js`'s own `drawWashRuns`.
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
  ## Report whether anything in this set asked to be drawn over the rest of it.
  if runOfRibbons(meshes.ribbons, is_overlay = true).count > 0: return true
  if runOf(meshes.points, is_overlay = true).count > 0: return true
  let (begin, until) = runsOfWashes(meshes.washes, is_overlay = true)
  until > begin


proc drawMeshes*(
  renderer: Renderer; meshes: MeshSet; view_projection: Matrix4; scale: DrawScale
) =
  ## Draw every mesh, opaque kinds before translucent ones, then the overlay over both.
  ##   Takes the frame's own `DrawScale` because the ribbon program needs the camera: the
  ##   widening, the near clip and the screen-constant width all run in its vertex shader
  ##   now, fed by exactly the fields `mesh.expandRibbon` reads.
  ##   **The overlay is a second pass over every kind, not a tail on each one.** A tail was
  ##   tried and measured: a selected line came out over the other lines and still tinted
  ##   by a plane's wash, because the wash is a later kind and the overlay run, having no
  ##   depth test, writes no depth for that wash to be rejected against. A wash over the
  ##   object you just picked is exactly the complaint this answers, so the whole ordinary
  ##   set goes down before any of the overlay goes on top.
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
  # The furniture fog's two radii, for the fragment stage's fade of fogged records; one
  #   schedule per frame, from the same rule the placement cuts the chords with.
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

  # Both wash programs get this frame's matrix before the run walk, which switches
  #   between them per run.
  gl.useProgram(renderer.program_disc)
  gl.uniformMatrix4fv(
    renderer.location_disc_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.useProgram(renderer.program_dome)
  gl.uniformMatrix4fv(
    renderer.location_dome_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  renderer.uploadWashes(meshes)

  # Draw opaque kinds first, so they own depth buffer.
  gl.useProgram(renderer.program_ribbon)
  renderer.drawRibbonRun(meshes, is_overlay = false)
  gl.useProgram(renderer.program)
  renderer.drawPointRun(meshes, is_overlay = false)

  # Draw washes without writing depth, so objects stay visible through them.
  gl.depthMask(gl.FALSE)
  renderer.drawWashRuns(meshes, is_overlay = false)
  gl.depthMask(gl.TRUE)

  # And the overlay over all of it, with no depth test at all -- which turns writes off
  #   with it, so nothing here occludes anything either, and the same kind order decides
  #   what is over what among the selected objects themselves.
  if meshes.hasOverlay:
    gl.disable(gl.DEPTH_TEST)
    gl.useProgram(renderer.program_ribbon)
    renderer.drawRibbonRun(meshes, is_overlay = true)
    gl.useProgram(renderer.program)
    renderer.drawPointRun(meshes, is_overlay = true)
    renderer.drawWashRuns(meshes, is_overlay = true)
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
