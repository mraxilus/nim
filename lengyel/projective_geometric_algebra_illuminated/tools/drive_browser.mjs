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

// Panels an earlier check opened sit *over* the canvas and swallow every pointer event, so
//   a gesture driven at a pixel beneath one never reaches the application at all. **The
//   drawer opens on the left**, the side the desktop's own panel occupies, which is the
//   side most of the gestures below start from -- so every section that drives the canvas
//   clears the glass first rather than trusting the pixels it aims at to be canvas.
async function clearTheGlass() {
  await page.evaluate(() => {
    clearSelection();
    hideSelectionMenu();
    if (drawer.classList.contains('open')) document.getElementById('btn-drawer').click();
  });
  await page.waitForTimeout(200);
}

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
// The object standing furthest from every other on screen, rather than whichever slot
//   happens to be last. A zoom aims at what `picking.pickNearest` finds under the pointer
//   and ranks a point above a plane, so a pointer over two overlapping objects anchors on
//   the thinner one -- and this check would then be measuring the object it did not aim
//   at. The opening scene has a point sitting 13 px from the ground plane's own drawn
//   anchor, which is exactly that case.
const slots = await page.evaluate(() => nimSceneSlots());
const anchors = [];
for (const slot of slots) anchors.push({ slot, at: await pixelOf(slot) });
const alone = anchors
  .filter((one) => one.at !== null)
  .map((one) => ({
    slot: one.slot,
    apart: Math.min(...anchors
      .filter((other) => other.slot !== one.slot && other.at !== null)
      .map((other) => Math.hypot(one.at[0] - other.at[0], one.at[1] - other.at[1]))),
  }))
  .sort((a, b) => b.apart - a.apart)[0];
const slot_aimed = alone.slot;
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
// Exact, not merely close: the zoom anchors on the very object the pointer is over, so
//   the pixel it was on is the pixel it stays on. Measured at 0.000 px across eight
//   notches; it was 1.957 while the anchor was a plane through the camera's own target.
reportWithin(
  'what the pointer is over stays under the pointer',
  Math.hypot(pixel_after[0] - pixel_before[0], pixel_after[1] - pixel_before[1]),
  0, 1, 'px',
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

// **Read the second object's pixel afresh, after the ease.** Picking turns the orbit about
//   what was picked, so the view is still gliding when the press above lets go and every
//   other object is somewhere new by the time it settles. A pixel read before the first
//   press names where the second object *was*.
await settleCamera();
const pixel_second_now = await pixelOf(slots_scene[2]);
await tapAt(pixel_second_now[0], pixel_second_now[1]);
report(
  'a tap toggles a second object into the selection',
  (await page.evaluate(() => nimSelectionCount())) === 2,
  `${await page.evaluate(() => nimSelectionCount())} selected`,
);

await settleCamera();
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
// A pan slides the view across a level, so the orbit centre keeps its height exactly. It
// used to slide within the plane facing the eye, which is tilted: a drag up the screen
// lifted the target off the ground -- driven at z 1.00 -> 6.40 -- and every later orbit
// then swung about a point in mid-air.
report(
  'and without lifting the orbit centre off the level it was on',
  Math.abs(dragged_after.target[2] - dragged_before.target[2]) < 1e-6,
  `target height ${dragged_before.target[2].toFixed(3)} -> ` +
    `${dragged_after.target[2].toFixed(3)}`,
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

// The same gesture as a finger actually performs it: pause over the target to aim before
// lifting. The dwell wheel opens under the finger during that pause -- hidden by it -- and
// once read the release as "chose nothing", so exactly the careful drags built nothing.
// A wheel nobody entered may not veto the release: it takes the pair's own answer, as the
// quick lift above does. The check first holds that the wheel really did open, so a slower
// dwell could never turn this into a second copy of the quick-lift check.
await page.keyboard.press('Home');
await page.waitForTimeout(150);
await page.evaluate(() => nimSelectClear());
const count_before_pause = await page.evaluate(() => nimSceneCount());
const from_pause = await pixelOf(slots_scene[1]);
const onto_pause = await pixelOf(slots_scene[2]);
await touchAt('touchStart', [{ x: from_pause[0], y: from_pause[1] }]);
for (let step = 1; step <= 10; step += 1) {
  await touchAt('touchMove', [{
    x: from_pause[0] + ((onto_pause[0] - from_pause[0]) * step) / 10,
    y: from_pause[1] + ((onto_pause[1] - from_pause[1]) * step) / 10,
  }]);
  await page.waitForTimeout(30);
}
await page.waitForTimeout(1100); // Past SECONDS_DWELL_MENU, as a finger pausing to aim is.
const is_wheel_open_paused = await page.evaluate(() => nimDragMenuOpen());
await touchAt('touchEnd', []);
await page.waitForTimeout(400);
report(
  'a paused finger still builds on lifting, through the wheel its pause opened',
  is_wheel_open_paused &&
    (await page.evaluate(() => nimSceneCount())) === count_before_pause + 1,
  `wheel open ${is_wheel_open_paused}; ` +
    `${await page.evaluate(() => nimSceneCount())} items, was ${count_before_pause}`,
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

// **The orbit turns about what is picked.** Turning about a point is what an orbit is, so
// a reader who picks objects and turns means to turn about those -- and framing used to
// leave the target wherever it was whenever everything picked was already on screen, which
// swung the picked object around the view instead. Held end to end: one pick lands the
// target on that object, a second lands it on the middle of the two, and the reader's own
// distance and orbit are untouched throughout.
await clearTheGlass();
await page.keyboard.press('Home');
await settleCamera();
const placeOfSlot = (slot) => page.evaluate((s) => {
  const c = Array.from(nimItemCoefficients(s));
  return [c[1] / c[4], c[2] / c[4], c[3] / c[4]];
}, slot);
const points_pickable = await page.evaluate(() => nimSceneSlots()
  .filter((slot) => nimItemShapeWord(slot) === 'point'));
const camera_before_pick = await readCamera();
await page.evaluate((slot) => nimSelectOnly(slot), points_pickable[0]);
await page.waitForTimeout(700);
const centred_one = await readCamera();
const place_one = await placeOfSlot(points_pickable[0]);
await page.evaluate((slot) => nimSelectToggle(slot), points_pickable[1]);
await page.waitForTimeout(700);
const centred_two = await readCamera();
const place_two = await placeOfSlot(points_pickable[1]);
const middle_two = place_one.map((v, i) => (v + place_two[i]) / 2);
const spanOf = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
report(
  'picking an object turns the orbit about it, and a pair about their middle',
  spanOf(centred_one.target, place_one) < 0.01 &&
    spanOf(centred_two.target, middle_two) < 0.01,
  `one pick -> ${centred_one.target.map((v) => v.toFixed(2))} ` +
    `(object at ${place_one.map((v) => v.toFixed(2))}); ` +
    `two -> ${centred_two.target.map((v) => v.toFixed(2))} ` +
    `(middle ${middle_two.map((v) => v.toFixed(2))})`,
);
report(
  'and re-centring alone never touches the reader\'s distance or orbit',
  Math.abs(centred_two.distance - camera_before_pick.distance) < 1e-6 &&
    Math.abs(centred_two.azimuth - camera_before_pick.azimuth) < 1e-6,
  `distance ${camera_before_pick.distance.toFixed(3)} -> ` +
    `${centred_two.distance.toFixed(3)}, azimuth ` +
    `${camera_before_pick.azimuth.toFixed(4)} -> ${centred_two.azimuth.toFixed(4)}`,
);

// **Panning was dead while anything stayed selected**: the standing framing offer re-armed
// every frame and dragged the camera back to where it had aimed. Reported as a touch bug,
// and neither touch- nor browser-specific.
// The pinch below starts at x=400, the drawer's own right edge once it is open on the
//   left, so the glass is cleared before the selection this check needs is made.
await clearTheGlass();
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
// Clear what the checks above left on screen, or this section measures the menu and the
//   drawer rather than the hover rule.
await clearTheGlass();
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

/* ---- A mouse pan grabs the level, and keeps its height ---- */

// The drag below starts at x=160, which is drawer once the drawer is open -- and it opens
//   on the left. Clear the glass first, or this measures a panel swallowing the press.
await clearTheGlass();
await page.evaluate(() => { nimSelectClear(); document.getElementById('gl').focus(); });
await page.keyboard.press('Home');
await page.waitForTimeout(900);
const pan_before = await readCamera();
// Started well clear of every object, so the right button pans rather than arming a drag,
// and dragged up the screen -- the direction that used to lift the target.
await page.mouse.move(160, 170);
await page.mouse.down({ button: 'right' });
await page.mouse.move(360, 470, { steps: 12 });
await page.mouse.up({ button: 'right' });
await page.waitForTimeout(250);
const pan_after = await readCamera();
report(
  'a right-button drag pans, and keeps the orbit centre on its level',
  spanTarget(pan_before, pan_after) > 0.5 &&
    Math.abs(pan_after.target[2] - pan_before.target[2]) < 1e-6 &&
    Math.abs(pan_after.distance - pan_before.distance) < 1e-6,
  `target moved ${spanTarget(pan_before, pan_after).toFixed(3)}, height ` +
    `${pan_before.target[2].toFixed(3)} -> ${pan_after.target[2].toFixed(3)}`,
);

/* ---- A zoom aims at what the pointer is over, and settles the target onto it ---- */

// Anchored on a plane through the target, a zoom left the orbit centre stranded on the
// level it started at however far the reader went in -- "the target gets away from what
// I'm looking at". Anchored on the object or the ground under the pointer, it comes down
// onto what is being zoomed into.
// The canvas has to hold focus for a key to reach the view at all: the help's own close
//   button took it a few checks ago, and a Home pressed into a button moves nothing.
await page.evaluate(() => { nimSelectClear(); document.getElementById('gl').focus(); });
await page.keyboard.press('Home');
// Long enough for the camera's own tween home to settle: a height read mid-flight is not
//   the height this check means to zoom away from.
await page.waitForTimeout(900);
const before_aim = await readCamera();
// Low in the frame, where the sight ray reaches the ground well in front of the camera.
await page.mouse.move(SIZE_VIEW.width / 2, SIZE_VIEW.height - 200);
for (let notch = 0; notch < 8; notch += 1) {
  await page.mouse.wheel(0, -120);
  await page.waitForTimeout(40);
}
const after_aim = await readCamera();
report(
  'zooming in over the ground brings the orbit centre down onto it',
  before_aim.target[2] > 0.9 &&
    after_aim.target[2] < before_aim.target[2] - 0.2 && after_aim.target[2] > -0.5,
  `target height ${before_aim.target[2].toFixed(2)} -> ${after_aim.target[2].toFixed(2)}, ` +
    `distance ${after_aim.distance.toFixed(2)}`,
);

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

/* ---- The draw loop's own work fits inside a frame ---- */

// The reader's complaint was an erratic frame time jumping between 30 and 60. A browser
// page cannot draw faster than the compositor presents -- `requestAnimationFrame` is the
// only honest loop and it is paced by the display -- so "uncapped" is not a thing to reach
// for; what makes the cadence even is every frame's work fitting inside the budget.
// Measured here is the part this page owns, not the wall clock: the machine running these
// checks renders through a software GL, so its frame times say more about swiftshader than
// about anything in this repository.
await page.evaluate(() => { nimSelectClear(); document.getElementById('gl').focus(); });
await page.keyboard.press('Home');
await page.waitForTimeout(600);
await page.evaluate(() => {
  window.__work_frame = [];
  window.__held_frame = 0;
  window.__phase_frame = [];
  const built = globalThis.nimBuildFrame;
  globalThis.nimBuildFrame = function (...given) {
    const started = performance.now();
    const data = built.apply(this, given);
    window.__work_frame.push(performance.now() - started);
    if (data.is_furniture_held) window.__held_frame += 1;
    window.__phase_frame.push({
      build: data.ms_build, furniture: data.ms_furniture,
      scene: data.ms_scene, flatten: data.ms_flatten,
      grid: data.ms_grid, axes: data.ms_axes, segments: data.count_grid_segments,
      points: data.ms_points, lines: data.ms_lines, planes: data.ms_planes,
      sky: data.ms_sky, ghost: data.ms_ghost, selected: data.ms_selected,
      count_points: data.count_points, count_lines: data.count_lines,
      count_planes: data.count_planes, count_sky: data.count_sky,
      count_ghost: data.count_ghost, count_selected: data.count_selected,
      wall: window.__work_frame[window.__work_frame.length - 1],
    });
    return data;
  };
});
await page.waitForTimeout(2500);
const work_frame = await page.evaluate(() => {
  const sorted = [...window.__work_frame].sort((a, b) => a - b);
  const at = (share) => sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))];
  return sorted.length === 0 ? null : {
    n: sorted.length, median: at(0.5), p90: at(0.9), max: sorted[sorted.length - 1],
    held: window.__held_frame,
  };
});
report(
  'the draw loop keeps building frames',
  work_frame !== null && work_frame.n > 30,
  `${work_frame === null ? 0 : work_frame.n} frames sampled`,
);
// Bands rather than figures: this is a real machine's real clock. The numbers that matter
// are the measurements recorded in PROVENANCE.md's bottleneck ledger, taken on this same
// software renderer.
// These two bands grew (16/24 -> 18/30) with the tessellation-stepping row of the
// bottleneck ledger: the scene's own objects now assemble every point through the
// algebra and rebuild every frame with no cache, which is the stress the project exists
// to apply. The bands still catch the collapse class a reader felt.
reportWithin(
  'a frame is assembled in a fraction of its own budget',
  work_frame === null ? -1 : work_frame.median, 0, 18, 'ms',
);
reportWithin(
  'and its slowest tenth stays inside one',
  work_frame === null ? -1 : work_frame.p90, 0, 30, 'ms',
);

