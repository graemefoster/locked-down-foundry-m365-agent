// v8 driver: node drive_edit.cjs <name> "<prompt>" edit|form  (edit: fill Body textarea, Approve; form: fill form, submit)
// Fresh page per scenario; shots mid-turn (progress) and final; dumps body text + ws frames.
const { chromium } = require("../playground/node_modules/playwright-core");
const fs = require("fs"), os = require("os"), path = require("path");
const [name, prompt, action] = process.argv.slice(2);
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
    ws.on("framereceived", f => frames.push({ ts: ts(), dir: "recv", data: String(f.payload).slice(0, 8000) }));
    ws.on("framesent", f => frames.push({ ts: ts(), dir: "sent", data: String(f.payload).slice(0, 3000) }));
  });
  const settle = async (max = 120000, quietMs = 15000) => {
    const t0 = Date.now(); let last = frames.length, quiet = Date.now();
    while (Date.now() - t0 < max) {
      await pg.waitForTimeout(1000);
      if (frames.length !== last) { last = frames.length; quiet = Date.now(); }
      if (Date.now() - quiet > quietMs) return;
    }
  };
  const shot = async n => { await pg.mouse.move(400, 600); await pg.mouse.wheel(0, 6000); await pg.waitForTimeout(600); await pg.screenshot({ path: path.join(out, `${name}_${n}.png`), fullPage: true }); };
  await pg.goto("http://localhost:56170/", { waitUntil: "networkidle" });
  await pg.waitForTimeout(2000);
  await pg.mouse.click(400, 1262); await pg.keyboard.type(prompt); await pg.keyboard.press("Enter");
  frames.push({ ts: ts(), dir: "ui", data: "SEND " + prompt });
  await pg.waitForTimeout(1800);
  await shot("mid");
  fs.writeFileSync(path.join(out, `${name}_mid.txt`), await pg.innerText("body"));
  await settle();
  await shot("final");
  fs.writeFileSync(path.join(out, `${name}_final.txt`), await pg.innerText("body"));
  if (action === "edit") {
    const fu = pg.getByRole("button", { name: /Draft a reply|reply/i }).first();
    if (!(await pg.locator("textarea").count()) && (await fu.count())) { await fu.click(); await settle(); await shot("followup"); }
    frames.push({ ts: ts(), dir: "ui", data: "textareas=" + (await pg.locator("textarea").count()) });
    await shot("card_before");
    const ta = pg.locator("textarea").last();
    await ta.fill("EDITED BODY v8: hello from the card editor.\nSecond line.");
    await shot("card_edited");
    await pg.getByRole("button", { name: /^Approve$/ }).first().click();
    frames.push({ ts: ts(), dir: "ui", data: "CLICK Approve" });
    await pg.waitForTimeout(5000);
    await shot("approved");
    fs.writeFileSync(path.join(out, `${name}_approved.txt`), await pg.innerText("body"));
  }
  if (action === "form") {
    const t = pg.locator("input[type=text], input:not([type])");
    frames.push({ ts: ts(), dir: "ui", data: "text inputs=" + (await t.count()) });
    for (const sel of await pg.locator("select").all()) { try { await sel.selectOption({ index: 1 }); } catch (e) {} }
    await shot("form_filled");
    await pg.getByRole("button", { name: /^Schedule$/ }).last().click();
    await settle(30000, 6000);
    await shot("after_submit");
    fs.writeFileSync(path.join(out, `${name}_after_submit.txt`), await pg.innerText("body"));
  }
  fs.writeFileSync(path.join(out, `${name}_frames.json`), JSON.stringify(frames, null, 1));
  await b.close();
})();
