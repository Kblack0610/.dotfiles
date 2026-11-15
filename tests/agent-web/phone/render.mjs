#!/usr/bin/env node
// Renders every agent-web table tab at phone width and records whether a phone can read it.
// No server and no auth: the page is assets::index() (dumped by an ignored Rust test), the
// static files are the checkout's, and /api/* is fixtures.mjs, all through Playwright routing.
//   node tests/agent-web/phone/render.mjs [--out dir] [--control] [--no-kit] [--wide] [--dark] [--api origin]
// --wide draws every tab at 1280px for a before-and-after look; it skips the phone checks.
// --dark draws every page in the dark colour scheme (ui.md rule 14); the checks are the same.
// --api answers /api/* from a running agent-web instead of the fixtures, so a change is seen on
// real data (lessons dotfiles.md: fixtures alone hide what real rows do); the session cookie is
// $AGENT_WEB_SESSION. The fixed clock is off, since the rows are live.
// --control forces body min-width 900px and fails unless every tab reports the overflow.
// The height budget: at a desktop size each tab and each of its inner tabs (app.js INNER_TABS), and
// each inner tab of a project page as big as the one that read 33,558 px (fixtures.mjs BIG_PROJECT),
// stays under BUDGET_SCREENS screens.
// --control opens every fold and shows every inner tab at once, the page before #1983, and fails
// unless the big project page reports it.
// The nav check (web-kit's <kb-shell>): at phone width the menu button shows, the list is hidden,
// a tap opens every group and tab, Escape closes it; at a desktop width the sidebar shows.
// --no-kit answers kb-shell.js with a 404 and fails unless the nav check reports no menu button.
// The cards check: Home at phone width shows every card, two across, and Needs you's head inside the
// first screen; under --control it forces one card per row and fails unless that is reported.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { BIG_PROJECT, FIXTURES, NOW, WIDGET_CARDS } from "./fixtures.mjs";

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
const DESK = { width: 1400, height: 900 };
const BUDGET_SCREENS = 3; // dashboards.md rule 4: no tab past three screens at 1400x900.
const UNFOLD_CSS = "[data-pin][hidden], [data-in][hidden] { display: block !important; }";

// Each tab's first data row; a tab with several tables names the one the brief measures, and a
// tab with inner tabs (app.js INNER_TABS) opens the one holding it (`inner`, `#tab/inner`). A second
// table on a tab is its own entry (`name`), scrolled to so its screenshot shows it.
const DATA_ROW = "tr:has(> td):not(.tfilters)";
const TABS = [
  { tab: "home", row: `#home tr.jr` },
  { tab: "home", name: "home-running", row: `#home [data-tbl="r"] tr.jr` },
  { tab: "queue", row: `#queue tr.qr` },
  { tab: "projects", row: `#p-cards tr.jr` },
  { tab: "projects", name: "projects-all", inner: "all", row: `#p-all tr.jr` },
  { tab: "projects", name: "projects-ladder", inner: "ladder", row: `#p-lstages tr.jr` },
  { tab: "projects", name: "projects-requirements", inner: "ladder", row: `#p-lreqs ${DATA_ROW}` },
  { tab: "sessions", row: `#ov-sessions tr.click` },
  { tab: "sessions", inner: "runners", name: "sessions-runners", row: `#ov-runners tr.wr` },
  { tab: "alerts", row: `#alerts tr.jr` },
  { tab: "infra", inner: "jobs", row: `#jobs tr.jr` },
  { tab: "infra", inner: "runners", name: "infra-local", row: `[data-tbl="u"] ${DATA_ROW}` },
  { tab: "infra", inner: "runs", name: "infra-runs", row: `#ci-runs tr.br` },
  { tab: "infra", inner: "pipelines", name: "infra-pipelines", row: `#ci-pipelines tr.pipr` },
  { tab: "infra", inner: "tests", name: "infra-tests", row: `#ci-tests tr.sr` },
  { tab: "log", row: `#log-work ${DATA_ROW}` },
  { tab: "schedules", row: `#schedules tr.jr` },
  { tab: "costs", inner: "spend", row: `#costs-body ${DATA_ROW}` },
  { tab: "releases", row: `#releases tr.jr` },
];

