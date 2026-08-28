// Drive the built browser page through real events, and assert what they reached.
//
// The suites test the *rules*: what a slide does to a target, what a zoom does to a
// distance. Nothing in them presses a key, turns a wheel or puts two fingers on the canvas,
// so nothing in them can catch a rule wired to the wrong event -- which is how the pinch
// came to zoom at its own midpoint and slide the view with it, with every suite case still
// green. This is the layer that catches that, and it is committed and run by `verify.sh`
// rather than retyped into `/tmp` each time somebody remembers.
//
// Reports every check it makes, pass or fail, and exits non-zero if any failed, exactly as
// `check_palette` does -- one run should say everything that is wrong, not just the first
// thing.
//
// **Timing-dependent quantities are asserted as bands, never as figures.** How far a held
// key travels depends on how many frames the machine drew while it was down. A check written
// against an exact number flakes, and a flaky check gets deleted rather than fixed.
//
// Run:
//   node tools/drive_browser.mjs
// Needs `playwright` resolvable (a global install wants `NODE_PATH`; see
// `dependencies.list`) and a Chromium, which Playwright finds itself unless
// `VISUALISER_CHROMIUM` names one.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require_here = createRequire(import.meta.url);
const { chromium } = require_here('playwright');

const dir_project = join(dirname(fileURLToPath(import.meta.url)), '..');
const url_page = `file://${join(dir_project, 'bin', 'rga_browser.html')}`;

// The viewport the checks below are written against; the wheel check reads an object's own
// pixel out of the page, so nothing here depends on these beyond having room to gesture in.
const SIZE_VIEW = { width: 1200, height: 900 };

let count_failed = 0;

function report(name, is_passing, detail) {
  if (!is_passing) count_failed += 1;
  const mark = is_passing ? '  ok  ' : ' FAIL ';
  console.log(`${mark} ${name}${detail ? ` -- ${detail}` : ''}`);
}

function reportWithin(name, value, low, high, units) {
  report(
    name, value >= low && value <= high,
    `${value.toFixed(3)} ${units}, wanted ${low}..${high}`,
  );
}

const browser = await chromium.launch({
  executablePath: process.env.VISUALISER_CHROMIUM || undefined,
  args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--no-sandbox'],
});
const page = await browser.newPage({ viewport: SIZE_VIEW, hasTouch: true });
const errors_page = [];
page.on('pageerror', (error) => errors_page.push(error.message));
await page.goto(url_page);
await page.waitForTimeout(2000);

// Focused rather than clicked: a click on the canvas selects whatever is under it, the
// standing framing offer then moves the camera on its own, and every reading below would be
// measuring that instead of the gesture under test.
await page.evaluate(() => document.getElementById('gl').focus());

const readCamera = () => page.evaluate(() => ({
  distance: nimCameraDistance(),
  target: nimCameraTarget(),
  azimuth: nimCameraAzimuth(),
}));
const spanTarget = (before, after) => Math.hypot(
  after.target[0] - before.target[0],
  after.target[1] - before.target[1],
  after.target[2] - before.target[2],
);

async function holdKeys(codes, milliseconds) {
  const before = await readCamera();
  for (const code of codes) await page.keyboard.down(code);
  await page.waitForTimeout(milliseconds);
  for (const code of codes) await page.keyboard.up(code);
  await page.waitForTimeout(80);
  return { before, after: await readCamera() };
}

/* ---- Held keys ---- */

const slid = await holdKeys(['KeyW'], 500);
reportWithin('a held key slides the view', spanTarget(slid.before, slid.after), 4, 25, 'units');
report(
  'a slide keeps the height it started at',
  Math.abs(slid.after.target[2] - slid.before.target[2]) < 1e-3,
  `z ${slid.before.target[2].toFixed(4)} -> ${slid.after.target[2].toFixed(4)}`,
);
report(
  'a slide leaves the orbit alone',
  Math.abs(slid.after.azimuth - slid.before.azimuth) < 1e-6 &&
    Math.abs(slid.after.distance - slid.before.distance) < 1e-6,
  'azimuth and distance unchanged',
);

