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
// two line widths are not: `mesh.addSegment` has already built them into the ribbon
// geometry, because WebGL clamps `gl.lineWidth` to one pixel on most implementations.
const [SIZE_POINT] = nimRenderLineWidths();

const vbo = {
  tri: gl.createBuffer(), ribbon: gl.createBuffer(), point: gl.createBuffer(),
  ribbon_furniture: gl.createBuffer(),
};
const STRIDE = 7 * 4;

function drawBuffer(data, mode, are_points_round, handle_buffer) {
  if (data.length === 0) return;
  const entries = data instanceof Float32Array ? data : new Float32Array(data);
  gl.bindBuffer(gl.ARRAY_BUFFER, handle_buffer);
  gl.bufferData(gl.ARRAY_BUFFER, entries, gl.DYNAMIC_DRAW);
  gl.enableVertexAttribArray(attribute_position);
  gl.vertexAttribPointer(attribute_position, 3, gl.FLOAT, false, STRIDE, 0);
  gl.enableVertexAttribArray(attribute_colour);
  gl.vertexAttribPointer(attribute_colour, 4, gl.FLOAT, false, STRIDE, 12);
  gl.uniform1i(uniform_is_round, are_points_round ? 1 : 0);
  gl.drawArrays(mode, 0, entries.length / 7);
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
/* `selectionSlots` below is a render snapshot of that answer, not a copy   */
/* with rules of its own: the frame loop's overlay reads it dozens of       */
/* times a second and must not cross the JS/Nim boundary to do it.          */
/* ---------------------------------------------------------------------- */

let slots_selection = []; // Ordered: first-picked first (-> operand m), second (-> n).

function refreshSelectionSnapshot() {
  slots_selection = nimSelectionSlots();
}

function onSelectionChanged(position_local) {
  // Choosing something is itself one of the things the hint teaches, and a plain click
  //   that selects moves the pointer far too little to trip the movement test that
  //   dismisses it on an orbit.
  dismissHint();
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
  element_toast.textContent = message;
  element_toast.classList.add('show');
  clearTimeout(timer_toast);
  timer_toast = setTimeout(() => element_toast.classList.remove('show'), 3200);
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
  header.addEventListener('click', () => header.parentElement.classList.toggle('open'));
});
document.getElementById('toggle-axes').addEventListener('click', (e) => {
  is_axes_shown = !is_axes_shown; e.target.classList.toggle('on', is_axes_shown);
});
document.getElementById('toggle-grid').addEventListener('click', (e) => {
  is_grid_shown = !is_grid_shown; e.target.classList.toggle('on', is_grid_shown);
});
/* ---------------------------------------------------------------------- */
/* Help: the hint says it once, the ? button says it whenever asked.       */
/* ---------------------------------------------------------------------- */

// The hint stays until the reader does something, rather than for a fixed four seconds.
//   A timer cuts off whoever reads slowly, and a first-time reader is exactly who reads
//   slowly; a reader who has already orbited has told us they do not need it. Dismissed
//   by a gesture that moves the camera or changes the scene -- not by a hover, which is
//   not a decision.
let has_hint_shown = true;
function dismissHint() {
  if (!has_hint_shown) return;
  has_hint_shown = false;
  document.getElementById('hint').classList.add('hidden');
}

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
function buildHelp() {
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
  rows_help.scrollTop = 0; // A tab always opens at its own first row.
}
buildHelp();

function showHelp(is_shown) {
  panel_help.classList.toggle('show', is_shown);
  button_help.setAttribute('aria-expanded', is_shown ? 'true' : 'false');
}
button_help.addEventListener('click', (e) => {
  e.stopPropagation();
  showHelp(!panel_help.classList.contains('show'));
});

/* ---------------------------------------------------------------------- */
/* Undo/redo: scene-content edits only, mirrors panel.layoutWorkbench's    */
/* own undo/redo buttons exactly -- see `history.nim` for what is and is   */
/* not on this timeline. A step carries the view its edit was made from,   */
/* so the camera moves under these too; an orbit alone is not a step.      */
/* ---------------------------------------------------------------------- */

