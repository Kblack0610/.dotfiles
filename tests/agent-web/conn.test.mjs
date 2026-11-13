// The live line beside the header dot (static/app.js showConn), run from
// tests/unit/agent_web_queue.bats: the real scripts in one vm context, over a stub page and a stub
// EventSource the test opens, drops and reopens.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);
const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const cls = () => { const on = new Set(); return { on, add: (c) => on.add(c), remove: (c) => on.delete(c), toggle: (c, f) => (f ? on.add(c) : on.delete(c)) }; };
const parts = {
  conn: Object.assign(el(), { classList: cls(), title: "" }),
  "live-off": Object.assign(el(), { innerHTML: "", hidden: true, className: "", title: "", heard: {}, addEventListener(ev, f) { this.heard[ev] = f; } }),
};
const heard = {};
const doc = {
  getElementById: (id) => (parts[id] ??= el()), addEventListener(ev, f) { (heard[ev] ??= []).push(f); },
  querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), hidden: false,
};
const streams = [];
let agentsRead = null;
const ctx = vm.createContext({
  console, document: doc, window: { addEventListener() {} }, URLSearchParams, history: { replaceState() {} },
  location: { hash: "", pathname: "/", search: "" },
  // The sessions read waits until the test lets it land; every other read answers at once.
  fetch: (url) => new Promise((done) => {
    const reply = () => done({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] });
    if (url.startsWith("/api/agents")) agentsRead = reply; else reply();
  }),
  EventSource: function () { this.closed = false; this.close = () => { this.closed = true; }; streams.push(this); },
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, MutationObserver: function () { this.observe = () => {}; },
  requestAnimationFrame: (f) => f(),
  // Reads and drawing other scripts own (waiting.js, home.js, sessions.js); this test loads app.js alone.
  refreshAsks: () => Promise.resolve(), refreshHome: () => Promise.resolve(), renderBadge() {}, sst: { render() {} }, renderHome() {},
});
for (const f of ["ui.js", "app.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const settle = () => new Promise((r) => setImmediate(r));
const land = async () => { await settle(); agentsRead?.(); agentsRead = null; await settle(); await settle(); };
const pill = parts["live-off"];

test("a dropped stream says offline since when with a Retry, and a reopen catches up, then clears", async () => {
  heard.DOMContentLoaded.forEach((f) => f());
  const es = streams.at(-1);
  es.onopen();
  await land();
  assert.equal(pill.hidden, true, "live: nothing to say");
  assert.ok(parts.conn.classList.on.has("live"));
  es.onerror();
  assert.equal(pill.hidden, false);
  assert.match(pill.innerHTML, /^offline since \d\d:\d\d <button class="btn sm" id="live-retry">Retry<\/button>$/);
  assert.match(pill.className, /warn/);
  assert.ok(!parts.conn.classList.on.has("live"));
  // A second error keeps the first drop's time.
  const was = pill.innerHTML;
  es.onerror();
  assert.equal(pill.innerHTML, was);
  // Retry closes the stream and opens a new one, and says so until the new one answers.
  pill.heard.click({ target: { id: "live-retry" } });
  assert.ok(es.closed);
  assert.match(pill.innerHTML, /disabled>Retrying</);
  let again = streams.at(-1);
  assert.notEqual(again, es);
  again.onerror();
  assert.equal(pill.innerHTML, was, "a retry that failed offers Retry again, the first drop's time kept");
  pill.heard.click({ target: { id: "live-retry" } });
  again = streams.at(-1);
  again.onopen();
  await settle();
  assert.equal(pill.innerHTML, "catching up", "until the sessions read lands");
  await land();
  assert.equal(pill.hidden, true);
});

test("a hidden tab that fell behind catches up when it comes back; negative control: one that did not says nothing", async () => {
  const es = streams.at(-1);
  doc.hidden = true;
  es.onmessage({ data: JSON.stringify({ kind: "sessions" }) });
  doc.hidden = false;
  heard.visibilitychange.forEach((f) => f());
  assert.equal(pill.innerHTML, "catching up");
  await land();
  assert.equal(pill.hidden, true);
  heard.visibilitychange.forEach((f) => f());
  assert.equal(pill.hidden, true, "nothing missed, nothing said");
});

test("paths the server cannot watch still say so, below a drop", async () => {
  const es = streams.at(-1);
  es.onmessage({ data: JSON.stringify({ kind: "live", off: ["/a"] }) });
  assert.equal(pill.innerHTML, "live updates off, reload to refresh");
  assert.equal(pill.title, "/a");
  es.onerror();
  assert.match(pill.innerHTML, /^offline since/);
  es.onopen();
  await land();
  assert.equal(pill.innerHTML, "live updates off, reload to refresh");
});

test("coalesce: a call while a read runs returns that run, its trailing refetch included", async () => {
  const lands = [];
  let n = 0;
  const read = vm.runInContext("coalesce", ctx)(() => new Promise((r) => lands.push(() => { n++; r(); })));
  const first = read(), second = read(), third = read();
  assert.equal(second, first, "one run");
  assert.equal(third, first);
  let done = false;
  second.then(() => { done = true; });
  lands.shift()();
  await settle();
  assert.equal(done, false, "the trailing refetch has not landed");
  assert.equal(lands.length, 1, "three calls, two reads");
  lands.shift()();
  await settle();
  assert.equal(done, true);
  assert.equal(n, 2);
  // NEGATIVE CONTROL: a call after the run ends starts a new one.
  assert.notEqual(read(), first);
});
