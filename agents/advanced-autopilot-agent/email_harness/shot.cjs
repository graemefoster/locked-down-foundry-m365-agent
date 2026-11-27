// Screenshot an HTML file at 600 px wide. Usage: node shot.cjs in.html out.png
// Uses playwright-core from .agent-runs/activity-ui-pilot/playground/node_modules and the cached Chrome for Testing.
const path = require("path");
const fs = require("fs");
const os = require("os");
const root = path.resolve(__dirname, "../../..");
const { chromium } = require(path.join(root, ".agent-runs/activity-ui-pilot/playground/node_modules/playwright-core"));
const cache = path.join(os.homedir(), "Library/Caches/ms-playwright");
let exe;
for (const d of fs.readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().reverse()) {
  for (const sub of fs.readdirSync(path.join(cache, d))) {
    const p = path.join(cache, d, sub, "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
    if (!exe && fs.existsSync(p)) exe = p;
  }
}
(async () => {
  const b = await chromium.launch({ executablePath: exe, headless: true });
  const pg = await b.newPage({ viewport: { width: 600, height: 800 } });
  await pg.goto("file://" + path.resolve(process.argv[2]));
  await pg.screenshot({ path: process.argv[3], fullPage: true });
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
