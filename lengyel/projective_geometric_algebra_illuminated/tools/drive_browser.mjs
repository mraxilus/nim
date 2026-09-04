// Drive built browser page through real events, and assert what they reached.
//
// Suites test *rules*:
//   what slide does to target, what zoom does to distance.
//   Nothing in them presses key, turns wheel or puts two fingers on canvas, so nothing in them
//   catches rule wired to wrong event; pinch once zoomed at its own midpoint with every case green.
//   This layer catches that, and `verify.sh` runs it rather than leaving it to `/tmp`.
//
// Reports every check, pass or fail, and exits non-zero if any failed, as `check_palette` does:
//   one run says everything wrong, not first thing.
//
// **Timing-dependent quantities are asserted as bands, never figures.** How far held key
// travels depends on frames drawn while it was down; exact figure flakes, and flaky check
// gets deleted rather than fixed.
//
// Run:
//   node tools/drive_browser.mjs
// Needs `playwright` resolvable (global install wants `NODE_PATH`; see `dependencies.list`)
// and Chromium, which Playwright finds itself unless `VISUALISER_CHROMIUM` names one.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require_here = createRequire(import.meta.url);
const { chromium } = require_here('playwright');

const dir_project = join(dirname(fileURLToPath(import.meta.url)), '..');
const url_page = `file://${join(dir_project, 'bin', 'rga_browser.html')}`;

// Fix viewport checks below are written against.
//   Wheel check reads object's own pixel out of page, so nothing here depends on these
//   beyond having room to gesture in.
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

// Focus canvas rather than clicking it.
//   Click on canvas selects whatever is under it, standing framing offer then moves
//   camera on its own, and every reading below would be measuring that instead of
//   gesture under test.
await page.evaluate(() => document.getElementById('gl').focus());

const readCamera = () => page.evaluate(() => ({
  distance: nimCameraDistance(),
  target: Array.from(nimCameraTarget()), // Plain array, for return across `evaluate`.
  azimuth: nimCameraAzimuth(),
}));
const spanTarget = (before, after) => Math.hypot(
  after.target[0] - before.target[0],
  after.target[1] - before.target[1],
  after.target[2] - before.target[2],
);

