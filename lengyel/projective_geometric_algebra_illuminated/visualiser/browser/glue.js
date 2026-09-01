"use strict";

/* ---------------------------------------------------------------------- */
/* Everything above this script is the actual `pga`, `objects`, `mesh`,    */
/* `camera`, `scene`, `picking`, `interaction` and `storyboard` Nim        */
/* modules, compiled to JS through Nim's own `nim js` backend from         */
/* `visualiser/browser_bridge.nim` -- every join, meet, attitude, support, */
/* expansion, projection, pick, drag and camera move below runs that same  */
/* compiled code, not a JS reimplementation of it. This script is only the */
/* presentation layer WebGL, the DOM and pointer input need -- the same    */
/* role OpenGL/SDL/Dear ImGui play over the desktop app's own identical    */
/* CPU-side geometry. See `browser_bridge.nim`'s own doc comment for what  */
/* deliberately does NOT carry over (native-only diagnostics, C-FFI-based  */
/* number formatting) and why.                                            */
/* ---------------------------------------------------------------------- */

const canvas = document.getElementById('gl');
// No `preserveDrawingBuffer`, deliberately: it makes every frame keep a copy of the drawing
//   buffer for the whole session, on a phone, so that a button pressed once can read it
//   afterwards. `captureFrameIfAsked` reads the buffer from inside the frame that drew it
//   instead, which costs nothing and is what the image export uses.
const gl = canvas.getContext('webgl', { antialias: true, alpha: false })
  || canvas.getContext('experimental-webgl', { antialias: true, alpha: false });

const SOURCE_VERTEX = `
  attribute vec3 aPosition;
  attribute vec4 aColor;
  uniform mat4 uMVP;
  uniform float uPointSize;
  varying vec4 vColor;
  void main() {
    gl_Position = uMVP * vec4(aPosition, 1.0);
    gl_PointSize = uPointSize;
    vColor = aColor;
  }
`;
const SOURCE_FRAGMENT = `
  precision mediump float;
  varying vec4 vColor;
  uniform bool uRound;
  void main() {
    if (uRound) {
      vec2 d = gl_PointCoord - vec2(0.5);
      if (dot(d, d) > 0.25) discard;
    }
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
gl.attachShader(program, compileShader(gl.VERTEX_SHADER, SOURCE_VERTEX));
gl.attachShader(program, compileShader(gl.FRAGMENT_SHADER, SOURCE_FRAGMENT));
gl.linkProgram(program);
if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
  throw new Error(gl.getProgramInfoLog(program));
}
gl.useProgram(program);

const attribute_position = gl.getAttribLocation(program, 'aPosition');
const attribute_colour = gl.getAttribLocation(program, 'aColor');
const uniform_view_projection = gl.getUniformLocation(program, 'uMVP');
const uniform_size_point = gl.getUniformLocation(program, 'uPointSize');
const uniform_is_round = gl.getUniformLocation(program, 'uRound');

// Read from renderer.nim's own constants via nimRenderLineWidths, rather than a hand-
// copied literal that could drift out of sync with them.
// `SIZE_POINT` is still a draw-call setting here, since `gl_PointSize` is honoured. The
// two line widths are not: each ribbon record carries its width and the ribbon vertex
// shader widens it, because WebGL clamps `gl.lineWidth` to one pixel on most
// implementations.
const [SIZE_POINT] = nimRenderLineWidths();

// A sibling copy of `mesh.expandRibbon` -- the reference the suite pins to the algebra --
// and of the GLSL 3.30 source in `renderer.nim`; a change to any one of the three is not
// finished until the other two are checked. Widens one 16-float ribbon record into the
// corner this invocation is: clip to the near plane, blend the clipped end's tint by the
// same fraction, derive the across as the cross the join reduces to, and step off by half
// a width of this end's own world-per-pixel.
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
// A sibling copy of `mesh.alphaGridFade` -- the reference the fog is held to -- and of
// the GLSL 3.30 fragment source in `renderer.nim`; a change to any one of the three is
// not finished until the other two are checked. Per fragment rather than per vertex, so
// the fade is exact along a record of any length -- which is what lets a lattice line be
// one record instead of a chain of fade pieces. A record with fog zero passes through
// untouched, which is every scene ribbon.
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
// Instancing is an extension on WebGL1 and universally shipped; a context without it gets
// the same loud failure a context without WebGL gets, not a silent picture with no lines.
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
// The six (end, side) corners of one ribbon instance, in `expandRibbon`'s own winding.
const buffer_ribbon_corners = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, buffer_ribbon_corners);
gl.bufferData(gl.ARRAY_BUFFER,
  new Float32Array([0, -1, 1, -1, 1, 1, 0, -1, 1, 1, 0, 1]), gl.STATIC_DRAW);

// A sibling copy of `mesh.expandDiscVertex` -- the reference the suite pins -- and of the
// GLSL 3.30 source in `renderer.nim`; a change to any one of the three is not finished
// until the other two are checked. Fans one 13-float disc record over the static corner
// buffer: each corner is the centre plus the two radius-scaled arms weighted by its own
// cosine and sine, with `(0, 0)` landing the centre corner on the centre exactly.
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
// A sibling copy of `mesh.expandDomeVertex`, under the same three-way rule: each corner
// is the centre plus its own unit direction scaled by the radius.
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
// A sibling copy of `mesh.expandRingVertex` -- the reference the suite pins -- and of the
// GLSL 3.30 source in `renderer.nim`; a change to any one of the three is not finished
// until the other two are checked. One 14-float ring record is a plane's whole rim: the
// static corner buffer carries every segment of the closed walk, so this one instance
// draws all `SEGMENTS_CIRCLE_HORIZON` of them.
//   Two steps, and the second is not new. Place the segment's ends on the circle exactly
// as the disc source places its fan corners -- `centre + cos*arm_first + sin*arm_second`
// -- and then widen that pair by *the ribbon source's own body*, verbatim: the near clip,
// the across the join reduces to, and half a width of this end's world-per-pixel. A rim
// is a line, and there is one rule for how wide a line is drawn.
//   The tint is flat, so the ribbon's blend between two ends collapses to `aFill`, and the
// fog is always zero, so this shares the plain fragment stage rather than the ribbon's
// fading one.
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
  // Shares the plain fragment stage, whose point-rounding is off unless asked.
  gl.useProgram(handle);
  gl.uniform1i(gl.getUniformLocation(handle, 'uRound'), 0);
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
// The very six the ribbon program takes, since the widening is the ribbon's own.
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
// The static corner geometry both wash shaders fan records over, read from mesh.nim's
// own generators rather than a hand-copied table that could drift from the references.
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
// Every segment of the rim, six corners each, so one ring record draws the whole circle.
const CORNERS_RING = new Float32Array(nimRingCorners());
const COUNT_CORNERS_RING = CORNERS_RING.length / 6;
const buffer_ring_corners = gl.createBuffer();
gl.bindBuffer(gl.ARRAY_BUFFER, buffer_ring_corners);
gl.bufferData(gl.ARRAY_BUFFER, CORNERS_RING, gl.STATIC_DRAW);

const vbo = {
  disc: gl.createBuffer(), dome: gl.createBuffer(), ring: gl.createBuffer(),
  ribbon: gl.createBuffer(), point: gl.createBuffer(),
  ribbon_furniture: gl.createBuffer(),
};
const STRIDE = 7 * 4;
const STRIDE_RIBBON = 16 * 4;
const STRIDE_DISC = 13 * 4;
const STRIDE_DOME = 8 * 4;
const STRIDE_RING = 14 * 4;

// How many furniture vertices its own buffer holds, carried between frames because the
// bridge stops sending them once the camera is still; see `renderFrame`.
let count_furniture_held = null;
// And the same for the scene's own buffers, carried for the same reason one layer out: a
// frame the bridge reports as held has uploaded nothing, so what stands in each buffer is
// the last frame's -- correct, since the bridge only says held when it would have written
// the very same bytes. See `FrameData.is_scene_held`.
let count_ribbon_held = null;
let count_ring_held = null;
let count_point_held = null;

// One mesh handed to the driver whole, ready to be drawn as one run or two. Separate
// from drawing because the two runs go out in different passes (see the draw loop below),
// and a mesh uploaded twice a frame would be the one real cost of that split.
// The bridge fills `Float32Array`s the page owns and hands back views on them, so there is
//   nothing to convert here and nothing to stage: the driver reads the very memory the
//   flatten wrote. A staging array used to sit here, refilled element by element from the
//   boxed `Array` a `seq[float32]` is on the JS backend -- see `browser_bridge.FlatBuffer`
//   for what that cost and why it is gone. Anything else reaching this is a mistake worth
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

// One run of an uploaded record buffer, drawn as instanced triangle pairs. `count_over`
// is how many records at the END are the overlay run, exactly as `drawRun`'s split below;
// a run that does not start at the first record re-points the five instance attributes at
// its own first byte, since WebGL1 has no base instance. Mirrors `renderer.drawRibbonRun`.
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
  // Divisors are context state, not program state: left at one they would corrupt the
  //   plain program's reads of these same attribute indices next draw.
  for (const attrib of [ribbon_attribs.tail, ribbon_attribs.head, ribbon_attribs.width,
    ribbon_attribs.fog, ribbon_attribs.tint_tail, ribbon_attribs.tint_head]) {
    instanced.vertexAttribDivisorANGLE(attrib, 0);
    gl.disableVertexAttribArray(attrib);
  }
}

// One run of the uploaded ring buffer, drawn as instanced rims: each instance is a whole
// plane's circle, `COUNT_CORNERS_RING` corners of it. Splits its two runs exactly as
// `drawRibbons` does, and re-points the five instance attributes at the run's own first
// byte for the same reason -- WebGL1 has no base instance. Mirrors `renderer.drawRingRun`.
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
  // Divisors are context state, not program state: left at one they would corrupt the
  //   plain program's reads of these same attribute indices next draw.
  for (const [attrib] of records) {
    instanced.vertexAttribDivisorANGLE(attrib, 0);
    gl.disableVertexAttribArray(attrib);
  }
  for (const [attrib] of [[ring_attribs.arc], [ring_attribs.corner]]) {
    gl.disableVertexAttribArray(attrib);
  }
}

// One instanced wash draw: `record_attribs` re-pointed at the run's first record (WebGL1
// has no base instance), corner attrib from the static buffer, divisors reset after --
// they are context state, and left at one they would corrupt the plain program's reads
// of the same attribute indices. Shared by the disc and dome runs below.
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

// Walk one pass's stretch of the wash draw order -- `wash_runs` is [kind, first, count]
// per run, `count_runs_over` how many runs at the END are the overlay stretch -- drawing
// each run through its own kind's program so two washes still blend in the order the
// scene emitted them. Mirrors `renderer.drawWashRuns`.
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

// `count_over` is how many vertices at the END of the uploaded mesh are its overlay run;
// `is_overlay` picks which of the two runs to draw. Mirrors `renderer.drawRun`.
function drawRun(handle_buffer, count, mode, are_points_round, count_over, is_overlay) {
  if (!count) return;
  const split = Math.max(0, count - Math.min(count_over || 0, count));
  const first = is_overlay ? split : 0;
  const span = is_overlay ? count - split : split;
  if (span === 0) return;
  gl.bindBuffer(gl.ARRAY_BUFFER, handle_buffer);
  gl.enableVertexAttribArray(attribute_position);
  gl.vertexAttribPointer(attribute_position, 3, gl.FLOAT, false, STRIDE, 0);
  gl.enableVertexAttribArray(attribute_colour);
  gl.vertexAttribPointer(attribute_colour, 4, gl.FLOAT, false, STRIDE, 12);
  gl.uniform1i(uniform_is_round, are_points_round ? 1 : 0);
  gl.drawArrays(mode, first, span);
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
/* the compiled Nim module; this file only tracks what the DOM needs to   */
/* reflect and drive it.                                                  */
/* ---------------------------------------------------------------------- */

nimInit(performance.now() / 1000);
let is_axes_shown = true, is_grid_shown = true;
// The debug layer, off by default: it draws every multivector the frame computed, with a
//   plane drawn as the infinite lattice it actually is rather than as the disc that stands
//   for one. A reader switches it on to see the algebra rather than the illustration of it.
let is_algebra_shown = false;

function now() { return performance.now() / 1000; }

/* ---------------------------------------------------------------------- */
/* Selection: ordered multi-select, shared by touch long-press/tap and     */
/* mouse click/shift-click -- see the pointer-input section below for the  */
/* full gesture design. Nim's own `selection.nim` holds it, through the    */
/* `nimSelect*` exports: pick order is what names an operation's operands  */
/* m and n, and that rule belongs beside every other rule about a          */
/* selection rather than in a second implementation over here. Every       */
/* construction path already writes the selection itself, so there is no   */
/* two-way sync to keep -- only a read.                                    */
/*                                                                          */
/* `slots_selection` below is a render snapshot of that answer, not a copy  */
/* with rules of its own: the frame loop's overlay reads it dozens of       */
/* times a second and must not cross the JS/Nim boundary to do it.          */
/* ---------------------------------------------------------------------- */

let slots_selection = []; // Ordered: first-picked first (-> operand m), second (-> n).

function refreshSelectionSnapshot() {
  slots_selection = nimSelectionSlots();
}

function onSelectionChanged(position_local) {
  refreshSelectionSnapshot();
  refreshSelectionMenu(position_local);
  refreshObjectsUI(); // Also re-syncs the apply controls and the row checkboxes.
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

// What a click on an object does, given which button made it and whether shift was held.
//   **Two independent questions**, and keeping them independent is the whole design: the
//   button says whether the selection menu comes up (`nimRevealsMenuOnButton`), shift says
//   whether the click adds to the selection or replaces it. Left picks silently, right picks
//   and shows the menu, and either of them with shift adds or drops instead.
//   **A null position does not mean "no menu"** -- `refreshSelectionMenu(null)` still shows
//   the menu, positioned from the selection rather than from the cursor, which is what the
//   keyboard path wants. So a non-revealing click hides it afterwards rather than hoping the
//   argument covered it. That misreading shipped once here and the left button kept popping
//   a menu it was supposed to have given up.
//   Both branches live here rather than at the two call sites, which used to hold a copy
//   each of the shift test.
function pickOnClick(slot, button, is_shifted) {
  const reveals = nimRevealsMenuOnButton(button);
  // A selection already standing with its menu dismissed is a reader who wants that menu
  //   back, not one who wants to throw the selection away -- so reveal it and pick nothing.
  //   The rule is Nim's, asked rather than restated, since the desktop asks the same one.
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
  // Every construction path already picked its own new object (see nimAddItem/
  //   nimApplyOperation/nimEndDrag's own doc comments), or cleared the selection
  //   (nimLoadDemo/nimUndo/nimRedo on success) -- this only picks that outcome up.
  refreshSelectionSnapshot();
  hideSelectionMenu(); // A construction action never itself opens the selection menu --
    // matches today's behaviour (add/apply/drag never popped the tap-menu either).
  refreshObjectsUI();
}

/* ---------------------------------------------------------------------- */
/* Toast: outcome of the last action, matching the desktop panel's own    */
/* one-line status message, shown transiently rather than pinned.         */
/* ---------------------------------------------------------------------- */

const element_toast = document.getElementById('toast');
let timer_toast = null;
function toast(message) {
  // An empty message is one the caller decided not to say -- a drag released over empty
  // space, say -- and showing an empty bar for it is worse than saying nothing. The desktop
  // has always guarded its own status line this way; this is that guard, on this side.
  if (!message) return;
  element_toast.textContent = message;
  element_toast.classList.remove('actionable');
  element_toast.classList.add('show');
  clearTimeout(timer_toast);
  timer_toast = setTimeout(() => element_toast.classList.remove('show'), 3200);
}

function toastWithLink(message, url, filename, label, url_image) {
  // A toast the reader can act on, held until dismissed. For the one case a page cannot
  //   resolve on its own: a file is ready and every automatic route to it may have been
  //   refused, silently, by a frame this page does not control. A tap the *reader* makes on
  //   a real anchor is the most permitted route there is, so offer that rather than assert
  //   a download happened.
  element_toast.textContent = '';
  const line = document.createElement('div');
  line.textContent = message;
  const link = document.createElement('a');
  link.className = 'toast-action';
  link.href = url;
  link.download = filename;
  link.textContent = label;
  link.rel = 'noopener';
  // `url_image` set means the file is one the reader can save straight off the screen, and
  //   showing it is worth the space: drawing a blob into an `<img>` is not a navigation, so
  //   it is the only route measured to survive a frame sandboxed without `allow-downloads`
  //   -- where a press on the anchor above is refused in silence, as is every automatic
  //   route. Offered beside the link, never instead of it, since where downloads *are*
  //   permitted the link is one tap and this is a press-and-hold.
  const preview = document.createElement('img');
  const hint = document.createElement('div');
  if (url_image !== undefined) {
    preview.className = 'toast-preview';
    preview.src = url_image;
    preview.alt = filename;
    hint.className = 'toast-hint';
    hint.textContent = 'or press and hold the image to save it';
  }
  // Something to do about it, in words, above the evidence. Measured on an Android phone in
  //   the Claude app: that frame withholds `allow-downloads`, `allow-popups` and the
  //   `web-share` policy all three, so no route from inside it can produce a file and no
  //   amount of further work here will change that. Saying so is more use than a link that
  //   cannot fire, and the same page opened as its own tab downloads normally.
  const advice = document.createElement('div');
  advice.className = 'toast-hint';
  advice.textContent = 'If nothing arrives, this frame is blocking it — '
    + 'open this page in its own browser tab and save from there.';
  // What was tried and what came back, beside the thing it was tried on. Every round of
  //   this fault so far ended with a reader who could only report "nothing happened"; this
  //   is what turns the next report into a diagnosis.
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
/* Handing a file to the reader.                                          */
/*                                                                        */
/* One route for the scene file and the image alike. It used to be five   */
/* statements written out twice -- build a Blob, make an `<a download>`,  */
/* click it -- with the anchor never put in the document. A detached      */
/* anchor's synthetic click is ignored by Safari outright and is          */
/* unreliable elsewhere, so saving anything from a phone did nothing at   */
/* all, while the caller toasted "Saved" regardless. Both halves of that  */
/* are fixed here: the routes below are tried in order of how likely the  */
/* platform is to honour them, and nothing claims a file was written.     */
/* ---------------------------------------------------------------------- */

// What the last delivery attempt tried and what came back, kept for the reader to read.
//   Three rounds of this fault were spent guessing because every refusal was silent: the
//   share sheet failed with its reason swallowed, and a download a frame refuses raises no
//   event at all. A page that cannot say what happened cannot be debugged from a phone
//   nobody here can reach, so the outcomes are recorded rather than inferred.
let report_delivery = [];

function describeEnvironment() {
  // Read at delivery time, not at load: transient activation is the whole question for the
  //   share route and is only meaningful during the gesture that asked.
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
  // `canShare` is a preference, never a precondition, and this is the second time that
  //   distinction has cost a route: gating on it skipped `share` outright, first on any
  //   platform shipping one without the other, then -- once that was fixed but the `false`
  //   still returned early -- on a frame where `canShare` says no for a reason that is not
  //   the platform's to give. So a `false` is *reported* and the attempt made anyway; only
  //   a missing `share` is grounds not to try.
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
    // Cancelling the sheet is a decision, not a failure -- report it and stop trying.
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

  // 1. The share sheet, where the platform has one. The route that actually works on a
  //    phone, and the only one that does not care whether this frame may download. Both
  //    callers run inside a click, so the transient activation it needs is present -- see
  //    `captureFrameIfAsked` on what it cost to make that true of the image too.
  if (await shareFile(file, filename)) {
    if (report_delivery[report_delivery.length - 1] === 'share: opened') {
      toast('Shared `' + filename + '`.');
    }
    return;
  }

  const url = URL.createObjectURL(blob);
  // 2. A real anchor, **in the document**. Appending is the whole of the original fix; a
  //    click on an element that is not in the page is what browsers were discarding.
  //    Measured in a frame granted `allow-downloads`: this fires a real download, and so
  //    does a reader's own tap on route 4. Neither does in a frame without it, in silence.
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = filename;
  anchor.style.display = 'none';
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  report_delivery.push('download: no signal');

  // 3. A tab of its own, which a frame that refuses a download may still permit. Expected to
  //    fail from a sandbox, since a `blob:` URL minted in an opaque origin resolves nowhere
  //    else -- but a `null` return says "blocked" out loud, which is one more thing the
  //    reader's report can rule out rather than leave open.
  if (window.self !== window.top) {
    const opened = window.open(url, '_blank');
    report_delivery.push('new tab: ' + (opened === null ? 'blocked' : 'opened'));
  }

  // 4. A link to tap, always. There is no event for "the download was refused" -- a framed
  //    page whose host withholds `allow-downloads` gets silence -- so rather than guess
  //    which happened, leave the reader a route they drive themselves. Framed is the case
  //    that needs it and the case this page ships in; unframed it is a harmless second way.
  //    An image goes on screen with it, which a refused frame cannot take away.
  if (window.self !== window.top) {
    report_delivery.push('link: offered');
    toastWithLink(
      described + ' is ready.', url, filename, 'save ' + filename,
      mime.startsWith('image/') ? url : undefined,
    );
  } else {
    toast('Handed `' + filename + '` to the browser to download.');
    // Long enough for the navigation to have started, and for a tap on the link above.
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    return;
  }
  // Held far longer than the old four seconds, since the link is the reader's to use.
  setTimeout(() => URL.revokeObjectURL(url), 600000);
}

/* ---------------------------------------------------------------------- */
/* Drawer + collapsible sections                                          */
/* ---------------------------------------------------------------------- */

// Every transition in the stylesheet runs to these, so the browser eases over the same
//   duration and curve the appear animation does -- `nimAnimationMilliseconds` is
//   `mesh.ANIMATION_MILLISECONDS`, and the bezier is easeOutCubic written for CSS.
document.documentElement.style.setProperty('--anim', nimAnimationMilliseconds() + 'ms');
document.documentElement.style.setProperty('--ease', 'cubic-bezier(0.215, 0.61, 0.355, 1)');

const drawer = document.getElementById('drawer');
const row_chip = document.querySelector('.chip-row');
const button_drawer = document.getElementById('btn-drawer');
button_drawer.addEventListener('click', () => {
  const open = drawer.classList.toggle('open');
  button_drawer.classList.toggle('on', open);
});

// Top menu: one popover holding every top-bar action (undo/redo, axes/grid, save/load
//   scene, save PNG/load demo) that used to be spread across four separate chip-row
//   pill-groups -- each button inside keeps its own pre-existing #id-based wiring
//   unchanged below; this only owns the popover's own open/close.
const menu_top = document.getElementById('top-menu');
const button_menu = document.getElementById('btn-menu');
button_menu.addEventListener('click', () => {
  const open = menu_top.classList.toggle('show');
  button_menu.classList.toggle('on', open);
});

document.querySelectorAll('.section-header').forEach((header) => {
  header.addEventListener('click', () => {
    header.parentElement.classList.toggle('open');
    // The apply section's own preview lives exactly as long as the section is on screen,
    // so opening one starts it and collapsing one ends it. Asked of every section rather
    // than only that one: the check reads the section's own class either way, and a
    // handler that knew which section it was would be a second place to keep in step.
    ghostDrawerOperation();
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
/* Help: the ? button says it whenever asked.                             */
/* ---------------------------------------------------------------------- */

// A pill naming a few gestures used to greet every load and leave on the reader's first
//   action. The panel below outgrew it -- it lists every path and every operation, on
//   demand and for as long as the reader wants -- and a page that explains itself when
//   asked does not need to explain itself unasked. The five gestures that dismissed the
//   pill now dismiss nothing, which is why no call replaced them.

// Built from `help.lut_help_entries` across the bridge, so this panel and the desktop's
//   own say the same thing by construction. Four strings per entry; see nimHelpEntries.
//   One tab per path, because a reader opens this in the middle of one way of working and
//   only that way's rows are any use to them right then. The tab a row belongs to is the
//   core's answer -- the first of its four strings -- so this builds a strip out of the
//   paths it actually sees rather than naming them here and drifting from the table.
const button_help = document.getElementById('btn-help');
const panel_help = document.getElementById('help-panel');
const strip_help = document.getElementById('help-tabs');
const rows_help = document.getElementById('help-rows');
const note_help = document.getElementById('help-description');
const descriptions_help = new Map();
function buildHelp() {
  // What each tab is about, in one sentence, keyed by the very title the rows are grouped
  //   by -- so the two exports join on a string rather than on a matching order.
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
  // Every row stays in the DOM and is hidden by attribute rather than rebuilt per tab:
  //   the table never changes at runtime, so rebuilding would be work to no end, and a
  //   test can count what each tab holds without switching to it.
  for (const tab of strip_help.children) {
    const is_open = tab.dataset.path === path;
    tab.classList.toggle('on', is_open);
    tab.setAttribute('aria-selected', is_open ? 'true' : 'false');
  }
  for (const row of rows_help.children) {
    row.hidden = row.dataset.path !== path;
  }
  // Swapped with the tab rather than one note per tab hidden alongside its rows: there is
  //   only ever one showing, so one element that changes text cannot go stale.
  note_help.textContent = descriptions_help.get(path) || '';
  rows_help.scrollTop = 0; // A tab always opens at its own first row.
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
/* not on this timeline. A step carries the view its edit was made from,   */
/* so the camera moves under these too; an orbit alone is not a step.      */
/* ---------------------------------------------------------------------- */

const button_add = document.getElementById('btn-add');
const button_undo = document.getElementById('btn-undo');
const button_redo = document.getElementById('btn-redo');

function openApplyPickerOnOperands(position_local) {
  // Where the drag menu's `more…` lands: `nimEndDrag` has already selected both operands
  //   in the order they were dragged, so this only has to open the picker that reads that
  //   selection. Refusing to open it would make `more…` a dead end, which is exactly what
  //   it exists to stop the gesture being.
  //   **The hover menu's picker, not the drawer's apply section.** `more…` is a fifth
  //   choice on a wheel that opened under the cursor, and sending it to a panel down the
  //   side of the screen threw the hand across the viewport and buried the two objects it
  //   had just named under a list of every other control. The picker lands where the wheel
  //   was, already open, already holding the last operation of that arity.
  refreshSelectionSnapshot();
  refreshObjectsUI();
  refreshSelectionMenu(position_local);
  if (menu_selection_apply.style.display !== 'none') openSelectionMenuOp();
}

// **A settled scroll, not a single jump.** A row outside the viewport is a placeholder
//   rather than a laid-out row -- see `.item-row`'s `content-visibility` in `shell.html` --
//   so the offset of a row a thousand places down the list is an estimate until the rows
//   above it have actually been measured. One `scrollIntoView` lands on the estimate:
//   measured on slot 900 of the demo, the row arrived 428px lower than it should have,
//   leaving the edit form it was opening off the bottom of the screen. Each pass lays out
//   the rows it scrolls past, so the estimate is exact where it matters by the next one.
//   Stops as soon as the row holds still, which on a list short enough to be laid out
//   whole is immediately.
const PASSES_SCROLL_SETTLE = 4;
function scrollRowIntoView(row, passes = PASSES_SCROLL_SETTLE) {
  row.scrollIntoView({ block: 'nearest' }); // A long list can open past it.
  if (passes <= 1) return;
  const settled = row.getBoundingClientRect().top;
  requestAnimationFrame(() => {
    if (Math.abs(row.getBoundingClientRect().top - settled) < 1) return;
    scrollRowIntoView(row, passes - 1);
  });
}

function openPanelTo(slot) {
  // Open an edit session on `slot` (or a composing one where null) and bring the drawer
  //   and the Objects section far enough open to see it -- shared by the top bar's `add`
  //   and the selection menu's `edit`, which differ only in what they open onto.
  beginEditSession(slot);
  document.querySelector('.section[data-section="objects"]').classList.add('open');
  drawer.classList.add('open');
  button_drawer.classList.add('on');
  refreshObjectsUI();
  const row = list_objects.querySelector(
    slot === null ? '.item-row.pending-item' : '.item-row[data-slot="' + slot + '"]');
  if (row) scrollRowIntoView(row);
}

button_add.addEventListener('click', () => {
  // Compose a new object as a row in the Objects list rather than in a section of its
  //   own: adding and editing stage the same four things through the same interface, so
  //   there is one grid and one ghost instead of two of each.
  openPanelTo(null);
});

// One function for the buttons and for the keys that do the same thing. The keys used to
//   go through `button.click()`, which quietly made them depend on that button's own
//   `disabled` attribute -- refreshed on the low-cadence UI tick, so a key pressed in the
//   frames after an edit did nothing at all while the timeline plainly had something on
//   it. Measured, not suspected. Mirrors `panel.stepHistory` on the desktop side.
//   A restored snapshot's slot numbers need not match, so an open session has nothing
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
/*   and a drag once begun had no way out at all, though `cancelDrag` has  */
/*   existed and been tested throughout. Nothing new happens here: these   */
/*   are second ways to reach what the buttons already do.                 */
/* ---------------------------------------------------------------------- */

document.addEventListener('keydown', (e) => {
  // Typing in a field is not a shortcut: a coefficient or a label is edited with the very
  //   keys these bind, and ctrl+z inside an input already means the browser's own undo.
  const target = e.target;
  if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' ||
      target.isContentEditable)) {
    return;
  }

  if (e.key === 'Escape') {
    // Everything in progress, in the order a reader would expect to shed it: the panel
    //   they just opened, then a menu, then the gesture underneath.
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

  // The 3D view answers its own keys, but only while it actually has focus -- it is one
  //   ordinary tab stop (see its `tabindex` in the markup), so a reader tabs into it,
  //   drives it, and tabs onward. Tab itself is never intercepted: rebinding it inside
  //   the canvas is the tempting design and risks a keyboard trap, which WCAG 2.1.2 rules
  //   out at the same level 2.1.1 asks for this in the first place.
  //   Which key does what is `interaction.actionFor`'s to say; only the DOM's own naming
  //   of the keys is translated across, exactly as SDL scancodes are on the desktop side.
  if (document.activeElement === canvas && !(e.ctrlKey || e.metaKey || e.altKey)) {
    // `e.code`, the physical key, which is what the desktop's scancodes name -- see
    //   `browser_bridge.keyFor`. A key that moves the view is held from here until its
    //   `keyup` below; a key that acts does so on this press.
    if (nimKeyBound(e.code)) {
      e.preventDefault(); // Arrows would otherwise scroll the page under the canvas.
      const slot = nimKeyDown(e.code);
      if (slot >= 0) {
        // Shift adds rather than replaces, exactly as shift-click does -- the one thing
        //   the shift state means that the shared binding table cannot answer alone.
        if (e.shiftKey) toggleSelection(slot, null); else selectOnly(slot, null);
      }
      return;
    }
  }

  // Ctrl on every platform, and cmd as well on macOS, where ctrl+z is not what a reader
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

// A key can only stop moving the camera if its release is seen, and there are three ways
// for one to go missing: the release lands while another element has focus, the window
// loses focus entirely, or the tab is hidden. The first is handled by matching the keydown
// guard; the other two let go of everything.
document.addEventListener('keyup', (e) => {
  nimKeyUp(e.code);
});
window.addEventListener('blur', () => { nimReleaseKeysAll(); nimSetCameraDragging(false); });
canvas.addEventListener('blur', () => { nimReleaseKeysAll(); });
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { nimReleaseKeysAll(); nimSetCameraDragging(false); }
});

function refreshUndoRedoButtons() {
  // Dimmed/disabled (via the shared .btn:disabled rule) whenever there's nothing on
  //   that side of the timeline to move to -- checked after every history-touching
  //   action below, plus once per low-cadence UI tick to catch every other path
  //   (add, apply, remove, load demo, scene load/clear) without hooking each one.
  button_undo.disabled = !nimCanUndo();
  button_redo.disabled = !nimCanRedo();
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
// Each field commits on change, falling back to the value the camera treats as its own
// floor for that quantity where the box is left empty or unparseable.
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

function refreshCameraFields() {
  if (are_fields_camera_focused) return; // Don't fight a value the user is mid-typing.
  // `nimFormatNumber`, not a `toFixed` here: an angle of 1.05 should read `1.05` rather
  //   than `1.050`, and the desktop draws every one of these with the same widget.
  fields_camera.azimuth.value = nimFormatNumber(nimCameraAzimuth());
  fields_camera.elevation.value = nimFormatNumber(nimCameraElevation());
  fields_camera.distance.value = nimFormatNumber(nimCameraDistance());
  fields_camera.fov.value = nimFormatNumber(nimCameraFov());
  const t = nimCameraTarget();
  fields_camera.tx.value = nimFormatNumber(t[0]);
  fields_camera.ty.value = nimFormatNumber(t[1]);
  fields_camera.tz.value = nimFormatNumber(t[2]);
}

// **Asked for here, taken inside the frame that draws it.** The context is created without
//   `preserveDrawingBuffer` (see its own note), so a canvas read from a task of its own finds
//   the drawing buffer already composited and thrown away -- the read comes back blank or
//   fails outright, which is the image button doing nothing at all. `preserveDrawingBuffer:
//   true` would fix it by making every frame keep a copy forever, on phones, to serve a
//   button pressed once in a session; capturing between the last draw call and the yield
//   costs nothing and is the same capture-then-yield shape `runStoryboard` uses.
//
//   Two theories for moving this into the handler instead -- `renderFrame` then a synchronous
//   `toDataURL` -- were tried and **both are false**, recorded so they are not re-derived:
//
//   - *It would keep the transient activation `navigator.share` needs.* It is not lost:
//     the window is around five seconds and spans the task boundary. Measured against a stub
//     that refuses without `navigator.userActivation.isActive` -- this build passes it.
//   - *It would stop a backgrounded tab stranding the capture,* since `requestAnimationFrame`
//     stops there. Did not reproduce: tapping and backgrounding the page immediately still
//     delivered the file.
//
//   With no measured benefit left, the asynchronous read wins on cost: `toDataURL` blocks the
//   main thread for the whole encode, which on a phone-sized canvas is most of a second of
//   frozen UI.
let is_capture_wanted = false;
document.getElementById('btn-export-png').addEventListener('click', () => {
  is_capture_wanted = true;
  toast('Capturing the next frame\u2026');
});

