// Unit tests for Log's Actions table (.local/src/agent-web/static/actions.js), run by `node --test`
// from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What a query keeps and how it sorts is
// hub_core::table, tested in Rust; this checks the page draws the server's rows and summary, and
// that the view and the window travel in Log's URL query to the API.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const on = {};
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const box = Object.assign(part(), { addEventListener: (ev, f) => { on[ev] = f; } });
const parts = { "actions-head": part(), "actions-facets": part(), "actions-chips": part(), "actions-body": part(), "sec-actions": part() };
const doc = { getElementById: (id) => (id === "actions" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
let asked = [];
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
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "actions.js", "table.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const ast = run("ast");

const col = (key, sort = null, next = [key, "desc"]) => ({ key, sort, next_sort: next[0], next_dir: next[1] });
// The shape hub_core::table::Summary serializes to, for `actor:shepherd`, newest first.
const table = {
  q: "actor:shepherd", state: "", sort: "", dir: "", total: 3, shown: 2,
  states: [{ name: "all", n: 2 }, { name: "loud", n: 0 }, { name: "failed", n: 1 }],
  columns: ["when", "actor", "verb", "priority", "source", "text"].map((k) => col(k)),
  facets: [{ key: "actor", on: "shepherd", clear: "", values: [{ value: "shepherd", n: 2, q: "actor:shepherd" }, { value: "notify", n: 1, q: "actor:notify" }] }],
};
const act = (i, o = {}) => ({ at: 1793942659 - i, actor: "shepherd", verb: "nudge", text: `agent-${i} <stalled>`, priority: null, reference: null, source: "shepherd", ...o });
const data = { actions: [act(1), act(2, { verb: "failed", priority: "high" })], counts: { shepherd: { nudge: 1, failed: 1 }, notify: { page: 1 } }, errors: [], table };

const target = (attrs) => ({ dataset: attrs, closest: (sel) => { const k = /^\[data-(.*)\]$/.exec(sel)?.[1].replace(/-(.)/g, (m, c) => c.toUpperCase()); return k in attrs ? { dataset: attrs } : null; } });
const click = (attrs) => on.click({ target: target(attrs), type: "click" });
const settle = () => new Promise((r) => setImmediate(r));
const fresh = () => { Object.assign(ast, { data, err: null, read: null, all: false }); asked = []; body = data; run("st.tab = 'log'; st.views.log = ''"); };

test("the table draws the server's rows, chips and dropdowns with no day headings", () => {
  fresh();
  run("renderActions()");
  const h = box.innerHTML;
  assert.match(h, /2 of 3 in 24h/);
  assert.match(h, /data-tsort="when"/, "every column header sorts");
  assert.match(h, /value="actor:shepherd"/, "the query sits in the search box");
  assert.match(h, /<option value="actor:notify">notify \(1\)<\/option>/, "the actors are a dropdown");
  assert.match(h, /data-ts="failed">failed <span class="n">1/, "the state chips carry the server's counts");
  assert.match(h, /<b>failed<\/b><\/td><td>high<\/td>/);
  assert.match(h, /title="2026-[^"]*Z"/, "the exact time is on the cell");
  assert.match(h, /agent-1 &lt;stalled&gt;/, "a row's text is escaped");
  assert.doesNotMatch(h, /frow|flist/);
});

test("a chip, a header and a window each go into the URL and the API query", async () => {
  fresh();
  click({ ts: "failed" });
  await settle();
  assert.equal(run("st.views.log"), "s=failed");
  assert.match(asked.at(-1), /\/api\/actions\?s=failed&hours=24$/);
  click({ tsort: "when", tdir: "asc" });
  await settle();
  assert.equal(run("st.views.log"), "s=failed&sort=when&dir=asc");
  click({ hours: "72" });
  await settle();
  assert.equal(run("st.views.log"), "s=failed&sort=when&dir=asc&hours=72");
  assert.match(asked.at(-1), /hours=72$/);
  assert.match(box.innerHTML, /class="on" data-hours="72"/);
  click({ hours: "24" });
  await settle();
  assert.equal(run("st.views.log"), "s=failed&sort=when&dir=asc", "the default window leaves the URL bare");
});

test("another tab's link lands on the filtered view and opens its section", async () => {
  fresh();
  run("st.tab = 'sessions'; showActions('shepherd', 'skip')");
  await settle();
  assert.equal(run("st.tab"), "log");
  assert.equal(run("st.views.log"), "q=actor%3Ashepherd+verb%3Askip");
  assert.equal(parts["sec-actions"].open, true);
  assert.match(asked.at(-1), /q=actor%3Ashepherd\+verb%3Askip&hours=24$/);
});

test("the view already read does not reopen a section the human folded", async () => {
  fresh();
  run("st.views.log = 's=loud'");
  ast.read = "s=loud";
  parts["sec-actions"].open = false;
  run("LOG_PARTS.at(-1).show()");
  await settle();
  assert.equal(parts["sec-actions"].open, false);
});

test("the rows stop at the fold cap until +N older is pressed", () => {
  fresh();
  const many = Array.from({ length: run("LOG_ROWS") + 3 }, (_, i) => act(i));
  ast.data = { ...data, actions: many };
  run("renderActions()");
  assert.match(box.innerHTML, /data-all="1">\+3 older/);
  click({ all: "1" });
  assert.doesNotMatch(box.innerHTML, /data-all/);
});

test("a refresh keeps the search box the human is typing in", () => {
  fresh();
  run("renderActions()");
  const painted = box.innerHTML;
  doc.activeElement = { id: "actions-q", dataset: {} };
  run("renderActions()");
  doc.activeElement = null;
  assert.equal(box.innerHTML, painted, "the bar stays");
  assert.match(parts["actions-body"].innerHTML, /agent-1/, "the rows around it repaint");
  assert.match(parts["actions-chips"].innerHTML, /data-ts="failed"/);
});

test("an empty answer says which kind of empty it is", () => {
  fresh();
  ast.data = { ...data, actions: [], table: { ...table, shown: 0 } };
  run("renderActions()");
  assert.match(box.innerHTML, /No action matches/);
  ast.data = { ...data, actions: [], table: { ...table, shown: 0, total: 0 } };
  run("renderActions()");
  assert.match(box.innerHTML, /Nothing recorded in the window/);
});

test("a ledger that could not be read is named above the table", () => {
  fresh();
  ast.data = { ...data, errors: ["dispatch.log: denied"] };
  run("renderActions()");
  assert.match(box.innerHTML, /unread: dispatch\.log: denied/);
});

test("a failed read says so over the rows it could not replace", () => {
  fresh();
  ast.err = "502";
  run("renderActions()");
  assert.match(box.innerHTML, /card err">502/);
  assert.match(box.innerHTML, /agent-1/);
});