// Clear glass before every section that drives canvas.
//   Panels earlier check opened sit over canvas and swallow every pointer event, so
//   gesture driven at pixel beneath one never reaches application at all.
//   Drawer opens on left, side desktop's own panel occupies, which is side most of
//   gestures below start from.
async function clearTheGlass() {
  await page.evaluate(() => {
    clearSelection();
    hideSelectionMenu();
    if (drawer.classList.contains('open')) document.getElementById('button-drawer').click();
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

// Check release, which key handling must see.
//   Key that never comes up moves camera for as long as page is open.
const at_release = await readCamera();
await page.waitForTimeout(400);
report(
  'releasing a key stops the view',
  spanTarget(at_release, await readCamera()) < 1e-6,
  'still after the release',
);

// Blur mid-hold, whose release is delivered to whoever took focus rather than here.
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

/* ---- Wheel ----     */

// Return to opening placement first, through key that means it.
//   Wheel checks below then start from known camera, and `home` is itself checked on
//   way.
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
// Pick object standing furthest from every other on screen.
//   Rather than whichever slot happens to be last.
//   Zoom aims at what `picking.pickNearest` finds under pointer and ranks point above
//   plane, so pointer over two overlapping objects anchors on thinner one, and this
//   check would then be measuring object it did not aim at.
//   Opening scene has point sitting few pixels from ground plane's own drawn anchor,
//   which is exactly that case.
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
// Require exact, not merely close.
//   Zoom anchors on very object pointer is over, so pixel it was on is pixel it stays
//   on; anchor on plane through camera's own target drifts; figures in
//   `PROVENANCE.md`.
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

/* ---- Pinch ----     */

// Playwright's own touch API is single-touch, so two fingers go through CDP directly.
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

// Pinch well off centre, which is where aimed zoom shows itself.
//   Midpoint never moves, so pinch that also translated view would drag it toward that
//   corner.
const mid_pinch = { x: 300, y: 300 };
const pinch_before = await readCamera();
await pinch(mid_pinch, mid_pinch, 40, 160);
const pinch_after = await readCamera();
report(
  'a pinch zooms',
  pinch_after.distance < pinch_before.distance * 0.6,
  `distance ${pinch_before.distance.toFixed(2)} -> ${pinch_after.distance.toFixed(2)}`,
);
// Allow residue that is two-finger pan's own.
//   Midpoint sits between one finger's new position and other's old one for moment
//   between their two `pointermove` events.
//   Aimed at its midpoint instead, this same gesture drags view far; figures in
//   `PROVENANCE.md`.
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

/* ---- Touch, way finger uses this ----       */

// Drive gestures suites cannot reach.
//   They live in `glue.js`'s pointer handling, which is where pinch regression lived
//   too.
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

// Hold well past `SECONDS_HOLD_SELECT`, only way finger has to start selection.
await tapAt(pixel_first[0], pixel_first[1], 1400);
report(
  'a long press selects what it is over',
  (await page.evaluate(() => nimSelectionCount())) === 1,
  `${await page.evaluate(() => nimSelectionCount())} selected`,
);

// **Read second object's pixel afresh, after ease.** Picking turns orbit about
//   what was picked, so view is still gliding when press above lets go and every
//   other object is somewhere new by time it settles. Pixel read before first
//   press names where second object *was*.
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

// Two fingers moving together, at fixed separation: pan and only pan.
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
// Check pan slides view across level, so orbit centre keeps its height exactly.
//   Sliding within plane facing eye, which is tilted, lifts target off ground, and
//   every later orbit then swings about point in mid-air.
report(
  'and without lifting the orbit centre off the level it was on',
  Math.abs(dragged_after.target[2] - dragged_before.target[2]) < 1e-6,
  `target height ${dragged_before.target[2].toFixed(3)} -> ` +
    `${dragged_after.target[2].toFixed(3)}`,
);

// Check finger dragging one object onto another builds third.
//   Whole gesture application is about.
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

// Check finger over crowd moves view rather than building anything.
//   Second point beside first, inside one finger's pick reach, so press is ambiguous;
//   same drag as above then orbits and builds nothing. Reader zooms in to separate them.
//   See `interaction.canConstructByTouch`.
await page.keyboard.press('Home');
await page.waitForTimeout(150);
const slot_rival = await page.evaluate((slot) => {
  const model = Array.from(nimItemCoefficients(slot));
  model[1] += 0.05;
  const added = nimAddItem(model, 'rival', nimDefaultInk(), nimDefaultRadius(), 0);
  nimSelectClear();
  return added;
}, slots_scene[1]);
await page.waitForTimeout(200);
const count_before_crowd = await page.evaluate(() => nimSceneCount());
const azimuth_before_crowd = await page.evaluate(() => nimCameraAzimuth());
const from_crowd = await pixelOf(slots_scene[1]);
await touchAt('touchStart', [{ x: from_crowd[0], y: from_crowd[1] }]);
for (let step = 1; step <= 10; step += 1) {
  await touchAt('touchMove', [{
    x: from_crowd[0] + ((onto[0] - from_crowd[0]) * step) / 10,
    y: from_crowd[1] + ((onto[1] - from_crowd[1]) * step) / 10,
  }]);
  await page.waitForTimeout(30);
}
await touchAt('touchEnd', []);
await page.waitForTimeout(400);
const count_after_crowd = await page.evaluate(() => nimSceneCount());
const azimuth_after_crowd = await page.evaluate(() => nimCameraAzimuth());
report(
  'a finger dragging from a crowd of objects orbits instead of building',
  count_after_crowd === count_before_crowd &&
    Math.abs(azimuth_after_crowd - azimuth_before_crowd) > 0.05,
  `${count_after_crowd} items, was ${count_before_crowd}; azimuth ` +
    `${azimuth_before_crowd.toFixed(3)} -> ${azimuth_after_crowd.toFixed(3)}`,
);
// Put camera back where orbit found it.
//   Later checks frame with `Home`, which keeps azimuth, and at this one line's anchor
//   lands over point.
await page.evaluate(([slot, azimuth]) => {
  nimRemoveItem(slot);
  nimSetCameraAzimuth(azimuth);
}, [slot_rival, azimuth_before_crowd]);
await page.waitForTimeout(150);

// Drive same gesture as finger actually performs it: pause over target to aim.
//   Dwell wheel opens under finger during that pause, hidden by it; reading release as
//   "chose nothing" would make exactly careful drags build nothing.
//   Wheel nobody entered may not veto release: it takes pair's own answer, as quick
//   lift above does.
//   Check first holds that wheel really did open, so slower dwell could never turn this
//   into second copy of quick-lift check.
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
await page.waitForTimeout(1100); // Past SECONDS_DWELL_MENU, as finger pausing to aim is.
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

// Check drag let go of over empty space builds nothing and says nothing.
//   Reader can see nothing, and status line for it would fire on every gesture anybody
//   thought better of.
await page.keyboard.press('Home');
await page.waitForTimeout(150);
await page.evaluate(() => {
  nimSelectClear();
  // Require cleared, not just hidden.
  //   Check that only asked whether bar is up would pass on message that was never
  //   dismissed from earlier gesture.
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

// **Apply picker names positions, scene names slots.** Ghost was once previewed
// from picker's own position passed straight through as slot, which is only ever right
// while nothing has been deleted. Checked where positions and slots genuinely differ.
// Deleted way reader deletes -- selection, menu, delete -- rather than through
//   bridge: operand pickers are rebuilt by UI action, not by periodic tick, so
//   scene changed behind UI's back is state no gesture can actually produce.
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

await page.click('#button-drawer');
// **And apply section, because that is where pickers are.** They are filled when
//   their own section opens rather than on every scene change: one `<option>` per object per
//   picker is ten thousand elements at largest size, and building them for collapsed
//   control was 119 ms of demo load. So route reader takes to *see* picker is
//   route this has to take to check one -- opening drawer alone no longer fills them,
//   and check that stopped at drawer would be asserting against control nobody
//   could have looked at.
await page.evaluate(() => {
  const section = document.querySelector('.section[data-section="apply"]');
  if (!section.classList.contains('open')) section.querySelector('.section-header').click();
});
await page.waitForTimeout(300);
report(
  'the operand pickers follow a scene the reader has just changed',
  await page.evaluate(
    () => document.getElementById('op-first').options.length === nimSceneCount(),
  ),
  `${await page.evaluate(() => document.getElementById('op-first').options.length)} options, ` +
    `${await page.evaluate(() => nimSceneCount())} items`,
);
// Shut apply section again, because open one keeps ghost standing.
//   Whole point of `ghostDrawerOperation` running on section toggle, and standing ghost
//   is one of three things `is_scene_settled` refuses to hold frame over.
//   Left open, this check would quietly break frame-hold checks further down.
await page.evaluate(() => {
  const section = document.querySelector('.section[data-section="apply"]');
  if (section.classList.contains('open')) section.querySelector('.section-header').click();
});
await page.waitForTimeout(200);
const count_before_apply = await page.evaluate(() => nimSceneCount());
// Apply twice over: once through picker, once straight through bridge.
//   Picker names positions; bridge takes slots those positions stand for.
//   Two build same object from same pair, so their drawn anchors coincide, and would
//   not if picker's position were passed through as slot, which is bug.
const slots_before_apply = await page.evaluate(() => nimSceneSlots());
const applied = await page.evaluate(() => {
  const slots = nimSceneSlots();
  document.getElementById('op-first').value = '0';
  document.getElementById('op-second').value = '1';
  const operation = parseInt(document.getElementById('op-select').value, 10);
  document.getElementById('button-apply').click();
  return { operation, first: slots[0], second: slots[1] };
});
await page.waitForTimeout(300);
const coefficientsOf = (slot) => page.evaluate((s) => nimItemCoefficients(s), slot);
// Take slot new item lands in as lowest free one, which after delete is in middle.
//   "The last slot" is not newest item, and saying so quietly compares wrong object.
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
  // Report rather than throw, since this is shape regression takes here.
  //   Reading position as slot names slot that was freed by delete above, and applying
  //   to dead operand builds nothing at all.
  report(
    'apply builds from the operands its pickers name, not from their positions', false,
    `the picker built ${slot_by_picker === undefined ? 'nothing' : 'slot ' + slot_by_picker}` +
      `, the bridge ${slot_by_bridge === undefined ? 'nothing' : 'slot ' + slot_by_bridge}`,
  );
} else {
  // Compare by their own coefficients rather than by where they are drawn.
  //   Operation picker happens to default to may be one whose result stands at horizon,
  //   and horizon object has no drawn anchor to compare.
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

// **Orbit turns about what is picked.** Turning about point is what orbit is, so
// reader who picks objects and turns means to turn about those -- and framing used to
// leave target wherever it was whenever everything picked was already on screen, which
// swung picked object around view instead. Held end to end: one pick lands
// target on that object, second lands it on middle of two, and reader's own
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

// **Panning was dead while anything stayed selected**: standing framing offer re-armed
// every frame and dragged camera back to where it had aimed. Reported as touch bug,
// and neither touch- nor browser-specific.
// Pinch below starts at x=400, drawer's own right edge once it is open on
//   left, so glass is cleared before selection this check needs is made.
await clearTheGlass();
await page.evaluate(() => nimSelectOnly(nimSceneSlots()[0]));
await page.waitForTimeout(700); // Let framing ease finish before moving by hand.
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

// **Timeline key did nothing in frames right after edit**, because buttons it
// answers through were refreshed on low-cadence tick.
const count_before_undo = await page.evaluate(() => nimSceneCount());
await page.evaluate(() => document.getElementById('gl').focus());
await page.keyboard.press('Control+z');
await page.waitForTimeout(250);
report(
  'undo reaches the timeline in the frames right after an edit',
  (await page.evaluate(() => nimSceneCount())) === count_before_undo - 1,
  `${await page.evaluate(() => nimSceneCount())} items, was ${count_before_undo}`,
);

// **WCAG 2.5.7**: every operation drag reaches is reachable with no dragging at all,
// through selection -> menu -> apply. Route, not wording. Selected through
// page's own helpers rather than bridge, so menu's view of selection is one
// finger would have left it with.
await page.evaluate(() => {
  const slots = nimSceneSlots();
  selectOnly(slots[0], null);
  toggleSelection(slots[1], null);
});
await page.waitForTimeout(200);
const count_before_menu = await page.evaluate(() => nimSceneCount());
// Press menu's apply twice, by design.
//   First press opens picker beside it, second commits whatever that picker names.
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

/* ---- Camera gesture is not hover ----     */

await page.keyboard.press('Home');
// Clear what checks above left on screen.
//   Otherwise this section measures menu and drawer rather than hover rule.
await clearTheGlass();
// Read slots afresh.
//   Checks above delete and build, so slot list captured for touch gestures no longer
//   names what is alive here.
const slots_now_live = await page.evaluate(() => nimSceneSlots());
const slot_swept = slots_now_live[1];
const pixel_swept = await pixelOf(slot_swept);
// **orbit** drag from empty space, swinging scene across pointer. Orbit rather
// than pan because pan carries world along with drag -- what was under cursor
// stays under it -- while orbit sweeps objects past pointer that is also moving, which
// is case that used to light up string of them. Every step is sampled, not just
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
// Aim onto where that object stands now.
//   Pan moved world under pointer, so its old pixel holds nothing any more, and asking
//   there would say nothing about rule.
const pixel_settled = await pixelOf(slot_swept);
await page.mouse.move(pixel_settled[0], pixel_settled[1]);
await page.evaluate(() => nimUpdateHover(window.innerWidth, window.innerHeight));
report(
  'the highlight comes back the moment the gesture ends',
  (await page.evaluate(() => nimHoverSlot())) >= 0,
  `hovering slot ${await page.evaluate(() => nimHoverSlot())} after the release`,
);

/* ---- Help stays open, and lists catalogue ----         */

await page.evaluate(() => showHelp(true));
await page.waitForTimeout(200);
await page.mouse.click(SIZE_VIEW.width / 2, SIZE_VIEW.height - 80);
await page.waitForTimeout(200);
await page.click('#button-drawer');
await page.waitForTimeout(200);
report(
  'the help stays open while the reader uses what it describes',
  await page.evaluate(() => document.getElementById('help-panel').classList.contains('show')),
  'still open after a click on the canvas and on the drawer',
);

const rows_catalogue = await page.evaluate(() => {
  // Tab strip names its tabs; open catalogue one and count what it renders.
  const tab = [...document.querySelectorAll('#help-tabs button')]
    .find((button) => button.textContent.trim() === 'operations');
  if (!tab) return -1;
  tab.click();
  // Every path's rows live in one box, shown and hidden by tab; count this tab's own.
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

/* ---- Horizon line's comet runs where reader can see it ----     */

// Guard comet on horizon line, whose marker is two circles on sky.
//   Circles run out to line's own vanishing points, and uncut one laps in hundreds of
//   thousands of pixels of outline no camera can show; comet travelling at fixed screen
//   pace would be off screen for all but few frames in thousand.
//   Driven rather than reasoned: this reads what page would actually stroke.
await page.evaluate(() => showHelp(false));
await page.keyboard.press('Home');
await page.waitForTimeout(150);
const slot_horizon = await page.evaluate(() => {
  const plane = nimSceneSlots().find((slot) => nimItemShapeWord(slot) === 'plane');
  if (plane === undefined) return null;
  const before = nimSceneSlots();
  // `Attitude` is catalogue's own first operation, and plane's attitude is
  //   pencil of directions lying in it -- line at horizon.
  nimApplyOperation(0, plane, plane, performance.now() / 1000);
  const built = nimSceneSlots().find((slot) => !before.includes(slot));
  // Stand level with ground, so sky bands wrap is in front of camera.
  //   Rather than above top edge of it.
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
// Page's own mirror of `marker.MarkerKind`, read from it rather than copied here.
const kind_bands = await page.evaluate(() => MARKER_BANDS);
report(
  'a plane\'s attitude is drawn as bands the window itself bounds',
  marker_horizon.kind === kind_bands && marker_horizon.points.length > 0 &&
    (await insideCanvas(marker_horizon.points)),
  `kind ${marker_horizon.kind}, ${marker_horizon.points.length} points`,
);

// Wait for comet to have head before timing how far it travels.
//   Object was created moments ago and fresh one starts its pulse at zero
//   (`nimEndDrag` forgets its clock on purpose), so sampling straight away sometimes
//   catches it before there is head to report, which comes back as `null` and reads as
//   "off screen".
let head_first = null;
for (let waited = 0; waited < 40 && head_first === null; waited += 1) {
  head_first = await headOf();
  if (head_first === null) await page.waitForTimeout(50);
}
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
// Band travel over half second at SPEED_MARKER_PULSE rather than pinning it exactly.
//   Page's own frame pacing decides how much of that half second clock actually saw.
reportWithin('its comet covers a screen pace, not a lap of the sky', travelled, 5, 60, 'px');

/* ---- Mouse pan grabs level, and keeps its height ----       */

// Clear glass first, or this measures panel swallowing press.
//   Drag below starts where drawer stands once open, and it opens on left.
await clearTheGlass();
await page.evaluate(() => { nimSelectClear(); document.getElementById('gl').focus(); });
await page.keyboard.press('Home');
await page.waitForTimeout(900);
const pan_before = await readCamera();
// Start well clear of every object, so right button pans rather than arming drag.
//   Dragged up screen, direction that lifts target under rate-based pan.
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

/* ---- Zoom aims at what pointer is over, and settles target onto it ----           */

// Check zoom brings orbit centre down onto what is being zoomed into.
//   Anchored on plane through target, zoom leaves orbit centre stranded on level it
//   started at however far reader goes in; anchored on object or ground under pointer,
//   it comes down.
// Focus canvas, which has to hold focus for key to reach view at all.
//   Help's own close button took it few checks ago, and Home pressed into button moves
//   nothing.
await page.evaluate(() => { nimSelectClear(); document.getElementById('gl').focus(); });
await page.keyboard.press('Home');
// Wait long enough for camera's own tween home to settle.
//   Height read mid-flight is not height this check means to zoom away from.
await page.waitForTimeout(900);
const before_aim = await readCamera();
// Low in frame, where sight ray reaches ground well in front of camera.
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

/* ---- Ground is still under camera however far it has pulled back ----         */

// Guard against fog's reach being capped short of where camera can dolly.
//   Camera dollied past cap would have ground stop reaching what it was looking at, and
//   further out meet black void with no reference of any kind, grid, axes and all.
//   Driven through page's own frame build, so what is counted is what would actually be
//   uploaded and drawn.
await page.evaluate(() => { nimSelectClear(); });
await page.keyboard.press('Home');
await page.waitForTimeout(150);
// Count grid only, with axes switched off.
//   Three axis lines are drawn by rule of their own and would keep count above zero in
//   exactly case being guarded against.
const groundAt = (distance) => page.evaluate((given) => {
  nimSetCameraDistance(given);
  const canvas = document.getElementById('gl');
  const data = nimBuildFrame(
    canvas.width / canvas.height, performance.now() / 1000, canvas.height, false, true,
  );
  // Read distance frame was actually built at, not one asked for.
  //   Camera can be mid-tween toward framing of scene, and count reported against
  //   distance it was not standing at says nothing.
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
// Check cell steps by decades to keep that true.
//   What is drawn then stays inside budget fixed cell was bounded by rather than
//   growing with reach.
report(
  'and no more of it is drawn far out than close in',
  Math.max(...Object.values(ground).map((at) => at.count)) <= 1.1 * ground[300].count,
  `most ${Math.max(...Object.values(ground).map((at) => at.count))}, ` +
    `at 300 ${ground[300].count}`,
);
await page.keyboard.press('Home');
await page.waitForTimeout(150);

/* ---- Draw loop's own work fits inside frame ----       */

// Check frame cadence is even, which is every frame's work fitting inside budget.
//   Browser page cannot draw faster than compositor presents: `requestAnimationFrame`
//   is only honest loop and it is paced by display, so "uncapped" is not thing to reach
//   for.
//   Measured here is part this page owns, not wall clock.
//     Machine running these checks renders through software GL, so its frame times say
//     more about swiftshader than about anything in this repository.
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
      // Count what crossed wire, by record kind.
      //   Plane's rim is one ring record, and check under demo below is what would
      //   notice it silently becoming many ribbons.
      records_ribbon: data.ribbon_verts.length / 16,
      records_ring: data.ring_records.length / 14,
      records_disc: data.disc_records.length / 13,
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
// Pin bands rather than figures: this is real machine's real clock.
//   Numbers that matter are measurements recorded in PROVENANCE.md's bottleneck ledger,
//   taken on this same software renderer.
//   Bands catch collapse class reader felt, over scene assembling every point through
//   algebra, which is stress project exists to apply.
reportWithin(
  'a frame is assembled in a fraction of its own budget',
  work_frame === null ? -1 : work_frame.median, 0, 18, 'ms',
);
reportWithin(
  'and its slowest tenth stays inside one',
  work_frame === null ? -1 : work_frame.p90, 0, 30, 'ms',
);

/* ---- Diagnostics tab's own phase clocks tell truth ----         */

// Check bridge's own build steps: populated, summing within whole, agreeing with clock.
//   Bridge reports scenery, scene objects and flatten; those have to sum to no more
//   than whole they are steps of, and agree with wall clock held around call from
//   outside.
//   Bands generous: performance.now() is sub-ms quantised and this container is slow.
const phases = await page.evaluate(() => window.__phase_frame.slice(2));
const sane = phases.filter((p) =>
  p.build > 0 && p.scene >= 0 && p.furniture >= 0 && p.flatten >= 0 &&
  p.furniture + p.scene + p.flatten <= p.build + 1.0 && p.build <= p.wall + 1.0);
report(
  'the build reports its phases, and they add up',
  phases.length > 30 && sane.length === phases.length,
  `${sane.length} of ${phases.length} frames consistent`,
);
// **Opened for real before any of it.** Two reasons, and second is newer: chevron's
// rotation is only resolvable on rendered element -- inside `display: none` subtree
// `getComputedStyle().transform` answers `none` whatever rule says -- and rows
// themselves are now written only while drawer is open. That gate is what stopped
// whole diagnostics refresh costing 2.8 ms five times second with nobody reading it, and
// it means these checks have to reach panel way reader does: tree node inside
// shut drawer is not state anyone can put page into. Both are put back at end.
const glass_before = await page.evaluate(() => {
  const drawer = document.querySelector('.drawer');
  const section = document.querySelector('.section[data-section="diagnostics"]');
  const was = { drawer: drawer.classList.contains('open'),
    section: section.classList.contains('open') };
  if (!was.drawer) document.getElementById('button-drawer').click();
  if (!was.section) section.querySelector('.section-header').click();
  return was;
});
await page.waitForTimeout(500);

// And drawer's rows actually render them, so reader can see each step live.
// **tree starts wholly closed** -- reader opens this panel to learn whether frame is
// slow, and goes looking for which step only once it is -- so subtotals under `build`
// are checked to be idle first, then opened way reader opens them, and only then
// checked to be live. Without first half tree that never closed would pass.
const rows_closed = await page.evaluate(() => ({
  is_open: document.querySelector('.diagnostic-node[data-node="build"]').classList.contains('open'),
  children: ['furniture', 'scene', 'flatten']
    .map((n) => document.getElementById('diagnostic-' + n).textContent),
}));
report(
  'the frame-time breakdown starts collapsed',
  !rows_closed.is_open && rows_closed.children.every((t) => !/ ms$/.test(t)),
  `node open ${rows_closed.is_open}, children ${JSON.stringify(rows_closed.children)}`,
);
await page.evaluate(() =>
  document.querySelector('.diagnostic-node[data-node="build"] .diagnostic-parent').click());
await page.waitForTimeout(400);
const row_texts = await page.evaluate(() => Object.fromEntries(
  ['build', 'camera', 'furniture', 'scene', 'matrix', 'flatten', 'unaccounted',
    'placing', 'emitting', 'hover', 'upload', 'overlay', 'ui']
    .map((n) => [n, document.getElementById('diagnostic-' + n).textContent])
));
report(
  'every drawing step has a live row once its branch is opened',
  Object.values(row_texts).every((t) => / ms$/.test(t)),
  Object.entries(row_texts).map(([n, t]) => `${n}: ${t}`).join(', '),
);

// **Branch opens its own rows and stops there.** `build` is open at this point and
// nothing under it has been touched, so two nested branches must still be shut: their
// rows out of layout and their chevrons unturned. This is check tree needed
// from start -- rules that reveal branch's children and turn its chevron used
// descendant combinator, so opening `build` laid whole tree bare and rotated all three
// chevrons while `isPhaseShown` went on correctly treating inner nodes as closed and
// never wrote their rows. Every deeper row then sat on screen, apparently expanded, showing
// em dash for good. Driving every branch open hid it: only opening outermost one
// does.
const nested = await page.evaluate(() => {
  // Ask row's own branch container, not `offsetParent`.
  //   Everything in drawer sits inside `position: fixed` ancestor, which makes
  //   `offsetParent` null whatever branch is doing, so it cannot tell open branch from
  //   shut one.
  const laid = (id) => getComputedStyle(
    document.getElementById(id).closest('.diagnostic-children')).display !== 'none';
  const turned = (node) => getComputedStyle(document.querySelector(
    '.diagnostic-node[data-node="' + node + '"] > .diagnostic-parent .chev')).transform !== 'none';
  const shut = {
    grid: laid('diagnostic-grid'), points: laid('diagnostic-points'),
    scenery_turned: turned('furniture'), scene_turned: turned('scene'),
  };

  document.querySelector('.diagnostic-node[data-node="scene"] > .diagnostic-parent').click();
  return shut;
});
// Read after chevron's own turn has finished.
//   Asked in same tick as click, transition that has not started yet still reports its
//   old transform.
await page.waitForTimeout(700);
const nested_open = await page.evaluate(() => {
  const laid = (id) => getComputedStyle(
    document.getElementById(id).closest('.diagnostic-children')).display !== 'none';
  const turned = (node) => getComputedStyle(document.querySelector(
    '.diagnostic-node[data-node="' + node + '"] > .diagnostic-parent .chev')).transform !== 'none';
  return {
    points: laid('diagnostic-points'), grid: laid('diagnostic-grid'),
    scene_turned: turned('scene'), scenery_turned: turned('furniture'),
    reading: document.getElementById('diagnostic-points').textContent,
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
// `scenery` opened too, for checks below which read every row; then drawer and
// section are put back exactly as this check found them.
await page.evaluate((was) => {
  document.querySelector('.diagnostic-node[data-node="furniture"] > .diagnostic-parent').click();
  const drawer = document.querySelector('.drawer');
  const section = document.querySelector('.section[data-section="diagnostics"]');
  if (drawer.classList.contains('open') !== was.drawer) {
    document.getElementById('button-drawer').click();
  }
  if (section.classList.contains('open') !== was.section) {
    section.querySelector('.section-header').click();
  }
}, glass_before);
await page.waitForTimeout(400);

// **Frame-time distribution, over window long enough to hold rare stall.**
// sparkline holds four seconds and says *when*; this says *how often*, which is
// question reader chasing occasional stutter is actually asking. Held as three
// properties that make curve distribution rather than drawing: every frame is at or
// over zero, share never rises as duration does, and buckets account for
// exactly frames in window -- plus stated 1-in-100 agreeing with same
// percentile taken directly off ring, which is arithmetic buckets stand in for.
const curve = await page.evaluate(() => {
  const counted = scanExceedance();
  let is_monotone = true;
  for (let i = 1; i < BUCKETS_EXCEEDANCE; i += 1) {
    if (shares_exceedance[i] > shares_exceedance[i - 1] + 1e-12) is_monotone = false;
  }
  let held = 0;
  for (let i = 0; i < BUCKETS_EXCEEDANCE; i += 1) held += buckets_exceedance[i];
  // Same percentile, taken slow honest way off samples themselves.
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
  // Allow bucket and half.
  //   Curve reports bucket's own lower edge, and direct percentile lands anywhere inside
  //   that bucket.
  Math.abs(curve.direct - curve.bucketed) <= 1.0 && curve.lit > 200,
  `curve says ${curve.bucketed.toFixed(1)} ms, samples say ${curve.direct.toFixed(1)} ms, ` +
    `${curve.lit} pixels drawn`,
);

// Give synthetic window wall-clock time to arrive, since axis waits and then glides.
//   `recordExceedance` is stubbed while it settles: real frame entering window
//   mid-settle would change very extent being waited for, and on this container every
//   real frame is slower than anything these checks feed in.
//   Held around fill as well as settle, since single real frame slipping into window
//   between filling it and waiting on it moves very extent being waited for.
//     Feed through `window.__record_kept` while hold stands.
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

// Read how narrow axis may get off page rather than restating it here.
//   Copy would pass while page drifted away from it, which is one thing these checks
//   exist to stop.
const { MILLISECONDS_FLOOR_DRAWN } = await page.evaluate(() => ({
  MILLISECONDS_FLOOR_DRAWN: MILLISECONDS_AXIS_LEAST,
}));
// Fix how deep band at each end to look in for mark's own labels.
//   This check's own sampling window, not copy of anything page declares.
//     Rates and durations are drawn over plot rather than in rows of their own, so
//     there is no page-side row height to read.
//   Comfortably more than line they are set in, and comfortably less than canvas, which
//   is all it has to be.
const ROW_LABEL_DRAWN = 11;

// **Curve is drawn in colour of budget each part of it sits inside**, and
// axis it is drawn against is fixed rather than fitted. Every frame this container draws is
// slower than 30 fps, so fast bands cannot be reached by driving page harder;
// window is fed spread through `recordExceedance` -- very call frame loop makes
// -- which exercises drawing without pretending machine is faster than it is.
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
  // Tokens stylesheet sets, as canvas would have written them.
  const wanted = ['--speed-fast', '--speed-good', '--speed-fair', '--speed-poor'].map((t) => {
    const hex = getComputedStyle(document.documentElement).getPropertyValue(t).trim();
    return [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16)).join(',');
  });
  return {
    drawn: wanted.filter((rgb) => (counted.get(rgb) || 0) > 15).length,
    wanted: wanted.length,
    // Axis is fixed at 0-50 ms, so 60 fps budget stands exactly third across.
    width: canvas.width,
  };
});
report(
  'the curve wears the colour of the budget each part of it is inside',
  bands.drawn >= 3,
  `${bands.drawn} of ${bands.wanted} band colours on the canvas`,
);

// **It reads bottom-left to top-right, between its own two ends.** Curve is share
// of frames that came in *under* each duration, so it climbs; and it is drawn only between
// fastest frame window holds and slowest, so it leaves 0% at one and arrives at
// 100% at other rather than running flat along both edges. Those two arrivals are how
// min and max are read off it, so they are what is held here.
const reach = await page.evaluate(() => {
  const canvas = document.getElementById('exceedance');
  const pixels = canvas.getContext('2d')
    .getImageData(0, 0, canvas.width, canvas.height).data;
  // Curve alone: gridlines are drawn at fifth of this opacity.
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
  const said = document.getElementById('diagnostic-exceedance-axis').textContent;
  return {
    top, bottom, rightmost, height: canvas.height, width: canvas.width,
    milliseconds: Number((said.match(/0\u2013(\d+(?:\.\d+)?) ms/) || [])[1]),
  };
});
report(
  'the curve climbs from 0% at the fastest frame to 100% at the slowest',
  // Sample bottom to top of canvas, which plot is whole of.
  //   Rates and durations are drawn over it rather than in rows of their own, so curve
  //   owns full height.
  //   And all way out to slowest frame window holds, which on window this size is far
  //   edge, axis being fitted to exactly that frame.
  reach.top <= 2 && reach.bottom >= reach.height - 3 &&
    // Allow axis's own deadband of far edge.
    //   Glide settles couple of percent short of extent rather than landing exactly on
    //   it, which is axis holding still rather than chasing last half-millisecond.
    reach.rightmost >= reach.width * 0.95,
  `drawn from row ${reach.top} to ${reach.bottom} of ${reach.height}, ` +
    `out to column ${reach.rightmost} of ${reach.width}`,
);
// Check floor where it actually binds.
//   Window holding nothing slow would otherwise draw axis far narrower and zoom session
//   into its own noise, so it stops at 30 fps mark.
//   Room past it to write that mark's own labels, which is why floor is little wider
//   than mark rather than exactly it.
await page.evaluate(() => {
  for (let i = 0; i < 1024; i += 1) window.__record_kept(5 + Math.random() * 9);
});
await settleAxis();
const floored = await page.evaluate(() => {
  const said = document.getElementById('diagnostic-exceedance-axis').textContent;
  return Number((said.match(/0\u2013(\d+(?:\.\d+)?) ms/) || [])[1]);
});
report(
  'and its axis follows the window without ever closing below the 30 fps mark',
  Number.isFinite(reach.milliseconds) && reach.milliseconds >= 33 &&
    // Allow axis's own deadband at floor.
    //   Glide settles near extent rather than exactly on it, and floor is extent like
    //   any other.
    Number.isFinite(floored) && floored >= MILLISECONDS_FLOOR_DRAWN - 1 &&
    floored <= MILLISECONDS_FLOOR_DRAWN + 2,
  `a mixed window reads 0-${reach.milliseconds} ms, a fast one 0-${floored} ms`,
);

// Read everything axis writes on itself out of canvas by opacity.
//   Four things drawn there are laid down at four different alphas, gridlines faintest,
//   then dashed budget marks, then labels, then curve opaque, so each can be counted
//   apart from others without knowing where any of them went.
const readAxisInk = () => page.evaluate((row) => {
  const canvas = document.getElementById('exceedance');
  const w = canvas.width, h = canvas.height;
  const pixels = canvas.getContext('2d').getImageData(0, 0, w, h).data;
  const alphaAt = (x, y) => pixels[(y * w + x) * 4 + 3];
  const isLabel = (x, y) => alphaAt(x, y) > 120 && alphaAt(x, y) < 230;
  // Find dashed mark as column that starts at very top and carries its alpha down.
  //   Both halves are needed: percentages stacked in left margin put antialiased pixels
  //   at that alpha down similar span of column, and only full-height line begins at
  //   row 0.
  //   Dash pattern leaves gaps, so third of rows is bar.
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
  // Check each mark is named at both ends.
  //   Label ink in top row and in bottom row, within reach of mark's own column on
  //   whichever side it took.
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

// **Both modes name heights curve is read against.** Linear drew five bare rules
// and not one word, so reader could see that some height mattered without being told
// which; log named two of its three decades and left 99.9% ceiling -- whole reason
// to switch to it -- unnamed. Checked in both, because only one of them was ever right.
//   Toggled through element itself rather than real click: drawer is shut at
//   this point in run, and Playwright rightly refuses to click what reader cannot
//   see. What is under test here is what axis draws, not how switch is reached --
//   switch's own wiring is driven with drawer open, further up.
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

// **Each mark is rate and duration.** Dashed line is one ruler read from both ends
// -- "60" above it and "16.7" below -- so reader never converts between two in their
// head. Durations are new half; before them bottom row was empty.
const ink_floor = await readAxisInk();
report(
  'every budget mark is named as a rate above it and a duration below it',
  ink_floor.marks.length >= 3 &&
    ink_floor.named.every((mark) => mark.above > 0 && mark.below > 0),
  `${ink_floor.marks.length} marks at columns ${ink_floor.marks.join(', ')}, ` +
    `named ${ink_floor.named.map((m) => `${m.above}/${m.below}`).join(' ')}`,
);

// **Slowest mark axis is always guaranteed to reach stands clear of its right
// edge.** At floor of exactly 1000/30 30 fps line landed *on* that edge, half pixel
// outside canvas, and its label flipped to cramped inside-left branch -- alone
// among marks in reading right to left. Floor now carries room for it.
report(
  'the 30 fps mark stands inside the axis at its narrowest, with room to name it',
  ink_floor.marks.length > 0 &&
    ink_floor.marks[ink_floor.marks.length - 1] <= ink_floor.w - 15,
  `slowest mark at column ${ink_floor.marks[ink_floor.marks.length - 1]} ` +
    `of ${ink_floor.w}, on a 0-${MILLISECONDS_FLOOR_DRAWN.toFixed(1)} ms floor`,
);

// **And 15 fps mark waits for window that needs it.** It is drawn by same rule
// every other mark is -- only where axis reaches it -- so it must be absent from
// fast window above and present once window holds frames that slow. Floor does not
// widen to accommodate it: 30 fps is what sets minimum.
await page.evaluate(() => {
  for (let i = 0; i < 1024; i += 1) window.__record_kept(10 + Math.random() * 80);
});
await settleAxis();
const ink_wide = await readAxisInk();
report(
  'and the 15 fps mark appears only once the window holds a frame that slow',
  //   Counts alone: that each mark is named is check above's business, and check
  //   that fails for two reasons tells you neither.
  ink_floor.marks.length === 3 && ink_wide.marks.length === 4,
  `${ink_floor.marks.length} marks on a fast window, ${ink_wide.marks.length} on a slow one`,
);

// **Timing rows wear cost they carry.** Twenty-odd numbers say nothing about which
// to look at; continuous ramp keyed on each row's share of *frame* does. Checked as
// ordering rather than against fixed colours, so retuning ramp does not mean
// rewriting this: row that costs more may never wear cooler colour than one that costs
// less. Every branch is opened first -- `refreshDiagnostics` skips what is closed, so
// shut node's rows would be read stale.
await page.evaluate(() => {
  const drawer = document.querySelector('.drawer');
  if (!drawer.classList.contains('open')) document.getElementById('button-drawer').click();
  const section = document.querySelector('.section[data-section="diagnostics"]');
  if (!section.classList.contains('open')) section.querySelector('.section-header').click();
  for (const node of document.querySelectorAll('.diagnostic-node')) {
    if (!node.classList.contains('open')) node.querySelector(':scope > .diagnostic-parent').click();
  }
});
await page.waitForTimeout(600);
const tinted = await page.evaluate(() => {
  // Where along ramp row sits, recovered from colour it actually wears:
  //   ramp is monotone in share, so nearest sampled step to row's own colour is its
  //   position on it. Read this way rather than recomputed, so check tests what
  //   page drew rather than agreeing with it by construction.
  const scratch = document.createElement('span');
  const steps = [];
  for (let i = 0; i < RAMP_TREE.length; i += 1) {
    scratch.style.color = rgbToCss(RAMP_TREE[i].value);
    steps.push(scratch.style.color);
  }
  const positionOf = (colour) => {
    const exact = steps.indexOf(colour);
    if (exact >= 0) return exact;
    // Between two shipped steps: parse and take nearest, which is all ordering needs.
    const read = (text) => (text.match(/\d+/g) || []).map(Number);
    const target = read(colour);
    if (target.length < 3) return -1;
    let best = -1;
    let closest = Infinity;
    for (let i = 0; i < steps.length; i += 1) {
      const step = read(steps[i]);
      const apart = Math.hypot(...[0, 1, 2].map((c) => step[c] - target[c]));
      if (apart < closest) { closest = apart; best = i; }
    }
    return best;
  };
  const rows = [];
  for (const [name] of PHASES_DIAGNOSTIC) {
    const value = element_phase[name];
    if (value === null || element_row[name] === null) continue;
    const said = Number((value.textContent.match(/^([\d.]+)/) || [])[1]);
    if (!Number.isFinite(said)) continue;
    if (value.style.color === '') continue;
    rows.push({
      name, milliseconds: said, step: positionOf(value.style.color),
      colour: value.style.color,
    });
  }
  return { rows, idle: element_phase.idle.style.color };
});
// Check ordering by sorting by cost and walking, never cheaper row further along ramp.
//   Equal step is allowed; rows page left untinted carry no step and sit out of
//   comparison.
const ranked = tinted.rows.filter((r) => r.step >= 0 && r.name !== 'idle')
  .sort((a, b) => b.milliseconds - a.milliseconds);
let is_ordered = true;
for (let i = 1; i < ranked.length; i += 1) {
  if (ranked[i].step > ranked[i - 1].step) is_ordered = false;
}
report(
  'a costlier timing row never wears a cooler colour than a cheaper one',
  ranked.length >= 4 && is_ordered,
  `${ranked.length} tinted rows, worst-first: ` +
    ranked.slice(0, 5).map((r) => `${r.name} ${r.milliseconds} step ${r.step}`).join(', '),
);
// Check frame's leftover is left alone.
//   It is largest share of healthy frame, so tinting it would paint best case in ramp's
//   loudest colour.
report(
  "and the frame's own idle time is left uncoloured, being no work at all",
  tinted.idle === '',
  `idle carries ${tinted.idle === '' ? 'no inline colour' : tinted.idle}`,
);

// **Every time in tree ends in one column.** That is whole reason counts moved
// off end of value: trailing tally pushed `ms` inward on exactly rows that
// had one, so units landed at three different places down column of twenty numbers.
// Asserted on rendered geometry, not on strings, because it is claim about where
// things *are*.
const aligned = await page.evaluate(() => {
  // Measure where `ms` itself ends, not where its box does.
  //   Row is flex-laid with value right-aligned, so box's own edge is identical whatever
  //   it contains, which makes it useless as evidence.
  //   Range over two characters measures thing reader's eye actually runs along.
  const edges = new Set();
  const trailing = [];
  for (const [name] of PHASES_DIAGNOSTIC) {
    const value = element_phase[name];
    if (value === null || value.firstChild === null) continue;
    const text = value.textContent;
    const at = text.lastIndexOf('ms');
    if (at < 0) continue;
    const span = document.createRange();
    span.setStart(value.firstChild, at);
    span.setEnd(value.firstChild, at + 2);
    edges.add(Math.round(span.getBoundingClientRect().right));
    if (!/ ms$/.test(text)) trailing.push(name + ': ' + text);
  }
  return { edges: [...edges], trailing };
});
report(
  'every timing row ends its unit in the same column',
  aligned.edges.length === 1 && aligned.trailing.length === 0,
  `${aligned.edges.length} distinct ms column(s) at ${aligned.edges.join(', ')}` +
    (aligned.trailing.length === 0 ? '' : `; trailing past ms: ${aligned.trailing.join(', ')}`),
);

// **Ramp says what it claims to say**: row's share of frame, walked by ratio
// rather than by difference, ending at whole frame. Checked on rule itself rather
// than on rendered row -- decade of cost must be fixed distance along ramp
// wherever it is taken, linear toe must be worth exactly one more of those, ends
// must be nothing and whole frame, and walk must never go backwards. Tolerance
// is tight because symlog makes decades exactly equal; approximation that only
// converges to it -- `log1p`, which this replaced -- misses by 0.11 and fails here.
//   Nothing caps it. Band ceiling tree used to carry existed because old tint
// was share of frame's *work*, relative measure that painted costliest row red
// on session where nothing was slow -- so it had to be held down to whatever band
// curve above it was drawing. Share of whole frame is already absolute.
const ramp_rule = await page.evaluate(() => {
  const walked = [];
  for (let i = 0; i <= 100; i += 1) walked.push(positionRampTree(i / 100));
  return {
    full: SHARE_RAMP_FULL_DIAGNOSTIC,
    knee: SHARE_RAMP_KNEE_DIAGNOSTIC,
    at_none: positionRampTree(0),
    at_full: positionRampTree(1),
    toe: positionRampTree(SHARE_RAMP_KNEE_DIAGNOSTIC),
    decade_low: positionRampTree(0.1) - positionRampTree(0.01),
    decade_high: positionRampTree(1) - positionRampTree(0.1),
    rising: walked.every((at, i) => i === 0 || at > walked[i - 1]),
    steps: RAMP_TREE.length,
  };
});
const decade_apart = Math.abs(ramp_rule.decade_low - ramp_rule.decade_high);
const toe_apart = Math.abs(ramp_rule.toe - ramp_rule.decade_low);
report(
  'a decade of cost is a fixed distance along the tree ramp, whole frame to whole ramp',
  ramp_rule.full === 1 && ramp_rule.at_none === 0 && ramp_rule.at_full === 1 &&
    ramp_rule.rising && decade_apart < 1e-9 && toe_apart < 1e-9 && ramp_rule.steps > 8,
  `knee at ${ramp_rule.knee} of the frame over ${ramp_rule.steps} steps; ` +
    `under the knee spans ${ramp_rule.toe.toFixed(4)} of the ramp, ` +
    `1% -> 10% spans ${ramp_rule.decade_low.toFixed(4)}, ` +
    `10% -> all spans ${ramp_rule.decade_high.toFixed(4)}`,
);
// **And it discriminates on real frame**, which is whole reason for ratio scale.
// Laid out linearly rows of comfortable session all landed within two of seventeen
// steps and tree read as one colour. Measured in **ramp steps recovered from what
// page drew**, reusing positions ordering check above already read back: counting
// distinct colours instead would not bite, since rounding alone makes near-identical rows
// come out as different `rgb()` strings -- checked, and linear scale passed that way.
//   Span is between row costing nothing, which every session has, and its costliest,
// which on this page's own frames is few percent. Third of ramp is floor:
// linear scale reaches one step of seventeen where this reaches nine.
const STEPS_SPREAD_RAMP_MIN = Math.ceil((ramp_rule.steps - 1) / 3);
const stepped = tinted.rows.filter((r) => r.step >= 0 && r.name !== 'idle');
const span_steps = stepped.length === 0 ? 0
  : Math.max(...stepped.map((r) => r.step)) - Math.min(...stepped.map((r) => r.step));
report(
  'the tinted rows spread down the ramp rather than crowding its first steps',
  span_steps >= STEPS_SPREAD_RAMP_MIN,
  `the rows cover ${span_steps} of the ramp's ${ramp_rule.steps} steps ` +
    `(${Math.min(...stepped.map((r) => r.step))} to ` +
    `${Math.max(...stepped.map((r) => r.step))}), floor ${STEPS_SPREAD_RAMP_MIN}`,
);

// And shipped ramp is one tool verified against CET-I1:
//   its ends are map's own, so hand-edited table or stale build shows up here rather than only on
//   screen.
const ramp_ends = await page.evaluate(() => ({
  first: RAMP_TREE[0].label.map((c) => Math.round(c * 255)),
  last: RAMP_TREE[RAMP_TREE.length - 1].label.map((c) => Math.round(c * 255)),
}));
report(
  'the shipped ramp runs from the map\'s cyan to its orange',
  ramp_ends.first[2] > ramp_ends.first[0] && ramp_ends.last[0] > ramp_ends.last[2] &&
    ramp_ends.first[1] > 100 && ramp_ends.last[1] > 60,
  `cyan end rgb(${ramp_ends.first.join(', ')}), orange end rgb(${ramp_ends.last.join(', ')})`,
);
// **Breakdown adds up.** For long time it did not, and nothing said so:
//   frame's prologue and its view matrix belonged to no row, so `build` was simply larger than sum
//   of what it showed and reader had no way to know how much was missing.
//   Every span is now named, `unaccounted` included, and this is check that keeps it that way.
const summed = await page.evaluate(() => {
  const runs = [];
  for (let i = 0; i < 30; i += 1) {
    nimSetCameraAzimuth(0.01 * i); // Rebuild furniture, so sum covers real work.
    const f = nimBuildFrame(1200 / 900, performance.now() / 1000, 900, true, true, false);
    const children = f.ms_camera + f.ms_furniture + f.ms_scene + f.ms_algebra +
      f.ms_matrix + f.ms_flatten + f.ms_unaccounted;
    runs.push({ build: f.ms_build, children, placing: f.ms_placing, emitting: f.ms_emitting });
  }
  const worst = runs.reduce((a, b) =>
    (Math.abs(b.build - b.children) > Math.abs(a.build - a.children) ? b : a));
  return {
    n: runs.length, off: worst.build - worst.children,
    build: worst.build, children: worst.children,
    placing: Math.max(...runs.map((r) => r.placing)),
    emitting: Math.max(...runs.map((r) => r.emitting)),
  };
});
report(
  "build accounts for itself: its rows sum to it, with the residue named",
  // Exact but for clock's own resolution -- these are all reads of one timer, so.
  //   only slack needed is rounding it does, not proportional tolerance.
  Math.abs(summed.off) <= 0.05,
  `worst of ${summed.n} frames: ${summed.build.toFixed(2)} against ` +
    `${summed.children.toFixed(2)} from its rows, off by ${summed.off.toFixed(3)} ms`,
);

// **And second cut says something.** Both sides of algebra boundary must be
// carrying real time on frame that draws scene -- split that reads zero on one side
// is bracket that never ran, which is exactly failure cut like this hides.
report(
  'and both sides of the algebra boundary carry time on a frame that draws',
  summed.placing > 0.01 && summed.emitting > 0.01,
  `placing peaked at ${summed.placing.toFixed(2)} ms, emitting at ` +
    `${summed.emitting.toFixed(2)} ms`,
);

// **Axis waits, then glides; it never jumps.** Fitted frame for frame it snapped:
//   one slow frame widened it and moment that frame aged out it snapped back, so two glances second
//   apart could not be compared.
//   Driven exactly as that happens:
//   settled window, then one much slower frame put into it.
//   Immediately after, axis must not have moved at all -- that wait is what lets dip-and-return
//   leave it where it was -- and some seconds later it must have arrived, having passed through
//   middle rather than jumped.
const axis_reading = () => page.evaluate(() => {
  drawExceedance();
  return Number((document.getElementById('diagnostic-exceedance-axis').textContent
    .match(/0\u2013(\d+(?:\.\d+)?) ms/) || [])[1]);
});
await page.evaluate(() => {
  for (let i = 0; i < 1024; i += 1) window.__record_kept(40 + Math.random() * 2);
});
await settleAxis();
const axis_settled = await axis_reading();
// One frame three times slower than anything else in window, and nothing else changed.
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
    // Unmoved while wait stands.
    axis_at_once === axis_settled &&
    // Under way, but not there yet: glide passes through middle.
    axis_midway > axis_settled && axis_midway < axis_arrived &&
    // Arrived at slow frame's own bucket, which is what window now reaches to.
    axis_arrived >= 120,
  `settled 0-${axis_settled} ms; at once 0-${axis_at_once}; after 1 s 0-${axis_midway}; ` +
    `arrived 0-${axis_arrived}`,
);

// **Vertical axis switches, and curve switches with it.** Linear reads
// proportion as proportion; log reads three decades of distance from top, which
// is only way slowest one percent is legible at all. Driven through pill
// reader actually presses rather than by setting flag, since flag being right and
// button being wired are separate claims -- and held on pixels, because same
// data drawn against different axis is different curve.
const axes_curve = await page.evaluate(async () => {
  const inked = () => {
    const canvas = document.getElementById('exceedance');
    const pixels = canvas.getContext('2d')
      .getImageData(0, 0, canvas.width, canvas.height).data;
    // Curve alone, at opacity only it is drawn with, summarised as row each.
    //   column's mark sits on -- which is shape of curve and nothing else.
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
  const caption = document.getElementById('diagnostic-exceedance-axis');
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

// **Step too quick for clock still reports time.** Every mobile browser coarsens
// and jitters `performance.now` against timing attacks, so sub-millisecond phase can
// measure as zero or below. Absence used to be marked by negative in value's own
// range, which made such reading indistinguishable from "this never ran" -- and left
// every sub-millisecond row of tree em dash on phone while six-millisecond
// ones read fine. Driven with exactly that: phase whose every measurement is zero or
// negative must still report, at zero.
// Both synthetic runs below fill rings by hand, and `recordFrameTime` clears every
// phase's presence as it advances -- so they hand rings back exactly as they found
// them. Without that, check reading real phase after one of these reads ring this
// harness itself wiped, and reports page broken when it was driving that was.
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
  for (const node of document.querySelectorAll('.diagnostic-node')) node.classList.add('open');
  // Frame ring is advanced first and phases written into it after, exactly as.
  //   draw loop does it, so slots line up way they really would.
  for (let i = 0; i < 240; i += 1) {
    recordFrameTime(16.7);
    recordPhaseTime('sky', i % 2 === 0 ? 0 : -0.4);
  }
  refreshDiagnostics();
  return {
    text: document.getElementById('diagnostic-sky').textContent,
    median: medianPhase('sky'),
  };
});
report(
  'a step too quick for the clock to measure still reports, at zero',
  unmeasured.median === 0 && unmeasured.text.startsWith('0.00 (0.00) ms'),
  `the row reads "${unmeasured.text}", median ${unmeasured.median}`,
);

// **Reading is mean over 200 ms, not newest frame.** One frame's number changes
// several times faster than it can be read, which is what made these rows flicker. Driven
// with phase that alternates between 1 ms and 9 ms every frame: newest frame is
// always one or other, and only averaged reading lands between them.
const smoothed = await page.evaluate(() => {
  for (const node of document.querySelectorAll('.diagnostic-node')) node.classList.add('open');
  for (let i = 0; i < 240; i += 1) {
    recordFrameTime(16.7);
    recordPhaseTime('overlay', i % 2 === 0 ? 1 : 9);
  }
  refreshDiagnostics();
  return {
    text: document.getElementById('diagnostic-overlay').textContent,
    frames: framesRecent(),
  };
});
// **Slowest frame in ring is named with its own split.** Rows are 200 ms means, which
// dilute one spike past telling whether page authored it; readout reads that frame's
// own slots. Driven with one 30 ms frame carrying 6 ms of `ui` among 16.7 ms frames
// carrying 0.5, so page, its largest phase and browser's remainder are all known.
const slowest = await page.evaluate(() => {
  for (let i = 0; i < 240; i += 1) {
    recordPhaseTime('build', 1);
    recordPhaseTime('ui', i === 100 ? 6 : 0.5);
    recordPhaseTime('render', i === 100 ? 3 : 0.2);
    recordFrameTime(i === 100 ? 30 : 16.7);
  }
  refreshDiagnostics();
  return document.getElementById('diagnostic-slowest').textContent + ' / ' +
    document.getElementById('diagnostic-slowest-split').textContent;
});
report(
  'the slowest frame in the ring is named, split between the page and the browser',
  slowest === '30.0 ms / 7.0 (ui 6.0) \u00b7 23.0 (render 3.0)',
  `the rows read "${slowest}"`,
);
// **Each experiment pill switches its suspect off, and back.** Blur through one class
// on body, pixel ratio through canvas's own backing store, overlay through its display.
const experiments = await page.evaluate(() => {
  const gl_canvas = document.getElementById('gl');
  const width_full = gl_canvas.width;
  const click = (id) => document.getElementById(id).click();
  click('toggle-blur');
  const is_blur_off = document.body.classList.contains('without-blur');
  click('toggle-blur');
  const is_blur_back = !document.body.classList.contains('without-blur');
  click('toggle-full-ratio');
  const width_low = gl_canvas.width;
  click('toggle-full-ratio');
  const width_back = gl_canvas.width;
  click('toggle-overlay');
  const is_overlay_off = document.getElementById('overlay').style.display === 'none';
  click('toggle-overlay');
  const is_overlay_back = document.getElementById('overlay').style.display === '';
  const ratio = Math.min(window.devicePixelRatio || 1, 2.5);
  return { is_blur_off, is_blur_back, width_full, width_low, width_back, ratio,
    is_overlay_off, is_overlay_back };
});
report(
  'each experiment pill switches its suspect off, and back on',
  experiments.is_blur_off && experiments.is_blur_back &&
    experiments.is_overlay_off && experiments.is_overlay_back &&
    experiments.width_back === experiments.width_full &&
    (experiments.ratio === 1
      ? experiments.width_low === experiments.width_full
      : experiments.width_low < experiments.width_full),
  `blur ${experiments.is_blur_off}/${experiments.is_blur_back}, canvas ` +
    `${experiments.width_full} -> ${experiments.width_low} -> ${experiments.width_back} ` +
    `at ratio ${experiments.ratio}, overlay ${experiments.is_overlay_off}/` +
    `${experiments.is_overlay_back}`,
);
await restoreRings(kept_rings);
// **Browser's own rendering is timed, frame by frame, while panel is shown.** Message
// posted as callback ends runs once style, layout, paint and commit are done; row
// is main-thread share of `display wait + browser`, never more than that remainder.
// Read off live ring after second with panel open: most frames carry reading, none
// negative, and each under its frame.
//   On ring restored above rather than synthetic one: synthetic loop advanced ring by
//   exactly one wrap inside one task, which put in-flight message back on its own slot.
const rendered = await page.evaluate(async () => {
  if (!document.getElementById('drawer').classList.contains('open')) {
    document.getElementById('button-drawer').click();
  }
  document.querySelector('.section[data-section="diagnostics"]').classList.add('open');
  written_phase.render.fill(0); // Only frames timed from here on are read.
  await new Promise((r) => setTimeout(r, 1200));
  let written = 0, bad = 0;
  for (let i = 0; i < FRAMES_HISTORY; i += 1) {
    if (i === index_history_frame || written_phase.render[i] !== 1) continue;
    written += 1;
    const v = history_phase.render[i];
    if (!(v >= 0) || v > history_frame[i] + 1) bad += 1;
  }
  return { written, bad, text: document.getElementById('diagnostic-render').textContent };
});
report(
  'the browser\'s style, layout and paint are timed frame by frame ' +
    'while the panel is shown',
  rendered.written >= 20 && rendered.bad === 0 && / ms$/.test(rendered.text),
  `${rendered.written} frames timed, ${rendered.bad} out of range, row "${rendered.text}"`,
);
// **Rows account for whole frame, not fraction of it.** Everything page
// spends is `build + upload + overlay + menu + ui`; rest of frame is waiting on
// display plus browser's own style, layout, paint, compositing and collection. Without
// that remainder on panel spike could not be told from stall in page's own
// code, which is first thing reader needs to know. Held frame by frame: six rows
// must reconstruct frame time they are breakdown of.
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
  // Exact but for float32 rounding on bridge's own three phases.
  accounted.n > 100 && accounted.worst < 0.05,
  `${accounted.n} frames reconstructed, worst off by ${accounted.worst.toFixed(4)} ms`,
);

report(
  'a reading is the mean over the last 200 ms, not whatever the newest frame said',
  // 200 ms of 16.7 ms frames is dozen of them, and dozen alternating 1s and 9s mean 5.
  smoothed.text.startsWith('5.00 ') && smoothed.frames >= 9 && smoothed.frames <= 16,
  `the row reads "${smoothed.text}" over ${smoothed.frames} frames`,
);

// **Algebra's own layer draws what picture only stands for.** Ordinary picture
// draws plane as disc of fixed radius, because infinite surface would bury
// everything; switched on, debug layer draws it as infinite lattice it actually is,
// reaching furniture's own extent instead of `EXTENT_PLANE`. It also draws geometry
// scene does not contain at all -- camera's sight axis, its near plane, ray under
// cursor -- so toggle has to change more than tint.
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
    // Ribbons: lattice is drawn as ribbons, as every line in this build is.
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

// **Plane is drawn infinite, not as its disc.** Lattice reaches furniture's own
// extent, which is far outside fixed radius disc stands at -- so furthest thing
// layer draws has to lie well beyond `EXTENT_PLANE`, or plane is still disc.
const reached = await page.evaluate((EXTENT_PLANE_DRIVE) => {
  const data = nimBuildFrame(1.4, 2.0, 700, false, false, true);
  // Furniture off, so every vertex counted here belongs to scene and layer over it.
  let furthest = 0;
  const v = data.ribbon_verts;
  // Sixteen floats record now widening and fog both run in shaders: tail.
  //   xyz, head xyz, width, fog, then two tints. Both ends are positions lattice
  //   actually reaches.
  for (let i = 0; i < v.length; i += 16) {
    furthest = Math.max(furthest,
      Math.hypot(v[i], v[i + 1], v[i + 2]), Math.hypot(v[i + 3], v[i + 4], v[i + 5]));
  }
  return { furthest, extent_plane: EXTENT_PLANE_DRIVE };
}, 8.0); // `mesh.EXTENT_PLANE`, fixed radius plane's disc stands at.
report(
  'a plane is drawn as the infinite thing it is, not as the disc that stands for one',
  reached.furthest > 4*reached.extent_plane,
  `furthest lattice vertex ${reached.furthest.toFixed(1)} units out, ` +
    `against a disc of ${reached.extent_plane}`,
);

// **Scene phase, broken down by kind of object each millisecond went to.**
// kinds differ by two orders of magnitude -- point is one vertex, plane rim of
// ribbons each carrying its own join -- so reader asking why scene is slow needs
// split, not total. Held only way breakdown can be held honest: parts must
// account for whole they are parts of, frame by frame, and each part must carry
// count it is time for.
const kinds = await page.evaluate(() => window.__phase_frame.slice(2).map((p) => ({
  scene: p.scene,
  parts: p.points + p.lines + p.planes + p.sky + p.ghost + p.selected,
  counted: p.count_points + p.count_lines + p.count_planes +
    p.count_sky + p.count_ghost + p.count_selected,
})));
// Parts may never exceed whole by more than rounding, and must account for.
//   bulk of it -- but not for all of it: phase also walks all 64 slots twice, marks
//   overlay and packs view-projection, and none of that belongs to any one kind. That
//   remainder is share of frame rather than fixed cost, so floor is share
//   too; fixed 3 ms floor failed one frame in sixty when frame itself ran long.
const kinds_sane = kinds.filter((k) =>
  k.parts <= k.scene + 0.6 && k.parts >= k.scene - Math.max(3.0, 0.3 * k.scene) &&
  k.counted > 0);
// **Share of frames rather than all of them**, at unchanged per-frame tolerance.
//   Every reading is quantised to tenth of millisecond, so summing six parts against one
//   whole carries up to 0.35 ms of rounding before any real disagreement, and frame whose
//   brackets straddle collection adds more. Demanding *every* frame account held for ten
//   runs at around 600 frames and then failed twice at 825 as container sped up and
//   sample grew -- which is property of sample size, not of accounting.
//   Loosening per-frame tolerance instead would have weakened check on all 800;
//   quantile keeps it exactly as strict per frame, since real accounting fault misses on
//   every frame and cannot hide inside four of them.
const FRACTION_KINDS_ACCOUNT = 0.995;
report(
  'the scene phase is accounted for by the kinds it is spent on',
  kinds.length > 30 && kinds_sane.length >= FRACTION_KINDS_ACCOUNT*kinds.length,
  `${kinds_sane.length} of ${kinds.length} frames account ` +
    `(floor ${Math.ceil(FRACTION_KINDS_ACCOUNT*kinds.length)}), ` +
    `last frame ${kinds.length ? kinds[kinds.length - 1].parts.toFixed(2) : '?'} of ` +
    `${kinds.length ? kinds[kinds.length - 1].scene.toFixed(2) : '?'} ms ` +
    `over ${kinds.length ? kinds[kinds.length - 1].counted : '?'} objects`,
);
await page.evaluate(() =>
  document.querySelector('.diagnostic-node[data-node="furniture"] > .diagnostic-parent').click());
await page.waitForTimeout(400);
const readRow = (names) => page.evaluate((given) => Object.fromEntries(given.map((n) => {
  const value = document.getElementById('diagnostic-' + n);
  return [n, {
    value: value.textContent,
    label: value.closest('.diagnostic-line').querySelector('span').textContent,
  }];
})), names);
const rows_scenery = await readRow(['grid', 'axes']);
report(
  'and both halves have their own row, the grid carrying its segment count',
  // Count sits beside row's **name**, so every value ends in `ms` and times.
  //   down tree finish in one column; grid names its segments, axes name none.
  / ms$/.test(rows_scenery.grid.value) && /\(\d+\)$/.test(rows_scenery.grid.label) &&
    / ms$/.test(rows_scenery.axes.value) && !/\(\d+\)$/.test(rows_scenery.axes.label),
  `grid: ${rows_scenery.grid.label} ${rows_scenery.grid.value}, ` +
    `axes: ${rows_scenery.axes.label} ${rows_scenery.axes.value}`,
);

await page.evaluate(() =>
  document.querySelector('.diagnostic-node[data-node="scene"] > .diagnostic-parent').click());
await page.waitForTimeout(400);
const rows_kind = await readRow(['points', 'lines', 'planes', 'sky', 'ghost', 'selected']);
report(
  'each kind reports its own count beside its own name',
  Object.values(rows_kind).every((r) =>
    / ms$/.test(r.value) && /\(\d+\)$/.test(r.label)),
  Object.entries(rows_kind).map(([n, r]) => `${n}: ${r.label} ${r.value}`).join(', '),
);

// **Scenery, at distance where it used to cost most.** Its price is its
// segment count, and that count climbs with camera distance until cell steps decade
// and drops it back -- so worst frame is not farthest one but one just before
// step. Measured at orbit distance 300 before budget: 2,084 segments and 126.5 ms of
// grid, against 154 and 7.3 ms at opening view. Held here at that same distance,
// through bridge's own grid clock and segment count, as band rather than figure.
const scenery_far = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  const distance_before = nimCameraDistance();
  nimSetCameraDistance(300);
  const milliseconds = [];
  let segments = 0;
  for (let i = 0; i < 9; i += 1) {
    nimCameraOrbit(0.005, 0); // Move, so furniture cache cannot hold and it rebuilds.
    const data = nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true);
    milliseconds.push(data.ms_grid);
    segments = data.count_grid_segments;
  }
  nimSetCameraDistance(distance_before);
  milliseconds.sort((a, b) => a - b);
  return { median: milliseconds[4], segments };
});
report(
  'the scenery holds its line bound where it used to cost the most',
  // Bound at one record per lattice line, since fog fade is fragment shader's.
  //   Two families of at most `2*CELLS_GRID_HALF_MAX + 1` lines each.
  scenery_far.segments > 0 && scenery_far.segments <= 2 * (2 * 120 + 1),
  `${scenery_far.segments} grid records at orbit distance 300, ` +
    `${scenery_far.median.toFixed(1)} ms of grid`,
);

// Same budget while camera actually moves, which is when reader felt it collapse:
//   moving camera rebuilds ground grid every frame, and per-segment multivector churn once put that
//   rebuild at 3x still frame's whole build.
//   Band is generous for same reason still ones are -- it exists to catch collapse, not to time
//   this container -- and drag is real one, from empty sky, so frames sampled are frames hand would
//   feel.
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
// **Scenery, split into two halves that answer differently to distance.** Axes
// are three lines however far camera stands; grid is however many ground reach
// asks for, and its cost *is* its segment count. Bridge has clocked them apart since
// grid gained its budget; these are rows that show it.
const scenery = await page.evaluate((from) => window.__phase_frame.slice(from),
  index_before_drag);
const scenery_moving = scenery.filter((p) => p.furniture > 0.05);
// Slack is **proportional**, as per-kind check's is and for same reason:
//   bracket around two halves also spans mesh clear and loop between them, and on frame scheduler
//   interrupts that gap grows with frame rather than by fixed amount.
//   Flat +-1 ms was ample on 8 ms rebuild and failed one frame in hundred and twenty on 15 ms one
//   -- flake, not finding, and flaky check gets deleted rather than fixed.
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
      // Worst frame, not last: bare count says nothing about what went wrong.
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
// Band grew from 20 when `directionAcross` was triple join.
//   It is cross product again -- ribbon is picture's business, not algebra's, see boundary in
//   PROVENANCE.md -- so that justification has lapsed, and band is now simply what catches collapse
//   class reader felt (30+ ms builds) without timing this container.
//   **It is close to bone on loaded shared runner**:
//   identical code has measured 25.0 and 29.8 ms hours apart here.
//   Failure at 27-30 says to re-measure against previous commit before believing it; failure well
//   past 30 is collapse this exists for.
reportWithin(
  'a frame is still assembled inside its budget while the camera moves',
  work_moving === null ? -1 : work_moving.median, 0, 26, 'ms',
);

// What buys that:
//   camera that has not moved draws very same grid and axes, so they are built once and held -- and
//   loop above should have held them on nearly every one of frames it just drew, since nothing
//   moved camera for those two seconds.
report(
  'a still camera holds its ground and axes rather than rebuilding them',
  work_frame !== null && work_frame.held > 0.8 * work_frame.n,
  `${work_frame === null ? 0 : work_frame.held} of ` +
    `${work_frame === null ? 0 : work_frame.n} frames held`,
);
// Stated directly too, since share of frames could be right by accident:
//   move camera, so next call must build, and one after it must hold.
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
// And camera that has moved rebuilds them, or view would keep grid it has left.
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

/* ---- Performance regression pins ---- */

// Pin every repaired performance fault to band few times its repaired cost.
//   Generous enough to survive loaded shared runner, tight enough to catch fault class
//   returning, since every fault below was large multiplier while it was alive.
//   Faults themselves, their causes and their measurements live in PROVENANCE.md's
//   performance ledger.
//   Raising band is sign-off.
//     Band is changed only with justification recorded beside ledger entry it pins,
//     never adjusted to quiet failure unexamined.
//     Failure just past band on slow run says re-measure against previous commit
//     first; failure at multiples of it is fault this exists for.
const BANDS_PERF = {
  hover_pick_ms: 5, // Repaired 1.5 ms; scene-copy-per-slot fault measured 7.1.
  anchor_us: 100, // Repaired 8 us; extent-tuple + Item-copy fault measured 280.
  marker_pair_ms: 4, // Worst live shape; repaired ~1.2 ms, per-sample sums ~3.2.
  grid_moving_ms: 20, // Repaired 8.7 ms; per-boundary fade sampling measured 26.1.
  emitting_moving_ms: 4.5, // Repaired ~1.2 ms; CPU ribbon/fan expansion measured 6.3.
  debug_layer_ms: 12, // Repaired 4.7 ms; per-piece lattice fades measured 18.5.
};

// Hover pick must stay off copy paths:
//   it walks scene by slot (never through `pairs`, whose Item carries whole Scene by value on this
//   backend) and steps horizon circle off fixed angle table.
//   It runs on every pointer move, which is why no frame row ever showed it.
const pin_pick = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  nimUpdateCursor(canvas.clientWidth / 2, canvas.clientHeight / 2);
  const times = [];
  for (let i = 0; i < 25; i += 1) {
    const start = performance.now();
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  return times[12];
});
reportWithin(
  'a hover pick stays off the scene-copy paths', pin_pick, 0, BANDS_PERF.hover_pick_ms,
  'ms median',
);

// Anchor lookup must stay projection, not copy:
//   overlay view cache hands out no `(DrawExtent, Matrix4)` value pair, and item is read by slot.
const pin_anchor = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const slot = nimSceneSlots()[0];
  const start = performance.now();
  for (let i = 0; i < 400; i += 1) {
    nimAnchorScreen(slot, canvas.clientWidth, canvas.clientHeight);
  }
  return (1000 * (performance.now() - start)) / 400;
});
reportWithin(
  'an anchor lookup stays a projection, not a copy', pin_anchor, 0, BANDS_PERF.anchor_us,
  'us mean',
);

// Marker and its pulse must shape into caller storage and off fixed angle table:
//   `markerFor` fills shared `var Marker`, nothing walks its fixed arrays through nimCopy, and loop
//   and band rings are stepped rather than assembled.
//   **Worst live shape, never slot zero.** Point's marker is ring of four
// floats and line's or plane's is sampled outline order of magnitude dearer, so
// pin that happened to time point would pass while selected plane cost multiples
// of it -- which is exactly how this cost stayed hidden until it was decomposed.
const pin_marker = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  let worst = { ms: 0, word: 'none' };
  for (const slot of nimSceneSlots()) {
    const start = performance.now();
    for (let i = 0; i < 30; i += 1) {
      nimSelectionMarker(slot, canvas.clientWidth, canvas.clientHeight, 1, false, 0);
      nimSelectionPulse(slot, canvas.clientWidth, canvas.clientHeight, 1, false);
    }
    const ms = (performance.now() - start) / 30;
    if (ms > worst.ms) worst = { ms, word: nimItemShapeWord(slot) };
  }
  return worst;
});
reportWithin(
  `a marker and its pulse shape without copying (worst: ${pin_marker.word})`,
  pin_marker.ms, 0, BANDS_PERF.marker_pair_ms, 'ms mean',
);

// Grid and CPU emit must stay at one record per line with fog fade in fragment shader:
//   moving-camera rebuild is frame this repository has spent most rounds on, and its cost is line
//   count and nothing else now.
const pin_grid = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  const distance_before = nimCameraDistance();
  nimSetCameraDistance(300);
  const grid = [];
  const emitting = [];
  for (let i = 0; i < 9; i += 1) {
    nimCameraOrbit(0.005, 0); // Move, so furniture cache cannot hold.
    const data = nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true);
    grid.push(data.ms_grid);
    emitting.push(data.ms_emitting);
  }
  nimSetCameraDistance(distance_before);
  grid.sort((a, b) => a - b);
  emitting.sort((a, b) => a - b);
  return { grid: grid[4], emitting: emitting[4] };
});
reportWithin(
  'the moving grid stays at one record per line', pin_grid.grid, 0,
  BANDS_PERF.grid_moving_ms, 'ms median',
);
reportWithin(
  'the CPU emit stays a copy of records, not an expansion', pin_grid.emitting, 0,
  BANDS_PERF.emitting_moving_ms, 'ms median',
);

// Debug layer must keep riding shared lattice machinery:
//   traced plane is lattice lines at one record each, not fade pieces, and trace is read by slot.
const pin_debug = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  const layer = [];
  for (let i = 0; i < 15; i += 1) {
    const data = nimBuildFrame(
      aspect, performance.now() / 1000, canvas.height, true, true, true,
    );
    layer.push(data.ms_algebra);
  }
  layer.sort((a, b) => a - b);
  return layer[7];
});
reportWithin(
  'the debug layer rides the shared lattice machinery', pin_debug, 0,
  BANDS_PERF.debug_layer_ms, 'ms median',
);

