// Unit tests for Sessions' Runners inner tab (.local/src/agent-web/static/fleet.js), the table of
// agentctl runners and each runner's page, run by `node --test` from tests/unit/agent_web_queue.bats.
// The page's real scripts load into one vm context, as the browser loads them; only the DOM is a
// stub. The registry itself is hub_core::fleet, tested in Rust; this checks what a row draws, where
// it opens, and that the retired `#fleet` links land here.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
// Sessions' #scroll holds the three inner tabs; every click handler on it hears a click, as in
// the browser. `box` is the Runners inner tab's own block (#ov-runners).
const scrollClicks = [];
const scroll = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], addEventListener: (ev, f) => { if (ev === "click") scrollClicks.push(f); } });
const click = (e) => { for (const f of scrollClicks) f(e); };
const box = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], addEventListener() {} });
let logClick = null;
const logBox = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], addEventListener: (ev, f) => { if (ev === "click") logClick = f; } });
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const parts = { "runners-body": part(), "runners-tiles": part(), "runners-facets": part(), "runners-head": part() };
const doc = { getElementById: (id) => (id === "ov-runners" ? box : id === "scroll" ? scroll : id === "log-verdicts" ? logBox : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el() };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  matchMedia: () => ({ matches: false, addEventListener() {} }),
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: { pathname: "/", hash: "" },
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({}) }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "board.js", "jobs.js", "watch.js", "shepherd.js", "sessions.js", "fleet.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const call = (id, o = {}) => ({ id, at: 1793942659, ms: 3222, ok: true, model: "claude-sonnet-5-5", cost: 0.0871, tokens: 30457, link: `https://lf/project/P/sessions/${id}`, ...o });
const worker = (name, registry) => ({
  name, lane: "observe", description: "", schedule: "", enabled: true, state: "idle", running_since: null, usual_s: null, overdue: false, last: null,
  runs_24h: 0, failed_24h: 0, why: null, next: null, score: null, detail: "",
  registry: {
    kind: "call", trigger: "called by its caller", role: "distill", role_desc: "reads and returns data",
    caps: "write no, task no, bash no, mcp none", model: "claude-sonnet-5-5", effect: "acts",
    prompt: "/home/k/.config/agent-ask/policy.md",
    calls: { n_24h: 14, errors_24h: 1, cost_24h: 0.12, tokens_24h: 864905, p95_ms: 7100, prompt_sha: "3fa1c2d", recent: [call("s1"), call("s2", { ok: false, link: "" })] },
    eval: null,
    ...registry,
  },
});
const judge = { agree: 0, disagree: 0, deferred: 0, pending: 0, unscored: 0, precision: null, kappa: null, prompt: "3fa1c2d",
  week: { live_pct: 25, coverage: 40, precision: 91 },
  verdicts: [
    { id: "a", project: "ucp", question: "land it?", type: "ship_deploy", rule: "ship_deploy", said: "answered", judge: "a", reason: "merged, not live", evidence: "merged", you: "kept", score: "right", at: 1793942659 },
    { id: "b", project: "trader", question: "which login?", type: "human_fact", rule: "knowledge", said: "passed", judge: "", reason: "only you know", evidence: "your login", you: "pending", score: "pending", at: 1793942600 },
    { id: "c", project: "ucp", question: "quarantine it?", type: "ci_capacity_ops", rule: "ci_capacity_ops", said: "would answer", judge: "a", reason: "rule says so", evidence: "", you: "b", score: "wrong", at: 1793942500 },
  ],
  cells: [
    { type: "ship_deploy", level: "repo", verdicts: 4, scored: 3, pending: 1, precision: 66.7, precision_lo: 20.8, precision_hi: 93.9, live: true, audited: 3, level_raised_pct: 25 },
    { type: "", level: "", verdicts: 2, scored: 0, pending: 2, precision: null, precision_lo: null, precision_hi: null, live: false, audited: 0, level_raised_pct: 0 },
  ] };