// The release, which nothing watched before this: a key that never comes up moves the camera
// for as long as the page is open.
const at_release = await readCamera();
await page.waitForTimeout(400);
report(
  'releasing a key stops the view',
  spanTarget(at_release, await readCamera()) < 1e-6,
  'still after the release',
);

// A blur mid-hold, whose release is delivered to whoever took the focus rather than here.
await page.keyboard.down('KeyD');
await page.waitForTimeout(150);
await page.evaluate(() => window.dispatchEvent(new Event('blur')));
await page.waitForTimeout(80);
const at_blur = await readCamera();
await page.waitForTimeout(400);
report(
  'a blur mid-hold lets go of everything',
  spanTarget(at_blur, await readCamera()) < 1e-6,
  'still after the blur',
);
await page.keyboard.up('KeyD');

const hastened = await holdKeys(['ShiftLeft', 'KeyW'], 500);
reportWithin(
  'shift moves faster, by about its own factor',
  spanTarget(hastened.before, hastened.after) / Math.max(1e-9, spanTarget(slid.before, slid.after)),
  2.5, 5.5, 'x',
);

const turned = await holdKeys(['ArrowRight'], 300);
report(
  'an arrow orbits rather than sliding',
  Math.abs(turned.after.azimuth - turned.before.azimuth) > 0.05 &&
    spanTarget(turned.before, turned.after) < 1e-6,
  `azimuth by ${(turned.after.azimuth - turned.before.azimuth).toFixed(3)} rad, target still`,
);

/* ---- The wheel ---- */

// Back to the opening placement first, through the key that means it, so the wheel checks
// below start from a known camera and `home` is itself checked on the way.
await page.keyboard.press('Home');
await page.waitForTimeout(120);
const homed = await readCamera();
report(
  'home returns the camera to where it opened',
  Math.abs(homed.distance - 19) < 1e-6 && Math.abs(homed.target[0]) < 1e-6 &&
    Math.abs(homed.target[1]) < 1e-6 && Math.abs(homed.target[2] - 1) < 1e-6,
  `distance ${homed.distance.toFixed(3)}, ` +
    `target ${homed.target.map((v) => v.toFixed(3)).join(', ')}`,
);

const pixelOf = (slot) => page.evaluate((s) => {
  const at = nimAnchorScreen(s, window.innerWidth, window.innerHeight);
  return at && at.length ? [at[0], at[1]] : null;
}, slot);
const slots = await page.evaluate(() => nimSceneSlots());
const slot_aimed = slots[slots.length - 1];
const pixel_before = await pixelOf(slot_aimed);
const wheel_before = await readCamera();

await page.mouse.move(pixel_before[0], pixel_before[1]);
for (let i = 0; i < 8; i += 1) { await page.mouse.wheel(0, -120); await page.waitForTimeout(40); }
await page.waitForTimeout(300);
const pixel_after = await pixelOf(slot_aimed);
const wheel_in = await readCamera();
report(
  'the wheel actually zooms',
  wheel_in.distance < wheel_before.distance * 0.6,
  `distance ${wheel_before.distance.toFixed(2)} -> ${wheel_in.distance.toFixed(2)}`,
);
reportWithin(
  'what the pointer is over stays under the pointer',
  Math.hypot(pixel_after[0] - pixel_before[0], pixel_after[1] - pixel_before[1]),
  0, 12, 'px',
);

for (let i = 0; i < 8; i += 1) { await page.mouse.wheel(0, 120); await page.waitForTimeout(40); }
await page.waitForTimeout(300);
const wheel_out = await readCamera();
report(
  'a wheel notch each way is a round trip',
  Math.abs(wheel_out.distance - wheel_before.distance) < 1e-3 &&
    spanTarget(wheel_before, wheel_out) < 1e-3,
  `distance ${wheel_out.distance.toFixed(3)}, target moved ` +
    `${spanTarget(wheel_before, wheel_out).toFixed(4)}`,
);

/* ---- The pinch ---- */

