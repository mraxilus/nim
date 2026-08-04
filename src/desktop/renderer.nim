## Draw the scene and the panel through GL, from fixed storage.
##
## Two programs and two vertex formats: the scene's position-and-colour triples, and the
## overlay's position, texture coordinate and colour, which draws the panel, its text and the
## selection rings alike. The overlay batches into one buffer and flushes once, so a panel of
## several hundred rectangles and glyphs costs one draw call.
##
## Draw order mirrors the browser's glue, which mirrors this, and the two must be kept in step
## by hand: furniture at furniture width with normal depth, then scene lines and points, then
## translucent triangles with depth writes off.

{.experimental: "strictFuncs".}

import std/[math, tables, unicode]

import ../core/[algebra, camera, config, mesh, palette, transform]
import ./[font, platform]



#[ Type Definitions ]#

const OVERLAY_CAPACITY* = 65536
  ## Cap overlay vertices per frame; the panel's own worst case is far below it.

type
  OverlayVertex = object
    ## Carry one overlay vertex: position in pixels, texture coordinate, colour.
    x, y, u, v, r, g, b, a: float32

  Renderer* = object
    ## Hold every GL object the tool draws with.
    scene_program, overlay_program: GLuint
    scene_buffer, overlay_buffer: GLuint
    atlas_texture: GLuint
    scene_mvp, scene_point_size, scene_is_point: GLint
    scene_position, scene_color: GLint
    overlay_viewport, overlay_sampler, overlay_uses_texture: GLint
    overlay_position, overlay_texcoord, overlay_color: GLint
    overlay: array[OVERLAY_CAPACITY, OverlayVertex]
    overlay_count: int
    scene_vertices: array[VERTEX_CAPACITY, array[7, float32]]
    width*, height*: int
    atlas*: Atlas



#[ Shaders ]#

const
  SCENE_VERTEX_SHADER = """
#version 120
attribute vec3 a_position;
attribute vec4 a_color;
uniform mat4 u_mvp;
uniform float u_pointSize;
varying vec4 v_color;
void main() {
  gl_Position = u_mvp * vec4(a_position, 1.0);
  gl_PointSize = u_pointSize;
  v_color = a_color;
}
"""
  SCENE_FRAGMENT_SHADER = """
#version 120
uniform float u_isPoint;
varying vec4 v_color;
void main() {
  // A point is round: the platform draws a square sprite, so the corners are cut. The cut is
  // gated on drawing points, because `gl_PointCoord` is undefined for any other primitive —
  // a driver that reads it as zero discards every line and triangle in the scene.
  if (u_isPoint > 0.5) {
    vec2 offset = gl_PointCoord - vec2(0.5);
    if (dot(offset, offset) > 0.25) discard;
  }
  gl_FragColor = v_color;
}
"""
  OVERLAY_VERTEX_SHADER = """
#version 120
attribute vec2 a_position;
attribute vec2 a_texcoord;
attribute vec4 a_color;
uniform vec2 u_viewport;
varying vec2 v_texcoord;
varying vec4 v_color;
void main() {
  vec2 ndc = vec2(a_position.x / u_viewport.x * 2.0 - 1.0,
                  1.0 - a_position.y / u_viewport.y * 2.0);
  gl_Position = vec4(ndc, 0.0, 1.0);
  v_texcoord = a_texcoord;
  v_color = a_color;
}
"""
  OVERLAY_FRAGMENT_SHADER = """
#version 120
uniform sampler2D u_atlas;
uniform float u_usesTexture;
varying vec2 v_texcoord;
varying vec4 v_color;
void main() {
  float coverage = mix(1.0, texture2D(u_atlas, v_texcoord).r, u_usesTexture);
  gl_FragColor = vec4(v_color.rgb, v_color.a * coverage);
}
"""


proc compileShader(kind: GLenum, source: string): GLuint =
  ## Compile one shader, failing loudly rather than drawing nothing.
  result = glCreateShader(kind)
  var text = source.cstring
  glShaderSource(result, 1, addr text, nil)
  glCompileShader(result)
  var status: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, addr status)
  if status == 0:
    var log = newString(1024)
    glGetShaderInfoLog(result, 1024, nil, log.cstring)
    raise newException(CatchableError, "shader failed to compile: " & log)