// The height pass: each tab, every inner tab of one (app.js INNER_TABS, read from the file so a new
// inner tab is measured with no edit here), then the big project page's inner tabs (PROJECT_PAGE).
// A tab is waited on by its TABS row, an inner tab by its own shown group, a project inner tab by
// its first section's heading.
const INNER = JSON.parse(readFileSync(join(STATIC, "app.js"), "utf8").match(/^const INNER_TABS = (.*);$/m)[1]);
const PAGE_HEAD = { overview: "p-needs", rows: "p-rows", build: "p-build", stage: "p-stage", activity: "p-shipped" };
const TALL = [
  ...TABS.filter((t) => !t.name).flatMap((t) => INNER[t.tab]
    ? INNER[t.tab].tabs.map(([id]) => ({ name: `${t.tab}/${id}`, hash: `${t.tab}/${id}`, el: t.tab, ready: `#${t.tab} [data-in="${id}"]:not([hidden])` }))
    : [{ name: t.tab, hash: t.tab, el: t.tab, ready: t.row }]),
  ...Object.entries(PAGE_HEAD).map(([inner, sec]) => ({ name: `project/${inner}`, big: true, hash: `projects/${BIG_PROJECT.profile}/${BIG_PROJECT.name}/${inner}`, el: "projects", ready: `#sec-${sec}` })),
];

const args = process.argv.slice(2);
const control = args.includes("--control");
const noKit = args.includes("--no-kit");
const wide = args.includes("--wide");
const dark = args.includes("--dark");
const apiAt = args.indexOf("--api");
const api = apiAt >= 0 ? args[apiAt + 1].replace(/\/$/, "") : null;
if (api && !process.env.AGENT_WEB_SESSION) throw new Error("--api needs AGENT_WEB_SESSION, the agent_web cookie of that instance");
const outAt = args.indexOf("--out");
const out = outAt >= 0 ? args[outAt + 1] : join(SCRATCH, (control ? "control" : noKit ? "no-kit" : wide ? "wide" : "out") + (dark ? "-dark" : ""));

// The versions npx pins do not match the cached browser, so both are named outright.
function playwright() {
  const npx = join(homedir(), ".npm/_npx");
  const roots = [join(SCRATCH, "node/node_modules/playwright-core"), ...(existsSync(npx) ? readdirSync(npx).map((d) => join(npx, d, "node_modules/playwright-core")) : [])].filter(existsSync);
  const version = (p) => JSON.parse(readFileSync(join(p, "package.json"), "utf8")).version;
  const root = roots.sort((a, b) => version(b).localeCompare(version(a), undefined, { numeric: true }))[0];
  if (!root) throw new Error(`no playwright-core under ${npx} or ${SCRATCH}/node`);
  return createRequire(join(root, "package.json"))("playwright-core");
}
// CI installs the browser its pinned playwright-core names (tests.yml, Phone render harness), so that
// one wins when it is there.
function chromium(pw) {
  const own = pw.chromium.executablePath();
  if (own && existsSync(own)) return own;
  const path = ["chromium-1208", "chromium-1200"].map((d) => join(homedir(), ".cache/ms-playwright", d, "chrome-linux64/chrome")).find(existsSync);
  if (!path) throw new Error("no cached chromium-1208 or chromium-1200 under ~/.cache/ms-playwright");
  return path;
}

