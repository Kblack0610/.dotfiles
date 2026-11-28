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
for (const f of ["../../web-kit/kb-ui.js", "ui.js", "charts.js", "app.js", "table.js", "actions.js", "board.js", "ladder.js", "departments.js", "projects.js", "sprints.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

// hub_core::projects::Status as sent: the headline, then a Fact (chip label, note value) per labelled line.
const shown = (role, text, full) => ({ role, text, ...(full ? { full } : {}) });
const NOTE = { headline: shown("note", "landed it"), rows: [{ label: shown("chip", "Done"), value: shown("note", "the arena (#9).") }, { label: shown("chip", "Needs you"), value: shown("note", "cut at the cap...", "cut at the cap and then the rest of the line") }] };

const card = (o) => ({
  profile: "bnb", name: "demo", stage: "alpha", version: "v0.1.0", goal: "ship the menu",
  progress: { open: 2, done: 1, open_weight: 3, done_weight: 1, closed_7d: 1, closed_weight_7d: 1 },
  window: { version: "v0.1.0", opened: "2026-11-15", due: "2026-11-22", committed: 4, delivered: 1, open: 3, dropped: 0, interrupted: 0, days_left: 4 }, window_says: "1/4 due 11-22", window_share: 25, window_cell: "1/4", due_cell: "4d",
  requested: 1, inbox: 2, running: [], waiting: 0, queued: 0, status: { headline: null, rows: [] }, status_date: "",
  doing: 0, hot: 0, net7d_cell: "-", growing: false, today: { shipped: 0, checks: 0 }, oldest: "-",
  summary: "v0.1.0 window 1/4 rows, due 11-22 (4 days left), closed 1 in 7d, 1 in 28d", in_flight: false, pace: 0.3, ...o,
});
// The Summary hub_core::table sends beside the cards the view kept out of `total`.
const listTable = (kept, total = kept.length, o = {}) => ({
  q: "", state: "", sort: "", dir: "desc", total, shown: kept.length,
  states: [{ name: "all", n: kept.length }, { name: "in flight", n: kept.filter((c) => c.in_flight).length }, { name: "waiting", n: kept.filter((c) => c.waiting).length }],
  columns: ["project", "state", "profile", "stage", "version", "prio", "open", "net7d", "doing", "hot", "done", "7d", "pts", "pts7d", "window", "due", "pace", "run", "wait", "queued", "shipped", "oldest"]
    .map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
  facets: [{ key: "stage", on: [], clear: "", values: [{ value: "alpha", n: kept.length, pct: 50, on: false, q: "stage:alpha" }] }], ...o,
});
const list = (cards = [card()], o = {}) => ({ cards, unlinked: [], errors: [], table: listTable(cards), ...o });
const rows = [
  { profile: "bnb", project: "demo", lane: "agent", state: "open", priority: "high", section: "next", actions: ["start", "done", "promote", "demote", "move", "edit", "prio", "tag", "drop"], label: "NEXT UP (1)", when: "", text: "fix(ui): fix the menu, so back returns", title: "fix the menu", summary: "so back returns", type: "fix", area: "ui", points: 3, epic: "ui to standard", raw: "- [ ] fix(ui): fix the menu, so back returns", sheet: "a.md", tags: [] },
  { profile: "personal", project: "garden", lane: "human", state: "open", priority: "low", section: "backlog", label: "BACKLOG (1)", when: "queued  ~11-12", text: "water the beds", title: "water the beds", summary: "", raw: "- [ ] water the beds", sheet: "b.md", tags: [] },
];
// The Summary hub_core::table sends beside the rows, for these rows.
const tableOf = (q, total, kept) => ({
  q, state: "", sort: "", dir: "desc", total, shown: kept.length,
  states: [{ name: "all", n: kept.length }, { name: "urgent", n: 0 }],
  columns: ["section", "type", "area", "title", "epic", "priority", "state", "when", "project", "lane", "id", "version", "size", "pts", "tier", "since", "text", "profile", "tag"]
    .map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
  facets: [{ key: "lane", on: [], clear: "", values: [{ value: "agent", n: 1, pct: 50, on: false, q: "lane:agent" }] }],
});
const projects = [{ profile: "bnb", project: "demo", inbox: 0 }, { profile: "personal", project: "garden", inbox: 0 }];
const focus = [{ profile: "personal", open: 3 }, { profile: "bnb", open: 1 }];
// What /api/board answers: `scope` narrows the rows, `q` is a word of a row's text or `id:<prefix>`.
function board(u) {
  const p = new URLSearchParams(u.split("?")[1] || ""), scope = p.get("scope"), q = p.get("q") || "";
  const mine = rows.filter((r) => !scope || r.profile + "/" + r.project === scope);
  const kept = mine.filter((r) => (q.startsWith("id:") ? (r.id || "").startsWith(q.slice(3)) : r.text.includes(q)));
  // totals is the whole board's, whatever the view: agent 3, never the table's 2; tiers is the scope's agent board, backlog and epics.
  return { today: "2026-11-05", projects, rows: kept, focus, totals: { open: 7, doing: 0, human: 4, agent: 3, playtest: 0, backlog: 4, epic_open: 2, epic_backlog: 5 }, tiers: scope ? "Today 1 | Backlog 2 | Epics 1 | Epic backlog 0" : "Sprint 2/5 | Today 3 | Backlog 4 | Epics 2 | Epic backlog 5", table: tableOf(q, mine.length, kept) };
}
const read = () => ({ cards: box("p-cards").innerHTML, head: box("p-head").innerHTML, pane: box("p-pane").innerHTML + box("p-pane2").innerHTML, rows: box("b-tbl").innerHTML });
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
// Projects' Board inner tab (a sidebar tab until 2026-11-12, All rows until 2026-11-18) under this view, once its rows have come back.
async function onBoard(view = "") {
  ctx.view = view;
  ctx.answers = { "/api/projects": list() };
  vm.runInContext(`st.tab = "projects"; st.arg = "all"; st.views.projects = view; pst.open = null; TABS.projects.show();`, ctx);
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
  const { cards } = draw(list([card({ running, state: "at risk", state_level: "warn", queued: 2, waiting: 1, in_flight: true, prio: "focus", net7d_cell: "+120", growing: true, status: NOTE, status_date: "2026-11-05", pace: 4.3, doing: 1, hot: 1, today: { shipped: 3, checks: 1 }, oldest: "30h" }), card({ profile: "personal", name: "garden", state: "parked", state_level: null, stage: "", version: null, window: null, window_share: null, window_says: "no window", window_cell: "no window", due_cell: "-", summary: "no version no rows", oldest: "" })], { unlinked: ["dotfiles: tidy"] }));
  assert.match(cards, /<h2 class="sec" id="sec-cards">Projects <span class="n">2<\/span><\/h2>/);
  assert.doesNotMatch(cards, /qstats|progress is the open version/, "the in-flight count is its state chip");
  assert.doesNotMatch(cards, /Board/, "every project's rows are the Board inner tab");
  assert.match(cards, /id="projects-tiles".*id="projects-q"/s);
  assert.match(cards, />IN FLIGHT<.*>WAITING</s);
  assert.doesNotMatch(cards, />ALL</, "no tile is every row");
  assert.match(cards, /data-tsort="project".*data-tsort="pace"[^>]*>pace\/wk<.*data-tsort="queued"/s);
  assert.match(cards, /<tr class="jr" tabindex="0" data-open="bnb\/demo"><td>demo<\/td><td><span class="cchip state warn">At risk<\/span><\/td><td>bnb<\/td><td>alpha<\/td><td>v0\.1\.0<\/td><td>focus<\/td><td class="n">2<\/td><td class="n warn">\+120<\/td><td class="n">1<\/td><td class="n warn">1<\/td><td class="n">1<\/td><td class="n">1<\/td><td class="n">1<\/td><td class="n">1<\/td><td class="n">1\/4<\/td><td class="n">4d<\/td><td class="n">4\.3<\/td><td class="n">1<\/td><td class="n">1<\/td><td class="n">2<\/td><td class="n">3<\/td><td class="n">30h<\/td><\/tr>/);
  assert.match(cards, /<tr class="jr" tabindex="0" data-open="personal\/garden"><td>garden<\/td><td><span class="cchip state">Parked<\/span><\/td><td>personal<\/td><td>-<\/td><td>-<\/td><td>-<\/td>.*<td class="n">no window<\/td><td class="n">-<\/td><td class="n">0\.3<\/td>.*<td class="n">0<\/td><td class="n">-<\/td><\/tr>/, "no hot row is not lit, and an empty oldest is a dash");
  for (const moved of ["ship the menu", "wire the bar", "landed it", "#requested", "class=\"card qitem"]) {
    assert.doesNotMatch(cards, new RegExp(moved), `${moved} is the opened card's`);
  }
  assert.match(cards, /<details data-k="unlinked" open><summary><h2 class="sec">Not on a card <span class="n">1<\/span><\/h2><\/summary>.*dotfiles: tidy/s);
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
  assert.match(cards, /Projects <span class="n">0 of 1<\/span><\/h2>/);
  assert.match(cards, /No project matches\./);
});

test("a re-read keeps the search box the human is typing in", () => {
  draw(list());
  box("p-cards").innerHTML = "the box in use";
  ctx.document.activeElement = { id: "projects-q", dataset: {} };
  vm.runInContext(`renderProjects()`, ctx);
  ctx.document.activeElement = undefined;
  assert.equal(box("p-cards").innerHTML, "the box in use");
  assert.match(box("projects-tiles").innerHTML, /in flight/);
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
  need_count: 5,
  need_groups: [
    { kind: "verify", says: "1 epic landed with no live proof", items: ["verify: Saves (4 of 4 rows landed, no live proof)"] },
    { kind: "plan", says: "2 plans with no epic", items: ["plan with no epic: a", "plan with no epic: <b>"] },
    { kind: "stage", says: "1 beta check failing, 1 for a human", items: ["HUMAN sign off", "FAIL a soak test"] },
  ],
  alerts: { says: "2 watches, 1 firing", level: "bad" },
  checks: { says: "Partial outage: api", level: "bad" },
  systems: [
    { id: "ui", head: "ui  25%  1 feature, 0 done  criteria 5 of 7", percent: 25, closed: "+1 closed, 1 verified", criteria_met: 5, criteria_total: 7,
      features: 1, features_done: 0, standing: 1, open_rows: 3, behind: 1, wave: { id: "de-9", title: "Menus", percent: 25, more: 2 },
      epics: [{ id: "de-9", line: "Menus  25%  [rows]  behind", behind: true }] },
    { id: "ci", head: "ci  criteria 1 of 2", percent: null, epics: [], closed: "", criteria_met: 1, criteria_total: 2, features: 0, features_done: 0, standing: 0, open_rows: 0, behind: 0, wave: null },
  ],
  systems_says: "2 systems, 1 open epics (2 rows with no epic)", next_says: "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet",
  gate: { stage: "beta", met: 4, total: 12, fail: 1, human: 1 },
  // hub-core sorts them (`Requirement::rank`): failing first, then a human's.
  next_rows: [{ stage: "beta", result: "FAIL", requirement: "a soak test" }, { stage: "beta", result: "HUMAN", requirement: "sign off" }, { stage: "beta", result: "TODO", requirement: "a playtest" }],
  shipped_says: "none yet", shipped: [], errors: [],
  release_tab: { versions: [], apps: [], legacy_versions: [], legacy_apps: [], line_text: "no app releases under this project, so no line", legacy_says: "0 versions, 0 apps", elsewhere: [], errors: [] },
  timeline: { says: "7d: 1 commit (1 red on CI), 1 PR", older: 3, notes: ["PRs: the origin is not GitHub"], lines: [
    { line: "2h  commit  fix the menu  CI red", level: "bad", url: "https://ci.example/run/1" },
    { line: "3h  PR      #7 opened: <menu>", level: "ok", url: "javascript:alert(1)" },
  ] },
};
// The pane of inner tab `id` in the drawn page.
const pinOf = (pane, id) => (pane.match(new RegExp(`<div data-pin="${id}"( hidden)?>(.*?)</div>(?=<div data-pin=|$)`, "s")) || [])[0] || "";

test("an opened project is a header and an inner tab strip over Overview, never every epic's tasks", async () => {
  ctx.answers = { "/api/projects/demo/page": page };
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", row: "ar-9", phases: { done: 1, total: 3, shown: "1/3", next: "web" } }];
  const running_table = { q: "", state: "", sort: "", dir: "desc", total: 1, shown: 1, states: [], facets: [], columns: ["item", "project", "row", "epic", "phase", "eta", "pr", "ci", "since"].map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc", role: key === "item" ? "lead" : "" })), links: [{ item: "#queue/s1", project: "#projects/demo", row: "#projects/all?q=id:=ar-9" }] };
  const c = card({ running, running_table, state: "on track", state_level: "ok", counts: "1 running, 0 waiting, 0 queued; 1 rows #requested, 2 in the inbox", status: NOTE, status_date: "2026-11-05", version_lines: ["v0.2.0: 2 open epics, 5 of 20 points done <b>"] });
  let { head, pane } = draw(list([c]), "bnb/demo");
  assert.match(head, /<span class="ctitle">demo<\/span><span class="cchip state ok">On track<\/span><span class="cchip ">alpha<\/span>/, "the state pill leads the chips");
  assert.match(head, /<div class="pgoal">ship the menu<\/div><div class="cline">epics: v0\.2\.0: 2 open epics, 5 of 20 points done &lt;b&gt;<\/div><\/div>/, "one line per version, escaped");
  assert.match(pinOf(pane, "overview"), /Reading the page\.\.\./);
  await settle();
  ({ head, pane } = read());
  assert.match(head, /v0\.1\.0 window 1\/4 rows, due 11-22 \(4 days left\), closed 1 in 7d, 1 in 28d/, "every number is named");
  assert.match(head, /flow: ideas 3 \| briefs 1/);
  assert.match(head, /<div class="cline">alerts: <a class="bad" href="#alerts\?q=project%3Ademo">2 watches, 1 firing<\/a><\/div>/);
  // The checks line opens the app's status page, and sits between releases and alerts.
  assert.match(head, /<div class="cline">checks: <a class="bad" href="#releases\/apps\/demo">Partial outage: api<\/a><\/div><div class="cline">alerts:/);
  assert.match(head, /<div class="cline warn">next stage: <a href="#" data-pgo="stage">beta  4 of 12 met, 1 failing/);
  // The strip: Overview open, its count what needs the human (1 verify, 2 plans, 2 checks), Stage's the failing checks.
  assert.match(head, /role="tablist"><button role="tab" data-ptab="overview" class="on" aria-selected="true" tabindex="0">Overview <span class="pill warn">5<\/span><\/button><button role="tab" data-ptab="sprint"[^>]*>Sprint<\/button><button role="tab" data-ptab="rows" class="" aria-selected="false" tabindex="-1">Rows<\/button><button role="tab" data-ptab="deliverables"[^>]*>Deliverables<\/button><button role="tab" data-ptab="releases"[^>]*>Releases<\/button><button role="tab" data-ptab="stage"[^>]*>Stage <span class="pill warn">1<\/span><\/button><button role="tab" data-ptab="activity"[^>]*>Activity<\/button><button role="tab" data-ptab="knowledge"[^>]*>Knowledge<\/button><\/div>$/);
  const over = pinOf(pane, "overview");
  assert.match(over, /^<div data-pin="overview">/, "Overview shows");
  for (const id of ["rows", "releases", "stage", "activity"]) assert.match(pinOf(pane, id), new RegExp(`^<div data-pin="${id}" hidden>`), `${id} is hidden`);
  // Needs you: each kind a shut fold with the inner tab that acts on it.
  assert.match(over, /id="sec-p-needs">Needs you <span class="n">5<\/span><\/h2>/);
  assert.match(over, /<details class="cfold" data-k="pg:need:verify"><summary><b>1 epic landed with no live proof<\/b><\/summary><div>verify: Saves/);
  assert.match(over, /data-k="pg:need:plan"><summary><b>2 plans with no epic<\/b><\/summary><div>plan with no epic: a<\/div><div>plan with no epic: &lt;b&gt;<\/div>/);
  assert.match(over, /data-k="pg:need:stage"><summary><b>1 beta check failing, 1 for a human<\/b> <a href="#" data-pgo="stage">open Stage<\/a><\/summary><div>HUMAN sign off<\/div><div>FAIL a soak test<\/div>/);
  assert.doesNotMatch(over, /<details[^>]* open/, "a group's items are per-row detail and start shut");
  assert.match(over, /id="sec-p-flight">In flight <span class="n">1<\/span><\/h2>.*wire the bar.*<div class="cline muted">1 running, 0 waiting, 0 queued; 1 rows #requested, 2 in the inbox<\/div><div class="cline"><a href="#queue\?q=project%3Ademo"/s);
  // In flight is Home's Running table scoped to the project: the item and its next phase, the
  // phase as hub_core words it, no PROJECT column, no sort button or row click on a fixed list.
  const flight = (over.match(/id="sec-p-flight".*?<\/table>/s) || [""])[0];
  assert.match(flight, /<th class="n"[^>]*>phase<\/th>/);
  assert.doesNotMatch(flight, />project<|thsort|class="jr"|<ul/, "scoped to the project, nothing to sort, no old list");
  assert.match(flight, /<tr><td class="wrap"><a class="tl" href="#queue\/s1">wire the bar<\/a><div class="muted">next: web<\/div><\/td><td><a class="tl" href="#projects\/all\?q=id:=ar-9">ar-9<\/a><\/td><td>-<\/td><td class="n">1\/3<\/td>/);
  // Systems: one row each, the head's numbers as columns; a system opens Deliverables.
  assert.match(over, /id="sec-p-systems">Systems <span class="n">2<\/span><\/h2>/);
  assert.match(over, /<tr class="jr" tabindex="0" data-psys="ui"><td>ui<\/td><td class="n">25%<\/td><td class="n">0 of 1<\/td><td class="n">1<\/td><td class="n">3<\/td><td class="n warn">1<\/td><td class="n">5 of 7<\/td><td class="wrap">Menus 25% <span class="muted">\+2<\/span><\/td><\/tr>/);
  assert.match(over, /data-psys="ci"><td>ci<\/td><td class="n">-<\/td><td class="n">-<\/td><td class="n">-<\/td><td class="n">-<\/td><td class="n">-<\/td><td class="n">1 of 2<\/td><td class="wrap">-<\/td>/);
  // NEGATIVE CONTROL: the leaves the page carries are never drawn.
  assert.doesNotMatch(head + pane, /wire the pause key|data-leaf/);
  // Stage: failing first, then a human's, then the rest.
  assert.match(pinOf(pane, "stage"), /<h2 class="sec warn" id="sec-p-stage">Next stage <span class="n">4 of 12<\/span><\/h2>.*<b>FAIL<\/b> a soak test.*<b>HUMAN<\/b> sign off.*<b>TODO<\/b> a playtest/s);
  const act = pinOf(pane, "activity");
  assert.match(act, /id="sec-p-shipped">Shipped <span class="n">0<\/span><\/h2>/);
  assert.match(act, /id="sec-p-timeline">Timeline <span class="n">5<\/span><\/h2>.*<div class="muted">PRs: the origin is not GitHub<\/div>/s);
  assert.match(act, /<div class="ptl bad"><a href="https:\/\/ci\.example\/run\/1" target="_blank" rel="noopener">2h  commit  fix the menu  CI red<\/a><\/div>/);
  assert.match(act, /<div class="ptl">3h  PR      #7 opened: &lt;menu&gt;<\/div><div class="muted more">\+3 older<\/div>/, "a non-http url is not a link");
  // The note is its headline over a key table; a cut line shows its uncut words on the opened card.
  assert.match(act, /id="sec-p-note">Agent note<\/h2><div class="card"><div class="pstat">landed it<\/div><dl><dt>Done<\/dt><dd>the arena \(#9\)\.<\/dd><dt>Needs you<\/dt><dd>cut at the cap and then the rest of the line<\/dd><\/dl><div class="cline muted"><b>written<\/b> 2026-11-05<\/div><\/div>/);
  assert.doesNotMatch(act, /cut at the cap\.\.\./, "the cap's cut is not drawn where the full text is");
});

test("Knowledge draws the project's docs, notes, asks and queue, says so for a part with nothing, and names a space that could not be read", () => {
  const base = { status: { headline: shown("note", "beta next"), date: "2026-11-20" }, cadence: { target_days: 14, measured_days: 16, cuts: 8, due_on: "2026-12-02", due: true },
    tracker: { system: "github", urls: ["https://example.test/demo"] }, lab: { core: [], docs: [{ path: "docs/briefs/a.md", title: shown("title", "A <brief>"), modified: "2026-11-01" }] },
    repo: null, agent: { plans: [], sessions: [], outcomes: [], lessons: { path: null, count: 0 } }, knowledge: [],
    asks: [{ id: "ask-1", title: "pick one" }], queue: [{ slug: "ar-1", state: "running" }], errors: ["agent-queue list: down"] };
  const k = ctx.pKnowledge({ space: base });
  assert.match(k, /id="sec-p-space-head">Status <span class="n">2026-11-20<\/span>/);
  assert.match(k, /<b>cadence<\/b> every 14 days promised, 16 measured over 8 cuts, due 2026-12-02 <span class="warn">\(due now\)<\/span>/);
  assert.match(k, /<td class="wrap">docs\/briefs\/a\.md<\/td><td class="wrap">A &lt;brief&gt;<\/td>/, "a title is escaped");
  assert.match(k, /No repo cloned here\./);
  assert.match(k, /No ADRs\.|No plans\./);
  assert.match(k, /No knowledge note names this project\./);
  assert.match(k, /<b>ask-1<\/b> pick one/);
  assert.match(k, /<b>ar-1<\/b> <span class="muted">running<\/span> <\/div>/, "an untitled item is not 'undefined'");
  assert.match(k, /<div class="panel down"><div>agent-queue list: down<\/div><\/div>/);
  assert.doesNotMatch(k, /undefined/);
  assert.match(ctx.pKnowledge({ space: null }), /could not be read/);
});

test("an inner tab is in the URL, a deep link opens on it, and a system opens Deliverables filtered to it", async () => {
  ctx.answers = { "/api/projects/demo/page": page, "/api/projects": list() };
  await drawn(list(), "bnb/demo");
  vm.runInContext(`pInner("stage")`, ctx);
  assert.equal(vm.runInContext(`st.arg + "|" + pst.inner`, ctx), "bnb/demo/stage|stage");
  vm.runInContext(`pInner("overview")`, ctx);
  assert.equal(vm.runInContext(`st.arg`, ctx), "bnb/demo", "Overview is the bare project");
  // A deep link with an inner tab, by profile/name or by name.
  for (const arg of ["bnb/demo/rows", "demo/rows"]) {
    vm.runInContext(`pst.open = null; st.arg = ${JSON.stringify(arg)}; pDeep();`, ctx);
    assert.equal(vm.runInContext(`pst.open + "|" + pst.inner`, ctx), "bnb/demo|rows", arg);
  }
  // NEGATIVE CONTROL: an unknown tail is no inner tab, and no project matches it.
  assert.deepEqual(JSON.parse(vm.runInContext(`JSON.stringify(pSplit("bnb/demo/nope"))`, ctx)), { key: "bnb/demo/nope", inner: "overview", dept: "", sprint: "" });
  vm.runInContext(`pInner("overview"); st.views.projects = "";`, ctx);
  ctx.sent = [];
  ctx.answers["/api/deliverables?dq=sys%3Aui&scope=bnb%2Fdemo"] = deliv();
  const target = { id: "", dataset: {}, closest: (sel) => (sel === "[data-psys]" ? { dataset: { psys: "ui" } } : null) };
  for (const f of box("projects").on.click) f({ type: "click", target });
  await settle(); await settle();
  assert.equal(vm.runInContext(`st.views.projects + "|" + st.arg`, ctx), "dq=sys%3Aui|bnb/demo/deliverables");
  assert.ok(ctx.sent.some((s) => s.u === "/api/deliverables?dq=sys%3Aui&scope=bnb%2Fdemo"), "Deliverables reads this project's epics");
  assert.match(box("p-deliv").innerHTML, /<h2 class="sec warn" id="sec-p-build">Deliverables <span class="n">2<\/span><\/h2>/);
  // An epic's row on Deliverables opens Rows filtered to that epic's rows.
  const o = { dataset: { open: "bnb/demo", epic: "de-9", sys: "ui" } };
  const row = { id: "", dataset: {}, closest: (sel) => (sel === "[data-open]" ? o : null) };
  for (const f of box("projects").on.click) f({ type: "click", target: row });
  assert.equal(vm.runInContext(`st.views.projects + "|" + st.arg`, ctx), "dq=sys%3Aui&q=tag%3A%3Dof%2Fde-9|bnb/demo/rows");
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
  assert.match(head, /^<nav class="crumb"[^>]*><a href="#projects" id="p-back">Projects<\/a> <span class="muted">&gt;<\/span> <b>demo<\/b><\/nav>.*v0\.1\.0 window 1\/4/s, "the breadcrumb, then the card");
  assert.match(shown, /1 of 1 rows; Today 1 \| Backlog 2 \| Epics 1 \| Epic backlog 0/, "the project's agent board, backlog and epics, the hub's words");
  assert.match(shown, /data-tsort="section".*data-tsort="type".*data-tsort="area".*data-tsort="title".*data-tsort="epic".*data-tsort="priority".*data-tsort="when".*data-tsort="id".*data-tsort="pts"/s);
  assert.doesNotMatch(shown, /data-tsort="(profile|tag|text|version|since)"/, "a query key or a field the opened row holds is not a column");
  // The row leads with its type and area, each its own column, then its title, the whole line
  // under it, then the epic it serves; its points close the line.
  assert.match(shown, /<tr class="jr" data-row="0"><td><b>NEXT UP \(1\)<\/b><\/td><td>fix<\/td><td>ui<\/td><td class="btitle"><div class="bt">fix the menu<\/div><div class="bsum muted">so back returns<\/div><\/td><td class="bepic">ui to standard<\/td><td><span class="qprio high">high<\/span><\/td>/);
  assert.match(shown, /<code>-<\/code><\/td><td class="n">3<\/td><\/tr>/, "the row's #pts is its own cell");
  assert.doesNotMatch(shown, /water the beds/, "another project's row is not sent");
  assert.doesNotMatch(shown, /href="#daily"/, "one project's rows have no Daily count");
  assert.match(read().rows, /id="board-tiles".*id="board-q"/s);
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
  assert.match(read().rows, /1 of 2 rows; Sprint 2\/5 \| Today 3 \| Backlog 4 \| Epics 2 \| Epic backlog 5/);
  vm.runInContext(`bst.feed = { ...bst.feed, tiers: null }; bst.render();`, ctx);
  assert.doesNotMatch(read().rows, /; (Sprint|Today)/, "an older notes sends no tiers: no line, never a 0");
  vm.runInContext(`bst.feed = { ...bst.feed, tiers: "Today 3 | Backlog 4" }; bst.render();`, ctx);
  ctx.sent = [];
  click("b-root", { start: "0" });
  await settle(); await settle();
  assert.equal(JSON.parse(ctx.sent.find((s) => s.body).body).raw, "- [ ] water the beds");
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?q=water"), "the re-read keeps the view");
});

// hub_core::tasks::SprintRow as /api/sprints sends it: the columns and heads of one table, a row per window.
const SPR_COLS = ["project", "version", "started", "cut", "left", "done", "finish", "build"].map((key) => ({ key, role: key === "project" ? "lead" : "" }));
const SPR_HEADS = { project: "PROJECT", version: "VERSION", started: "STARTED", cut: "CUT", left: "LEFT", done: "DONE", finish: "FINISH (7d rate)", build: "BUILD" };
const sprRow = (o) => ({ profile: "bnb", project: "demo", version: "v0.3.0", queued: false, started: "11-19 14:25", cut: "11-19 15:59", left: "49m", done: "0/2", finish: "~15:40", late: false, build: "none", ...o });
const sprQueued = () => sprRow({ version: "v0.3.1", queued: true, started: "11-19 15:59", cut: "11-20 15:59", left: "queued", done: "0/1" });
const sprAnswer = (rows, o = {}) => ({ rows, table: { columns: SPR_COLS, links: rows.map((r) => ({ version: `#projects/bnb%2F${r.project}/sprint/${r.version}` })) }, heads: SPR_HEADS, ...o });

test("Board shows rows only: the windows are the Sprints tab's", async () => {
  await onBoard("q=water");
  vm.runInContext(`bst.feed = { ...bst.feed, sprints: ${JSON.stringify(sprAnswer([sprRow({})]))} }; bst.render();`, ctx);
  assert.doesNotMatch(read().rows, /Sprints|v0\.3\.0|de-1/, "a window is not a row");
});

test("Projects > Sprints is one row per window, its version a link to its page, then each project's last score", async () => {
  ctx.answers = { "/api/projects": list(), "/api/sprints": sprAnswer([sprRow({}), sprRow({ project: "late", left: "over", finish: "~11-20 09:00", late: true }), sprQueued()], { last: [{ profile: "bnb", project: "demo", version: "v0.2.0", line: "delivered 3 of 4" }] }) };
  vm.runInContext(`sprst.data = null; st.tab = "projects"; st.arg = "sprints"; st.views.projects = ""; pst.open = null; TABS.projects.show();`, ctx);
  await settle(); await settle();
  const html = box("p-sprints").innerHTML;
  assert.match(html, /<h2 class="sec" id="sec-sprints">Sprints <span class="n">3<\/span><\/h2>/);
  assert.match(html, /<td><a class="tl" href="#projects\/bnb%2Fdemo\/sprint\/v0\.3\.1">v0\.3\.1<\/a><\/td><td>11-19 15:59<\/td><td>11-20 15:59<\/td><td class="muted">queued<\/td>/, "a queued sprint starts at the open one's cut");
  assert.match(html, />FINISH \(7d rate\)</);
  assert.match(html, /<td>11-19 14:25<\/td><td>11-19 15:59<\/td><td>49m<\/td><td>0\/2<\/td><td>~15:40<\/td><td>-<\/td>/);
  assert.match(html, /<td class="warn">over<\/td>.*<td class="warn">~11-20 09:00 late<\/td>/s, "a finish after the cut is marked late");
  assert.match(html, /Last score <span class="n">1<\/span>.*<td>demo<\/td><td>v0\.2\.0<\/td><td class="wrap muted">delivered 3 of 4<\/td>/s);
  assert.match(html, /<a class="tl" href="#projects\/bnb%2Fdemo\/sprint\/v0\.3\.0">v0\.3\.0<\/a>/, "a version links to its sprint page");
  assert.doesNotMatch(html, /data-spr|data-stask|de-1/, "no window folds open to its tasks");
  // The control: no window at all is a line, never an empty table.
  ctx.answers["/api/sprints"] = sprAnswer([], { last: [] });
  vm.runInContext(`sprst.data = null; refreshSprints();`, ctx);
  await settle(); await settle();
  assert.match(box("p-sprints").innerHTML, /No window is open or queued\..*No project has a scored window\./s);
});

test("a project's Sprint tab has its open window, the queued one, and the scored past newest first, each version a link", async () => {
  const past = [{ version: "v0.2.0", link: "#projects/bnb%2Fdemo/sprint/v0.2.0", opened: "11-10", cut: "11-17", committed: 5, delivered: 4, carried: 1, dropped: 0, interrupted: 2, timing: "1d late", line: "delivered 4 of 5" }, { version: "v0.1.0", link: "#projects/bnb%2Fdemo/sprint/v0.1.0", opened: null, cut: null, committed: 3, delivered: 3, carried: 0, dropped: 0, interrupted: 0, timing: null, line: "delivered 3 of 3" }];
  ctx.answers = { "/api/projects/demo/page": { ...page, sprint_past: past }, "/api/sprints?scope=bnb%2Fdemo": sprAnswer([sprRow({}), sprQueued()]) };
  vm.runInContext("sprst.data = null", ctx);
  draw(list([card({})]), "bnb/demo");
  vm.runInContext(`pInner("sprint");`, ctx);
  await settle(); await settle();
  const sprint = pinOf(read().pane, "sprint");
  assert.doesNotMatch(sprint, /hidden/, "the Sprint tab shows");
  const at = (re) => sprint.search(re);
  const [open, queued, pastAt] = [at(/id="sec-p-sprint">Sprint <span class="n">1</), at(/id="sec-p-sprint-queued">Queued <span class="n">1</), at(/id="sec-p-sprint-past">Past <span class="n">2</)];
  assert.ok(open >= 0 && open < queued && queued < pastAt, sprint);
  assert.match(sprint.slice(open, queued), /<a class="tl" href="#projects\/bnb%2Fdemo\/sprint\/v0\.3\.0">v0\.3\.0<\/a>/, "the open window's version links to its page");
  assert.doesNotMatch(sprint.slice(open, queued), /v0\.3\.1/, "the queued window is not the open one");
  assert.match(sprint.slice(queued, pastAt), /v0\.3\.1.*queued/s);
  const pastHtml = sprint.slice(pastAt);
  assert.ok(pastHtml.indexOf("v0.2.0") >= 0 && pastHtml.indexOf("v0.2.0") < pastHtml.indexOf("v0.1.0"), "newest first");
  assert.match(pastHtml, /<td class="warn">1d late<\/td>/, "a late cut is marked");
  assert.match(pastHtml, /<a class="tl" href="#projects\/bnb%2Fdemo\/sprint\/v0\.2\.0">v0\.2\.0<\/a>/, "a scored version links to its page");
  assert.doesNotMatch(pastHtml, /delivered 4 of 5|data-past/, "no past row folds open");
  assert.ok(ctx.sent.some((x) => x.u === "/api/sprints?scope=bnb%2Fdemo"), "the project's windows are read under its scope");
});

test("a sprint page's deep link splits off its version, and its By area rows narrow the rows below", () => {
  const sp = JSON.parse(vm.runInContext(`JSON.stringify(pSplit("bnb/demo/sprint/v0.3.0"))`, ctx));
  assert.deepEqual(sp, { key: "bnb/demo", inner: "sprint", dept: "", sprint: "v0.3.0" });
  const d = { page: { version: "v0.3.0", prev: "#projects/bnb%2Fdemo/sprint/v0.2.0", next: null, head: ["11-19 to 11-20", "delivered 2 of 3"], errors: [], by_area: [{ group: "Engine", rows: 2 }, { group: "Look and UI", rows: 1 }] }, area_heads: { group: "AREA", rows: "ROWS", delivered: "DELIVERED", pending: "OPEN", dropped: "DROPPED", pts: "PTS" }, table: { total: 3 }, rows: [] };
  const html = vm.runInContext(`spgHead(${JSON.stringify(d)})`, ctx);
  assert.match(html, /<a class="tl" href="#projects\/bnb%2Fdemo\/sprint\/v0\.2\.0">previous<\/a> <span class="muted">next<\/span>/, "prev and next are links where there is a neighbour");
  assert.match(html, /<tr class="jr" data-tqc="group:Engine"/);
  assert.match(html, /data-tqc="group:&quot;Look and UI&quot;"/, "a group with spaces is quoted into the query");
  const head = html.match(/<tr><th.*?<\/tr>/)[0];
  assert.equal((head.match(/data-role="lead"/g) || []).length, 1, "the By area header leads with the area");
  assert.ok((head.match(/data-role="glance"/g) || []).length <= 3, "and glances at no more than 3");
  assert.match(html, /<div class="panel scroll" data-tbl="sp">/, "the rollup sits inside the table's own block, so the table's click handler hears it");
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
  assert.equal(vm.runInContext(`bst.feed`, ctx), null, "Board's rows do not follow");
  ctx.input = { data: list() };
  ctx.answers = { "/api/projects/demo/page": page };
  vm.runInContext(`pst.data = input.data; pOpen("bnb/demo");`, ctx);
  await settle(); await settle();
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?scope=bnb%2Fdemo"));
});

test("a Board answer that lands after the inner tab changed is dropped", async () => {
  await onBoard();
  vm.runInContext(`bst.feed = null; refreshBoard(); st.arg = "";`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`bst.feed`, ctx), null);
});

test("Board opens every project's rows, and a stats error is shown, not hidden", async () => {
  const all = await onBoard();
  assert.match(all.rows, /fix the menu.*water the beds/s);
  assert.match(all.rows, /<a class="btn sm" href="#daily">Daily: personal 3, bnb 1 open<\/a>/, "the daily notes' Focus is a count linking to Daily");
  assert.match(draw(list([], { errors: ["notes projects failed"] })).cards, /panel down">notes projects failed/);
});

test("the board draws the page the server sends with its pager, a write names the page's row, and a view with nothing says so", async () => {
  await onBoard();
  ctx.input = Array.from({ length: 5 }, (_, i) => ({ ...rows[0], raw: "- [ ] r" + (30 + i), text: "r" + (30 + i), title: "r" + (30 + i), summary: "" }));
  vm.runInContext(`bst.feed = { ...bst.feed, rows: input, table: { ...bst.feed.table, shown: 35, total: 35, pager: { page: 2, pages: 2, per: 30 } } }; bst.render();`, ctx);
  assert.match(read().rows, /<td>ui<\/td><td class="btitle"><div class="bt">r34</);
  assert.match(read().rows, /<span class="muted" aria-live="polite">rows 31-35 of 35<\/span>/);
  assert.doesNotMatch(read().rows, /data-all|\+\d+ more/);
  ctx.sent = [];
  click("b-root", { start: "4" });
  await settle();
  assert.ok(ctx.sent.some((s) => s.u === "/api/board" && JSON.parse(s.body).raw === "- [ ] r34"), "the action index is into the page sent");
  vm.runInContext(`bst.feed = { ...bst.feed, rows: [], table: { ...bst.feed.table, shown: 0 } }; bst.render();`, ctx);
  assert.match(read().rows, /No row matches\./);
});

test("the epics chip lists epics with their open and done rows as a link to those rows, and the task rows keep their epic cell", async () => {
  await onBoard("s=epics");
  const epic = { ...rows[0], lane: "human", priority: "high", section: "epics", label: "EPICS (1)", type: "epic", area: "menu", id: "demo-1", raw: "- [ ] epic(menu): the menu", text: "epic(menu): the menu", title: "the menu", summary: "", children: { open: 12, done: 4 } };
  const cols = ["section", "type", "area", "title", "epic", "priority", "state", "when", "project", "lane", "id", "version", "size", "pts", "tier", "since", "text", "profile", "tag", "rows"];
  ctx.input = { rows: [epic], table: { ...tableOf("", 1, [epic]), state: "epics", columns: cols.map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })), links: [{ rows: "#projects/all?q=tag:=of/demo-1" }] } };
  vm.runInContext(`bst.feed = { ...bst.feed, rows: input.rows, table: input.table }; bst.render();`, ctx);
  const html = read().rows;
  assert.match(html, /<a class="tl" href="#projects\/all\?q=tag:=of\/demo-1">12 open \/ 4 done<\/a>/, "the count opens the epic's rows");
  assert.match(html, /<th[^>]*data-label="epic".*<th[^>]*data-label="rows".*<th[^>]*data-label="priority".*<th[^>]*data-label="project".*<th[^>]*data-label="id"/s, "the head runs epic, rows, priority, project, id");
  assert.doesNotMatch(html, /data-label="(section|lane|when)"|no epic/, "an epic has no section, and is under none");
  // The default chip draws tasks: a task under an epic links up to it, one under none says so.
  const task = { ...rows[0], parent: "demo-1", epic: "the menu" };
  ctx.input = { rows: [task, rows[1]], table: { ...tableOf("", 2, [task, rows[1]]), links: [{ epic: "#projects/all?q=id:=demo-1" }, {}] } };
  vm.runInContext(`bst.feed = { ...bst.feed, rows: input.rows, table: input.table }; bst.render();`, ctx);
  const tasks = read().rows;
  assert.match(tasks, /<a class="tl" href="#projects\/all\?q=id:=demo-1">the menu<\/a>/);
  assert.match(tasks, /<span class="muted">no epic<\/span>/);
  assert.doesNotMatch(tasks, /data-label="rows"/);
});

test("the strip is the list, Board and Deliverables; a count is a total once read, never amber", async () => {
  vm.runInContext(`pCount.all = null; pCount.sprints = null; pCount.deliverables = null;`, ctx);
  draw(list());
  const strip = () => box("p-strip").innerHTML;
  assert.match(strip(), /data-itab="list" class="on"[^>]*>Projects<.*data-itab="all" class=""[^>]*>Board<.*data-itab="deliverables" class=""[^>]*>Deliverables</s);
  assert.doesNotMatch(strip(), /span/, "nothing read, nothing counted");
  ctx.answers = { "/api/projects": list([card()], { board_open: 9 }) };
  ctx.sent = [];
  vm.runInContext(`st.tab = "projects"; st.arg = ""; st.views.projects = ""; pst.open = null; TABS.projects.show();`, ctx);
  await settle(); await settle();
  assert.match(strip(), /data-itab="all" class=""[^>]*>Board <span class="muted">9<\/span>/, "Board's count comes with the list, before its rows are read");
  assert.ok(!ctx.sent.some((s) => s.u.startsWith("/api/board")));
  await onBoard();
  assert.match(strip(), /data-itab="all" class="on"[^>]*>Board <span class="muted">3<\/span>/, "the agent board's totals.agent, not every lane's open 7 nor the rows table's 2");
  assert.doesNotMatch(strip(), /warn/);
  ctx.answers = { "/api/projects/demo/page": "not read here" };
  vm.runInContext(`pst.data = ${JSON.stringify(list())}; pOpen("bnb/demo");`, ctx);
  assert.equal(strip(), "", "an opened project has its own strip");
  vm.runInContext(`pGo(null);`, ctx);
});

test("a strip click reads only the inner tab it shows, and leaves the old one's view behind", async () => {
  await drawn(list());
  ctx.answers = { "/api/deliverables": deliv(), "/api/projects": list() };
  ctx.sent = [];
  vm.runInContext(`st.views.projects = "q=menu"; innerGo("projects", "deliverables");`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`st.arg + "|" + st.views.projects`, ctx), "deliverables|");
  assert.deepEqual(ctx.sent.map((s) => s.u), ["/api/deliverables"]);
  assert.match(box("p-strip").innerHTML, /data-itab="deliverables" class="on"[^>]*>Deliverables <span class="muted">2<\/span>/);
  ctx.sent = [];
  vm.runInContext(`innerGo("projects", "all");`, ctx);
  await settle(); await settle();
  assert.deepEqual(ctx.sent.map((s) => s.u), ["/api/board"]);
  assert.match(read().rows, /fix the menu.*water the beds/s);
});

test("a link to Board (`#board`) leaves an opened project", async () => {
  ctx.answers = { "/api/projects": list(), "/api/projects/demo/page": "not read here" };
  vm.runInContext(`st.tab = "projects"; pst.data = ${JSON.stringify(list())}; pGo("bnb/demo");`, ctx);
  assert.equal(vm.runInContext(`pst.open`, ctx), "bnb/demo");
  ctx.sent = [];
  vm.runInContext(`st.arg = "all"; st.views.projects = "q=water"; TABS.projects.show();`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`pst.open`, ctx), null);
  assert.ok(ctx.sent.some((s) => s.u === "/api/board?q=water"), "the link's search is read, with no scope");
  assert.match(read().rows, /1 of 2 rows/);
});

test("a repaint with the same counts flips the strip's marks in place, so its focus stays", async () => {
  await drawn(list());
  vm.runInContext(`pCount.all = 2; pCount.deliverables = null; pStripPaint();`, ctx);
  const strip = box("p-strip");
  strip.innerHTML = "the strip in use";
  vm.runInContext(`renderProjects()`, ctx);
  assert.equal(strip.innerHTML, "the strip in use", "same counts, no rebuild");
  // A count that changes rebuilds it, and the button that had focus gets it back.
  let focused = null;
  strip.querySelector = (sel) => ({ focus() { focused = sel; } });
  ctx.document.activeElement = { dataset: { itab: "all" } };
  strip.contains = () => true;
  vm.runInContext(`pCountSet("all", 7)`, ctx);
  ctx.document.activeElement = undefined;
  delete strip.contains; delete strip.querySelector;
  assert.match(strip.innerHTML, /Board <span class="muted">7<\/span>/);
  assert.equal(focused, '[data-itab="all"]');
});

test("each inner tab keeps its own view: the Board search is back after a look at Deliverables", async () => {
  await drawn(list());
  ctx.answers = { "/api/deliverables": deliv(), "/api/projects": list() };
  vm.runInContext(`innerGo("projects", "all");`, ctx);
  await settle(); await settle();
  vm.runInContext(`setQuery("q=water"); innerGo("projects", "deliverables");`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`st.views.projects`, ctx), "", "Deliverables has its own view");
  ctx.sent = [];
  vm.runInContext(`innerGo("projects", "all");`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`st.views.projects`, ctx), "q=water");
  assert.deepEqual(ctx.sent.map((s) => s.u), ["/api/board?q=water"]);
  assert.match(read().rows, /1 of 2 rows/);
  vm.runInContext(`setQuery(""); innerGo("projects", "list");`, ctx);
  await settle(); await settle();
});