const data = {
  at: 1793942659, errors: [], judge,
  dispatch: { counts_24h: {}, counts_7d: {}, log_24h: {}, recent: [], partial: false },
  workers: [
    worker("ask-judge", {
      eval: {
        prompt_sha: "3fa1c2d", live: ["ship_deploy"], total: {},
        rules: [
          { rule: "ship_deploy", verdicts: 9, errors: 0, scored: 6, precision: 100, false_defer_pct: null, live: true, bar: { labels: 6, need: 30, met: false } },
          { rule: "taste", verdicts: 31, errors: 0, scored: 28, precision: null, false_defer_pct: 18, live: false, bar: { labels: 6, need: 30, met: false } },
        ],
      },
    }),
    worker("dream", { kind: "oneshot", trigger: "*-*-* 03:00:00", calls: { n_24h: 0, errors_24h: 0, cost_24h: null, tokens_24h: 0, p95_ms: null, prompt_sha: "", recent: [] } }),
  ],
};


test("Log lists every answer verdict with why and what you did, and a filter narrows it", () => {
  vm.runInContext("fst", ctx).data = data;
  ctx.renderLogVerdicts();
  assert.match(logBox.innerHTML, /7d: 25% answered, 40% would answer, 91% right/);
  assert.match(logBox.innerHTML, /<b>knowledge<\/b> "your login" only you know/);
  assert.match(logBox.innerHTML, /<td>ship_deploy<\/td>/);
  assert.match(logBox.innerHTML, /class="cchip bad">b</);
  const pick = (said) => logClick({ target: { closest: (sel) => (sel === "[data-said]" ? { dataset: { said } } : null) } });
  pick("passed");
  assert.match(logBox.innerHTML, /which login/);
  assert.doesNotMatch(logBox.innerHTML, /land it/);
  pick("wrong");
  assert.match(logBox.innerHTML, /quarantine it/);
  assert.doesNotMatch(logBox.innerHTML, /which login/);
  pick("all");
});



// The table: hub_core::fleet::who's rows, and the Summary hub_core::table sends beside them.
const st = vm.runInContext("st", ctx);
// The Runners inner tab shown, its table and no runner page.
const onRunners = () => { st.tab = "sessions"; st.arg = "runners"; st.page = ""; st.sel = null; };
const wrow = (o) => ({ tier: 2, kind: "observe", who: "ask-judge", state: "idle", since: 1793942000, for: "Answers asks it can", doing: "next 14:00", under: "called by dream", ...o });
const COLS = ["kind", "who", "state", "cost", "since", "for", "doing", "under"];
const table = (o = {}) => ({
  q: "", state: "", sort: "", dir: "desc", total: 3, shown: 3,
  states: [{ name: "all", n: 3 }, { name: "lead", n: 1 }, { name: "observe", n: 2 }, { name: "failed", n: 1 }],
  columns: COLS.map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })),
  facets: [{ key: "kind", on: [], clear: "", values: [{ value: "lead", n: 1, on: false, q: "kind:lead" }] }],
  ...o,
});
const people = [
  wrow({ tier: 1, kind: "lead", who: "fleet-dispatch", for: "Starts a one-shot session per small agent row", under: "2 sessions" }),
  wrow({ state: "failed", cost_24h: 4.5, doing: "no gateway route (2 failed 24h)" }),
  wrow({ who: "inbox-triage", for: "files the inbox", under: "" }),
];
// What hub_core::links sends beside those rows (`Who::link`); the page builds no `#...` itself.
const links = [
  { who: "#sessions/runners/fleet-dispatch" },
  { who: "#sessions/runners/ask-judge" },
  { who: "#sessions/runners/inbox-triage" },
];
const fleetData = { ...data, who: people, legend: ["lead runs or watches the sessions", "observe reports"], table: table({ links }), hidden: 0 };

