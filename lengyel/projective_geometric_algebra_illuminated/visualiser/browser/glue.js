"use strict";

/* ---------------------------------------------------------------------- */
/* Everything above this script is `pga`, `objects`, `mesh`, `camera`,    */
/* `scene`, `picking`, `interaction` and `storyboard`, compiled to JS by  */
/* `nim js` from `visualiser/browser_bridge.nim`: every join, meet, pick, */
/* drag and camera move below runs that compiled code, never JS rewrite.  */
/* This script is presentation only: WebGL, DOM and pointer input, role   */
/* OpenGL/SDL/Dear ImGui play over desktop app's identical geometry. See  */
/* `browser_bridge.nim` doc for what deliberately does NOT carry over.    */
/* ---------------------------------------------------------------------- */

const canvas = document.getElementById('gl');
// No `preserveDrawingBuffer`, deliberately: it makes every frame keep copy of drawing.
//   buffer for whole session, on phone, so that button pressed once can read it
//   afterwards. `captureFrameIfAsked` reads buffer from inside frame that drew it
//   instead, which costs nothing and is what image export uses.
const gl = canvas.getContext('webgl', { antialias: true, alpha: false })
  || canvas.getContext('experimental-webgl', { antialias: true, alpha: false });

// Fan one point record into camera-facing quad at its own radius.
//   Sibling copy of `mesh.radiusDrawnAt` and of GLSL 3.30 source in `renderer.nim`;
//   change to any one is not finished until other two are checked.
//   Quad spans camera's screen axes at centre's depth, so disc shrinks with distance
//   exactly as perspective says and floors at `uDiameterLeast` pixels. Behind near plane
//   it collapses to clip-space point outside frustum.
const SOURCE_VERTEX_POINT = `
  attribute vec2 aCorner;
  attribute vec3 aCentre;
  attribute float aRadius;
  attribute vec3 aLight;
  attribute vec4 aColor;
  uniform mat4 uMVP;
  uniform vec3 uEye;
  uniform vec3 uForward;
  uniform vec3 uRight;
  uniform vec3 uUp;
  uniform float uDepthNear;
  uniform float uTangentHalfView;
  uniform float uHeightPixels;
  uniform float uDiameterLeast;
  varying vec4 vColor;
  varying vec2 vCorner;
  varying float vRadiusPixels;
  varying vec3 vLight;
  void main() {
    float depth = dot(aCentre - uEye, uForward);
    if (depth < uDepthNear) {
      gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
      vColor = vec4(0.0);
      vCorner = vec2(0.0);
      vRadiusPixels = 0.0;
      vLight = vec3(0.0);
      return;
    }
    float world_per_pixel = 2.0*depth*uTangentHalfView/uHeightPixels;
    float radius = max(aRadius, 0.5*uDiameterLeast*world_per_pixel);
    vec3 at = aCentre + aCorner.x*radius*uRight + aCorner.y*radius*uUp;
    gl_Position = uMVP*vec4(at, 1.0);
    vColor = aColor;
    vCorner = aCorner;
    vRadiusPixels = radius/world_per_pixel;
    vLight = vec3(dot(aLight, uRight), dot(aLight, uUp), -dot(aLight, uForward));
  }
`;
// Round point's quad into disc, fading its last pixel of rim, shaded as sphere.
//   Corner pair is unit-circle coordinate, so edge is where its length passes one, and
//   sphere's normal is that pair with height lifted off it. Lit where record carries
//   light, in camera's basis from vertex stage: Lambert toward it over `uAmbient` floor;
//   flat otherwise. Sibling of GLSL 3.30 source in `renderer.nim`.
const SOURCE_FRAGMENT_POINT = `
  precision mediump float;
  varying vec4 vColor;
  varying vec2 vCorner;
  varying float vRadiusPixels;
  varying vec3 vLight;
  uniform float uAmbient;
  void main() {
    float reach = length(vCorner);
    if (reach > 1.0) discard;
    float edge = clamp((1.0 - reach)*vRadiusPixels, 0.0, 1.0);
    float shade = 1.0;
    if (dot(vLight, vLight) > 0.5) {
      vec3 normal = vec3(vCorner, sqrt(max(0.0, 1.0 - reach*reach)));
      shade = uAmbient + (1.0 - uAmbient)*max(0.0, dot(normal, vLight));
    }
    gl_FragColor = vec4(vColor.rgb*shade, vColor.a*edge);
  }
`;
// Plain colour pass-through, every wash program's fragment stage.
const SOURCE_FRAGMENT = `
  precision mediump float;
  varying vec4 vColor;
  void main() {
    gl_FragColor = vColor;
  }
`;

function compileShader(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}
const program = gl.createProgram();
gl.attachShader(program, compileShader(gl.VERTEX_SHADER, SOURCE_VERTEX_POINT));
gl.attachShader(program, compileShader(gl.FRAGMENT_SHADER, SOURCE_FRAGMENT_POINT));
gl.linkProgram(program);
if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
  throw new Error(gl.getProgramInfoLog(program));
}
gl.useProgram(program);

const point_attribs = {
  corner: gl.getAttribLocation(program, 'aCorner'),
  centre: gl.getAttribLocation(program, 'aCentre'),
  radius: gl.getAttribLocation(program, 'aRadius'),
  light: gl.getAttribLocation(program, 'aLight'),
  colour: gl.getAttribLocation(program, 'aColor'),
};
const point_uniforms = {
  mvp: gl.getUniformLocation(program, 'uMVP'),
  eye: gl.getUniformLocation(program, 'uEye'),
  forward: gl.getUniformLocation(program, 'uForward'),
  right: gl.getUniformLocation(program, 'uRight'),
  up: gl.getUniformLocation(program, 'uUp'),
  depth_near: gl.getUniformLocation(program, 'uDepthNear'),
  tangent: gl.getUniformLocation(program, 'uTangentHalfView'),
  height: gl.getUniformLocation(program, 'uHeightPixels'),
  diameter_least: gl.getUniformLocation(program, 'uDiameterLeast'),
  ambient: gl.getUniformLocation(program, 'uAmbient'),
};

// Read from renderer.nim's own constants via nimRenderLineWidths.
//   Never hand-copied literal that could drift out of sync with them.
//   Least point diameter is uniform here, floor point vertex shader holds far disc at.
//   Two line widths are not: each ribbon record carries its width and ribbon vertex
//   shader widens it, because WebGL clamps `gl.lineWidth` to one pixel on most
//   implementations.
const [DIAMETER_POINT_LEAST] = nimRenderLineWidths();
// Night side of lit point, as fraction of its colour; `mesh.FRACTION_AMBIENT_SHADE`.
const AMBIENT_SHADE = nimShadeAmbient();

// Widen one 16-float ribbon record into corner this invocation is.
//   Sibling copy of `mesh.expandRibbon`, reference suite pins to algebra, and of GLSL
//   3.30 source in `renderer.nim`; change to any one of three is not finished until
//   other two are checked.
//   Clip to near plane, blend clipped end's tint by same fraction, derive across as
//   cross join reduces to, and step off by half width of this end's own
//   world-per-pixel.
const SOURCE_VERTEX_RIBBON = `
  attribute vec2 aCorner;
  attribute vec3 aTail;
  attribute vec3 aHead;
  attribute float aWidth;
  attribute float aFog;
  attribute vec4 aTintTail;
  attribute vec4 aTintHead;
  uniform mat4 uMVP;
  uniform vec3 uEye;
  uniform vec3 uForward;
  uniform float uDepthNear;
  uniform float uTangentHalfView;
  uniform float uHeightPixels;
  varying vec4 vColor;
  varying vec3 vWorld;
  varying float vFog;
  void main() {
    vFog = aFog;
    float depth_tail = dot(aTail - uEye, uForward);
    float depth_head = dot(aHead - uEye, uForward);
    vec3 across_raw = cross(aHead - aTail, uEye - aTail);
    float across_length = length(across_raw);
    if (max(depth_tail, depth_head) < uDepthNear || across_length < 1e-12) {
      gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
      vColor = vec4(0.0);
      vWorld = aTail;
      return;
    }
    vec3 near_end = aTail;
    vec3 far_end = aHead;
    vec4 tint_near = aTintTail;
    vec4 tint_far = aTintHead;
    if (depth_tail < uDepthNear) {
      float fraction = (uDepthNear - depth_tail)/(depth_head - depth_tail);
      near_end = aTail + fraction*(aHead - aTail);
      tint_near = mix(aTintTail, aTintHead, fraction);
    } else if (depth_head < uDepthNear) {
      float fraction = (uDepthNear - depth_head)/(depth_tail - depth_head);
      far_end = aHead + fraction*(aTail - aHead);
      tint_far = mix(aTintHead, aTintTail, fraction);
    }
    vec3 across = across_raw/across_length;
    vec3 at = mix(near_end, far_end, aCorner.x);
    float depth_at = max(dot(at - uEye, uForward), uDepthNear);
    float world_per_pixel = 2.0*depth_at*uTangentHalfView/uHeightPixels;
    at += aCorner.y*0.5*aWidth*world_per_pixel*across;
    gl_Position = uMVP*vec4(at, 1.0);
    vWorld = at;
    vColor = mix(tint_near, tint_far, aCorner.x);
  }
`;
// Fade fogged record by its distance from eye, per fragment.
//   Sibling copy of `mesh.alphaGridFade`, reference fog is held to, and of GLSL 3.30
//   fragment source in `renderer.nim`; change to any one of three is not finished
//   until other two are checked.
//   Per fragment rather than per vertex, so fade is exact along record of any length,
//   which is what lets lattice line be one record instead of chain of fade pieces.
//   Record with fog zero passes through untouched, which is every scene ribbon.
const SOURCE_FRAGMENT_RIBBON = `
  precision mediump float;
  varying vec4 vColor;
  varying highp vec3 vWorld;
  varying highp float vFog;
  uniform highp vec3 uEye;
  uniform highp float uFogFull;
  uniform highp float uFogGone;
  void main() {
    highp float fade = 1.0 - clamp(
      (distance(vWorld, uEye) - uFogFull)/(uFogGone - uFogFull), 0.0, 1.0
    );
    gl_FragColor = vec4(vColor.rgb, vColor.a*mix(1.0, fade, clamp(vFog, 0.0, 1.0)));
  }
`;
const program_ribbon = gl.createProgram();
gl.attachShader(program_ribbon, compileShader(gl.VERTEX_SHADER, SOURCE_VERTEX_RIBBON));
gl.attachShader(program_ribbon, compileShader(gl.FRAGMENT_SHADER, SOURCE_FRAGMENT_RIBBON));
gl.linkProgram(program_ribbon);
if (!gl.getProgramParameter(program_ribbon, gl.LINK_STATUS)) {
  throw new Error(gl.getProgramInfoLog(program_ribbon));
}
// Require instancing, extension on WebGL1 and universally shipped.
//   Context without it gets same loud failure context without WebGL gets, not silent
//   picture with no lines.
const instanced = gl.getExtension('ANGLE_instanced_arrays');
if (instanced === null) throw new Error('ANGLE_instanced_arrays is unavailable');
const ribbon_attribs = {
  corner: gl.getAttribLocation(program_ribbon, 'aCorner'),
  tail: gl.getAttribLocation(program_ribbon, 'aTail'),
  head: gl.getAttribLocation(program_ribbon, 'aHead'),
  width: gl.getAttribLocation(program_ribbon, 'aWidth'),
  fog: gl.getAttribLocation(program_ribbon, 'aFog'),
  tint_tail: gl.getAttribLocation(program_ribbon, 'aTintTail'),
  tint_head: gl.getAttribLocation(program_ribbon, 'aTintHead'),
};
const ribbon_uniforms = {
  mvp: gl.getUniformLocation(program_ribbon, 'uMVP'),
  eye: gl.getUniformLocation(program_ribbon, 'uEye'),
  forward: gl.getUniformLocation(program_ribbon, 'uForward'),
  depth_near: gl.getUniformLocation(program_ribbon, 'uDepthNear'),
  tangent: gl.getUniformLocation(program_ribbon, 'uTangentHalfView'),
  height: gl.getUniformLocation(program_ribbon, 'uHeightPixels'),
  fog_full: gl.getUniformLocation(program_ribbon, 'uFogFull'),
  fog_gone: gl.getUniformLocation(program_ribbon, 'uFogGone'),
};
// Six (end, side) corners of one ribbon instance, in `expandRibbon`'s own winding.
const buffer_ribbon_corners = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, buffer_ribbon_corners);
gl.bufferData(gl.ARRAY_BUFFER,
  new Float32Array([0, -1, 1, -1, 1, 1, 0, -1, 1, 1, 0, 1]), gl.STATIC_DRAW);

// Fan one 13-float disc record over static corner buffer.
//   Sibling copy of `mesh.expandDiscVertex`, reference suite pins, and of GLSL 3.30
//   source in `renderer.nim`; change to any one of three is not finished until other
//   two are checked.
//   Each corner is centre plus two radius-scaled arms weighted by its own cosine and
//   sine, with `(0, 0)` landing centre corner on centre exactly.
const SOURCE_VERTEX_DISC = `
  attribute vec2 aCorner;
  attribute vec3 aCentre;
  attribute vec3 aArmFirst;
  attribute vec3 aArmSecond;
  attribute vec4 aFill;
  uniform mat4 uMVP;
  varying vec4 vColor;
  void main() {
    vec3 at = aCentre + aCorner.x*aArmFirst + aCorner.y*aArmSecond;
    gl_Position = uMVP*vec4(at, 1.0);
    vColor = aFill;
  }
`;
// Sibling copy of `mesh.expandDomeVertex`, under same three-way rule:
//   each corner is centre plus its own unit direction scaled by radius.
const SOURCE_VERTEX_DOME = `
  attribute vec3 aUnit;
  attribute vec4 aCentreRadius;
  attribute vec4 aTint;
  uniform mat4 uMVP;
  varying vec4 vColor;
  void main() {
    vec3 at = aCentreRadius.xyz + aCentreRadius.w*aUnit;
    gl_Position = uMVP*vec4(at, 1.0);
    vColor = aTint;
  }
`;
// Widen one 14-float ring record into plane's whole rim.
//   Sibling copy of `mesh.expandRingVertex`, reference suite pins, and of GLSL 3.30
//   source in `renderer.nim`; change to any one of three is not finished until other
//   two are checked.
//   Static corner buffer carries every segment of closed walk, so this one instance
//   draws all `SEGMENTS_CIRCLE_HORIZON` of them.
//   Two steps, and second is not new.
//     Place segment's ends on circle exactly as disc source places its fan corners,
//     `centre + cos*arm_first + sin*arm_second`, then widen that pair by ribbon
//     source's own body, verbatim: near clip, across join reduces to, and half width
//     of this end's world-per-pixel.
//     Rim is line, and there is one rule for how wide line is drawn.
//   Tint is flat, so ribbon's blend between two ends collapses to `aFill`, and fog is
//   always zero, so this shares plain fragment stage rather than ribbon's fading one.
const SOURCE_VERTEX_RING = `
  attribute vec4 aArc;
  attribute vec2 aCorner;
  attribute vec3 aCentre;
  attribute vec3 aArmFirst;
  attribute vec3 aArmSecond;
  attribute vec4 aFill;
  attribute float aWidth;
  uniform mat4 uMVP;
  uniform vec3 uEye;
  uniform vec3 uForward;
  uniform float uDepthNear;
  uniform float uTangentHalfView;
  uniform float uHeightPixels;
  varying vec4 vColor;
  void main() {
    vec3 tail = aCentre + aArc.x*aArmFirst + aArc.y*aArmSecond;
    vec3 head = aCentre + aArc.z*aArmFirst + aArc.w*aArmSecond;
    float depth_tail = dot(tail - uEye, uForward);
    float depth_head = dot(head - uEye, uForward);
    vec3 across_raw = cross(head - tail, uEye - tail);
    float across_length = length(across_raw);
    if (max(depth_tail, depth_head) < uDepthNear || across_length < 1e-12) {
      gl_Position = vec4(0.0, 0.0, 2.0, 1.0);
      vColor = vec4(0.0);
      return;
    }
    vec3 near_end = tail;
    vec3 far_end = head;
    if (depth_tail < uDepthNear) {
      float fraction = (uDepthNear - depth_tail)/(depth_head - depth_tail);
      near_end = tail + fraction*(head - tail);
    } else if (depth_head < uDepthNear) {
      float fraction = (uDepthNear - depth_head)/(depth_tail - depth_head);
      far_end = head + fraction*(tail - head);
    }
    vec3 across = across_raw/across_length;
    vec3 at = mix(near_end, far_end, aCorner.x);
    float depth_at = max(dot(at - uEye, uForward), uDepthNear);
    float world_per_pixel = 2.0*depth_at*uTangentHalfView/uHeightPixels;
    at += aCorner.y*0.5*aWidth*world_per_pixel*across;
    gl_Position = uMVP*vec4(at, 1.0);
    vColor = aFill;
  }
`;
function linkWashProgram(source_vertex) {
  const handle = gl.createProgram();
  gl.attachShader(handle, compileShader(gl.VERTEX_SHADER, source_vertex));
  gl.attachShader(handle, compileShader(gl.FRAGMENT_SHADER, SOURCE_FRAGMENT));
  gl.linkProgram(handle);
  if (!gl.getProgramParameter(handle, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(handle));
  }
  return handle;
}
const program_disc = linkWashProgram(SOURCE_VERTEX_DISC);
const program_dome = linkWashProgram(SOURCE_VERTEX_DOME);
const disc_attribs = {
  corner: gl.getAttribLocation(program_disc, 'aCorner'),
  centre: gl.getAttribLocation(program_disc, 'aCentre'),
  arm_first: gl.getAttribLocation(program_disc, 'aArmFirst'),
  arm_second: gl.getAttribLocation(program_disc, 'aArmSecond'),
  fill: gl.getAttribLocation(program_disc, 'aFill'),
};
const dome_attribs = {
  unit: gl.getAttribLocation(program_dome, 'aUnit'),
  centre_radius: gl.getAttribLocation(program_dome, 'aCentreRadius'),
  tint: gl.getAttribLocation(program_dome, 'aTint'),
};
const program_ring = linkWashProgram(SOURCE_VERTEX_RING);
const ring_attribs = {
  arc: gl.getAttribLocation(program_ring, 'aArc'),
  corner: gl.getAttribLocation(program_ring, 'aCorner'),
  centre: gl.getAttribLocation(program_ring, 'aCentre'),
  arm_first: gl.getAttribLocation(program_ring, 'aArmFirst'),
  arm_second: gl.getAttribLocation(program_ring, 'aArmSecond'),
  fill: gl.getAttribLocation(program_ring, 'aFill'),
  width: gl.getAttribLocation(program_ring, 'aWidth'),
};
// Very six ribbon program takes, since widening is ribbon's own.
const ring_uniforms = {
  mvp: gl.getUniformLocation(program_ring, 'uMVP'),
  eye: gl.getUniformLocation(program_ring, 'uEye'),
  forward: gl.getUniformLocation(program_ring, 'uForward'),
  depth_near: gl.getUniformLocation(program_ring, 'uDepthNear'),
  tangent: gl.getUniformLocation(program_ring, 'uTangentHalfView'),
  height: gl.getUniformLocation(program_ring, 'uHeightPixels'),
};
const uniform_disc_mvp = gl.getUniformLocation(program_disc, 'uMVP');
const uniform_dome_mvp = gl.getUniformLocation(program_dome, 'uMVP');
// Hold static corner geometry both wash shaders fan records over.
//   Read from mesh.nim's own generators rather than hand-copied table that could drift
//   from references.
const CORNERS_DISC = new Float32Array(nimDiscCorners());
const CORNERS_DOME = new Float32Array(nimDomeCorners());
const COUNT_CORNERS_DISC = CORNERS_DISC.length / 2;
const COUNT_CORNERS_DOME = CORNERS_DOME.length / 3;
const buffer_disc_corners = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, buffer_disc_corners);
gl.bufferData(gl.ARRAY_BUFFER, CORNERS_DISC, gl.STATIC_DRAW);
const buffer_dome_corners = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, buffer_dome_corners);
gl.bufferData(gl.ARRAY_BUFFER, CORNERS_DOME, gl.STATIC_DRAW);
// Every segment of rim, six corners each, so one ring record draws whole circle.
const CORNERS_RING = new Float32Array(nimRingCorners());
const COUNT_CORNERS_RING = CORNERS_RING.length / 6;
const buffer_ring_corners = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, buffer_ring_corners);
gl.bufferData(gl.ARRAY_BUFFER, CORNERS_RING, gl.STATIC_DRAW);
// Two triangles of unit square, one disc per point record.
const CORNERS_POINT = new Float32Array(nimPointCorners());
const COUNT_CORNERS_POINT = CORNERS_POINT.length / 2;
const buffer_point_corners = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, buffer_point_corners);
gl.bufferData(gl.ARRAY_BUFFER, CORNERS_POINT, gl.STATIC_DRAW);

const vbo = {
  disc: gl.createBuffer(), dome: gl.createBuffer(), ring: gl.createBuffer(),
  ribbon: gl.createBuffer(), point: gl.createBuffer(),
  ribbon_furniture: gl.createBuffer(),
};
const STRIDE_POINT = 11 * 4;
const STRIDE_RIBBON = 16 * 4;
const STRIDE_DISC = 13 * 4;
const STRIDE_DOME = 8 * 4;
const STRIDE_RING = 14 * 4;

// Count furniture vertices its own buffer holds, carried between frames.
//   Bridge stops sending them once camera is still; see `renderFrame`.
let count_furniture_held = null;
// And same for scene's own buffers, carried for same reason one layer out:
//   frame bridge reports as held has uploaded nothing, so what stands in each buffer is last
//   frame's -- correct, since bridge only says held when it would have written very same bytes.
//   See `FrameData.is_scene_held`.
let count_ribbon_held = null;
let count_ring_held = null;
let count_point_held = null;

// One mesh handed to driver whole, ready to be drawn as one run or two.
//   Separate from drawing because two runs go out in different passes (see draw loop below), and
//   mesh uploaded twice frame would be one real cost of that split.
//   Bridge fills `Float32Array`s page owns and hands back views on them, so there is
//   nothing to convert here and nothing to stage: driver reads very memory
//   flatten wrote. Staging array used to sit here, refilled element by element from
//   boxed `Array` `seq[float32]` is on JS backend -- see `browser_bridge.FlatBuffer`
//   for what that cost and why it is gone. Anything else reaching this is mistake worth
//   hearing about rather than silently copying around.
function uploadBuffer(data, handle_buffer, floats_each) {
  if (!(data instanceof Float32Array)) {
    throw new Error('uploadBuffer wants a Float32Array from the bridge, not ' + typeof data);
  }
  if (data.length === 0) return null;
  gl.bindBuffer(gl.ARRAY_BUFFER, handle_buffer);
  gl.bufferData(gl.ARRAY_BUFFER, data, gl.DYNAMIC_DRAW);
  return data.length / floats_each;
}

// One run of uploaded record buffer, drawn as instanced triangle pairs.
//   `count_over` is how many records at END are overlay run, exactly as `drawPoints`'s split;
//   run that does not start at first record re-points five instance attributes at its own first
//   byte, since WebGL1 has no base instance.
//   Mirrors `renderer.drawRibbonRun`.
function drawRibbons(handle_buffer, count, count_over, is_overlay) {
  if (!count) return;
  const split = Math.max(0, count - Math.min(count_over || 0, count));
  const first = is_overlay ? split : 0;
  const span = is_overlay ? count - split : split;
  if (span === 0) return;
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer_ribbon_corners);
  gl.enableVertexAttribArray(ribbon_attribs.corner);
  gl.vertexAttribPointer(ribbon_attribs.corner, 2, gl.FLOAT, false, 8, 0);
  instanced.vertexAttribDivisorANGLE(ribbon_attribs.corner, 0);
  gl.bindBuffer(gl.ARRAY_BUFFER, handle_buffer);
  const base = first * STRIDE_RIBBON;
  for (const [attrib, floats, offset] of [
    [ribbon_attribs.tail, 3, 0], [ribbon_attribs.head, 3, 12], [ribbon_attribs.width, 1, 24],
    [ribbon_attribs.fog, 1, 28],
    [ribbon_attribs.tint_tail, 4, 32], [ribbon_attribs.tint_head, 4, 48],
  ]) {
    gl.enableVertexAttribArray(attrib);
    gl.vertexAttribPointer(attrib, floats, gl.FLOAT, false, STRIDE_RIBBON, base + offset);
    instanced.vertexAttribDivisorANGLE(attrib, 1);
  }
  instanced.drawArraysInstancedANGLE(gl.TRIANGLES, 0, 6, span);
  // Divisors are context state, not program state: left at one they would corrupt.
  //   plain program's reads of these same attribute indices next draw.
  for (const attrib of [ribbon_attribs.tail, ribbon_attribs.head, ribbon_attribs.width,
    ribbon_attribs.fog, ribbon_attribs.tint_tail, ribbon_attribs.tint_head]) {
    instanced.vertexAttribDivisorANGLE(attrib, 0);
    gl.disableVertexAttribArray(attrib);
  }
}

// One run of uploaded ring buffer, drawn as instanced rims:
//   each instance is whole plane's circle, `COUNT_CORNERS_RING` corners of it.
//   Splits its two runs exactly as `drawRibbons` does, and re-points five instance attributes at
//   run's own first byte for same reason -- WebGL1 has no base instance.
//   Mirrors `renderer.drawRingRun`.
function drawRings(count, count_over, is_overlay) {
  if (!count) return;
  const split = Math.max(0, count - Math.min(count_over || 0, count));
  const first = is_overlay ? split : 0;
  const span = is_overlay ? count - split : split;
  if (span === 0) return;
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer_ring_corners);
  for (const [attrib, floats, offset] of [
    [ring_attribs.arc, 4, 0], [ring_attribs.corner, 2, 16],
  ]) {
    gl.enableVertexAttribArray(attrib);
    gl.vertexAttribPointer(attrib, floats, gl.FLOAT, false, 24, offset);
    instanced.vertexAttribDivisorANGLE(attrib, 0);
  }
  gl.bindBuffer(gl.ARRAY_BUFFER, vbo.ring);
  const base = first * STRIDE_RING;
  const records = [
    [ring_attribs.centre, 3, 0], [ring_attribs.arm_first, 3, 12],
    [ring_attribs.arm_second, 3, 24], [ring_attribs.fill, 4, 36],
    [ring_attribs.width, 1, 52],
  ];
  for (const [attrib, floats, offset] of records) {
    gl.enableVertexAttribArray(attrib);
    gl.vertexAttribPointer(attrib, floats, gl.FLOAT, false, STRIDE_RING, base + offset);
    instanced.vertexAttribDivisorANGLE(attrib, 1);
  }
  instanced.drawArraysInstancedANGLE(gl.TRIANGLES, 0, COUNT_CORNERS_RING, span);
  // Divisors are context state, not program state: left at one they would corrupt.
  //   plain program's reads of these same attribute indices next draw.
  for (const [attrib] of records) {
    instanced.vertexAttribDivisorANGLE(attrib, 0);
    gl.disableVertexAttribArray(attrib);
  }
  for (const [attrib] of [[ring_attribs.arc], [ring_attribs.corner]]) {
    gl.disableVertexAttribArray(attrib);
  }
}

// One instanced wash draw:
//   `record_attribs` re-pointed at run's first record (WebGL1 has no base instance), corner attrib
//   from static buffer, divisors reset after -- they are context state, and left at one they would
//   corrupt plain program's reads of same attribute indices.
//   Shared by disc and dome runs below.
function drawWashInstances(
  buffer_corners, floats_corner, count_corners, corner_attrib,
  handle_records, stride, record_attribs, first, count
) {
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer_corners);
  gl.enableVertexAttribArray(corner_attrib);
  gl.vertexAttribPointer(corner_attrib, floats_corner, gl.FLOAT, false,
    floats_corner * 4, 0);
  instanced.vertexAttribDivisorANGLE(corner_attrib, 0);
  gl.bindBuffer(gl.ARRAY_BUFFER, handle_records);
  const base = first * stride;
  for (const [attrib, floats, offset] of record_attribs) {
    gl.enableVertexAttribArray(attrib);
    gl.vertexAttribPointer(attrib, floats, gl.FLOAT, false, stride, base + offset);
    instanced.vertexAttribDivisorANGLE(attrib, 1);
  }
  instanced.drawArraysInstancedANGLE(gl.TRIANGLES, 0, count_corners, count);
  for (const [attrib] of record_attribs) {
    instanced.vertexAttribDivisorANGLE(attrib, 0);
    gl.disableVertexAttribArray(attrib);
  }
}

// Walk one pass's stretch of wash draw order, drawing each run through its kind's program.
//   `wash_runs` is [kind, first, count] per run, `count_runs_over` how many runs at end
//   are overlay stretch.
//   Two washes then still blend in order scene emitted them; mirrors
//   `renderer.drawWashRuns`.
function drawWashRuns(wash_runs, count_runs_over, is_overlay) {
  const count_runs = wash_runs.length / 3;
  const split = count_runs - Math.min(count_runs_over || 0, count_runs);
  const begin = is_overlay ? split : 0;
  const end = is_overlay ? count_runs : split;
  for (let i = begin; i < end; i += 1) {
    const kind = wash_runs[3 * i], first = wash_runs[3 * i + 1];
    const count = wash_runs[3 * i + 2];
    if (kind === 0) {
      gl.useProgram(program_disc);
      drawWashInstances(buffer_disc_corners, 2, COUNT_CORNERS_DISC, disc_attribs.corner,
        vbo.disc, STRIDE_DISC, [
          [disc_attribs.centre, 3, 0], [disc_attribs.arm_first, 3, 12],
          [disc_attribs.arm_second, 3, 24], [disc_attribs.fill, 4, 36],
        ], first, count);
    } else {
      gl.useProgram(program_dome);
      drawWashInstances(buffer_dome_corners, 3, COUNT_CORNERS_DOME, dome_attribs.unit,
        vbo.dome, STRIDE_DOME, [
          [dome_attribs.centre_radius, 4, 0], [dome_attribs.tint, 4, 16],
        ], first, count);
    }
  }
}

