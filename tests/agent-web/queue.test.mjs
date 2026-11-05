// Unit tests for the Queue tab's waiting card (.local/src/agent-web/static/queue.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context, as the browser loads them into one global scope; only the DOM is a stub.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const ctx = vm.createContext({
  console,
  document: { getElementById: el, addEventListener() {}, querySelector: el, querySelectorAll: () => [] },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
for (const f of ["ui.js", "md.js", "app.js", "waiting.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

function card(agents, asks, item) {
  ctx.input = { agents, asks, item };
  return vm.runInContext("st.agents = input.agents; st.asks = input.asks; qItem(input.item)", ctx);
}

const item = (state = "waiting") => ({ slug: "s", state, priority: "high", project: "p", mode: "oneshot", task: "t", session: "lab:game-agent-2" });
const pane = (session = "c1", items = ["s"]) => ({ target: `lab/game-agent-2:${session}`, session, items, project: "p", actions: [] });
const ask = (o) => ({ id: "a1", project: "p", kind: "question", question: "Ship it?", options: ["yes", "no"], recommend: "no", session: "c1", judge: "", ...o });

test("the pane hub-core joined to the item is the one the card can open", () => {
  assert.match(card([pane()], [], item()), /data-open="s"/);
  assert.doesNotMatch(card([pane("c1", ["other"])], [], item()), /data-open/);
});

test("a waiting card counts its open ask and links to Home, which answers it", () => {
  const html = card([pane()], [ask()], item());
  assert.match(html, /<a href="#" data-home><span class="chip sm"[^>]*>1 waiting on you<\/span> answer on Home<\/a>/);
  assert.doesNotMatch(html, /Ship it|data-a=/, "the answer card is Home's");
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("an ask from another item's pane stays off this card", () => {
  assert.doesNotMatch(card([pane("c1"), pane("c2", ["other"])], [ask({ session: "c2" })], item()), /waiting on you/);
});

test("an ask no Claude session owns is on no card, whatever its tmux name", () => {
  assert.doesNotMatch(card([pane()], [ask({ session: "" })], item()), /waiting on you/);
});

test("with no ask and no dialog, the card names the prompt and the tmux session", () => {
  assert.match(card([pane()], [], item()), /title="tmux session lab:game-agent-2">Waiting on a prompt in its window/);
});

test("with no pane left, the card does not claim one", () => {
  const html = card([], [], item());
  assert.match(html, /title="tmux session lab:game-agent-2">Its session window is closed/);
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("a dialog open in the pane is the answer, not the prompt line", () => {
  const html = card([{ ...pane(), question: { kind: "choice", text: "Pick", options: ["a"] } }], [], item());
  assert.match(html, />1 waiting on you</);
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("a session shared by several windows offers no single pane, but shows each ask from it", () => {
  const panes = [pane("c1"), pane("c2")];
  const html = card(panes, [ask({ session: "c2" })], item());
  assert.doesNotMatch(html, /data-open="s"/);
  assert.match(html, />1 waiting on you</);
  assert.match(card(panes, [], item()), /Waiting on a prompt in its window/);
});

test("the prompt line is for waiting items only", () => {
  assert.doesNotMatch(card([pane()], [], item("running")), /Waiting on a prompt/);
});

test("Stop and cancel stays, as the quiet button", () => {
  assert.match(card([], [], item()), /class="btn sm quiet" data-cancel="s">Stop and cancel/);
});

test("the card leads with the title, not the slug, and folds the task and its bookkeeping away", () => {
  const html = card([], [], { ...item("running"), title: "Fix the join", task: "The long prompt", mode: "oneshot" });
  assert.match(html, /<span class="ctitle">Fix the join<\/span>/);
  assert.match(html, /<details class="cfold" data-k="task:s"><summary>Full task and details<\/summary><dl>.*<dt>slug<\/dt><dd>s<\/dd>.*<div class="q">The long prompt<\/div><\/details>/s);
  assert.match(html, /<span class="cchip running">Running/);
  // An item from a store older than titles still has a heading.
  assert.match(card([], [], item("queued")), /<span class="ctitle">s<\/span>/);
});

test("a running item shows its estimate, and a past one as overdue", () => {
  const soon = Math.floor(Date.now() / 1000) + 3600, past = Math.floor(Date.now() / 1000) - 7200;
  const withEta = (e) => [{ ...pane(), phases: { done: 1, total: 3, next: "2: wire it", eta: "x p9", eta_epoch: e } }];
  const html = card(withEta(soon), [], item("running"));
  assert.match(html, /phase 1\/3/);
  assert.match(html, /<span title="estimate x p9">ETA /);
  assert.match(html, /<div class="qnext">Next: 2: wire it<\/div>/);
  assert.match(card(withEta(past), [], item("running")), /<span class="qlate"[^>]*>overdue 2h \(ETA was /);
});

test("a done card shows how it ended and how long it took, with no buttons", () => {
  const d = { ...item("done"), status: "failed", started: "2026-11-05T08:00:00Z", finished: "2026-11-05T10:30:00Z", pr: "https://x/pr/1" };
  const html = card([], [], d);
  assert.match(html, /<span class="cchip bad">Failed<\/span>/);
  assert.match(html, /took 2h 30m/);
  assert.match(html, /<a href="https:\/\/x\/pr\/1"/);
  assert.doesNotMatch(html, /data-cancel|data-bump/);
});

test("sections fold: Done starts shut and groups by day, the rest start open", () => {
  ctx.input = [
    { ...item("waiting"), slug: "w" },
    { ...item("done"), slug: "d1", status: "ok", finished: new Date().toISOString() },
  ];
  const html = vm.runInContext(`st.agents = []; st.asks = []; qst.items = input; qst.stats = { week: "since x", wait_minutes_median: 60 };
    const box = {}; drawQueueList(box); box.innerHTML`, ctx);
  assert.match(html, /<details class="csec" data-k="sec:waiting" open>/);
  assert.match(html, /<details class="csec" data-k="sec:running" open>/);
  assert.match(html, /<details class="csec" data-k="sec:done"><summary><h2 class="sec">Done, last 7 days <span class="muted">1<\/span>/);
  assert.match(html, /<h3 class="qday">Today<\/h3>/);
  assert.match(html, /<span class="tl">NEEDS YOU<\/span><span class="tv">1<\/span>/);
  assert.match(html, /<summary>Stats detail<\/summary><div class="muted">since x<\/div>/);
});
