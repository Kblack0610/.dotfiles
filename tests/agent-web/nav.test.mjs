// The sidebar's outline (static/nav.js), run from tests/unit/agent_web_queue.bats: the real
// scripts in one vm context, over a stub page.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const anchor = (id, title, tagName = "H2") => ({ id, tagName, open: false, scrolled: 0, matches: () => tagName === "H2", querySelector: (q) => (tagName === "H2" ? null : q === "h2" ? { firstChild: { textContent: title + " " } } : { firstChild: { textContent: title + " (3)" } }), firstChild: { textContent: title + " " }, scrollIntoView() { this.scrolled++; } });
const boards = {};
const buttons = {};
const made = [];
let observed;
const doc = {
  getElementById: (id) => (id.startsWith("tab-") ? (buttons[id] ??= Object.assign(el(), { placed: 0, after() { this.placed++; } })) : id in boards ? boards[id] : el()),
  addEventListener() {}, querySelector: el, querySelectorAll: () => [],
  createElement: () => { const e = Object.assign(el(), { innerHTML: "" }); made.push(e); return e; },
  body: el(),
};
const ctx = vm.createContext({
  console, document: doc, window: { addEventListener() {} }, URLSearchParams, history: { replaceState() {} },
  location: { hash: "", pathname: "/", search: "" },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
  EventSource: function () { return el(); }, setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0,
  MutationObserver: function (f) { observed = f; this.observe = () => {}; },
  requestAnimationFrame: (f) => f(),
});
for (const f of ["ui.js", "app.js", "nav.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const outline = made.find((e) => e.className === "outl");
const show = (tab, anchors) => {
  boards[tab] = { querySelectorAll: () => anchors };
  vm.runInContext(`st.tab = ${JSON.stringify(tab)}`, ctx);
  observed();
};

test("the open tab's anchors are listed under its button, by their own headings", () => {
  show("infra", [anchor("sec-red", "Red now"), anchor("sec-ci", "CI")]);
  assert.match(outline.innerHTML, /data-sec="red">Red now</);
  assert.match(outline.innerHTML, /data-sec="ci">CI</);
  assert.equal(buttons["tab-infra"].placed, 1);
});

test("a fold is listed by its heading's title, without the count beside it", () => {
  show("queue", [anchor("sec-flow", "Flow"), anchor("sec-candidates", "Candidates", "DETAILS")]);
  assert.match(outline.innerHTML, /data-sec="candidates">Candidates</);
});

test("one anchor is no outline", () => {
  show("releases", [anchor("sec-builds", "Builds")]);
  assert.equal(outline.innerHTML, "");
});

test("a repaint with the same sections writes nothing", () => {
  show("costs", [anchor("sec-burn", "Burn"), anchor("sec-table", "Costs")]);
  const placed = buttons["tab-costs"].placed;
  show("costs", [anchor("sec-burn", "Burn"), anchor("sec-table", "Costs")]);
  assert.equal(buttons["tab-costs"].placed, placed);
});

test("a click opens that section on the showing board, not a same-named one on a hidden board", () => {
  const hidden = anchor("sec-table", "Queue", "DETAILS");
  boards.queue = { querySelectorAll: () => [hidden] };
  const here = anchor("sec-table", "Costs", "DETAILS");
  show("costs", [anchor("sec-burn", "Burn"), here]);
  outline.onclick({ target: { closest: () => ({ dataset: { sec: "table" } }) } });
  assert.equal(here.open, true);
  assert.equal(here.scrolled, 1);
  assert.equal(hidden.open, false);
});
