// Unit tests for the Costs tab (.local/src/agent-web/static/costs.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context; only the DOM
// is a stub. Which rows a cut, window or query keeps, and their order, is hub_core::costs::board,
// tested in Rust; this checks the page draws the board it is sent and asks for the view clicked.
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
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ||= []).push(f); } });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const doc = { getElementById: (id) => (id === "costs" ? box : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "costs.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const cost = run("cost");
const tick = () => new Promise((r) => setImmediate(r));

const col = (key, sort = null, next = [key, "desc"]) => ({ key, sort, next_sort: next[0], next_dir: next[1] });
const line = (o) => ({ session: null, title: null, tool: null, kind: null, project: null, harness: null, model: null, runner: null, sessions: null, calls: null, tokens: null, cost: 0, share: 0, landed: null, redo: null, reverts: null, per_pr: null, src: null, pr: null, at: null, ...o });
// The shape hub_core::costs::Board serializes to: the model cut over 7d, sorted by cost ascending.
const MODEL_COLS = ["model", "harness", "sessions", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "src"];
// The table's columns are every Line column in Line::COLUMNS order, whatever the cut.
const LINE_COLS = ["session", "tool", "kind", "project", "harness", "model", "runner", "title", "sessions", "calls", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "src", "pr", "at"];
// hub_core::burn::Burn as serialized: the 2026-11-06 fleet, 3.3x over what the weeks carry.
// A source row: a Claude account unless `o` says otherwise; used_text is what burn::used_text prints.
const acct = (name, o) => {
  const a = { name, kind: "claude", unpaced: false, reserve: null, parent: null, state: "ok", room: { ok: true, reasons: [], headroom: 4.2, text: "room, 4 points spare" }, live: 0, used: 10, gone: 5, burn: 1, sustain: 2, over: 0.5, idle_at: 1794003600, burn_at: null, run_out: null, resets: 1794200000, ...o };
  return { used_text: a.used == null ? "-" : `${Math.floor(a.used)}%`, ...a };
};
const burn = (o = {}) => ({
  at: 1794000000, level: "bad", head: "4.5 pts/h vs 1.4 sustainable, 3.3x OVER, 39 live, carries ~11", drip_line: "15 started in 1h, 349 in 24h",
  accounts: [acct("alt", { live: 9, used: 55, gone: 25, burn: 1.04, sustain: 0.36 }), acct("bnb", { live: 17, used: 7, gone: 1, burn: 1.97, sustain: 0.56 }), acct("main", { live: 13, used: 33, gone: 12, burn: 1.51, sustain: 0.45, burn_at: 1794000600 })],
  fleet: { live: 39, burn: 4.52, sustain: 1.37, over: 3.3, rate: 0.116, carries: 11 },
  drip: { hour: 15, day: 349, held: "fleet-assess says HOLD" },
  pace: { on_pace: false, at_burn: [["main", 1794000600]], idle_all_by: 1794003600, idle_rest_after_reset: false },
  legend: [["pts/h", "points of a weekly limit an hour"], ["GONE", "the share of the week gone"]], ...o,
});
const board = (o = {}) => ({
  at: 1794000000, by: "model", window: "7d",
  cuts: ["session", "model", "harness", "tool", "project", "runner", "kind"], windows: ["24h", "7d", "30d"],
  totals: [{ window: "24h", usd: 12.5, sessions: 3, unpriced: 0 }, { window: "7d", usd: 40, sessions: 9, unpriced: 2 }, { window: "30d", usd: 90, sessions: 20, unpriced: 2 }],
  live: { claude_24h: 11 },
  direct: { usd: 1.25, unpriced: 1, note: "opencode lazer/*, nightly; other direct use unseen" },
  sources: [{ name: "outcomes", as_of: 1793990000, stale: false }, { name: "token snapshot", as_of: 1793000000, stale: true }, { name: "calls", as_of: null, stale: true }],
  errors: [], columns: MODEL_COLS, source: "outcomes rows", eval_days: 7, unpriced: null,
  rows: [
    line({ model: "gpt-5-codex", harness: "codex", sessions: 2, tokens: 1500000, cost: 4, share: 0.1, landed: 0.5, redo: 1, reverts: 0, per_pr: 4, src: "mixed" }),
    line({ model: "opus-5-5", harness: "claude", sessions: 7, tokens: 9e9, cost: 36, share: 0.9, landed: 0.875, redo: 0, reverts: 1, per_pr: 5.14, src: "outcomes" }),
  ],
  shown_usd: 40,
  table: { q: "", state: "", sort: "cost", dir: "asc", total: 2, shown: 2, states: [], columns: LINE_COLS.map((k) => (k === "cost" ? col(k, "asc", ["", "desc"]) : col(k))), facets: [{ key: "harness", on: null, clear: "", values: [{ value: "codex", n: 1, q: "harness:codex" }] }] },
  grafana: "https://grafana.example/d/kb-agents-overview", burn: burn(), ...o,
});
const show = (d) => { run("st.tab = 'costs'"); Object.assign(cost, { data: d, err: null }); run("cost.render()"); return box.innerHTML; };
// `tbl` is the section table the target sits in (its block's data-tbl), blank for the main one.
const target = ({ tbl = "", ...attrs }) => ({ dataset: attrs, closest: (sel) => (sel === "[data-tbl]" ? (tbl ? { dataset: { tbl } } : null) : (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) || (sel === "[data-cv]" && "cv" in attrs) ? { dataset: attrs } : null) });

test("the model cut draws the server's columns, order and sort, with its evaluation", () => {
  const h = show(board());
  for (const k of ["model", "harness", "sess", "tokens", "landed", "redo", "rev", "\\$/PR", "src"]) assert.match(h, new RegExp(`>${k}</button></th>`), `header ${k}`);
  assert.doesNotMatch(h, /data-tsort="runner"/, "a column the cut does not name is not drawn");
  const heads = [...h.matchAll(/title="sort by ([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(heads.slice(0, 2), ["model", "harness"], "the header is in the cut's order, as the cells are");
  assert.match(h, /aria-sort="ascending"[^>]*><button class="thsort" data-tsort="" data-tdir="desc" title="sort by cost">cost \^/, "the sorted header says its direction");
  assert.ok(h.indexOf("gpt-5-codex") < h.indexOf("opus-5-5"), "the server's order is kept");
  assert.match(h, /<td class="n">\$5\.14<\/td>/, "$ per PR");
  assert.match(h, /<td class="n">0\.88<\/td>/, "landed rate");
  assert.match(h, /<td class=" warn">mixed<\/td>/, "a joined evaluation is flagged");
  assert.match(h, /<td class="n">9\.0B<\/td>/);
  assert.match(h, /fleet-bench models over 7d, per family \(opus\), queue items only/);
  assert.match(h, /2 of 2 rows, \$40\.00\./);
  assert.match(h, /<button class="on" data-cv="by" data-cval="model">model<\/button>/);
  assert.match(h, /<button class="on" data-cv="w" data-cval="7d">7d<\/button>/);
  assert.match(h, /href="https:\/\/grafana\.example\/d\/kb-agents-overview"/);
});

test("the head says spend, the live gauges and how old each source is", () => {
  const h = show(board());
  assert.match(h, /SPEND 7D[\s\S]*\$40\.00[\s\S]*9 sessions, 2 unpriced/);
  assert.doesNotMatch(h, /LAZER (POOL|RESERVE|GLM)/, "the pool and its keys are Burn rows, not tiles");
  assert.match(h, /LAZER DIRECT<\/span><span class="tv">\$1\.25<\/span><span class="ts1"><span class="warn">\+1 unpriced<\/span>, opencode lazer\/\*, nightly; other direct use unseen</);
  assert.match(h, /<span class="warn">token snapshot /, "a stale source is amber");
  assert.match(h, /<span class="warn">calls never<\/span>/);
  assert.match(h, /<span class="muted">outcomes /);
});

test("with no direct rows the direct tile says unknown, never $0 or blank", () => {
  const h = show(board({ live: {}, direct: undefined }));
  assert.match(h, /LAZER DIRECT<\/span><span class="tv">-<\/span><span class="ts1">not read</, "no direct figure says so");
  assert.doesNotMatch(h, /unpriced<\/span>, /);
});

test("Burn points at Consumers for the keys inside a pool, and lists the pool only", () => {
  const key = acct("glm", { kind: "litellm-key", unpaced: true, used: 96, used_text: "96% $48/$50", gone: null, reserve: 15, parent: "lazer", nested: true });
  const pool = acct("lazer", { kind: "litellm-team", unpaced: true, used: 90, used_text: "90% $226/$250", gone: null });
  const paced = acct("alt", { used: 80, gone: 64 });
  const page = (level) => show(board({ burn: burn({ accounts: [paced, pool, key], keys: { head: "1 in lazer, 0 live, tightest glm 96%", level } }) }));
  const quiet = page("ok");
  assert.match(quiet, /<span class="muted">KEYS<\/span> <span class="muted">1 in lazer, 0 live, tightest glm 96%<\/span> <a href="#costs\/consumers">rows in Consumers<\/a>/);
  assert.ok(quiet.includes("<td>lazer</td>"), "the pool is a Burn row");
  assert.doesNotMatch(quiet, /<td>glm<\/td>/, "the key is a Consumers row, not a Burn one");
  assert.match(quiet, /<td>alt<\/td>.*?width:80\.0%[^>]*><\/span><i style="left:min\(64\.0%,calc\(100% - 2px\)\)"><\/i>/, "a paced row has its tick, held inside the box");
  assert.match(page("warn"), /KEYS<\/span> <span class="warn">/, "a key refusing on its own is amber");
  assert.equal(ctx.route("#costs/consumers").arg, "limits", "the pointer opens the inner tab holding Consumers");
});

// hub_core::gateway::Consumers as serialized: one runner on the core key, one on the low pool.
const consumer = (o) => ({ consumer: "version-summary", kind: "runner", priority: "must", runs_on: "raw fast via gateway-fast", budget: "lazer-core (key comms-triage)", spent: "$0.02/$25.00 30d", fallback: "gemini-flash", status: "ok", who: null, mismatch: false, level: "ok", ...o });
const CONSUMER_COLS = ["consumer", "priority", "runs_on", "budget", "spent", "fallback", "status"];
const consumers = (o = {}) => ({
  head: "2 consumers: must 1, low 1 | lazer-core $0.50/$200", level: "ok", stale: null, errors: [], columns: CONSUMER_COLS,
  headers: ["CONSUMER", "PRI", "RUNS ON", "BUDGET", "SPENT", "FALLBACK", "STATUS"],
  rows: [consumer(), consumer({ consumer: "claude-reserve", kind: "key", priority: "low", budget: "lazer-pool", status: "team at cap" })],
  pools: ["team must lazer-core $0.50/$200 per 1mo", "team low lazer-pool $228/$50.00 AT CAP per 1mo"],
  routes: "aliases: fast -> gpt-oss-120b; fallbacks: gpt-oss-120b -> gemini-flash",
  legend: [["PRI", "the priority its conf or key declares: must, low, off"]],
  table: { q: "", state: "", sort: "", dir: "", total: 2, shown: 2, states: [], columns: CONSUMER_COLS.map((k) => col(k)), facets: [] }, ...o,
});

test("Consumers start open after Burn, green or red, and the reader's fold stays", () => {
  const quiet = show(board({ consumers: consumers() }));
  assert.match(quiet, /<details class="csec" data-k="consumers" id="sec-consumers" open><summary><h2 class="sec">Consumers <span class="n">2<\/span><\/h2><\/summary>/, "green is open, its head a count");
  assert.doesNotMatch(quiet, /MISMATCH:/, "no mismatch, no line");
  assert.ok(quiet.indexOf("sec-burn") < quiet.indexOf("sec-consumers") && quiet.indexOf("sec-consumers") < quiet.indexOf('data-in="models"'), "after Burn, before Models");
  for (const h of ["consumer", "pri", "runs on", "budget", "spent", "fallback", "status"]) assert.match(quiet, new RegExp(`data-tsort="[a-z_]+" data-tdir="desc" title="sort by ${h}">${h}</button>`), `header ${h}`);
  assert.match(quiet, /<div data-tbl="c"><div id="costs-cons-tiles"><\/div><div class="tqbar"><input id="costs-cons-q" data-tsearch placeholder="search, or priority:low -status:ok"/, "its own search bar, flush on its rows");
  assert.match(quiet, /<div id="costs-cons-body"><div class="panel scroll"><table class="tbl">/);
  assert.match(quiet, /<tr><td>version-summary<\/td><td>must<\/td><td>raw fast via gateway-fast<\/td><td>lazer-core \(key comms-triage\)<\/td><td>\$0\.02\/\$25\.00 30d<\/td><td>gemini-flash<\/td><td>ok<\/td><\/tr>/);
  assert.match(quiet, /<div>team low lazer-pool \$228\/\$50\.00 AT CAP per 1mo<\/div><div>aliases: fast -&gt; gpt-oss-120b; fallbacks: gpt-oss-120b -&gt; gemini-flash<\/div>/);
  assert.match(quiet, /pri: the priority its conf or key declares/);
  const red = consumers({ level: "bad", head: "1 MISMATCH | 2 consumers: must 2", rows: [consumer({ consumer: "nightly-thing", budget: "lazer-pool (key claude-reserve)", status: "MISMATCH: lazer-pool is low priority", mismatch: true, level: "bad" })] });
  red.table = { ...red.table, total: 1, shown: 1, states: [{ name: "all", n: 1 }, { name: "mismatch", n: 1, tone: "warn", means: "a runner on a budget of another priority" }] };
  const h = show(board({ consumers: red }));
  assert.match(h, /data-k="consumers" id="sec-consumers" open><summary><h2 class="sec bad">Consumers <span class="n">1<\/span><\/h2><\/summary>/);
  assert.match(h, /<button class="tile t-warn" data-ts="mismatch" title="a runner on a budget of another priority"><span class="tl">MISMATCH<\/span><span class="tv">1<\/span><\/button>/, "a mismatch is its table's amber tile");
  assert.doesNotMatch(h, /MISMATCH: a runner/, "and no line beside it says it again");
  assert.match(h, /<td class="bad">nightly-thing<\/td>.*?<td class="bad">MISMATCH: lazer-pool is low priority<\/td>/);
  // negative control: the reader's fold wins over the open default, and a stale read says why
  cost.open.consumers = false;
  const stale = show(board({ consumers: consumers({ level: "warn", stale: "stale: the gateway snapshot is 3h old (claude-acct gateway, timer claude-acct-usage)" }) }));
  assert.match(stale, /data-k="consumers" id="sec-consumers"><summary>/);
  assert.match(stale, /<div class="warn">stale: the gateway snapshot is 3h old/);
  delete cost.open.consumers;
  assert.doesNotMatch(show(board()), /sec-consumers/, "no Consumers data draws no section");
  // negative control: a search that keeps nothing says so, and the bar stays to clear it
  const none = consumers({ rows: [] });
  none.table = { ...none.table, q: "zzz", shown: 0 };
  assert.match(show(board({ consumers: none })), /id="costs-cons-q"[\s\S]*<div id="costs-cons-body"><div class="panel muted">No consumer matches\.<\/div>/);
});

test("a Consumers header, search or tile is its own view, apart from the main table", async () => {
  asked = [];
  body = board({ consumers: consumers() });
  run("st.tab = 'costs'; st.views.costs = 'q=harness%3Acodex&sort=cost'");
  fire("click", { type: "click", target: target({ tsort: "priority", tdir: "desc", tbl: "c" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&csort=priority");
  fire("click", { type: "click", target: target({ tsort: "priority", tdir: "asc", tbl: "c" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&csort=priority&cdir=asc");
  fire("input", { type: "input", target: { ...target({ tsearch: "", tbl: "c" }), value: "priority:low" } });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&cq=priority%3Alow&csort=priority&cdir=asc");
  fire("click", { type: "click", target: target({ ts: "mismatch", tbl: "c" }) });
  await tick();
  assert.match(asked.at(-1), /&cs=mismatch/);
  // negative control: the same header click in the main table is the main table's sort
  fire("click", { type: "click", target: target({ tsort: "harness", tdir: "desc" }) });
  await tick();
  assert.match(asked.at(-1), /^\/api\/costs\?q=harness%3Acodex&sort=harness&cq=/);
});

test("a dollar source is a burn row with its kind, dollars and reserve, and no pace cells", () => {
  const key = acct("reserve", { kind: "litellm-key", unpaced: true, used: 41, used_text: "41% $41/$100", gone: null, reserve: 15, parent: "lazer", burn: 9, sustain: 1, idle_at: null, resets: null });
  const h = show(board({ burn: burn({ accounts: [acct("main", { reserve: 15 }), key] }) }));
  assert.match(h, /<tr><th data-role="lead">source<\/th><th>kind<\/th><th class="n">live<\/th><th>bar<\/th><th class="n" data-role="glance" data-named>used<\/th><th class="n" data-role="glance" data-named>gone<\/th><th class="n">reserve<\/th><th data-role="glance">room<\/th>/);
  assert.match(h, /<th class="n">\$24h<\/th><\/tr>/, "the pool column is gone: a key nests under its pool");
  assert.match(h, /<td>reserve<\/td><td>litellm-key<\/td><td class="n">0<\/td><td>.*?<\/td><td class="n">41% \$41\/\$100<\/td><td class="n">-<\/td><td class="n">15%<\/td>/);
  // negative control: its 9 pts/h over a 1 pts/h line would be amber on a paced row
  assert.match(h, /<td class="n">-<\/td><td class="n">-<\/td><td>-<\/td><td>-<\/td><td>-<\/td><td>-<\/td>/, "burn, keeps and both pace cells say nothing");
  assert.doesNotMatch(h, /<td class="n warn">9\.00/);
  assert.match(h, /<td>main<\/td><td>claude<\/td><td class="n">0<\/td><td>.*?<\/td><td class="n">10%<\/td><td class="n">5%<\/td><td class="n">15%<\/td>/);
});

test("the tool cut with no allocated dollars prints no dollars", () => {
  const note = "no snapshot in this window allocates dollars to tools yet: calls and tokens only";
  const h = show(board({ by: "tool", columns: ["tool", "calls", "tokens", "cost", "share"], unpriced: note, rows: [line({ tool: "Bash", calls: 40, tokens: 2e6, cost: 0, share: 0 })], table: { ...board().table, columns: LINE_COLS.map((k) => col(k)), sort: "", dir: "desc", total: 1, shown: 1 } }));
  assert.match(h, /<td class="n">-<\/td><td class="n">-<\/td><\/tr>/, "cost and share are unknown, not zero");
  assert.match(h, new RegExp(`<span class="warn">${note}\\.</span>`));
  assert.match(h, /1 of 1 rows, -\./);
  assert.doesNotMatch(h, /fleet-bench/, "the evaluation note is the model and harness cuts' only");
});

test("an empty query result is told apart from an empty window", () => {
  const none = { ...board().table, q: "harness:nope", total: 2, shown: 0 };
  assert.match(show(board({ rows: [], shown_usd: 0, table: none })), /Nothing matches the query\./);
  assert.match(show(board({ rows: [], shown_usd: 0, table: { ...none, total: 0 } })), /Nothing spent in this window\./);
});

test("a click becomes the view keys in the URL and the request", async () => {
  asked = [];
  body = board();
  run("st.tab = 'costs'; st.views.costs = 'q=harness%3Acodex&sort=cost&dir=asc'");
  fire("click", { type: "click", target: target({ cv: "w", cval: "24h" }) });
  await tick();
  assert.equal(ctx.history.url, "#costs?q=harness%3Acodex&sort=cost&dir=asc&w=24h", "a window keeps the query and sort");
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&dir=asc&w=24h");
  fire("click", { type: "click", target: target({ cv: "by", cval: "runner" }) });
  await tick();
  assert.equal(ctx.history.url, "#costs?q=harness%3Acodex&w=24h&by=runner", "a new cut drops the old cut's sort");
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&by=runner&w=24h");
  fire("click", { type: "click", target: target({ tsort: "cost", tdir: "asc" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&dir=asc&by=runner&w=24h");
  fire("input", { type: "input", target: { ...target({ tsearch: "" }), value: "-model:opus" } });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=-model%3Aopus&sort=cost&dir=asc&by=runner&w=24h");
});

test("a failed read says why instead of drawing an empty table", () => {
  run("st.tab = 'costs'");
  Object.assign(cost, { data: null, err: "502 bad gateway" });
  run("cost.render()");
  assert.match(box.innerHTML, /<div class="card err">502 bad gateway<\/div>/);
});

test("the burn section leads the tab: headline, drip with its hold link, pace and a row per source", () => {
  const h = show(board());
  assert.ok(h.indexOf("sec-burn") > h.indexOf("sec-totals"), "burn leads Limits, which follows Spend");
  assert.match(h, /<span class="burn bad">4\.5 pts\/h vs 1\.4 sustainable, 3\.3x OVER, 39 live, carries ~11<\/span>/);
  assert.match(h, /<details class="csec" data-k="burn" id="sec-burn" open>/, "red starts open");
  assert.match(h, /15 started in 1h, 349 in 24h <a class="warn" href="#sessions" title="fleet-assess says HOLD">dispatch held -> Sessions<\/a>/);
  assert.match(h, /at this burn: main [^;]+; if idle: all by /);
  assert.match(h, /<td>bnb<\/td><td>claude<\/td><td class="n">17<\/td><td>.*?<\/td><td class="n">7%<\/td><td class="n">1%<\/td><td class="n">-<\/td><td class="ok">room, 4 points spare<\/td><td class="n warn">1\.97<\/td><td class="n">0\.56<\/td><td>after reset<\/td>/, "an account over its sustainable rate is amber; burn that never gets there is after the reset");
  assert.doesNotMatch(h, /<td class="n warn">0\.45/, "keeps/h is never amber");
  assert.match(h, /<div class="muted fold">pts\/h: points of a weekly limit an hour; gone: the share of the week gone<\/div>/, "the terms come from hub-core's one legend");
});

test("every term hub-core's burn::LEGEND defines, bar the headline's unit, is a column this page prints", () => {
  const src = readFileSync(new URL("../../hub-core/src/burn.rs", dir), "utf8");
  const block = src.slice(src.indexOf("pub const LEGEND"), src.indexOf("];", src.indexOf("pub const LEGEND")));
  const terms = [...block.matchAll(/\(\s*"([^"]+)",\s*"/g)].map((m) => m[1]);
  assert.ok(terms.length > 5, `read ${terms.length} terms`);
  const h = show(board());
  for (const t of terms.filter((t) => t !== "pts/h")) {
    assert.ok(h.includes(`>${t.toLowerCase()}</th>`), `${t} is not a column`);
  }
});

test("a green burn starts open like every section, and a fold the reader set is kept", () => {
  const ok = board({ burn: burn({ level: "ok", head: "0.5 pts/h vs 1.4 sustainable, 0.4x, 5 live" }) });
  assert.match(show(ok), /<details class="csec" data-k="burn" id="sec-burn" open><summary>/, "green starts open");
  cost.open.burn = false;
  assert.match(show(ok), /<details class="csec" data-k="burn" id="sec-burn"><summary>/, "the reader's fold wins");
  cost.open = {};
});

test("an account claude-acct could not read is named, and no data says so", () => {
  const b = burn({ accounts: [acct("old", { state: "unreadable" }), acct("new", { state: "idle" })] });
  const h = show(board({ burn: b }));
  assert.match(h, /<td>old<\/td><td colspan="16" class="bad">usage unreadable<\/td>/);
  assert.match(h, /<td>new<\/td><td colspan="16" class="muted">idle, token refreshes on launch<\/td>/);
  const key = show(board({ burn: burn({ accounts: [acct("glm", { kind: "litellm-key", state: "idle" })] }) }));
  assert.match(key, /<td>glm<\/td><td colspan="16" class="muted">no usage read yet<\/td>/, "a key has no token to refresh");
  assert.match(show(board({ burn: burn({ accounts: [] }) })), /<div class="panel muted">no data from claude-acct<\/div>/);
});

test("the room column prints claude-acct's verdict: points past the line, the reserve, a stale textfile", () => {
  const room = (o) => ({ ok: false, reasons: ["pace"], headroom: -19.5, text: "no room: pace 20 points past the line", ...o });
  const b = burn({ stale: "stale, claude-acct's textfile is not fresh", accounts: [
    acct("a", { room: room({}) }),
    acct("b", { room: room({ reasons: ["reserve", "five_hour"], headroom: 3, text: "no room: reserve, five hour" }) }),
    acct("c", { state: "stale" }),
    acct("d", { room: null }),
  ] });
  const h = show(board({ burn: b }));
  assert.match(h, /<td class="bad">no room: pace 20 points past the line<\/td>/);
  assert.match(h, /<td class="bad">no room: reserve, five hour<\/td>/);
  assert.match(h, /<td>c<\/td><td colspan="16" class="bad">stale, claude-acct&#39;s textfile is not fresh<\/td>/);
  assert.match(h, /<td class="muted">-<\/td>/, "an account with no published verdict shows none, never a derived one");
});

// hub_core::sections::Block as serialized: All PRs, then the rows as printed cells.
const SEC_KEYS = ["section", "prs", "first_try", "reds_per_pr", "gate_min_per_pr", "gate_h", "green_lost", "cost_per_pr", "tokens_per_pr", "work_min_per_pr"];
const sections = (sort = null) => ({
  days: 7, head: "598 PRs in 7d, 52% first try, 145 gate min per PR, 116 greens lost", columns: SEC_KEYS, headers: ["section", "PRs", "first try", "gate reds/PR", "gate min/PR", "gate h", "greens lost", "cost/PR", "tokens/PR", "work min/PR"],
  all: ["All PRs", "598", "52%", "0.98", "145", "1109", "116", "$7.33", "14M", "34"],
  rows: [["Assets/Playground/Tests", "417", "48%", "1.07", "156", "1035", "107", "$6.96", "13M", "36"], ["docs", "472", "45%", "1.13", "163", "1002", "103", "-", "-", "-"]],
  notes: ["A PR counts in every section it touches, so the rows add up to more than All PRs.", "Cost, tokens and work min cover only the PRs a session claims (339 of 598 in All PRs)."],
  table: { ...board().table, total: 2, shown: 2, columns: SEC_KEYS.map((k) => (k === sort ? col(k, "desc", [k, "asc"]) : col(k, null, [k, "desc"]))) },
});

test("the Sections block starts open with its window, All PRs on top and both caveats", () => {
  const h = show(board({ sections: sections() }));
  assert.match(h, /<details class="csec" data-k="sections" id="sec-sections" open><summary><h2 class="sec">Sections <span class="n">2<\/span><\/h2><\/summary><div data-tbl="s">/, "open, a count on the head");
  assert.match(h, /<div class="tqbar"><input id="costs-sec-q" data-tsearch placeholder="search, or section:agent-web"/, "its own search bar");
  assert.match(h, /<div id="costs-sec-body"><div class="panel scroll"><div><b>window<\/b> last 7d<\/div>/, "the window in the body");
  assert.match(h, /<tr class="allrow"><td class="">All PRs<\/td><td class="n">598<\/td><td class="n">52%<\/td><td class="n">0\.98<\/td><td class="n">145<\/td><td class="n">1109<\/td><td class="n">116<\/td>/, "the old headline's PRs, first try, gate min and greens lost are the All PRs row");
  for (const k of ["section", "PRs", "first try", "gate reds/PR", "gate min/PR", "gate h", "greens lost", "cost/PR", "tokens/PR", "work min/PR"]) assert.match(h, new RegExp(`title="sort by ${k.replace("/", "\\/")}"`), `header ${k}`);
  assert.match(h, /data-tbl="s">[\s\S]*data-tsort="prs" data-tdir="desc"/, "its headers sort in its own block, apart from the main table's");
  assert.ok(h.indexOf("All PRs</td>") < h.indexOf("Assets/Playground/Tests</td>"), "All PRs is first");
  assert.ok(h.indexOf("Assets/Playground/Tests</td>") < h.indexOf("docs</td>"), "the server's order is kept");
  assert.match(h, /tr class="allrow"/);
  assert.match(h, /A PR counts in every section it touches[\s\S]*only the PRs a session claims \(339 of 598/);
  assert.match(h, /<td class="n">-<\/td><td class="n">-<\/td><td class="n">-<\/td><\/tr>/, "no claimed session is a dash");
});

test("a header click sorts the Sections block both ways without touching the main table", async () => {
  asked = [];
  body = board({ sections: sections() });
  run("st.tab = 'costs'; st.views.costs = 'q=harness%3Acodex&sort=cost'");
  fire("click", { type: "click", target: target({ tsort: "gate_h", tdir: "desc", tbl: "s" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&ssort=gate_h");
  fire("click", { type: "click", target: target({ tsort: "gate_h", tdir: "asc", tbl: "s" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&ssort=gate_h&sdir=asc");
  fire("click", { type: "click", target: target({ tsort: "", tdir: "desc", tbl: "s" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost", "the third click is the default order");
});

test("a poll while a section table's search has focus repaints only that table, so the typing stays", () => {
  const d = board({ sections: sections() });
  show(d);
  box.innerHTML = "whole tab";
  doc.activeElement = { id: "costs-sec-q" };
  run("cost.render()");
  assert.equal(box.innerHTML, "whole tab", "the tab is not redrawn around the search box");
  // negative control: with focus elsewhere the poll redraws the tab
  doc.activeElement = null;
  run("cost.render()");
  assert.match(box.innerHTML, /id="sec-sections"/);
});

test("no Sections data draws no block", () => {
  assert.doesNotMatch(show(board()), /sec-sections/);
  assert.doesNotMatch(show(board({ sections: { days: 7, head: "", columns: SEC_KEYS, headers: [], all: [], rows: [], notes: [], table: null } })), /sec-sections/);
});

test("a Sections fold the reader closed stays closed through the repaint a sort click causes", () => {
  run("st.tab = 'costs'");
  Object.assign(cost, { open: {} });
  const d = board({ sections: sections() });
  assert.match(show(d), /id="sec-sections" open/, "starts open");
  box.querySelectorAll = () => [{ dataset: { k: "sections" }, open: false }];
  run("cost.render()");
  assert.doesNotMatch(box.innerHTML, /id="sec-sections" open/, "the reader's fold survives the repaint");
  box.querySelectorAll = () => [{ dataset: { k: "sections" }, open: true }];
  run("cost.render()");
  assert.match(box.innerHTML, /id="sec-sections" open/, "and so does one they opened again");
  box.querySelectorAll = () => [];
});

test("a burn row carries the 5h window, when it resets and the day's dollars", () => {
  const h = show(board({ burn: burn({ accounts: [acct("main", { five_hour: 61.4, five_hour_resets: 1794007200, cost_24h: 12.5 }), acct("alt", { state: "idle" })] }) }));
  assert.match(h, /<th>resets<\/th><th class="n">5h<\/th><th>5h resets<\/th><th class="n">\$24h<\/th><\/tr>/);
  assert.match(h, /<td class="n">61%<\/td><td>[^<-][^<]*<\/td><td class="n">\$12\.50<\/td><\/tr>/);
  assert.match(h, /<td>alt<\/td><td colspan="16" class="muted">idle/, "a note row spans every column");
  const none = show(board({ burn: burn({ accounts: [acct("main", {})] }) }));
  assert.match(none, /<td class="n">-<\/td><td>-<\/td><td class="n">-<\/td><\/tr>/, "the control: no figures, no numbers");
});

test("the burn table ends on hub-core's total row, and has none without one", () => {
  const total = { live: 39, burn: 4.52, sustain: 1.37, over: true, run_out: null, cost_24h: 42.5 };
  const h = show(board({ burn: burn({ total }) }));
  assert.match(h, /<tr class="tot"><td><b>total<\/b><\/td><td>-<\/td><td class="n">39<\/td>/);
  assert.match(h, /<td class="n warn">4\.52<\/td><td class="n">1\.37<\/td>/, "over its line is amber");
  assert.match(h, /<td class="n">\$42\.50<\/td><\/tr><\/table>/, "the dollars close the row");
  assert.doesNotMatch(show(board({ burn: burn() })), /class="tot"/, "the control: no total, no row");
});

test("the token and Langfuse folds follow the Spend sections, in the Models inner tab", () => {
  run("cost.open = {}");
  const h = show(board({ tokens: tokens({ langfuse: { figures: lfFigures(), why: null } }), sections: null }));
  const at = (id) => h.indexOf(`id="${id}"`);
  assert.ok(at("sec-totals") >= 0 && at("sec-totals") < at("sec-burn") && at("sec-burn") < at("sec-tokens") && at("sec-tokens") < at("sec-langfuse"), "the DOM order is the layout order");
  assert.match(show(board()), /<h2 class="sec warn" id="sec-tokens">Where the tokens go<\/h2><div class="cline warn">no snapshot/);
});

test("a new token snapshot re-reads Costs while it is shown, and not from another tab", async () => {
  asked = [];
  run("st.tab = 'fleet'");
  run("TABS.costs").onEvent({ kind: "costs" });
  await tick();
  assert.equal(asked.length, 0, "the control: not shown, not read");
  run("st.tab = 'costs'");
  run("TABS.costs").onEvent({ kind: "fleet" });
  await tick();
  assert.equal(asked.length, 0, "another tab's event is not Costs'");
  run("TABS.costs").onEvent({ kind: "costs" });
  await tick();
  assert.equal(asked.length, 1);
  assert.match(asked[0], /^\/api\/costs/);
});

test("a Fleet link to a moved section opens Costs at that section", () => {
  const r = ctx.route("#fleet/tokens");
  assert.equal(r.tab, "costs");
  assert.equal(r.section, "tokens");
  assert.equal(ctx.route("#fleet/LANGFUSE").section, "langfuse");
  assert.deepEqual([ctx.route("#fleet/accounts").tab, ctx.route("#fleet/accounts").section], ["costs", "burn"]);
  const runner = ctx.route("#fleet/inbox-triage");
  assert.deepEqual([runner.tab, runner.arg, runner.section], ["fleet", "inbox-triage", undefined], "the control: a runner page stays on Fleet");
});

// Where the tokens go: hub_core::tokens's sums, open until the reader folds it.
const tokenRow = (name, chars, share, other = false) => ({ name, calls: 141812, chars, share, carried_tokens: 2550000000, other });
const tokenSplit = (context) => ({ days: 7, partial: 0, context, per_response: 120000, carried_share: 0.15, tools: [tokenRow("Bash", 331000000, 0.823), tokenRow("Other (22)", 10000000, 0.026, true)], commands: [tokenRow("sed", 89000000, 0.221)] });
const tokens = (o = {}) => ({ date: "2026-11-05", generated_at: 1793942659, stale: false, week: tokenSplit(18000000000), day: tokenSplit(3900000000), ...o });
const tail = (t) => { const f = run("cost"); f.open = {}; f.tokWin = "week"; return ctx.tokensSection({ tokens: t }); };

test("the tokens section starts open while fresh, with the week in its body", () => {
  const h = tail(tokens());
  assert.match(h, /<details class="csec" data-k="tokens" id="sec-tokens" open><summary><h2 class="sec">Where the tokens go<\/h2><\/summary><div class="panel scroll">/);
  assert.match(h, /7d: 18\.0B context, [^,]+, tool output carried 15%/);
  assert.match(h, /by tool/);
  assert.match(h, /by Bash command/);
  assert.match(h, /82\.3%/);
  assert.match(h, /href="#costs\?by=tool&w=7d"/);
});

test("a named row takes its chart slot and Other its grey", () => {
  const h = tail(tokens());
  assert.match(h, /background:var\(--c1\)/);
  assert.match(h, /background:var\(--c-other\)/);
  assert.doesNotMatch(h, /background:var\(--c2\)/);
});

test("a stale snapshot opens the section with an amber head, until the human shuts it", () => {
  const h = tail(tokens({ stale: true }));
  assert.match(h, /id="sec-tokens" open>/);
  assert.match(h, /<h2 class="sec warn">Where the tokens go<\/h2><\/summary><div class="cline warn">stale: newest snapshot 2026-11-05<\/div>/);
  run("cost").open.tokens = false;
  assert.doesNotMatch(ctx.tokensSection({ tokens: tokens({ stale: true }) }), /id="sec-tokens" open>/);
});

test("no snapshot is an amber head with nothing to open", () => {
  const h = tail(null);
  assert.match(h, /<h2 class="sec warn" id="sec-tokens">Where the tokens go<\/h2><div class="cline warn">no snapshot/);
  assert.doesNotMatch(h, /<details/);
});

test("the window switch picks yesterday, and a partial window says so", () => {
  const f = run("cost");
  tail(tokens());
  f.data = board({ tokens: tokens({ day: { ...tokenSplit(3900000000), days: 1, partial: 1 } }) });
  run("st.tab = 'costs'");
  fire("click", { target: { closest: (sel) => (sel === "[data-tokwin]" ? { dataset: { tokwin: "day" } } : null) } });
  assert.equal(f.tokWin, "day");
  const h = ctx.tokensSection(f.data);
  assert.match(box.innerHTML, /yesterday: 3\.9B context/, "the click repainted the tab");
  assert.match(h, /yesterday: 3\.9B context/);
  assert.match(h, /class="warn">, 1 of 1 partial/);
  f.tokWin = "week";
});

test("a stale day names its date, not yesterday", () => {
  const f = run("cost");
  f.open = {};
  f.tokWin = "day";
  const h = ctx.tokensSection({ tokens: tokens({ stale: true }) });
  assert.match(h, /2026-11-05: 3\.9B context/);
  assert.doesNotMatch(h, /yesterday: /);
  f.tokWin = "week";
});

test("the fold keeps what paint remembered, fresh or stale, under one key", () => {
  const f = run("cost");
  f.open = { tokens: true };
  assert.match(ctx.tokensSection({ tokens: tokens() }), /id="sec-tokens" open>/);
  f.open = { tokens: false };
  assert.doesNotMatch(ctx.tokensSection({ tokens: tokens() }), /id="sec-tokens" open>/);
  assert.doesNotMatch(ctx.tokensSection({ tokens: tokens({ stale: true }) }), /id="sec-tokens" open>/, "going stale does not undo the reader's fold");
  assert.match(ctx.tokensSection({ tokens: tokens({ stale: true }) }), /data-k="tokens" id="sec-tokens"><summary><h2 class="sec warn">/, "the folded head still wears amber");
  f.open = {};
});

// What Langfuse sees: the newest snapshot's `.langfuse`, open until the reader folds it.
const lfFigures = () => ({
  tools: [{ tool: "Bash", calls: 35243, p50_ms: 99, p95_ms: 17487, total_s: 224341 }],
  tool_executions: 38947, tool_errors: 854, tool_error_share: 0.0219, tool_error_classes: [{ name: "ShellError", n: 781 }],
  gateway_calls: 194, gateway_errors: 26, gateway_error_share: 0.134, gateway_error_classes: [{ name: "invalid_key", n: 16 }],
  gateway_cost_usd: 3.59, gateway_tokens: 2271863, gateway_models: [{ model: "claude-sonnet-5.5", calls: 33, errors: 0, cost_usd: 3.45 }], gateway_other_models: 14, truncated: false,
});
const lfTail = (t) => { const f = run("cost"); f.open = {}; return ctx.langfuseSection({ tokens: t }); };

test("the langfuse section starts open while it reads, with both error shares and the gateway's cost first in its body", () => {
  const h = lfTail(tokens({ langfuse: { figures: lfFigures(), why: null } }));
  assert.match(h, /id="sec-langfuse" open><summary><h2 class="sec">What Langfuse sees<\/h2><\/summary><div class="panel scroll"><div><b>tool errors<\/b> 2%, <b>gateway errors<\/b> 13%, <b>gateway cost<\/b> \$3\.59<\/div>/);
  assert.doesNotMatch(h, /cline warn/, "fresh, no warn line");
});

test("open, it draws the slowest tools, the error classes and the dearest models", () => {
  const f = run("cost");
  f.open = { langfuse: true };
  const h = ctx.langfuseSection({ tokens: tokens({ langfuse: { figures: lfFigures(), why: null } }) });
  assert.match(h, /<td>Bash<\/td><td class="n">35,243<\/td><td class="n">99ms<\/td><td class="n">17\.5s<\/td>/);
  assert.match(h, /854 of 38,947 executions \(ShellError 781\)/);
  assert.match(h, /194 calls, 26 errors \(invalid_key 16\)/);
  assert.match(h, /claude-sonnet-5\.5 \$3\.45, 14 more/);
  f.open = {};
});

test("no figures is an amber head that says why; a stale snapshot is amber too; a fold the reader closed stays closed", () => {
  const none = lfTail(tokens({ langfuse: { figures: null, why: "no key (rbw langfuse-api)" } }));
  assert.match(none, /data-k="langfuse" id="sec-langfuse" open>/);
  assert.match(none, /<h2 class="sec warn">What Langfuse sees<\/h2><\/summary><div class="cline warn">no figures in snapshot 2026-11-05<\/div>/);
  assert.match(none, /no key \(rbw langfuse-api\)/);
  const stale = lfTail(tokens({ stale: true, langfuse: { figures: lfFigures(), why: null } }));
  assert.match(stale, /data-k="langfuse" id="sec-langfuse" open>/);
  assert.match(stale, /<h2 class="sec warn">What Langfuse sees<\/h2><\/summary><div class="cline warn">stale: newest snapshot 2026-11-05<\/div>/);
  const f = run("cost");
  f.open = { langfuse: false };
  assert.match(ctx.langfuseSection({ tokens: tokens({ stale: true, langfuse: { figures: lfFigures(), why: null } }) }), /data-k="langfuse" id="sec-langfuse"><summary>/);
  f.open = {};
});

test("a snapshot from before the reader has no langfuse key and still draws the amber head", () => {
  assert.match(lfTail(tokens()), /no figures in snapshot/);
  assert.equal(ctx.langfuseSection({ tokens: null }), "");
});

test("the fleet figure is Spend's first tile; who spent it is a table under a plain title; every % is of the fleet", () => {
  const fleet_cost = { why: null, usd: "about $849", measured: "$310", estimated: "$538", as_of: 1700000000, stale: false,
    coverage: "71% of tokens estimated: 280 of 458 sessions have no cost telemetry",
    rows: [
      { name: "queue items", usd: 260, cost: "$260", share: "31%", basis: "30 sessions, $214 measured, $46 estimated", detail: null },
      { name: "shepherd", usd: 44, cost: "$44", share: "5%", basis: "61 sessions, measured", detail: null },
      { name: "other runners", usd: 30, cost: "$30", share: "4%", basis: "139 sessions, estimated", detail: "ask-judge $6.40, briefing $2.90" },
      { name: "lazer-reserve", usd: null, cost: "-", share: "-", basis: "1 session, no price known", detail: null },
    ],
    unpriced: ["claude-sonnet-4-6: 32M tokens in 3 sessions not in the total, no billed sessions"],
    foot: "% is of the whole fleet's 24h cost. \"estimated\" is priced from tokens." };
  const h = show(board({ fleet_cost }));
  assert.ok(h.indexOf("FLEET 24H") < h.indexOf("SPEND 24H") && h.indexOf("sec-fleet") < h.indexOf("sec-burn"), "the whole figure is the first answer");
  assert.match(h, /<span class="tl">FLEET 24H<\/span><span class="tv">about \$849<\/span><span class="ts1">whole fleet, measured \$310, estimated \$538, as of /, "a shared tile");
  assert.match(h, /<h2 class="sec" id="sec-fleet">Who spent the 24h <span class="n">4<\/span><\/h2>/, "a row count, no figure, in the title");
  assert.match(h, /<th class="n" data-role="glance">% of fleet<\/th>/);
  assert.match(h, /<tr><td>shepherd<\/td><td class="n">\$44<\/td><td class="n">5%<\/td><td class="muted">61 sessions, measured<\/td><\/tr>/);
  assert.match(h, /colspan="3" class="muted wrap">ask-judge \$6\.40, briefing \$2\.90/, "every runner is reachable");
  assert.match(h, /<tr><td>lazer-reserve<\/td><td class="n">-<\/td>/, "nothing priced is unknown, never $0");
  assert.match(h, /not in the total/);
  assert.match(h, /<th data-role="lead">who<\/th>/, "the table folds to a phone row");
  assert.doesNotMatch(h.slice(h.indexOf('id="sec-fleet"'), h.indexOf("</tr>", h.indexOf('id="sec-fleet"'))), /<th(?![^>]*data-role)/, "no column waits for a tap, so estimated stays on screen");
  assert.match(show(board({ fleet_cost: { ...fleet_cost, stale: true } })), /class="warn">stale, as of /);
  // negative control: nothing read says so, never a $0 table
  const none = show(board({ fleet_cost: { why: "nothing read: no file", rows: [] } }));
  assert.match(none, /FLEET 24H<\/span><span class="tv">-<\/span><span class="ts1"><span class="warn">nothing read: no file/);
  assert.doesNotMatch(none, /id="sec-fleet"/, "no table to show");
  assert.doesNotMatch(none, /% of fleet/);
});

test("spend: the 30-day chart and month bars, period rows with $/session, and burn per session last with no chips, search or dropdowns", async () => {
  const p = (kind, period, total, days, per_day, per_session, vs_prev, est) => ({ kind, period, total, days, per_day, per_session, vs_prev, est });
  const bar = (key, usd, measured, estimated) => ({ key, label: key.slice(5), usd, measured, estimated, tip: usd == null ? `${key}: no figure` : `${key}: $${usd}` });
  const chart = [bar("2026-11-07", 30, 20, 10), bar("2026-11-08", null, 0, 0), bar("2026-11-09", 100, 60, 40)];
  const history = { why: null, month: "Nov $1,579/day vs Oct $1,102/day (+43%)", last_day: "11-09 $1,312 vs 7d median $1,120 (+17%)",
    rows: [p("year", "2026", "$61,300", 54, "$1,135", "$2.40", "-", "38%"), p("month", "2026-11", "$14,210", 9, "$1,579", "$2.51", "+43%", "21%"),
      p("day", "11-09", "$1,312", 1, "$1,312", "-", "+69%", "21%")],
    older: 3, missing: 2, stale: false, note: "est. is the share priced from tokens", chart, months: [bar("2026-11", 130, 80, 50)] };
  const srow = (sid, session, cost) => ({ sid, session, project: "dotfiles", origin: "runner", agent: null, harness: "claude", cost, share: cost, est: 0, days: 2 });
  const day = { day: "2026-11-09", head: "2026-11-09: 2 sessions, $95 of the day's $100", why: null, rows: [srow("c", "big run", 90), srow("b", "shepherd", 5)], more: 0, shown_usd: "$95",
    table: { q: "", state: "", sort: "", dir: "desc", total: 2, shown: 2, states: [], columns: ["session", "project", "origin", "agent", "harness", "cost", "share", "est", "days"].map((k) => col(k)), facets: [] },
    series: { sid: "b", session: "shepherd", total: "$15", bars: [bar("2026-11-07", 10, 10, 0), bar("2026-11-08", null, 0, 0), bar("2026-11-09", 5, 5, 0)] } };
  const h = show(board({ history, day }));
  assert.ok(h.indexOf("sec-totals") < h.indexOf("sec-spend") && h.indexOf("sec-spend") < h.indexOf('id="sec-table"') && h.indexOf('id="sec-table"') < h.indexOf("sec-sessions"), "the tiles, the chart, the table, then burn per session last");
  assert.match(h, /<details class="csec" data-k="spend" id="sec-spend" open><summary><h2 class="sec">Spend<\/h2><\/summary>/, "open until the reader folds it");
  assert.match(h, /<div><span class="muted">MONTH<\/span> Nov \$1,579\/day vs Oct \$1,102\/day \(\+43%\)<\/div><div><span class="muted">LAST DAY<\/span> 11-09 \$1,312 vs 7d median \$1,120 \(\+17%\)<\/div>/, "the headline is two facts in the chart's box");
  const days = h.slice(h.indexOf('id="spend-days"'), h.indexOf("By month"));
  assert.match(days, /class="cc sel" data-key="2026-11-09"/, "the picked day is marked");
  assert.match(days, /data-key="2026-11-08" data-tip="2026-11-08: no figure"><div class="cs"><\/div>/, "a day with no figure is an empty column, never a $0 bar");
  assert.match(days, /height:60%;background:var\(--c1\)"><\/i><i style="height:40%;background:var\(--c-other\)/, "billed under estimated");
  assert.match(h, /By month<\/h3>.*data-key="2026-11"/s);
  assert.match(h, /id="sec-sessions" open><summary><h2 class="sec">Burn per session <span class="n">2<\/span><\/h2><\/summary>/);
  assert.match(h, /<div><span class="muted">DAY<\/span> 2026-11-09: 2 sessions, \$95 of the day&#39;s \$100<\/div>/, "the day's figure is a fact under its head");
  // negative control on the cleanup: no day chips, no search box, no facet dropdowns
  const sess = h.slice(h.indexOf('id="sec-sessions"'));
  assert.doesNotMatch(h, /data-cv="day"/, "no day chips: the chart picks the day");
  assert.doesNotMatch(h, /spend-dq|data-dq/, "no search box");
  assert.doesNotMatch(sess, /tfacet|<select/, "no dropdowns over the sessions");
  assert.ok(h.indexOf("big run") < h.indexOf('<tr data-sid="b"'), "the server's ranking is kept");
  assert.match(h, /<tr data-sid="b" class="sel">/, "the opened session's row is marked");
  assert.match(h, /data-tbl="d">[\s\S]*data-tsort="cost"/, "the day table sorts in its own block, on its own keys");
  assert.match(h, /shepherd <span class="muted">\$15 in the chart's 30 days/);
  assert.ok(h.indexOf("Year, month and day rows") < h.indexOf("Burn per session"), "the period rows come before the day's sessions");
  assert.match(h, /data-named title="what one session cost on an average day">\$\/session<\/th>/, "one $/session column");
  assert.match(h, /<tr class="allrow"><td>2026-11<\/td><td class="n">\$14,210<\/td><td class="n">9<\/td><td class="n">\$1,579<\/td><td class="n">\$2\.51<\/td><td class="n">\+43%<\/td><td class="n">21%<\/td><\/tr>/);
  assert.match(h, /<td>11-09<\/td><td class="n">\$1,312<\/td><td class="n">1<\/td><td class="n">\$1,312<\/td><td class="n">-<\/td>/, "a day with no session rows is -, never $0");
  assert.match(h, /\+3 older/);
  assert.match(h, /2 days in the range have no figure and are not counted/);
  assert.match(show(board({ history: { ...history, stale: true }, day })), /<h2 class="sec warn">Spend<\/h2><\/summary><div class="cline warn">stale: no snapshot for yesterday<\/div>/);
  // a click on a day or a row is the day or sid key in the URL and the request
  asked = [];
  body = board({ history, day });
  run("st.tab = 'costs'; st.views.costs = ''");
  const at = (sel, data) => ({ dataset: data, closest: (q) => (q === sel ? { dataset: data } : null) });
  const dayBar = { dataset: { key: "2026-11-07" }, closest: (q) => (q === "#spend-days" || q.includes("#spend-days [data-key]") ? dayBar : null) };
  fire("click", { type: "click", target: dayBar });
  assert.equal(run("st.section"), "sessions", "a chart click scrolls to the day's sessions, Spend's last section");
  await tick();
  assert.equal(ctx.history.url, "#costs?day=2026-11-07");
  assert.match(asked.at(-1), /day=2026-11-07/);
  fire("click", { type: "click", target: at("tr[data-sid]", { sid: "c" }) });
  await tick();
  assert.equal(ctx.history.url, "#costs?day=2026-11-07&sid=c");
  fire("click", { type: "click", target: at("tr[data-sid]", { sid: "c" }) });
  await tick();
  assert.doesNotMatch(ctx.history.url, /sid=c/, "the open row again closes it");
  // negative control: no snapshot says so, never a $0 chart
  const none = show(board({ history: { why: "no snapshot with a fleet figure yet", rows: [] } }));
  assert.match(none, /id="sec-spend"><h2 class="sec">Spend<\/h2><div class="panel muted">no snapshot with a fleet figure yet/);
  assert.doesNotMatch(none, /spend-days/);
});

// Inner tabs: the five behaviours of fleet-platform's device-tabs.test.ts, over hub_core::layout's groups.
const innerOn = (arg) => { run(`st.arg = ${JSON.stringify(arg)}; st.section = null`); return show(board()); };
const shown = (h, id) => !new RegExp(`data-in="${id}" hidden`).test(h) && new RegExp(`data-in="${id}"`).test(h);

test("a URL that names an inner tab opens it, and the others stay hidden", () => {
  assert.equal(ctx.route("#costs/models").arg, "models");
  const h = innerOn("models");
  assert.ok(shown(h, "models") && !shown(h, "spend") && !shown(h, "limits"));
  assert.match(h, /data-itab="models" class="on" aria-selected="true"/);
  assert.match(h, /data-itab="spend" class="" aria-selected="false"/);
});

test("a missing or unknown inner tab opens Spend, and the fleet figure shows on no other inner tab", () => {
  for (const hash of ["#costs", "#costs/nonsense"]) assert.equal(ctx.route(hash).arg, "", hash);
  const fleet = ctx.route("#costs/fleet");
  assert.deepEqual([fleet.arg, fleet.section], ["spend", "fleet"], "the old fleet link opens Spend at the table");
  run("st.arg = ''; st.section = null");
  const h = show(board({ fleet_cost: { why: null, usd: "$9", measured: "$9", estimated: "$0", as_of: 1700000000, stale: false, coverage: "", rows: [], unpriced: [], foot: "" } }));
  assert.ok(shown(h, "spend") && !shown(h, "limits") && !shown(h, "models"));
  const groupOf = (needle) => { const at = h.indexOf(needle); return h.slice(h.lastIndexOf("data-in=", at), at).match(/data-in="([a-z]+)"/)[1]; };
  assert.equal(groupOf("FLEET 24H"), "spend", "the tile is in Spend's group");
  assert.equal(groupOf('id="sec-fleet"'), "spend", "the table is in Spend's group");
  // the control: Limits hides Spend's group, and with it every fleet figure
  const lim = innerOn("limits");
  assert.ok(shown(lim, "limits") && !shown(lim, "spend"));
});

test("the strip is the first element of the page, on every inner tab", () => {
  for (const arg of ["", "spend", "models"]) assert.match(innerOn(arg), /^<div id="costs-head"><div class="seg fseg istrip" role="tablist">/, arg || "first");
});

test("an old section link opens the inner tab that holds the section, and still scrolls to it", () => {
  const burn = ctx.route("#costs/burn");
  assert.deepEqual([burn.arg, burn.section], ["limits", "burn"]);
  const tok = ctx.route("#costs/TOKENS");
  assert.deepEqual([tok.arg, tok.section], ["models", "tokens"]);
  const moved = ctx.route("#fleet/tokens");
  assert.deepEqual([moved.tab, moved.arg, moved.section], ["costs", "models", "tokens"]);
  assert.equal(ctx.route("#fleet/accounts").arg, "limits");
  // an inner id that is also a section id (spend) is the inner tab holding it
  assert.equal(ctx.route("#costs/spend").arg, "spend");
});

test("a count shows beside an inner tab only when above zero", () => {
  const strip = (amber) => { run("st.arg = ''"); return run(`innerStrip("costs", ${JSON.stringify(amber)})`); };
  assert.doesNotMatch(strip([]), /pill/);
  assert.doesNotMatch(run(`innerStrip("costs")`), /pill/);
  const h = strip(["burn", "tokens", "langfuse"]);
  assert.match(h, />Limits <span class="pill warn">1<\/span>/);
  assert.match(h, />Models <span class="pill warn">2<\/span>/);
  assert.doesNotMatch(h, />Spend <span/);
});

test("a link can name an inner tab and a section on another one, and the page switches", () => {
  innerOn("limits");
  run("st.tab = 'costs'; st.section = 'langfuse'");
  run("seekSection()");
  assert.equal(run("st.arg"), "models", "a section on a hidden inner tab opens its tab first");
  run("st.section = null; st.arg = ''");
});

test("switching an inner tab flips the groups in place, with no repaint", () => {
  const mk = (id) => ({ dataset: { in: id }, hidden: id !== "limits" });
  const groups = ["limits", "spend", "models"].map(mk);
  const btn = (id) => ({ dataset: { itab: id }, classList: { toggle() {} }, setAttribute() {}, tabIndex: 0 });
  const board = { querySelectorAll: (q) => (q === "[data-in]" ? groups : q === "[data-itab]" ? ["limits", "spend", "models"].map(btn) : []) };
  const prev = doc.getElementById;
  doc.getElementById = (id) => (id === "costs" ? Object.assign(box, board) : prev(id));
  run("st.tab = 'costs'");
  run("innerGo('costs', 'models')");
  doc.getElementById = prev;
  assert.deepEqual(groups.map((g) => g.hidden), [true, true, false]);
  assert.equal(run("st.arg"), "models");
});

test("a tab button brings back the inner tab that tab last showed; a link without one opens the first", () => {
  run("lastInner.costs = 'models'");
  run("setTab('costs')");
  assert.equal(run("st.arg"), "models");
  run("setTab('costs', '')");
  assert.equal(run("st.arg"), "", "a link to #costs names no inner tab");
  run("setTab('costs')");
  assert.equal(run("st.arg"), "", "and that is what the button brings back");
  run("setTab('fleet')");
  assert.equal(run("st.arg"), "", "a tab with no inner tabs keeps no memory");
});

test("the Budget inner tab is this month's cash: head, what needs a look, the bills grouped agents, CI, infra, the split", () => {
  const budget = { why: null, month: "Nov, day 11 of 30", spent: "$838", projected: "~$1,304", caps: "$1,445", partial: [], as_of: 1700000000, stale: false,
    needs: ["lazer over its $50 cap ($228), paid by lazer, not in our total"],
    groups: [
      { id: "agents", name: "Agents", spent: "$200", month: "~$200", bills: [
        { name: "lazer", kind: "litellm", cap: "$50", spent: "$228", month: "$228", note: "over, paid by lazer, not in our total", status: "over" },
        { name: "max4", kind: "subscription", cap: "$200", spent: "$200", month: "$200", note: "$1,126 list work (6x)", status: "ok" },
      ] },
      { id: "ci", name: "CI", spent: "$113", month: "~$380", bills: [
        { name: "aws", kind: "aws", cap: "$600", spent: "$113", month: "$380", note: "AWS's own forecast", status: "ok" },
      ] },
    ],
    by_lane: ["Agents: queue $175", "CI: ci $141"],
    by_project: [{ name: "unity-core-playground", usd: "$334" }, { name: "unattributed", usd: "$91" }],
    foot: "Cash: what we pay, not list price." };
  assert.equal(ctx.route("#costs/budget").arg, "budget", "the Infra Cloud card's link lands here");
  run("st.arg = 'budget'; st.section = null");
  const h = show(board({ budget }));
  assert.ok(shown(h, "budget") && !shown(h, "limits"));
  const b = h.slice(h.indexOf('id="sec-budget"'));
  assert.match(b, /^id="sec-budget">Budget<\/h2><div class="panel scroll"><div><b>So far<\/b> \$838, <b>by month end<\/b> ~\$1,304, <b>month<\/b> Nov, day 11 of 30, <b>caps<\/b> \$1,445, <b>as of<\/b> /);
  assert.ok(b.indexOf("Needs a look 1") < b.indexOf("<table"), "what needs a look leads the bills");
  assert.match(b, /<tr><td class="warn">lazer<\/td><td class="muted">litellm<\/td><td class="n">\$50<\/td><td class="n warn">\$228<\/td>/, "a bill over its cap is amber");
  assert.match(b, /<tr><td class="">max4<\/td>.*<td class="n ">\$200<\/td>/, "an ok bill is not amber");
  assert.match(b, /<b>By project<\/b> unity-core-playground \$334, unattributed \$91/);
  assert.match(b, /<tr class="allrow"><td>Agents<\/td><td><\/td><td><\/td><td class="n">\$200<\/td>/, "a group heads its bills with our cash");
  assert.ok(b.indexOf(">Agents<") < b.indexOf(">max4<") && b.indexOf(">max4<") < b.indexOf(">CI<") && b.indexOf(">CI<") < b.indexOf(">aws<"), "each bill sits under its group");
  assert.match(b, /<b>By lane<\/b> Agents: queue \$175, CI: ci \$141/);
  assert.match(b, /<th data-role="lead">bill<\/th>/, "the table folds to a phone row");
  assert.doesNotMatch(b, /of \$\d[\d,]*\/mo/, "no list price shown as a share of a fee");
  assert.match(show(board({ budget: { ...budget, stale: true } })), /<h2 class="sec warn" id="sec-budget">Budget<\/h2><div class="cline warn">stale, as of /);
  // negative control: no file says so, never a $0 table
  const none = show(board({ budget: { why: "no budget file: the fleet-bench budget step has not run" } }));
  assert.match(none, /<h2 class="sec warn" id="sec-budget">Budget<\/h2><div class="panel"><span class="warn">no budget file/);
  run("st.arg = ''");
});

test("every Costs section is drawn in the layout's order, so each inner tab's group reads top to bottom", () => {
  run("st.arg = ''; st.section = null; cost.open = {}");
  const fleet_cost = { why: null, usd: "$9", measured: "$9", estimated: "$0", as_of: 1700000000, stale: false, coverage: "", rows: [], unpriced: [], foot: "" };
  const h = show(board({ fleet_cost, tokens: tokens({ langfuse: { figures: lfFigures(), why: null } }) }));
  const order = JSON.parse(run("JSON.stringify(INNER_TABS.costs.tabs.flatMap((t) => t[2]))"));
  const drawn = order.filter((id) => h.includes(`id="sec-${id}"`));
  assert.ok(drawn.length >= 6, `most sections drawn: ${drawn}`);
  const at = drawn.map((id) => h.indexOf(`id="sec-${id}"`));
  assert.deepEqual(at, [...at].sort((a, b) => a - b), `DOM order ${drawn} at ${at}`);
});
