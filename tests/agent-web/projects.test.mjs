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
  // A path in `answers` gets that body (a string is a 502 with it as the text); /api/board
  // answers from `board` as the server would, and the rest get []. `sent` is every request.
  answers: {},
  sent: [],
  fetch: async (u, opts) => {
    ctx.sent.push({ u, body: opts && opts.body });
    const a = u.startsWith("/api/board") ? board(u) : ctx.answers[u];
    if (typeof a === "string") return { ok: false, status: 502, statusText: "Bad Gateway", text: async () => a, headers: { get: () => "text/plain" } };
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => a ?? [] };
  },
});
for (const f of ["ui.js", "charts.js", "app.js", "actions.js", "table.js", "board.js", "projects.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const card = (o) => ({
  profile: "bnb", name: "demo", stage: "alpha", version: "v0.1.0", goal: "ship the menu",
  progress: { open: 2, done: 1, open_weight: 3, done_weight: 1 }, percent: 25, eta_days: 4,
  requested: 1, inbox: 2, running: [], waiting: 0, queued: 0, status: "", status_date: "",
  summary: "v0.1.0 25% (1 of 4 by size), 7d 1, 28d 1, ETA 4d", in_flight: false, pace: 0.25, ...o,
});
// The Summary hub_core::table sends beside the cards the view kept out of `total`.
const listTable = (kept, total = kept.length, o = {}) => ({
  q: "", state: "", sort: "", dir: "desc", total, shown: kept.length,
  states: [{ name: "all", n: kept.length }, { name: "in flight", n: kept.filter((c) => c.in_flight).length }, { name: "waiting", n: kept.filter((c) => c.waiting).length }],
  columns: ["project", "profile", "stage", "version", "prio", "open", "done", "pct", "pace", "eta", "run", "wait", "queued"]
    .map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
  facets: [{ key: "stage", on: "", clear: "", values: [{ value: "alpha", n: kept.length, q: "stage:alpha" }] }], ...o,
});
const list = (cards = [card()], o = {}) => ({ cards, unlinked: [], errors: [], table: listTable(cards), ...o });
const rows = [
  { profile: "bnb", project: "demo", lane: "agent", state: "open", priority: "high", text: "fix the menu", raw: "- [ ] fix the menu", sheet: "a.md", tags: [] },
  { profile: "personal", project: "garden", lane: "human", state: "open", priority: "low", text: "water the beds", raw: "- [ ] water the beds", sheet: "b.md", tags: [] },
];
// The Summary hub_core::table sends beside the rows, for these rows.
const tableOf = (q, total, kept) => ({
  q, state: "", sort: "", dir: "desc", total, shown: kept.length,
  states: [{ name: "all", n: kept.length }, { name: "urgent", n: 0 }],
  columns: ["priority", "project", "lane", "state", "id", "version", "size", "tier", "since", "text", "profile", "tag"]
    .map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
  facets: [{ key: "lane", on: "", clear: "", values: [{ value: "agent", n: 1, q: "lane:agent" }] }],
});
const projects = [{ profile: "bnb", project: "demo", inbox: 0 }, { profile: "personal", project: "garden", inbox: 0 }];
const focus = [{ profile: "personal", open: 3 }, { profile: "bnb", open: 1 }];
// What /api/board answers: `scope` narrows the rows, `q` is a word of a row's text.
function board(u) {
  const p = new URLSearchParams(u.split("?")[1] || ""), scope = p.get("scope"), q = p.get("q") || "";
  const mine = rows.filter((r) => !scope || r.profile + "/" + r.project === scope);
  const kept = mine.filter((r) => r.text.includes(q));
  return { today: "2026-11-05", projects, rows: kept, focus, table: tableOf(q, mine.length, kept) };
}
const read = () => ({ cards: box("p-top").innerHTML + box("p-bar").innerHTML + box("p-list").innerHTML, head: box("p-head").innerHTML, rows: box("b-list").innerHTML });
function draw(data, open = null) {
  ctx.input = { data, feed: board("/api/board"), open };
  vm.runInContext(`st.tab = "projects"; st.arg = ""; st.views.projects = ""; pst.data = input.data; pst.err = null; bst.feed = input.feed; pst.open = null;
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
// A click on the page, on a target with these data attributes, inside a row when `row` is set.
function click(id, dataset, row) {
  const target = { id: "", dataset, closest: (sel) => (sel === "tr[data-row]" && row != null ? { dataset: { row } } : null) };
  for (const f of box(id).on.click) f({ type: "click", target });
}

test("the list is one table row per project with its counts, and the card's words stay on the card", () => {
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", phases: { done: 1, total: 3, next: "web" } }];
  const { cards } = draw(list([card({ running, queued: 2, waiting: 1, in_flight: true, prio: "focus", status: "landed it", status_date: "2026-11-05", pace: 4.25 }), card({ profile: "personal", name: "garden", stage: "", version: null, percent: null, eta_days: null, summary: "no version no rows" })], { unlinked: ["dotfiles: tidy"] }));
  assert.match(cards, /2 projects, 1 in flight; progress is the open version's rows by size/);
  assert.match(cards, /<button class="btn sm" data-open="all">All rows 2<\/button>/);
  assert.match(cards, /id="projects-q".*id="projects-chips"/s);
  assert.match(cards, />all <.*>in flight <.*>waiting </s);
  assert.match(cards, /data-tsort="project".*data-tsort="pace"[^>]*>pace\/wk<.*data-tsort="queued"/s);
  assert.match(cards, /<tr class="jr" data-open="bnb\/demo"><td>demo<\/td><td>bnb<\/td><td>alpha<\/td><td>v0\.1\.0<\/td><td>focus<\/td><td class="n">2<\/td><td class="n">1<\/td><td class="n">25%<\/td><td class="n">4\.3<\/td><td class="n">4d<\/td><td class="n">1<\/td><td class="n">1<\/td><td class="n">2<\/td><\/tr>/);
  assert.match(cards, /<tr class="jr" data-open="personal\/garden"><td>garden<\/td><td>personal<\/td><td>-<\/td><td>-<\/td><td>-<\/td>.*<td class="n">-<\/td><td class="n">0\.3<\/td><td class="n">-<\/td>/);
  for (const moved of ["ship the menu", "wire the bar", "landed it", "#requested", "class=\"card qitem"]) {
    assert.doesNotMatch(cards, new RegExp(moved), `${moved} is the opened card's`);
  }
  assert.match(cards, /Not on a card.*1 active queue items no project claims.*dotfiles: tidy/s);
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
  box("p-bar").innerHTML = "the box in use";
  ctx.document.activeElement = { id: "projects-q", dataset: {} };
  vm.runInContext(`renderProjects()`, ctx);
  ctx.document.activeElement = undefined;
  assert.equal(box("p-bar").innerHTML, "the box in use");
  assert.match(box("projects-chips").innerHTML, /in flight/);
  assert.match(box("projects-facets").innerHTML, /every stage/);
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
  vm.runInContext(`refreshProjects(); st.arg = "all";`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`pst.data.cards[0].name`, ctx), "kept");
});