// The page and CSP exactly as the server fills them, never a dump left over from another checkout:
// each run dumps into its own directory, so harness runs from two worktrees at once never read each
// other's page. CI points CARGO_TARGET_DIR at the crate's own target, which the rust gate has just built.
function dumpIndex() {
  mkdirSync(SCRATCH, { recursive: true });
  const dir = mkdtempSync(join(SCRATCH, "dump-"));
  const path = join(dir, "index.html");
  const r = spawnSync("cargo", ["test", "--quiet", "assets::tests::dump_index_for_phone_harness", "--", "--ignored", "--exact"], { cwd: WEB, env: { ...process.env, AGENT_WEB_INDEX_OUT: path, CARGO_TARGET_DIR: process.env.CARGO_TARGET_DIR || join(SCRATCH, "target") }, encoding: "utf8" });
  try {
    if (r.status !== 0) throw new Error(`dumping assets::index() failed:\n${r.stdout}\n${r.stderr}`);
    return { index: readFileSync(path, "utf8"), widget: readFileSync(`${path}.widget`, "utf8"), csp: readFileSync(`${path}.csp`, "utf8"), roles: JSON.parse(readFileSync(`${path}.roles`, "utf8")) };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// The server's Column carries each column's phone role; the fixtures name only the keys, so the
// roles come from hub-core itself, matched on the table's whole column list. A fixture table that
// matches none has drifted from the server; it is named with the hub-core table nearest it.
function withRoles(body, roles, drift) {
  const byColumns = new Map(roles.map((t) => [[...t.columns].sort().join(), t]));
  const walk = (v) => {
    if (Array.isArray(v)) return v.map(walk);
    if (!v || typeof v !== "object") return v;
    const out = Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
    if (!Array.isArray(v.columns) || !v.columns[0]?.key) return out;
    const keys = v.columns.map((c) => c.key);
    const t = byColumns.get([...keys].sort().join());
    if (t) out.columns = out.columns.map((c) => ({ ...c, role: c.key === t.lead ? "lead" : t.glance.includes(c.key) ? "glance" : "" }));
    else drift.add(driftLine(keys, roles));
    return out;
  };
  return walk(body);
}
function driftLine(keys, roles) {
  const near = roles.map((t) => ({ t, shared: t.columns.filter((k) => keys.includes(k)).length })).sort((a, b) => b.shared - a.shared)[0]?.t;
  if (!near) return `fixture columns [${keys}] match no hub-core table`;
  const missing = near.columns.filter((k) => !keys.includes(k)), extra = keys.filter((k) => !near.columns.includes(k));
  return `fixture columns [${keys}] match no hub-core table; nearest (lead ${near.lead}) ${missing.length ? `lacks [${missing}]` : ""}${extra.length ? ` has extra [${extra}]` : ""}`;
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

async function wire(context, page, { index, widget, csp, roles }, seen) {
  await context.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== ORIGIN) return route.abort();
    const path = url.pathname;
    if (api && path.startsWith("/api/")) {
      const headers = { cookie: `agent_web=${process.env.AGENT_WEB_SESSION}` };
      return route.fulfill({ response: await route.fetch({ url: api + path + url.search, headers }) });
    }
    if (path === "/") return route.fulfill({ status: 200, contentType: TYPES[".html"], body: index, headers: { ...NOSNIFF, "content-security-policy": csp } });
    // assets::widget(): the page with its cards as JSON, `<` escaped, under the same CSP.
    if (path === "/widget") {
      const data = JSON.stringify({ at: NOW, cards: WIDGET_CARDS }).replaceAll("<", "\\u003c");
      return route.fulfill({ status: 200, contentType: TYPES[".html"], body: widget.replace("{{data}}", data), headers: { ...NOSNIFF, "content-security-policy": csp } });
    }
    if (path.startsWith("/static/")) return route.fulfill(staticFile(path.slice("/static/".length)));
    // A fixture keyed with its query (`/api/queue/candidates?counts=1`) answers that read only.
    const key = (path + url.search) in FIXTURES ? path + url.search : path;
    if (!(key in FIXTURES) && path.startsWith("/api/")) seen.unfixtured.add(path);
    const body = key in FIXTURES ? FIXTURES[key] : {};
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(withRoles(body, roles, seen.drift)) });
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

// A fresh page at a viewport with the clock fixed, the live stream stubbed and every request
// answered by wire(); every check opens its pages through this.
async function openPage(browser, page0, viewport, phone) {
  const context = await browser.newContext({ viewport, deviceScaleFactor: phone ? 2 : 1, hasTouch: phone, isMobile: phone, locale: "en-US", timezoneId: "America/Los_Angeles", colorScheme: dark ? "dark" : "light" });
  const page = await context.newPage();
  const seen = { errors: [], unfixtured: new Set(), drift: new Set() };
  if (!api) await context.clock.setFixedTime(new Date(NOW * 1000));
  await page.addInitScript(() => {
    window.EventSource = class {
      constructor(url) { this.url = url; this.readyState = 1; setTimeout(() => { if (this.onopen) this.onopen({}); }, 0); }
      addEventListener() {}
      close() { this.readyState = 2; }
    };
  });
  await wire(context, page, page0, seen);
  return { context, page, seen };
}

async function renderTab(browser, spec, page0) {
  const { context, page, seen } = await openPage(browser, page0, wide ? WIDE : VIEWPORT, !wide);
  const result = { tab: spec.name || spec.tab, pageOverflowX: null, firstRowTop: null, tableOverflowX: null, leadVisible: null, leadMethod: null };
  try {
    await page.goto(`${ORIGIN}/#${spec.tab}${spec.inner ? "/" + spec.inner : ""}`, { waitUntil: "load" });
    if (control) await page.addStyleTag({ content: CONTROL_CSS });
    await page.waitForLoadState("networkidle");
    if (spec.open) await page.evaluate((id) => { document.getElementById(id).open = true; }, spec.open);
    await page.waitForSelector(spec.row, { state: "visible", timeout: WAIT_MS });
    await page.evaluate(async () => { await document.fonts.ready; await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); });
    if (spec.name) await page.locator(spec.row).first().scrollIntoViewIfNeeded();
    const { badText, ...numbers } = await page.evaluate(measure, { width: (wide ? WIDE : VIEWPORT).width, row: spec.row });
    Object.assign(result, numbers);
    if (badText) seen.errors.push(`a fixture field is missing: the page shows "${badText}"`);
  } catch (e) {
    seen.errors.push(`no row: ${e.message.split("\n")[0]}`);
  }
  await page.screenshot({ path: join(out, `${spec.name || spec.tab}.png`) }).catch((e) => seen.errors.push(`screenshot: ${e.message}`));
  await context.close();
  seen.errors.push(...seen.drift);
  return { ...result, errors: seen.errors, unfixtured: [...seen.unfixtured] };
}

