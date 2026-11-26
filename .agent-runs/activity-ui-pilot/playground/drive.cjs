// Drives the Playground UI for one turn; logs every websocket frame with a timestamp
// and saves a screenshot. Usage: node drive.cjs "<prompt>" <outdir>
const { chromium } = require("playwright-core");
const fs = require("fs");
const os = require("os");
const path = require("path");
const prompt = process.argv[2] || "summarise my inbox";
const out = process.argv[3] || "../baseline";
const cache = path.join(os.homedir(), "Library/Caches/ms-playwright");
const dirs = fs.readdirSync(cache).filter(d => /^chromium-\d+$/.test(d))
  .sort((a, b) => parseInt(b.split("-")[1]) - parseInt(a.split("-")[1]));
let exe;
for (const d of dirs) {
  const base = path.join(cache, d);
  for (const sub of fs.readdirSync(base)) {
    const p = path.join(base, sub, "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
    if (!exe && fs.existsSync(p)) exe = p;
  }
}
const ts = () => { const d = new Date(); return d.toTimeString().slice(0, 8) + "." + String(d.getMilliseconds()).padStart(3, "0"); };
(async () => {
  const b = await chromium.launch({ executablePath: exe, headless: true });
  const pg = await b.newPage({ viewport: { width: 1200, height: 900 } });
  const frames = [];
  pg.on("websocket", ws => {
    ws.on("framereceived", f => frames.push({ ts: ts(), dir: "recv", data: String(f.payload).slice(0, 4000) }));
    ws.on("framesent", f => frames.push({ ts: ts(), dir: "sent", data: String(f.payload).slice(0, 4000) }));
  });
  await pg.goto("http://localhost:56170/", { waitUntil: "networkidle" });
  await pg.waitForTimeout(2000);
  await pg.mouse.click(400, 852);
  await pg.keyboard.type(prompt);
  frames.push({ ts: ts(), dir: "ui", data: "SEND " + prompt });
  await pg.keyboard.press("Enter");
  // wait until the final reply is quiet for 20s or 240s max
  const t0 = Date.now(); let last = frames.length, quiet = Date.now();
  while (Date.now() - t0 < 240000) {
    await pg.waitForTimeout(1000);
    if (frames.length !== last) { last = frames.length; quiet = Date.now(); }
    if (Date.now() - quiet > 20000 && frames.some(f => /Working on your request/.test(f.data))) break;
  }
  await pg.screenshot({ path: path.join(out, "playground.png"), fullPage: true });
  fs.writeFileSync(path.join(out, "ws_frames.json"), JSON.stringify(frames, null, 1));
  fs.writeFileSync(path.join(out, "page_text.txt"), await pg.innerText("body"));
  await b.close();
})();