// Overlay must reuse its own SVG elements rather than rebuilding layer:
//   mark nodes standing now, let draw loop run, and same nodes must still be there -- layer cleared
//   with innerHTML creates fresh nodes every frame and keeps none.
await page.keyboard.press('Home'); // Earlier checks left camera wherever they orbited
await page.waitForTimeout(800); //   it; hover below needs anchor actually on screen.
const pixel_hover_pool = await pixelOf((await page.evaluate(() => nimSceneSlots()))[0]);
await page.mouse.move(pixel_hover_pool[0], pixel_hover_pool[1]);
await page.waitForTimeout(250);
const pin_pool = await page.evaluate(async () => {
  const layer = document.getElementById('overlay');
  const before = layer.children.length;
  for (const element of layer.children) element.__probe_pool = true;
  await new Promise((resolve) => setTimeout(resolve, 150));
  let kept = 0;
  for (const element of layer.children) if (element.__probe_pool) kept += 1;
  return { before, after: layer.children.length, kept };
});
report(
  'the overlay reuses its elements across frames rather than rebuilding',
  pin_pool.before > 0 && pin_pool.kept > 0,
  `${pin_pool.kept} of ${pin_pool.after} elements survived from ${pin_pool.before} ` +
    'marked a few frames earlier',
);

