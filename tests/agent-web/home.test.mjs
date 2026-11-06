// Unit tests for the Home tab (.local/src/agent-web/static/home.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them into one global scope; only the DOM is a stub. The join itself is
// hub_core::home, tested in Rust; this checks how its answer is drawn.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const box = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
// The pieces a repaint replaces while a control has focus, and what the page listens for.
const parts = {};
const on = {};
box.addEventListener = (t, f) => { (on[t] ??= []).push(f); };
const doc = { getElementById: (id) => (id === "home" ? box : (parts[id] ??= el())), addEventListener() {}, querySelector: el, querySelectorAll: () => [] };
const reads = [];
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  history: { replaceState() {} },
  location: { hash: "", pathname: "/", search: "" },
  fetch: async (path) => { reads.push(path); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => (path.startsWith("/api/home") ? home() : []) }; },
});
for (const f of ["ui.js", "md.js", "app.js", "waiting.js", "home.js", "table.js", "actions.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const now = () => Math.floor(Date.now() / 1000);
function draw(home, agents = [], asks = [], opened = []) {
  ctx.input = { home, agents, asks, opened };
  return vm.runInContext(`st.agents = input.agents; st.asks = input.asks; hst.data = input.home; hst.err = null; hst.open = new Set(input.opened); hst.all = false; drawHome(); $("home").innerHTML`, ctx);
}
const COLS = ["rank", "kind", "project", "waited", "holds", "what"];
const table = (needs, o) => ({ q: "", state: "", sort: "", dir: "desc", total: needs.length, shown: needs.length,
  states: [{ name: "all", n: needs.length }], columns: COLS.map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })), facets: [], ...o });
// Rows as the server ranks them.
const ranked = (needs) => needs.map((n, i) => ({ rank: i + 1, ...n }));
const home = (o = {}) => {
  const needs = ranked(o.needs || []);
  return { running: [], numbers: [], health: [], errors: [], shown: 8, ...o, needs, table: table(needs, o.table) };
};
const live = (target, kind) => ({ target, short: target, session: target, project: "p", summary: target, items: [], actions: [], question: { kind, text: "Run it?" } });
const shipIt = { id: "a1", project: "p", kind: "question", question: "Ship it?", title: "Ship it?", body: "", options: ["yes", "no"], recommend: "yes", session: "", agent: "x", judge: "", created: now() - 120 };

test("Needs you is the shared table: the columns, the server's chips, the rank as the order", () => {
  const html = draw(home({
    needs: [
      { kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1", since: now() - 3900, score: { holds: "session, 2 phases" } },
      { kind: "nightly", need: "red", project: "", text: "PlayMode.Lobby red", id: "unity-core" },
    ],
    table: { shown: 2, total: 2, states: [{ name: "all", n: 2 }, { name: "Question", n: 1 }, { name: "Failing", n: 1 }] },
  }));
  assert.match(html, /<h2 class="sec">Needs you <span class="muted">2<\/span><\/h2>/);
  assert.match(html, /id="home-q" data-tsearch placeholder="search, or kind:ask project:dotfiles -kind:red"/);
  assert.match(html, /data-ts="Question">Question <span class="n">1<\/span>/);
  assert.match(html, /<th class="n"><button class="thsort" data-tsort="rank"[^>]*>rank v<\/button><\/th>/);
  assert.match(html, /data-tsort="waited"[^>]*>waited<\/button>/);
  const row = /<tr class="jr" data-need="ask:a1"><td class="n">1<\/td><td>Question<\/td><td>p<\/td><td class="n" title="(\d{4}-\d\d-\d\dT[^"]+Z)">1h 5m<\/td><td class="wrap muted">session, 2 phases<\/td><td class="wrap">Ship it\?<\/td><\/tr>/.exec(html);
  assert.ok(row, html);
  assert.ok(Math.abs(Date.parse(row[1]) / 1000 - (now() - 3900)) < 5, "the hover is the exact time");
  assert.match(html, /data-need="nightly:unity-core"><td class="n">2<\/td><td>Failing<\/td><td>-<\/td><td class="n">-<\/td><td class="wrap muted">-<\/td>/, "an empty cell says so");
  assert.doesNotMatch(html, /class="card need/, "a card is only an opened row");
  assert.doesNotMatch(html, /ntally|nchip/);
});