test("a runner row opens its page on Sessions' Runners, and a lead counts the sessions it oversees", () => {
  onRunners();
  const f = vm.runInContext("fst", ctx);
  f.data = fleetData;
  ctx.renderRunners();
  const h = box.innerHTML;
  assert.match(h, /<tr class="wr" data-href="#sessions\/runners\/fleet-dispatch"><td class="muted">lead<\/td>/);
  assert.match(h, /<a class="tl" href="#sessions\/runners\/ask-judge">ask-judge<\/a>/);
  assert.match(h, /<td class="bad">failed<\/td>/);
  assert.match(h, /<td class="wrap muted">2 sessions<\/td>/);
  assert.doesNotMatch(h, /data-fold|#sessions\/lab/, "no fold and no session rows: the sessions are the Sessions inner tab's");
  // A row the server sent no link for draws its text and opens nothing.
  f.data = { ...fleetData, table: table() };
  ctx.renderRunners();
  assert.match(box.innerHTML, /<tr class="wr" data-href=""><td class="muted">lead<\/td><td>fleet-dispatch<\/td>/);
});

test("the Runners table is drawn only while its inner tab shows", () => {
  const f = vm.runInContext("fst", ctx);
  f.data = fleetData;
  box.innerHTML = "";
  st.tab = "sessions"; st.arg = "sessions"; st.page = ""; st.sel = null;
  ctx.renderRunners();
  assert.equal(box.innerHTML, "", "the Sessions inner tab shows");
  onRunners();
  st.sel = { target: "a" };
  ctx.renderRunners();
  assert.equal(box.innerHTML, "", "a session's record is open");
  onRunners();
  ctx.renderRunners();
  assert.match(box.innerHTML, /fleet-dispatch/, "the control: Runners shows");
});

test("a held runner reads red and the held chip counts it", () => {
  onRunners();
  const held = wrow({ state: "held", doing: "budget: over its daily budget: $5.03 of $5" });
  vm.runInContext("fst", ctx).data = { ...fleetData, who: [held], table: table({ states: [{ name: "all", n: 1 }, { name: "held", n: 1 }] }) };
  ctx.renderRunners();
  const h = box.innerHTML;
  assert.match(h, /<td class="bad">held<\/td>/);
  assert.match(h, /data-ts="held"><span class="tl">HELD<\/span><span class="tv">1</);
});

test("the header draws every hub-core column and the bar is the shared one, under the r prefix", () => {
  onRunners();
  vm.runInContext("fst", ctx).data = fleetData;
  ctx.renderRunners();
  const h = box.innerHTML;
  assert.equal((h.match(/data-tsort=/g) || []).length, COLS.length);
  assert.match(h, /who spent what on <a href="#costs">Costs<\/a>/);
  assert.match(h, /id="runners-q" data-tsearch/);
  assert.match(h, /<tr class="tfilters" data-phone="filters"><th><details class="tfacet" data-fkey="kind"[^>]*>/, "kind's dropdown sits under its header");
  assert.match(h, /data-fv="lead" value="kind:lead"> <span>lead<\/span> <span class="n">1<\/span>/);
});

test("KIND and FOR say what each row is and why it is deployed, under the lanes.tsv legend", () => {
  onRunners();
  vm.runInContext("fst", ctx).data = fleetData;
  doc.activeElement = null;
  ctx.renderRunners();
  const h = box.innerHTML;
  assert.match(h, /<div class="muted legend">lead runs or watches the sessions \| observe reports<\/div>/);
  assert.match(h, /<td class="muted">observe<\/td><td><a class="tl" href="#sessions\/runners\/ask-judge">ask-judge<\/a>/);
  assert.match(h, /<td class="wrap">Starts a one-shot session per small agent row<\/td>/);
  assert.match(h, /<td class="wrap">no gateway route \(2 failed 24h\)<\/td>/);
  for (const k of ["lead", "observe"]) assert.match(h, new RegExp(`data-ts="${k}"><span class="tl">${k.toUpperCase()}</span><span class="tv">`));
  vm.runInContext("fst", ctx).data = { ...fleetData, legend: [] };
  ctx.renderRunners();
  assert.match(box.innerHTML, /<div class="muted legend">-<\/div>/, "no lanes.tsv reads as -");
});

test("a click on a runner row sets the hash; a link, or a row outside Runners, does not", () => {
  onRunners();
  vm.runInContext("fst", ctx).data = fleetData;
  ctx.renderRunners();
  const target = (hits, inRunners = true) => ({ closest: (sel) => (sel === "#ov-runners" ? (inRunners ? box : null) : hits[sel] || null), dataset: {} });
  click({ target: target({ "tr.wr": { dataset: { href: "#sessions/runners/x" } } }) });
  assert.equal(ctx.location.hash, "#sessions/runners/x");
  ctx.location.hash = "";
  click({ target: target({ "a, button, select, input": {}, "tr.wr": { dataset: { href: "#sessions/runners/y" } } }) });
  assert.equal(ctx.location.hash, "", "a link is the browser's");
  click({ target: target({ "tr.wr": { dataset: { href: "#sessions/runners/z" } } }, false) });
  assert.equal(ctx.location.hash, "", "another inner tab's row is its own");
});

test("typing repaints the rows and leaves the search box in place", () => {
  onRunners();
  const f = vm.runInContext("fst", ctx);
  f.data = fleetData;
  ctx.fetch = async () => answer(fleetData);
  ctx.renderRunners();
  const before = box.innerHTML;
  doc.activeElement = { id: "runners-q" };
  ctx.renderRunners();
  assert.equal(box.innerHTML, before, "the page around the box is not rebuilt");
  assert.match(parts["runners-body"].innerHTML, /inbox-triage/);
  doc.activeElement = null;
});

test("the tab is the one table: the accounts, tokens and Langfuse are Costs'", () => {
  onRunners();
  const f = vm.runInContext("fst", ctx);
  f.data = { ...fleetData, tokens: { date: "2026-11-05" } };
  doc.activeElement = null;
  ctx.renderRunners();
  assert.match(box.innerHTML, /inbox-triage/, "the control: the table drew");
  for (const id of ["sec-accounts", "sec-tokens", "sec-langfuse"]) assert.doesNotMatch(box.innerHTML, new RegExp(`id="${id}"`));
  assert.doesNotMatch(box.innerHTML, /Claude accounts|Where the tokens go|What Langfuse sees/);
});

test("a search with no hit says so, and an unconfigured fleet says where runners are", () => {
  onRunners();
  const f = vm.runInContext("fst", ctx);
  f.data = { ...fleetData, who: [], table: table({ total: 3, shown: 0 }) };
  ctx.renderRunners();
  assert.match(box.innerHTML, /No runner matches\./);
  f.data = { ...fleetData, who: [], table: table({ total: 0, shown: 0 }) };
  ctx.renderRunners();
  assert.match(box.innerHTML, /No runner configured in ~\/\.config\/agentctl\/agents\./);
  f.data = fleetData;
});

// The retired Fleet tab's links (hub_core::layout RETIRED and MOVED, links::RETIRED_TAB_PAGES).
test("#fleet lands on Sessions' Runners, and #fleet/<runner> on that runner's page", () => {
  const r = (h) => JSON.parse(vm.runInContext(`JSON.stringify(route(${JSON.stringify(h)}))`, ctx));
  const bare = r("#fleet");
  assert.deepEqual([bare.tab, bare.arg, bare.page], ["sessions", "runners", undefined]);
  const page = r("#fleet/inbox-triage");
  assert.deepEqual([page.tab, page.arg, page.page], ["sessions", "runners", "runners/inbox-triage"]);
  assert.equal(r("#fleet/a%20b").page, "runners/a b", "the name is decoded once");
  assert.deepEqual(r("#sessions/runners/inbox-triage"), { ...page, name: "sessions" }, "the alias is the new link");
  // The old view keys move under the Runners table's prefix; a key that is not a table's stays.
  const view = new URLSearchParams(r("#fleet?s=failed&q=kind:lead&x=1").query);
  assert.deepEqual([view.get("rs"), view.get("rq"), view.get("s"), view.get("q"), view.get("x")], ["failed", "kind:lead", null, null, "1"]);
  // A Fleet section that moved before keeps its MOVED target.
  assert.deepEqual([r("#fleet/tokens").tab, r("#fleet/tokens").section], ["costs", "tokens"]);
  assert.deepEqual([r("#fleet/workers").tab, r("#fleet/workers").arg], ["sessions", "runners"]);
  // Negative control: a Sessions arg that is no inner tab is still a session's id.
  assert.deepEqual([r("#sessions/lab%2Fdotfiles-agent-11%3A1").arg, r("#sessions/lab%2Fdotfiles-agent-11%3A1").page], ["lab/dotfiles-agent-11:1", undefined]);
});

// The runner page, `#sessions/runners/<name>`: hub_core::fleet::runner's JSON, fetched only when it opens.
const totals = (o) => ({ calls: 0, errors: 0, tokens: 0, cost: null, p50_ms: null, ...o });
const runnerPage = (name, o = {}) => ({
  at: 1793942659, name, errors: [], lane: "observe", description: "files the inbox", enabled: true, state: "idle", running_since: null,
  next: 1793946000, registry: worker(name, { kind: "persistent", trigger: "always on" }).registry,
  conf: [{ key: "KIND", value: "persistent" }, { key: "DETAIL", value: "ingest" }, { key: "API_TOKEN", value: "(set)" }],
  status: { state: "idle", detail: "3 filed; retry 14:20", next: "1793946000", updated: "1793942000" },
  activity: [{ word: "WORKED", ok: true, at: 1793942000, text: "3 filed" }],
  runs: [
    { source: "agentctl", name, state: "done", ok: false, result: "FAILED", started: 1793941000, finished: 1793941060, secs: 60, detail: "inv 1a2b3c4d", runs: 1,
      log: { kind: "runner", invocation: "1a2b3c4d", out: [0, 120], err: [0, 0] } },
    { source: "agentctl", name, state: "done", ok: true, result: "WORKED", started: 1793930000, finished: 1793930030, secs: 30, detail: "inv 9f8e7d6c", runs: 1 },
  ],
  runs_total: 2, failed_total: 1,
  days: Array.from({ length: 14 }, (_, i) => ({ day: `11-${String(i + 1).padStart(2, "0")}`, runs: i === 13 ? 2 : 0, failed: i === 13 ? 1 : 0 })),
  calls: { day: totals({ calls: 4, errors: 1, tokens: 12000, cost: 0.42, p50_ms: 2100 }), week: totals({ calls: 30, tokens: 90000, cost: 3.1, p50_ms: 2400 }), partial: true, recent: [call("s9")] },
  extras: { kind: "ingest", counts_7d: { filed: 5, routed: 2 }, partial: false, steps: [{ ts: "2026-11-06T10:00:00Z", action: "filed", from: "inbox", to: "board", lane: "", text: "fix the thing", id: "ar-9", why: "model: names the hub", row: "fix the thing on the hub", by: "inbox-triage" }] },
  ...o,
});
const answer = (body, status = 200) => ({ ok: status < 400, status, statusText: "", headers: { get: () => (status < 400 ? "application/json" : "text/plain") }, json: async () => body, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) });
const flush = () => new Promise((r) => setImmediate(r));
let asked = [];
const serve = (pages) => { asked = []; ctx.fetch = async (url) => { asked.push(url); const m = url.match(/^\/api\/fleet\/runner\?name=(.*)$/); if (m) { const p = pages[decodeURIComponent(m[1])]; return p ? answer(p) : answer(`no runner named ${decodeURIComponent(m[1])}`, 404); } if (url.startsWith("/api/jobs/log?ref=")) return answer("run log text"); return answer(url === "/api/fleet" ? fleetData : {}); }; };
const openPage = async (name, pages) => { serve(pages); ctx.setTab("sessions", "runners", "", "runners/" + name); await flush(); return box.innerHTML; };

