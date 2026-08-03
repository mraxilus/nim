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

const VERT_SRC = `
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
const FRAG_SRC = `
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
gl.attachShader(program, compileShader(gl.VERTEX_SHADER, VERT_SRC));
gl.attachShader(program, compileShader(gl.FRAGMENT_SHADER, FRAG_SRC));
gl.linkProgram(program);
if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
gl.useProgram(program);

const aPosition = gl.getAttribLocation(program, 'aPosition');
const aColor = gl.getAttribLocation(program, 'aColor');
const uMVP = gl.getUniformLocation(program, 'uMVP');
const uPointSize = gl.getUniformLocation(program, 'uPointSize');
const uRound = gl.getUniformLocation(program, 'uRound');

// Read from renderer.nim's own constants via nimRenderLineWidths, rather than a hand-
// copied literal that could drift out of sync with them.
const [SIZE_POINT, WIDTH_LINE_FURNITURE, WIDTH_LINE_OBJECT] = nimRenderLineWidths();

const vbo = {
  tri: gl.createBuffer(), line: gl.createBuffer(), point: gl.createBuffer(),
  furnLine: gl.createBuffer(),
};
const STRIDE = 7 * 4;

function drawBuffer(data, mode, roundPoints, vboHandle) {
  if (data.length === 0) return;
  const arr = data instanceof Float32Array ? data : new Float32Array(data);
  gl.bindBuffer(gl.ARRAY_BUFFER, vboHandle);
  gl.bufferData(gl.ARRAY_BUFFER, arr, gl.DYNAMIC_DRAW);
  gl.enableVertexAttribArray(aPosition);
  gl.vertexAttribPointer(aPosition, 3, gl.FLOAT, false, STRIDE, 0);
  gl.enableVertexAttribArray(aColor);
  gl.vertexAttribPointer(aColor, 4, gl.FLOAT, false, STRIDE, 12);
  gl.uniform1i(uRound, roundPoints ? 1 : 0);
  gl.drawArrays(mode, 0, arr.length / 7);
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
let showAxes = true, showGrid = true;

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

let selectionSlots = []; // Ordered: first-picked first (-> operand m), second (-> n).

function refreshSelectionSnapshot() {
  selectionSlots = nimSelectionSlots();
}

function onSelectionChanged(localPos) {
  refreshSelectionSnapshot();
  refreshSelectionMenu(localPos);
  refreshObjectsUI(); // Also re-syncs the apply controls and the row checkboxes.
}

function selectOnly(slot, localPos) {
  nimSelectOnly(slot);
  onSelectionChanged(localPos);
}

function toggleSelection(slot, localPos) {
  nimSelectToggle(slot);
  onSelectionChanged(localPos);
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

const toastEl = document.getElementById('toast');
let toastTimer = null;
function toast(message) {
  toastEl.textContent = message;
  toastEl.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove('show'), 3200);
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
const chipRow = document.querySelector('.chip-row');
const drawerBtn = document.getElementById('btn-drawer');
drawerBtn.addEventListener('click', () => {
  const open = drawer.classList.toggle('open');
  drawerBtn.classList.toggle('on', open);
});

// Top menu: one popover holding every top-bar action (undo/redo, axes/grid, save/load
//   scene, save PNG/load demo) that used to be spread across four separate chip-row
//   pill-groups -- each button inside keeps its own pre-existing #id-based wiring
//   unchanged below; this only owns the popover's own open/close.
const topMenu = document.getElementById('top-menu');
const menuBtn = document.getElementById('btn-menu');
menuBtn.addEventListener('click', () => {
  const open = topMenu.classList.toggle('show');
  menuBtn.classList.toggle('on', open);
});

document.querySelectorAll('.section-header').forEach((header) => {
  header.addEventListener('click', () => header.parentElement.classList.toggle('open'));
});
document.getElementById('toggle-axes').addEventListener('click', (e) => {
  showAxes = !showAxes; e.target.classList.toggle('on', showAxes);
});
document.getElementById('toggle-grid').addEventListener('click', (e) => {
  showGrid = !showGrid; e.target.classList.toggle('on', showGrid);
});
// Four seconds to read it, then a 0.6s fade. One clock: the stylesheet used to carry a
//   transition-delay too, which ran from the moment this class was added rather than from
//   load, so the two stacked and the hint outstayed both numbers.
setTimeout(() => document.getElementById('hint').classList.add('hidden'), 4000);

/* ---------------------------------------------------------------------- */
/* Undo/redo: scene-content edits only, mirrors panel.layoutWorkbench's    */
/* own undo/redo buttons exactly -- see `history.nim` for what is and is   */
/* not on this timeline.                                                   */
/* ---------------------------------------------------------------------- */

const btnAdd = document.getElementById('btn-add');
const btnUndo = document.getElementById('btn-undo');
const btnRedo = document.getElementById('btn-redo');

function openWorkbenchTo(slot) {
  // Open an edit session on `slot` (or a composing one where null) and bring the drawer
  //   and the Objects section far enough open to see it -- shared by the top bar's `add`
  //   and the selection menu's `edit`, which differ only in what they open onto.
  beginEditSession(slot);
  document.querySelector('.section[data-section="objects"]').classList.add('open');
  drawer.classList.add('open');
  drawerBtn.classList.add('on');
  refreshObjectsUI();
  const row = objectsList.querySelector(
    slot === null ? '.item-row.pending-item' : '.item-row[data-slot="' + slot + '"]');
  if (row) row.scrollIntoView({ block: 'nearest' }); // A long list can open past it.
}

btnAdd.addEventListener('click', () => {
  // Compose a new object as a row in the Objects list rather than in a section of its
  //   own: adding and editing stage the same four things through the same interface, so
  //   there is one grid and one ghost instead of two of each.
  openWorkbenchTo(null);
});

btnUndo.addEventListener('click', () => {
  // A restored snapshot's slot numbers need not match, so an open session has nothing
  //   trustworthy left to commit against.
  if (nimUndo()) { endEditSession(); adoptConstructionSelection(); refreshObjectsUI(); }
  else toast('Nothing to undo.');
  refreshUndoRedoButtons();
});
btnRedo.addEventListener('click', () => {
  if (nimRedo()) { endEditSession(); adoptConstructionSelection(); refreshObjectsUI(); }
  else toast('Nothing to redo.');
  refreshUndoRedoButtons();
});

function refreshUndoRedoButtons() {
  // Dimmed/disabled (via the shared .btn:disabled rule) whenever there's nothing on
  //   that side of the timeline to move to -- checked after every history-touching
  //   action below, plus once per low-cadence UI tick to catch every other path
  //   (add, apply, remove, load demo, scene load/clear) without hooking each one.
  btnUndo.disabled = !nimCanUndo();
  btnRedo.disabled = !nimCanRedo();
}

/* ---------------------------------------------------------------------- */
/* View panel: camera numeric fields, mirroring panel.layoutView exactly. */
/* ---------------------------------------------------------------------- */

const camFields = {
  azimuth: document.getElementById('cam-azimuth'),
  elevation: document.getElementById('cam-elevation'),
  distance: document.getElementById('cam-distance'),
  fov: document.getElementById('cam-fov'),
  tx: document.getElementById('cam-target-x'),
  ty: document.getElementById('cam-target-y'),
  tz: document.getElementById('cam-target-z'),
};
let camFieldsFocused = false;
Object.values(camFields).forEach((el) => {
  el.addEventListener('focus', () => { camFieldsFocused = true; });
  el.addEventListener('blur', () => { camFieldsFocused = false; });
});
camFields.azimuth.addEventListener('change', () => nimSetCameraAzimuth(parseFloat(camFields.azimuth.value) || 0));
camFields.elevation.addEventListener('change', () => nimSetCameraElevation(parseFloat(camFields.elevation.value) || 0));
camFields.distance.addEventListener('change', () => nimSetCameraDistance(parseFloat(camFields.distance.value) || 0.1));
camFields.fov.addEventListener('change', () => nimSetCameraFov(parseFloat(camFields.fov.value) || 45));
function commitTarget() {
  nimSetCameraTarget(
    parseFloat(camFields.tx.value) || 0, parseFloat(camFields.ty.value) || 0, parseFloat(camFields.tz.value) || 0,
  );
}
camFields.tx.addEventListener('change', commitTarget);
camFields.ty.addEventListener('change', commitTarget);
camFields.tz.addEventListener('change', commitTarget);

function refreshCameraFields() {
  if (camFieldsFocused) return; // Don't fight a value the user is mid-typing.
  // `nimFormatNumber`, not a `toFixed` here: an angle of 1.05 should read `1.05` rather
  //   than `1.050`, and the desktop draws every one of these with the same widget.
  camFields.azimuth.value = nimFormatNumber(nimCameraAzimuth());
  camFields.elevation.value = nimFormatNumber(nimCameraElevation());
  camFields.distance.value = nimFormatNumber(nimCameraDistance());
  camFields.fov.value = nimFormatNumber(nimCameraFov());
  const t = nimCameraTarget();
  camFields.tx.value = nimFormatNumber(t[0]);
  camFields.ty.value = nimFormatNumber(t[1]);
  camFields.tz.value = nimFormatNumber(t[2]);
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

const opArity = document.getElementById('op-arity');
const opSelect = document.getElementById('op-select');
const opFirst = document.getElementById('op-first');
const opSecond = document.getElementById('op-second');
const opSecondField = document.getElementById('op-second-field');

let currentArity = 0; // 0 = unary, 1 = binary -- matches nimOperationArity's own convention.

function populateOperations() {
  const prevValue = opSelect.value;
  opSelect.innerHTML = '';
  const count = nimOperationCount();
  for (let i = 0; i < count; i++) {
    if (nimOperationArity(i) !== currentArity) continue;
    const opt = document.createElement('option');
    opt.value = i;
    opt.textContent = nimOperationNotation(i);
    opSelect.appendChild(opt);
  }
  // Switching arity can leave the previous selection's own index absent from the new,
  //   filtered option list -- fall back to the new list's first option rather than
  //   leaving opSelect.value pointing at a now-nonexistent <option>.
  if (opSelect.querySelector('option[value="' + prevValue + '"]')) opSelect.value = prevValue;
  updateOperandEnablement();
}

opArity.querySelectorAll('button[data-arity]').forEach((btn) => {
  btn.addEventListener('click', () => {
    currentArity = parseInt(btn.dataset.arity, 10);
    opArity.querySelectorAll('button[data-arity]').forEach((b) => b.classList.toggle('on', b === btn));
    populateOperations();
  });
});

opSelect.addEventListener('change', updateOperandEnablement);
function updateOperandEnablement() {
  const arity = nimOperationArity(parseInt(opSelect.value, 10) || 0);
  opSecondField.style.display = arity === 0 ? 'none' : '';
}

populateOperations();

// Coefficient grid, shared by the add-multivector section and each row's own edit box:
//   stacked one row per grade (0 to n), rather than wrapping basis order at a fixed
//   column count regardless of grade boundaries -- grade comes from `nimBasisGrade`
//   (backed by `pga/algebra.grade`, the library's own basis-to-grade lookup), needing
//   no hardcoded basis list or JS-side reimplementation to stay correct if this build's
//   own dimension ever changes.
function buildGradedCoeffGrid(container, valueAt) {
  const basisCount = nimBasisCount();
  const inputs = new Array(basisCount);
  const byGrade = [];
  for (let b = 0; b < basisCount; b++) {
    const grade = nimBasisGrade(b);
    (byGrade[grade] || (byGrade[grade] = [])).push(b);
  }
  for (const group of byGrade) {
    if (!group) continue;
    const row = document.createElement('div');
    row.className = 'coeff-grade-row';
    for (const b of group) {
      const f = document.createElement('div');
      f.className = 'field';
      const lbl = document.createElement('label');
      lbl.textContent = nimBasisName(b);
      const input = document.createElement('input');
      input.type = 'number';
      input.step = '0.1';
      input.value = valueAt(b);
      f.appendChild(lbl);
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
  const first = slots[Math.min(parseInt(opFirst.value, 10) || 0, slots.length - 1)];
  const second = slots[Math.min(parseInt(opSecond.value, 10) || 0, slots.length - 1)];
  if (nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
  const result = nimApplyOperation(parseInt(opSelect.value, 10), first, second, now());
  toast(result.message);
  adoptConstructionSelection();
});

let lastSyncedSelectionKey = ''; // Mirrors panel.nim's index_operand_synced_highlight,
  // generalized to a pair: re-defaults operand m/n to the current selection only the
  // moment the selection itself changes (not on every refreshOperandOptions call, which
  // happens far more often than selection changes), so a manual pick of a different
  // operand sticks until selection moves again.
let lastOperandOptionsKey = ''; // Slot list + labels last used to rebuild operand m/n's
  // own <option> elements -- rebuilding a <select>'s options while its native picker
  // is open (mobile especially) makes the browser re-show/reset that picker, so the
  // full rebuild below only actually runs when scene composition or a label changed,
  // never on every periodic tick.

function refreshOperandOptions() {
  const slots = nimSceneSlots();
  const key = slots.map((slot) => slot + ':' + nimItemLabel(slot)).join(',');
  if (key !== lastOperandOptionsKey) {
    lastOperandOptionsKey = key;
    for (const sel of [opFirst, opSecond]) {
      const prev = sel.value;
      sel.innerHTML = '';
      slots.forEach((slot, i) => {
        const opt = document.createElement('option');
        opt.value = i;
        opt.textContent = nimItemLabel(slot);
        sel.appendChild(opt);
      });
      if (prev !== '' && parseInt(prev, 10) < slots.length) sel.value = prev;
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
  const key = selectionSlots.join(',');
  if (key === lastSyncedSelectionKey) return;
  lastSyncedSelectionKey = key;
  if (selectionSlots.length === 0) return; // Nothing picked names nothing; leave it be.
  const sceneSlots = slots || nimSceneSlots();

  const arity = nimSelectionArity();
  if (arity !== currentArity) {
    // A filtered operation list is indexed per arity, so an option carried across from
    // the other list names an unrelated operation -- populateOperations rebuilds it and
    // falls back to the new list's first entry, exactly as the arity buttons do.
    currentArity = arity;
    opArity.querySelectorAll('button[data-arity]').forEach((b) => {
      b.classList.toggle('on', parseInt(b.dataset.arity, 10) === arity);
    });
    populateOperations();
  }

  const posFirst = sceneSlots.indexOf(selectionSlots[0]);
  if (posFirst >= 0) opFirst.value = posFirst;
  if (selectionSlots.length >= 2) {
    // Three or more picked still names a binary operation, on the first two: this picker
    // can say which two, unlike the floating menu, which hides `apply` rather than guess.
    const posSecond = sceneSlots.indexOf(selectionSlots[1]);
    if (posSecond >= 0) opSecond.value = posSecond;
  }
}

/* ---------------------------------------------------------------------- */
/* Objects panel: list, show/hide, remove, rename, recolour, edit         */
/* coefficients -- mirrors panel.layoutObjects / layoutItem exactly.      */
/* ---------------------------------------------------------------------- */

const objectsList = document.getElementById('objects-list');
const objectsCount = document.getElementById('objects-count');
/* ---------------------------------------------------------------------- */
/* Edit session: one at a time, in one of two modes -- composing a brand-  */
/* new object (`slot` null, nothing backing it in the scene yet) or        */
/* editing an existing one. Both stage the same four things and preview    */
/* through the same ghost; only `save` reaches the scene. State lives here */
/* rather than in the row's own closures because `refreshObjectsUI`        */
/* rebuilds every row from scratch, which would otherwise discard it.      */
/* ---------------------------------------------------------------------- */

let editSession = null; // { slot: number|null, coefficients: number[], label, ink }

function beginEditSession(slot) {
  // A null slot composes; a real slot edits that item. Seeding a composing session from
  //   Nim's own defaults keeps the auto-label and cycled ink every other construction
  //   path assigns, while leaving both editable before the object exists.
  editSession = slot === null
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
  nimSetGhost(editSession.coefficients);
}

function endEditSession() {
  editSession = null;
  nimClearGhost();
}

function refreshObjectsUI() {
  const slots = nimSceneSlots()
    .slice()
    .sort((a, b) => nimItemBorn(b) - nimItemBorn(a)); // Most recently added first.
  objectsCount.textContent = '(' + slots.length + ' of ' + nimSceneCapacity() + ')';
  objectsList.innerHTML = '';
  if (slots.length === 0 && !isComposing()) {
    const p = document.createElement('div');
    p.className = 'help-text';
    p.style.margin = '8px 0 0';
    p.textContent = 'Nothing here yet -- press `add` above, or drag between two objects.';
    objectsList.appendChild(p);
  }
  // A composing session heads the list: it is the newest thing here, and it has no
  //   `born` reading to sort by since nothing backs it in the scene yet.
  if (isComposing()) objectsList.appendChild(buildItemRow(null));
  for (const slot of slots) objectsList.appendChild(buildItemRow(slot));
  refreshOperandOptions();
  refreshAddButton();
}

function isComposing() { return editSession !== null && editSession.slot === null; }

function isEditing(slot) { return editSession !== null && editSession.slot === slot; }

function refreshAddButton() {
  // Disabled while any session is open, so starting a second one cannot silently
  //   discard the first -- the same treatment undo/redo get when their side is empty.
  btnAdd.disabled = editSession !== null || nimSceneCount() >= nimSceneCapacity();
}

function buildItemRow(slot) {
  // `slot === null` builds the composing row: same layout, but nothing backs it in the
  //   scene, so everything it displays comes from `editSession` and the buttons that act
  //   on a real object (hide, remove) are left out entirely.
  const isPending = slot === null;
  const isOpen = isPending || isEditing(slot);

  const row = document.createElement('div');
  if (!isPending) row.dataset.slot = slot; // Lets a caller find one row again by slot.
  row.className = 'item-row'
    + (isPending ? ' pending-item' : '')
    + (!isPending && selectionSlots.includes(slot) ? ' selected' : '')
    + (!isPending && !nimItemVisible(slot) ? ' hidden-item' : '');

  const top = document.createElement('div');
  top.className = 'item-top';

  // While a session is open its staged values drive the row, so the swatch, label and
  //   coefficient line preview the edit without the scene having changed.
  const inkOf = () => (isOpen ? editSession.ink : nimItemInk(slot));
  const labelOf = () => (isOpen ? editSession.label : nimItemLabel(slot));

  // Selection checkbox: mirrors/toggles membership in `selectionSlots`, exactly the
  // same helper long-press/click-to-select already drives -- not visibility any more.
  const selectCheck = document.createElement('input');
  selectCheck.type = 'checkbox';
  selectCheck.checked = !isPending && selectionSlots.includes(slot);
  selectCheck.disabled = isPending; // Nothing to select until it exists.
  selectCheck.title = 'Select or deselect this object.';
  if (!isPending) selectCheck.addEventListener('change', () => toggleSelection(slot, null));
  top.appendChild(selectCheck);

  const swatch = document.createElement('span');
  swatch.className = 'swatch';
  swatch.style.background = rgbToCss(nimInkColor(inkOf()));
  top.appendChild(swatch);

  const label = document.createElement('span');
  label.className = 'item-label';
  label.textContent = labelOf();
  label.style.color = rgbToCss(nimInkColor(inkOf()));
  top.appendChild(label);

  const editToggle = document.createElement('button');
  editToggle.className = 'btn item-edit-toggle';
  editToggle.type = 'button';
  editToggle.textContent = isOpen ? 'save' : 'edit';
  editToggle.title = isOpen
    ? 'Commit these values to the scene.'
    : 'Rename, recolour or reshape this object; nothing changes until you save.';
  editToggle.addEventListener('click', () => {
    if (!isOpen) { beginEditSession(slot); refreshObjectsUI(); return; }
    if (isPending && nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
    if (isPending) {
      nimAddItem(editSession.coefficients, editSession.label, editSession.ink, now());
      endEditSession();
      adoptConstructionSelection();
      toast('Added `' + label.textContent + '`.');
    } else {
      nimCommitItem(slot, editSession.coefficients, editSession.label, editSession.ink);
      endEditSession();
      toast('Saved `' + label.textContent + '`.');
    }
    refreshObjectsUI();
    refreshUndoRedoButtons();
  });
  top.appendChild(editToggle);

  if (isOpen) {
    // Abandon: a composing row vanishes with nothing added, an editing row reverts. In
    //   both cases the scene was never touched, so this only has to drop the session.
    const cancel = document.createElement('button');
    cancel.className = 'btn item-edit-cancel';
    cancel.type = 'button';
    cancel.textContent = '✕';
    cancel.title = isPending ? 'Discard this new object.' : 'Discard these changes.';
    cancel.addEventListener('click', () => {
      endEditSession();
      refreshObjectsUI();
    });
    top.appendChild(cancel);
  }

  if (!isOpen) {
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
      const wasVisible = nimItemVisible(slot);
      nimSetVisible(slot, !wasVisible);
      visibility.textContent = wasVisible ? 'show' : 'hide'; // Local flip, no full rebuild.
      row.classList.toggle('hidden-item', wasVisible);
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

  const coeffLine = document.createElement('div');
  coeffLine.className = 'item-coeff';
  const describeStaged = () =>
    isOpen ? nimDescribeCoefficients(editSession.coefficients)
           : nimItemShapeWord(slot) + ': ' + nimFormatMultivector(slot);
  coeffLine.textContent = describeStaged();
  row.appendChild(coeffLine);

  const editBox = document.createElement('div');
  editBox.className = 'item-edit' + (isOpen ? ' open' : '');

  const labelField = document.createElement('div');
  labelField.className = 'field';
  labelField.innerHTML = '<label>label</label>';
  // Every field below writes into the session, never the scene: the row's own swatch,
  //   label and coefficient line preview the change, the ghost previews the geometry,
  //   and only `save` above reaches `g_scene`.
  const labelInput = document.createElement('input');
  labelInput.type = 'text';
  labelInput.value = labelOf();
  labelInput.maxLength = 39;
  labelInput.addEventListener('input', () => {
    editSession.label = labelInput.value;
    label.textContent = labelInput.value;
  });
  labelField.appendChild(labelInput);
  editBox.appendChild(labelField);

  const inkField = document.createElement('div');
  inkField.className = 'field';
  inkField.innerHTML = '<label>colour</label>';
  const inkSelect = document.createElement('select');
  // Only the categorical slots are offerable; `nimInkChoosableSlots` decides which those
  //   are, so no palette rule lives out here. Its entries stay whole-palette ordinals,
  //   the same ones `nimItemInk` reports and `nimInkName`/`nimInkColor` accept.
  for (const ink of nimInkChoosableSlots()) {
    const opt = document.createElement('option');
    opt.value = ink;
    opt.textContent = nimInkName(ink);
    inkSelect.appendChild(opt);
  }
  inkSelect.value = inkOf();
  inkSelect.addEventListener('change', () => {
    editSession.ink = parseInt(inkSelect.value, 10);
    const rgb = nimInkColor(editSession.ink);
    swatch.style.background = rgbToCss(rgb);
    label.style.color = rgbToCss(rgb);
  });
  inkField.appendChild(inkSelect);
  editBox.appendChild(inkField);

  const coeffNote = document.createElement('div');
  coeffNote.className = 'help-text';
  coeffNote.style.margin = '6px 0';
  coeffNote.textContent = isPending
    ? 'The 16 numbers of the new multivector, in the library’s basis order. A live preview draws as soon as any goes non-zero.'
    : 'The 16 numbers of this object’s own multivector, in the library’s basis order. The object itself only moves when you save.';
  editBox.appendChild(coeffNote);

  const grid = document.createElement('div');
  grid.className = 'coeff-grid';
  // `nimFormatNumber`, not a `toFixed` here: how many digits a coefficient is worth
  //   is a decision about this project's numbers, and the desktop's own cells make it the
  //   same way.
  const coeffInputs = buildGradedCoeffGrid(
    grid,
    (b) =>
      nimFormatNumber(isOpen ? editSession.coefficients[b] : nimItemCoefficients(slot)[b]),
  );
  coeffInputs.forEach((input, b) => {
    // `input`, not `change`: the ghost tracks a keystroke rather than waiting for the
    //   field to blur, which is what makes the preview feel live.
    input.addEventListener('input', () => {
      editSession.coefficients[b] = parseFloat(input.value) || 0;
      nimSetGhost(editSession.coefficients);
      coeffLine.textContent = describeStaged();
    });
  });
  editBox.appendChild(grid);

  row.appendChild(editBox);
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
  const basisCount = nimBasisCount();
  const items = slots.map((slot) => ({
    ink: nimItemInk(slot),
    visible: nimItemVisible(slot),
    label: nimItemLabel(slot),
    coefficients: nimItemCoefficients(slot),
  }));

  let size = 4 + 1 + 1 + 4;
  for (const item of items) size += 1 + 1 + 1 + item.label.length + basisCount * 8;

  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  let offset = 0;
  const magic = 'RGAS';
  for (let i = 0; i < 4; i++) { view.setUint8(offset, magic.charCodeAt(i)); offset += 1; }
  view.setUint8(offset, 1); offset += 1; // version
  view.setUint8(offset, basisCount); offset += 1;
  view.setUint32(offset, items.length, true); offset += 4;

  for (const item of items) {
    view.setUint8(offset, item.ink); offset += 1;
    view.setUint8(offset, item.visible ? 1 : 0); offset += 1;
    view.setUint8(offset, item.label.length); offset += 1;
    for (let i = 0; i < item.label.length; i++) { view.setUint8(offset, item.label.charCodeAt(i)); offset += 1; }
    for (let i = 0; i < basisCount; i++) { view.setFloat64(offset, item.coefficients[i], true); offset += 8; }
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
  const magic = String.fromCharCode(
    view.getUint8(0), view.getUint8(1), view.getUint8(2), view.getUint8(3),
  );
  offset = 4;
  if (magic !== 'RGAS') throw new Error('File is not a scene file.');
  const version = view.getUint8(offset); offset += 1;
  if (version !== 1) throw new Error('File is a scene file of a version this build cannot read.');
  const basisCountFile = view.getUint8(offset); offset += 1;
  const basisCountHere = nimBasisCount();
  if (basisCountFile !== basisCountHere) {
    throw new Error(
      'File was saved under a different PGA dimension or metric; this build reads ' +
      basisCountHere + '-term multivectors.',
    );
  }
  const itemCount = view.getUint32(offset, true); offset += 4;
  if (itemCount > nimSceneCapacity()) {
    throw new Error('File holds ' + itemCount + ' objects, more than this build’s ' + nimSceneCapacity() + '-item capacity.');
  }

  const parsed = [];
  for (let i = 0; i < itemCount; i++) {
    if (offset + 3 > buffer.byteLength) throw new Error('File is truncated partway through object ' + i + '.');
    const ink = view.getUint8(offset); offset += 1;
    const visible = view.getUint8(offset) !== 0; offset += 1;
    const labelLen = view.getUint8(offset); offset += 1;
    if (offset + labelLen > buffer.byteLength) throw new Error('File is truncated partway through object ' + i + '’s label.');
    let label = '';
    for (let j = 0; j < labelLen; j++) { label += String.fromCharCode(view.getUint8(offset)); offset += 1; }
    if (offset + basisCountHere * 8 > buffer.byteLength) {
      throw new Error('File is truncated partway through object ' + i + '’s geometry.');
    }
    const coefficients = new Array(basisCountHere);
    for (let b = 0; b < basisCountHere; b++) { coefficients[b] = view.getFloat64(offset, true); offset += 8; }
    parsed.push({ ink, visible, label, coefficients });
  }

  nimSceneClear();
  for (const item of parsed) nimSceneAddRaw(item.ink, item.visible, item.label, item.coefficients);
  return 'Loaded ' + itemCount + ' object(s) from scene file.';
}

/* ---------------------------------------------------------------------- */
/* Diagnostics: browser-appropriate stand-ins for the desktop build's own */
/* arena/frame-time panel -- see this file's own `.help-text` and         */
/* `browser_bridge.nim`'s doc comment for why the numbers differ in kind. */
/* ---------------------------------------------------------------------- */

const FRAMES_HISTORY = 240;
const frameHistory = new Array(FRAMES_HISTORY).fill(16.6);
let frameHistoryIndex = 0;
let lastFrameTime = performance.now();
const sparkline = document.getElementById('sparkline');
const sparklineCtx = sparkline.getContext('2d');
const diagFrametime = document.getElementById('diag-frametime');
const diagHeap = document.getElementById('diag-heap');
const diagPool = document.getElementById('diag-pool');
const poolStrip = document.getElementById('pool-strip');
let poolStripBuilt = false;

function recordFrameTime(deltaMs) {
  frameHistory[frameHistoryIndex] = deltaMs;
  frameHistoryIndex = (frameHistoryIndex + 1) % FRAMES_HISTORY;
}

function refreshDiagnostics() {
  const w = sparkline.clientWidth || 300, h = sparkline.clientHeight || 40;
  if (sparkline.width !== w) sparkline.width = w;
  if (sparkline.height !== h) sparkline.height = h;
  let highest = 16.6;
  for (const v of frameHistory) if (v > highest) highest = v;
  sparklineCtx.clearRect(0, 0, w, h);
  sparklineCtx.strokeStyle = '#00a7a5';
  sparklineCtx.lineWidth = 1.5;
  sparklineCtx.beginPath();
  for (let i = 0; i < FRAMES_HISTORY; i++) {
    const v = frameHistory[(frameHistoryIndex + i) % FRAMES_HISTORY];
    const x = (i / (FRAMES_HISTORY - 1)) * w;
    const y = h - (Math.min(v, highest) / highest) * h;
    if (i === 0) sparklineCtx.moveTo(x, y); else sparklineCtx.lineTo(x, y);
  }
  sparklineCtx.stroke();

  const latest = frameHistory[(frameHistoryIndex + FRAMES_HISTORY - 1) % FRAMES_HISTORY];
  diagFrametime.textContent = latest.toFixed(2) + ' ms (' + Math.round(1000 / Math.max(latest, 1)) + ' fps)';

  if (performance.memory) {
    diagHeap.textContent = (performance.memory.usedJSHeapSize / (1024 * 1024)).toFixed(1) + ' / ' +
      (performance.memory.jsHeapSizeLimit / (1024 * 1024)).toFixed(0) + ' MB';
  }

  const count = nimSceneCount(), capacity = nimSceneCapacity();
  diagPool.textContent = count + ' / ' + capacity;
  if (!poolStripBuilt) {
    for (let i = 0; i < capacity; i++) poolStrip.appendChild(document.createElement('span'));
    poolStripBuilt = true;
  }
  // An occupied cell wears its own object's ink, so the strip reads as the scene rather
  //   than as an anonymous occupancy count. `nimPoolCellColors` decides every cell's
  //   colour, free ones included, so no palette rule lives out here -- it returns one
  //   [r, g, b] triple per slot, in slot order.
  const cells = nimPoolCellColors();
  Array.from(poolStrip.children).forEach((el, i) => {
    el.style.background = rgbToCss(cells.slice(i * 3, i * 3 + 3));
  });
}

/* ---------------------------------------------------------------------- */
/* Overlay: hover ring + drag rubber-band, as plain 2D SVG drawn on top of */
/* the WebGL canvas -- mirrors `visualiser.drawInteractionOverlay` exactly */
/* (same radius, same tint per operation), just drawn through SVG rather   */
/* than through Dear ImGui's own immediate-mode draw list.                */
/* ---------------------------------------------------------------------- */

const overlaySvg = document.getElementById('overlay');
// Read from marker.nim's own constants via nimOverlayMetrics, rather than a hand-copied
// literal that could drift out of sync with them.
const [WIDTH_OVERLAY_LINE, ALPHA_MARKER_HOVER] = nimOverlayMetrics();
// Mirrors marker.MarkerKind's own ordinals; nimSelectionMarker leads with one of these.
const MARKER_RING = 0, MARKER_RAILS = 1, MARKER_LOOP = 2;

function svgEl(tag, attrs) {
  const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const k in attrs) el.setAttribute(k, attrs[k]);
  return el;
}

// Stroke one object's marker into the overlay. Every geometric decision -- which outline,
// how far off the object it sits, where its points land on screen -- was made by
// marker.nim; this only turns the flat array it reports into SVG elements, and scales
// from framebuffer pixels to CSS pixels the way every other overlay here does.
function appendMarker(slot, alpha, w, h) {
  const marker = nimSelectionMarker(slot, canvas.width, canvas.height);
  if (marker.length === 0) return;
  const kind = marker[0], isClosed = marker[1] > 0.5, radius = marker[2];
  const stroke = 'rgba(255,255,255,' + alpha + ')';
  const points = [];
  for (let i = 3; i + 1 < marker.length; i += 2) {
    points.push([marker[i] * (w / canvas.width), marker[i + 1] * (h / canvas.height)]);
  }

  if (kind === MARKER_RING) {
    overlaySvg.appendChild(svgEl('circle', {
      cx: points[0][0], cy: points[0][1], r: radius,
      fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
    }));
  } else if (kind === MARKER_RAILS) {
    for (let i = 0; i < points.length; i += 2) {
      overlaySvg.appendChild(svgEl('line', {
        x1: points[i][0], y1: points[i][1], x2: points[i + 1][0], y2: points[i + 1][1],
        stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      }));
    }
  } else if (kind === MARKER_LOOP) {
    overlaySvg.appendChild(svgEl(isClosed ? 'polygon' : 'polyline', {
      points: points.map((p) => p[0] + ',' + p[1]).join(' '),
      fill: 'none', stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
    }));
  }
}

function refreshOverlay(cursor) {
  overlaySvg.innerHTML = '';
  const w = canvas.clientWidth, h = canvas.clientHeight;

  // One marker per selected object, shaped to that object by marker.nim -- a ring about
  // a point, rails flanking a line, a loop lying on a plane. Hover draws the very same
  // marker at lower opacity, so both read as one family and hovering a line previews
  // exactly what selecting it will draw.
  for (const slot of selectionSlots) appendMarker(slot, 1.0, w, h);

  const hoverSlot = nimHoverSlot();
  if (hoverSlot >= 0 && !selectionSlots.includes(hoverSlot)) {
    appendMarker(hoverSlot, ALPHA_MARKER_HOVER, w, h);
  }

  if (nimDragActive()) {
    const src = nimAnchorScreen(nimDragSourceSlot(), canvas.width, canvas.height);
    if (src[2] > 0.5 && cursor) {
      const sx = src[0] * (w / canvas.width), sy = src[1] * (h / canvas.height);
      const tint = nimDragTint(nimDragOperation());
      overlaySvg.appendChild(svgEl('line', {
        x1: sx, y1: sy, x2: cursor.x, y2: cursor.y,
        stroke: 'rgba(' + Math.round(tint[0] * 255) + ',' + Math.round(tint[1] * 255) + ',' + Math.round(tint[2] * 255) + ',0.85)',
        'stroke-width': WIDTH_OVERLAY_LINE,
      }));
    }
  }
}

/* ---------------------------------------------------------------------- */
/* Pointer input.                                                          */
/*   Mouse/pen: left-drag-from-object joins, right-drag-from-object meets, */
/*   middle-drag-from-object projects; drag-from-empty-space falls back to */
/*   left-orbit/right-pan/wheel-dolly -- mirrors                          */
/*   `visualiser.handleEvent`/`dragOperationFor` exactly.                  */
/*   Touch: single-finger drag orbits, pinch zooms, two-finger pan (all    */
/*   unchanged); a tap on an object selects it as a drag source, a second  */
/*   tap on a different object opens a small join/meet/project menu,      */
/*   since touch has no buttons to carry that choice the way a mouse does. */
/* ---------------------------------------------------------------------- */

canvas.addEventListener('contextmenu', (e) => e.preventDefault());

const pointers = new Map();
let pinchStartDist = null;
let panLast = null;
let mouseDragButton = null; // Button held for camera orbit/pan fallback, while no operation drag is active.
let lastCursor = null;

// Touch long-press-to-select / tap-to-toggle state.
let touchDownAt = null, touchDownPos = null, touchMoved = false;
let touchLongPressTimer = null, touchLongPressFired = false;
const TAP_MAX_MS = 350, TAP_MAX_MOVE = 12, LONG_PRESS_MS = 500;

// Mouse click-vs-drag disambiguation state -- a plain click (no movement) selects/
//   shift-selects; an actual drag still applies join/meet/project exactly as before.
let mouseDownAt = null, mouseDownPos = null, mouseDownButton = null, mouseMoved = false;
const MOUSE_CLICK_MAX_MS = 350, MOUSE_CLICK_MAX_MOVE = 6;

function pointerDist(pts) {
  const [a, b] = pts;
  return Math.hypot(a.x - b.x, a.y - b.y);
}
function pointerMid(pts) {
  const [a, b] = pts;
  return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
}

canvas.addEventListener('pointerdown', (e) => {
  canvas.setPointerCapture(e.pointerId);
  const rect = canvas.getBoundingClientRect();
  const local = { x: e.clientX - rect.left, y: e.clientY - rect.top };
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

  if (e.pointerType === 'mouse') {
    const dpr = canvas.width / rect.width;
    nimUpdateCursor(local.x * dpr, local.y * dpr);
    nimUpdateHover(canvas.width, canvas.height);
    mouseDownAt = performance.now();
    mouseDownPos = { x: e.clientX, y: e.clientY };
    mouseDownButton = e.button;
    mouseMoved = false;
    const drag = nimDragOperationForButton(e.button);
    if (drag >= 0 && nimBeginDrag(drag)) {
      mouseDragButton = e.button;
    } else if (e.button === 0) {
      mouseDragButton = 'orbit';
    } else if (e.button === 2) {
      mouseDragButton = 'pan';
    }
    return;
  }

  // Touch/pen: track for the existing multi-touch orbit/pinch/pan gesture, for a
  // single-finger tap that toggles selection membership once a selection exists, and
  // for a long-press that starts one.
  if (pointers.size === 1) {
    touchDownAt = performance.now();
    touchDownPos = local;
    touchMoved = false;
    touchLongPressFired = false;
    clearTimeout(touchLongPressTimer);
    touchLongPressTimer = setTimeout(() => {
      if (touchMoved) return; // Moved into an orbit gesture before the hold matured.
      const rect2 = canvas.getBoundingClientRect();
      const dpr2 = canvas.width / rect2.width;
      nimUpdateCursor(touchDownPos.x * dpr2, touchDownPos.y * dpr2);
      nimUpdateHover(canvas.width, canvas.height);
      const hovered = nimHoverSlot();
      if (hovered >= 0) {
        touchLongPressFired = true;
        toggleSelection(hovered, touchDownPos);
      }
    }, LONG_PRESS_MS);
  } else {
    touchDownAt = null; // A second finger landed; this is a pinch/pan gesture, not a tap.
    clearTimeout(touchLongPressTimer);
  }
  if (pointers.size === 2) {
    const pts = [...pointers.values()];
    pinchStartDist = pointerDist(pts);
    panLast = pointerMid(pts);
  }
});

canvas.addEventListener('pointermove', (e) => {
  const rect = canvas.getBoundingClientRect();
  lastCursor = { x: e.clientX - rect.left, y: e.clientY - rect.top };

  if (e.pointerType === 'mouse') {
    const dpr = canvas.width / rect.width;
    nimUpdateCursor(lastCursor.x * dpr, lastCursor.y * dpr);
    if (mouseDownPos && Math.hypot(e.clientX - mouseDownPos.x, e.clientY - mouseDownPos.y) > MOUSE_CLICK_MAX_MOVE) {
      mouseMoved = true;
    }
    if (mouseDragButton !== null && typeof mouseDragButton === 'number') {
      nimUpdateHover(canvas.width, canvas.height); // Re-check hover for the drag's own destination preview.
      return;
    }
    if (!pointers.has(e.pointerId)) return;
    const prev = pointers.get(e.pointerId);
    const cur = { x: e.clientX, y: e.clientY };
    pointers.set(e.pointerId, cur);
    const dx = cur.x - prev.x, dy = cur.y - prev.y;
    if (mouseDragButton === 'orbit') {
      nimCameraOrbit(-dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4);
    } else if (mouseDragButton === 'pan') {
      nimCameraPan(-dx / canvas.clientWidth * 1.4, dy / canvas.clientHeight * 1.4);
    }
    nimUpdateHover(canvas.width, canvas.height);
    return;
  }

  if (!pointers.has(e.pointerId)) return;
  const prev = pointers.get(e.pointerId);
  const cur = { x: e.clientX, y: e.clientY };
  pointers.set(e.pointerId, cur);
  if (touchDownPos && Math.hypot(lastCursor.x - touchDownPos.x, lastCursor.y - touchDownPos.y) > TAP_MAX_MOVE) {
    touchMoved = true;
    clearTimeout(touchLongPressTimer);
  }

  if (pointers.size === 1) {
    const dx = cur.x - prev.x, dy = cur.y - prev.y;
    nimCameraOrbit(-dx / canvas.clientWidth * Math.PI * 1.4, dy / canvas.clientHeight * Math.PI * 1.4);
  } else if (pointers.size === 2) {
    const pts = [...pointers.values()];
    const dist = pointerDist(pts);
    if (pinchStartDist) nimCameraDolly(pinchStartDist / Math.max(1, dist));
    pinchStartDist = dist;

    const mid = pointerMid(pts);
    if (panLast) {
      const dx = (mid.x - panLast.x) / canvas.clientWidth;
      const dy = (mid.y - panLast.y) / canvas.clientHeight;
      nimCameraPan(-dx * 1.4, dy * 1.4);
    }
    panLast = mid;
  }
});

function endMouseDrag(e) {
  const isClick = !mouseMoved && mouseDownAt !== null &&
    performance.now() - mouseDownAt < MOUSE_CLICK_MAX_MS;

  if (typeof mouseDragButton === 'number') {
    if (isClick && mouseDownButton === 0) {
      // A plain left click over a hovered object: today this eagerly-begun Join drag
      //   would complete as a harmless "released on its own source" no-op and toast
      //   that; a plain click now means select/shift-select instead, so abandon the
      //   drag without applying anything.
      nimCancelDrag();
      const hovered = nimHoverSlot();
      if (hovered >= 0) {
        if (e.shiftKey) toggleSelection(hovered, lastCursor);
        else selectOnly(hovered, lastCursor);
      }
    } else {
      // A genuine drag (moved, or held past the click window), or a non-left-button
      //   plain click -- both keep exactly today's behaviour unchanged.
      const result = nimEndDrag(now());
      toast(result.message);
      if (result.created_slot >= 0) adoptConstructionSelection();
    }
  } else if (isClick && mouseDownButton === 0 && !e.shiftKey) {
    // Plain left click over empty space -- mirrors touch's own "tapping empty space
    //   always cancels" rule. A shift+click over empty space is left a no-op, not a
    //   clear -- shift signals "preserve what I already have".
    clearSelection();
  }

  mouseDragButton = null;
  mouseDownAt = null; mouseDownPos = null; mouseDownButton = null; mouseMoved = false;
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
  clearTimeout(touchLongPressTimer);
  if (!touchLongPressFired && touchDownAt !== null && !touchMoved && pointers.size === 1 &&
      performance.now() - touchDownAt < TAP_MAX_MS) {
    handleTap(touchDownPos);
  }
  touchDownAt = null;
  touchLongPressFired = false;
  pointers.delete(e.pointerId);
  if (pointers.size < 2) { pinchStartDist = null; panLast = null; }
  if (pointers.size === 0) nimClearHover(); // No finger left touching the canvas -- there's
    // no cursor position left to be "hovering" anything, so don't let the last touch-down's
    // own hover reading linger and draw its ring forever.
}
canvas.addEventListener('pointerup', releasePointer);
canvas.addEventListener('pointercancel', releasePointer);
canvas.addEventListener('pointerleave', (e) => { if (e.buttons === 0) releasePointer(e); });

canvas.addEventListener('wheel', (e) => {
  e.preventDefault();
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

function handleTap(localPos) {
  const rect = canvas.getBoundingClientRect();
  const dpr = canvas.width / rect.width;
  nimUpdateCursor(localPos.x * dpr, localPos.y * dpr);
  nimUpdateHover(canvas.width, canvas.height);
  const hovered = nimHoverSlot();

  if (hovered < 0) {
    clearSelection(); // Tapping empty space always cancels.
    return;
  }
  if (selectionSlots.length === 0) return; // Not in select mode yet -- only a long-press
    // starts one; a plain tap before that is a no-op, same as before this feature.
  toggleSelection(hovered, localPos);
}

const selectionMenu = document.getElementById('selection-menu');
const selectionMenuApply = document.getElementById('selection-menu-apply');
const selectionMenuEdit = document.getElementById('selection-menu-edit');
const selectionMenuHide = document.getElementById('selection-menu-hide');
const selectionMenuDelete = document.getElementById('selection-menu-delete');
const selectionMenuReveal = document.getElementById('selection-menu-reveal');
const selectionMenuSelect = document.getElementById('selection-menu-select');
const selectionMenuBack = document.getElementById('selection-menu-back');
const selectionMenuClose = document.getElementById('selection-menu-close');
let lastMenuOpArity = -1; // Arity last used to rebuild selection-menu-select's own
  // <option> list -- like the drawer's own populateOperations, only rebuilds when it
  // actually changes, not on every reveal.

function populateSelectionMenuOptions(arity) {
  if (arity === lastMenuOpArity) return;
  lastMenuOpArity = arity;
  selectionMenuSelect.innerHTML = '';
  const count = nimOperationCount();
  for (let i = 0; i < count; i++) {
    if (nimOperationArity(i) !== arity) continue;
    const opt = document.createElement('option');
    opt.value = i;
    opt.textContent = nimOperationNotation(i);
    selectionMenuSelect.appendChild(opt);
  }
}

function openSelectionMenuOp() {
  // "apply" itself never moves -- it stays the leftmost element of one single row
  //   throughout; this only animates the picker+back group open immediately to its
  //   right (see .selection-menu-reveal's own max-width transition). hide/delete step
  //   aside while picking an operation, matching the old two-row design's own behaviour
  //   (its second row never carried them either) -- ✕ stays, as it always did.
  populateSelectionMenuOptions(nimSelectionArity());
  selectionMenuReveal.classList.add('open');
  selectionMenuEdit.style.display = 'none';
  selectionMenuHide.style.display = 'none';
  selectionMenuDelete.style.display = 'none';
}

function closeSelectionMenuOp() {
  selectionMenuReveal.classList.remove('open');
  selectionMenuEdit.style.display = selectionSlots.length === 1 ? '' : 'none';
  selectionMenuHide.style.display = '';
  selectionMenuDelete.style.display = '';
}

function refreshSelectionMenu(localPos) {
  const n = selectionSlots.length;
  if (n === 0) { hideSelectionMenu(); return; }
  selectionMenuApply.style.display = (n === 1 || n === 2) ? '' : 'none'; // 3+: no apply --
    // this menu has no operand pickers, so it cannot say which two of three it would use.
  selectionMenuEdit.style.display = n === 1 ? '' : 'none'; // One object has one editor.
  selectionMenuHide.textContent = nimSelectionAllHidden() ? 'show' : 'hide';
  closeSelectionMenuOp(); // Any fresh selection change resets the picker closed.
  if (localPos) positionSelectionMenuAt(localPos); else updateSelectionMenuPosition();
  selectionMenu.classList.add('show');
}

function hideSelectionMenu() {
  selectionMenu.classList.remove('show');
  closeSelectionMenuOp();
  lastMenuOpArity = -1;
}

function positionSelectionMenuAt(localPos) {
  const rect = canvas.getBoundingClientRect();
  // Reserved right margin covers the widest state this popover reaches: the op-picker
  //   row (select sized to its own longest notation, e.g. "𝐧 ∨ (𝐦 ∧ 𝐧☆)", plus "apply"/
  //   "back") now that the select's own width is content-sized rather than truncated.
  selectionMenu.style.left = Math.min(rect.left + localPos.x, window.innerWidth - 300) + 'px';
  selectionMenu.style.top = Math.max(rect.top + localPos.y - 60, 8) + 'px';
}

function updateSelectionMenuPosition() {
  // Keep the menu glued to the most-recently-selected slot's own screen position every
  //   frame it's open, generalizing the old tap-menu's single-slot follow -- an average
  //   across all selected would jump around as membership changes for no real benefit.
  if (!selectionMenu.classList.contains('show') || selectionSlots.length === 0) return;
  const anchorSlot = selectionSlots[selectionSlots.length - 1];
  const anchor = nimAnchorScreen(anchorSlot, canvas.width, canvas.height);
  if (anchor[2] <= 0.5) return; // Off-screen -- leave the menu at its last valid spot.
  const w = canvas.clientWidth, h = canvas.clientHeight;
  positionSelectionMenuAt({
    x: anchor[0] * (w / canvas.width),
    y: anchor[1] * (h / canvas.height),
  });
}

selectionMenuApply.addEventListener('click', () => {
  // First press: open the picker (animates open to this same button's own right --
  //   the button itself never moves or relabels). Second press, picker already open:
  //   commit with whatever operation is currently selected -- one button serves both
  //   roles instead of a separate "go" button appearing once the picker opens.
  if (!selectionMenuReveal.classList.contains('open')) {
    openSelectionMenuOp();
    return;
  }
  const n = selectionSlots.length;
  if (n !== 1 && n !== 2) return; // Guard only -- apply is hidden for 0/3+ anyway.
  if (nimSceneCount() >= nimSceneCapacity()) { toast('Scene is full.'); return; }
  const first = selectionSlots[0];
  const second = n === 2 ? selectionSlots[1] : first; // Unary ignores the second operand.
  const result = nimApplyOperation(parseInt(selectionMenuSelect.value, 10), first, second, now());
  toast(result.message);
  adoptConstructionSelection();
});
selectionMenuEdit.addEventListener('click', () => {
  // Reaching an object's editor otherwise means opening the drawer and hunting its row,
  //   even with that object already picked and its own menu on screen.
  if (selectionSlots.length !== 1) return; // Guard only -- hidden for 0 and 2+ anyway.
  openWorkbenchTo(selectionSlots[0]);
  hideSelectionMenu(); // The workbench owns the interaction now; the pick itself stays.
});

selectionMenuBack.addEventListener('click', closeSelectionMenuOp);

selectionMenuHide.addEventListener('click', () => {
  // Whichever way the button reads is what it does, so the objects it hid can be brought
  //   back from the same place -- `nimSelectionAllHidden` owns what "hidden" means for a
  //   whole selection, the way the row button reads `nimItemVisible` for one object.
  const show = nimSelectionAllHidden();
  for (const slot of selectionSlots) nimSetVisible(slot, show);
  toast((show ? 'Showed ' : 'Hid ') + selectionSlots.length + ' object(s).');
  refreshSelectionMenu(null); // Relabels the button for what it would now do.
  refreshObjectsUI(); // Selection itself is kept -- hiding doesn't invalidate the slot.
});

selectionMenuDelete.addEventListener('click', () => {
  const n = selectionSlots.length;
  for (const slot of selectionSlots) nimRemoveItem(slot);
  toast('Deleted ' + n + ' object(s).');
  clearSelection();
  refreshObjectsUI();
});

selectionMenuClose.addEventListener('click', clearSelection);

document.addEventListener('pointerdown', (e) => {
  // Only a tap/click landing outside the canvas, the menu itself, the drawer
  //   (interacting with the Objects list/workbench must not dismiss the selection menu
  //   or clear selection), and the top chip-row (save/load scene lives there too)
  //   should dismiss it here -- dismissing on the canvas's own down event would race
  //   handleTap/endMouseDrag's own resolution of that same gesture.
  if (selectionMenu.classList.contains('show') && !selectionMenu.contains(e.target) &&
      e.target !== canvas && !drawer.contains(e.target) && !chipRow.contains(e.target)) {
    clearSelection();
  }
  // Top menu: same shape of guard, its own state/target -- a tap landing outside the
  //   popover and outside its own trigger button closes it.
  if (topMenu.classList.contains('show') && !topMenu.contains(e.target) && e.target !== menuBtn
      && !menuBtn.contains(e.target)) {
    topMenu.classList.remove('show');
    menuBtn.classList.remove('on');
  }
});

/* ---------------------------------------------------------------------- */
/* Resize                                                                   */
/* ---------------------------------------------------------------------- */

function resize() {
  const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
  const w = Math.round(canvas.clientWidth * dpr);
  const h = Math.round(canvas.clientHeight * dpr);
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
    gl.viewport(0, 0, w, h);
  }
  overlaySvg.setAttribute('viewBox', '0 0 ' + canvas.clientWidth + ' ' + canvas.clientHeight);
}
window.addEventListener('resize', resize);

/* ---------------------------------------------------------------------- */
/* Frame loop -- pull one frame's tessellated vertices and view-projection */
/* matrix out of the compiled Nim module and upload them straight to GL.   */
/* ---------------------------------------------------------------------- */

let uiRefreshAccum = 0;

function frame() {
  resize();
  const nowSeconds = now();
  const aspect = canvas.width / canvas.height;

  const nowMs = performance.now();
  recordFrameTime(nowMs - lastFrameTime);
  lastFrameTime = nowMs;

  const data = nimBuildFrame(aspect, nowSeconds, showAxes, showGrid);

  const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.uniformMatrix4fv(uMVP, false, new Float32Array(data.view_projection));

  // World furniture first, at its own thinner line width, with normal depth test/write.
  // Mirrors renderer.nim's own drawMeshes(MESHES_FURNITURE, ...) call exactly.
  gl.lineWidth(WIDTH_LINE_FURNITURE);
  drawBuffer(data.furn_line_verts, gl.LINES, false, vbo.furnLine);

  // Scene objects last, at their own wider line width; opaque kinds before plane washes
  // (triangles), with depth writes off for those, so a translucent plane never occludes
  // a line or point that happens to sit behind it -- it only tints over whatever was
  // already drawn there. Mirrors renderer.nim's own drawMeshes(MESHES, ...) call exactly.
  gl.uniform1f(uPointSize, SIZE_POINT * dpr);
  gl.lineWidth(WIDTH_LINE_OBJECT);
  drawBuffer(data.line_verts, gl.LINES, false, vbo.line);
  drawBuffer(data.point_verts, gl.POINTS, true, vbo.point);
  gl.depthMask(false);
  drawBuffer(data.tri_verts, gl.TRIANGLES, false, vbo.tri);
  gl.depthMask(true);

  refreshOverlay(lastCursor);
  updateSelectionMenuPosition();

  // UI (camera fields, diagnostics) refresh at a lower cadence than the draw loop --
  // no visual harm in a number lagging one frame, and it keeps DOM writes off the hot path.
  uiRefreshAccum += 1;
  if (uiRefreshAccum >= 6) {
    uiRefreshAccum = 0;
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
