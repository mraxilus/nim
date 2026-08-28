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
  `distance ${homed.distance.toFixed(3)}, target ${homed.target.map((v) => v.toFixed(3)).join(', ')}`,
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

/* ---- Nothing may have thrown along the way ---- */

report('the page raised no errors', errors_page.length === 0, errors_page.join('; '));

await browser.close();
console.log(
  count_failed === 0
    ? '\nEvery driven check passed.'
    : `\n${count_failed} driven check(s) failed.`,
);
process.exit(count_failed === 0 ? 0 : 1);
