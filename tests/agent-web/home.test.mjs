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
  fetch: async (path) => { reads.push(path); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => (path.startsWith("/api/home") ? home() : path === "/api/briefing" ? { error: "off" } : []) }; },
});
// In the page's own order: a script that calls another at load needs it loaded first.
const page = readFileSync(new URL("../src/index.html", dir), "utf8");
const scripts = new Set(["ui.js", "md.js", "app.js", "actions.js", "table.js", "flow.js", "waiting.js", "home.js", "queue.js"]);
for (const f of [...page.matchAll(/static\/([a-z]+\.js)/g)].map((m) => m[1]).filter((f) => scripts.has(f))) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const now = () => Math.floor(Date.now() / 1000);
function draw(home, agents = [], asks = [], opened = []) {
  ctx.input = { home, agents, asks, opened };
  return vm.runInContext(`st.agents = input.agents; st.asks = input.asks; hst.data = input.home; hst.err = null; hst.open = new Set(input.opened); needT.all = false; propT.all = false; drawHome(); $("home").innerHTML`, ctx);
}
// Proposals' table summary, and Needs you's (`ntable`) over the rows it ranks.
const table = (n) => ({ q: "", state: "", sort: "", dir: "desc", total: n, shown: n, states: [{ name: "all", n }], facets: [],
  columns: ["stream", "project", "proposal", "created", "verb"].map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })) });
const COLS = ["rank", "kind", "project", "waited", "holds", "what"];
const ntable = (needs, o) => ({ q: "", state: "", sort: "", dir: "desc", total: needs.length, shown: needs.length,
  states: [{ name: "all", n: needs.length }], columns: COLS.map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })), facets: [], ...o });
// Rows as the server ranks them.
const ranked = (needs) => needs.map((n, i) => ({ rank: i + 1, ...n }));
const home = (o = {}) => {
  const needs = ranked(o.needs || []);
  return { proposals: [], proposals_head: "", proposals_table: table(0), running: [], flow: { chips: [{ key: "running", label: "running", value: "1", hot: false, to: { tab: "queue", state: "running" } }, { key: "inbox", label: "inbox", value: null, hot: false, to: null }], bottleneck: null, as_of: null, error: null }, sessions: "", spend: null, health: [], errors: [], shown: 8, ...o, needs, table: ntable(needs, o.table) };
};
const live = (target, kind) => ({ target, short: target, session: target, project: "p", summary: target, items: [], actions: [], question: { kind, text: "Run it?" } });
const shipIt = { id: "a1", project: "p", kind: "question", question: "Ship it?", title: "Ship it?", body: "", options: ["yes", "no"], recommend: "yes", session: "", agent: "x", judge: "", created: now() - 120 };
const prop = (id, o) => ({ id, stream: "dream", project: "dotfiles", title: `Keep ${id}`, why: "said twice", evidence: "", verb: "queue",
  does: "agent-queue add --project dotfiles -- x", created: "2026-11-05T10:00:00Z", expires: "2026-12-05T10:00:00Z", error: null, ...o });

