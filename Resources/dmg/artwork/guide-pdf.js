// Rebuilds "First time opening SpaceKeeper.pdf" from guide.html (needs Node + Playwright).
const path = require('path');
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('file://' + path.resolve(__dirname, 'guide.html'));
  await page.pdf({ path: path.resolve(__dirname, 'First time opening SpaceKeeper.pdf'),
    format: 'A4', printBackground: true, tagged: true, outline: true, preferCSSPageSize: true });
  await browser.close();
})();
