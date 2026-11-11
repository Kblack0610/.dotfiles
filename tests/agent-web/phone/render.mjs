#!/usr/bin/env node
// Renders every agent-web table tab at phone width and records whether a phone can read it.
// No server and no auth: the page is assets::index() (dumped by an ignored Rust test), the
// static files are the checkout's, and /api/* is fixtures.mjs, all through Playwright routing.
//   node tests/agent-web/phone/render.mjs [--out dir] [--control] [--no-kit]
// --control forces body min-width 900px and fails unless every tab reports the overflow.
// The nav check (web-kit's <kb-shell>): at phone width the menu button shows, the list is hidden,
// a tap opens every group and tab, Escape closes it; at a desktop width the sidebar shows.
// --no-kit answers kb-shell.js with a 404 and fails unless the nav check reports no menu button.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { FIXTURES, NOW } from "./fixtures.mjs";

const VIEWPORT = { width: 390, height: 844 };
const ORIGIN = "https://agent-web.invalid";
const WAIT_MS = 15000; // A guard on a tab that never draws, not a pacing delay.
const SCRATCH = join(homedir(), ".cache/agent-web-phone");
const ROOT = fileURLToPath(new URL("../../../", import.meta.url));
const WEB = join(ROOT, ".local/src/agent-web");
const STATIC = join(WEB, "static");
const KIT = join(ROOT, ".local/src/web-kit");
const WIDE = { width: 1280, height: 800 };
const NAV = { menu: "kb-shell .kb-menu", nav: "kb-shell .kb-nav", group: ".kb-nav .kb-group", item: ".kb-nav > [id^=tab-]", cur: "kb-shell .kb-cur", script: "kb-shell.js" };
const CONTROL_CSS = "body { min-width: 900px !important; }";

// Each tab's first data row; a tab with several tables names the one the brief measures, and a
// tab with inner tabs (app.js INNER_TABS) opens the one holding it (`inner`, `#tab/inner`).
const DATA_ROW = "tr:has(> td)";
const TABS = [
  { tab: "home", row: `#home tr.jr` },
  { tab: "queue", row: `#queue tr.qr` },
  { tab: "projects", row: `#p-cards tr.jr` },
  { tab: "board", row: `#board tr.jr` },
  { tab: "sessions", row: `#scroll tr.click` },
  { tab: "alerts", row: `#alerts tr.jr` },
  { tab: "infra", inner: "jobs", row: `#jobs tr.jr` },
  { tab: "log", row: `#log-work ${DATA_ROW}` },
  { tab: "fleet", row: `#fleet tr.wr` },
  { tab: "schedules", row: `#schedules tr.jr` },
  { tab: "costs", inner: "spend", row: `#costs-body ${DATA_ROW}` },
  { tab: "releases", row: `#releases tr.jr` },
];

const args = process.argv.slice(2);
const control = args.includes("--control");
const noKit = args.includes("--no-kit");
const outAt = args.indexOf("--out");
const out = outAt >= 0 ? args[outAt + 1] : join(SCRATCH, control ? "control" : noKit ? "no-kit" : "out");

// The versions npx pins do not match the cached browser, so both are named outright.
function playwright() {
  const npx = join(homedir(), ".npm/_npx");
  const roots = [join(SCRATCH, "node/node_modules/playwright-core"), ...(existsSync(npx) ? readdirSync(npx).map((d) => join(npx, d, "node_modules/playwright-core")) : [])].filter(existsSync);
  const version = (p) => JSON.parse(readFileSync(join(p, "package.json"), "utf8")).version;
  const root = roots.sort((a, b) => version(b).localeCompare(version(a), undefined, { numeric: true }))[0];
  if (!root) throw new Error(`no playwright-core under ${npx} or ${SCRATCH}/node`);
  return createRequire(join(root, "package.json"))("playwright-core");
}
function chromium() {
  const path = ["chromium-1208", "chromium-1200"].map((d) => join(homedir(), ".cache/ms-playwright", d, "chrome-linux64/chrome")).find(existsSync);
  if (!path) throw new Error("no cached chromium-1208 or chromium-1200 under ~/.cache/ms-playwright");
  return path;
}