/* ---- The diagnostics tab's own phase clocks tell the truth ---- */

// The bridge reports each step of its own build -- scenery, scene objects, flatten -- and
// those steps have to (a) be populated, (b) sum to no more than the whole they are steps
// of, and (c) agree with a wall clock held around the call from outside. Bands generous:
// performance.now() is sub-ms quantised and this container is slow.
const phases = await page.evaluate(() => window.__phase_frame.slice(2));
const sane = phases.filter((p) =>
  p.build > 0 && p.scene >= 0 && p.furniture >= 0 && p.flatten >= 0 &&
  p.furniture + p.scene + p.flatten <= p.build + 1.0 && p.build <= p.wall + 1.0);
report(
  'the build reports its phases, and they add up',
  phases.length > 30 && sane.length === phases.length,
  `${sane.length} of ${phases.length} frames consistent`,
);
// And the drawer's rows actually render them, so a reader can see each step live. The
// **tree starts wholly closed** -- a reader opens this panel to learn whether a frame is
// slow, and goes looking for which step only once it is -- so the subtotals under `build`
// are checked to be idle first, then opened the way a reader opens them, and only then
// checked to be live. Without the first half a tree that never closed would pass.
const rows_closed = await page.evaluate(() => ({
  is_open: document.querySelector('.diag-node[data-node="build"]').classList.contains('open'),
  children: ['furniture', 'scene', 'flatten']
    .map((n) => document.getElementById('diag-' + n).textContent),
}));
report(
  'the frame-time breakdown starts collapsed',
  !rows_closed.is_open && rows_closed.children.every((t) => !/ ms$/.test(t)),
  `node open ${rows_closed.is_open}, children ${JSON.stringify(rows_closed.children)}`,
);
await page.evaluate(() =>
  document.querySelector('.diag-node[data-node="build"] .diag-parent').click());
await page.waitForTimeout(400);
const row_texts = await page.evaluate(() => Object.fromEntries(
  ['build', 'furniture', 'scene', 'flatten', 'upload', 'overlay', 'menu', 'ui']
    .map((n) => [n, document.getElementById('diag-' + n).textContent])
));
report(
  'every drawing step has a live row once its branch is opened',
  Object.values(row_texts).every((t) => / ms$/.test(t)),
  Object.entries(row_texts).map(([n, t]) => `${n}: ${t}`).join(', '),
);

// **A branch opens its own rows and stops there.** `build` is open at this point and
// nothing under it has been touched, so the two nested branches must still be shut: their
// rows out of the layout and their chevrons unturned. This is the check the tree needed
// from the start -- the rules that reveal a branch's children and turn its chevron used a
// descendant combinator, so opening `build` laid the whole tree bare and rotated all three
// chevrons while `isPhaseShown` went on correctly treating the inner nodes as closed and
// never wrote their rows. Every deeper row then sat on screen, apparently expanded, showing
// an em dash for good. Driving every branch open hid it: only opening the outermost one
// does.
// Opened for real first: a chevron's rotation is only resolvable on a rendered element --
//   inside a `display: none` subtree `getComputedStyle().transform` answers `none` whatever
//   the rule says -- and the rows this check is about are written whether or not anyone can
//   see them. Both are put back at the end.
const glass_before = await page.evaluate(() => {
  const drawer = document.querySelector('.drawer');
  const section = document.querySelector('.section[data-section="diagnostics"]');
  const was = { drawer: drawer.classList.contains('open'),
    section: section.classList.contains('open') };
  if (!was.drawer) document.getElementById('btn-drawer').click();
  if (!was.section) section.querySelector('.section-header').click();
  return was;
});
await page.waitForTimeout(500);
const nested = await page.evaluate(() => {
  // Asked of the row's own branch container, not of `offsetParent`: everything in the
  //   drawer sits inside a `position: fixed` ancestor, which makes `offsetParent` null
  //   whatever the branch is doing, so it cannot tell an open branch from a shut one.
  const laid = (id) => getComputedStyle(
    document.getElementById(id).closest('.diag-children')).display !== 'none';
  const turned = (node) => getComputedStyle(document.querySelector(
    '.diag-node[data-node="' + node + '"] > .diag-parent .chev')).transform !== 'none';
  const shut = {
    grid: laid('diag-grid'), points: laid('diag-points'),
    scenery_turned: turned('furniture'), scene_turned: turned('scene'),
  };

  document.querySelector('.diag-node[data-node="scene"] > .diag-parent').click();
  return shut;
});
// Read after the chevron's own 350 ms turn has finished: asked in the same tick as the
//   click, a transition that has not started yet still reports its old transform.
await page.waitForTimeout(700);
const nested_open = await page.evaluate(() => {
  const laid = (id) => getComputedStyle(
    document.getElementById(id).closest('.diag-children')).display !== 'none';
  const turned = (node) => getComputedStyle(document.querySelector(
    '.diag-node[data-node="' + node + '"] > .diag-parent .chev')).transform !== 'none';
  return {
    points: laid('diag-points'), grid: laid('diag-grid'),
    scene_turned: turned('scene'), scenery_turned: turned('furniture'),
    reading: document.getElementById('diag-points').textContent,
  };
});
report(
  'opening a branch reveals its own rows only, and they carry numbers',
  // Shut: neither nested branch is laid out or turned, though their parent is open.
  !nested.grid && !nested.points && !nested.scenery_turned && !nested.scene_turned &&
    // Opened: `scene` alone -- its rows appear and its chevron turns, `scenery` stays shut.
    nested_open.points && nested_open.scene_turned &&
    !nested_open.grid && !nested_open.scenery_turned &&
    / ms/.test(nested_open.reading),
  `with build alone open: grid laid ${nested.grid}, points laid ${nested.points}, ` +
    `chevrons turned ${nested.scenery_turned}/${nested.scene_turned}; after opening scene: ` +
    `points laid ${nested_open.points} turned ${nested_open.scene_turned} reading ` +
    `"${nested_open.reading}", grid laid ${nested_open.grid} turned ` +
    `${nested_open.scenery_turned}`,
);
// `scenery` opened too, for the checks below which read every row; then the drawer and the
// section are put back exactly as this check found them.
await page.evaluate((was) => {
  document.querySelector('.diag-node[data-node="furniture"] > .diag-parent').click();
  const drawer = document.querySelector('.drawer');
  const section = document.querySelector('.section[data-section="diagnostics"]');
  if (drawer.classList.contains('open') !== was.drawer) {
    document.getElementById('btn-drawer').click();
  }
  if (section.classList.contains('open') !== was.section) {
    section.querySelector('.section-header').click();
  }
}, glass_before);
await page.waitForTimeout(400);