test("Needs you is the shared table: the columns, the server's chips, the rank as the order", () => {
  const html = draw(home({
    needs: [
      { kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1", since: now() - 3900, score: { holds: "session, 2 phases" } },
      { kind: "nightly", need: "red", project: "", text: "PlayMode.Lobby red", id: "unity-core" },
    ],
    table: { shown: 2, total: 2, states: [{ name: "all", n: 2 }, { name: "Question", n: 1 }, { name: "Failing", n: 1 }] },
  }));
  assert.match(html, /<h2 class="sec" id="sec-needs">Needs you <span class="muted">2<\/span><\/h2>/);
  assert.match(html, /id="home-need-q" data-tsearch placeholder="search, or kind:ask project:dotfiles -kind:red"/);
  assert.match(html, /data-ts="Question">Question <span class="n">1<\/span>/);
  assert.match(html, /<th class="n"[^>]*><button class="thsort" data-tsort="rank"[^>]*>rank \^<\/button><\/th>/);
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
  assert.match(html, /<th class="n" aria-sort="ascending"[^>]*>.*waited \^<\/button>/);
  assert.match(html, />rank<\/button>/);
});

test("the view keeps the count of the whole list, and no match is not an all-clear", () => {
  const html = draw({ ...home(), table: ntable([], { q: "kind:ask", total: 5, shown: 0 }) });
  assert.match(html, /<h2 class="sec" id="sec-needs">Needs you <span class="muted">0 of 5<\/span><\/h2>/);
  assert.match(html, /No needs match\./);
  assert.doesNotMatch(html, /Nothing waits on you/);
  assert.match(html, /id="home-need-q"[^>]*value="kind:ask"/, "the box stays, so the view can be changed back");
  const none = draw(home());
  assert.match(none, /Nothing waits on you\./);
  assert.doesNotMatch(none, /id="home-need-q"/, "an empty list has nothing to search");
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
// A control inside Needs you's block (data-tbl="n"); one outside it is Proposals'.
const inNeeds = (sel) => (sel === "[data-tbl]" ? { dataset: { tbl: "n" } } : null);

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
  const tab = vm.runInContext("st.tab", ctx);
  vm.runInContext(`st.tab = "home"; st.views.home = ""`, ctx);
  draw(home());
  const search = { dataset: { tsearch: "" }, value: "kind:ask", closest: inNeeds };
  fire("input", search);
  const chip = stub((sel) => (sel === "[data-ts]" ? { dataset: { ts: "Question" } } : inNeeds(sel)));
  fire("click", chip);
  await new Promise(setImmediate);
  assert.equal(vm.runInContext("st.views.home", ctx), "nq=kind%3Aask&ns=Question");
  assert.ok(reads.includes("/api/home?nq=kind%3Aask"), reads.join(" "));
  assert.ok(reads.at(-1).startsWith("/api/home?nq=kind%3Aask&ns=Question"), reads.join(" "));
  ctx.input = tab;
  vm.runInContext(`st.tab = input; st.views.home = ""; hst.night = null; hst.nightErr = null`, ctx);
});

test("each table's bar changes only its own view keys: Needs you's n-prefixed, Proposals' plain", async () => {
  const tab = vm.runInContext("st.tab", ctx);
  vm.runInContext(`st.tab = "home"; st.views.home = ""`, ctx);
  draw(home({ needs: [{ kind: "ask", need: "ask", project: "p", text: "x", id: "a1" }], proposals: [prop("a1")], proposals_table: table(1) }));
  const outside = () => null;
  const sortOn = (key, near) => stub((sel) => (sel === "[data-tsort]" ? { dataset: { tsort: key, tdir: "asc" } } : near(sel)));
  const chipOn = (name, near) => stub((sel) => (sel === "[data-ts]" ? { dataset: { ts: name } } : near(sel)));
  const view = () => Object.fromEntries(new URLSearchParams(vm.runInContext("st.views.home", ctx)));
  reads.length = 0;
  fire("input", { dataset: { tsearch: "" }, value: "kind:ask", closest: inNeeds });
  fire("click", chipOn("Question", inNeeds));
  fire("click", sortOn("waited", inNeeds));
  await new Promise(setImmediate);
  assert.deepEqual(view(), { nq: "kind:ask", ns: "Question", nsort: "waited", ndir: "asc" });
  assert.ok(reads.every((r) => !r.startsWith("/api/home/proposals")), reads.join(" "));
  fire("input", { dataset: { tsearch: "" }, value: "stream:dream", closest: outside });
  fire("change", { dataset: { tq: "" }, value: "stream:dream project:dotfiles", closest: outside });
  fire("click", chipOn("queue", outside));
  fire("click", sortOn("created", outside));
  await new Promise(setImmediate);
  assert.deepEqual(view(), { nq: "kind:ask", ns: "Question", nsort: "waited", ndir: "asc", q: "stream:dream project:dotfiles", s: "queue", sort: "created", dir: "asc" });
  const section = reads.filter((r) => r.startsWith("/api/home/proposals"));
  assert.ok(section.length, reads.join(" "));
  for (const r of section) assert.doesNotMatch(r, /[?&]n(q|s|sort|dir)=/, "the Proposals read carries only its own keys");
  ctx.input = tab;
  vm.runInContext(`st.tab = input; st.views.home = ""; hst.night = null; hst.nightErr = null`, ctx);
});

test("a dropdown in use in one table repaints around it, and the other table whole", () => {
  const needs = [{ kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1" }];
  const first = draw(home({ needs, proposals: [prop("a1")], proposals_table: table(1) }));
  delete parts["home-prop-body"];
  doc.activeElement = { dataset: { tsv: "" }, closest: (sel) => (sel === "#home-need-facets" ? {} : null), matches: () => false };
  ctx.input = home({ needs: [...needs, { kind: "ask", need: "ask", project: "p", text: "Second", id: "a2" }], proposals: [prop("a1")], proposals_table: table(1) });
  const again = vm.runInContext(`hst.data = input; renderHome(); $("home").innerHTML`, ctx);
  doc.activeElement = undefined;
  assert.equal(again, first);
  assert.match(parts["home-need-body"].innerHTML, /Second/);
  assert.match(parts["home-prop-body"].innerHTML, /a1/, "Proposals is repainted, so it is never left stale");
  assert.equal(typeof parts["home-need-facets"]?.innerHTML, "undefined", "the dropdown in use is left alone");
});

test("a refresh repaints around the search box in use and leaves it alone", () => {
  const needs = [{ kind: "ask", need: "ask", project: "p", text: "Ship it?", id: "a1" }];
  const first = draw(home({ needs }));
  doc.activeElement = { id: "home-need-q", dataset: {}, closest: () => null, matches: () => false };
  ctx.input = home({ needs: [...needs, { kind: "ask", need: "ask", project: "p", text: "Second", id: "a2" }] });
  const again = vm.runInContext(`hst.data = input; renderHome(); $("home").innerHTML`, ctx);
  doc.activeElement = undefined;
  assert.equal(again, first, "the board with the box in it is not repainted");
  assert.match(parts["home-need-body"].innerHTML, /Second/);
  assert.match(parts["home-need-head"].innerHTML, /Needs you/);
  assert.equal(typeof parts["home-need-chips"].innerHTML, "string");
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
  assert.match(mixed, /green<\/span> <a href="#alerts">Alerts<\/a><\/div>/, "the chips open Alerts, which has every domain");
});

test("what could not be read is drawn as hub-core worded it", () => {
  const html = draw(home({ errors: ["Prometheus: down"] }));
  assert.match(html, /^<div class="cline warn">Prometheus: down<\/div>/);
});

test("Home has no Numbers heading: the session counts head Running and the spend is one line linking Costs", () => {
  const html = draw(home({ sessions: "3 working, 1 need you, 0 stalled", spend: "claude $573 in 24h" }));
  assert.doesNotMatch(html, /Numbers/);
  assert.match(html, />Running <span class="muted">0<\/span> <span class="muted"><a href="#sessions">sessions<\/a>: 3 working, 1 need you, 0 stalled<\/span><\/h2>/);
  assert.match(html, /Spend<\/h2><div class="cline">claude \$573 in 24h <a href="#costs">Costs<\/a><\/div>/);
  assert.ok(html.indexOf("Health") < html.indexOf("Spend") && html.indexOf("Spend") < html.indexOf("Needs you"), html);
  const none = draw(home());
  assert.doesNotMatch(none, /Spend|sessions<\/a>/, "the control: no spend and no counts, no lines for them");
});

const vitals = (o = {}) => ({ head: "1 of 2 off target", line: "1 of 2 off target: Flow", all_ok: false, rows: [
  { question: "Output", level: "ok", parts: ["1633 PRs merged in 7d"] },
  { question: "Flow", level: "warn", parts: ["Queue -200 in 24h", "queued p90 53h, limit 12h"] },
], ...o });

test("Vitals sits under Spend and above Needs you, a row per question, the off ones marked", () => {
  const html = draw(home({ spend: "claude $573 in 24h", vitals: vitals() }));
  assert.match(html, /Vitals <span class="muted">1 of 2 off target<\/span><\/h2>/);
  assert.match(html, /<div class="cline vital"><b>Output<\/b> 1633 PRs merged in 7d<\/div>/);
  assert.match(html, /<div class="cline vital warn"><b>Flow<\/b> Queue -200 in 24h; queued p90 53h, limit 12h<\/div>/);
  assert.ok(html.indexOf("Spend") < html.indexOf("Vitals") && html.indexOf("Vitals") < html.indexOf("Needs you"), html);
});

test("an unread vital is dim, so it never looks like a healthy row", () => {
  const rows = [{ question: "Trust", level: "nodata", parts: ["Ledger ?"] }];
  assert.match(draw(home({ vitals: vitals({ rows }) })), /<div class="cline vital muted"><b>Trust<\/b> Ledger \?<\/div>/);
});

test("Vitals folds to its head when all are on target, and shows nothing until it is read", () => {
  const html = draw(home({ vitals: vitals({ head: "2 of 2 on target", all_ok: true }) }));
  assert.match(html, /Vitals <span class="muted">2 of 2 on target<\/span>/);
  assert.doesNotMatch(html, /cline vital/, "green is one line (dashboards rule 4)");
  assert.doesNotMatch(draw(home({ vitals: null })), /Vitals/);
  assert.match(draw(home({ vitals: vitals(), grafana: "https://g" })), /Vitals <span class="muted">[^<]*<\/span> <a class="glink" href="https:\/\/g\/d\/kb-agents-overview"/, "the trend is one click away");
});

test("the flow strip leads Home, and the queue and done-today numbers are gone", () => {
  const html = draw(home());
  assert.ok(html.indexOf("Flow") < html.indexOf("Health"), html);
  assert.match(html, /href="#queue\?s=running" data-flow="running">running 1</);
  assert.match(html, />inbox -</);
  assert.doesNotMatch(html, /<b>queue<\/b>|done today/);
});

test("the summary leads, and a long list shows the cap with a button for the rest", () => {
  const needs = Array.from({ length: 11 }, (_, i) => ({ kind: "nightly", need: "red", project: "p", text: `red ${i}`, id: `r${i}` }));
  const html = draw(home({ needs, health: [{ name: "ci", level: "red" }] }));
  assert.ok(html.indexOf("Flow") < html.indexOf("Health") && html.indexOf("Health") < html.indexOf("Needs you"), html);
  assert.match(html, /red 7/);
  assert.doesNotMatch(html, /red 8/);
  assert.match(html, /<button class="btn sm" data-all="1">\+3 more<\/button>/);
  assert.doesNotMatch(draw(home({ needs: needs.slice(0, 8) })), /data-all/);
  draw(home({ needs }));
  fire("click", stub(inNeeds, { all: "1" }));
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

test("Proposals is one line when empty and sits between Needs you and Running", () => {
  const html = draw(home());
  assert.match(html, /Nothing proposed\./);
  assert.ok(html.indexOf("Needs you") < html.indexOf("Proposals") && html.indexOf("Proposals") < html.indexOf("Running"), html);
  assert.doesNotMatch(html, /home-prop-q/);
});

test("a proposal row carries both actions; the rest fold under +N more", () => {
  const rows = Array.from({ length: 10 }, (_, i) => prop(`p${i}`));
  const html = draw(home({ proposals: rows, proposals_head: "10 from 1 stream", proposals_table: table(10) }));
  assert.match(html, /Proposals <span class="muted">10 from 1 stream<\/span>/);
  assert.match(html, /data-accept="p0".*data-reject="p0"/s);
  assert.equal((html.match(/data-accept=/g) || []).length, 8);
  assert.match(html, /\+2 more/);
});

test("an opened proposal says why and exactly what accept runs, and escapes it", () => {
  const p = prop("aa", { why: "<b>why</b>", evidence: "https://x.test/r", error: "boom" });
  ctx.input = p.id;
  vm.runInContext("hst.prop.open = input", ctx);
  const html = draw(home({ proposals: [p], proposals_head: "1 from 1 stream", proposals_table: table(1) }));
  vm.runInContext("hst.prop.open = null", ctx);
  assert.match(html, /Accept runs.*agent-queue add --project dotfiles -- x/s);
  assert.match(html, /&lt;b&gt;why&lt;\/b&gt;/);
  assert.match(html, /href="https:\/\/x\.test\/r"/);
  assert.match(html, /Last accept failed<\/b> boom/);
});

test("evidence that is not a web link is text, never an href", () => {
  const p = prop("aa", { evidence: "javascript:alert(1)" });
  ctx.input = p.id;
  vm.runInContext("hst.prop.open = input", ctx);
  const html = draw(home({ proposals: [p], proposals_head: "1 from 1 stream", proposals_table: table(1) }));
  vm.runInContext("hst.prop.open = null", ctx);
  assert.doesNotMatch(html, /href="javascript/);
});

test("accept and reject post the id to their own route, and a refusal stays on the page", async () => {
  const sent = [];
  const reply = { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({}) };
  const before = ctx.fetch;
  ctx.fetch = async (path, o) => {
    if (path === "/api/briefing") return { ...reply, json: async () => ({ error: "off" }) };
    if (!path.startsWith("/api/proposals/")) return { ...reply, json: async () => home({ proposals: [prop("a1")], proposals_table: table(1) }) };
    sent.push([path, o.body]);
    return path.endsWith("/reject") ? { ok: false, status: 500, statusText: "", text: async () => "already decided" } : reply;
  };
  try {
    await vm.runInContext(`propDecide("accept", "a1")`, ctx);
    assert.equal(vm.runInContext("hst.prop.err", ctx), null);
    await vm.runInContext(`propDecide("reject", "a1")`, ctx);
  } finally { ctx.fetch = before; }
  assert.deepEqual(sent, [["/api/proposals/accept", '{"id":"a1"}'], ["/api/proposals/reject", '{"id":"a1"}']]);
  assert.match(vm.runInContext("hst.prop.err", ctx), /already decided/);
  assert.equal(vm.runInContext("hst.prop.busy", ctx), null);
  vm.runInContext("hst.prop.err = null", ctx);
});

test("a failed proposals read does not say nothing is proposed", () => {
  const html = draw(home({ proposals_failed: true, errors: ["no jq, so no proposals are shown"] }));
  assert.match(html, /Could not read proposals/);
  assert.doesNotMatch(html, /Nothing proposed/);
});

const night = (o) => ({ at: now(), since: now() - 3600, since_label: "Thu 18:00", rows: [], ok_line: "all 6 areas ok", errors: [], ...o });
const area = (name, level, o) => ({ name, level, line: `${name} line`, details: [], link: "#fleet?s=failed", fix: null, ...o });
function drawNight(n) {
  ctx.input = n;
  vm.runInContext("hst.night = input; hst.nightErr = null; hst.fix = {}", ctx);
  return draw(home());
}

test("Since last night shows only what is not ok, links each row and folds the ok areas", () => {
  assert.match(drawNight(night()), /<h2 class="sec" id="sec-night">Since last night <span class="muted">since Thu 18:00 <a href="#daily">briefing<\/a><\/span><\/h2><div class="cline muted">all 6 areas ok<\/div>/);
  const html = drawNight(night({
    rows: [
      area("Workers overnight", "bad", { details: ["wave-roll failed 02:10"], fix: { project: "agent-runtime", task: "Fix it" } }),
      area("Sessions", "warn", { link: "#sessions" }),
    ],
    ok_line: "Infra, Nightly, Delivery, Costs ok",
    errors: ["watches: no such dir"],
  }));
  assert.match(html, /<div class="cline warn">watches: no such dir<\/div>/);
  assert.match(html, /<a href="#fleet\?s=failed">Workers overnight<\/a> <span class="cchip bad">bad<\/span> Workers overnight line <button class="btn sm" data-fix="Workers overnight">Queue a fix<\/button><\/div><div class="cline muted">wave-roll failed 02:10<\/div>/);
  assert.match(html, /<a href="#sessions">Sessions<\/a> <span class="cchip warn">warn<\/span> Sessions line <\/div>/, "a warn row has no fix");
  assert.equal(html.match(/data-fix=/g).length, 1);
  assert.match(html, /Infra, Nightly, Delivery, Costs ok/);
  assert.ok(html.indexOf("Needs you") < html.indexOf("Since last night") && html.indexOf("Since last night") < html.indexOf("Proposals"));
});

test("a failed briefing read says why instead of an all-clear", () => {
  vm.runInContext("hst.night = null; hst.nightErr = 'agent-web: 502'", ctx);
  const html = draw(home());
  assert.match(html, /Since last night<\/h2><div class="cline warn">agent-web: 502<\/div>/);
  assert.doesNotMatch(html, /areas ok/);
  vm.runInContext("hst.nightErr = null", ctx);
});

test("Queue a fix posts the area's task to the queue once and says what it queued", async () => {
  const sent = [];
  const before = ctx.fetch;
  ctx.fetch = async (path, o) => {
    sent.push([path, o && o.body]);
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({ out: "20261107-fix-it" }) };
  };
  drawNight(night({ rows: [area("Nightly", "bad", { fix: { project: "agent-runtime", task: "Fix the nightly" } })] }));
  try {
    await vm.runInContext(`queueFix("Nightly")`, ctx);
  } finally { ctx.fetch = before; }
  assert.deepEqual(sent, [["/api/queue", '{"project":"agent-runtime","task":"Fix the nightly"}']]);
  const html = draw(home());
  assert.match(html, /<span class="muted">queued 20261107-fix-it<\/span>/);
  assert.doesNotMatch(html, /data-fix=/, "a queued fix is not offered again");
  vm.runInContext("hst.night = null; hst.fix = {}", ctx);
});

test("a fix the queue already holds shows its item, and a new window offers fixes again", async () => {
  const held = night({ rows: [area("Nightly", "bad", { fix: { project: "agent-runtime", task: "Fix the nightly", queued: "20261106-fix-nightly" } })] });
  let html = drawNight(held);
  assert.match(html, /<span class="muted">queued 20261106-fix-nightly<\/span>/);
  assert.doesNotMatch(html, /data-fix=/, "a reload or the hub TUI does not queue it twice");

  const before = ctx.fetch;
  let answer = night({ rows: [area("Nightly", "bad", { fix: { project: "agent-runtime", task: "Fix the nightly" } })] });
  ctx.fetch = async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => answer });
  try {
    vm.runInContext(`hst.fix = { Nightly: { ok: true, text: "queued x" } }`, ctx);
    await vm.runInContext("refreshNight()", ctx);
    assert.equal(vm.runInContext("hst.fix.Nightly.text", ctx), "queued x", "the same window keeps what was queued here");
    answer = { ...answer, since: answer.since - 86400 };
    await vm.runInContext("refreshNight()", ctx);
    assert.equal(vm.runInContext("hst.fix.Nightly", ctx), undefined, "a new window forgets it");
    answer = { error: "briefing: boom" };
    await vm.runInContext("refreshNight()", ctx);
    assert.equal(vm.runInContext("hst.nightErr", ctx), "briefing: boom");
    html = draw(home());
    assert.match(html, /<div class="cline warn">briefing: boom<\/div>/);
    assert.match(html, /data-fix="Nightly"/, "the last good read stays up under a failed one");
  } finally { ctx.fetch = before; }
  vm.runInContext("hst.night = null; hst.nightErr = null; hst.fix = {}", ctx);
});

test("a search reads the Proposals section alone and lays it over the Home already held", async () => {
  const seen = [];
  const before = ctx.fetch;
  ctx.URLSearchParams = URLSearchParams;
  ctx.fetch = async (path) => {
    seen.push(path);
    const body = path.startsWith("/api/home/proposals")
      ? { proposals: [prop("b2")], proposals_head: "2 from 1 stream", proposals_table: table(2) }
      : home({ needs: [{ kind: "queue", project: "p", text: "kept", id: "q1" }], proposals: [prop("a1"), prop("b2")], proposals_table: table(2) });
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body };
  };
  try {
    draw(home({ needs: [{ kind: "queue", project: "p", text: "kept", id: "q1" }], proposals: [prop("a1"), prop("b2")], proposals_table: table(2) }));
    seen.length = 0;
    await vm.runInContext(`refreshProposals()`, ctx);
  } finally { ctx.fetch = before; delete ctx.URLSearchParams; }
  assert.equal(seen.length, 1);
  assert.match(seen[0], /^\/api\/home\/proposals/);
  assert.deepEqual(vm.runInContext("hst.data.proposals.map((p) => p.id)", ctx), ["b2"]);
  assert.equal(vm.runInContext("hst.data.needs.length", ctx), 1, "the rest of Home is untouched");
});

test("a failed section read falls back to the full Home read, which shows the error", async () => {
  const seen = [];
  const before = ctx.fetch;
  ctx.URLSearchParams = URLSearchParams;
  ctx.fetch = async (path) => {
    seen.push(path);
    if (path === "/api/briefing") return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({ error: "briefing: off" }) };
    if (path.startsWith("/api/home/proposals")) return { ok: false, status: 502, statusText: "", text: async () => "agent-propose: boom" };
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => home({ proposals_failed: true, errors: ["agent-propose: boom, so no proposals are shown"] }) };
  };
  try {
    draw(home({ proposals: [prop("a1")], proposals_table: table(1) }));
    seen.length = 0;
    await vm.runInContext(`refreshProposals()`, ctx);
  } finally { ctx.fetch = before; delete ctx.URLSearchParams; }
  assert.match(seen[0], /^\/api\/home\/proposals/);
  assert.ok(seen.includes("/api/home"), seen.join());
  assert.match(vm.runInContext("$('home').innerHTML", ctx), /Could not read proposals/);
});