// One run of uploaded point records, drawn as instanced camera-facing discs.
//   `count_over` is how many records at END are overlay run; `is_overlay` picks which of
//   two runs to draw. Re-points three instance attributes at run's own first byte, since
//   WebGL1 has no base instance, and resets divisors after, as `drawRings` does.
//   Mirrors `renderer.drawPointRun`.
function drawPoints(count, count_over, is_overlay) {
  if (!count) return;
  const split = Math.max(0, count - Math.min(count_over || 0, count));
  const first = is_overlay ? split : 0;
  const span = is_overlay ? count - split : split;
  if (span === 0) return;
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer_point_corners);
  gl.enableVertexAttribArray(point_attribs.corner);
  gl.vertexAttribPointer(point_attribs.corner, 2, gl.FLOAT, false, 8, 0);
  instanced.vertexAttribDivisorANGLE(point_attribs.corner, 0);
  gl.bindBuffer(gl.ARRAY_BUFFER, vbo.point);
  const base = first * STRIDE_POINT;
  const records = [
    [point_attribs.centre, 3, 0], [point_attribs.radius, 1, 12], [point_attribs.light, 3, 16],
    [point_attribs.colour, 4, 28],
  ];
  for (const [attrib, floats, offset] of records) {
    gl.enableVertexAttribArray(attrib);
    gl.vertexAttribPointer(attrib, floats, gl.FLOAT, false, STRIDE_POINT, base + offset);
    instanced.vertexAttribDivisorANGLE(attrib, 1);
  }
  instanced.drawArraysInstancedANGLE(gl.TRIANGLE_STRIP, 0, COUNT_CORNERS_POINT, span);
  for (const [attrib] of records) {
    instanced.vertexAttribDivisorANGLE(attrib, 0);
    gl.disableVertexAttribArray(attrib);
  }
  gl.disableVertexAttribArray(point_attribs.corner);
}

function rgbToCss(rgb) {
  const byteOf = (c) => Math.round(Math.min(1, Math.max(0, c)) * 255).toString(16).padStart(2, '0');
  return '#' + rgb.map(byteOf).join('');
}

gl.enable(gl.DEPTH_TEST);
gl.enable(gl.BLEND);
gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
const backdrop = nimBackdropColor();
gl.clearColor(backdrop[0], backdrop[1], backdrop[2], 1.0);
document.documentElement.style.setProperty('--bg', rgbToCss(backdrop));

/* ---------------------------------------------------------------------- */
/* Scene setup. Every construction, visibility and camera state lives in  */
/* compiled Nim module; this file only tracks what DOM needs to           */
/* reflect and drive it.                                                  */
/* ---------------------------------------------------------------------- */

nimInit(performance.now() / 1000);
let is_axes_shown = true, is_grid_shown = true;
// Debug layer, off by default: it draws every multivector frame computed, with.
//   plane drawn as infinite lattice it actually is rather than as disc that stands
//   for one. Reader switches it on to see algebra rather than illustration of it.
let is_algebra_shown = false;

function now() { return performance.now() / 1000; }

/* ---------------------------------------------------------------------- */
/* Selection: ordered multi-select, shared by touch long-press/tap and     */
/* mouse click/shift-click -- see pointer-input section below for          */
/* full gesture design. Nim's own `selection.nim` holds it, through        */
/* `nimSelect*` exports: pick order is what names operation's operands     */
/* m and n, and that rule belongs beside every other rule about            */
/* selection rather than in second implementation over here. Every         */
/* construction path already writes selection itself, so there is no       */
/* two-way sync to keep -- only read.                                      */
/*                                                                          */
/* `slots_selection` below is render snapshot of that answer, not copy      */
/* with rules of its own: frame loop's overlay reads it dozens of           */
/* times second and must not cross JS/Nim boundary to do it.                */
/* ---------------------------------------------------------------------- */

let slots_selection = []; // Ordered: first-picked first (-> operand m), second (-> n).

function refreshSelectionSnapshot() {
  slots_selection = nimSelectionSlots();
}

function onSelectionChanged(position_local) {
  refreshSelectionSnapshot();
  refreshSelectionMenu(position_local);
  refreshObjectsUI(); // Also re-syncs apply controls and row checkboxes.
}

function selectOnly(slot, position_local) {
  nimSelectOnly(slot);
  onSelectionChanged(position_local);
}

function toggleSelection(slot, position_local) {
  nimSelectToggle(slot);
  onSelectionChanged(position_local);
}

function clearSelection() {
  nimSelectClear();
  onSelectionChanged(null);
}

// What click on object does, given which button made it and whether shift was held.
//   **Two independent questions**, and keeping them independent is whole design:
//   button says whether selection menu comes up (`nimRevealsMenuOnButton`), shift says
//   whether click adds to selection or replaces it. Left picks silently, right picks
//   and shows menu, and either of them with shift adds or drops instead.
//   **Null position does not mean "no menu"** -- `refreshSelectionMenu(null)` still shows
//   menu, positioned from selection rather than from cursor, which is what
//   keyboard path wants. So non-revealing click hides it afterwards rather than hoping
//   argument covered it. That misreading shipped once here and left button kept popping
//   menu it was supposed to have given up.
//   Both branches live here rather than at two call sites, which used to hold copy
//   each of shift test.
function pickOnClick(slot, button, is_shifted) {
  const reveals = nimRevealsMenuOnButton(button);
  // Selection already standing with its menu dismissed is reader who wants that menu.
  //   back, not one who wants to throw selection away -- so reveal it and pick nothing.
  //   Rule is Nim's, asked rather than restated, since desktop asks same one.
  if (reveals && !is_shifted &&
      nimRevealsWithoutPicking(nimSelectionCount() > 0, isSelectionMenuShown())) {
    refreshSelectionMenu(cursor_last);
    return;
  }
  if (is_shifted) toggleSelection(slot, reveals ? cursor_last : null);
  else selectOnly(slot, reveals ? cursor_last : null);
  if (!reveals) hideSelectionMenu();
}

function adoptConstructionSelection() {
  // Pick up outcome every construction path already decided.
  //   Each picked its own new object (see nimAddItem/nimApplyOperation/nimEndDrag's own
  //   doc comments), or cleared selection (nimLoadDemo/nimUndo/nimRedo on success).
  refreshSelectionSnapshot();
  hideSelectionMenu(); // Construction action never itself opens selection menu --
    // matches today's behaviour (add/apply/drag never popped tap-menu either).
  refreshObjectsUI();
}

/* ---------------------------------------------------------------------- */
/* Toast: outcome of last action, matching desktop panel's own            */
/* one-line status message, shown transiently rather than pinned.         */
/* ---------------------------------------------------------------------- */

const element_toast = document.getElementById('toast');
let timer_toast = null;
function toast(message) {
  // Say nothing for empty message, which is one caller decided not to say.
  //   Drag released over empty space, say; showing empty bar for it is worse than saying
  //   nothing.
  //   Desktop guards its own status line this way; this is that guard, on this side.
  if (!message) return;
  element_toast.textContent = message;
  element_toast.classList.remove('actionable');
  element_toast.classList.add('show');
  clearTimeout(timer_toast);
  timer_toast = setTimeout(() => element_toast.classList.remove('show'), 3200);
}

function toastWithLink(message, url, filename, label, url_image) {
  // Toast reader can act on, held until dismissed. For one case page cannot.
  //   resolve on its own: file is ready and every automatic route to it may have been
  //   refused, silently, by frame this page does not control. Tap *reader* makes on
  //   real anchor is most permitted route there is, so offer that rather than assert
  //   download happened.
  element_toast.textContent = '';
  const line = document.createElement('div');
  line.textContent = message;
  const link = document.createElement('a');
  link.className = 'toast-action';
  link.href = url;
  link.download = filename;
  link.textContent = label;
  link.rel = 'noopener';
  // `url_image` set means file is one reader can save straight off screen, and.
  //   showing it is worth space: drawing blob into `<img>` is not navigation, so
  //   it is only route measured to survive frame sandboxed without `allow-downloads`
  //   -- where press on anchor above is refused in silence, as is every automatic
  //   route. Offered beside link, never instead of it, since where downloads *are*
  //   permitted link is one tap and this is press-and-hold.
  const preview = document.createElement('img');
  const hint = document.createElement('div');
  if (url_image !== undefined) {
    preview.className = 'toast-preview';
    preview.src = url_image;
    preview.alt = filename;
    hint.className = 'toast-hint';
    hint.textContent = 'or press and hold the image to save it';
  }
  // Something to do about it, in words, above evidence. Measured on Android phone in.
  //   Claude app: that frame withholds `allow-downloads`, `allow-popups` and
  //   `web-share` policy all three, so no route from inside it can produce file and no
  //   amount of further work here will change that. Saying so is more use than link that
  //   cannot fire, and same page opened as its own tab downloads normally.
  const advice = document.createElement('div');
  advice.className = 'toast-hint';
  advice.textContent = 'If nothing arrives, this frame is blocking it — '
    + 'open this page in its own browser tab and save from there.';
  // What was tried and what came back, beside thing it was tried on. Every round of.
  //   this fault so far ended with reader who could only report "nothing happened"; this
  //   is what turns next report into diagnosis.
  const detail = document.createElement('div');
  detail.className = 'toast-detail';
  detail.textContent = report_delivery.join(' · ');
  const dismiss = document.createElement('button');
  dismiss.className = 'toast-dismiss';
  dismiss.type = 'button';
  dismiss.textContent = 'dismiss';
  dismiss.addEventListener('click', () => {
    element_toast.classList.remove('show', 'actionable');
  });
  element_toast.append(line, link);
  if (url_image !== undefined) element_toast.append(preview, hint);
  element_toast.append(advice, detail, dismiss);
  element_toast.classList.add('show', 'actionable');
  clearTimeout(timer_toast); // No expiry: see above.
}


/* ---------------------------------------------------------------------- */
/* Handing file to reader.                                                */
/*                                                                        */
/* One route for scene file and image alike. It used to be five           */
/* statements written out twice -- build Blob, make `<a download>`,       */
/* click it -- with anchor never put in document. Detached                */
/* anchor's synthetic click is ignored by Safari outright and is          */
/* unreliable elsewhere, so saving anything from phone did nothing at     */
/* all, while caller toasted "Saved" regardless. Both halves of that      */
/* are fixed here: routes below are tried in order of how likely          */
/* platform is to honour them, and nothing claims file was written.       */
/* ---------------------------------------------------------------------- */

// What last delivery attempt tried and what came back, kept for reader to read.
//   Three rounds of this fault were spent guessing because every refusal was silent:
//   share sheet failed with its reason swallowed, and download frame refuses raises no
//   event at all. Page that cannot say what happened cannot be debugged from phone
//   nobody here can reach, so outcomes are recorded rather than inferred.
let report_delivery = [];

function describeEnvironment() {
  // Read at delivery time, not at load: transient activation is whole question for.
  //   share route and is only meaningful during gesture that asked.
  const share_allowed = document.featurePolicy === undefined ? 'unknown'
    : String(document.featurePolicy.allowsFeature('web-share'));
  return [
    'framed: ' + (window.self !== window.top),
    'origin: ' + (window.origin === 'null' ? 'opaque' : 'own'),
    'share api: ' + (navigator.share === undefined ? 'absent' : 'present'),
    'web-share: ' + share_allowed,
    'activation: ' + (navigator.userActivation === undefined ? 'unknown'
      : String(navigator.userActivation.isActive)),
  ];
}

async function shareFile(file, filename) {
  // `canShare` is preference, never precondition, and this is second time that.
  //   distinction has cost route: gating on it skipped `share` outright, first on any
  //   platform shipping one without other, then -- once that was fixed but `false`
  //   still returned early -- on frame where `canShare` says no for reason that is not
  //   platform's to give. So `false` is *reported* and attempt made anyway; only
  //   missing `share` is grounds not to try.
  if (navigator.share === undefined) {
    report_delivery.push('share: no api');
    return false;
  }
  if (navigator.canShare !== undefined && !navigator.canShare({ files: [file] })) {
    report_delivery.push('share: files no');
  }
  try {
    await navigator.share({ files: [file], title: filename });
    report_delivery.push('share: opened');
    return true;
  } catch (err) {
    // Cancelling sheet is decision, not failure -- report it and stop trying.
    if (err !== undefined && err !== null && err.name === 'AbortError') {
      report_delivery.push('share: cancelled');
      return true;
    }
    report_delivery.push('share: ' + (err === null || err === undefined ? 'failed' : err.name));
    return false;
  }
}

async function deliverFile(blob, filename, mime, described) {
  report_delivery = describeEnvironment();
  const file = new File([blob], filename, { type: mime });

  // 1. Share sheet, where platform has one. Route that actually works on.
  //    phone, and only one that does not care whether this frame may download. Both
  //    callers run inside click, so transient activation it needs is present -- see
  //    `captureFrameIfAsked` on what it cost to make that true of image too.
  if (await shareFile(file, filename)) {
    if (report_delivery[report_delivery.length - 1] === 'share: opened') {
      toast('Shared `' + filename + '`.');
    }
    return;
  }

  const url = URL.createObjectURL(blob);
  // 2. Real anchor, in document.
  //    Appending is whole of original fix; click on element that is not in page is what
  //    browsers were discarding.
  //    Measured in frame granted `allow-downloads`: this fires real download, and so
  //    does reader's own tap on route 4; neither does in frame without it, in silence.
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.style.display = 'none';
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  report_delivery.push('download: no signal');

  // 3. Tab of its own, which frame that refuses download may still permit. Expected to.
  //    fail from sandbox, since `blob:` URL minted in opaque origin resolves nowhere
  //    else -- but `null` return says "blocked" out loud, which is one more thing
  //    reader's report can rule out rather than leave open.
  if (window.self !== window.top) {
    const opened = window.open(url, '_blank');
    report_delivery.push('new tab: ' + (opened === null ? 'blocked' : 'opened'));
  }

  // 4. Link to tap, always. There is no event for "the download was refused" -- framed.
  //    page whose host withholds `allow-downloads` gets silence -- so rather than guess
  //    which happened, leave reader route they drive themselves. Framed is case
  //    that needs it and case this page ships in; unframed it is harmless second way.
  //    Image goes on screen with it, which refused frame cannot take away.
  if (window.self !== window.top) {
    report_delivery.push('link: offered');
    toastWithLink(
      described + ' is ready.', url, filename, 'save ' + filename,
      mime.startsWith('image/') ? url : undefined,
    );
  } else {
    toast('Handed `' + filename + '` to the browser to download.');
    // Long enough for navigation to have started, and for tap on link above.
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    return;
  }
  // Held far longer than old four seconds, since link is reader's to use.
  setTimeout(() => URL.revokeObjectURL(url), 600000);
}

/* ---------------------------------------------------------------------- */
/* Drawer + collapsible sections                                          */
/* ---------------------------------------------------------------------- */

// Every transition in stylesheet runs to these, so browser eases over same.
//   duration and curve appear animation does -- `nimAnimationMilliseconds` is
//   `mesh.ANIMATION_MILLISECONDS`, and bezier is easeOutCubic written for CSS.
document.documentElement.style.setProperty('--anim', nimAnimationMilliseconds() + 'ms');
document.documentElement.style.setProperty('--ease', 'cubic-bezier(0.215, 0.61, 0.355, 1)');

const drawer = document.getElementById('drawer');
const row_chip = document.querySelector('.chip-row');
const button_drawer = document.getElementById('button-drawer');
button_drawer.addEventListener('click', () => {
  const open = drawer.classList.toggle('open');
  button_drawer.classList.toggle('on', open);
  // Everything inside it that skips its work while out of sight catches up now:
  //   rows, operand pickers.
  //   Both are no-ops when their own section is still collapsed.
  refreshObjectsUI();
});

// Top menu: one popover holding every top-bar action (undo/redo, axes/grid, save/load.
//   scene, save PNG/load demo) that used to be spread across four separate chip-row
//   pill-groups -- each button inside keeps its own pre-existing #id-based wiring
//   unchanged below; this only owns popover's own open/close.
const menu_top = document.getElementById('top-menu');
const button_menu = document.getElementById('button-menu');
button_menu.addEventListener('click', () => {
  const open = menu_top.classList.toggle('show');
  button_menu.classList.toggle('on', open);
});

document.querySelectorAll('.section-header').forEach((header) => {
  header.addEventListener('click', () => {
    header.parentElement.classList.toggle('open');
    // Start or end apply section's own preview with section itself.
    //   Preview lives exactly as long as section is on screen, so opening one starts it
    //   and collapsing one ends it.
    //   Asked of every section rather than only that one: check reads section's own
    //   class either way, and handler that knew which section it was would be second
    //   place to keep in step.
    ghostDrawerOperation();
    // Let objects list catch up on whatever it skipped while it was closed.
    //   See `refreshObjectsUI`; same shape, same reason, and asked of every section for
    //   same reason as above, since call is no-op unless it is objects section that
    //   opened.
    refreshObjectsUI();
  });
});
document.getElementById('toggle-axes').addEventListener('click', (e) => {
  is_axes_shown = !is_axes_shown; e.target.classList.toggle('on', is_axes_shown);
});
document.getElementById('toggle-grid').addEventListener('click', (e) => {
  is_grid_shown = !is_grid_shown; e.target.classList.toggle('on', is_grid_shown);
});
document.getElementById('toggle-algebra').addEventListener('click', (e) => {
  is_algebra_shown = !is_algebra_shown;
  e.target.classList.toggle('on', is_algebra_shown);
});
/* ---------------------------------------------------------------------- */
/* Help: ? button says it whenever asked.                                 */
/* ---------------------------------------------------------------------- */

// Pill naming few gestures used to greet every load and leave on reader's first.
//   action. Panel below outgrew it -- it lists every path and every operation, on
//   demand and for as long as reader wants -- and page that explains itself when
//   asked does not need to explain itself unasked. Five gestures that dismissed
//   pill now dismiss nothing, which is why no call replaced them.

// Built from `help.lut_help_entries` across bridge, so this panel and desktop's.
//   own say same thing by construction. Four strings per entry; see nimHelpEntries.
//   One tab per path, because reader opens this in middle of one way of working and
//   only that way's rows are any use to them right then. Tab row belongs to is
//   core's answer -- first of its four strings -- so this builds strip out of
//   paths it actually sees rather than naming them here and drifting from table.
const button_help = document.getElementById('button-help');
const panel_help = document.getElementById('help-panel');
const strip_help = document.getElementById('help-tabs');
const rows_help = document.getElementById('help-rows');
const note_help = document.getElementById('help-description');
const descriptions_help = new Map();
function buildHelp() {
  // What each tab is about, in one sentence, keyed by very title rows are grouped.
  //   by -- so two exports join on string rather than on matching order.
  const described = nimHelpDescriptions();
  for (let i = 0; i + 1 < described.length; i += 2) {
    descriptions_help.set(described[i], described[i + 1]);
  }
  const flat = nimHelpEntries();
  const paths = [];
  for (let i = 0; i + 3 < flat.length; i += 4) {
    const [path, action, outcome, touch] = [flat[i], flat[i + 1], flat[i + 2], flat[i + 3]];
    if (!paths.includes(path)) paths.push(path);
    const row = document.createElement('div');
    row.className = 'help-row';
    row.dataset.path = path;
    const cell_action = document.createElement('div');
    cell_action.className = 'help-action' + (touch ? ' help-touch' : '');
    cell_action.textContent = action;
    const cell_outcome = document.createElement('div');
    cell_outcome.className = 'help-outcome';
    cell_outcome.textContent = outcome;
    row.appendChild(cell_action);
    row.appendChild(cell_outcome);
    rows_help.appendChild(row);
  }
  for (const path of paths) {
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.className = 'help-tab';
    tab.dataset.path = path;
    tab.textContent = path;
    tab.setAttribute('role', 'tab');
    tab.addEventListener('click', () => showHelpPath(path));
    strip_help.appendChild(tab);
  }
  showHelpPath(paths[0]);
}

function showHelpPath(path) {
  // Every row stays in DOM and is hidden by attribute rather than rebuilt per tab:
  //   table never changes at runtime, so rebuilding would be work to no end, and
  //   test can count what each tab holds without switching to it.
  for (const tab of strip_help.children) {
    const is_open = tab.dataset.path === path;
    tab.classList.toggle('on', is_open);
    tab.setAttribute('aria-selected', is_open ? 'true' : 'false');
  }
  for (const row of rows_help.children) {
    row.hidden = row.dataset.path !== path;
  }
  // Swapped with tab rather than one note per tab hidden alongside its rows: there is.
  //   only ever one showing, so one element that changes text cannot go stale.
  note_help.textContent = descriptions_help.get(path) || '';
  rows_help.scrollTop = 0; // Tab always opens at its own first row.
}
buildHelp();

document.getElementById('help-close').addEventListener('click', () => showHelp(false));

function showHelp(is_shown) {
  panel_help.classList.toggle('show', is_shown);
  button_help.setAttribute('aria-expanded', is_shown ? 'true' : 'false');
}
button_help.addEventListener('click', (e) => {
  e.stopPropagation();
  showHelp(!panel_help.classList.contains('show'));
});

/* ---------------------------------------------------------------------- */
/* Undo/redo: scene-content edits only, mirrors panel.layoutPanel's    */
/* own undo/redo buttons exactly -- see `history.nim` for what is and is   */
/* not on this timeline. Step carries view its edit was made from,         */
/* so camera moves under these too; orbit alone is not step.               */
/* ---------------------------------------------------------------------- */

const button_add = document.getElementById('button-add');
const button_undo = document.getElementById('button-undo');
const button_redo = document.getElementById('button-redo');

function openApplyPickerOnOperands(position_local) {
  // Where drag menu's `more…` lands: `nimEndDrag` has already selected both operands.
  //   in order they were dragged, so this only has to open picker that reads that
  //   selection. Refusing to open it would make `more…` dead end, which is exactly what
  //   it exists to stop gesture being.
  //   **Hover menu's picker, not drawer's apply section.** `more…` is fifth
  //   choice on wheel that opened under cursor, and sending it to panel down
  //   side of screen threw hand across viewport and buried two objects it
  //   had just named under list of every other control. Picker lands where wheel
  //   was, already open, already holding last operation of that arity.
  refreshSelectionSnapshot();
  refreshObjectsUI();
  refreshSelectionMenu(position_local);
  if (menu_selection_apply.style.display !== 'none') openSelectionMenuOp();
}

// **Settled scroll, not single jump.** Row outside viewport is placeholder.
//   rather than laid-out row -- see `.item-row`'s `content-visibility` in `shell.html` --
//   so offset of row thousand places down list is estimate until rows
//   above it have actually been measured. One `scrollIntoView` lands on estimate:
//   measured on slot 900 of demo, row arrived 428px lower than it should have,
//   leaving edit form it was opening off bottom of screen. Each pass lays out
//   rows it scrolls past, so estimate is exact where it matters by next one.
//   Stops as soon as row holds still, which on list short enough to be laid out
//   whole is immediately.
const PASSES_SCROLL_SETTLE = 4;
function scrollRowIntoView(row, passes = PASSES_SCROLL_SETTLE) {
  row.scrollIntoView({ block: 'nearest' }); // Long list can open past it.
  if (passes <= 1) return;
  const settled = row.getBoundingClientRect().top;
  requestAnimationFrame(() => {
    if (Math.abs(row.getBoundingClientRect().top - settled) < 1) return;
    scrollRowIntoView(row, passes - 1);
  });
}

function openPanelTo(slot) {
  // Open edit session on `slot` (or composing one where null) and bring drawer.
  //   and Objects section far enough open to see it -- shared by top bar's `add`
  //   and selection menu's `edit`, which differ only in what they open onto.
  beginEditSession(slot);
  document.querySelector('.section[data-section="objects"]').classList.add('open');
  drawer.classList.add('open');
  button_drawer.classList.add('on');
  refreshObjectsUI();
  // Scrolled once its row stands, which is now or slices from now; see `revealPendingRow`.
  //   Asked at once as well, since list already built ends refresh above without slicing.
  //   Querying row here and giving up where it was not yet built left panel open on
  //   top of list with wanted row thousands of pixels down it.
  key_reveal_pending = slot === null ? KEY_ROW_PENDING : String(slot);
  revealPendingRow();
}

button_add.addEventListener('click', () => {
  // Compose new object as row in Objects list rather than in section of its.
  //   own: adding and editing stage same four things through same interface, so
  //   there is one grid and one ghost instead of two of each.
  openPanelTo(null);
});

// One function for buttons and for keys that do same thing. Keys used to.
//   go through `button.click()`, which quietly made them depend on that button's own
//   `disabled` attribute -- refreshed on low-cadence UI tick, so key pressed in
//   frames after edit did nothing at all while timeline plainly had something on
//   it. Measured, not suspected. Mirrors `panel.stepHistory` on desktop side.
//   Restored snapshot's slot numbers need not match, so open session has nothing
//   trustworthy left to commit against and is dropped.
function stepHistory(is_undo) {
  if (is_undo ? nimUndo() : nimRedo()) {
    endEditSession();
    adoptConstructionSelection();
    refreshObjectsUI();
  } else {
    toast(is_undo ? 'Nothing to undo.' : 'Nothing to redo.');
  }
  refreshUndoRedoButtons();
}

button_undo.addEventListener('click', () => stepHistory(true));
button_redo.addEventListener('click', () => stepHistory(false));

/* ---------------------------------------------------------------------- */
/* Keyboard. Undo and redo were reachable only by pressing their buttons,  */
/*   and drag once begun had no way out at all, though `cancelDrag` has    */
/*   existed and been tested throughout. Nothing new happens here: these   */
/*   are second ways to reach what buttons already do.                     */
/* ---------------------------------------------------------------------- */

document.addEventListener('keydown', (e) => {
  // Typing in field is not shortcut: coefficient or label is edited with very.
  //   keys these bind, and ctrl+z inside input already means browser's own undo.
  const target = e.target;
  if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' ||
      target.isContentEditable)) {
    return;
  }

  if (e.key === 'Escape') {
    // Everything in progress, in order reader would expect to shed it: panel.
    //   they just opened, then menu, then gesture underneath.
    if (panel_help.classList.contains('show')) { showHelp(false); return; }
    if (menu_top.classList.contains('show')) {
      menu_top.classList.remove('show');
      button_menu.classList.remove('on');
      return;
    }
    if (nimDragActive()) { nimCancelDrag(); toast('Cancelled.'); return; }
    nimCancelHold();
    if (menu_selection.classList.contains('show')) { clearSelection(); return; }
    if (session_edit !== null) { endEditSession(); refreshObjectsUI(); }
    return;
  }

  // 3D view answers its own keys, but only while it actually has focus -- it is one.
  //   ordinary tab stop (see its `tabindex` in markup), so reader tabs into it,
  //   drives it, and tabs onward. Tab itself is never intercepted: rebinding it inside
  //   canvas is tempting design and risks keyboard trap, which WCAG 2.1.2 rules
  //   out at same level 2.1.1 asks for this in first place.
  //   Which key does what is `interaction.actionFor`'s to say; only DOM's own naming
  //   of keys is translated across, exactly as SDL scancodes are on desktop side.
  if (document.activeElement === canvas && !(e.ctrlKey || e.metaKey || e.altKey)) {
    // `e.code`, physical key, which is what desktop's scancodes name -- see.
    //   `browser_bridge.keyFor`. Key that moves view is held from here until its
    //   `keyup` below; key that acts does so on this press.
    if (nimKeyBound(e.code)) {
      e.preventDefault(); // Arrows would otherwise scroll page under canvas.
      const slot = nimKeyDown(e.code);
      if (slot >= 0) {
        // Shift adds rather than replaces, exactly as shift-click does -- one thing.
        //   shift state means that shared binding table cannot answer alone.
        if (e.shiftKey) toggleSelection(slot, null); else selectOnly(slot, null);
      }
      return;
    }
  }

  // Ctrl on every platform, and cmd as well on macOS, where ctrl+z is not what reader.
  //   with muscle memory presses.
  if (!(e.ctrlKey || e.metaKey)) return;
  const key = e.key.toLowerCase();
  if (key === 'z' && !e.shiftKey) {
    e.preventDefault();
    stepHistory(true);
  } else if ((key === 'z' && e.shiftKey) || key === 'y') {
    e.preventDefault();
    stepHistory(false);
  }
});

// Let go of every held key whenever its release could go missing.
//   Key can only stop moving camera if its release is seen, and there are three ways
//   for one to go missing: release lands while another element has focus, window loses
//   focus entirely, or tab is hidden.
//   First is handled by matching keydown guard; other two let go of everything.
document.addEventListener('keyup', (e) => {
  nimKeyUp(e.code);
});
window.addEventListener('blur', () => { nimReleaseKeysAll(); nimSetCameraDragging(false); });
canvas.addEventListener('blur', () => { nimReleaseKeysAll(); });
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { nimReleaseKeysAll(); nimSetCameraDragging(false); }
});

// Write `disabled` only where it moved.
//   Compared first, so button whose state stands costs its tick one property read and
//   no attribute write.
function writeDisabled(button, is_disabled) {
  if (button.disabled !== is_disabled) button.disabled = is_disabled;
}

