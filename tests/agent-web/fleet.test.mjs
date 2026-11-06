// Unit tests for the Fleet tab's runner rows (.local/src/agent-web/static/fleet.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context, as the browser loads them; only the DOM is a stub. The registry itself is
// hub_core::fleet, tested in Rust; this checks how a row opens and what it draws.
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
const parts = { "fw-body": part(), "fw-chips": part(), "fleet-head": part(), "fleet-tail": part() };
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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "table.js", "actions.js", "board.js", "jobs.js", "fleet.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

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
  tonight: { until: 1793942659 + 6 * 3600, other_timers: 0, slots: [] },
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
const open = (name) => { vm.runInContext("fst", ctx).data = data; click({ target: { closest: (sel) => (sel === "tr.wr" ? { dataset: { key: name } } : null) } }); };

test("a runner row is closed until clicked, and a second click closes it", () => {
  vm.runInContext("st", ctx).tab = "fleet";
  vm.runInContext("fst", ctx).data = data;
  ctx.renderFleet();
  assert.doesNotMatch(box.innerHTML, /class="wdet"/);
  assert.match(box.innerHTML, /<tr class="wr" data-key="ask-judge">/);
  open("ask-judge");
  assert.match(box.innerHTML, /<tr class="wr sel" data-key="ask-judge">/);
  assert.equal((box.innerHTML.match(/class="wdet"/g) || []).length, 1);
  open("ask-judge");
  assert.doesNotMatch(box.innerHTML, /class="wdet"/);
});

test("an open judge shows its role, prompt, 24h calls with Langfuse links, and its rule table", () => {
  open("ask-judge");
  const h = box.innerHTML;
  assert.match(h, /<b>distill<\/b> <span class="muted" title="reads and returns data">write no, task no, bash no, mcp none<\/span>/);
  assert.match(h, /prompt <span title="\/home\/k\/.config\/agent-ask\/policy.md">policy.md<\/span> 3fa1c2d/);
  assert.match(h, /trigger called by its caller \| 24h: 14 calls, <span class="bad">1 errors<\/span>, \$0.12, 865k tokens, p95 7s/);
  assert.match(h, /<a href="https:\/\/lf\/project\/P\/sessions\/s1" target="_blank" rel="noopener">Langfuse<\/a>/);
  assert.match(h, /<td class="bad">error<\/td><td><span class="muted">s2<\/span>/, "a call with no session shows its id");
  assert.match(h, /<td>ship_deploy<\/td><td class="n">9<\/td><td class="n">6<\/td><td class="n">100%<\/td><td class="n">-<\/td><td>yes<\/td>/);
  assert.match(h, /<td>taste<\/td>.*<td class="n">18%<\/td><td>no \(6\/30 to bar\)<\/td>/);
  open("ask-judge");
});

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

test("a runner with no calls and no judge table shows only its registry lines", () => {
  open("dream");
  const det = box.innerHTML.split('class="wdet"')[1];
  assert.match(det, /trigger \*-\*-\* 03:00:00 \| 24h: 0 calls, <span class="">0 errors<\/span>, -, 0 tokens, p95 -/);
  assert.doesNotMatch(det, /<th>rule<\/th>|<th>trace<\/th>/);
  open("dream");
});

