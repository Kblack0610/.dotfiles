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
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ||= []).push(f); } });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const parts = { "sched-head": part(), "sched-facets": part(), "sched-tiles": part(), "sched-body": part() };
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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "jobs.js", "schedules.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const schst = run("schst");

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = {
  q: "", state: "failing", sort: "", dir: "", total: 3, shown: 2,
  states: [{ name: "all", n: 3 }, { name: "failing", n: 2 }, { name: "stale", n: 0 }, { name: "never", n: 0 }, { name: "off", n: 0 }, { name: "ok", n: 1 }, { name: "no-purpose", n: 1 }],
  columns: ["kind", "name", "state", "schedule", "next", "last", "took", "passed", "failed", "streak", "triage", "result", "repo"].map(col),
  facets: [{ key: "kind", on: [], clear: "", values: [{ value: "ci", n: 2, on: false, q: "kind:ci" }] }],
};
const row = (kind, name, o = {}) => ({ kind, name, state: "failing", state_level: "bad", state_why: "", repo: "", schedule: "02:00 daily", purpose: "", last: 1793942659, result: "failure", ok: false, streak: -6, streak_word: "red 6", red_since: 1793442659, ok_at: null, fail_at: 1793942659, took: 2520, every: 86400, triage: "-", next: null, inside: "", before: "", after: [], open: [], runs: [], page: "", status: "", ...o });
const run1 = (n) => ({ at: 1793942659 - n, result: "failure", ok: false, failed: ["PlayMode 2", "PlayMode 8"], url: `https://ci/${n}`, took: 2520 });
const nightly = row("ci", "playground / Tests", {
  purpose: "the only full run of every class on main", triage: "queued nightly-triage-1", status: "failing since 11-01, triage queued, next 02:00",
  inside: "Plan -> PlayMode 1..8", before: "cron 0 10 * * * UTC", after: ["Sentinel playground-nightly (pages urgent)", "triage agent playground-nightly-fix"], open: ["nightly-triage-1 (queued)"],
  runs: [run1(0), run1(1), run1(2), run1(3)],
});
const data = { at: 1793942700, summary: "4 scheduled: 2 failing, 0 stale, 0 never ran, 1 off, 1 no purpose, CI read 7m ago", errors: [], table,
  rows: [nightly, row("timer", "journal-sync"),
    row("agentctl", "dream", { page: "dream", purpose: "nightly memory", result: "WORKED", ok: true, streak: 9, streak_word: "green 9", state: "ok", state_level: "ok", ok_at: 1793942659, fail_at: null }),
    row("agentctl", "old-sweep", { page: "old-sweep", purpose: "retired", state: "off", state_level: "ok", streak: 0, streak_word: "", last: null, fail_at: null, took: null })] };

const target = (attrs, tr = null) => ({ dataset: attrs, closest: (sel) => (sel === "tr.jr" ? tr : (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) ? { dataset: attrs } : null) });
const show = () => { run("st.tab = 'schedules'"); Object.assign(schst, { data, err: null, sel: null }); run("schst.render()"); };

test("the table draws its head, the mock's columns and a missing purpose", () => {
  show();
  const h = box.innerHTML;
  assert.match(h, /<h2 class="sec">Schedules <span class="n">\d+(?: of \d+)?<\/span><\/h2>/, "the head is its title and the view's count");
  assert.doesNotMatch(h, /CI read 7m ago/, "no summary sentence after the title");
  // When the schedules were read is a tile after the state tiles (the Schedules tblTab's tiles).
  assert.match(run("schedulesTiles")(data), /<span class="tl">READ<\/span><span class="tv">\d\d:\d\d<\/span>/);
  for (const c of ["kind", "name", "state", "schedule", "next", "last", "took", "passed", "failed", "streak", "triage"]) assert.match(h, new RegExp(`data-tsort="${c}"`));
  for (const c of ["result", "repo"]) assert.doesNotMatch(h, new RegExp(`data-tsort="${c}"`), `${c} sorts and filters without a column`);
  assert.match(h, /<td class="bad" title="[^"]*">failing<\/td>/, "a failing row says so in red");
  assert.match(h, /<td class="muted" title="">off<\/td>/, "a runner turned off reads off, plain");
  assert.match(h, /<td class="n">42m<\/td>/, "how long the last run took");
  assert.match(h, /<td class="bad">red 6<\/td>/);
  assert.match(h, /<td class="">green 9<\/td>/);
  assert.match(h, /journal-sync <span class="warn"[^>]*>no purpose<\/span>/, "a missing purpose is amber");
  assert.match(h, /queued nightly-triage-1/);
  assert.match(h, /<button class="tile on[^"]*" data-ts=""[^>]*><span class="tl">FAILING<\/span><span class="tv">2<\/span><\/button>/);
  assert.match(h, /id="sched-q"/);
});