test("Board reached from an open project with no query of its own leaves the project's search behind", async () => {
  ctx.answers = { "/api/projects": list(), "/api/projects/demo/page": "not read here" };
  vm.runInContext(`st.tab = "projects"; pst.data = ${JSON.stringify(list())}; pGo("bnb/demo"); setQuery("q=menu"); renderProjects();`, ctx);
  await settle(); await settle();
  ctx.sent = [];
  vm.runInContext(`setTab("projects", "all");`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`(pst.open) + "|" + st.views.projects`, ctx), "null|");
  assert.deepEqual(ctx.sent.filter((s) => s.u.startsWith("/api/board")).map((s) => s.u), ["/api/board"]);
});

test("the Board count is written only from a current answer with a number", async () => {
  await onBoard();
  assert.equal(vm.runInContext(`pCount.all`, ctx), 3);
  vm.runInContext(`pCountSet("all", undefined); pCountSet("all", "9");`, ctx);
  assert.equal(vm.runInContext(`pCount.all`, ctx), 3, "a count that is not a number is not written");
  vm.runInContext(`pCount.all = 5; refreshBoard(); st.arg = "";`, ctx);
  await settle(); await settle();
  assert.equal(vm.runInContext(`pCount.all`, ctx), 5, "an answer for an inner tab no longer shown counts nothing");
});