// **The frame-time distribution, over a window long enough to hold a rare stall.** The
// sparkline holds four seconds and says *when*; this says *how often*, which is the
// question a reader chasing an occasional stutter is actually asking. Held as the three
// properties that make a curve a distribution rather than a drawing: every frame is at or
// over zero, the share never rises as the duration does, and the buckets account for
// exactly the frames in the window -- plus the stated 1-in-100 agreeing with the same
// percentile taken directly off the ring, which is the arithmetic the buckets stand in for.
const curve = await page.evaluate(() => {
  const counted = scanExceedance();
  let is_monotone = true;
  for (let i = 1; i < BUCKETS_EXCEEDANCE; i += 1) {
    if (shares_exceedance[i] > shares_exceedance[i - 1] + 1e-12) is_monotone = false;
  }
  let held = 0;
  for (let i = 0; i < BUCKETS_EXCEEDANCE; i += 1) held += buckets_exceedance[i];
  // The same percentile, taken the slow honest way off the samples themselves.
  const sorted = Array.from(history_exceedance.slice(0, counted)).sort((a, b) => a - b);
  const direct = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.99))];
  let bucketed = 0;
  for (let i = BUCKETS_EXCEEDANCE - 1; i >= 0; i -= 1) {
    if (shares_exceedance[i] >= 0.01) { bucketed = i * MILLISECONDS_BUCKET; break; }
  }
  const canvas = document.getElementById('exceedance');
  const pixels = canvas.getContext('2d')
    .getImageData(0, 0, canvas.width, canvas.height).data;
  let lit = 0;
  for (let i = 3; i < pixels.length; i += 4) if (pixels[i] > 8) lit += 1;
  return { counted, held, is_monotone, at_zero: shares_exceedance[0], direct, bucketed, lit };
});
report(
  'the frame-time curve is a distribution, and the window accounts for itself',
  curve.counted > 60 && curve.held === curve.counted && curve.is_monotone &&
    Math.abs(curve.at_zero - 1) < 1e-9,
  `${curve.counted} frames, ${curve.held} in buckets, monotone ${curve.is_monotone}, ` +
    `P(at or over 0) = ${curve.at_zero}`,
);
report(
  'and its stated 1-in-100 agrees with the samples it was taken from',
  // Within a bucket and a half: the curve reports the bucket's own lower edge, and the
  //   direct percentile lands anywhere inside that bucket.
  Math.abs(curve.direct - curve.bucketed) <= 1.0 && curve.lit > 200,
  `curve says ${curve.bucketed.toFixed(1)} ms, samples say ${curve.direct.toFixed(1)} ms, ` +
    `${curve.lit} pixels drawn`,
);

// The axis waits before it moves and then glides, so a synthetic window has to be given
// wall-clock time to arrive at it. `recordExceedance` is stubbed while it settles: a real
// frame entering the window mid-settle would change the very extent being waited for, and
// on this container every real frame is slower than anything these checks feed in.
// Held **around** the fill as well as the settle: on this container every real frame is
// slower than anything these checks feed in, so a single one slipping into the window
// between filling it and waiting on it moves the very extent being waited for. Feed through
// `window.__record_kept` while the hold stands.
const holdExceedance = () => page.evaluate(() => {
  if (window.__record_kept === undefined) window.__record_kept = recordExceedance;
  globalThis.recordExceedance = () => {};
});
const releaseExceedance = () => page.evaluate(() => {
  if (window.__record_kept !== undefined) globalThis.recordExceedance = window.__record_kept;
});
const settleAxis = async () => {
  for (let i = 0; i < 48; i += 1) {
    await page.waitForTimeout(120);
    const settled = await page.evaluate(() => {
      drawExceedance();
      return ms_axis_restless === 0;
    });
    if (settled && i > 4) break;
  }
};

// How narrow the axis may get is read **off the page** rather than restated here: a copy
// would pass while the page drifted away from it, which is the one thing these checks exist
// to stop.
const { MILLISECONDS_FLOOR_DRAWN } = await page.evaluate(() => ({
  MILLISECONDS_FLOOR_DRAWN: MILLISECONDS_AXIS_LEAST,
}));
// How deep a band at each end to look in for a mark's own labels. **This check's own
// sampling window, not a copy of anything the page declares** -- the rates and durations are
// drawn over the plot rather than in rows of their own, so there is no page-side row height
// to read. Comfortably more than the 9px line they are set in, and comfortably less than the
// canvas, which is all it has to be.
const ROW_LABEL_DRAWN = 11;

// **The curve is drawn in the colour of the budget each part of it sits inside**, and the
// axis it is drawn against is fixed rather than fitted. Every frame this container draws is
// slower than 30 fps, so the fast bands cannot be reached by driving the page harder; the
// window is fed a spread through `recordExceedance` -- the very call the frame loop makes
// -- which exercises the drawing without pretending the machine is faster than it is.
await holdExceedance();
await page.evaluate(() => {
  for (let i = 0; i < 3000; i += 1) {
    const roll = Math.random();
    window.__record_kept(roll < 0.7 ? 5 + Math.random() * 3
      : roll < 0.92 ? 9 + Math.random() * 7
      : roll < 0.99 ? 17 + Math.random() * 15 : 34 + Math.random() * 40);
  }
});
await settleAxis();
const bands = await page.evaluate(() => {
  const canvas = document.getElementById('exceedance');
  const pixels = canvas.getContext('2d')
    .getImageData(0, 0, canvas.width, canvas.height).data;
  const counted = new Map();
  for (let i = 0; i < pixels.length; i += 4) {
    if (pixels[i + 3] < 200) continue;
    counted.set(`${pixels[i]},${pixels[i + 1]},${pixels[i + 2]}`,
      (counted.get(`${pixels[i]},${pixels[i + 1]},${pixels[i + 2]}`) || 0) + 1);
  }
  // The tokens the stylesheet sets, as the canvas would have written them.
  const wanted = ['--speed-fast', '--speed-good', '--speed-fair', '--speed-poor'].map((t) => {
    const hex = getComputedStyle(document.documentElement).getPropertyValue(t).trim();
    return [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16)).join(',');
  });
  return {
    drawn: wanted.filter((rgb) => (counted.get(rgb) || 0) > 15).length,
    wanted: wanted.length,
    // The axis is fixed at 0-50 ms, so the 60 fps budget stands exactly a third across.
    width: canvas.width,
  };
});
report(
  'the curve wears the colour of the budget each part of it is inside',
  bands.drawn >= 3,
  `${bands.drawn} of ${bands.wanted} band colours on the canvas`,
);