proc linkProgram(vertex_source, fragment_source: string): GLuint =
  ## Link one program from its two shaders.
  result = glCreateProgram()
  glAttachShader(result, compileShader(GL_VERTEX_SHADER, vertex_source))
  glAttachShader(result, compileShader(GL_FRAGMENT_SHADER, fragment_source))
  glLinkProgram(result)
  var status: GLint
  glGetProgramiv(result, GL_LINK_STATUS, addr status)
  if status == 0:
    var log = newString(1024)
    glGetProgramInfoLog(result, 1024, nil, log.cstring)
    raise newException(CatchableError, "program failed to link: " & log)



#[ Renderer Construction ]#

proc initRenderer*(renderer: var Renderer, atlas: Atlas) =
  ## Build every GL object the tool draws with, once.
  var vertex_array: GLuint
  glGenVertexArrays(1, addr vertex_array)
  glBindVertexArray(vertex_array)

  renderer.atlas = atlas
  renderer.scene_program = linkProgram(SCENE_VERTEX_SHADER, SCENE_FRAGMENT_SHADER)
  renderer.overlay_program = linkProgram(OVERLAY_VERTEX_SHADER, OVERLAY_FRAGMENT_SHADER)
  renderer.scene_mvp = glGetUniformLocation(renderer.scene_program, "u_mvp")
  renderer.scene_point_size = glGetUniformLocation(renderer.scene_program, "u_pointSize")
  renderer.scene_is_point = glGetUniformLocation(renderer.scene_program, "u_isPoint")
  renderer.scene_position = glGetAttribLocation(renderer.scene_program, "a_position")
  renderer.scene_color = glGetAttribLocation(renderer.scene_program, "a_color")
  renderer.overlay_viewport = glGetUniformLocation(renderer.overlay_program, "u_viewport")
  renderer.overlay_sampler = glGetUniformLocation(renderer.overlay_program, "u_atlas")
  renderer.overlay_uses_texture =
    glGetUniformLocation(renderer.overlay_program, "u_usesTexture")
  renderer.overlay_position = glGetAttribLocation(renderer.overlay_program, "a_position")
  renderer.overlay_texcoord = glGetAttribLocation(renderer.overlay_program, "a_texcoord")
  renderer.overlay_color = glGetAttribLocation(renderer.overlay_program, "a_color")

  glGenBuffers(1, addr renderer.scene_buffer)
  glGenBuffers(1, addr renderer.overlay_buffer)

  glGenTextures(1, addr renderer.atlas_texture)
  glBindTexture(GL_TEXTURE_2D, renderer.atlas_texture)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_R8, ATLAS_SIZE.GLsizei, ATLAS_SIZE.GLsizei, 0,
    GL_RED, GL_UNSIGNED_BYTE, addr renderer.atlas.pixels[0],
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)



#[ Frame ]#

proc beginFrame*(renderer: var Renderer, width, height: int) =
  ## Start a frame: size the viewport and clear to the backdrop.
  renderer.width = width
  renderer.height = height
  renderer.overlay_count = 0
  let backdrop = Paint.Backdrop.color
  glViewport(0, 0, width.GLsizei, height.GLsizei)
  glClearColor(backdrop.r.GLfloat, backdrop.g.GLfloat, backdrop.b.GLfloat, 1.0)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  glEnable(GL_VERTEX_PROGRAM_POINT_SIZE)


proc uploadScene(
  renderer: var Renderer, vertices: openArray[Vertex], count: int
) =
  ## Copy one bucket into the scene buffer, interleaved.
  for index in 0 ..< count:
    let vertex = vertices[index]
    renderer.scene_vertices[index] = [
      vertex.position.x.float32, vertex.position.y.float32, vertex.position.z.float32,
      vertex.color.r.float32, vertex.color.g.float32, vertex.color.b.float32,
      vertex.color.a.float32,
    ]
  glBindBuffer(GL_ARRAY_BUFFER, renderer.scene_buffer)
  glBufferData(
    GL_ARRAY_BUFFER, count*7*sizeof(float32), addr renderer.scene_vertices[0],
    GL_DYNAMIC_DRAW,
  )
  glEnableVertexAttribArray(renderer.scene_position.GLuint)
  glVertexAttribPointer(
    renderer.scene_position.GLuint, 3, GL_KIND_FLOAT, GL_FALSE, 7*sizeof(float32).GLsizei, nil
  )
  glEnableVertexAttribArray(renderer.scene_color.GLuint)
  glVertexAttribPointer(
    renderer.scene_color.GLuint, 4, GL_KIND_FLOAT, GL_FALSE, 7*sizeof(float32).GLsizei,
    cast[pointer](3*sizeof(float32)),
  )