// One page's height at a desktop size: the document's, or its tab element's when that scrolls
// inside its own box. Under --control every fold is opened and every inner tab shown first.
// A drifted fixture fails it, and so does a project read the big project page makes with no
// fixture: a page answered {} draws short and would pass the budget for the wrong reason.
async function heightOf(browser, spec, page0) {
  const { context, page, seen } = await openPage(browser, page0, DESK, false);
  const result = { page: spec.name, big: !!spec.big, height: null, errors: seen.errors };
  try {
    await page.goto(`${ORIGIN}/#${spec.hash}`, { waitUntil: "load" });
    await page.waitForLoadState("networkidle");
    await page.waitForSelector(spec.ready, { state: "visible", timeout: WAIT_MS });
    if (control) {
      await page.addStyleTag({ content: UNFOLD_CSS });
      await page.evaluate(() => { for (const d of document.querySelectorAll("details")) d.open = true; });
    }
    await page.evaluate(async () => { await document.fonts.ready; await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); });
    result.height = await page.evaluate((id) => Math.max(document.documentElement.scrollHeight, document.getElementById(id)?.scrollHeight || 0), spec.el);
  } catch (e) {
    seen.errors.push(`no page: ${e.message.split("\n")[0]}`);
  }
  await page.screenshot({ path: join(out, `tall-${spec.name.replace("/", "-")}.png`) }).catch((e) => seen.errors.push(`screenshot: ${e.message}`));
  await context.close();
  seen.errors.push(...seen.drift);
  const own = [...seen.unfixtured].filter((p) => p.startsWith("/api/projects"));
  if (spec.big && own.length) seen.errors.push(`no fixture, answered {}: ${own.join(", ")}`);
  result.unfixtured = [...seen.unfixtured];
  return result;
}