// **It reads bottom-left to top-right, between its own two ends.** The curve is the share
// of frames that came in *under* each duration, so it climbs; and it is drawn only between
// the fastest frame the window holds and the slowest, so it leaves 0% at one and arrives at
// 100% at the other rather than running flat along both edges. Those two arrivals are how
// the min and the max are read off it, so they are what is held here.
const reach = await page.evaluate(() => {
  const canvas = document.getElementById('exceedance');
  const pixels = canvas.getContext('2d')
    .getImageData(0, 0, canvas.width, canvas.height).data;
  // The curve alone: the gridlines are drawn at a fifth of this opacity.
  let top = canvas.height;
  let bottom = -1;
  let rightmost = -1;
  for (let y = 0; y < canvas.height; y += 1) {
    for (let x = 0; x < canvas.width; x += 1) {
      if (pixels[(y * canvas.width + x) * 4 + 3] < 200) continue;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
      if (x > rightmost) rightmost = x;
    }
  }
  const said = document.getElementById('diag-exceedance-axis').textContent;
  return {
    top, bottom, rightmost, height: canvas.height, width: canvas.width,
    milliseconds: Number((said.match(/0\u2013(\d+(?:\.\d+)?) ms/) || [])[1]),
  };
});
report(
  'the curve climbs from 0% at the fastest frame to 100% at the slowest',
  // Bottom to top of the canvas, which the plot is the whole of: the rates and durations are
  //   drawn over it rather than in rows of their own, so the curve owns the full height.
  //   And all the way out to the slowest frame the window holds, which on a window this size
  //   is the far edge, the axis being fitted to exactly that frame.
  reach.top <= 2 && reach.bottom >= reach.height - 3 &&
    // Within the axis's own deadband of the far edge: the glide settles a couple of
    //   percent short of the extent rather than landing exactly on it, which is the axis
    //   holding still rather than chasing the last half-millisecond.
    reach.rightmost >= reach.width * 0.95,
  `drawn from row ${reach.top} to ${reach.bottom} of ${reach.height}, ` +
    `out to column ${reach.rightmost} of ${reach.width}`,
);
// The floor, exercised where it actually binds: a window holding nothing slower than
// 15 ms would otherwise draw an axis a third that wide and zoom the session into its own
// noise, so it stops at the 30 fps mark -- with room past it to write that mark's own
// labels, which is why the floor is a little wider than 33.3 ms rather than exactly it.
await page.evaluate(() => {
  for (let i = 0; i < 1024; i += 1) window.__record_kept(5 + Math.random() * 9);
});
await settleAxis();
const floored = await page.evaluate(() => {
  const said = document.getElementById('diag-exceedance-axis').textContent;
  return Number((said.match(/0\u2013(\d+(?:\.\d+)?) ms/) || [])[1]);
});
report(
  'and its axis follows the window without ever closing below the 30 fps mark',
  Number.isFinite(reach.milliseconds) && reach.milliseconds >= 33 &&
    // At the floor, within the axis's own deadband -- the glide settles near the extent
    //   rather than exactly on it, and the floor is an extent like any other.
    Number.isFinite(floored) && floored >= MILLISECONDS_FLOOR_DRAWN - 1 &&
    floored <= MILLISECONDS_FLOOR_DRAWN + 2,
  `a mixed window reads 0-${reach.milliseconds} ms, a fast one 0-${floored} ms`,
);

// Everything the axis writes on itself, read out of the canvas by opacity. The four things
// drawn there are laid down at four different alphas -- gridlines faintest, then the dashed
// budget marks, then the labels, then the curve opaque -- so each can be counted apart from
// the others without knowing where any of them went.
const readAxisInk = () => page.evaluate((row) => {
  const canvas = document.getElementById('exceedance');
  const w = canvas.width, h = canvas.height;
  const pixels = canvas.getContext('2d').getImageData(0, 0, w, h).data;
  const alphaAt = (x, y) => pixels[(y * w + x) * 4 + 3];
  const isLabel = (x, y) => alphaAt(x, y) > 120 && alphaAt(x, y) < 230;
  // A dashed mark is a column that **starts at the very top** and carries its own alpha
  //   down a good part of the height. Both halves are needed: the percentages stacked in
  //   the left margin put antialiased pixels at that alpha down a similar span of column,
  //   and were counted as marks until the run had to begin at row 0 as only a full-height
  //   line does. The dash pattern leaves gaps, so a third of the rows is the bar.
  const marks = [];
  for (let x = 0; x < w; x += 1) {
    let down = 0, first = h;
    for (let y = 0; y < h; y += 1) {
      if (alphaAt(x, y) <= 60 || alphaAt(x, y) >= 120) continue;
      if (y < first) first = y;
      down += 1;
    }
    if (first <= 2 && down > h * 0.3) marks.push(x);
  }
  let ink_margin = 0;
  for (let y = row; y < h - row; y += 1) {
    for (let x = 0; x < 26; x += 1) if (isLabel(x, y)) ink_margin += 1;
  }
  // Each mark named at both ends: label ink in the top row and in the bottom row, within
  //   reach of the mark's own column on whichever side it took.
  const named = marks.map((x) => {
    let above = 0, below = 0;
    for (let dx = -16; dx <= 16; dx += 1) {
      const at = x + dx;
      if (at < 0 || at >= w) continue;
      for (let y = 0; y < row; y += 1) if (isLabel(at, y)) above += 1;
      for (let y = h - row; y < h; y += 1) if (isLabel(at, y)) below += 1;
    }
    return { x, above, below };
  });
  return { w, h, marks, named, ink_margin };
}, ROW_LABEL_DRAWN);

// **Both modes name the heights the curve is read against.** Linear drew five bare rules
// and not one word, so a reader could see that some height mattered without being told
// which; log named two of its three decades and left the 99.9% ceiling -- the whole reason
// to switch to it -- unnamed. Checked in both, because only one of them was ever right.
//   Toggled through the element itself rather than a real click: the drawer is shut at
//   this point in the run, and Playwright rightly refuses to click what a reader cannot
//   see. What is under test here is what the axis draws, not how the switch is reached --
//   the switch's own wiring is driven with the drawer open, further up.
const toggleLog = () => page.evaluate(() => {
  document.getElementById('toggle-exceedance-log').click();
  drawExceedance();
});
const ink_linear = (await readAxisInk()).ink_margin;
await toggleLog();
const ink_log = (await readAxisInk()).ink_margin;
await toggleLog();
report(
  'both scales of the axis name the heights they are read against',
  ink_linear > 40 && ink_log > 40,
  `${ink_linear} pixels of label linear, ${ink_log} log`,
);

// **Each mark is a rate and a duration.** The dashed line is one ruler read from both ends
// -- "60" above it and "16.7" below -- so a reader never converts between the two in their
// head. The durations are the new half; before them the bottom row was empty.
const ink_floor = await readAxisInk();
report(
  'every budget mark is named as a rate above it and a duration below it',
  ink_floor.marks.length >= 3 &&
    ink_floor.named.every((mark) => mark.above > 0 && mark.below > 0),
  `${ink_floor.marks.length} marks at columns ${ink_floor.marks.join(', ')}, ` +
    `named ${ink_floor.named.map((m) => `${m.above}/${m.below}`).join(' ')}`,
);

// **The slowest mark the axis is always guaranteed to reach stands clear of its right
// edge.** At a floor of exactly 1000/30 the 30 fps line landed *on* that edge, half a pixel
// outside the canvas, and its label flipped to the cramped inside-left branch -- alone
// among the marks in reading right to left. The floor now carries room for it.
report(
  'the 30 fps mark stands inside the axis at its narrowest, with room to name it',
  ink_floor.marks.length > 0 &&
    ink_floor.marks[ink_floor.marks.length - 1] <= ink_floor.w - 15,
  `slowest mark at column ${ink_floor.marks[ink_floor.marks.length - 1]} ` +
    `of ${ink_floor.w}, on a 0-${MILLISECONDS_FLOOR_DRAWN.toFixed(1)} ms floor`,
);

// **And the 15 fps mark waits for a window that needs it.** It is drawn by the same rule
// every other mark is -- only where the axis reaches it -- so it must be absent from the
// fast window above and present once the window holds frames that slow. The floor does not
// widen to accommodate it: 30 fps is what sets the minimum.
await page.evaluate(() => {
  for (let i = 0; i < 1024; i += 1) window.__record_kept(10 + Math.random() * 80);
});
await settleAxis();
const ink_wide = await readAxisInk();
report(
  'and the 15 fps mark appears only once the window holds a frame that slow',
  //   Counts alone: that each mark is named is the check above's business, and a check
  //   that fails for two reasons tells you neither.
  ink_floor.marks.length === 3 && ink_wide.marks.length === 4,
  `${ink_floor.marks.length} marks on a fast window, ${ink_wide.marks.length} on a slow one`,
);

// **The timing rows wear the cost they carry.** Twenty-odd numbers say nothing about which
// to look at; the curve's own ramp, banded by each row's share of the frame's *work*, does.
// Checked as an ordering rather than against fixed colours, so tuning a threshold does not
// mean rewriting this: a row that costs more may never wear a faster colour than one that
// costs less. Every branch is opened first -- `refreshDiagnostics` skips what is closed, so
// a shut node's rows would be read stale.
await page.evaluate(() => {
  const drawer = document.querySelector('.drawer');
  if (!drawer.classList.contains('open')) document.getElementById('btn-drawer').click();
  const section = document.querySelector('.section[data-section="diagnostics"]');
  if (!section.classList.contains('open')) section.querySelector('.section-header').click();
  for (const node of document.querySelectorAll('.diag-node')) {
    if (!node.classList.contains('open')) node.querySelector(':scope > .diag-parent').click();
  }
});
await page.waitForTimeout(600);
const tinted = await page.evaluate(() => {
  // The page tints with hex and reads back `rgb(...)`, so the ramp is put through the same
  //   normalisation before anything is compared to it.
  const scratch = document.createElement('span');
  const normalised = colours_row_value.map((colour) => {
    scratch.style.color = colour;
    return scratch.style.color;
  });
  const rows = [];
  for (const [name] of PHASES_DIAGNOSTIC) {
    const value = element_phase[name];
    if (value === null || element_row[name] === null) continue;
    const said = Number((value.textContent.match(/^([\d.]+)/) || [])[1]);
    if (!Number.isFinite(said)) continue;
    rows.push({
      name, milliseconds: said,
      // The band is read back through the ramp the page tinted with, so this check never
      //   holds an opinion about which colour a band is.
      band: normalised.indexOf(value.style.color),
      colour: value.style.color,
    });
  }
  return { rows, idle: element_phase.idle.style.color };
});
// Ordering: sort by cost and walk, allowing equal bands but never a cheaper row in a
//   costlier band. Rows the page left untinted carry no band and sit out of the comparison.
const ranked = tinted.rows.filter((r) => r.band >= 0 && r.name !== 'idle')
  .sort((a, b) => b.milliseconds - a.milliseconds);
