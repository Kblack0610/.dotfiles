// Unit tests for the Projects tab (.local/src/agent-web/static/projects.js and the rows of
// board.js it opens), run by `node --test` from tests/unit/agent_web_queue.bats. The page's
// real scripts load into one vm context; only the DOM is a stub. The cards' join and numbers
// are hub_core::projects, tested in Rust; this checks how its answer is drawn.
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
const box = (id) => (boxes[id] ||= Object.assign(el(), {
  innerHTML: "", scrollTop: 0, hidden: false, textContent: "", querySelectorAll: () => [],
  on: {}, addEventListener(ev, f) { (this.on[ev] ||= []).push(f); },
}));
const doc = { getElementById: box, addEventListener() {}, createElement: el, body: el(), querySelector: el, querySelectorAll: () => [] };
const ctx = vm.createContext({
  console,
  URLSearchParams,
  document: doc,
  window: { addEventListener() {} },
  // A path in `answers` gets that body (a string is a 502 with it as the text, an Error is a
  // fetch that got no answer, as the browser rejects one); /api/board
  // answers from `board` as the server would, and the rest get []. `sent` is every request.
  answers: {},
  sent: [],
  fetch: async (u, opts) => {
    ctx.sent.push({ u, body: opts && opts.body });
    const a = u.startsWith("/api/board") ? board(u) : ctx.answers[u];
    if (a instanceof Error) throw a;
    if (typeof a === "string") return { ok: false, status: 502, statusText: "Bad Gateway", text: async () => a, headers: { get: () => "text/plain" } };
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => a ?? [] };
  },
});
for (const f of ["ui.js", "charts.js", "app.js", "table.js", "actions.js", "board.js", "projects.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const card = (o) => ({
  profile: "bnb", name: "demo", stage: "alpha", version: "v0.1.0", goal: "ship the menu",
  progress: { open: 2, done: 1, open_weight: 3, done_weight: 1, closed_7d: 1 }, percent: 25, eta_days: 4,
  requested: 1, inbox: 2, running: [], waiting: 0, queued: 0, status: "", status_date: "",
  doing: 0, hot: 0, held: 0, done_today: 0, oldest: "-",
  summary: "v0.1.0 25% (1 of 4 by size), 7d 1, 28d 1, ETA 4d", in_flight: false, pace: 0.3, ...o,
});
// The Summary hub_core::table sends beside the cards the view kept out of `total`.
const listTable = (kept, total = kept.length, o = {}) => ({
  q: "", state: "", sort: "", dir: "desc", total, shown: kept.length,
  states: [{ name: "all", n: kept.length }, { name: "in flight", n: kept.filter((c) => c.in_flight).length }, { name: "waiting", n: kept.filter((c) => c.waiting).length }],
  columns: ["project", "profile", "stage", "version", "prio", "open", "doing", "hot", "done", "7d", "pct", "pace", "eta", "run", "wait", "queued", "held", "today", "oldest"]
    .map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
  facets: [{ key: "stage", on: [], clear: "", values: [{ value: "alpha", n: kept.length, on: false, q: "stage:alpha" }] }], ...o,
});
const list = (cards = [card()], o = {}) => ({ cards, unlinked: [], errors: [], table: listTable(cards), ...o });
const rows = [
  { profile: "bnb", project: "demo", lane: "agent", state: "open", priority: "high", section: "next", label: "NEXT UP (1)", when: "", text: "fix the menu", raw: "- [ ] fix the menu", sheet: "a.md", tags: [] },
  { profile: "personal", project: "garden", lane: "human", state: "open", priority: "low", section: "backlog", label: "BACKLOG (1)", when: "queued  ~11-12", text: "water the beds", raw: "- [ ] water the beds", sheet: "b.md", tags: [] },
];
// The Summary hub_core::table sends beside the rows, for these rows.
const tableOf = (q, total, kept) => ({
  q, state: "", sort: "", dir: "desc", total, shown: kept.length,
  states: [{ name: "all", n: kept.length }, { name: "urgent", n: 0 }],
  columns: ["section", "priority", "project", "lane", "state", "id", "version", "size", "tier", "since", "when", "text", "profile", "tag"]
    .map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
  facets: [{ key: "lane", on: [], clear: "", values: [{ value: "agent", n: 1, on: false, q: "lane:agent" }] }],
});
const projects = [{ profile: "bnb", project: "demo", inbox: 0 }, { profile: "personal", project: "garden", inbox: 0 }];
const focus = [{ profile: "personal", open: 3 }, { profile: "bnb", open: 1 }];
// What /api/board answers: `scope` narrows the rows, `q` is a word of a row's text or `id:<prefix>`.
function board(u) {
  const p = new URLSearchParams(u.split("?")[1] || ""), scope = p.get("scope"), q = p.get("q") || "";
  const mine = rows.filter((r) => !scope || r.profile + "/" + r.project === scope);
  const kept = mine.filter((r) => (q.startsWith("id:") ? (r.id || "").startsWith(q.slice(3)) : r.text.includes(q)));
  return { today: "2026-11-05", projects, rows: kept, focus, table: tableOf(q, mine.length, kept) };
}
const read = () => ({ cards: box("p-cards").innerHTML, head: box("p-head").innerHTML, rows: box("b-tbl").innerHTML });
function draw(data, open = null) {
  ctx.input = { data, feed: board("/api/board"), open };
  vm.runInContext(`st.tab = "projects"; st.arg = ""; st.views.projects = ""; pst.data = input.data; pst.err = null; pst.viewed = ""; bst.feed = input.feed; pst.open = null;
    if (input.open) pOpen(input.open); else renderProjects();`, ctx);
  return read();
}
const settle = () => new Promise((r) => setImmediate(r));
// The same, once the rows it asked for have come back.
async function drawn(data, open) {
  draw(data, open);
  await settle(); await settle();
  return read();
}
// The Board tab under this view, once its rows have come back.
async function onBoard(view = "") {
  ctx.view = view;
  ctx.answers = { "/api/projects": list() };
  vm.runInContext(`st.tab = "board"; st.arg = ""; st.views.board = view; pst.open = null; TABS.board.show();`, ctx);
  await settle(); await settle();
  return read();
}
// A click on the page, on a target with these data attributes, inside a row when `row` is set.
function click(id, dataset, row) {
  const target = { id: "", dataset, closest: (sel) => (sel === "tr[data-row]" && row != null ? { dataset: { row } } : null) };
  for (const f of box(id).on.click) f({ type: "click", target });
}