// The page and CSP exactly as the server fills them, never a dump left over from another checkout.
function dumpIndex() {
  mkdirSync(SCRATCH, { recursive: true });
  const path = join(SCRATCH, "index.html");
  const r = spawnSync("cargo", ["test", "--quiet", "assets::tests::dump_index_for_phone_harness", "--", "--ignored", "--exact"], { cwd: WEB, env: { ...process.env, AGENT_WEB_INDEX_OUT: path, CARGO_TARGET_DIR: join(SCRATCH, "target") }, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`dumping assets::index() failed:\n${r.stdout}\n${r.stderr}`);
  return { index: readFileSync(path, "utf8"), csp: readFileSync(`${path}.csp`, "utf8"), roles: JSON.parse(readFileSync(`${path}.roles`, "utf8")) };
}

// The server's Column carries each column's phone role; the fixtures name only the keys, so the
// roles come from hub-core itself, matched on the table's whole column list.
function withRoles(body, roles) {
  const byColumns = new Map(roles.map((t) => [[...t.columns].sort().join(), t]));
  const walk = (v) => {
    if (Array.isArray(v)) return v.map(walk);
    if (!v || typeof v !== "object") return v;
    const out = Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
    const t = Array.isArray(v.columns) && v.columns[0]?.key && byColumns.get(v.columns.map((c) => c.key).sort().join());
    if (t) out.columns = out.columns.map((c) => ({ ...c, role: c.key === t.lead ? "lead" : t.glance.includes(c.key) ? "glance" : "" }));
    return out;
  };
  return walk(body);
}

const JS = "text/javascript; charset=utf-8";
const TYPES = { ".css": "text/css; charset=utf-8", ".js": JS, ".woff2": "font/woff2", ".html": "text/html; charset=utf-8" };
const NOSNIFF = { "x-content-type-options": "nosniff", "referrer-policy": "same-origin" };

// agent-web serves its own static files and web-kit's under one flat /static/ (assets.rs FILES).
function staticFile(name) {
  if (noKit && name === NAV.script) return { status: 404, contentType: "text/plain", body: "no-kit control", headers: NOSNIFF };
  const path = [join(STATIC, name), join(KIT, name)].find(existsSync) || join(STATIC, name);
  if (!existsSync(path)) return { status: 404, contentType: "text/plain", body: `no ${name}`, headers: NOSNIFF };
  const raw = readFileSync(path);
  const body = name.endsWith(".css") ? raw.toString("utf8").replaceAll("{{v}}", "harness") : raw;
  return { status: 200, contentType: TYPES[extname(name)], body, headers: NOSNIFF };
}

async function wire(context, page, { index, csp, roles }, seen) {
  await context.route("**/*", (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== ORIGIN) return route.abort();
    const path = url.pathname;
    if (path === "/") return route.fulfill({ status: 200, contentType: TYPES[".html"], body: index, headers: { ...NOSNIFF, "content-security-policy": csp } });
    if (path.startsWith("/static/")) return route.fulfill(staticFile(path.slice("/static/".length)));
    if (!(path in FIXTURES) && path.startsWith("/api/")) seen.unfixtured.add(path);
    const body = path in FIXTURES ? FIXTURES[path] : {};
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(withRoles(body, roles)) });
  });
  page.on("pageerror", (e) => seen.errors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => { if (m.type() === "error") seen.errors.push(`console: ${m.text()}`); });
}

// Runs in the page. Every width is against the viewport constant: a phone zooms out to fit a page
// that is too wide, which grows innerWidth to match and would read as no overflow.
function measure({ width, row: selector }) {
  // A closed fold keeps its boxes in layout (content-visibility), so it is ruled out by name.
  const shown = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !e.closest("details:not([open])"); };
  const scrollBox = (e) => {
    for (let p = e.parentElement; p; p = p.parentElement) if (["auto", "scroll"].includes(getComputedStyle(p).overflowX)) return p;
    return e.parentElement;
  };
  let widest = null;
  for (const t of document.querySelectorAll("table")) if (shown(t) && (!widest || t.scrollWidth > widest.scrollWidth)) widest = t;
  const row = [...document.querySelectorAll(selector)].find(shown) || null;
  const marked = row && row.querySelector('td[data-role="lead"]');
  const lead = marked || (row && [...row.children].sort((a, b) => b.textContent.trim().length - a.textContent.trim().length)[0]);
  const box = lead && lead.getBoundingClientRect();
  return {
    pageOverflowX: document.documentElement.scrollWidth - width,
    firstRowTop: row ? Math.round(row.getBoundingClientRect().top + window.scrollY) : null,
    tableOverflowX: widest ? widest.scrollWidth - scrollBox(widest).clientWidth : null,
    leadVisible: box ? box.left >= 0 && box.right <= width : null,
    leadMethod: marked ? "data-role" : lead ? "widest-text" : null,
    badText: document.body.innerText.match(/.{0,50}(\b(undefined|NaN)\b|\[object ).{0,20}/)?.[0] ?? null,
  };
}

