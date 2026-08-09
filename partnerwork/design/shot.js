// Screenshot the marks page, light and dark, full length.
//
// The animations only exist in a browser, so a still build passing says
// nothing about them; this is the cheap half of checking they run (take two
// shots a moment apart and diff them for the expensive half).
//
//   node design/shot.js design/marks.html /tmp/marks
//
// Chromium and playwright are pre-installed in the remote environment at the
// paths below; elsewhere, point the two constants at your own.
const PLAYWRIGHT = '/opt/node22/lib/node_modules/playwright';
const CHROMIUM = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';

const path = require('path');
const { chromium } = require(PLAYWRIGHT);

(async () => {
  const [page_file, prefix] = process.argv.slice(2);
  const url = 'file://' + path.resolve(page_file);
  const browser = await chromium.launch({ executablePath: CHROMIUM });
  for (const theme of ['light', 'dark']) {
    const page = await browser.newPage({
      viewport: { width: 1000, height: 900 }, colorScheme: theme,
    });
    await page.goto(url);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${prefix}-${theme}.png`, fullPage: true });
    await page.close();
  }
  await browser.close();
})();