function refreshUndoRedoButtons() {
  // Dimmed/disabled (via shared .button:disabled rule) whenever there's nothing on.
  //   that side of timeline to move to -- checked after every history-touching
  //   action below, plus once per low-cadence UI tick to catch every other path
  //   (add, apply, remove, load demo, scene load/clear) without hooking each one.
  writeDisabled(button_undo, !nimCanUndo());
  writeDisabled(button_redo, !nimCanRedo());
}

/* ---------------------------------------------------------------------- */
/* View panel: camera numeric fields, mirroring panel.layoutView exactly. */
/* ---------------------------------------------------------------------- */

const fields_camera = {
  azimuth: document.getElementById('cam-azimuth'),
  elevation: document.getElementById('cam-elevation'),
  distance: document.getElementById('cam-distance'),
  fov: document.getElementById('cam-fov'),
  tx: document.getElementById('cam-target-x'),
  ty: document.getElementById('cam-target-y'),
  tz: document.getElementById('cam-target-z'),
};
let are_fields_camera_focused = false;
Object.values(fields_camera).forEach((element) => {
  element.addEventListener('focus', () => { are_fields_camera_focused = true; });
  element.addEventListener('blur', () => { are_fields_camera_focused = false; });
});
// Commit each field on change.
//   Falls back to value camera treats as its own floor for that quantity where box is
//   left empty or unparseable.
function commitCameraField(field, apply, fallback) {
  field.addEventListener('change', () => apply(parseFloat(field.value) || fallback));
}
commitCameraField(fields_camera.azimuth, nimSetCameraAzimuth, 0);
commitCameraField(fields_camera.elevation, nimSetCameraElevation, 0);
commitCameraField(fields_camera.distance, nimSetCameraDistance, 0.1);
commitCameraField(fields_camera.fov, nimSetCameraFov, 45);

function commitTarget() {
  nimSetCameraTarget(
    parseFloat(fields_camera.tx.value) || 0,
    parseFloat(fields_camera.ty.value) || 0,
    parseFloat(fields_camera.tz.value) || 0,
  );
}
fields_camera.tx.addEventListener('change', commitTarget);
fields_camera.ty.addEventListener('change', commitTarget);
fields_camera.tz.addEventListener('change', commitTarget);

// Each field's last written value, so still camera formats and writes nothing.
//   Seven `nimFormatNumber` calls and seven input writes ran five times second for
//   numbers that had not moved. `NaN` before first tick: equal to nothing, so first
//   comparison always writes.
const camera_written = {
  azimuth: NaN, elevation: NaN, distance: NaN, fov: NaN, tx: NaN, ty: NaN, tz: NaN,
};
function writeCameraField(name, value) {
  if (camera_written[name] === value) return;
  camera_written[name] = value;
  // `nimFormatNumber`, not `toFixed` here: angle of 1.05 should read `1.05` rather.
  //   than `1.050`, and desktop draws every one of these with same widget.
  fields_camera[name].value = nimFormatNumber(value);
}

function refreshCameraFields() {
  if (are_fields_camera_focused) return; // Don't fight value user is mid-typing.
  writeCameraField('azimuth', nimCameraAzimuth());
  writeCameraField('elevation', nimCameraElevation());
  writeCameraField('distance', nimCameraDistance());
  writeCameraField('fov', nimCameraFov());
  const target = nimCameraTarget();
  writeCameraField('tx', target[0]);
  writeCameraField('ty', target[1]);
  writeCameraField('tz', target[2]);
}

// **Asked for here, taken inside frame that draws it.** Context is created without.
//   `preserveDrawingBuffer` (see its own note), so canvas read from task of its own finds
//   drawing buffer already composited and thrown away -- read comes back blank or
//   fails outright, which is image button doing nothing at all. `preserveDrawingBuffer:
//   true` would fix it by making every frame keep copy forever, on phones, to serve
//   button pressed once in session; capturing between last draw call and yield
//   costs nothing and is same capture-then-yield shape `runStoryboard` uses.
//
//   Two theories for moving this into handler instead -- `renderFrame` then synchronous
//   `toDataURL` -- were tried and **both are false**, recorded so they are not re-derived:
//
//   - *It would keep transient activation `navigator.share` needs.* It is not lost:
//     window is around five seconds and spans task boundary. Measured against stub
//     that refuses without `navigator.userActivation.isActive` -- this build passes it.
//   - *It would stop backgrounded tab stranding capture,* since `requestAnimationFrame`
//     stops there. Did not reproduce: tapping and backgrounding page immediately still
//     delivered file.
//
//   With no measured benefit left, asynchronous read wins on cost: `toDataURL` blocks
//   main thread for whole encode, which on phone-sized canvas is most of second of
//   frozen UI.
let is_capture_wanted = false;
document.getElementById('button-export-png').addEventListener('click', () => {
  is_capture_wanted = true;
  toast('Capturing the next frame\u2026');
});

function captureFrameIfAsked() {
  if (!is_capture_wanted) return;
  is_capture_wanted = false;
  const [width, height] = [canvas.width, canvas.height];
  canvas.toBlob((blob) => {
    // `toBlob` hands back null where encoding failed. Unchecked, next line threw into.
    //   async callback nobody watches -- silence on top of silence.
    if (blob === null) {
      toast('The browser could not encode this frame as a PNG.');
      return;
    }
    deliverFile(
      blob, 'rga_visualiser.png', 'image/png',
      'A ' + width + '\u00d7' + height + ' image of this view',
    );
  }, 'image/png');
}

// **One button per size, built from what bridge reports.** Counts are
// `orrery.ScaleOrrery`'s and nothing here knows them: size added or renamed there shows up
// as button without this file or markup being touched. Button is labelled with
// count because count is what reader picking between benchmark scenes is choosing.
for (const scale of nimDemoScales()) {
  const items = nimDemoItems(scale);
  const button = document.createElement('button');
  button.className = 'button';
  button.type = 'button';
  button.id = `button-load-demo-${items}`;
  button.textContent = String(items);
  button.title =
    `Load the orrery at ${items} objects: the real solar neighbourhood, Sol at the origin, ` +
    'every drawable kind present. The same arrangement at every size, reaching further into ' +
    'the star catalogue as it grows.' +
    (scale === nimDemoScaleDefault() ? ' The size everything opens on.' : '');
  button.addEventListener('click', () => {
    nimLoadDemo(scale, now(), canvas.width, canvas.height);
    toast(`Loaded the orrery: ${nimSceneCount()} objects, ` +
      `${nimSceneCapacity() - nimSceneCount()} slots free.`);
    adoptConstructionSelection();
  });
  document.getElementById('button-demo-scales').appendChild(button);
}

/* ---------------------------------------------------------------------- */
/* Construct panel: add point, apply operation -- mirrors                 */
/* panel.layoutPointNew / panel.layoutOperation exactly.                  */
/* ---------------------------------------------------------------------- */

const picker_arity = document.getElementById('op-arity');
const picker_operation = document.getElementById('op-select');
const picker_operand_first = document.getElementById('op-first');
const picker_operand_second = document.getElementById('op-second');
const field_operand_second = document.getElementById('op-second-field');

let arity_current = 0; // 0 = unary, 1 = binary -- matches nimOperationArity's own convention.

function populateOperations() {
  const value_previous = picker_operation.value;
  picker_operation.innerHTML = '';
  const count = nimOperationCount();
  for (let i = 0; i < count; i++) {
    if (nimOperationArity(i) !== arity_current) continue;
    const option = document.createElement('option');
    option.value = i;
    option.textContent = nimOperationNotation(i);
    picker_operation.appendChild(option);
  }
  // Fall back to new list's first option where previous selection's index is absent.
  //   Switching arity can leave it absent from new, filtered option list, and
  //   opSelect.value must not point at now-nonexistent <option>.
  if (picker_operation.querySelector('option[value="' + value_previous + '"]')) {
    picker_operation.value = value_previous;
  } else {
    // Fresh list opens on what was last applied at this arity, not on its own head.
    picker_operation.value = String(nimOperationRemembered(arity_current));
  }
  updateOperandEnablement();
  ghostDrawerOperation();
}

picker_arity.querySelectorAll('button[data-arity]').forEach((button) => {
  button.addEventListener('click', () => {
    arity_current = parseInt(button.dataset.arity, 10);
    picker_arity.querySelectorAll('button[data-arity]').forEach(
      (each) => each.classList.toggle('on', each === button),
    );
    populateOperations();
  });
});

function ghostDrawerOperation() {
  // Preview what `apply` would build, live while this section is open.
  //   Follows operation and both operands, since preview that ignored half its own
  //   inputs would be showing something button beside it would not build.
  //   Nim decides what preview is worth showing; this only says which three readings to
  //   try.
  //   Drawer names its own operands, so it reads them rather than selection.
  if (!isDrawerApplyOpen()) { nimClearPreview(); return; }
  const slots = nimSceneSlots();
  const first = slots[parseInt(picker_operand_first.value, 10)];
  const second = arity_current === 0
    ? first
    : slots[parseInt(picker_operand_second.value, 10)];
  if (!Number.isInteger(first) || !Number.isInteger(second)) { nimClearPreview(); return; }
  nimGhostOperation(parseInt(picker_operation.value, 10), first, second);
}

// How long one slice of row building may take before it yields frame. Under third of.
//   60 fps frame: long enough that few dozen rows land per slice, short enough that
//   frame it is spending is still frame that draws.
const MILLISECONDS_ROWS_SLICE = 5;
// Wider slice while row is waited for: reader pressed `edit` and is looking at nothing.
//   until that row stands, so frames give way to rows -- five thousand at largest demo,
//   which at five milliseconds is over one second of list filling before row can be
//   scrolled to. See `openPanelTo`.
const MILLISECONDS_ROWS_SLICE_REVEAL = 24;
// Row `openPanelTo` is waiting to scroll to, by key, or null.
//   Consumed by `revealPendingRow` once row stands, whether that is at once or slices later.
let key_reveal_pending = null;
// What is left of reconcile that has not finished building its rows, or null. Drained by.
//   frame loop rather than by `requestAnimationFrame` of its own, for one reason:
//   `recordPhaseTime` *overwrites* phase's reading for frame rather than adding to it,
//   so work done in callback beside loop is either unmeasured or clobbers what
//   loop measured. Cost inside frame belongs to phase of that frame -- same rule
//   `ui refresh` row was fixed under once already.
let rows_pending = null;

function sliceObjectRows() {
  // One slice of pending reconcile, bounded by time rather than by row count: row.
  //   that is already standing and unchanged costs almost nothing, and one that has to be
  //   built costs far more, so fixed count would be different budget on every pass.
  if (rows_pending === null) return;
  const { keys, standing } = rows_pending;
  const budget = key_reveal_pending === null
    ? MILLISECONDS_ROWS_SLICE : MILLISECONDS_ROWS_SLICE_REVEAL;
  const until = performance.now() + budget;
  while (rows_pending.at < keys.length) {
    const at = rows_pending.at;
    const key = keys[at];
    const signature = signatureOfItemRow(key);
    let node = standing.get(key);
    const is_building = node === undefined || signatures_row.get(key) !== signature;
    if (is_building) {
      if (node !== undefined) node.remove();
      node = buildRowFor(key);
      node.dataset.key = key;
    }
    // **Signature committed per row, not at end of pass.** Refresh arriving mid-build.
    //   restarts pass from top, and with signatures held back until pass finished every
    //   row already built read as stale and was built again -- list that never finished
    //   while selection kept refreshing it, and edit form that never scrolled into view.
    signatures_row.set(key, signature);
    // Already in right place is common case; otherwise this moves it there.
    if (list_objects.children[at] !== node) {
      list_objects.insertBefore(node, list_objects.children[at] || null);
    }
    rows_pending.at = at + 1;
    // Checked only where row was actually built, so pass that changes nothing runs to.
    //   end without ever reading clock -- tap on `hide` stays immediate.
    if (is_building && performance.now() >= until) {
      revealPendingRow();
      return;
    }
  }
  // Whatever is left past wanted rows is gone from scene, signatures with it.
  while (list_objects.children.length > keys.length) list_objects.lastElementChild.remove();
  const wanted = new Set(keys);
  for (const key of Array.from(signatures_row.keys())) {
    if (!wanted.has(key)) signatures_row.delete(key);
  }
  rows_pending = null;
  revealPendingRow();
}

function revealPendingRow() {
  // Scroll to row `openPanelTo` asked for, once it stands; see `key_reveal_pending`.
  //   Row far down list stands only after every row above it, so this is asked after
  //   each slice as well as at once.
  if (key_reveal_pending === null) return;
  const row = list_objects.querySelector('.item-row[data-key="' + key_reveal_pending + '"]');
  if (row === null) return;
  key_reveal_pending = null;
  scrollRowIntoView(row);
}

function isDrawerObjectsOpen() {
  // Collapsed section shows no rows, so there are none to keep current.
  //   Drawer is asked as well as section:
  //   section marked open inside closed drawer is still not on screen, and load happens either way.
  const section = document.querySelector('.section[data-section="objects"]');
  return section !== null && section.classList.contains('open') &&
    drawer.classList.contains('open');
}

function isDrawerApplyOpen() {
  // Collapsed section previews nothing:
  //   ghost belongs to control on screen, and one left standing after its section closed names
  //   nothing reader can see.
  const section = document.querySelector('.section[data-section="apply"]');
  return section !== null && section.classList.contains('open');
}

picker_operation.addEventListener('change', () => {
  updateOperandEnablement();
  ghostDrawerOperation();
});
for (const operand of [picker_operand_first, picker_operand_second]) {
  operand.addEventListener('change', ghostDrawerOperation);
}
function updateOperandEnablement() {
  const arity = nimOperationArity(parseInt(picker_operation.value, 10) || 0);
  field_operand_second.style.display = arity === 0 ? 'none' : '';
}

populateOperations();

// Coefficient grid, shared by add-multivector section and each row's own edit box:
//   stacked one row per grade (0 to n), rather than wrapping basis order at fixed
//   column count regardless of grade boundaries -- grade comes from `nimBasisGrade`
//   (backed by `pga/algebra.grade`, library's own basis-to-grade lookup), needing
//   no hardcoded basis list or JS-side reimplementation to stay correct if this build's
//   own dimension ever changes.
function buildGradedCoefficientGrid(container, valueAt) {
  const count_basis = nimBasisCount();
  const inputs = new Array(count_basis);
  const by_grade = [];
  for (let b = 0; b < count_basis; b++) {
    const grade = nimBasisGrade(b);
    (by_grade[grade] || (by_grade[grade] = [])).push(b);
  }
  for (const group of by_grade) {
    if (!group) continue;
    const row = document.createElement('div');
    row.className = 'coefficient-grade-row';
    for (const b of group) {
      const f = document.createElement('div');
      f.className = 'field';
      const label_text = document.createElement('label');
      label_text.textContent = nimBasisName(b);
      const input = document.createElement('input');
      input.type = 'number';
      input.step = '0.1';
      input.value = valueAt(b);
      f.appendChild(label_text);
      f.appendChild(input);
      row.appendChild(f);
      inputs[b] = input;
    }
    container.appendChild(row);
  }
  return inputs;
}

document.getElementById('button-apply').addEventListener('click', () => {
  if (nimSceneCount() === 0) { toast('Scene is empty; add a point first.'); return; }
  const slots = nimSceneSlots();
  const first = slots[Math.min(parseInt(picker_operand_first.value, 10) || 0, slots.length - 1)];
  const second = slots[Math.min(parseInt(picker_operand_second.value, 10) || 0, slots.length - 1)];
  if (nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
  const result = nimApplyOperation(parseInt(picker_operation.value, 10), first, second, now());
  toast(result.message);
  adoptConstructionSelection();
});

let key_selection_synced_last = ''; // Mirrors panel.nim's index_operand_synced_highlight,
  // generalized to pair:
  //   re-defaults operand m/n to current selection only moment selection itself changes (not on
  //   every refreshOperandOptions call, which happens far more often than selection changes), so
  //   manual pick of different operand sticks until selection moves again.
let key_operand_options_last = ''; // Slot list + labels last used to rebuild operand m/n's
  // own <option> elements -- rebuilding <select>'s options while its native picker
  // is open (mobile especially) makes browser re-show/reset that picker, so
  // full rebuild below only actually runs when scene composition or label changed,
  // never on every periodic tick.

function refreshOperandOptions() {
  const slots = nimSceneSlots();
  // **Keyed on scene's own revision, not on roll-call of every label.** Key used.
  //   to be `slot:label` joined over whole scene, which is one FFI call per object and
  //   string length of list -- 5,038 calls to decide whether two pickers needed
  //   rebuilding, on path every scene change runs through. `scene.revision` moves on
  //   exactly edits that can change label, and count catches nothing else moving.
  const key = nimSceneRevision() + ':' + slots.length;
  // Collapsed section has no pickers to fill: rebuilding them is one `<option>` per.
  //   object per picker, ten thousand elements at largest size, for control that is
  //   not on screen. Section header and drawer button both refresh on opening.
  if (key !== key_operand_options_last && isDrawerApplyOpen()) {
    key_operand_options_last = key;
    for (const selection_target of [picker_operand_first, picker_operand_second]) {
      const prev = selection_target.value;
      selection_target.innerHTML = '';
      slots.forEach((slot, i) => {
        const option = document.createElement('option');
        option.value = i;
        option.textContent = nimItemLabel(slot);
        selection_target.appendChild(option);
      });
      if (prev !== '' && parseInt(prev, 10) < slots.length) selection_target.value = prev;
    }
  }
  syncOperandsToSelection(slots);
}

function syncOperandsToSelection(slots) {
  // Everything selection already says is filled in here rather than asked for second time:
  //   how many objects are picked names arity (`nimSelectionArity`, same rule floating menu reads),
  //   and order they were picked names m and n.
  //   Only right when selection itself changes -- cheap enough (no DOM rebuild) to call on every
  //   frame-loop tick, unlike option-list rebuild above, and leaving later manual pick of either
  //   alone until selection next moves.
  //   Mirrors panel.layoutApply exactly.
  const key = slots_selection.join(',');
  if (key === key_selection_synced_last) return;
  key_selection_synced_last = key;
  if (slots_selection.length === 0) return; // Nothing picked names nothing; leave it be.
  const slots_scene = slots || nimSceneSlots();

  const arity = nimSelectionArity();
  if (arity !== arity_current) {
    // Rebuild filtered operation list, indexed per arity.
    //   Option carried across from other list names unrelated operation;
    //   populateOperations rebuilds it and falls back to new list's first entry, exactly
    //   as arity buttons do.
    arity_current = arity;
    picker_arity.querySelectorAll('button[data-arity]').forEach((each) => {
      each.classList.toggle('on', parseInt(each.dataset.arity, 10) === arity);
    });
    populateOperations();
  }

  const position_first = slots_scene.indexOf(slots_selection[0]);
  if (position_first >= 0) picker_operand_first.value = position_first;
  if (slots_selection.length >= 2) {
    // Three or more picked still names binary operation, on first two:
    //   this picker can say which two, unlike floating menu, which hides `apply` rather than guess.
    const position_second = slots_scene.indexOf(slots_selection[1]);
    if (position_second >= 0) picker_operand_second.value = position_second;
  }
}

/* ---------------------------------------------------------------------- */
/* Objects panel: list, show/hide, remove, rename, recolour, edit         */
/* coefficients -- mirrors panel.layoutObjects / layoutItem exactly.      */
/* ---------------------------------------------------------------------- */

const list_objects = document.getElementById('objects-list');
const count_objects = document.getElementById('objects-count');
/* ---------------------------------------------------------------------- */
/* Edit session: one at time, in one of two modes -- composing brand-      */
/* new object (`slot` null, nothing backing it in scene yet) or            */
/* editing existing one. Both stage same four things and preview           */
/* through same ghost; only `save` reaches scene. State lives here         */
/* rather than in row's own closures because `refreshObjectsUI`            */
/* rebuilds every row from scratch, which would otherwise discard it.      */
/* ---------------------------------------------------------------------- */

let session_edit = null; // { slot, coefficients: number[], label, ink, radius, shines }

function beginEditSession(slot) {
  // Null slot composes; real slot edits that item. Seeding composing session from.
  //   Nim's own defaults keeps auto-label and cycled ink every other construction
  //   path assigns, while leaving both editable before object exists.
  session_edit = slot === null
    ? {
        slot: null,
        coefficients: new Array(nimBasisCount()).fill(0),
        label: nimDefaultLabel(),
        ink: nimDefaultInk(),
        radius: nimDefaultRadius(),
        shines: false,
      }
    : {
        slot,
        coefficients: Array.from(nimItemCoefficients(slot)),
        label: nimItemLabel(slot),
        ink: nimItemInk(slot),
        radius: nimItemRadius(slot),
        shines: nimItemShines(slot),
      };
  nimSetGhost(session_edit.coefficients, session_edit.radius);
}

function endEditSession() {
  session_edit = null;
  nimClearGhost();
}

// Two rows that are not object: note shown to empty list, and row.
//   composing session heads it with. Keys rather than positions, so reconcile below can
//   talk about every row same way.
const KEY_ROW_EMPTY = 'empty';
const KEY_ROW_PENDING = 'pending';
// What each key's row was picture of when it was last built. Compared, never ordered.
let signatures_row = new Map();

// Geometry line row shows, held per slot against scene's own revision.
//   **Costly half of signature, and function of geometry alone.** Measured at
//   1,024 objects, `nimFormatMultivector` is 11.8 ms of walk and `nimItemShapeWord` 2.9,
//   against 0.8 ms for every other field row draws put together. Geometry changes only
//   when `scene.revision` does -- every writer bumps it, which is what frame hold and
//   placement cache already rest on -- so text is re-derived when revision moves
//   and reused otherwise. Selection change, which is what most refreshes are, moves no
//   revision and re-derives nothing.
//   Cleared whole rather than per slot: revision is scene's, not slot's, so
//   edit re-derives every row. That is same over-approximation `PLACEMENTS` makes, and it
//   costs one deliberate action walk it would have paid anyway.
let text_geometry_row = new Map();
let revision_geometry_row = -1;

function geometryTextFor(slot) {
  const revision = nimSceneRevision();
  if (revision_geometry_row !== revision) {
    revision_geometry_row = revision;
    text_geometry_row = new Map();
  }
  let held = text_geometry_row.get(slot);
  if (held === undefined) {
    held = nimItemShapeWord(slot) + ': ' + nimFormatMultivector(slot);
    text_geometry_row.set(slot, held);
  }
  return held;
}

function signatureOfItemRow(key) {
  // **Everything row draws, and nothing else.** Two equal signatures mean same.
  //   picture, so element standing there is already right and is left alone.
  if (key === KEY_ROW_EMPTY || key === KEY_ROW_PENDING) return key;
  const slot = parseInt(key, 10);
  // Open row is keyed by being open rather than described. Its fields preview.
  //   `session_edit` and its own handlers keep them current as reader types; rebuilding
  //   it on some unrelated refresh would take caret out of whatever field they were in.
  if (isEditing(slot)) return 'open:' + slot;
  return [
    nimItemLabel(slot), nimItemInk(slot), nimItemVisible(slot) ? 1 : 0,
    slots_selection.includes(slot) ? 1 : 0, geometryTextFor(slot),
  ].join('\u0001');
}

function buildRowFor(key) {
  if (key === KEY_ROW_EMPTY) {
    const p = document.createElement('div');
    p.className = 'help-text';
    p.style.margin = '8px 0 0';
    p.textContent = 'Nothing here yet -- press `add` above, or drag between two objects.';
    return p;
  }
  return buildItemRow(key === KEY_ROW_PENDING ? null : parseInt(key, 10));
}

function refreshObjectsUI() {
  // **Closed section builds nothing, and catches up when it opens.** Loading largest.
  //   size with this section collapsed built 5,038 rows for list nobody could see: 790 ms
  //   of 1,496 ms load, half of it, spent on picture that was not on screen. Count
  //   in header is written either way -- it is one string, it is visible while
  //   section is shut, and it is only part of this reader can see from there.
  //   Same shape as pool grid's `is_pool_stale` and diagnostics tick's own
  //   `open` check; section handler above is what redeems flag.
  count_objects.textContent =
    '(' + nimSceneCount() + ' of ' + nimSceneCapacity() + ')';
  // These two belong to *apply* section and to button above list, not to.
  //   rows -- they are refreshed here only because every caller that changes scene
  //   already calls this. So they run whether or not rows do: gating them behind
  //   objects section left operand pickers empty for reader who had collapsed it.
  refreshOperandOptions();
  refreshAddButton();
  if (!isDrawerObjectsOpen()) return;

  // **Reconciled against rows already standing, not rebuilt.** This used to empty.
  //   list and build every row again, which on 1,024-object demo was 570 ms of
  //   JavaScript and 164 ms of layout -- and there are dozen callers, so tap on `hide`
  //   paid all of it to change one checkbox.
  //   Built as diff rather than by making tap-driven callers call something narrower:
  //   list of "the cheap callers" is contract thirteenth caller breaks silently, and
  //   this way every caller is cheap, including ones not yet written. Refresh that
  //   changes nothing writes nothing. Same shape as `timings.RECORDS_FRAME`'s
  //   this-frame/last-frame pair and swap arena, one side of wire over.
  // **Ordered by bridge, not by comparator that calls it.** This used to sort by.
  //   `nimItemBorn`, which is two calls across FFI per comparison -- about 124,000 of
  //   them over 5,038 slots, and 165 ms of load, to reach order Nim can hand over.
  //   `nimSceneSlotsCreated` is that order already: `scene.slotsCreated` walks by
  //   creation ordinal, and replayed load stamps `born` in creation order, so reversing
  //   it is same "most recently added first" for one pass and no comparator at all.
  const slots = Array.from(nimSceneSlotsCreated()).reverse();
  const keys = [];
  if (slots.length === 0 && !isComposing()) keys.push(KEY_ROW_EMPTY);
  // Composing session heads list: it is newest thing here, and it has no.
  //   `born` reading to sort by since nothing backs it in scene yet.
  if (isComposing()) keys.push(KEY_ROW_PENDING);
  for (const slot of slots) keys.push(String(slot));

  // Snapshotted, not walked live: loop below inserts into this very collection.
  const standing = new Map();
  for (const node of Array.from(list_objects.children)) standing.set(node.dataset.key, node);

  // **Built in slices, so long list cannot freeze page.** Five thousand rows is 820 ms.
  //   of element construction in one block -- whole of load, once bridge stopped
  //   deep-copying timeline -- and there is no version of that reader does not feel.
  //   Diff itself stays whole and synchronous: it is *building* that costs, and
  //   half-applied diff is only ever list that has not finished filling, never wrong one.
  //   Rows appear top-down as scene's own objects animate in, which is order
  //   they arrive in anyway.
  //   Refresh that finds everything already standing does no building and so never yields
  //   -- common case, tap on `hide`, stays exactly as immediate as it was.
  rows_pending = { keys, standing, signatures: new Map(), at: 0 };
  sliceObjectRows();
}

function isComposing() { return session_edit !== null && session_edit.slot === null; }

function isEditing(slot) { return session_edit !== null && session_edit.slot === slot; }

function refreshAddButton() {
  // Disabled while any session is open, so starting second one cannot silently.
  //   discard first -- same treatment undo/redo get when their side is empty.
  writeDisabled(button_add, session_edit !== null || nimSceneCount() >= nimSceneCapacity());
}

function buildItemRow(slot) {
  // `slot === null` builds composing row: same layout, but nothing backs it in.
  //   scene, so everything it displays comes from `session_edit` and buttons that act
  //   on real object (hide, remove) are left out entirely.
  const is_pending = slot === null;
  const is_open = is_pending || isEditing(slot);

  const row = document.createElement('div');
  if (!is_pending) row.dataset.slot = slot; // Lets caller find one row again by slot.
  // Open row says so on itself: it is one row whose real height panel has to.
  //   know -- `scrollRowIntoView` scrolls to bring its edit form into view, and form
  //   standing behind 42px placeholder scrolls to placeholder. `shell.html` reads
  //   this class to keep open row out of containment other thousand are in.
  row.className = 'item-row'
    + (is_open ? ' editing-item' : '')
    + (is_pending ? ' pending-item' : '')
    + (!is_pending && slots_selection.includes(slot) ? ' selected' : '')
    + (!is_pending && !nimItemVisible(slot) ? ' hidden-item' : '');

  const top = document.createElement('div');
  top.className = 'item-top';

  // While session is open its staged values drive row, so swatch, label and.
  //   coefficient line preview edit without scene having changed.
  const inkOf = () => (is_open ? session_edit.ink : nimItemInk(slot));
  const labelOf = () => (is_open ? session_edit.label : nimItemLabel(slot));

  // Selection checkbox:
  //   mirrors/toggles membership in `slots_selection`, exactly same helper
  //   long-press/click-to-select already drives -- not visibility any more.
  const check_select = document.createElement('input');
  check_select.type = 'checkbox';
  check_select.checked = !is_pending && slots_selection.includes(slot);
  check_select.disabled = is_pending; // Nothing to select until it exists.
  check_select.title = 'Select or deselect this object.';
  if (!is_pending) check_select.addEventListener('change', () => toggleSelection(slot, null));
  top.appendChild(check_select);

  const swatch = document.createElement('span');
  swatch.className = 'swatch';
  swatch.style.background = rgbToCss(nimInkColor(inkOf()));
  top.appendChild(swatch);

  const label = document.createElement('span');
  label.className = 'item-label';
  label.textContent = labelOf();
  label.style.color = rgbToCss(nimInkColor(inkOf()));
  top.appendChild(label);

  const toggle_edit = document.createElement('button');
  toggle_edit.className = 'button item-edit-toggle';
  toggle_edit.type = 'button';
  toggle_edit.textContent = is_open ? 'save' : 'edit';
  toggle_edit.title = is_open
    ? 'Commit these values to the scene.'
    : 'Rename, recolour or reshape this object; nothing changes until you save.';
  toggle_edit.addEventListener('click', () => {
    if (!is_open) { beginEditSession(slot); refreshObjectsUI(); return; }
    if (is_pending && nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
    if (is_pending) {
      nimAddItem(
        session_edit.coefficients, session_edit.label, session_edit.ink, session_edit.radius,
        session_edit.shines, now(),
      );
      endEditSession();
      adoptConstructionSelection();
      toast('Added `' + label.textContent + '`.');
    } else {
      nimCommitItem(
        slot, session_edit.coefficients, session_edit.label, session_edit.ink,
        session_edit.radius, session_edit.shines,
      );
      endEditSession();
      toast('Saved `' + label.textContent + '`.');
    }
    refreshObjectsUI();
    refreshUndoRedoButtons();
  });
  top.appendChild(toggle_edit);

  if (is_open) {
    // Abandon: composing row vanishes with nothing added, editing row reverts. In.
    //   both cases scene was never touched, so this only has to drop session.
    const cancel = document.createElement('button');
    cancel.className = 'button item-edit-cancel';
    cancel.type = 'button';
    cancel.textContent = '✕';
    cancel.title = is_pending ? 'Discard this new object.' : 'Discard these changes.';
    cancel.addEventListener('click', () => {
      endEditSession();
      refreshObjectsUI();
    });
    top.appendChild(cancel);
  }

  if (!is_open) {
    // Hide/show and remove act on object as scene holds it, which is exactly what.
    //   open session is staging replacement for -- offering them mid-edit invites
    //   acting on one version while looking at another. Composing row has no object at
    //   all yet, so both are left out rather than shown disabled either way.
    const visibility = document.createElement('button');
    visibility.className = 'button item-visibility';
    visibility.type = 'button';
    visibility.textContent = nimItemVisible(slot) ? 'hide' : 'show';
    visibility.title = 'Show or hide this object without removing it.';
    visibility.addEventListener('click', () => {
      const was_visible = nimItemVisible(slot);
      nimSetVisible(slot, !was_visible);
      visibility.textContent = was_visible ? 'show' : 'hide'; // Local flip, no full rebuild.
      row.classList.toggle('hidden-item', was_visible);
    });
    top.appendChild(visibility);

    const remove = document.createElement('button');
    remove.className = 'button item-remove';
    remove.type = 'button';
    remove.textContent = 'remove';
    remove.title = "Delete this object; its slot is reused by the next one you add.";
    remove.addEventListener('click', () => {
      nimRemoveItem(slot); // Drops slot from selection itself, so stale pick
        // cannot linger and read as "selected" once future add reuses freed slot.
      if (isEditing(slot)) endEditSession(); // Its session has nothing left to commit to.
      toast('Removed `' + label.textContent + '`.');
      onSelectionChanged(null);
    });
    top.appendChild(remove);
  }

  row.appendChild(top);

  const line_coefficient = document.createElement('div');
  line_coefficient.className = 'item-coefficient';
  const describeStaged = () =>
    is_open ? nimDescribeCoefficients(session_edit.coefficients)
           : geometryTextFor(slot);
  line_coefficient.textContent = describeStaged();
  row.appendChild(line_coefficient);

  // **Built only for row that is open, which is at most one of them.** Everything.
  //   below is edit form, and closed row used to build whole of it -- label
  //   field, ink picker with option per choosable slot, and grid with input per
  //   basis element -- and then let CSS hide it. Measured on 1,024-object demo that was
  //   **76 elements per collapsed row and 80,325 on page**, against 843 on opening
  //   scene; one rebuild of list cost 570 ms of JavaScript and 164 ms of layout, so
  //   tap on `hide` froze page for three quarters of second. It also meant
  //   `nimItemCoefficients` call across FFI for every row of every rebuild, to fill
  //   inputs nobody could see.
  //   Nothing was reachable in there anyway: every field writes into `session_edit`, which
  //   is null unless session is open, so hidden form could only have thrown.
  if (is_open) {
    const box_edit = document.createElement('div');
    box_edit.className = 'item-edit' + (is_open ? ' open' : '');

    const field_label = document.createElement('div');
    field_label.className = 'field';
    field_label.innerHTML = '<label>label</label>';
    // Write every field below into session, never scene.
    //   Row's own swatch, label and coefficient line preview change, ghost previews
    //   geometry, and only `save` above reaches `SCENE`.
    const input_label = document.createElement('input');
    input_label.type = 'text';
    input_label.value = labelOf();
    input_label.maxLength = 39;
    input_label.addEventListener('input', () => {
      session_edit.label = input_label.value;
      label.textContent = input_label.value;
    });
    field_label.appendChild(input_label);
    box_edit.appendChild(field_label);

    const field_ink = document.createElement('div');
    field_ink.className = 'field';
    field_ink.innerHTML = '<label>colour</label>';
    const picker_ink = document.createElement('select');
    // Only categorical slots are offerable; `nimInkChoosableSlots` decides which those.
    //   are, so no palette rule lives out here. Its entries stay whole-palette ordinals,
    //   same ones `nimItemInk` reports and `nimInkName`/`nimInkColor` accept.
    for (const ink of nimInkChoosableSlots()) {
      const option = document.createElement('option');
      option.value = ink;
      option.textContent = nimInkName(ink);
      picker_ink.appendChild(option);
    }
    picker_ink.value = inkOf();
    picker_ink.addEventListener('change', () => {
      session_edit.ink = parseInt(picker_ink.value, 10);
      const rgb = nimInkColor(session_edit.ink);
      swatch.style.background = rgbToCss(rgb);
      label.style.color = rgbToCss(rgb);
    });
    field_ink.appendChild(picker_ink);
    box_edit.appendChild(field_ink);

    // Size reads for point alone; line and plane take theirs from camera and horizon.
    //   World units, so what is typed shrinks with distance like everything else drawn
    //   at position. Bounded below at what editor accepts, since model refuses zero
    //   outright and would take page down with it.
    const field_radius = document.createElement('div');
    field_radius.className = 'field';
    field_radius.innerHTML = '<label>size</label>';
    const input_radius = document.createElement('input');
    input_radius.type = 'number';
    input_radius.min = String(nimLeastRadius());
    input_radius.step = 'any';
    input_radius.value = nimFormatNumber(session_edit.radius);
    input_radius.title = 'Radius the point is drawn at, in world units; it shrinks with distance.';
    input_radius.addEventListener('input', () => {
      const typed = parseFloat(input_radius.value);
      session_edit.radius = Number.isFinite(typed) && typed >= nimLeastRadius()
        ? typed : nimDefaultRadius();
      nimSetGhost(session_edit.coefficients, session_edit.radius); // Ghost shows size too.
    });
    field_radius.appendChild(input_radius);
    box_edit.appendChild(field_radius);

    // Sun: point every other point is shaded from, drawn flat itself; see `lighting`.
    const field_shines = document.createElement('label');
    field_shines.className = 'field field-check';
    const input_shines = document.createElement('input');
    input_shines.type = 'checkbox';
    input_shines.checked = session_edit.shines;
    input_shines.addEventListener('change', () => { session_edit.shines = input_shines.checked; });
    field_shines.appendChild(input_shines);
    field_shines.appendChild(document.createTextNode(' shines'));
    field_shines.title = 'A sun: lights every other point from where it stands.';
    box_edit.appendChild(field_shines);

    const note_coefficient = document.createElement('div');
    note_coefficient.className = 'help-text';
    note_coefficient.style.margin = '6px 0';
    note_coefficient.textContent = is_pending
      ? 'The 16 numbers of the new multivector, in the library’s basis order. ' +
        'A live preview draws as soon as any goes non-zero.'
      : 'The 16 numbers of this object’s own multivector, in the library’s basis ' +
        'order. The object itself only moves when you save.';
    box_edit.appendChild(note_coefficient);

    const grid = document.createElement('div');
    grid.className = 'coefficient-grid';
    // `nimFormatNumber`, not `toFixed` here: how many digits coefficient is worth.
    //   is decision about this project's numbers, and desktop's own cells make it
    //   same way.
    const inputs_coefficient = buildGradedCoefficientGrid(
      grid,
      (b) =>
        nimFormatNumber(is_open ? session_edit.coefficients[b] : nimItemCoefficients(slot)[b]),
    );
    inputs_coefficient.forEach((input, b) => {
      // `input`, not `change`: ghost tracks keystroke rather than waiting for.
      //   field to blur, which is what makes preview feel live.
      input.addEventListener('input', () => {
        session_edit.coefficients[b] = parseFloat(input.value) || 0;
        nimSetGhost(session_edit.coefficients, session_edit.radius);
        line_coefficient.textContent = describeStaged();
      });
    });
    box_edit.appendChild(grid);

    row.appendChild(box_edit);
  }
  return row;
}

document.getElementById('button-save-scene').addEventListener('click', saveScene);
document.getElementById('button-load-scene').addEventListener('click', () => {
  document.getElementById('file-load-scene').click();
});
document.getElementById('file-load-scene').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (file) loadSceneFile(file);
  e.target.value = '';
});

