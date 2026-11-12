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
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ||= []).push(f); }, querySelectorAll: (q) => (q.includes("sec-") ? [parts["sec-flow"]] : []) });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
let scrolled = 0;
const parts = { "sec-flow": { id: "sec-flow", tagName: "H2", scrollIntoView() { scrolled++; } }, "qt-head": part(), "qt-facets": part(), "qt-chips": part(), "qt-body": part(), "q-list": part(), "q-tabs": part() };
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
  node("queued", "queued", { count: "272", hot: true, stopped: true, stop: "Dispatch stopped 9h50m", facts: ["272 items, bound 12h (5.7x)"], to: { tab: "queue", state: "up next" } }),
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
const data = { at: 1793942700, items, table, inner: "active", needs_you: 1, open_rows: 30, section_aliases: { waiting: "needs you", running: "running", queued: "up next", done: "done" } };
const load = (d = data, over = {}) => {
  run("st.tab = 'queue'; st.arg = ''; st.views.queue = ''");
  Object.assign(run("qst"), { items: d.items, table: d.table, inner: d.inner, aliases: d.section_aliases, needs: d.needs_you, openRows: d.open_rows, all: false, sel: "", err: null, stats: {}, ...over });
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
  reply = (url) => url.startsWith("/api/queue/candidates") ? { rows: [], total: 0 }
    : url.startsWith("/api/queue/stats") ? { week: "updated stats" }
    : { ...data, items: [item("fresh")], table: { ...table, q: "title" } };
  try {
    fire("input", { type: "input", target: search });
    await settle();
    assert.equal(run("st.views.queue"), "q=title");
    assert.equal(doc.activeElement, search, "the query response keeps focus");
    assert.match(parts["qt-body"].innerHTML, /title fresh/, "the query response repaints the rows");
    for (const refresh of ["refreshQueue", "refreshCands", "refreshFlow"]) {
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
  assert.match(h, /<button class="on" data-ts="">all <span class="n">3<\/span><\/button>/, "no chip is every row");
  assert.match(h, /<button class="" data-ts="needs you">needs you <span class="n">1<\/span><\/button>/);
  assert.match(h, /<button class="" data-ts="up next">up next <span class="n">1<\/span><\/button>/);
  for (const c of ["state", "in", "wait", "run", "project", "kind", "size", "acct", "pr", "title"]) {
    assert.match(h, new RegExp(`<th[^>]*><button class="thsort" data-tsort="${c}" data-tdir="desc" title="sort by ${c}">`), `${c} sorts`);
  }
  assert.ok(h.indexOf("title w1") < h.indexOf("title r1") && h.indexOf("title r1") < h.indexOf("title q1"), "the server's order is kept");
  assert.match(h, /id="sec-flow"/);
  assert.match(h, /<div data-in="active"><h2 class="sec" id="sec-active">Active <span class="muted">3 of 4<\/span><\/h2>/, "the heading is the inner tab's");
  assert.doesNotMatch(h, /id="sec-candidates"/, "Candidates is its own inner tab, drawn only while it is shown");
  assert.doesNotMatch(h, /<details[^>]*id="sec-candidates"/, "and no longer a fold under the table");
  // The strip: the open one marked, Active amber while an item needs you.
  const strip = parts["q-tabs"].innerHTML;
  assert.match(strip, /data-itab="active" class="on"[^>]*>Active <span class="pill warn">1<\/span><\/button>/);
  for (const t of ["Up next", "Done 24h", "Candidates"]) assert.match(strip, new RegExp(`>${t}</button>`), t);
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

test("an item not started is ready or held, a held cell names its hold, and the legend says what each means", () => {
  const legend = "ready: starts when dispatch has a slot for it; held: waits on its hold";
  load({ ...data, table: { ...table, legend }, items: [item("r", { state: "queued" }), item("h", { state: "queued", hold: "after r" })] });
  const h = draw();
  assert.match(h, /<td>ready<\/td>/);
  assert.match(h, /<td class="warn" title="held: after r">held<\/td>/);
  assert.match(h, /<div class="muted fold tlegend">ready: starts when dispatch has a slot for it; held: waits on its hold<\/div>/);
  assert.doesNotMatch(h, /<td>queued<\/td>/);
  // Negative control: a table with no legend draws no legend line.
  load();
  assert.doesNotMatch(draw(), /tlegend/);
});

test("the page caps at the server's open_rows with +N older, one click lifts it", () => {
  load({ ...data, open_rows: 2 });
  let h = draw();
  assert.doesNotMatch(h, /title q1/);
  assert.match(h, /<button class="btn sm" data-all="1">\+1 older<\/button>/);
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
  assert.equal(asked.find((u) => u.startsWith("/api/queue?")), "/api/queue?q=dotfiles&s=running&sort=run&in=active", "a chip clicked on Active stays on Active");
  fire("click", { type: "click", target: target({ tsort: "", tdir: "desc" }) });
  await settle();
  assert.equal(ctx.history.url, "#queue?q=dotfiles&s=running", "the plain sort is a bare URL");
});

test("an old section id opens the table on its chip, once", async () => {
  load();
  asked = [];
  reply = data;
  // As a link opens it (setTab with an arg): the server picks the inner tab holding the chip.
  run("st.tab = 'queue'; st.arg = 'running'; st.views.queue = ''; qst.pick = true");
  run("refreshQueue()");
  await settle(); await settle();
  assert.equal(ctx.history.url, "#queue?s=running");
  assert.ok(asked.includes("/api/queue?s=running"), "the pre-filtered table is asked for");
  assert.equal(run("st.arg"), "");
  // A view that already names a chip keeps it: the old id does not overwrite what the link said.
  run("st.arg = 'waiting'; st.views.queue = 's=done'; qst.pick = true");
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

test("each inner tab's link opens it, and old Queue links still land", async () => {
  const r = (h) => { const x = run(`route(${JSON.stringify(h)})`); return [x.tab, x.arg]; };
  for (const id of ["active", "next", "today", "candidates"]) assert.deepEqual(r(`#queue/${id}`), ["queue", id], id);
  assert.deepEqual(r("#queue/table"), ["queue", "active"], "the old table section opens Active");
  // A word that is no inner tab stays the arg for refreshQueue: an old chip id, an item's slug.
  for (const w of ["running", "waiting", "ar-1944"]) assert.deepEqual(r(`#queue/${w}`), ["queue", w], w);
  // The pipeline leads Active: its old link opens Active and scrolls to it.
  const flow = run(`route("#queue/flow")`);
  assert.deepEqual([flow.tab, flow.arg, flow.section], ["queue", "active", "flow"]);
  // The tab button brings back the last inner tab, never a slug the tab read as a word.
  reply = (url) => (url.startsWith("/api/queue/projects") ? [] : data);
  run("setTab('queue', 'next'); setTab('queue', 'ar-1944'); setTab('queue', undefined)");
  assert.equal(run("st.arg"), "next");
  await settle(); await settle();
  run("setTab('queue', '')");
  await settle(); await settle();
  reply = {};
});

test("a scope asks the server for its rows; Candidates reads only when its inner tab opens", async () => {
  load();
  reply = (url) => (url.startsWith("/api/queue/candidates") ? { rows: [], total: 0 } : data);
  asked = [];
  run("st.arg = 'next'");
  run("refreshQueue()");
  await settle();
  assert.ok(asked.includes("/api/queue?in=next"), asked.join(" "));
  assert.ok(!asked.some((u) => u.startsWith("/api/queue/candidates")), "no Candidates read off its inner tab");
  // On Candidates the table keeps the scope it had, hidden; the snapshot is read.
  asked = [];
  run("qst.inner = 'next'; innerGo('queue', 'candidates')");
  await settle();
  assert.ok(asked.includes("/api/queue/candidates"), asked.join(" "));
  run("refreshQueue()");
  await settle();
  assert.ok(asked.includes("/api/queue?in=next"), asked.join(" "));
  // A strip switch drops the last scope's chip, which the new one may not have.
  asked = [];
  run("st.views.queue = 's=running'; innerGo('queue', 'today')");
  await settle();
  assert.equal(run("st.views.queue"), "");
  assert.ok(asked.includes("/api/queue?in=today"), asked.join(" "));  run("qst.cands = null");
  reply = {};
});

test("a view that names no inner tab shows the one the server picked, and the URL follows", async () => {
  load();
  reply = { ...data, inner: "next" };
  run("st.arg = ''; st.views.queue = 's=up%20next'; qst.pick = true");
  run("refreshQueue()");
  await settle();
  assert.equal(run("st.arg"), "next");
  assert.equal(ctx.history.url, "#queue/next?s=up%20next");
  // The server's own default (Active) leaves the bare URL, and the tab button forgets Up next.
  reply = data;
  run("st.arg = ''; st.views.queue = 's=running'; qst.pick = true");
  run("refreshQueue()");
  await settle();
  assert.equal(run("st.arg"), "");
  assert.equal(run("lastInner.queue"), "");
  run("st.views.queue = ''");
});

test("a search typed on a tab stays on it; only a link that names no tab takes the server's pick", async () => {
  load();
  asked = [];
  // The server answers a blank inner tab with Done 24h, where the search found a row.
  reply = (url) => (url.startsWith("/api/queue/projects") ? [] : url.startsWith("/api/queue?") && !url.includes("in=") ? { ...data, inner: "today" } : data);
  // The tab button on a bare #queue is Active: a search typed there asks for Active and stays.
  run("lastInner.queue = ''; setTab('queue', undefined)");
  await settle(); await settle();
  asked = [];
  run("st.views.queue = 'q=x'; refreshQueue()");
  await settle(); await settle();
  assert.ok(asked.includes("/api/queue?q=x&in=active"), asked.join(" "));
  assert.equal(run("st.arg"), "", "still Active");
  // A link `#queue?q=x` names no tab: the read sends none and the strip follows the server's pick.
  asked = [];
  run("setTab('queue', '', 'q=x')");
  await settle(); await settle();
  assert.ok(asked.includes("/api/queue?q=x"), asked.join(" "));
  assert.equal(run("st.arg"), "today");
  assert.equal(ctx.history.url, "#queue/today?q=x");
  // The next search typed there stays on the tab the link landed on.
  asked = [];
  run("st.views.queue = 'q=y'; refreshQueue()");
  await settle(); await settle();
  assert.ok(asked.includes("/api/queue?q=y&in=today"), asked.join(" "));
  assert.equal(run("st.arg"), "today");
  run("st.arg = ''; lastInner.queue = ''; st.views.queue = ''");
  reply = {};
});

test("the pipeline's old link opens Active and scrolls to it, not into the filter", async () => {
  load();
  reply = data;
  scrolled = 0;
  const r = run(`route("#queue/flow")`);
  run(`st.arg = ${JSON.stringify(r.arg)}; st.section = ${JSON.stringify(r.section)}`);
  run("refreshQueue()");
  await settle();
  assert.equal(scrolled, 1, "the page scrolled to the pipeline once it drew");
  assert.equal(run("st.views.queue"), "", "no chip was set");
  assert.equal(run("st.arg"), "active");
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
  assert.match(h, /<tr class="qr sel" data-slug="w1">.*?<\/tr><tr class="wdet"><td colspan="10"><div class="card qitem waiting">/, "the detail opens right under its row, across the table");
  assert.match(h, /queued [^>]*? -> started [^>]*? \(\+5m\) -> merged abcdef01/);
  assert.match(h, /<details class="cfold" data-k="task:w1"><summary>Full task and details<\/summary><dl>/);
  for (const k of ["state", "in state", "wait", "run", "project", "kind", "size", "acct"]) assert.match(h, new RegExp(`<dt>${k}</dt>`), k);
  assert.match(h, /<dd>2h10<\/dd>/);
  assert.match(h, /do the thing/);
  fire("click", { type: "click", target: target({}, "w1") });
  assert.doesNotMatch(parts["q-list"].innerHTML, /wdet/, "the same row again shuts it");
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
  assert.match(draw(), /<td title="o\/r#7"><a href="https:\/\/github\.com\/o\/r\/pull\/7"[^>]*>r#7<\/a><\/td>/, "every ref on hover");
});

test("an opened item links its session, project, row, PR and the PR's CI runs; the project cell links too", () => {
  const links = [
    { what: "session", text: "agent-3", href: "#fleet/session/w1" },
    { what: "project", text: "dotfiles", href: "#projects/dotfiles" },
    { what: "row", text: "ar-1726", href: "#projects/agent-runtime?row=ar-1726" },
    { what: "pr", text: "o/r#7", href: "https://github.com/o/r/pull/7" },
    { what: "ci", text: "CI runs of o/r#7", href: "#infra/runs?bq=pr:=o%2Fr%237" },
  ];
  load({ ...data, items: [item("w1", { links })], table: { ...table, links: [{ project: "#projects/dotfiles" }] } });
  assert.match(draw(), /<td><a class="tl" href="#projects\/dotfiles">dotfiles<\/a><\/td>/, "the project cell is its page");
  fire("click", { type: "click", target: target({}, "w1") });
  const h = parts["q-list"].innerHTML;
  assert.match(h, /<div class="cline qlinks">session <a class="tl" href="#fleet\/session\/w1">agent-3<\/a>, project <a class="tl" href="#projects\/dotfiles">dotfiles<\/a>, row <a class="tl" href="#projects\/agent-runtime\?row=ar-1726">ar-1726<\/a>, pr <a class="tl" href="https:\/\/github.com\/o\/r\/pull\/7" target="_blank" rel="noopener">o\/r#7<\/a>, <a class="tl" href="#infra\/runs\?bq=pr:=o%2Fr%237">CI runs of o\/r#7<\/a><\/div>/);
  fire("click", { type: "click", target: target({}, "w1") });
  load({ ...data, items: [item("w1")] });
  fire("click", { type: "click", target: target({}, "w1") });
  assert.doesNotMatch(parts["q-list"].innerHTML, /qlinks/, "an item that names nothing draws no line");
  fire("click", { type: "click", target: target({}, "w1") });
});
