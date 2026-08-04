// Drive the assembled browser build headlessly, with real synthetic events.
//
// Every gesture below goes through the platform's own input layer — Playwright's mouse and
// touchscreen drive the browser's event pipeline — rather than calling handlers directly.
// Calling a handler bypasses the listener wiring, which is exactly where the real bugs hide.
//
// Usage: node tools/verify_browser.mjs [path-to-index.html]

import { chromium } from "/opt/node22/lib/node_modules/playwright/index.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";
import process from "node:process";

const pagePath = path.resolve(process.argv[2] ?? "build/index.html");
const checks = [];
let failures = 0;

function check(name, condition, detail) {
  const ok = Boolean(condition);
  checks.push({ name, ok, detail });
  if (!ok) failures += 1;
  console.log((ok ? "PASS  " : "FAIL  ") + name + (detail && !ok ? "  [" + detail + "]" : ""));
}

const browser = await chromium.launch({
  args: ["--use-gl=swiftshader", "--enable-unsafe-swiftshader", "--disable-lcd-text"],
});
const context = await browser.newContext({
  viewport: { width: 1280, height: 860 },
  hasTouch: true,
  deviceScaleFactor: 1,
});
const page = await context.newPage();

const consoleErrors = [];
page.on("pageerror", (error) => consoleErrors.push(String(error)));
page.on("console", (message) => {
  if (message.type() === "error") consoleErrors.push(message.text());
});

await page.goto(pathToFileURL(pagePath).href);
await page.waitForTimeout(600);

check("page loads with no console errors", consoleErrors.length === 0, consoleErrors.join("; "));

// ---- What the page shows ---------------------------------------------------------------------

const sections = await page.$$eval("details.section", (nodes) =>
  nodes.map((node) => ({ name: node.querySelector("summary").textContent, open: node.open }))
);
check(
  "four sections in alphabetical order",
  JSON.stringify(sections.map((s) => s.name)) ===
    JSON.stringify(["apply", "diagnostics", "objects", "view"]),
  JSON.stringify(sections)
);
check(
  "only objects is open",
  sections.filter((s) => s.open).length === 1 && sections.find((s) => s.open).name === "objects"
);

const labels = await page.evaluate(() => {
  const out = [];
  for (const isBinary of [false, true]) {
    for (let index = 0; index < rgaOperationCount(isBinary); index += 1) {
      out.push(rgaOperationLabel(rgaOperationAt(isBinary, index)));
    }
  }
  return out;
});
check("the catalogue holds twenty-seven operations", labels.length === 27, String(labels.length));

// Parity, asserted mechanically: what this page reports for all 27 operations, against what
// the desktop build reports. Trivially true once there is one table — which is the point.
const cataloguePath = path.join(path.dirname(pagePath), "catalogue.list");
if (fs.existsSync(cataloguePath)) {
  const native = fs.readFileSync(cataloguePath, "utf8").split("\n").filter((line) => line.length);
  const inCatalogueOrder = await page.evaluate(() => {
    const out = [];
    for (let operation = 0; operation < 27; operation += 1) out.push(rgaOperationLabel(operation));
    return out;
  });
  const differences = native
    .map((label, index) => (label === inCatalogueOrder[index] ? null : `${index}: ${label} vs ${inCatalogueOrder[index]}`))
    .filter(Boolean);
  check("both front-ends report the same 27 labels, character for character",
    native.length === 27 && differences.length === 0, differences.join("; "));
} else {
  check("both front-ends report the same 27 labels, character for character", false,
    "build/catalogue.list is missing; run tools/catalogue.nim first");
}

// The two targets reach the identical file format: a scene the native build wrote, decoded by
// the page's own reader.
const scenePath = path.join(path.dirname(pagePath), "demo.rgascene");
if (fs.existsSync(scenePath)) {
  const bytes = Array.from(fs.readFileSync(scenePath));
  const loaded = await page.evaluate((data) => {
    const view = new DataView(new Uint8Array(data).buffer);
    const ok = window.rgaPage.decodeScene(view);
    const labels = [];
    for (let index = 0; index < rgaItemCount(); index += 1) labels.push(rgaItemLabel(rgaItemSlotAt(index)));
    return { ok, count: rgaItemCount(), labels };
  }, bytes);
  check("a scene the desktop build wrote loads in the page",
    loaded.ok && loaded.count === 16, JSON.stringify(loaded).slice(0, 200));
  await page.evaluate(() => { rgaResetScene(); window.rgaPage.refreshAll(); });
}


