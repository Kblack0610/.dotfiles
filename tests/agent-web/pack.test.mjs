// Home's packed card grid (static/cards.js packCards) against the drawn mark (static/ui.js
// drawnCheck), run from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context as home.test.mjs loads them; #home's stub turns each paint into a grid of card stubs
// whose heights the test sets, and the ResizeObserver and the frames run only when the test says,
// as in a browser that has not ticked yet (a throttled scratch Firefox, a screenshot between ticks).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
// What happened, in order: "span <card>", "packed", "drawn".
const log = [];
let tall = (i) => 100 + 20 * i;
// The grid a paint draws: one stub per card in the HTML, each new and unspanned, as innerHTML makes them.
function gridOf(html) {
  if (!html.includes('<div class="kgrid">')) return null;
  const cards = [...html.matchAll(/<section class="kcard" data-card="([^"]+)"/g)].map((m, i) => {
    let end = "";
    const style = {};
    Object.defineProperty(style, "gridRowEnd", { get: () => end, set: (v) => { end = v; log.push(`span ${m[1]}`); } });
    return { card: m[1], style, getBoundingClientRect: () => ({ height: tall(i) }) };
  });
  const cls = new Set();
  return { cards, cls, querySelectorAll: (s) => (s === ".kcard" ? cards : []),
    classList: { add: (c) => { cls.add(c); log.push(c); }, remove: (c) => cls.delete(c), contains: (c) => cls.has(c) } };
}
let grid = null;
const box = Object.assign(el(), { id: "home", scrollTop: 0, querySelectorAll: () => [], querySelector: (s) => (s === ".kgrid" ? grid : null) });
Object.defineProperty(box, "innerHTML", { get: () => "", set: (h) => { grid = gridOf(h); } });
const dataset = new Proxy({}, { set: (t, k, v) => { if (k === "drawn") log.push("drawn"); t[k] = v; return true; } });
const main = Object.assign(el(), { dataset });
const parts = {};
const doc = { getElementById: (id) => (id === "home" ? box : id === "main" ? main : (parts[id] ??= el())), addEventListener() {}, querySelector: el, querySelectorAll: () => [] };
const frames = [], observers = [];
class ResizeObserver {
  constructor(f) { this.f = f; this.seen = new Set(); observers.push(this); }
  observe(c) { this.seen.add(c); }
  disconnect() { this.seen.clear(); }
}
const ctx = vm.createContext({
  console, ResizeObserver,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  history: { replaceState() {} },
  location: { hash: "", pathname: "/", search: "" },
  performance: { now: () => 0 },
  getComputedStyle: () => ({ columnGap: "10px" }),
  requestAnimationFrame: (f) => frames.push(f),
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
const page = readFileSync(new URL("../src/index.html", dir), "utf8");
const scripts = new Set(["kb-ui.js", "ui.js", "md.js", "app.js", "actions.js", "table.js", "flow.js", "waiting.js", "cards.js", "home.js", "queue.js"]);
for (const f of [...page.matchAll(/static\/([a-z-]+\.js)/g)].map((m) => m[1]).filter((f) => scripts.has(f))) vm.runInContext(readFileSync(new URL(f === "kb-ui.js" ? "../../web-kit/kb-ui.js" : f, dir), "utf8"), ctx, { filename: f });
// app.js reads /api/session-options at load; let it answer, so no read is out when a test checks the mark.
await new Promise((r) => setImmediate(r));

const frame = () => { for (const f of frames.splice(0)) f(); };
// The browser's layout step: the newest observer hears every card it watches.
const resized = () => { const o = observers.at(-1); o.f([...o.seen].map((target) => ({ target, borderBoxSize: [{ blockSize: target.getBoundingClientRect().height }] }))); };
const COLS = ["rank", "kind", "project", "waited", "holds", "what"];
const table = (cols) => ({ q: "", state: "", sort: "", dir: "desc", total: 0, shown: 0, states: [{ name: "all", n: 0 }], facets: [],
  columns: cols.map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })) });
const home = { proposals: [], proposals_head: "", proposals_table: table(["stream", "project", "proposal", "created", "verb"]), streams: [], health: [], errors: [], needs: [], table: table(COLS),
  vitals: { head: "1 of 2 off target", all_ok: false, rows: [{ question: "Outcome", level: "warn", parts: ["3 of 5"] }] } };
const card = (tab) => ({ tab, title: tab, big: "3", unit: "live", level: "ok", bar: [{ level: "ok", n: 3 }], parts: [], lists: [], counted: tab, error: null, link: `#${tab}` });
const TABS = ["releases", "schedules", "projects", "queue"];
ctx.input = { home, cards: TABS.map(card) };
vm.runInContext("conn.open = true; st.tab = 'home'; hst.data = input.home; hst.cards = input.cards; hst.cardsErr = null", ctx);
const redraw = () => vm.runInContext("drawHome()", ctx);
const spans = () => grid.cards.map((c) => c.style.gridRowEnd);
const want = () => grid.cards.map((c, i) => `span ${Math.ceil(tall(i) + 10)}`);

function reset(t) {
  tall = t;
  log.length = 0;
  frames.length = 0;
  delete dataset.drawn;
  vm.runInContext("st.tab = 'home'", ctx);
}

test("a Home redraw spans every card before the grid packs, in the draw's own task, and the mark comes after", () => {
  reset((i) => 100 + 20 * i);
  redraw();
  // No observer answer and no frame yet: what a screenshot taken now would draw.
  assert.deepEqual(spans(), want(), "every card spans its own height plus the gap");
  assert.deepEqual(log, [...TABS.map((t) => `span ${t}`), "packed"], "the spans are written before .packed, never after");
  vm.runInContext("drawnCheck()", ctx);
  frame();
  assert.equal(dataset.drawn, "home");
  assert.equal(log.at(-1), "drawn", "the mark lands after the pack");
  // A poll's redraw while the mark stands: the new grid is spanned before it packs, again.
  log.length = 0;
  redraw();
  assert.deepEqual(log, [...TABS.map((t) => `span ${t}`), "packed"]);
  assert.deepEqual(spans(), want());
  // A later size change (a font, a rewrap) is the observer's.
  tall = (i) => 200 + i;
  resized();
  assert.deepEqual(spans(), want(), "the observer respans a card whose height changed");
});

test("a grid drawn while hidden stays unpacked and holds Home's mark, not another tab's, until its observer packs it", () => {
  reset(() => 0);
  redraw();
  assert.ok(!grid.cls.has("packed"), "no heights, no packed rows");
  assert.deepEqual(spans(), TABS.map(() => ""));
  vm.runInContext("drawnCheck()", ctx);
  frame();
  assert.equal(dataset.drawn, undefined, "Home's grid is not laid out yet");
  vm.runInContext("st.tab = 'costs'; drawnCheck()", ctx);
  frame();
  assert.equal(dataset.drawn, "costs", "the hold is Home's alone");
  delete dataset.drawn;
  vm.runInContext("st.tab = 'home'", ctx);
  tall = (i) => 120 + i;
  resized();
  assert.ok(grid.cls.has("packed"));
  assert.deepEqual(spans(), want());
  assert.ok(log.indexOf("packed") > log.lastIndexOf("span queue"), "spanned before packed");
  frame();
  assert.equal(dataset.drawn, "home", "the observer's pack lets the mark land");
});