/* ---------------------------------------------------------------------- */
/* Scene save/load: pack and parse exact `.rgascene` binary format         */
/* `scene.nim`'s own doc comment documents (magic/version/basis-count/     */
/* item-count/per-item ink+visible+label+16 float64+radius+shines), so    */
/* build saves loads on desktop build and vice versa. Packing lives       */
/* here rather than in Nim, since `DataView` already does exactly this     */
/* natively -- see `browser_bridge.nim`'s own doc comment.                */
/* ---------------------------------------------------------------------- */

function saveScene() {
  // Creation order, not slot order: version-3 file promises its sequence is order.
  //   scene was built in, and removed-then-re-added object sits in reused slot
  //   well before objects that predate it. Loading walks sequence back one object at
  //   time, so writing slot order here would replay construction that never happened.
  const slots = nimSceneSlotsCreated();
  const count_basis = nimBasisCount();
  // Labels go out as UTF-8 bytes, which is what format holds and what `scene.nim`.
  //   writes: derived label carries operator notation (`a ∧ b`, `a ∨ b`, `a ⊖ b`), and
  //   JavaScript string's own `.length` counts UTF-16 units while `charCodeAt` truncated to
  //   byte throws away everything above U+00FF. Both together wrote shorter length than
  //   bytes that followed, so every object after first non-ASCII label parsed from
  //   wrong offset. Measured: `a ⊖ b` came back on desktop as `a` and replacement
  //   glyph.
  const encoder = new TextEncoder();
  const items = slots.map((slot) => ({
    ink: nimItemInk(slot),
    visible: nimItemVisible(slot),
    label: encoder.encode(nimItemLabel(slot)),
    coefficients: nimItemCoefficients(slot),
    radius: nimItemRadius(slot),
    shines: nimItemShines(slot),
  }));

  let size = 4 + 1 + 1 + 4;
  for (const item of items) size += 1 + 1 + 1 + item.label.length + count_basis * 8 + 8 + 1;

  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  let offset = 0;
  // Magic and version come from `scene.nim` through bridge, never from literals here:
  //   version was literal `1` and stayed one through format's bump to 2, so this
  //   build stamped every file it saved with version its own content was not.
  const magic = nimSceneMagic();
  for (let i = 0; i < magic.length; i++) {
    view.setUint8(offset, magic.charCodeAt(i));
    offset += 1;
  }
  view.setUint8(offset, nimSceneVersion()); offset += 1;
  view.setUint8(offset, count_basis); offset += 1;
  view.setUint32(offset, items.length, true); offset += 4;

  for (const item of items) {
    view.setUint8(offset, item.ink); offset += 1;
    view.setUint8(offset, item.visible ? 1 : 0); offset += 1;
    view.setUint8(offset, item.label.length); offset += 1;
    for (const byte of item.label) { view.setUint8(offset, byte); offset += 1; }
    for (let i = 0; i < count_basis; i++) {
      view.setFloat64(offset, item.coefficients[i], true);
      offset += 8;
    }
    view.setFloat64(offset, item.radius, true); offset += 8;
    view.setUint8(offset, item.shines ? 1 : 0); offset += 1;
  }

  deliverFile(
    new Blob([buffer], { type: 'application/octet-stream' }), 'scene.rgascene',
    'application/octet-stream',
    'A scene file holding ' + items.length + ' object(s)',
  );
}

function loadSceneFile(file) {
  const reader = new FileReader();
  reader.onload = () => {
    try {
      const outcome = parseAndLoadScene(reader.result);
      toast(outcome);
      adoptConstructionSelection(); // nimSceneClear() inside already cleared hover.
    } catch (err) {
      toast(String(err.message || err));
    }
  };
  reader.onerror = () => toast('Could not read `' + file.name + '`.');
  reader.readAsArrayBuffer(file);
}

function parseAndLoadScene(buffer) {
  const view = new DataView(buffer);
  if (buffer.byteLength < 10) throw new Error('`' + 'file' + '` is not a scene file.');
  let offset = 0;
  // Both expectations come from `scene.nim` through bridge, for reason `saveScene`.
  //   above gives: literal here is exactly what drifted out of step with format.
  const magic_wanted = nimSceneMagic();
  let magic = '';
  for (let i = 0; i < magic_wanted.length; i++) magic += String.fromCharCode(view.getUint8(i));
  offset = magic_wanted.length;
  if (magic !== magic_wanted) throw new Error('File is not a scene file.');
  // *range* through bridge, not this build's own writing version: every version.
  //   ever written stays readable, and which those are is `scene.readsSceneVersion`'s
  //   answer rather than pair of literals here to fall out of step with it.
  const version = view.getUint8(offset); offset += 1;
  if (!nimSceneReadsVersion(version)) {
    throw new Error('File is a scene file of a version this build cannot read.');
  }
  const count_basis_file = view.getUint8(offset); offset += 1;
  const count_basis_here = nimBasisCount();
  if (count_basis_file !== count_basis_here) {
    throw new Error(
      'File was saved under a different PGA dimension or metric; this build reads ' +
      count_basis_here + '-term multivectors.',
    );
  }
  const count_item = view.getUint32(offset, true); offset += 4;
  if (count_item > nimSceneCapacity()) {
    throw new Error(
      'File holds ' + count_item + ' objects, more than this build’s ' +
      nimSceneCapacity() + '-item capacity.',
    );
  }

  const parsed = [];
  for (let i = 0; i < count_item; i++) {
    if (offset + 3 > buffer.byteLength) {
      throw new Error('File is truncated partway through object ' + i + '.');
    }
    const ink = view.getUint8(offset); offset += 1;
    const visible = view.getUint8(offset) !== 0; offset += 1;
    const length_label = view.getUint8(offset); offset += 1;
    if (offset + length_label > buffer.byteLength) {
      throw new Error(
        'File is truncated partway through object ' + i + '’s label.',
      );
    }
    // Decoded as UTF-8, for reason `saveScene` gives: byte-per-character would read.
    //   every operator in derived label as two or three Latin-1 characters of noise.
    const label = new TextDecoder().decode(
      new Uint8Array(buffer, offset, length_label),
    );
    offset += length_label;
    if (offset + count_basis_here * 8 > buffer.byteLength) {
      throw new Error('File is truncated partway through object ' + i + '’s geometry.');
    }
    const coefficients = new Array(count_basis_here);
    for (let b = 0; b < count_basis_here; b++) {
      coefficients[b] = view.getFloat64(offset, true);
      offset += 8;
    }
    // Radius only where file's version wrote one; which versions did is Nim's rule.
    //   Older file's items take theirs from upgrade chain, so value passed is moot.
    let radius = nimDefaultRadius();
    if (nimSceneHasRadius(version)) {
      if (offset + 8 > buffer.byteLength) {
        throw new Error('File is truncated partway through object ' + i + '’s radius.');
      }
      radius = view.getFloat64(offset, true);
      offset += 8;
    }
    let shines = false;
    if (nimSceneHasShine(version)) {
      if (offset + 1 > buffer.byteLength) {
        throw new Error('File is truncated partway through object ' + i + '’s shine.');
      }
      shines = view.getUint8(offset) !== 0;
      offset += 1;
    }
    parsed.push({ ink, visible, label, coefficients, radius, shines });
  }

  nimSceneClear();
  // In file order, which from version 3 on is order objects were built: each is.
  //   stamped to appear beat after last, so scene replays its own construction.
  //   Version rides along because older file's palette ordinals mean something
  //   else; mapping is Nim's, not this parser's.
  //   One clock reading for whole arrival, taken before loop: read per item it
  //   would creep forward by however long parsing took, which is stagger nobody chose.
  const arrived = now();
  for (const item of parsed) {
    const slot = nimSceneAddRaw(
      version, item.ink, item.visible, item.label, item.coefficients, item.radius,
      item.shines, count_item, arrived,
    );
    if (slot < 0) throw new Error('File names an unknown palette slot or radius for an object.');
  }
  return 'Loaded ' + count_item + ' object(s) from scene file.';
}

/* ---------------------------------------------------------------------- */
/* Sizes: every CSS size low-cadence tick reads, kept by observer.        */
/* ---------------------------------------------------------------------- */

// **Kept by `ResizeObserver`, never measured inside tick.** `clientWidth` read after
//   tick's own writes forces browser to lay whole document out there and then, inside
//   frame: measured at 0.9 ms of 1.3 ms tick on pool grid. Ruler, curve and
//   sparkline each read theirs same way, after writes tick had just made; that cost
//   is unmeasured on desktop, where layout is cheap, and is only mechanism found for
//   once-second spike phone showed. Observer answers same question for nothing,
//   after layout browser was doing anyway, and fires once when it starts watching.
//   Measured once here, before any frame: observer's first report lands after first
//   frame's own callback, and 0x0 canvas until then would draw nothing.
//   Callback runs after layout, so reads inside it are free.
//   `onResize` is where size's readers ask for their redraw.
//   Without observer size stands as first measured; every browser this build runs in
//   has one, and pool grid already leant on it.
function sizeObserved(element, onResize) {
  const size = { width: 0, height: 0 };
  if (element === null) return size;
  size.width = element.clientWidth;
  size.height = element.clientHeight;
  if (typeof ResizeObserver !== 'function') return size;
  new ResizeObserver(() => {
    size.width = element.clientWidth;
    size.height = element.clientHeight;
    onResize();
  }).observe(element);
  return size;
}
// Canvas's own, read by ruler's tick.
//   Window's resize handler still measures for itself: it runs once per resize event,
//   not five times second.
const size_canvas = sizeObserved(canvas, () => {});

/* ---------------------------------------------------------------------- */
/* Diagnostics: browser-appropriate stand-ins for desktop build's own     */
/* arena/frame-time panel -- see `browser_bridge.nim`'s own doc comment   */
/* for why numbers differ in kind. Drawer states none of this:            */
/* reader opening diagnostics panel wants numbers, not essay.             */
/* ---------------------------------------------------------------------- */

const FRAMES_HISTORY = 240;
const history_frame = new Array(FRAMES_HISTORY).fill(16.6);
let index_history_frame = 0;
let time_frame_last = performance.now();
const sparkline = document.getElementById('sparkline');
const context_sparkline = sparkline.getContext('2d');
const size_sparkline = sizeObserved(sparkline, () => askSlowPass(false, true, false, false));
const diagnostic_frame_time = document.getElementById('diagnostic-frametime');
const diagnostic_slowest = document.getElementById('diagnostic-slowest');
const diagnostic_slowest_split = document.getElementById('diagnostic-slowest-split');
const diagnostic_heap = document.getElementById('diagnostic-heap');
const diagnostic_pool = document.getElementById('diagnostic-pool');
const grid_pool = document.getElementById('pool-grid');
const context_pool = grid_pool === null ? null : grid_pool.getContext('2d');
// Scene revision grid was last drawn at; -1 until it has been drawn once. Grid.
//   is picture of which slots are occupied and in what ink, so it changes exactly when
//   scene does -- see `scene.revision`, same counter frame hold reads. Its own
//   geometry joins key because canvas cleared by resize has to be redrawn whatever
//   scene did, and because section opens onto canvas that had no size at all.
let revision_pool_last = -1;
let ratio_pool_last = 0;
// Redraw owed for canvas's own reasons: resized, or never drawn.
//   Set by observer below, which fires once when it starts watching -- what makes first
//   draw happen.
let is_pool_stale = true;
// What last draw actually chose, for check to read rather than re-derive.
//   derivation is thing being checked, so test that repeated it would agree with
//   itself no matter what reached canvas.
let geometry_pool_drawn = { cell: 0, gap: 0, columns: 0, rows: 0, height: 0 };
// **One square per slot, wrapped**, at largest size that keeps whole grid inside.
//   block rather than page. Cell cannot be constant: at 1,024 slots six pixels with
//   gap is 53 columns of 20 rows and 139px tall, and at 10,080 same cell is 191 rows
//   and over 1,300px -- which is not grid reader scans, it is scroll. So size is
//   chosen against capacity and measured width, largest first, and gap goes
//   before cell does: below four pixels one-pixel gap is half strip.
//   At 10,080 slots in 371px drawer this lands on 2px cells, 185 columns by 55 rows and
//   110px tall -- density map rather than set of squares, which is honest reading at
//   ten thousand.
const CELLS_POOL = [[6, 1], [5, 1], [4, 1], [3, 0], [2, 0], [1, 0]];
const HEIGHT_POOL_MAX = 150;
// CSS colour per packed triple, so palette that cycles is converted dozen times.
//   rather than thousand. Cleared with nothing: palette is fixed, so it converges.
const css_pool = new Map();
// Width last draw laid grid out for; `NaN` before first, equal to nothing.
let width_pool_drawn = NaN;
// Watched in its own box rather than window's:
//   drawer is fixed-width panel on wide screen and full-width sheet on narrow one, and
//   either can change without window doing so. Width alone: draw sets canvas's own
//   height, and observer answering that with second identical draw was 4 ms for nobody.
const size_pool = sizeObserved(grid_pool, () => {
  if (size_pool.width !== width_pool_drawn) is_pool_stale = true;
});

// Keep one ring per step of drawing process.
//   Diagnostics tab can then show where frame actually went rather than one opaque
//   total.
//   Bridge reports its own three phases on FrameData (build = furniture + scene +
//   flatten, timed inside nimBuildFrame where only it can see them); this side times
//   what only it can see: GL upload+draw, SVG overlay, selection menu, and low-cadence
//   UI block.
//   Rings rather than latest value, so each row can show rolling median beside
//   instantaneous number.
//     Single frame's reading flickers too fast to read, and median is what reader means
//     by "how long does this step take".
const PHASES_DIAGNOSTIC = [
  ['build', 'diagnostic-build'], ['camera', 'diagnostic-camera'],
  ['furniture', 'diagnostic-furniture'],
  ['grid', 'diagnostic-grid'], ['axes', 'diagnostic-axes'], ['scene', 'diagnostic-scene'],
  ['points', 'diagnostic-points'], ['lines', 'diagnostic-lines'], ['planes', 'diagnostic-planes'],
  ['sky', 'diagnostic-sky'], ['ghost', 'diagnostic-ghost'], ['selected', 'diagnostic-selected'],
  ['algebra', 'diagnostic-algebra'], ['matrix', 'diagnostic-matrix'],
  ['flatten', 'diagnostic-flatten'],
  ['unaccounted', 'diagnostic-unaccounted'],
  // Second cut, not stages: these re-divide very milliseconds above them.
  ['placing', 'diagnostic-placing'], ['emitting', 'diagnostic-emitting'],
  ['hover', 'diagnostic-hover'], ['upload', 'diagnostic-upload'], ['overlay', 'diagnostic-overlay'],
  ['ui', 'diagnostic-ui'], ['idle', 'diagnostic-idle'],
  // Third cut: browser's main-thread share of `idle`; see `markRendered`.
  ['render', 'diagnostic-render'],
];
// Rows that re-divide time already counted elsewhere. They must stay out of every sum.
//   -- idle derivation below, and cost tint's own denominator -- or frame would
//   appear to have spent its drawing twice.
const PHASES_CUT_DIAGNOSTIC = ['placing', 'emitting', 'render'];
// Name phases nothing else contains.
//   Their sum is everything this page spent on frame, and rest of frame is `idle`
//   below.
//   `build` holds bridge's own three, and those hold scenery halves and object kinds,
//   so counting any of them here would count same milliseconds twice.
const PHASES_TOP_DIAGNOSTIC = ['build', 'hover', 'upload', 'overlay', 'ui'];
// Rows that carry count beside their time, and ring each count is written to.
//   Time alone cannot tell "one of these is expensive" from "there are many of them",
//   which is whole question reader opens this branch to answer.
const COUNTS_DIAGNOSTIC = {
  grid: 'count_grid_segments',
  points: 'count_points', lines: 'count_lines', planes: 'count_planes',
  sky: 'count_sky', ghost: 'count_ghost', selected: 'count_selected',
};
const count_phase = {};
let count_points_culled = 0; // Points skipped this frame for lying outside view.
const history_phase = {};
// **Whether phase ran is kept beside its time, never inside it.** Sentinel in.
//   value's own range was doing that job, and duration has no room for one: every mobile
//   browser coarsens and jitters `performance.now` against timing attacks, so
//   sub-millisecond step can measure as zero or below, and real reading then becomes
//   indistinguishable from "never ran". That is precisely what left every sub-millisecond
//   row of tree em dash on phone while six-millisecond ones read fine.
const written_phase = {};
const element_phase = {};
const element_row = {};
const element_tally = {};
for (const [name, id] of PHASES_DIAGNOSTIC) {
  history_phase[name] = new Float64Array(FRAMES_HISTORY);
  written_phase[name] = new Uint8Array(FRAMES_HISTORY);
  element_phase[name] = document.getElementById(id);
  // Whole row as well as its number, so row can be tinted entire. `closest` rather.
  //   than `parentElement`: leaf's value sits in plain div and parent's in button,
  //   and both carry `.diagnostic-line`.
  element_row[name] = element_phase[name] === null
    ? null : element_phase[name].closest('.diagnostic-line');
  // And slot beside row's own name where its count goes, on rows that have one.
  //   Written into rather than label being rewritten, so label's words stay in
  //   markup and this file never holds second copy of them to keep in step.
  element_tally[name] = element_row[name] === null
    ? null : element_row[name].querySelector('.diagnostic-tally');
}
for (const name in COUNTS_DIAGNOSTIC) count_phase[name] = 0;
function recordPhaseTime(name, delta_milliseconds) {
  // Share frame ring's own index, advanced once per frame by recordFrameTime.
  //   Every ring then lines up frame for frame; UI phase only runs one frame in several
  //   and leaves its other slots unwritten, which readings below skip.
  if (!Number.isFinite(delta_milliseconds)) return; // Nothing measured; leave it absent.
  // Clamped at zero: negative elapsed time is artefact of coarsened clock, not.
  //   duration, and honest reading of it is "too short to measure".
  history_phase[name][index_history_frame] =
    delta_milliseconds > 0 ? delta_milliseconds : 0;
  written_phase[name][index_history_frame] = 1;
}
// Add to phase's slot rather than replace it:
//   `ui` is written more than once per frame -- tick inside frame's callback, glide
//   redraw beside it, slow pass in idle time after it -- all before `recordFrameTime`
//   closes slot at next frame's start, so every one lands in frame it belongs to.
function addPhaseTime(name, delta_milliseconds) {
  if (!Number.isFinite(delta_milliseconds)) return; // Nothing measured; leave it as is.
  const at = index_history_frame;
  const held = written_phase[name][at] === 1 ? history_phase[name][at] : 0;
  history_phase[name][at] = held + (delta_milliseconds > 0 ? delta_milliseconds : 0);
  written_phase[name][at] = 1;
}

// **How long reading is averaged over, and how often it is rewritten.** Single frame's.
//   number changes faster than anyone can read it, which is what made these rows flicker.
//   200 ms is settling time performance readout is conventionally given: long enough
//   that digits hold still, short enough that stall is still on screen while it is
//   happening. Same span governs averaging and refresh, so number shown is
//   number for interval since last one -- not average over one window
//   sampled on cadence of another.
const MILLISECONDS_WINDOW_READING = 200;
// How many frames back that span reaches, measured in frames' own durations rather.
//   than assumed from frame rate: at 60 fps it is dozen, on labouring phone it is
//   two, and either way it is last 200 ms.
function framesRecent() {
  let spanned = 0;
  for (let i = 0; i < FRAMES_HISTORY; i += 1) {
    spanned += history_frame[(index_history_frame + FRAMES_HISTORY - 1 - i) % FRAMES_HISTORY];
    if (spanned >= MILLISECONDS_WINDOW_READING) return i + 1;
  }
  return FRAMES_HISTORY;
}
// Phase's mean over those frames, skipping ones it did not run in. Mean rather.
//   than latest: whole complaint about latest is that one frame decides it.
function meanPhase(name, frames) {
  const ring = history_phase[name];
  const written = written_phase[name];
  let total = 0;
  let count = 0;
  for (let i = 0; i < frames; i += 1) {
    const at = (index_history_frame + FRAMES_HISTORY - 1 - i) % FRAMES_HISTORY;
    if (written[at] === 0) continue;
    total += ring[at];
    count += 1;
  }
  return count === 0 ? null : total / count;
}
// Scratch median borrows rather than allocating: this runs per phase per refresh, and.
//   rows tree can hold grow faster than frames between refreshes do. Filter
//   plus sort built two arrays each time and threw both away.
const scratch_median = new Array(FRAMES_HISTORY);
function medianPhase(name) {
  const ring = history_phase[name];
  const written = written_phase[name];
  let count = 0;
  for (let i = 0; i < FRAMES_HISTORY; i += 1) {
    if (written[i] === 1) { scratch_median[count] = ring[i]; count += 1; }
  }
  if (count === 0) return null;
  // Insertion sort over written part: ring is nearly sorted only by accident, but.
  //   it is small and this beats allocating fresh sorted copy of it every refresh.
  for (let i = 1; i < count; i += 1) {
    const value = scratch_median[i];
    let j = i - 1;
    while (j >= 0 && scratch_median[j] > value) {
      scratch_median[j + 1] = scratch_median[j];
      j -= 1;
    }
    scratch_median[j + 1] = value;
  }
  return scratch_median[count >> 1];
}
// Each row's last median, so 200 ms rows can state one without re-sorting ring that.
//   is four seconds long. Refreshed by `recomputeMedians` on slow pass; `undefined`
//   means never computed, which is not same as `null` -- that is phase which has
//   genuinely never run, and row is left as em dash for it.
const median_phase_last = {};
function medianPhaseHeld(name) {
  // Ask on spot where nothing is held, or what is held says never ran.
  //   Cheap to ask, and row coming alive between slow passes would otherwise stay em
  //   dash for up to second.
  const held = median_phase_last[name];
  if (held === undefined || held === null) median_phase_last[name] = medianPhase(name);
  return median_phase_last[name];
}
// Re-sort every shown row's median from ring. Rows inside closed node keep theirs:
//   nobody is reading them, and each is 240-entry insertion sort.
function recomputeMedians() {
  for (const [name] of PHASES_DIAGNOSTIC) {
    if (isPhaseShown(name)) median_phase_last[name] = medianPhase(name);
  }
}

