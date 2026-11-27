// After-run driver: sends a prompt in Playground, logs ws frames with ms timestamps,
// screenshots every ~600ms during the turn (frames/), final screenshot. Usage: node drive_after.cjs "<prompt>" <outdir>
const { chromium } = require("../playground/node_modules/playwright-core");
const fs = require("fs"), os = require("os"), path = require("path");
const prompt = process.argv[2], out = process.argv[3] || ".";
fs.mkdirSync(path.join(out, "frames"), { recursive: true });
const cache = path.join(os.homedir(), "Library/Caches/ms-playwright");
const dirs = fs.readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort((a, b) => parseInt(b.split("-")[1]) - parseInt(a.split("-")[1]));
let exe;
for (const d of dirs) for (const sub of fs.readdirSync(path.join(cache, d))) {
  const p = path.join(cache, d, sub, "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
  if (!exe && fs.existsSync(p)) exe = p;
}
const ts = () => { const d = new Date(); return d.toTimeString().slice(0, 8) + "." + String(d.getMilliseconds()).padStart(3, "0"); };
(async () => {
  const b = await chromium.launch({ executablePath: exe, headless: true });
  const pg = await b.newPage({ viewport: { width: 1200, height: 900 } });
  const frames = [];
  pg.on("websocket", ws => {
    ws.on("framereceived", f => frames.push({ ts: ts(), t: Date.now(), dir: "recv", data: String(f.payload).slice(0, 6000) }));
  });
  await pg.goto("http://localhost:56170/", { waitUntil: "networkidle" });
  await pg.waitForTimeout(2000);
  await pg.mouse.click(400, 852);
  await pg.keyboard.type(prompt);
  const sent = Date.now();
  frames.push({ ts: ts(), t: sent, dir: "ui", data: "SEND " + prompt });
  await pg.keyboard.press("Enter");
  let i = 0, last = frames.length, quiet = Date.now();
  while (Date.now() - sent < 120000) {
    await pg.screenshot({ path: path.join(out, "frames", `f${String(i++).padStart(3, "0")}_${Date.now() - sent}ms.png`) });
    await pg.waitForTimeout(400);
    if (frames.length !== last) { last = frames.length; quiet = Date.now(); }
    if (Date.now() - quiet > 12000 && frames.length > 3) break;
  }
  await pg.screenshot({ path: path.join(out, "final.png"), fullPage: true });
  fs.writeFileSync(path.join(out, "ws_frames.json"), JSON.stringify(frames, null, 1));
  fs.writeFileSync(path.join(out, "page_text.txt"), await pg.innerText("body"));
  await b.close();
})();
