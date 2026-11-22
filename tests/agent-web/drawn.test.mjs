// The drawn mark agent-web-shot waits on (static/ui.js api and drawnCheck), run from
// tests/unit/agent_web_queue.bats: ui.js in a vm context over a stub #main, a fetch whose reads
// answer when the test says, and a frame the test runs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

function page() {
  const main = { dataset: {} }, out = new Map(), frames = [], clock = { now: 0 };
  const ctx = vm.createContext({
    console, clock,
    performance: { now: () => clock.now },
    document: { getElementById: (id) => (id === "main" ? main : null) },
    st: { tab: "home" }, conn: { open: true }, location: { reload() {} },
    // Each read waits for answer(path); status 500 is a failed read.
    fetch: (path) => new Promise((done) => out.set(path, (status = 200) =>
      done({ ok: status < 400, status, statusText: "", headers: { get: () => "application/json" }, json: async () => ({ path }), text: async () => "boom" }))),
    requestAnimationFrame: (f) => frames.push(f),
  });
  for (const f of ["../../web-kit/kb-ui.js", "ui.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
  const settle = () => new Promise((r) => setImmediate(r));
  return {
    ctx, main, clock,
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
  p.clock.now = 1234.6;
  p.frame();
  assert.equal(p.main.dataset.drawn, "home");
  assert.equal(p.main.dataset.drawnAt, 1235, "stamped with the frame it drew in");
  p.clock.now = 9000;
  p.api("/api/home");
  await p.answer("/api/home");
  p.frame();
  assert.equal(p.main.dataset.drawnAt, 1235, "a refetch of a drawn tab keeps its first stamp");
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

test("a read of a new path takes the mark off until it answers; a failed read still counts as answered", async () => {
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

test("a refetch of an answered path (a poll, a pushed event) never holds the mark off", async () => {
  const p = page();
  p.api("/api/home/cards"); p.api("/api/home");
  await p.answer("/api/home/cards");
  p.api("/api/home/cards"); // an event re-reads the cards while Home's first read is still out
  await p.answer("/api/home");
  p.frame();
  assert.equal(p.main.dataset.drawn, "home", "the cards' refetch is still out, and does not count");
});

test("a tab shown from what it already read is marked by setTab's check", () => {
  const p = page();
  p.ctx.st.tab = "costs";
  vm.runInContext("drawnCheck()", p.ctx);
  p.frame();
  assert.equal(p.main.dataset.drawn, "costs");
});

test("no mark before the stream opens, since its reads (sessions, asks) have not started", async () => {
  const p = page();
  p.ctx.conn.open = false;
  p.api("/api/home");
  await p.answer("/api/home");
  p.frame();
  assert.equal(p.main.dataset.drawn, undefined);
  p.ctx.conn.open = true;
  vm.runInContext("drawnCheck()", p.ctx); // the stream's open
  p.frame();
  assert.equal(p.main.dataset.drawn, "home");
});

test("a signed-out read (401) reloads the page and never marks it", async () => {
  const p = page();
  p.api("/api/home");
  await p.answer("/api/home", 401);
  p.frame();
  assert.equal(p.main.dataset.drawn, undefined);
});

test("drawnReset forgets what was heard: a tab shown again waits for its refetch", async () => {
  const p = page();
  p.api("/api/home");
  await p.answer("/api/home");
  p.clock.now = 100;
  p.frame();
  assert.equal(p.main.dataset.drawnAt, 100);
  vm.runInContext("drawnReset()", p.ctx);
  assert.equal(p.main.dataset.drawnAt, undefined, "the reset drops the stamp with the mark");
  p.api("/api/home");
  p.frame();
  assert.equal(p.main.dataset.drawn, undefined, "the refetch after the reset is a first read");
  await p.answer("/api/home");
  p.clock.now = 250;
  p.frame();
  assert.equal(p.main.dataset.drawn, "home");
  assert.equal(p.main.dataset.drawnAt, 250, "the tab shown again is stamped when it draws again");
});