test("a sort asked for marks its own header and takes the mark off the rank", () => {
  const cols = COLS.map((key) => ({ key, sort: key === "waited" ? "asc" : null, next_sort: key, next_dir: "desc" }));
  const html = draw(home({ needs: [{ kind: "ask", need: "ask", project: "p", text: "x", id: "a1" }], table: { sort: "waited", dir: "asc", columns: cols } }));
  assert.match(html, /<th class="n" aria-sort="ascending">.*waited \^<\/button>/);
  assert.match(html, />rank<\/button>/);
});

test("the view keeps the count of the whole list, and no match is not an all-clear", () => {
  const html = draw({ ...home(), table: table([], { q: "kind:ask", total: 5, shown: 0 }) });
  assert.match(html, /<h2 class="sec">Needs you <span class="muted">0 of 5<\/span><\/h2>/);
  assert.match(html, /No needs match\./);
  assert.doesNotMatch(html, /Nothing waits on you/);
  assert.match(html, /id="home-q"[^>]*value="kind:ask"/, "the box stays, so the view can be changed back");
  const none = draw(home());
  assert.match(none, /Nothing waits on you\./);
  assert.doesNotMatch(none, /id="home-q"/, "an empty list has nothing to search");
});

test("an opened ask or dialog is its answer card under its row; an opened red nightly is a plain card", () => {
  const needs = [
    { kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1", since: now() - 120 },
    { kind: "session", need: "perm", project: "p", text: "Wire the join", id: "lab/w:1", target: "lab/w:1", since: now() - 300 },
    { kind: "nightly", need: "red", project: "unity-core", text: "PlayMode.Lobby red", id: "unity-core" },
  ];
  const html = draw(home({ needs }), [live("lab/w:1", "tool")], [shipIt], ["ask:a1", "session:lab/w:1", "nightly:unity-core"]);
  assert.match(html, /<tr class="jr sel" data-need="ask:a1">.*<\/tr><tr class="wdet"><td colspan="6"><div class="card need k-ask" data-id="a1">.*data-a="yes"/s);
  assert.match(html, /data-need="session:lab\/w:1">.*<tr class="wdet">.*need k-perm" data-t="lab\/w:1".*data-k="1"/s, html);
  assert.match(html, /need k-red.*<span class="nkind">Failing<\/span><span>unity-core<\/span><span>nightly failed<\/span><\/div><div class="ntitle">PlayMode\.Lobby red/s, "the id that only repeats the project is not shown twice");
  const shut = draw(home({ needs }), [live("lab/w:1", "tool")], [shipIt]);
  assert.doesNotMatch(shut, /wdet/);
});

test("a dialog's kind is the row's, as the server read it, and not worked out here", () => {
  const needs = [{ kind: "session", need: "plan", project: "p", text: "s1", id: "s1", target: "s1" }];
  const html = draw(home({ needs }), [live("s1", "tool")], [], ["session:s1"]);
  assert.match(html, /need k-plan.*<span class="nkind">Plan to approve<\/span>/s);
});

test("the opened record says what the row holds and how long it waited, exactly", () => {
  const score = (holds) => ({ human: true, holds, value: 1 });
  const needs = [
    { kind: "queue", need: "blocked", project: "p", text: "blocked one", id: "q1", score: score("2 queued") },
    { kind: "sheet", need: "todo", project: "p", text: "sheet row", id: "t1", score: { human: true, holds: "", priority: "high", value: 1 } },
    { kind: "stopped", need: "stopped", project: "", text: "Dispatch stopped 13h: no account has room.", id: "stopped:fleet-dispatch", since: now() - 13 * 3600 - 300 },
  ];
  const html = draw(home({ needs }), [], [], needs.map((n) => `${n.kind}:${n.id}`));
  assert.match(html, /<span class="nkind">Blocked<\/span>.*<span>holds 2 queued<\/span>/s);
  assert.match(html, /<td class="wrap muted">#high<\/td>/);
  assert.match(html, /<span class="nkind">To do<\/span>.*<span>#high<\/span>/s);
  assert.match(html, /need k-stopped.*<span class="nkind">Stopped<\/span><span>dispatch<\/span><span>13h 5m<\/span><\/div><div class="ntitle">Dispatch stopped 13h/s, html);
  assert.doesNotMatch(html, /stopped:fleet-dispatch<\/span>/);
});

test("a need whose session is gone has no Open button; a waiting queue item opens the queue", () => {
  const needs = [
    { kind: "session", need: "turn", project: "p", text: "Stalled", id: "lab/x:1", target: "lab/x:1" },
    { kind: "queue", need: "blocked", project: "p", text: "Review the PR", id: "fix-it" },
  ];
  const html = draw(home({ needs }), [], [], ["session:lab/x:1", "queue:fix-it"]);
  assert.doesNotMatch(html, /data-open/);
  assert.match(html, /need k-turn.*need k-blocked.*<span class="nkind">Blocked<\/span>.*data-tab="queue">Open the queue/s);
});

// What the page does with an event on its board.
const fire = (type, target) => { for (const f of on[type]) f({ type, target }); };
const stub = (closest, dataset = {}) => ({ dataset, closest: (sel) => closest(sel) ?? null });

test("a click on a row opens its record and a second click shuts it", () => {
  const needs = [{ kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1" }];
  draw(home({ needs }), [], [shipIt]);
  const row = stub((sel) => (sel.startsWith("tr.jr") ? { dataset: { need: "ask:a1" } } : null));
  fire("click", row);
  assert.match(box.innerHTML, /<tr class="wdet">.*data-id="a1"/s);
  fire("click", row);
  assert.doesNotMatch(box.innerHTML, /wdet/);
});

test("a chip, a header and the search box ask the server, and the view goes in the URL", async () => {
  vm.runInContext(`st.tab = "home"; st.views.home = ""`, ctx);
  draw(home());
  const search = { dataset: { tsearch: "" }, value: "kind:ask" };
  fire("input", search);
  const chip = stub((sel) => (sel === "[data-ts]" ? { dataset: { ts: "Question" } } : null));
  fire("click", chip);
  await new Promise(setImmediate);
  assert.equal(vm.runInContext("st.views.home", ctx), "q=kind%3Aask&s=Question");
  assert.ok(reads.includes("/api/home?q=kind%3Aask"), reads.join(" "));
  assert.ok(reads.at(-1).startsWith("/api/home?q=kind%3Aask&s=Question"), reads.join(" "));
  vm.runInContext(`st.tab = "sessions"; st.views.home = ""`, ctx);
});

test("a refresh repaints around the search box in use and leaves it alone", () => {
  const needs = [{ kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1" }];
  const first = draw(home({ needs }));
  doc.activeElement = { id: "home-q", dataset: {}, closest: (sel) => (sel === "#home" ? box : null), matches: () => false };
  const again = draw(home({ needs: [...needs, { kind: "ask", need: "ask", project: "p", text: "Second", id: "a2" }] }));
  doc.activeElement = undefined;
  assert.equal(again, first, "the board with the box in it is not repainted");
  assert.match(parts["home-nbody"].innerHTML, /Second/);
  assert.match(parts["home-nhead"].innerHTML, /Needs you/);
  assert.equal(typeof parts["home-chips"].innerHTML, "string");
});

test("a reply being typed in an open card survives a refresh", () => {
  const needs = [{ kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1" }];
  draw(home({ needs }), [], [shipIt], ["ask:a1"]);
  const fresh = { value: "", focus() { this.focused = true; } };
  const card = { dataset: { id: "a1" }, querySelector: () => fresh };
  doc.activeElement = { value: "half a repl", closest: (sel) => (sel === "#home .card" ? card : null), matches: (sel) => sel === "[data-free]" };
  doc.querySelectorAll = () => [card];
  vm.runInContext("renderHome()", ctx);
  doc.activeElement = undefined;
  doc.querySelectorAll = () => [];
  assert.equal(fresh.value, "half a repl");
  assert.ok(fresh.focused);
  assert.match(box.innerHTML, /data-id="a1"/, "the opened row is still open after the repaint");
});

test("running rows carry their phase and next phase; empty sections say so", () => {
  const html = draw(home({ running: [{ slug: "ar-1", title: "Queue cards", project: "agent-runtime", phases: { done: 3, total: 4, next: "docs" } }] }));
  assert.match(html, /Queue cards<\/span><span class="cchip running">running<\/span>.*agent-runtime, phase 3\/4, next: docs/s);
  assert.match(html, /Nothing waits on you\./);
  assert.match(draw(home()), /Nothing running from the queue\./);
});

test("health shows only what is not green, and all green as one chip", () => {
  const chips = [{ name: "k3s", level: "ok" }, { name: "ci", level: "warn" }, { name: "prod", level: "nodata" }];
  const mixed = draw(home({ health: chips }));
  assert.match(mixed, /cchip warn">ci WARN<\/span> <span class="cchip ">prod NO DATA<\/span> <span class="muted">1 green<\/span>/);
  assert.doesNotMatch(mixed, /k3s/);
  assert.match(draw(home({ health: [chips[0]] })), /cchip ok">all green \(1\)<\/span>/);
});

test("the numbers and what could not be read are drawn as hub-core worded them", () => {
  const html = draw(home({ numbers: [{ label: "queue", value: "1 running, 2 up next" }], errors: ["Prometheus: down"] }));
  assert.match(html, /^<div id="home-top"><div class="cline warn">Prometheus: down<\/div>/);
  assert.match(html, /<span><b>queue<\/b> 1 running, 2 up next<\/span>/);
});

test("the summary leads, and a long list shows the cap with a button for the rest", () => {
  const needs = Array.from({ length: 11 }, (_, i) => ({ kind: "nightly", need: "red", project: "p", text: `red ${i}`, id: `r${i}` }));
  const html = draw(home({ needs, numbers: [{ label: "queue", value: "1 running" }], health: [{ name: "ci", level: "red" }] }));
  assert.ok(html.indexOf("Numbers") < html.indexOf("Health") && html.indexOf("Health") < html.indexOf("Needs you"), html);
  assert.match(html, /red 7/);
  assert.doesNotMatch(html, /red 8/);
  assert.match(html, /<button class="btn sm" data-all="1">\+3 more<\/button>/);
  assert.doesNotMatch(draw(home({ needs: needs.slice(0, 8) })), /data-all/);
  draw(home({ needs }));
  fire("click", stub(() => null, { all: "1" }));
  assert.match(box.innerHTML, /red 10/);
  assert.doesNotMatch(box.innerHTML, /data-all/);
});

test("an open row past the cap stays on the page, so a rerank never hides an answer", () => {
  const needs = Array.from({ length: 11 }, (_, i) => ({ kind: "nightly", need: "red", project: "p", text: `red ${i}`, id: `r${i}` }));
  const html = draw(home({ needs }), [], [], ["nightly:r9"]);
  assert.match(html, /red 9/);
  assert.doesNotMatch(html, /red 10<\/td>/);
  assert.match(html, /\+1 more/);
});

test("a retired tab name lands on its new tab, and anything unknown on the landing tab, Home", () => {
  const of = (n) => vm.runInContext(`tabOf(${JSON.stringify(n)})`, ctx);
  assert.equal(of("waiting"), "home");
  assert.equal(of("asks"), "home");
  assert.equal(of("queue"), "queue");
  assert.equal(of("home"), "home");
  assert.equal(of("outbox"), "daily");
  assert.equal(of("focus"), "daily");
  assert.equal(of(""), "home");
  assert.equal(of("nope"), "home");
});
