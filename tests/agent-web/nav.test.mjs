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
const anchor = (id, title, tagName = "H2") => ({ id, tagName, open: false, scrolled: 0, matches: (q) => q === tagName.toLowerCase(), querySelector: (q) => (tagName === "H2" ? null : q === "h2" ? { firstChild: { textContent: title + " " } } : { firstChild: { textContent: title + " (3)" } }), firstChild: { textContent: title + " " }, scrollIntoView() { this.scrolled++; } });
const boards = {};
const buttons = {};
const made = [];
let observed;
const heard = {};
const doc = {
  getElementById: (id) => (id.startsWith("tab-") ? (buttons[id] ??= Object.assign(el(), { placed: 0, after() { this.placed++; } })) : id in boards ? boards[id] : el()),
  addEventListener(ev, f) { (heard[ev] ??= []).push(f); }, querySelector: el, querySelectorAll: () => [],
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
  boards[tab] = { querySelectorAll: (q) => (q.startsWith("[id^=") ? anchors : []) };
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

test("a wrapper div is not listed, even with a heading inside it", () => {
  const wrap = Object.assign(anchor("sec-history", "Merges by hour", "DIV"), { querySelector: () => ({ firstChild: { textContent: "Merges by hour" } }) });
  show("log", [anchor("sec-actions", "Actions", "DETAILS"), anchor("sec-changes", "Changes", "DETAILS"), wrap]);
  assert.doesNotMatch(outline.innerHTML, /Merges/);
});

test("a section repainted away before the click leaves nothing pending", () => {
  show("infra", [anchor("sec-red", "Red now"), anchor("sec-ci", "CI")]);
  boards.infra = { querySelectorAll: () => [] };
  outline.onclick({ target: { closest: () => ({ dataset: { sec: "ci" } }) } });
  assert.equal(vm.runInContext("st.section", ctx), null);
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

test("a section painted later above the sought one does not leave it off screen, until the reader scrolls", () => {
  const tests = anchor("sec-tests", "Tests");
  const board = { scrollTop: 0, querySelectorAll: (q) => (q.startsWith("[id^=") ? [tests] : []) };
  // Where scrollIntoView leaves the board: the anchor's offset, which a paint above it raises.
  let offset = 400;
  tests.scrollIntoView = function () { this.scrolled++; board.scrollTop = offset; };
  tests.getBoundingClientRect = () => ({ top: offset - board.scrollTop });
  boards.log = board;
  vm.runInContext('st.tab = "log"; st.section = "tests"; seekSection()', ctx);
  assert.equal(tests.scrolled, 1);
  vm.runInContext("seekSection()", ctx); // a repaint that moved nothing
  assert.equal(tests.scrolled, 1, "an anchor already on top is not scrolled again");
  offset = 9000; // the runs table paints above Tests; the board did not move, so Tests is pushed down
  vm.runInContext("seekSection()", ctx);
  assert.equal(tests.scrolled, 2);
  assert.equal(board.scrollTop, 9000);
  board.scrollTop = 8000; // the reader scrolls
  vm.runInContext("seekSection()", ctx);
  assert.equal(tests.scrolled, 2);
  board.scrollTop = 9000;
  vm.runInContext("seekSection()", ctx);
  assert.equal(tests.scrolled, 2, "a dropped hold stays dropped");
});

test("a reader's input or a new pending section ends the hold, and a hold never pulls back to an old section", () => {
  const tests = anchor("sec-tests", "Tests");
  const board = { scrollTop: 0, querySelectorAll: (q) => (q.startsWith("[id^=") ? [tests] : []) };
  let offset = 400;
  tests.scrollIntoView = function () { this.scrolled++; board.scrollTop = offset; };
  tests.getBoundingClientRect = () => ({ top: offset - board.scrollTop });
  boards.log = board;
  vm.runInContext('st.tab = "log"; st.section = "tests"; seekSection()', ctx);
  assert.equal(tests.scrolled, 1);
  // The reader opens a fold above Tests: no scroll, but a click.
  for (const f of heard.pointerdown) f();
  offset = 700;
  vm.runInContext("seekSection()", ctx);
  assert.equal(tests.scrolled, 1, "input ended the hold");
  // A fresh seek holds again; then a new section is asked for that has not painted yet.
  vm.runInContext('st.section = "tests"; seekSection()', ctx);
  assert.equal(tests.scrolled, 2);
  vm.runInContext('st.section = "jobs"', ctx);
  offset = 5000;
  vm.runInContext("seekSection()", ctx);
  assert.equal(tests.scrolled, 2, "the pending section is the target, not the old hold");
  vm.runInContext("st.section = null; seekSection()", ctx);
  assert.equal(tests.scrolled, 2, "and the old hold is gone");
});
