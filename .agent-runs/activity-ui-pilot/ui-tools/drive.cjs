// node drive.cjs "<prompt>" <name> [approve]  -> <name>.png (+ _approved.png, _replay.png), <name>.txt
const { chromium } = require("../playground/node_modules/playwright-core");
const fs = require("fs"), os = require("os"), path = require("path");
const [prompt, name, approve] = [process.argv[2], process.argv[3], process.argv[4]];
const cache = path.join(os.homedir(), "Library/Caches/ms-playwright");
let exe;
for (const d of fs.readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().reverse())
  for (const sub of fs.readdirSync(path.join(cache, d))) {
    const p = path.join(cache, d, sub, "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
    if (!exe && fs.existsSync(p)) exe = p;
  }
(async () => {
  const b = await chromium.launch({ executablePath: exe, headless: true });
  const pg = await b.newPage({ viewport: { width: 1200, height: 1300 } });
  let n = 0; pg.on("websocket", ws => ws.on("framereceived", () => n++));
  const settle = async (needle, max = 150000) => {
    const t0 = Date.now(); let last = n, quiet = Date.now();
    while (Date.now() - t0 < max) {
      await pg.waitForTimeout(1000);
      if (n !== last) { last = n; quiet = Date.now(); }
      if (Date.now() - quiet > 12000 && (!needle || (await pg.innerText("body")).includes(needle))) return;
    }
  };
  const shot = f => pg.screenshot({ path: path.join(__dirname, f), fullPage: true });
  await pg.goto("http://localhost:56171/", { waitUntil: "networkidle" });
  await pg.waitForTimeout(2000);
  await pg.mouse.click(400, 1262); await pg.keyboard.type(prompt); await pg.keyboard.press("Enter");
  await settle(approve ? "Approve" : "");
  await shot(name + ".png");
  fs.writeFileSync(path.join(__dirname, name + ".txt"), await pg.innerText("body"));
  if (approve) {
    const ap = pg.getByRole("button", { name: /^Approve$/ });
    console.log("approve buttons", await ap.count());
    await ap.first().click();
    await pg.waitForTimeout(6000);
    await shot(name + "_approved.png");
    console.log("approve buttons after", await ap.count());
    fs.writeFileSync(path.join(__dirname, name + "_approved.txt"), await pg.innerText("body"));
  }
  await b.close();
})();