// Rows that have children, and whether each is open. **Every one starts closed**:
//   reader opens diagnostics panel to see whether frame is slow, and goes looking for
//   which step only once it is. Closed node's rows are skipped by `refreshDiagnostics`
//   entirely, so subtotal nobody is reading costs nothing to keep offering.
//   Nesting is read off markup itself rather than declared here second time:
//   tree's shape used to live in both places, agreeing only by care, and row moved
//   in one without other would silently stop hiding -- or stop updating -- with its
//   branch. DOM is one copy now, and this file only asks it questions.
for (const node of document.querySelectorAll('.diagnostic-node')) {
  // Node's *own* parent row, not descendant's: nested branch puts another.
  //   `.diagnostic-parent` inside this one, and `querySelector` would find that one first.
  const header = node.querySelector(':scope > .diagnostic-parent');
  header.addEventListener('click', () => {
    const is_open = node.classList.toggle('open');
    header.setAttribute('aria-expanded', String(is_open));
  });
  header.setAttribute('aria-expanded', 'false');
}
function isPhaseShown(name) {
  // Walk up: row is shown only where every branch holding it is open. Branch's own.
  //   header row starts walk *above* its node -- header is what reader clicks
  //   to open it, so it stays visible while its node is closed.
  const row = element_row[name];
  if (row === null) return false;
  let node = row.closest('.diagnostic-node');
  if (node !== null && row.classList.contains('diagnostic-parent')) {
    node = node.parentElement.closest('.diagnostic-node');
  }
  while (node !== null) {
    if (!node.classList.contains('open')) return false;
    node = node.parentElement.closest('.diagnostic-node');
  }
  return true;
}

// **How often frame runs long, over window long enough to answer that.**
//   sparkline holds four seconds and shows *when*; reader chasing stall that happens
//   once minute needs *how often*, which is distribution rather than trace. Kept as
//   rolling window of last `FRAMES_EXCEEDANCE` frames -- about seventeen seconds at
//   60 fps, which is long enough to hold stall and short enough that one ages out again
//   rather than flattening chart for minute -- summarised as share of them at or
//   over each duration.
//   Window is ring of samples *and* histogram of same samples, maintained
//   together: frame entering increments its bucket, frame it evicts decrements
//   one it was in. That keeps per-frame cost couple of array writes -- this runs on
//   every frame, including ones being measured -- and leaves curve single
//   suffix scan over buckets, done only when panel is actually open.
const FRAMES_EXCEEDANCE = 1024;
const MILLISECONDS_BUCKET = 0.5; // Fine enough to separate 16.7 ms frame from 17.2.
// **Slowest budget chart marks**, in frames per second, and reach of.
//   histogram folded from it. Two have to agree or mark is unreachable: axis
//   only ever runs as far as slowest bucket holding frame, so mark past last
//   bucket is skipped by `drawExceedance` on every draw and simply never appears. Adding
//   1 fps line to `BUDGETS_EXCEEDANCE` alone did exactly that, silently, against
//   histogram that stopped at 128 ms. Folded here so next mark cannot repeat it.
//   Extra bucket is what puts mark *inside* reachable range rather than exactly
//   at its edge.
const RATE_BUDGET_SLOWEST = 1;
const BUCKETS_EXCEEDANCE =
  Math.ceil((1000 / RATE_BUDGET_SLOWEST) / MILLISECONDS_BUCKET) + 1;
const history_exceedance = new Float32Array(FRAMES_EXCEEDANCE);
const buckets_exceedance = new Int32Array(BUCKETS_EXCEEDANCE);
let index_exceedance = 0;
let count_exceedance = 0; // Rises to window's own size, then stays there.
const exceedance = document.getElementById('exceedance');
const context_exceedance = exceedance === null ? null : exceedance.getContext('2d');
const size_exceedance = sizeObserved(exceedance, () => askSlowPass(true, false, false, false));
const diagnostic_exceedance = document.getElementById('diagnostic-exceedance');
const label_exceedance_axis = document.getElementById('diagnostic-exceedance-axis');
// Vertical axis's own switch, wired here rather than beside header's chips because.
//   it reads chart it belongs to. Linear by default: chart exists to say what share
//   of session ran at each speed, and proportion reads as proportion on linear
//   axis. Log answers narrower question -- how bad slowest one percent is, which
//   linear squeezes flat against ceiling -- so it is offered rather than assumed.
const toggle_exceedance_log = document.getElementById('toggle-exceedance-log');
let is_exceedance_log = false;
if (toggle_exceedance_log !== null) {
  toggle_exceedance_log.addEventListener('click', (e) => {
    is_exceedance_log = !is_exceedance_log;
    e.target.classList.toggle('on', is_exceedance_log);
    // Redrawn on spot rather than at diagnostics panel's own six-frame cadence:
    //   switch that answers sixth of second late reads as one that did not work.
    drawExceedance();
  });
}

function bucketOf(milliseconds) {
  const index = Math.floor(milliseconds / MILLISECONDS_BUCKET);
  // Anything past last bucket lands *in* it rather than being dropped: 300 ms stall.
  //   is most important sample window ever holds, and curve that discarded it
  //   would read as calmer than session actually was.
  return Math.max(0, Math.min(BUCKETS_EXCEEDANCE - 1, index));
}

function recordExceedance(delta_milliseconds) {
  if (count_exceedance === FRAMES_EXCEEDANCE) {
    buckets_exceedance[bucketOf(history_exceedance[index_exceedance])] -= 1;
  } else {
    count_exceedance += 1;
  }
  history_exceedance[index_exceedance] = delta_milliseconds;
  buckets_exceedance[bucketOf(delta_milliseconds)] += 1;
  index_exceedance = (index_exceedance + 1) % FRAMES_EXCEEDANCE;
}

// Complementary distribution, as share of window per bucket, scanned from.
//   slow end so each entry is "this many frames took at least this long". Written into
//   buffer caller owns so scan allocates nothing on path that runs ten times
//   second; returns how much of it is meaningful.
const shares_exceedance = new Float64Array(BUCKETS_EXCEEDANCE);
function scanExceedance() {
  let running = 0;
  for (let i = BUCKETS_EXCEEDANCE - 1; i >= 0; i -= 1) {
    running += buckets_exceedance[i];
    shares_exceedance[i] = count_exceedance === 0 ? 0 : running / count_exceedance;
  }
  return count_exceedance;
}

function recordFrameTime(delta_milliseconds) {
  history_frame[index_history_frame] = delta_milliseconds;
  // **Everything page did not spend itself**: waiting on display, and browser's.
  //   own style, layout, paint, compositing and collection. Without it breakdown
  //   accounted for fraction of frame and left rest unexplained, so spike could
  //   not be told from stall in page's own code -- which is first question
  //   reader has. Computed here because this is one moment frame's duration and its
  //   own phases sit in same slot: delta written just above measures frame
  //   whose phases were recorded into this index, and advance below moves past both.
  let spent = 0;
  for (const name of PHASES_TOP_DIAGNOSTIC) {
    if (written_phase[name][index_history_frame] === 1) {
      spent += history_phase[name][index_history_frame];
    }
  }
  recordPhaseTime('idle', delta_milliseconds - spent);
  recordExceedance(delta_milliseconds);
  index_history_frame = (index_history_frame + 1) % FRAMES_HISTORY;
  // Clear slot phases are about to write into, up front.
  //   Phase that does not run this frame (UI block, held furniture build) then reads as
  //   absent rather than as whatever it cost one ring ago.
  for (const [name] of PHASES_DIAGNOSTIC) written_phase[name][index_history_frame] = 0;
}

// How far log axis runs, when reader switches to it: decades from every frame down.
//   to one in thousand, which is as fine as window of thousand frames can resolve.
const DECADES_EXCEEDANCE = 3;
// **Axis follows window, but never closes below slowest budget plus room to.
//   name it.** Fitting it to slowest frame is what makes max readable -- curve
//   reaches 100% exactly there -- and floor is what stops fast session zooming into
//   its own noise: at 30 fps and better axis stands still and budget lines keep
//   their places, so two readings of healthy session compare directly. It is bands
//   that made this affordable: axis that moves is legible when colours and
//   labelled lines say where budgets are regardless of how far it runs.
//   Stated as share of axis slowest labelled mark stands at, not as that
//   mark's own duration. At exactly `1000 / 30` 30 fps line landed on right edge:
//   half pixel outside canvas, and its label flipped to cramped inside-left
//   branch below, alone among marks in reading right to left. Margin has to be
//   share because canvas is responsive -- fixed number of milliseconds buys
//   different number of pixels at every drawer width -- and 14% clears label's own
//   14px threshold down to about 110px canvas.
// What label is haloed against where curve runs through it: drawer's own solid.
//   surface, which is what shows through this canvas, at most of full strength -- enough to
//   part curve around digits, little enough that it reads as ground rather than
//   as box drawn behind them.
const HALO_LABEL_EXCEEDANCE = 'rgba(22, 27, 34, 0.85)';
const SHARE_MARK_LEAST = 0.86;
const MILLISECONDS_AXIS_LEAST = (1000 / 30) / SHARE_MARK_LEAST;
// Frame budgets reader actually aims at, each named by rate it is: duration.
//   means nothing to most people and "60" means something to everyone.
//   This list is both marks and colour bands: `bandOfExceedance` indexes it and
//   `colours_exceedance` maps over it. 15 fps entry therefore carries *poor band's
//   own token* on purpose -- it is mark reader asked for, not fifth band. Anything
//   past 33.3 ms is poor whichever side of 66.7 it falls, so curve merely splits into
//   two runs there and strokes them same colour. **Do not tidy repeated token
//   away**: dropping it would either lose mark or invent band. 1 fps entry below is
//   same case second time, and is there for same reason: loading largest size
//   is frame of *seconds*, and chart whose slowest mark is 66.7 ms cannot say how bad
//   that is -- it can only say "past the end". Mark at 1,000 ms gives spike ruler.
//   Its own consequence, stated rather than discovered: window holding one-second frame
//   stretches axis until 8.3, 16.7 and 33.3 crowd into its leftmost tenth. That is
//   self-limiting, since axis eases back as spike ages out of 1,024-frame
//   window, and it is honest picture of window that really did hold such frame.
//   10 and 5 fps marks fill stretch between 15 and 1, which is where labouring
//   frame actually lands and where axis otherwise ran decade unlabelled. They need no
//   room histogram does not already have: at 100 ms and 200 ms they sit well inside
//   reach `RATE_BUDGET_SLOWEST` folds. **Kept in ascending order of duration** --
//   `bandOfExceedance` returns first entry reading falls under, so entry out of
//   order would silently mis-band every frame past it.
const BUDGETS_EXCEEDANCE = [
  { milliseconds: 1000 / 120, label: '120', token: '--speed-fast' },
  { milliseconds: 1000 / 60, label: '60', token: '--speed-good' },
  { milliseconds: 1000 / 30, label: '30', token: '--speed-fair' },
  { milliseconds: 1000 / 15, label: '15', token: '--speed-poor' },
  { milliseconds: 1000 / 10, label: '10', token: '--speed-poor' },
  { milliseconds: 1000 / 5, label: '5', token: '--speed-poor' },
  { milliseconds: 1000 / RATE_BUDGET_SLOWEST, label: String(RATE_BUDGET_SLOWEST),
    token: '--speed-poor' },
  { milliseconds: Infinity, label: '', token: '--speed-poor' },
];
// Read once from stylesheet, which is where they are set and tuned; see tokens'.
//   own comment in `shell.html` for how four were screened.
// Resolved once, like colours below: this is redrawn at frame rate while axis.
//   glides, and each draw was asking layout for same font token.
const FONT_EXCEEDANCE = '9px ' +
  (getComputedStyle(document.documentElement).getPropertyValue('--mono').trim() ||
    'monospace');
const colours_exceedance = BUDGETS_EXCEEDANCE.map((budget) =>
  getComputedStyle(document.documentElement).getPropertyValue(budget.token).trim() ||
    '#00a7a5');
// **Which timing rows are expensive, said in colour.** Twenty-odd numbers down drawer,
//   and nothing in them says which one to look at. Each row's colour answers one question
//   -- what fraction of this frame went here -- read continuously off CET-I1.
//   **Denominator is whole frame, idle included, and ramp spans all of it.**
//   row is drawn at fraction it actually occupies, so scale is absolute: tenth of
//   fast frame and tenth of slow one wear same colour, and curve above says
//   which of two session is in. Shares nest correctly, parent's being sum
//   of its children's, and they sum with `idle` to whole ramp.
// **Where ramp reaches its far end**:
//   row costing this share of frame is drawn in map's last colour.
//   At whole frame far end means step that *is* frame.
const SHARE_RAMP_FULL_DIAGNOSTIC = 1.0;
// **Ramp is walked by ratio, not by difference.** Laid out linearly over whole.
//   frame, every row on comfortable session lands in first two steps and tree
//   reads as one colour: page waiting on display spends most of frame idle, so
//   drawing's own rows are all small fractions and interesting differences between them
//   -- one row ten times another -- are differences far end of scale cannot show.
//   Measured that way at 28.8 ms: costliest row at 12.7% and floor at 0.3% sat 30
//   units of blue apart out of ramp's 131, and rows between them were one colour.
//   On this scale **equal distance along ramp is equal ratio of cost**, which is
//   comparison reader is actually making, and spread no longer depends on whether
//   frame happened to be busy.
//   Knee is where scale stops being logarithmic and goes linear, so row costing
//   nothing has somewhere to sit -- log has no zero. Hundredth of frame is
//   choice: below it row is not one to look at whatever it sits next to.
//   **symlog** proper, linear under knee and logarithmic over it, rather than
//   `log1p` that smooths join. `log1p` is only asymptotically logarithmic, so its
//   decades are not equal -- measured, decade above knee spanned 0.37 of ramp
//   where top one spanned 0.48 -- and equal-ratio-equal-distance promise above is
//   whole point. Seam costs kink in rate at knee and buys exactness.
//   Linear toe is worth **one decade of ramp**, usual convention, which makes
//   whole scale legible as sentence: below hundredth of frame, then hundredth to
//   tenth, then tenth to all of it -- third of ramp each.
const SHARE_RAMP_KNEE_DIAGNOSTIC = 0.01;
const DECADES_RAMP_TREE = Math.log10(SHARE_RAMP_FULL_DIAGNOSTIC / SHARE_RAMP_KNEE_DIAGNOSTIC);
const UNITS_RAMP_TREE = DECADES_RAMP_TREE + 1; // Decades, plus toe's own decade.
function positionRampTree(share) {
  // Where share falls along ramp, from nothing at 0 to all of it at whole frame.
  const held = Math.min(Math.max(share, 0), SHARE_RAMP_FULL_DIAGNOSTIC);
  if (held <= SHARE_RAMP_KNEE_DIAGNOSTIC) {
    return held / SHARE_RAMP_KNEE_DIAGNOSTIC / UNITS_RAMP_TREE;
  }
  return (1 + Math.log10(held / SHARE_RAMP_KNEE_DIAGNOSTIC)) / UNITS_RAMP_TREE;
}
// Tree's ramp, from `ramp.nim` through `nimRampTree`:
//   six floats step, row's label rgb then its value rgb.
//   What ramp is -- CET-I1 re-lit to this drawer's own text tones -- and what holds it to that is
//   `tools/check_ramp.nim`; nothing here knows anything about it beyond how to walk it.
const RAMP_TREE = (() => {
  const flat = nimRampTree();
  const steps = [];
  for (let at = 0; at < flat.length; at += 6) {
    steps.push({
      label: [flat[at], flat[at + 1], flat[at + 2]],
      value: [flat[at + 3], flat[at + 4], flat[at + 5]],
    });
  }
  return steps;
})();

// Legend bar is ramp **as rows are actually tinted**:
//   across its width sits share, not ramp position, so colours crowd into its left exactly as they
//   do down tree and reader can lay row's colour against it and read share off.
//   Painted by calling same function rows are tinted by, so key that disagreed with tree would have
//   to be bug in one line rather than second declaration left behind.
const STOPS_LEGEND_RAMP = 48;
(() => {
  const bar = document.getElementById('diagnostic-legend-ramp');
  if (bar === null) return;
  const stops = [];
  for (let i = 0; i <= STOPS_LEGEND_RAMP; i += 1) {
    const share = i / STOPS_LEGEND_RAMP;
    stops.push(`${rampTreeAt(share).label} ${(share * 100).toFixed(1)}%`);
  }
  bar.style.background = `linear-gradient(to right, ${stops.join(', ')})`;
})();

function rampTreeAt(share) {
  // Sample ramp at one row's share of frame, interpolating between shipped.
  //   steps so row's colour moves as its cost does rather than stepping between bands.
  //   `check_ramp` measures what interpolating costs against map's full 256 entries.
  const position = positionRampTree(share) * (RAMP_TREE.length - 1);
  const below = Math.min(Math.floor(position), RAMP_TREE.length - 2);
  const fraction = position - below;
  const mix = (first, second) => rgbToCss([0, 1, 2].map(
    (channel) => first[channel] * (1 - fraction) + second[channel] * fraction));
  return {
    label: mix(RAMP_TREE[below].label, RAMP_TREE[below + 1].label),
    value: mix(RAMP_TREE[below].value, RAMP_TREE[below + 1].value),
  };
}
// **Axis follows window, but not at window's own speed.** Fitted frame for.
//   frame it snapped: one slow frame widened it, and moment that frame aged out of
//   window it snapped back, so curve jumped about and two glances second apart could
//   not be compared. Two things fix that without going back to fixed axis.
//   *Wait before anything moves.* Extent that differs from what is drawn starts
//   clock, and only difference that stands for `MILLISECONDS_AXIS_WAIT` moves axis at
//   all -- so window that dips and comes back, which is what ageing spike does, leaves
//   axis exactly where it was rather than travelling out and back.
//   *Then glide, not jump.* Exponential ease toward extent, on time constant
//   rather than step count, so it runs at same speed however often it is drawn.
//   Deadband is proportional: half millisecond matters on 33 ms axis and is noise
//   on 130 ms one.
const MILLISECONDS_AXIS_WAIT = 400;
const MILLISECONDS_AXIS_EASE = 420;
const SHARE_AXIS_DEADBAND = 0.02;
let milliseconds_axis = 0; // What is drawn; zero until first extent arrives.
let ms_axis_restless = 0; // When extent first differed from it; zero while settled.
let ms_axis_eased = 0; // Last ease, for elapsed time glide is scaled by.
// True while axis is still travelling, so frame loop can redraw curve at its.
//   own rate instead of panel's five-a-second, which would show glide as steps.
let is_axis_gliding = false;
function axisEased(milliseconds_wanted) {
  const now = performance.now();
  const since = ms_axis_eased === 0 ? 0 : now - ms_axis_eased;
  ms_axis_eased = now;
  // First extent is simply adopted: there is nothing to ease from.
  if (milliseconds_axis === 0) milliseconds_axis = milliseconds_wanted;
  const apart = Math.abs(milliseconds_wanted - milliseconds_axis);
  if (apart <= SHARE_AXIS_DEADBAND * milliseconds_axis) {
    ms_axis_restless = 0; // Settled: clock only runs while two are apart.
    is_axis_gliding = false;
    return milliseconds_axis;
  }
  if (ms_axis_restless === 0) ms_axis_restless = now;
  if (now - ms_axis_restless < MILLISECONDS_AXIS_WAIT) {
    is_axis_gliding = false;
    return milliseconds_axis; // Still inside wait; extent may yet come back.
  }
  is_axis_gliding = true;
  milliseconds_axis +=
    (milliseconds_wanted - milliseconds_axis) * (1 - Math.exp(-since / MILLISECONDS_AXIS_EASE));
  return milliseconds_axis;
}
function spanExceedance() {
  // Window's own bounds, in buckets: fastest frame it holds and slowest.
  //   curve is drawn between exactly these, so it leaves 0% at one and reaches 100% at
  //   other instead of running flat along both edges -- which is what makes two of them
  //   readable rather than merely present. Both extremes are window's own: lone
  //   collection pause belongs on chart of what session actually did, and it is
  //   axis's easing, not trim, that stops one deciding how rest is drawn.
  //   Read by curve alone now: timing rows below it used to be capped at worst
  //   band this reported, which tree's own absolute ramp made unnecessary.
  let first = -1;
  let last = 0;
  for (let i = 0; i < BUCKETS_EXCEEDANCE; i += 1) {
    if (buckets_exceedance[i] === 0) continue;
    if (first < 0) first = i;
    last = i;
  }
  return { first, last };
}

function bandOfExceedance(milliseconds) {
  for (let i = 0; i < BUDGETS_EXCEEDANCE.length; i += 1) {
    if (milliseconds < BUDGETS_EXCEEDANCE[i].milliseconds) return i;
  }
  return BUDGETS_EXCEEDANCE.length - 1;
}
// Axis layer of exceedance curve: rules, marks and their labels, cached between draws.
//   Same size as curve's canvas; `drawExceedance` composites it under curve.
const axis_exceedance = document.createElement('canvas');
const context_axis_exceedance = axis_exceedance.getContext('2d');
let key_axis_exceedance = ''; // Size, extent and mode layer was drawn for; empty before first.

function drawAxisExceedance(context, w, h, milliseconds_full, xOf, yOf) {
  if (axis_exceedance.width !== w) axis_exceedance.width = w;
  if (axis_exceedance.height !== h) axis_exceedance.height = h;
  context.clearRect(0, 0, w, h);
  context.font = FONT_EXCEEDANCE;
  context.textBaseline = 'top';
  // Recessive rules at heights axis actually resolves, each named except floor.
  //   Linear takes quarter at time up to 100%, which is what curve's own arrival is
  //   read against. Log takes decades instead, up to 99.9% its three decades
  //   actually reach -- ceiling is whole reason to switch to it, so it is last
  //   thing that should go unnamed. **Neither names 0%**: it is where every curve starts,
  //   so label states what shape already says, and at very bottom of canvas
  //   it has nowhere to sit that is not either off plot or on top of label above.
  const gridlines = is_exceedance_log
    ? [{ share: 0 }, { share: 0.9, label: '90%' }, { share: 0.99, label: '99%' },
      { share: 0.999, label: '99.9%' }]
    : [{ share: 0 }, { share: 0.25, label: '25%' }, { share: 0.5, label: '50%' },
      { share: 0.75, label: '75%' }, { share: 1, label: '100%' }];
  context.strokeStyle = 'rgba(139, 150, 163, 0.18)';
  context.lineWidth = 1;
  for (const gridline of gridlines) {
    // Held half-pixel inside canvas at two ends, where line would otherwise.
    //   straddle edge and render at half its weight or not at all.
    const y = Math.min(h - 0.5, Math.max(0.5, Math.round(yOf(gridline.share)) + 0.5));
    context.beginPath();
    context.moveTo(0, y);
    context.lineTo(w, y);
    context.stroke();
    if (gridline.label === undefined) continue;
    // Under its own line and at left margin, which rates along top and.
    //   curve's own climb both leave clear.
    context.fillStyle = 'rgba(139, 150, 163, 0.75)';
    context.fillText(gridline.label, 2, y + 1);
  }
  // Budgets themselves, **each named twice**: rate at top of line and.
  //   duration at its foot, so one dashed mark answers both "how smooth is that" and "how
  //   long is that" and reader never has to convert between them in their head.
  //   Both sit *over* plot rather than in rows of their own. Rows were tried, and they
  //   do buy clearance -- curve reaches 100% in top right, under slowest mark's
  //   label, and 0% in bottom left, under fastest mark's duration -- but they cost
  //   22px of drawer that has none to spare, and number reader can find beside its
  //   own line is worth more than guarantee it is never crossed. Labels are drawn
  //   before curve, so where two meet it is curve that reads as continuous.
  //   Drawn only where axis actually reaches them: window with nothing slower than
  //   120 fps in it has no business drawing others, and 15 fps mark stays away
  //   until window holds frame that slow. Floor is set so slowest mark
  //   axis is guaranteed to reach -- 30 fps -- stands clear of right edge with room
  //   for its own labels; see `SHARE_MARK_LEAST`.
  context.setLineDash([2, 3]);
  for (const budget of BUDGETS_EXCEEDANCE) {
    if (!Number.isFinite(budget.milliseconds)) continue;
    if (budget.milliseconds > milliseconds_full) continue;
    const x = Math.round(xOf(budget.milliseconds)) + 0.5;
    context.strokeStyle = 'rgba(139, 150, 163, 0.30)';
    context.beginPath();
    context.moveTo(x, 0);
    context.lineTo(x, h);
    context.stroke();
    context.fillStyle = 'rgba(139, 150, 163, 0.75)';
    // Inside line where it would otherwise run off right edge. Both rows take.
    //   same side, so rate and its duration stay in one column whichever way they go.
    const is_room = x + 14 < w;
    context.textAlign = is_room ? 'left' : 'right';
    const x_label = x + (is_room ? 2 : -2);
    // Haloed against drawer's own surface before being filled. These sit over plot.
    //   and curve crosses fastest ones outright -- duration bisected by stroke
    //   of same weight is unreadable, and this is what buys numbers their place
    //   inside without asking chart for height it does not have.
    const write = (text, y, baseline) => {
      context.textBaseline = baseline;
      context.strokeStyle = HALO_LABEL_EXCEEDANCE;
      context.lineWidth = 3;
      context.setLineDash([]);
      context.strokeText(text, x_label, y);
      context.fillText(text, x_label, y);
      context.lineWidth = 1;
      context.setLineDash([2, 3]);
    };
    write(budget.label, 1, 'top');
    write(budget.milliseconds.toFixed(1), h - 1, 'bottom');
  }
  context.setLineDash([]);
  context.textAlign = 'left';
  context.textBaseline = 'top';
}

