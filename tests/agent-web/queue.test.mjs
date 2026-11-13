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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "flow.js", "jobs.js", "waiting.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const settle = () => new Promise((r) => setImmediate(r));

// The shape hub_core::flow::Rail serializes to.
const node = (key, label, o = {}) => ({ key, label, count: "4", sub: "p90 2h", hot: false, stopped: false, to: null, stop: null, facts: [], problems_n: 0, problems: [], gap: null, elsewhere: null, ...o });
const nodes = (over = {}) => [
  node("inbox", "inbox", { count: "1", sub: "ok" }),
  node("board", "board", { count: "312" }),
  node("queued", "queued", { count: "272", hot: true, stopped: true, stop: "Dispatch stopped 9h50m", facts: ["272 items, bound 12h (5.7x)"], to: { tab: "queue", state: "ready" } }),
  node("running", "running", { count: "9", problems_n: 11, problems: [{ text: "01:16  ucp-412  failed  died", item: "ucp-412" }, { text: "00:01  a line  refused  no", item: null }], to: { tab: "queue", state: "running" } }),
  node("needs", "needs you", { count: "2", hot: true }),
  node("done", "done 24h", { count: "9" }),
].map((n) => ({ ...n, ...(over[n.key] || {}) }));
const rail = ({ nodes: over, ...o } = {}) => ({ nodes: nodes(over), worst: 2, as_of: "10:20", stale: false, reading: false, error: null, absent: false, ...o });
const drawStrip = (line, grafana = null, picked = "") => vm.runInContext(`qfl.data = ${JSON.stringify(line && { line, grafana })}; qfl.err = null; qfl.node = ${JSON.stringify(picked)}; qStrip()`, ctx);