proc drawScene*(renderer: var Renderer, target: Mesh, view: Camera) =
  ## Draw one frame's scene, in the order the blend depends on.
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glUseProgram(renderer.scene_program)
  var matrix = view.viewProjection(renderer.width.float/renderer.height.float).toFloat32
  glUniformMatrix4fv(renderer.scene_mvp, 1, GL_FALSE, addr matrix[0])
  glUniform1f(renderer.scene_point_size, POINT_SIZE_PX.GLfloat)

  glUniform1f(renderer.scene_is_point, 0.0)
  glLineWidth(LINE_WIDTH_FURNITURE.GLfloat)
  renderer.uploadScene(target.furniture, target.furniture_count)
  glDrawArrays(GL_LINES, 0, target.furniture_count.GLsizei)

  glLineWidth(LINE_WIDTH_OBJECT.GLfloat)
  renderer.uploadScene(target.lines, target.line_count)
  glDrawArrays(GL_LINES, 0, target.line_count.GLsizei)

  glUniform1f(renderer.scene_is_point, 1.0)
  renderer.uploadScene(target.points, target.point_count)
  glDrawArrays(GL_POINTS, 0, target.point_count.GLsizei)
  glUniform1f(renderer.scene_is_point, 0.0)

  glDepthMask(GL_FALSE)
  renderer.uploadScene(target.triangles, target.triangle_count)
  glDrawArrays(GL_TRIANGLES, 0, target.triangle_count.GLsizei)
  glDepthMask(GL_TRUE)



#[ Overlay ]#

proc push(
  renderer: var Renderer, x, y, u, v: float, color: Color
) {.inline.} =
  ## Append one overlay vertex.
  if renderer.overlay_count >= OVERLAY_CAPACITY: return
  renderer.overlay[renderer.overlay_count] = OverlayVertex(
    x: x.float32, y: y.float32, u: u.float32, v: v.float32,
    r: color.r.float32, g: color.g.float32, b: color.b.float32, a: color.a.float32,
  )
  renderer.overlay_count += 1


proc quad*(
  renderer: var Renderer, x, y, width, height: float, color: Color,
  u0 = -1.0, v0 = -1.0, u1 = -1.0, v1 = -1.0,
) =
  ## Append one overlay rectangle, textured where a caller gives coordinates.
  ##   A caller that gives none samples the atlas's solid block, so an untextured surface
  ##   draws at full coverage in the same batch as the text.
  let
    u0 = if u0 < 0: renderer.atlas.solid_u else: u0
    v0 = if v0 < 0: renderer.atlas.solid_v else: v0
    u1 = if u1 < 0: renderer.atlas.solid_u else: u1
    v1 = if v1 < 0: renderer.atlas.solid_v else: v1
  renderer.push(x, y, u0, v0, color)
  renderer.push(x + width, y, u1, v0, color)
  renderer.push(x + width, y + height, u1, v1, color)
  renderer.push(x, y, u0, v0, color)
  renderer.push(x + width, y + height, u1, v1, color)
  renderer.push(x, y + height, u0, v1, color)


proc strokeRect*(
  renderer: var Renderer, x, y, width, height, thickness: float, color: Color
) =
  ## Append one overlay rectangle outline.
  renderer.quad(x, y, width, thickness, color)
  renderer.quad(x, y + height - thickness, width, thickness, color)
  renderer.quad(x, y, thickness, height, color)
  renderer.quad(x + width - thickness, y, thickness, height, color)


proc text*(
  renderer: var Renderer, x, y: float, value: string, color: Color,
  family = Family.Text,
): float =
  ## Append one run of text in a family, and report where it ended.
  ##   Advances by each glyph's own width, which is why the catalogue's accents are spacing
  ##   modifier letters: a combining mark carries no advance and would land beside its operand.
  var pen = x
  for rune in value.runes:
    let codepoint = int(rune)
    if not renderer.atlas.glyphs[family].hasKey(codepoint): continue
    let glyph = renderer.atlas.glyphs[family][codepoint]
    if glyph.width > 0 and glyph.height > 0:
      renderer.quad(
        pen + glyph.bearing_x, y + renderer.atlas.ascent + glyph.bearing_y,
        glyph.width, glyph.height, color, glyph.u0, glyph.v0, glyph.u1, glyph.v1,
      )
    pen += glyph.advance
  pen