// Playwright's own touch API is single-touch, so the two fingers go through CDP directly.
const cdp = await page.context().newCDPSession(page);
const touch = (type, points) => cdp.send('Input.dispatchTouchEvent', {
  type,
  touchPoints: points.map((point, index) => ({ x: point.x, y: point.y, id: index })),
});

async function pinch(mid_from, mid_to, spread_from, spread_to) {
  await touch('touchStart', [
    { x: mid_from.x - spread_from, y: mid_from.y }, { x: mid_from.x + spread_from, y: mid_from.y },
  ]);
  for (let step = 1; step <= 8; step += 1) {
    const spread = spread_from + ((spread_to - spread_from) * step) / 8;
    const mid = {
      x: mid_from.x + ((mid_to.x - mid_from.x) * step) / 8,
      y: mid_from.y + ((mid_to.y - mid_from.y) * step) / 8,
    };
    await touch('touchMove', [
      { x: mid.x - spread, y: mid.y }, { x: mid.x + spread, y: mid.y },
    ]);
    await page.waitForTimeout(25);
  }
  await touch('touchEnd', []);
  await page.waitForTimeout(200);
}

// Well off centre, which is where an aimed zoom shows itself: the midpoint never moves, so a
// pinch that also translated the view would drag it toward that corner.
const mid_pinch = { x: 300, y: 300 };
const pinch_before = await readCamera();
await pinch(mid_pinch, mid_pinch, 40, 160);
const pinch_after = await readCamera();
report(
  'a pinch zooms',
  pinch_after.distance < pinch_before.distance * 0.6,
  `distance ${pinch_before.distance.toFixed(2)} -> ${pinch_after.distance.toFixed(2)}`,
);
// The residue is the two-finger pan's own: the midpoint sits between one finger's new
// position and the other's old one for the moment between their two `pointermove` events.
// Aimed at its midpoint instead, this same gesture dragged the view 11.4 units.
reportWithin(
  'a pinch whose middle stays put does not slide the view',
  spanTarget(pinch_before, pinch_after), 0, 0.5, 'units',
);

const panned_before = await readCamera();
await pinch({ x: 300, y: 300 }, { x: 700, y: 600 }, 90, 100);
const panned_after = await readCamera();
report(
  'a pinch whose middle travels still pans',
  spanTarget(panned_before, panned_after) > 0.5,
  `target moved ${spanTarget(panned_before, panned_after).toFixed(3)} units`,
);

/* ---- Touch, the way a finger uses this ---- */

// Gestures the suites cannot reach and nothing committed has ever checked: they live in
// `glue.js`'s pointer handling, which is where the pinch regression lived too.
const touchAt = (type, points) => touch(type, points);
async function tapAt(x, y, milliseconds = 60) {
  await touchAt('touchStart', [{ x, y }]);
  await page.waitForTimeout(milliseconds);
  await touchAt('touchEnd', []);
  await page.waitForTimeout(250);
}

await page.keyboard.press('Home');
await page.waitForTimeout(150);
await page.evaluate(() => nimSelectClear());
const slots_scene = await page.evaluate(() => nimSceneSlots());
const pixel_first = await pixelOf(slots_scene[1]);
const pixel_second = await pixelOf(slots_scene[2]);

// A long press is the only way a finger has to start a selection; `SECONDS_HOLD_SELECT`
// decides when, so hold well past it.
await tapAt(pixel_first[0], pixel_first[1], 1400);
report(
  'a long press selects what it is over',
  (await page.evaluate(() => nimSelectionCount())) === 1,
  `${await page.evaluate(() => nimSelectionCount())} selected`,
);

await tapAt(pixel_second[0], pixel_second[1]);
report(
  'a tap toggles a second object into the selection',
  (await page.evaluate(() => nimSelectionCount())) === 2,
  `${await page.evaluate(() => nimSelectionCount())} selected`,
);

await tapAt(40, SIZE_VIEW.height - 40);
report(
  'a tap on empty space clears the selection',
  (await page.evaluate(() => nimSelectionCount())) === 0,
  `${await page.evaluate(() => nimSelectionCount())} selected`,
);