// The Summary hub_core::table sends beside the Deliverables rows.
const deliv = (o = {}) => {
  const rows = [
    { project: "demo", profile: "bnb", id: "de-9", title: "Menus <fast>", system: "ui", done: 3, total: 4, percent: 75, done_says: "75% 3/4", eta: 1794537535, eta_day: "11-13", track: "behind" },
    { project: "garden", profile: "personal", id: "ga-1", title: "Water", system: "save", done: 2, total: 2, percent: 100, done_says: "100% 2/2", eta: null, eta_day: "", track: "verify" },
  ];
  return {
    rows, behind: 1, says: "Deliverables (2 open, 1 ready to verify, 0 on track, 1 behind)",
    coverage_says: "Coverage: 74 linked / 79 open rows (94%); no feature epic: home-config", legend: "percent is by size, then rows done/all",
    table: {
      q: "", state: "", sort: "", dir: "desc", total: 2, shown: 2,
      states: [{ name: "all", n: 2 }, { name: "behind", n: 1 }, { name: "on track", n: 0 }, { name: "verify", n: 1 }],
      columns: ["project", "epic", "sys", "done", "eta", "track"].map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })),
      facets: [{ key: "sys", on: [], clear: "", values: [{ value: "ui", n: 1, pct: 50, on: false, q: "sys:ui" }] }],
    },
    ...o,
  };
};
const drawDeliv = async (d) => {
  ctx.answers = { "/api/deliverables": d, "/api/projects": list() };
  vm.runInContext(`st.tab = "projects"; st.arg = "deliverables"; st.views.projects = ""; pst.open = null; dst.data = null; dst.err = null; dst.refresh();`, ctx);
  await settle(); await settle();
  return box("p-deliv").innerHTML;
};