test("the line draws a point per step with the worst step's detail open", () => {
  const html = drawStrip(rail(), "https://g.example");
  assert.equal((html.match(/data-rail="/g) || []).length, 6);
  assert.match(html, /class="rnode stopped sel" data-rail="queued"/);
  assert.match(html, /<div class="rstop">Stopped: Dispatch stopped 9h50m<\/div>/);
  assert.match(html, /272 items, bound 12h \(5\.7x\)/);
  assert.match(html, /as of 10:20/);
  assert.match(html, /href="https:\/\/g\.example\/d\/kb-agents-overview"/);
  assert.equal((html.match(/rdetail/g) || []).length, 1);
});

test("amber is a step past its bound, red one nothing can leave, and a problem alone is neither", () => {
  const html = drawStrip(rail());
  assert.match(html, /class="rnode hot" data-rail="needs"/);
  assert.match(html, /class="rnode stopped sel" data-rail="queued"/);
  assert.match(html, /class="rnode" data-rail="running"/);
});

test("a picked step opens its problems, and one that names an item links it", () => {
  const html = drawStrip(rail(), null, "running");
  assert.match(html, /class="rnode sel" data-rail="running"/);
  assert.match(html, /Problems, 24h: 11/);
  assert.match(html, /<a class="rprob" href="#queue\?q=ucp-412">01:16  ucp-412  failed  died<\/a>/);
  assert.match(html, /<span class="rprob">00:01  a line  refused  no<\/span>/);
  fire("click", { target: { id: "", closest: (q) => (q === "[data-rail]" ? { dataset: { rail: "needs" } } : null) } });
  assert.equal(run("qfl.node"), "needs");
  assert.match(drawStrip(rail(), null, "gone"), /class="rnode stopped sel" data-rail="queued"/, "a step no longer there falls back to the worst");
});

test("negative control: no snapshot draws inbox - and board -, never 0, and says so", () => {
  const html = drawStrip(rail({ as_of: null, absent: true, nodes: { inbox: { count: null }, board: { count: null } } }));
  assert.match(html, /<span class="rcount">-<\/span><span class="rlabel">inbox/);
  assert.match(html, /<span class="rcount">-<\/span><span class="rlabel">board/);
  assert.match(html, /inbox, board: no snapshot/);
  assert.doesNotMatch(html, /href="https:/);
});

test("a stale or ageless snapshot is red, a failed read says why, and no data yet says reading", () => {
  assert.match(drawStrip(rail({ stale: true })), /<span class="rstop">as of 10:20 \(stale\)<\/span>/);
  assert.match(drawStrip(rail({ stale: true, as_of: null })), /<span class="rstop">age unknown<\/span>/);
  assert.match(drawStrip(rail({ error: "snapshot cannot be read", as_of: null })), /inbox, board: snapshot cannot be read/);
  assert.match(drawStrip(null), /class="flow muted">reading</);
});

// hub_core::queue's COLUMNS, title first; the web draws them all, in this order.
const QCOLS = ["#", "title", "project", "priority", "state", "hold", "from", "in", "wait", "run", "pr", "row", "kind", "size", "acct", "mode", "plan"];
const col = (key, sort = null, next = [key, "desc"]) => ({ key, sort, next_sort: next[0], next_dir: next[1] });
// The shape hub_core::table::Summary serializes to for the Queue table: opened in its own order
// (no sort key marked), chips from the states, every column sortable.
const table = {
  q: "", state: "", sort: "", dir: "", total: 4, shown: 3,
  states: [{ name: "active", n: 3 }, { name: "needs you", n: 1 }, { name: "running", n: 1 }, { name: "on a PR", n: 0 }, { name: "ready", n: 1 }, { name: "held", n: 0 }, { name: "done", n: 0 }, { name: "all", n: 3 }],
  columns: QCOLS.map((k) => col(k)),
  facets: [],
};
const item = (slug, o = {}) => ({ state: "queued", project: "dotfiles", slug, title: `title ${slug}`, priority: "high", ...o });
const items = [
  item("w1", { state: "waiting", type: "feat", size: "m", account: "k1", timing: { in_state: 130, wait: 5, run: 70 } }),
  item("r1", { state: "running", pr: "o/r#7", pr_label: "r#7", pr_url: "https://github.com/o/r/pull/7", timing: { in_state: 42, wait: 3, run: 42 } }),
  item("q1", { timing: { in_state: 10 } }),
];
const data = { at: 1793942700, items, table, needs_you: 1, open_rows: 200, section_aliases: { waiting: "needs you", running: "running", queued: "ready", done: "done" } };
const load = (d = data, over = {}) => {
  run("st.tab = 'queue'; st.arg = ''; st.views.queue = ''; Object.assign(qcd, { data: null, err: null, all: false, msg: '', promoting: null })");
  Object.assign(run("qst"), { items: d.items, table: d.table, aliases: d.section_aliases, needs: d.needs_you, openRows: d.open_rows, all: false, sel: "", err: null, stats: {}, open: {}, hist: {}, candCounts: null, candErr: null, ...over });
};
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
    : url.startsWith("/api/queue/stats") ? { week: "updated stats" }
    : { ...data, items: [item("fresh")], table: { ...table, q: "title" } };
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

test("the Queue is one table with the server's chips and every header a sort button", () => {
  load();
  const h = draw();
  assert.doesNotMatch(h, /data-ts="active"|>ACTIVE</, "no tile is the default view");
  assert.match(h, /<button class="tile" data-ts="needs you"><span class="tl">NEEDS YOU<\/span><span class="tv">1<\/span><\/button>/);
  assert.match(h, /<button class="tile" data-ts="ready"><span class="tl">READY<\/span><span class="tv">1<\/span><\/button>/);
  assert.match(h, /<button class="tile zero" data-ts="done">/, "done is one tile away");
  assert.match(h, /<button class="tile" data-ts="all"><span class="tl">ALL<\/span>/);
  for (const c of QCOLS) {
    assert.match(h, new RegExp(`<th[^>]*><button class="thsort" data-tsort="${c}" data-tdir="desc" title="sort by ${c}">`), `${c} sorts`);
  }
  assert.ok(h.indexOf("title w1") < h.indexOf("title r1") && h.indexOf("title r1") < h.indexOf("title q1"), "the server's order is kept");
  assert.match(h, /id="sec-flow"/);
  assert.match(h, /<h2 class="sec" id="sec-table">Queue <span class="n">3 of 4<\/span><\/h2>/);
  assert.match(h, /id="sec-candidates"/);
});

// The shape agent-web's /api/queue/candidates sends: hub_core::table's Summary over every
// Candidate, the first page of rows, and how many more the view keeps.
const cand = (n, o = {}) => ({ rank: n, key: `ar-${n}`, title: `cand ${n}`, project: "p", profile: "home", lane: "agent", text: `- [ ] cand ${n} #id/ar-${n}`, why: "focus", start_label: "auto", held: false, prio: 2, blocked: [], ...o });
const cands = (o = {}) => ({
  rows: [cand(1), cand(2, { project: "trader", prio: 0, blocked: ["no worker covers trader", "judge: skip, too big"] })], more: 39,
  table: { q: "", state: "", sort: "", dir: "", total: 41, shown: 41, legend: "clear: a worker takes it",
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
    assert.match(h, /<details class="csec" id="sec-candidates" data-k="sec:candidates" open><summary id="qc-sum"><h2 class="sec warn">Candidates <span class="n">41<\/span><\/h2><\/summary>/);
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
    assert.match(h, /<button class="btn sm" data-all="1">\+39 more<\/button>/);
    const calm = drawCands(cands({ urgent_blocked: 0, table: { ...cands().table, total: 41, shown: 3 } }));
    assert.match(calm, /<h2 class="sec">Candidates <span class="n">3 of 41<\/span><\/h2>/);
    assert.doesNotMatch(calm, /urgent/, "the control: no blocked urgent row, no line");
    assert.match(run("qcd.data = null; qcd.err = 'boom'; qCandidates()"), /<h2 class="sec bad">Candidates<\/h2><\/summary><div id="qc-fold"><div class="panel down">No candidates: boom<\/div>/);
  } finally { run("qcd.data = null; qcd.err = null"); }
});

test("a Candidates search asks the server with its own keys, and +N more asks for every row", async () => {
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
    fire("click", { type: "click", target: { dataset: { all: "1" }, closest: search.closest } });
    await settle();
    assert.ok(asked.includes("/api/queue/candidates?cq=trader&call=1"), asked.join(" "));
  } finally { reply = {}; run("st.views.queue = ''; qcd.data = null; qcd.all = false"); }
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
  load({ ...data, table: { ...table, sort: "run", dir: "desc", columns: table.columns.map((c) => (c.key === "run" ? { ...c, sort: "desc", next_dir: "asc", next_sort: "run" } : c)) } });
  const h = draw();
  assert.match(h, /<th class="n" aria-sort="descending" data-role="" data-label="run"><button class="thsort" data-tsort="run" data-tdir="asc" title="sort by run">run v<\/button><\/th>/);
  assert.match(h, /<th class="n"[^>]*><button[^>]*>in<\/button><\/th>/);
});

test("in, wait and run are the server's timing minutes, and no timing reads -", () => {
  load();
  let h = draw();
  assert.match(h, /<td class="n">2h10<\/td><td class="n">5m<\/td><td class="n">1h10<\/td>/);
  assert.match(h, /<td class="n">42m<\/td><td class="n">3m<\/td><td class="n">42m<\/td>/);
  // Negative control: a running item with only stamps, no timing, works out nothing.
  load({ ...data, items: [item("n1", { state: "running", started: "2026-11-06T11:00:00Z", queued: "2026-11-06T10:00:00Z" })] });
  h = draw();
  assert.match(h, /<td class="n">-<\/td><td class="n">-<\/td><td class="n">-<\/td>/);
  assert.doesNotMatch(h, /<td class="n">\d/);
});

test("a state cell says what the item is, and how a done one ended", () => {
  load({ ...data, items: [item("a", { state: "waiting" }), item("b", { state: "done", status: "failed" }), item("c", { state: "done", status: "cancelled" }), item("d", { state: "done", status: "ok" })] });
  const h = draw();
  assert.match(h, /<td class="warn">needs<\/td>/);
  assert.match(h, /<td class="bad">failed<\/td>/);
  assert.match(h, /<td class="muted">cancelled<\/td>/);
  assert.match(h, /<td>done<\/td>/);
});

test("a stuck running or review row is amber with the server's word and its why on hover; a fine one is plain", () => {
  load({ ...data, items: [
    item("s", { state: "running", state_word: "stalled", stuck: true, state_why: "STALLED 42m idle: PR #7 CI red" }),
    item("n", { state: "running", state_word: "no session", stuck: true, state_why: "no session works it" }),
    item("p", { state: "review", state_word: "PR red, yours", stuck: true }),
    item("w", { state: "running", state_word: "running", state_why: "WORKING 1m idle: idle 1m" }),
    item("o", { state: "review", state_word: "on a PR" }),
  ] });
  const h = draw();
  assert.match(h, /<td class="warn" title="STALLED 42m idle: PR #7 CI red">stalled<\/td>/);
  assert.match(h, /<td class="warn" title="no session works it">no session<\/td>/);
  assert.match(h, /<td class="warn">PR red, yours<\/td>/);
  // Negative controls: a working session and a plain PR are not amber.
  assert.match(h, /<td title="WORKING 1m idle: idle 1m">running<\/td>/);
  assert.match(h, /<td>on a PR<\/td>/);
});

test("an item not started is ready or held, a held cell names its hold, and the legend says what each means", () => {
  const legend = "ready: starts when dispatch has a slot for it; held: waits on its hold";
  load({ ...data, table: { ...table, legend }, items: [item("r", { state: "queued" }), item("h", { state: "queued", hold: "after r" })] });
  const h = draw();
  assert.match(h, /<td>ready<\/td>/);
  assert.match(h, /<td class="warn" title="held: after r">held<\/td>/);
  assert.match(h, /<summary>Legend<\/summary><div class="muted">ready: starts when dispatch has a slot for it; held: waits on its hold<\/div>/, "the legend is a fold under the table");
  assert.doesNotMatch(h, /<td>queued<\/td>/);
  // Negative control: a table with no legend draws no legend line.
  load();
  assert.doesNotMatch(draw(), /ready: starts/);
});

test("the page caps at the server's open_rows with +N more, one click lifts it", () => {
  load({ ...data, open_rows: 2 });
  let h = draw();
  assert.doesNotMatch(h, /title q1/);
  assert.match(h, /<button class="btn sm" data-all="1">\+1 more<\/button>/);
  fire("click", { type: "click", target: target({ all: "1" }) });
  h = parts["q-list"].innerHTML;
  assert.match(h, /title q1/);
  assert.doesNotMatch(h, /data-all/);
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
  // Not in this view: the table searches for it, and the read that has it opens it.
  reply = (url) => (url.includes("q=gone") ? { ...data, items: [{ ...items[0], slug: "gone" }] } : { ...data, items: [] });
  run("qst.sel = ''; st.arg = 'gone'; st.views.queue = 's=done'");
  run("refreshQueue()");
  await settle(); await settle(); await settle();
  assert.ok(asked.some((u) => u.startsWith("/api/queue?q=gone")), asked.join(" "));
  assert.equal(run("qst.sel"), "gone");
  // An unknown slug searches once and then gives up, with the table still drawn.
  reply = { ...data, items: [] };
  run("qst.sel = ''; st.arg = 'nowhere'; st.views.queue = ''");
  run("refreshQueue()");
  await settle(); await settle(); await settle();
  assert.equal(run("st.arg"), "");
  assert.equal(run("qst.sel"), "");
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
  assert.match(h, /<details class="csec" id="sec-candidates" data-k="sec:candidates"><summary id="qc-sum"><h2 class="sec warn">Candidates <span class="n">120<\/span><\/h2><\/summary><div id="qc-fold"><\/div><\/details>/);
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
  assert.match(parts["q-list"].innerHTML, /id="sec-candidates" data-k="sec:candidates" open>/);
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
  reply = { ...data, items: [items[1]], needs_you: 3 };
  run("refreshQueue()");
  await settle();
  assert.equal(run("qst.needs"), 3);
});

test("the title cell is a record cell: the title over its muted note, each one line, the whole on hover and on the opened row", () => {
  const long = "x".repeat(400);
  load({ ...data, items: [item("n1", { title: long, note: "held for the release" }), item("n2"), item("n3", { title: "" })] });
  let h = draw();
  assert.match(h, new RegExp(`<td class="btitle"><div class="c1" title="${long}"><span class="bt">${long}</span></div><div class="c1 muted" title="held for the release">held for the release</div></td>`));
  assert.match(h, /data-slug="n2">.*?<div class="c1 muted" title="n2">n2<\/div>/, "no note: the slug says which item");
  assert.match(h, /data-slug="n3">.*?<div class="c1" title="n3"><span class="bt">n3<\/span><\/div><div class="c1 muted" title="">&nbsp;<\/div>/, "the slug as the title is not said twice, and the row keeps two lines");
  assert.doesNotMatch(h, /class="(bsum|c2)/, "no clamped block in the queue's cells");
  load({ ...data, items: [item("n1", { title: long, note: "held for the release" })] }, { sel: "n1" });
  h = draw();
  assert.match(h, /<tr class="wdet">.*held for the release/s, "the opened row says the note in full");
});

test("the removed card, day-heading and tile code is gone", () => {
  for (const k of ["cands", "candReason", "candQ", "candMsg", "promoting"]) assert.ok(!(k in run("qst")), `qst.${k}`);
  for (const n of ["qItem", "qDoneDays", "qTiles", "qSorted", "qChip", "qEta", "Q_SECTIONS", "Q_STATE", "qCandShown", "qCandAll", "refreshCands", "CAND_SHOWN"]) assert.equal(run(`typeof ${n}`), "undefined", n);
});

test("a row opens its detail: every header, the stages with gaps, the task folded", () => {
  const w = item("w1", {
    state: "waiting", type: "feat", size: "m", account: "k1", task: "do the thing", timing: { in_state: 130, wait: 5, run: 70 },
    timeline: [{ step: "queued", at: "2026-11-06T10:00:00Z", gap_min: null }, { step: "started", at: "2026-11-06T10:05:00Z", gap_min: 5 }, { step: "merged", at: null, gap_min: null, sha: "abcdef0123456" }],
  });
  load({ ...data, items: [w] });
  fire("click", { type: "click", target: target({}, "w1") });
  const h = parts["q-list"].innerHTML;
  assert.match(h, /<tr class="qr sel" data-slug="w1">.*?<\/tr><tr class="wdet"><td colspan="17"><div class="card qitem waiting">/, "the detail opens right under its row, across the table");
  assert.match(h, /queued [^>]*? -> started [^>]*? \(\+5m\) -> merged abcdef01/);
  assert.match(h, /<details class="cfold" data-k="task:w1"><summary>Full task and details<\/summary><dl>/);
  for (const k of ["state", "in state", "wait", "run", "project", "kind", "size", "acct"]) assert.match(h, new RegExp(`<dt>${k}</dt>`), k);
  assert.match(h, /<dd>2h10<\/dd>/);
  assert.match(h, /do the thing/);
  fire("click", { type: "click", target: target({}, "w1") });
  assert.doesNotMatch(parts["q-list"].innerHTML, /wdet/, "the same row again shuts it");
});

test("an opened row's History fold starts shut, reads on opening, once, and drops what it read on shutting", async () => {
  load({ ...data, items: [item("w1", { state: "review" })] }, { sel: "w1" });
  asked = [];
  const hist = { attempts: 3, steps: 54, lines: [{ at: "2026-11-12T07:04:21-08:00", text: "started on lab:ucp-agent-10, sol on codex" }, { at: "2026-11-12T07:16:54-08:00", text: "PR still red after fix-ci, yours" }] };
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
  assert.match(h, /<summary>History, 3 attempts \(54 steps, last 2\)<\/summary><div class="cline"><span class="muted">[^<]+<\/span> started on lab:ucp-agent-10, sol on codex<\/div><div class="cline">.*PR still red after fix-ci, yours/);
  fold(false);
  assert.equal(run("qst.hist.w1"), undefined, "a shut fold holds nothing");
  assert.match(parts["q-list"].innerHTML, /data-k="hist:w1"><summary>History<\/summary><\/details>/);
  // A failed read says why; an item with no steps says so, never an empty fold.
  reply = (url) => url.startsWith("/api/queue/history") ? Promise.reject(new Error("notes: no record")) : data;
  run(`readHist("w1")`);
  await settle(); await settle();
  run(`qst.open["hist:w1"] = true`);
  assert.match(draw(), /<div class="panel down">No history: notes: no record<\/div>/);
  run(`qst.hist.w1 = { data: { attempts: 0, steps: 0, lines: [] } }`);
  assert.match(draw(), /History, 0 attempts \(0 steps\)<\/summary><div class="muted">No steps in the last 30 days\.<\/div>/);
  reply = {};
});

test("an opened row past the cap still shows, with its detail", () => {
  load({ ...data, open_rows: 1 }, { sel: "q1" });
  const h = draw();
  assert.match(h, /data-slug="q1">.*<tr class="wdet">/s);
  assert.doesNotMatch(h, /data-all/, "nothing is left under the opened row");
});

test("a waiting row's detail carries its session's ask, answered in place; one with none says where to look", async () => {
  run(`st.agents = [{ target: "lab:w-1", session: "sid-1", items: ["w1"], short: "agent-1" }]; st.asks = [{ id: "A1", session: "sid-1", question: "Ship it?", options: ["yes", "no"], project: "dotfiles" }]`);
  load({ ...data, items: [item("w1", { state: "waiting", session: "lab:w-1" })] }, { sel: "w1" });
  let h = draw();
  assert.match(h, /<tr class="wdet">.*<div class="card need k-ask" data-id="A1">.*Ship it\?/s);
  assert.doesNotMatch(h, /answer on Home|data-home/);
  posted = []; asked = [];
  reply = { ok: true };
  const card = { dataset: { id: "A1" }, querySelector: () => null };
  fire("click", { type: "click", target: { dataset: {}, closest: (sel) => (sel === ".card[data-t], .card[data-id]" ? card : sel === "[data-a]" ? { dataset: { a: "yes" } } : null) } });
  await settle();
  assert.ok(posted.some((u) => u.startsWith("/api/asks/answer") && u.includes('"answer":"yes"')), posted.join(" "));
  assert.equal(asked.filter((u) => u.startsWith("/api/queue")).length, 0, "an answer re-reads no queue: the asks read redraws the card");
  fire("toggle", { target: { open: true, dataset: { k: "ask:A1" }, closest: (sel) => (sel === ".card[data-t], .card[data-id]" ? card : null) } });
  assert.equal(run("askst.open['ask:A1']"), true, "a card's fold is kept where waiting.js draws it from");
  assert.equal(run("qst.open['ask:A1']"), undefined);
  run("st.asks = []");
  load({ ...data, items: [item("w1", { state: "waiting", session: "lab:w-1" })] }, { sel: "w1" });
  h = draw();
  assert.match(h, /Waiting on a prompt in its window/, "negative control: no ask, no card, and the line says where to look");
  run("st.agents = []");
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
  load({ ...data, items: [item("w1", { links })], table: { ...table, links: [{ project: "#projects/dotfiles" }] } });
  assert.match(draw(), /<td><a class="tl" href="#projects\/dotfiles">dotfiles<\/a><\/td>/, "the project cell is its page");
  fire("click", { type: "click", target: target({}, "w1") });
  const h = parts["q-list"].innerHTML;
  assert.match(h, /<div class="cline qlinks">session <a class="tl" href="#sessions\/sessions\/w1">agent-3<\/a>, project <a class="tl" href="#projects\/dotfiles">dotfiles<\/a>, row <a class="tl" href="#projects\/agent-runtime\?row=ar-1726">ar-1726<\/a>, pr <a class="tl" href="https:\/\/github.com\/o\/r\/pull\/7" target="_blank" rel="noopener">o\/r#7<\/a>, <a class="tl" href="#infra\/runs\?bq=pr:=o%2Fr%237">CI runs of o\/r#7<\/a><\/div>/);
  fire("click", { type: "click", target: target({}, "w1") });
  load({ ...data, items: [item("w1")] });
  fire("click", { type: "click", target: target({}, "w1") });
  assert.doesNotMatch(parts["q-list"].innerHTML, /qlinks/, "an item that names nothing draws no line");
  fire("click", { type: "click", target: target({}, "w1") });
});

test("a row carries its start place, hold, source and board row, and the head says what dispatch is doing", () => {
  const rows = [
    item("q1", { priority: "urgent", start: 1, source: "board", row_id: "apo-120", timing: { in_state: 10 } }),
    item("q2", { priority: "low", hold: "after q1", waits_for: "after q1", source: "human" }),
  ];
  const links = [{ row: "#board/apo-120" }, {}];
  load({ ...data, items: rows, table: { ...table, links } }, { dispatch: { line: "Dispatch held: load 31 is over the pace. It could start 0 of 1 runnable.", warn: true } });
  const h = draw();
  assert.match(h, /<tr class="qr" data-slug="q1"><td class="n">1<\/td><td class="btitle"><div class="c1" title="title q1"><span class="bt">title q1<\/span><\/div><div class="c1 muted" title="q1">q1<\/div><\/td>/, "# then the title over its slug");
  assert.match(h, /data-slug="q1">.*?<td class="warn">urgent<\/td>/, "urgent reads amber");
  assert.match(h, /data-slug="q1">.*?<td>board<\/td>/);
  assert.match(h, /<a class="tl" href="#board\/apo-120">apo-120<\/a>/, "the row links to the board");
  // NEGATIVE CONTROL: a held item has no start place, and its hold links the item it waits on.
  assert.match(h, /<tr class="qr" data-slug="q2"><td class="n"><\/td>/);
  assert.match(h, /<td title="after q1">after <a class="tl" href="#queue\/q1">q1<\/a><\/td>/);
  load({ ...data, items: [item("w1", { state: "waiting", waits_for: "ask OBAJTo" })], table: { ...table, links: [{}] } });
  assert.match(draw(), /<td title="ask OBAJTo">ask OBAJTo<\/td>/, "a waiting row says its wait, and hovers it");
  assert.match(h, /<div class="cline qdispatch warn">Dispatch held: load 31 is over the pace\. It could start 0 of 1 runnable\.<\/div>/);
  load({ ...data, items: rows }, { dispatch: { line: "Dispatch running: it could start 2 of 3 runnable.", warn: false } });
  assert.match(draw(), /<div class="cline qdispatch">Dispatch running/);
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
  for (const [, f] of page.matchAll(/<script src="\/static\/([\w-]+\.js)/g)) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), c, { filename: f });
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