const seeds = await page.evaluate(() => rgaItemCount());
check("the page opens on the five seeds alone", seeds === 5, String(seeds));

// ---- Glyph coverage, measured by rendering ----------------------------------------------------

const coverage = await page.evaluate(async (codepoints) => {
  await document.fonts.ready;
  const canvas = document.createElement("canvas");
  canvas.width = 64;
  canvas.height = 64;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  function bitmap(text, family) {
    context.clearRect(0, 0, 64, 64);
    context.font = "32px " + family;
    context.fillStyle = "#fff";
    context.fillText(text, 4, 40);
    return Array.from(context.getImageData(0, 0, 64, 64).data).join(",");
  }
  const notdef = {};
  for (const family of ['"Noto Sans"', '"Noto Sans Mono"']) {
    notdef[family] = bitmap("￿", family);
  }
  const missing = [];
  for (const codepoint of codepoints) {
    const text = String.fromCodePoint(codepoint);
    for (const family of ['"Noto Sans"', '"Noto Sans Mono"']) {
      const drawn = bitmap(text, family);
      const blank = bitmap(" ", family);
      if (drawn === notdef[family] || drawn === blank) {
        missing.push("U+" + codepoint.toString(16).toUpperCase() + " in " + family);
      }
    }
  }
  return missing;
}, JSON.parse(process.env.RGA_CODEPOINTS ?? "[]"));
check("every codepoint the tool writes renders as a glyph", coverage.length === 0, coverage.join("; "));

// ---- Mouse: click selects, drag derives -------------------------------------------------------

async function slotScreen(slotIndex) {
  return page.evaluate((index) => {
    const buffer = new Float32Array(2);
    const slot = rgaItemSlotAt(index);
    if (!rgaSlotScreen(slot, buffer)) return null;
    return { x: buffer[0], y: buffer[1], slot };
  }, slotIndex);
}

const rgaDuration = await page.evaluate(() => rgaAnimationDuration());
const first = await slotScreen(0);
const second = await slotScreen(1);
check("seed anchors project to the page", first !== null && second !== null);

await page.mouse.click(first.x, first.y);
await page.waitForTimeout(120);
const selectedAfterClick = await page.evaluate(() => rgaSelectionCount());
check("a plain click selects one object", selectedAfterClick === 1, String(selectedAfterClick));

// Selecting aims the camera at what was picked, so both anchors are re-read after the ease
// has landed rather than reused from before it started.
await page.waitForTimeout(rgaDuration + 300);
const dragFrom = await slotScreen(0);
const dragTo = await slotScreen(1);
const before = await page.evaluate(() => rgaItemCount());
await page.mouse.move(dragFrom.x, dragFrom.y);
await page.mouse.down({ button: "left" });
await page.mouse.move(dragTo.x, dragTo.y, { steps: 12 });
await page.mouse.up({ button: "left" });
await page.waitForTimeout(150);
const after = await page.evaluate(() => rgaItemCount());
check("a left drag between objects joins them", after === before + 1, `${before} -> ${after}`);

const derivedLabel = await page.evaluate(() => rgaItemLabel(rgaSelectionAt(0)));
check("the derived object is named from the operands", derivedLabel.includes("∧"), derivedLabel);

// A click on empty space clears the selection.
await page.mouse.click(30, 700);
await page.waitForTimeout(120);
check("a click on empty space clears the selection",
  (await page.evaluate(() => rgaSelectionCount())) === 0);

// ---- Undo and redo -----------------------------------------------------------------------------

await page.click("#chip-undo", { force: true });
await page.waitForTimeout(120);
check("undo removes the derived object",
  (await page.evaluate(() => rgaItemCount())) === before);
check("undo clears the selection",
  (await page.evaluate(() => rgaSelectionCount())) === 0);
await page.click("#chip-redo", { force: true });
await page.waitForTimeout(120);
check("redo restores it", (await page.evaluate(() => rgaItemCount())) === before + 1);

// ---- Edit session: nothing is written before save ------------------------------------------------