function drawExceedance() {
  if (context_exceedance === null) return;
  // Observer's size, not canvas's own; see `sizeObserved`.
  //   Fallback stands for canvas without layout, as inside shut section; checks drawing
  //   with drawer shut lean on it.
  const w = size_exceedance.width || 300, h = size_exceedance.height || 74;
  if (exceedance.width !== w) exceedance.width = w;
  if (exceedance.height !== h) exceedance.height = h;
  context_exceedance.clearRect(0, 0, w, h);
  const counted = scanExceedance();
  if (counted === 0) return;

  const { first: bucket_first, last: bucket_last } = spanExceedance();
  if (bucket_first < 0) return;
  const milliseconds_full = axisEased(
    Math.max(MILLISECONDS_AXIS_LEAST, (bucket_last + 1) * MILLISECONDS_BUCKET),
  );
  const xOf = (milliseconds) => (milliseconds / milliseconds_full) * w;
  // Proportion **below**, rising: question reader is asking is how much of.
  //   session came in under duration, and curve that answers it climbing left to right
  //   is read without translation.
  //   Linear, where axis is proportion itself; or, on switch, three decades of
  //   distance from top -- share still at or over -- which is only way
  //   slowest one percent is legible at all, since linear squeezes it flat against
  //   ceiling for last third of chart.
  const yOf = is_exceedance_log
    ? (share_below) => {
        const share_over = Math.max(1 - share_below, Math.pow(10, -DECADES_EXCEEDANCE));
        return h * (1 + Math.log10(share_over) / DECADES_EXCEEDANCE);
      }
    : (share_below) => h - share_below * h;

  // Rules, marks and labels come off cached layer, redrawn only where axis moved.
  //   Some thirty text operations, each haloed, were most of what drawing curve cost, for
  //   axis that changes only while it glides; figures in `PROVENANCE.md`.
  const key_axis =
    w + 'x' + h + '@' + milliseconds_full.toFixed(3) + (is_exceedance_log ? 'L' : 'l');
  if (key_axis !== key_axis_exceedance) {
    key_axis_exceedance = key_axis;
    drawAxisExceedance(context_axis_exceedance, w, h, milliseconds_full, xOf, yOf);
  }
  context_exceedance.drawImage(axis_exceedance, 0, 0);
  context_exceedance.textAlign = 'left';
  context_exceedance.textBaseline = 'top';

  // Curve, in one run per band, each stroked in that band's own colour and each.
  //   starting where last ended so line is continuous across change. Drawn
  //   band by band rather than sampling colour per segment: run is one path and one
  //   stroke, and join at boundary is exact rather than pixel of wrong hue.
  context_exceedance.lineWidth = 1.5;
  let band_open = -1;
  for (let i = bucket_first; i <= bucket_last; i += 1) {
    const milliseconds = i * MILLISECONDS_BUCKET;
    const band = bandOfExceedance(milliseconds);
    // `shares_exceedance[i]` is share at or over this duration, so its complement is.
    //   share below it -- histogram stays exceedance and only drawing turns
    //   over, which is what keeps scan plain suffix sum.
    const point = [xOf(milliseconds), yOf(1 - shares_exceedance[i])];
    if (band !== band_open) {
      if (band_open >= 0) {
        // Carry run into boundary before closing it, so two runs meet on.
        //   dashed line rather than bucket short of it.
        context_exceedance.lineTo(point[0], point[1]);
        context_exceedance.stroke();
      }
      context_exceedance.beginPath();
      context_exceedance.moveTo(point[0], point[1]);
      context_exceedance.strokeStyle = colours_exceedance[band];
      band_open = band;
    } else {
      context_exceedance.lineTo(point[0], point[1]);
    }
  }
  // Last bucket's own upper edge, where share below reaches one: slowest frame.
  //   window holds, standing at 100% and at axis's own end.
  context_exceedance.lineTo(xOf((bucket_last + 1) * MILLISECONDS_BUCKET), yOf(1));
  if (band_open >= 0) context_exceedance.stroke();

  // One number worth stating outright beside curve: what slowest frame in.
  //   hundred took. Reader tuning for smoothness is tuning that, not median.
  let milliseconds_p99 = 0;
  for (let i = BUCKETS_EXCEEDANCE - 1; i >= 0; i -= 1) {
    if (shares_exceedance[i] >= 0.01) { milliseconds_p99 = i * MILLISECONDS_BUCKET; break; }
  }
  writeText(diagnostic_exceedance,
    '1 in 100: ' + milliseconds_p99.toFixed(1) + ' ms \u00b7 ' + counted + ' frames');
  // Axis's own extent, said where reader is looking rather than left to be.
  //   inferred from curve that now moves with window.
  if (label_exceedance_axis !== null) {
    // Mode is named in caption as well as lit on its own pill, so screenshot of.
    //   drawer says which axis curve in it was read against.
    writeText(label_exceedance_axis,
      'frames under \u00b7 0\u2013' + milliseconds_full.toFixed(0) + ' ms' +
      (is_exceedance_log ? ' \u00b7 log' : ''));
  }
}

// Scale bar's own reading, as map carries one: span of ground drawn at its true.
//   screen length, with distance it covers written under it, and **ground grid's
//   own cell size beside that** -- which is what makes ruled ground measurable rather
//   than decorative. Span is chosen 1-2-5 by decade to land near
//   `PIXELS_RULER_TARGET`, way every map scale is stepped: bar tied rigidly to one
//   cell runs off screen when camera is close and shrinks to nothing when it is
//   far, because cell steps by decades while projection does not.
//   Cell comes from `nimGridMetrics`, which reads same `mesh.sizeCellGridAt`
//   grid is laid with; nothing here re-derives cell size of its own.
const ruler = document.getElementById('ruler');
const ruler_bar = document.getElementById('ruler-bar');
const ruler_label = document.getElementById('ruler-label');
const PIXELS_RULER_TARGET = 130;
const STEPS_RULER = [1, 2, 5];
// Reading bar was last laid out for, so still ground formats and writes nothing.
//   Both `NaN` before first tick: equal to nothing, so first comparison always writes.
let cell_ruler_written = NaN;
let scale_ruler_written = NaN;
function refreshRuler() {
  if (ruler === null) return;
  // Observer's size, not canvas's own; see `sizeObserved`.
  const metrics = nimGridMetrics(size_canvas.width, size_canvas.height);
  const size_cell = metrics[0], world_per_pixel = metrics[1];
  if (size_cell === cell_ruler_written && world_per_pixel === scale_ruler_written) return;
  cell_ruler_written = size_cell;
  scale_ruler_written = world_per_pixel;
  // No ground drawn -- eye above fog's own reach -- so there is nothing to measure.
  if (!(size_cell > 0) || !(world_per_pixel > 0)) { ruler.hidden = true; return; }
  const world_target = PIXELS_RULER_TARGET * world_per_pixel;
  const decade = Math.pow(10, Math.floor(Math.log10(world_target)));
  let span = decade;
  for (const step of STEPS_RULER) {
    // Largest 1-2-5 step still at or under target: bar that overshoots crowds.
    //   corner it sits in, while one that undershoots is only harder to read against.
    if (step * decade <= world_target) span = step * decade;
  }
  ruler.hidden = false;
  ruler_bar.style.width = (span / world_per_pixel).toFixed(1) + 'px';
  // Thousands separated with thin space rather than comma: comma reads as decimal.
  //   point to much of world, and these numbers are what bar is claiming.
  const written = (value) => (value >= 1000
    ? value.toLocaleString('en-US').replace(/,/g, '\u2009')
    : String(Number(value.toPrecision(3))));
  ruler_label.textContent = span === size_cell
    ? written(span) + ' units, one grid cell'
    : written(span) + ' units \u00b7 grid ' + written(size_cell);
}

// **Write only where value moved.** Every one of these is text node or inline.
//   style browser must re-style and re-lay out afterwards, and measured on full tree
//   only about **10 of 29 rows actually change** -- so two thirds of writes were
//   dirtying layout to set string that was already there. Same rule pool strip
//   and objects list already follow, at grain of single element.
//   `WeakMap` rather than table keyed by row name: row's element can be replaced, and
//   stale entry keyed by name would then suppress first write to its successor.
const text_written = new WeakMap();
const colour_written = new WeakMap();

function writeText(element, value) {
  if (element === null || element === undefined) return;
  if (text_written.get(element) === value) return;
  text_written.set(element, value);
  element.textContent = value;
}

function writeColour(element, value) {
  if (element === null || element === undefined) return;
  if (colour_written.get(element) === value) return;
  colour_written.set(element, value);
  element.style.color = value;
}

// Panel's own collapsible section, read by guard below rather than by class on.
//   drawer: drawer holds several sections and only this one owns these figures.
const section_diagnostics = document.querySelector('.section[data-section="diagnostics"]');
// Report whether figures are on screen at all: drawer open, and section open inside it.
function isDiagnosticsShown() {
  return drawer.classList.contains('open') && section_diagnostics.classList.contains('open');
}

// **Figures are redrawn on cadence of window they are averaged over, not on panel's.**
//   Rows are 200 ms readings and belong at 200 ms. Sparkline holds four seconds, ring
//   medians four, exceedance curve seventeen, and pool grid changes with scene: none
//   can visibly change in fifth of second, and redrawing them at that rate was single
//   most expensive thing page did -- 0.31 ms for curve and 0.27 for medians out of
//   1.17 ms tick. Not slower still: second is longest reader will watch curve without
//   deciding it has stopped, and sparkline has to scroll rather than jump.
//   One job per tick rather than three on one: three together made one tick in five
//   cost three to four times its neighbours, spike reader saw once second on
//   `ui refresh`. Jobs run off frame besides -- see `askSlowPass` -- and each is
//   still kept short for idle window it runs in.
//   Every job runs on first tick after section is shown, so panel never opens half
//   drawn.
const TICKS_DISTRIBUTION = 5; // Five 200 ms ticks is window's own second.
const TICK_CURVE = 0;
const TICK_SPARKLINE = 2;
const TICK_MEDIANS = 4;
let ticks_diagnostics = 0; // Ticks since section was shown, driving rota above.
let is_diagnostics_shown_last = false; // Whether last tick found section open.

// **Slow pass runs in idle time, off frame.** Tick only asks; `runSlowPass` draws.
//   Curve, sparkline, medians and pool grid are drawn in `requestIdleCallback`, between
//   one frame's callback and next, where page was waiting on display anyway. Its
//   clock reads go into same frame's `ui` reading through `addPhaseTime`, so row
//   still states everything panel cost -- on frame's path or off it -- and frame-time
//   row above it is what says whether frame stalled.
//   Timeout is one reading window: browser finding no idle time still draws figure
//   within 200 ms rather than never.
//   `setTimeout` where idle callbacks are missing: still task of its own, off frame's
//   callback, only without browser's word that frame had slack.
const MILLISECONDS_SLOW_PASS_LATEST = MILLISECONDS_WINDOW_READING;
const scheduleIdle = typeof requestIdleCallback === 'function'
  ? (job) => { requestIdleCallback(job, { timeout: MILLISECONDS_SLOW_PASS_LATEST }); }
  : (job) => { setTimeout(job, 0); };
// Jobs of slow pass, in order pass runs them.
const JOBS_SLOW_PASS = {
  curve: () => drawExceedance(),
  sparkline: () => drawSparkline(),
  medians: () => recomputeMedians(),
  pool: () => drawPoolGrid(nimSceneCount(), nimSceneCapacity()),
};
// Jobs owed, each once however many ticks asked before pass ran.
const due_slow_pass = { curve: false, sparkline: false, medians: false, pool: false };
// What each job cost last time, weighed against idle period's remaining time.
//   2 ms before first run: first draws measured 2.6 and 6.1 ms on desktop, so first
//   period is asked for room rather than assumed to have it.
const ms_job_slow_pass = { curve: 2, sparkline: 2, medians: 2, pool: 2 };
let is_slow_pass_scheduled = false;
function askSlowPass(is_curve, is_sparkline, is_medians, is_pool) {
  if (is_curve) due_slow_pass.curve = true;
  if (is_sparkline) due_slow_pass.sparkline = true;
  if (is_medians) due_slow_pass.medians = true;
  if (is_pool) due_slow_pass.pool = true;
  if (is_slow_pass_scheduled) return;
  is_slow_pass_scheduled = true;
  scheduleIdle(runSlowPass);
}
function runSlowPass(deadline) {
  is_slow_pass_scheduled = false;
  const ms_before = performance.now();
  // Section shut since ask: owed jobs are dropped.
  //   First tick after it is shown again asks for all of them.
  const is_shown = isDiagnosticsShown();
  // Callback without deadline, or past its timeout, runs every job:
  //   `setTimeout` fallback has no deadline, and timeout promised figure within window,
  //   whatever frame is doing.
  const is_hurried = deadline === undefined || deadline.didTimeout;
  let is_owed = false;
  for (const name in JOBS_SLOW_PASS) {
    if (!due_slow_pass[name]) continue;
    if (!is_shown) { due_slow_pass[name] = false; continue; }
    // Job that would overrun idle period waits for next one:
    //   overrun lands on very frame job was moved off, and browser's own estimate of
    //   period's end is only word there is on when that frame is due.
    if (!is_hurried && deadline.timeRemaining() < ms_job_slow_pass[name]) {
      is_owed = true;
      continue;
    }
    const ms_job = performance.now();
    JOBS_SLOW_PASS[name]();
    ms_job_slow_pass[name] = performance.now() - ms_job;
    due_slow_pass[name] = false;
  }
  addPhaseTime('ui', performance.now() - ms_before);
  if (is_owed) { is_slow_pass_scheduled = true; scheduleIdle(runSlowPass); }
}

// Draw last four seconds of frame times as one line, scaled to slowest of them.
function drawSparkline() {
  // Observer's size, not canvas's own; see `sizeObserved`.
  const w = size_sparkline.width || 300, h = size_sparkline.height || 40;
  if (sparkline.width !== w) sparkline.width = w;
  if (sparkline.height !== h) sparkline.height = h;
  let highest = 16.6;
  for (const v of history_frame) if (v > highest) highest = v;
  context_sparkline.clearRect(0, 0, w, h);
  context_sparkline.strokeStyle = '#00a7a5';
  context_sparkline.lineWidth = 1.5;
  context_sparkline.beginPath();
  for (let i = 0; i < FRAMES_HISTORY; i++) {
    const v = history_frame[(index_history_frame + i) % FRAMES_HISTORY];
    const x = (i / (FRAMES_HISTORY - 1)) * w;
    const y = h - (Math.min(v, highest) / highest) * h;
    if (i === 0) context_sparkline.moveTo(x, y); else context_sparkline.lineTo(x, y);
  }
  context_sparkline.stroke();
}

function refreshDiagnostics() {
  // **Nothing here is worth millisecond while drawer is shut.** Every figure this.
  //   writes is inside it, and with drawer closed whole refresh was still running
  //   five times second: measured on 1,024-object demo at 2.8 ms typical and 5.7 ms
  //   worst, landing on one frame in twelve. On frame that otherwise costs about
  //   millisecond -- which is what scene hold made still case -- that is not
  //   overhead, it is stutter reader can see, and it was largest single source of
  //   frame-time variance left in build.
  //   Two canvases could not skip themselves either: each fell back to 300-pixel
  //   width where its own was zero, so canvas nobody could see was drawn at made-up
  //   size. That fallback is for canvas that has not been laid out yet, not for one
  //   inside closed drawer, and this guard is what tells two apart.
  //   **And same argument one level down**: diagnostics section is collapsible
  //   inside open drawer, and collapsed one gave both canvases zero width again --
  //   so they fell back to 300 pixels and drew, five times second, for reader looking
  //   at objects list. Drawer guard above did not catch it because drawer is
  //   genuinely open.
  if (!isDiagnosticsShown()) { is_diagnostics_shown_last = false; return; }
  // Which slow-pass job this tick asks for; see `TICKS_DISTRIBUTION` and `askSlowPass`.
  //   Numeric rows below run every tick, here on frame.
  const is_first_shown = !is_diagnostics_shown_last;
  is_diagnostics_shown_last = true;
  if (is_first_shown) ticks_diagnostics = 0;
  const slot_distribution = ticks_diagnostics % TICKS_DISTRIBUTION;
  ticks_diagnostics += 1;
  askSlowPass(
    is_first_shown || slot_distribution === TICK_CURVE,
    is_first_shown || slot_distribution === TICK_SPARKLINE,
    is_first_shown || slot_distribution === TICK_MEDIANS,
    isPoolGridStale(),
  );

  // Averaged over last 200 ms rather than taken from newest frame: per-frame.
  //   reading changes several times faster than it can be read, and frame rate quoted
  //   off one frame swings by tens of fps between glances.
  const frames_recent = framesRecent();
  let total_recent = 0;
  for (let i = 0; i < frames_recent; i += 1) {
    total_recent += history_frame[(index_history_frame + FRAMES_HISTORY - 1 - i) % FRAMES_HISTORY];
  }
  const mean_frame = total_recent / frames_recent;
  // **No band ceiling any more, and no share-of-work denominator.** Both belonged to.
  //   four-band tint this replaced: bands had to agree with curve above them, so
  //   tree was capped at whatever band that curve was drawing. Ramp is absolute --
  //   row's share of *frame*, over whole of it -- so it says same thing
  //   whatever curve happens to show, and there is nothing left to contradict.
  writeText(diagnostic_frame_time,
    mean_frame.toFixed(2) + ' ms (' + Math.round(1000 / Math.max(mean_frame, 1)) + ' fps)');
  // Slowest frame ring holds, split from its own slots between page and browser.
  //   Rows below are 200 ms means, which dilute one spike past telling whether page
  //   authored it; every phase was recorded frame by frame, so one frame can be read
  //   back exactly. Largest page phase is named beside page's sum.
  //   Slot about to be written is skipped: its phases are cleared and its frame is
  //   ring-old.
  let at_slowest = -1;
  for (let i = 0; i < FRAMES_HISTORY; i += 1) {
    if (i === index_history_frame) continue;
    if (at_slowest < 0 || history_frame[i] > history_frame[at_slowest]) at_slowest = i;
  }
  let page = 0;
  let largest = 0;
  let name_largest = '';
  for (const name of PHASES_TOP_DIAGNOSTIC) {
    if (written_phase[name][at_slowest] !== 1) continue;
    const spent = history_phase[name][at_slowest];
    page += spent;
    if (spent > largest) { largest = spent; name_largest = name; }
  }
  const browser = written_phase.idle[at_slowest] === 1 ? history_phase.idle[at_slowest] : 0;
  // Browser's share split where timer measured it; see `markRendered`.
  const render = written_phase.render[at_slowest] === 1
    ? ' (render ' + history_phase.render[at_slowest].toFixed(1) + ')' : '';
  writeText(diagnostic_slowest, history_frame[at_slowest].toFixed(1) + ' ms');
  writeText(diagnostic_slowest_split,
    page.toFixed(1) +
    (name_largest === '' ? '' : ' (' + name_largest + ' ' + largest.toFixed(1) + ')') +
    ' \u00b7 ' + browser.toFixed(1) + render);

  // Each step of drawing process, as `mean over 200 ms (median over the ring)`:
  //   short mean is what reader watches while changing something, long median is settled figure to
  //   act on.
  //   Phase that has not run at all stays em dash.
  for (const [name] of PHASES_DIAGNOSTIC) {
    if (!isPhaseShown(name)) continue; // Inside closed node; nobody is reading it.
    const median = medianPhaseHeld(name);
    if (median === null) continue;
    // Phase idle for whole window shows its median rather than nothing: it is step.
    //   that runs, and "0.00" would claim it had run for free this window.
    const recent = meanPhase(name, frames_recent);
    const shown = recent === null ? median : recent;
    writeText(element_phase[name], shown.toFixed(2) + ' (' + median.toFixed(2) + ') ms');
    // Count beside row's own name, so **every** value ends in `ms` and times.
    //   down tree finish in one column. Zero is shown rather than left off: kind
    //   present but empty says something kind that is absent does not.
    // Points drawn of points standing, where cull skipped any; see `isPointInView`.
    const tally = name === 'points' && count_points_culled > 0
      ? ' (' + count_phase[name] + ' of ' + (count_phase[name] + count_points_culled) + ')'
      : ' (' + count_phase[name] + ')';
    writeText(element_tally[name], tally);
    // And what that number is worth, in curve's own colours.
    if (element_row[name] === null) continue;
    // Some rows keep neutral ink instead. **`idle` always**: it is frame's.
    //   leftover rather than work done, so on healthy frame it is largest share of
    //   all and tinting it would paint best case in ramp's loudest colour. And
    //   where nothing has been measured yet there is no share to take.
    if (name === 'idle' || !(mean_frame > 0)) {
      writeColour(element_row[name], '');
      writeColour(element_phase[name], '');
      continue;
    }
    // **Against whole frame, not against work in it.** Row's colour answers.
    //   "how much of a frame goes here", so denominator is frame -- which makes
    //   ramp absolute reading reader can compare between sessions, rather than
    //   share of total that shrinks as page gets faster and repaints every row
    //   louder for it.
    const tint = rampTreeAt(shown / mean_frame);
    writeColour(element_row[name], tint.label);
    writeColour(element_phase[name], tint.value);
  }

  if (performance.memory) {
    writeText(diagnostic_heap,
      (performance.memory.usedJSHeapSize / (1024 * 1024)).toFixed(1) + ' / ' +
      (performance.memory.jsHeapSizeLimit / (1024 * 1024)).toFixed(0) + ' MB');
  }

  writeText(diagnostic_pool, nimSceneCount() + ' / ' + nimSceneCapacity());
}

// Object pool, one square per slot in ink of whatever object holds it.
//   `nimPoolCellColors` decides every cell's colour, free ones included, so no palette rule
//   lives out here -- it returns one [r, g, b] triple per slot, in slot order, and this only
//   arranges them.
//   **Drawn when scene changes and at no other time.** At capacity of 1,024 walk
//   that fills that buffer is about millisecond, and this refresh runs five times second
//   for picture that moves when object is added or removed. Scene's own revision is
//   exactly that question, and it is same counter frame hold is keyed on.
//   canvas's own geometry is part of key as well, because resize clears what was drawn
//   and because section opens onto canvas that had no size until it did.
// Report whether grid's picture is behind:
//   scene edited, pixel ratio moved, or canvas itself resized or never drawn. Plain
//   reads all; tick asks this and slow pass draws.
function isPoolGridStale() {
  const ratio = Math.min(window.devicePixelRatio || 1, 2.5);
  return is_pool_stale || revision_pool_last !== nimSceneRevision() || ratio_pool_last !== ratio;
}

function drawPoolGrid(count, capacity) {
  if (context_pool === null) return;
  const ratio = Math.min(window.devicePixelRatio || 1, 2.5);
  // Observer's width, not canvas's own; see `sizeObserved`.
  const width = size_pool.width;
  if (!(width > 0)) return; // Laid out inside something closed; nothing to draw on.
  revision_pool_last = nimSceneRevision();
  ratio_pool_last = ratio;
  is_pool_stale = false;
  width_pool_drawn = width;

  // First size whose grid fits budget, or smallest offered where none does.
  let [cell, gap] = CELLS_POOL[CELLS_POOL.length - 1];
  let columns = 1, rows = capacity, height = 0;
  for (const [side, between] of CELLS_POOL) {
    const pitch_try = side + between;
    const columns_try = Math.max(1, Math.floor((width + between) / pitch_try));
    const rows_try = Math.ceil(capacity / columns_try);
    const height_try = rows_try * pitch_try - between;
    if (height_try > HEIGHT_POOL_MAX && side !== CELLS_POOL[CELLS_POOL.length - 1][0]) continue;
    cell = side; gap = between;
    columns = columns_try; rows = rows_try; height = height_try;
    break;
  }
  const pitch = cell + gap;
  // **Drawn at device resolution, unlike its two neighbours.** Curve and sparkline.
  //   are 1.5px strokes and lose nothing to doubled display; grid of hard-edged squares
  //   this small does, and every cell edge would be soft on tablet this is read on.
  geometry_pool_drawn = { cell, gap, columns, rows, height };
  grid_pool.style.height = height + 'px';
  grid_pool.width = Math.round(width * ratio);
  grid_pool.height = Math.round(height * ratio);
  context_pool.setTransform(ratio, 0, 0, ratio, 0, 0);
  context_pool.clearRect(0, 0, width, height);
  const cells = nimPoolCellColors();
  for (let slot = 0; slot < capacity; slot += 1) {
    const at = slot * 3;
    // Keyed on bytes rather than floats, so triple that rounds to same colour.
    //   is same entry; `rgbToCss` rounds to bytes anyway.
    const key = (Math.round(cells[at] * 255) << 16) | (Math.round(cells[at + 1] * 255) << 8) |
      Math.round(cells[at + 2] * 255);
    let colour = css_pool.get(key);
    if (colour === undefined) {
      colour = rgbToCss([cells[at], cells[at + 1], cells[at + 2]]);
      css_pool.set(key, colour);
    }
    context_pool.fillStyle = colour;
    context_pool.fillRect(
      (slot % columns) * pitch, Math.floor(slot / columns) * pitch, cell, cell,
    );
  }
  // What picture says, for reader who cannot see it. `title` beside it in.
  //   markup carries legend, which does not change.
  grid_pool.setAttribute(
    'aria-label', count + ' of ' + capacity + ' object slots in use, one cell each',
  );
}

/* ---------------------------------------------------------------------- */
/* Overlay: hover ring + drag rubber-band, as plain 2D SVG drawn on top of */
/* WebGL canvas -- mirrors `visualiser.drawInteractionOverlay` exactly     */
/* (same radius, same tint per operation), just drawn through SVG rather   */
/* than through Dear ImGui's own immediate-mode draw list.                */
/* ---------------------------------------------------------------------- */

const svg_overlay = document.getElementById('overlay');
// Read from marker.nim's own constants via nimOverlayMetrics.
//   Never hand-copied literal that could drift out of sync with them.
const [WIDTH_OVERLAY_LINE, ALPHA_MARKER_SELECTED, ALPHA_MARKER_HOVER, HEIGHT_LABEL_MARKER] =
  nimOverlayMetrics();
// Every ink's colour as CSS string, read once: name label wears its object's ink, and.
//   `nimInkColor` builds sequence per call, which per selected object per frame was
//   allocation per frame. Indexed by ink ordinal, `nimItemInk`'s answer.
const COLOUR_INK_CSS = [];
for (let ink = 0; ink < nimInkCount(); ink += 1) {
  const rgb = nimInkColor(ink);
  COLOUR_INK_CSS.push('rgb(' + Math.round(rgb[0] * 255) + ',' + Math.round(rgb[1] * 255) +
    ',' + Math.round(rgb[2] * 255) + ')');
}
// Label's face sized to box marker.nim placed it in, so one number decides both.
svg_overlay.style.fontSize = HEIGHT_LABEL_MARKER + 'px';
// Outline around label's letters, in pixels: wide enough to read against object's own.
//   disc, which label's fill matches by design.
const WIDTH_LABEL_STROKE = 3;
// Mirrors marker.MarkerKind's own ordinals; nimSelectionMarker leads with one of these.
const MARKER_RING = 0, MARKER_RAILS = 1, MARKER_LOOP = 2, MARKER_BANDS = 3,
  MARKER_FRAME = 4;
// Read from interaction.nim's own constants via nimMenuMetrics, for same reason marker's sizes are:
//   hand-copied literal here would drift from desktop's menu.
const [HEIGHT_MENU_WEDGE, PADDING_MENU_WEDGE, ROUNDING_MENU_WEDGE,
  WIDTH_MENU_WEDGE_BORDER, RADIUS_MENU_CENTRE,
  ALPHA_MENU_WEDGE, ALPHA_MENU_UNOFFERED] = nimMenuMetrics();
// Floats per wedge in nimDragMenuLayout:
//   x, y, offered.
//   Wedge's own colours come from `.menu-wedge`, which is `.selection-menu button` -- see
//   shell.html.
const FLOATS_MENU_WEDGE = 3;

// **Overlay reuses its own elements rather than rebuilding DOM each frame.**
// `refreshOverlay` used to clear layer with innerHTML and create every marker,
// pulse and wedge afresh -- element construction plus garbage per frame, roughly half
// overlay row's cost while anything was selected. Now each frame *stages* what it
// wants drawn: `stageEl` takes recycled element of right tag (stripping whatever
// attributes last use left on it), and one `replaceChildren` at end swaps
// layer's children in staged order -- so z-order still reads straight down staging
// calls, and element unused this frame simply comes off DOM into pool.
const pool_overlay = new Map();
let staged_overlay = [];
function stageEl(tag, attrs) {
  const bin = pool_overlay.get(tag);
  const element = bin !== undefined && bin.length > 0
    ? bin.pop()
    : document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (let i = element.attributes.length - 1; i >= 0; i -= 1) {
    const name = element.attributes[i].name;
    if (!(name in attrs)) element.removeAttribute(name);
  }
  for (const k in attrs) element.setAttribute(k, attrs[k]);
  staged_overlay.push(element);
  return element;
}
function recycleOverlay() {
  for (const element of svg_overlay.children) {
    let bin = pool_overlay.get(element.tagName);
    if (bin === undefined) { bin = []; pool_overlay.set(element.tagName, bin); }
    bin.push(element);
  }
  staged_overlay = [];
}

// Stroke one object's marker into overlay.
//   Every geometric decision -- which outline, how far off object it sits, where its points land on
//   screen -- was made by marker.nim; this only turns flat array it reports into SVG elements.
//
// **Interaction layer works in CSS pixels; render layer works in framebuffer
// pixels.** Two layers, two units, and each is told which it is in: cursor, hover,
// markers and menus are all asked and answered in CSS pixels, while `nimBuildFrame` and
// WebGL uniforms below take framebuffer size and scale their own constants by
// device pixel ratio. This used to be half-done -- positions were converted from
// framebuffer to CSS but every *length* was not, so marker's radius and menu wedge's
// height were drawn at ratio times their intended size, and "make the marker bigger" had
// no stable meaning. Converting nothing is simpler than converting some of it.
// Rails arrive as consecutive pairs, one per drawn piece, so pairwise loop below
// covers line clipped into any number of them without knowing how many to expect.
// Orientation pulse travelling along selected object's marker: which way it goes is
// object's own orientation, and shape of every run comes across bridge already
// in screen space. Filled rather than stroked, because each run tapers from swollen head
// back to outline's own width and stroke carries one width for its whole length --
// marker.ribbonAlong shapes that outline, this only fills what it is handed. Only caller
// passing time gets one -- hover and focus wear same marker standing still.
function appendMarkerPulse(slot, alpha, progress, is_touch) {
  const flat = nimSelectionPulse(slot, canvas.clientWidth, canvas.clientHeight, progress,
    is_touch === true);
  if (flat.length === 0) return;
  const fill = 'rgba(255,255,255,' + alpha + ')';
  let at = 1;
  for (let run = 0; run < flat[0]; run++) {
    const count = flat[at++];
    const points = [];
    for (let i = 0; i < count; i++) points.push(flat[at + 2 * i] + ',' + flat[at + 2 * i + 1]);
    at += 2 * count;
    stageEl('polygon', {
      points: points.join(' '), fill: fill, stroke: 'none',
    });
  }
}

// Write selected object's name above its marker.
//   Filled in object's own ink and outlined in marker's stroke, so label reads as part of
//   marker family. Where it sits is `marker.Marker.label_at`'s decision, centred here on
//   both axes; face is `svg#overlay text`'s in shell.html.
//   Text set on element rather than through attributes: `stageEl` strips and sets
//   attributes only, and recycled <text> keeps last content unless overwritten.
function appendLabel(slot, alpha) {
  const at = nimSelectionLabelAt(slot, canvas.clientWidth, canvas.clientHeight);
  if (at[2] < 0.5) return;
  const element = stageEl('text', {
    x: at[0], y: at[1], 'text-anchor': 'middle', 'dominant-baseline': 'central',
    fill: COLOUR_INK_CSS[nimItemInk(slot)],
    stroke: 'rgba(255,255,255,' + alpha + ')', 'stroke-width': WIDTH_LABEL_STROKE,
    'stroke-linejoin': 'round', 'paint-order': 'stroke',
  });
  element.textContent = nimItemLabel(slot);
}

