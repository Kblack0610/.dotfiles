// Unit tests for the Sessions list (.local/src/agent-web/static/app.js renderList, with the
// fleet-state join in watch.js and the shepherd's pass in shepherd.js), run by `node --test`
// from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context; only
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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "watch.js", "shepherd.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const agent = (target, o) => ({ target, session: target + "-id", status: "idle", summary: "", project: "dotfiles", ...o });
const state = (target, bucket, o) => ({ target, session_id: target + "-id", bucket, topic: `task of ${target}`, idle_min: 5, ...o });

// st, wst and shst are top-level consts of the page's scripts: the vm sees them, ctx does not.
const run = (code, d) => { ctx.__d = d; return vm.runInContext(code, ctx); };

function setup() {
  run(`st.tab = "sessions"; st.sel = null; wst.filter = null;
    st.agents = __d.agents; wst.data = __d.watch; shst.data = __d.shep;`, {
    agents: [agent("hub/a:1"), agent("hub/b:1", { parked: true }), agent("hub/shep:1"), agent("hub/c:1")],
    watch: { state: { sessions: [state("hub/a:1", "WORKING", { pr: "12", ci: "PASS", eta: "14:05" }), state("hub/b:1", "NEEDS"), state("lab/x:1", "STALLED")] }, transitions: [] },
    shep: { target: "hub/shep:1", status: "idle", stats: { pass_running: true, pass_age_s: 240, pass_status: "running" }, ledger: { due: [{}, {}] }, rundowns: [] },
  });
}

test("the list is the pass line, then the shepherd pinned, then one row per session by bucket", () => {
  setup();
  ctx.renderList();
  const html = boxes.list.innerHTML;
  const order = ["data-ov", ">SHEPHERD ", ">NEEDS ", ">STALLED ", ">WORKING ", ">PARKED "].map((s) => html.indexOf(s));
  assert.ok(order.every((i) => i >= 0), html);
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.match(html, /shepherd: pass 4m running, 2 due/);
  // The card fields ride on the row: PR and CI, ETA, idle; the topic is the task line.
  assert.match(html, /PR #12 <b class="ci pass">PASS<\/b>/);
  assert.match(html, /eta 14:05/);
  assert.match(html, /task of hub\/a:1/);
  // A fleet-state row with no session here folds to its card; it has nothing to open.
  assert.match(html, /<details class="ghost" data-k="ghost:lab\/x:1">/);
  // hub/c:1 has no fleet-state row: PARKED, as on the hub's Sessions tab.
  assert.ok(html.indexOf('data-t="hub/c:1"') > html.indexOf(">PARKED "));
});

test("a bucket tile filters the list to that bucket", () => {
  setup();
  run(`wst.filter = "NEEDS"`);
  ctx.renderList();
  const html = boxes.list.innerHTML;
  assert.match(html, /data-t="hub\/b:1"/);
  assert.doesNotMatch(html, /data-t="hub\/a:1"/);
  assert.match(html, /data-ov/);
});

test("the overview folds the last day and the shepherd; the changes and the rundowns are Log's", () => {
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