function captureFrameIfAsked() {
  if (!is_capture_wanted) return;
  is_capture_wanted = false;
  const [width, height] = [canvas.width, canvas.height];
  canvas.toBlob((blob) => {
    // `toBlob` hands back null where encoding failed. Unchecked, the next line threw into
    //   an async callback nobody watches -- silence on top of silence.
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

// **One button per size, built from what the bridge reports.** The counts are
// `orrery.ScaleOrrery`'s and nothing here knows them: a size added or renamed there shows up
// as a button without this file or the markup being touched. The button is labelled with the
// count because a count is what a reader picking between benchmark scenes is choosing.
for (const scale of nimDemoScales()) {
  const items = nimDemoItems(scale);
  const button = document.createElement('button');
  button.className = 'btn';
  button.type = 'button';
  button.id = `btn-load-demo-${items}`;
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
  document.getElementById('btn-demo-scales').appendChild(button);
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
  // Switching arity can leave the previous selection's own index absent from the new,
  //   filtered option list -- fall back to the new list's first option rather than
  //   leaving opSelect.value pointing at a now-nonexistent <option>.
  if (picker_operation.querySelector('option[value="' + value_previous + '"]')) {
    picker_operation.value = value_previous;
  } else {
    // A fresh list opens on what was last applied at this arity, not on its own head.
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
  // Preview what `apply` would build, live while this section is open -- following the
  // operation AND both operands, since a preview that ignored half its own inputs would
  // be showing something the button beside it would not build. Nim decides what a
  // preview is worth showing; this only says which three readings to try.
  // The drawer names its own operands, so it reads them rather than the selection.
  if (!isDrawerApplyOpen()) { nimClearPreview(); return; }
  const slots = nimSceneSlots();
  const first = slots[parseInt(picker_operand_first.value, 10)];
  const second = arity_current === 0
    ? first
    : slots[parseInt(picker_operand_second.value, 10)];
  if (!Number.isInteger(first) || !Number.isInteger(second)) { nimClearPreview(); return; }
  nimGhostOperation(parseInt(picker_operation.value, 10), first, second);
}

function isDrawerApplyOpen() {
  // A collapsed section previews nothing: the ghost belongs to a control on screen, and
  // one left standing after its section closed names nothing a reader can see.
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

// Coefficient grid, shared by the add-multivector section and each row's own edit box:
//   stacked one row per grade (0 to n), rather than wrapping basis order at a fixed
//   column count regardless of grade boundaries -- grade comes from `nimBasisGrade`
//   (backed by `pga/algebra.grade`, the library's own basis-to-grade lookup), needing
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
    row.className = 'coeff-grade-row';
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

document.getElementById('btn-apply').addEventListener('click', () => {
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
  // generalized to a pair: re-defaults operand m/n to the current selection only the
  // moment the selection itself changes (not on every refreshOperandOptions call, which
  // happens far more often than selection changes), so a manual pick of a different
  // operand sticks until selection moves again.
let key_operand_options_last = ''; // Slot list + labels last used to rebuild operand m/n's
  // own <option> elements -- rebuilding a <select>'s options while its native picker
  // is open (mobile especially) makes the browser re-show/reset that picker, so the
  // full rebuild below only actually runs when scene composition or a label changed,
  // never on every periodic tick.

function refreshOperandOptions() {
  const slots = nimSceneSlots();
  const key = slots.map((slot) => slot + ':' + nimItemLabel(slot)).join(',');
  if (key !== key_operand_options_last) {
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
  // Everything the selection already says is filled in here rather than asked for a
  // second time: how many objects are picked names the arity (`nimSelectionArity`, the
  // same rule the floating menu reads), and the order they were picked names m and n.
  // Only right when the selection itself changes -- cheap enough (no DOM rebuild) to
  // call on every frame-loop tick, unlike the option-list rebuild above, and leaving a
  // later manual pick of either alone until the selection next moves. Mirrors
  // panel.layoutApply exactly.
  const key = slots_selection.join(',');
  if (key === key_selection_synced_last) return;
  key_selection_synced_last = key;
  if (slots_selection.length === 0) return; // Nothing picked names nothing; leave it be.
  const slots_scene = slots || nimSceneSlots();

  const arity = nimSelectionArity();
  if (arity !== arity_current) {
    // A filtered operation list is indexed per arity, so an option carried across from
    // the other list names an unrelated operation -- populateOperations rebuilds it and
    // falls back to the new list's first entry, exactly as the arity buttons do.
    arity_current = arity;
    picker_arity.querySelectorAll('button[data-arity]').forEach((each) => {
      each.classList.toggle('on', parseInt(each.dataset.arity, 10) === arity);
    });
    populateOperations();
  }

  const position_first = slots_scene.indexOf(slots_selection[0]);
  if (position_first >= 0) picker_operand_first.value = position_first;
  if (slots_selection.length >= 2) {
    // Three or more picked still names a binary operation, on the first two: this picker
    // can say which two, unlike the floating menu, which hides `apply` rather than guess.
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
/* Edit session: one at a time, in one of two modes -- composing a brand-  */
/* new object (`slot` null, nothing backing it in the scene yet) or        */
/* editing an existing one. Both stage the same four things and preview    */
/* through the same ghost; only `save` reaches the scene. State lives here */
/* rather than in the row's own closures because `refreshObjectsUI`        */
/* rebuilds every row from scratch, which would otherwise discard it.      */
/* ---------------------------------------------------------------------- */

let session_edit = null; // { slot: number|null, coefficients: number[], label, ink }

function beginEditSession(slot) {
  // A null slot composes; a real slot edits that item. Seeding a composing session from
  //   Nim's own defaults keeps the auto-label and cycled ink every other construction
  //   path assigns, while leaving both editable before the object exists.
  session_edit = slot === null
    ? {
        slot: null,
        coefficients: new Array(nimBasisCount()).fill(0),
        label: nimDefaultLabel(),
        ink: nimDefaultInk(),
      }
    : {
        slot,
        coefficients: Array.from(nimItemCoefficients(slot)),
        label: nimItemLabel(slot),
        ink: nimItemInk(slot),
      };
  nimSetGhost(session_edit.coefficients);
}

function endEditSession() {
  session_edit = null;
  nimClearGhost();
}

// The two rows that are not an object: the note shown to an empty list, and the row a
//   composing session heads it with. Keys rather than positions, so the reconcile below can
//   talk about every row the same way.
const KEY_ROW_EMPTY = 'empty';
const KEY_ROW_PENDING = 'pending';
// What each key's row was a picture of when it was last built. Compared, never ordered.
let signatures_row = new Map();

// The geometry line a row shows, held per slot against the scene's own revision.
//   **The costly half of a signature, and a function of the geometry alone.** Measured at
//   1,024 objects, `nimFormatMultivector` is 11.8 ms of a walk and `nimItemShapeWord` 2.9,
//   against 0.8 ms for every other field a row draws put together. Geometry changes only
//   when `scene.revision` does -- every writer bumps it, which is what the frame hold and
//   the placement cache already rest on -- so the text is re-derived when the revision moves
//   and reused otherwise. A selection change, which is what most refreshes are, moves no
//   revision and re-derives nothing.
//   Cleared whole rather than per slot: the revision is the scene's, not a slot's, so an
//   edit re-derives every row. That is the same over-approximation `g_placed` makes, and it
//   costs one deliberate action the walk it would have paid anyway.
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
  // **Everything the row draws, and nothing else.** Two equal signatures mean the same
  //   picture, so the element standing there is already right and is left alone.
  if (key === KEY_ROW_EMPTY || key === KEY_ROW_PENDING) return key;
  const slot = parseInt(key, 10);
  // An open row is keyed by being open rather than described. Its fields preview
  //   `session_edit` and its own handlers keep them current as the reader types; rebuilding
  //   it on some unrelated refresh would take the caret out of whatever field they were in.
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
  // **Reconciled against the rows already standing, not rebuilt.** This used to empty the
  //   list and build every row again, which on the 1,024-object demo was 570 ms of
  //   JavaScript and 164 ms of layout -- and there are a dozen callers, so a tap on `hide`
  //   paid all of it to change one checkbox.
  //   Built as a diff rather than by making the tap-driven callers call something narrower:
  //   a list of "the cheap callers" is a contract a thirteenth caller breaks silently, and
  //   this way every caller is cheap, including ones not yet written. A refresh that
  //   changes nothing writes nothing. The same shape as `timings.RECORDS_FRAME`'s
  //   this-frame/last-frame pair and the swap arena, one side of the wire over.
  const slots = nimSceneSlots()
    .slice()
    .sort((a, b) => nimItemBorn(b) - nimItemBorn(a)); // Most recently added first.
  count_objects.textContent = '(' + slots.length + ' of ' + nimSceneCapacity() + ')';

  const keys = [];
  if (slots.length === 0 && !isComposing()) keys.push(KEY_ROW_EMPTY);
  // A composing session heads the list: it is the newest thing here, and it has no
  //   `born` reading to sort by since nothing backs it in the scene yet.
  if (isComposing()) keys.push(KEY_ROW_PENDING);
  for (const slot of slots) keys.push(String(slot));

  // Snapshotted, not walked live: the loop below inserts into this very collection.
  const standing = new Map();
  for (const node of Array.from(list_objects.children)) standing.set(node.dataset.key, node);

  const signatures = new Map();
  let at = 0;
  for (const key of keys) {
    const signature = signatureOfItemRow(key);
    signatures.set(key, signature);
    let node = standing.get(key);
    if (node === undefined || signatures_row.get(key) !== signature) {
      if (node !== undefined) node.remove();
      node = buildRowFor(key);
      node.dataset.key = key;
    }
    // Already in the right place is the common case; otherwise this moves it there.
    if (list_objects.children[at] !== node) {
      list_objects.insertBefore(node, list_objects.children[at] || null);
    }
    at += 1;
  }
  // Whatever is left past the wanted rows is gone from the scene.
  while (list_objects.children.length > keys.length) list_objects.lastElementChild.remove();
  signatures_row = signatures;

  refreshOperandOptions();
  refreshAddButton();
}

function isComposing() { return session_edit !== null && session_edit.slot === null; }

function isEditing(slot) { return session_edit !== null && session_edit.slot === slot; }

function refreshAddButton() {
  // Disabled while any session is open, so starting a second one cannot silently
  //   discard the first -- the same treatment undo/redo get when their side is empty.
  button_add.disabled = session_edit !== null || nimSceneCount() >= nimSceneCapacity();
}

function buildItemRow(slot) {
  // `slot === null` builds the composing row: same layout, but nothing backs it in the
  //   scene, so everything it displays comes from `session_edit` and the buttons that act
  //   on a real object (hide, remove) are left out entirely.
  const is_pending = slot === null;
  const is_open = is_pending || isEditing(slot);

  const row = document.createElement('div');
  if (!is_pending) row.dataset.slot = slot; // Lets a caller find one row again by slot.
  // The open row says so on itself: it is the one row whose real height the panel has to
  //   know -- `scrollRowIntoView` scrolls to bring its edit form into view, and a form
  //   standing behind a 42px placeholder scrolls to the placeholder. `shell.html` reads
  //   this class to keep the open row out of the containment the other thousand are in.
  row.className = 'item-row'
    + (is_open ? ' editing-item' : '')
    + (is_pending ? ' pending-item' : '')
    + (!is_pending && slots_selection.includes(slot) ? ' selected' : '')
    + (!is_pending && !nimItemVisible(slot) ? ' hidden-item' : '');

  const top = document.createElement('div');
  top.className = 'item-top';

  // While a session is open its staged values drive the row, so the swatch, label and
  //   coefficient line preview the edit without the scene having changed.
  const inkOf = () => (is_open ? session_edit.ink : nimItemInk(slot));
  const labelOf = () => (is_open ? session_edit.label : nimItemLabel(slot));

  // Selection checkbox: mirrors/toggles membership in `slots_selection`, exactly the
  // same helper long-press/click-to-select already drives -- not visibility any more.
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
  toggle_edit.className = 'btn item-edit-toggle';
  toggle_edit.type = 'button';
  toggle_edit.textContent = is_open ? 'save' : 'edit';
  toggle_edit.title = is_open
    ? 'Commit these values to the scene.'
    : 'Rename, recolour or reshape this object; nothing changes until you save.';
  toggle_edit.addEventListener('click', () => {
    if (!is_open) { beginEditSession(slot); refreshObjectsUI(); return; }
    if (is_pending && nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
    if (is_pending) {
      nimAddItem(session_edit.coefficients, session_edit.label, session_edit.ink, now());
      endEditSession();
      adoptConstructionSelection();
      toast('Added `' + label.textContent + '`.');
    } else {
      nimCommitItem(slot, session_edit.coefficients, session_edit.label, session_edit.ink);
      endEditSession();
      toast('Saved `' + label.textContent + '`.');
    }
    refreshObjectsUI();
    refreshUndoRedoButtons();
  });
  top.appendChild(toggle_edit);

  if (is_open) {
    // Abandon: a composing row vanishes with nothing added, an editing row reverts. In
    //   both cases the scene was never touched, so this only has to drop the session.
    const cancel = document.createElement('button');
    cancel.className = 'btn item-edit-cancel';
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
    // Hide/show and remove act on the object as the scene holds it, which is exactly what
    //   an open session is staging a replacement for -- offering them mid-edit invites
    //   acting on one version while looking at another. A composing row has no object at
    //   all yet, so both are left out rather than shown disabled either way.
    const visibility = document.createElement('button');
    visibility.className = 'btn item-visibility';
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
    remove.className = 'btn item-remove';
    remove.type = 'button';
    remove.textContent = 'remove';
    remove.title = "Delete this object; its slot is reused by the next one you add.";
    remove.addEventListener('click', () => {
      nimRemoveItem(slot); // Drops the slot from the selection itself, so a stale pick
        // cannot linger and read as "selected" once a future add reuses the freed slot.
      if (isEditing(slot)) endEditSession(); // Its session has nothing left to commit to.
      toast('Removed `' + label.textContent + '`.');
      onSelectionChanged(null);
    });
    top.appendChild(remove);
  }

  row.appendChild(top);

  const line_coefficient = document.createElement('div');
  line_coefficient.className = 'item-coeff';
  const describeStaged = () =>
    is_open ? nimDescribeCoefficients(session_edit.coefficients)
           : geometryTextFor(slot);
  line_coefficient.textContent = describeStaged();
  row.appendChild(line_coefficient);

  // **Built only for the row that is open, which is at most one of them.** Everything
  //   below is the edit form, and a closed row used to build the whole of it -- a label
  //   field, an ink picker with an option per choosable slot, and a grid with an input per
  //   basis element -- and then let CSS hide it. Measured on the 1,024-object demo that was
  //   **76 elements per collapsed row and 80,325 on the page**, against 843 on the opening
  //   scene; one rebuild of the list cost 570 ms of JavaScript and 164 ms of layout, so a
  //   tap on `hide` froze the page for three quarters of a second. It also meant an
  //   `nimItemCoefficients` call across the FFI for every row of every rebuild, to fill
  //   inputs nobody could see.
  //   Nothing was reachable in there anyway: every field writes into `session_edit`, which
  //   is null unless a session is open, so a hidden form could only have thrown.
  if (is_open) {
    const box_edit = document.createElement('div');
    box_edit.className = 'item-edit' + (is_open ? ' open' : '');

    const field_label = document.createElement('div');
    field_label.className = 'field';
    field_label.innerHTML = '<label>label</label>';
    // Every field below writes into the session, never the scene: the row's own swatch,
    //   label and coefficient line preview the change, the ghost previews the geometry,
    //   and only `save` above reaches `g_scene`.
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
    // Only the categorical slots are offerable; `nimInkChoosableSlots` decides which those
    //   are, so no palette rule lives out here. Its entries stay whole-palette ordinals,
    //   the same ones `nimItemInk` reports and `nimInkName`/`nimInkColor` accept.
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
    grid.className = 'coeff-grid';
    // `nimFormatNumber`, not a `toFixed` here: how many digits a coefficient is worth
    //   is a decision about this project's numbers, and the desktop's own cells make it the
    //   same way.
    const inputs_coefficient = buildGradedCoefficientGrid(
      grid,
      (b) =>
        nimFormatNumber(is_open ? session_edit.coefficients[b] : nimItemCoefficients(slot)[b]),
    );
    inputs_coefficient.forEach((input, b) => {
      // `input`, not `change`: the ghost tracks a keystroke rather than waiting for the
      //   field to blur, which is what makes the preview feel live.
      input.addEventListener('input', () => {
        session_edit.coefficients[b] = parseFloat(input.value) || 0;
        nimSetGhost(session_edit.coefficients);
        line_coefficient.textContent = describeStaged();
      });
    });
    box_edit.appendChild(grid);

    row.appendChild(box_edit);
  }
  return row;
}

document.getElementById('btn-save-scene').addEventListener('click', saveScene);
document.getElementById('btn-load-scene').addEventListener('click', () => {
  document.getElementById('file-load-scene').click();
});
document.getElementById('file-load-scene').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (file) loadSceneFile(file);
  e.target.value = '';
});

/* ---------------------------------------------------------------------- */
/* Scene save/load: pack and parse the exact `.rgascene` binary format     */
/* `scene.nim`'s own doc comment documents (magic/version/basis-count/     */
/* item-count/per-item ink+visible+label+16 float64), so a file this      */
/* build saves loads on the desktop build and vice versa. Packing lives   */
/* here rather than in Nim, since `DataView` already does exactly this     */
/* natively -- see `browser_bridge.nim`'s own doc comment.                */
/* ---------------------------------------------------------------------- */

function saveScene() {
  // Creation order, not slot order: a version-3 file promises its sequence is the order
  //   the scene was built in, and a removed-then-re-added object sits in a reused slot
  //   well before objects that predate it. Loading walks the sequence back one object at
  //   a time, so writing slot order here would replay a construction that never happened.
  const slots = nimSceneSlotsCreated();
  const count_basis = nimBasisCount();
  // Labels go out as UTF-8 bytes, which is what the format holds and what `scene.nim`
  //   writes: a derived label carries operator notation (`a ∧ b`, `a ∨ b`, `a ⊖ b`), and a
  //   JavaScript string's own `.length` counts UTF-16 units while `charCodeAt` truncated to
  //   a byte throws away everything above U+00FF. Both together wrote a shorter length than
  //   the bytes that followed, so every object after the first non-ASCII label parsed from
  //   the wrong offset. Measured: `a ⊖ b` came back on the desktop as `a` and a replacement
  //   glyph.
  const encoder = new TextEncoder();
  const items = slots.map((slot) => ({
    ink: nimItemInk(slot),
    visible: nimItemVisible(slot),
    label: encoder.encode(nimItemLabel(slot)),
    coefficients: nimItemCoefficients(slot),
  }));

  let size = 4 + 1 + 1 + 4;
  for (const item of items) size += 1 + 1 + 1 + item.label.length + count_basis * 8;

  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  let offset = 0;
  // Magic and version come from `scene.nim` through the bridge, never from literals here:
  //   the version was a literal `1` and stayed one through the format's bump to 2, so this
  //   build stamped every file it saved with a version its own content was not.
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
      adoptConstructionSelection(); // nimSceneClear() inside already cleared g_index_highlighted.
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
  // Both expectations come from `scene.nim` through the bridge, for the reason `saveScene`
  //   above gives: a literal here is exactly what drifted out of step with the format.
  const magic_wanted = nimSceneMagic();
  let magic = '';
  for (let i = 0; i < magic_wanted.length; i++) magic += String.fromCharCode(view.getUint8(i));
  offset = magic_wanted.length;
  if (magic !== magic_wanted) throw new Error('File is not a scene file.');
  // A *range* through the bridge, not this build's own writing version: every version
  //   ever written stays readable, and which those are is `scene.readsSceneVersion`'s
  //   answer rather than a pair of literals here to fall out of step with it.
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
    // Decoded as UTF-8, for the reason `saveScene` gives: byte-per-character would read
    //   every operator in a derived label as two or three Latin-1 characters of noise.
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
    parsed.push({ ink, visible, label, coefficients });
  }

  nimSceneClear();
  // In file order, which from version 3 on is the order the objects were built: each is
  //   stamped to appear a beat after the last, so the scene replays its own construction.
  //   The version rides along because an older file's palette ordinals mean something
  //   else; the mapping is Nim's, not this parser's.
  //   One clock reading for the whole arrival, taken before the loop: read per item it
  //   would creep forward by however long parsing took, which is a stagger nobody chose.
  const arrived = now();
  for (const item of parsed) {
    const slot = nimSceneAddRaw(
      version, item.ink, item.visible, item.label, item.coefficients,
      count_item, arrived,
    );
    if (slot < 0) throw new Error('File names an unknown palette slot for an object.');
  }
  return 'Loaded ' + count_item + ' object(s) from scene file.';
}

/* ---------------------------------------------------------------------- */
/* Diagnostics: browser-appropriate stand-ins for the desktop build's own */
/* arena/frame-time panel -- see `browser_bridge.nim`'s own doc comment   */
/* for why the numbers differ in kind. The drawer states none of this: a  */
/* reader opening a diagnostics panel wants the numbers, not an essay.    */
/* ---------------------------------------------------------------------- */

const FRAMES_HISTORY = 240;
const history_frame = new Array(FRAMES_HISTORY).fill(16.6);
let index_history_frame = 0;
let time_frame_last = performance.now();
const sparkline = document.getElementById('sparkline');
const context_sparkline = sparkline.getContext('2d');
const diagnostic_frame_time = document.getElementById('diag-frametime');
const diagnostic_heap = document.getElementById('diag-heap');
const diagnostic_pool = document.getElementById('diag-pool');
const grid_pool = document.getElementById('pool-grid');
const context_pool = grid_pool === null ? null : grid_pool.getContext('2d');
// The scene revision the grid was last drawn at; -1 until it has been drawn once. The grid
//   is a picture of which slots are occupied and in what ink, so it changes exactly when the
//   scene does -- see `scene.revision`, the same counter the frame hold reads. Its own
//   geometry joins the key because a canvas cleared by a resize has to be redrawn whatever
//   the scene did, and because the section opens onto a canvas that had no size at all.
let revision_pool_last = -1;
let ratio_pool_last = 0;
// **Set by a `ResizeObserver`, never by measuring.** The gate below has to run before
//   anything reads the canvas's width, because a layout read *after* the tick's own row
//   writes forces the browser to lay the drawer out there and then -- measured at 0.9 ms of
//   a 1.3 ms tick, five times a second, for a picture that had not changed. An observer
//   answers the same question for nothing, and fires once when it starts watching, which is
//   what makes the first draw happen.
let is_pool_stale = true;
// What the last draw actually chose, for a check to read rather than re-derive. The
//   derivation is the thing being checked, so a test that repeated it would agree with
//   itself no matter what reached the canvas.
let geometry_pool_drawn = { cell: 0, gap: 0, columns: 0, rows: 0, height: 0 };
// **One square per slot, wrapped**, at the largest size that keeps the whole grid inside a
//   block rather than a page. The cell cannot be a constant: at 1,024 slots six pixels with
//   a gap is 53 columns of 20 rows and 139px tall, and at 10,080 the same cell is 191 rows
//   and over 1,300px -- which is not a grid a reader scans, it is a scroll. So the size is
//   chosen against the capacity and the measured width, largest first, and the gap goes
//   before the cell does: below four pixels a one-pixel gap is half the strip.
//   At 10,080 slots in a 371px drawer this lands on 2px cells, 185 columns by 55 rows and
//   110px tall -- a density map rather than a set of squares, which is the honest reading at
//   ten thousand.
const CELLS_POOL = [[6, 1], [5, 1], [4, 1], [3, 0], [2, 0], [1, 0]];
const HEIGHT_POOL_MAX = 150;
// A CSS colour per packed triple, so a palette that cycles is converted a dozen times
//   rather than a thousand. Cleared with nothing: the palette is fixed, so it converges.
const css_pool = new Map();
if (grid_pool !== null && typeof ResizeObserver === 'function') {
  // Its own box, not the window's: the drawer is a fixed-width panel on a wide screen and a
  //   full-width sheet on a narrow one, and either can change without the window doing so.
  new ResizeObserver(() => { is_pool_stale = true; }).observe(grid_pool);
}

// One ring per step of the drawing process, so the diagnostics tab can show where a frame
// actually went rather than one opaque total. The bridge reports its own three phases on
// FrameData (build = furniture + scene + flatten, timed inside nimBuildFrame where only it
// can see them); this side times what only it can see -- the GL upload+draw, the SVG
// overlay, the selection menu, and the low-cadence UI block. Rings rather than a latest
// value, so each row can show a rolling median beside the instantaneous number: a single
// frame's reading flickers too fast to read, and a median is what a reader means by "how
// long does this step take".
const PHASES_DIAGNOSTIC = [
  ['build', 'diag-build'], ['camera', 'diag-camera'], ['furniture', 'diag-furniture'],
  ['grid', 'diag-grid'], ['axes', 'diag-axes'], ['scene', 'diag-scene'],
  ['points', 'diag-points'], ['lines', 'diag-lines'], ['planes', 'diag-planes'],
  ['sky', 'diag-sky'], ['ghost', 'diag-ghost'], ['selected', 'diag-selected'],
  ['algebra', 'diag-algebra'], ['matrix', 'diag-matrix'], ['flatten', 'diag-flatten'],
  ['unaccounted', 'diag-unaccounted'],
  // The second cut, not stages: these re-divide the very milliseconds above them.
  ['placing', 'diag-placing'], ['emitting', 'diag-emitting'],
  ['hover', 'diag-hover'], ['upload', 'diag-upload'], ['overlay', 'diag-overlay'],
  ['ui', 'diag-ui'], ['idle', 'diag-idle'],
];
// The rows that re-divide time already counted elsewhere. They must stay out of every sum
//   -- the idle derivation below, and the cost tint's own denominator -- or the frame would
//   appear to have spent its drawing twice.
const PHASES_CUT_DIAGNOSTIC = ['placing', 'emitting'];
// The phases nothing else contains: their sum is everything this page spent on a frame,
//   and the rest of the frame is `idle` below. `build` holds the bridge's own three, and
//   those hold the scenery halves and the object kinds, so counting any of them here would
//   count the same milliseconds twice.
const PHASES_TOP_DIAGNOSTIC = ['build', 'hover', 'upload', 'overlay', 'ui'];
// The rows that carry a count beside their time, and the ring each count is written to.
//   A time alone cannot tell "one of these is expensive" from "there are many of them",
//   which is the whole question a reader opens this branch to answer.
const COUNTS_DIAGNOSTIC = {
  grid: 'count_grid_segments',
  points: 'count_points', lines: 'count_lines', planes: 'count_planes',
  sky: 'count_sky', ghost: 'count_ghost', selected: 'count_selected',
};
const count_phase = {};
const history_phase = {};
// **Whether a phase ran is kept beside its time, never inside it.** A sentinel in the
//   value's own range was doing that job, and a duration has no room for one: every mobile
//   browser coarsens and jitters `performance.now` against timing attacks, so a
//   sub-millisecond step can measure as zero or below, and a real reading then becomes
//   indistinguishable from "never ran". That is precisely what left every sub-millisecond
//   row of the tree an em dash on a phone while the six-millisecond ones read fine.
const written_phase = {};
const element_phase = {};
const element_row = {};
const element_tally = {};
for (const [name, id] of PHASES_DIAGNOSTIC) {
  history_phase[name] = new Float64Array(FRAMES_HISTORY);
  written_phase[name] = new Uint8Array(FRAMES_HISTORY);
  element_phase[name] = document.getElementById(id);
  // The whole row as well as its number, so a row can be tinted entire. `closest` rather
  //   than `parentElement`: a leaf's value sits in a plain div and a parent's in a button,
  //   and both carry `.diag-line`.
  element_row[name] = element_phase[name] === null
    ? null : element_phase[name].closest('.diag-line');
  // And the slot beside the row's own name where its count goes, on the rows that have one.
  //   Written into rather than the label being rewritten, so the label's words stay in the
  //   markup and this file never holds a second copy of them to keep in step.
  element_tally[name] = element_row[name] === null
    ? null : element_row[name].querySelector('.diag-tally');
}
for (const name in COUNTS_DIAGNOSTIC) count_phase[name] = 0;
function recordPhaseTime(name, delta_milliseconds) {
  // Shares the frame ring's own index, advanced once per frame by recordFrameTime, so
  // every ring lines up frame for frame; the UI phase only runs one frame in six and
  // leaves its other slots unwritten, which the readings below skip.
  if (!Number.isFinite(delta_milliseconds)) return; // Nothing measured; leave it absent.
  // Clamped at zero: a negative elapsed time is an artefact of a coarsened clock, not a
  //   duration, and the honest reading of it is "too short to measure".
  history_phase[name][index_history_frame] =
    delta_milliseconds > 0 ? delta_milliseconds : 0;
  written_phase[name][index_history_frame] = 1;
}

// **How long a reading is averaged over, and how often it is rewritten.** A single frame's
//   number changes faster than anyone can read it, which is what made these rows flicker.
//   200 ms is the settling time a performance readout is conventionally given: long enough
//   that the digits hold still, short enough that a stall is still on screen while it is
//   happening. The same span governs the averaging and the refresh, so the number shown is
//   the number for the interval since the last one -- not an average over one window
//   sampled on the cadence of another.
const MILLISECONDS_WINDOW_READING = 200;
// **A figure is redrawn on the cadence of the window it is averaged over, not on the
//   panel's.** The rows above are 200 ms readings and belong at 200 ms. Three of the things
//   this panel shows are not: the sparkline holds four seconds, the ring medians four, and
//   the exceedance curve seventeen. None of them can visibly change in a fifth of a second,
//   and redrawing them at that rate was the single most expensive thing the page did --
//   measured at 0.31 ms for the curve and 0.27 for the medians out of a 1.17 ms tick, half
//   of it, five times a second, on the one row (`ui refresh`) that reads three to five times
//   the cost of building the whole frame. A slow pass carries them instead.
//   Not slower still: a second is the longest a reader will watch a curve without deciding
//   it has stopped, and the sparkline has to scroll rather than jump.
const MILLISECONDS_WINDOW_DISTRIBUTION = 1000;
// How many frames back that span reaches, measured in the frames' own durations rather
//   than assumed from a frame rate: at 60 fps it is a dozen, on a labouring phone it is
//   two, and either way it is the last 200 ms.
function framesRecent() {
  let spanned = 0;
  for (let i = 0; i < FRAMES_HISTORY; i += 1) {
    spanned += history_frame[(index_history_frame + FRAMES_HISTORY - 1 - i) % FRAMES_HISTORY];
    if (spanned >= MILLISECONDS_WINDOW_READING) return i + 1;
  }
  return FRAMES_HISTORY;
}
// A phase's mean over those frames, skipping the ones it did not run in. The mean rather
//   than the latest: the whole complaint about the latest is that one frame decides it.
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
// Scratch the median borrows rather than allocating: this runs per phase per refresh, and
//   the rows a tree can hold grow faster than the frames between refreshes do. A filter
//   plus a sort built two arrays each time and threw both away.
const scratch_median = new Array(FRAMES_HISTORY);
function medianPhase(name) {
  const ring = history_phase[name];
  const written = written_phase[name];
  let count = 0;
  for (let i = 0; i < FRAMES_HISTORY; i += 1) {
    if (written[i] === 1) { scratch_median[count] = ring[i]; count += 1; }
  }
  if (count === 0) return null;
  // Insertion sort over the written part: the ring is nearly sorted only by accident, but
  //   it is small and this beats allocating a fresh sorted copy of it every refresh.
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
// Each row's last median, so the 200 ms rows can state one without re-sorting a ring that
//   is four seconds long. Refreshed on the slow pass; `undefined` means never computed,
//   which is not the same as `null` -- that is a phase which has genuinely never run, and
//   the row is left as an em dash for it. A row that becomes shown between slow passes
//   computes its own on the spot rather than reading an em dash for up to a second.
const median_phase_last = {};
function medianPhaseHeld(name, is_recomputing) {
  if (is_recomputing || median_phase_last[name] === undefined) {
    median_phase_last[name] = medianPhase(name);
  }
  return median_phase_last[name];
}

// The rows that have children, and whether each is open. **Every one starts closed**: a
//   reader opens the diagnostics panel to see whether a frame is slow, and goes looking for
//   which step only once it is. A closed node's rows are skipped by `refreshDiagnostics`
//   entirely, so a subtotal nobody is reading costs nothing to keep offering.
//   The nesting is read off the markup itself rather than declared here a second time:
//   the tree's shape used to live in both places, agreeing only by care, and a row moved
//   in one without the other would silently stop hiding -- or stop updating -- with its
//   branch. The DOM is the one copy now, and this file only asks it questions.
for (const node of document.querySelectorAll('.diag-node')) {
  // The node's *own* parent row, not a descendant's: a nested branch puts another
  //   `.diag-parent` inside this one, and `querySelector` would find that one first.
  const header = node.querySelector(':scope > .diag-parent');
  header.addEventListener('click', () => {
    const is_open = node.classList.toggle('open');
    header.setAttribute('aria-expanded', String(is_open));
  });
  header.setAttribute('aria-expanded', 'false');
}
function isPhaseShown(name) {
  // Walk up: a row is shown only where every branch holding it is open. A branch's own
  //   header row starts the walk *above* its node -- the header is what a reader clicks
  //   to open it, so it stays visible while its node is closed.
  const row = element_row[name];
  if (row === null) return false;
  let node = row.closest('.diag-node');
  if (node !== null && row.classList.contains('diag-parent')) {
    node = node.parentElement.closest('.diag-node');
  }
  while (node !== null) {
    if (!node.classList.contains('open')) return false;
    node = node.parentElement.closest('.diag-node');
  }
  return true;
}

// **How often a frame runs long, over a window long enough to answer that.** The
//   sparkline holds four seconds and shows *when*; a reader chasing a stall that happens
//   once a minute needs *how often*, which is a distribution rather than a trace. Kept as
//   a rolling window of the last `FRAMES_EXCEEDANCE` frames -- about seventeen seconds at
//   60 fps, which is long enough to hold a stall and short enough that one ages out again
//   rather than flattening the chart for a minute -- summarised as the share of them at or
//   over each duration.
//   The window is a ring of samples *and* a histogram of the same samples, maintained
//   together: a frame entering increments its bucket, the frame it evicts decrements the
//   one it was in. That keeps the per-frame cost a couple of array writes -- this runs on
//   every frame, including the ones being measured -- and leaves the curve a single
//   suffix scan over the buckets, done only when the panel is actually open.
const FRAMES_EXCEEDANCE = 1024;
const MILLISECONDS_BUCKET = 0.5; // Fine enough to separate a 16.7 ms frame from a 17.2.
const BUCKETS_EXCEEDANCE = 256; // Up to 128 ms; everything slower lands in the last one.
const history_exceedance = new Float32Array(FRAMES_EXCEEDANCE);
const buckets_exceedance = new Int32Array(BUCKETS_EXCEEDANCE);
let index_exceedance = 0;
let count_exceedance = 0; // Rises to the window's own size, then stays there.
const exceedance = document.getElementById('exceedance');
const context_exceedance = exceedance === null ? null : exceedance.getContext('2d');
const diagnostic_exceedance = document.getElementById('diag-exceedance');
const label_exceedance_axis = document.getElementById('diag-exceedance-axis');
// The vertical axis's own switch, wired here rather than beside the header's chips because
//   it reads the chart it belongs to. Linear by default: the chart exists to say what share
//   of the session ran at each speed, and a proportion reads as a proportion on a linear
//   axis. Log answers a narrower question -- how bad the slowest one percent is, which
//   linear squeezes flat against the ceiling -- so it is offered rather than assumed.
const toggle_exceedance_log = document.getElementById('toggle-exceedance-log');
let is_exceedance_log = false;
if (toggle_exceedance_log !== null) {
  toggle_exceedance_log.addEventListener('click', (e) => {
    is_exceedance_log = !is_exceedance_log;
    e.target.classList.toggle('on', is_exceedance_log);
    // Redrawn on the spot rather than at the diagnostics panel's own six-frame cadence: a
    //   switch that answers a sixth of a second late reads as one that did not work.
    drawExceedance();
  });
}

function bucketOf(milliseconds) {
  const index = Math.floor(milliseconds / MILLISECONDS_BUCKET);
  // Anything past the last bucket lands *in* it rather than being dropped: a 300 ms stall
  //   is the most important sample the window ever holds, and a curve that discarded it
  //   would read as calmer than the session actually was.
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

// The complementary distribution, as a share of the window per bucket, scanned from the
//   slow end so each entry is "this many frames took at least this long". Written into a
//   buffer the caller owns so the scan allocates nothing on a path that runs ten times a
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
  // **Everything the page did not spend itself**: waiting on the display, and the browser's
  //   own style, layout, paint, compositing and collection. Without it the breakdown
  //   accounted for a fraction of the frame and left the rest unexplained, so a spike could
  //   not be told from a stall in the page's own code -- which is the first question a
  //   reader has. Computed here because this is the one moment a frame's duration and its
  //   own phases sit in the same slot: the delta written just above measures the frame
  //   whose phases were recorded into this index, and the advance below moves past both.
  let spent = 0;
  for (const name of PHASES_TOP_DIAGNOSTIC) {
    if (written_phase[name][index_history_frame] === 1) {
      spent += history_phase[name][index_history_frame];
    }
  }
  recordPhaseTime('idle', delta_milliseconds - spent);
  recordExceedance(delta_milliseconds);
  index_history_frame = (index_history_frame + 1) % FRAMES_HISTORY;
  // The slot the phases are about to write into is cleared up front, so a phase that
  // does not run this frame (the UI block, a held furniture build) reads as absent
  // rather than as whatever it cost 240 frames ago.
  for (const [name] of PHASES_DIAGNOSTIC) written_phase[name][index_history_frame] = 0;
}

// How far the log axis runs, when the reader switches to it: decades from every frame down
//   to one in a thousand, which is as fine as a window of a thousand frames can resolve.
const DECADES_EXCEEDANCE = 3;
// **The axis follows the window, but never closes below the slowest budget plus room to
//   name it.** Fitting it to the slowest frame is what makes the max readable -- the curve
//   reaches 100% exactly there -- and the floor is what stops a fast session zooming into
//   its own noise: at 30 fps and better the axis stands still and the budget lines keep
//   their places, so two readings of a healthy session compare directly. It is the bands
//   that made this affordable: an axis that moves is legible when the colours and the
//   labelled lines say where the budgets are regardless of how far it runs.
//   Stated as the share of the axis the slowest labelled mark stands at, not as that
//   mark's own duration. At exactly `1000 / 30` the 30 fps line landed on the right edge:
//   half a pixel outside the canvas, and its label flipped to the cramped inside-left
//   branch below, alone among the marks in reading right to left. The margin has to be a
//   share because the canvas is responsive -- a fixed number of milliseconds buys a
//   different number of pixels at every drawer width -- and 14% clears the label's own
//   14px threshold down to about a 110px canvas.
// What a label is haloed against where the curve runs through it: the drawer's own solid
//   surface, which is what shows through this canvas, at most of full strength -- enough to
//   part the curve around the digits, little enough that it reads as the ground rather than
//   as a box drawn behind them.
const HALO_LABEL_EXCEEDANCE = 'rgba(22, 27, 34, 0.85)';
const SHARE_MARK_LEAST = 0.86;
const MILLISECONDS_AXIS_LEAST = (1000 / 30) / SHARE_MARK_LEAST;
// The frame budgets a reader actually aims at, each named by the rate it is: a duration
//   means nothing to most people and "60" means something to everyone.
//   This list is both the marks and the colour bands: `bandOfExceedance` indexes it and
//   `colours_exceedance` maps over it. The 15 fps entry therefore carries the *poor band's
//   own token* on purpose -- it is a mark a reader asked for, not a fifth band. Anything
//   past 33.3 ms is poor whichever side of 66.7 it falls, so the curve merely splits into
//   two runs there and strokes them the same colour. **Do not tidy the repeated token
//   away**: dropping it would either lose the mark or invent a band.
const BUDGETS_EXCEEDANCE = [
  { milliseconds: 1000 / 120, label: '120', token: '--speed-fast' },
  { milliseconds: 1000 / 60, label: '60', token: '--speed-good' },
  { milliseconds: 1000 / 30, label: '30', token: '--speed-fair' },
  { milliseconds: 1000 / 15, label: '15', token: '--speed-poor' },
  { milliseconds: Infinity, label: '', token: '--speed-poor' },
];
// Read once from the stylesheet, which is where they are set and tuned; see the tokens'
//   own comment in `shell.html` for how the four were screened.
// Resolved once, like the colours below: this is redrawn at frame rate while the axis
//   glides, and each draw was asking layout for the same font token.
const FONT_EXCEEDANCE = '9px ' +
  (getComputedStyle(document.documentElement).getPropertyValue('--mono').trim() ||
    'monospace');
const colours_exceedance = BUDGETS_EXCEEDANCE.map((budget) =>
  getComputedStyle(document.documentElement).getPropertyValue(budget.token).trim() ||
    '#00a7a5');
// **Which timing rows are expensive, said in colour.** Twenty-odd numbers down the drawer,
//   and nothing in them says which one to look at. Each row's colour answers one question
//   -- what fraction of this frame went here -- read continuously off CET-I1.
//   **The denominator is the whole frame, idle included, and the ramp spans all of it.** A
//   row is drawn at the fraction it actually occupies, so the scale is absolute: a tenth of
//   a fast frame and a tenth of a slow one wear the same colour, and the curve above says
//   which of the two the session is in. The shares nest correctly, a parent's being the sum
//   of its children's, and they sum with `idle` to the whole ramp.
// **Where the ramp reaches its far end**: a row costing this share of the frame is drawn in
// the map's last colour. At the whole frame the far end means a step that *is* the frame.
const SHARE_RAMP_FULL_DIAGNOSTIC = 1.0;
// **The ramp is walked by ratio, not by difference.** Laid out linearly over the whole
//   frame, every row on a comfortable session lands in the first two steps and the tree
//   reads as one colour: a page waiting on the display spends most of a frame idle, so the
//   drawing's own rows are all small fractions and the interesting differences between them
//   -- one row ten times another -- are differences the far end of the scale cannot show.
//   Measured that way at 28.8 ms: the costliest row at 12.7% and the floor at 0.3% sat 30
//   units of blue apart out of the ramp's 131, and the rows between them were one colour.
//   On this scale **equal distance along the ramp is equal ratio of cost**, which is the
//   comparison a reader is actually making, and the spread no longer depends on whether the
//   frame happened to be busy.
//   The knee is where the scale stops being logarithmic and goes linear, so a row costing
//   nothing has somewhere to sit -- a log has no zero. A hundredth of the frame is the
//   choice: below it a row is not the one to look at whatever it sits next to.
//   A **symlog** proper, linear under the knee and logarithmic over it, rather than the
//   `log1p` that smooths the join. `log1p` is only asymptotically logarithmic, so its
//   decades are not equal -- measured, the decade above the knee spanned 0.37 of the ramp
//   where the top one spanned 0.48 -- and the equal-ratio-equal-distance promise above is
//   the whole point. The seam costs a kink in the rate at the knee and buys exactness.
//   The linear toe is worth **one decade of ramp**, the usual convention, which makes the
//   whole scale legible as a sentence: below a hundredth of the frame, then a hundredth to
//   a tenth, then a tenth to all of it -- a third of the ramp each.
const SHARE_RAMP_KNEE_DIAGNOSTIC = 0.01;
const DECADES_RAMP_TREE = Math.log10(SHARE_RAMP_FULL_DIAGNOSTIC / SHARE_RAMP_KNEE_DIAGNOSTIC);
const UNITS_RAMP_TREE = DECADES_RAMP_TREE + 1; // The decades, plus the toe's own decade.
function positionRampTree(share) {
  // Where a share falls along the ramp, from nothing at 0 to all of it at a whole frame.
  const held = Math.min(Math.max(share, 0), SHARE_RAMP_FULL_DIAGNOSTIC);
  if (held <= SHARE_RAMP_KNEE_DIAGNOSTIC) {
    return held / SHARE_RAMP_KNEE_DIAGNOSTIC / UNITS_RAMP_TREE;
  }
  return (1 + Math.log10(held / SHARE_RAMP_KNEE_DIAGNOSTIC)) / UNITS_RAMP_TREE;
}
// The tree's ramp, from `ramp.nim` through `nimRampTree`: six floats a step, a row's
// label rgb then its value rgb. What the ramp is -- CET-I1 re-lit to this drawer's own
// text tones -- and what holds it to that is `tools/check_ramp.nim`; nothing here knows
// anything about it beyond how to walk it.
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

// The legend bar is the ramp **as the rows are actually tinted**: across its width sits the
// share, not the ramp position, so the colours crowd into its left exactly as they do down
// the tree and a reader can lay a row's colour against it and read the share off. Painted
// by calling the same function the rows are tinted by, so a key that disagreed with the
// tree would have to be a bug in one line rather than a second declaration left behind.
const STOPS_LEGEND_RAMP = 48;
(() => {
  const bar = document.getElementById('diag-legend-ramp');
  if (bar === null) return;
  const stops = [];
  for (let i = 0; i <= STOPS_LEGEND_RAMP; i += 1) {
    const share = i / STOPS_LEGEND_RAMP;
    stops.push(`${rampTreeAt(share).label} ${(share * 100).toFixed(1)}%`);
  }
  bar.style.background = `linear-gradient(to right, ${stops.join(', ')})`;
})();

function rampTreeAt(share) {
  // Sample the ramp at one row's share of the frame, interpolating between the shipped
  //   steps so a row's colour moves as its cost does rather than stepping between bands.
  //   `check_ramp` measures what interpolating costs against the map's full 256 entries.
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
// **The axis follows the window, but not at the window's own speed.** Fitted frame for
//   frame it snapped: one slow frame widened it, and the moment that frame aged out of the
//   window it snapped back, so the curve jumped about and two glances a second apart could
//   not be compared. Two things fix that without going back to a fixed axis.
//   *A wait before anything moves.* An extent that differs from what is drawn starts a
//   clock, and only a difference that stands for `MILLISECONDS_AXIS_WAIT` moves the axis at
//   all -- so a window that dips and comes back, which is what an ageing spike does, leaves
//   the axis exactly where it was rather than travelling out and back.
//   *Then a glide, not a jump.* An exponential ease toward the extent, on a time constant
//   rather than a step count, so it runs at the same speed however often it is drawn.
//   The deadband is proportional: half a millisecond matters on a 33 ms axis and is noise
//   on a 130 ms one.
const MILLISECONDS_AXIS_WAIT = 400;
const MILLISECONDS_AXIS_EASE = 420;
const SHARE_AXIS_DEADBAND = 0.02;
let milliseconds_axis = 0; // What is drawn; zero until the first extent arrives.
let ms_axis_restless = 0; // When the extent first differed from it; zero while settled.
let ms_axis_eased = 0; // Last ease, for the elapsed time the glide is scaled by.
// True while the axis is still travelling, so the frame loop can redraw the curve at its
//   own rate instead of the panel's five-a-second, which would show the glide as steps.
let is_axis_gliding = false;
function axisEased(milliseconds_wanted) {
  const now = performance.now();
  const since = ms_axis_eased === 0 ? 0 : now - ms_axis_eased;
  ms_axis_eased = now;
  // The first extent is simply adopted: there is nothing to ease from.
  if (milliseconds_axis === 0) milliseconds_axis = milliseconds_wanted;
  const apart = Math.abs(milliseconds_wanted - milliseconds_axis);
  if (apart <= SHARE_AXIS_DEADBAND * milliseconds_axis) {
    ms_axis_restless = 0; // Settled: the clock only runs while the two are apart.
    is_axis_gliding = false;
    return milliseconds_axis;
  }
  if (ms_axis_restless === 0) ms_axis_restless = now;
  if (now - ms_axis_restless < MILLISECONDS_AXIS_WAIT) {
    is_axis_gliding = false;
    return milliseconds_axis; // Still inside the wait; the extent may yet come back.
  }
  is_axis_gliding = true;
  milliseconds_axis +=
    (milliseconds_wanted - milliseconds_axis) * (1 - Math.exp(-since / MILLISECONDS_AXIS_EASE));
  return milliseconds_axis;
}
function spanExceedance() {
  // The window's own bounds, in buckets: the fastest frame it holds and the slowest. The
  //   curve is drawn between exactly these, so it leaves 0% at one and reaches 100% at the
  //   other instead of running flat along both edges -- which is what makes the two of them
  //   readable rather than merely present. Both extremes are the window's own: a lone
  //   collection pause belongs on a chart of what the session actually did, and it is the
  //   axis's easing, not a trim, that stops one deciding how the rest is drawn.
  //   Read by the curve alone now: the timing rows below it used to be capped at the worst
  //   band this reported, which the tree's own absolute ramp made unnecessary.
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
function drawExceedance() {
  if (context_exceedance === null) return;
  const w = exceedance.clientWidth || 300, h = exceedance.clientHeight || 74;
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
  // Proportion **below**, rising: the question a reader is asking is how much of the
  //   session came in under a duration, and a curve that answers it climbing left to right
  //   is read without translation.
  //   Linear, where the axis is the proportion itself; or, on the switch, three decades of
  //   the distance from the top -- the share still at or over -- which is the only way the
  //   slowest one percent is legible at all, since linear squeezes it flat against the
  //   ceiling for the last third of the chart.
  const yOf = is_exceedance_log
    ? (share_below) => {
        const share_over = Math.max(1 - share_below, Math.pow(10, -DECADES_EXCEEDANCE));
        return h * (1 + Math.log10(share_over) / DECADES_EXCEEDANCE);
      }
    : (share_below) => h - share_below * h;

  context_exceedance.font = FONT_EXCEEDANCE;
  context_exceedance.textBaseline = 'top';
  // Recessive rules at the heights the axis actually resolves, each named except the floor.
  //   Linear takes a quarter at a time up to 100%, which is what the curve's own arrival is
  //   read against. Log takes the decades instead, up to the 99.9% its three decades
  //   actually reach -- the ceiling is the whole reason to switch to it, so it is the last
  //   thing that should go unnamed. **Neither names 0%**: it is where every curve starts,
  //   so the label states what the shape already says, and at the very bottom of the canvas
  //   it has nowhere to sit that is not either off the plot or on top of the label above.
  const gridlines = is_exceedance_log
    ? [{ share: 0 }, { share: 0.9, label: '90%' }, { share: 0.99, label: '99%' },
      { share: 0.999, label: '99.9%' }]
    : [{ share: 0 }, { share: 0.25, label: '25%' }, { share: 0.5, label: '50%' },
      { share: 0.75, label: '75%' }, { share: 1, label: '100%' }];
  context_exceedance.strokeStyle = 'rgba(139, 150, 163, 0.18)';
  context_exceedance.lineWidth = 1;
  for (const gridline of gridlines) {
    // Held a half-pixel inside the canvas at the two ends, where the line would otherwise
    //   straddle the edge and render at half its weight or not at all.
    const y = Math.min(h - 0.5, Math.max(0.5, Math.round(yOf(gridline.share)) + 0.5));
    context_exceedance.beginPath();
    context_exceedance.moveTo(0, y);
    context_exceedance.lineTo(w, y);
    context_exceedance.stroke();
    if (gridline.label === undefined) continue;
    // Under its own line and at the left margin, which the rates along the top and the
    //   curve's own climb both leave clear.
    context_exceedance.fillStyle = 'rgba(139, 150, 163, 0.75)';
    context_exceedance.fillText(gridline.label, 2, y + 1);
  }
  // The budgets themselves, **each named twice**: the rate at the top of the line and the
  //   duration at its foot, so one dashed mark answers both "how smooth is that" and "how
  //   long is that" and a reader never has to convert between them in their head.
  //   Both sit *over* the plot rather than in rows of their own. Rows were tried, and they
  //   do buy clearance -- the curve reaches 100% in the top right, under the slowest mark's
  //   label, and 0% in the bottom left, under the fastest mark's duration -- but they cost
  //   22px of a drawer that has none to spare, and a number a reader can find beside its
  //   own line is worth more than a guarantee it is never crossed. The labels are drawn
  //   before the curve, so where the two meet it is the curve that reads as continuous.
  //   Drawn only where the axis actually reaches them: a window with nothing slower than
  //   120 fps in it has no business drawing the others, and the 15 fps mark stays away
  //   until the window holds a frame that slow. The floor is set so the slowest mark the
  //   axis is guaranteed to reach -- 30 fps -- stands clear of the right edge with room
  //   for its own labels; see `SHARE_MARK_LEAST`.
  context_exceedance.setLineDash([2, 3]);
  for (const budget of BUDGETS_EXCEEDANCE) {
    if (!Number.isFinite(budget.milliseconds)) continue;
    if (budget.milliseconds > milliseconds_full) continue;
    const x = Math.round(xOf(budget.milliseconds)) + 0.5;
    context_exceedance.strokeStyle = 'rgba(139, 150, 163, 0.30)';
    context_exceedance.beginPath();
    context_exceedance.moveTo(x, 0);
    context_exceedance.lineTo(x, h);
    context_exceedance.stroke();
    context_exceedance.fillStyle = 'rgba(139, 150, 163, 0.75)';
    // Inside the line where it would otherwise run off the right edge. Both rows take the
    //   same side, so the rate and its duration stay in one column whichever way they go.
    const is_room = x + 14 < w;
    context_exceedance.textAlign = is_room ? 'left' : 'right';
    const x_label = x + (is_room ? 2 : -2);
    // Haloed against the drawer's own surface before being filled. These sit over the plot
    //   and the curve crosses the fastest ones outright -- a duration bisected by a stroke
    //   of the same weight is unreadable, and this is what buys the numbers their place
    //   inside without asking the chart for height it does not have.
    const write = (text, y, baseline) => {
      context_exceedance.textBaseline = baseline;
      context_exceedance.strokeStyle = HALO_LABEL_EXCEEDANCE;
      context_exceedance.lineWidth = 3;
      context_exceedance.setLineDash([]);
      context_exceedance.strokeText(text, x_label, y);
      context_exceedance.fillText(text, x_label, y);
      context_exceedance.lineWidth = 1;
      context_exceedance.setLineDash([2, 3]);
    };
    write(budget.label, 1, 'top');
    write(budget.milliseconds.toFixed(1), h - 1, 'bottom');
  }
  context_exceedance.setLineDash([]);
  context_exceedance.textAlign = 'left';
  context_exceedance.textBaseline = 'top';

  // The curve, in one run per band, each stroked in that band's own colour and each
  //   starting where the last ended so the line is continuous across the change. Drawn
  //   band by band rather than sampling a colour per segment: a run is one path and one
  //   stroke, and the join at a boundary is exact rather than a pixel of the wrong hue.
  context_exceedance.lineWidth = 1.5;
  let band_open = -1;
  for (let i = bucket_first; i <= bucket_last; i += 1) {
    const milliseconds = i * MILLISECONDS_BUCKET;
    const band = bandOfExceedance(milliseconds);
    // `shares_exceedance[i]` is the share at or over this duration, so its complement is
    //   the share below it -- the histogram stays an exceedance and only the drawing turns
    //   over, which is what keeps the scan a plain suffix sum.
    const point = [xOf(milliseconds), yOf(1 - shares_exceedance[i])];
    if (band !== band_open) {
      if (band_open >= 0) {
        // Carry the run into the boundary before closing it, so the two runs meet on the
        //   dashed line rather than a bucket short of it.
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
  // The last bucket's own upper edge, where the share below reaches one: the slowest frame
  //   the window holds, standing at 100% and at the axis's own end.
  context_exceedance.lineTo(xOf((bucket_last + 1) * MILLISECONDS_BUCKET), yOf(1));
  if (band_open >= 0) context_exceedance.stroke();

  // The one number worth stating outright beside the curve: what the slowest frame in a
  //   hundred took. A reader tuning for smoothness is tuning that, not the median.
  let milliseconds_p99 = 0;
  for (let i = BUCKETS_EXCEEDANCE - 1; i >= 0; i -= 1) {
    if (shares_exceedance[i] >= 0.01) { milliseconds_p99 = i * MILLISECONDS_BUCKET; break; }
  }
  diagnostic_exceedance.textContent =
    '1 in 100: ' + milliseconds_p99.toFixed(1) + ' ms \u00b7 ' + counted + ' frames';
  // The axis's own extent, said where the reader is looking rather than left to be
  //   inferred from a curve that now moves with the window.
  if (label_exceedance_axis !== null) {
    // The mode is named in the caption as well as lit on its own pill, so a screenshot of
    //   the drawer says which axis the curve in it was read against.
    label_exceedance_axis.textContent =
      'frames under \u00b7 0\u2013' + milliseconds_full.toFixed(0) + ' ms' +
      (is_exceedance_log ? ' \u00b7 log' : '');
  }
}

// The scale bar's own reading, as a map carries one: a span of ground drawn at its true
//   screen length, with the distance it covers written under it, and **the ground grid's
//   own cell size beside that** -- which is what makes the ruled ground measurable rather
//   than decorative. The span is chosen 1-2-5 by decade to land near
//   `PIXELS_RULER_TARGET`, the way every map scale is stepped: a bar tied rigidly to one
//   cell runs off the screen when the camera is close and shrinks to nothing when it is
//   far, because the cell steps by decades while the projection does not.
//   The cell comes from `nimGridMetrics`, which reads the same `mesh.sizeCellGridAt` the
//   grid is laid with; nothing here re-derives a cell size of its own.
const ruler = document.getElementById('ruler');
const ruler_bar = document.getElementById('ruler-bar');
const ruler_label = document.getElementById('ruler-label');
const PIXELS_RULER_TARGET = 130;
const STEPS_RULER = [1, 2, 5];
function refreshRuler() {
  if (ruler === null) return;
  const [size_cell, world_per_pixel] =
    nimGridMetrics(canvas.clientWidth, canvas.clientHeight);
  // No ground drawn -- an eye above the fog's own reach -- so there is nothing to measure.
  if (!(size_cell > 0) || !(world_per_pixel > 0)) { ruler.hidden = true; return; }
  const world_target = PIXELS_RULER_TARGET * world_per_pixel;
  const decade = Math.pow(10, Math.floor(Math.log10(world_target)));
  let span = decade;
  for (const step of STEPS_RULER) {
    // The largest 1-2-5 step still at or under the target: a bar that overshoots crowds
    //   the corner it sits in, while one that undershoots is only harder to read against.
    if (step * decade <= world_target) span = step * decade;
  }
  ruler.hidden = false;
  ruler_bar.style.width = (span / world_per_pixel).toFixed(1) + 'px';
  // Thousands separated with a thin space rather than a comma: a comma reads as a decimal
  //   point to much of the world, and these numbers are what the bar is claiming.
  const written = (value) => (value >= 1000
    ? value.toLocaleString('en-US').replace(/,/g, '\u2009')
    : String(Number(value.toPrecision(3))));
  ruler_label.textContent = span === size_cell
    ? written(span) + ' units, one grid cell'
    : written(span) + ' units \u00b7 grid ' + written(size_cell);
}

// **Write only where the value moved.** Every one of these is a text node or an inline
//   style the browser must re-style and re-lay out afterwards, and measured on a full tree
//   only about **10 of 29 rows actually change** -- so two thirds of the writes were
//   dirtying layout to set the string that was already there. The same rule the pool strip
//   and the objects list already follow, at the grain of a single element.
//   `WeakMap` rather than a table keyed by row name: a row's element can be replaced, and a
//   stale entry keyed by name would then suppress the first write to its successor.
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

// The panel's own collapsible section, read by the guard below rather than by a class on
//   the drawer: the drawer holds several sections and only this one owns these figures.
const section_diagnostics = document.querySelector('.section[data-section="diagnostics"]');
let ms_refresh_distribution = 0; // Last slow pass; zero, so the first tick draws everything.

function refreshDiagnostics() {
  // **Nothing here is worth a millisecond while the drawer is shut.** Every figure this
  //   writes is inside it, and with the drawer closed the whole refresh was still running
  //   five times a second: measured on the 1,024-object demo at 2.8 ms typical and 5.7 ms
  //   worst, landing on one frame in twelve. On a frame that otherwise costs about a
  //   millisecond -- which is what the scene hold made the still case -- that is not
  //   overhead, it is a stutter a reader can see, and it was the largest single source of
  //   frame-time variance left in the build.
  //   The two canvases could not skip themselves either: each fell back to a 300-pixel
  //   width where its own was zero, so a canvas nobody could see was drawn at a made-up
  //   size. That fallback is for a canvas that has not been laid out yet, not for one
  //   inside a closed drawer, and this guard is what tells the two apart.
  //   **And the same argument one level down**: the diagnostics section is collapsible
  //   inside an open drawer, and a collapsed one gave both canvases a zero width again --
  //   so they fell back to 300 pixels and drew, five times a second, for a reader looking
  //   at the objects list. The drawer guard above did not catch it because the drawer is
  //   genuinely open.
  if (!drawer.classList.contains('open')) return;
  if (!section_diagnostics.classList.contains('open')) return;
  // Whether the four- and seventeen-second figures are due; see
  //   `MILLISECONDS_WINDOW_DISTRIBUTION`. The numeric rows below run either way.
  const ms_now_distribution = performance.now();
  const is_redrawing_distribution =
    ms_now_distribution - ms_refresh_distribution >= MILLISECONDS_WINDOW_DISTRIBUTION;
  if (is_redrawing_distribution) ms_refresh_distribution = ms_now_distribution;

  if (is_redrawing_distribution) {
    drawExceedance();
    const w = sparkline.clientWidth || 300, h = sparkline.clientHeight || 40;
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

  // Averaged over the last 200 ms rather than taken from the newest frame: a per-frame
  //   reading changes several times faster than it can be read, and a frame rate quoted
  //   off one frame swings by tens of fps between glances.
  const frames_recent = framesRecent();
  let total_recent = 0;
  for (let i = 0; i < frames_recent; i += 1) {
    total_recent += history_frame[(index_history_frame + FRAMES_HISTORY - 1 - i) % FRAMES_HISTORY];
  }
  const mean_frame = total_recent / frames_recent;
  // **No band ceiling any more, and no share-of-work denominator.** Both belonged to the
  //   four-band tint this replaced: the bands had to agree with the curve above them, so
  //   the tree was capped at whatever band that curve was drawing. The ramp is absolute --
  //   a row's share of the *frame*, over the whole of it -- so it says the same thing
  //   whatever the curve happens to show, and there is nothing left to contradict.
  writeText(diagnostic_frame_time,
    mean_frame.toFixed(2) + ' ms (' + Math.round(1000 / Math.max(mean_frame, 1)) + ' fps)');

  // Each step of the drawing process, as `mean over 200 ms (median over the ring)`: the
  // short mean is what a reader watches while changing something, the long median is the
  // settled figure to act on. A phase that has not run at all stays an em dash.
  for (const [name] of PHASES_DIAGNOSTIC) {
    if (!isPhaseShown(name)) continue; // Inside a closed node; nobody is reading it.
    const median = medianPhaseHeld(name, is_redrawing_distribution);
    if (median === null) continue;
    // A phase idle for the whole window shows its median rather than nothing: it is a step
    //   that runs, and "0.00" would claim it had run for free this window.
    const recent = meanPhase(name, frames_recent);
    const shown = recent === null ? median : recent;
    writeText(element_phase[name], shown.toFixed(2) + ' (' + median.toFixed(2) + ') ms');
    // The count beside the row's own name, so **every** value ends in `ms` and the times
    //   down the tree finish in one column. A zero is shown rather than left off: a kind
    //   present but empty says something a kind that is absent does not.
    writeText(element_tally[name], ' (' + count_phase[name] + ')');
    // And what that number is worth, in the curve's own colours.
    if (element_row[name] === null) continue;
    // Some rows keep the neutral ink instead. **`idle` always**: it is the frame's
    //   leftover rather than work done, so on a healthy frame it is the largest share of
    //   all and tinting it would paint the best case in the ramp's loudest colour. And
    //   where nothing has been measured yet there is no share to take.
    if (name === 'idle' || !(mean_frame > 0)) {
      writeColour(element_row[name], '');
      writeColour(element_phase[name], '');
      continue;
    }
    // **Against the whole frame, not against the work in it.** A row's colour answers
    //   "how much of a frame goes here", so the denominator is the frame -- which makes
    //   the ramp an absolute reading a reader can compare between sessions, rather than
    //   a share of a total that shrinks as the page gets faster and repaints every row
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

  const count = nimSceneCount(), capacity = nimSceneCapacity();
  writeText(diagnostic_pool, count + ' / ' + capacity);
  drawPoolGrid(count, capacity);
}

// The object pool, one square per slot in the ink of whatever object holds it.
//   `nimPoolCellColors` decides every cell's colour, free ones included, so no palette rule
//   lives out here -- it returns one [r, g, b] triple per slot, in slot order, and this only
//   arranges them.
//   **Drawn when the scene changes and at no other time.** At a capacity of 1,024 the walk
//   that fills that buffer is about a millisecond, and this refresh runs five times a second
//   for a picture that moves when an object is added or removed. The scene's own revision is
//   exactly that question, and it is the same counter the frame hold is keyed on. The
//   canvas's own geometry is part of the key as well, because a resize clears what was drawn
//   and because the section opens onto a canvas that had no size until it did.
function drawPoolGrid(count, capacity) {
  if (context_pool === null) return;
  // **The gate runs before anything measures.** `devicePixelRatio` and the revision are
  //   plain reads; the canvas's width is not, and asking for it here -- after the rows above
  //   have been written -- is what makes the browser lay the drawer out there and then.
  const ratio = Math.min(window.devicePixelRatio || 1, 2.5);
  if (revision_pool_last === nimSceneRevision() && ratio_pool_last === ratio &&
      !is_pool_stale) return;

  const width = grid_pool.clientWidth;
  if (!(width > 0)) return; // Laid out inside something closed; nothing to draw on.
  revision_pool_last = nimSceneRevision();
  ratio_pool_last = ratio;
  is_pool_stale = false;

  // The first size whose grid fits the budget, or the smallest offered where none does.
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
  // **Drawn at device resolution, unlike its two neighbours.** The curve and the sparkline
  //   are 1.5px strokes and lose nothing to a doubled display; a grid of hard-edged squares
  //   this small does, and every cell edge would be soft on the tablet this is read on.
  geometry_pool_drawn = { cell, gap, columns, rows, height };
  grid_pool.style.height = height + 'px';
  grid_pool.width = Math.round(width * ratio);
  grid_pool.height = Math.round(height * ratio);
  context_pool.setTransform(ratio, 0, 0, ratio, 0, 0);
  context_pool.clearRect(0, 0, width, height);
  const cells = nimPoolCellColors();
  for (let slot = 0; slot < capacity; slot += 1) {
    const at = slot * 3;
    // Keyed on the bytes rather than the floats, so a triple that rounds to the same colour
    //   is the same entry; `rgbToCss` rounds to bytes anyway.
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
  // What the picture says, for a reader who cannot see it. The `title` beside it in the
  //   markup carries the legend, which does not change.
  grid_pool.setAttribute(
    'aria-label', count + ' of ' + capacity + ' object slots in use, one cell each',
  );
}

/* ---------------------------------------------------------------------- */
/* Overlay: hover ring + drag rubber-band, as plain 2D SVG drawn on top of */
/* the WebGL canvas -- mirrors `visualiser.drawInteractionOverlay` exactly */
/* (same radius, same tint per operation), just drawn through SVG rather   */
/* than through Dear ImGui's own immediate-mode draw list.                */
/* ---------------------------------------------------------------------- */

const svg_overlay = document.getElementById('overlay');
// Read from marker.nim's own constants via nimOverlayMetrics, rather than a hand-copied
// literal that could drift out of sync with them.
const [WIDTH_OVERLAY_LINE, ALPHA_MARKER_SELECTED, ALPHA_MARKER_HOVER] =
  nimOverlayMetrics();
// Mirrors marker.MarkerKind's own ordinals; nimSelectionMarker leads with one of these.
const MARKER_RING = 0, MARKER_RAILS = 1, MARKER_LOOP = 2, MARKER_BANDS = 3,
  MARKER_FRAME = 4;
// Read from interaction.nim's own constants via nimMenuMetrics, for the same reason the
// marker's sizes are: a hand-copied literal here would drift from the desktop's menu.
const [HEIGHT_MENU_WEDGE, PADDING_MENU_WEDGE, ROUNDING_MENU_WEDGE,
  WIDTH_MENU_WEDGE_BORDER, RADIUS_MENU_CENTRE,
  ALPHA_MENU_WEDGE, ALPHA_MENU_UNOFFERED] = nimMenuMetrics();
// Floats per wedge in nimDragMenuLayout: x, y, offered. The wedge's own colours come from
// `.menu-wedge`, which is `.selection-menu button` -- see shell.html.
const FLOATS_MENU_WEDGE = 3;

// **The overlay reuses its own elements rather than rebuilding the DOM each frame.**
// `refreshOverlay` used to clear the layer with innerHTML and create every marker,
// pulse and wedge afresh -- element construction plus garbage per frame, roughly half
// the overlay row's cost while anything was selected. Now each frame *stages* what it
// wants drawn: `stageEl` takes a recycled element of the right tag (stripping whatever
// attributes the last use left on it), and one `replaceChildren` at the end swaps the
// layer's children in staged order -- so z-order still reads straight down the staging
// calls, and an element unused this frame simply comes off the DOM into the pool.
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

// Stroke one object's marker into the overlay. Every geometric decision -- which outline,
// how far off the object it sits, where its points land on screen -- was made by
// marker.nim; this only turns the flat array it reports into SVG elements.
//
// **The interaction layer works in CSS pixels; the render layer works in framebuffer
// pixels.** Two layers, two units, and each is told which it is in: the cursor, hover,
// markers and menus are all asked and answered in CSS pixels, while `nimBuildFrame` and
// the WebGL uniforms below take the framebuffer size and scale their own constants by the
// device pixel ratio. This used to be half-done -- positions were converted from
// framebuffer to CSS but every *length* was not, so a marker's radius and a menu wedge's
// height were drawn at ratio times their intended size, and "make the marker bigger" had
// no stable meaning. Converting nothing is simpler than converting some of it.
// Rails arrive as consecutive pairs, one per drawn piece, so the pairwise loop below
// covers a line clipped into any number of them without knowing how many to expect.
// The orientation pulse travelling along a selected object's marker: which way it goes is
// the object's own orientation, and the shape of every run comes across the bridge already
// in screen space. Filled rather than stroked, because each run tapers from a swollen head
// back to the outline's own width and a stroke carries one width for its whole length --
// marker.ribbonAlong shapes that outline, this only fills what it is handed. Only a caller
// passing a time gets one -- hover and focus wear the same marker standing still.
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
    // A whole ring stays a <circle>, the element it has always been, so a marker that is
    // not filling draws exactly as it did before holds were animated. Only a partial one
    // becomes an arc path.
    if (fraction >= 1) {
      stageEl('circle', {
        cx: points[0][0], cy: points[0][1], r: radius,
        fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      });
    } else if (fraction > 0) {
      // Clockwise from twelve o'clock, measuring the angle from the top so the sweep
      // reads the way every other progress dial does. With y downward, SVG's positive
      // sweep direction (flag 1) is that same clockwise sense.
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
    // A frame is a closed polyline too -- a circle while it expands, the screen's own
    // rectangle once it arrives -- so it strokes through the very same element a plane's
    // loop does rather than through a <rect> of its own: one path for every closed
    // outline, and nothing to keep in step when one of them changes.
    stageEl(is_closed ? 'polygon' : 'polyline', {
      points: points.map((p) => p[0] + ',' + p[1]).join(' '),
      fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
    });
  } else if (kind === MARKER_BANDS) {
    // Two runs in one array: the header says how many points the first band holds and
    // whether each band closed, since either can be cut into an arc by the eye on its own.
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
  // One clock reading for the whole overlay, before any pulse is shaped: every selected
  // object's comet advances by that same step. A pulse carries its phase between frames
  // rather than computing it from the time -- see selection.PulseClock for why reading it
  // off the clock made every comet lurch the moment the camera moved.
  nimTickPulse(now());

  // One marker per selected object, shaped to that object by marker.nim -- a ring about
  // a point, rails flanking a line, a loop lying on a plane. Hover draws the very same
  // marker at lower opacity, so both read as one family and hovering a line previews
  // exactly what selecting it will draw.
  for (const slot of slots_selection) {
    if (slot === nimHoldSlot()) continue; // Its own swollen marker is drawn below.
    appendMarker(slot, ALPHA_MARKER_SELECTED, w, h, 1);
    appendMarkerPulse(slot, ALPHA_MARKER_SELECTED, 1, false);
  }

  // A press maturing into a selection fills that item's own marker as it goes, so the
  // wait reads as filling rather than as nothing happening. Drawn at the selected weight
  // it is about to become, and skipped for an item already selected, whose finished
  // marker is on screen already.
  // Filled markers swell clear of the finger doing the filling. `nimBeginHold` is called
  // from the touch branch of `pointerdown` and from nowhere else, so a hold in progress on
  // this build is a finger's by construction -- the flag is passed rather than inferred
  // inside marker.nim, which cannot see what kind of pointer is on the glass.
  // Drawn **even once the slot is selected**, unlike every other overlay rule here: a
  // matured hold keeps its swollen marker until the finger lifts and it settles, and the
  // plain selected marker underneath it is the very size this is animating away from.
  const slot_hold = nimHoldSlot();
  if (slot_hold >= 0) {
    appendMarker(slot_hold, ALPHA_MARKER_SELECTED, w, h, nimHoldProgress(now()), true,
      nimSwellHold(now()));
  }

  // Hover and keyboard focus wear the same marker at the same weight: a reader driving by
  // key sees exactly what a reader driving by pointer sees, and the focus indicator WCAG
  // 2.4.7 asks for is machinery already built rather than a second one invented beside it.
  for (const slot of [nimHoverSlot(), nimFocusSlot()]) {
    if (slot >= 0 && slot !== slot_hold && !slots_selection.includes(slot)) {
      appendMarker(slot, ALPHA_MARKER_HOVER, w, h, 1);
    }
  }

  if (nimDragActive()) {
    const src = nimAnchorScreen(nimDragSourceSlot(), canvas.clientWidth, canvas.clientHeight);
    if (src[2] > 0.5 && cursor) {
      const [sx, sy] = [src[0], src[1]];
      // Tinted by what releasing would do, not by which button started the drag: the
      // operation's own colour over a pair that makes something, the reserved magenta
      // over one that makes nothing, neutral while crossing empty space.
      const tint = nimDragTint();
      const stroke = 'rgba(' + Math.round(tint[0] * 255) + ',' +
        Math.round(tint[1] * 255) + ',' + Math.round(tint[2] * 255) + ',0.85)';
      stageEl('line', {
        x1: sx, y1: sy, x2: cursor.x, y2: cursor.y,
        stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      });
      // Which way round the pair is being taken: the band swelling into its own last
      // stretch, the same shape the orientation pulse wears. Shaped by `marker.cometFor`
      // across the bridge rather than worked out here -- the band's direction is the
      // gesture's own business, and this layer fills what it is handed. Empty while the
      // cursor rests on its own source, which points nowhere.
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

  // One swap for the whole layer, in staged order. Also what detaches whatever last
  //   frame drew and this one did not: those elements sit in the pool, off the DOM.
  svg_overlay.replaceChildren(...staged_overlay);
}

// Draw the four wedges of an open choice menu. Every position, colour, label and whether
// a wedge is offered comes from interaction.nim through nimDragMenuLayout/Labels, and
// which one the cursor stands in from nimDragMenuHighlighted -- the same call the release
// resolves through, so the highlight is never a second opinion about where the cursor is.
// A wedge label's laid-out width, measured once per label and remembered. Still measured
// from what the browser actually laid it out as -- never estimated from a character
// count, which drifts the moment the face loaded is not the one the estimate was tuned
// against -- but a label's metrics cannot change between frames, and `getBBox` forces a
// layout, so paying it once per label is the whole point. The cache empties when the
// document's fonts finish loading, in case an early measure ran against a fallback face.
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

function appendChoiceMenu(w, h) {
  const layout = nimDragMenuLayout();
  if (layout.length === 0) return;
  const labels = nimDragMenuLabels();
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
      // An unoffered wedge is dimmed rather than dropped: a gap where a wedge should be is
      // unreadable, and the point of a fixed compass is that a choice never moves.
      'fill-opacity': is_offered ? 1 : 0.6,
      class: i === highlighted ? 'menu-wedge-label on' : 'menu-wedge-label',
    });
    text.textContent = labels[i];
  }
  // The middle is where nothing is chosen, and the way out of a menu that opened unasked.
  stageEl('circle', {
    cx: centre[0], cy: centre[1],
    r: RADIUS_MENU_CENTRE,
    fill: 'none', class: 'menu-centre', 'stroke-width': WIDTH_OVERLAY_LINE,
  });
}

/* ---------------------------------------------------------------------- */
/* Pointer input.                                                          */
/*   One invariant across every pointer: THE PRESS TARGET CHOOSES THE      */
/*   SCHEME. A press that lands on an object constructs; one that lands on */
/*   empty space moves the camera. Mirrors `visualiser.handleEvent`.       */
/*   Mouse: left-drag takes whatever the two objects make and is never     */
/*   interrupted, right-drag opens the choice menu on arrival. From empty  */
/*   space, left orbits, right pans, the wheel dollies.                    */
/*   Touch: the same, with the dwell as the only way to open the menu --   */
/*   there is no second button to force it with. A finger that presses an  */
/*   object and stays still selects it instead (the long-press), so the    */
/*   first movement past `TAP_MAX_MOVE` is what decides between the two.   */
/*   Two fingers still pinch and pan, and cancel any drag in progress.     */
/* ---------------------------------------------------------------------- */

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

const pointers = new Map();
let separation_pinch_start = null;
let pan_last = null;
// Button held for camera orbit/pan fallback, while no operation drag is active.
let button_mouse_drag = null;
let cursor_last = null;
// **What the pointer asked for, for the frame loop to answer once.** A pick and a dolly
//   both walk the whole scene, and a pointer or trackpad reports several times between two
//   frames; see the frame loop, which is where each of these is spent.
let is_hover_stale = false;
let deltas_wheel = 0; // Summed wheel travel awaiting one dolly; `wheel` says why.

// Touch long-press-to-select / tap-to-toggle / drag-to-construct state.
let touch_down_at = null, position_touch_down = null, has_touch_moved = false;
let has_long_press_fired = false;
// The item the finger came down on, and whether that press has become a construction drag.
//   `slot_touch_down` is read once at pointerdown, while hover still holds it -- picking
//   again later would report whatever the finger has since moved over.
let slot_touch_down = -1, is_touch_dragging = false;
// Whether the press landed on something a drag may be built from, decided at the press and
//   held for the gesture. **A press that can construct never moves the camera, not even
//   over the pixels before the slop is crossed** -- that is the press-target rule the mouse
//   already follows by choosing its scheme at the button. Touch reached the same place by a
//   different road and got it wrong: a finger that eased into its drag orbited for the frame
//   or two before the slop, which latched `nimSetCameraDragging`, and hover is suppressed
//   while the camera moves -- so the construction drag that armed a moment later ran blind
//   for the rest of the gesture, ghosting nothing and building nothing. A flick that cleared
//   the slop in one event armed before any of that and worked, which is what made the fault
//   read as intermittent.
let is_touch_press_constructing = false;
// How far a press may move and still be a press comes from `interaction.PIXELS_TAP_SLOP`:
//   it decides which scheme the gesture enters, which is a rule about the gesture, not a
//   presentation number. The tap *timeout* stays here -- that one really is local.
const TAP_MAX_MS = 350, TAP_MAX_MOVE = nimTapSlop();
// How a finger's construction drag comes to offer the wheel. A mouse reads this off the
//   button it pressed; touch has no second button, so it names the one arming that waits.
const ARMING_DRAG_TOUCH = nimDragArmingOnDwell();

// Mouse click-vs-drag disambiguation -- a plain click (no movement) selects/shift-selects;
//   an actual drag still applies join/meet/project exactly as before. *Whether* a press
//   stayed a click is `interaction.isClick`'s to say: both of its bounds lived here as
//   MOUSE_CLICK_MAX_MS/MOUSE_CLICK_MAX_MOVE until the desktop needed the same answer. All
//   that is left here is which button went down, which is this layer's own numbering.
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
  // Every gesture starts by saying it is not a camera move; the branches below say so where
  //   they are one. Cleared here rather than only at the release because a release can go
  //   missing -- a pointer cancelled, a touch sequence the browser tears down -- and a flag
  //   left true stops the hover ring working for the rest of the session, with nothing on
  //   screen to say why. Same failure the held keys have, handled the same way.
  if (pointers.size === 0) nimSetCameraDragging(false);
  const rect = canvas.getBoundingClientRect();
  const local = { x: e.clientX - rect.left, y: e.clientY - rect.top };
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

  if (e.pointerType === 'mouse') {
    nimUpdateCursor(local.x, local.y);
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
    // Note the press before anything is decided about it: whether it was a click is only
    //   knowable at the release, and both branches below can end in one.
    nimBeginPress(now());
    button_mouse_down = e.button;
    // The button says whether the drag decides for you or asks; what it builds is read
    // off the operands at release. Mirrors `visualiser.armingFor`.
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

  // Touch/pen: track for the existing multi-touch orbit/pinch/pan gesture, for a
  // single-finger tap that toggles selection membership once a selection exists, for a
  // long-press that starts one, and for a drag off an object that constructs.
  if (pointers.size === 1) {
    touch_down_at = performance.now();
    position_touch_down = local;
    has_touch_moved = false;
    has_long_press_fired = false;
    // Pick the item under the finger now and hand the press to Nim, which owns how long a
    //   hold takes and whether one is due. The frame loop asks it both, which is also what
    //   fills the item's own marker -- a timer firing on its own could not draw anything.
    //   The slot is kept as well: it is what decides, on the first movement, whether this
    //   press was a construction drag or a camera orbit.
    nimUpdateCursor(local.x, local.y);
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
    // Noted like any other press, so that a finger's own construction drag is measured
    //   against where the finger landed rather than against the last mouse press.
    nimBeginPress(now());
    slot_touch_down = nimHoverSlot();
    // Whether this press *can* become a construction drag, decided here at the press and
    //   not re-asked -- the same question `interaction.beginDrag` answers when the slop is
    //   finally crossed, asked early because the moves before that have to know which
    //   scheme they belong to. The sky is hovered wherever nothing else is and is refused
    //   there, so a press on it still falls through to the camera; see `beginDrag`.
    is_touch_press_constructing = slot_touch_down >= 0 && !nimIsHoverBackdrop();
    if (slot_touch_down >= 0) nimBeginHold(slot_touch_down, now());
  } else {
    touch_down_at = null; // A second finger landed; this is a pinch/pan gesture, not a tap.
    nimCancelHold();
    // ...and not a construction either. A drag the reader has visibly abandoned must not
    //   commit on whichever finger happens to lift first.
    if (is_touch_dragging) { nimCancelDrag(); is_touch_dragging = false; }
    slot_touch_down = -1;
    is_touch_press_constructing = false;
  }
  if (pointers.size === 2) {
    const points_flat = [...pointers.values()];
    separation_pinch_start = pointerDist(points_flat);
    pan_last = pointerMid(points_flat);
  }
});

canvas.addEventListener('pointermove', (e) => {
  const rect = canvas.getBoundingClientRect();
  cursor_last = { x: e.clientX - rect.left, y: e.clientY - rect.top };

  if (e.pointerType === 'mouse') {
    nimUpdateCursor(cursor_last.x, cursor_last.y);
    if (button_mouse_drag !== null && typeof button_mouse_drag === 'number') {
      // Re-check hover for the drag's own destination preview -- next frame, not now; see
      //   `is_hover_stale`.
      is_hover_stale = true;
      return;
    }
    if (!pointers.has(e.pointerId)) return;
    const prev = pointers.get(e.pointerId);
    const current = { x: e.clientX, y: e.clientY };
    pointers.set(e.pointerId, current);
    const dx = current.x - prev.x, dy = current.y - prev.y;
    // A camera gesture is not a hover, said at the *move* rather than at the press: a
    // press that never moves is a click, and a click has to know what it came down on.
    if (button_mouse_drag === 'orbit' || button_mouse_drag === 'pan') nimSetCameraDragging(true);
    if (button_mouse_drag === 'orbit') {
      nimCameraOrbit(
        -dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4,
      );
    } else if (button_mouse_drag === 'pan') {
      // Where the pointer was and where it is, not how far it moved: a pan grabs the
      // level under it and carries that point along, which needs both ends of the step.
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
    // The one moment this press stops being a press. Decided once, here, and never
    //   revisited: the press target chooses the scheme, so a finger that came down on an
    //   object constructs and one that came down on empty space moves the camera.
    //   `nimBeginDrag` reads the hover reading, which still holds the touch-down slot
    //   because touch pointermove has not updated the cursor yet -- so it must run before
    //   the two lines below start following the finger.
    has_touch_moved = true;
    nimCancelHold(); // Moved, so this press will never mature into a selection.
    if (slot_touch_down >= 0 && pointers.size === 1) {
      // A finger has no second button to ask the wheel for, so it is the one pointer that
      //   still reaches the wheel by standing still; see `interaction.MenuArming`.
      is_touch_dragging = nimBeginDrag(ARMING_DRAG_TOUCH, now());
    }
  }

  if (is_touch_dragging) {
    // Follow the finger and let the frame loop's own `nimUpdateDrag` do the rest: the
    //   preview, the dwell, and the menu are all already driven from there. Returning
    //   here is what keeps a construction drag from also orbiting the camera under it.
    nimUpdateCursor(cursor_last.x, cursor_last.y);
    is_hover_stale = true;
    return;
  }

  if (pointers.size === 1) {
    // One finger that is not constructing and not holding is orbiting, which the hover
    //   ring should sit out; the two branches above return before reaching here.
    //   A press that came down on an object is not orbiting even now, before its slop is
    //   crossed: it is a construction press waiting to become a drag, and moving the
    //   camera under it would both jerk the view and put out the hover the drag needs.
    if (is_touch_press_constructing) return;
    nimSetCameraDragging(true);
    const dx = current.x - prev.x, dy = current.y - prev.y;
    nimCameraOrbit(
      -dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4,
    );
  } else if (pointers.size === 2) {
    nimSetCameraDragging(true); // Two fingers pan and pinch; neither points at anything.
    const points_flat = [...pointers.values()];
    const separation = pointerDist(points_flat);
    const mid = pointerMid(points_flat);
    // Straight in and out, at the middle of the frame -- **not** aimed at the pinch's own
    // midpoint the way the wheel is aimed at the pointer. The pan below already moves the
    // view by that midpoint's own travel, so aiming the zoom there too translates the view
    // twice for one gesture, and a pinch anywhere but dead centre slides the scene while it
    // scales it. A wheel has no pan beside it, which is why the same rule is right there.
    if (separation_pinch_start) nimCameraDolly(separation_pinch_start / Math.max(1, separation));
    separation_pinch_start = separation;

    if (pan_last) {
      // The two fingers' own midpoint, grabbed and carried exactly as a mouse drag is --
      // the same rule for both, so a fix to one is a fix to both.
      nimCameraPanAt(
        pan_last.x - rect.left, pan_last.y - rect.top,
        mid.x - rect.left, mid.y - rect.top,
        canvas.clientWidth, canvas.clientHeight,
      );
    }
    pan_last = mid;
  }
});

function endMouseDrag(e) {
  if (typeof button_mouse_drag === 'number') {
    // `nimEndDrag` resolves the press itself: a click over an object comes back as a
    //   `clicked_slot` with the eagerly-begun drag already abandoned, an actual drag as
    //   whatever it built. Which of the two it was is `interaction.endDrag`'s answer, so
    //   this build and the desktop cannot come to disagree about where the line is.
    const result = nimEndDrag(now());
    if (result.clicked_slot >= 0) {
      pickOnClick(result.clicked_slot, button_mouse_drag, e.shiftKey);
    } else {
      toast(result.message);
      if (result.created_slot >= 0) adoptConstructionSelection();
      else if (result.is_more) openApplyPickerOnOperands(cursor_last);
    }
  } else if (button_mouse_down !== null && nimIsClick(now())) {
    // A plain click that began no drag to end -- so it landed on empty space, or on the one
    //   thing that *is* empty space: a plane at horizon, which nimBeginDrag refuses so this
    //   press could still have become an orbit or a pan. Clicking it selects it, which is
    //   the only way a pointer can, since it can never be dragged from. **Either button**,
    //   on the same rule as above: a right click on the sky behaving unlike a right click on
    //   anything else would be a rule with a hole in it.
    if (nimIsHoverBackdrop() && nimHoverSlot() >= 0) {
      pickOnClick(nimHoverSlot(), button_mouse_down, e.shiftKey);
    } else if (button_mouse_down === 0 && !e.shiftKey) {
      // Mirrors touch's own "tapping empty space always cancels" rule. A shift+click over
      //   empty space is left a no-op, not a clear -- shift means "preserve what I have" --
      //   and so is a right click, whose job on empty space is to pan.
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

  // Touch: a tap is a same-finger down+up within time/distance bounds, with no second
  // finger ever joining and no long-press already having fired -- resolves into a
  // selection toggle (see `handleTap`).
  // Released, whether or not the hold had matured; the frame that matured it has already
  //   selected the item. The hold itself lives on for one settle, which is what shrinks
  //   the marker back -- `nimIsHoldSpent` retires it in the draw loop.
  nimReleaseHold(now());
  if (is_touch_dragging) {
    // A construction drag ends exactly as the mouse's own does -- same call, same three
    //   outcomes -- because it *is* the same gesture reached by a different pointer.
    //   A drag is never also a tap, so this branch runs instead of `handleTap`.
    //   `pointercancel` is the browser saying it has taken the gesture over, which is not
    //   a release: it cancels rather than building something the reader never let go of.
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
  if (pointers.size < 2) { separation_pinch_start = null; pan_last = null; }
  if (pointers.size === 0) nimSetCameraDragging(false);
  if (pointers.size === 0) nimClearHover(); // No finger left touching the canvas -- there's
    // no cursor position left to be "hovering" anything, so don't let the last touch-down's
    // own hover reading linger and draw its ring forever.
}
canvas.addEventListener('pointerup', releasePointer);
canvas.addEventListener('pointercancel', releasePointer);
canvas.addEventListener('pointerleave', (e) => { if (e.buttons === 0) releasePointer(e); });

canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
  // Toward what the pointer is over, the way a map zooms. Where that is comes from the
  // cursor this build already tracks, so the wheel says it the same way picking does.
  const rect = canvas.getBoundingClientRect();
  nimUpdateCursor(e.clientX - rect.left, e.clientY - rect.top);
  // **Summed here, applied once by the frame loop.** A trackpad reports several notches
  //   between two frames, and each dolly runs `picking.anchorZoomAt` to find what the
  //   cursor is over -- a full pick over every live slot, 11.4 ms on the 1,024-object demo.
  //   Six notches a frame measured 83.8 ms of picking on a frame, for a 136 ms gap, and
  //   every answer but the last was thrown away. The factor is `exp(k*delta)`, so summing
  //   the deltas and exponentiating once is the same zoom, not an approximation of it.
  deltas_wheel += e.deltaY;
}, { passive: false });

/* ---- Touch tap-to-toggle / mouse click-to-select ---- */
/*   Long-pressing (touch) or plain-clicking (mouse) an object selects it; a further    */
/*   tap or shift-click toggles another object into/out of the same selection. The       */
/*   selection menu's own content depends purely on how many objects are selected --     */
/*   see `refreshSelectionMenu` -- 1 or 2 offer apply (revealing a unary/binary catalogue */
/*   dropdown) plus hide/delete; 3+ offer only hide/delete, bulk-acting on every          */
/*   selected slot at once. Tapping/clicking empty space, or the menu's own close        */
/*   button, always clears the whole selection.                                          */

function handleTap(position_local) {
  const rect = canvas.getBoundingClientRect();
  nimUpdateCursor(position_local.x, position_local.y);
  nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
  const hovered = nimHoverSlot();

  // The sky counts as empty space to a *tap*, deliberately, though a mouse click selects
  //   it: tapping empty space is the only way a finger has to dismiss a selection, and
  //   spending it on selecting the backdrop would take that away. Touch reaches the sky
  //   through the long-press instead -- which is where its marker fills anyway.
  if (hovered < 0 || nimIsHoverBackdrop()) {
    clearSelection(); // Tapping empty space always cancels.
    return;
  }
  if (slots_selection.length === 0) return; // Not in select mode yet -- only a long-press
    // starts one; a plain tap before that is a no-op, same as before this feature.
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
  // <option> list -- like the drawer's own populateOperations, only rebuilds when it
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
  // "apply" itself never moves -- it stays the leftmost element of one single row
  //   throughout; this only animates the picker+back group open immediately to its
  //   right (see .selection-menu-reveal's own max-width transition). hide/delete step
  //   aside while picking an operation, matching the old two-row design's own behaviour
  //   (its second row never carried them either) -- ✕ stays, as it always did.
  const arity = nimSelectionArity();
  populateSelectionMenuOptions(arity);
  // Open on whatever was last applied at this arity rather than on the head of the list,
  //   and ghost it straight away: the picker's answer is worth seeing while choosing, not
  //   only once apply is pressed.
  menu_selection_select.value = String(nimOperationRemembered(arity));
  ghostSelectionMenuOperation();
  menu_selection_reveal.classList.add('open');
  menu_selection_edit.style.display = 'none';
  menu_selection_hide.style.display = 'none';
  menu_selection_delete.style.display = 'none';
}

function ghostSelectionMenuOperation() {
  // Both operands come from the selection in pick order, exactly as apply reads them.
  const first = slots_selection[0];
  const second = slots_selection.length > 1 ? slots_selection[1] : slots_selection[0];
  if (first === undefined) return;
  nimGhostOperation(parseInt(menu_selection_select.value, 10), first, second);
}

function closeSelectionMenuOp() {
  // Nothing is being chosen any more, so nothing is being previewed. The drawer's own
  // section may still be open behind this menu, so ask it to speak up again rather than
  // leaving the view blank while a control that has something to say is on screen.
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
  closeSelectionMenuOp(); // Any fresh selection change resets the picker closed.
  if (position_local) positionSelectionMenuAt(position_local); else updateSelectionMenuPosition();
  menu_selection.classList.add('show');
}

// Whether the floating selection menu is currently up. Its own reader because it is now a
//   question the click rule asks (see `pickOnClick`), not just a class this file toggles.
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
  // Reserved right margin covers the widest state this popover reaches: the op-picker
  //   row (select sized to its own longest notation, e.g. "𝐧 ∨ (𝐦 ∧ 𝐧☆)", plus "apply"/
  //   "back") now that the select's own width is content-sized rather than truncated.
  menu_selection.style.left =
    Math.min(rect.left + position_local.x, window.innerWidth - 300) + 'px';
  menu_selection.style.top = Math.max(rect.top + position_local.y - 60, 8) + 'px';
}

function updateSelectionMenuPosition() {
  // Keep the menu glued to the most-recently-selected slot's own screen position every
  //   frame it's open, generalizing the old tap-menu's single-slot follow -- an average
  //   across all selected would jump around as membership changes for no real benefit.
  if (!menu_selection.classList.contains('show') || slots_selection.length === 0) return;
  const slot_anchor = slots_selection[slots_selection.length - 1];
  const anchor = nimAnchorScreen(slot_anchor, canvas.clientWidth, canvas.clientHeight);
  if (anchor[2] <= 0.5) return; // Off-screen -- leave the menu at its last valid spot.
  positionSelectionMenuAt({ x: anchor[0], y: anchor[1] });
}

menu_selection_apply.addEventListener('click', () => {
  // First press: open the picker (animates open to this same button's own right --
  //   the button itself never moves or relabels). Second press, picker already open:
  //   commit with whatever operation is currently selected -- one button serves both
  //   roles instead of a separate "go" button appearing once the picker opens.
  if (!menu_selection_reveal.classList.contains('open')) {
    openSelectionMenuOp();
    return;
  }
  const n = slots_selection.length;
  if (n !== 1 && n !== 2) return; // Guard only -- apply is hidden for 0/3+ anyway.
  if (nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
  const first = slots_selection[0];
  const second = n === 2 ? slots_selection[1] : first; // Unary ignores the second operand.
  const result = nimApplyOperation(parseInt(menu_selection_select.value, 10), first, second, now());
  toast(result.message);
  adoptConstructionSelection();
});
menu_selection_edit.addEventListener('click', () => {
  // Reaching an object's editor otherwise means opening the drawer and hunting its row,
  //   even with that object already picked and its own menu on screen.
  if (slots_selection.length !== 1) return; // Guard only -- hidden for 0 and 2+ anyway.
  openPanelTo(slots_selection[0]);
  hideSelectionMenu(); // The panel owns the interaction now; the pick itself stays.
});

menu_selection_back.addEventListener('click', closeSelectionMenuOp);

menu_selection_hide.addEventListener('click', () => {
  // Whichever way the button reads is what it does, so the objects it hid can be brought
  //   back from the same place -- `nimSelectionAllHidden` owns what "hidden" means for a
  //   whole selection, the way the row button reads `nimItemVisible` for one object.
  const show = nimSelectionAllHidden();
  for (const slot of slots_selection) nimSetVisible(slot, show);
  toast((show ? 'Showed ' : 'Hid ') + slots_selection.length + ' object(s).');
  refreshSelectionMenu(null); // Relabels the button for what it would now do.
  refreshObjectsUI(); // Selection itself is kept -- hiding doesn't invalidate the slot.
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
  // Only a tap/click landing outside the canvas, the menu itself, the drawer
  //   (interacting with the Objects list/panel must not dismiss the selection menu
  //   or clear selection), and the top chip-row (save/load scene lives there too)
  //   should dismiss it here -- dismissing on the canvas's own down event would race
  //   handleTap/endMouseDrag's own resolution of that same gesture.
  if (menu_selection.classList.contains('show') && !menu_selection.contains(e.target) &&
      e.target !== canvas && !drawer.contains(e.target) && !row_chip.contains(e.target)) {
    clearSelection();
  }
  // **The help is not dismissed by a tap outside it**, unlike the two popovers either side
  //   of this. It is opened to be read *while* doing the thing it describes -- that is the
  //   whole reason it is cut by way of working rather than by kind of control -- and the
  //   first touch of that thing used to close it, including a touch on the canvas. It goes
  //   when the reader says so: its own close button, the `?` that opened it, or escape.
  // Top menu: same shape of guard, its own state/target -- a tap landing outside the
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

function resize() {
  const ratio_pixel = Math.min(window.devicePixelRatio || 1, 2.5);
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
/* matrix out of the compiled Nim module and upload them straight to GL.   */
/* ---------------------------------------------------------------------- */

let ms_refresh_ui = 0;

// Draw one frame, and nothing else. Split out of `frame()` so the PNG button can draw and
//   read back **inside its own click**, without also re-running the per-tick simulation that
//   frame() does around it. Mirrors `visualiser.renderFrame`, which is split the same way and
//   for the same reason: the desktop's storyboard capture drives it directly too.
function renderFrame(now_seconds) {
  resize();
  const aspect = canvas.width / canvas.height;

  const data = nimBuildFrame(
    aspect, now_seconds, canvas.height, is_axes_shown, is_grid_shown, is_algebra_shown,
  );
  // The bridge times its own three phases where only it can see them; this side just
  // records what came back, into the same rings its own phases use.
  recordPhaseTime('build', data.ms_build);
  // The frame's prologue and its view matrix, which used to belong to no row, and the
  //   residue the named phases still fail to cover -- so `build` now sums from what is
  //   under it instead of merely being larger than the sum.
  recordPhaseTime('camera', data.ms_camera);
  recordPhaseTime('matrix', data.ms_matrix);
  recordPhaseTime('unaccounted', data.ms_unaccounted);
  // The second cut: the same milliseconds re-divided by which side of the algebra
  //   boundary they fell on. Recorded like any other row and kept out of every sum by
  //   `PHASES_CUT_DIAGNOSTIC`.
  recordPhaseTime('placing', data.ms_placing);
  recordPhaseTime('emitting', data.ms_emitting);
  // Measured between frames and reported by this one; see the bridge's own note.
  recordPhaseTime('hover', data.ms_hover_pick);
  recordPhaseTime('furniture', data.ms_furniture);
  // The scenery's own two halves, which the bridge has clocked apart since the grid's
  //   segment budget went in: the axes are three lines at any distance, the grid however
  //   many the ground reach asks for, and only the split says which of them moved.
  recordPhaseTime('grid', data.ms_grid);
  recordPhaseTime('axes', data.ms_axes);
  recordPhaseTime('scene', data.ms_scene);
  // The debug layer, beside the scene rather than inside it, so the per-kind rows still
  //   account for the scene exactly. Zero whenever the layer is off, which is its resting
  //   state.
  recordPhaseTime('algebra', data.ms_algebra);
  recordPhaseTime('flatten', data.ms_flatten);
  // The scene phase broken out by the kind of object each millisecond went to, with the
  //   counts kept beside them. Counts are latest rather than ringed: a median count would
  //   lag a deletion by two seconds and read as a scene that still holds what it no longer
  //   does, while the *time* wants its median precisely because a single frame flickers.
  recordPhaseTime('points', data.ms_points);
  recordPhaseTime('lines', data.ms_lines);
  recordPhaseTime('planes', data.ms_planes);
  recordPhaseTime('sky', data.ms_sky);
  recordPhaseTime('ghost', data.ms_ghost);
  recordPhaseTime('selected', data.ms_selected);
  for (const name in COUNTS_DIAGNOSTIC) count_phase[name] = data[COUNTS_DIAGNOSTIC[name]];

  const ms_before_draw = performance.now();
  const ratio_pixel = Math.min(window.devicePixelRatio || 1, 2.5);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

  // The ribbon program's camera, once a frame: the widening runs in its vertex shader
  // now, fed by exactly the DrawScale fields mesh.expandRibbon reads.
  gl.useProgram(program_ribbon);
  gl.uniformMatrix4fv(ribbon_uniforms.mvp, false, data.view_projection);
  gl.uniform3f(ribbon_uniforms.eye, data.cam_eye_x, data.cam_eye_y, data.cam_eye_z);
  gl.uniform3f(ribbon_uniforms.forward,
    data.cam_forward_x, data.cam_forward_y, data.cam_forward_z);
  gl.uniform1f(ribbon_uniforms.depth_near, data.cam_depth_near);
  gl.uniform1f(ribbon_uniforms.tangent, data.cam_tangent_half_view);
  gl.uniform1f(ribbon_uniforms.height, data.cam_height_pixels);
  // The furniture fog's two radii, for the fragment stage's fade of fogged records.
  gl.uniform1f(ribbon_uniforms.fog_full, data.fog_radius_full);
  gl.uniform1f(ribbon_uniforms.fog_gone, data.fog_radius_gone);

  // World furniture first, with normal depth test/write. One record a segment now --
  // kept rather than re-uploaded where the bridge says the furniture is unchanged, since
  // the grid and the axes are a function of the camera alone. Mirrors renderer.nim's own
  // drawMeshes(MESHES_FURNITURE, ...) call exactly.
  if (!data.is_furniture_held) {
    count_furniture_held = uploadBuffer(data.furn_ribbon_verts, vbo.ribbon_furniture, 16);
  }
  drawRibbons(vbo.ribbon_furniture, count_furniture_held, 0, false);

  // Scene objects last; opaque kinds before the translucent washes, with depth writes
  // off for those, so a translucent plane never occludes a line or point that happens to
  // sit behind it -- it only tints over whatever was already drawn there. Mirrors
  // renderer.nim's own drawMeshes(MESHES, ...) call exactly.
  // Uploaded only where the bridge rebuilt: a held frame's buffers already hold this
  //   frame's records, and re-uploading identical bytes is the copy the hold exists to
  //   skip. The draws below still run -- the framebuffer is cleared every frame.
  if (!data.is_scene_held) count_ribbon_held = uploadBuffer(data.ribbon_verts, vbo.ribbon, 16);
  const count_ribbon = count_ribbon_held;
  drawRibbons(vbo.ribbon, count_ribbon, data.ribbon_over, false);
  // The plane rims, one record each, straight after the lines they are drawn like -- the
  // widening is the ribbon program's own, so this program takes the same six camera
  // uniforms and the same pass.
  gl.useProgram(program_ring);
  gl.uniformMatrix4fv(ring_uniforms.mvp, false, data.view_projection);
  gl.uniform3f(ring_uniforms.eye, data.cam_eye_x, data.cam_eye_y, data.cam_eye_z);
  gl.uniform3f(ring_uniforms.forward,
    data.cam_forward_x, data.cam_forward_y, data.cam_forward_z);
  gl.uniform1f(ring_uniforms.depth_near, data.cam_depth_near);
  gl.uniform1f(ring_uniforms.tangent, data.cam_tangent_half_view);
  gl.uniform1f(ring_uniforms.height, data.cam_height_pixels);
  if (!data.is_scene_held) count_ring_held = uploadBuffer(data.ring_records, vbo.ring, 14);
  const count_ring = count_ring_held;
  drawRings(count_ring, data.ring_over, false);
  gl.useProgram(program);
  gl.uniformMatrix4fv(uniform_view_projection, false, data.view_projection);
  gl.uniform1f(uniform_size_point, SIZE_POINT * ratio_pixel);
  if (!data.is_scene_held) count_point_held = uploadBuffer(data.point_verts, vbo.point, 7);
  const count_point = count_point_held;
  drawRun(vbo.point, count_point, gl.POINTS, true, data.point_over, false);
  // The washes: one record a disc or dome, fanned out by their own vertex shaders and
  // walked in scene order through the run list. Both programs get this frame's matrix
  // before the walk, which switches between them per run.
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

  // The overlay over all of it, with no depth test at all -- which turns writes off with
  // it, so nothing here occludes anything either. A second pass over every kind rather
  // than a tail on each: a selected line drawn only after the other lines is still tinted
  // by a plane's wash, which is a later kind. Mirrors `renderer.drawMeshes`.
  if (data.ribbon_over + data.ring_over + data.point_over + data.wash_run_over > 0) {
    gl.disable(gl.DEPTH_TEST);
    gl.useProgram(program_ribbon);
    drawRibbons(vbo.ribbon, count_ribbon, data.ribbon_over, true);
    gl.useProgram(program_ring);
    drawRings(count_ring, data.ring_over, true);
    gl.useProgram(program);
    drawRun(vbo.point, count_point, gl.POINTS, true, data.point_over, true);
    drawWashRuns(data.wash_runs, data.wash_run_over, true);
    gl.enable(gl.DEPTH_TEST);
  }
  // Command submission only: GL runs asynchronously, so what a CPU clock can honestly
  // bracket here is the upload and the draw-call issue, not the GPU's own work.
  recordPhaseTime('upload', performance.now() - ms_before_draw);
}

function frame() {
  const now_seconds = now();

  const now_milliseconds = performance.now();
  const seconds_frame = (now_milliseconds - time_frame_last) / 1000;
  recordFrameTime(now_milliseconds - time_frame_last);
  time_frame_last = now_milliseconds;

  // Whatever key is held moves the camera by one frame's worth, before anything is drawn
  // from the placement. Scaled by the frame's own elapsed time, so a hold travels the same
  // distance on a 60 Hz screen and a 144 Hz one -- which way it moves the camera is
  // `interaction.driveHeld`'s to say, never this file's.
  nimDriveHeld(seconds_frame);

  // A press that has now lasted long enough selects its item. Checked here rather than by
  //   a timer that fires on its own, so that the moment the marker finishes filling is the
  //   moment the selection lands -- `interaction.isHoldMature` is stated against the same
  //   progress the marker was just drawn at, so the two cannot disagree by a frame.
  // One question, not two. Asking "is it mature" beside a flag kept here for "have I
  // already acted on that" needs the two to agree, and they stopped agreeing once a hold
  // outlived its own release: this handler clears its flag on the lift while the hold is
  // still settling and still mature, so the next frame selected the item again and toggled
  // it straight back off. `nimTakeMaturedHold` answers once and never again.
  const slot_matured = nimTakeMaturedHold(now_seconds);
  if (slot_matured >= 0) {
    // Selected, but the hold is **kept**: its marker stays swollen clear of the finger for
    // as long as that finger is down, and settles only once `nimReleaseHold` says it may.
    has_long_press_fired = true; // Still needed, to stop the release also reading as a tap.
    toggleSelection(slot_matured, position_touch_down);
  }
  // And retire it once that settle is spent, so a finished hold stops being drawn at all.
  if (nimIsHoldSpent(now_seconds)) nimCancelHold();

  // Recompute what the drag in progress would build, and whether its dwell has come due,
  // before the frame that ghosts the answer is assembled. Runs every frame rather than on
  // pointermove alone: a dwell is time passing over a cursor that is deliberately still,
  // so there is no move event to hang it off. Mirrors `visualiser.renderFrame`'s order.
  // **One dolly and one pick a frame, whatever the pointer reported.** Both used to run
  //   from the event handlers, so a device reporting faster than the display paid for
  //   answers nobody read: `picking.pickNearest` walks every live slot, and on the
  //   1,024-object demo that is 11.4 ms each. Coalesced here instead, after `nimDriveHeld`
  //   so the camera is where this frame will draw it, and before the drag update and the
  //   build so both read the answer this frame's cursor deserves.
  //   The presses do not come through here: `pointerdown`, a touch-down and `handleTap`
  //   each need a hover reading before their own handler returns -- it is what
  //   `nimBeginDrag`, `slot_touch_down` and selection are decided from -- so they pick on
  //   the spot and are the only paths that still do.
  if (deltas_wheel !== 0) {
    nimCameraDollyAt(
      Math.exp(deltas_wheel * 0.0012), canvas.clientWidth, canvas.clientHeight,
    );
    deltas_wheel = 0;
    is_hover_stale = true; // The camera moved under a cursor that did not.
  }
  if (is_hover_stale) {
    is_hover_stale = false;
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
  }

  if (nimDragActive()) nimUpdateDrag(now_seconds);

  renderFrame(now_seconds);

  // Immediately after the last draw call and before this callback yields, which is the only
  //   moment the drawing buffer is still there to read; see `captureFrameIfAsked`.
  captureFrameIfAsked();

  const ms_before_overlay = performance.now();
  refreshOverlay(cursor_last);
  updateSelectionMenuPosition();
  // Menu placement folded in with the markers rather than kept as a row of its own: it is
  //   one early-returning call reading 0.00 in every state but one, and its old bracket
  //   enclosed the overlay's own `recordPhaseTime` -- so that row had been charging its
  //   bookkeeping to itself.
  recordPhaseTime('overlay', performance.now() - ms_before_overlay);

  // UI (camera fields, diagnostics) refresh at a lower cadence than the draw loop --
  // no visual harm in a number lagging a frame, and it keeps DOM writes off the hot path.
  // Paced by the clock rather than by a frame count, so the readings settle over the same
  // 200 ms they are averaged over however fast or slow the machine is drawing: six frames
  // is a twelfth of a second on a desktop and a third of one on a labouring phone, and the
  // digits changed at whichever of those the reader happened to be on.
  // A travelling axis is redrawn at the frame's own rate: the panel refreshes five times a
  //   second, which would show the glide as five steps rather than a movement. Only while
  //   it travels, and only while the curve is actually on screen -- a canvas inside a
  //   closed section reports no width.
  if (is_axis_gliding && exceedance !== null && exceedance.clientWidth > 0) drawExceedance();
  const ms_now_ui = performance.now();
  if (ms_now_ui - ms_refresh_ui >= MILLISECONDS_WINDOW_READING) {
    ms_refresh_ui = ms_now_ui;
    const ms_before_ui = performance.now();
    refreshCameraFields();
    refreshRuler();
    refreshDiagnostics();
    refreshUndoRedoButtons(); // catches every history-touching path this tick's own
      // click handlers above don't reach directly (add, apply, remove, load demo,
      // scene load/clear).
    syncOperandsToSelection(); // catches selection changes from tap-to-select too.
    refreshAddButton(); // catches paths that fill or empty the scene without a click here.
    recordPhaseTime('ui', performance.now() - ms_before_ui);
  }

  requestAnimationFrame(frame);
}

refreshObjectsUI();
refreshUndoRedoButtons();
requestAnimationFrame(frame);