test("Tonight lists the slots in hub-core's order, a call under its caller, and the other timers as a count", () => {
  const night = {
    ...data,
    workers: [...data.workers, worker("sentinel", { kind: "persistent" })],
    tonight: {
      until: 1793942659 + 6 * 3600, other_timers: 12,
      slots: [
        { name: "sentinel", at: null, under: null },
        { name: "dream", at: 1793942659 + 3600, under: null },
        { name: "ask-judge", at: null, under: "dream" },
        { name: "gone", at: 1793942659 + 7200, under: null },
      ],
    },
  };
  const f = vm.runInContext("fst", ctx);
  f.data = night;
  ctx.renderFleet();
  assert.match(box.innerHTML, /<button class="btn sm" data-tonight>Tonight<\/button>/);
  const rows = () => [...box.innerHTML.matchAll(/data-key="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(rows(), ["ask-judge", "dream", "sentinel"], "the default order is untouched");
  click({ target: { closest: (sel) => (sel === "[data-tonight]" ? {} : null) } });
  const h = box.innerHTML;
  assert.deepEqual(rows(), ["sentinel", "dream", "ask-judge"], "a slot with no worker is skipped");
  const clock = vm.runInContext("clock", ctx);
  assert.match(h, /<td title="">always <a href="#fleet\/sentinel">sentinel<\/a><\/td>/);
  assert.match(h, new RegExp(`<td title="">${clock((1793942659 + 3600) * 1e3)} <a href="#fleet/dream">dream</a></td>`));
  assert.match(h, /<td title=""><span class="muted" title="called by dream">`- <\/span> <a href="#fleet\/ask-judge">ask-judge<\/a><\/td>/);
  assert.match(h, new RegExp(`\\+ 12 other timers before ${clock((1793942659 + 6 * 3600) * 1e3)}: <a href="#jobs">Infra Jobs</a>`));
  assert.match(h, /data-tonight>Default order<\/button>/);
  click({ target: { closest: (sel) => (sel === "[data-tonight]" ? {} : null) } });
  assert.deepEqual(rows(), ["ask-judge", "dream", "sentinel"]);
  assert.doesNotMatch(box.innerHTML, /other timers/);
  f.data = data;
});

test("the score cell ends each row in both orders, its title what it counted, and no score is a dash", () => {
  const score = { value: 93.2, right: 41, n: 44, window: "7d", source: "triage-untouched", text: "93% untouched", title: "7d, 41 of 44 right, 3 pending, triage-untouched" };
  const scored = {
    ...data,
    workers: [{ ...data.workers[0], score }, data.workers[1]],
    tonight: { until: 1793942659 + 6 * 3600, other_timers: 0, slots: [{ name: "ask-judge", at: null, under: null }, { name: "dream", at: 1793942659 + 3600, under: null }] },
  };
  const f = vm.runInContext("fst", ctx);
  f.data = scored;
  for (const tonight of [false, true]) {
    f.tonight = tonight;
    ctx.renderFleet();
    const h = box.innerHTML;
    assert.match(h, /\$ 24h<\/(button><\/)?th><th>score 7d<\/th><\/tr>/);
    assert.match(h, /<td title="7d, 41 of 44 right, 3 pending, triage-untouched">93% untouched<\/td><\/tr>/, `tonight=${tonight}`);
    assert.match(h, /data-key="dream">.*?<td class="muted">-<\/td><\/tr>/, `tonight=${tonight}`);
  }
  f.tonight = false;
  f.data = data;
});

test("an empty night says so and draws no count", () => {
  const f = vm.runInContext("fst", ctx);
  f.data = data;
  f.tonight = true;
  ctx.renderFleet();
  assert.match(box.innerHTML, /No runner runs before morning\./);
  assert.doesNotMatch(box.innerHTML, /other timers/);
  f.tonight = false;
});

// The Workers filter. The rows here are in hub-core's default order, exceptions first.
const row = (name, o) => ({ ...worker(name), ...o });
const fleet = {
  ...data,
  tonight: { until: data.at + 6 * 3600, other_timers: 0, slots: [{ name: "stuck", at: data.at + 60, under: "" }, { name: "calm", at: data.at + 120, under: "" }] },
  workers: [
    row("broke", { lane: "deliver", state: "idle", failed_24h: 2, runs_24h: 5, cost_24h: 0.5, why: { word: "FAILED", text: "no gateway route", at: 10, ok: false }, last: { word: "FAILED", at: 900, ok: false } }),
    row("stuck", { lane: "deliver", state: "running", running_since: data.at - 900, usual_s: 120, overdue: true, runs_24h: 9, cost_24h: 2, description: "hangs on the pool" }),
    row("calm", { lane: "observe", state: "idle", runs_24h: 1, last: { word: "OK", at: 500, ok: true } }),
    row("parked", { lane: "", state: "off", enabled: false }),
  ],
};
const st = vm.runInContext("st", ctx);
const show = (query) => {
  st.tab = "fleet";
  st.views.fleet = query;
  vm.runInContext("fst", ctx).data = fleet;
  vm.runInContext("fst", ctx).tonight = false;
  ctx.renderFleet();
  return box.innerHTML;
};
const names = (html) => [...html.matchAll(/data-key="([^"]+)"/g)].map((m) => m[1]);
const press = (attr, key, val) => click({ target: { closest: (sel) => (sel === `[data-${attr}]` ? { dataset: { [key]: val } } : null) } });
const chip = (html, label) => html.match(new RegExp(`${label} <span class="n">(\\d+)`))?.[1];

test("a linked view opens filtered, and only a real tab reads as one", () => {
  const r = ctx.route("#fleet?lane=deliver&s=failed");
  assert.deepEqual([r.tab, r.arg, r.query], ["fleet", "", "lane=deliver&s=failed"]);
  assert.equal(ctx.route("#daily/status/inbox").query, "");
  assert.deepEqual(names(show(r.query)), ["broke"]);
  assert.match(box.innerHTML, /<option value="deliver" selected>/);
  assert.deepEqual(names(show("s=nonsense&sort=nonsense")), ["broke", "stuck", "calm", "parked"]);
});

test("a chip and a sort write the hash, and the plain view is a bare #fleet", () => {
  show("");
  press("fstate", "fstate", "failed");
  assert.equal(vm.runInContext("history", ctx).url, "#fleet?s=failed");
  press("fsort", "fsort", "cost");
  assert.equal(vm.runInContext("history", ctx).url, "#fleet?s=failed&sort=cost");
  press("fstate", "fstate", "all");
  press("fsort", "fsort", "cost");
  press("fsort", "fsort", "cost");
  assert.equal(vm.runInContext("history", ctx).url, "#fleet");
});

test("a tab hop keeps the view and a bare link clears it", () => {
  show("s=off");
  ctx.setTab("home");
  assert.equal(vm.runInContext("history", ctx).url, "/");
  ctx.setTab("fleet");
  assert.equal(st.views.fleet, "s=off");
  assert.equal(vm.runInContext("history", ctx).url, "#fleet?s=off");
  ctx.setTab("fleet", "", "");
  assert.equal(st.views.fleet, "");
});

test("each chip counts under the search and lane, whichever chip is on", () => {
  let h = show("");
  assert.deepEqual(["All", "Failed 24h", "Running", "Idle", "Off"].map((l) => chip(h, l)), ["4", "1", "1", "2", "1"]);
  h = show("lane=deliver&s=running");
  assert.deepEqual(names(h), ["stuck"]);
  assert.deepEqual(["All", "Failed 24h", "Running", "Idle", "Off"].map((l) => chip(h, l)), ["2", "1", "1", "1", "0"]);
  assert.match(h, /<button class="on" data-fstate="running">/);
});

test("the search reads name, description and why, and an empty result says so", () => {
  assert.deepEqual(names(show("q=CAL")), ["calm"]);
  assert.deepEqual(names(show("q=pool")), ["stuck"]);
  assert.deepEqual(names(show("q=gateway")), ["broke"]);
  assert.match(show("q=zzz"), /No runner matches this filter/);
});

test("the lane list is built from the data and keeps a linked lane", () => {
  const h = show("lane=gone");
  assert.deepEqual([...h.matchAll(/<option value="([^"]*)"/g)].map((m) => m[1]), ["", "deliver", "gone", "observe"]);
});

test("a sort goes biggest first then smallest, a runner with no value last both ways", () => {
  assert.deepEqual(names(show("sort=cost")), ["stuck", "broke", "calm", "parked"]);
  assert.match(box.innerHTML, /aria-sort="descending"><button class="thsort" data-fsort="cost"[^>]*>\$ 24h v</);
  assert.deepEqual(names(show("sort=cost&dir=asc")), ["broke", "stuck", "calm", "parked"]);
  assert.deepEqual(names(show("sort=runs")), ["stuck", "broke", "calm", "parked"]);
  assert.deepEqual(names(show("sort=last")), ["stuck", "broke", "calm", "parked"]);
});

test("a row still opens under a filter and a sort", () => {
  show("s=failed&sort=cost");
  click({ target: { closest: (sel) => (sel === "tr.wr" ? { dataset: { key: "broke" } } : null) } });
  assert.match(box.innerHTML, /<tr class="wr sel" data-key="broke">/);
  assert.equal((box.innerHTML.match(/class="wdet"/g) || []).length, 1);
  click({ target: { closest: (sel) => (sel === "tr.wr" ? { dataset: { key: "broke" } } : null) } });
});

test("Tonight keeps its own order: the filter applies, the headers do not sort", () => {
  show("sort=cost");
  vm.runInContext("fst", ctx).tonight = true;
  ctx.renderFleet();
  assert.deepEqual(names(box.innerHTML), ["stuck", "calm"]);
  assert.doesNotMatch(box.innerHTML, /data-fsort/);
  st.views.fleet = "s=running";
  ctx.renderFleet();
  assert.deepEqual(names(box.innerHTML), ["stuck"]);
  vm.runInContext("fst", ctx).tonight = false;
});

test("typing repaints the rows and leaves the search box in place", () => {
  const before = show("");
  doc.activeElement = { id: "fw-q" };
  on.input({ target: { id: "fw-q", value: "stuck" } });
  assert.equal(box.innerHTML, before);
  assert.deepEqual(names(parts["fw-body"].innerHTML), ["stuck"]);
  assert.equal(chip(parts["fw-chips"].innerHTML, "All"), "1");
  assert.equal(st.views.fleet, "q=stuck");
  ctx.renderFleet();
  assert.equal(box.innerHTML, before);
  assert.match(parts["fleet-head"].innerHTML, /Claude accounts/, "a refresh still reaches the rest of the page");
  assert.match(parts["fleet-tail"].innerHTML, /ANSWER JUDGE/);
  doc.activeElement = null;
  on.change({ target: { id: "fw-lane", value: "deliver" } });
  assert.equal(st.views.fleet, "q=stuck&lane=deliver");
});

test("a run past its usual length says so", () => {
  const h = show("q=stuck");
  assert.match(h, /<td class="warn">running since [^<]*, over its usual 2m<\/td>/);
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

test("a Workers row links to its runner page, and the page is read only when opened", async () => {
  serve({});
  ctx.setTab("fleet", "", "");
  vm.runInContext("fst", ctx).data = data;
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

test("the Fleet tab keeps one tile per judge linking to the runner whose DETAIL= draws it, and Log's verdict headers link there too", () => {
  const fs = vm.runInContext("fst", ctx);
  // The links follow the confs: a renamed runner moves the link, no name is hard-coded.
  const judges = { ...data, workers: [{ ...data.workers[0], detail: "ask-judge" }, { ...worker("dispatch-judge"), detail: "dispatch-verdicts" }] };
  st.tab = "fleet";
  fs.data = judges;
  ctx.renderFleet();
  assert.match(box.innerHTML, /<a class="tile" href="#fleet\/dispatch-judge"[^>]*><span class="tl">DISPATCH JUDGE/);
  assert.match(box.innerHTML, /<a class="tile" href="#fleet\/ask-judge"[^>]*><span class="tl">ANSWER JUDGE/);
  assert.doesNotMatch(box.innerHTML, /<span class="tl">AGREE/, "the full judge tiles moved to the page");
  st.tab = "log";
  ctx.renderLogVerdicts();
  assert.match(logBox.innerHTML, /<a href="#fleet\/dispatch-judge">Dispatch judge<\/a>/);
  assert.match(logBox.innerHTML, /<a href="#fleet\/ask-judge">Answer judge<\/a>/);
  // Negative control: no conf names the block, so the tile and header are plain, not a dead link.
  fs.data = data;
  ctx.renderLogVerdicts();
  assert.match(logBox.innerHTML, /<h3 class="sub">Dispatch judge <span/);
  st.tab = "fleet";
  ctx.renderFleet();
  assert.match(box.innerHTML, /<div class="tile"[^>]*><span class="tl">DISPATCH JUDGE/);
});