// The shell at phone width, closed then open then Escaped, and at a desktop width. Each failed
// expectation is one error line; screenshots go beside the tabs' (nav-*.png).
async function navCheck(browser, page0) {
  const errors = [];
  const expect = (ok, what) => { if (!ok) errors.push(what); };
  const shown = (page, sel) => page.locator(sel).first().isVisible().catch(() => false);
  for (const [name, viewport, phone] of [["phone", VIEWPORT, true], ["wide", WIDE, false]]) {
    const { context, page, seen } = await openPage(browser, page0, viewport, phone);
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
    errors.push(...[...seen.errors, ...seen.drift].filter(() => !noKit).map((e) => `${name}: ${e}`));
    await context.close();
  }
  return errors;
}

// Home's cards at phone width: every card shown (none inside a closed fold), two across, the whole
// grid and the Needs you head under it inside the first screen (dashboards.md, the Home row). `css`
// is the --control breakage: one card per row, which must be reported.
const CARDS_CONTROL_CSS = "#home .kgrid { grid-template-columns: 1fr !important; }";
async function cardsCheck(browser, page0, css = null) {
  const errors = [];
  const { context, page, seen } = await openPage(browser, page0, VIEWPORT, true);
  try {
    await page.goto(`${ORIGIN}/#home`, { waitUntil: "load" });
    await page.waitForLoadState("networkidle");
    await page.waitForSelector("#home .kcard", { state: "attached", timeout: WAIT_MS });
    if (css) await page.addStyleTag({ content: css });
    await page.evaluate(async () => { await document.fonts.ready; await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); });
    const c = await page.evaluate(() => {
      const all = [...document.querySelectorAll("#home .kcard")];
      const box = (e) => e.getBoundingClientRect();
      const shown = all.filter((e) => box(e).height > 0 && !e.closest("details:not([open])"));
      const tops = new Set(shown.map((e) => Math.round(box(e).top + window.scrollY)));
      const need = document.getElementById("home-need-head");
      return { all: all.length, shown: shown.length, rows: tops.size, bottom: shown.length ? Math.round(Math.max(...shown.map((e) => box(e).bottom + window.scrollY))) : null,
        need: need ? Math.round(box(need).bottom + window.scrollY) : null };
    });
    if (c.shown < c.all || !c.all) errors.push(`${c.shown} of ${c.all} cards shown`);
    if (c.shown && c.rows > Math.ceil(c.shown / 2)) errors.push(`${c.shown} cards take ${c.rows} rows, not two across`);
    if (c.bottom > VIEWPORT.height) errors.push(`the cards end at ${c.bottom}px, past the first screen (${VIEWPORT.height}px)`);
    if (c.need == null || c.need > VIEWPORT.height) errors.push(`the Needs you head ends at ${c.need}px, not inside the first screen`);
  } catch (e) {
    errors.push(e.message.split("\n")[0]);
  }
  await page.screenshot({ path: join(out, "home-cards.png") }).catch((e) => errors.push(`screenshot: ${e.message}`));
  errors.push(...seen.errors, ...seen.drift);
  await context.close();
  return errors;
}