// Two fingers moving together, at a fixed separation: a pan and only a pan.
await page.keyboard.press('Home');
await page.waitForTimeout(150);
const dragged_before = await readCamera();
await pinch({ x: 400, y: 400 }, { x: 700, y: 500 }, 80, 80);
const dragged_after = await readCamera();
report(
  'two fingers moving together pan without zooming',
  spanTarget(dragged_before, dragged_after) > 0.5 &&
    Math.abs(dragged_after.distance - dragged_before.distance) < 1e-6,
  `target moved ${spanTarget(dragged_before, dragged_after).toFixed(3)}, ` +
    `distance ${dragged_after.distance.toFixed(3)}`,
);

// A finger dragging one object onto another builds a third, which is the whole gesture the
// application is about.
await page.keyboard.press('Home');
await page.waitForTimeout(150);
await page.evaluate(() => nimSelectClear());
const count_before_drag = await page.evaluate(() => nimSceneCount());
const from = await pixelOf(slots_scene[1]);
const onto = await pixelOf(slots_scene[2]);
await touchAt('touchStart', [{ x: from[0], y: from[1] }]);
for (let step = 1; step <= 10; step += 1) {
  await touchAt('touchMove', [{
    x: from[0] + ((onto[0] - from[0]) * step) / 10,
    y: from[1] + ((onto[1] - from[1]) * step) / 10,
  }]);
  await page.waitForTimeout(30);
}
await touchAt('touchEnd', []);
await page.waitForTimeout(400);
report(
  'a finger dragging one object onto another builds a third',
  (await page.evaluate(() => nimSceneCount())) === count_before_drag + 1,
  `${await page.evaluate(() => nimSceneCount())} items, was ${count_before_drag}`,
);

// A drag let go of over empty space built nothing and says nothing: the reader can see the
// nothing, and a status line for it fires on every gesture anybody thought better of.
await page.keyboard.press('Home');
await page.waitForTimeout(150);
await page.evaluate(() => {
  nimSelectClear();
  // Cleared, not just hidden: a check that only asked whether the bar is up would pass on
  //   a message that was never dismissed from an earlier gesture.
  const bar = document.getElementById('toast');
  bar.classList.remove('show');
  bar.textContent = '';
});
const from_empty = await pixelOf(slots_scene[1]);
await page.mouse.move(from_empty[0], from_empty[1]);
await page.mouse.down();
await page.mouse.move(SIZE_VIEW.width - 30, SIZE_VIEW.height - 30, { steps: 8 });
await page.mouse.up();
await page.waitForTimeout(300);
const said_on_empty = await page.evaluate(() => ({
  shown: document.getElementById('toast').classList.contains('show'),
  text: document.getElementById('toast').textContent,
}));
report(
  'a drag released over empty space says nothing at all',
  !said_on_empty.shown && said_on_empty.text === '',
  `shown ${said_on_empty.shown}, text ${JSON.stringify(said_on_empty.text)}`,
);

/* ---- Regressions this layer inherited ---- */

// **The apply picker names positions, the scene names slots.** A ghost was once previewed
// from a picker's own position passed straight through as a slot, which is only ever right
// while nothing has been deleted. Checked where positions and slots genuinely differ.
// Deleted the way a reader deletes -- selection, menu, delete -- rather than through the
//   bridge: the operand pickers are rebuilt by the UI action, not by a periodic tick, so a
//   scene changed behind the UI's back is a state no gesture can actually produce.
await page.evaluate(() => {
  const slots = nimSceneSlots();
  selectOnly(slots[0], null);
  refreshSelectionMenu();
  document.getElementById('selection-menu-delete').click();
});
await page.waitForTimeout(250);
const slots_now = await page.evaluate(() => nimSceneSlots());
report(
  'deleting an item leaves the picker positions offset from the scene slots',
  slots_now[0] !== 0,
  `slots ${JSON.stringify(slots_now)}`,
);