/* ---- Nothing may have thrown along way ----     */

/* ---- Touch drags as finger really performs them ----   */

// Last of checks, and deliberately so:
//   these build objects, and budget and zoom checks above are written against opening scene's own
//   weight and layout.

// `Home` glides camera back rather than snapping it, so anything that reads object's.
//   own pixel has to wait for glide to finish -- pixel read mid-flight names where
//   object *was*, and press then lands on empty space.
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

// **Finger that eases into its drag rather than flicking.** Press target chooses
// scheme, so press on object is construction press from moment it lands -- but
// touch used to orbit over few pixels before tap slop was crossed, which latched
// camera-dragging flag, and hover is suppressed while camera moves. Construction
// drag that armed moment later then ran blind for rest of gesture: no destination,
// no ghost, nothing built. Driven here in sub-slop steps, which is what real finger does
// and what no flick-speed check could reach.
await clearTheGlass();
await page.keyboard.press('Home');
await settleCamera();
await page.evaluate(() => nimSelectClear());
// Read afresh, for same reason section above says: checks between here and.
//   opening scene delete and build, so slot list captured up there is stale.
const points_live = await page.evaluate(() => nimSceneSlots()
  .filter((slot) => nimItemShapeWord(slot) === 'point'));
const count_before_creep = await page.evaluate(() => nimSceneCount());
const camera_before_creep = await page.evaluate(() => ({
  azimuth: nimCameraAzimuth(), elevation: nimCameraElevation(),
}));
const from_creep = await pixelOf(points_live[0]);
const onto_creep = await pixelOf(points_live[1]);
// Four steps of third of slop each, so gesture spends three moves under.
//   threshold before crossing it -- exactly frames that used to orbit.
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
// **Finger chases object's live pixel, not memorised one.** Press starts.
//   aim tween, which glides camera target toward drag -- so every anchor
//   moves on screen while gesture is still in flight. Real finger tracks thing
//   it is reaching for; finger creeping to where object stood at press misses
//   it by exactly tween's progress, which is why this raced runner's own speed
//   -- slow frames left anchors near their read positions, fast ones did not.
for (let step = 1; step <= 8; step += 1) {
  const onto_live = await pixelOf(points_live[1]);
  await touchAt('touchMove', [{
    x: from_creep[0] + ((onto_live[0] - from_creep[0]) * step) / 8,
    y: from_creep[1] + ((onto_live[1] - from_creep[1]) * step) / 8,
  }]);
  await page.waitForTimeout(35);
}
// And last touch settles on wherever object stands now, so hover read below.
//   is claim about picking rather than about how far tween happened to get.
const onto_final = await pixelOf(points_live[1]);
await touchAt('touchMove', [{ x: onto_final[0], y: onto_final[1] }]);
await page.waitForTimeout(80);
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