const page = {
  project: "demo", flow_line: "ideas 3 | briefs 1 | plans 1 | epics 2 | rows 5 | landed 1 | verified 0",
  needs: ["verify: Saves (4 of 4 rows landed, no live proof)"],
  systems: [{ id: "ui", head: "ui  criteria 5 of 7", epics: [{ line: "Menus  [rows]  behind", behind: true }], closed: "+1 closed, 1 verified" }],
  systems_says: "1 systems, 1 open epics (2 rows with no epic)", next_says: "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet",
  next_rows: [{ stage: "beta", result: "FAIL", requirement: "a soak test" }], shipped_says: "none yet", shipped: [], errors: [],
};

test("an opened card reads its page once and shows Needs you, then folds with their counts", async () => {
  ctx.answers = { "/api/projects/demo/page": page };
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", phases: { done: 1, total: 3, next: "web" } }];
  const c = card({ running, counts: "1 running, 0 waiting, 0 queued; 1 rows #requested, 2 in the inbox", status: "landed it", note_says: "model-written, 2026-11-05" });
  let { head } = draw(list([c]), "bnb/demo");
  assert.match(head, /<div class="pgoal">ship the menu<\/div><div class="muted">Reading the page\.\.\.<\/div>/);
  await settle();
  head = box("p-head").innerHTML;
  assert.match(head, /flow: ideas 3 \| briefs 1/);
  assert.match(head, /Needs you <span class="muted">1<\/span><\/h2><div class="card"><div class="qlate">verify: Saves/);
  assert.match(head, /data-k="pg:systems"><summary><b>Build by system<\/b> <span class="muted">1 systems, 1 open epics \(2 rows with no epic\)<\/span>/);
  assert.match(head, /<div class="pep qlate">Menus  \[rows\]  behind<\/div><div class="pep muted">\+1 closed, 1 verified/);
  assert.match(head, /Next stage<\/b> <span class="muted">beta  4 of 12 met.*<b>FAIL<\/b> a soak test/s);
  assert.match(head, /Shipped<\/b> <span class="muted">none yet/);
  assert.match(head, /In flight<\/b> <span class="muted">1 running, 0 waiting, 0 queued; 1 rows #requested.*wire the bar/s);
  assert.match(head, /Agent note<\/b> <span class="muted">model-written, 2026-11-05.*landed it/s);
  assert.doesNotMatch(head, /<details[^>]* open/, "every fold starts shut");
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
  assert.match(shown, /1 of 1 open rows/);
  assert.match(shown, /data-tsort="priority".*data-tsort="text"/s);
  assert.doesNotMatch(shown, /data-tsort="profile"|data-tsort="tag"/, "a query key with no column of its own is not drawn");
  assert.match(shown, /<tr class="jr" data-row="0"><td><span class="qprio high">high<\/span><\/td><td>demo<\/td>.*fix the menu/s);
  assert.doesNotMatch(shown, /water the beds/, "another project's row is not sent");
  assert.doesNotMatch(shown, /href="#daily"/, "one project's rows have no Daily count");
  assert.match(box("b-bar").innerHTML, /id="board-q".*id="board-chips"/s);
});

test("a row opens under itself with its actions, and a second click shuts it", async () => {
  await drawn(list(), "bnb/demo");
  click("board", {}, "0");
  assert.match(read().rows, /<tr class="jr sel" data-row="0">.*<tr class="bopen"><td colspan="10">.*data-tag="0">Tags\.\.\./s);
  click("board", {}, "0");
  assert.doesNotMatch(read().rows, /bopen/);
});

test("a row action after the server filtered names the row on screen, not its place in the sheet", async () => {
  await drawn(list(), "all");
  ctx.answers = { "/api/projects": list() };
  vm.runInContext(`st.views.projects = "q=water"; refreshBoard();`, ctx);
  await settle(); await settle();
  assert.match(read().rows, /1 of 2 open rows/);
  ctx.sent = [];
  click("board", { start: "0" });
  await settle(); await settle();
  assert.equal(JSON.parse(ctx.sent.find((s) => s.body).body).raw, "- [ ] water the beds");
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?q=water"), "the re-read keeps the view");
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

test("All opens every project's rows, and a stats error is shown, not hidden", async () => {
  const all = await drawn(list(), "all");
  assert.match(all.rows, /fix the menu.*water the beds/s);
  assert.match(all.rows, /<a class="btn sm" href="#daily">Daily: personal 3, bnb 1 open<\/a>/, "the daily notes' Focus is a count linking to Daily");
  assert.match(draw(list([], { errors: ["notes projects failed"] })).cards, /panel down">notes projects failed/);
});

test("rows past the cap wait behind a button, and a view with nothing says so", async () => {
  await drawn(list(), "all");
  ctx.input = Array.from({ length: 205 }, (_, i) => ({ ...rows[0], raw: "- [ ] r" + i, text: "r" + i }));
  vm.runInContext(`bst.feed = { ...bst.feed, rows: input, table: { ...bst.feed.table, shown: 205, total: 205 } }; drawBoardList();`, ctx);
  assert.match(read().rows, /data-all="1">\+5 more/);
  click("board", { all: "1" });
  assert.doesNotMatch(read().rows, /\+5 more/);
  assert.match(read().rows, />r204</);
  vm.runInContext(`bst.feed = { ...bst.feed, rows: [], table: { ...bst.feed.table, shown: 0 } }; drawBoardList();`, ctx);
  assert.match(read().rows, /No row matches\./);
});
