// Unit tests for the Queue tab's waiting card (.local/src/agent-web/static/queue.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context, as the browser loads them into one global scope; only the DOM is a stub.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

function page() {
  const el = () => new Proxy({}, {
    get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : () => el()),
    set: (t, k, v) => { t[k] = v; return true; },
  });
  const ctx = vm.createContext({
    console, setTimeout, clearTimeout, setInterval, clearInterval,
    document: { getElementById: el, addEventListener() {}, querySelector: el, querySelectorAll: () => [] },
    window: { addEventListener() {} }, location: { hash: "", reload() {} }, localStorage: { getItem() {}, setItem() {} },
    fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
  });
  for (const f of ["ui.js", "md.js", "app.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
  return (agents, asks, item) => {
    ctx.input = { agents, asks, item };
    return vm.runInContext("st.agents = input.agents; st.asks = input.asks; qItem(input.item)", ctx);
  };
}

const card = page();
const item = (session, state = "waiting") => ({ slug: "s", state, priority: "high", project: "p", mode: "oneshot", task: "t", session });
const pane = (target, session = "c1") => ({ target, session, project: "p", actions: [] });
const ask = (o) => ({ id: "a1", project: "p", kind: "question", question: "Ship it?", options: ["yes", "no"], recommend: "no", session: "c1", tmux: "game-agent-2", judge: "", ...o });

test("an item's <server>:<session> finds its pane, so the card can open it", () => {
  assert.match(card([pane("lab/game-agent-2:1")], [], item("lab:game-agent-2")), /data-open="s"/);
});

test("the same session name on another server is not the item's pane", () => {
  const html = card([pane("hub/game-agent-2:1")], [], item("lab:game-agent-2"));
  assert.doesNotMatch(html, /data-open/);
  assert.match(html, /No live window: tmux session lab:game-agent-2/);
});

test("a bare session still finds its pane", () => {
  assert.match(card([pane("lab/game-agent-2:1")], [], item("game-agent-2")), /data-open="s"/);
});

test("a session name is not matched by its prefix", () => {
  assert.doesNotMatch(card([pane("lab/game-agent-22:1")], [], item("lab:game-agent-2")), /data-open/);
});

test("a waiting card shows the open ask, its options and the recommended one", () => {
  const html = card([pane("lab/game-agent-2:1")], [ask()], item("lab:game-agent-2"));
  assert.match(html, /class="qneed"/);
  assert.match(html, /Ship it\?/);
  assert.match(html, /data-a="yes"/);
  assert.match(html, /class="btn rec" data-a="no">no \(rec\)/);
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("an ask from a session in another item's pane stays off this card", () => {
  const panes = [pane("lab/game-agent-2:1", "c1"), pane("lab/game-agent-3:1", "c2")];
  assert.doesNotMatch(card(panes, [ask({ session: "c2", tmux: "game-agent-3" })], item("lab:game-agent-2")), /Ship it/);
});

test("an ask whose pane is gone still reaches the card by its tmux session", () => {
  const html = card([], [ask({ session: "" })], item("lab:game-agent-2"));
  assert.match(html, /Ship it\?/);
  assert.doesNotMatch(html, /No live window/);
});

test("with no ask and no dialog, the card names the prompt and the tmux session", () => {
  assert.match(card([pane("lab/game-agent-2:1")], [], item("lab:game-agent-2")), /Waiting on a prompt in its window: tmux session lab:game-agent-2/);
});

test("a dialog open in the pane is the answer, not the prompt line", () => {
  const p = { ...pane("lab/game-agent-2:1"), question: { kind: "choice", text: "Pick", options: ["a"] } };
  const html = card([p], [], item("lab:game-agent-2"));
  assert.match(html, /data-t="lab\/game-agent-2:1"/);
  assert.doesNotMatch(html, /Waiting on a prompt/);
});

test("a session shared by several windows offers no single pane, but shows each ask from it", () => {
  const panes = [pane("hub/dotfiles:1", "c1"), pane("hub/dotfiles:2", "c2")];
  const html = card(panes, [ask({ session: "c2", tmux: "dotfiles" })], item("hub:dotfiles"));
  assert.doesNotMatch(html, /data-open="s"/);
  assert.match(html, /Ship it\?/);
  assert.match(card(panes, [], item("hub:dotfiles")), /Waiting on a prompt in its window: tmux session hub:dotfiles/);
});

test("the prompt line is for waiting items only", () => {
  assert.doesNotMatch(card([pane("lab/game-agent-2:1")], [], item("lab:game-agent-2", "running")), /Waiting on a prompt/);
});

test("Stop and cancel stays, as the quiet button", () => {
  assert.match(card([], [], item("lab:game-agent-2")), /class="btn sm quiet" data-cancel="s">Stop and cancel/);
});