// **Plane is pickable over disc it is drawn as, whichever way its normal faces.**
// hit test read depth of raw meet, whose weight carries which side ray crossed
// from, so plane met from behind its normal read as standing behind eye and could not
// be picked anywhere at all -- while ground plane, whose normal happens to face eye,
// picked fine and hid it. Held here on plane gesture itself builds, since that is
// only kind reader makes.
await clearTheGlass();
// Drop lines earlier gestures left.
//   Each built same `b ∧ c` again, and four coincident lines under one finger are crowd
//   touch refuses to drag from; see `interaction.canConstructByTouch`. Line built below
//   is then alone.
await page.evaluate(() => {
  for (const slot of nimSceneSlots()) {
    if (nimItemShapeWord(slot) === 'line') nimRemoveItem(slot);
  }
});
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
// That line joined with third point gives plane, which is what is being reached for.
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
// Sweep canvas for pixel that picks it. Disc this size covers good part of.
//   view, so finding none at all is fault this guards against.
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

// Pick plane from underneath it too, not only from above.
//   Plane has two faces and neither is its front: hit test asks where sight ray crosses,
//   and where is not side.
//   Reading crossing's orientation as its depth makes plane met from behind its own
//   normal report itself behind eye and go unpickable over its whole disc.
//   Ground plane is honest subject for pin: it lies flat, so above and below are same
//   view mirrored, and reading that differs between them is sign leaking back in rather
//   than geometry.
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
// Everything else hidden, so point or line standing in front cannot take pixel.
//   plane would otherwise have answered for and make two sides differ for that reason.
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