test("the Runners table is read only on its inner tab, and a runner page only when opened", async () => {
  serve({});
  ctx.setTab("sessions", "sessions", "");
  await flush();
  assert.deepEqual(asked.filter((u) => u.startsWith("/api/fleet")), [], "the Sessions inner tab reads no runner");
  ctx.setTab("sessions", "runners", "");
  await flush();
  assert.deepEqual(asked.filter((u) => u.startsWith("/api/fleet")), ["/api/fleet"]);
  assert.match(box.innerHTML, /<a class="tl" href="#sessions\/runners\/ask-judge">ask-judge<\/a>/);
  assert.deepEqual(asked.filter((u) => u.includes("/runner")), [], "the table never reads a runner page");
});

test("a runner page draws its runs, status next, activity, 24h and 7d calls, extras and conf", async () => {
  const h = await openPage("inbox-triage", { "inbox-triage": runnerPage("inbox-triage") });
  assert.deepEqual(asked.filter((u) => u.includes("/runner")), ["/api/fleet/runner?name=inbox-triage"]);
  assert.match(h, /<span class="tl">RUNS 14D<\/span><span class="tv">2<\/span><span class="ts1">1 failed<\/span>/);
  assert.match(h, /status: 3 filed; retry 14:20/);
  assert.match(h, /<td class="bad">FAILED<\/td>/);
  assert.match(h, /<td>7d<\/td><td class="n">30\+<\/td>/, "a partial week is a floor");
  assert.match(h, /<span class="tl">FILED<\/span><span class="tv">5<\/span>/);
  assert.match(h, /<td>filed <span class="muted">ar-9<\/span><\/td><td class="muted">inbox -&gt; board<\/td><td class="muted">inbox-triage<\/td>/, "an intake step names its id, route and writer");
  assert.match(h, /fix the thing<div class="muted">=&gt; fix the thing on the hub<\/div><\/td><td class="wrap muted">model: names the hub<\/td>/, "and the row it became and why");
  assert.match(h, /<td>API_TOKEN<\/td><td class="wrap muted">\(set\)<\/td>/);
  assert.match(h, /href="#sessions\/runners">All runners<\/a>/);
  click({ target: { closest: (sel) => (sel === "#ov-runners" ? box : sel === "tr.rr" ? { dataset: { i: "0" } } : null), dataset: {} } });
  await flush();
  assert.match(box.innerHTML, /<pre class="panel joblog">run log text<\/pre>/);
  assert.ok(asked.some((u) => u.startsWith("/api/jobs/log?ref=") && decodeURIComponent(u).includes('"out":[0,120]')), "the log is the run's byte range");
});

