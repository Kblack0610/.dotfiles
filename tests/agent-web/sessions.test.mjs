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
  location: { hash: "", pathname: "/" },
  history: { replaceState() {} },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "watch.js", "table.js", "actions.js", "shepherd.js", "sessions.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const agent = (target, o) => ({ target, session: target + "-id", status: "idle", summary: "", project: "dotfiles", ...o });
const state = (target, bucket, o) => ({ target, session_id: target + "-id", bucket, topic: `task of ${target}`, idle_min: 5, ...o });

// st, wst and shst are top-level consts of the page's scripts: the vm sees them, ctx does not.
const run = (code, d) => { ctx.__d = d; return vm.runInContext(code, ctx); };
run(`var __api = api`);

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
  run(`st.tab = "sessions"; st.sel = null; st.view = "page"; st.views = {}; st.arg = ""; sst.confirm = null; api = __api; sst.all = false;
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

const PAGE = { name: "ucp-394", session_id: "s9", target: "", bucket: "DONE", task: "the <task>", idle: "ended", errors: ["notes board: exit 1"], outcome: "card of s9",
  parts: [{ label: "Queue item", text: "ucp-394 (done, high)", link: "#queue", warn: false }, { label: "PR", text: "#1915 merged", link: "https://github.com/o/r/pull/1915", warn: false }, { label: "Asks", text: "1 open: ship?", link: null, warn: true }] };

test("every row is a link to its page, keeping the table's view for Back", () => {
  setup();
  run(`location.hash = ""; sessionClick(sst.data.rows[0])`);
  assert.equal(run("location.hash"), "#sessions/hub%2Fb%3A1-id", "a session on a pane, by its session id");
  run(`st.views.sessions = "q=pr%3Aopen"; sessionClick(sst.data.rows[2])`);
  assert.equal(run("location.hash"), "#sessions/s9?q=pr%3Aopen", "an ended one, by its session id");
  run(`st.views.sessions = ""; sessionClick({ ...sst.data.rows[2], session_id: "" })`);
  assert.equal(run("location.hash"), "#sessions/ucp-394", "no session id, by its row key");
});

test("a transcript that answers after the view moved back to the page does not cover it", async () => {
  await run(`(async () => {
    let answer; api = () => new Promise((r) => { answer = r; });
    st.sel = { target: "hub/a:1" }; st.view = "transcript"; $("scroll").innerHTML = "the page";
    const loading = load();
    st.view = "page"; answer({ start: 0, end: 1, events: [] });
    await loading;
  })()`);
  assert.equal(run(`$("scroll").innerHTML`), "the page");
  assert.equal(run("st.end"), null);
});

test("the URL opens the session on a pane on its page, and one with no pane has nothing to type into", async () => {
  setup();
  run(`__opened = []; __select = select; select = (a) => { __opened.push(a); }; api = async () => PAGE_STUB;`);
  ctx.PAGE_STUB = PAGE;
  await run(`openSession("hub/a:1-id")`);
  assert.equal(run("__opened[0].target"), "hub/a:1");
  assert.equal(run("!!__opened[0].paneless"), false);
  await run(`openSession("s9")`);
  assert.equal(run("__opened[1].paneless"), true);
  assert.equal(run("__opened[1].paneless"), true, "no pane keeps the compose box and Screen off");
  run(`select = __select`);
});

test("a page draws hub-core's parts: links, amber, errors, the open outcome card, and no card while it lives", async () => {
  setup();
  ctx.PAGE_STUB = PAGE;
  run(`api = async () => PAGE_STUB; st.sel = { target: "s9", session: "s9", paneless: true, actions: [] }; wst.open = {}`);
  await run(`loadPage()`);
  const html = boxes.scroll.innerHTML;
  assert.match(html, /<a href="#queue">ucp-394 \(done, high\)<\/a>/);
  assert.match(html, /<a href="https:\/\/github.com\/o\/r\/pull\/1915" target="_blank" rel="noopener">/);
  assert.match(html, /pgv capwarn">1 open: ship\?/);
  assert.match(html, /the &lt;task&gt;/, "text is escaped");
  assert.match(html, /card err">notes board: exit 1/);
  assert.match(html, /data-k="page-outcome" open.*card of s9/s);
  assert.match(html, /data-transcript/);
  assert.doesNotMatch(html, /page-state/, "a session out of the state document has no state fold");
  assert.equal(run("st.sel.name"), "ucp-394");
  assert.equal(run("st.sel.summary"), "the <task>");
  ctx.PAGE_STUB = { ...PAGE, session_id: "hub/a:1-id", target: "hub/a:1", outcome: "" };
  run(`st.sel = { target: "hub/a:1", session: "hub/a:1-id", actions: [] }`);
  await run(`loadPage()`);
  assert.match(boxes.scroll.innerHTML, /after it ends/);
  assert.doesNotMatch(boxes.scroll.innerHTML, /page-outcome/);
  assert.match(boxes.scroll.innerHTML, /data-k="page-state"/);
});

test("a page that cannot be read says why, and one for a session left since is not drawn", async () => {
  setup();
  run(`api = async () => { throw new Error("no such session"); }; st.sel = { target: "gone", session: "gone", actions: [] }`);
  await run(`loadPage()`);
  assert.match(boxes.scroll.innerHTML, /no such session/);
  boxes.scroll.innerHTML = "kept";
  ctx.PAGE_STUB = PAGE;
  run(`api = async () => { st.sel = { target: "other", session: "other", actions: [] }; return PAGE_STUB; }; st.sel = { target: "a", session: "a", actions: [] }`);
  await run(`loadPage()`);
  await new Promise(setImmediate);
  assert.doesNotMatch(boxes.scroll.innerHTML, /ucp-394 \(done/, "the first session's page does not land on the second");
});

test("a page refreshes with the feed, the transcript is not read for it, and the table stays unread", async () => {
  setup();
  ctx.PAGE_STUB = PAGE;
  run(`__asked = []; api = async (u) => { __asked.push(u); return PAGE_STUB; }; st.sel = { target: "s9", session: "s9", actions: [] }`);
  run(`refreshSessions()`);
  await new Promise(setImmediate);
  assert.equal(run("__asked.join()"), "/api/sessions/page?t=s9");
  run(`st.view = "transcript"; __asked.length = 0; refreshSessions()`);
  await new Promise(setImmediate);
  assert.equal(run("__asked.length"), 0);
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

test("PARKED and CHAT have a colour of their own; a retired bucket takes CHAT's grey", () => {
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

test("an open session's facts are its fleet-state card, folded to one line, and the page shows them itself", () => {
  setup();
  run("st.sel = st.agents[0]");
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, true, "the page has its own fold");
  run(`st.view = "transcript"`);
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, false);
  assert.match(boxes.facts.innerHTML, /<details data-k="facts"><summary>.*WORKING.*PR #12/);
  run("st.sel = st.agents[3]");
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, true);
});
