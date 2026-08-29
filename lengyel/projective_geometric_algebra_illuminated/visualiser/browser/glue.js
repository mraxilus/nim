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
// two line widths are not: `mesh.addSegment` has already built them into the ribbon
// geometry, because WebGL clamps `gl.lineWidth` to one pixel on most implementations.
const [SIZE_POINT] = nimRenderLineWidths();

const vbo = {
  tri: gl.createBuffer(), ribbon: gl.createBuffer(), point: gl.createBuffer(),
  ribbon_furniture: gl.createBuffer(),
};
const STRIDE = 7 * 4;

// How many furniture vertices its own buffer holds, carried between frames because the
// bridge stops sending them once the camera is still; see `renderFrame`.
let count_furniture_held = null;

// One mesh handed to the driver whole, ready to be drawn as one run or two. Separate
// from drawing because the two runs go out in different passes (see the draw loop below),
// and a mesh uploaded twice a frame would be the one real cost of that split.
function uploadBuffer(data, handle_buffer) {
  if (data.length === 0) return null;
  const entries = data instanceof Float32Array ? data : new Float32Array(data);
  gl.bindBuffer(gl.ARRAY_BUFFER, handle_buffer);
  gl.bufferData(gl.ARRAY_BUFFER, entries, gl.DYNAMIC_DRAW);
  return entries.length / 7;
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
    refreshDeliveryReport();
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
    refreshDeliveryReport();
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
  // The drawer opens over the corner the scale bar sits in; see `.ruler.aside`.
  document.getElementById('ruler').classList.toggle('aside', open);
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
  if (row) row.scrollIntoView({ block: 'nearest' }); // A long list can open past it.
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
  //   scene, so everything it displays comes from `session_edit` and the buttons that act
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
const strip_pool = document.getElementById('pool-strip');
const diagnostic_delivery = document.getElementById('diag-delivery');
let is_strip_pool_built = false;

// One ring per step of the drawing process, so the diagnostics tab can show where a frame
// actually went rather than one opaque total. The bridge reports its own three phases on
// FrameData (build = furniture + scene + flatten, timed inside nimBuildFrame where only it
// can see them); this side times what only it can see -- the GL upload+draw, the SVG
// overlay, the selection menu, and the low-cadence UI block. Rings rather than a latest
// value, so each row can show a rolling median beside the instantaneous number: a single
// frame's reading flickers too fast to read, and a median is what a reader means by "how
// long does this step take".
const PHASES_DIAGNOSTIC = [
  ['build', 'diag-build'], ['furniture', 'diag-furniture'],
  ['grid', 'diag-grid'], ['axes', 'diag-axes'], ['scene', 'diag-scene'],
  ['points', 'diag-points'], ['lines', 'diag-lines'], ['planes', 'diag-planes'],
  ['sky', 'diag-sky'], ['ghost', 'diag-ghost'], ['selected', 'diag-selected'],
  ['flatten', 'diag-flatten'], ['upload', 'diag-upload'], ['overlay', 'diag-overlay'],
  ['menu', 'diag-menu'], ['ui', 'diag-ui'],
];
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
const element_phase = {};
for (const [name, id] of PHASES_DIAGNOSTIC) {
  history_phase[name] = new Array(FRAMES_HISTORY).fill(-1); // -1 marks a never-written slot.
  element_phase[name] = document.getElementById(id);
}
for (const name in COUNTS_DIAGNOSTIC) count_phase[name] = 0;
function recordPhaseTime(name, delta_milliseconds) {
  // Shares the frame ring's own index, advanced once per frame by recordFrameTime, so
  // every ring lines up frame for frame; the UI phase only runs one frame in six and
  // leaves its other slots at -1, which the median below skips.
  history_phase[name][index_history_frame] = delta_milliseconds;
}
// Scratch the median borrows rather than allocating: this runs per phase per refresh, and
//   the rows a tree can hold grow faster than the frames between refreshes do. A filter
//   plus a sort built two arrays each time and threw both away.
const scratch_median = new Array(FRAMES_HISTORY);
function medianPhase(name) {
  const ring = history_phase[name];
  let count = 0;
  for (let i = 0; i < FRAMES_HISTORY; i += 1) {
    if (ring[i] >= 0) { scratch_median[count] = ring[i]; count += 1; }
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

// The rows that have children, and whether each is open. **Every one starts closed**: a
//   reader opens the diagnostics panel to see whether a frame is slow, and goes looking for
//   which step only once it is. A closed node's rows are skipped by `refreshDiagnostics`
//   entirely, so a subtotal nobody is reading costs nothing to keep offering.
const NODES_DIAGNOSTIC = {
  build: ['furniture', 'scene', 'flatten'],
  furniture: ['grid', 'axes'],
  scene: ['points', 'lines', 'planes', 'sky', 'ghost', 'selected'],
};
const element_node = {};
for (const name in NODES_DIAGNOSTIC) {
  const node = document.querySelector('.diag-node[data-node="' + name + '"]');
  if (node === null) continue;
  element_node[name] = node;
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
  // Walk up: a row is shown only where every branch holding it is open. A closed branch
  //   nested inside an open one hides its rows just as an outermost closed one does.
  let child = name;
  for (let depth = 0; depth < 8; depth += 1) {
    let parent = null;
    for (const above in NODES_DIAGNOSTIC) {
      if (NODES_DIAGNOSTIC[above].includes(child)) { parent = above; break; }
    }
    if (parent === null) return true; // Reached a row nothing encloses.
    const node = element_node[parent];
    if (node !== undefined && !node.classList.contains('open')) return false;
    child = parent;
  }
  return true;
}

function refreshDeliveryReport() {
  // Where a save went, in the reader's own words -- because on a phone in a frame this page
  //   does not control, that is otherwise unknowable to anyone. The toast carries it too,
  //   but a toast is transient and this is the copy somebody can screenshot at leisure.
  diagnostic_delivery.textContent = report_delivery.length === 0
    ? 'nothing saved yet' : report_delivery.join('\n');
}

// **How often a frame runs long, over a window long enough to answer that.** The
//   sparkline holds four seconds and shows *when*; a reader chasing a stall that happens
//   once a minute needs *how often*, which is a distribution rather than a trace. Kept as
//   a rolling window of the last `FRAMES_EXCEEDANCE` frames, which at 60 fps is a minute
//   or so, and summarised as the share of them at or over each duration.
//   The window is a ring of samples *and* a histogram of the same samples, maintained
//   together: a frame entering increments its bucket, the frame it evicts decrements the
//   one it was in. That keeps the per-frame cost a couple of array writes -- this runs on
//   every frame, including the ones being measured -- and leaves the curve a single
//   suffix scan over the buckets, done only when the panel is actually open.
const FRAMES_EXCEEDANCE = 4096;
const MILLISECONDS_BUCKET = 0.5; // Fine enough to separate a 16.7 ms frame from a 17.2.
const BUCKETS_EXCEEDANCE = 256; // Up to 128 ms; everything slower lands in the last one.
const history_exceedance = new Float32Array(FRAMES_EXCEEDANCE);
const buckets_exceedance = new Int32Array(BUCKETS_EXCEEDANCE);
let index_exceedance = 0;
let count_exceedance = 0; // Rises to the window's own size, then stays there.
const exceedance = document.getElementById('exceedance');
const context_exceedance = exceedance === null ? null : exceedance.getContext('2d');
const diagnostic_exceedance = document.getElementById('diag-exceedance');

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
  recordExceedance(delta_milliseconds);
  index_history_frame = (index_history_frame + 1) % FRAMES_HISTORY;
  // The slot the phases are about to write into is cleared up front, so a phase that
  // does not run this frame (the UI block, a held furniture build) reads as absent
  // rather than as whatever it cost 240 frames ago.
  for (const [name] of PHASES_DIAGNOSTIC) history_phase[name][index_history_frame] = -1;
}

// Log probability down, milliseconds across: a curve on a linear probability axis is a
//   vertical drop and a flat line, which says nothing about the tail -- and the tail is
//   the whole question. Decades from every frame down to one in a thousand.
const DECADES_EXCEEDANCE = 3;
// **The axis is fixed, not fitted.** It used to run out to the slowest bucket the window
//   held, which made the same curve mean a different thing minute to minute: a session
//   that got worse redrew itself flatter, and no two readings could be compared. Fifty
//   milliseconds holds every budget below plus half again, and a curve still carrying
//   height at the right edge is a session with frames slower than that -- which reads as
//   "off the chart", correctly. The buckets keep their own full range, so the 1-in-100
//   stated beside the curve is true even when it lies beyond the axis.
const MILLISECONDS_AXIS_EXCEEDANCE = 50;
// The frame budgets a reader actually aims at, each named by the rate it is: a duration
//   means nothing to most people and "60" means something to everyone.
const BUDGETS_EXCEEDANCE = [
  { milliseconds: 1000 / 120, label: '120', token: '--speed-fast' },
  { milliseconds: 1000 / 60, label: '60', token: '--speed-good' },
  { milliseconds: 1000 / 30, label: '30', token: '--speed-fair' },
  { milliseconds: Infinity, label: '', token: '--speed-poor' },
];
// Read once from the stylesheet, which is where they are set and tuned; see the tokens'
//   own comment in `shell.html` for how the four were screened.
const colours_exceedance = BUDGETS_EXCEEDANCE.map((budget) =>
  getComputedStyle(document.documentElement).getPropertyValue(budget.token).trim() ||
    '#00a7a5');
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
  const share_floor = Math.pow(10, -DECADES_EXCEEDANCE);
  const yOf = (share) => {
    if (share <= share_floor) return h;
    return h - (1 + Math.log10(share) / DECADES_EXCEEDANCE) * h;
  };
  const xOf = (milliseconds) => (milliseconds / MILLISECONDS_AXIS_EXCEEDANCE) * w;

  // A decade line per order of magnitude, so the reader can see where one frame in ten,
  //   one in a hundred and one in a thousand fall without a labelled axis eating the plot.
  context_exceedance.strokeStyle = 'rgba(139, 150, 163, 0.18)';
  context_exceedance.lineWidth = 1;
  for (let decade = 1; decade <= DECADES_EXCEEDANCE; decade += 1) {
    const y = Math.round(yOf(Math.pow(10, -decade))) + 0.5;
    context_exceedance.beginPath();
    context_exceedance.moveTo(0, y);
    context_exceedance.lineTo(w, y);
    context_exceedance.stroke();
  }
  // The budgets themselves, each named by its frame rate. These are what divide the curve
  //   into its four coloured runs below, so the line a reader reads the colour against is
  //   the very line the colour changes at.
  context_exceedance.setLineDash([2, 3]);
  context_exceedance.font = '9px ' +
    (getComputedStyle(document.documentElement).getPropertyValue('--mono').trim() ||
      'monospace');
  context_exceedance.textBaseline = 'top';
  for (const budget of BUDGETS_EXCEEDANCE) {
    if (!Number.isFinite(budget.milliseconds)) continue;
    const x = Math.round(xOf(budget.milliseconds)) + 0.5;
    context_exceedance.strokeStyle = 'rgba(139, 150, 163, 0.30)';
    context_exceedance.beginPath();
    context_exceedance.moveTo(x, 0);
    context_exceedance.lineTo(x, h);
    context_exceedance.stroke();
    context_exceedance.fillStyle = 'rgba(139, 150, 163, 0.75)';
    context_exceedance.fillText(budget.label, x + 2, 1);
  }
  context_exceedance.setLineDash([]);

  // The curve, in one run per band, each stroked in that band's own colour and each
  //   starting where the last ended so the line is continuous across the change. Drawn
  //   band by band rather than sampling a colour per segment: a run is one path and one
  //   stroke, and the join at a boundary is exact rather than a pixel of the wrong hue.
  context_exceedance.lineWidth = 1.5;
  const last_bucket = Math.min(
    BUCKETS_EXCEEDANCE - 1,
    Math.ceil(MILLISECONDS_AXIS_EXCEEDANCE / MILLISECONDS_BUCKET),
  );
  let band_open = -1;
  for (let i = 0; i <= last_bucket; i += 1) {
    const milliseconds = Math.min(i * MILLISECONDS_BUCKET, MILLISECONDS_AXIS_EXCEEDANCE);
    const band = bandOfExceedance(milliseconds);
    const point = [xOf(milliseconds), yOf(shares_exceedance[i])];
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
  if (band_open >= 0) context_exceedance.stroke();

  // The one number worth stating outright beside the curve: what the slowest frame in a
  //   hundred took. A reader tuning for smoothness is tuning that, not the median.
  let milliseconds_p99 = 0;
  for (let i = BUCKETS_EXCEEDANCE - 1; i >= 0; i -= 1) {
    if (shares_exceedance[i] >= 0.01) { milliseconds_p99 = i * MILLISECONDS_BUCKET; break; }
  }
  diagnostic_exceedance.textContent =
    '1 in 100: ' + milliseconds_p99.toFixed(1) + ' ms \u00b7 ' + counted + ' frames';
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

function refreshDiagnostics() {
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

  const latest = history_frame[(index_history_frame + FRAMES_HISTORY - 1) % FRAMES_HISTORY];
  diagnostic_frame_time.textContent =
    latest.toFixed(2) + ' ms (' + Math.round(1000 / Math.max(latest, 1)) + ' fps)';

  // Each step of the drawing process, as `latest (median)` over the ring: the median is
  // the number a reader can act on, the instantaneous one is what shows a spike as it
  // happens. A phase that has not run yet stays an em dash.
  const index_latest = (index_history_frame + FRAMES_HISTORY - 1) % FRAMES_HISTORY;
  for (const [name] of PHASES_DIAGNOSTIC) {
    if (!isPhaseShown(name)) continue; // Inside a closed node; nobody is reading it.
    const median = medianPhase(name);
    if (median === null) continue;
    let now_phase = history_phase[name][index_latest];
    if (now_phase < 0) now_phase = median; // A phase idle this frame shows its median.
    const tally = name in COUNTS_DIAGNOSTIC ? ' \u00b7 ' + count_phase[name] : '';
    element_phase[name].textContent =
      now_phase.toFixed(2) + ' (' + median.toFixed(2) + ') ms' + tally;
  }

  if (performance.memory) {
    diagnostic_heap.textContent =
      (performance.memory.usedJSHeapSize / (1024 * 1024)).toFixed(1) + ' / ' +
      (performance.memory.jsHeapSizeLimit / (1024 * 1024)).toFixed(0) + ' MB';
  }

  refreshDeliveryReport();

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
const [HEIGHT_MENU_WEDGE, PADDING_MENU_WEDGE, ROUNDING_MENU_WEDGE,
  WIDTH_MENU_WEDGE_BORDER, RADIUS_MENU_CENTRE,
  ALPHA_MENU_WEDGE, ALPHA_MENU_UNOFFERED] = nimMenuMetrics();
// Floats per wedge in nimDragMenuLayout: x, y, offered. The wedge's own colours come from
// `.menu-wedge`, which is `.selection-menu button` -- see shell.html.
const FLOATS_MENU_WEDGE = 3;

function svgEl(tag, attrs) {
  const element = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const k in attrs) element.setAttribute(k, attrs[k]);
  return element;
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
    svg_overlay.appendChild(svgEl('polygon', {
      points: points.join(' '), fill: fill, stroke: 'none',
    }));
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
    // A frame is a closed polyline too -- a circle while it expands, the screen's own
    // rectangle once it arrives -- so it strokes through the very same element a plane's
    // loop does rather than through a <rect> of its own: one path for every closed
    // outline, and nothing to keep in step when one of them changes.
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
      svg_overlay.appendChild(svgEl('line', {
        x1: sx, y1: sy, x2: cursor.x, y2: cursor.y,
        stroke: stroke, 'stroke-width': WIDTH_OVERLAY_LINE,
      }));
      // Which way round the pair is being taken: the band swelling into its own last
      // stretch, the same shape the orientation pulse wears. Shaped by `marker.cometFor`
      // across the bridge rather than worked out here -- the band's direction is the
      // gesture's own business, and this layer fills what it is handed. Empty while the
      // cursor rests on its own source, which points nowhere.
      const comet = nimDragComet(w, h);
      if (comet.length) {
        const points = [];
        for (let i = 0; i + 1 < comet.length; i += 2) points.push(comet[i] + ',' + comet[i + 1]);
        svg_overlay.appendChild(svgEl('polygon', {
          points: points.join(' '), fill: stroke, stroke: 'none',
        }));
      }
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
    const [x, y] = [layout[at], layout[at + 1]];
    const is_offered = layout[at + 2] > 0.5;
    // Label first, then a rect sized from what the browser actually laid it out as --
    // measured rather than estimated from a character count, which drifts the moment the
    // face loaded is not the one the estimate was tuned against.
    const text = svgEl('text', {
      x: x, y: y, 'text-anchor': 'middle', 'dominant-baseline': 'central',
      // An unoffered wedge is dimmed rather than dropped: a gap where a wedge should be is
      // unreadable, and the point of a fixed compass is that a choice never moves.
      'fill-opacity': is_offered ? 1 : 0.6,
      class: i === highlighted ? 'menu-wedge-label on' : 'menu-wedge-label',
    });
    text.textContent = labels[i];
    svg_overlay.appendChild(text);
    const width = text.getBBox().width + PADDING_MENU_WEDGE;
    svg_overlay.insertBefore(svgEl('rect', {
      x: x - width / 2, y: y - HEIGHT_MENU_WEDGE / 2,
      width: width, height: HEIGHT_MENU_WEDGE, rx: ROUNDING_MENU_WEDGE,
      'fill-opacity': is_offered ? ALPHA_MENU_WEDGE : ALPHA_MENU_UNOFFERED,
      'stroke-width': WIDTH_MENU_WEDGE_BORDER,
      class: i === highlighted ? 'menu-wedge on' : 'menu-wedge',
    }), text);
  }
  // The middle is where nothing is chosen, and the way out of a menu that opened unasked.
  svg_overlay.appendChild(svgEl('circle', {
    cx: centre[0], cy: centre[1],
    r: RADIUS_MENU_CENTRE,
    fill: 'none', class: 'menu-centre', 'stroke-width': WIDTH_OVERLAY_LINE,
  }));
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
      // Re-check hover for the drag's own destination preview.
      nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
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
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
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
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
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
  nimCameraDollyAt(
    Math.exp(e.deltaY * 0.0012), canvas.clientWidth, canvas.clientHeight,
  );
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

let count_refresh_ui = 0;

// Draw one frame, and nothing else. Split out of `frame()` so the PNG button can draw and
//   read back **inside its own click**, without also re-running the per-tick simulation that
//   frame() does around it. Mirrors `visualiser.renderFrame`, which is split the same way and
//   for the same reason: the desktop's storyboard capture drives it directly too.
function renderFrame(now_seconds) {
  resize();
  const aspect = canvas.width / canvas.height;

  const data = nimBuildFrame(
    aspect, now_seconds, canvas.height, is_axes_shown, is_grid_shown,
  );
  // The bridge times its own three phases where only it can see them; this side just
  // records what came back, into the same rings its own phases use.
  recordPhaseTime('build', data.ms_build);
  recordPhaseTime('furniture', data.ms_furniture);
  // The scenery's own two halves, which the bridge has clocked apart since the grid's
  //   segment budget went in: the axes are three lines at any distance, the grid however
  //   many the ground reach asks for, and only the split says which of them moved.
  recordPhaseTime('grid', data.ms_grid);
  recordPhaseTime('axes', data.ms_axes);
  recordPhaseTime('scene', data.ms_scene);
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
  gl.uniformMatrix4fv(uniform_view_projection, false, new Float32Array(data.view_projection));

  // World furniture first, with normal depth test/write. Its ribbons already carry their
  // own thinner width as geometry -- there is no width to set here any more. Mirrors
  // renderer.nim's own drawMeshes(MESHES_FURNITURE, ...) call exactly.
  // Kept rather than re-uploaded where the bridge says the furniture is unchanged: the
  // grid and the axes are a function of the camera alone, and rebuilding them for a camera
  // that has not moved is two thirds of a frame spent drawing the same picture. The buffer
  // still holds last frame's vertices, so only the count has to survive here.
  if (!data.is_furniture_held) {
    count_furniture_held = uploadBuffer(data.furn_ribbon_verts, vbo.ribbon_furniture);
  }
  drawRun(vbo.ribbon_furniture, count_furniture_held, gl.TRIANGLES, false, 0, false);

  // Scene objects last; opaque kinds before plane washes (triangles), with depth writes
  // off for those, so a translucent plane never occludes a line or point that happens to
  // sit behind it -- it only tints over whatever was already drawn there. Mirrors
  // renderer.nim's own drawMeshes(MESHES, ...) call exactly.
  gl.uniform1f(uniform_size_point, SIZE_POINT * ratio_pixel);
  const count_ribbon = uploadBuffer(data.ribbon_verts, vbo.ribbon);
  const count_point = uploadBuffer(data.point_verts, vbo.point);
  const count_tri = uploadBuffer(data.tri_verts, vbo.tri);
  drawRun(vbo.ribbon, count_ribbon, gl.TRIANGLES, false, data.ribbon_over, false);
  drawRun(vbo.point, count_point, gl.POINTS, true, data.point_over, false);
  gl.depthMask(false);
  drawRun(vbo.tri, count_tri, gl.TRIANGLES, false, data.tri_over, false);
  gl.depthMask(true);

  // The overlay over all of it, with no depth test at all -- which turns writes off with
  // it, so nothing here occludes anything either. A second pass over every kind rather
  // than a tail on each: a selected line drawn only after the other lines is still tinted
  // by a plane's wash, which is a later kind. Mirrors `renderer.drawMeshes`.
  if (data.ribbon_over + data.point_over + data.tri_over > 0) {
    gl.disable(gl.DEPTH_TEST);
    drawRun(vbo.ribbon, count_ribbon, gl.TRIANGLES, false, data.ribbon_over, true);
    drawRun(vbo.point, count_point, gl.POINTS, true, data.point_over, true);
    drawRun(vbo.tri, count_tri, gl.TRIANGLES, false, data.tri_over, true);
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
  if (nimDragActive()) nimUpdateDrag(now_seconds);

  renderFrame(now_seconds);

  // Immediately after the last draw call and before this callback yields, which is the only
  //   moment the drawing buffer is still there to read; see `captureFrameIfAsked`.
  captureFrameIfAsked();

  const ms_before_overlay = performance.now();
  refreshOverlay(cursor_last);
  const ms_before_menu = performance.now();
  recordPhaseTime('overlay', ms_before_menu - ms_before_overlay);
  updateSelectionMenuPosition();
  recordPhaseTime('menu', performance.now() - ms_before_menu);

  // UI (camera fields, diagnostics) refresh at a lower cadence than the draw loop --
  // no visual harm in a number lagging one frame, and it keeps DOM writes off the hot path.
  count_refresh_ui += 1;
  if (count_refresh_ui >= 6) {
    count_refresh_ui = 0;
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
