// Unit tests for Log's Work table (.local/src/agent-web/static/work.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the browser
// loads them; only the DOM is a stub. What the reader joins and what a window keeps is
// hub_core::worklog, tested in Rust; this checks the page draws the server's rows and that the day
// and the view travel in Log's URL query to the API.
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
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ??= []).push(f); } });
const parts = { "work-head": part(), "work-facets": part(), "work-tiles": part(), "work-body": part(), "work-tail": part() };
const doc = { getElementById: (id) => (id === "log-work" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
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
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body, text: async () => "" }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "queue.js", "work.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const wrk = run("wrk");

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = { q: "", state: "", sort: "", dir: "", total: 3, shown: 2, states: [{ name: "all", n: 2 }, { name: "done", n: 1 }], columns: ["state", "when", "project", "what", "kind", "pr", "cost"].map(col), facets: [] };
const today = new Date(Date.now() - new Date().getTimezoneOffset() * 60e3).toISOString().slice(0, 10);
const row = (o = {}) => ({ state: "done", when: `${today}T09:30`, project: "notes", what: "fix <it>", kind: "fix", pr: "notes#7", url: "https://x/7", cost: 1.5, slug: "a", unproven: false, ...o });
const data = { rows: [row(), row({ state: "failed", when: "2026-01-03T08:05", pr: null, url: null, cost: null })], more: 0, errors: [], today, items_from: "2026-11-04", prs_from: "2026-10-14", table };

const target = (attrs) => ({ dataset: attrs, closest: (sel) => { const k = /^\[data-(.*)\]$/.exec(sel)?.[1].replace(/-(.)/g, (m, c) => c.toUpperCase()); return k in attrs ? { dataset: attrs } : null; } });
const click = (attrs, extra = {}) => on.click.forEach((f) => f({ target: Object.assign(target({ tbl: "w", ...attrs }), extra), type: "click" }));
const settle = () => new Promise((r) => setImmediate(r));
const fresh = (d = data) => { Object.assign(wrk, { data: d, err: null, all: false }); asked = []; body = d; run("st.tab = 'log'; st.views.log = ''; lst.hist = []"); };

test("a row reads state, time, project, the work, its PR and cost, and escapes the text", () => {
  fresh();
  run("wrk.render()");
  const h = box.innerHTML;
  assert.match(h, /--c:var\(--b-done\)">done<\/span>/);
  assert.match(h, /title="[^"]*T09:30">09:30<\/td>/, "today's time is its clock");
  assert.match(h, />01-03 08:05<\/td>/, "an older one keeps its date");
  assert.match(h, /fix &lt;it&gt;/);
  assert.match(h, /<a href="https:\/\/x\/7"[^>]*>notes#7<\/a>/);
  assert.match(h, /<h2 class="sec">Work <span class="n">2 of 3<\/span><\/h2>/);
  assert.match(h, /queue items from 2026-11-04, merged PRs from 2026-10-14/);
  assert.match(h, /<a href="#board">Board<\/a>/);
});

test("an unread source is an error card above the rows, and an empty window says so", () => {
  fresh({ ...data, errors: ["daylog 2026-11-01.json"] });
  run("wrk.render()");
  assert.match(box.innerHTML, /card err">unread: daylog 2026-11-01\.json/);
  fresh({ ...data, rows: [], table: { ...table, total: 0, shown: 0 } });
  run("wrk.render()");
  assert.match(box.innerHTML, /Nothing in this window\./);
  fresh({ ...data, rows: [], table: { ...table, total: 3, shown: 0 } });
  run("wrk.render()");
  assert.match(box.innerHTML, /No work matches\./);
});

test("a day window goes into the URL and the API query; the plain window leaves them bare", async () => {
  fresh();
  click({ twin: "day", tval: "30d" });
  await settle();
  assert.equal(run("st.views.log"), "wday=30d");
  assert.match(asked.at(-1), /\/api\/log\/work\?wday=30d$/);
  assert.match(box.innerHTML, /class="on" data-twin="day" data-tval="30d"/);
  click({ twin: "day", tval: "" });
  await settle();
  assert.equal(run("st.views.log"), "");
  assert.match(asked.at(-1), /\/api\/log\/work$/);
});

test("a state chip keeps its own prefix beside the day", async () => {
  fresh();
  run("st.views.log = 'wday=today'");
  click({ ts: "done" });
  await settle();
  assert.equal(run("st.views.log"), "wday=today&ws=done");
  assert.match(asked.at(-1), /ws=done/);
});

test("+N more asks the server for every row rather than slicing what it has", async () => {
  fresh();
  click({ all: "1" });
  await settle();
  assert.match(asked.at(-1), /all=1/);
});

test("today is the server's, so a phone in another timezone reads the same clock", () => {
  fresh({ ...data, today: "2026-01-03" });
  run("wrk.render()");
  assert.match(box.innerHTML, />08:05<\/td>/);
});

test("a view changed by a link or Back drops the +N more of the last one", async () => {
  fresh();
  wrk.all = true;
  wrk.read = "";
  run("st.views.log = 'ws=done'; LOG_PARTS[LOG_PARTS.length - 1].show()");
  await settle();
  assert.equal(wrk.all, false);
  assert.ok(asked.length && asked.every((u) => !u.includes("all=1")), asked.join(" "));
});

test("stepping to a day writes wday, and stepping back to today writes the today window", async () => {
  fresh();
  run("goDay('2026-11-03')");
  await settle();
  assert.equal(run("st.views.log"), "wday=2026-11-03");
  run("goDay(null)");
  await settle();
  assert.equal(run("st.views.log"), "wday=today");
});