test("Deliverables is its own inner tab's table: the head, one row per epic, then the coverage line", async () => {
  const html = await drawDeliv(deliv());
  assert.match(html, /^<div data-tbl="d"><div id="p-del-head"><h2 class="sec warn" id="sec-deliverables">Deliverables <span class="n">2<\/span><\/h2>/, "an epic behind hues the head");
  assert.match(await drawDeliv(deliv({ behind: 0 })), /<h2 class="sec" id="sec-deliverables">/, "the control: none behind, a plain head");
  assert.match(html, /id="p-del-tiles".*id="p-del-q"/s);
  assert.match(html, />BEHIND<.*>ON TRACK<.*>VERIFY</s);
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

test("a Deliverables row opens its project's Deliverables searched to its epic", async () => {
  await drawDeliv(deliv());
  ctx.answers = { "/api/projects": list(), "/api/projects/demo/page": "not read here" };
  const o = { dataset: { open: "bnb/demo", epic: "de-9", sys: "ui" } };
  const target = { id: "", dataset: {}, closest: (sel) => (sel === "[data-open]" ? o : null) };
  for (const f of box("projects").on.click) f({ type: "click", target });
  assert.equal(vm.runInContext(`pst.open + "|" + pst.inner + "|" + st.arg + "|" + st.views.projects`, ctx), "bnb/demo|deliverables|bnb/demo/deliverables|dq=de-9");
});

test("a failed Deliverables read says so and never shows an empty table", async () => {
  ctx.answers = { "/api/deliverables": "fleet-bench: not found", "/api/projects": list() };
  vm.runInContext(`st.tab = "projects"; st.arg = "deliverables"; st.views.projects = ""; pst.open = null; dst.data = null; dst.err = null; dst.refresh();`, ctx);
  await settle(); await settle();
  const html = box("p-deliv").innerHTML;
  assert.match(html, /class="card err".*fleet-bench: not found/);
  assert.doesNotMatch(html, /<table/);
});

test("a page read that gets no answer says agent-web did not answer, never a bare network error", async () => {
  ctx.answers["/api/projects/game/page?x=1"] = new TypeError("NetworkError when attempting to fetch resource.");
  await assert.rejects(vm.runInContext('api("/api/projects/game/page?x=1")', ctx),
    { message: "agent-web did not answer /api/projects/game/page (NetworkError when attempting to fetch resource.). It may be restarting: retry in a few seconds." });
  const abort = Object.assign(new Error("aborted"), { name: "AbortError" });
  ctx.answers["/api/projects/game/page?x=1"] = abort;
  await assert.rejects(vm.runInContext('api("/api/projects/game/page?x=1")', ctx), (e) => e === abort);
  delete ctx.answers["/api/projects/game/page?x=1"];
});

// Ladder: hub_core::stages' two tables (/api/stages, /api/stages/requirements), as the server sends them.
const ladTable = (cols, total, states) => ({
  q: "", state: "", sort: "", dir: "desc", total, shown: total, states,
  columns: cols.map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })), facets: [],
});
const ladder = (o = {}) => ({
  rows: [
    { name: "busy", profile: "bnb", type: "game", stage: "dev", next: "alpha", met: 3, total: 5, fail: 2, todo: 4, human: 1, filed_open: 2, filed_closed: 1, error: null, state: "failing", met_says: "3/5", filed_says: "2/1" },
    { name: "odd", profile: "personal", type: null, stage: "beta", next: "", met: 0, total: 0, fail: 0, todo: 0, human: 0, filed_open: 0, filed_closed: 0, error: "no such stage", state: "not read", met_says: "", filed_says: "" },
  ],
  says: "", gate_says: "report only until 2026-11-19 (in 6 days)", gate_level: "warn",
  filer_says: "nightly, last 04:30 today: 2 filed", filer_level: "bad", kinds_says: "on fix feat; off legal", kinds_level: "",
  failing: 2, doc: "~/.local/src/docs/stages.md", filer_href: "#schedules?q=name:=project-index",
  table: ladTable(["project", "type", "stage", "next", "met", "failing", "filed"], 2, [{ name: "all", n: 2 }, { name: "failing", n: 1 }]),
  ...o,
});
const reqs = () => ({
  rows: [{ stage: "dev", applies: ["base"], requirement: "CI runs on <every> PR", check: "`ci-green`", kind: "predicate", skills: ["fix-ci"], says: "test" },
    { stage: "prod", applies: ["game", "store"], requirement: "Store page signed off", check: "human", kind: "human", skills: [], says: "human" }],
  says: "", table: ladTable(["stage", "applies", "requirement", "check", "by"], 2, [{ name: "all", n: 2 }]),
});
const drawLadder = async (l) => {
  ctx.answers = { "/api/stages": l, "/api/stages/requirements": reqs(), "/api/projects": list() };
  vm.runInContext(`pCount.ladder = null; st.tab = "projects"; st.arg = "ladder"; st.views.projects = ""; pst.open = null; ladst.data = null; reqst.data = null; renderProjects(); pRead();`, ctx);
  await settle(); await settle();
  return { stages: box("p-lstages").innerHTML, reqs: box("p-lreqs").innerHTML };
};

