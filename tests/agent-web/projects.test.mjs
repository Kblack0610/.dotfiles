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
const box = (id) => (boxes[id] ||= Object.assign(el(), { innerHTML: "", scrollTop: 0, hidden: false, textContent: "", querySelectorAll: () => [] }));
const doc = { getElementById: box, addEventListener() {}, createElement: el, body: el(), querySelector: el, querySelectorAll: () => [] };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  // A path in `answers` gets that body (a string is a 502 with it as the text); the rest get [].
  answers: {},
  fetch: async (u) => {
    const a = ctx.answers[u];
    if (typeof a === "string") return { ok: false, status: 502, statusText: "Bad Gateway", text: async () => a, headers: { get: () => "text/plain" } };
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => a ?? [] };
  },
});
for (const f of ["ui.js", "charts.js", "app.js", "board.js", "projects.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const card = (o) => ({
  profile: "bnb", name: "demo", stage: "alpha", version: "v0.1.0", goal: "ship the menu",
  progress: { open: 2, done: 1, open_weight: 3, done_weight: 1 }, percent: 25, eta_days: 4,
  requested: 1, inbox: 2, running: [], waiting: 0, queued: 0, status: "", status_date: "",
  summary: "v0.1.0 25% (1 of 4 by size), 7d 1, 28d 1, ETA 4d", in_flight: false, ...o,
});
const feed = {
  today: "2026-11-05",
  projects: [{ profile: "bnb", project: "demo", inbox: 0 }, { profile: "personal", project: "garden", inbox: 0 }],
  rows: [
    { profile: "bnb", project: "demo", lane: "agent", state: "open", priority: "high", text: "fix the menu", raw: "- [ ] fix the menu", sheet: "a.md", tags: [] },
    { profile: "personal", project: "garden", lane: "human", state: "open", priority: "low", text: "water the beds", raw: "- [ ] water the beds", sheet: "b.md", tags: [] },
  ],
  focus: [{ profile: "personal", open: 3 }, { profile: "bnb", open: 1 }],
};
function draw(data, open = null) {
  ctx.input = { data, feed, open };
  vm.runInContext(`st.tab = "projects"; pst.data = input.data; pst.err = null; bst.feed = input.feed; pst.open = null;
    if (input.open) pOpen(input.open); else renderProjects();`, ctx);
  return { cards: box("p-cards").innerHTML, head: box("p-head").innerHTML, rows: box("b-list").innerHTML };
}

test("the cards list All first, then each card with its stage, queue, bar and summary only", () => {
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", phases: { done: 1, total: 3, next: "web" } }];
  const { cards } = draw({ cards: [card({ running, queued: 2, in_flight: true, status: "landed it", status_date: "2026-11-05" }), card({ profile: "personal", name: "garden", percent: null, summary: "no version no rows" })], unlinked: ["dotfiles: tidy"], errors: [] });
  assert.match(cards, /2 projects, 1 in flight; progress is the open version's rows by size/);
  assert.match(cards, /All projects.*2 open rows.*>demo<.*>garden</s);
  assert.match(cards, /<span class="ctitle">demo<\/span><span class="cchip ">alpha<\/span><span class="cchip running">1 running<\/span><span class="cchip ">2 queued<\/span><\/div>/, "a zero count is no chip");
  assert.match(cards, /<span style="width:25\.0%[^"]*"><\/span><\/span><span class="ppct">25%<\/span><\/div><div class="psum">v0\.1\.0 25% \(1 of 4 by size\)/);
  for (const moved of ["ship the menu", "wire the bar", "landed it", "#requested"]) {
    assert.doesNotMatch(cards, new RegExp(moved), `${moved} is the opened card's`);
  }
  assert.match(cards, /Not on a card.*1 active queue items no project claims.*dotfiles: tidy/s);
});

const page = {
  project: "demo", flow_line: "ideas 3 | briefs 1 | plans 1 | epics 2 | rows 5 | landed 1 | verified 0",
  needs: ["verify: Saves (4 of 4 rows landed, no live proof)"],
  systems: [{ id: "ui", head: "ui  criteria 5 of 7", epics: [{ id: "gm-1", step: "rows", line: "Menus  [rows]  behind", behind: true }], closed: "+1 closed, 1 verified" }],
  no_epic: "(2 rows with no epic)", next_stage: "beta  4 of 12 met, 1 failing, 1 human, 6 not checkable yet",
  next_rows: [{ stage: "beta", result: "FAIL", requirement: "a soak test" }], shipped: [], errors: [],
};
const settle = () => new Promise((r) => setImmediate(r));

test("an opened card reads its page once and shows Needs you, then folds with their counts", async () => {
  ctx.answers = { "/api/projects/demo/page": page };
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", phases: { done: 1, total: 3, next: "web" } }];
  const c = card({ running, counts: "1 running, 0 waiting, 0 queued; 1 rows #requested, 2 in the inbox", status: "landed it", status_date: "2026-11-05" });
  let { head } = draw({ cards: [c], unlinked: [], errors: [] }, "bnb/demo");
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
  draw({ cards: [card({ goal: "", counts: "" })], unlinked: [], errors: [] }, "bnb/demo");
  await settle(); await settle();
  const head = box("p-head").innerHTML;
  assert.match(head, /<span class="muted">no goal set<\/span>/);
  assert.match(head, /panel down">Could not read projects \(HTTP 502\): fleet-bench epics lists no project demo/);
});

test("opening a card shows its rows under it, with Tags... among the row actions", () => {
  const { head, rows } = draw({ cards: [card()], unlinked: [], errors: [] }, "bnb/demo");
  assert.match(head, /Back to projects.*>demo<.*v0\.1\.0 25%/s);
  assert.doesNotMatch(head, /Open rows/);
  assert.match(rows, /fix the menu/);
  assert.doesNotMatch(rows, /water the beds/, "another project's row is filtered out");
  assert.match(rows, /data-tag="0">Tags\.\.\./);
  assert.doesNotMatch(rows, /href="#daily"/, "one project's rows have no Daily count");
});

test("All opens every project's rows, and a stats error is shown, not hidden", () => {
  assert.match(draw({ cards: [card()], unlinked: [], errors: [] }, "all").rows, /fix the menu.*water the beds/s);
  assert.match(draw({ cards: [card()], unlinked: [], errors: [] }, "all").rows, /<a class="btn sm" href="#daily">Daily: personal 3, bnb 1 open<\/a>/, "the daily notes' Focus is a count linking to Daily");
  assert.match(draw({ cards: [], unlinked: [], errors: ["notes projects failed"] }).cards, /panel down">notes projects failed/);
});