test("the sentinel page is one count line linking to Alerts' Watches, never the watch table", async () => {
  const w = (name, state) => ({ name, state, severity: "normal", since: null, lastrun: null, lasttrip: null, place: "", what: "", action: "", evidence: "" });
  const h = await openPage("sentinel", { sentinel: runnerPage("sentinel", { extras: { kind: "sentinel-watches", watches: [w("a", "TRIP"), w("b", "OK"), w("c", "ERROR")] } }) });
  assert.match(h, /<h2 class="sec">Watches <span class="muted"><a href="#alerts\/watches">3 watches, 1 tripped<\/a><\/span><\/h2>/);
  assert.doesNotMatch(h, /<th>watch<\/th>/);
});

test("a runner with no runs says no run in 14 days, not an error", async () => {
  const h = await openPage("quiet", { quiet: runnerPage("quiet", { runs: [], runs_total: 0, failed_total: 0, days: [], status: {}, activity: [], extras: { kind: "none" } }) });
  assert.match(h, /<div class="empty">no run in 14 days<\/div>/);
  assert.doesNotMatch(h, /panel down/);
  assert.match(h, /No status file\./);
});

test("an unknown runner shows the server's words, and a judge page carries the moved judge section", async () => {
  const miss = await openPage("nope", {});
  assert.match(miss, /<div class="panel down">Could not read fleet \(HTTP 404\): no runner named nope/);
  const disp = { counts_24h: { dispatch: 2, skip: 5 }, counts_7d: { dispatch: 9, skip: 30 }, log_24h: { started: 2, reaped: 1 }, partial: false,
    recent: [{ ts: 1793942000, project: "dotfiles", key: "fix the thing", verdict: "dispatch", tier: 2, clear: true, reason: "clear and small" }] };
  const h = await openPage("dispatch-judge", { "dispatch-judge": runnerPage("dispatch-judge", { extras: { kind: "dispatch-verdicts", dispatch: disp } }) });
  assert.match(h, /<h2 class="sec">Dispatch judge /);
  assert.match(h, /<span class="tl">STARTED<\/span><span class="tv">2<\/span>/);
  assert.match(h, /clear and small/);
  const j = await openPage("ask-judge", { "ask-judge": runnerPage("ask-judge", { extras: { kind: "ask-judge", judge } }) });
  assert.match(j, /<h2 class="sec">Answer judge /);
  assert.match(j, /<span class="tl">AGREE<\/span>/);
  assert.match(j, /land it\?/);
  // One row per type and level, judge-eval's numbers, between the tiles and the verdict list.
  assert.match(j, /<td>ship_deploy<\/td><td>repo<\/td><td class="n">4<\/td><td class="n">3<\/td><td class="n">66.7% <span class="muted">\[20.8-93.9\]<\/span><\/td><td class="n">1<\/td><td class="">yes<\/td><td class="n">3<\/td><td class="n">25%<\/td>/);
  assert.match(j, /<td>\(no type\)<\/td><td>-<\/td>/);
  assert.ok(j.indexOf("AGREE") < j.indexOf("By type and level") && j.indexOf("By type and level") < j.indexOf("land it?"));
  const none = await openPage("ask-judge", { "ask-judge": runnerPage("ask-judge", { extras: { kind: "ask-judge", judge: { ...judge, cells: [] } } }) });
  assert.match(none, /no verdicts under prompt 3fa1c2d/);
  ctx.setTab("sessions", "runners", "");
});