async function renderTab(browser, spec, page0) {
  const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 2, hasTouch: true, isMobile: true, locale: "en-US", timezoneId: "America/Los_Angeles" });
  const page = await context.newPage();
  const seen = { errors: [], unfixtured: new Set() };
  await context.clock.setFixedTime(new Date(NOW * 1000));
  await page.addInitScript(() => {
    window.EventSource = class {
      constructor(url) { this.url = url; this.readyState = 1; setTimeout(() => { if (this.onopen) this.onopen({}); }, 0); }
      addEventListener() {}
      close() { this.readyState = 2; }
    };
  });
  await wire(context, page, page0, seen);
  const result = { tab: spec.tab, pageOverflowX: null, firstRowTop: null, tableOverflowX: null, leadVisible: null, leadMethod: null };
  try {
    await page.goto(`${ORIGIN}/#${spec.tab}${spec.inner ? "/" + spec.inner : ""}`, { waitUntil: "load" });
    if (control) await page.addStyleTag({ content: CONTROL_CSS });
    await page.waitForLoadState("networkidle");
    if (spec.open) await page.evaluate((id) => { document.getElementById(id).open = true; }, spec.open);
    await page.waitForSelector(spec.row, { state: "visible", timeout: WAIT_MS });
    await page.evaluate(async () => { await document.fonts.ready; await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); });
    const { badText, ...numbers } = await page.evaluate(measure, { width: VIEWPORT.width, row: spec.row });
    Object.assign(result, numbers);
    if (badText) seen.errors.push(`a fixture field is missing: the page shows "${badText}"`);
  } catch (e) {
    seen.errors.push(`no row: ${e.message.split("\n")[0]}`);
  }
  await page.screenshot({ path: join(out, `${spec.tab}.png`) }).catch((e) => seen.errors.push(`screenshot: ${e.message}`));
  await context.close();
  return { ...result, errors: seen.errors, unfixtured: [...seen.unfixtured] };
}

// The shell at phone width, closed then open then Escaped, and at a desktop width. Each failed
// expectation is one error line; screenshots go beside the tabs' (nav-*.png).
async function navCheck(browser, page0) {
  const errors = [];
  const expect = (ok, what) => { if (!ok) errors.push(what); };
  const shown = (page, sel) => page.locator(sel).first().isVisible().catch(() => false);
  for (const [name, viewport, phone] of [["phone", VIEWPORT, true], ["wide", WIDE, false]]) {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, hasTouch: phone, isMobile: phone, locale: "en-US", timezoneId: "America/Los_Angeles" });
    const page = await context.newPage();
    const seen = { errors: [], unfixtured: new Set() };
    await context.clock.setFixedTime(new Date(NOW * 1000));
    await page.addInitScript(() => { window.EventSource = class { constructor() { this.readyState = 1; } addEventListener() {} close() {} }; });
    await wire(context, page, page0, seen);
    try {
      await page.goto(`${ORIGIN}/#home`, { waitUntil: "load" });
      await page.waitForLoadState("networkidle");
      await page.evaluate(async () => { await document.fonts.ready; });
      const items = await page.locator(NAV.item).count();
      const groups = await page.locator(NAV.group).count();
      expect(items >= 2 && groups >= 1, `${name}: ${items} tabs and ${groups} group headings in the nav`);
      if (phone) {
        expect(await shown(page, NAV.menu), `${name}: no menu button`);
        expect(!(await shown(page, NAV.nav)), `${name}: the tab list shows before the menu is opened`);
        const cur = (await page.locator(NAV.cur).first().textContent().catch(() => "")) || "";
        expect(cur.trim() === "Home", `${name}: current tab label is "${cur.trim()}", not Home`);
        await page.screenshot({ path: join(out, `nav-${name}-closed.png`) });
        if (await shown(page, NAV.menu)) {
          await page.locator(NAV.menu).first().click();
          expect(await shown(page, NAV.nav), `${name}: the menu did not open the tab list`);
          const visible = await page.locator(NAV.item).evaluateAll((es) => es.filter((e) => e.getBoundingClientRect().height > 0).length);
          expect(visible === items, `${name}: ${visible} of ${items} tabs visible in the open menu`);
          const groupsShown = await page.locator(NAV.group).evaluateAll((es) => es.filter((e) => e.getBoundingClientRect().height > 0).length);
          expect(groupsShown === groups, `${name}: ${groupsShown} of ${groups} group headings visible in the open menu`);
          await page.screenshot({ path: join(out, `nav-${name}-open.png`) });
          await page.keyboard.press("Escape");
          expect(!(await shown(page, NAV.nav)), `${name}: Escape did not close the menu`);
        }
      } else {
        expect(await shown(page, NAV.nav), `${name}: the sidebar is not shown`);
        expect(!(await shown(page, NAV.menu)), `${name}: the menu button shows on a wide screen`);
        await page.screenshot({ path: join(out, `nav-${name}.png`) });
      }
      const over = await page.evaluate((w) => document.documentElement.scrollWidth - w, viewport.width);
      expect(over <= 0, `${name}: the page scrolls sideways by ${over}px`);
    } catch (e) {
      errors.push(`${name}: ${e.message.split("\n")[0]}`);
    }
    errors.push(...seen.errors.filter((e) => !noKit).map((e) => `${name}: ${e}`));
    await context.close();
  }
  return errors;
}

