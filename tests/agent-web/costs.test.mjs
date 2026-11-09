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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "table.js", "actions.js", "costs.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
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

test("the keys fold under their pool, and only a key refusing on its own starts open", () => {
  const key = acct("glm", { kind: "litellm-key", unpaced: true, used: 96, used_text: "96% $48/$50", gone: null, reserve: 15, parent: "lazer", nested: true });
  const pool = acct("lazer", { kind: "litellm-team", unpaced: true, used: 90, used_text: "90% $226/$250", gone: null });
  const paced = acct("alt", { used: 80, gone: 64 });
  const page = (level) => show(board({ burn: burn({ accounts: [paced, pool, key], keys: { head: "1 in lazer, 0 live, tightest glm 96%", level } }) }));
  const quiet = page("ok");
  assert.match(quiet, /<details class="cfold" data-k="burn-keys"><summary>KEYS <span class="muted">1 in lazer, 0 live, tightest glm 96%/, "closed by default");
  assert.ok(quiet.indexOf("<td>lazer</td>") < quiet.indexOf('data-k="burn-keys"'), "the fold is under the pool");
  assert.equal([...quiet.matchAll(/<td>glm<\/td>/g)].length, 1, "the key is listed once, in the fold");
  assert.ok(quiet.indexOf("<td>glm</td>") > quiet.indexOf('data-k="burn-keys"'));
  assert.match(quiet, /<tr><th>source<\/th><th class="n">live<\/th><th>bar<\/th><th class="n">used<\/th><th class="n">reserve<\/th><th>room<\/th><th>resets<\/th><th class="n">24h<\/th><\/tr>/);
  assert.match(quiet, /<td>alt<\/td>.*?width:80\.0%[^>]*><\/span><i style="left:min\(64\.0%,calc\(100% - 2px\)\)"><\/i>/, "a paced row has its tick, held inside the box");
  assert.doesNotMatch(quiet, /<td>glm<\/td>.*?<i style/, "a dollar budget has none");
  // negative control: the same key with a warn level opens, under the key paint has not remembered
  assert.match(page("warn"), /<details class="cfold" data-k="burn-keys-warn" open><summary>KEYS <span class="warn">/);
  cost.open["burn-keys"] = true;
  assert.match(page("ok"), /data-k="burn-keys" open>/, "the reader's open wins");
  delete cost.open["burn-keys"];
  delete cost.open["burn-keys-warn"];
});