await page.click('#btn-drawer');
await page.waitForTimeout(300);
report(
  'the operand pickers follow a scene the reader has just changed',
  await page.evaluate(
    () => document.getElementById('op-first').options.length === nimSceneCount(),
  ),
  `${await page.evaluate(() => document.getElementById('op-first').options.length)} options, ` +
    `${await page.evaluate(() => nimSceneCount())} items`,
);
const count_before_apply = await page.evaluate(() => nimSceneCount());
// Applied twice over: once through the picker, which names *positions*, and once straight
//   through the bridge with the slots those positions stand for. The two build the same
//   object from the same pair, so their drawn anchors coincide -- and would not if the
//   picker's position were passed through as a slot, which is the bug.
const slots_before_apply = await page.evaluate(() => nimSceneSlots());
const applied = await page.evaluate(() => {
  const slots = nimSceneSlots();
  document.getElementById('op-first').value = '0';
  document.getElementById('op-second').value = '1';
  const operation = parseInt(document.getElementById('op-select').value, 10);
  document.getElementById('btn-apply').click();
  return { operation, first: slots[0], second: slots[1] };
});
await page.waitForTimeout(300);
const coefficientsOf = (slot) => page.evaluate((s) => nimItemCoefficients(s), slot);
// The slot a new item lands in is the lowest free one, which after a delete is somewhere in
//   the middle -- "the last slot" is not the newest item and saying so quietly compares the
//   wrong object.
const addedSlot = (before, after) => after.find((slot) => !before.includes(slot));
const slots_after_picker = await page.evaluate(() => nimSceneSlots());
const slot_by_picker = addedSlot(slots_before_apply, slots_after_picker);
await page.evaluate(
  (applied_pair) => nimApplyOperation(
    applied_pair.operation, applied_pair.first, applied_pair.second, performance.now() / 1000,
  ),
  applied,
);
await page.waitForTimeout(300);
const slots_after_bridge = await page.evaluate(() => nimSceneSlots());
const slot_by_bridge = addedSlot(slots_after_picker, slots_after_bridge);
if (slot_by_picker === undefined || slot_by_bridge === undefined) {
  // Reading a position as a slot names a slot that was freed by the delete above, and
  //   applying to a dead operand builds nothing at all -- so this is the shape the
  //   regression takes here, and it is reported rather than thrown over.
  report(
    'apply builds from the operands its pickers name, not from their positions', false,
    `the picker built ${slot_by_picker === undefined ? 'nothing' : 'slot ' + slot_by_picker}` +
      `, the bridge ${slot_by_bridge === undefined ? 'nothing' : 'slot ' + slot_by_bridge}`,
  );
} else {
  // Compared by their own coefficients rather than by where they are drawn: the operation
  //   the picker happens to default to may be one whose result stands at the horizon, and a
  //   horizon object has no drawn anchor to compare.
  const built_by_picker = await coefficientsOf(slot_by_picker);
  const built_by_slot = await coefficientsOf(slot_by_bridge);
  const span_built = Math.max(
    ...built_by_picker.map((value, index) => Math.abs(value - built_by_slot[index])),
  );
  report(
    'apply builds from the operands its pickers name, not from their positions',
    span_built < 1e-9,
    `the two agree to ${span_built.toExponential(1)} across every coefficient`,
  );
}

// **Panning was dead while anything stayed selected**: the standing framing offer re-armed
// every frame and dragged the camera back to where it had aimed. Reported as a touch bug,
// and neither touch- nor browser-specific.
await page.evaluate(() => nimSelectOnly(nimSceneSlots()[0]));
await page.waitForTimeout(700); // Let the framing ease finish before moving by hand.
const panned_selected_before = await readCamera();
await pinch({ x: 400, y: 400 }, { x: 650, y: 520 }, 80, 80);
const panned_selected_at = await readCamera();
await page.waitForTimeout(700);
const panned_selected_after = await readCamera();
report(
  'a pan while a selection stands is not taken back',
  spanTarget(panned_selected_before, panned_selected_at) > 0.3 &&
    spanTarget(panned_selected_at, panned_selected_after) < 0.05,
  `panned ${spanTarget(panned_selected_before, panned_selected_at).toFixed(3)}, ` +
    `then drifted ${spanTarget(panned_selected_at, panned_selected_after).toFixed(4)}`,
);