function appendMarker(slot, alpha, w, h, progress, is_touch, swell) {
  const marker =
    nimSelectionMarker(slot, canvas.clientWidth, canvas.clientHeight, progress,
      is_touch === true, swell || 0);
  if (marker.length === 0) return;
  const kind = marker[0], is_closed = marker[1] > 0.5;
  const radius = marker[2], fraction = marker[3];
  const stroke = 'rgba(255,255,255,' + alpha + ')';
  const points = [];
  for (let i = 4; i + 1 < marker.length; i += 2) {
    points.push([marker[i], marker[i + 1]]);
  }

  if (kind === MARKER_RING) {
    // Keep whole ring as <circle>; only partial one becomes arc path.
    //   Marker that is not filling draws exactly as plain ring.
    if (fraction >= 1) {
      stageEl('circle', {
        cx: points[0][0], cy: points[0][1], r: radius,
        fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      });
    } else if (fraction > 0) {
      // Sweep clockwise from twelve o'clock, measuring angle from top.
      //   Sweep then reads way every other progress dial does; with y downward, SVG's
      //   positive sweep direction (flag 1) is that same clockwise sense.
      const [cx, cy] = points[0];
      const turn = fraction * 2 * Math.PI;
      const ex = cx + radius * Math.sin(turn), ey = cy - radius * Math.cos(turn);
      stageEl('path', {
        d: 'M ' + cx + ',' + (cy - radius) +
           ' A ' + radius + ',' + radius + ' 0 ' + (fraction > 0.5 ? 1 : 0) + ',1 ' +
           ex + ',' + ey,
        fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      });
    }
  } else if (kind === MARKER_RAILS) {
    for (let i = 0; i < points.length; i += 2) {
      stageEl('line', {
        x1: points[i][0], y1: points[i][1], x2: points[i + 1][0], y2: points[i + 1][1],
        stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      });
    }
  } else if (kind === MARKER_LOOP || kind === MARKER_FRAME) {
    // Stroke frame through very same element plane's loop does, as closed polyline.
    //   Circle while it expands, screen's own rectangle once it arrives.
    //   One path for every closed outline rather than <rect> of its own, and nothing to
    //   keep in step when one of them changes.
    stageEl(is_closed ? 'polygon' : 'polyline', {
      points: points.map((p) => p[0] + ',' + p[1]).join(' '),
      fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
    });
  } else if (kind === MARKER_BANDS) {
    // Two runs in one array:
    //   header says how many points first band holds and whether each band closed, since either can
    //   be cut into arc by eye on its own.
    const count_first = Math.round(marker[2]), is_closed_second = marker[3] > 0.5;
    const bands = [
      { run: points.slice(0, count_first), closed: is_closed },
      { run: points.slice(count_first), closed: is_closed_second },
    ];
    for (const band of bands) {
      if (band.run.length === 0) continue;
      stageEl(band.closed ? 'polygon' : 'polyline', {
        points: band.run.map((p) => p[0] + ',' + p[1]).join(' '),
        fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      });
    }
  }
}

function refreshOverlay(cursor) {
  recycleOverlay();
  const w = canvas.clientWidth, h = canvas.clientHeight;
  // One clock reading for whole overlay, before any pulse is shaped:
  //   every selected object's comet advances by that same step.
  //   Pulse carries its phase between frames rather than computing it from time -- see
  //   selection.PulseClock for why reading it off clock made every comet lurch moment camera moved.
  nimTickPulse(now());

  // Draw one marker per selected object, shaped to that object by marker.nim.
  //   Ring about point, rails flanking line, loop lying on plane.
  //   Hover draws very same marker at lower opacity, so both read as one family and
  //   hovering line previews exactly what selecting it will draw.
  for (const slot of slots_selection) {
    if (slot === nimHoldSlot()) continue; // Its own swollen marker is drawn below.
    appendMarker(slot, ALPHA_MARKER_SELECTED, w, h, 1);
    appendMarkerPulse(slot, ALPHA_MARKER_SELECTED, 1, false);
    appendLabel(slot, ALPHA_MARKER_SELECTED);
  }

  // Fill pressed item's own marker as press matures into selection.
  //   Wait then reads as filling rather than as nothing happening.
  //   Drawn at selected weight it is about to become, and skipped for item already
  //   selected, whose finished marker is on screen already.
  // Swell filled marker clear of finger doing filling.
  //   `nimBeginHold` is called from touch branch of `pointerdown` and from nowhere
  //   else, so hold in progress on this build is finger's by construction.
  //   Flag is passed rather than inferred inside marker.nim, which cannot see what kind
  //   of pointer is on glass.
  // Draw even once slot is selected, unlike every other overlay rule here.
  //   Matured hold keeps its swollen marker until finger lifts and it settles, and
  //   plain selected marker underneath it is very size this is animating away from.
  const slot_hold = nimHoldSlot();
  if (slot_hold >= 0) {
    appendMarker(slot_hold, ALPHA_MARKER_SELECTED, w, h, nimHoldProgress(now()), true,
      nimSwellHold(now()));
    // Name rides up with swollen marker, once hold has selected it.
    if (slots_selection.includes(slot_hold)) appendLabel(slot_hold, ALPHA_MARKER_SELECTED);
  }

  // Hover and keyboard focus wear same marker at same weight:
  //   reader driving by key sees exactly what reader driving by pointer sees, and focus indicator
  //   WCAG 2.4.7 asks for is machinery already built rather than second one invented beside it.
  for (const slot of [nimHoverSlot(), nimFocusSlot()]) {
    if (slot >= 0 && slot !== slot_hold && !slots_selection.includes(slot)) {
      appendMarker(slot, ALPHA_MARKER_HOVER, w, h, 1);
    }
  }

  if (nimDragActive()) {
    const src = nimAnchorScreen(nimDragSourceSlot(), canvas.clientWidth, canvas.clientHeight);
    if (src[2] > 0.5 && cursor) {
      const [sx, sy] = [src[0], src[1]];
      // Tinted by what releasing would do, not by which button started drag:
      //   operation's own colour over pair that makes something, reserved magenta over one that
      //   makes nothing, neutral while crossing empty space.
      const tint = nimDragTint();
      const stroke = 'rgba(' + Math.round(tint[0] * 255) + ',' +
        Math.round(tint[1] * 255) + ',' + Math.round(tint[2] * 255) + ',0.85)';
      stageEl('line', {
        x1: sx, y1: sy, x2: cursor.x, y2: cursor.y,
        stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      });
      // Which way round pair is being taken:
      //   band swelling into its own last stretch, same shape orientation pulse wears.
      //   Shaped by `marker.cometFor` across bridge rather than worked out here -- band's direction
      //   is gesture's own business, and this layer fills what it is handed.
      //   Empty while cursor rests on its own source, which points nowhere.
      const comet = nimDragComet(w, h);
      if (comet.length) {
        const points = [];
        for (let i = 0; i + 1 < comet.length; i += 2) points.push(comet[i] + ',' + comet[i + 1]);
        stageEl('polygon', {
          points: points.join(' '), fill: stroke, stroke: 'none',
        });
      }
    }
    appendChoiceMenu(w, h);
  }

  // One swap for whole layer, in staged order. Also what detaches whatever last.
  //   frame drew and this one did not: those elements sit in pool, off DOM.
  svg_overlay.replaceChildren(...staged_overlay);
}

// Draw four wedges of open choice menu.
//   Every position, colour, label and whether wedge is offered comes from interaction.nim through
//   nimDragMenuLayout/Labels, and which one cursor stands in from nimDragMenuHighlighted -- same
//   call release resolves through, so highlight is never second opinion about where cursor is.
//   Wedge label's laid-out width, measured once per label and remembered.
//   Still measured from what browser actually laid it out as -- never estimated from character
//   count, which drifts moment face loaded is not one estimate was tuned against -- but label's
//   metrics cannot change between frames, and `getBBox` forces layout, so paying it once per label
//   is whole point.
//   Cache empties when document's fonts finish loading, in case early measure ran against fallback
//   face.
const widths_menu_label = new Map();
document.fonts.ready.then(() => widths_menu_label.clear());
function widthMenuLabel(label) {
  const held = widths_menu_label.get(label);
  if (held !== undefined) return held;
  const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
  text.setAttribute('class', 'menu-wedge-label');
  text.textContent = label;
  svg_overlay.appendChild(text);
  const width = text.getBBox().width;
  text.remove();
  widths_menu_label.set(label, width);
  return width;
}

// Cache wedge labels: fixed for build, so bridge is asked once rather than per frame.
let labels_menu = null;

function appendChoiceMenu(w, h) {
  const layout = nimDragMenuLayout();
  if (layout.length === 0) return;
  if (labels_menu === null) labels_menu = nimDragMenuLabels();
  const labels = labels_menu;
  const highlighted = nimDragMenuHighlighted();
  const centre = nimDragMenuCentre();
  for (let i = 0; i * FLOATS_MENU_WEDGE < layout.length; i += 1) {
    const at = i * FLOATS_MENU_WEDGE;
    const [x, y] = [layout[at], layout[at + 1]];
    const is_offered = layout[at + 2] > 0.5;
    const width = widthMenuLabel(labels[i]) + PADDING_MENU_WEDGE;
    stageEl('rect', {
      x: x - width / 2, y: y - HEIGHT_MENU_WEDGE / 2,
      width: width, height: HEIGHT_MENU_WEDGE, rx: ROUNDING_MENU_WEDGE,
      'fill-opacity': is_offered ? ALPHA_MENU_WEDGE : ALPHA_MENU_UNOFFERED,
      'stroke-width': WIDTH_MENU_WEDGE_BORDER,
      class: i === highlighted ? 'menu-wedge on' : 'menu-wedge',
    });
    const text = stageEl('text', {
      x: x, y: y, 'text-anchor': 'middle', 'dominant-baseline': 'central',
      // Unoffered wedge is dimmed rather than dropped:
      //   gap where wedge should be is unreadable, and point of fixed compass is that choice never
      //   moves.
      'fill-opacity': is_offered ? 1 : 0.6,
      class: i === highlighted ? 'menu-wedge-label on' : 'menu-wedge-label',
    });
    text.textContent = labels[i];
  }
  // Middle is where nothing is chosen, and way out of menu that opened unasked.
  stageEl('circle', {
    cx: centre[0], cy: centre[1],
    r: RADIUS_MENU_CENTRE,
    fill: 'none', class: 'menu-centre', 'stroke-width': WIDTH_OVERLAY_LINE,
  });
}

/* ---------------------------------------------------------------------- */
/* Pointer input.                                                          */
/*   One invariant across every pointer: THE PRESS TARGET CHOOSES THE      */
/*   SCHEME. Press that lands on object constructs; one that lands on      */
/*   empty space moves camera. Mirrors `visualiser.handleEvent`.           */
/*   Mouse: left-drag takes whatever two objects make and is never         */
/*   interrupted, right-drag opens choice menu on arrival. From empty      */
/*   space, left orbits, right pans, wheel dollies.                        */
/*   Touch: same, with dwell as only way to open menu --                   */
/*   there is no second button to force it with. Finger that presses       */
/*   object and stays still selects it instead (long-press), so            */
/*   first movement past `TAP_MAX_MOVE` is what decides between two.       */
/*   Two fingers still pinch and pan, and cancel any drag in progress.     */
/* ---------------------------------------------------------------------- */

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

const pointers = new Map();
let separation_pinch_start = null;
// Whether two fingers have parted or closed further than tap slop since both came down.
//   Until they have, gesture is pan and only pan: two fingers carried together never
//   hold their separation to pixel, and every notch of that jitter went through zoom,
//   which re-targets turntable onto whatever middle of frame crossed. Slop itself is not
//   zoomed once crossed; zoom starts from separation where it was crossed, without jump.
let is_pinch_zooming = false;
// Whether two fingers have moved since frame loop last read them.
//   Each finger's move arrives as its own `pointermove`, so between two of them
//   separation and midpoint are one finger new and other old: read there, every step of
//   pan carried together was zoom in by one finger's step and out again by other's,
//   and each of those went through re-target. Read once per frame instead, in
//   `settleTwoFingers`, after both have reported.
let is_two_fingers_pending = false;
let pan_last = null;
// Button held for camera orbit/pan fallback, while no operation drag is active.
let button_mouse_drag = null;
let cursor_last = null;
// **What pointer asked for, for frame loop to answer once.** Pick and dolly.
//   both walk whole scene, and pointer or trackpad reports several times between two
//   frames; see frame loop, which is where each of these is spent.
let is_hover_stale = false;
let deltas_wheel = 0; // Summed wheel travel awaiting one dolly; `wheel` says why.

// Touch long-press-to-select / tap-to-toggle / drag-to-construct state.
let touch_down_at = null, position_touch_down = null, has_touch_moved = false;
let has_long_press_fired = false;
// Item finger came down on, and whether that press has become construction drag.
//   `slot_touch_down` is read once at pointerdown, while hover still holds it -- picking
//   again later would report whatever finger has since moved over.
let slot_touch_down = -1, is_touch_dragging = false;
// Whether press landed on something drag may be built from, decided at press and.
//   held for gesture. **Press that can construct never moves camera, not even
//   over pixels before slop is crossed** -- that is press-target rule mouse
//   already follows by choosing its scheme at button. Touch reached same place by
//   different road and got it wrong: finger that eased into its drag orbited for frame
//   or two before slop, which latched `nimSetCameraDragging`, and hover is suppressed
//   while camera moves -- so construction drag that armed moment later ran blind
//   for rest of gesture, ghosting nothing and building nothing. Flick that cleared
//   slop in one event armed before any of that and worked, which is what made fault
//   read as intermittent.
let is_touch_press_constructing = false;
// How far press may move and still be press comes from `interaction.PIXELS_TAP_SLOP`:
//   it decides which scheme gesture enters, which is rule about gesture, not
//   presentation number. Tap *timeout* stays here -- that one really is local.
const TAP_MAX_MS = 350, TAP_MAX_MOVE = nimTapSlop();
// How finger's construction drag comes to offer wheel. Mouse reads this off.
//   button it pressed; touch has no second button, so it names one arming that waits.
const ARMING_DRAG_TOUCH = nimDragArmingOnDwell();

// Tell mouse click from drag: plain click selects or shift-selects, drag builds.
//   Whether press stayed click is `interaction.isClick`'s to say.
//   All that is left here is which button went down, which is this layer's own
//   numbering.
let button_mouse_down = null;

function pointerDist(points_flat) {
  const [a, b] = points_flat;
  return Math.hypot(a.x - b.x, a.y - b.y);
}
function pointerMid(points_flat) {
  const [a, b] = points_flat;
  return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
}

canvas.addEventListener('pointerdown', (e) => {
  canvas.setPointerCapture(e.pointerId);
  // Every gesture starts by saying it is not camera move; branches below say so where.
  //   they are one. Cleared here rather than only at release because release can go
  //   missing -- pointer cancelled, touch sequence browser tears down -- and flag
  //   left true stops hover ring working for rest of session, with nothing on
  //   screen to say why. Same failure held keys have, handled same way.
  if (pointers.size === 0) nimSetCameraDragging(false);
  const rect = canvas.getBoundingClientRect();
  const local = { x: e.clientX - rect.left, y: e.clientY - rect.top };
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

  if (e.pointerType === 'mouse') {
    nimUpdateCursor(local.x, local.y);
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
    // Note press before anything is decided about it: whether it was click is only.
    //   knowable at release, and both branches below can end in one.
    nimBeginPress(now());
    button_mouse_down = e.button;
    // Read off button whether drag decides for you or asks.
    //   What it builds is read off operands at release; mirrors `visualiser.armingFor`.
    const arming_drag = nimDragKindForButton(e.button);
    if (arming_drag >= 0 && nimBeginDrag(arming_drag, now())) {
      button_mouse_drag = e.button;
    } else if (e.button === 0) {
      button_mouse_drag = 'orbit';
    } else if (e.button === 2) {
      button_mouse_drag = 'pan';
    }
    return;
  }

  // Touch/pen:
  //   track for existing multi-touch orbit/pinch/pan gesture, for single-finger tap that toggles
  //   selection membership once selection exists, for long-press that starts one, and for drag off
  //   object that constructs.
  if (pointers.size === 1) {
    touch_down_at = performance.now();
    position_touch_down = local;
    has_touch_moved = false;
    has_long_press_fired = false;
    // Pick item under finger now and hand press to Nim, which owns how long.
    //   hold takes and whether one is due. Frame loop asks it both, which is also what
    //   fills item's own marker -- timer firing on its own could not draw anything.
    //   Slot is kept as well: it is what decides, on first movement, whether this
    //   press was construction drag or camera orbit.
    nimUpdateCursor(local.x, local.y);
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
    // Noted like any other press, so that finger's own construction drag is measured.
    //   against where finger landed rather than against last mouse press.
    nimBeginPress(now());
    slot_touch_down = nimHoverSlot();
    // Whether this press *can* become construction drag, decided here at press and.
    //   not re-asked -- same question `interaction.beginDrag` answers when slop is
    //   finally crossed, asked early because moves before that have to know which
    //   scheme they belong to. Sky is hovered wherever nothing else is and is refused
    //   there, so press on it still falls through to camera; so is crowd, several
    //   objects in reach of one finger, which moves view instead; see
    //   `interaction.canConstructByTouch`.
    is_touch_press_constructing = nimCanTouchConstruct();
    if (slot_touch_down >= 0) nimBeginHold(slot_touch_down, now());
  } else {
    touch_down_at = null; // Second finger landed; this is pinch/pan gesture, not tap.
    nimCancelHold();
    // ...and not construction either. Drag reader has visibly abandoned must not.
    //   commit on whichever finger happens to lift first.
    if (is_touch_dragging) { nimCancelDrag(); is_touch_dragging = false; }
    slot_touch_down = -1;
    is_touch_press_constructing = false;
  }
  if (pointers.size === 2) {
    const points_flat = [...pointers.values()];
    separation_pinch_start = pointerDist(points_flat);
    is_pinch_zooming = false;
    pan_last = pointerMid(points_flat);
  }
});

canvas.addEventListener('pointermove', (e) => {
  const rect = canvas.getBoundingClientRect();
  cursor_last = { x: e.clientX - rect.left, y: e.clientY - rect.top };

  if (e.pointerType === 'mouse') {
    nimUpdateCursor(cursor_last.x, cursor_last.y);
    if (button_mouse_drag !== null && typeof button_mouse_drag === 'number') {
      // Re-check hover for drag's own destination preview -- next frame, not now; see.
      //   `is_hover_stale`.
      is_hover_stale = true;
      return;
    }
    if (!pointers.has(e.pointerId)) return;
    const prev = pointers.get(e.pointerId);
    const current = { x: e.clientX, y: e.clientY };
    pointers.set(e.pointerId, current);
    const dx = current.x - prev.x, dy = current.y - prev.y;
    // Camera gesture is not hover, said at *move* rather than at press:
    //   press that never moves is click, and click has to know what it came down on.
    if (button_mouse_drag === 'orbit' || button_mouse_drag === 'pan') nimSetCameraDragging(true);
    if (button_mouse_drag === 'orbit') {
      nimCameraOrbit(
        -dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4,
      );
    } else if (button_mouse_drag === 'pan') {
      // Where pointer was and where it is, not how far it moved:
      //   pan grabs level under it and carries that point along, which needs both ends of step.
      nimCameraPanAt(
        prev.x - rect.left, prev.y - rect.top,
        current.x - rect.left, current.y - rect.top,
        canvas.clientWidth, canvas.clientHeight,
      );
    }
    is_hover_stale = true;
    return;
  }

  if (!pointers.has(e.pointerId)) return;
  const prev = pointers.get(e.pointerId);
  const current = { x: e.clientX, y: e.clientY };
  pointers.set(e.pointerId, current);
  const reach_touch = position_touch_down &&
    Math.hypot(cursor_last.x - position_touch_down.x, cursor_last.y - position_touch_down.y);
  if (reach_touch > TAP_MAX_MOVE && !has_touch_moved) {
    // One moment this press stops being press. Decided once, here, and never.
    //   revisited: press target chooses scheme, so finger that came down on
    //   object constructs and one that came down on empty space moves camera.
    //   `nimBeginDrag` reads hover reading, which still holds touch-down slot
    //   because touch pointermove has not updated cursor yet -- so it must run before
    //   two lines below start following finger.
    has_touch_moved = true;
    nimCancelHold(); // Moved, so this press will never mature into selection.
    if (slot_touch_down >= 0 && pointers.size === 1) {
      // Finger has no second button to ask wheel for, so it is one pointer that.
      //   still reaches wheel by standing still; see `interaction.MenuArming`.
      is_touch_dragging = nimBeginDrag(ARMING_DRAG_TOUCH, now());
    }
  }

  if (is_touch_dragging) {
    // Follow finger and let frame loop's own `nimUpdateDrag` do rest:
    //   preview, dwell, and menu are all already driven from there. Returning
    //   here is what keeps construction drag from also orbiting camera under it.
    nimUpdateCursor(cursor_last.x, cursor_last.y);
    is_hover_stale = true;
    return;
  }

  if (pointers.size === 1) {
    // One finger that is not constructing and not holding is orbiting, which hover.
    //   ring should sit out; two branches above return before reaching here.
    //   Press that came down on object is not orbiting even now, before its slop is
    //   crossed: it is construction press waiting to become drag, and moving
    //   camera under it would both jerk view and put out hover drag needs.
    if (is_touch_press_constructing) return;
    nimSetCameraDragging(true);
    const dx = current.x - prev.x, dy = current.y - prev.y;
    nimCameraOrbit(
      -dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4,
    );
  } else if (pointers.size === 2) {
    nimSetCameraDragging(true); // Two fingers pan and pinch; neither points at anything.
    is_two_fingers_pending = true; // Read by frame loop; see `settleTwoFingers`.
  }
});

// Move camera by two fingers' travel since frame loop last looked.
//   Run from `frame` before it draws, once per frame both fingers have reported in;
//   see `is_two_fingers_pending`.
function settleTwoFingers() {
  if (!is_two_fingers_pending) return;
  is_two_fingers_pending = false;
  if (pointers.size !== 2) return;
  const rect = canvas.getBoundingClientRect();
  const points_flat = [...pointers.values()];
  const separation = pointerDist(points_flat);
  const mid = pointerMid(points_flat);
  // Zoom at middle of frame, not aimed at pinch's own midpoint.
  //   Pan below already moves view by that midpoint's own travel, so aiming zoom
  //   there too translates view twice for one gesture, and pinch anywhere but dead
  //   centre slides scene while it scales it.
  //   Wheel has no pan beside it, which is why aiming at pointer is right there.
  //   Through anchor at middle rather than plain dolly, so target lands on planet
  //   pinch arrives at and orbit turns about it; plane, ground and level under middle
  //   leave target on its level. See `interaction.dollyAtCentre`.
  if (separation_pinch_start !== null && !is_pinch_zooming &&
      Math.abs(separation - separation_pinch_start) > TAP_MAX_MOVE) {
    is_pinch_zooming = true;
    separation_pinch_start = separation;
  }
  if (is_pinch_zooming) {
    nimCameraDollyCentred(
      separation_pinch_start / Math.max(1, separation), canvas.clientWidth, canvas.clientHeight,
    );
    separation_pinch_start = separation;
  }

  if (pan_last) {
    // Grab and carry two fingers' own midpoint exactly as mouse drag is.
    //   Same rule for both, so fix to one is fix to both.
    nimCameraPanAt(
      pan_last.x - rect.left, pan_last.y - rect.top,
      mid.x - rect.left, mid.y - rect.top,
      canvas.clientWidth, canvas.clientHeight,
    );
  }
  pan_last = mid;
}

function endMouseDrag(e) {
  if (typeof button_mouse_drag === 'number') {
    // `nimEndDrag` resolves press itself: click over object comes back as.
    //   `clicked_slot` with eagerly-begun drag already abandoned, actual drag as
    //   whatever it built. Which of two it was is `interaction.endDrag`'s answer, so
    //   this build and desktop cannot come to disagree about where line is.
    const result = nimEndDrag(now());
    if (result.clicked_slot >= 0) {
      pickOnClick(result.clicked_slot, button_mouse_drag, e.shiftKey);
    } else {
      toast(result.message);
      if (result.created_slot >= 0) adoptConstructionSelection();
      else if (result.is_more) openApplyPickerOnOperands(cursor_last);
    }
  } else if (button_mouse_down !== null && nimIsClick(now())) {
    // Plain click that began no drag to end -- so it landed on empty space, or on one.
    //   thing that *is* empty space: plane at horizon, which nimBeginDrag refuses so this
    //   press could still have become orbit or pan. Clicking it selects it, which is
    //   only way pointer can, since it can never be dragged from. **Either button**,
    //   on same rule as above: right click on sky behaving unlike right click on
    //   anything else would be rule with hole in it.
    if (nimIsHoverBackdrop() && nimHoverSlot() >= 0) {
      pickOnClick(nimHoverSlot(), button_mouse_down, e.shiftKey);
    } else if (button_mouse_down === 0 && !e.shiftKey) {
      // Mirrors touch's own "tapping empty space always cancels" rule. Shift+click over.
      //   empty space is left no-op, not clear -- shift means "preserve what I have" --
      //   and so is right click, whose job on empty space is to pan.
      clearSelection();
    }
  }

  button_mouse_drag = null;
  button_mouse_down = null;
  nimSetCameraDragging(false);
}

function releasePointer(e) {
  if (e.pointerType === 'mouse') {
    endMouseDrag(e);
    pointers.delete(e.pointerId);
    return;
  }

  // Touch:
  //   tap is same-finger down+up within time/distance bounds, with no second finger ever joining
  //   and no long-press already having fired -- resolves into selection toggle (see `handleTap`).
  //   Released, whether or not hold had matured; frame that matured it has already
  //   selected item. Hold itself lives on for one settle, which is what shrinks
  //   marker back -- `nimIsHoldSpent` retires it in draw loop.
  nimReleaseHold(now());
  if (is_touch_dragging) {
    // Construction drag ends exactly as mouse's own does -- same call, same three.
    //   outcomes -- because it *is* same gesture reached by different pointer.
    //   Drag is never also tap, so this branch runs instead of `handleTap`.
    //   `pointercancel` is browser saying it has taken gesture over, which is not
    //   release: it cancels rather than building something reader never let go of.
    if (e.type === 'pointercancel') {
      nimCancelDrag();
    } else {
      const result = nimEndDrag(now());
      toast(result.message);
      if (result.created_slot >= 0) adoptConstructionSelection();
      else if (result.is_more) openApplyPickerOnOperands(cursor_last);
    }
    is_touch_dragging = false;
  } else if (!has_long_press_fired && touch_down_at !== null && !has_touch_moved &&
      pointers.size === 1 && performance.now() - touch_down_at < TAP_MAX_MS) {
    handleTap(position_touch_down);
  }
  touch_down_at = null;
  has_long_press_fired = false;
  slot_touch_down = -1;
  pointers.delete(e.pointerId);
  if (pointers.size < 2) {
    separation_pinch_start = null; is_pinch_zooming = false; pan_last = null;
    is_two_fingers_pending = false;
  }
  if (pointers.size === 0) nimSetCameraDragging(false);
  if (pointers.size === 0) nimClearHover(); // No finger left touching canvas -- there's
    // no cursor position left to be "hovering" anything, so don't let last touch-down's
    // own hover reading linger and draw its ring forever.
}
canvas.addEventListener('pointerup', releasePointer);
canvas.addEventListener('pointercancel', releasePointer);
canvas.addEventListener('pointerleave', (e) => { if (e.buttons === 0) releasePointer(e); });

canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
  // Toward what pointer is over, way map zooms.
  //   Where that is comes from cursor this build already tracks, so wheel says it same way picking
  //   does.
  const rect = canvas.getBoundingClientRect();
  nimUpdateCursor(e.clientX - rect.left, e.clientY - rect.top);
  // **Summed here, applied once by frame loop.** Trackpad reports several notches.
  //   between two frames, and each dolly runs `picking.anchorZoomAt` to find what
  //   cursor is over -- full pick over every live slot, 11.4 ms on 1,024-object demo.
  //   Six notches frame measured 83.8 ms of picking on frame, for 136 ms gap, and
  //   every answer but last was thrown away. Factor is `exp(k*delta)`, so summing
  //   deltas and exponentiating once is same zoom, not approximation of it.
  deltas_wheel += e.deltaY;
}, { passive: false });

/* ---- Touch tap-to-toggle / mouse click-to-select ---- */
/*   Long-pressing (touch) or plain-clicking (mouse) object selects it; further         */
/*   tap or shift-click toggles another object into/out of same selection.               */
/*   selection menu's own content depends purely on how many objects are selected --     */
/*   see `refreshSelectionMenu` -- 1 or 2 offer apply (revealing unary/binary catalogue   */
/*   dropdown) plus hide/delete; 3+ offer only hide/delete, bulk-acting on every          */
/*   selected slot at once. Tapping/clicking empty space, or menu's own close            */
/*   button, always clears whole selection.                                              */