test("Ladder: the gate, filer and kinds lines, projects failing in red, a check that could not run, the requirements", async () => {
  const { stages, reqs: r } = await drawLadder(ladder());
  assert.match(stages, /<h2 class="sec bad" id="sec-stages">Projects by stage <span class="n">2<\/span><\/h2>/, "a failing project reddens the head");
  assert.match(stages, /<div class="cline vital warn"><b>Gate<\/b> report only until 2026-11-19 \(in 6 days\)<\/div>/);
  assert.match(stages, /<div class="cline vital bad"><b>Filer<\/b> <a href="#schedules\?q=name:=project-index">nightly, last 04:30 today: 2 filed<\/a>/);
  assert.match(stages, /<b>Kinds<\/b> on fix feat; off legal/);
  assert.match(stages, /<code>~\/.local\/src\/docs\/stages.md<\/code>/);
  assert.match(stages, /data-open="bnb\/busy" data-inner="stage">.*<td class="n bad"[^>]*>2 <span class="muted">4 todo<\/span><\/td>/s, "failing is red, not-yet rows are a TODO");
  assert.match(stages, /<td class="n bad" title="no such stage">not read<\/td>/, "a check that could not run says so, never zero");
  assert.match(box("p-strip").innerHTML, /data-itab="ladder" class="on"[^>]*>Ladder <span class="muted">2<\/span>/);
  assert.match(r, /<h2 class="sec" id="sec-requirements">Requirements <span class="n">2<\/span><\/h2>/);
  assert.match(r, /<td title="`ci-green`">test<\/td><td>fix-ci<\/td>/);
  assert.match(r, /<td>game store<\/td>.*<td class="warn" title="human">human<\/td><td>-<\/td>/s);
  assert.match(r, /CI runs on &lt;every&gt; PR/);
  // NEGATIVE CONTROL: nothing failing, a plain head and no red cell.
  const calm = await drawLadder(ladder({ failing: 0, rows: [{ ...ladder().rows[0], fail: 0, todo: 0, state: "met" }] }));
  assert.match(calm.stages, /<h2 class="sec" id="sec-stages">/);
  assert.doesNotMatch(calm.stages, /class="n bad"/);
});