function print(results) {
  const cols = ["tab", "pageOverflowX", "firstRowTop", "tableOverflowX", "leadVisible", "leadMethod"];
  const cells = [cols, ...results.map((r) => cols.map((c) => String(r[c])))];
  const widths = cols.map((_, i) => Math.max(...cells.map((row) => row[i].length)));
  for (const row of cells) console.log(row.map((c, i) => c.padEnd(widths[i])).join("  "));
  for (const r of results) {
    for (const e of r.errors) console.log(`ERROR ${r.tab}: ${e}`);
    if (r.unfixtured.length) console.log(`note ${r.tab}: no fixture, answered {}: ${r.unfixtured.join(", ")}`);
  }
}

async function main() {
  mkdirSync(out, { recursive: true });
  const page = dumpIndex();
  const browser = await playwright().chromium.launch({ headless: true, executablePath: chromium() });
  const results = [];
  // --control proves the overflow detector alone; the nav check has its own control, --no-kit.
  const navErrors = control ? [] : await navCheck(browser, page);
  if (!noKit) for (const spec of TABS) results.push(await renderTab(browser, spec, page));
  await browser.close();
  for (const e of navErrors) console.log(`NAV ${e}`);
  if (noKit) {
    if (!navErrors.some((e) => e.includes("no menu button"))) { console.log("FAIL: --no-kit control: the nav check did not report the missing menu button"); process.exit(1); }
    console.log("no-kit control ok: the nav check reported the missing menu button");
    return;
  }
  if (navErrors.length) { console.log(`FAIL: nav check, ${navErrors.length} error(s)`); process.exit(1); }
  if (!control) console.log("nav ok: phone menu opens and closes, wide sidebar shows");
  writeFileSync(join(out, "numbers.json"), JSON.stringify(results, null, 2) + "\n");
  print(results);
  console.log(`screenshots and numbers.json: ${out}`);
  const errored = results.filter((r) => r.errors.length);
  if (errored.length) { console.log(`FAIL: errors on ${errored.map((r) => r.tab).join(", ")}`); process.exit(1); }
  // A tab whose row has no lead, or whose lead runs off the screen, is what this harness exists to catch.
  const cut = control ? [] : results.filter((r) => r.leadVisible !== true || r.leadMethod !== "data-role");
  if (cut.length) { console.log(`FAIL: no visible lead on ${cut.map((r) => r.tab).join(", ")}`); process.exit(1); }
  if (control) {
    const missed = results.filter((r) => !(r.pageOverflowX > 0));
    if (missed.length) { console.log(`FAIL: control overflow not reported on ${missed.map((r) => r.tab).join(", ")}`); process.exit(1); }
    console.log("control ok: every tab reported the forced overflow");
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