let is_ordered = true;
for (let i = 1; i < ranked.length; i += 1) {
  if (ranked[i].band > ranked[i - 1].band) is_ordered = false;
}
report(
  'a costlier timing row never wears a faster colour than a cheaper one',
  ranked.length >= 4 && is_ordered,
  `${ranked.length} tinted rows, worst-first: ` +
    ranked.slice(0, 5).map((r) => `${r.name} ${r.milliseconds} band ${r.band}`).join(', '),
);
// And the frame's leftover is left alone: it is the largest share of a healthy frame, so a
// band on it would paint the best case as the worst.
report(
  "and the frame's own idle time is left uncoloured, being no work at all",
  tinted.idle === '',
  `idle carries ${tinted.idle === '' ? 'no inline colour' : tinted.idle}`,
);

// **The axis waits, then glides; it never jumps.** Fitted frame for frame it snapped: one
// slow frame widened it and the moment that frame aged out it snapped back, so two glances
// a second apart could not be compared. Driven exactly as that happens: a settled window,
// then one much slower frame put into it. Immediately after, the axis must not have moved
// at all -- that wait is what lets a dip-and-return leave it where it was -- and some
// seconds later it must have arrived, having passed through the middle rather than jumped.
const axis_reading = () => page.evaluate(() => {
  drawExceedance();
  return Number((document.getElementById('diag-exceedance-axis').textContent
    .match(/0\u2013(\d+(?:\.\d+)?) ms/) || [])[1]);
});
await page.evaluate(() => {
  for (let i = 0; i < 1024; i += 1) window.__record_kept(40 + Math.random() * 2);
});
await settleAxis();
const axis_settled = await axis_reading();
// One frame three times slower than anything else in the window, and nothing else changed.
await page.evaluate(() => window.__record_kept(126));
const axis_at_once = await axis_reading();
await page.waitForTimeout(1000);
const axis_midway = await axis_reading();
for (let i = 0; i < 24; i += 1) {
  await page.waitForTimeout(120);
  if (await page.evaluate(() => { drawExceedance(); return ms_axis_restless === 0; })) break;
}
const axis_arrived = await axis_reading();
await releaseExceedance(); // Every synthetic window above is done with; real frames resume.
report(
  'the axis waits before it moves, then glides to the new extent rather than jumping',
  Number.isFinite(axis_settled) && axis_settled > 0 &&
    // Unmoved while the wait stands.
    axis_at_once === axis_settled &&
    // Under way, but not there yet: the glide passes through the middle.
    axis_midway > axis_settled && axis_midway < axis_arrived &&
    // Arrived at the slow frame's own bucket, which is what the window now reaches to.
    axis_arrived >= 120,
  `settled 0-${axis_settled} ms; at once 0-${axis_at_once}; after 1 s 0-${axis_midway}; ` +
    `arrived 0-${axis_arrived}`,
);

// **The vertical axis switches, and the curve switches with it.** Linear reads the
// proportion as a proportion; log reads three decades of the distance from the top, which
// is the only way the slowest one percent is legible at all. Driven through the pill the
// reader actually presses rather than by setting the flag, since the flag being right and
// the button being wired are separate claims -- and held on the pixels, because the same
// data drawn against a different axis is a different curve.
const axes_curve = await page.evaluate(async () => {
  const inked = () => {
    const canvas = document.getElementById('exceedance');
    const pixels = canvas.getContext('2d')
      .getImageData(0, 0, canvas.width, canvas.height).data;
    // The curve alone, at the opacity only it is drawn with, summarised as the row each
    //   column's mark sits on -- which is the shape of the curve and nothing else.
    const rows = [];
    for (let x = 0; x < canvas.width; x += 1) {
      let row = -1;
      for (let y = 0; y < canvas.height; y += 1) {
        if (pixels[(y * canvas.width + x) * 4 + 3] < 200) continue;
        row = y;
        break;
      }
      rows.push(row);
    }
    return rows.join(',');
  };
  const pill = document.getElementById('toggle-exceedance-log');
  const caption = document.getElementById('diag-exceedance-axis');
  drawExceedance();
  const linear = { rows: inked(), said: caption.textContent, on: pill.classList.contains('on') };
  pill.click();
  const log = { rows: inked(), said: caption.textContent, on: pill.classList.contains('on') };
  pill.click();
  const back = { rows: inked(), said: caption.textContent, on: pill.classList.contains('on') };
  return { linear, log, back };
});
report(
  'the curve switches between a linear axis and a log one, and back',
  axes_curve.linear.on === false && axes_curve.log.on === true &&
    axes_curve.back.on === false &&
    axes_curve.log.said !== axes_curve.linear.said &&
    axes_curve.back.said === axes_curve.linear.said &&
    axes_curve.log.rows !== axes_curve.linear.rows &&
    axes_curve.back.rows === axes_curve.linear.rows,
  `"${axes_curve.linear.said}" then "${axes_curve.log.said}", ` +
    `curve ${axes_curve.log.rows === axes_curve.linear.rows ? 'unchanged' : 'redrawn'} ` +
    `and ${axes_curve.back.rows === axes_curve.linear.rows ? 'restored' : 'not restored'}`,
);

// **A step too quick for the clock still reports a time.** Every mobile browser coarsens
// and jitters `performance.now` against timing attacks, so a sub-millisecond phase can
// measure as zero or below. Absence used to be marked by a negative in the value's own
// range, which made such a reading indistinguishable from "this never ran" -- and left
// every sub-millisecond row of the tree an em dash on a phone while the six-millisecond
// ones read fine. Driven with exactly that: a phase whose every measurement is zero or
// negative must still report, at zero.
// Both synthetic runs below fill the rings by hand, and `recordFrameTime` clears every
// phase's presence as it advances -- so they hand the rings back exactly as they found
// them. Without that, a check reading a real phase after one of these reads a ring this
// harness itself wiped, and reports the page broken when it was the driving that was.
const keepRings = () => page.evaluate(() => {
  const kept = { at: index_history_frame, frames: Array.from(history_frame), phases: {} };
  for (const [name] of PHASES_DIAGNOSTIC) {
    kept.phases[name] = [Array.from(history_phase[name]), Array.from(written_phase[name])];
  }
  return kept;
});
const restoreRings = (kept) => page.evaluate((k) => {
  index_history_frame = k.at;
  for (let i = 0; i < k.frames.length; i += 1) history_frame[i] = k.frames[i];
  for (const [name] of PHASES_DIAGNOSTIC) {
    history_phase[name].set(k.phases[name][0]);
    written_phase[name].set(k.phases[name][1]);
  }
}, kept);

const kept_rings = await keepRings();
const unmeasured = await page.evaluate(() => {
  for (const node of document.querySelectorAll('.diag-node')) node.classList.add('open');
  // The frame ring is advanced first and the phases written into it after, exactly as the
  //   draw loop does it, so the slots line up the way they really would.
  for (let i = 0; i < 240; i += 1) {
    recordFrameTime(16.7);
    recordPhaseTime('sky', i % 2 === 0 ? 0 : -0.4);
  }
  refreshDiagnostics();
  return {
    text: document.getElementById('diag-sky').textContent,
    median: medianPhase('sky'),
  };
});
report(
  'a step too quick for the clock to measure still reports, at zero',
  unmeasured.median === 0 && unmeasured.text.startsWith('0.00 (0.00) ms'),
  `the row reads "${unmeasured.text}", median ${unmeasured.median}`,
);

