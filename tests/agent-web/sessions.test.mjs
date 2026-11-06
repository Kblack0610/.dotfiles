// Unit tests for the Sessions page (.local/src/agent-web/static/sessions.js, with the folds in
// watch.js and shepherd.js), run by `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context; only
// the DOM is a stub.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const boxes = {};
const box = (id) => (boxes[id] ||= Object.assign(el(), { innerHTML: "", scrollTop: 0, hidden: false, textContent: "", querySelectorAll: () => [] }));
const doc = { getElementById: box, addEventListener() {}, createElement: el, body: el(), querySelector: el, querySelectorAll: () => [] };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "watch.js", "table.js", "actions.js", "shepherd.js", "sessions.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const agent = (target, o) => ({ target, session: target + "-id", status: "idle", summary: "", project: "dotfiles", ...o });
const state = (target, bucket, o) => ({ target, session_id: target + "-id", bucket, topic: `task of ${target}`, idle_min: 5, ...o });

// st, wst and shst are top-level consts of the page's scripts: the vm sees them, ctx does not.
const run = (code, d) => { ctx.__d = d; return vm.runInContext(code, ctx); };

const row = (key, o) => ({ key, bucket: "WORKING", project: "dotfiles", task: `task of ${key}`, item: "", target: key, session_id: key + "-id", pr: null, pr_state: "", ci: "", phases_done: null, phases_total: null, idle_min: 3, ended: "", finished: null, cost_usd: null, account: "a", source: "live", unlinked: false, ...o });
const ROWS = [
  row("hub/b:1", { bucket: "NEEDS", pr: "12", pr_state: "open", ci: "PASS", phases_done: 2, phases_total: 4, cost_usd: 1.2 }),
  row("lab/x:1", { bucket: "STALLED", idle_min: 1980 }),
  row("ucp-394", { bucket: "DONE", target: "", session_id: "s9", item: "ucp-394", pr: "1915", pr_state: "merged", ended: "ended", idle_min: null, source: "queue" }),
];
const TABLE = { q: "", state: "", shown: 3, total: 3, facets: [{ key: "project", clear: "", on: "", values: [{ q: "project:dotfiles", value: "dotfiles", n: 3 }] }],
  states: [{ name: "all", n: 3 }, { name: "running", n: 0 }, { name: "needs you", n: 1 }, { name: "stalled", n: 1 }, { name: "done today", n: 1 }],
  columns: ["bucket", "project", "task", "pr", "phases", "idle", "cost", "acct", "item", "source"].map((key) => ({ key, sort: "", next_sort: key, next_dir: "asc" })) };
const CAP = { parts: [{ text: "38 live: 14 hand, 18 dispatched (0/40 run units, 3 per pass), 6 other", warn: false, start: null, confirm: "" },
  { text: "dispatch on, next 13:01", warn: false, start: null, confirm: "" },
  { text: "shepherd timer stopped", warn: true, start: "shepherd", confirm: "Start the shepherd timer?" }], live: 38, unlinked: 21, errors: ["fleet-dispatch headroom: exit 1"] };

function setup() {
  run(`st.tab = "sessions"; st.sel = null; sst.open = null; sst.confirm = null; sst.all = false;
    st.agents = __d.agents; wst.data = __d.watch; shst.data = __d.shep; sst.data = __d.table; sst.cap = __d.cap;`, {
    table: { rows: ROWS, errors: [], table: TABLE },
    cap: CAP,
    agents: [agent("hub/a:1"), agent("hub/b:1", { parked: true }), agent("hub/shep:1"), agent("hub/c:1")],
    watch: { state: { sessions: [state("hub/a:1", "WORKING", { pr: "12", ci: "PASS", eta: "14:05" }), state("hub/b:1", "NEEDS"), state("lab/x:1", "STALLED")] }, transitions: [] },
    shep: { target: "hub/shep:1", status: "idle", stats: { pass_running: true, pass_age_s: 240, pass_status: "running" }, ledger: { due: [{}, {}] }, rundowns: [] },
  });
}