const button_add = document.getElementById('btn-add');
const button_undo = document.getElementById('btn-undo');
const button_redo = document.getElementById('btn-redo');

function openApplyWithOperands() {
  // Where the drag menu's `more…` lands: nimEndDrag has already selected both operands in
  //   the order they were dragged, so this only has to bring the section that reads that
  //   selection into view. Refusing to open it would make `more…` a dead end, which is
  //   exactly what it exists to stop the gesture being.
  refreshSelectionSnapshot();
  hideSelectionMenu();
  document.querySelector('.section[data-section="apply"]').classList.add('open');
  drawer.classList.add('open');
  button_drawer.classList.add('on');
  refreshObjectsUI();
}

function openWorkbenchTo(slot) {
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
  if (row) row.scrollIntoView({ block: 'nearest' }); // A long list can open past it.
}

button_add.addEventListener('click', () => {
  // Compose a new object as a row in the Objects list rather than in a section of its
  //   own: adding and editing stage the same four things through the same interface, so
  //   there is one grid and one ghost instead of two of each.
  openWorkbenchTo(null);
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
    const action = nimKeyAction(e.key, e.shiftKey);
    if (action >= 0) {
      e.preventDefault(); // Arrows would otherwise scroll the page under the canvas.
      dismissHint();
      const slot = nimApplyKeyAction(action);
      if (slot >= 0) {
        // Shift adds rather than replaces, exactly as shift-click does -- the one thing
        //   the shift state means that the shared action table cannot answer alone.
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

document.getElementById('btn-export-png').addEventListener('click', () => {
  canvas.toBlob((blob) => {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'rga_workbench.png';
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    toast('Wrote ' + canvas.width + 'x' + canvas.height + ' frame to `rga_workbench.png`.');
  }, 'image/png');
});

document.getElementById('btn-load-demo').addEventListener('click', () => {
  nimLoadDemo(now());
  toast('Loaded the eleven-step demo construction.');
  adoptConstructionSelection();
});

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
  }
  updateOperandEnablement();
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

picker_operation.addEventListener('change', updateOperandEnablement);
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

function refreshObjectsUI() {
  const slots = nimSceneSlots()
    .slice()
    .sort((a, b) => nimItemBorn(b) - nimItemBorn(a)); // Most recently added first.
  count_objects.textContent = '(' + slots.length + ' of ' + nimSceneCapacity() + ')';
  list_objects.innerHTML = '';
  if (slots.length === 0 && !isComposing()) {
    const p = document.createElement('div');
    p.className = 'help-text';
    p.style.margin = '8px 0 0';
    p.textContent = 'Nothing here yet -- press `add` above, or drag between two objects.';
    list_objects.appendChild(p);
  }
  // A composing session heads the list: it is the newest thing here, and it has no
  //   `born` reading to sort by since nothing backs it in the scene yet.
  if (isComposing()) list_objects.appendChild(buildItemRow(null));
  for (const slot of slots) list_objects.appendChild(buildItemRow(slot));
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
  //   scene, so everything it displays comes from `editSession` and the buttons that act
  //   on a real object (hide, remove) are left out entirely.
  const is_pending = slot === null;
  const is_open = is_pending || isEditing(slot);

  const row = document.createElement('div');
  if (!is_pending) row.dataset.slot = slot; // Lets a caller find one row again by slot.
  row.className = 'item-row'
    + (is_pending ? ' pending-item' : '')
    + (!is_pending && slots_selection.includes(slot) ? ' selected' : '')
    + (!is_pending && !nimItemVisible(slot) ? ' hidden-item' : '');

  const top = document.createElement('div');
  top.className = 'item-top';

  // While a session is open its staged values drive the row, so the swatch, label and
  //   coefficient line preview the edit without the scene having changed.
  const inkOf = () => (is_open ? session_edit.ink : nimItemInk(slot));
  const labelOf = () => (is_open ? session_edit.label : nimItemLabel(slot));

  // Selection checkbox: mirrors/toggles membership in `selectionSlots`, exactly the
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
           : nimItemShapeWord(slot) + ': ' + nimFormatMultivector(slot);
  line_coefficient.textContent = describeStaged();
  row.appendChild(line_coefficient);

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
  const slots = nimSceneSlots();
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

  const blob = new Blob([buffer], { type: 'application/octet-stream' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'scene.rgascene';
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
  toast('Saved ' + items.length + ' object(s) to `scene.rgascene`.');
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
  const version = view.getUint8(offset); offset += 1;
  if (version !== nimSceneVersion()) {
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
  for (const item of parsed) nimSceneAddRaw(item.ink, item.visible, item.label, item.coefficients);
  return 'Loaded ' + count_item + ' object(s) from scene file.';
}

/* ---------------------------------------------------------------------- */
/* Diagnostics: browser-appropriate stand-ins for the desktop build's own */
/* arena/frame-time panel -- see this file's own `.help-text` and         */
/* `browser_bridge.nim`'s doc comment for why the numbers differ in kind. */
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
const strip_pool = document.getElementById('pool-strip');
let is_strip_pool_built = false;

function recordFrameTime(delta_milliseconds) {
  history_frame[index_history_frame] = delta_milliseconds;
  index_history_frame = (index_history_frame + 1) % FRAMES_HISTORY;
}

function refreshDiagnostics() {
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

  const latest = history_frame[(index_history_frame + FRAMES_HISTORY - 1) % FRAMES_HISTORY];
  diagnostic_frame_time.textContent =
    latest.toFixed(2) + ' ms (' + Math.round(1000 / Math.max(latest, 1)) + ' fps)';

  if (performance.memory) {
    diagnostic_heap.textContent =
      (performance.memory.usedJSHeapSize / (1024 * 1024)).toFixed(1) + ' / ' +
      (performance.memory.jsHeapSizeLimit / (1024 * 1024)).toFixed(0) + ' MB';
  }

  const count = nimSceneCount(), capacity = nimSceneCapacity();
  diagnostic_pool.textContent = count + ' / ' + capacity;
  if (!is_strip_pool_built) {
    for (let i = 0; i < capacity; i++) strip_pool.appendChild(document.createElement('span'));
    is_strip_pool_built = true;
  }
  // An occupied cell wears its own object's ink, so the strip reads as the scene rather
  //   than as an anonymous occupancy count. `nimPoolCellColors` decides every cell's
  //   colour, free ones included, so no palette rule lives out here -- it returns one
  //   [r, g, b] triple per slot, in slot order.
  const cells = nimPoolCellColors();
  Array.from(strip_pool.children).forEach((element, i) => {
    element.style.background = rgbToCss(cells.slice(i * 3, i * 3 + 3));
  });
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
const [HEIGHT_MENU_WEDGE, PADDING_MENU_WEDGE, ROUNDING_MENU_WEDGE, RADIUS_MENU_CENTRE,
  ALPHA_MENU_WEDGE, ALPHA_MENU_UNOFFERED] = nimMenuMetrics();
// Floats per wedge in nimDragMenuLayout: x, y, offered, then red, green and blue.
const FLOATS_MENU_WEDGE = 6;

function svgEl(tag, attrs) {
  const element = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const k in attrs) element.setAttribute(k, attrs[k]);
  return element;
}

// Stroke one object's marker into the overlay. Every geometric decision -- which outline,
// how far off the object it sits, where its points land on screen -- was made by
// marker.nim; this only turns the flat array it reports into SVG elements, and scales
// from framebuffer pixels to CSS pixels the way every other overlay here does.
// Rails arrive as consecutive pairs, one per drawn piece, so the pairwise loop below
// covers a line clipped into any number of them without knowing how many to expect.
function appendMarker(slot, alpha, w, h, progress, is_touch) {
  const marker =
    nimSelectionMarker(slot, canvas.width, canvas.height, progress, is_touch === true);
  if (marker.length === 0) return;
  const kind = marker[0], is_closed = marker[1] > 0.5;
  const radius = marker[2], fraction = marker[3];
  const stroke = 'rgba(255,255,255,' + alpha + ')';
  const points = [];
  for (let i = 4; i + 1 < marker.length; i += 2) {
    points.push([marker[i] * (w / canvas.width), marker[i + 1] * (h / canvas.height)]);
  }

  if (kind === MARKER_RING) {
    // A whole ring stays a <circle>, the element it has always been, so a marker that is
    // not filling draws exactly as it did before holds were animated. Only a partial one
    // becomes an arc path.
    if (fraction >= 1) {
      svg_overlay.appendChild(svgEl('circle', {
        cx: points[0][0], cy: points[0][1], r: radius,
        fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      }));
    } else if (fraction > 0) {
      // Clockwise from twelve o'clock, measuring the angle from the top so the sweep
      // reads the way every other progress dial does. With y downward, SVG's positive
      // sweep direction (flag 1) is that same clockwise sense.
      const [cx, cy] = points[0];
      const turn = fraction * 2 * Math.PI;
      const ex = cx + radius * Math.sin(turn), ey = cy - radius * Math.cos(turn);
      svg_overlay.appendChild(svgEl('path', {
        d: 'M ' + cx + ',' + (cy - radius) +
           ' A ' + radius + ',' + radius + ' 0 ' + (fraction > 0.5 ? 1 : 0) + ',1 ' +
           ex + ',' + ey,
        fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      }));
    }
  } else if (kind === MARKER_RAILS) {
    for (let i = 0; i < points.length; i += 2) {
      svg_overlay.appendChild(svgEl('line', {
        x1: points[i][0], y1: points[i][1], x2: points[i + 1][0], y2: points[i + 1][1],
        stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      }));
    }
  } else if (kind === MARKER_LOOP || kind === MARKER_FRAME) {
    // A frame is four corners and always closed, so it strokes through the very same
    // element a plane's loop does rather than through a <rect> of its own -- one path
    // for every closed outline, and nothing to keep in step when one of them changes.
    svg_overlay.appendChild(svgEl(is_closed ? 'polygon' : 'polyline', {
      points: points.map((p) => p[0] + ',' + p[1]).join(' '),
      fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
    }));
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
      svg_overlay.appendChild(svgEl(band.closed ? 'polygon' : 'polyline', {
        points: band.run.map((p) => p[0] + ',' + p[1]).join(' '),
        fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      }));
    }
  }
}

function refreshOverlay(cursor) {
  svg_overlay.innerHTML = '';
  const w = canvas.clientWidth, h = canvas.clientHeight;

  // One marker per selected object, shaped to that object by marker.nim -- a ring about
  // a point, rails flanking a line, a loop lying on a plane. Hover draws the very same
  // marker at lower opacity, so both read as one family and hovering a line previews
  // exactly what selecting it will draw.
  for (const slot of slots_selection) appendMarker(slot, ALPHA_MARKER_SELECTED, w, h, 1);

  // A press maturing into a selection fills that item's own marker as it goes, so the
  // wait reads as filling rather than as nothing happening. Drawn at the selected weight
  // it is about to become, and skipped for an item already selected, whose finished
  // marker is on screen already.
  // Filled markers swell clear of the finger doing the filling. `nimBeginHold` is called
  // from the touch branch of `pointerdown` and from nowhere else, so a hold in progress on
  // this build is a finger's by construction -- the flag is passed rather than inferred
  // inside marker.nim, which cannot see what kind of pointer is on the glass.
  const slot_hold = nimHoldSlot();
  if (slot_hold >= 0 && !slots_selection.includes(slot_hold)) {
    appendMarker(slot_hold, ALPHA_MARKER_SELECTED, w, h, nimHoldProgress(now()), true);
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
    const src = nimAnchorScreen(nimDragSourceSlot(), canvas.width, canvas.height);
    if (src[2] > 0.5 && cursor) {
      const sx = src[0] * (w / canvas.width), sy = src[1] * (h / canvas.height);
      // Tinted by what releasing would do, not by which button started the drag: the
      // operation's own colour over a pair that makes something, the reserved magenta
      // over one that makes nothing, neutral while crossing empty space.
      const tint = nimDragTint();
      svg_overlay.appendChild(svgEl('line', {
        x1: sx, y1: sy, x2: cursor.x, y2: cursor.y,
        stroke: 'rgba(' + Math.round(tint[0] * 255) + ',' +
          Math.round(tint[1] * 255) + ',' + Math.round(tint[2] * 255) + ',0.85)',
        'stroke-width': WIDTH_OVERLAY_LINE,
      }));
    }
    appendChoiceMenu(w, h);
  }
}

// Draw the four wedges of an open choice menu. Every position, colour, label and whether
// a wedge is offered comes from interaction.nim through nimDragMenuLayout/Labels, and
// which one the cursor stands in from nimDragMenuHighlighted -- the same call the release
// resolves through, so the highlight is never a second opinion about where the cursor is.
function appendChoiceMenu(w, h) {
  const layout = nimDragMenuLayout();
  if (layout.length === 0) return;
  const labels = nimDragMenuLabels();
  const highlighted = nimDragMenuHighlighted();
  const centre = nimDragMenuCentre();
  for (let i = 0; i * FLOATS_MENU_WEDGE < layout.length; i += 1) {
    const at = i * FLOATS_MENU_WEDGE;
    const x = layout[at] * (w / canvas.width), y = layout[at + 1] * (h / canvas.height);
    const is_offered = layout[at + 2] > 0.5;
    const fill = 'rgb(' + Math.round(layout[at + 3] * 255) + ',' +
      Math.round(layout[at + 4] * 255) + ',' + Math.round(layout[at + 5] * 255) + ')';
    // Label first, then a rect sized from what the browser actually laid it out as --
    // measured rather than estimated from a character count, which drifts the moment the
    // face loaded is not the one the estimate was tuned against.
    const text = svgEl('text', {
      x: x, y: y, 'text-anchor': 'middle', 'dominant-baseline': 'central',
      // An offered wedge is a solid fill and reads best with dark text on it; an
      // unoffered one is barely a fill at all, so dark text there disappears into the
      // scene behind. Light text instead, dimmed -- legible, and still not a choice.
      fill: is_offered ? 'rgb(13,17,23)' : 'rgba(255,255,255,0.55)',
      class: 'menu-wedge-label',
    });
    text.textContent = labels[i];
    svg_overlay.appendChild(text);
    const width = text.getBBox().width + PADDING_MENU_WEDGE;
    svg_overlay.insertBefore(svgEl('rect', {
      x: x - width / 2, y: y - HEIGHT_MENU_WEDGE / 2,
      width: width, height: HEIGHT_MENU_WEDGE, rx: ROUNDING_MENU_WEDGE,
      fill: fill, 'fill-opacity': is_offered ? ALPHA_MENU_WEDGE : ALPHA_MENU_UNOFFERED,
      // The wedge under the cursor wears an outline as well as its fill, so the
      // highlight survives a reader who cannot tell its fill from its neighbour's.
      stroke: i === highlighted ? 'rgba(255,255,255,0.9)' : 'none',
      'stroke-width': WIDTH_OVERLAY_LINE,
    }), text);
  }
  // The middle is where nothing is chosen, and the way out of a menu that opened unasked.
  svg_overlay.appendChild(svgEl('circle', {
    cx: centre[0] * (w / canvas.width), cy: centre[1] * (h / canvas.height),
    r: RADIUS_MENU_CENTRE,
    fill: 'none', stroke: 'rgba(255,255,255,0.7)', 'stroke-width': WIDTH_OVERLAY_LINE,
  }));
}

/* ---------------------------------------------------------------------- */
/* Pointer input.                                                          */
/*   Mouse/pen: left-drag-from-object joins, right-drag-from-object meets, */
/*   One invariant across every pointer: THE PRESS TARGET CHOOSES THE      */
/*   SCHEME. A press that lands on an object constructs; one that lands on */
/*   empty space moves the camera. Mirrors `visualiser.handleEvent`.       */
/*   Mouse: left-drag takes whatever the two objects make, right-drag opens */
/*   the choice menu on arrival, and holding still over the target opens   */
/*   the same menu without the second button. From empty space, left       */
/*   orbits, right pans, the wheel dollies.                                */
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

// Touch long-press-to-select / tap-to-toggle / drag-to-construct state.
let touch_down_at = null, position_touch_down = null, has_touch_moved = false;
let has_long_press_fired = false;
// The item the finger came down on, and whether that press has become a construction drag.
//   `slot_touch_down` is read once at pointerdown, while hover still holds it -- picking
//   again later would report whatever the finger has since moved over.
let slot_touch_down = -1, is_touch_dragging = false;
// How far a press may move and still be a press comes from `interaction.PIXELS_TAP_SLOP`:
//   it decides which scheme the gesture enters, which is a rule about the gesture, not a
//   presentation number. The tap *timeout* stays here -- that one really is local.
const TAP_MAX_MS = 350, TAP_MAX_MOVE = nimTapSlop();

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
  const rect = canvas.getBoundingClientRect();
  const local = { x: e.clientX - rect.left, y: e.clientY - rect.top };
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

  if (e.pointerType === 'mouse') {
    const ratio_pixel = canvas.width / rect.width;
    nimUpdateCursor(local.x * ratio_pixel, local.y * ratio_pixel);
    nimUpdateHover(canvas.width, canvas.height);
    // Note the press before anything is decided about it: whether it was a click is only
    //   knowable at the release, and both branches below can end in one.
    nimBeginPress(now());
    button_mouse_down = e.button;
    // The button says whether the drag decides for you or asks; what it builds is read
    // off the operands at release. Mirrors `visualiser.isMenuForcedFor`.
    const kind_drag = nimDragKindForButton(e.button);
    if (kind_drag >= 0 && nimBeginDrag(kind_drag === 1, now())) {
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
    const ratio_pixel_touch = canvas.width / rect.width;
    nimUpdateCursor(local.x * ratio_pixel_touch, local.y * ratio_pixel_touch);
    nimUpdateHover(canvas.width, canvas.height);
    // Noted like any other press, so that a finger's own construction drag is measured
    //   against where the finger landed rather than against the last mouse press.
    nimBeginPress(now());
    slot_touch_down = nimHoverSlot();
    if (slot_touch_down >= 0) nimBeginHold(slot_touch_down, now());
  } else {
    touch_down_at = null; // A second finger landed; this is a pinch/pan gesture, not a tap.
    nimCancelHold();
    // ...and not a construction either. A drag the reader has visibly abandoned must not
    //   commit on whichever finger happens to lift first.
    if (is_touch_dragging) { nimCancelDrag(); is_touch_dragging = false; }
    slot_touch_down = -1;
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
    const ratio_pixel = canvas.width / rect.width;
    nimUpdateCursor(cursor_last.x * ratio_pixel, cursor_last.y * ratio_pixel);
    // `nimUpdateCursor` above is what notices a press leaving its own landing spot, so
    //   the hint only has to react to that having happened.
    if (button_mouse_down !== null && !nimIsClick(now())) dismissHint();
    if (button_mouse_drag !== null && typeof button_mouse_drag === 'number') {
      // Re-check hover for the drag's own destination preview.
      nimUpdateHover(canvas.width, canvas.height);
      return;
    }
    if (!pointers.has(e.pointerId)) return;
    const prev = pointers.get(e.pointerId);
    const current = { x: e.clientX, y: e.clientY };
    pointers.set(e.pointerId, current);
    const dx = current.x - prev.x, dy = current.y - prev.y;
    if (button_mouse_drag === 'orbit') {
      nimCameraOrbit(
        -dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4,
      );
    } else if (button_mouse_drag === 'pan') {
      nimCameraPan(-dx / canvas.clientWidth * 1.4, dy / canvas.clientHeight * 1.4);
    }
    nimUpdateHover(canvas.width, canvas.height);
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
    dismissHint();
    nimCancelHold(); // Moved, so this press will never mature into a selection.
    if (slot_touch_down >= 0 && pointers.size === 1) {
      is_touch_dragging = nimBeginDrag(false, now());
    }
  }

  if (is_touch_dragging) {
    // Follow the finger and let the frame loop's own `nimUpdateDrag` do the rest: the
    //   preview, the dwell, and the menu are all already driven from there. Returning
    //   here is what keeps a construction drag from also orbiting the camera under it.
    const ratio_pixel_drag = canvas.width / rect.width;
    nimUpdateCursor(cursor_last.x * ratio_pixel_drag, cursor_last.y * ratio_pixel_drag);
    nimUpdateHover(canvas.width, canvas.height);
    return;
  }

  if (pointers.size === 1) {
    const dx = current.x - prev.x, dy = current.y - prev.y;
    nimCameraOrbit(
      -dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4,
    );
  } else if (pointers.size === 2) {
    const points_flat = [...pointers.values()];
    const separation = pointerDist(points_flat);
    if (separation_pinch_start) nimCameraDolly(separation_pinch_start / Math.max(1, separation));
    separation_pinch_start = separation;

    const mid = pointerMid(points_flat);
    if (pan_last) {
      const dx = (mid.x - pan_last.x) / canvas.clientWidth;
      const dy = (mid.y - pan_last.y) / canvas.clientHeight;
      nimCameraPan(-dx * 1.4, dy * 1.4);
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
      if (e.shiftKey) toggleSelection(result.clicked_slot, cursor_last);
      else selectOnly(result.clicked_slot, cursor_last);
    } else {
      toast(result.message);
      if (result.created_slot >= 0) adoptConstructionSelection();
      else if (result.is_more) openApplyWithOperands();
    }
  } else if (button_mouse_down === 0 && nimIsClick(now())) {
    // A plain left click that began no drag to end -- so it landed on empty space, or on
    //   the one thing that *is* empty space: a plane at horizon, which nimBeginDrag
    //   refuses so this press could still have become an orbit. Clicking it selects it,
    //   which is the only way a pointer can, since it can never be dragged from.
    if (nimIsHoverBackdrop() && nimHoverSlot() >= 0) {
      if (e.shiftKey) toggleSelection(nimHoverSlot(), cursor_last);
      else selectOnly(nimHoverSlot(), cursor_last);
    } else if (!e.shiftKey) {
      // Mirrors touch's own "tapping empty space always cancels" rule. A shift+click over
      //   empty space is left a no-op, not a clear -- shift means "preserve what I have".
      clearSelection();
    }
  }

  button_mouse_drag = null;
  button_mouse_down = null;
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
  nimCancelHold(); // Released, whether or not the hold had matured; the frame that matured
    //   it has already selected the item.
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
      else if (result.is_more) openApplyWithOperands();
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
  if (pointers.size === 0) nimClearHover(); // No finger left touching the canvas -- there's
    // no cursor position left to be "hovering" anything, so don't let the last touch-down's
    // own hover reading linger and draw its ring forever.
}
canvas.addEventListener('pointerup', releasePointer);
canvas.addEventListener('pointercancel', releasePointer);
canvas.addEventListener('pointerleave', (e) => { if (e.buttons === 0) releasePointer(e); });

canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
  dismissHint();
  nimCameraDolly(Math.exp(e.deltaY * 0.0012));
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
  const ratio_pixel = canvas.width / rect.width;
  nimUpdateCursor(position_local.x * ratio_pixel, position_local.y * ratio_pixel);
  nimUpdateHover(canvas.width, canvas.height);
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
  populateSelectionMenuOptions(nimSelectionArity());
  menu_selection_reveal.classList.add('open');
  menu_selection_edit.style.display = 'none';
  menu_selection_hide.style.display = 'none';
  menu_selection_delete.style.display = 'none';
}

function closeSelectionMenuOp() {
  menu_selection_reveal.classList.remove('open');
  menu_selection_edit.style.display = slots_selection.length === 1 ? '' : 'none';
  menu_selection_hide.style.display = '';
  menu_selection_delete.style.display = '';
}

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
  const anchor = nimAnchorScreen(slot_anchor, canvas.width, canvas.height);
  if (anchor[2] <= 0.5) return; // Off-screen -- leave the menu at its last valid spot.
  const w = canvas.clientWidth, h = canvas.clientHeight;
  positionSelectionMenuAt({
    x: anchor[0] * (w / canvas.width),
    y: anchor[1] * (h / canvas.height),
  });
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
  openWorkbenchTo(slots_selection[0]);
  hideSelectionMenu(); // The workbench owns the interaction now; the pick itself stays.
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
  //   (interacting with the Objects list/workbench must not dismiss the selection menu
  //   or clear selection), and the top chip-row (save/load scene lives there too)
  //   should dismiss it here -- dismissing on the canvas's own down event would race
  //   handleTap/endMouseDrag's own resolution of that same gesture.
  if (menu_selection.classList.contains('show') && !menu_selection.contains(e.target) &&
      e.target !== canvas && !drawer.contains(e.target) && !row_chip.contains(e.target)) {
    clearSelection();
  }
  // Help panel: same shape of guard, its own state/target. Closed by a tap anywhere
  //   outside it and outside its own button, including on the canvas -- unlike the
  //   selection menu, nothing about it is mid-gesture, so there is no resolution to race.
  if (panel_help.classList.contains('show') && !panel_help.contains(e.target) &&
      e.target !== button_help && !button_help.contains(e.target)) {
    showHelp(false);
  }
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

let count_refresh_ui = 0;

function frame() {
  resize();
  const now_seconds = now();
  const aspect = canvas.width / canvas.height;

  const now_milliseconds = performance.now();
  recordFrameTime(now_milliseconds - time_frame_last);
  time_frame_last = now_milliseconds;

  // A press that has now lasted long enough selects its item. Checked here rather than by
  //   a timer that fires on its own, so that the moment the marker finishes filling is the
  //   moment the selection lands -- `interaction.isHoldMature` is stated against the same
  //   progress the marker was just drawn at, so the two cannot disagree by a frame.
  if (nimHoldMature(now_seconds)) {
    const slot_matured = nimHoldSlot();
    nimCancelHold();
    has_long_press_fired = true;
    toggleSelection(slot_matured, position_touch_down);
  }

  // Recompute what the drag in progress would build, and whether its dwell has come due,
  // before the frame that ghosts the answer is assembled. Runs every frame rather than on
  // pointermove alone: a dwell is time passing over a cursor that is deliberately still,
  // so there is no move event to hang it off. Mirrors `visualiser.renderFrame`'s order.
  if (nimDragActive()) nimUpdateDrag(now_seconds);

  const data = nimBuildFrame(
    aspect, now_seconds, canvas.height, is_axes_shown, is_grid_shown,
  );

  const ratio_pixel = Math.min(window.devicePixelRatio || 1, 2.5);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.uniformMatrix4fv(uniform_view_projection, false, new Float32Array(data.view_projection));

  // World furniture first, with normal depth test/write. Its ribbons already carry their
  // own thinner width as geometry -- there is no width to set here any more. Mirrors
  // renderer.nim's own drawMeshes(MESHES_FURNITURE, ...) call exactly.
  drawBuffer(data.furn_ribbon_verts, gl.TRIANGLES, false, vbo.ribbon_furniture);

  // Scene objects last; opaque kinds before plane washes (triangles), with depth writes
  // off for those, so a translucent plane never occludes a line or point that happens to
  // sit behind it -- it only tints over whatever was already drawn there. Mirrors
  // renderer.nim's own drawMeshes(MESHES, ...) call exactly.
  gl.uniform1f(uniform_size_point, SIZE_POINT * ratio_pixel);
  drawBuffer(data.ribbon_verts, gl.TRIANGLES, false, vbo.ribbon);
  drawBuffer(data.point_verts, gl.POINTS, true, vbo.point);
  gl.depthMask(false);
  drawBuffer(data.tri_verts, gl.TRIANGLES, false, vbo.tri);
  gl.depthMask(true);

  refreshOverlay(cursor_last);
  updateSelectionMenuPosition();

  // UI (camera fields, diagnostics) refresh at a lower cadence than the draw loop --
  // no visual harm in a number lagging one frame, and it keeps DOM writes off the hot path.
  count_refresh_ui += 1;
  if (count_refresh_ui >= 6) {
    count_refresh_ui = 0;
    refreshCameraFields();
    refreshDiagnostics();
    refreshUndoRedoButtons(); // catches every history-touching path this tick's own
      // click handlers above don't reach directly (add, apply, remove, load demo,
      // scene load/clear).
    syncOperandsToSelection(); // catches selection changes from tap-to-select too.
    refreshAddButton(); // catches paths that fill or empty the scene without a click here.
  }

  requestAnimationFrame(frame);
}

refreshObjectsUI();
refreshUndoRedoButtons();
requestAnimationFrame(frame);