// The home-screen widget at two widget sizes (a 4x3 and a 4x2 cell widget): every card shown, two
// across, inside the widget with its number unclipped, the page never scrolling. A web-widget app
// snapshots the viewport, so anything past it is lost, not scrolled to.
const WIDGET_SIZES = [{ width: 360, height: 420 }, { width: 360, height: 280 }];
const WIDGET_CONTROL_CSS = ".wgrid { grid-template-columns: 1fr !important; }";
async function widgetCheck(browser, page0, css = null) {
  const errors = [];
  for (const size of WIDGET_SIZES) {
    const at = `${size.width}x${size.height}`;
    const { context, page, seen } = await openPage(browser, page0, size, true);
    try {
      await page.goto(`${ORIGIN}/widget`, { waitUntil: "load" });
      await page.waitForSelector(".wgrid .kcard", { state: "attached", timeout: WAIT_MS });
      if (css) await page.addStyleTag({ content: css });
      await page.evaluate(async () => { await document.fonts.ready; await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); });
      const w = await page.evaluate(({ width, height }) => {
        const cards = [...document.querySelectorAll(".wgrid .kcard")];
        const box = (e) => e.getBoundingClientRect();
        return { n: cards.length, cols: new Set(cards.map((c) => Math.round(box(c).left))).size,
          past: cards.filter((c) => box(c).bottom > height || box(c).right > width).map((c) => c.dataset.card),
          // A line the card cuts off (past its bottom) or squeezes (shorter than its own content).
          clipped: cards.filter((c) => !c.querySelector(".kbig") || [...c.children].some((e) => e.getClientRects().length &&
            (box(e).bottom > box(c).bottom - 1 || e.scrollHeight > e.clientHeight + 1))).map((c) => c.dataset.card),
          scrolls: document.documentElement.scrollHeight > height || document.documentElement.scrollWidth > width,
          bad: document.body.innerText.match(/.{0,30}\b(undefined|NaN)\b.{0,20}/)?.[0] ?? null };
      }, size);
      if (w.n !== WIDGET_CARDS.length) errors.push(`${at}: ${w.n} of ${WIDGET_CARDS.length} cards drawn`);
      if (w.cols !== 2) errors.push(`${at}: the cards sit ${w.cols} across, not two across`);
      if (w.past.length) errors.push(`${at}: ${w.past.join(", ")} past the widget's edge`);
      if (w.clipped.length) errors.push(`${at}: a line is cut or squeezed on ${w.clipped.join(", ")}`);
      if (w.scrolls) errors.push(`${at}: the page scrolls, so a snapshot loses its end`);
      if (w.bad) errors.push(`${at}: the page shows "${w.bad}"`);
    } catch (e) {
      errors.push(`${at}: ${e.message.split("\n")[0]}`);
    }
    await page.screenshot({ path: join(out, `widget-${at}.png`) }).catch((e) => errors.push(`screenshot: ${e.message}`));
    errors.push(...seen.errors, ...seen.drift);
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
  const pw = playwright();
  const browser = await pw.chromium.launch({ headless: true, executablePath: chromium(pw) });
  const results = [];
  // --control proves the overflow detector alone; the nav check has its own control, --no-kit.
  const navErrors = control || wide ? [] : await navCheck(browser, page);
  const cardErrors = wide || noKit ? [] : await cardsCheck(browser, page, control ? CARDS_CONTROL_CSS : null);
  const widgetErrors = wide || noKit ? [] : await widgetCheck(browser, page, control ? WIDGET_CONTROL_CSS : null);
  if (!noKit) for (const spec of TABS) results.push(await renderTab(browser, spec, page));
  const heights = [];
  if (!noKit) for (const spec of TALL) heights.push(await heightOf(browser, spec, page));
  await browser.close();
  for (const e of navErrors) console.log(`NAV ${e}`);
  for (const e of cardErrors) console.log(`CARDS ${e}`);
  for (const e of widgetErrors) console.log(`WIDGET ${e}`);
  if (control && !cardErrors.some((e) => e.includes("not two across"))) { console.log("FAIL: --control: the cards check did not report one card per row"); process.exit(1); }
  if (control && !widgetErrors.some((e) => e.includes("not two across"))) { console.log("FAIL: --control: the widget check did not report one card per row"); process.exit(1); }
  if (noKit) {
    if (!navErrors.some((e) => e.includes("no menu button"))) { console.log("FAIL: --no-kit control: the nav check did not report the missing menu button"); process.exit(1); }
    console.log("no-kit control ok: the nav check reported the missing menu button");
    return;
  }
  const fail = [];
  if (navErrors.length) fail.push(`nav check, ${navErrors.length} error(s)`);
  else if (!control && !wide) console.log("nav ok: phone menu opens and closes, wide sidebar shows");
  if (!control && cardErrors.length) fail.push(`Home cards check, ${cardErrors.length} error(s)`);
  else if (!control && !wide) console.log("cards ok: Home's cards show two across, they and the Needs you head inside the first screen");
  if (!control && widgetErrors.length) fail.push(`widget check, ${widgetErrors.length} error(s)`);
  else if (!control && !wide) console.log(`widget ok: ${WIDGET_CARDS.length} cards two across inside the widget at ${WIDGET_SIZES.map((s) => `${s.width}x${s.height}`).join(" and ")}`);
  writeFileSync(join(out, "numbers.json"), JSON.stringify(results, null, 2) + "\n");
  print(results);
  console.log(`screenshots and numbers.json: ${out}`);
  const budget = BUDGET_SCREENS * DESK.height;
  console.log(`\nheight at ${DESK.width}x${DESK.height}, budget ${budget}px${control ? " (control: every fold open, every inner tab shown)" : ""}`);
  for (const h of heights) console.log(`${h.page.padEnd(20)}${String(h.height).padStart(7)}${h.height > budget ? "  over" : ""}${h.errors.map((e) => `  ERROR ${e}`).join("")}${h.unfixtured.length ? `  note: no fixture for ${h.unfixtured.join(", ")}` : ""}`);
  const unmeasured = heights.filter((h) => h.errors.length || h.height == null);
  if (unmeasured.length) fail.push(`height not measured on ${unmeasured.map((h) => h.page).join(", ")}`);
  const tall = heights.filter((h) => h.height > budget);
  if (!control && tall.length) fail.push(`over ${BUDGET_SCREENS} screens on ${tall.map((h) => `${h.page} ${h.height}px`).join(", ")}`);
  const errored = results.filter((r) => r.errors.length);
  if (errored.length) fail.push(`errors on ${errored.map((r) => r.tab).join(", ")}`);
  // --wide is a look, not a phone check: only errors and the height budget fail it.
  if (wide) { for (const f of fail) console.log(`FAIL: ${f}`); if (fail.length) process.exit(1); return; }
  // A tab whose row has no lead, or whose lead runs off the screen, is what this harness exists to catch.
  const cut = control ? [] : results.filter((r) => r.leadVisible !== true || r.leadMethod !== "data-role");
  if (cut.length) fail.push(`no visible lead on ${cut.map((r) => r.tab).join(", ")}`);
  if (control) {
    const missedTall = heights.filter((h) => h.big && !(h.height > budget));
    if (missedTall.length) fail.push(`control height not reported on ${missedTall.map((h) => h.page).join(", ")}`);
    const missed = results.filter((r) => !(r.pageOverflowX > 0));
    if (missed.length) fail.push(`control overflow not reported on ${missed.map((r) => r.tab).join(", ")}`);
  }
  for (const f of fail) console.log(`FAIL: ${f}`);
  if (fail.length) process.exit(1);
  if (control) console.log("control ok: every tab reported the forced overflow, and the big project page the height");
}

main().catch((e) => { console.error(e); process.exit(1); });