proc segment*(
  renderer: var Renderer, x0, y0, x1, y1, thickness: float, color: Color
) =
  ## Append one thick line in screen space, for a plot or a rule.
  let
    dx = x1 - x0
    dy = y1 - y0
    length = max(sqrt(dx*dx + dy*dy), 1.0e-6)
    nx = -dy/length*thickness*0.5
    ny = dx/length*thickness*0.5
    (u, v) = (renderer.atlas.solid_u, renderer.atlas.solid_v)
  renderer.push(x0 + nx, y0 + ny, u, v, color)
  renderer.push(x1 + nx, y1 + ny, u, v, color)
  renderer.push(x1 - nx, y1 - ny, u, v, color)
  renderer.push(x0 + nx, y0 + ny, u, v, color)
  renderer.push(x1 - nx, y1 - ny, u, v, color)
  renderer.push(x0 - nx, y0 - ny, u, v, color)


proc ring*(renderer: var Renderer, x, y, radius, thickness: float, color: Color) =
  ## Append one billboarded ring, in screen space.
  const SEGMENTS = 32
  for step in 0 ..< SEGMENTS:
    let
      angle_a = TAU*step.float/SEGMENTS.float
      angle_b = TAU*(step + 1).float/SEGMENTS.float
      ax = x + cos(angle_a)*radius
      ay = y + sin(angle_a)*radius
      bx = x + cos(angle_b)*radius
      by = y + sin(angle_b)*radius
      dx = bx - ax
      dy = by - ay
      length = max(sqrt(dx*dx + dy*dy), 1.0e-6)
      nx = -dy/length*thickness*0.5
      ny = dx/length*thickness*0.5
    let (u, v) = (renderer.atlas.solid_u, renderer.atlas.solid_v)
    renderer.push(ax + nx, ay + ny, u, v, color)
    renderer.push(bx + nx, by + ny, u, v, color)
    renderer.push(bx - nx, by - ny, u, v, color)
    renderer.push(ax + nx, ay + ny, u, v, color)
    renderer.push(bx - nx, by - ny, u, v, color)
    renderer.push(ax - nx, ay - ny, u, v, color)


proc flushOverlay*(renderer: var Renderer, uses_texture: bool) =
  ## Draw everything appended to the overlay, in one call, and empty it.
  if renderer.overlay_count == 0: return
  glDisable(GL_DEPTH_TEST)
  glUseProgram(renderer.overlay_program)
  glUniform2f(
    renderer.overlay_viewport, renderer.width.GLfloat, renderer.height.GLfloat
  )
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, renderer.atlas_texture)
  glUniform1i(renderer.overlay_sampler, 0)
  glUniform1f(renderer.overlay_uses_texture, if uses_texture: 1.0 else: 0.0)
  glBindBuffer(GL_ARRAY_BUFFER, renderer.overlay_buffer)
  glBufferData(
    GL_ARRAY_BUFFER, renderer.overlay_count*sizeof(OverlayVertex),
    addr renderer.overlay[0], GL_DYNAMIC_DRAW,
  )
  let stride = sizeof(OverlayVertex).GLsizei
  glEnableVertexAttribArray(renderer.overlay_position.GLuint)
  glVertexAttribPointer(renderer.overlay_position.GLuint, 2, GL_KIND_FLOAT, GL_FALSE, stride, nil)
  glEnableVertexAttribArray(renderer.overlay_texcoord.GLuint)
  glVertexAttribPointer(
    renderer.overlay_texcoord.GLuint, 2, GL_KIND_FLOAT, GL_FALSE, stride,
    cast[pointer](2*sizeof(float32)),
  )
  glEnableVertexAttribArray(renderer.overlay_color.GLuint)
  glVertexAttribPointer(
    renderer.overlay_color.GLuint, 4, GL_KIND_FLOAT, GL_FALSE, stride,
    cast[pointer](4*sizeof(float32)),
  )
  glDrawArrays(GL_TRIANGLES, 0, renderer.overlay_count.GLsizei)
  renderer.overlay_count = 0
  glEnable(GL_DEPTH_TEST)


proc drawRings*(renderer: var Renderer, target: Mesh, view: Camera) =
  ## Draw one ring per selected slot, and one for the hover, in screen space.
  let matrix = view.viewProjection(renderer.width.float/renderer.height.float)
  for index in 0 ..< target.ring_count:
    let entry = target.rings[index]
    let clip = matrix.project(entry.anchor)
    if clip.w <= 1.0e-6: continue
    let
      x = (clip.x/clip.w*0.5 + 0.5)*renderer.width.float
      y = (1.0 - (clip.y/clip.w*0.5 + 0.5))*renderer.height.float
    renderer.ring(
      x, y, entry.radius_px, RING_WIDTH_PX,
      Paint.Outline.color.withAlpha(entry.alpha),
    )
  renderer.flushOverlay(uses_texture = true)
