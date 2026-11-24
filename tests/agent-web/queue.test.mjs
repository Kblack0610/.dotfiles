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
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ||= []).push(f); }, querySelectorAll: (q) => (q.includes("sec-") ? [parts["sec-candidates"]] : []) });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
let scrolled = 0;
const parts = { "sec-candidates": { id: "sec-candidates", tagName: "DETAILS", open: false, scrollIntoView() { scrolled++; } }, "qt-head": part(), "qt-facets": part(), "qt-tiles": part(), "qt-body": part(), "q-list": part(), ...Object.fromEntries(["head", "facets", "tiles", "body", "tail", "fold", "sum"].map((k) => [`qc-${k}`, part()])) };
const doc = { getElementById: (id) => (id === "queue" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
let asked = [], posted = [];
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
  fetch: async (url, o) => { asked.push(url); if (o && o.body) posted.push(`${url} ${o.body}`); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => (url.startsWith("/api/flow") ? { line: rail(), grafana: null } : typeof reply === "function" ? reply(url) : reply) }; },
});
for (const f of ["../../web-kit/kb-ui.js", "ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "flow.js", "jobs.js", "waiting.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const settle = () => new Promise((r) => setImmediate(r));

// The shape hub_core::flow::Rail serializes to.
const node = (key, label, o = {}) => ({ key, label, count: "4", sub: "p90 2h", hot: false, stopped: false, to: null, stop: null, facts: [], problems_n: 0, problems: [], gap: null, elsewhere: null, ...o });
const nodes = (over = {}) => [
  node("inbox", "inbox", { count: "1", sub: "ok" }),
  node("backlog", "agent backlog", { count: "312" }),
  node("queued", "queued", { count: "272", hot: true, stopped: true, stop: "Dispatch stopped 9h50m", facts: ["272 items, bound 12h (5.7x)"], to: { tab: "queue", state: "ready", section: "next" } }),
  node("running", "running", { count: "9", problems_n: 11, problems: [{ text: "01:16  ucp-412  failed  died", item: "ucp-412" }, { text: "00:01  a line  refused  no", item: null }], to: { tab: "queue", state: "running", section: "running" } }),
  node("needs", "needs you", { count: "2", hot: true }),
  node("done", "done 24h", { count: "9" }),
].map((n) => ({ ...n, ...(over[n.key] || {}) }));
const rail = ({ nodes: over, ...o } = {}) => ({ nodes: nodes(over), worst: 2, as_of: "10:20", stale: false, reading: false, error: null, absent: false, ...o });
const drawStrip = (line, grafana = null, picked = "") => vm.runInContext(`qfl.data = ${JSON.stringify(line && { line, grafana })}; qfl.err = null; qfl.node = ${JSON.stringify(picked)}; qStrip()`, ctx);

test("the line draws a point per step and opens no detail until one is picked", () => {
  const html = drawStrip(rail(), "https://g.example");
  assert.equal((html.match(/data-rail="/g) || []).length, 6);
  assert.match(html, /class="rnode stopped" data-rail="queued"/);
  assert.equal((html.match(/rdetail/g) || []).length, 0, "the line is one row");
  assert.match(html, /as of 10:20/);
  assert.match(html, /href="https:\/\/g\.example\/d\/kb-agents-overview"/);
  const open = drawStrip(rail(), null, "queued");
  assert.match(open, /class="rnode stopped sel" data-rail="queued"/);
  assert.match(open, /<div class="rstop">Stopped: Dispatch stopped 9h50m<\/div>/);
  assert.match(open, /272 items, bound 12h \(5\.7x\)/);
  assert.match(open, /<a class="glink" href="#queue\/next">open<\/a>/, "a step with no problems links its section");
  assert.equal((open.match(/rdetail/g) || []).length, 1);
});

test("amber is a step past its bound, red one nothing can leave, and a problem alone is neither", () => {
  const html = drawStrip(rail());
  assert.match(html, /class="rnode hot" data-rail="needs"/);
  assert.match(html, /class="rnode stopped" data-rail="queued"/);
  assert.match(html, /class="rnode" data-rail="running"/);
});

test("a picked step opens its problems, five at most behind a count, and one that names an item links it", () => {
  const html = drawStrip(rail(), null, "running");
  assert.match(html, /class="rnode sel" data-rail="running"/);
  assert.match(html, /Problems, 24h: 11 <a class="glink" href="#queue\/running">open<\/a>/);
  assert.match(html, /<a class="rprob" href="#queue\?q=ucp-412">01:16  ucp-412  failed  died<\/a>/);
  assert.match(html, /<span class="rprob">00:01  a line  refused  no<\/span>/);
  const long = Array.from({ length: 8 }, (_, i) => ({ text: `p${i}`, item: null }));
  const many = drawStrip(rail({ nodes: { running: { problems_n: 8, problems: long } } }), null, "running");
  assert.equal((many.match(/class="rprob"/g) || []).length, 5);
  assert.match(many, /and 3 more/);
  assert.doesNotMatch(drawStrip(rail({ nodes: { running: { problems_n: 5, problems: long.slice(0, 5) } } }), null, "running"), /more</, "the control: five problems say nothing more");
  fire("click", { target: { id: "", closest: (q) => (q === "[data-rail]" ? { dataset: { rail: "needs" } } : null) } });
  assert.equal(run("qfl.node"), "needs");
  fire("click", { target: { id: "", closest: (q) => (q === "[data-rail]" ? { dataset: { rail: "needs" } } : null) } });
  assert.equal(run("qfl.node"), "", "the same step again shuts it");
  assert.equal((drawStrip(rail(), null, "gone").match(/rdetail/g) || []).length, 0, "a step no longer there opens nothing");
});

test("negative control: no snapshot draws inbox - and agent backlog -, never 0, and says so", () => {
  const html = drawStrip(rail({ as_of: null, absent: true, nodes: { inbox: { count: null }, backlog: { count: null } } }));
  assert.match(html, /<span class="rcount">-<\/span><span class="rlabel">inbox/);
  assert.match(html, /<span class="rcount">-<\/span><span class="rlabel">agent backlog/);
  assert.match(html, /inbox, agent backlog: no snapshot/);
  assert.doesNotMatch(html, /href="https:/);
});

test("a stale or ageless snapshot is red, a failed read says why, and no data yet says reading", () => {
  assert.match(drawStrip(rail({ stale: true })), /<span class="rstop">as of 10:20 \(stale\)<\/span>/);
  assert.match(drawStrip(rail({ stale: true, as_of: null })), /<span class="rstop">age unknown<\/span>/);
  assert.match(drawStrip(rail({ error: "snapshot cannot be read", as_of: null })), /inbox, agent backlog: snapshot cannot be read/);
  assert.match(drawStrip(null), /class="flow muted">reading</);
});

// hub_core::queue's COLUMNS, title first. The server sends them all with every section; the page
// draws the ones its section labels (queue.js Q_COLS).
const QCOLS = ["#", "title", "project", "priority", "state", "hold", "from", "in", "wait", "run", "pr", "row", "kind", "size", "pts", "acct", "mode", "plan"];
const col = (key, sort = null, next = [key, "desc"]) => ({ key, sort, next_sort: next[0], next_dir: next[1] });
// The shape hub_core::table::Summary serializes to for one section: its own sort and page, no
// chips, no facets (the bar holds them).
const tab = (n, o = {}) => ({ q: "", state: "", sort: "", dir: "", total: n, shown: n, states: [], columns: QCOLS.map((k) => col(k)), facets: [], ...o });
// The one search bar's summary: the search and the facets, no chips and no columns.
const table = { q: "", state: "", sort: "", dir: "", total: 4, shown: 3, states: [], columns: [], facets: [] };
const item = (slug, o = {}) => ({ state: "queued", project: "dotfiles", slug, title: `title ${slug}`, priority: "high", ...o });
// The section that holds an item (hub_core::queue::Section), worst first.
const SECS = [["needs", "Needs you", "nd"], ["stuck", "Stuck", "sk"], ["running", "Running", "rn"], ["pr", "On a PR", "pr"], ["next", "Up next", "nx"]];
const secOf = (i) => (i.state === "waiting" ? "needs" : i.stuck ? "stuck" : i.state === "running" ? "running" : i.state === "review" ? "pr" : i.state === "queued" ? "next" : null);
const sections = (list, over = {}) => SECS.map(([id, title, pre]) => {
  const its = list.filter((i) => secOf(i) === id);
  return { id, title, pre, items: its, table: tab(its.length, over[id]) };
});
const items = [
  item("w1", { state: "waiting", type: "feat", size: "m", account: "k1", waits_for: "ask OBAJTo", timing: { in_state: 130, wait: 5, run: 70 } }),
  item("r1", { state: "running", pr: "o/r#7", pr_label: "r#7", pr_url: "https://github.com/o/r/pull/7", timing: { in_state: 42, wait: 3, run: 42 } }),
  item("q1", { timing: { in_state: 10 } }),
];
const data = { at: 1793942700, sections: sections(items), table, needs_you: 1, done_today: 9, cancelled_today: 2, finished_at: "#log/work", sel: null };
// The server's answer for these rows; `rest` adds to the answer, `over` to a section's summary.
const answer = (list, { over, rest } = {}) => ({ ...data, sections: sections(list, over), ...rest });
// `load({ items })` seats the sections these rows fall in; a finished row a link opened is `opened`.
const load = (d = data, over = {}) => {
  run("st.tab = 'queue'; st.arg = ''; st.views.queue = ''; Object.assign(qcd, { data: null, err: null, msg: '', promoting: null })");
  Object.assign(run("qst"), { sections: d.items ? sections(d.items, d.over) : d.sections, table: d.table || table, needs: d.needs_you ?? 1, done: d.done_today ?? 9, cancelled: d.cancelled_today ?? 2, finishedAt: "#log/work", sel: "", selRow: null, err: null, stats: {}, flow: [], open: {}, hist: {}, candCounts: null, candErr: null, ...over });
};
const opened = (i) => load({ items: [] }, { sel: i.slug, selRow: i });
const draw = () => { run("qst.render()"); return parts["q-list"].innerHTML; };
test("Queue search keeps focus, text and selection across queue, candidates and flow refreshes", async () => {
  await settle();
  load();
  draw();
  const descriptors = [box, parts["q-list"]].map((parent) => [parent, Object.getOwnPropertyDescriptor(parent, "innerHTML")]);
  // Replacing either ancestor detaches the input and clears browser focus.
  for (const [parent, descriptor] of descriptors) Object.defineProperty(parent, "innerHTML", {
    configurable: true,
    get: () => descriptor.value,
    set: (html) => { descriptor.value = html; doc.activeElement = null; },
  });
  const search = { id: "qt-q", dataset: { tsearch: "" }, value: "title", selectionStart: 1, selectionEnd: 4, closest: () => null };
  doc.activeElement = search;
  reply = (url) => url.startsWith("/api/queue/candidates") ? cands()
    : url.startsWith("/api/queue/stats") ? { line: "updated stats" }
    : answer([item("fresh")], { rest: { table: { ...table, q: "title" } } });
  try {
    fire("input", { type: "input", target: search });
    await settle();
    assert.equal(run("st.views.queue"), "q=title");
    assert.equal(doc.activeElement, search, "the query response keeps focus");
    assert.match(parts["qt-body"].innerHTML, /title fresh/, "the query response repaints the rows");
    for (const refresh of ["refreshQueue", "qcd.refresh", "refreshFlow"]) {
      run(`${refresh}()`);
      await settle();
      assert.equal(doc.activeElement, search, `${refresh} keeps the original input focused`);
      assert.equal(search.value, "title");
      assert.deepEqual([search.selectionStart, search.selectionEnd], [1, 4]);
      assert.match(parts["qt-body"].innerHTML, /title fresh/);
    }
    assert.match(parts["qt-head"].innerHTML, /updated stats/);
  } finally {
    doc.activeElement = null;
    reply = {};
    for (const [parent, descriptor] of descriptors) Object.defineProperty(parent, "innerHTML", descriptor);
  }
});
const target = (attrs, row) => ({
  dataset: attrs,
  closest: (sel) => (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) ? { dataset: attrs }
    : sel === "tr.qr" && row ? { dataset: { slug: row } } : null,
});

test("the Queue is a section per state, worst first, each with only its own columns, and no chip", () => {
  load();
  const h = draw();
  assert.doesNotMatch(h, /class="tile|data-ts=|id="sec-table"/, "the sections are the states: no chip, no one table");
  assert.equal((h.match(/id="qt-q"/g) || []).length, 1, "one search over every section");
  const at = SECS.map(([id]) => h.indexOf(`id="sec-${id}"`));
  assert.ok(at.every((x, i) => x > 0 && (!i || x > at[i - 1])), `worst first: ${at}`);
  assert.match(h, /<h2 class="sec warn" id="sec-needs">Needs you <span class="n">1<\/span><\/h2>/);
  assert.match(h, /<h2 class="sec" id="sec-running">Running <span class="n">1<\/span><\/h2>/);
  assert.match(h, /<h2 class="sec" id="sec-next">Up next <span class="n">1<\/span><\/h2>/);
  const sec = (id) => { const from = h.indexOf(`id="sec-${id}"`), to = h.indexOf("<h2", from + 1); return h.slice(from, to < 0 ? undefined : to); };
  const heads = (id) => [...sec(id).matchAll(/data-label="([^"]*)"/g)].map((m) => m[1]);
  assert.deepEqual(heads("needs"), ["title", "project", "waited", "pr"]);
  assert.deepEqual(heads("running"), ["title", "project", "run", "pr"]);
  assert.deepEqual(heads("next"), ["#", "title", "project", "priority", "waited"]);
  assert.match(sec("running"), /<button class="thsort" data-tsort="run" data-tdir="desc" title="sort by run">/, "a header sorts its section");
  assert.match(sec("next"), /<div data-tbl="nx">/, "a section is its own view, apart from the search");
  assert.match(h, /id="sec-candidates"/);
  // NEGATIVE CONTROL: a state with no row draws its head with 0 and no table.
  assert.match(h, /<h2 class="sec" id="sec-stuck">Stuck <span class="n">0<\/span><\/h2>/);
  assert.ok(!sec("stuck").includes("<table"), "no table for no rows");
});

test("finished work is a count linked to Log, never a section; a count not read draws nothing", () => {
  load();
  assert.match(draw(), /<div class="cline qdone">Done 9, cancelled 2 today <a class="glink" href="#log\/work">open in Log<\/a><\/div>/);
  assert.doesNotMatch(draw(), /id="sec-(done|log)"/);
  load(data, { done: null });
  assert.doesNotMatch(draw(), /qdone|Done \d/, "unread says nothing, never 0");
});

// The shape agent-web's /api/queue/candidates sends: hub_core::table's Summary over every
// Candidate and the first page of rows, with its pager.
const cand = (n, o = {}) => ({ rank: n, key: `ar-${n}`, title: `cand ${n}`, project: "p", profile: "home", lane: "agent", text: `- [ ] cand ${n} #id/ar-${n}`, why: "focus", start_label: "auto", held: false, prio: 2, blocked: [], ...o });
const cands = (o = {}) => ({
  rows: [cand(1), cand(2, { project: "trader", prio: 0, blocked: ["no worker covers trader", "judge: skip, too big"] })],
  table: { q: "", state: "", sort: "", dir: "", total: 41, shown: 41, pager: { page: 1, pages: 2, per: 30 }, legend: "clear: a worker takes it",
    states: [{ name: "all", n: 41 }, { name: "clear", n: 30 }, { name: "blocked", n: 11, tone: "warn" }],
    columns: ["rank", "project", "key", "task", "start", "why", "blocked"].map((k) => col(k)),
    facets: [{ key: "blocked", on: [], clear: "", values: [{ value: "judge: skip", n: 9, on: false, q: 'blocked:"judge: skip"' }] }],
    links: [{ project: "#projects/p" }, { project: "#projects/trader" }] },
  auto: 2, urgent_blocked: 1, uncovered: ["trader"], as_of: "10:20", ...o,
});
const drawCands = (d) => run(`qst.open["sec:candidates"] = true; qcd.data = ${JSON.stringify(d)}; qcd.err = null; qCandidates()`);

test("Candidates is the shared table in its fold: the count heads it, urgent blocked a warn line, every header sorts", () => {
  load();
  try {
    const h = drawCands(cands());
    assert.match(h, /<details class="csec" data-k="sec:candidates" id="sec-candidates" open><summary id="qc-sum"><h2 class="sec warn">Candidates <span class="n">41<\/span><\/h2><\/summary>/);
    assert.match(h, /<div class="cline warn">1 urgent blocked<\/div>/);
    assert.match(h, /<div class="cline warn">Worked on today, and no worker covers a row: trader<\/div>/);
    assert.match(h, /<b>auto<\/b> 2, <b>as of<\/b> 10:20/);
    assert.match(h, /<div data-tbl="c">.*id="qc-q"/s, "its bar sits in its own block, so its keys are c-prefixed");
    assert.match(h, /<button class="tile t-warn" data-ts="blocked"><span class="tl">BLOCKED<\/span><span class="tv">11<\/span><\/button>/);
    for (const c of ["rank", "project", "key", "task", "start", "why", "blocked"]) assert.match(h, new RegExp(`data-tsort="${c}"`), `${c} sorts`);
    assert.match(h, /data-fkey="blocked"/, "each reason is a facet");
    assert.match(h, /<a class="tl" href="#projects\/trader">trader<\/a>/);
    assert.match(h, /<span class="cchip bad">judge: skip, too big<\/span>/);
    assert.match(h, /data-promote="2"/, "Promote names the row by its rank");
    assert.match(h, /<span class="muted" aria-live="polite">rows 1-30 of 41<\/span><\/nav>/, "the pager sits under the rows");
    assert.doesNotMatch(h, /data-all/, "the rows are drawn as sent, with no more button");
    const calm = drawCands(cands({ urgent_blocked: 0, table: { ...cands().table, total: 41, shown: 3 } }));
    assert.match(calm, /<h2 class="sec">Candidates <span class="n">3 of 41<\/span><\/h2>/);
    assert.doesNotMatch(calm, /urgent/, "the control: no blocked urgent row, no line");
    assert.match(run("qcd.data = null; qcd.err = 'boom'; qCandidates()"), /<h2 class="sec bad">Candidates<\/h2><\/summary><div id="qc-fold"><div class="panel down">No candidates: boom<\/div>/);
  } finally { run("qcd.data = null; qcd.err = null"); }
});

test("a Candidates search asks the server with its own keys, and a page pick asks for that page", async () => {
  load();
  asked = [];
  reply = (url) => (url.startsWith("/api/queue/candidates") ? cands() : data);
  try {
    run("qcd.data = null");
    const search = { id: "qc-q", dataset: { tsearch: "" }, value: "trader", closest: (q) => (q === "[data-tbl]" ? { dataset: { tbl: "c" } } : null) };
    fire("input", { type: "input", target: search });
    await settle();
    assert.equal(run("st.views.queue"), "cq=trader", "the queue's own keys stay bare");
    assert.ok(asked.includes("/api/queue/candidates?cq=trader"), asked.join(" "));
    assert.ok(!asked.some((u) => u.startsWith("/api/queue?")), "the queue is not re-read");
    asked = [];
    const pg = { dataset: { tpg: "2" } };
    fire("click", { type: "click", target: { dataset: { tpg: "2" }, closest: (q) => (q === "[data-tbl]" ? { dataset: { tbl: "c" } } : q === "[data-tpg]" ? pg : null) } });
    await settle();
    assert.equal(run("st.views.queue"), "cq=trader&cpg=2");
    assert.ok(asked.includes("/api/queue/candidates?cq=trader&cpg=2"), asked.join(" "));
  } finally { reply = {}; run("st.views.queue = ''; qcd.data = null"); }
});

test("Promote starts the row its rank names, when another row shares its key", async () => {
  load();
  posted = [];
  reply = (url) => (url.startsWith("/api/board") ? { out: "promoted ar-2" } : url.startsWith("/api/queue/candidates") ? cands() : data);
  try {
    // Negative control: a key is a row's text when it has no id, so two rows can share one.
    const d = cands();
    d.rows[0].key = d.rows[1].key;
    run(`qcd.data = ${JSON.stringify(d)}`);
    fire("click", { type: "click", target: { id: "", dataset: { promote: "2" }, closest: () => null } });
    await settle();
    const [p] = posted;
    assert.match(p, /^\/api\/board /);
    assert.deepEqual(JSON.parse(p.slice(p.indexOf(" ") + 1)), { verb: "start", profile: "home", project: "trader", lane: "agent", raw: "- [ ] cand 2 #id/ar-2" });
    assert.equal(run("qcd.msg"), "promoted ar-2");
  } finally { reply = {}; run("qcd.data = null; qcd.msg = ''"); }
});

test("Candidates heads the counts read's total until its rows are read; a failed counts read is said once, open or shut", () => {
  const counts = { total: 5, auto: 2, urgent_blocked: 1, as_of: "10:20" };
  load(data, { candCounts: counts });
  run("qcd.data = null; qcd.err = null");
  assert.match(run("qCandidates()"), /<summary id="qc-sum"><h2 class="sec warn">Candidates <span class="n">5<\/span><\/h2><\/summary><div id="qc-fold"><\/div><\/details>/);
  const calm = run(`qst.candCounts = ${JSON.stringify({ ...counts, urgent_blocked: 0 })}; qCandidates()`);
  assert.match(calm, /<h2 class="sec">Candidates <span class="n">5<\/span><\/h2>/);
  // A failed read is said in the heading, so a shut fold shows it too, and once.
  for (const open of [true, false]) {
    const bad = run(`qst.open['sec:candidates'] = ${open}; qst.candCounts = null; qcd.err = 'boom'; qst.candErr = 'boom'; qCandidates()`);
    assert.match(bad, /<summary id="qc-sum"><h2 class="sec bad">Candidates<\/h2><div class="panel down">No candidates: boom<\/div><\/summary>/);
    assert.equal(bad.match(/boom/g).length, 1, bad);
  }
  run("qcd.err = null; qst.candErr = null; qst.candCounts = null");
});

test("Pipeline is said once: the worst step hues the head and is a warn line under it", () => {
  load();
  try {
    const h = run(`qfl.data = ${JSON.stringify({ line: rail() })}; qfl.err = null; qfl.node = ""; qFlow()`);
    assert.equal(h.match(/Pipeline/g).length, 1, h);
    assert.match(h, /<summary><h2 class="sec warn" id="sec-flow">Pipeline<\/h2><\/summary><div class="cline warn">queued stopped<\/div>/);
    const calm = run(`qfl.data = ${JSON.stringify({ line: rail({ nodes: { queued: { hot: false, stopped: false } } }) })}; qFlow()`);
    assert.match(calm, /<summary><h2 class="sec" id="sec-flow">Pipeline<\/h2><\/summary><div class="flow">/, "the control: nothing past its bound, no line");
  } finally { run("qfl.data = null"); }
});

test("a sorted header says its direction, and the number columns are n", () => {
  const sorted = (c) => ({ ...c, sort: "desc", next_dir: "asc", next_sort: "run" });
  load({ items, over: { running: { sort: "run", dir: "desc", columns: QCOLS.map((k) => (k === "run" ? sorted(col(k)) : col(k))) } } });
  const h = draw();
  assert.match(h, /<th class="n" aria-sort="descending" data-role="" data-label="run"><button class="thsort" data-tsort="run" data-tdir="asc" title="sort by run">run v<\/button><\/th>/);
  assert.match(h, /<th class="n"[^>]*><button[^>]*>waited<\/button><\/th>/);
});

test("in and run are the server's timing minutes, and no timing reads -", () => {
  load();
  let h = draw();
  assert.match(h, /data-slug="w1">.*?<td class="n">2h10<\/td>/, "needs you: the time it has waited");
  assert.match(h, /data-slug="r1">.*?<td class="n">42m<\/td>/, "running: its run");
  // Negative control: a running item with only stamps, no timing, works out nothing.
  load({ items: [item("n1", { state: "running", started: "2026-11-06T11:00:00Z", queued: "2026-11-06T10:00:00Z" })] });
  h = draw();
  assert.match(h, /data-slug="n1">.*?<td class="n">-<\/td>/);
  assert.doesNotMatch(h, /<td class="n">\d/);
});

test("a stuck row is amber with the server's word, its why under the title and on hover; a fine one has no state cell", () => {
  load({ items: [
    item("s", { state: "running", state_word: "stalled", stuck: true, state_why: "STALLED 42m idle: PR #7 CI red" }),
    item("n", { state: "running", state_word: "no session", stuck: true, state_why: "no session works it" }),
    item("p", { state: "review", state_word: "PR red, escalated", stuck: true }),
    item("w", { state: "running", state_word: "running", state_why: "WORKING 1m idle: idle 1m" }),
    item("o", { state: "review", state_word: "on a PR" }),
  ] });
  const h = draw();
  assert.match(h, /<td class="warn" title="STALLED 42m idle: PR #7 CI red">stalled<\/td>/);
  assert.match(h, /<td class="warn" title="no session works it">no session<\/td>/);
  assert.match(h, /<td class="warn">PR red, escalated<\/td>/);
  assert.match(h, /<div class="c1 muted" title="STALLED 42m idle: PR #7 CI red">STALLED 42m idle: PR #7 CI red<\/div>/, "the why is the title's second line");
  // Negative controls: a working session and a plain PR leave the stuck section and draw no amber.
  assert.equal((h.match(/<td class="warn"/g) || []).length, 3);
  assert.doesNotMatch(h, /WORKING|>on a PR<\/td>/);
});

test("a finished item a link opened says how it ended, and who cancelled it and why", () => {
  const why = "cancelled by 9fd0d2fd: dead chain";
  opened(item("c", { state: "done", status: "cancelled", state_word: "cancelled", state_why: why, cancelled_by: "9fd0d2fd", cancel_why: "dead chain" }));
  const h = draw();
  assert.match(h, /<h2 class="sec">Opened<\/h2>/);
  assert.match(h, /done, cancelled/);
  assert.match(h, /cancelled by<\/[^>]+>[^]*9fd0d2fd/);
  assert.match(h, /cancel reason<\/[^>]+>[^]*dead chain/);
  // negative control: a finish that ran has no such line
  opened(item("d", { state: "done", status: "ok" }));
  assert.doesNotMatch(draw(), /cancelled by/);
  // a finished item a section holds is not drawn twice, and none is opened with no link
  load();
  assert.doesNotMatch(draw(), />Opened</);
});

test("an up-next row has its start place, priority and wait; an old hold line changes nothing", () => {
  load({ items: [item("r", { state: "queued", start: 1, priority: "urgent", timing: { in_state: 65 } }), item("h", { state: "queued", hold: "after r" })] });
  const h = draw();
  assert.match(h, /<tr class="qr" data-slug="r"><td class="n">1<\/td><td class="btitle"><div class="c12" title="title r"><span class="bt">title r<\/span><\/div><\/td><td>[^]*?<\/td><td class="warn">urgent<\/td><td class="n">1h05<\/td><\/tr>/);
  assert.match(h, /<tr class="qr" data-slug="h"><td class="n"><\/td>/, "negative control: no start place, no number");
  assert.doesNotMatch(h, /held|after r|Legend|<td>ready<\/td>/, "no chip, so no legend and no state cell");
});

test("a section draws the page the server sends with its own pager, and a table that fits draws none", () => {
  load({ items: items.slice(2), over: { next: { total: 3, shown: 3, pager: { page: 1, pages: 2, per: 1 } } } });
  const h = draw();
  assert.match(h, /<div data-tbl="nx">.*data-tpg="2"[^>]*>next<\/button><span class="muted" aria-live="polite">rows 1-1 of 3<\/span>/);
  assert.doesNotMatch(h, /data-all/);
  // Negative control: one page draws no pager.
  load();
  assert.doesNotMatch(draw(), /tpager/);
});

test("a link to an item asks for the page that holds it, and the URL keeps that page of its section", async () => {
  load();
  asked = [];
  reply = answer(items, { over: { next: { pager: { page: 3, pages: 3, per: 1 } } } });
  try {
    run("st.tab = 'queue'; st.arg = 'q1'; st.views.queue = ''; refreshQueue()");
    await settle();
    assert.ok(asked.includes("/api/queue?sel=q1"), asked.join(" "));
    assert.equal(run("qst.sel"), "q1");
    assert.equal(run("st.views.queue"), "nxpg=3", "a re-read stays on the item's page of its own section");
    asked = [];
    run("refreshQueue()");
    await settle();
    assert.ok(asked.includes("/api/queue?nxpg=3"), "with no link the view's page is read, no sel: " + asked.join(" "));
  } finally { reply = {}; run("st.arg = ''; st.views.queue = ''"); }
});

test("a header sorts its own section and a page pick pages it, under its prefix; a search is the tab's and restarts every page", async () => {
  load();
  asked = [];
  reply = data;
  run("st.views.queue = 'q=dotfiles'");
  const inTbl = (pre, own) => ({ dataset: own, closest: (q) => (q === "[data-tbl]" ? { dataset: { tbl: pre } } : q === "[data-tsort]" && "tsort" in own ? { dataset: own } : q === "[data-tpg]" && "tpg" in own ? { dataset: own } : null) });
  fire("click", { type: "click", target: inTbl("rn", { tsort: "run", tdir: "desc" }) });
  await settle();
  assert.equal(ctx.history.url, "#queue?q=dotfiles&rnsort=run");
  assert.equal(asked.find((u) => u.startsWith("/api/queue?")), "/api/queue?q=dotfiles&rnsort=run");
  fire("click", { type: "click", target: inTbl("nx", { tpg: "2" }) });
  await settle();
  assert.equal(ctx.history.url, "#queue?q=dotfiles&rnsort=run&nxpg=2");
  assert.equal(asked.filter((u) => u.startsWith("/api/queue?")).pop(), "/api/queue?q=dotfiles&rnsort=run&nxpg=2", "the read carries every section's keys");
  // A new search starts every section at its first page and keeps the sorts.
  fire("input", { type: "input", target: { id: "qt-q", dataset: { tsearch: "" }, value: "x", closest: () => null } });
  await settle();
  assert.equal(ctx.history.url, "#queue?q=x&rnsort=run");
  // The plain sort is a bare key.
  fire("click", { type: "click", target: inTbl("rn", { tsort: "", tdir: "desc" }) });
  await settle();
  assert.equal(ctx.history.url, "#queue?q=x");
  reply = {}; run("st.views.queue = ''");
});

test("a state id scrolls to its section, once, and sets no filter", async () => {
  load();
  reply = data;
  for (const id of ["stuck", "needs"]) {
    run(`st.tab = 'queue'; st.arg = '${id}'; st.views.queue = ''; st.section = null`);
    run("refreshQueue()");
    await settle(); await settle();
    assert.equal(run("st.section"), id, "the section to scroll to");
    assert.equal(run("st.arg"), "");
    assert.equal(run("st.views.queue"), "", "a section id is not a chip");
  }
  // A chip in the URL still narrows what the sections hold.
  asked = [];
  run("st.arg = ''; st.views.queue = 's=ready'");
  run("refreshQueue()");
  await settle();
  assert.ok(asked.includes("/api/queue?s=ready"), asked.join(" "));
  reply = {}; run("st.views.queue = ''");
});

test("an item's slug opens that item; one outside the view is searched for once", async () => {
  load();
  asked = [];
  const slug = items[0].slug;
  reply = data;
  run(`st.tab = 'queue'; st.arg = '${slug}'; st.views.queue = ''`);
  run("refreshQueue()");
  await settle(); await settle();
  assert.equal(run("qst.sel"), slug, "the item's record opens");
  assert.equal(run("st.arg"), "");
  // Not in this view: the tab searches for it, and the read that has it opens it.
  reply = (url) => (url.includes("q=gone") ? answer([{ ...items[0], slug: "gone" }]) : answer([]));
  run("qst.sel = ''; st.arg = 'gone'; st.views.queue = 's=done'");
  run("refreshQueue()");
  await settle(); await settle(); await settle();
  assert.ok(asked.some((u) => u.startsWith("/api/queue?q=gone")), asked.join(" "));
  assert.equal(run("qst.sel"), "gone");
  // An unknown slug searches once and then gives up, with the sections still drawn.
  reply = answer([]);
  run("qst.sel = ''; st.arg = 'nowhere'; st.views.queue = ''");
  run("refreshQueue()");
  await settle(); await settle(); await settle();
  assert.equal(run("st.arg"), "");
  assert.equal(run("qst.sel"), "");
});

test("a link to a finished item opens it as its own card, since no section holds it", async () => {
  const d = item("d1", { state: "done", status: "ok", pr: "o/r#7", pr_label: "r#7", pr_url: "https://github.com/o/r/pull/7", pr_merged: true, cost_label: "$6.10" });
  load();
  reply = answer([], { rest: { sel: d } });
  run("st.tab = 'queue'; st.arg = 'd1'; st.views.queue = ''; refreshQueue()");
  await settle(); await settle(); await settle();
  assert.equal(run("qst.sel"), "d1");
  const h = parts["q-list"].innerHTML;
  assert.match(h, /<h2 class="sec">Opened<\/h2>/);
  assert.match(h, /PR <a[^>]*>r#7<\/a> merged/);
  assert.doesNotMatch(h, /data-cancel|data-bump/, "a finished item has no actions");
  reply = {}; run("st.arg = ''; st.views.queue = ''");
});

test("a new section id scrolls to its section, not into the filter", async () => {
  load();
  asked = [];
  reply = (url) => url.startsWith("/api/queue/candidates") ? cands({ rows: [], more: 0 }) : data;
  scrolled = 0;
  run("st.tab = 'queue'; st.arg = 'candidates'; st.views.queue = ''; st.section = null");
  run("refreshQueue()");
  await settle(); await settle();
  assert.equal(scrolled, 1, "the page scrolled to Candidates once it drew");
  assert.equal(parts["sec-candidates"].open, true);
  assert.ok(asked.includes("/api/queue/candidates"), "a link to Candidates opens the fold, so it reads them");
  assert.equal(run("st.views.queue"), "", "and no chip was set");
  reply = {};
});

test("shut, Candidates is a heading from its counts read, made after the table's: no rows drawn or read", async () => {
  const counts = { total: 120, auto: 40, urgent_blocked: 3, as_of: "10:20" };
  load(data, { candCounts: counts });
  asked = [];
  reply = (url) => url.startsWith("/api/queue/projects") ? [] : url.startsWith("/api/queue/candidates") ? counts : data;
  const h = draw();
  assert.match(h, /<details class="csec" data-k="sec:candidates" id="sec-candidates"><summary id="qc-sum"><h2 class="sec warn">Candidates <span class="n">120<\/span><\/h2><\/summary><div id="qc-fold"><\/div><\/details>/);
  assert.doesNotMatch(h, /qc-q|qc-body/, "a shut fold builds no rows, chips or search box");
  run("TABS.queue.show()");
  await settle(); await settle(); await settle();
  const cands = asked.filter((u) => u.startsWith("/api/queue/candidates"));
  assert.deepEqual(cands, ["/api/queue/candidates?counts=1"], `show reads the counts and no rows while shut: ${asked.join(" ")}`);
  assert.ok(asked.indexOf("/api/queue") < asked.indexOf(cands[0]), `the table's read goes first: ${asked.join(" ")}`);
  assert.equal(data.candidates, undefined, "the queue read carries no candidates");
  // The snapshot's event reads the counts again, and still no rows while shut.
  asked = [];
  run(`TABS.queue.onEvent({ kind: "candidates" })`);
  await settle();
  assert.deepEqual(asked, ["/api/queue/candidates?counts=1"]);
  asked = [];
  run(`TABS.queue.onEvent({ kind: "queue" })`);
  await settle();
  assert.ok(!asked.some((u) => u.startsWith("/api/queue/candidates")), `a queue event is not the snapshot's: ${asked.join(" ")}`);
  // Negative control: no snapshot draws no count, never a zero.
  load();
  assert.match(draw(), /<h2 class="sec">Candidates<\/h2><\/summary><div id="qc-fold"><\/div><\/details>/);
  reply = {};
});

test("opening Candidates reads them once; a redraw's toggle reads nothing, and shutting drops the rows", async () => {
  load();
  asked = [];
  reply = (url) => url.startsWith("/api/queue/candidates") ? cands({ rows: [cand(1, { title: "a row" })], more: 0 })
    : url.startsWith("/api/queue/projects") ? [] : data;
  const fold = (open) => fire("toggle", { target: { open, dataset: { k: "sec:candidates" } } });
  fold(true);
  await settle();
  assert.deepEqual(asked.filter((u) => u.startsWith("/api/queue/candidates")), ["/api/queue/candidates"]);
  // The read repaints the fold alone (qCandPaint), inside the list the toggle drew open.
  assert.match(parts["q-list"].innerHTML, /data-k="sec:candidates" id="sec-candidates" open>/);
  assert.match(parts["qc-fold"].innerHTML, /id="qc-q"/);
  fold(true);
  await settle();
  assert.equal(asked.filter((u) => u.startsWith("/api/queue/candidates")).length, 1, "the re-inserted open fold does not read again");
  run("TABS.queue.show()");
  await settle(); await settle(); await settle();
  assert.equal(asked.filter((u) => u === "/api/queue/candidates").length, 2, "an open fold reads its rows on show");
  fold(false);
  assert.doesNotMatch(parts["q-list"].innerHTML, /qc-q/);
  assert.equal(run("qcd.data"), null, "a shut fold holds no rows");
  // Reopened, it says it is reading, not the old rows, and reads them.
  let land;
  const later = new Promise((r) => { land = r; });
  reply = (url) => url.startsWith("/api/queue/candidates") ? later : data;
  fold(true);
  assert.match(parts["q-list"].innerHTML, /Reading candidates\.\.\./);
  assert.doesNotMatch(parts["q-list"].innerHTML, /a row/);
  assert.equal(asked.filter((u) => u === "/api/queue/candidates").length, 3);
  fold(true);
  assert.equal(asked.filter((u) => u === "/api/queue/candidates").length, 3, "the redraw's toggle while it reads asks for none");
  land(cands({ rows: [cand(1, { title: "a row" })], more: 0 }));
  await settle(); await settle();
  assert.match(parts["qc-fold"].innerHTML, /a row/);
  fold(false);
  reply = {};
});

test("a toggle stores the fold's own state, so a click a redraw got ahead of still reads", async () => {
  // The map already says open (a redraw re-inserted the fold open before this toggle landed) and
  // no rows are held: the old map compare read nothing and left "Reading candidates..." up.
  load(data, { open: { "sec:candidates": true } });
  asked = [];
  reply = (url) => url.startsWith("/api/queue/candidates") ? cands({ rows: [], more: 0 }) : data;
  fire("toggle", { target: { open: true, dataset: { k: "sec:candidates" } } });
  await settle();
  assert.deepEqual(asked.filter((u) => u.startsWith("/api/queue/candidates")), ["/api/queue/candidates"]);
  // And a shut that lands after a redraw re-inserted it open still shuts it.
  fire("toggle", { target: { open: false, dataset: { k: "sec:candidates" } } });
  assert.equal(run("qCandOpen()"), false);
  reply = {};
});

test("a promote re-reads the counts, and the rows only while the fold is open", async () => {
  for (const open of [false, true]) {
    load(data, { open: { "sec:candidates": open } });
    run(`qcd.data = ${JSON.stringify(cands())}`);
    asked = [];
    reply = (url) => url.startsWith("/api/queue/candidates") ? cands({ rows: [], more: 0 }) : url === "/api/board" ? { out: "ok" } : data;
    await run("qPromote(1)");
    await settle();
    const got = asked.filter((u) => u.startsWith("/api/queue/candidates"));
    assert.deepEqual(got, open ? ["/api/queue/candidates?counts=1", "/api/queue/candidates"] : ["/api/queue/candidates?counts=1"], `open ${open}: ${asked.join(" ")}`);
  }
  reply = {}; run("qcd.data = null; qcd.msg = ''");
});

test("on a phone the pipeline is read only while its fold is open", async () => {
  load();
  asked = [];
  reply = data;
  ctx.matchMedia = () => ({ matches: true });
  try {
    run("delete PFOLD['q-flow']; qfl.open = false; refreshFlow()");
    await settle();
    assert.ok(!asked.some((u) => u.startsWith("/api/flow")), "a shut fold reads no flow");
    run("PFOLD['q-flow'] = true");
    fire("toggle", { target: { open: true, dataset: { pf: "q-flow" } } });
    await settle();
    assert.equal(asked.filter((u) => u.startsWith("/api/flow")).length, 1, "opening it reads the flow");
    // Negative control: on a desktop the fold is always open, so the read happens.
    ctx.matchMedia = () => ({ matches: false });
    run("delete PFOLD['q-flow']; refreshFlow()");
    await settle();
    assert.equal(asked.filter((u) => u.startsWith("/api/flow")).length, 2);
  } finally {
    delete ctx.matchMedia;
    run("qfl.open = false");
    reply = {};
  }
});

test("the badge counts everything waiting on the human, whatever the view keeps", async () => {
  load();
  reply = answer([items[1]], { rest: { needs_you: 3 } });
  run("refreshQueue()");
  await settle();
  assert.equal(run("qst.needs"), 3);
});

test("the title cell is a record cell where a second fact helps: the title over what it needs or why it is stuck, each one line, the whole on hover", () => {
  const long = "x".repeat(400);
  load({ items: [item("n1", { state: "waiting", title: long, waits_for: "ask OBAJTo" }), item("n2", { state: "waiting" }), item("n3", { state: "waiting", title: "" })] });
  let h = draw();
  assert.match(h, new RegExp(`<td class="btitle"><div class="c1" title="${long}"><span class="bt">${long}</span></div><div class="c1 muted" title="ask OBAJTo">ask OBAJTo</div></td>`));
  assert.match(h, /data-slug="n2">.*?<div class="c1 muted" title="">&nbsp;<\/div>/, "no fact: the row keeps its two lines");
  assert.match(h, /data-slug="n3">.*?<div class="c1" title="n3"><span class="bt">n3<\/span><\/div>/, "the slug stands for a title that is not there");
  assert.doesNotMatch(h, /class="(bsum|c2)/, "no clamped block in the queue's cells");
  // Up next says nothing under the title: one line.
  load({ items: [item("u1", { title: long, note: "held for the release" })] });
  h = draw();
  assert.match(h, new RegExp(`<td class="btitle"><div class="c12" title="${long}"><span class="bt">${long}</span></div></td>`));
  // The opened row says the note in full.
  load({ items: [item("u1", { title: long, note: "held for the release" })] }, { sel: "u1" });
  assert.match(draw(), /<tr class="wdet">.*held for the release/s);
});

test("the removed one-table, card, day-heading and tile code is gone", () => {
  for (const k of ["cands", "candReason", "candQ", "candMsg", "promoting", "items", "aliases"]) assert.ok(!(k in run("qst")), `qst.${k}`);
  for (const n of ["qItem", "qDoneDays", "qTiles", "qSorted", "qChip", "qEta", "Q_SECTIONS", "Q_STATE", "qCandShown", "qCandAll", "refreshCands", "CAND_SHOWN", "qAliases"]) assert.equal(run(`typeof ${n}`), "undefined", n);
});

test("a row opens its detail: every header, the stages with gaps, the task folded", () => {
  const w = item("w1", {
    state: "waiting", type: "feat", size: "m", account: "k1", task: "do the thing", timing: { in_state: 130, wait: 5, run: 70 },
    timeline: [{ step: "queued", at: "2026-11-06T10:00:00Z", gap_min: null }, { step: "started", at: "2026-11-06T10:05:00Z", gap_min: 5 }, { step: "merged", at: null, gap_min: null, sha: "abcdef0123456" }],
  });
  load({ items: [w] });
  fire("click", { type: "click", target: target({}, "w1") });
  const h = parts["q-list"].innerHTML;
  assert.match(h, /<tr class="qr sel" data-slug="w1">.*?<\/tr><tr class="wdet"><td colspan="4"><div class="card qitem waiting">/, "the detail opens right under its row, across its section's table");
  assert.match(h, /queued [^>]*? -> started [^>]*? \(\+5m\) -> merged abcdef01/);
  assert.match(h, /<details class="cfold" data-k="task:w1"><summary>Full task and details<\/summary><dl>/);
  for (const k of ["state", "in state", "wait", "run", "project", "kind", "size", "acct"]) assert.match(h, new RegExp(`<dt>${k}</dt>`), k);
  assert.match(h, /<dd>2h10<\/dd>/);
  assert.match(h, /do the thing/);
  fire("click", { type: "click", target: target({}, "w1") });
  assert.doesNotMatch(parts["q-list"].innerHTML, /wdet/, "the same row again shuts it");
});

test("an opened row's History fold starts shut, reads on opening, once, and drops what it read on shutting", async () => {
  load({ items: [item("w1", { state: "review" })] }, { sel: "w1" });
  asked = [];
  const hist = { attempts: 3, steps: 54, lines: [{ at: "2026-11-12T07:04:21-08:00", text: "started on lab:ucp-agent-10, sol on codex" }, { at: "2026-11-12T07:16:54-08:00", text: "PR tries spent, escalated" }] };
  let land;
  reply = (url) => url.startsWith("/api/queue/history") ? new Promise((r) => { land = r; }) : data;
  assert.match(draw(), /<details class="cfold" data-k="hist:w1"><summary>History<\/summary><\/details>/);
  assert.ok(!asked.some((u) => u.startsWith("/api/queue/history")), "a shut fold reads nothing");
  const fold = (open) => fire("toggle", { target: { open, dataset: { k: "hist:w1" } } });
  fold(true);
  assert.match(parts["q-list"].innerHTML, /data-k="hist:w1" open><summary>History<\/summary><div class="muted">Reading history\.\.\.<\/div>/);
  fold(true);
  assert.deepEqual(asked.filter((u) => u.startsWith("/api/queue/history")), ["/api/queue/history?slug=w1"], "the redraw's toggle while it reads asks for none");
  await settle();
  land(hist);
  await settle(); await settle();
  const h = parts["q-list"].innerHTML;
  assert.match(h, /<summary>History, 3 attempts \(54 steps, last 2\)<\/summary><div class="cline"><span class="muted">[^<]+<\/span> started on lab:ucp-agent-10, sol on codex<\/div><div class="cline">.*PR tries spent, escalated/);
  fold(false);
  assert.equal(run("qst.hist.w1"), undefined, "a shut fold holds nothing");
  assert.match(parts["q-list"].innerHTML, /data-k="hist:w1"><summary>History<\/summary><\/details>/);
  // A failed read says why; an item with no steps says so, never an empty fold.
  reply = (url) => url.startsWith("/api/queue/history") ? Promise.reject(new Error("notes: no record")) : data;
  run(`readHist("w1")`);
  await settle(); await settle();
  run(`qst.open["hist:w1"] = true`);
  assert.match(draw(), /<div class="panel down">No history: notes: no record<\/div>/);
  run(`qst.hist.w1 = { data: { attempts: 0, steps: 0, lines: [], days: 30 } }`);
  assert.match(draw(), /History, 0 attempts \(0 steps\)<\/summary><div class="muted">No steps in the last 30 days\.<\/div>/);
  // Shutting the row (a click on it again) drops its History, read and fold both, so a reopen
  // starts shut and reads afresh.
  run(`qst.hist.w1 = { data: { attempts: 1, steps: 1, lines: [], days: 30 } }`);
  fire("click", { type: "click", target: target({}, "w1") });
  assert.deepEqual([run("Object.keys(qst.hist).length"), run(`qst.open["hist:w1"]`)], [0, undefined]);
  fire("click", { type: "click", target: target({}, "w1") });
  assert.match(parts["q-list"].innerHTML, /data-k="hist:w1"><summary>History<\/summary><\/details>/);
  reply = {};
});

test("an opened row on the page shows with its detail", () => {
  load(data, { sel: "q1" });
  const h = draw();
  assert.match(h, /data-slug="q1">.*<tr class="wdet">/s);
  assert.doesNotMatch(h, /data-all/);
});

test("a waiting row links the server's count of what waits on you; it draws no answer card of its own", () => {
  run(`st.agents = [{ target: "lab:w-1", session: "sid-1", items: ["w1"], short: "agent-1", question: { kind: "tool", text: "Run it?" } }]; st.waiting = { count: 2, href: "#home" }`);
  load({ items: [item("w1", { state: "waiting", session: "lab:w-1" }), item("r1", { state: "running" })] }, { sel: "w1" });
  let h = draw();
  assert.match(h, /<div class="qhold" title="tmux session lab:w-1">Waiting on you: <a href="#home">2 on Home<\/a><\/div>/);
  assert.doesNotMatch(h, /class="card need|data-id="A1"|data-k="1"/, "the answers are Home's, not a second set here");
  run(`qst.sel = "r1"`);
  assert.doesNotMatch(draw(), /Waiting on you/, "an item that is not waiting says nothing of it");
  run(`qst.sel = "w1"; st.waiting = null`);
  assert.match(draw(), /<div class="qhold"[^>]*>Waiting on you: not read<\/div>/, "a count that was not read says so, never 0");
  assert.doesNotMatch(draw(), /: 0\b|0 on Home/);
  run(`st.waiting = { count: 0, href: "#home" }`);
  assert.match(draw(), /<div class="qhold"[^>]*>Waiting on you: <a href="#home">0 on Home<\/a><\/div>/, "the server's 0 is shown as it is");
  run("st.agents = []; st.waiting = undefined");
});

test("cancel and the priority select are for an active item only, cancel asks twice", async () => {
  const d1 = item("d1", { state: "done", status: "ok", pr: "o/r#7", pr_label: "r#7", pr_merged: true, cost_label: "$6.10" });
  load({ items: [item("a1", { state: "running" })] });
  run("qst.sel = 'a1'");
  let h = draw();
  assert.match(h, /data-cancel="a1">Stop and cancel</);
  assert.match(h, /data-bump="a1"/);
  opened(d1);
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
  opened(item("u1", { state: "done", status: "ok", unproven: true }));
  const h = draw();
  assert.match(h, /class="qbad"[^>]*>! no PR, no proof</);
  assert.match(h, /<span title="dollars[^>]*>-<\/span>/);
  assert.doesNotMatch(h, /\$0/);
});

test("a PR with no recorded merge says so, and a bare older number keeps its words", () => {
  opened(item("m1", { state: "done", pr: "o/r#7", pr_label: "r#7", pr_url: "u", pr_merged: false }));
  assert.match(draw(), /PR <a href="u"[^>]*>r#7<\/a> merge not recorded/);
  opened(item("m2", { state: "done", pr: "1796", pr_label: "#1796", pr_url: null }));
  assert.match(draw(), /PR #1796 merge not recorded/);
});

test("a row with a PR links it in the PR cell", () => {
  load();
  assert.match(draw(), /<td><a href="https:\/\/github\.com\/o\/r\/pull\/7"[^>]*>r#7<\/a><\/td>/);
});

test("an opened item links its session, project, row, PR and the PR's CI runs; the project cell links too", () => {
  const links = [
    { what: "session", text: "agent-3", href: "#sessions/sessions/w1" },
    { what: "project", text: "dotfiles", href: "#projects/dotfiles" },
    { what: "row", text: "ar-1726", href: "#projects/agent-runtime?row=ar-1726" },
    { what: "pr", text: "o/r#7", href: "https://github.com/o/r/pull/7" },
    { what: "ci", text: "CI runs of o/r#7", href: "#infra/runs?bq=pr:=o%2Fr%237" },
  ];
  load({ items: [item("w1", { links })], over: { next: { links: [{ project: "#projects/dotfiles" }] } } });
  assert.match(draw(), /<td><a class="tl" href="#projects\/dotfiles">dotfiles<\/a><\/td>/, "the project cell is its page");
  fire("click", { type: "click", target: target({}, "w1") });
  const h = parts["q-list"].innerHTML;
  assert.match(h, /<div class="cline qlinks">session <a class="tl" href="#sessions\/sessions\/w1">agent-3<\/a>, project <a class="tl" href="#projects\/dotfiles">dotfiles<\/a>, row <a class="tl" href="#projects\/agent-runtime\?row=ar-1726">ar-1726<\/a>, pr <a class="tl" href="https:\/\/github.com\/o\/r\/pull\/7" target="_blank" rel="noopener">o\/r#7<\/a>, <a class="tl" href="#infra\/runs\?bq=pr:=o%2Fr%237">CI runs of o\/r#7<\/a><\/div>/);
  fire("click", { type: "click", target: target({}, "w1") });
  load({ items: [item("w1")] });
  fire("click", { type: "click", target: target({}, "w1") });
  assert.doesNotMatch(parts["q-list"].innerHTML, /qlinks/, "an item that names nothing draws no line");
  fire("click", { type: "click", target: target({}, "w1") });
});

test("a row carries its start place and priority, a needs-you row its need, and the head carries the flow verdict lines, each linked", () => {
  const rows = [
    item("q1", { priority: "urgent", start: 1, timing: { in_state: 10 } }),
    item("q2", { priority: "low", state: "waiting", waits_for: "ask OBAJTo", source: "human" }),
  ];
  const lines = [
    { line: "Dispatch paused 2h00m: load 31 is over its cap of 24. See the fleet-pace skill.", level: "warn", to: "#queue/next" },
    { line: "Dispatch hold 3h00m: urgent work waits on it. Run fleet-dispatch run --dry-run.", level: "red" },
  ];
  load({ items: rows }, { flow: lines });
  const h = draw();
  assert.match(h, /<tr class="qr" data-slug="q1"><td class="n">1<\/td><td class="btitle"><div class="c12" title="title q1"><span class="bt">title q1<\/span><\/div><\/td>/, "# then the title, one line");
  assert.match(h, /data-slug="q1">.*?<td class="warn">urgent<\/td>/, "urgent reads amber");
  // NEGATIVE CONTROL: a waiting item has no start place, and its title says what it needs.
  assert.match(h, /data-slug="q2"><td class="btitle"><div class="c1" title="title q2"><span class="bt">title q2<\/span><\/div><div class="c1 muted" title="ask OBAJTo">ask OBAJTo<\/div>/);
  assert.match(h, /<div class="cline qverdict warn">Dispatch paused 2h00m: load 31 is over its cap of 24\. See the fleet-pace skill\. <a class="glink" href="#queue\/next">open<\/a><\/div><div class="cline qverdict bad">Dispatch hold 3h00m[^<]*<\/div>/, "a line with a page links it; one without says only itself");
  load({ items: rows }, { flow: [{ line: "Flowing.", level: "ok" }] });
  assert.match(draw(), /<div class="cline qverdict ">Flowing\.<\/div>/, "a flowing line wears no warn hue");
});

// A page opened on a linked Queue view reads /api/queue once, with that view; any other tab still
// reads it once for the nav badge. Each case loads the scripts into a fresh context and fires the
// page's DOMContentLoaded listeners in the order the scripts added them.
const loadAt = async (hash) => {
  const ready = [], urls = [];
  const d = { ...doc, addEventListener: (ev, f) => { if (ev === "DOMContentLoaded") ready.push(f); } };
  const c = vm.createContext({
    console, document: d, window: { addEventListener() {} }, URLSearchParams,
    setInterval: () => 0, clearInterval() {}, setTimeout: () => 0,
    EventSource: function () { return { addEventListener() {}, close() {} }; },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    MutationObserver: function () { return { observe() {}, disconnect() {} }; },
    location: { pathname: "/", hash },
    history: { url: "", replaceState(a, b, u) { this.url = u; } },
    // Only the URLs count here: no reply ever lands, so nothing renders.
    fetch: (url) => { urls.push(url); return new Promise(() => {}); },
  });
  // The page's own script order, since the listeners' order is what this checks.
  const page = readFileSync(new URL("../src/index.html", dir), "utf8");
  for (const [, f] of page.matchAll(/<script src="\/static\/([\w-]+\.js)/g)) vm.runInContext(readFileSync(new URL(f === "kb-ui.js" ? "../../web-kit/kb-ui.js" : f, dir), "utf8"), c, { filename: f });
  ready.forEach((f) => f());
  await settle();
  return urls.filter((u) => /^\/api\/queue(\?|$)/.test(u));
};

test("a linked Queue view reads once with its view, and another tab reads once for the badge", async () => {
  const linked = await loadAt("#queue?s=ready");
  assert.equal(linked.length, 1, linked.join(" "));
  assert.match(linked[0], /s=ready/);
  assert.equal((await loadAt("#board")).length, 1);
});