test("the list is one table row per project with its counts, and the card's words stay on the card", () => {
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", phases: { done: 1, total: 3, next: "web" } }];
  const { cards } = draw(list([card({ running, queued: 2, waiting: 1, in_flight: true, prio: "focus", status: "landed it", status_date: "2026-11-05", pace: 4.3, doing: 1, hot: 1, held: 1, done_today: 3, oldest: "30h" }), card({ profile: "personal", name: "garden", stage: "", version: null, percent: null, eta_days: null, summary: "no version no rows", oldest: "" })], { unlinked: ["dotfiles: tidy"] }));
  assert.match(cards, /2 projects, 1 in flight; progress is the open version's rows by size/);
  assert.doesNotMatch(cards, /All rows/, "every project's rows are the Board tab");
  assert.match(cards, /id="projects-q".*id="projects-chips"/s);
  assert.match(cards, />all <.*>in flight <.*>waiting </s);
  assert.match(cards, /data-tsort="project".*data-tsort="pace"[^>]*>pace\/wk<.*data-tsort="queued"/s);
  assert.match(cards, /<tr class="jr" tabindex="0" data-open="bnb\/demo"><td>demo<\/td><td>bnb<\/td><td>alpha<\/td><td>v0\.1\.0<\/td><td>focus<\/td><td class="n">2<\/td><td class="n">1<\/td><td class="n warn">1<\/td><td class="n">1<\/td><td class="n">1<\/td><td class="n">25%<\/td><td class="n">4\.3<\/td><td class="n">4d<\/td><td class="n">1<\/td><td class="n">1<\/td><td class="n">2<\/td><td class="n">1<\/td><td class="n">3<\/td><td class="n">30h<\/td><\/tr>/);
  assert.match(cards, /<tr class="jr" tabindex="0" data-open="personal\/garden"><td>garden<\/td><td>personal<\/td><td>-<\/td><td>-<\/td><td>-<\/td>.*<td class="n">-<\/td><td class="n">0\.3<\/td><td class="n">-<\/td>.*<td class="n">0<\/td><td class="n">-<\/td><\/tr>/, "no hot row is not lit, and an empty oldest is a dash");
  for (const moved of ["ship the menu", "wire the bar", "landed it", "#requested", "class=\"card qitem"]) {
    assert.doesNotMatch(cards, new RegExp(moved), `${moved} is the opened card's`);
  }
  assert.match(cards, /<details data-k="unlinked" open><summary><h2 class="sec">Not on a card.*1 active queue items no project claims.*dotfiles: tidy/s);
});

test("the list's view goes to the server, and a view that keeps nothing says so", async () => {
  draw(list());
  ctx.answers = { "/api/projects?q=stage%3Abeta": list([], { table: listTable([], 1) }) };
  ctx.sent = [];
  const target = { dataset: { tsearch: "" }, value: "stage:beta" };
  for (const f of box("p-cards").on.input) f({ type: "input", target });
  assert.equal(vm.runInContext(`st.views.projects`, ctx), "q=stage%3Abeta");
  await settle(); await settle();
  assert.ok(ctx.sent.some((s) => s.u === "/api/projects?q=stage%3Abeta"));
  assert.ok(!ctx.sent.some((s) => s.u.startsWith("/api/board")), "the list's view is not the rows'");
  const { cards } = read();
  assert.match(cards, /0 of 1 projects, 0 in flight/);
  assert.match(cards, /No project matches\./);
});

test("a re-read keeps the search box the human is typing in", () => {
  draw(list());
  box("p-cards").innerHTML = "the box in use";
  ctx.document.activeElement = { id: "projects-q", dataset: {} };
  vm.runInContext(`renderProjects()`, ctx);
  ctx.document.activeElement = undefined;
  assert.equal(box("p-cards").innerHTML, "the box in use");
  assert.match(box("projects-chips").innerHTML, /in flight/);
  assert.match(box("projects-facets").innerHTML, /data-tsv/, "the bar keeps its sort dropdown");
  assert.doesNotMatch(box("projects-facets").innerHTML, /data-fkey="stage"/, "stage's dropdown is in the filter row under its header, not again in the bar");
});

test("with a project open every card is read, and an answer for a list no longer on screen is dropped", async () => {
  draw(list());
  ctx.answers = { "/api/projects": list(), "/api/projects/demo/page": page };
  ctx.sent = [];
  vm.runInContext(`st.arg = "bnb/demo"; st.views.projects = "q=menu"; refreshProjects();`, ctx);
  await settle(); await settle();
  assert.ok(ctx.sent.some((s) => s.u === "/api/projects"), "the query is the rows'");
  assert.ok(!ctx.sent.some((s) => s.u.startsWith("/api/projects?")));
  draw(list([card({ name: "kept" })]));
  ctx.answers = { "/api/projects": list([card({ name: "stale" })]) };
  vm.runInContext(`refreshProjects(); st.arg = "bnb/demo";`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`pst.data.cards[0].name`, ctx), "kept");
});