// **A timeline key did nothing in the frames right after an edit**, because the buttons it
// answers through were refreshed on a low-cadence tick.
const count_before_undo = await page.evaluate(() => nimSceneCount());
await page.evaluate(() => document.getElementById('gl').focus());
await page.keyboard.press('Control+z');
await page.waitForTimeout(250);
report(
  'undo reaches the timeline in the frames right after an edit',
  (await page.evaluate(() => nimSceneCount())) === count_before_undo - 1,
  `${await page.evaluate(() => nimSceneCount())} items, was ${count_before_undo}`,
);

// **WCAG 2.5.7**: every operation the drag reaches is reachable with no dragging at all,
// through selection -> menu -> apply. The route, not the wording. Selected through the
// page's own helpers rather than the bridge, so the menu's view of the selection is the one
// a finger would have left it with.
await page.evaluate(() => {
  const slots = nimSceneSlots();
  selectOnly(slots[0], null);
  toggleSelection(slots[1], null);
});
await page.waitForTimeout(200);
const count_before_menu = await page.evaluate(() => nimSceneCount());
// The menu's apply is press-twice by design: the first press opens the picker beside it,
//   the second commits whatever that picker names.
await page.evaluate(() => document.getElementById('selection-menu-apply').click());
await page.waitForTimeout(200);
await page.evaluate(() => {
  const select = document.getElementById('selection-menu-select');
  select.value = select.options[0].value;
  select.dispatchEvent(new Event('change'));
  document.getElementById('selection-menu-apply').click();
});
await page.waitForTimeout(300);
report(
  'every operation is reachable without dragging at all',
  (await page.evaluate(() => nimSceneCount())) === count_before_menu + 1,
  `${await page.evaluate(() => nimSceneCount())} items, was ${count_before_menu}`,
);

/* ---- A camera gesture is not a hover ---- */

await page.keyboard.press('Home');
// Clear what the checks above left on screen: a selection menu standing over the canvas
//   swallows the pointer moves below, so the application never learns where the cursor is
//   and this section would be measuring the menu rather than the hover rule.
await page.evaluate(() => {
  clearSelection();
  hideSelectionMenu();
  // And the drawer the apply checks opened: it covers the right third of the viewport, so
  //   a pointer move over an object standing there never reaches the canvas at all.
  if (drawer.classList.contains('open')) document.getElementById('btn-drawer').click();
});
await page.waitForTimeout(200);
// Read afresh: the checks above delete and build, so the slot list captured for the touch
//   gestures no longer names what is alive here.
const slots_now_live = await page.evaluate(() => nimSceneSlots());
const slot_swept = slots_now_live[1];
const pixel_swept = await pixelOf(slot_swept);
// An **orbit** drag from empty space, swinging the scene across the pointer. Orbit rather
// than pan because a pan carries the world along with the drag -- what was under the cursor
// stays under it -- while an orbit sweeps objects past a pointer that is also moving, which
// is the case that used to light up a string of them. Every step is sampled, not just the
// end: one frame of highlight is one too many.
await page.mouse.move(80, SIZE_VIEW.height - 80);
await page.mouse.down();
let hovered_while_moving = -1;
for (let step = 1; step <= 10; step += 1) {
  await page.mouse.move(
    80 + ((pixel_swept[0] - 80) * step) / 10,
    SIZE_VIEW.height - 80 + ((pixel_swept[1] - (SIZE_VIEW.height - 80)) * step) / 10,
  );
  await page.evaluate(() => nimUpdateHover(window.innerWidth, window.innerHeight));
  const slot = await page.evaluate(() => nimHoverSlot());
  if (slot >= 0) hovered_while_moving = slot;
  await page.waitForTimeout(20);
}
await page.mouse.up();
await page.waitForTimeout(150);
report(
  'a camera drag sweeping over objects highlights none of them',
  hovered_while_moving < 0,
  `slot hovered mid-gesture: ${hovered_while_moving}`,
);
// Onto where that object stands *now* -- the pan moved the world under the pointer, so its
// old pixel holds nothing any more, and asking there would say nothing about the rule.
const pixel_settled = await pixelOf(slot_swept);
await page.mouse.move(pixel_settled[0], pixel_settled[1]);
await page.evaluate(() => nimUpdateHover(window.innerWidth, window.innerHeight));
report(
  'the highlight comes back the moment the gesture ends',
  (await page.evaluate(() => nimHoverSlot())) >= 0,
  `hovering slot ${await page.evaluate(() => nimHoverSlot())} after the release`,
);

