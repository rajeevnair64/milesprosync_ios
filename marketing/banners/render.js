// Renders every *.html banner in this folder to a PNG at its exact size.
// Usage: node render.js   (needs Playwright; works from any directory)
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
(async () => {
  const b = await chromium.launch();
  for (const f of fs.readdirSync(__dirname).filter(f => f.endsWith('.html'))) {
    const [, w, h] = f.match(/-(\d+)x(\d+)\.html$/);
    const p = await b.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: 2 });
    await p.goto('file://' + path.join(__dirname, f));
    await p.screenshot({ path: path.join(__dirname, f.replace('.html', '@2x.png')) });
    await p.close();
  }
  await b.close();
})();