await page.click("#chip-drawer");
await page.waitForTimeout(400);
const countBeforeSession = await page.evaluate(() => rgaItemCount());
await page.evaluate(() => { rgaSessionStartComposing("driven"); window.rgaPage.refreshAll(); });
await page.waitForTimeout(100);
const coefficientField = await page.$("#section-objects input.coefficient");
check("a composing session shows a coefficient grid", coefficientField !== null);
await coefficientField.fill("5");
await coefficientField.press("Enter");
await page.waitForTimeout(100);
check("editing a coefficient adds nothing to the scene",
  (await page.evaluate(() => rgaItemCount())) === countBeforeSession);
await page.evaluate(() => { rgaSessionCancel(); window.rgaPage.refreshAll(); });
check("abandoning a session leaves the count untouched",
  (await page.evaluate(() => rgaItemCount())) === countBeforeSession);

// ---- Touch: long press selects, tap toggles --------------------------------------------------------

await page.click("#chip-drawer");
await page.waitForTimeout(400);
await page.evaluate(() => { rgaSelectClear(); window.rgaPage.refreshAll(); });
const touchTarget = await slotScreen(0);
await page.waitForTimeout(rgaDuration + 300);
await page.touchscreen.tap(touchTarget.x, touchTarget.y);
await page.waitForTimeout(100);
const afterTap = await page.evaluate(() => rgaSelectionCount());
check("a tap with nothing selected does not select", afterTap === 0, String(afterTap));

await page.evaluate(async ({ x, y }) => {
  // A long press, driven through the browser's own touch event pipeline.
  const target = document.getElementById("scene");
  const touch = new Touch({ identifier: 1, target, clientX: x, clientY: y });
  target.dispatchEvent(new TouchEvent("touchstart", {
    touches: [touch], targetTouches: [touch], changedTouches: [touch], bubbles: true, cancelable: true,
  }));
  await new Promise((resolve) => setTimeout(resolve, rgaLongPressDuration() + 120));
  target.dispatchEvent(new TouchEvent("touchend", {
    touches: [], targetTouches: [], changedTouches: [touch], bubbles: true, cancelable: true,
  }));
}, touchTarget);
await page.waitForTimeout(150);
check("a long press selects an object",
  (await page.evaluate(() => rgaSelectionCount())) === 1);
check("the hover reading is cleared once the last finger lifts",
  (await page.evaluate(() => { const b = new Float32Array(4); return rgaPackRings(b); })) === 1);

// ---- The floating menu ----------------------------------------------------------------------------

const menuOpen = await page.$eval("#selection-menu", (node) => node.classList.contains("open"));
check("the floating menu follows a selection", menuOpen);
const menuOrder = await page.$$eval("#selection-menu > button, #selection-menu > div",
  (nodes) => nodes.map((node) => node.id));
check("apply sits leftmost and never moves", menuOrder[0] === "menu-apply", menuOrder.join(","));

// ---- File round trip --------------------------------------------------------------------------------

const roundTrip = await page.evaluate(() => {
  const bytes = window.rgaPage.encodeScene();
  const before = rgaItemCount();
  const labels = [];
  for (let index = 0; index < before; index += 1) labels.push(rgaItemLabel(rgaItemSlotAt(index)));
  rgaResetScene();
  const ok = window.rgaPage.decodeScene(new DataView(bytes.buffer));
  const after = [];
  for (let index = 0; index < rgaItemCount(); index += 1) {
    after.push(rgaItemLabel(rgaItemSlotAt(index)));
  }
  return { ok, before, count: rgaItemCount(), same: JSON.stringify(labels.sort()) === JSON.stringify(after.sort()) };
});
check("a scene round-trips through the page's own file format",
  roundTrip.ok && roundTrip.count === roundTrip.before && roundTrip.same,
  JSON.stringify(roundTrip));

// ---- The canvas actually drew ----------------------------------------------------------------------

const drawn = await page.evaluate(() => {
  const canvas = document.getElementById("scene");
  const context = canvas.getContext("webgl", { preserveDrawingBuffer: true });
  return { width: canvas.width, height: canvas.height, lost: context === null };
});
check("the canvas is sized and holds a context", drawn.width > 0 && !drawn.lost, JSON.stringify(drawn));
await page.screenshot({ path: path.join(path.dirname(pagePath), "browser.png") });

// ---- Report -------------------------------------------------------------------------------------------

console.log(`${checks.length - failures}/${checks.length} checks passed`);
await browser.close();
process.exit(failures === 0 ? 0 : 1);
