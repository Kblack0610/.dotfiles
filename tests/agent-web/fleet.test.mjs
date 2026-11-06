// Unit tests for the Fleet tab's one table of who is working (.local/src/agent-web/static/fleet.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context, as the browser loads them; only the DOM is a stub. The registry itself is
// hub_core::fleet, tested in Rust; this checks what a row draws and where it opens.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
let click = null;
const on = {};
const box = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], addEventListener: (ev, f) => { on[ev] = f; if (ev === "click") click = f; } });
let logClick = null;
const logBox = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], addEventListener: (ev, f) => { if (ev === "click") logClick = f; } });
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const parts = { "fleet-body": part(), "fleet-chips": part(), "fleet-facets": part(), "fleet-head": part(), "fleet-tail": part() };
const doc = { getElementById: (id) => (id === "fleet" ? box : id === "log-verdicts" ? logBox : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el() };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: { pathname: "/", hash: "" },
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({}) }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "actions.js", "board.js", "table.js", "jobs.js", "fleet.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const call = (id, o = {}) => ({ id, at: 1793942659, ms: 3222, ok: true, model: "claude-sonnet-5-5", cost: 0.0871, tokens: 30457, link: `https://lf/project/P/sessions/${id}`, ...o });
const worker = (name, registry) => ({
  name, lane: "observe", description: "", schedule: "", enabled: true, state: "idle", running_since: null, usual_s: null, overdue: false, last: null,
  runs_24h: 0, failed_24h: 0, why: null, next: null, cost_24h: null, score: null, detail: "",
  registry: {
    kind: "call", trigger: "called by its caller", role: "distill", role_desc: "reads and returns data",
    caps: "write no, task no, bash no, mcp none", model: "claude-sonnet-5-5", effect: "acts",
    prompt: "/home/k/.config/agent-ask/policy.md",
    calls: { n_24h: 14, errors_24h: 1, cost_24h: 0.12, tokens_24h: 864905, p95_ms: 7100, prompt_sha: "3fa1c2d", recent: [call("s1"), call("s2", { ok: false, link: "" })] },
    eval: null,
    ...registry,
  },
});
const judge = { agree: 0, disagree: 0, deferred: 0, false_defer: 0, pending: 0, unscored: 0, precision: null, kappa: null, prompt: "3fa1c2d",
  week: { live_pct: 25, coverage: 40, precision: 91 },
  verdicts: [
    { id: "a", project: "ucp", question: "land it?", type: "ship_deploy", rule: "ship_deploy", said: "answered", judge: "a", reason: "merged, not live", evidence: "merged", you: "kept", score: "right", at: 1793942659 },
    { id: "b", project: "trader", question: "which login?", type: "human_fact", rule: "knowledge", said: "passed", judge: "", reason: "only you know", evidence: "your login", you: "pending", score: "pending", at: 1793942600 },
    { id: "c", project: "ucp", question: "quarantine it?", type: "ci_capacity_ops", rule: "ci_capacity_ops", said: "would answer", judge: "a", reason: "rule says so", evidence: "", you: "b", score: "wrong", at: 1793942500 },
  ] };
const data = {
  at: 1793942659, errors: [], accounts: [], cost_24h: 1, judge,
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
const wrow = (o) => ({ tier: 3, who: "dotfiles-agent-11", opens: "session", key: "lab/dotfiles-agent-11:1", state: "working", since: 1793942000, doing: "editing fleet.js", under: "dispatch dotfiles", cost: 1.5, project: "dotfiles", parent: "fleet-dispatch", kids: 0, ...o });
const COLS = ["tier", "who", "state", "since", "doing", "under", "cost", "project"];
const table = (o = {}) => ({
  q: "", state: "", sort: "", dir: "desc", total: 4, shown: 4,
  states: [{ name: "all", n: 4 }, { name: "failed", n: 1 }, { name: "working", n: 2 }],
  columns: COLS.map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })),
  facets: [{ key: "tier", on: null, clear: "", values: [{ value: "1", n: 1, q: "tier:1" }] }],
  ...o,
});
const people = [
  wrow({ tier: 1, who: "fleet-dispatch", opens: "runner", key: "fleet-dispatch", state: "idle", doing: "next 14:00", under: "2 sessions", parent: null, kids: 2, cost: 0.2 }),
  wrow({ tier: 2, who: "ask-judge", opens: "runner", key: "ask-judge", state: "failed", doing: "no gateway route", under: "called by dream", parent: null, cost: null, project: "observe" }),
  wrow({}),
  wrow({ who: "dotfiles-agent-12", key: "lab/dotfiles-agent-12:1", state: "needs you" }),
];
const fleetData = { ...data, who: people, table: table(), hidden: 0 };