function handleTap(position_local) {
  const rect = canvas.getBoundingClientRect();
  nimUpdateCursor(position_local.x, position_local.y);
  nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
  const hovered = nimHoverSlot();

  // Sky counts as empty space to *tap*, deliberately, though mouse click selects.
  //   it: tapping empty space is only way finger has to dismiss selection, and
  //   spending it on selecting backdrop would take that away. Touch reaches sky
  //   through long-press instead -- which is where its marker fills anyway.
  if (hovered < 0 || nimIsHoverBackdrop()) {
    clearSelection(); // Tapping empty space always cancels.
    return;
  }
  if (slots_selection.length === 0) return; // Not in select mode yet -- only long-press
    // starts one; plain tap before that is no-op, same as before this feature.
  toggleSelection(hovered, position_local);
}

const menu_selection = document.getElementById('selection-menu');
const menu_selection_apply = document.getElementById('selection-menu-apply');
const menu_selection_edit = document.getElementById('selection-menu-edit');
const menu_selection_hide = document.getElementById('selection-menu-hide');
const menu_selection_delete = document.getElementById('selection-menu-delete');
const menu_selection_reveal = document.getElementById('selection-menu-reveal');
const menu_selection_select = document.getElementById('selection-menu-select');
const menu_selection_back = document.getElementById('selection-menu-back');
const menu_selection_close = document.getElementById('selection-menu-close');
let arity_menu_last = -1; // Arity last used to rebuild selection-menu-select's own
  // <option> list -- like drawer's own populateOperations, only rebuilds when it
  // actually changes, not on every reveal.

function populateSelectionMenuOptions(arity) {
  if (arity === arity_menu_last) return;
  arity_menu_last = arity;
  menu_selection_select.innerHTML = '';
  const count = nimOperationCount();
  for (let i = 0; i < count; i++) {
    if (nimOperationArity(i) !== arity) continue;
    const option = document.createElement('option');
    option.value = i;
    option.textContent = nimOperationNotation(i);
    menu_selection_select.appendChild(option);
  }
}

function openSelectionMenuOp() {
  // "apply" itself never moves -- it stays leftmost element of one single row.
  //   throughout; this only animates picker+back group open immediately to its
  //   right (see .selection-menu-reveal's own max-width transition). hide/delete step
  //   aside while picking operation, matching old two-row design's own behaviour
  //   (its second row never carried them either) -- ✕ stays, as it always did.
  const arity = nimSelectionArity();
  populateSelectionMenuOptions(arity);
  // Open on whatever was last applied at this arity, and ghost it straight away.
  //   Rather than on head of list; picker's answer is worth seeing while choosing, not
  //   only once apply is pressed.
  menu_selection_select.value = String(nimOperationRemembered(arity));
  ghostSelectionMenuOperation();
  menu_selection_reveal.classList.add('open');
  menu_selection_edit.style.display = 'none';
  menu_selection_hide.style.display = 'none';
  menu_selection_delete.style.display = 'none';
}

function ghostSelectionMenuOperation() {
  // Both operands come from selection in pick order, exactly as apply reads them.
  const first = slots_selection[0];
  const second = slots_selection.length > 1 ? slots_selection[1] : slots_selection[0];
  if (first === undefined) return;
  nimGhostOperation(parseInt(menu_selection_select.value, 10), first, second);
}

function closeSelectionMenuOp() {
  // Nothing is being chosen any more, so nothing is being previewed.
  //   Drawer's own section may still be open behind this menu, so ask it to speak up again rather
  //   than leaving view blank while control that has something to say is on screen.
  nimClearPreview();
  ghostDrawerOperation();
  menu_selection_reveal.classList.remove('open');
  menu_selection_edit.style.display = slots_selection.length === 1 ? '' : 'none';
  menu_selection_hide.style.display = '';
  menu_selection_delete.style.display = '';
}

menu_selection_select.addEventListener('change', ghostSelectionMenuOperation);

function refreshSelectionMenu(position_local) {
  const n = slots_selection.length;
  if (n === 0) { hideSelectionMenu(); return; }
  menu_selection_apply.style.display = (n === 1 || n === 2) ? '' : 'none'; // 3+: no apply --
    // this menu has no operand pickers, so it cannot say which two of three it would use.
  menu_selection_edit.style.display = n === 1 ? '' : 'none'; // One object has one editor.
  menu_selection_hide.textContent = nimSelectionAllHidden() ? 'show' : 'hide';
  closeSelectionMenuOp(); // Any fresh selection change resets picker closed.
  if (position_local) positionSelectionMenuAt(position_local); else updateSelectionMenuPosition();
  menu_selection.classList.add('show');
}

// Whether floating selection menu is currently up. Its own reader because it is now.
//   question click rule asks (see `pickOnClick`), not just class this file toggles.
function isSelectionMenuShown() {
  return menu_selection.classList.contains('show');
}

function hideSelectionMenu() {
  menu_selection.classList.remove('show');
  closeSelectionMenuOp();
  arity_menu_last = -1;
}

function positionSelectionMenuAt(position_local) {
  const rect = canvas.getBoundingClientRect();
  // Reserved right margin covers widest state this popover reaches: op-picker.
  //   row (select sized to its own longest notation, e.g. "𝐧 ∨ (𝐦 ∧ 𝐧☆)", plus "apply"/
  //   "back") now that select's own width is content-sized rather than truncated.
  menu_selection.style.left =
    Math.min(rect.left + position_local.x, window.innerWidth - 300) + 'px';
  menu_selection.style.top = Math.max(rect.top + position_local.y - 60, 8) + 'px';
}

function updateSelectionMenuPosition() {
  // Keep menu glued to most-recently-selected slot's own screen position every.
  //   frame it's open, generalizing old tap-menu's single-slot follow -- average
  //   across all selected would jump around as membership changes for no real benefit.
  if (!menu_selection.classList.contains('show') || slots_selection.length === 0) return;
  const slot_anchor = slots_selection[slots_selection.length - 1];
  const anchor = nimAnchorScreen(slot_anchor, canvas.clientWidth, canvas.clientHeight);
  if (anchor[2] <= 0.5) return; // Off-screen -- leave menu at its last valid spot.
  positionSelectionMenuAt({ x: anchor[0], y: anchor[1] });
}

menu_selection_apply.addEventListener('click', () => {
  // Serve both roles with one button: first press opens picker, second commits.
  //   Picker animates open to this same button's own right; button itself never moves
  //   or relabels.
  //   Second press commits with whatever operation is currently selected, instead of
  //   separate "go" button appearing once picker opens.
  if (!menu_selection_reveal.classList.contains('open')) {
    openSelectionMenuOp();
    return;
  }
  const n = slots_selection.length;
  if (n !== 1 && n !== 2) return; // Guard only -- apply is hidden for 0/3+ anyway.
  if (nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
  const first = slots_selection[0];
  const second = n === 2 ? slots_selection[1] : first; // Unary ignores second operand.
  const result = nimApplyOperation(parseInt(menu_selection_select.value, 10), first, second, now());
  toast(result.message);
  adoptConstructionSelection();
});
menu_selection_edit.addEventListener('click', () => {
  // Offer edit here, since reaching object's editor otherwise means hunting its row.
  //   Even with that object already picked and its own menu on screen.
  if (slots_selection.length !== 1) return; // Guard only -- hidden for 0 and 2+ anyway.
  openPanelTo(slots_selection[0]);
  hideSelectionMenu(); // Panel owns interaction now; pick itself stays.
});

menu_selection_back.addEventListener('click', closeSelectionMenuOp);

menu_selection_hide.addEventListener('click', () => {
  // Whichever way button reads is what it does, so objects it hid can be brought.
  //   back from same place -- `nimSelectionAllHidden` owns what "hidden" means for
  //   whole selection, way row button reads `nimItemVisible` for one object.
  const show = nimSelectionAllHidden();
  for (const slot of slots_selection) nimSetVisible(slot, show);
  toast((show ? 'Showed ' : 'Hid ') + slots_selection.length + ' object(s).');
  refreshSelectionMenu(null); // Relabels button for what it would now do.
  refreshObjectsUI(); // Selection itself is kept -- hiding doesn't invalidate slot.
});

menu_selection_delete.addEventListener('click', () => {
  const n = slots_selection.length;
  for (const slot of slots_selection) nimRemoveItem(slot);
  toast('Deleted ' + n + ' object(s).');
  clearSelection();
  refreshObjectsUI();
});

menu_selection_close.addEventListener('click', clearSelection);

document.addEventListener('pointerdown', (e) => {
  // Only tap/click landing outside canvas, menu itself, drawer.
  //   (interacting with Objects list/panel must not dismiss selection menu
  //   or clear selection), and top chip-row (save/load scene lives there too)
  //   should dismiss it here -- dismissing on canvas's own down event would race
  //   handleTap/endMouseDrag's own resolution of that same gesture.
  if (menu_selection.classList.contains('show') && !menu_selection.contains(e.target) &&
      e.target !== canvas && !drawer.contains(e.target) && !row_chip.contains(e.target)) {
    clearSelection();
  }
  // **Help is not dismissed by tap outside it**, unlike two popovers either side.
  //   of this. It is opened to be read *while* doing thing it describes -- that is
  //   whole reason it is cut by way of working rather than by kind of control -- and
  //   first touch of that thing used to close it, including touch on canvas. It goes
  //   when reader says so: its own close button, `?` that opened it, or escape.
  // Top menu: same shape of guard, its own state/target -- tap landing outside.
  //   popover and outside its own trigger button closes it.
  if (menu_top.classList.contains('show') && !menu_top.contains(e.target)
      && e.target !== button_menu
      && !button_menu.contains(e.target)) {
    menu_top.classList.remove('show');
    button_menu.classList.remove('on');
  }
});

/* ---------------------------------------------------------------------- */
/* Resize                                                                   */
/* ---------------------------------------------------------------------- */

// **Experiments: one suspect off at time, its cost read off rows.** Browser's main.
//   thread spends most of frame on device after callback returns (`style + layout +
//   paint` at 10.7 ms median of 16.7 on still scene), and page cannot tell apart from
//   inside what it spends it on: every backdrop blur over canvas that changes each
//   frame, canvas at full pixel ratio with antialiasing, or SVG overlay's paint. Each
//   pill switches one off at runtime; reader flips one, watches row, and reports.
//   None is saved: these are instruments, not settings.
let cap_ratio_pixel = 2.5;
function ratioPixel() {
  return Math.min(window.devicePixelRatio || 1, cap_ratio_pixel);
}
function wireExperiment(id, apply) {
  const toggle = document.getElementById(id);
  if (toggle === null) return;
  toggle.addEventListener('click', () => {
    const is_on = toggle.classList.toggle('on');
    apply(is_on);
  });
}
wireExperiment('toggle-blur', (is_on) => {
  document.body.classList.toggle('without-blur', !is_on);
});
wireExperiment('toggle-full-ratio', (is_on) => {
  cap_ratio_pixel = is_on ? 2.5 : 1;
  resize();
});
// Overlay's refresh stops with its paint.
//   Writing to layer with no layout cost `overlay + menu` 4.6 ms mean on device, which
//   is experiment's own artefact standing in page's column.
let is_overlay_shown = true;
wireExperiment('toggle-overlay', (is_on) => {
  is_overlay_shown = is_on;
  svg_overlay.style.display = is_on ? '' : 'none';
});

function resize() {
  const ratio_pixel = ratioPixel();
  const w = Math.round(canvas.clientWidth * ratio_pixel);
  const h = Math.round(canvas.clientHeight * ratio_pixel);
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
    gl.viewport(0, 0, w, h);
  }
  svg_overlay.setAttribute('viewBox', '0 0 ' + canvas.clientWidth + ' ' + canvas.clientHeight);
}
window.addEventListener('resize', resize);

/* ---------------------------------------------------------------------- */
/* Frame loop -- pull one frame's tessellated vertices and view-projection */
/* matrix out of compiled Nim module and upload them straight to GL.       */
/* ---------------------------------------------------------------------- */

let ms_refresh_ui = 0;

// **Browser's own rendering, timed by message posted as frame's callback ends.**
//   Message task runs once style, layout, paint and commit that follow callback are
//   done, so its lateness is main-thread share of `display wait + browser`; rest is
//   display and GPU wait. Cut of `idle`, kept out of every sum.
//   `MessageChannel` rather than `setTimeout(0)`: timers are clamped and, under load,
//   deferred behind rendering, and message is neither.
//   Message that still loses to next frame's callback says thread was busy until that
//   frame began, so reading is clamped to slot's whole remainder rather than left to
//   count next frame's work as well -- measured 24 ms on 16.7 ms frame before clamp.
//   One in flight at time. Gated on reader: message per frame is cheap, and still work
//   for nobody while panel is shut.
let is_render_pending = false;
let at_render = 0; // Slot frame that posted message was recorded in.
let ms_render_posted = 0;
function markRendered() {
  is_render_pending = false;
  let spent = performance.now() - ms_render_posted;
  if (index_history_frame !== at_render && written_phase.idle[at_render] === 1) {
    spent = Math.min(spent, history_phase.idle[at_render]);
  }
  history_phase.render[at_render] = spent > 0 ? spent : 0;
  written_phase.render[at_render] = 1;
}
const channel_render = new MessageChannel();
channel_render.port1.onmessage = markRendered;

// Draw one frame, and nothing else. Split out of `frame()` so PNG button can draw and.
//   read back **inside its own click**, without also re-running per-tick simulation that
//   frame() does around it. Mirrors `visualiser.renderFrame`, which is split same way and
//   for same reason: desktop's storyboard capture drives it directly too.
function renderFrame(now_seconds) {
  resize();
  const aspect = canvas.width / canvas.height;

  // **Fine breakdown is gathered only where it is being read.** Bridge times.
  //   placing and emitting halves of *every object*, so five-thousand-point scene reads
  //   clock three times per object per frame -- measured at 2.8 ms of 16 ms build,
  //   for rows that are not on screen unless this section is expanded. Per-kind
  //   *counts* still come back either way; only times are skipped. Same argument as
  //   pool grid, objects list and operand pickers.
  const data = nimBuildFrame(
    aspect, now_seconds, canvas.height, is_axes_shown, is_grid_shown, is_algebra_shown,
    !(drawer.classList.contains('open') && section_diagnostics.classList.contains('open')),
  );
  // Record bridge's own three phases into same rings this side's phases use.
  //   Bridge times them where only it can see them.
  recordPhaseTime('build', data.ms_build);
  // Frame's prologue and its view matrix, which used to belong to no row, and.
  //   residue named phases still fail to cover -- so `build` now sums from what is
  //   under it instead of merely being larger than sum.
  recordPhaseTime('camera', data.ms_camera);
  recordPhaseTime('matrix', data.ms_matrix);
  recordPhaseTime('unaccounted', data.ms_unaccounted);
  // Second cut: same milliseconds re-divided by which side of algebra.
  //   boundary they fell on. Recorded like any other row and kept out of every sum by
  //   `PHASES_CUT_DIAGNOSTIC`.
  recordPhaseTime('placing', data.ms_placing);
  recordPhaseTime('emitting', data.ms_emitting);
  // Measured between frames and reported by this one; see bridge's own note.
  recordPhaseTime('hover', data.ms_hover_pick);
  recordPhaseTime('furniture', data.ms_furniture);
  // Scenery's own two halves, which bridge has clocked apart since grid's.
  //   segment budget went in: axes are three lines at any distance, grid however
  //   many ground reach asks for, and only split says which of them moved.
  recordPhaseTime('grid', data.ms_grid);
  recordPhaseTime('axes', data.ms_axes);
  recordPhaseTime('scene', data.ms_scene);
  // Debug layer, beside scene rather than inside it, so per-kind rows still.
  //   account for scene exactly. Zero whenever layer is off, which is its resting
  //   state.
  recordPhaseTime('algebra', data.ms_algebra);
  recordPhaseTime('flatten', data.ms_flatten);
  // Scene phase broken out by kind of object each millisecond went to, with.
  //   counts kept beside them. Counts are latest rather than ringed: median count would
  //   lag deletion by two seconds and read as scene that still holds what it no longer
  //   does, while *time* wants its median precisely because single frame flickers.
  recordPhaseTime('points', data.ms_points);
  recordPhaseTime('lines', data.ms_lines);
  recordPhaseTime('planes', data.ms_planes);
  recordPhaseTime('sky', data.ms_sky);
  recordPhaseTime('ghost', data.ms_ghost);
  recordPhaseTime('selected', data.ms_selected);
  for (const name in COUNTS_DIAGNOSTIC) count_phase[name] = data[COUNTS_DIAGNOSTIC[name]];
  count_points_culled = data.count_points_culled;

  // **Every frame is drawn, still or moving.** Held frame could skip clear and draws.
  //   and leave compositor showing last presentation, and did for one round: on
  //   device it changed spikes not at all, and reader would rather still and moving
  //   frames behave alike than have still ones cheap. Records are still held above;
  //   that changes nothing about what is drawn or when.
  const ms_before_draw = performance.now();
  const ratio_pixel = ratioPixel();
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

  // Ribbon program's camera, once frame:
  //   widening runs in its vertex shader now, fed by exactly DrawScale fields mesh.expandRibbon
  //   reads.
  gl.useProgram(program_ribbon);
  gl.uniformMatrix4fv(ribbon_uniforms.mvp, false, data.view_projection);
  gl.uniform3f(ribbon_uniforms.eye, data.camera_eye_x, data.camera_eye_y, data.camera_eye_z);
  gl.uniform3f(ribbon_uniforms.forward,
    data.camera_forward_x, data.camera_forward_y, data.camera_forward_z);
  gl.uniform1f(ribbon_uniforms.depth_near, data.camera_depth_near);
  gl.uniform1f(ribbon_uniforms.tangent, data.camera_tangent_half_view);
  gl.uniform1f(ribbon_uniforms.height, data.camera_height_pixels);
  // Furniture fog's two radii, for fragment stage's fade of fogged records.
  gl.uniform1f(ribbon_uniforms.fog_full, data.fog_radius_full);
  gl.uniform1f(ribbon_uniforms.fog_gone, data.fog_radius_gone);

  // World furniture first, with normal depth test/write.
  //   One record segment now -- kept rather than re-uploaded where bridge says furniture is
  //   unchanged, since grid and axes are function of camera alone.
  //   Mirrors renderer.nim's own drawMeshes(MESHES_FURNITURE, ...) call exactly.
  if (!data.is_furniture_held) {
    count_furniture_held = uploadBuffer(data.furn_ribbon_verts, vbo.ribbon_furniture, 16);
  }
  drawRibbons(vbo.ribbon_furniture, count_furniture_held, 0, false);

  // Draw scene objects last, opaque kinds before translucent washes.
  //   Depth writes off for washes, so translucent plane never occludes line or point
  //   that happens to sit behind it; it only tints over whatever was already drawn
  //   there.
  //   Mirrors renderer.nim's own drawMeshes(MESHES, ...) call exactly.
  // Upload only where bridge rebuilt.
  //   Held frame's buffers already hold this frame's records, and re-uploading
  //   identical bytes is copy hold exists to skip.
  //   Draws below still run; framebuffer is cleared every frame.
  if (!data.is_scene_held) count_ribbon_held = uploadBuffer(data.ribbon_verts, vbo.ribbon, 16);
  const count_ribbon = count_ribbon_held;
  drawRibbons(vbo.ribbon, count_ribbon, data.ribbon_over, false);
  // Draw plane rims, one record each, straight after lines they are drawn like.
  //   Widening is ribbon program's own, so this program takes same six camera uniforms
  //   and same pass.
  gl.useProgram(program_ring);
  gl.uniformMatrix4fv(ring_uniforms.mvp, false, data.view_projection);
  gl.uniform3f(ring_uniforms.eye, data.camera_eye_x, data.camera_eye_y, data.camera_eye_z);
  gl.uniform3f(ring_uniforms.forward,
    data.camera_forward_x, data.camera_forward_y, data.camera_forward_z);
  gl.uniform1f(ring_uniforms.depth_near, data.camera_depth_near);
  gl.uniform1f(ring_uniforms.tangent, data.camera_tangent_half_view);
  gl.uniform1f(ring_uniforms.height, data.camera_height_pixels);
  if (!data.is_scene_held) count_ring_held = uploadBuffer(data.ring_records, vbo.ring, 14);
  const count_ring = count_ring_held;
  drawRings(count_ring, data.ring_over, false);
  // Point program's camera, once per frame, with both screen axes disc spans.
  //   Least diameter scaled by device pixel ratio, since `uHeightPixels` is framebuffer's.
  gl.useProgram(program);
  gl.uniformMatrix4fv(point_uniforms.mvp, false, data.view_projection);
  gl.uniform3f(point_uniforms.eye, data.camera_eye_x, data.camera_eye_y, data.camera_eye_z);
  gl.uniform3f(point_uniforms.forward,
    data.camera_forward_x, data.camera_forward_y, data.camera_forward_z);
  gl.uniform3f(point_uniforms.right,
    data.camera_right_x, data.camera_right_y, data.camera_right_z);
  gl.uniform3f(point_uniforms.up, data.camera_up_x, data.camera_up_y, data.camera_up_z);
  gl.uniform1f(point_uniforms.depth_near, data.camera_depth_near);
  gl.uniform1f(point_uniforms.tangent, data.camera_tangent_half_view);
  gl.uniform1f(point_uniforms.height, data.camera_height_pixels);
  gl.uniform1f(point_uniforms.diameter_least, DIAMETER_POINT_LEAST * ratio_pixel);
  gl.uniform1f(point_uniforms.ambient, AMBIENT_SHADE);
  if (!data.is_scene_held) count_point_held = uploadBuffer(data.point_verts, vbo.point, 11);
  const count_point = count_point_held;
  drawPoints(count_point, data.point_over, false);
  // Washes:
  //   one record disc or dome, fanned out by their own vertex shaders and walked in scene order
  //   through run list.
  //   Both programs get this frame's matrix before walk, which switches between them per run.
  gl.useProgram(program_disc);
  gl.uniformMatrix4fv(uniform_disc_mvp, false, data.view_projection);
  gl.useProgram(program_dome);
  gl.uniformMatrix4fv(uniform_dome_mvp, false, data.view_projection);
  if (!data.is_scene_held) {
    uploadBuffer(data.disc_records, vbo.disc, 13);
    uploadBuffer(data.dome_records, vbo.dome, 8);
  }
  gl.depthMask(false);
  drawWashRuns(data.wash_runs, data.wash_run_over, false);
  gl.depthMask(true);

  // Draw overlay over all of it, against depth buffer cleared first.
  //   Cleared rather than test turned off: nothing unselected is left to reject against,
  //   so selected object still shows through whatever stands before it, and selected
  //   objects reject one another by depth exactly as main pass does. With test off,
  //   emission order decided among them, and selected planet drawn after its moon
  //   buried moon standing in front of it.
  //   Second pass over every kind rather than tail on each: selected line drawn only
  //   after other lines is still tinted by plane's wash, which is later kind.
  //   Washes write no depth here either, as in main pass.
  //   Mirrors `renderer.drawMeshes`.
  if (data.ribbon_over + data.ring_over + data.point_over + data.wash_run_over > 0) {
    gl.clear(gl.DEPTH_BUFFER_BIT);
    gl.useProgram(program_ribbon);
    drawRibbons(vbo.ribbon, count_ribbon, data.ribbon_over, true);
    gl.useProgram(program_ring);
    drawRings(count_ring, data.ring_over, true);
    gl.useProgram(program);
    drawPoints(count_point, data.point_over, true);
    gl.depthMask(false);
    drawWashRuns(data.wash_runs, data.wash_run_over, true);
    gl.depthMask(true);
  }
  // Command submission only:
  //   GL runs asynchronously, so what CPU clock can honestly bracket here is upload and draw-call
  //   issue, not GPU's own work.
  recordPhaseTime('upload', performance.now() - ms_before_draw);
}

function frame() {
  const now_seconds = now();

  const now_milliseconds = performance.now();
  const seconds_frame = (now_milliseconds - time_frame_last) / 1000;
  recordFrameTime(now_milliseconds - time_frame_last);
  time_frame_last = now_milliseconds;

  // Move camera by one frame's worth of whatever key is held, before drawing.
  //   Scaled by frame's own elapsed time, so hold travels same distance on 60 Hz screen
  //   and 144 Hz one.
  //   Which way it moves camera is `interaction.driveHeld`'s to say, never this file's.
  nimDriveHeld(seconds_frame);
  settleTwoFingers();

  // Press that has now lasted long enough selects its item. Checked here rather than by.
  //   timer that fires on its own, so that moment marker finishes filling is
  //   moment selection lands -- `interaction.isHoldMature` is stated against same
  //   progress marker was just drawn at, so two cannot disagree by frame.
  // One question, not two.
  //   Asking "is it mature" beside flag kept here for "have I already acted on that" needs two to
  //   agree, and they stopped agreeing once hold outlived its own release:
  //   this handler clears its flag on lift while hold is still settling and still mature, so next
  //   frame selected item again and toggled it straight back off.
  //   `nimTakeMaturedHold` answers once and never again.
  const slot_matured = nimTakeMaturedHold(now_seconds);
  if (slot_matured >= 0) {
    // Selected, but hold is **kept**:
    //   its marker stays swollen clear of finger for as long as that finger is down, and settles
    //   only once `nimReleaseHold` says it may.
    has_long_press_fired = true; // Still needed, to stop release also reading as tap.
    toggleSelection(slot_matured, position_touch_down);
  }
  // And retire it once that settle is spent, so finished hold stops being drawn at all.
  if (nimIsHoldSpent(now_seconds)) nimCancelHold();

  // Recompute what drag in progress would build, and whether its dwell has come due.
  //   Before frame that ghosts answer is assembled.
  //   Runs every frame rather than on pointermove alone: dwell is time passing over
  //   cursor that is deliberately still, so there is no move event to hang it off.
  //   Mirrors `visualiser.renderFrame`'s order.
  // Take one dolly and one pick per frame, whatever pointer reported.
  //   Device reporting faster than display would otherwise pay for answers nobody read:
  //   `picking.pickNearest` walks every live slot.
  //   Coalesced here, after `nimDriveHeld` so camera is where this frame will draw it,
  //   and before drag update and build so both read answer this frame's cursor
  //   deserves.
  //   Presses do not come through here.
  //     `pointerdown`, touch-down and `handleTap` each need hover reading before their
  //     own handler returns, since `nimBeginDrag`, `slot_touch_down` and selection are
  //     decided from it, so they pick on spot and are only paths that still do.
  if (deltas_wheel !== 0) {
    nimCameraDollyAt(
      Math.exp(deltas_wheel * 0.0012), canvas.clientWidth, canvas.clientHeight,
    );
    deltas_wheel = 0;
    is_hover_stale = true; // Camera moved under cursor that did not.
  }
  if (is_hover_stale) {
    is_hover_stale = false;
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
  }

  if (nimDragActive()) nimUpdateDrag(now_seconds);

  renderFrame(now_seconds);

  // Immediately after last draw call and before this callback yields, which is only.
  //   moment drawing buffer is still there to read; see `captureFrameIfAsked`.
  captureFrameIfAsked();

  const ms_before_overlay = performance.now();
  if (is_overlay_shown) refreshOverlay(cursor_last);
  updateSelectionMenuPosition();
  // Menu placement folded in with markers rather than kept as row of its own: it is.
  //   one early-returning call reading 0.00 in every state but one, and its old bracket
  //   enclosed overlay's own `recordPhaseTime` -- so that row had been charging its
  //   bookkeeping to itself.
  recordPhaseTime('overlay', performance.now() - ms_before_overlay);

  // Refresh UI (camera fields, diagnostics) at lower cadence than draw loop.
  //   No visual harm in number lagging frame, and it keeps DOM writes off hot path.
  //   Paced by clock rather than by frame count, so readings settle over same window
  //   they are averaged over however fast or slow machine is drawing.
  //     Fixed frame count is fraction of second on desktop and much longer on
  //     labouring phone, and digits would change at whichever of those reader happened
  //     to be on.
  // Redraw travelling axis at frame's own rate.
  //   Panel refreshes few times second, which would show glide as steps rather than
  //   movement.
  //   Only while it travels, and only while curve is actually on screen. On frame
  //   rather than in idle time, since it is animation; charged to `ui` like rest.
  if (is_axis_gliding && isDiagnosticsShown()) {
    const ms_before_glide = performance.now();
    drawExceedance();
    addPhaseTime('ui', performance.now() - ms_before_glide);
  }
  const ms_now_ui = performance.now();
  // One reading for every kind of UI work this frame did, through `addPhaseTime`:
  //   glide redraw above, tick here and slow pass in idle time after all land in same
  //   slot. Row build runs every frame while it has rows left; rest runs on its own
  //   five-a-second cadence; frame doing neither leaves slot unwritten.
  const is_ticking_ui = ms_now_ui - ms_refresh_ui >= MILLISECONDS_WINDOW_READING;
  if (is_ticking_ui || rows_pending !== null) {
    const ms_before_ui = performance.now();
    sliceObjectRows();
    if (is_ticking_ui) {
      ms_refresh_ui = ms_now_ui;
      refreshCameraFields();
      refreshRuler();
      refreshDiagnostics();
      refreshUndoRedoButtons(); // catches every history-touching path this tick's own
        // click handlers above don't reach directly (add, apply, remove, load demo,
        // scene load/clear).
      syncOperandsToSelection(); // catches selection changes from tap-to-select too.
      refreshAddButton(); // catches paths that fill or empty scene without click.
    }
    addPhaseTime('ui', performance.now() - ms_before_ui);
  }

  // Time browser's rendering of this frame; see `markRendered`.
  if (!is_render_pending && isDiagnosticsShown()) {
    is_render_pending = true;
    at_render = index_history_frame;
    ms_render_posted = performance.now();
    channel_render.port2.postMessage(0);
  }

  requestAnimationFrame(frame);
}

refreshObjectsUI();
refreshUndoRedoButtons();
requestAnimationFrame(frame);