const page = {
  project: "demo", flow_line: "ideas 3 | briefs 1 | plans 1 | epics 2 | rows 5 | landed 1 | verified 0",
  needs: ["verify: Saves (4 of 4 rows landed, no live proof)"],
  alerts: { says: "2 watches, 1 firing", level: "bad" },
  systems: [
    { id: "ui", head: "ui  25%  1 feature, 0 done  criteria 5 of 7", closed: "+1 closed, 1 verified", epics: [{ id: "de-9", line: "Menus  25%  [rows]  behind", behind: true, leaves: [
      { id: "de-1", line: "[ ] de-1  feat: wire the pause key  m", done: false },
      { id: "de-2", line: "[x] de-2  fix: <menu> flicker  s  pr 7", done: true },
    ] }] },
    { id: "ci", head: "ci  criteria 1 of 2", epics: [], closed: "" },
  ],
  systems_says: "1 systems, 1 open epics (2 rows with no epic)", next_says: "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet",
  next_rows: [{ stage: "beta", result: "FAIL", requirement: "a soak test" }], shipped_says: "none yet", shipped: [], errors: [],
  timeline: { says: "7d: 1 commit (1 red on CI), 1 PR", older: 3, notes: ["PRs: the origin is not GitHub"], lines: [
    { line: "2h  commit  fix the menu  CI red", level: "bad", url: "https://ci.example/run/1" },
    { line: "3h  PR      #7 opened: <menu>", level: "ok", url: "javascript:alert(1)" },
  ] },
};

