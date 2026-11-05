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
for (const f of ["ui.js", "md.js", "app.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

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

test("a waiting card shows the open ask, its options and the recommended one", () => {
  const html = card([pane()], [ask()], item());
  assert.match(html, /class="qneed"/);
  assert.match(html, /Ship it\?/);
  assert.match(html, /data-a="yes"/);
  assert.match(html, /class="btn rec" data-a="no">no \(rec\)/);
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("an ask from another item's pane stays off this card", () => {
  assert.doesNotMatch(card([pane("c1"), pane("c2", ["other"])], [ask({ session: "c2" })], item()), /Ship it/);
});

test("an ask no Claude session owns is on no card, whatever its tmux name", () => {
  assert.doesNotMatch(card([pane()], [ask({ session: "" })], item()), /Ship it/);
});

test("with no ask and no dialog, the card names the prompt and the tmux session", () => {
  assert.match(card([pane()], [], item()), /Waiting on a prompt in its window: tmux session lab:game-agent-2/);
});

test("with no pane left, the card does not claim one", () => {
  const html = card([], [], item());
  assert.match(html, /No live window: tmux session lab:game-agent-2/);
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("a dialog open in the pane is the answer, not the prompt line", () => {
  const html = card([{ ...pane(), question: { kind: "choice", text: "Pick", options: ["a"] } }], [], item());
  assert.match(html, /data-t="lab\/game-agent-2:c1"/);
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("a session shared by several windows offers no single pane, but shows each ask from it", () => {
  const panes = [pane("c1"), pane("c2")];
  const html = card(panes, [ask({ session: "c2" })], item());
  assert.doesNotMatch(html, /data-open="s"/);
  assert.match(html, /Ship it\?/);
  assert.match(card(panes, [], item()), /Waiting on a prompt in its window/);
});

test("the prompt line is for waiting items only", () => {
  assert.doesNotMatch(card([pane()], [], item("running")), /Waiting on a prompt/);
});

test("Stop and cancel stays, as the quiet button", () => {
  assert.match(card([], [], item()), /class="btn sm quiet" data-cancel="s">Stop and cancel/);
});
