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
const box = Object.assign(part(), { addEventListener: (ev, f) => { on[ev] = f; } });
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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "actions.js", "table.js", "costs.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
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
const acct = (name, o) => ({ name, state: "ok", room: { ok: true, reasons: [], headroom: 4.2 }, live: 0, used: 10, gone: 5, burn: 1, sustain: 2, over: 0.5, idle_at: 1794003600, burn_at: null, run_out: null, resets: 1794200000, ...o });
const burn = (o = {}) => ({
  at: 1794000000, level: "bad", head: "4.5 pts/h vs 1.4 sustainable, 3.3x OVER, 39 live, carries ~11", drip_line: "15 started in 1h, 349 in 24h",
  accounts: [acct("alt", { live: 9, used: 55, gone: 25, burn: 1.04, sustain: 0.36 }), acct("bnb", { live: 17, used: 7, gone: 1, burn: 1.97, sustain: 0.56 }), acct("main", { live: 13, used: 33, gone: 12, burn: 1.51, sustain: 0.45, burn_at: 1794000600 })],
  fleet: { live: 39, burn: 4.52, sustain: 1.37, over: 3.3, rate: 0.116, carries: 11 },
  drip: { hour: 15, day: 349, held: "fleet-assess says HOLD" },
  pace: { on_pace: false, at_burn: [["main", 1794000600]], idle_all_by: 1794003600, idle_rest_after_reset: false }, ...o,
});
const board = (o = {}) => ({
  at: 1794000000, by: "model", window: "7d",
  cuts: ["session", "model", "harness", "tool", "project", "runner", "kind"], windows: ["24h", "7d", "30d"],
  totals: [{ window: "24h", usd: 12.5, sessions: 3, unpriced: 0 }, { window: "7d", usd: 40, sessions: 9, unpriced: 2 }, { window: "30d", usd: 90, sessions: 20, unpriced: 2 }],
  live: { claude_24h: 11, lazer_spend: 50, lazer_budget: 250, reserve_spend: 19.52, reserve_budget: 100, reserve_reset_hours: 575 },
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
const show = (d) => { run("st.tab = 'costs'"); Object.assign(cost, { data: d, err: null }); run("renderCosts()"); return box.innerHTML; };
const target = (attrs) => ({ dataset: attrs, closest: (sel) => (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) || (sel === "[data-cv]" && "cv" in attrs) || (sel === "[data-ssort]" && "ssort" in attrs) ? { dataset: attrs } : null });

test("the model cut draws the server's columns, order and sort, with its evaluation", () => {
  const h = show(board());
  for (const k of ["model", "harness", "sess", "tokens", "landed", "redo", "rev", "\\$/PR", "src"]) assert.match(h, new RegExp(`>${k}</button></th>`), `header ${k}`);
  assert.doesNotMatch(h, /data-tsort="runner"/, "a column the cut does not name is not drawn");
  const heads = [...h.matchAll(/title="sort by ([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(heads.slice(0, 2), ["model", "harness"], "the header is in the cut's order, as the cells are");
  assert.match(h, /aria-sort="ascending"><button class="thsort" data-tsort="" data-tdir="desc" title="sort by cost">cost \^/, "the sorted header says its direction");
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
  assert.match(h, /LAZER POOL[\s\S]*of \$250 \(20%\)/);
  assert.match(h, /LAZER RESERVE<\/span><span class="tv">\$19\.52<\/span><span class="ts1">of \$100 \(20%\), 24d left</);
  assert.match(h, /LAZER DIRECT<\/span><span class="tv">\$1\.25<\/span><span class="ts1"><span class="warn">\+1 unpriced<\/span>, opencode lazer\/\*, nightly; other direct use unseen</);
  assert.match(h, /<span class="warn">token snapshot /, "a stale source is amber");
  assert.match(h, /<span class="warn">calls never<\/span>/);
  assert.match(h, /<span class="muted">outcomes /);
});

test("with no gauges and no direct rows the Lazer tiles say unknown, never $0 or blank", () => {
  const h = show(board({ live: {}, direct: undefined }));
  assert.match(h, /LAZER RESERVE<\/span><span class="tv">-<\/span><\/div>/, "no gauge is unknown");
  const reset = show(board({ live: { reserve_reset_hours: 48 } }));
  assert.match(reset, /LAZER RESERVE<\/span><span class="tv">-<\/span><span class="ts1">2d left</, "no cap, so no leading comma");
  assert.match(h, /LAZER DIRECT<\/span><span class="tv">-<\/span><span class="ts1">not read</, "no direct figure says so");
  assert.doesNotMatch(h, /unpriced<\/span>, /);
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
  on.click({ type: "click", target: target({ cv: "w", cval: "24h" }) });
  await tick();
  assert.equal(ctx.history.url, "#costs?q=harness%3Acodex&sort=cost&dir=asc&w=24h", "a window keeps the query and sort");
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&dir=asc&w=24h");
  on.click({ type: "click", target: target({ cv: "by", cval: "runner" }) });
  await tick();
  assert.equal(ctx.history.url, "#costs?q=harness%3Acodex&w=24h&by=runner", "a new cut drops the old cut's sort");
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&by=runner&w=24h");
  on.click({ type: "click", target: target({ tsort: "cost", tdir: "asc" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&dir=asc&by=runner&w=24h");
  on.input({ type: "input", target: { ...target({ tsearch: "" }), value: "-model:opus" } });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=-model%3Aopus&sort=cost&dir=asc&by=runner&w=24h");
});

test("a failed read says why instead of drawing an empty table", () => {
  run("st.tab = 'costs'");
  Object.assign(cost, { data: null, err: "502 bad gateway" });
  run("renderCosts()");
  assert.match(box.innerHTML, /<div class="empty">502 bad gateway<\/div>/);
});

test("the burn section leads the tab: headline, drip with its hold link, pace and a row per account", () => {
  const h = show(board());
  assert.ok(h.indexOf("sec-burn") < h.indexOf("sec-totals"), "burn is above the spend tiles");
  assert.match(h, /<span class="burn bad">4\.5 pts\/h vs 1\.4 sustainable, 3\.3x OVER, 39 live, carries ~11<\/span>/);
  assert.match(h, /<details class="csec" data-k="burn" id="sec-burn" open>/, "red starts open");
  assert.match(h, /15 started in 1h, 349 in 24h <a class="warn" href="#sessions" title="fleet-assess says HOLD">dispatch held -> Sessions<\/a>/);
  assert.match(h, /at this burn: main [^;]+; if idle: all by /);
  assert.match(h, /<td>bnb<\/td><td class="n">17<\/td><td class="n">7%<\/td><td class="n">1%<\/td><td class="ok">room, 4 points spare<\/td><td class="n warn">1\.97<\/td><td class="n">0\.56<\/td><td>after reset<\/td>/, "an account over its sustainable rate is amber; burn that never gets there is after the reset");
  assert.doesNotMatch(h, /<td class="n warn">0\.45/, "keeps/h is never amber");
});

test("a green burn folds to its headline, and a fold the reader set is kept", () => {
  const ok = board({ burn: burn({ level: "ok", head: "0.5 pts/h vs 1.4 sustainable, 0.4x, 5 live" }) });
  assert.match(show(ok), /<details class="csec" data-k="burn" id="sec-burn"><summary>/, "green starts folded");
  cost.open.burn = true;
  assert.match(show(ok), /data-k="burn" id="sec-burn" open>/, "the reader's open wins");
  cost.open = {};
});

test("an account claude-acct could not read is named, and no data says so", () => {
  const b = burn({ accounts: [acct("old", { state: "unreadable" }), acct("new", { state: "idle" })] });
  const h = show(board({ burn: b }));
  assert.match(h, /<td>old<\/td><td colspan="10" class="bad">usage unreadable<\/td>/);
  assert.match(h, /<td>new<\/td><td colspan="10" class="muted">idle, token refreshes on launch<\/td>/);
  assert.match(show(board({ burn: burn({ accounts: [] }) })), /<div class="panel muted">no data from claude-acct<\/div>/);
});

test("the room column prints claude-acct's verdict: points past the line, the reserve, a stale textfile", () => {
  const room = (o) => ({ ok: false, reasons: ["pace"], headroom: -19.5, ...o });
  const b = burn({ accounts: [
    acct("a", { room: room({}) }),
    acct("b", { room: room({ reasons: ["reserve", "five_hour"], headroom: 3 }) }),
    acct("c", { state: "stale" }),
    acct("d", { room: null }),
  ] });
  const h = show(board({ burn: b }));
  assert.match(h, /<td class="bad">no room: pace 20 points past the line<\/td>/);
  assert.match(h, /<td class="bad">no room: reserve, five hour<\/td>/);
  assert.match(h, /<td>c<\/td><td colspan="10" class="bad">stale, claude-acct's textfile is over an hour old<\/td>/);
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

test("the Sections block is folded to its headline, with All PRs on top and both caveats", () => {
  const h = show(board({ sections: sections() }));
  assert.match(h, /<details class="csec" data-k="sections" id="sec-sections"><summary><h2 class="sec">Sections <span class="muted">598 PRs in 7d, 52% first try/, "folded, headline in the summary");
  for (const k of ["section", "PRs", "first try", "gate reds/PR", "gate min/PR", "gate h", "greens lost", "cost/PR", "tokens/PR", "work min/PR"]) assert.match(h, new RegExp(`title="sort by ${k.replace("/", "\\/")}"`), `header ${k}`);
  assert.match(h, /data-ssort="prs" data-sdir="desc"/, "its headers sort apart from the main table's");
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
  on.click({ type: "click", target: target({ ssort: "gate_h", sdir: "desc" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&ssort=gate_h");
  on.click({ type: "click", target: target({ ssort: "gate_h", sdir: "asc" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&ssort=gate_h&sdir=asc");
  on.click({ type: "click", target: target({ ssort: "", sdir: "desc" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost", "the third click is the default order");
});

test("no Sections data draws no block", () => {
  assert.doesNotMatch(show(board()), /sec-sections/);
  assert.doesNotMatch(show(board({ sections: { days: 7, head: "", columns: SEC_KEYS, headers: [], all: [], rows: [], notes: [], table: null } })), /sec-sections/);
});

test("a Sections fold the reader opened stays open through the repaint a sort click causes", () => {
  run("st.tab = 'costs'");
  Object.assign(cost, { open: {} });
  const d = board({ sections: sections() });
  assert.doesNotMatch(show(d), /id="sec-sections" open/, "starts folded");
  box.querySelectorAll = () => [{ dataset: { k: "sections" }, open: true }];
  run("renderCosts()");
  assert.match(box.innerHTML, /id="sec-sections" open/, "the reader's open survives the repaint");
  box.querySelectorAll = () => [{ dataset: { k: "sections" }, open: false }];
  run("renderCosts()");
  assert.doesNotMatch(box.innerHTML, /id="sec-sections" open/, "and so does a fold they closed");
  box.querySelectorAll = () => [];
});