// **Scale bar measures what it says it measures.** Bar drawn from one derivation and
// labelled from another is classic way map scale goes quietly wrong, so both halves
// are checked against bridge's own `nimGridMetrics` -- and at two distances decade
// apart, since grid's cell steps by decades and bar that ignored step would still
// pass at single distance.
const rulers = [];
for (const distance of [19, 4000]) {
  await page.evaluate((d) => nimSetCameraDistance(d), distance);
  await page.waitForTimeout(400);
  rulers.push(await page.evaluate((d) => {
    const [cell, world_per_pixel] =
      nimGridMetrics(window.innerWidth, window.innerHeight);
    const label = document.getElementById('ruler-label').textContent;
    const width = document.getElementById('ruler-bar').getBoundingClientRect().width;
    // Span label claims, read back out of label itself -- thin spaces and all.
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

// **Drawer covers scale bar rather than moving or hiding it.** Bar belongs to
// view it measures, so it stays put and drawer is simply drawn over it. It used to
// step aside to drawer's far edge, which on phone -- where drawer is
// full-width sheet -- put it off-screen entirely; reading that vanishes when panel
// opens is worse than one panel is sitting on.
const covered = await page.evaluate(() => {
  const ruler = document.getElementById('ruler');
  const drawer = document.querySelector('.drawer');
  const boxOf = () => ruler.getBoundingClientRect();
  const closed = boxOf();
  document.getElementById('button-drawer').click();
  const open = boxOf();
  const layer = (element) => Number(getComputedStyle(element).zIndex);
  const shown = getComputedStyle(ruler).display !== 'none' &&
    getComputedStyle(ruler).visibility !== 'hidden' && !ruler.hidden;
  document.getElementById('button-drawer').click(); // Leave it as it was found.
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

/* ---- Scene hold ----     */

// **Still camera over still scene rebuilds nothing, and every edit releases that.**
// Scene phase was whole of frame's own work on large scene; frame matching
// last one now skips tessellation, flattens and every upload together.
// danger of hold is not that it fails to engage -- that costs milliseconds -- but that it
// engages when it should not, and shows picture that no longer matches scene. So both
// halves are held here, and second is checked through **drawn pixels** rather than
// through flag: hold that released but drew old records would pass flag check.
await page.evaluate(() => {
  // Switch debug layer off, since it refuses hold outright and earlier check left it on.
  //   It draws cursor's own ray.
  const chip = document.getElementById('toggle-algebra');
  if (chip.classList.contains('on')) chip.click();
  nimSelectClear();
  document.getElementById('gl').focus();
  window.__hold = { held: 0, built: 0 };
  const built = globalThis.nimBuildFrame;
  globalThis.nimBuildFrame = function (...a) {
    const d = built.apply(this, a);
    if (d.is_scene_held) window.__hold.held += 1; else window.__hold.built += 1;
    return d;
  };
  // One rebuild owed to counter above, so both sides of hold are seen.
  //   Inside same task as counter, so no frame can spend it first; recolouring item to
  //   ink it wears moves revision and not one pixel.
  nimSetInk(nimSceneSlots()[0], nimItemInk(nimSceneSlots()[0]));
  // Drawn pixels have to be sampled from **inside** frame that drew them:
  //   context asks for no `preserveDrawingBuffer` (see `glue.js`'s own note at top),
  //   so read from later task finds buffer compositor has already taken. Hooked
  //   onto end of `renderFrame`, where draw has just been issued.
  const canvas = document.getElementById('gl');
  const gl = canvas.getContext('webgl');
  const px = new Uint8Array(canvas.width * canvas.height * 4);
  const drawn = globalThis.renderFrame;
  globalThis.renderFrame = function (...a) {
    const out = drawn.apply(this, a);
    gl.readPixels(0, 0, canvas.width, canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, px);
    // Sample every seventh pixel.
    //   Six-pixel dot, least any point is drawn at, spans six in row and cannot slip
    //   between samples; every thirty-seventh missed undone dot.
    let hash = 2166136261;
    for (let i = 0; i < px.length; i += 4 * 7) {
      hash = Math.imul(hash ^ px[i], 16777619) ^ px[i + 1] ^ (px[i + 2] << 8);
    }
    window.__drawn = hash | 0;
    return out;
  };
});
await page.waitForTimeout(1200);
const idle = await page.evaluate(() => ({ ...window.__hold }));
report(
  'a still camera over a still scene holds its records instead of rebuilding them',
  idle.held > 0.5*(idle.held + idle.built) && idle.built > 0,
  `${idle.held} held, ${idle.built} rebuilt over ~1.2 s`,
);

// Hash what frame loop last drew on coarse pixel grid.
//   Enough to notice object appearing, vanishing, moving or changing colour.
const drawnSignature = () => page.evaluate(() => window.__drawn);
// Drive each edit path in turn, through very export page's own controls call.
//   What is asserted after each: next frames were rebuilt, not held, and canvas
//   changed.
const edits = [
  ['hiding an item', () => nimSetVisible(nimSceneSlots()[1], false)],
  ['showing it again', () => nimSetVisible(nimSceneSlots()[1], true)],
  ['recolouring an item', () => nimSetInk(nimSceneSlots()[1], 4)],
  ['moving a coefficient', () => nimSetCoefficient(nimSceneSlots()[1], 1, 4.5)],
  ['selecting an item', () => nimSelectOnly(nimSceneSlots()[1])],
  ['removing an item', () => nimRemoveItem(nimSceneSlots()[1])],
  ['undoing that removal', () => nimUndo()],
  ['redoing it', () => nimRedo()],
];
let count_released = 0;
let count_redrawn = 0;
for (const [what, run] of edits) {
  const before = await drawnSignature();
  await page.evaluate(() => { window.__hold = { held: 0, built: 0 }; });
  await page.evaluate(`(${run.toString()})()`);
  await page.waitForTimeout(500);
  const after = await drawnSignature();
  const seen = await page.evaluate(() => ({ ...window.__hold }));
  if (seen.built > 0) count_released += 1;
  if (after !== before) count_redrawn += 1;
  if (seen.built === 0 || after === before) {
    console.log(`      ${what}: ${seen.built} rebuilt, canvas ` +
      `${after === before ? 'UNCHANGED' : 'changed'}`);
  }
}
report(
  'and every edit releases the hold and reaches the canvas',
  count_released === edits.length && count_redrawn === edits.length,
  `${count_released} of ${edits.length} released, ${count_redrawn} of ${edits.length} redrawn`,
);
await page.evaluate(() => { nimSelectClear(); });
await page.waitForTimeout(200);

/* ---- What still frame and moving one are allowed to cost ----     */

// **Drawer's own work does not happen while drawer is shut.** Every figure
// diagnostics refresh writes is inside it, and it used to run five times second
// regardless: 2.8 ms typical and 5.7 ms worst on this scene, landing on one frame in twelve
// against frame that scene hold had taken down to about millisecond. That is what
// stutter is made of. Counted structurally rather than clocked -- `nimPoolCellColors` is
// expensive half and call to it is call nobody asked for.
await page.evaluate(() => {
  if (document.getElementById('drawer').classList.contains('open')) {
    document.getElementById('button-drawer').click();
  }
  window.__cells = 0;
  const original = globalThis.nimPoolCellColors;
  globalThis.nimPoolCellColors = function (...a) {
    window.__cells += 1;
    return original.apply(this, a);
  };
});
await page.waitForTimeout(1500);
const cells_shut = await page.evaluate(() => window.__cells);
report(
  'a shut drawer costs nothing to keep up to date',
  cells_shut === 0,
  `${cells_shut} pool-strip rebuilds over ~1.5 s with the drawer shut`,
);

// Check grid is drawn when scene changes and not on every tick.
//   With drawer and its diagnostics section open.
//   Walk over every slot per tick would be paid for picture that moves when object is
//   added or removed and at no other time.
//   Section has to be opened too: tick returns immediately while it is collapsed, so
//   check that only opens drawer proves nothing about gate it names.
await page.evaluate(() => {
  document.getElementById('button-drawer').click();
  document.querySelector('.section[data-section="diagnostics"]').classList.add('open');
  window.__cells = 0;
});
await page.waitForTimeout(1500);
const cells_open = await page.evaluate(() => window.__cells);
report(
  'and an open one draws the pool grid on a scene change, not on a clock',
  cells_open <= 2,
  `${cells_open} pool-grid draws over ~1.5 s with the drawer and section open`,
);

// Check remove reaches picture, since it is scene change.
//   Other half of same gate, and half "costs nothing" check can never fail.
const pool_edit = await page.evaluate(async () => {
  const wait = (n) => new Promise((r) => setTimeout(r, n));
  window.__cells = 0;
  nimRemoveItem(nimSceneSlots()[0]);
  await wait(600);
  return window.__cells;
});
report(
  'and an edit reaches it',
  pool_edit >= 1,
  `${pool_edit} pool-grid draws after removing one object`,
);

// **Every slot has cell, and every cell has pixel.** Strip this replaced was flex
// row of 1,024 spans with 1px gap: 1,023px of gap inside 371px strip, so flex shrank
// every cell to zero and whole thing drew as gap, correctly coloured and completely
// invisible. Nothing caught it -- elements were all there and colours were all
// right. This asks two questions that would have.
const pool_grid = await page.evaluate(() => {
  const grid = document.getElementById('pool-grid');
  // Read from draw itself rather than re-deriving here.
  //   Choice of cell size is thing being checked, and check that repeats derivation
  //   agrees with itself whatever reached canvas.
  const { cell, columns, rows } = geometry_pool_drawn;
  const ratio = Math.min(window.devicePixelRatio || 1, 2.5);
  // What actually reached canvas, rather than what arithmetic hoped for.
  const data = grid.getContext('2d')
    .getImageData(0, 0, grid.width, grid.height).data;
  let lit = 0;
  for (let i = 3; i < data.length; i += 4) if (data[i] > 0) lit += 1;
  return { columns, rows, addressable: columns * rows, capacity: nimSceneCapacity(),
    cell_device_px: cell * ratio, height: Math.round(grid.clientHeight),
    share_painted: lit / Math.max(1, grid.width * grid.height) };
});
report(
  'every pool slot has a cell, and every cell has a pixel',
  pool_grid.addressable >= pool_grid.capacity && pool_grid.cell_device_px >= 1 &&
    pool_grid.height > 0 && pool_grid.share_painted > 0.5,
  `${pool_grid.columns}x${pool_grid.rows} cells for ${pool_grid.capacity} slots, ` +
    `${pool_grid.cell_device_px}px a side, ${pool_grid.height}px tall, ` +
    `${(pool_grid.share_painted * 100).toFixed(0)}% of the canvas painted`,
);
await page.evaluate(() => {
  if (document.getElementById('drawer').classList.contains('open')) {
    document.getElementById('button-drawer').click();
  }
});
await page.waitForTimeout(200);

// **Held placement draws what fresh one draws.** Where object stands is question
// about object, so browser asks algebra once per edit and reuses answer
// while camera orbits -- which is 12 ms of 17 ms frame on this scene. Fault that
// buys is stale placement: object drawn where it used to be, or drawn as wrong
// shape, with nothing to say so. Checked by driving camera long way, then bumping
// scene's revision **without changing anything reader could see** -- recolouring item
// to ink it already wears -- which forces every placement to be derived again. Two
// frames must be pixel-identical; if cached one had gone stale, they could not be.
await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const gl = canvas.getContext('webgl');
  const px = new Uint8Array(canvas.width * canvas.height * 4);
  const drawn = globalThis.renderFrame;
  globalThis.renderFrame = function (...a) {
    const out = drawn.apply(this, a);
    gl.readPixels(0, 0, canvas.width, canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, px);
    let hash = 2166136261;
    for (let i = 0; i < px.length; i += 4 * 17) {
      hash = Math.imul(hash ^ px[i], 16777619) ^ px[i + 1] ^ (px[i + 2] << 8);
    }
    window.__drawn_placed = hash | 0;
    return out;
  };
  document.getElementById('gl').focus();
});
await holdKeys(['ArrowRight'], 900);
await page.waitForTimeout(400);
const drawn_held = await page.evaluate(() => window.__drawn_placed);
await page.evaluate(() => {
  // Scene's revision moves; not one pixel of scene does.
  for (const slot of nimSceneSlots()) nimSetInk(slot, nimItemInk(slot));
});
await page.waitForTimeout(400);
const drawn_fresh = await page.evaluate(() => window.__drawn_placed);
report(
  'a placement held across a camera move draws what a fresh one draws',
  drawn_held !== undefined && drawn_held === drawn_fresh,
  `held ${drawn_held}, re-placed ${drawn_fresh}`,
);
await page.keyboard.press('Home');
await page.waitForTimeout(400);

/* ---- Demo preset ----     */

// **Demo is build's own stress case**, and its whole value is that it is heavy in
// every dimension at once. Driven through button reader presses rather than by calling
// `nimLoadDemo`, because wiring between two is exactly what rename breaks.
//   Nim suite already checks what *scene* contains; what only this can check is that
// pressing button gets that scene onto page, and that camera it leaves behind
// actually holds arrangement.
//   **Which size.** Arrangement comes in three, and this runs at default -- what
// reader gets when they press button without thinking about it. Performance pins
// further down re-load at largest, because band that only ever runs at default
// cannot see regression that shows under load. `VISUALISER_DEMO_ITEMS` overrides
// default for run driven by hand.
const ITEMS_DEMO = Number(process.env.VISUALISER_DEMO_ITEMS ?? 0) ||
  await page.evaluate(() => nimDemoItems(nimDemoScaleDefault()));
const ITEMS_DEMO_LOAD = await page.evaluate(
  () => nimDemoItems(nimDemoScales()[nimDemoScales().length - 1]));
// One button per size, so size asked for names button that loads it.
const loadDemo = async (items) => {
  await page.click('#button-menu');
  await page.click(`#button-load-demo-${items}`);
  await page.click('#button-menu'); // Shut popover again, as reader would.
  await page.waitForFunction((n) => nimSceneCount() === n, items, { timeout: 120000 });
  await page.waitForTimeout(600);
};
await loadDemo(ITEMS_DEMO);
const demo = await page.evaluate(() => {
  const tally = {};
  for (const slot of nimSceneSlots()) {
    const word = nimItemShapeWord(slot);
    tally[word] = (tally[word] || 0) + 1;
  }
  return {
    count: nimSceneCount(), capacity: nimSceneCapacity(), tally,
    distance: nimCameraDistance(),
  };
});
report(
  // **It used to fill pool exactly**, back when arrangement's own tables were
  // whole of it. Star catalogue carries far more stars than any scene has room for, so
  // what fills scene is target and slots above it are deliberate headroom:
  // reader can build on top of loaded demo rather than meeting refusal.
  //   Count comes from bridge rather than being written here, so sizes stay
  // `orrery.ScaleOrrery`'s to change; what this pins is that pressing that button gets
  // exactly that many objects onto page.
  'the demo button fills its target and leaves the rest of the pool free',
  demo.count === ITEMS_DEMO && demo.capacity > demo.count,
  `${demo.count} of ${demo.capacity} slots, ${demo.capacity - demo.count} free`,
);
// Every kind, and nothing that draws nothing. Mixed-grade case is one worth naming:
//   three collinear points wedge to no clean grade, and such item holds slot while
//   drawing nothing at all -- six of sixty-four did, and scene still counted 64.
//   Lines carry **ceiling**, alone among kinds: they were cut from fifteen to
//   three that mean something, because line is infinite and every one crosses whole
//   frame whatever it joins, and slots that freed went into system and nine more
//   bodies. Presence alone would let them creep back.
//   **Two, not three, and difference is this tally's own bucketing**: `nimItemShapeWord`
//   reports line at horizon as its own kind, so `line` here counts only finite ones --
//   `sol ∧ earth` and `earth ∧ luna`. Suite's own version of this check counts all three
//   together, which is why two figures differ by one and why neither is typo.
//   **Presence, not proportions.** Counts each size comes to, and that they rise with
//   size, are Nim suite's to check at all three; what only this can see is that
//   pressing button put every kind on page. Floors written here would be second
//   copy of arrangement's tally, pinned to whichever size this happens to run at.
const drawing = ['point', 'line', 'plane', 'point at horizon', 'line at horizon',
  'plane at horizon'];
const undrawn = Object.keys(demo.tally).filter((word) => !drawing.includes(word));
report(
  'it carries every drawable kind, including one of each at horizon, and nothing blank',
  drawing.every((word) => (demo.tally[word] || 0) >= 1) && undrawn.length === 0 &&
    demo.tally.line >= 2 && demo.tally.line <= 3,
  Object.entries(demo.tally).map(([word, n]) => `${word} ${n}`).join(', '),
);
// Check camera it leaves is standing back far enough to see what it just built.
//   On opening camera demo loads inside its own inner planets.
report(
  'and it stands the camera back far enough to hold what it built',
  demo.distance > 40,
  `camera at ${demo.distance.toFixed(1)}, opening distance is 19`,
);

// **From here on, under load.** Everything above is what pressing button does; what
// follows measures what build costs, and band that only ever ran at default size
// could not see regression that shows at largest. Reloaded rather than reasoned about.
await loadDemo(ITEMS_DEMO_LOAD);

// **Culling changes no pixel.** Points outside view are skipped before emitting.
// Hashed at three cameras -- demo's own, dollied in, orbited -- with cull on and then
// off, each once picture has settled; at demo's own camera most points are off screen
// and count row must say so.
const culled = await page.evaluate(async () => {
  const wait = (n) => new Promise((r) => setTimeout(r, n));
  const settled = async () => {
    let last = null;
    for (let i = 0; i < 30; i += 1) {
      await wait(150);
      if (window.__drawn_placed === last) return last;
      last = window.__drawn_placed;
    }
    return last;
  };
  const readings = [];
  const moves = [() => {}, () => nimCameraDolly(0.3), () => nimCameraOrbit(0.9, 0.3)];
  for (const move of moves) {
    move();
    nimSetCulling(true);
    const hash_on = await settled();
    const on = { hash: hash_on, points: count_phase.points, off: count_points_culled };
    nimSetCulling(false);
    const hash_off = await settled();
    const off = { hash: hash_off, points: count_phase.points, off: count_points_culled };
    readings.push({ on, off });
  }
  nimSetCulling(true);
  return readings;
});
report(
  'points outside the view are skipped before emitting, and not one pixel changes',
  culled.every((r) => r.on.hash === r.off.hash && r.on.hash !== null &&
    r.on.points + r.on.off === r.off.points && r.off.off === 0) &&
    culled.some((r) => r.on.off > 0),
  culled.map((r) => `${r.on.points} of ${r.on.points + r.on.off} drawn, ` +
    `${r.on.hash === r.off.hash ? 'same' : 'different'} pixels`).join('; '),
);
await page.keyboard.press('Home');
await page.waitForTimeout(400);

// **Zoom keeps field on screen and target where reader was looking.** Far clip used
// to sit at twenty orbit distances whatever scene held, so six notches in at demo's
// centre left 49 of 4,938 points drawn; and zoom anchored on whatever star was under
// pointer, so six notches off-centre carried target 1,737 units off, three opening
// distances. Driven with same notches. Off-centre spot sits right of middle, clear of
// drawer standing open on left; canvas is focused before `Home` so key reaches it.
const zoomed = await page.evaluate(async () => {
  const wait = (n) => new Promise((r) => setTimeout(r, n));
  await wait(400);
  return { distance: nimCameraDistance(), target: Array.from(nimCameraTarget()) };
});
const canvas_box = await page.evaluate(() => {
  const r = document.getElementById('gl').getBoundingClientRect();
  return { x: r.left, y: r.top, w: r.width, h: r.height };
});
const zoomAt = async (fx, fy) => {
  await page.mouse.move(canvas_box.x + fx * canvas_box.w, canvas_box.y + fy * canvas_box.h);
  for (let i = 0; i < 6; i += 1) {
    await page.mouse.wheel(0, -400);
    await page.waitForTimeout(250);
  }
  await page.waitForTimeout(600);
  const after = await page.evaluate(() => ({
    distance: nimCameraDistance(), target: Array.from(nimCameraTarget()),
    points: count_phase.points,
  }));
  await page.evaluate(() => document.getElementById('gl').focus());
  await page.keyboard.press('Home');
  await page.waitForTimeout(1200);
  return after;
};
const zoom_centre = await zoomAt(0.5, 0.5);
const zoom_corner = await zoomAt(0.85, 0.2);
const carried = Math.hypot(
  zoom_corner.target[0] - zoomed.target[0], zoom_corner.target[1] - zoomed.target[1],
  zoom_corner.target[2] - zoomed.target[2],
);
report(
  'six notches in at the centre keep the field drawn behind the near stars',
  zoom_centre.distance < 0.1 * zoomed.distance && zoom_centre.points >= 200,
  `${zoom_centre.points} points drawn at distance ${zoom_centre.distance.toFixed(1)}, ` +
    `from ${zoomed.distance.toFixed(1)}`,
);
report(
  'six notches in off-centre keep the target within one opening distance',
  carried <= 1.0 * zoomed.distance,
  `target carried ${carried.toFixed(0)} units over an opening distance of ` +
    `${zoomed.distance.toFixed(0)}`,
);

// **Retiring oldest undo step used to move whole timeline.** `Step` is whole
// scene, so once timeline is full that was thirty-one whole-scene copies for one
// visibility toggle -- 153 ms at capacity of time, nine dropped frames, on edit
// reader makes without thinking about it. It is ring now and costs one scene copy at any
// depth. Measured *past* capacity on purpose: under it old shape and new one cost
// same, so check that edits fresh timeline would pass either way. Bound is far
// above what this measures and far below fault it is here to catch, so slow container
// never decides it.
const ms_edit = await page.evaluate(() => {
  const slot = nimSceneSlots()[0];
  const was_visible = nimItemVisible(slot);
  for (let i = 0; i < 40; i += 1) nimSetVisible(slot, i % 2 === 0); // Fill timeline.
  const started = performance.now();
  for (let i = 0; i < 20; i += 1) nimSetVisible(slot, i % 2 === 0);
  const each = (performance.now() - started) / 20;
  nimSetVisible(slot, was_visible); // Leave scene as demo built it.
  return each;
});
report(
  'an edit past the timeline capacity copies one scene, not the whole timeline',
  ms_edit < 40,
  `${ms_edit.toFixed(1)} ms an edit over ${ITEMS_DEMO_LOAD} objects`,
);

// **Frame after edit re-places slot it touched, not scene.** Placement
// cache refilled every live slot on any change of revision, so frame after one add
// re-ran whole placing side: 42 ms at this size, against 4 with per-slot stamps. Bound
// well under fault and well over repaired figure.
const ms_after_edit = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  const model = Array.from(nimItemCoefficients(nimSceneSlots()[0]));
  const times = [];
  for (let i = 0; i < 6; i += 1) {
    const slot = nimAddItem(
      model, 'placed', nimDefaultInk(), nimDefaultRadius(), performance.now() / 1000,
    );
    const started = performance.now();
    nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true, false, true);
    times.push(performance.now() - started);
    nimRemoveItem(slot);
    nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true, false, true);
  }
  nimSelectClear();
  times.sort((a, b) => a - b);
  return times[3];
});
report(
  'the frame after an edit re-places one slot, not every slot',
  ms_after_edit < 15,
  `${ms_after_edit.toFixed(1)} ms over ${ITEMS_DEMO_LOAD} objects`,
);