/* ---- The help stays open, and lists the catalogue ---- */

await page.evaluate(() => showHelp(true));
await page.waitForTimeout(200);
await page.mouse.click(SIZE_VIEW.width / 2, SIZE_VIEW.height - 80);
await page.waitForTimeout(200);
await page.click('#btn-drawer');
await page.waitForTimeout(200);
report(
  'the help stays open while the reader uses what it describes',
  await page.evaluate(() => document.getElementById('help-panel').classList.contains('show')),
  'still open after a click on the canvas and on the drawer',
);

const rows_catalogue = await page.evaluate(() => {
  // The tab strip names its tabs; open the catalogue one and count what it renders.
  const tab = [...document.querySelectorAll('#help-tabs button')]
    .find((button) => button.textContent.trim() === 'operations');
  if (!tab) return -1;
  tab.click();
  // Every path's rows live in the one box, shown and hidden by tab; count this tab's own.
  return document.querySelectorAll('#help-rows .help-row[data-path="operations"]').length;
});
report(
  'the help lists every operation the build offers',
  rows_catalogue === (await page.evaluate(() => nimOperationCount())),
  `${rows_catalogue} rows, ${await page.evaluate(() => nimOperationCount())} operations`,
);

await page.click('#help-close');
await page.waitForTimeout(200);
report(
  'the help closes when the reader closes it',
  !(await page.evaluate(
    () => document.getElementById('help-panel').classList.contains('show'),
  )),
  'closed by its own button',
);

/* ---- A horizon line's comet runs where a reader can see it ---- */

// The fault: a horizon line's marker is two circles on the sky running out to the line's
// own vanishing points, and an uncut one laps in hundreds of thousands of pixels of
// outline no camera can show. The comet, travelling at a fixed screen pace, was then off
// screen for all but a few frames in a thousand -- "the comet does not work on horizon
// lines". Driven rather than reasoned: this reads what the page would actually stroke.
await page.evaluate(() => showHelp(false));
await page.keyboard.press('Home');
await page.waitForTimeout(150);
const slot_horizon = await page.evaluate(() => {
  const plane = nimSceneSlots().find((slot) => nimItemShapeWord(slot) === 'plane');
  if (plane === undefined) return null;
  const before = nimSceneSlots();
  // `Attitude` is the catalogue's own first operation, and a plane's attitude is the
  //   pencil of directions lying in it -- a line at horizon.
  nimApplyOperation(0, plane, plane, performance.now() / 1000);
  const built = nimSceneSlots().find((slot) => !before.includes(slot));
  // Level with the ground, so the sky the bands wrap is in front of the camera rather
  //   than above the top edge of it.
  nimSetCameraElevation(0.0);
  nimSelectClear();
  selectOnly(built, null);
  return built === undefined ? null : built;
});
const insideCanvas = (points) => page.evaluate((given) => {
  const canvas = document.getElementById('gl');
  return given.every(
    ([x, y]) => x >= -1 && y >= -1 &&
      x <= canvas.clientWidth + 1 && y <= canvas.clientHeight + 1,
  );
}, points);
const headOf = () => page.evaluate((slot) => {
  const canvas = document.getElementById('gl');
  const flat = nimSelectionPulse(slot, canvas.clientWidth, canvas.clientHeight, 1, false, 0);
  if (flat.length === 0 || flat[0] < 1) return null;
  return [flat[2], flat[3]];
}, slot_horizon);
const marker_horizon = slot_horizon === null ? { kind: -1, points: [] } : await page.evaluate(
  (slot) => {
    const canvas = document.getElementById('gl');
    const flat = nimSelectionMarker(
      slot, canvas.clientWidth, canvas.clientHeight, 1, false, 0,
    );
    const points = [];
    for (let i = 4; i + 1 < flat.length; i += 2) points.push([flat[i], flat[i + 1]]);
    return { kind: flat.length === 0 ? -1 : flat[0], points };
  },
  slot_horizon,
);
// The page's own mirror of `marker.MarkerKind`, read from it rather than copied here.
const kind_bands = await page.evaluate(() => MARKER_BANDS);
report(
  'a plane\'s attitude is drawn as bands the window itself bounds',
  marker_horizon.kind === kind_bands && marker_horizon.points.length > 0 &&
    (await insideCanvas(marker_horizon.points)),
  `kind ${marker_horizon.kind}, ${marker_horizon.points.length} points`,
);