test("a dollar source is a burn row with its kind, dollars and reserve, and no pace cells", () => {
  const key = acct("reserve", { kind: "litellm-key", unpaced: true, used: 41, used_text: "41% $41/$100", gone: null, reserve: 15, parent: "lazer", burn: 9, sustain: 1, idle_at: null, resets: null });
  const h = show(board({ burn: burn({ accounts: [acct("main", { reserve: 15 }), key] }) }));
  assert.match(h, /<tr><th>source<\/th><th>kind<\/th><th class="n">live<\/th><th>bar<\/th><th class="n">used<\/th><th class="n">gone<\/th><th class="n">reserve<\/th><th>room<\/th>/);
  assert.match(h, /<th class="n">24h<\/th><\/tr>/, "the pool column is gone: a key nests under its pool");
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
  assert.ok(h.indexOf("sec-burn") < h.indexOf("sec-totals"), "burn is above the spend tiles");
  assert.match(h, /<span class="burn bad">4\.5 pts\/h vs 1\.4 sustainable, 3\.3x OVER, 39 live, carries ~11<\/span>/);
  assert.match(h, /<details class="csec" data-k="burn" id="sec-burn" open>/, "red starts open");
  assert.match(h, /15 started in 1h, 349 in 24h <a class="warn" href="#sessions" title="fleet-assess says HOLD">dispatch held -> Sessions<\/a>/);
  assert.match(h, /at this burn: main [^;]+; if idle: all by /);
  assert.match(h, /<td>bnb<\/td><td>claude<\/td><td class="n">17<\/td><td>.*?<\/td><td class="n">7%<\/td><td class="n">1%<\/td><td class="n">-<\/td><td class="ok">room, 4 points spare<\/td><td class="n warn">1\.97<\/td><td class="n">0\.56<\/td><td>after reset<\/td>/, "an account over its sustainable rate is amber; burn that never gets there is after the reset");
  assert.doesNotMatch(h, /<td class="n warn">0\.45/, "keeps/h is never amber");
  assert.match(h, /<div class="muted fold">pts\/h: points of a weekly limit an hour; gone: the share of the week gone<\/div>/, "the terms come from hub-core's one legend");
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
  fire("click", { type: "click", target: target({ ssort: "gate_h", sdir: "desc" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&ssort=gate_h");
  fire("click", { type: "click", target: target({ ssort: "gate_h", sdir: "asc" }) });
  await tick();
  assert.equal(asked.at(-1), "/api/costs?q=harness%3Acodex&sort=cost&ssort=gate_h&sdir=asc");
  fire("click", { type: "click", target: target({ ssort: "", sdir: "desc" }) });
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
  run("cost.render()");
  assert.match(box.innerHTML, /id="sec-sections" open/, "the reader's open survives the repaint");
  box.querySelectorAll = () => [{ dataset: { k: "sections" }, open: false }];
  run("cost.render()");
  assert.doesNotMatch(box.innerHTML, /id="sec-sections" open/, "and so does a fold they closed");
  box.querySelectorAll = () => [];
});

test("a burn row carries the 5h window, when it resets and the day's dollars", () => {
  const h = show(board({ burn: burn({ accounts: [acct("main", { five_hour: 61.4, five_hour_resets: 1794007200, cost_24h: 12.5 }), acct("alt", { state: "idle" })] }) }));
  assert.match(h, /<th>resets<\/th><th class="n">5h<\/th><th>5h resets<\/th><th class="n">24h<\/th><\/tr>/);
  assert.match(h, /<td class="n">61%<\/td><td>[^<-][^<]*<\/td><td class="n">\$12\.50<\/td><\/tr>/);
  assert.match(h, /<td>alt<\/td><td colspan="16" class="muted">idle/, "a note row spans every column");
  const none = show(board({ burn: burn({ accounts: [acct("main", {})] }) }));
  assert.match(none, /<td class="n">-<\/td><td>-<\/td><td class="n">-<\/td><\/tr>/, "the control: no figures, no numbers");
});

test("the token and Langfuse folds sit between Burn and Sections", () => {
  run("cost.open = {}");
  const h = show(board({ tokens: tokens({ langfuse: { figures: lfFigures(), why: null } }), sections: null }));
  const at = (id) => h.indexOf(`id="${id}"`);
  assert.ok(at("sec-burn") >= 0 && at("sec-burn") < at("sec-tokens") && at("sec-tokens") < at("sec-langfuse") && at("sec-langfuse") < at("sec-totals"));
  assert.match(show(board()), /id="sec-tokens"><span class="warn">no snapshot|Where the tokens go <span class="warn">no snapshot/);
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

// Where the tokens go: hub_core::tokens's sums, folded while fresh.
const tokenRow = (name, chars, share, other = false) => ({ name, calls: 141812, chars, share, carried_tokens: 2550000000, other });
const tokenSplit = (context) => ({ days: 7, partial: 0, context, per_response: 120000, carried_share: 0.15, tools: [tokenRow("Bash", 331000000, 0.823), tokenRow("Other (22)", 10000000, 0.026, true)], commands: [tokenRow("sed", 89000000, 0.221)] });
const tokens = (o = {}) => ({ date: "2026-11-05", generated_at: 1793942659, stale: false, week: tokenSplit(18000000000), day: tokenSplit(3900000000), ...o });
const tail = (t) => { const f = run("cost"); f.open = {}; f.tokWin = "week"; return ctx.tokensSection({ tokens: t }); };

test("the tokens section is folded while fresh, with the week on its head", () => {
  const h = tail(tokens());
  assert.match(h, /<details class="csec" data-k="tokens" id="sec-tokens"><summary>/);
  assert.match(h, /Where the tokens go <span class="muted">7d 18\.0B, tool output 15%/);
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
  assert.match(h, /class="warn">7d 18\.0B, tool output 15%, stale: newest snapshot 2026-11-05/);
  run("cost").open["tokens-stale"] = false;
  assert.doesNotMatch(ctx.tokensSection({ tokens: tokens({ stale: true }) }), /id="sec-tokens" open>/);
});

test("no snapshot is an amber head with nothing to open", () => {
  const h = tail(null);
  assert.match(h, /class="warn">no snapshot/);
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

test("the fold keeps what paint remembered, and going stale still opens it", () => {
  const f = run("cost");
  f.open = { tokens: true };
  assert.match(ctx.tokensSection({ tokens: tokens() }), /id="sec-tokens" open>/);
  f.open = { tokens: false };
  assert.match(ctx.tokensSection({ tokens: tokens({ stale: true }) }), /data-k="tokens-stale" id="sec-tokens" open>/);
  f.open = { tokens: false, "tokens-stale": false };
  assert.doesNotMatch(ctx.tokensSection({ tokens: tokens({ stale: true }) }), /id="sec-tokens" open>/);
  f.open = {};
});

// What Langfuse sees: the newest snapshot's `.langfuse`, folded while it reads.
const lfFigures = () => ({
  tools: [{ tool: "Bash", calls: 35243, p50_ms: 99, p95_ms: 17487, total_s: 224341 }],
  tool_executions: 38947, tool_errors: 854, tool_error_share: 0.0219, tool_error_classes: [{ name: "ShellError", n: 781 }],
  gateway_calls: 194, gateway_errors: 26, gateway_error_share: 0.134, gateway_error_classes: [{ name: "invalid_key", n: 16 }],
  gateway_cost_usd: 3.59, gateway_tokens: 2271863, gateway_models: [{ model: "claude-sonnet-5.5", calls: 33, errors: 0, cost_usd: 3.45 }], gateway_other_models: 14, truncated: false,
});
const lfTail = (t) => { const f = run("cost"); f.open = {}; return ctx.langfuseSection({ tokens: t }); };

test("the langfuse section is folded while it reads, with both error shares and the gateway's cost on its head", () => {
  const h = lfTail(tokens({ langfuse: { figures: lfFigures(), why: null } }));
  assert.doesNotMatch(h, /id="sec-langfuse" open>/);
  assert.match(h, /tool errors 2%, gateway errors 13%, \$3\.59 gateway/);
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

test("no figures opens the section amber and says why; a stale snapshot opens it too", () => {
  const none = lfTail(tokens({ langfuse: { figures: null, why: "no key (rbw langfuse-api)" } }));
  assert.match(none, /data-k="langfuse-stale" id="sec-langfuse" open>/);
  assert.match(none, /class="warn">no figures in snapshot 2026-11-05/);
  assert.match(none, /no key \(rbw langfuse-api\)/);
  const stale = lfTail(tokens({ stale: true, langfuse: { figures: lfFigures(), why: null } }));
  assert.match(stale, /data-k="langfuse-stale" id="sec-langfuse" open>/);
  assert.match(stale, /stale: newest snapshot 2026-11-05/);
});

test("a snapshot from before the reader has no langfuse key and still draws the amber head", () => {
  assert.match(lfTail(tokens()), /no figures in snapshot/);
  assert.equal(ctx.langfuseSection({ tokens: null }), "");
});

test("WHO SPENT 24H leads the tab: live Claude by runner, other harnesses from outcomes with their unpriced count", () => {
  const who = { usd: 10, claude_usd: 9, rows: [
    { who: "you", usd: 6, share: 0.6, source: "Prometheus", sessions: null, unpriced: null },
    { who: "fleet-dispatch", usd: 3, share: 0.3, source: "Prometheus", sessions: null, unpriced: null },
    { who: "codex", usd: 1, share: 0.1, source: "outcomes", sessions: 2, unpriced: 1 },
    { who: "opencode", usd: null, share: 0, source: "outcomes", sessions: 1, unpriced: 1 },
  ] };
  const h = show(board({ who }));
  assert.ok(h.indexOf("sec-who") < h.indexOf("sec-burn"), "who spent it is the first answer");
  assert.match(h, /Who spent 24h <span class="muted">\$10\.00: Claude \$9\.00 live \(exporting sessions\); others: outcomes<\/span>/);
  assert.match(h, /<tr><td>fleet-dispatch<\/td><td class="n">\$3\.00<\/td><td class="n">30%<\/td><td class="muted">live<\/td><\/tr>/);
  assert.match(h, /<td>codex<\/td>.*?outcomes, 2 sessions, <span class="warn">1 unpriced<\/span>/);
  assert.match(h, /<tr><td>opencode<\/td><td class="n">-<\/td><td class="n">-<\/td>/, "nothing priced is unknown, never $0");
  assert.doesNotMatch(h, /LIVE 24H/, "the live total is this block's head, not a second tile");
  // negative control: nothing read says so, never a $0 table
  const none = show(board({ who: { usd: 0, claude_usd: null, rows: [] } }));
  assert.match(none, /id="sec-who">Who spent 24h<\/h2><div class="panel muted">nothing read/);
});