// **A reading is the mean over 200 ms, not the newest frame.** One frame's number changes
// several times faster than it can be read, which is what made these rows flicker. Driven
// with a phase that alternates between 1 ms and 9 ms every frame: the newest frame is
// always one or the other, and only an averaged reading lands between them.
const smoothed = await page.evaluate(() => {
  for (const node of document.querySelectorAll('.diag-node')) node.classList.add('open');
  for (let i = 0; i < 240; i += 1) {
    recordFrameTime(16.7);
    recordPhaseTime('overlay', i % 2 === 0 ? 1 : 9);
  }
  refreshDiagnostics();
  return {
    text: document.getElementById('diag-overlay').textContent,
    frames: framesRecent(),
  };
});
await restoreRings(kept_rings);
// **The rows account for the whole frame, not a fraction of it.** Everything the page
// spends is `build + upload + overlay + menu + ui`; the rest of a frame is waiting on the
// display plus the browser's own style, layout, paint, compositing and collection. Without
// that remainder on the panel a spike could not be told from a stall in the page's own
// code, which is the first thing a reader needs to know. Held frame by frame: the six rows
// must reconstruct the frame time they are a breakdown of.
const accounted = await page.evaluate(() => {
  const rows = [];
  for (let i = 2; i < FRAMES_HISTORY - 2; i += 1) {
    const at = (index_history_frame + i) % FRAMES_HISTORY;
    if (written_phase.idle[at] !== 1) continue;
    let sum = history_phase.idle[at];
    for (const name of PHASES_TOP_DIAGNOSTIC) {
      if (written_phase[name][at] === 1) sum += history_phase[name][at];
    }
    rows.push({ frame: history_frame[at], sum });
  }
  const off = rows.map((r) => Math.abs(r.frame - r.sum));
  return { n: rows.length, worst: off.length === 0 ? 0 : Math.max(...off) };
});
report(
  'the breakdown rows account for the whole frame they break down',
  // Exact but for float32 rounding on the bridge's own three phases.
  accounted.n > 100 && accounted.worst < 0.05,
  `${accounted.n} frames reconstructed, worst off by ${accounted.worst.toFixed(4)} ms`,
);

report(
  'a reading is the mean over the last 200 ms, not whatever the newest frame said',
  // 200 ms of 16.7 ms frames is a dozen of them, and a dozen alternating 1s and 9s mean 5.
  smoothed.text.startsWith('5.00 ') && smoothed.frames >= 9 && smoothed.frames <= 16,
  `the row reads "${smoothed.text}" over ${smoothed.frames} frames`,
);

// **The algebra's own layer draws what the picture only stands for.** The ordinary picture
// draws a plane as a disc of fixed radius, because an infinite surface would bury
// everything; switched on, the debug layer draws it as the infinite lattice it actually is,
// reaching the furniture's own extent instead of `EXTENT_PLANE`. It also draws geometry the
// scene does not contain at all -- the camera's sight axis, its near plane, the ray under
// the cursor -- so the toggle has to change more than a tint.
const layered = await page.evaluate(async () => {
  const settle = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  const chip = document.getElementById('toggle-algebra');
  const count = () => nimBuildFrame(1.4, 2.0, 700, true, true, chip.classList.contains('on'));
  const off = count();
  const lit_off = chip.classList.contains('on');
  chip.click();
  await settle();
  const on = count();
  return {
    lit_off, lit_on: chip.classList.contains('on'),
    // Ribbons: the lattice is drawn as ribbons, as every line in this build is.
    ribbons_off: off.ribbon_verts.length, ribbons_on: on.ribbon_verts.length,
    ms_off: off.ms_algebra, ms_on: on.ms_algebra,
  };
});
report(
  'the algebra layer is off until asked for, and then draws more than the scene',
  !layered.lit_off && layered.lit_on &&
    layered.ms_off === 0 && layered.ms_on > 0 &&
    layered.ribbons_on > layered.ribbons_off,
  `off: ${layered.ribbons_off} ribbon vertices, ${layered.ms_off} ms; ` +
    `on: ${layered.ribbons_on}, ${layered.ms_on.toFixed(1)} ms`,
);

// **A plane is drawn infinite, not as its disc.** The lattice reaches the furniture's own
// extent, which is far outside the fixed radius the disc stands at -- so the furthest thing
// the layer draws has to lie well beyond `EXTENT_PLANE`, or the plane is still a disc.
const reached = await page.evaluate((EXTENT_PLANE_DRIVE) => {
  const data = nimBuildFrame(1.4, 2.0, 700, false, false, true);
  // Furniture off, so every vertex counted here belongs to the scene and the layer over it.
  let furthest = 0;
  const v = data.ribbon_verts;
  // Seven floats a vertex: three of place, four of colour.
  for (let i = 0; i < v.length; i += 7) {
    furthest = Math.max(furthest, Math.hypot(v[i], v[i + 1], v[i + 2]));
  }
  return { furthest, extent_plane: EXTENT_PLANE_DRIVE };
}, 8.0); // `mesh.EXTENT_PLANE`, the fixed radius a plane's disc stands at.
report(
  'a plane is drawn as the infinite thing it is, not as the disc that stands for one',
  reached.furthest > 4*reached.extent_plane,
  `furthest lattice vertex ${reached.furthest.toFixed(1)} units out, ` +
    `against a disc of ${reached.extent_plane}`,
);

// **The scene phase, broken down by the kind of object each millisecond went to.** The
// kinds differ by two orders of magnitude -- a point is one vertex, a plane a rim of
// ribbons each carrying its own join -- so a reader asking why a scene is slow needs the
// split, not the total. Held the only way a breakdown can be held honest: the parts must
// account for the whole they are parts of, frame by frame, and each part must carry the
// count it is a time for.
const kinds = await page.evaluate(() => window.__phase_frame.slice(2).map((p) => ({
  scene: p.scene,
  parts: p.points + p.lines + p.planes + p.sky + p.ghost + p.selected,
  counted: p.count_points + p.count_lines + p.count_planes +
    p.count_sky + p.count_ghost + p.count_selected,
})));
// The parts may never exceed the whole by more than a rounding, and must account for the
//   bulk of it -- but not for all of it: the phase also walks all 64 slots twice, marks the
//   overlay and packs the view-projection, and none of that belongs to any one kind. That
//   remainder is a share of the frame rather than a fixed cost, so the floor is a share
//   too; a fixed 3 ms floor failed one frame in sixty when the frame itself ran long.
const kinds_sane = kinds.filter((k) =>
  k.parts <= k.scene + 0.6 && k.parts >= k.scene - Math.max(3.0, 0.3 * k.scene) &&
  k.counted > 0);
report(
  'the scene phase is accounted for by the kinds it is spent on',
  kinds.length > 30 && kinds_sane.length === kinds.length,
  `${kinds_sane.length} of ${kinds.length} frames account, ` +
    `last frame ${kinds.length ? kinds[kinds.length - 1].parts.toFixed(2) : '?'} of ` +
    `${kinds.length ? kinds[kinds.length - 1].scene.toFixed(2) : '?'} ms ` +
    `over ${kinds.length ? kinds[kinds.length - 1].counted : '?'} objects`,
);
await page.evaluate(() =>
  document.querySelector('.diag-node[data-node="furniture"] > .diag-parent').click());
await page.waitForTimeout(400);
const rows_scenery = await page.evaluate(() => Object.fromEntries(
  ['grid', 'axes'].map((n) => [n, document.getElementById('diag-' + n).textContent])));
report(
  'and both halves have their own row, the grid carrying its segment count',
  / ms \u00b7 \d+$/.test(rows_scenery.grid) && / ms$/.test(rows_scenery.axes),
  `grid: ${rows_scenery.grid}, axes: ${rows_scenery.axes}`,
);

await page.evaluate(() =>
  document.querySelector('.diag-node[data-node="scene"] > .diag-parent').click());
await page.waitForTimeout(400);
const rows_kind = await page.evaluate(() => Object.fromEntries(
  ['points', 'lines', 'planes', 'sky', 'ghost', 'selected']
    .map((n) => [n, document.getElementById('diag-' + n).textContent])
));
report(
  'each kind reports its own count beside its own time',
  Object.values(rows_kind).every((t) => / ms \u00b7 \d+$/.test(t)),
  Object.entries(rows_kind).map(([n, t]) => `${n}: ${t}`).join(', '),
);

// **The scenery, at the distance where it used to cost the most.** Its price is its
// segment count, and that count climbs with camera distance until the cell steps a decade
// and drops it back -- so the worst frame is not the farthest one but the one just before
// a step. Measured at orbit distance 300 before the budget: 2,084 segments and 126.5 ms of
// grid, against 154 and 7.3 ms at the opening view. Held here at that same distance,
// through the bridge's own grid clock and segment count, as a band rather than a figure.
const scenery_far = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  const distance_before = nimCameraDistance();
  nimSetCameraDistance(300);
  const milliseconds = [];
  let segments = 0;
  for (let i = 0; i < 9; i += 1) {
    nimCameraOrbit(0.005, 0); // Move, so the furniture cache cannot hold and it rebuilds.
    const data = nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true);
    milliseconds.push(data.ms_grid);
    segments = data.count_grid_segments;
  }
  nimSetCameraDistance(distance_before);
  milliseconds.sort((a, b) => a - b);
  return { median: milliseconds[4], segments };
});
report(
  'the scenery holds its segment budget where it used to cost the most',
  scenery_far.segments > 0 && scenery_far.segments <= 640,
  `${scenery_far.segments} segments at orbit distance 300, ` +
    `${scenery_far.median.toFixed(1)} ms of grid`,
);