test("Ladder: a project row opens its Stage page; a new stages.json re-reads both tables only while they show", async () => {
  await drawLadder(ladder());
  ctx.sent = [];
  vm.runInContext(`TABS.projects.onEvent({ kind: "stages" });`, ctx);
  await settle(); await settle();
  assert.deepEqual(ctx.sent.map((s) => s.u).sort(), ["/api/stages", "/api/stages/requirements"]);
  ctx.answers["/api/projects/busy/page"] = "not read here";
  vm.runInContext(`pOpenAt({ dataset: { open: "bnb/busy", inner: "stage" } });`, ctx);
  assert.equal(vm.runInContext(`st.arg`, ctx), "bnb/busy/stage");
  ctx.sent = [];
  vm.runInContext(`TABS.projects.onEvent({ kind: "stages" });`, ctx);
  await settle();
  assert.ok(!ctx.sent.some((s) => s.u.startsWith("/api/stages")), "hidden, the ladder is not read");
  vm.runInContext(`pGo(null);`, ctx);
});

// hub_core::departments for one product, as /api/projects/{key}/departments sends it.
const dept = (id, title, o = {}) => ({ id, title, question: `Is ${title} in hand?`, cell: "off", due_at: null, required: false, needs: [], numbers: [], numbers_says: "no kb_project_number series for it", pipes: [], checks: [], grafana: null, outbound: [], outbound_says: "", ...o });
const depts = () => ({
  says: "",
  product: {
    profile: "bnb", name: "demo", stage: "beta", type: "game", stage_rank: 3,
    depts: [dept("analytics", "Analytics"), dept("marketing", "Marketing", {
        cell: "amber", needs: [{ level: "warn", says: "post \"devlog\" on reddit has waited 9 days on your review (ask Ab12Cd)" }],
        outbound: [{ id: "261115-aaaaaa", channel: "reddit", kind: "post", title: "devlog", state: "review", verdict: "", reviewed_by: "", url: "", created: 1794700000, sent: null, results: "" },
          { id: "261114-bbbbbb", channel: "bluesky", kind: "mockup", title: "clip", state: "sent", verdict: "hand", reviewed_by: "human", url: "https://bsky.app/x", created: 1794600000, sent: 1794650000, results: "9 wishlist adds 7d, so far to 2026-11-16" }],
      }),
      dept("legal", "Legal", {
        cell: "red", required: true, due_at: "beta",
        needs: [{ level: "bad", says: "privacy policy: no privacyUrl in game.json" }],
        checks: [{ item: "privacy policy", state: "gap", level: "bad", says: "no privacyUrl in game.json", evidence: "game.json" },
          { item: "support URL", state: "ok", level: "ok", says: "answers 200", evidence: "https://example.com/support" }],
        numbers: [{ metric: "reviews", value: 3, says: "3 store reviews" }], grafana: "https://grafana.example/d/kb-project?var-project=demo",
        pipes: [{ source: "store-reviews", kind: "runner", record: "~/.agent/state/store-reviews", shared: true, found: "missing", last: null, last_says: "never ran", verdict: "", level: "warn" }],
      }),
      dept("support", "Support"), dept("money", "Money")],
  },
  // Product::open_needs: each department's needs that are not ok.
  dept_needs: { marketing: 1, legal: 1 },
  dept_total: 2,
  // Product::need_groups over the depts above: red first.
  need_groups: [
    { kind: "dept:legal", says: "Legal: 1", items: ["privacy policy: no privacyUrl in game.json"] },
    { kind: "dept:marketing", says: "Marketing: 1", items: ["post \"devlog\" on reddit has waited 9 days on your review (ask Ab12Cd)"] },
  ],
});
const DEPT_API = "/api/projects/bnb%2Fdemo/departments";

