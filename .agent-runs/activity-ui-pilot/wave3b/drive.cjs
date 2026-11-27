// Wave2 driver: turn 1 (inbox+calendar) -> click follow-up button -> approval card -> Approve.
// Usage: node drive2.cjs "<prompt>"   (run from ../playground for playwright-core)
const { chromium } = require("../playground/node_modules/playwright-core");
const fs = require("fs"), os = require("os"), path = require("path");
const prompt = process.argv[2] || "Summarise my inbox and calendar for today";
const out = __dirname;
const cache = path.join(os.homedir(), "Library/Caches/ms-playwright");
let exe;
for (const d of fs.readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().reverse())
  for (const sub of fs.readdirSync(path.join(cache, d))) {
    const p = path.join(cache, d, sub, "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
    if (!exe && fs.existsSync(p)) exe = p;
  }
const frames = [];
const ts = () => new Date().toTimeString().slice(0, 8);
(async () => {
  const b = await chromium.launch({ executablePath: exe, headless: true });
  const pg = await b.newPage({ viewport: { width: 1200, height: 1300 } });
  pg.on("websocket", ws => {
    ws.on("framereceived", f => frames.push({ ts: ts(), dir: "recv", data: String(f.payload).slice(0, 6000) }));
    ws.on("framesent", f => frames.push({ ts: ts(), dir: "sent", data: String(f.payload).slice(0, 6000) }));
  });
  const settle = async (needle, max = 120000) => {
    const t0 = Date.now(); let last = frames.length, quiet = Date.now();
    while (Date.now() - t0 < max) {
      await pg.waitForTimeout(1000);
      if (frames.length !== last) { last = frames.length; quiet = Date.now(); }
      if (Date.now() - quiet > 12000 && (!needle || (await pg.innerText("body")).includes(needle))) return;
    }
  };
  const shot = n => pg.screenshot({ path: path.join(out, n), fullPage: true });
  await pg.goto("http://localhost:56170/", { waitUntil: "networkidle" });
  await pg.waitForTimeout(2000);
  const send = async t => { await pg.mouse.click(400, 1262); await pg.keyboard.type(t); await pg.keyboard.press("Enter"); };
  const step = process.argv[3] || "all";
  frames.push({ ts: ts(), dir: "ui", data: "SEND " + prompt });
  await send(prompt);
  await settle("Unread");
  await shot("final.png");
  await pg.mouse.move(400, 600); await pg.mouse.wheel(0, 3000); await pg.waitForTimeout(800); await shot("donut_bottom.png");
  fs.writeFileSync(path.join(out, "page_text_turn1.txt"), await pg.innerText("body"));
  // click the follow-up button
  const btn = pg.getByRole("button", { name: /Draft a reply to/i }).first();
  const n = await pg.getByRole("button").count();
  frames.push({ ts: ts(), dir: "ui", data: "buttons=" + n + " followup_visible=" + (await btn.count()) });
  await btn.click();
  frames.push({ ts: ts(), dir: "ui", data: "CLICK follow-up" });
  await settle("Approve", 150000);
  await pg.mouse.move(400, 600); await pg.mouse.wheel(0, 5000); await pg.waitForTimeout(800);
  await shot("followup_turn.png");
  await shot("pending.png");
  fs.writeFileSync(path.join(out, "page_text_turn2.txt"), await pg.innerText("body"));
  const ap = pg.getByRole("button", { name: /^Approve$/ }).first();
  frames.push({ ts: ts(), dir: "ui", data: "approve_buttons=" + (await ap.count()) });
  await ap.click();
  frames.push({ ts: ts(), dir: "ui", data: "CLICK Approve" });
  await pg.waitForTimeout(5000);
  await shot("approved.png");
  fs.writeFileSync(path.join(out, "page_text_after_approve.txt"), await pg.innerText("body"));
  frames.push({ ts: ts(), dir: "ui", data: "approve_buttons_after=" + (await pg.getByRole("button", { name: /^Approve$/ }).count()) });
  fs.writeFileSync(path.join(out, "ws_frames.json"), JSON.stringify(frames, null, 1));
  await b.close();
})();
