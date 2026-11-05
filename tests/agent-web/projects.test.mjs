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
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
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
};
function draw(data, open = null) {
  ctx.input = { data, feed, open };
  vm.runInContext(`st.tab = "projects"; pst.data = input.data; pst.err = null; bst.feed = input.feed; pst.open = null;
    if (input.open) pOpen(input.open); else renderProjects();`, ctx);
  return { cards: box("p-cards").innerHTML, head: box("p-head").innerHTML, rows: box("b-list").innerHTML };
}

test("the cards list All first, then each card with its bar, summary, goal and counts", () => {
  const running = [{ slug: "s1", title: "wire the bar", project: "demo", phases: { done: 1, total: 3, next: "web" } }];
  const { cards } = draw({ cards: [card({ running, in_flight: true }), card({ profile: "personal", name: "garden", percent: null, summary: "no version no rows" })], unlinked: ["dotfiles: tidy"], errors: [] });
  assert.match(cards, /2 projects, 1 in flight; progress is the open version's rows by size/);
  assert.match(cards, /ALL PROJECTS.*2 open rows.*DEMO.*GARDEN/s);
  assert.match(cards, /<span style="width:25\.0%[^"]*"><\/span><\/span><span>v0\.1\.0 25% \(1 of 4 by size\)/);
  assert.match(cards, /goal<\/span><span>ship the menu/);
  assert.match(cards, /running<\/span><span>wire the bar \(phase 2 of 3: web\)/);
  assert.match(cards, /1 running, 0 waiting, 0 queued; 1 rows #requested, 2 in the inbox/);
  assert.match(cards, /Not on a card.*1 active queue items no project claims.*dotfiles: tidy/s);
});

test("opening a card shows its rows under it, with Tags... among the row actions", () => {
  const { head, rows } = draw({ cards: [card()], unlinked: [], errors: [] }, "bnb/demo");
  assert.match(head, /&larr; Projects.*DEMO.*v0\.1\.0 25%/s);
  assert.doesNotMatch(head, /Open rows/);
  assert.match(rows, /fix the menu/);
  assert.doesNotMatch(rows, /water the beds/, "another project's row is filtered out");
  assert.match(rows, /data-tag="0">Tags\.\.\./);
});

test("All opens every project's rows, and a stats error is shown, not hidden", () => {
  assert.match(draw({ cards: [card()], unlinked: [], errors: [] }, "all").rows, /fix the menu.*water the beds/s);
  assert.match(draw({ cards: [], unlinked: [], errors: ["notes projects failed"] }).cards, /panel down">notes projects failed/);
});
