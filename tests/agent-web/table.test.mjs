// Unit tests for tblTab (.local/src/agent-web/static/table.js), the skeleton every tab on the
// shared table draws with, run by `node --test` from tests/unit/agent_web_queue.bats. The page's
// real scripts load into one vm context with a stub DOM; the tabs' own tests check what each draws,
// this checks what they all share: the placeholder, the repaint around a control in use, the more
// button, the scroll a whole draw keeps, and which of two tables in one block an event belongs to.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : (() => el())),
  set: (t, k, v) => { t[k] = v; return true; },
});
const on = {};
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const parts = {};
const box = (id) => (parts[id] ||= part());
box("tt").addEventListener = (ev, f) => { (on[ev] ||= []).push(f); };
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const doc = { getElementById: (id) => (id.startsWith("t") ? box(id) : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
const asked = [];
let body = {};
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: { pathname: "/", hash: "" },
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body, text: async () => "" }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "table.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const tick = () => new Promise((r) => setImmediate(r));

const summary = { q: "", state: "", sort: "", dir: "", total: 3, shown: 3, states: [{ name: "all", n: 3 }], columns: [], facets: [] };
// Two tables drawn into one element, as Home's are: the second's keys carry the prefix "n" and its
// block a data-tbl="n". The scroller is reset by every whole draw, as replacing innerHTML resets
// the scrolling parent in a browser.
run(`
  st.tab = "tt";
  var one = tblTab({ tab: "tt", id: "tt", api: "/api/one", hint: "", scroller: "tscroll", body: (t) => "rows " + t.data.rows.slice(0, t.all ? undefined : 1).join(",") + tblMore(t.all ? 0 : t.data.rows.length - 1),
    draw: (html) => { $("tt").innerHTML = html; $("tscroll").scrollTop = 0; } });
  var two = tblTab({ tab: "tt", id: "tn", el: "tt", pre: "n", refresh: () => {}, table: () => one.data?.table, body: () => "second", render: () => {} });
`);
const target = (data, tbl = "") => ({ dataset: data, closest: (sel) => (sel === "[data-tbl]" ? (tbl ? { dataset: { tbl } } : null) : sel === "[data-tsort]" && "tsort" in data ? { dataset: data } : null) });

test("no answer yet waits, a failed first read says why as an error", async () => {
  run(`one.data = null; one.err = null; one.render()`);
  assert.equal(box("tt").innerHTML, `<div class="empty">Loading...</div>`);
  run(`one.err = "502 bad gateway"; one.render()`);
  assert.equal(box("tt").innerHTML, `<div class="card err">502 bad gateway</div>`);
});

test("a whole draw keeps the scroller where the reader left it", () => {
  run(`one.err = null; one.data = { table: input, rows: ["a", "b", "c"] }`.replace("input", JSON.stringify(summary)));
  box("tscroll").scrollTop = 40;
  run(`one.render()`);
  assert.match(box("tt").innerHTML, /rows a<button class="btn sm" data-all="1">\+2 older/);
  assert.equal(box("tscroll").scrollTop, 40);
});

test("the more button lifts the cap, and a view change puts it back", async () => {
  fire("click", { type: "click", target: target({ all: "1" }) });
  assert.equal(run("one.all"), true);
  assert.match(box("tt").innerHTML, /rows a,b,c/);
  body = { table: summary, rows: ["a", "b", "c"] };
  fire("click", { type: "click", target: target({ tsort: "name", tdir: "asc" }) });
  await tick();
  assert.equal(run("one.all"), false);
  assert.equal(asked.at(-1), "/api/one?sort=name&dir=asc");
});

test("an event in the second table's block moves only that table's keys", () => {
  run(`st.views.tt = ""; two.all = false`);
  asked.length = 0;
  fire("click", { type: "click", target: target({ tsort: "when", tdir: "" }, "n") });
  assert.equal(run("st.views.tt"), "nsort=when");
  assert.equal(asked.length, 0, "the first table did not re-read");
  fire("click", { type: "click", target: target({ all: "1" }, "n") });
  assert.equal(run("two.all"), true);
  assert.equal(run("one.all"), false);
});

test("with a dropdown in use only what is around it repaints", () => {
  run(`one.render()`);
  box("tt").innerHTML = "the bar in use";
  doc.activeElement = { id: "", dataset: { tq: "" }, closest: (sel) => (sel === "#tt-facets" ? {} : null) };
  run(`one.data.rows = ["z"]; one.all = false; one.render()`);
  doc.activeElement = null;
  assert.equal(box("tt").innerHTML, "the bar in use");
  assert.match(box("tt-body").innerHTML, /rows z/);
});