// **Undo made while frame is held is drawn.** Restored snapshot carried its own
// revision, and bump after it landed on revision of very edit being undone, so
// hold kept last frame's meshes: undone object stayed on screen until camera
// moved. Hold is engaged first, on purpose -- fault only shows once it has, and
// it cannot engage under debug layer, which page's own loop is still drawing
// from check far above: switched off here rather than fought.
const undo_drawn = await page.evaluate(async () => {
  const chip = document.getElementById('toggle-algebra');
  if (chip.classList.contains('on')) chip.click();
  const canvas = document.getElementById('gl');
  const aspect = canvas.width / canvas.height;
  const build = () =>
    nimBuildFrame(aspect, performance.now() / 1000, canvas.height, true, true, false, true);
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const model = Array.from(nimItemCoefficients(nimSceneSlots()[0]));
  const state = (f) => ({
    verts: f.point_verts.length / 8, points: f.count_points, selected: f.count_selected,
    held: f.is_scene_held, count: nimSceneCount(), revision: nimSceneRevision(),
    hidden: nimSceneSlots().filter((slot) => !nimItemVisible(slot)).length,
  });
  const before = state(build());
  nimAddItem(model, 'undone', nimDefaultInk(), nimDefaultRadius(), performance.now() / 1000);
  nimSelectClear();
  let is_held = false;
  for (let i = 0; i < 60 && !is_held; i += 1) { await sleep(50); is_held = build().is_scene_held; }
  const added = state(build());
  nimUndo();
  const after = state(build());
  return { is_held, before, added, after };
});
report(
  'an undo made while the frame is held is drawn',
  undo_drawn.is_held && undo_drawn.added.verts > undo_drawn.before.verts &&
    undo_drawn.after.verts === undo_drawn.before.verts && !undo_drawn.after.held,
  JSON.stringify(undo_drawn),
);