test("a tier 1 row carries a fold button and a count, a tier 3 row opens the Sessions record, a runner its page", () => {
  vm.runInContext("st", ctx).tab = "fleet";
  const f = vm.runInContext("fst", ctx);
  f.data = fleetData;
  ctx.renderFleet();
  const h = box.innerHTML;
  assert.match(h, /<tr class="wr" data-href="#fleet\/fleet-dispatch"><td class="n"><button class="thsort" data-fold="fleet-dispatch" aria-expanded="true"[^>]*>v<\/button> 1<\/td>/);
  assert.match(h, /<a href="#fleet\/ask-judge">ask-judge<\/a>/);
  assert.match(h, /<tr class="wr" data-href="#sessions\/lab%2Fdotfiles-agent-11%3A1">/);
  assert.match(h, /<td class="bad">failed<\/td>/);
  assert.match(h, /<td class="warn">needs you<\/td>/);
  assert.doesNotMatch(h, /data-fold="ask-judge"/, "only a row with children folds");
  assert.match(h, /2 sessions/);
});

test("the header draws every hub-core column and the bar is the shared one", () => {
  vm.runInContext("fst", ctx).data = fleetData;
  ctx.renderFleet();
  const h = box.innerHTML;
  assert.equal((h.match(/data-tsort=/g) || []).length, COLS.length);
  assert.match(h, /id="fleet-q" data-tsearch/);
  assert.match(h, /<option value="tier:1">1 \(1\)<\/option>/);
});

test("a click on a row sets the hash, a click on a link or the fold button does not", () => {
  const f = vm.runInContext("fst", ctx);
  f.data = fleetData;
  ctx.renderFleet();
  const target = (hits) => ({ closest: (sel) => hits[sel] || null, dataset: {} });
  click({ target: target({ "tr.wr": { dataset: { href: "#sessions/x" } } }) });
  assert.equal(ctx.location.hash, "#sessions/x");
  ctx.location.hash = "";
  click({ target: target({ "a, button, select, input": {}, "tr.wr": { dataset: { href: "#sessions/y" } } }) });
  assert.equal(ctx.location.hash, "", "a link is the browser's");
});

test("the fold button folds and unfolds a tier 1 row and asks the server again", () => {
  const f = vm.runInContext("fst", ctx);
  f.data = fleetData;
  asked = [];
  ctx.fetch = async (url) => { asked.push(url); return answer(fleetData); };
  const fold = () => click({ target: { closest: (sel) => (sel === "[data-fold]" ? { dataset: { fold: "fleet-dispatch" } } : null), dataset: {} } });
  fold();
  assert.ok(f.fold.has("fleet-dispatch"));
  assert.ok(asked.some((u) => u.includes("fold=fleet-dispatch")), asked.join());
  fold();
  assert.ok(!f.fold.has("fleet-dispatch"));
});

test("typing repaints the rows and leaves the search box in place", () => {
  const f = vm.runInContext("fst", ctx);
  f.data = fleetData;
  ctx.fetch = async () => answer(fleetData);
  ctx.renderFleet();
  const before = box.innerHTML;
  doc.activeElement = { id: "fleet-q" };
  ctx.renderFleet();
  assert.equal(box.innerHTML, before, "the page around the box is not rebuilt");
  assert.match(parts["fleet-body"].innerHTML, /dotfiles-agent-12/);
  assert.match(parts["fleet-tail"].innerHTML, /Claude accounts/);
  doc.activeElement = null;
});

test("a search with no hit says so, and an unconfigured fleet says where runners are", () => {
  const f = vm.runInContext("fst", ctx);
  f.data = { ...fleetData, who: [], table: table({ total: 4, shown: 0 }) };
  ctx.renderFleet();
  assert.match(box.innerHTML, /No runner or session matches\./);
  f.data = { ...fleetData, who: [], table: table({ total: 0, shown: 0 }) };
  ctx.renderFleet();
  assert.match(box.innerHTML, /No runner configured in ~\/\.config\/agentctl\/agents\./);
  f.data = fleetData;
});

test("#sessions/<target> keeps the whole target, slash included", () => {
  assert.equal(ctx.route("#sessions/lab%2Fdotfiles-agent-11%3A1").arg, "lab/dotfiles-agent-11:1");
});

