// Unit tests for the Schedules tab (.local/src/agent-web/static/schedules.js), run by `node --test`
// from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What a query keeps and how it sorts is
// hub_core::table, and what a row says is hub_core::schedules, both tested in Rust; this checks
// that the page draws them and turns each click into the view keys it sends back.
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
const box = Object.assign(part(), { addEventListener: (ev, f) => { on[ev] = f; } });
const parts = { "sched-head": part(), "sched-facets": part(), "sched-chips": part(), "sched-body": part() };
const doc = { getElementById: (id) => (id === "schedules" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
const asked = [];
let body = {};
const loc = { pathname: "/", hash: "" };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: loc,
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body, text: async () => "" }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "actions.js", "table.js", "jobs.js", "schedules.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const sst = run("sst");

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = {
  q: "", state: "red", sort: "", dir: "", total: 3, shown: 2,
  states: [{ name: "all", n: 3 }, { name: "red", n: 2 }, { name: "ok", n: 1 }, { name: "unknown", n: 0 }, { name: "no-purpose", n: 1 }],
  columns: ["kind", "name", "schedule", "last", "result", "streak", "triage", "repo", "next"].map(col),
  facets: [{ key: "kind", on: null, clear: "", values: [{ value: "ci", n: 2, q: "kind:ci" }] }],
};
const row = (kind, name, o = {}) => ({ kind, name, repo: "", schedule: "02:00 daily", purpose: "", last: 1793942659, result: "failure", ok: false, streak: -6, red_since: 1793442659, triage: "-", next: null, inside: "", before: "", after: [], open: [], runs: [], page: "", status: "", ...o });
const run1 = (n) => ({ at: 1793942659 - n, result: "failure", ok: false, failed: ["PlayMode 2", "PlayMode 8"], url: `https://ci/${n}` });
const nightly = row("ci", "playground / Tests", {
  purpose: "the only full run of every class on main", triage: "queued nightly-triage-1", status: "red since 11-01, triage queued, next 02:00",
  inside: "Plan -> PlayMode 1..8", before: "cron 0 10 * * * UTC", after: ["Sentinel playground-nightly (pages urgent)", "triage agent playground-nightly-fix"], open: ["nightly-triage-1 (queued)"],
  runs: [run1(0), run1(1), run1(2), run1(3)],
});
const data = { at: 1793942700, summary: "3 scheduled, 2 red, 1 no purpose, CI read 7m ago", errors: [], table,
  rows: [nightly, row("timer", "journal-sync"), row("agentctl", "dream", { page: "dream", purpose: "nightly memory", result: "WORKED", ok: true, streak: 9 })] };

const target = (attrs, tr = null) => ({ dataset: attrs, closest: (sel) => (sel === "tr.jr" ? tr : (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) ? { dataset: attrs } : null) });
const show = () => { run("st.tab = 'schedules'"); Object.assign(sst, { data, err: null, sel: null }); run("renderSchedules()"); };

test("the table draws the summary, the mock's columns and a missing purpose", () => {
  show();
  const h = box.innerHTML;
  assert.match(h, /3 scheduled, 2 red, 1 no purpose, CI read 7m ago/);
  for (const c of ["kind", "name", "schedule", "last", "result", "streak", "triage"]) assert.match(h, new RegExp(`data-tsort="${c}"`));
  assert.doesNotMatch(h, /data-tsort="repo"/, "repo sorts and filters without a column");
  assert.match(h, /<td class="bad">red 6<\/td>/);
  assert.match(h, /<td class="">green 9<\/td>/);
  assert.match(h, /journal-sync <span class="warn"[^>]*>no purpose<\/span>/, "a missing purpose is amber");
  assert.match(h, /queued nightly-triage-1/);
  assert.match(h, /<button class="on" data-ts="red">red <span class="n">2<\/span><\/button>/);
  assert.match(h, /id="sched-q"/);
});

test("a row opens its detail and folds runs past the second", () => {
  show();
  on.click({ target: target({}, { dataset: { key: "ci|playground / Tests" } }) });
  const h = box.innerHTML;
  assert.equal(sst.sel, "ci|playground / Tests");
  assert.match(h, /red since 11-01, triage queued, next 02:00/);
  assert.match(h, /<b>Why it exists<\/b> the only full run/);
  assert.match(h, /<b>Inside<\/b> Plan -&gt; PlayMode 1..8/);
  assert.match(h, /<b>Before<\/b> cron 0 10/);
  assert.match(h, /<b>After<\/b> Sentinel playground-nightly \(pages urgent\); triage agent/);
  assert.match(h, /<b>Open triage<\/b> nightly-triage-1 \(queued\)/);
  assert.match(h, /PlayMode 2, PlayMode 8/);
  assert.match(h, /<summary class="muted">\+2 older<\/summary>/);
  assert.equal((h.match(/Open run/g) || []).length, 4);
  on.click({ target: target({}, { dataset: { key: "ci|playground / Tests" } }) });
  assert.equal(sst.sel, null, "a second click closes it");
});

test("a row with no purpose says so in its detail", () => {
  show();
  on.click({ target: target({}, { dataset: { key: "timer|journal-sync" } }) });
  assert.match(box.innerHTML, /<span class="warn">no purpose written/);
});

test("an agentctl row goes to its runner's Fleet page and copies nothing", () => {
  show();
  loc.hash = "";
  on.click({ target: target({}, { dataset: { key: "agentctl|dream" } }) });
  assert.equal(loc.hash, "fleet/dream");
  assert.equal(sst.sel, null);
});

test("a header click, a chip and a query go to the server as view keys", async () => {
  show();
  run("st.views.schedules = ''");
  body = data;
  asked.length = 0;
  on.click({ type: "click", target: target({ tsort: "streak", tdir: "asc" }) });
  await new Promise((r) => setImmediate(r));
  assert.match(asked.at(-1), /^\/api\/schedules\?sort=streak&dir=asc$/);
  on.click({ type: "click", target: target({ ts: "red" }) });
  await new Promise((r) => setImmediate(r));
  assert.match(asked.at(-1), /s=red/);
  assert.match(run("st.views.schedules"), /s=red/, "the URL keeps the view, so it is a link");
});

test("a repaint leaves the search box in use and a failed read says why", () => {
  show();
  parts["sched-body"].innerHTML = "";
  doc.activeElement = { id: "sched-q", dataset: {} };
  box.innerHTML = "untouched";
  run("renderSchedules()");
  assert.equal(box.innerHTML, "untouched");
  assert.match(parts["sched-body"].innerHTML, /playground \/ Tests/);
  doc.activeElement = null;
  Object.assign(sst, { data: { rows: [], errors: ["schedules: gone"] }, err: null });
  run("renderSchedules()");
  assert.match(box.innerHTML, /schedules: gone/);
});
