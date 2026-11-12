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
// The split pane's media query (sessions.js SPLIT): narrow unless a test widens it.
const mq = { matches: false, addEventListener() {} };
const ctx = vm.createContext({
  console,
  matchMedia: () => mq,
  URLSearchParams,
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

const row = (key, o) => ({ key, bucket: "WORKING", project: "dotfiles", task: `task of ${key}`, item: "", target: key, session_id: key + "-id", pr: null, pr_state: "", ci: "", phases_done: null, phases_total: null, idle_min: 3, ended: "", finished: null, cost_usd: null, account: "a", harness: "claude", source: "live", unlinked: false, ...o });
const ROWS = [
  row("hub/b:1", { bucket: "NEEDS", pr: "12", pr_state: "open", ci: "PASS", phases_done: 2, phases_total: 4, cost_usd: 1.2 }),
  row("lab/x:1", { bucket: "STALLED", idle_min: 1980 }),
  row("ucp-394", { bucket: "DONE", target: "", session_id: "s9", item: "ucp-394", pr: "1915", pr_state: "merged", ended: "ended", idle_min: null, source: "queue", harness: "codex", close: "now" }),
];
const TABLE = { q: "", state: "", shown: 3, total: 3, facets: [{ key: "project", clear: "", on: [], values: [{ q: "project:dotfiles", value: "dotfiles", n: 3, on: false }] }],
  states: [{ name: "all", n: 3 }, { name: "running", n: 0 }, { name: "needs you", n: 1, tone: "bad" }, { name: "stalled", n: 1, tone: "warn" }, { name: "done today", n: 1, tone: "ok", means: "ended today" }],
  columns: ["bucket", "project", "task", "by", "pr", "phases", "idle", "cost", "acct", "harness", "close", "item", "source"].map((key) => ({ key, sort: "", next_sort: key, next_dir: "asc" })) };
const CAP = { parts: [{ text: "38 live: 14 hand, 18 dispatched (0/40 run units, 3 per pass), 6 other", warn: false, start: null, confirm: "" },
  { text: "dispatch on, next 13:01", warn: false, start: null, confirm: "" },
  { text: "shepherd timer stopped", warn: true, start: "shepherd", confirm: "Start the shepherd timer?" }], live: 38, unlinked: 21, errors: ["fleet-dispatch headroom: exit 1"] };

function setup() {
  mq.matches = false;
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
  run("sst.render()");
  let html = boxes["ov-sessions"].innerHTML;
  assert.match(html, /38 live: 14 hand, 18 dispatched \(0\/40 run units, 3 per pass\), 6 other<\/span> \| <span class="">dispatch on, next 13:01/);
  assert.match(html, /<span class="capwarn">shepherd timer stopped<\/span> <button class="btn sm" data-start="shepherd">Start<\/button>/);
  assert.equal(html.match(/data-start/g).length, 1, "a running timer has no button");
  assert.match(html, /21 of 38 live sessions have no queue item <button class="btn sm" data-unlinked>Show/);
  assert.match(html, /fleet-dispatch headroom: exit 1/, "what could not be read says so");
  run(`sst.confirm = "shepherd"`);
  run("sst.render()");
  html = boxes["ov-sessions"].innerHTML;
  assert.match(html, /Start the shepherd timer\? <button class="btn sm" data-go="shepherd">Start<\/button>/);
  assert.doesNotMatch(html, /data-start/);
});

test("the table is the server's rows in its order, with the overview tiles and the facet", () => {
  setup();
  run("sst.render()");
  const html = boxes["ov-sessions"].innerHTML;
  const order = ["hub/b:1", "lab/x:1", "ucp-394"].map((k) => html.indexOf(`data-key="${k}"`));
  assert.ok(order.every((i) => i >= 0), html);
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.match(html, /<button class="tile t-ok" data-ts="done today" title="ended today"><span class="tl">DONE TODAY<\/span><span class="tv">1<\/span>/);
  assert.doesNotMatch(html, /data-ts="all"|sessions-chips|class="seg fseg"/, "the tiles are the chips, so the small chip row is gone");
  assert.ok(html.indexOf("stiles") < html.indexOf("tqbar"), "the overview row sits on the search bar");
  assert.match(html, /<input type="checkbox" data-tq data-fv="dotfiles" value="project:dotfiles"> <span>dotfiles<\/span> <span class="n">3<\/span>/);
  assert.match(html, /#12 open <b class="ci pass">PASS<\/b>/);
  assert.match(html, /<td class="n">2\/4<\/td><td class="n">3m<\/td><td class="n">\$1\.20<\/td>/);
  assert.match(html, /title="sort by harness">harness<\/button>/, "the harness is a column");
  assert.match(html, /title="sort by close">close<\/button>/, "the close verdict is a column");
  assert.match(html, /<td>a<\/td><td>codex<\/td><td>now<\/td><\/tr>/, "each row names its harness after its account, then its close verdict");
  assert.doesNotMatch(html, /data-tsort="(item|source)"/, "item and source are search keys, not columns");
});

test("a row says what the columns do not: parked, no session here, and where an ended row came from", () => {
  setup();
  run("sst.render()");
  const html = boxes["ov-sessions"].innerHTML;
  assert.match(html, /<div class="c2" title="task of hub\/b:1"><span class="pill parked">parked<\/span> task of hub\/b:1<\/div>/);
  assert.match(html, /<span class="pill">no session<\/span> task of lab\/x:1/);
  assert.match(html, /<span class="pill" title="where this row came from">queue<\/span> task of ucp-394/);
  assert.match(html, /<td class="n">ended<\/td>/);
});

const PAGE = { name: "ucp-394", session_id: "s9", target: "", bucket: "DONE", task: "the <task>", idle: "ended", errors: ["notes board: exit 1"], outcome: "card of s9",
  parts: [{ label: "Queue item", text: "ucp-394 (done, high)", link: "#queue", warn: false }, { label: "PR", text: "#1915 merged", link: "https://github.com/o/r/pull/1915", warn: false }, { label: "Asks", text: "1 open: ship?", link: null, warn: true }] };

test("the overview spend is the server's sum, and the tile in force clears the filter", () => {
  setup();
  run(`sst.data = { ...sst.data, spend_usd: 41.2, table: { ...sst.data.table, state: "stalled", shown: 1 } }`);
  run("sst.render()");
  const html = boxes["ov-sessions"].innerHTML;
  assert.match(html, /SPEND<\/span><span class="tv">\$41\.20<\/span><span class="ts1">1 shown/);
  assert.match(html, /<button class="tile on t-warn" data-ts="">/);
});

test("an opened session starts on its conversation, not its Details page", () => {
  setup();
  run(`__load = load; load = () => {}; select({ target: "hub/a:1", session: "hub/a:1-id", status: "idle", actions: [] })`);
  assert.equal(run("st.view"), "transcript");
  run(`load = __load`);
});

test("from 900px an open session lists the table's rows beside it, the open one marked; narrower, none", async () => {
  setup();
  mq.matches = true;
  run(`__load = load; load = () => {}; __asked = []; api = async (u) => { __asked.push(u); return { rows: [], table: TABLE }; }`);
  await run(`openSession("hub/b:1-id")`);
  const html = boxes.side.innerHTML;
  assert.equal((html.match(/class="srow/g) || []).length, 3, "every row the table shows");
  assert.match(html, /<button class="srow on" data-key="hub\/b:1">/, "the open session is marked");
  assert.match(html, /data-ts=/, "the state chips filter it");
  assert.equal(run("__asked.length"), 0, "a read table is not read again to draw it");
  run(`sst.data = null`);
  run(`refreshSessions()`);
  await new Promise(setImmediate);
  assert.match(run("__asked.join()"), /^\/api\/sessions\/table/, "an open session keeps the list fresh");
  mq.matches = false;
  run(`sst.data = __d; renderSide()`, { rows: ROWS, errors: [], table: TABLE });
  assert.equal(boxes.side.innerHTML, "", "under 900px nothing is drawn");
  run(`load = __load; api = __api`);
});

test("every row is a link to its page, keeping the table's view for Back", () => {
  setup();
  run(`location.hash = ""; sessionClick(sst.data.rows[0])`);
  assert.equal(run("location.hash"), "#sessions/sessions/hub%2Fb%3A1-id", "a session on a pane, by its session id");
  run(`st.views.sessions = "q=pr%3Aopen"; sessionClick(sst.data.rows[2])`);
  assert.equal(run("location.hash"), "#sessions/sessions/s9?q=pr%3Aopen", "an ended one, by its session id");
  run(`st.views.sessions = ""; sessionClick({ ...sst.data.rows[2], session_id: "" })`);
  assert.equal(run("location.hash"), "#sessions/sessions/ucp-394", "no session id, by its row key");
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
  assert.doesNotMatch(html, /data-transcript/, "the conversation is the default view, so Details has no Load row");
  assert.doesNotMatch(html, /page-state/, "a session out of the state document has no state fold");
  assert.equal(run("st.sel.name"), "ucp-394");
  assert.equal(run("st.sel.summary"), "the <task>");
  ctx.PAGE_STUB = { ...PAGE, session_id: "hub/a:1-id", target: "hub/a:1", outcome: "" };
  run(`st.sel = { target: "hub/a:1", session: "hub/a:1-id", actions: [] }`);
  await run(`loadPage()`);
  assert.match(boxes.scroll.innerHTML, /after it ends/);
  assert.doesNotMatch(boxes.scroll.innerHTML, /page-outcome/);
  assert.match(boxes.scroll.innerHTML, /data-k="page-state" open/);
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

test("past the server's open_rows the table offers the rest, and the count is every row the view keeps", () => {
  setup();
  run(`sst.data.open_rows = 25; sst.data.rows = Array.from({ length: 32 }, (_, i) => ({ ...sst.data.rows[0], key: "k" + i }))`);
  run("sst.render()");
  const h = boxes["ov-sessions"].innerHTML;
  assert.equal((h.match(/<tr class="click"/g) || []).length, 25, "the page draws the server's cap");
  assert.match(h, /data-all="1">\+7 more/);
  run("sst.all = true");
  run("sst.render()");
  assert.equal((boxes["ov-sessions"].innerHTML.match(/<tr class="click"/g) || []).length, 32);
  assert.doesNotMatch(boxes["ov-sessions"].innerHTML, /\+\d+ more/);
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
  run("sst.render()");
  assert.match(boxes["ov-sessions"].innerHTML, /trader/);
  assert.doesNotMatch(boxes["ov-sessions"].innerHTML, /freqtrade_trading_attempt-agent-1<\/td>/);
});

test("PARKED and CHAT have a colour of their own; a retired bucket takes CHAT's grey", () => {
  run(`setBuckets(__d)`, VOCAB);
  assert.equal(run(`bucketColor("PARKED")`), "var(--b-parked)");
  assert.equal(run(`bucketColor("UNCLEAR")`), "var(--b-chat)");
  const css = readFileSync(new URL("app.css", dir), "utf8");
  for (const t of ["--b-parked", "--b-chat"]) assert.equal(css.split(t + ":").length, 3, `${t} in both themes`);
});

test("under the table the last day starts shut with its lane count; the shepherd is its own inner tab, the changes and the rundowns are Log's", () => {
  setup();
  run("sst.render()");
  const html = boxes["ov-sessions"].innerHTML;
  assert.match(html, /<details class="ovsec" data-k="lanes"><summary><h2 class="sec">Last 24h <span class="n">\d+<\/span><\/h2><\/summary>/);
  for (const k of ["shep", "changes", "rundowns"]) assert.doesNotMatch(html, new RegExp(`data-k="${k}"`));
  run(`wst.open.lanes = true; sst.render()`);
  assert.match(boxes["ov-sessions"].innerHTML, /<details class="ovsec" data-k="lanes" open>/, "a fold the reader opened stays open");
  run(`wst.open.lanes = false`);
});

test("the Shepherd inner tab draws its chat, pass and due lines only while it shows", () => {
  setup();
  box("ov-shepherd").innerHTML = "";
  run("renderShepherd()");
  assert.equal(boxes["ov-shepherd"].innerHTML, "", "the control: the Sessions inner tab shows, so the shepherd paints nothing");
  run(`st.arg = "shepherd"; renderShepherd()`);
  const html = boxes["ov-shepherd"].innerHTML;
  assert.match(html, /data-chat>Chat: open hub\/shep:1/);
  assert.match(html, /Skipped on purpose, in Actions/);
  assert.doesNotMatch(html, /<details class="ovsec"/, "the tab is the section, not a fold");
});

test("each inner tab reads only its own feed while shown", async () => {
  setup();
  run(`__asked = []; api = async (u) => { __asked.push(u); return u.startsWith("/api/shepherd") ? shst.data : u.startsWith("/api/watch") ? wst.data : u.startsWith("/api/sessions/capacity") ? sst.cap : sst.data; }`);
  run(`st.arg = "shepherd"; TABS.sessions.inner("shepherd")`);
  await new Promise(setImmediate);
  assert.equal(run("__asked.join()"), "/api/shepherd");
  // A queue event while Shepherd shows reads no table; it marks the table to read when it shows.
  run(`__asked.length = 0; st.tab = "sessions"; tableFeed.onEvent({ kind: "queue" })`);
  await new Promise(setImmediate);
  assert.doesNotMatch(run("__asked.join()"), /\/api\/sessions\/table/, "off its inner tab the table is not read");
  run(`__asked.length = 0; st.arg = "sessions"; TABS.sessions.inner("sessions")`);
  await new Promise(setImmediate);
  const read = run("__asked.join()");
  assert.match(read, /\/api\/sessions\/table/, "the control: the Sessions inner tab reads its stale table");
  assert.doesNotMatch(read, /\/api\/(shepherd|fleet)/);
  run(`__asked.length = 0; TABS.sessions.inner("sessions")`);
  await new Promise(setImmediate);
  assert.doesNotMatch(run("__asked.join()"), /\/api\/sessions\/table/, "shown again with nothing new, it is not read again");
  run(`api = __api`);
});

test("STARTED BY says who started a row: dispatch, resume, by hand", () => {
  setup();
  run(`sst.data.rows = [{ ...sst.data.rows[0], by: "dispatch" }, { ...sst.data.rows[1], by: "hand" }, sst.data.rows[2]]`);
  run("sst.render()");
  const html = boxes["ov-sessions"].innerHTML;
  assert.match(html, /title="sort by started by">started by<\/button>/);
  assert.match(html, /<td class="muted">dispatch<\/td>/);
  assert.match(html, /<td class="muted">hand<\/td>/);
});

test("Log's ranked sessions list the week worst first, and an open row shows its card", () => {
  setup();
  run(`ost.rows = null; ost.open = null; ost.cards = {}`);
  run("sst.render()");
  assert.doesNotMatch(boxes["ov-sessions"].innerHTML, /data-k="ranked"/, "the ranking is Log's, not the Sessions overview's");
  ctx.renderLogRanked();
  assert.doesNotMatch(boxes["log-ranked"].innerHTML, /by friction/, "no prose head: the summary is the title");
  assert.match(boxes["log-ranked"].innerHTML, /Loading\./, "nothing is read until the section opens");
  run(`ost.rows = __d.rows; ost.open = __d.rows[0].session_id; ost.cards[ost.open] = __d.card;`, { card: "fix the gate (6f296b73)\n  Time      work 2h05", rows: [
    { session_id: "6f296b73-b7a5", project: "dotfiles", title: "fix the gate\nmore", friction: 11, why: "9 nudges", cost_usd: 41.2, duration_s: 22200, prs_merged: 24, prs_open: 0, prs_closed_unmerged: 1 },
    { session_id: "aa11bb22-cc", project: "hub", title: "t", friction: 1, why: "1 denied", cost_usd: null, duration_s: null, prs_merged: 0, prs_open: 0, prs_closed_unmerged: 0 },
  ] });
  ctx.renderLogRanked();
  const html = boxes["log-ranked"].innerHTML;
  assert.match(html, /<tr class="click" data-sid="6f296b73-b7a5"><td class="n">11<\/td><td>fix the gate <span class="muted">6f296b73<\/span>/);
  assert.match(html, /<td class="n">6h 10m<\/td><td class="n">\$41\.20<\/td><td class="n">24\/25<\/td>/);
  assert.match(html, /<pre class="joblog">fix the gate \(6f296b73\)\n  Time/);
  assert.equal(html.match(/joblog/g).length, 1, "only the open row shows a card");
});

test("an open session's facts are its fleet-state card, open until folded to one line, and the page shows them itself", () => {
  setup();
  run("st.sel = st.agents[0]");
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, true, "the page has its own fold");
  run(`st.view = "transcript"`);
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, false);
  assert.match(boxes.facts.innerHTML, /<details data-k="facts" open><summary>.*WORKING.*PR #12/);
  run("st.sel = st.agents[3]");
  ctx.renderFacts();
  assert.equal(boxes.facts.hidden, true);
});

test("Log's Rundowns list the server's shown rows, every card shut until opened, and +N older shows the rest", async () => {
  const shst = vm.runInContext("shst", ctx), cap = 30;
  Object.assign(shst, { data: null, err: null });
  run('st.tab = "log"');
  ctx.renderLogRundowns();
  assert.match(boxes["log-rundowns"].innerHTML, /Loading/, "the first render, before any data, says Loading");
  const rundowns = Array.from({ length: cap + 3 }, (_, i) => ({ file: `r${i}.md`, title: `rundown-${i}`, stamp: "2026-11-12 12:00 UTC", body: "a long sum-up" }));
  const fetch0 = ctx.fetch;
  ctx.fetch = async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({ rundowns, shown: cap, stats: null, ledger: { due: [] } }) });
  await run("refreshShepherd()");
  ctx.fetch = fetch0;
  run('st.tab = "log"');
  ctx.renderLogRundowns();
  const h = boxes["log-rundowns"].innerHTML;
  assert.equal((h.match(/<details class="card rd"/g) || []).length, cap);
  assert.doesNotMatch(h, /<details class="card rd" open/, "the newest starts shut too (dashboards rule 4)");
  assert.match(h, />\+3 older</);
  shst.all = true;
  ctx.renderLogRundowns();
  assert.match(boxes["log-rundowns"].innerHTML, new RegExp(`rundown-${cap + 2}<`));
  assert.doesNotMatch(boxes["log-rundowns"].innerHTML, /older</);
  Object.assign(shst, { all: false, data: null });
  run('st.tab = "sessions"');
});