test("an opened card reads its page once and shows Needs you, then open folds with their counts", async () => {
  ctx.answers = { "/api/projects/demo/page": page };
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", phases: { done: 1, total: 3, next: "web" } }];
  const c = card({ running, counts: "1 running, 0 waiting, 0 queued; 1 rows #requested, 2 in the inbox", status: "landed it", note_says: "model-written, 2026-11-05" });
  let { head } = draw(list([c]), "bnb/demo");
  assert.match(head, /<div class="pgoal">ship the menu<\/div><div class="muted">Reading the page\.\.\.<\/div>/);
  await settle();
  head = box("p-head").innerHTML;
  assert.match(head, /flow: ideas 3 \| briefs 1/);
  assert.match(head, /<div class="cline">alerts: <a class="bad" href="#alerts\?q=project%3Ademo">2 watches, 1 firing<\/a><\/div>/);
  assert.match(head, /Needs you <span class="muted">1<\/span><\/h2><div class="card"><div class="qlate">verify: Saves/);
  // Build by system is always shown, above Needs you: a fold per system with an epic, a fold per
  // epic over its tasks, an open task a link to its row, a system with no epic only its line.
  assert.match(head, /<h2 class="sec">Build by system <span class="muted">1 systems, 1 open epics \(2 rows with no epic\)<\/span><\/h2>.*Needs you/s);
  assert.match(head, /data-k="pg:sys:ui" open><summary><b>ui  25%  1 feature, 0 done  criteria 5 of 7<\/b><\/summary>/);
  assert.match(head, /data-k="pg:ep:de-9" open><summary><span class="pep qlate">Menus  25%  \[rows\]  behind<\/span><\/summary>/);
  assert.match(head, /<div class="pleaf"><a href="#" data-leaf="de-1">\[ \] de-1  feat: wire the pause key  m<\/a><\/div>/);
  assert.match(head, /<div class="pleaf muted">\[x\] de-2  fix: &lt;menu&gt; flicker  s  pr 7<\/div>/, "a done task is no link");
  assert.match(head, /<\/details><div class="pep muted">\+1 closed, 1 verified<\/div><\/details><div class="psys"><b>ci  criteria 1 of 2<\/b><\/div>/);
  assert.match(head, /Next stage<\/b> <span class="muted">beta  4 of 12 met.*<b>FAIL<\/b> a soak test/s);
  assert.match(head, /Shipped<\/b> <span class="muted">none yet/);
  assert.match(head, /Timeline<\/b> <span class="muted">7d: 1 commit \(1 red on CI\), 1 PR<\/span>.*<div class="muted">PRs: the origin is not GitHub<\/div>/s);
  assert.match(head, /<div class="ptl bad"><a href="https:\/\/ci\.example\/run\/1" target="_blank" rel="noopener">2h  commit  fix the menu  CI red<\/a><\/div>/);
  assert.match(head, /<div class="ptl">3h  PR      #7 opened: &lt;menu&gt;<\/div><div class="muted more">\+3 older<\/div>/, "a non-http url is not a link");
  assert.match(head, /In flight<\/b> <span class="muted">1 running, 0 waiting, 0 queued; 1 rows #requested.*wire the bar/s);
  assert.match(head, /Agent note<\/b> <span class="muted">model-written, 2026-11-05.*landed it/s);
  for (const k of ["sys:ui", "ep:de-9", "next", "shipped", "timeline", "flight", "note"]) assert.match(head, new RegExp(`data-k="pg:${k}" open>`), `${k} starts open`);
  assert.doesNotMatch(head, /<details(?![^>]* open)[^>]*>/, "no fold starts shut");
});

test("a task under an epic filters the rows to its id and opens its row", async () => {
  rows.push({ profile: "bnb", project: "demo", lane: "human", state: "open", priority: "low", id: "de-1", text: "wire the pause key", raw: "- [ ] wire the pause key <!-- id:de-1 -->", sheet: "h.md", tags: [] });
  try {
    ctx.answers = { "/api/projects/demo/page": page };
    await drawn(list(), "bnb/demo");
    let prevented = false;
    const target = { id: "", dataset: {}, closest: (sel) => (sel === "[data-leaf]" ? { dataset: { leaf: "de-1" } } : null) };
    for (const f of box("projects").on.click) f({ type: "click", target, preventDefault() { prevented = true; } });
    await settle(); await settle();
    assert.ok(prevented, "the link goes nowhere itself");
    assert.equal(vm.runInContext("st.views.projects", ctx), "q=id%3Ade-1");
    assert.match(read().rows, /<tr class="jr sel" data-row="0">.*wire the pause key/s);
    assert.doesNotMatch(read().rows, /fix the menu/, "the rows are the task's alone");
    assert.equal(vm.runInContext("pst.leaf", ctx), null, "the answer settles it");
    // A read that lacks the row (one in flight before the click) leaves the click waiting.
    vm.runInContext('pst.leaf = { id: "de-404", feed: null }; renderProjects()', ctx);
    assert.equal(vm.runInContext("pst.leaf && pst.leaf.id", ctx), "de-404");
  } finally { rows.pop(); }
});

test("a page that cannot be read says why, and a card with no goal says so", async () => {
  ctx.answers = { "/api/projects/demo/page": "fleet-bench epics lists no project demo" };
  draw(list([card({ goal: "", counts: "" })]), "bnb/demo");
  await settle(); await settle();
  const head = box("p-head").innerHTML;
  assert.match(head, /<span class="muted">no goal set<\/span>/);
  assert.match(head, /panel down">Could not read projects \(HTTP 502\): fleet-bench epics lists no project demo/);
});

test("opening a card asks for its rows alone and draws them as the shared table", async () => {
  ctx.sent = [];
  const { head, rows: shown } = await drawn(list(), "bnb/demo");
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?scope=bnb%2Fdemo"), "the server scopes the rows");
  assert.match(head, /Back to projects.*>demo<.*v0\.1\.0 25%/s);
  assert.match(shown, /1 of 1 rows/);
  assert.match(shown, /data-tsort="priority".*data-tsort="text"/s);
  assert.doesNotMatch(shown, /data-tsort="profile"|data-tsort="tag"/, "a query key with no column of its own is not drawn");
  assert.match(shown, /<tr class="jr" data-row="0"><td><b>NEXT UP \(1\)<\/b><\/td><td><span class="qprio high">high<\/span><\/td><td>demo<\/td>.*fix the menu/s);
  assert.doesNotMatch(shown, /water the beds/, "another project's row is not sent");
  assert.doesNotMatch(shown, /href="#daily"/, "one project's rows have no Daily count");
  assert.match(read().rows, /id="board-q".*id="board-chips"/s);
});

test("a row opens under itself with its actions, and a second click shuts it", async () => {
  await drawn(list(), "bnb/demo");
  click("b-root", {}, "0");
  assert.match(read().rows, /<tr class="jr sel" data-row="0">.*<tr class="bopen"><td colspan="12">.*data-tag="0">Tags\.\.\./s);
  click("b-root", {}, "0");
  assert.doesNotMatch(read().rows, /bopen/);
});

test("a row action after the server filtered names the row on screen, not its place in the sheet", async () => {
  await onBoard("q=water");
  assert.match(read().rows, /1 of 2 rows/);
  ctx.sent = [];
  click("b-root", { start: "0" });
  await settle(); await settle();
  assert.equal(JSON.parse(ctx.sent.find((s) => s.body).body).raw, "- [ ] water the beds");
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?q=water"), "the re-read keeps the view");
});

test("Enter on a row opens its project, and Back shows no list read under the old view", async () => {
  await drawn(list());
  ctx.answers = { "/api/projects?q=menu": list([card({ name: "narrowed" })]), "/api/projects": list(), "/api/projects/demo/page": "not read here" };
  vm.runInContext(`st.views.projects = "q=menu"; refreshProjects();`, ctx);
  await settle(); await settle();
  assert.match(read().cards, /narrowed/);
  const target = { matches: (sel) => sel === "tr[data-open]", dataset: { open: "bnb/demo" } };
  for (const f of box("p-cards").on.keydown) f({ key: "Enter", target });
  assert.equal(vm.runInContext(`pst.open`, ctx), "bnb/demo");
  vm.runInContext(`pGo(null);`, ctx);
  assert.equal(vm.runInContext(`pst.data`, ctx), null, "the filtered answer goes with its view");
  assert.match(box("p-cards").innerHTML, /Reading notes projects/);
  await settle(); await settle();
  assert.equal(vm.runInContext(`pst.data.cards[0].name + pst.viewed`, ctx), "demo");
});

test("a click into a project or Back clears the query; a deep link keeps its own", async () => {
  await drawn(list());
  ctx.answers = { "/api/projects": list(), "/api/projects/demo/page": "not read here" };
  vm.runInContext(`st.views.projects = "q=menu"; pGo("bnb/demo");`, ctx);
  assert.equal(vm.runInContext(`st.views.projects + "|" + st.arg + "|" + pst.open`, ctx), "|bnb/demo|bnb/demo");
  await settle(); await settle();
  vm.runInContext(`st.views.projects = "q=menu"; pGo(null);`, ctx);
  assert.equal(vm.runInContext(`st.views.projects + "|" + st.arg + "|" + pst.open`, ctx), "||null");
  await settle(); await settle();
  ctx.sent = [];
  vm.runInContext(`st.arg = "demo"; st.views.projects = "q=menu"; pDeep();`, ctx);
  await settle(); await settle();
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?q=menu&scope=bnb%2Fdemo"), "the link's view is read");
  assert.equal(vm.runInContext(`st.views.projects`, ctx), "q=menu");
});

test("Board reads every project's rows under its own view, and leaves them behind", async () => {
  ctx.sent = [];
  assert.match((await onBoard("q=water")).rows, /1 of 2 rows/);
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?q=water"), "no scope, the Board's own query");
  ctx.sent = [];
  vm.runInContext(`st.tab = "projects"; st.arg = ""; st.views.projects = ""; TABS.projects.show();`, ctx);
  await settle(); await settle();
  assert.ok(!ctx.sent.some((s) => s.u.startsWith("/api/board")), "the list has no rows to read");
  assert.equal(vm.runInContext(`bst.feed`, ctx), null, "the Board's rows do not follow");
  ctx.input = { data: list() };
  ctx.answers = { "/api/projects/demo/page": page };
  vm.runInContext(`pst.data = input.data; pOpen("bnb/demo");`, ctx);
  await settle(); await settle();
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?scope=bnb%2Fdemo"));
});

test("a Board answer that lands after the tab changed is dropped", async () => {
  await onBoard();
  vm.runInContext(`bst.feed = null; refreshBoard(); st.tab = "projects"; pst.open = "bnb/demo";`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`bst.feed`, ctx), null);
});

test("Board opens every project's rows, and a stats error is shown, not hidden", async () => {
  const all = await onBoard();
  assert.match(all.rows, /fix the menu.*water the beds/s);
  assert.match(all.rows, /<a class="btn sm" href="#daily">Daily: personal 3, bnb 1 open<\/a>/, "the daily notes' Focus is a count linking to Daily");
  assert.match(draw(list([], { errors: ["notes projects failed"] })).cards, /panel down">notes projects failed/);
});

test("rows past the cap wait behind a button, and a view with nothing says so", async () => {
  await onBoard();
  ctx.input = Array.from({ length: 205 }, (_, i) => ({ ...rows[0], raw: "- [ ] r" + i, text: "r" + i }));
  vm.runInContext(`bst.feed = { ...bst.feed, rows: input, table: { ...bst.feed.table, shown: 205, total: 205 } }; bst.render();`, ctx);
  assert.match(read().rows, /data-all="1">\+5 more/);
  click("b-root", { all: "1" });
  assert.doesNotMatch(read().rows, /\+5 more/);
  assert.match(read().rows, />r204</);
  vm.runInContext(`bst.feed = { ...bst.feed, rows: [], table: { ...bst.feed.table, shown: 0 } }; bst.render();`, ctx);
  assert.match(read().rows, /No row matches\./);
});

// The Summary hub_core::table sends beside the Deliverables rows.
const deliv = (o = {}) => {
  const rows = [
    { project: "demo", profile: "bnb", id: "de-9", title: "Menus <fast>", system: "ui", done: 3, total: 4, percent: 75, done_says: "75% 3/4", eta: 1794537535, eta_day: "11-13", track: "behind" },
    { project: "garden", profile: "personal", id: "ga-1", title: "Water", system: "save", done: 2, total: 2, percent: 100, done_says: "100% 2/2", eta: null, eta_day: "", track: "verify" },
  ];
  return {
    rows, says: "Deliverables (2 open, 1 ready to verify, 0 on track, 1 behind)",
    coverage_says: "Coverage: 74 linked / 79 open rows (94%); no feature epic: home-config", legend: "percent is by size, then rows done/all",
    table: {
      q: "", state: "", sort: "", dir: "desc", total: 2, shown: 2,
      states: [{ name: "all", n: 2 }, { name: "behind", n: 1 }, { name: "on track", n: 0 }, { name: "verify", n: 1 }],
      columns: ["project", "epic", "sys", "done", "eta", "track"].map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
      facets: [{ key: "sys", on: [], clear: "", values: [{ value: "ui", n: 1, on: false, q: "sys:ui" }] }],
    },
    ...o,
  };
};
const drawDeliv = async (d) => {
  ctx.answers = { "/api/deliverables": d, "/api/projects": list() };
  vm.runInContext(`st.tab = "projects"; st.arg = ""; st.views.projects = ""; pst.open = null; dst.data = null; dst.err = null; dst.refresh();`, ctx);
  await settle(); await settle();
  return box("p-deliv").innerHTML;
};

test("Deliverables is a table over the project list: the head, one row per epic, then the coverage line", async () => {
  const html = await drawDeliv(deliv());
  assert.match(html, /^<div data-tbl="d">.*id="sec-deliverables">Deliverables \(2 open, 1 ready to verify, 0 on track, 1 behind\)<\/h2>/s);
  assert.match(html, /id="p-del-q".*id="p-del-chips"/s);
  assert.match(html, />all <.*>behind <.*>on track <.*>verify </s);
  assert.match(html, /data-tsort="project".*data-tsort="epic".*data-tsort="sys".*data-tsort="done".*data-tsort="eta".*data-tsort="track"/s);
  assert.match(html, /home-config; percent is by size, then rows done\/all/);
  assert.match(html, /<tr class="jr" tabindex="0" data-open="bnb\/demo" data-epic="de-9" data-sys="ui"><td>demo<\/td><td class="wrap" title="de-9">Menus &lt;fast&gt;<\/td><td>ui<\/td><td class="n" title="3 of 4 rows done; the percent is by size">75% 3\/4<\/td><td class="n">11-13<\/td><td class="warn">behind<\/td><\/tr>/);
  assert.match(html, /<td>save<\/td>.*<td class="n">-<\/td><td>verify<\/td>/s, "no ETA is a dash and only behind is amber");
  assert.match(html, /Coverage: 74 linked \/ 79 open rows \(94%\); no feature epic: home-config/);
});

test("the Deliverables view keys are d-prefixed, so the project list keeps the plain ones", async () => {
  await drawDeliv(deliv());
  ctx.answers = { "/api/deliverables?dq=sys%3Aui": deliv({ rows: [deliv().rows[0]] }) };
  ctx.sent = [];
  const target = { dataset: { tsearch: "" }, value: "sys:ui", closest: (sel) => (sel === "[data-tbl]" ? { dataset: { tbl: "d" } } : null) };
  for (const f of box("p-deliv").on.input) f({ type: "input", target });
  assert.equal(vm.runInContext(`st.views.projects`, ctx), "dq=sys%3Aui");
  await settle(); await settle();
  assert.ok(ctx.sent.some((s) => s.u === "/api/deliverables?dq=sys%3Aui"));
  assert.ok(!ctx.sent.some((s) => s.u.startsWith("/api/projects?")), "the list's view is not the deliverables'");
});

test("a Deliverables row opens its project's card with its system and epic folds open", async () => {
  await drawDeliv(deliv());
  ctx.answers = { "/api/projects": list(), "/api/projects/demo/page": "not read here" };
  const o = { dataset: { open: "bnb/demo", epic: "de-9", sys: "ui" } };
  const target = { id: "", dataset: {}, closest: (sel) => (sel === "[data-open]" ? o : null) };
  for (const f of box("projects").on.click) f({ type: "click", target });
  assert.equal(vm.runInContext(`pst.open`, ctx), "bnb/demo");
  assert.equal(vm.runInContext(`pst.folds["pg:sys:ui"] + "|" + pst.folds["pg:ep:de-9"]`, ctx), "true|true");
});

test("a failed Deliverables read says so and never shows an empty table", async () => {
  ctx.answers = { "/api/deliverables": "fleet-bench: not found", "/api/projects": list() };
  vm.runInContext(`st.tab = "projects"; st.arg = ""; st.views.projects = ""; pst.open = null; dst.data = null; dst.err = null; dst.refresh();`, ctx);
  await settle(); await settle();
  const html = box("p-deliv").innerHTML;
  assert.match(html, /class="card err".*fleet-bench: not found/);
  assert.doesNotMatch(html, /<table/);
});

test("a page read that gets no answer says agent-web did not answer, never a bare network error", async () => {
  ctx.answers["/api/projects/game/page?x=1"] = new TypeError("NetworkError when attempting to fetch resource.");
  await assert.rejects(vm.runInContext('api("/api/projects/game/page?x=1")', ctx),
    { message: "agent-web did not answer /api/projects/game/page. It may be restarting: retry in a few seconds." });
  const abort = Object.assign(new Error("aborted"), { name: "AbortError" });
  ctx.answers["/api/projects/game/page?x=1"] = abort;
  await assert.rejects(vm.runInContext('api("/api/projects/game/page?x=1")', ctx), (e) => e === abort);
  delete ctx.answers["/api/projects/game/page?x=1"];
});