test("a project's page has the work tabs, then one Departments tab with a chip per department its card names, their needs on Overview, and Legal says what is missing", async () => {
  // A list read an earlier test left in flight lands first, so it cannot replace this card.
  await settle(); await settle();
  ctx.answers = { "/api/projects/demo/page": { ...page, need_count: 7 }, [DEPT_API]: depts() };
  draw(list([card({ dept_tabs: ["analytics", "marketing", "legal", "support", "money"] })]), "bnb/demo");
  await settle(); await settle();
  const { head, pane } = read();
  assert.match(head, /data-ptab="overview"[^>]*>Overview <span class="pill warn">7<\/span><\/button><button[^>]*data-ptab="sprint"[^>]*>Sprint<\/button><button[^>]*data-ptab="rows"[^>]*>Rows[^<]*(<span[^>]*>[^<]*<\/span>)?<\/button><button[^>]*data-ptab="deliverables".*data-ptab="stage".*data-ptab="activity"[^>]*>Activity<\/button><button[^>]*data-ptab="knowledge"[^>]*>Knowledge<\/button><button[^>]*data-ptab="departments"[^>]*>Departments <span class="pill warn">2<\/span><\/button><\/div>$/, "Overview, the work tabs, then one Departments tab counting the departments' needs");
  assert.doesNotMatch(head, /data-ptab="(product|engineering|ops|design|analytics|marketing|legal|support|money)"|isep/, "a department is a chip, not a tab");
  const over = pinOf(pane, "overview");
  assert.match(over, /id="sec-p-needs">Needs you <span class="n">7<\/span>/, "the page's 5 needs and the departments' 2");
  assert.match(over, /<b>Legal: 1<\/b> <a href="#" data-pgo="departments\/legal">open Legal<\/a>.*<b>Marketing: 1<\/b> <a href="#" data-pgo="departments\/marketing">open Marketing<\/a>/s, "each department with needs is a fold linking to its tab, red first");
  assert.doesNotMatch(over, /departments (not read|: reading)/, "a read product leaves no note");
  const dp = pinOf(pane, "departments");
  assert.match(dp, /^<div data-pin="departments" hidden><h2 class="sec" id="sec-p-departments">Departments <span class="n">2<\/span><\/h2><div class="dchips"><div class="seg fseg istrip" role="tablist"><button role="tab" data-pdept="analytics" class="on"[^>]*>Analytics<\/button><button[^>]*data-pdept="marketing"[^>]*>Marketing <span class="pill warn">1<\/span><\/button><button[^>]*data-pdept="legal"[^>]*>Legal <span class="pill warn">1<\/span><\/button><button[^>]*data-pdept="support"[^>]*>Support<\/button><button[^>]*data-pdept="money"[^>]*>Money<\/button><\/div><\/div>/, "one chip per department the card names, the first open");
  const chip = (id) => dp.match(new RegExp(`<div data-pdp="${id}"[^>]*>.*?(?=<div data-pdp="|$)`, "s"))[0];
  const legal = chip("legal");
  assert.match(legal, /^<div data-pdp="legal" hidden><div class="muted qstats">Is Legal in hand\?<\/div>/);
  assert.match(legal, /<h2 class="sec bad" id="sec-p-legal-needs">Needs you <span class="n">1<\/span><\/h2><div class="card"><div class="bad">privacy policy: no privacyUrl in game.json<\/div>/);
  assert.match(legal, /id="sec-p-legal-checks">Checklist <span class="n">1 of 2<\/span>.*<td class="bad">gap<\/td>.*<a class="tl" href="https:\/\/example.com\/support" target="_blank"/s, "a required gap is red, a probed URL its evidence");
  assert.match(legal, /id="sec-p-legal-numbers">Numbers <span class="n">1<\/span>.*<b>reviews<\/b> 3 store reviews.*trends in Grafana/s);
  assert.match(legal, /id="sec-p-legal-pipes">Pipelines <span class="n">1<\/span>.*every product.*<td class="warn">never ran<\/td>/s, "a shared pipeline missing here is amber");
  assert.match(chip("analytics"), /^<div data-pdp="analytics"><div class="muted qstats">.*<div class="card muted">Nothing\.<\/div>.*no kb_project_number series for it.*No pipeline in departments.tsv feeds Analytics\./s, "an empty department says so, section by section");
  const mk = chip("marketing");
  assert.match(mk, /id="sec-p-marketing-needs">Needs you <span class="n">1<\/span><\/h2><div class="card"><div class="[^"]*warn[^"]*">post &quot;devlog&quot; on reddit has waited 9 days on your review/, "a stale review is an amber need");
  assert.match(mk, /id="sec-p-marketing-outbound">Outbound <span class="n">1 sent in 30d<\/span>.*<td>reddit<\/td><td>post<\/td><td class="wrap">devlog <span class="muted">261115-aaaaaa<\/span><\/td><td>-<\/td><td class="warn">review<\/td><td>-<\/td>.*<a class="tl" href="https:\/\/bsky.app\/x"[^>]*>clip<\/a>.*<td>hand by human<\/td><td class="">sent<\/td><td>9 wishlist adds 7d, so far to 2026-11-16<\/td>/s, "open items and sends, a send linked to its post and its numbers");
  assert.match(mk, /sec-p-marketing-needs.*sec-p-marketing-outbound.*sec-p-marketing-numbers/s, "Outbound sits under Needs you");
  // The retired inner id lands on Deliverables, in the URL too.
  vm.runInContext(`pInner("build")`, ctx);
  assert.equal(vm.runInContext(`pst.inner + "|" + st.arg`, ctx), "deliverables|bnb/demo/deliverables");
  assert.deepEqual(JSON.parse(vm.runInContext(`JSON.stringify(pSplit("bnb/demo/build"))`, ctx)), { key: "bnb/demo", inner: "deliverables", dept: "", sprint: "" });
  // A chip is in the URL; an old department id lands on Departments under that chip, a chip the card lacks on its first.
  vm.runInContext(`pInner("departments/legal")`, ctx);
  assert.equal(vm.runInContext(`pst.inner + "|" + pst.dept + "|" + st.arg`, ctx), "departments|legal|bnb/demo/departments/legal");
  vm.runInContext(`pInner("marketing")`, ctx);
  assert.equal(vm.runInContext(`pst.inner + "|" + pst.dept`, ctx), "departments|marketing");
  vm.runInContext(`pInner("departments/design")`, ctx);
  assert.equal(vm.runInContext(`pst.dept`, ctx), "analytics", "design is not this card's: its first chip");
  for (const [arg, want] of [["bnb/demo/departments/legal", { key: "bnb/demo", inner: "departments", dept: "legal", sprint: "" }], ["bnb/demo/legal", { key: "bnb/demo", inner: "departments", dept: "legal", sprint: "" }], ["bnb/demo/departments", { key: "bnb/demo", inner: "departments", dept: "", sprint: "" }]]) {
    assert.deepEqual(JSON.parse(vm.runInContext(`JSON.stringify(pSplit(${JSON.stringify(arg)}))`, ctx)), want, arg);
  }
  vm.runInContext(`pGo(null);`, ctx);
});

test("an infra project gets the engineering and ops chips only, and a chip it lacks lands on its first", async () => {
  await settle(); await settle();
  const infra = card({ dept_tabs: ["engineering", "ops"] });
  ctx.answers = {
    "/api/projects/demo/page": page, "/api/projects": list([infra]),
    [DEPT_API]: { says: "", product: { profile: "bnb", name: "demo", stage: "beta", type: "infra", stage_rank: 3, depts: [dept("engineering", "Engineering"), dept("ops", "Ops")] } },
  };
  ctx.sent = [];
  draw(list([infra]), "bnb/demo");
  await settle(); await settle();
  const { head, pane } = read();
  assert.match(head, /data-ptab="departments"/);
  const depts = pinOf(pane, "departments");
  assert.match(depts, /data-pdept="engineering"[^>]*>Engineering<\/button><button[^>]*data-pdept="ops"[^>]*>Ops<\/button><\/div>/);
  assert.doesNotMatch(depts, /data-pdept="(product|design|analytics|marketing|legal|support|money)"/);
  assert.match(depts, /<div data-pdp="engineering"><div class="muted qstats">Is Engineering in hand\?/);
  vm.runInContext(`pInner("legal")`, ctx);
  assert.equal(vm.runInContext(`pst.inner + "|" + pst.dept + "|" + st.arg`, ctx), "departments|engineering|bnb/demo/departments/engineering");
  vm.runInContext(`pGo(null);`, ctx);
});