// **Hover pick over largest demo meets ninety-seven planes.** Each was meet through
// algebra whether or not cursor was anywhere near its disc -- half of every pick at
// this size. Broad phase skips ones it cannot be over; meet still decides
// rest. Repaired 2.4 ms; unguarded walk measured 5.3.
const pin_pick_loaded = await page.evaluate(() => {
  const canvas = document.getElementById('gl');
  nimUpdateCursor(canvas.clientWidth / 2, canvas.clientHeight / 2);
  const times = [];
  for (let i = 0; i < 25; i += 1) {
    const start = performance.now();
    nimUpdateHover(canvas.clientWidth, canvas.clientHeight);
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  return times[12];
});
reportWithin(
  'a hover pick over the largest demo skips the discs it cannot be over', pin_pick_loaded,
  0, BANDS_PERF.hover_pick_ms, 'ms median',
);

// **Per-kind accounting, asked again where numbers mean something.** Same check
// runs far above on opening scene, and on fast container that scene's whole phase is
// around half millisecond -- every reading is quantised to tenth, so lower bound is
// inert there: halving every part's contribution was measured to still pass. Nothing about
// check is wrong; scene is simply too cheap to divide. Under demo phase is
// order of magnitude larger, and same rule applied to it *means* something: 0.6 ms
// against 7-14 ms phase is 5-8% tolerance where against 0.5 ms it was 120%. Lower
// bound keeps allowance check above uses, because work it allows for -- two
// walks of all 64 slots, marking overlay, packing view-projection -- belongs to no
// kind and gets *larger* with 64 objects, not smaller. Measured over three runs, worst
// excess on this side was 0.00 ms; lower bound is one that occasionally moves.
// Debug layer has been on since check that switched it on, some way above, and
//   lattice it draws is ribbons -- about 1,650 records of them, which would drown
//   record accounting below in geometry that has nothing to do with plane's rim. Off for
//   this window, since what is measured here is ordinary picture.
await page.evaluate(() => {
  const chip = document.getElementById('toggle-algebra');
  if (chip.classList.contains('on')) chip.click();
});
await page.waitForTimeout(200);
// Fill free slots first, so drag below meets full scene.
//   Construction gesture released on full scene must refuse through `isFull` rather
//   than take whole page down with assertion; every panel path guards it, and gesture
//   reaches `scene.addItem` through shared code.
//   Preset fills target and leaves rest of pool free on purpose, so reader can build on
//   top of loaded demo, which means gesture below would legitimately succeed and this
//   check would silently check nothing.
//   Copying point demo already placed, rather than composing one here, because what is
//   under test is gesture's own guard.
await page.evaluate(() => {
  const model = Array.from(nimItemCoefficients(nimSceneSlots()[0]));
  while (nimSceneCount() < nimSceneCapacity()) {
    nimAddItem(model, 'filler', nimDefaultInk(), nimDefaultRadius(), 0);
  }
  nimSelectClear(); // Each add selects what it added; leave nothing standing behind.
});
await page.waitForTimeout(300);
// **Breakdown only exists while it is being read**, so check that it adds up has to
//   run in that state. Bridge times placing and emitting halves of every object,
//   which at five thousand points is three clock reads each and 5 ms of 14 ms frame, so it
//   is gathered only where drawer and diagnostics section are both open. Collapsed,
//   per-kind rows are legitimately absent rather than wrong -- and this check would be
//   summing zeros against real scene phase, which is how it first failed.
await page.evaluate(() => {
  const drawer = document.getElementById('drawer');
  const section = document.querySelector('.section[data-section="diagnostics"]');
  if (!drawer.classList.contains('open')) document.getElementById('button-drawer').click();
  if (!section.classList.contains('open')) section.querySelector('.section-header').click();
});
await page.waitForTimeout(300);
// Start window accounting below reads only now.
//   Fill is many committed edits back to back, which is not ordinary picture this
//   measures.
await page.evaluate(() => { window.__phase_frame = []; });
await page.mouse.move(720, 450);
await page.mouse.down();
for (let i = 0; i < 20; i += 1) await page.mouse.move(720 + 8*i, 450 + 3*i);
await page.mouse.up();
await page.waitForTimeout(700);
// **And then orbit, because still camera over still scene is now held frame.**
//   scene hold skips tessellation, flatten and uploads together where nothing
//   has moved, so idle window records frames whose scene phase is legitimately zero and
//   there is nothing there to divide. What this check is about is cost of drawing while
//   view moves, which is case reader actually waits on; orbiting produces it.
await page.evaluate(() => document.getElementById('gl').focus());
// **Orbited until sample is big enough, not for fixed time.** Floor below wants
//   frames whose scene phase clears 2 ms, and fixed window kept finding fewer of them:
//   placement cache took that phase from about 17 ms to under 4, so check was
//   failing *because* thing it guards got faster, and on loaded runner it failed at
//   different count each time. Window is wrong instrument for sample size. This
//   collects until it has one, and gives up rather than hanging if frames never come.
//   Forty rounds, not twenty: point cull took orbit's scene phase to about 1.7 ms p50,
//   so frames clearing 2 ms are minority and twenty rounds stopped at nineteen.
await page.evaluate(() => document.getElementById('gl').focus());
await page.keyboard.down('ArrowRight');
let count_heavy_seen = 0;
for (let round = 0; round < 40 && count_heavy_seen < 25; round += 1) {
  await page.waitForTimeout(400);
  count_heavy_seen = await page.evaluate(
    () => window.__phase_frame.slice(2).filter((p) => p.scene >= 2.0).length);
}
await page.keyboard.up('ArrowRight');
await page.waitForTimeout(120);
const after_drag = await page.evaluate(() => nimSceneCount());
report(
  'a construction gesture on a full scene is refused, not crashed through',
  errors_page.length === 0 && after_drag === demo.capacity,
  `${after_drag} items after the drag, ${errors_page.length} page error(s)`,
);
const loaded = await page.evaluate(() => window.__phase_frame.slice(2).map((p) => ({
  scene: p.scene,
  parts: p.points + p.lines + p.planes + p.sky + p.ghost + p.selected,
})));
const loaded_records = await page.evaluate(() => window.__phase_frame.slice(2).map((p) => ({
  records_ribbon: p.records_ribbon, records_ring: p.records_ring,
  records_disc: p.records_disc,
})));
const heavy = loaded.filter((k) => k.scene >= 2.0);
const heavy_sane = heavy.filter((k) =>
  k.parts <= k.scene + 0.6 && k.parts >= k.scene - Math.max(3.0, 0.3*k.scene));
report(
  'and under it the same accounting still holds, on a phase big enough to divide',
  heavy.length > 20 && heavy_sane.length >= FRACTION_KINDS_ACCOUNT*heavy.length,
  `${heavy_sane.length} of ${heavy.length} frames over 2 ms account, ` +
    `worst scene phase ${Math.max(0, ...heavy.map((k) => k.scene)).toFixed(2)} ms`,
);

// **Rim is on GPU, and this is number that says so.** Plane's rim used to
// arrive as `SEGMENTS_CIRCLE_HORIZON` ribbon records: on scene of this many planes that
// was ninety-six records each, 99% of all ribbon traffic, and largest single cost in
// frame. It is one ring record plane now. What makes this real pin rather than
// restatement is that ceiling is *far* below old figure -- regression that put
// rim back on CPU could not creep past it, it would blow through by two orders of
// magnitude. Three finite lines are what is left, at two records each.
//   Floor is planes actually loaded, read from scene rather than written down:
// it is what makes ceiling mean something (with no planes drawn, "few ribbons" is
// vacuous), and figure pinned to whichever size this runs at would have to move with it.
const planes_loaded = await page.evaluate(() => {
  let counted = 0;
  for (const slot of nimSceneSlots()) {
    const word = nimItemShapeWord(slot);
    if (word === 'plane' || word === 'plane at horizon') counted += 1;
  }
  return counted;
});
const records = loaded_records.length === 0 ? null : {
  ribbon: Math.max(...loaded_records.map((r) => r.records_ribbon)),
  ring: Math.max(...loaded_records.map((r) => r.records_ring)),
  disc: Math.max(...loaded_records.map((r) => r.records_disc)),
};
report(
  'a plane rim crosses the wire as one ring record, not ninety-six ribbons',
  records !== null && records.ribbon <= 64 && records.ring >= planes_loaded &&
    records.ring >= records.disc,
  records === null
    ? 'no frames recorded'
    : `${records.ribbon} ribbon, ${records.ring} ring, ${records.disc} disc records ` +
      `over ${planes_loaded} planes`,
);

/* ---- What drawer costs to keep up to date ----     */

// **Row reader cannot see does not build form it would edit with.** Every row used
// to build whole edit form -- label field, ink picker, and grid with input per
// basis element -- and let CSS hide it. At 1,024 objects that was 76 elements row and
// 80,325 on page, one rebuild cost 570 ms of JavaScript and 164 ms of layout, and tap
// on `hide` froze page for three quarters of second. Counted structurally, since
// element that is not there cannot cost anything.
// **Opened first, because list nobody is looking at now builds nothing.** That is
//   point of gate this check exists on other side of: rows are built when
//   drawer and objects section are both open, and cost below is what reader who
//   *is* looking pays. Then waited for, since list fills across frames rather than in
//   one block -- see `refreshObjectsUI`'s own slicing -- which is also what reader sees.
await page.evaluate(() => {
  const drawer = document.getElementById('drawer');
  const section = document.querySelector('.section[data-section="objects"]');
  if (!drawer.classList.contains('open')) document.getElementById('button-drawer').click();
  if (!section.classList.contains('open')) section.querySelector('.section-header').click();
});
//   Waited against scene's own count rather than size that was loaded: refusal
//   check above filled free slots, so list is one row per *live object*, which is
//   invariant either way.
await page.waitForFunction(
  () => document.getElementById('objects-list').children.length === nimSceneCount(),
  null, { timeout: 120000 });
const drawer_dom = await page.evaluate(() => ({
  elements: document.querySelectorAll('*').length,
  rows: document.querySelectorAll('#objects-list > *').length,
  forms: document.querySelectorAll('#objects-list .item-edit').length,
}));
report(
  // Bound per row rather than outright.
  //   Row count is scene's, and check written against fixed ceiling stops meaning
  //   anything moment capacity moves.
  //   Nine elements row is what collapsed row costs; slack covers rest of page.
  'a closed row builds no edit form, so the page holds thousands of elements and not tens',
  drawer_dom.rows >= ITEMS_DEMO_LOAD && drawer_dom.forms === 0 &&
    drawer_dom.elements < 12 * drawer_dom.rows,
  `${drawer_dom.elements} elements over ${drawer_dom.rows} rows ` +
    `(${(drawer_dom.elements / drawer_dom.rows).toFixed(1)} each), ` +
    `${drawer_dom.forms} edit forms`,
);

// Check opening one row builds exactly one form.
//   Keeps guard above from being way to break editing rather than way to make it cheap.
const drawer_open_row = await page.evaluate(() => {
  document.querySelector('.section[data-section="objects"]').classList.add('open');
  document.querySelector('#objects-list .item-edit-toggle').click();
  const open = document.querySelector('#objects-list .item-edit.open');
  return {
    forms: document.querySelectorAll('#objects-list .item-edit').length,
    inputs: open === null ? 0 : open.querySelectorAll('input').length,
  };
});
report(
  'and opening a row builds one, with its coefficient grid intact',
  drawer_open_row.forms === 1 && drawer_open_row.inputs >= 16,
  `${drawer_open_row.forms} form, ${drawer_open_row.inputs} inputs in it`,
);
await page.evaluate(() => {
  const cancel = document.querySelector('#objects-list .item-edit-cancel');
  if (cancel !== null) cancel.click();
});
await page.waitForTimeout(200);

// **List reconciles against what is standing rather than rebuilding.** Two properties,
// and first is what makes second safe to rely on: refresh that changes nothing
// keeps very same elements, and refresh that changes one row keeps every other one.
// Held on element identity rather than on clock, so it cannot flake -- and identity is
// exactly claim, since rebuilt row is different object however fast it was made.
const reconciled = await page.evaluate(() => {
  const rowsNow = () => Array.from(document.querySelectorAll('#objects-list > *'));
  const same = (a, b) => a.length === b.length && a.every((n, i) => n === b[i]);
  const before_idle = rowsNow();
  refreshObjectsUI();
  const after_idle = rowsNow();
  const slot = nimSceneSlots()[0];
  const before_hide = rowsNow();
  nimSetVisible(slot, false);
  refreshObjectsUI();
  const after_hide = rowsNow();
  let moved = 0;
  for (let i = 0; i < after_hide.length; i += 1) if (after_hide[i] !== before_hide[i]) moved += 1;
  nimSetVisible(slot, true);
  refreshObjectsUI();
  return { idle_kept: same(before_idle, after_idle), rows_touched_by_a_hide: moved,
    rows: after_hide.length };
});
report(
  'an unchanged refresh writes nothing, and a hide rebuilds one row of a thousand',
  reconciled.idle_kept && reconciled.rows_touched_by_a_hide === 1,
  `idle kept every element: ${reconciled.idle_kept}; a hide rebuilt ` +
    `${reconciled.rows_touched_by_a_hide} of ${reconciled.rows} rows`,
);

// **Diagnostics tick writes rows that changed and no others.** Every one of those
// writes is text node browser must re-style and re-lay out afterwards, and that work
// lands in `display wait + browser` rather than in `ui` row -- so tick that looked
// like 4 ms of JavaScript was closer to 8 ms of frame, five times second, which is what
// reader saw as stutter. About ten of twenty-nine rows actually move on tick.
const tick_writes = await page.evaluate(async () => {
  const wait = (n) => new Promise((r) => setTimeout(r, n));
  if (!document.getElementById('drawer').classList.contains('open')) {
    document.getElementById('button-drawer').click();
  }
  for (const n of document.querySelectorAll('.diagnostic-node')) n.classList.add('open');
  await wait(400);
  const descriptor = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent');
  let writes = 0;
  Object.defineProperty(Node.prototype, 'textContent', {
    ...descriptor, set(v) { writes += 1; descriptor.set.call(this, v); },
  });
  const original = globalThis.refreshDiagnostics;
  const per_tick = [];
  globalThis.refreshDiagnostics = function (...a) {
    writes = 0;
    const out = original.apply(this, a);
    per_tick.push(writes);
    return out;
  };
  await wait(1600);
  globalThis.refreshDiagnostics = original;
  Object.defineProperty(Node.prototype, 'textContent', descriptor);
  return { ticks: per_tick.length, worst: Math.max(0, ...per_tick),
    rows: document.querySelectorAll('[id^="diagnostic-"]').length };
});
report(
  'the diagnostics tick writes only the rows that moved',
  tick_writes.ticks > 2 && tick_writes.worst > 0 && tick_writes.worst <= 20,
  `${tick_writes.worst} text writes at worst over ${tick_writes.ticks} ticks, ` +
    `${tick_writes.rows} rows on the tree`,
);
// **Figures on slow pass are redrawn once second, not five times.**
// exceedance curve covers 1,024 frames and sparkline and ring medians four seconds:
// none of them can change in fifth of second, and redrawing them at panel's own
// rate was half tick. Counted rather than timed -- call count cannot flake.
const cadence_tick = await page.evaluate(async () => {
  const wait = (n) => new Promise((r) => setTimeout(r, n));
  const original_curve = globalThis.drawExceedance;
  let curves = 0;
  globalThis.drawExceedance = function (...a) {
    curves += 1; return original_curve.apply(this, a);
  };
  const original_tick = globalThis.refreshDiagnostics;
  let ticks = 0;
  globalThis.refreshDiagnostics = function (...a) {
    ticks += 1; return original_tick.apply(this, a);
  };
  await wait(3000);
  const open = { ticks, curves };
  // Check whole tick is skipped with section collapsed inside open drawer.
  //   Both canvases would otherwise fall back to made-up width and draw for nobody.
  document.querySelector('.section[data-section="diagnostics"]').classList.remove('open');
  ticks = 0; curves = 0;
  await wait(1500);
  const collapsed = { ticks, curves };
  document.querySelector('.section[data-section="diagnostics"]').classList.add('open');
  globalThis.drawExceedance = original_curve;
  globalThis.refreshDiagnostics = original_tick;
  return { open, collapsed };
});
report(
  'the panel redraws its four- and seventeen-second figures on their own slower clock',
  cadence_tick.open.ticks >= 8 && cadence_tick.open.curves > 0 &&
    cadence_tick.open.curves * 3 <= cadence_tick.open.ticks,
  `${cadence_tick.open.curves} curve redraws over ${cadence_tick.open.ticks} ticks`,
);
report(
  'and a collapsed diagnostics section costs the tick nothing at all',
  cadence_tick.collapsed.curves === 0,
  `${cadence_tick.collapsed.curves} curve redraws over ` +
    `${cadence_tick.collapsed.ticks} ticks with the section shut`,
);

// **One pick and one dolly frame, whatever pointer reported.** `pickNearest` walks
// every live slot, so answer computed per input event and thrown away is most
// expensive thing pointer can ask for; trackpad reports several wheel notches between
// two frames and mouse several moves.
const per_frame = await page.evaluate(async () => {
  const gl = document.getElementById('gl');
  const r = gl.getBoundingClientRect();
  const cx = r.left + r.width * 0.5, cy = r.top + r.height * 0.5;
  let picks = 0, dollies = 0;
  const original_hover = globalThis.nimUpdateHover;
  globalThis.nimUpdateHover = function (...a) {
    picks += 1; return original_hover.apply(this, a);
  };
  const original_dolly = globalThis.nimCameraDollyAt;
  globalThis.nimCameraDollyAt = function (...a) {
    dollies += 1; return original_dolly.apply(this, a);
  };
  const send = (type, x, y, buttons) => gl.dispatchEvent(new PointerEvent(type, {
    pointerId: 1, pointerType: 'mouse', isPrimary: true, bubbles: true, cancelable: true,
    clientX: x, clientY: y, buttons, button: buttons === 0 ? -1 : 0 }));
  send('pointerdown', cx, cy, 1);
  picks = 0; dollies = 0; // Press picks inside its own handler, by design.
  let frames = 0;
  await new Promise((resolve) => {
    const step = () => {
      // Six of each frame, which is ordinary trackpad against 60 Hz display.
      //   All notches one way: frame's travel that sums to nothing is no zoom, and
      //   frame loop rightly does not spend pick on it.
      for (let k = 0; k < 6; k += 1) {
        send('pointermove', cx + k * 3, cy + k * 2, 1);
        gl.dispatchEvent(new WheelEvent('wheel', { deltaY: frames % 2 ? 6 : -6,
          clientX: cx, clientY: cy, bubbles: true, cancelable: true }));
      }
      frames += 1;
      if (frames < 30) requestAnimationFrame(step); else requestAnimationFrame(resolve);
    };
    requestAnimationFrame(step);
  });
  send('pointerup', cx, cy, 0);
  globalThis.nimUpdateHover = original_hover;
  globalThis.nimCameraDollyAt = original_dolly;
  return { frames, picks, dollies, events: frames * 6 };
});
report(
  'a burst of pointer and wheel events costs one pick and one dolly a frame, not one each',
  per_frame.picks <= per_frame.frames + 2 && per_frame.dollies <= per_frame.frames + 2 &&
    per_frame.picks > 0 && per_frame.dollies > 0,
  `${per_frame.events} moves and ${per_frame.events} notches over ${per_frame.frames} ` +
    `frames drew ${per_frame.picks} picks and ${per_frame.dollies} dollies`,
);

await page.evaluate(() => {
  if (document.getElementById('drawer').classList.contains('open')) {
    document.getElementById('button-drawer').click();
  }
});

report('the page raised no errors', errors_page.length === 0, errors_page.join('; '));

await browser.close();
console.log(
  count_failed === 0
    ? '\nEvery driven check passed.'
    : `\n${count_failed} driven check(s) failed.`,
);
process.exit(count_failed === 0 ? 0 : 1);