test("a slow full read that started before a search cannot put the older rows back", async () => {
  const before = ctx.fetch;
  ctx.URLSearchParams = URLSearchParams;
  let release;
  const json = (body) => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body });
  ctx.fetch = (path) => {
    if (path === "/api/briefing") return Promise.resolve(json({ error: "off" }));
    if (path.startsWith("/api/home/proposals")) return Promise.resolve(json({ proposals: [prop("new")], proposals_head: "1 from 1 stream", proposals_table: table(1) }));
    return new Promise((r) => { release = () => r(json(home({ needs: [{ kind: "queue", project: "p", text: "fresh", id: "q2" }], proposals: [prop("old")], proposals_table: table(1) }))); });
  };
  try {
    draw(home({ proposals: [prop("old")], proposals_table: table(1) }));
    const full = vm.runInContext(`refreshHome()`, ctx);
    await vm.runInContext(`refreshProposals()`, ctx);
    release();
    await full;
  } finally { ctx.fetch = before; delete ctx.URLSearchParams; }
  assert.deepEqual(vm.runInContext("hst.data.proposals.map((p) => p.id)", ctx), ["new"]);
  assert.equal(vm.runInContext("hst.data.needs.length", ctx), 1, "the rest of the full read still lands");
});

test("after a failed proposals read the next search goes to the full read, so the recovery shows", async () => {
  const seen = [];
  const before = ctx.fetch;
  ctx.URLSearchParams = URLSearchParams;
  ctx.fetch = async (path) => {
    seen.push(path);
    const body = path === "/api/briefing" ? { error: "off" } : home({ proposals: [prop("a1")], proposals_table: table(1) });
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body };
  };
  try {
    draw(home({ proposals_failed: true, errors: ["agent-propose: boom, so no proposals are shown"] }));
    seen.length = 0;
    await vm.runInContext(`refreshProposals()`, ctx);
  } finally { ctx.fetch = before; delete ctx.URLSearchParams; }
  assert.ok(!seen.some((p) => p.startsWith("/api/home/proposals")), seen.join());
  assert.equal(vm.runInContext("hst.data.proposals_failed", ctx), undefined);
  assert.doesNotMatch(vm.runInContext("$('home').innerHTML", ctx), /Could not read proposals/);
});

test("a row that leaves Needs you closes, so its id never comes back open", async () => {
  const before = ctx.fetch;
  const a = (id) => ({ kind: "ask", need: "ask", project: "p", text: id, id });
  let answer = home({ needs: [a("a1"), a("a2")] });
  ctx.fetch = async (path) => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => (path === "/api/briefing" ? { error: "off" } : answer) });
  ctx.URLSearchParams = URLSearchParams;
  try {
    vm.runInContext(`hst.open = new Set(["ask:a1", "ask:a2"])`, ctx);
    answer = home({ needs: [a("a2")] });
    await vm.runInContext("refreshHome()", ctx);
    assert.equal(vm.runInContext("JSON.stringify([...hst.open])", ctx), '["ask:a2"]');
  } finally { ctx.fetch = before; delete ctx.URLSearchParams; vm.runInContext("hst.open = new Set()", ctx); }
});