// The same budget while the camera actually moves, which is when a reader felt it
// collapse: a moving camera rebuilds the ground grid every frame, and per-segment
// multivector churn once put that rebuild at 3x the still frame's whole build. The band
// is generous for the same reason the still ones are -- it exists to catch the collapse,
// not to time this container -- and the drag is a real one, from empty sky, so the frames
// sampled are the frames a hand would feel.
const index_before_drag = await page.evaluate(() => window.__work_frame.length);
await page.mouse.move(SIZE_VIEW.width / 2, 60);
await page.mouse.down();
for (let i = 0; i < 40; i += 1) {
  await page.mouse.move(
    SIZE_VIEW.width / 2 + 350 * Math.sin(i / 6), 60 + 20 * Math.cos(i / 6), { steps: 3 },
  );
}
await page.mouse.up();
const work_moving = await page.evaluate((from) => {
  const sorted = window.__work_frame.slice(from).sort((a, b) => a - b);
  const at = (share) => sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))];
  return sorted.length < 10 ? null : { n: sorted.length, median: at(0.5), p90: at(0.9) };
}, index_before_drag);
// **The scenery, split into the two halves that answer differently to distance.** The axes
// are three lines however far the camera stands; the grid is however many the ground reach
// asks for, and its cost *is* its segment count. The bridge has clocked them apart since
// the grid gained its budget; these are the rows that show it.
const scenery = await page.evaluate((from) => window.__phase_frame.slice(from),
  index_before_drag);
const scenery_moving = scenery.filter((p) => p.furniture > 0.05);
// The slack is **proportional**, as the per-kind check's is and for the same reason: the
// bracket around the two halves also spans the mesh clear and the loop between them, and on
// a frame the scheduler interrupts that gap grows with the frame rather than by a fixed
// amount. A flat +-1 ms was ample on an 8 ms rebuild and failed one frame in a hundred and
// twenty on a 15 ms one -- a flake, not a finding, and a flaky check gets deleted rather
// than fixed.
const sceneryOff = (p) => (p.grid + p.axes) - p.furniture;
const scenery_sane = scenery_moving.filter((p) =>
  sceneryOff(p) <= Math.max(0.6, 0.08 * p.furniture) &&
  sceneryOff(p) >= -Math.max(1.0, 0.12 * p.furniture) &&
  p.segments > 0);
report(
  'the scenery is accounted for by the grid and the axes it is drawn from',
  scenery_moving.length > 3 && scenery_sane.length === scenery_moving.length,
  `${scenery_sane.length} of ${scenery_moving.length} rebuilt frames account` +
    (scenery_moving.length === 0 ? '' : (() => {
      // The worst frame, not the last: a bare count says nothing about what went wrong.
      const worst = scenery_moving.reduce(
        (a, b) => (Math.abs(sceneryOff(b)) > Math.abs(sceneryOff(a)) ? b : a));
      return `, worst ${worst.grid.toFixed(1)} + ${worst.axes.toFixed(1)} ` +
        `of ${worst.furniture.toFixed(1)} ms (off by ${sceneryOff(worst).toFixed(2)}) ` +
        `over ${worst.segments} segments`;
    })()),
);

report(
  'the camera was really moved for the moving-frame sample',
  work_moving !== null,
  `${work_moving === null ? 0 : work_moving.n} frames sampled mid-drag`,
);
// The band grew from 20 when `directionAcross` was the triple join. It is a cross product
// again -- the ribbon is the picture's business, not the algebra's, see the boundary in
// PROVENANCE.md -- so that justification has lapsed, and the band is now simply what
// catches the collapse class a reader felt (30+ ms builds) without timing this container.
// **It is close to the bone on a loaded shared runner**: identical code has measured 25.0
// and 29.8 ms hours apart here. A failure at 27-30 says to re-measure against the previous
// commit before believing it; a failure well past 30 is the collapse this exists for.
reportWithin(
  'a frame is still assembled inside its budget while the camera moves',
  work_moving === null ? -1 : work_moving.median, 0, 26, 'ms',
);

// What buys that: a camera that has not moved draws the very same grid and axes, so they
// are built once and held -- and the loop above should have held them on nearly every one
// of the frames it just drew, since nothing moved the camera for those two seconds.
report(
  'a still camera holds its ground and axes rather than rebuilding them',
  work_frame !== null && work_frame.held > 0.8 * work_frame.n,
  `${work_frame === null ? 0 : work_frame.held} of ` +
    `${work_frame === null ? 0 : work_frame.n} frames held`,
);
// Stated directly too, since a share of frames could be right by accident: move the
// camera, so the next call must build, and the one after it must hold.
const furniture_held = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  const once = () => nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true);
  nimCameraOrbit(0.05, 0.0);
  const first = once();
  const second = once();
  return {
    first: { held: first.is_furniture_held, floats: first.furn_ribbon_verts.length },
    second: { held: second.is_furniture_held, floats: second.furn_ribbon_verts.length },
  };
});
report(
  'a still camera builds its ground and axes once and holds them',
  furniture_held.first.floats > 0 && furniture_held.first.held === false &&
    furniture_held.second.held === true && furniture_held.second.floats === 0,
  `first ${furniture_held.first.floats} floats (held ${furniture_held.first.held}), ` +
    `second ${furniture_held.second.floats} (held ${furniture_held.second.held})`,
);
// And a camera that has moved rebuilds them, or the view would keep a grid it has left.
const furniture_rebuilt = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true);
  nimCameraOrbit(0.3, 0.0);
  const after = nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true);
  return { held: after.is_furniture_held, floats: after.furn_ribbon_verts.length };
});
report(
  'and a camera that has moved builds them again',
  furniture_rebuilt.held === false && furniture_rebuilt.floats > 0,
  `held ${furniture_rebuilt.held}, ${furniture_rebuilt.floats} floats`,
);

/* ---- Nothing may have thrown along the way ---- */

/* ---- Touch drags as a finger really performs them ---- */

// Last of the checks, and deliberately so: these build objects, and the budget and zoom
// checks above are written against the opening scene's own weight and layout.

// `Home` glides the camera back rather than snapping it, so anything that reads an object's
//   own pixel has to wait for the glide to finish -- a pixel read mid-flight names where the
//   object *was*, and the press then lands on empty space.
async function settleCamera() {
  let previous = null;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const now_at = await readCamera();
    if (previous !== null && Math.abs(now_at.distance - previous.distance) < 1e-9 &&
        Math.abs(now_at.azimuth - previous.azimuth) < 1e-9 &&
        spanTarget(previous, now_at) < 1e-9) return;
    previous = now_at;
    await page.waitForTimeout(50);
  }
}

// **A finger that eases into its drag rather than flicking.** The press target chooses the
// scheme, so a press on an object is a construction press from the moment it lands -- but
// touch used to orbit over the few pixels before the tap slop was crossed, which latched the
// camera-dragging flag, and hover is suppressed while the camera moves. The construction
// drag that armed a moment later then ran blind for the rest of the gesture: no destination,
// no ghost, nothing built. Driven here in sub-slop steps, which is what a real finger does
// and what no flick-speed check could reach.
await clearTheGlass();
await page.keyboard.press('Home');
await settleCamera();
await page.evaluate(() => nimSelectClear());
// Read afresh, for the same reason the section above says: the checks between here and
//   the opening scene delete and build, so the slot list captured up there is stale.
const points_live = await page.evaluate(() => nimSceneSlots()
  .filter((slot) => nimItemShapeWord(slot) === 'point'));
const count_before_creep = await page.evaluate(() => nimSceneCount());
const camera_before_creep = await page.evaluate(() => ({
  azimuth: nimCameraAzimuth(), elevation: nimCameraElevation(),
}));
const from_creep = await pixelOf(points_live[0]);
const onto_creep = await pixelOf(points_live[1]);
// Four steps of a third of the slop each, so the gesture spends three moves under the
//   threshold before crossing it -- exactly the frames that used to orbit.
const step_creep = (await page.evaluate(() => nimTapSlop())) / 3;
await touchAt('touchStart', [{ x: from_creep[0], y: from_creep[1] }]);
await page.waitForTimeout(90);
for (let step = 1; step <= 4; step += 1) {
  const reach = (step * step_creep) /
    Math.hypot(onto_creep[0] - from_creep[0], onto_creep[1] - from_creep[1]);
  await touchAt('touchMove', [{
    x: from_creep[0] + (onto_creep[0] - from_creep[0]) * reach,
    y: from_creep[1] + (onto_creep[1] - from_creep[1]) * reach,
  }]);
  await page.waitForTimeout(35);
}
for (let step = 1; step <= 8; step += 1) {
  await touchAt('touchMove', [{
    x: from_creep[0] + ((onto_creep[0] - from_creep[0]) * step) / 8,
    y: from_creep[1] + ((onto_creep[1] - from_creep[1]) * step) / 8,
  }]);
  await page.waitForTimeout(35);
}
const creep_mid = await page.evaluate(() => ({
  hover: nimHoverSlot(), dragging: nimDragActive(),
}));
await touchAt('touchEnd', []);
await page.waitForTimeout(400);
const camera_after_creep = await page.evaluate(() => ({
  azimuth: nimCameraAzimuth(), elevation: nimCameraElevation(),
}));
report(
  'a finger easing into its drag still sees what it is pointing at',
  creep_mid.dragging && creep_mid.hover === points_live[1] &&
    (await page.evaluate(() => nimSceneCount())) === count_before_creep + 1,
  `dragging ${creep_mid.dragging}, hovering ${creep_mid.hover} (wanted ${points_live[1]}), ` +
    `${await page.evaluate(() => nimSceneCount())} items, was ${count_before_creep}`,
);
report(
  'and it never moved the camera on the way',
  Math.abs(camera_after_creep.azimuth - camera_before_creep.azimuth) < 1e-6 &&
    Math.abs(camera_after_creep.elevation - camera_before_creep.elevation) < 1e-6,
  `azimuth ${camera_before_creep.azimuth.toFixed(4)} -> ` +
    `${camera_after_creep.azimuth.toFixed(4)}, elevation ` +
    `${camera_before_creep.elevation.toFixed(4)} -> ${camera_after_creep.elevation.toFixed(4)}`,
);