test("a project with no type has no department tabs and reads no departments", async () => {
  await settle(); await settle();
  ctx.answers = { "/api/projects/demo/page": page, "/api/projects": list([card()]) };
  ctx.sent = [];
  draw(list([card()]), "bnb/demo");
  await settle();
  const { head } = read();
  assert.doesNotMatch(head, /data-ptab="(departments|product|engineering|ops|design|analytics|marketing|legal|support|money)"|isep/);
  vm.runInContext(`pInner("legal")`, ctx);
  assert.equal(vm.runInContext(`pst.inner + "|" + st.arg`, ctx), "overview|bnb/demo", "an untyped project has no Departments: Overview");
  assert.ok(!ctx.sent.some((s) => s.u.includes("/departments")), "an untyped project reads no departments");
  assert.doesNotMatch(pinOf(read().pane, "overview"), /departments/, "nor waits on them");
  vm.runInContext(`pGo(null);`, ctx);
});

test("a typed project's Overview says when its departments are not read, so a failed read is not a clean list", async () => {
  await settle(); await settle();
  const typed = card({ dept_tabs: ["legal"] });
  ctx.answers = { "/api/projects/demo/page": page, "/api/projects": list([typed]), [DEPT_API]: new TypeError("NetworkError when attempting to fetch resource.") };
  draw(list([typed]), "bnb/demo");
  await settle(); await settle();
  assert.match(pinOf(read().pane, "overview"), /<div class="muted">departments not read: agent-web did not answer \/api\/projects\/bnb%2Fdemo\/departments \(NetworkError[^<]*<\/div><\/div>/, "the note closes Needs you");
  vm.runInContext(`pGo(null);`, ctx);
});

test("the list's project names are links to their pages, and a click on one is left to the link", () => {
  const t = listTable([card()], 1, { links: [{ project: "#projects/bnb%2Fdemo" }] });
  const { cards } = draw(list([card()], { table: t }));
  assert.match(cards, /<tr class="jr" tabindex="0" data-open="bnb\/demo"><td><a class="tl" href="#projects\/bnb%2Fdemo">demo<\/a><\/td>/);
  const a = { id: "", dataset: {}, closest: (sel) => (sel === "a" ? {} : sel === "[data-open]" ? { dataset: { open: "bnb/demo" } } : null) };
  for (const f of box("projects").on.click) f({ type: "click", target: a, preventDefault() {} });
  assert.equal(vm.runInContext(`pst.open`, ctx), null, "the href navigates; the row's own open does not run too");
});

// hub_core::departments' grid, as /api/coverage sends it.
const coverage = () => ({
  rows: [
    { key: "bnb/demo", profile: "bnb", name: "demo", type: "game", stage: "beta", cells: { product: "off", engineering: "off", ops: "off", design: "off", analytics: "off", marketing: "off", legal: "red", support: "amber", money: "ok" } },
    { key: "personal/home-config", profile: "personal", name: "home-config", type: "infra", stage: "beta", cells: { engineering: "ok", ops: "amber" } },
  ],
  head: "1 red  |  2 amber  |  8 off", says: [], red: 1, amber: 2, off: 8, failing: 1,
  departments: [["product", "Product"], ["engineering", "Engineering"], ["ops", "Ops"], ["design", "Design"], ["analytics", "Analytics"], ["marketing", "Marketing"], ["legal", "Legal"], ["support", "Support"], ["money", "Money"]],
  table: { ...listTable([]), total: 2, shown: 2, legend: "red: a required department has a gap", links: [{ project: "#projects/bnb%2Fdemo", legal: "#projects/bnb%2Fdemo%2Fdepartments%2Flegal" }, { project: "#projects/personal%2Fhome-config" }],
    columns: ["project", "type", "stage", "product", "engineering", "ops", "design", "analytics", "marketing", "legal", "support", "money"].map((key) => ({ key, sort: "", next_sort: key, next_dir: "desc" })) },
});

test("Coverage is one row per typed project, a cell its department's word linked to that tab, infra with only its own cells, the head red when one is", async () => {
  ctx.answers = { "/api/coverage": coverage(), "/api/projects": list() };
  ctx.sent = [];
  vm.runInContext(`pCount.coverage = null; st.tab = "projects"; st.arg = "coverage"; st.views.projects = ""; pst.open = null; covst.data = null; renderProjects(); pRead();`, ctx);
  await settle(); await settle();
  const cov = box("p-cov").innerHTML;
  assert.ok(ctx.sent.some((s) => s.u === "/api/coverage"), "Coverage reads only while it shows");
  assert.match(cov, /<h2 class="sec bad" id="sec-coverage">Coverage <span class="n">1 red  \|  2 amber  \|  8 off<\/span><\/h2>/);
  assert.match(cov, /data-open="bnb\/demo"><td><a class="tl" href="#projects\/bnb%2Fdemo">demo<\/a><\/td><td>game<\/td><td>beta<\/td>(<td class="muted">off<\/td>){6}<td class="bad"><a class="tl" href="#projects\/bnb%2Fdemo%2Fdepartments%2Flegal">red<\/a><\/td><td class="warn">amber<\/td><td>ok<\/td><\/tr>/);
  assert.match(cov, /data-open="personal\/home-config"><td><a class="tl" href="#projects\/personal%2Fhome-config">home-config<\/a><\/td><td>infra<\/td><td>beta<\/td><td class="muted">off<\/td><td>ok<\/td><td class="warn">amber<\/td>(<td class="muted">off<\/td>){6}<\/tr>/, "infra has engineering and ops cells and the rest off");
  assert.match(cov, /red: a required department has a gap/);
  assert.match(box("p-strip").innerHTML, /data-itab="coverage" class="on"[^>]*>Coverage <span class="muted">1<\/span>/, "the strip counts products with a red cell");
  // NEGATIVE CONTROL: on another inner tab Coverage is not read.
  ctx.sent = [];
  vm.runInContext(`st.arg = ""; renderProjects(); pRead();`, ctx);
  await settle();
  assert.ok(!ctx.sent.some((s) => s.u.startsWith("/api/coverage")));
});

test("Releases lists the line's versions newest first, the apps with a line, and folds the legacy shut", async () => {
  const ver = (version, line_text, o = {}) => ({ version, status: "released", level: "ok", line_text, done: 2, total: 4, progress_text: "2 of 4 rows", cut_text: `${version}-web 11-19`, href: `#releases/versions/demo%2F${version.slice(1)}`, ...o });
  const app = (name, line) => ({ app: name, status_text: "live", level: "ok", live_text: "prod 11-19", released_text: "v0.6.0", line_text: line, href: `#releases/apps/${name}` });
  const release_tab = {
    versions: [ver("v0.6.0", "on the line"), ver("v0.5.9", "cut outside the release flow", { level: "warn", status: "unreleased" })],
    apps: [app("demo-web", "from v0.5.0")],
    legacy_versions: [ver("v0.1.0", "before the line", { level: "neutral", status: "legacy" })],
    legacy_apps: [app("demo-<old>", "no line")],
    line_text: "line from v0.5.0", legacy_says: "1 version, 1 app from before the release line",
    elsewhere: [{ text: "demo-cli releases under tools", href: "#projects/tools/releases" }], errors: ["release-state: stale"],
  };
  ctx.answers = { "/api/projects/demo/page": { ...page, release_tab }, "/api/projects": list() };
  await drawn(list(), "bnb/demo");
  vm.runInContext(`pInner("releases")`, ctx);
  assert.equal(vm.runInContext(`st.arg`, ctx), "bnb/demo/releases", "Releases has its own link");
  const rel = pinOf(read().pane, "releases");
  assert.match(rel, /id="sec-p-versions">Versions <span class="n">2<\/span><\/h2><div class="panel down"><div>release-state: stale<\/div><\/div><div class="cline muted">line from v0\.5\.0<\/div><div class="cline"><a href="#projects\/tools\/releases">demo-cli releases under tools<\/a><\/div>/);
  assert.match(rel, /<td><a href="#releases\/versions\/demo%2F0\.6\.0">v0\.6\.0<\/a><\/td><td class="">released<\/td><td class="muted">on the line<\/td>.*<td><a href="#releases\/versions\/demo%2F0\.5\.9">v0\.5\.9<\/a><\/td><td class="warn">unreleased<\/td><td class="muted">cut outside the release flow<\/td>/s, "newest first, an outside cut warned");
  assert.match(rel, /id="sec-p-apps">Apps <span class="n">1<\/span><\/h2>.*<a href="#releases\/apps\/demo-web">demo-web<\/a>.*from v0\.5\.0/s);
  assert.match(rel, /id="sec-p-legacy">Legacy <span class="n">2<\/span><\/h2><div class="card"><details class="cfold" data-k="pg:legacy"><summary><span class="muted">1 version, 1 app from before the release line<\/span><\/summary>/);
  assert.doesNotMatch(rel, /<details[^>]* open/, "the fold starts shut");
  const fold = rel.slice(rel.indexOf('data-k="pg:legacy"'));
  assert.match(fold, /v0\.1\.0.*<td class="muted">before the line<\/td>.*demo-&lt;old&gt;/s, "the legacy versions and apps sit inside the fold, escaped");
  // NEGATIVE CONTROL: a legacy version is never in the line's table.
  assert.doesNotMatch(rel.slice(0, rel.indexOf('id="sec-p-legacy"')), /v0\.1\.0/);
});