test("a judge has no tile on the Runners table, and Log's verdict headers link to the runner whose DETAIL= draws it", () => {
  const fs = vm.runInContext("fst", ctx);
  // The links follow the confs: a renamed runner moves the link, no name is hard-coded.
  const judges = { ...fleetData, workers: [{ ...data.workers[0], detail: "ask-judge" }, { ...worker("dispatch-judge"), detail: "dispatch-verdicts" }] };
  onRunners();
  fs.data = judges;
  ctx.renderRunners();
  assert.doesNotMatch(box.innerHTML, /<div class="tile"/, "the judges' tiles moved to their pages");
  st.tab = "log";
  ctx.renderLogVerdicts();
  assert.match(logBox.innerHTML, /<a href="#sessions\/runners\/dispatch-judge">Dispatch judge<\/a>/);
  assert.match(logBox.innerHTML, /<a href="#sessions\/runners\/ask-judge">Answer judge<\/a>/);
  // Negative control: no conf names the block, so the header is plain, not a dead link.
  fs.data = fleetData;
  ctx.renderLogVerdicts();
  assert.match(logBox.innerHTML, /<h3 class="sub">Dispatch judge <span/);
  onRunners();
});

test("COST 24H is a runner's dollars linking to Costs, and none is a dash, never $0", () => {
  onRunners();
  vm.runInContext("fst", ctx).data = fleetData;
  ctx.renderRunners();
  const h = box.innerHTML;
  assert.match(h, />cost 24h<\/button><\/th>/);
  assert.match(h, /<td class="bad">failed<\/td><td class="n"><a href="#costs">\$4\.50<\/a><\/td>/);
  assert.match(h, /<td class="muted">idle<\/td><td class="n">-<\/td>/, "a runner with no spend reads -");
  vm.runInContext("fst", ctx).data = { ...fleetData, who: fleetData.who.map((r) => ({ ...r, cost_estimated: r.cost_24h != null })) };
  ctx.renderRunners();
  assert.match(box.innerHTML, /<a href="#costs">~\$4\.50<\/a>/, "an estimated figure is marked on the screen");
  assert.doesNotMatch(h, /\$0\.00/);
});