// **A plane is pickable over the disc it is drawn as, whichever way its normal faces.** The
// hit test read the depth of the raw meet, whose weight carries which side the ray crossed
// from, so a plane met from behind its normal read as standing behind the eye and could not
// be picked anywhere at all -- while the ground plane, whose normal happens to face the eye,
// picked fine and hid it. Held here on a plane the gesture itself builds, since that is the
// only kind a reader makes.
await clearTheGlass();
await page.keyboard.press('Home');
await settleCamera();
await page.evaluate(() => nimSelectClear());
const points_for_plane = await page.evaluate(() => nimSceneSlots()
  .filter((slot) => nimItemShapeWord(slot) === 'point'));
const from_plane = await pixelOf(points_for_plane[0]);
const onto_plane = await pixelOf(points_for_plane[1]);
await touchAt('touchStart', [{ x: from_plane[0], y: from_plane[1] }]);
for (let step = 1; step <= 8; step += 1) {
  await touchAt('touchMove', [{
    x: from_plane[0] + ((onto_plane[0] - from_plane[0]) * step) / 8,
    y: from_plane[1] + ((onto_plane[1] - from_plane[1]) * step) / 8,
  }]);
  await page.waitForTimeout(35);
}
await touchAt('touchEnd', []);
await page.waitForTimeout(400);
const slot_line_made = await page.evaluate(() => nimSceneSlots()
  .find((slot) => nimItemShapeWord(slot) === 'line'));
// That line joined with a third point gives a plane, which is what is being reached for.
const on_line = await page.evaluate((slot) => {
  const at = nimAnchorScreen(slot, window.innerWidth, window.innerHeight);
  return at && at.length ? [at[0], at[1]] : null;
}, slot_line_made);
const onto_third = await pixelOf(points_for_plane[2]);
await touchAt('touchStart', [{ x: on_line[0], y: on_line[1] }]);
for (let step = 1; step <= 8; step += 1) {
  await touchAt('touchMove', [{
    x: on_line[0] + ((onto_third[0] - on_line[0]) * step) / 8,
    y: on_line[1] + ((onto_third[1] - on_line[1]) * step) / 8,
  }]);
  await page.waitForTimeout(35);
}
await touchAt('touchEnd', []);
await page.waitForTimeout(400);
const slot_plane_made = await page.evaluate(() => nimSceneSlots()
  .find((slot) => nimItemShapeWord(slot) === 'plane' && nimItemLabel(slot) !== 'ground'));
// Sweep the canvas for a pixel that picks it. A disc this size covers a good part of the
//   view, so finding none at all is the fault this guards against.
const pixels_on_plane = slot_plane_made === undefined ? 0 : await page.evaluate((slot) => {
  let found = 0;
  for (let y = 40; y < window.innerHeight - 40; y += 40) {
    for (let x = 40; x < window.innerWidth - 40; x += 40) {
      nimUpdateCursor(x, y);
      nimUpdateHover(window.innerWidth, window.innerHeight);
      if (nimHoverSlot() === slot) found += 1;
    }
  }
  return found;
}, slot_plane_made);
report(
  'a plane the gesture built can be pointed at where it is drawn',
  slot_plane_made !== undefined && pixels_on_plane > 0,
  `plane slot ${slot_plane_made}, picked at ${pixels_on_plane} sampled pixels`,
);

// **And from underneath it, not only from above.** A plane has two faces and neither is
// its front: the hit test asks where the sight ray crosses, and where is not a side. The
// shipped fault read the crossing's *orientation* as its depth, so a plane met from behind
// its own normal reported itself behind the eye and went unpickable over its whole disc --
// reported as "I can only select a plane from one side". The ground plane is the honest
// subject for the pin: it lies flat, so above and below are the same view mirrored, and a
// reading that differs between them is the sign leaking back in rather than geometry.
const slot_ground = await page.evaluate(() => nimSceneSlots()
  .find((slot) => nimItemLabel(slot) === 'ground'));
const seenFromElevation = (elevation) => page.evaluate(([slot, rise]) => {
  nimSetCameraElevation(rise);
  let found = 0;
  for (let y = 40; y < window.innerHeight - 40; y += 40) {
    for (let x = 40; x < window.innerWidth - 40; x += 40) {
      nimUpdateCursor(x, y);
      nimUpdateHover(window.innerWidth, window.innerHeight);
      if (nimHoverSlot() === slot) found += 1;
    }
  }
  return found;
}, [slot_ground, elevation]);
// Everything else hidden, so a point or a line standing in front cannot take a pixel the
//   plane would otherwise have answered for and make the two sides differ for that reason.
const hidden_for_sides = await page.evaluate((keep) => {
  const hidden = nimSceneSlots().filter((slot) => slot !== keep && nimItemVisible(slot));
  for (const slot of hidden) nimSetVisible(slot, false);
  return hidden;
}, slot_ground);
const seen_above = await seenFromElevation(0.9);
const seen_below = await seenFromElevation(-0.9);
const seen_edge_on = await seenFromElevation(0.0);
await page.evaluate((slots) => { for (const slot of slots) nimSetVisible(slot, true); },
  hidden_for_sides);
await page.keyboard.press('Home');
report(
  'and from underneath it, as readily as from above',
  seen_above > 20 && seen_below > 20 &&
    Math.min(seen_above, seen_below) > 0.5 * Math.max(seen_above, seen_below),
  `${seen_above} pixels from above, ${seen_below} from below, ${seen_edge_on} edge-on`,
);

// **The scale bar measures what it says it measures.** A bar drawn from one derivation and
// labelled from another is the classic way a map scale goes quietly wrong, so both halves
// are checked against the bridge's own `nimGridMetrics` -- and at two distances a decade
// apart, since the grid's cell steps by decades and a bar that ignored the step would still
// pass at a single distance.
const rulers = [];
for (const distance of [19, 4000]) {
  await page.evaluate((d) => nimSetCameraDistance(d), distance);
  await page.waitForTimeout(400);
  rulers.push(await page.evaluate((d) => {
    const [cell, world_per_pixel] =
      nimGridMetrics(window.innerWidth, window.innerHeight);
    const label = document.getElementById('ruler-label').textContent;
    const width = document.getElementById('ruler-bar').getBoundingClientRect().width;
    // The span the label claims, read back out of the label itself -- thin spaces and all.
    const span = Number(label.split(' units')[0].replace(/\u2009/g, ''));
    return { distance: d, cell, world_per_pixel, label, width, span,
      hidden: document.getElementById('ruler').hidden };
  }, distance));
}
await page.evaluate(() => nimSetCameraDistance(19));
const rulers_true = rulers.filter((r) =>
  !r.hidden && Number.isFinite(r.span) && r.span > 0 &&
  Math.abs(r.width - r.span / r.world_per_pixel) <= 1.5 &&
  r.label.includes(String(r.cell >= 1000
    ? r.cell.toLocaleString('en-US').replace(/,/g, '\u2009') : r.cell)));
report(
  'the scale bar is as long as the distance it claims, and names the grid it measures',
  rulers_true.length === rulers.length && rulers[0].cell !== rulers[1].cell,
  rulers.map((r) => `at ${r.distance}: "${r.label}" over ${r.width.toFixed(1)}px ` +
    `(claims ${(r.span / r.world_per_pixel).toFixed(1)}px)`).join('; '),
);

// **The drawer covers the scale bar rather than moving or hiding it.** The bar belongs to
// the view it measures, so it stays put and the drawer is simply drawn over it. It used to
// step aside to the drawer's far edge, which on a phone -- where the drawer is a
// full-width sheet -- put it off-screen entirely; a reading that vanishes when a panel
// opens is worse than one the panel is sitting on.
const covered = await page.evaluate(() => {
  const ruler = document.getElementById('ruler');
  const drawer = document.querySelector('.drawer');
  const boxOf = () => ruler.getBoundingClientRect();
  const closed = boxOf();
  document.getElementById('btn-drawer').click();
  const open = boxOf();
  const layer = (el) => Number(getComputedStyle(el).zIndex);
  const shown = getComputedStyle(ruler).display !== 'none' &&
    getComputedStyle(ruler).visibility !== 'hidden' && !ruler.hidden;
  document.getElementById('btn-drawer').click(); // Leave it as it was found.
  return {
    moved: Math.abs(open.left - closed.left) + Math.abs(open.top - closed.top),
    shown, ruler: layer(ruler), drawer: layer(drawer), width: open.width,
  };
});
report(
  'the drawer covers the scale bar rather than moving it aside or hiding it',
  covered.moved === 0 && covered.shown && covered.width > 0 &&
    covered.ruler < covered.drawer,
  `moved ${covered.moved}px, shown ${covered.shown}, ` +
    `layer ${covered.ruler} under the drawer's ${covered.drawer}`,
);

report('the page raised no errors', errors_page.length === 0, errors_page.join('; '));

await browser.close();
console.log(
  count_failed === 0
    ? '\nEvery driven check passed.'
    : `\n${count_failed} driven check(s) failed.`,
);
process.exit(count_failed === 0 ? 0 : 1);
