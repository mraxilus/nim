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

import std/strformat

import ./[camera, mesh]
import ./opengl as gl



#[ Renderer Configuration ]#

const
  SIZE_POINT* = 9.0'f32
    ## Set diameter of drawn points, in pixels.
  WIDTH_LINE_FURNITURE* = 1.5'f32
    ## Set width of the ground grid and world axes, in pixels -- kept thinner than a
    ## scene line object's own width (`WIDTH_LINE_OBJECT`), so reference furniture
    ## recedes behind whatever the workbench is actually showing.
  WIDTH_LINE_OBJECT* = 2.5'f32
    ## Set width of a scene line object, in pixels -- wider than furniture, so its own
    ## highlighted outline can widen by the same border thickness a point's own outline
    ## does (`BORDER_OUTLINE`), rather than needing a disproportionately wide outline
    ## relative to a thin line to show a comparable border.
  BORDER_OUTLINE* = 2.5'f32
    ## Set the highlight outline's own border thickness, in pixels, shared by a point
    ## and a line alike -- subtle enough to read as a border, not overwhelm the object
    ## itself. A plane's own border is a world-space addition instead
    ## (`mesh.EXTENT_OUTLINE_BORDER`), tuned to roughly match this at the camera
    ## distance the workbench's own storyboard is captured from.
  SIZE_POINT_OUTLINE* = SIZE_POINT + 2.0'f32*BORDER_OUTLINE
    ## Diameter the highlighted object's own point draws at, in its outline pass --
    ## `BORDER_OUTLINE` wider on every side than `SIZE_POINT`, so the difference shows
    ## as a border of that thickness once the normal-size point redraws over it.
  WIDTH_LINE_OUTLINE* = WIDTH_LINE_OBJECT + 2.0'f32*BORDER_OUTLINE
    ## Width the highlighted object's own line draws at, in its outline pass --
    ## `BORDER_OUTLINE` wider on each side than `WIDTH_LINE_OBJECT`, matching the
    ## point's own border thickness exactly.
  LOG_MAX = 1024
    ## Bound how much of driver's compile log is reported.

static:
  doAssert WIDTH_LINE_OBJECT > WIDTH_LINE_FURNITURE,
    &"Object line width must exceed furniture's; got `{WIDTH_LINE_OBJECT}` <= " &
    &"`{WIDTH_LINE_FURNITURE}`."
  doAssert BORDER_OUTLINE > 0, &"Outline border must be positive; got `{BORDER_OUTLINE}`."


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


proc drawOutline*(renderer: Renderer; meshes: MeshSet; view_projection: Matrix4) =
  ## Draw the currently highlighted object's own geometry oversized and in a flat
  ## outline colour (already baked into `meshes`' own vertex colours by the caller) --
  ## the same "selection outline" technique 3D modelling software uses: an enlarged
  ## silhouette, so only the sliver of it sticking out past the object's own true-size
  ## edge stays visible once the object itself draws back over it.
  ##   Caller must draw this between world furniture (`drawMeshes` on the ground grid
  ##   and world axes alone) and the scene's own objects (`drawMeshes` again, on
  ##   everything else): drawn any earlier, furniture painted afterward would cover the
  ##   border wherever a grid line or axis happens to cross it: furniture has no
  ##   business occluding a selection outline. Drawn any later, it would instead cover
  ##   the object's own true-size redraw, hiding the object rather than framing it.
  ##   A point's and a line's own geometry is unchanged from the ordinary pass; drawing
  ##   them here at a wider point size / line width is what pushes their own silhouette
  ##   out past their normal-sized redraw. A plane's own geometry is genuinely built
  ##   larger by the caller (`mesh.addObject`'s `outline` flag), since its size is not
  ##   a draw-time uniform the way a point or line's is.
  ##   Depth test and write both off: this draws between two ordinary passes that both
  ##   depth-test normally, and leaving depth on here would let this pass block the
  ##   second of them from redrawing over this same position, at some fractionally
  ##   different depth an equality-based test cannot be trusted to resolve consistently.
  gl.useProgram(renderer.program)
  gl.uniformMatrix4fv(
    renderer.location_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.disable(gl.DEPTH_TEST)
  gl.uniform1f(renderer.location_size_point, SIZE_POINT_OUTLINE)
  gl.lineWidth(WIDTH_LINE_OUTLINE)
  renderer.drawPrimitive(meshes, Primitive.Line)
  renderer.drawPrimitive(meshes, Primitive.Point)
  renderer.drawPrimitive(meshes, Primitive.Triangle)
  gl.enable(gl.DEPTH_TEST)
  gl.bindVertexArray(0)


proc drawMeshes*(
  renderer: Renderer; meshes: MeshSet; view_projection: Matrix4;
  width_line: float32 = WIDTH_LINE_OBJECT
) =
  ## Draw every mesh, opaque kinds before translucent ones.
  ##   `width_line` defaults to a scene object's own width; caller passes
  ##   `WIDTH_LINE_FURNITURE` instead when drawing the ground grid and world axes alone,
  ##   so furniture reads thinner than whatever object the workbench is actually
  ##   showing (see `WIDTH_LINE_FURNITURE`'s own doc comment).
  gl.useProgram(renderer.program)
  gl.uniformMatrix4fv(
    renderer.location_view_projection, 1, gl.FALSE, view_projection.elementsAddress
  )
  gl.uniform1f(renderer.location_size_point, SIZE_POINT)
  gl.lineWidth(width_line)

  # Draw opaque kinds first, so they own depth buffer.
  renderer.drawPrimitive(meshes, Primitive.Line)
  renderer.drawPrimitive(meshes, Primitive.Point)

  # Draw washes without writing depth, so objects stay visible through them.
  gl.depthMask(gl.FALSE)
  renderer.drawPrimitive(meshes, Primitive.Triangle)
  gl.depthMask(1)
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