const head_first = await headOf();
await page.waitForTimeout(500);
const head_second = await headOf();
const travelled = head_first === null || head_second === null
  ? -1
  : Math.hypot(head_second[0] - head_first[0], head_second[1] - head_first[1]);
report(
  'its comet is on screen and travelling along it',
  head_first !== null && head_second !== null &&
    (await insideCanvas([head_first, head_second])),
  `head ${JSON.stringify(head_first)} then ${JSON.stringify(head_second)}`,
);
// Half a second at SPEED_MARKER_PULSE is 30 pixels; banded rather than exact, since the
//   page's own frame pacing decides how much of that half second the clock actually saw.
reportWithin('its comet covers a screen pace, not a lap of the sky', travelled, 5, 60, 'px');

/* ---- The ground is still under the camera however far it has pulled back ---- */

// The fault: the fog's reach was capped at 1,200 units, so a camera dollied past that had
// the ground stop reaching what it was looking at, and past twice that met a black void
// with no reference of any kind -- grid, axes and all. Driven through the page's own frame
// build, so what is counted is what would actually be uploaded and drawn.
await page.evaluate(() => { nimSelectClear(); });
await page.keyboard.press('Home');
await page.waitForTimeout(150);
// Grid only, with the axes switched off: three axis lines are drawn by a rule of their
//   own and would keep the count above zero in exactly the case being guarded against.
const groundAt = (distance) => page.evaluate((given) => {
  nimSetCameraDistance(given);
  const canvas = document.getElementById('gl');
  const data = nimBuildFrame(
    canvas.width / canvas.height, performance.now() / 1000, canvas.height, false, true,
  );
  // The distance the frame was actually built at, not the one asked for: the camera can
  //   be mid-tween toward a framing of the scene, and a count reported against a distance
  //   it was not standing at says nothing.
  return { count: data.furn_ribbon_verts.length, distance: nimCameraDistance() };
}, distance);
const ground = {};
for (const distance of [19, 300, 1000, 5000, 40000, 1000000]) {
  ground[distance] = await groundAt(distance);
}
report(
  'there is ground under the camera at every distance it can reach',
  Object.values(ground).every((at) => at.count > 0),
  Object.values(ground)
    .map((at) => `${at.distance.toFixed(0)}: ${at.count}`).join(', '),
);
// The cell steps by decades to keep that true, so what is drawn stays inside the budget
//   the fixed cell was bounded by rather than growing with the reach.
report(
  'and no more of it is drawn far out than close in',
  Math.max(...Object.values(ground).map((at) => at.count)) <= 1.1 * ground[300].count,
  `most ${Math.max(...Object.values(ground).map((at) => at.count))}, ` +
    `at 300 ${ground[300].count}`,
);
await page.keyboard.press('Home');
await page.waitForTimeout(150);

/* ---- Nothing may have thrown along the way ---- */

report('the page raised no errors', errors_page.length === 0, errors_page.join('; '));

await browser.close();
console.log(
  count_failed === 0
    ? '\nEvery driven check passed.'
    : `\n${count_failed} driven check(s) failed.`,
);
process.exit(count_failed === 0 ? 0 : 1);