// The runner page, `#fleet/<name>`: hub_core::fleet::runner's JSON, fetched only when it opens.
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
  extras: { kind: "ingest", counts_7d: { filed: 5, routed: 2 }, partial: false, steps: [{ ts: "2026-11-06T10:00:00Z", action: "filed", from: "inbox", to: "board", lane: "", text: "fix the thing", id: null, why: null }] },
  ...o,
});
const answer = (body, status = 200) => ({ ok: status < 400, status, statusText: "", headers: { get: () => (status < 400 ? "application/json" : "text/plain") }, json: async () => body, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) });
const flush = () => new Promise((r) => setImmediate(r));
let asked = [];
const serve = (pages) => { asked = []; ctx.fetch = async (url) => { asked.push(url); const m = url.match(/^\/api\/fleet\/runner\?name=(.*)$/); if (m) { const p = pages[decodeURIComponent(m[1])]; return p ? answer(p) : answer(`no runner named ${decodeURIComponent(m[1])}`, 404); } if (url.startsWith("/api/jobs/log?ref=")) return answer("run log text"); return answer(url === "/api/fleet" ? data : {}); }; };
const openPage = async (name, pages) => { serve(pages); ctx.setTab("fleet", name, ""); await flush(); return box.innerHTML; };

test("a runner row links to its runner page, and the page is read only when opened", async () => {
  serve({});
  ctx.setTab("fleet", "", "");
  vm.runInContext("fst", ctx).data = fleetData;
  ctx.renderFleet();
  assert.match(box.innerHTML, /<a href="#fleet\/ask-judge">ask-judge<\/a>/);
  assert.deepEqual(asked.filter((u) => u.includes("/runner")), [], "the Fleet tab never reads a runner page");
  assert.equal(ctx.route("#fleet/inbox-triage").arg, "inbox-triage");
});

test("a runner page draws its runs, status next, activity, 24h and 7d calls, extras and conf", async () => {
  const h = await openPage("inbox-triage", { "inbox-triage": runnerPage("inbox-triage") });
  assert.deepEqual(asked.filter((u) => u.includes("/runner")), ["/api/fleet/runner?name=inbox-triage"]);
  assert.match(h, /<span class="tl">RUNS 14D<\/span><span class="tv">2<\/span><span class="ts1">1 failed<\/span>/);
  assert.match(h, /status: 3 filed; retry 14:20/);
  assert.match(h, /<td class="bad">FAILED<\/td>/);
  assert.match(h, /<td>7d<\/td><td class="n">30\+<\/td>/, "a partial week is a floor");
  assert.match(h, /<span class="tl">FILED<\/span><span class="tv">5<\/span>/);
  assert.match(h, /<td>API_TOKEN<\/td><td class="wrap muted">\(set\)<\/td>/);
  assert.match(h, /href="#fleet">All runners<\/a>/);
  click({ target: { closest: (sel) => (sel === "tr.rr" ? { dataset: { i: "0" } } : null) } });
  await flush();
  assert.match(box.innerHTML, /<pre class="panel joblog">run log text<\/pre>/);
  assert.ok(asked.some((u) => u.startsWith("/api/jobs/log?ref=") && decodeURIComponent(u).includes('"out":[0,120]')), "the log is the run's byte range");
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
  ctx.setTab("fleet", "", "");
});

test("a judge has no tile on the Fleet tab, and Log's verdict headers link to the runner whose DETAIL= draws it", () => {
  const fs = vm.runInContext("fst", ctx);
  // The links follow the confs: a renamed runner moves the link, no name is hard-coded.
  const judges = { ...fleetData, workers: [{ ...data.workers[0], detail: "ask-judge" }, { ...worker("dispatch-judge"), detail: "dispatch-verdicts" }] };
  st.tab = "fleet";
  fs.data = judges;
  ctx.renderFleet();
  assert.doesNotMatch(box.innerHTML, /class="tile"/, "the judges' tiles moved to their pages");
  st.tab = "log";
  ctx.renderLogVerdicts();
  assert.match(logBox.innerHTML, /<a href="#fleet\/dispatch-judge">Dispatch judge<\/a>/);
  assert.match(logBox.innerHTML, /<a href="#fleet\/ask-judge">Answer judge<\/a>/);
  // Negative control: no conf names the block, so the header is plain, not a dead link.
  fs.data = fleetData;
  ctx.renderLogVerdicts();
  assert.match(logBox.innerHTML, /<h3 class="sub">Dispatch judge <span/);
  st.tab = "fleet";
});
