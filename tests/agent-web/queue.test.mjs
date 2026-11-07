// Unit tests for the Queue tab (.local/src/agent-web/static/queue.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The real scripts load into one vm context; only the DOM is a
// stub. What a query keeps, how it sorts and the minutes in `timing` are hub-core, tested in Rust;
// this checks what the page draws from /api/queue and /api/flow and the view keys it sends back.
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
let scrolled = 0;
const parts = { "sec-candidates": { tagName: "DETAILS", open: false, scrollIntoView() { scrolled++; } }, "qt-head": part(), "qt-facets": part(), "qt-chips": part(), "qt-body": part(), "qt-detail": part(), "q-flow": part(), "q-list": part() };
const doc = { getElementById: (id) => (id === "queue" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
let asked = [];
let reply = {};
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  setTimeout: () => 0,
  location: { pathname: "/", hash: "" },
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => (typeof reply === "function" ? reply(url) : reply) }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "table.js", "actions.js", "flow.js", "jobs.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const settle = () => new Promise((r) => setImmediate(r));

const chips = (over = {}) => [
  { key: "inbox", label: "inbox", value: "4", hot: false, to: null },
  { key: "board", label: "board", value: "312", hot: false, to: { tab: "projects", state: "" } },
  { key: "queued", label: "queued", value: "3 (2 ready)", hot: false, to: { tab: "queue", state: "up next" } },
  { key: "running", label: "running", value: "5", hot: false, to: { tab: "queue", state: "running" } },
  { key: "needs", label: "needs you", value: "2", hot: true, to: { tab: "queue", state: "needs you" } },
  { key: "done", label: "done 24h", value: "9", hot: false, to: { tab: "queue", state: "done" } },
  { key: "drain", label: "drain", value: "6h +4/-9 shrinking", hot: false, to: { tab: "queue", state: "" } },
].map((c) => ({ ...c, ...(over[c.key] || {}) }));
const drawStrip = (strip, grafana = null) => vm.runInContext(`qfl.data = ${JSON.stringify(strip && { flow: strip, grafana })}; qfl.err = null; qStrip()`, ctx);

test("the strip draws every chip as a link to the Queue on its filter, the board to Projects", () => {
  const html = drawStrip({ chips: chips(), bottleneck: "bottleneck: waiting, age p90 9h (bound 4h)", as_of: "10:20", error: null }, "https://g.example");
  assert.match(html, /<a class="cchip fchip" href="#queue\?s=up%20next" data-flow="queued">queued 3 \(2 ready\)<\/a>/);
  assert.match(html, /href="#queue\?s=running" data-flow="running">running 5</);
  assert.match(html, /href="#queue\?s=needs%20you"[^>]*>needs you 2</);
  assert.match(html, /href="#queue" data-flow="drain">drain 6h \+4\/-9 shrinking</);
  assert.match(html, /href="#projects" data-flow="board">board 312</);
  assert.match(html, /<span class="cchip fchip" data-flow="inbox">inbox 4<\/span>/);
});

test("only the chip of a step past its bound is amber, and the bottleneck and graph link show", () => {
  const html = drawStrip({ chips: chips(), bottleneck: "bottleneck: waiting, age p90 9h (bound 4h)", as_of: "10:20", error: null }, "https://g.example");
  assert.equal((html.match(/fchip warn/g) || []).length, 1);
  assert.match(html, /fchip warn" href="#queue\?s=needs%20you"/);
  assert.match(html, /<div class="qwarn">! bottleneck: waiting, age p90 9h \(bound 4h\)<\/div>/);
  assert.match(html, /inbox, board as of 10:20/);
  assert.match(html, /href="https:\/\/g\.example\/d\/kb-agents-overview"/);
});

test("negative control: absent gauges draw inbox - and board - , never 0, with no amber or link", () => {
  const html = drawStrip({ chips: chips({ inbox: { value: null }, board: { value: null }, needs: { hot: false } }), bottleneck: null, as_of: null, error: null, absent: true });
  assert.match(html, />inbox -</);
  assert.match(html, />board -</);
  assert.doesNotMatch(html, /inbox 0|board 0|fchip warn|qwarn|href="https:/);
  assert.match(html, /inbox, board: no gauges/);
});

test("a failed read says why beside the strip, and no data yet says reading", () => {
  assert.match(drawStrip({ chips: chips({ inbox: { value: null }, board: { value: null } }), bottleneck: null, as_of: null, error: "no prom" }), /inbox, board: no prom/);
  assert.match(drawStrip(null), /class="flow muted">reading</);
});

const col = (key, sort = null, next = [key, "desc"]) => ({ key, sort, next_sort: next[0], next_dir: next[1] });
// The shape hub_core::table::Summary serializes to for the Queue table: opened in its own order
// (no sort key marked), chips from the states, every column sortable.
const table = {
  q: "", state: "", sort: "", dir: "", total: 4, shown: 3,
  states: [{ name: "all", n: 3 }, { name: "needs you", n: 1 }, { name: "running", n: 1 }, { name: "up next", n: 1 }, { name: "done", n: 0 }],
  columns: ["state", "in", "wait", "run", "project", "kind", "size", "acct", "pr", "title"].map((k) => col(k)),
  facets: [],
};
const item = (slug, o = {}) => ({ state: "queued", project: "dotfiles", slug, title: `title ${slug}`, priority: "high", ...o });
const items = [
  item("w1", { state: "waiting", type: "feat", size: "m", account: "k1", timing: { in_state: 130, wait: 5, run: 70 } }),
  item("r1", { state: "running", pr: "o/r#7", pr_label: "r#7", pr_url: "https://github.com/o/r/pull/7", timing: { in_state: 42, wait: 3, run: 42 } }),
  item("q1", { timing: { in_state: 10 } }),
];
const data = { at: 1793942700, items, table, needs_you: 1, open_rows: 200, section_aliases: { waiting: "needs you", running: "running", queued: "up next", done: "done" } };
const load = (d = data, over = {}) => {
  run("st.tab = 'queue'; st.arg = ''; st.views.queue = ''");
  Object.assign(run("qst"), { items: d.items, table: d.table, aliases: d.section_aliases, needs: d.needs_you, openRows: d.open_rows, all: false, sel: "", err: null, stats: {}, ...over });
};
const draw = () => { ctx.listEl = parts["q-list"]; run("drawQueueList(listEl)"); return parts["q-list"].innerHTML; };
const target = (attrs, row) => ({
  dataset: attrs,
  closest: (sel) => (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) ? { dataset: attrs }
    : sel === "tr.qr" && row ? { dataset: { slug: row } } : null,
});

test("the Queue is one table with the server's chips and every header a sort button", () => {
  load();
  const h = draw();
  assert.match(h, /<button class="on" data-ts="">all <span class="n">3<\/span><\/button>/, "no chip is every row");
  assert.match(h, /<button class="" data-ts="needs you">needs you <span class="n">1<\/span><\/button>/);
  assert.match(h, /<button class="" data-ts="up next">up next <span class="n">1<\/span><\/button>/);
  for (const c of ["state", "in", "wait", "run", "project", "kind", "size", "acct", "pr", "title"]) {
    assert.match(h, new RegExp(`<th[^>]*><button class="thsort" data-tsort="${c}" data-tdir="desc" title="sort by ${c}">`), `${c} sorts`);
  }
  assert.ok(h.indexOf("title w1") < h.indexOf("title r1") && h.indexOf("title r1") < h.indexOf("title q1"), "the server's order is kept");
  assert.match(h, /id="sec-flow"/);
  assert.match(h, /id="sec-table"/);
  assert.match(h, /id="sec-candidates"/);
  assert.match(h, /3 of 4/);
});

test("a sorted header says its direction, and the number columns are n", () => {
  load({ ...data, table: { ...table, sort: "run", dir: "desc", columns: table.columns.map((c) => (c.key === "run" ? { ...c, sort: "desc", next_dir: "asc", next_sort: "run" } : c)) } });
  const h = draw();
  assert.match(h, /<th class="n qx" aria-sort="descending"><button class="thsort" data-tsort="run" data-tdir="asc" title="sort by run">run v<\/button><\/th>/);
  assert.match(h, /<th class="n"><button[^>]*>in<\/button><\/th>/);
});

test("in, wait and run are the server's timing minutes, and no timing reads -", () => {
  load();
  let h = draw();
  assert.match(h, /<td class="n">2h10<\/td><td class="n qx">5m<\/td><td class="n qx">1h10<\/td>/);
  assert.match(h, /<td class="n">42m<\/td><td class="n qx">3m<\/td><td class="n qx">42m<\/td>/);
  // Negative control: a running item with only stamps, no timing, works out nothing.
  load({ ...data, items: [item("n1", { state: "running", started: "2026-11-06T11:00:00Z", queued: "2026-11-06T10:00:00Z" })] });
  h = draw();
  assert.match(h, /<td class="n">-<\/td><td class="n qx">-<\/td><td class="n qx">-<\/td>/);
  assert.doesNotMatch(h, /<td class="n">\d/);
});

test("phone width drops all but state, in, project and title by class", () => {
  load();
  const h = draw();
  const heads = [...h.matchAll(/<th( class="([^"]*)")?>/g)].map((m) => (m[2] || "").split(" "));
  const kept = ["state", "in", "project", "title"];
  assert.equal(heads.filter((c) => !c.includes("qx")).length, kept.length);
  assert.match(h, /<td class="qx">feat<\/td>/);
  assert.ok(run("Q_COLS").pr[1].includes("qx") && !run("Q_COLS").title[1]);
});

test("a state cell says what the item is, and how a done one ended", () => {
  load({ ...data, items: [item("a", { state: "waiting" }), item("b", { state: "done", status: "failed" }), item("c", { state: "done", status: "cancelled" }), item("d", { state: "done", status: "ok" })] });
  const h = draw();
  assert.match(h, /<td class="warn">needs<\/td>/);
  assert.match(h, /<td class="bad">failed<\/td>/);
  assert.match(h, /<td class="muted">cancelled<\/td>/);
  assert.match(h, /<td>done<\/td>/);
});

test("the page caps at the server's open_rows with +N older, one click lifts it", () => {
  load({ ...data, open_rows: 2 });
  let h = draw();
  assert.doesNotMatch(h, /title q1/);
  assert.match(h, /<button class="btn sm" data-qall="1">\+1 older<\/button>/);
  fire("click", { type: "click", target: target({ qall: "1" }) });
  h = parts["q-list"].innerHTML;
  assert.match(h, /title q1/);
  assert.doesNotMatch(h, /data-qall/);
});

test("a click on a chip or a header asks the server for that view, and the URL carries it", async () => {
  load();
  asked = [];
  reply = data;
  run("st.views.queue = 'q=dotfiles&sort=run'");
  fire("click", { type: "click", target: target({ ts: "running" }) });
  await settle();
  assert.equal(ctx.history.url, "#queue?q=dotfiles&sort=run&s=running");
  assert.equal(asked.find((u) => u.startsWith("/api/queue?")), "/api/queue?q=dotfiles&s=running&sort=run");
  fire("click", { type: "click", target: target({ tsort: "", tdir: "desc" }) });
  await settle();
  assert.equal(ctx.history.url, "#queue?q=dotfiles&s=running", "the plain sort is a bare URL");
});

test("an old section id opens the table on its chip, once", async () => {
  load();
  asked = [];
  reply = data;
  run("st.tab = 'queue'; st.arg = 'running'; st.views.queue = ''");
  run("refreshQueue()");
  await settle(); await settle();
  assert.equal(ctx.history.url, "#queue?s=running");
  assert.ok(asked.includes("/api/queue?s=running"), "the pre-filtered table is asked for");
  assert.equal(run("st.arg"), "");
  // A view that already names a chip keeps it: the old id does not overwrite what the link said.
  run("st.arg = 'waiting'; st.views.queue = 's=done'");
  run("refreshQueue()");
  await settle(); await settle();
  assert.equal(ctx.history.url, "#queue?s=done");
});

test("a new section id scrolls to its section, not into the filter", async () => {
  load();
  reply = data;
  scrolled = 0;
  run("st.arg = 'candidates'; st.views.queue = ''; st.section = null");
  run("refreshQueue()");
  await settle();
  assert.equal(scrolled, 1, "the page scrolled to Candidates once it drew");
  assert.equal(parts["sec-candidates"].open, true);
  assert.equal(run("st.views.queue"), "", "and no chip was set");
});

test("the badge counts everything waiting on the human, whatever the view keeps", async () => {
  load();
  reply = { ...data, items: [items[1]], needs_you: 3 };
  run("refreshQueue()");
  await settle();
  assert.equal(run("qst.needs"), 3);
});

test("the removed card, day-heading and tile code is gone", () => {
  for (const n of ["qItem", "qDoneDays", "qTiles", "qSorted", "qChip", "qEta", "Q_SECTIONS", "Q_STATE"]) assert.equal(run(`typeof ${n}`), "undefined", n);
});

test("a row opens its detail: every header, the stages with gaps, the task folded", () => {
  const w = item("w1", {
    state: "waiting", type: "feat", size: "m", account: "k1", task: "do the thing", timing: { in_state: 130, wait: 5, run: 70 },
    timeline: [{ step: "queued", at: "2026-11-06T10:00:00Z", gap_min: null }, { step: "started", at: "2026-11-06T10:05:00Z", gap_min: 5 }, { step: "merged", at: null, gap_min: null, sha: "abcdef0123456" }],
  });
  load({ ...data, items: [w] });
  fire("click", { type: "click", target: target({}, "w1") });
  const h = parts["q-list"].innerHTML;
  assert.match(h, /Item <span class="muted">w1<\/span>/);
  assert.match(h, /queued [^>]*? -> started [^>]*? \(\+5m\) -> merged abcdef01/);
  assert.match(h, /<details class="cfold" data-k="task:w1"><summary>Full task and details<\/summary><dl>/);
  for (const k of ["state", "in state", "wait", "run", "project", "kind", "size", "acct"]) assert.match(h, new RegExp(`<dt>${k}</dt>`), k);
  assert.match(h, /<dd>2h10<\/dd>/);
  assert.match(h, /do the thing/);
  fire("click", { type: "click", target: target({}, "w1") });
  assert.doesNotMatch(parts["q-list"].innerHTML, /Item <span/, "the same row again shuts it");
});

test("cancel and the priority select are for an active item only, cancel asks twice", async () => {
  load({ ...data, items: [item("a1", { state: "running" }), item("d1", { state: "done", status: "ok", pr: "o/r#7", pr_label: "r#7", pr_merged: true, cost_label: "$6.10" })] });
  run("qst.sel = 'a1'");
  let h = draw();
  assert.match(h, /data-cancel="a1">Stop and cancel</);
  assert.match(h, /data-bump="a1"/);
  run("qst.sel = 'd1'");
  h = draw();
  assert.doesNotMatch(h, /data-cancel|data-bump/);
  assert.match(h, /PR r#7 merged/);
  assert.match(h, /\$6\.10/);
  // Two clicks: the first only arms it.
  asked = []; reply = {};
  const t = { dataset: { cancel: "a1" }, closest: () => null, textContent: "" };
  fire("click", { type: "click", target: t });
  assert.equal(t.textContent, "Click again to cancel");
  assert.ok(!asked.includes("/api/queue/cancel"));
  fire("click", { type: "click", target: t });
  await settle();
  assert.ok(asked.includes("/api/queue/cancel"));
});

test("negative control: an item with no PR and no report is flagged, and an unknown cost reads -", () => {
  load({ ...data, items: [item("u1", { state: "done", status: "ok", unproven: true })] }, { sel: "u1" });
  const h = draw();
  assert.match(h, /class="qbad"[^>]*>! no PR, no proof</);
  assert.match(h, /<span title="dollars[^>]*>-<\/span>/);
  assert.doesNotMatch(h, /\$0/);
});

test("a PR with no recorded merge says so, and a bare older number keeps its words", () => {
  load({ ...data, items: [item("m1", { state: "done", pr: "o/r#7", pr_label: "r#7", pr_url: "u", pr_merged: false }), item("m2", { state: "done", pr: "1796", pr_label: "#1796", pr_url: null })] }, { sel: "m1" });
  assert.match(draw(), /PR <a href="u"[^>]*>r#7<\/a> merge not recorded/);
  run("qst.sel = 'm2'");
  assert.match(draw(), /PR #1796 merge not recorded/);
});

test("a row with a PR links it in the PR cell", () => {
  load();
  assert.match(draw(), /<td class="qx"><a href="https:\/\/github\.com\/o\/r\/pull\/7"[^>]*>r#7<\/a><\/td>/);
});