test("the header is hub-core's parts: a stopped timer is amber with a Start, and nothing runs until confirmed", () => {
  setup();
  ctx.renderOverview();
  let html = boxes.scroll.innerHTML;
  assert.match(html, /38 live: 14 hand, 18 dispatched \(0\/40 run units, 3 per pass\), 6 other<\/span> \| <span class="">dispatch on, next 13:01/);
  assert.match(html, /<span class="capwarn">shepherd timer stopped<\/span> <button class="btn sm" data-start="shepherd">Start<\/button>/);
  assert.equal(html.match(/data-start/g).length, 1, "a running timer has no button");
  assert.match(html, /21 of 38 live sessions have no queue item <button class="btn sm" data-unlinked>Show/);
  assert.match(html, /fleet-dispatch headroom: exit 1/, "what could not be read says so");
  run(`sst.confirm = "shepherd"`);
  ctx.renderOverview();
  html = boxes.scroll.innerHTML;
  assert.match(html, /Start the shepherd timer\? <button class="btn sm" data-go="shepherd">Start<\/button>/);
  assert.doesNotMatch(html, /data-start/);
});

test("the table is the server's rows in its order, with the chips and the facet", () => {
  setup();
  ctx.renderOverview();
  const html = boxes.scroll.innerHTML;
  const order = ["hub/b:1", "lab/x:1", "ucp-394"].map((k) => html.indexOf(`data-key="${k}"`));
  assert.ok(order.every((i) => i >= 0), html);
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.match(html, /data-ts="done today">done today <span class="n">1/);
  assert.match(html, /<option value="project:dotfiles">dotfiles \(3\)/);
  assert.match(html, /#12 open <b class="ci pass">PASS<\/b>/);
  assert.match(html, /<td class="n">2\/4<\/td><td class="n">3m<\/td><td class="n">\$1\.20<\/td>/);
  assert.doesNotMatch(html, /data-tsort="(item|source)"/, "item and source are search keys, not columns");
});

test("a row says what the columns do not: parked, no session here, and where an ended row came from", () => {
  setup();
  ctx.renderOverview();
  const html = boxes.scroll.innerHTML;
  assert.match(html, /task of hub\/b:1 <span class="pill parked">parked<\/span>/);
  assert.match(html, /task of lab\/x:1 <span class="pill">no session<\/span>/);
  assert.match(html, /task of ucp-394 <span class="pill" title="where this row came from">queue<\/span>/);
  assert.match(html, /<td class="n">ended<\/td>/);
});

test("a live row opens its session; a row with none unfolds to its card, and the outcome card says when it is missing", async () => {
  setup();
  run(`__opened = null; select = (a) => { __opened = a.target; }; sessionClick(sst.data.rows[0])`);
  assert.equal(run("__opened"), "hub/b:1");
  run(`sessionClick(sst.data.rows[1])`);
  assert.match(boxes.scroll.innerHTML, /colspan="8"/);
  assert.match(boxes.scroll.innerHTML, /task of lab\/x:1|wcard/);
  run(`sst.cards = { s9: "card of s9" }; sessionClick(sst.data.rows[2])`);
  assert.match(boxes.scroll.innerHTML, /queue item ucp-394/);
  assert.match(boxes.scroll.innerHTML, /<pre class="joblog">card of s9/);
  run(`sessionClick(sst.data.rows[2])`);
  assert.doesNotMatch(boxes.scroll.innerHTML, /joblog/, "a second click folds it");
});

test("a card that was missing is asked for again on the next open", async () => {
  setup();
  run(`__asked = 0; api = async () => { __asked += 1; throw new Error("no card"); }`);
  run(`sessionClick(sst.data.rows[2])`);
  await new Promise(setImmediate);
  assert.match(boxes.scroll.innerHTML, /No outcome card yet/);
  run(`sessionClick(sst.data.rows[2]); api = async () => { __asked += 1; return "card at last"; }; sessionClick(sst.data.rows[2])`);
  await new Promise(setImmediate);
  assert.equal(run("__asked"), 2);
  assert.match(boxes.scroll.innerHTML, /card at last/);
});

test("past the cap the table offers the rest", () => {
  setup();
  run(`sst.data.rows = Array.from({ length: SESSIONS_OPEN + 7 }, (_, i) => ({ ...sst.data.rows[0], key: "k" + i }))`);
  ctx.renderOverview();
  assert.match(boxes.scroll.innerHTML, /data-all="1">\+7 older/);
  run("sst.all = true");
  ctx.renderOverview();
  assert.doesNotMatch(boxes.scroll.innerHTML, /\+\d+ older/);
});

const VOCAB = ["NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"];

test("the bucket order and colours come from the published vocabulary, not a list in the page", () => {
  run(`BUCKETS = []`);
  assert.equal(run(`bucketColor("WORKING")`), "var(--b-chat)", "no vocabulary yet: nothing is named here");
  run(`setBuckets(__d)`, VOCAB);
  assert.equal(run(`bucketColor("WORKING")`), "var(--b-working)");
  assert.deepEqual([...run(`["PARKED", "NEEDS", "X"].map(bucketRank)`)], [6, 0, 7]);
  setup();
  run(`BUCKETS = []; setBuckets(sst.data.buckets)`);
  assert.equal(run(`BUCKETS.length`), 0, "a table body with no buckets leaves the order alone");
  run(`setBuckets(__d)`, VOCAB);
});

test("a freqtrade_trading_attempt-agent-1 session reads trader in the table", () => {
  setup();
  run(`sst.data.rows = [__d]`, row("lab/freqtrade_trading_attempt-agent-1:1", { project: "trader" }));
  ctx.renderOverview();
  assert.match(boxes.scroll.innerHTML, /trader/);
  assert.doesNotMatch(boxes.scroll.innerHTML, /freqtrade_trading_attempt-agent-1<\/td>/);
});

test("PARKED and CHAT have a colour of their own; a retired bucket takes CHAT's grey", () => {
  run(`setBuckets(__d)`, VOCAB);
  assert.equal(run(`bucketColor("PARKED")`), "var(--b-parked)");
  assert.equal(run(`bucketColor("UNCLEAR")`), "var(--b-chat)");
  const css = readFileSync(new URL("app.css", dir), "utf8");
  for (const t of ["--b-parked", "--b-chat"]) assert.equal(css.split(t + ":").length, 3, `${t} in both themes`);
});

test("under the table fold the last day and the shepherd; the changes and the rundowns are Log's", () => {
  setup();
  ctx.renderOverview();
  const html = boxes.scroll.innerHTML;
  for (const k of ["lanes", "shep"]) assert.match(html, new RegExp(`<details class="ovsec" data-k="${k}">`));
  for (const k of ["changes", "rundowns"]) assert.doesNotMatch(html, new RegExp(`data-k="${k}"`));
  assert.match(html, /data-chat>Chat: open hub\/shep:1/);
  assert.match(html, /Skipped on purpose, in Actions/);
});

test("Log's ranked sessions list the week worst first, and an open row shows its card", () => {
  setup();
  run(`ost.rows = null; ost.open = null; ost.cards = {}`);
  ctx.renderOverview();
  assert.doesNotMatch(boxes.scroll.innerHTML, /data-k="ranked"/, "the ranking is Log's, not the Sessions overview's");
  ctx.renderLogRanked();
  assert.match(boxes["log-ranked"].innerHTML, /<span class="muted">7d, by friction<\/span>/);
  assert.match(boxes["log-ranked"].innerHTML, /Loading\./, "nothing is read until the section opens");
  run(`ost.rows = __d.rows; ost.open = __d.rows[0].session_id; ost.cards[ost.open] = __d.card;`, { card: "fix the gate (6f296b73)\n  Time      work 2h05", rows: [
    { session_id: "6f296b73-b7a5", project: "dotfiles", title: "fix the gate\nmore", friction: 11, why: "9 nudges", cost_usd: 41.2, duration_s: 22200, prs_merged: 24, prs_open: 0, prs_closed_unmerged: 1 },
    { session_id: "aa11bb22-cc", project: "hub", title: "t", friction: 1, why: "1 denied", cost_usd: null, duration_s: null, prs_merged: 0, prs_open: 0, prs_closed_unmerged: 0 },
  ] });
  ctx.renderLogRanked();
  const html = boxes["log-ranked"].innerHTML;
  assert.match(html, /2 worst, 7d, by friction/);
  assert.match(html, /<tr class="click" data-sid="6f296b73-b7a5"><td class="n">11<\/td><td>fix the gate <span class="muted">6f296b73<\/span>/);
  assert.match(html, /<td class="n">6h 10m<\/td><td class="n">\$41\.20<\/td><td class="n">24\/25<\/td>/);
  assert.match(html, /<pre class="joblog">fix the gate \(6f296b73\)\n  Time/);
  assert.equal(html.match(/joblog/g).length, 1, "only the open row shows a card");
});

test("an open session's facts are its fleet-state card, folded to one line", () => {
  setup();
  run("st.sel = st.agents[0]");
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, false);
  assert.match(boxes.facts.innerHTML, /<details data-k="facts"><summary>.*WORKING.*PR #12/);
  run("st.sel = st.agents[3]");
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, true);
});
