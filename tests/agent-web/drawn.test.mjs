// The drawn mark agent-web-shot waits on (static/ui.js api and drawnCheck), run from
// tests/unit/agent_web_queue.bats: ui.js in a vm context over a stub #main, a fetch whose reads
// answer when the test says, and a frame the test runs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

function page() {
  const main = { dataset: {} }, out = new Map(), frames = [];
  const ctx = vm.createContext({
    console,
    document: { getElementById: (id) => (id === "main" ? main : null) },
    st: { tab: "home" },
    // Each read waits for answer(path); status 500 is a failed read.
    fetch: (path) => new Promise((done) => out.set(path, (status = 200) =>
      done({ ok: status < 400, status, statusText: "", headers: { get: () => "application/json" }, json: async () => ({ path }), text: async () => "boom" }))),
    requestAnimationFrame: (f) => frames.push(f),
  });
  vm.runInContext(readFileSync(new URL("ui.js", dir), "utf8"), ctx, { filename: "ui.js" });
  const settle = () => new Promise((r) => setImmediate(r));
  return {
    ctx, main,
    api: (path) => vm.runInContext(`api(${JSON.stringify(path)})`, ctx).catch((e) => e),
    async answer(path, status) { out.get(path)(status); out.delete(path); await settle(); },
    frame() { for (const f of frames.splice(0)) f(); },
  };
}

test("the mark waits for every read out, and names the shown tab", async () => {
  const p = page();
  p.api("/api/home"); p.api("/api/home/cards");
  await p.answer("/api/home");
  p.frame();
  assert.equal(p.main.dataset.drawn, undefined, "one read is still out");
  await p.answer("/api/home/cards");
  p.frame();
  assert.equal(p.main.dataset.drawn, "home");
});

test("a read chained on the last one's answer holds the mark off", async () => {
  const p = page();
  vm.runInContext(`globalThis.chain = (async () => { await api("/api/queue"); await api("/api/queue/candidates"); })()`, p.ctx);
  await p.answer("/api/queue");
  p.frame();
  assert.equal(p.main.dataset.drawn, undefined, "the chained read started before the frame");
  await p.answer("/api/queue/candidates");
  p.frame();
  assert.equal(p.main.dataset.drawn, "home");
});

test("a new read takes the mark off until it answers; a failed read still counts as answered", async () => {
  const p = page();
  p.api("/api/home");
  await p.answer("/api/home");
  p.frame();
  assert.equal(p.main.dataset.drawn, "home");
  p.api("/api/alerts");
  assert.equal(p.main.dataset.drawn, undefined);
  await p.answer("/api/alerts", 500);
  p.frame();
  assert.equal(p.main.dataset.drawn, "home");
});

test("a tab shown from what it already read is marked by setTab's check", () => {
  const p = page();
  p.ctx.st.tab = "costs";
  vm.runInContext("drawnCheck()", p.ctx);
  p.frame();
  assert.equal(p.main.dataset.drawn, "costs");
});