test("next shows the time of a start today, the day too for a later one, and a dash for none", () => {
  const at = (ms) => run(`nextStart(${Math.round(ms / 1e3)})`);
  const hm = (d) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  const soon = new Date(); soon.setHours(23, 59, 0, 0);
  assert.equal(at(soon.getTime()), hm(soon));
  const later = new Date(soon.getTime() + 3 * 86400e3);
  assert.match(at(later.getTime()), /^\d\d-\d\d \d\d:\d\d$/);
  assert.equal(run("nextStart(null)"), "-");
});

test("a row opens its detail and folds runs past the second", () => {
  show();
  fire("click", { target: target({}, { dataset: { key: "ci|playground / Tests" } }) });
  const h = box.innerHTML;
  assert.equal(schst.sel, "ci|playground / Tests");
  assert.match(h, /failing since 11-01, triage queued, next 02:00/);
  assert.match(h, /<b>Why it exists<\/b> the only full run/);
  assert.match(h, /<b>Inside<\/b> Plan -&gt; PlayMode 1..8/);
  assert.match(h, /<b>Before<\/b> cron 0 10/);
  assert.match(h, /<b>After<\/b> Sentinel playground-nightly \(pages urgent\); triage agent/);
  assert.match(h, /<b>Open triage<\/b> nightly-triage-1 \(queued\)/);
  assert.match(h, /PlayMode 2, PlayMode 8/);
  assert.match(h, /<span class="muted">in 42m<\/span>/, "each run says how long it took");
  assert.match(h, /<summary class="muted">\+2 older<\/summary>/);
  assert.equal((h.match(/Open run/g) || []).length, 4);
  fire("click", { target: target({}, { dataset: { key: "ci|playground / Tests" } }) });
  assert.equal(schst.sel, null, "a second click closes it");
});

test("a row with no purpose says so in its detail", () => {
  show();
  fire("click", { target: target({}, { dataset: { key: "timer|journal-sync" } }) });
  assert.match(box.innerHTML, /<span class="warn">no purpose written/);
});

test("an agentctl row goes to its runner's Fleet page and copies nothing", () => {
  show();
  loc.hash = "";
  fire("click", { target: target({}, { dataset: { key: "agentctl|dream" } }) });
  assert.equal(loc.hash, "fleet/dream");
  assert.equal(schst.sel, null);
});

test("a header click, a chip and a query go to the server as view keys", async () => {
  show();
  run("st.views.schedules = ''");
  body = data;
  asked.length = 0;
  fire("click", { type: "click", target: target({ tsort: "streak", tdir: "asc" }) });
  await new Promise((r) => setImmediate(r));
  assert.match(asked.at(-1), /^\/api\/schedules\?sort=streak&dir=asc$/);
  fire("click", { type: "click", target: target({ ts: "failing" }) });
  await new Promise((r) => setImmediate(r));
  assert.match(asked.at(-1), /s=failing/);
  assert.match(run("st.views.schedules"), /s=failing/, "the URL keeps the view, so it is a link");
});

test("a repaint leaves the search box in use and a failed read says why", () => {
  show();
  parts["sched-body"].innerHTML = "";
  doc.activeElement = { id: "sched-q", dataset: {} };
  box.innerHTML = "untouched";
  run("schst.render()");
  assert.equal(box.innerHTML, "untouched");
  assert.match(parts["sched-body"].innerHTML, /playground \/ Tests/);
  doc.activeElement = null;
  Object.assign(schst, { data: { rows: [], errors: ["schedules: gone"] }, err: null });
  run("schst.render()");
  assert.match(box.innerHTML, /schedules: gone/);
});

test("a past time reads as HH:MM today, its weekday this week, and MM-DD past that", () => {
  const now = Date.now() / 1e3;
  assert.match(run(`when(${now})`), /^\d\d:\d\d$/);
  assert.match(run(`when(${now - 3 * 86400})`), /^[A-Z][a-z]{2} \d\d:\d\d$/);
  assert.match(run(`when(${now - 40 * 86400})`), /^\d\d-\d\d \d\d:\d\d$/, "a weekday would name the wrong week");
});
