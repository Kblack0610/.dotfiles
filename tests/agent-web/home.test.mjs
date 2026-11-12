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
  fetch: async (path) => { reads.push(path); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => (path === "/api/home/cards" ? cards() : path.startsWith("/api/home") ? home() : path === "/api/briefing" ? { error: "off" } : []) }; },
});
// Every Home refresh also reads the cards (refreshCards), so a test's own fetch stub answers that
// read with the fixture cards and only has to stub the reads it is about.
let fetchNow = ctx.fetch;
Object.defineProperty(ctx, "fetch", { get: () => fetchNow, set: (f) => {
  fetchNow = f.cards ? f : Object.assign((path, o) => (path === "/api/home/cards" ? Promise.resolve({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => cards() }) : f(path, o)), { cards: true });
} });
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
// Running's (`rtable`) over its rows, the columns hub_core::home::Running names.
const RCOLS = ["item", "project", "row", "epic", "phase", "eta", "pr", "ci", "since"];
const rtable = (rows, o) => ({ q: "", state: "", sort: "", dir: "desc", total: rows.length, shown: rows.length,
  states: [{ name: "all", n: rows.length }, { name: "CI failing", n: 0 }], columns: RCOLS.map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })), facets: [], ...o });
// Rows as the server ranks them.
const ranked = (needs) => needs.map((n, i) => ({ rank: i + 1, ...n }));
const home = (o = {}) => {
  const needs = ranked(o.needs || []);
  return { proposals: [], proposals_head: "", proposals_table: table(0), running: [], sessions: "", health: [], errors: [], shown: 8, ...o, needs, table: ntable(needs, o.table), running_table: rtable(o.running || [], o.running_table) };
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
  assert.match(html, /<h2 class="sec" id="sec-needs">Needs you <span class="n">2<\/span><\/h2>/);
  assert.match(html, /id="home-need-q" data-tsearch placeholder="search, or kind:ask project:dotfiles -kind:red"/);
  assert.match(html, /data-ts="Question"><span class="tl">QUESTION<\/span><span class="tv">1</);
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
  assert.match(html, /<h2 class="sec" id="sec-needs">Needs you <span class="n">0 of 5<\/span><\/h2>/);
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
  assert.equal(typeof parts["home-need-tiles"].innerHTML, "string");
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

test("Running is the shared table: its own bar and keys, and each row opens the item and links its records", () => {
  const due = now() - 7200;
  const html = draw(home({
    running: [
      { slug: "ar-1", title: "Queue cards", project: "agent-runtime", target: "lab/dotfiles-agent-2:1", started: "2026-11-11T10:00:00Z",
        phases: { done: 3, total: 4, next: "docs", eta_epoch: due }, overdue: true, row: "ar-1494", epic: "ar-1292",
        pr: "#1871", pr_url: "https://github.com/o/r/pull/1871", pr_state: "open", ci: "fail", ci_url: "https://github.com/o/r/pull/1871/checks" },
      { slug: "q-2", title: "No session yet", project: "trader" },
    ],
    // hub_core::links beside the rows (`Running::link`): the page draws these, it builds none.
    running_table: { states: [{ name: "all", n: 2 }, { name: "CI failing", n: 1 }], links: [
      { item: "#sessions/lab%2Fdotfiles-agent-2%3A1", project: "#projects/agent-runtime", row: "#projects/all?q=id:=ar-1494", epic: "#projects/all?q=id:=ar-1292",
        pr: "https://github.com/o/r/pull/1871", ci: "https://github.com/o/r/pull/1871/checks" },
      { item: "#queue/q-2", project: "#projects/trader" },
    ] },
  }));
  assert.match(html, /<div data-tbl="r"><div id="home-run-head"><h2 class="sec" id="sec-running">Running <span class="n">2<\/span><\/h2><\/div>/);
  assert.match(html, /<\/table><div class="cline muted"><a href="#sessions\?s=running">all running in Sessions<\/a><\/div><\/div>/, "the filtered link is the table's last line");
  assert.match(html, /id="home-run-q" data-tsearch placeholder="search, or project:dotfiles ci:fail epic:ar-1292"/);
  assert.match(html, /data-ts="CI failing"><span class="tl">CI FAILING<\/span><span class="tv">1</);
  assert.match(html, /data-tsort="eta"[^>]*>eta<\/button>/);
  const row = /<tr class="jr" data-slug="ar-1" data-target="lab\/dotfiles-agent-2:1"[^>]*>(.*?)<\/tr>/.exec(html);
  assert.ok(row, html);
  const cells = row[1];
  assert.match(cells, /<a class="tl" href="#sessions\/lab%2Fdotfiles-agent-2%3A1">Queue cards<\/a><div class="muted">next: docs<\/div>/);
  assert.match(cells, /<a class="tl" href="#projects\/agent-runtime">agent-runtime<\/a>/);
  assert.match(cells, /<a class="tl" href="#projects\/all\?q=id:=ar-1494">ar-1494<\/a>/);
  assert.match(cells, /<a class="tl" href="#projects\/all\?q=id:=ar-1292">ar-1292<\/a>/);
  assert.match(cells, /<td class="n">3\/4<\/td><td class="n"><span class="qlate"[^>]*>overdue 2h/);
  assert.match(cells, /<a class="tl" href="https:\/\/github.com\/o\/r\/pull\/1871" target="_blank" rel="noopener">#1871<\/a>/);
  assert.match(cells, /<a class="tl ci fail" href="https:\/\/github.com\/o\/r\/pull\/1871\/checks"[^>]*>fail<\/a>/);
  // No session: the row has no target to open and empty cells say so.
  assert.match(html, /<tr class="jr" data-slug="q-2" title="q-2"><td class="wrap"><a class="tl" href="#queue\/q-2">No session yet<\/a><\/td><td><a class="tl" href="#projects\/trader">trader<\/a><\/td><td>-<\/td><td>-<\/td><td class="n">-<\/td><td class="n">-<\/td><td>-<\/td><td>-<\/td><td class="n">-<\/td><\/tr>/);
  assert.doesNotMatch(html, /cchip running/, "no running cards: a card is only an opened record");
  assert.match(draw(home()), /Nothing running from the queue\./);
  // The server's clock decides overdue, the one its Overdue chip counts by: a past ETA it did
  // not call overdue is drawn as an ETA, not late.
  const calm = draw(home({ running: [{ slug: "ar-3", title: "t", project: "p", phases: { done: 1, total: 2, eta_epoch: due } }] }));
  assert.doesNotMatch(calm, /qlate/, calm);
});

test("a Running row click opens its session, else its queue item; a link in it goes where it points", () => {
  draw(home({ running: [{ slug: "ar-1", title: "t", project: "p", target: "lab/x:1" }, { slug: "q-2", title: "u", project: "p" }] }));
  const went = [];
  ctx.went = went;
  vm.runInContext(`setTab = (t, a) => went.push(t + "/" + a)`, ctx);
  const tr = (data) => ({ dataset: data });
  const click = (target) => on.click.forEach((f) => f({ target, preventDefault() {} }));
  const cell = (row, link) => ({ dataset: {}, closest: (sel) => (sel === "a" ? link : sel.startsWith("tr.jr[data-slug]") ? row : null) });
  click(cell(tr({ slug: "ar-1", target: "lab/x:1" }), null));
  click(cell(tr({ slug: "q-2" }), null));
  click(cell(tr({ slug: "q-2" }), {}));
  assert.deepEqual(went, ["sessions/lab/x:1", "queue/q-2"]);
});

test("Running reads its own r-prefixed keys beside Needs you's and Proposals'", async () => {
  reads.length = 0;
  vm.runInContext(`st.views.home = "q=x&nq=kind:ask&rq=project:trader&rs=CI+failing"`, ctx);
  await vm.runInContext("refreshHome()", ctx);
  const r = reads.find((p) => p.startsWith("/api/home?"));
  assert.ok(r, reads.join(" "));
  const p = new URLSearchParams(r.split("?")[1]);
  assert.deepEqual([p.get("q"), p.get("nq"), p.get("rq"), p.get("rs")], ["x", "kind:ask", "project:trader", "CI failing"]);
  vm.runInContext(`st.views.home = ""`, ctx);
});

test("what could not be read is drawn as hub-core worded it", () => {
  const html = draw(home({ errors: ["Prometheus: down"] }));
  assert.match(html, /^<div class="cline warn">Prometheus: down<\/div>/);
});

test("Home has no Numbers heading: the session counts close Running", () => {
  const html = draw(home({ sessions: "3 working, 1 need you, 0 stalled" }));
  assert.doesNotMatch(html, /Numbers/);
  assert.match(html, />Running <span class="n">0<\/span><\/h2>/);
  assert.match(html, /<div class="empty">Nothing running from the queue.<\/div><div class="cline muted"><b>Sessions<\/b> 3 working, 1 need you, 0 stalled <a href="#sessions\?s=running">all running in Sessions<\/a><\/div>/);
  assert.doesNotMatch(draw(home()), /<b>Sessions/, "the control: no counts, no line for them");
});

const vitals = (o = {}) => ({ head: "1 of 2 off target", line: "1 of 2 off target: Outcome", all_ok: false, rows: [
  { question: "Cost", level: "ok", parts: ["$12.54 per merged item"] },
  { question: "Outcome", level: "warn", parts: ["Oldest request 340h, limit 72h", "12 unverified, limit 0"] },
], ...o });

test("Vitals sits under the cards and above Needs you, a row per question, the off ones marked", () => {
  const html = draw(home({ vitals: vitals() }));
  assert.match(html, /<h2 class="sec warn" id="sec-vitals">Vitals<\/h2><div class="cline warn">1 of 2 off target<\/div>/);
  assert.match(html, /<div class="cline vital"><b>Cost<\/b> \$12.54 per merged item<\/div>/);
  assert.match(html, /<div class="cline vital warn"><b>Outcome<\/b> Oldest request 340h, limit 72h; 12 unverified, limit 0<\/div>/);
  assert.ok(html.indexOf("kgrid") < html.indexOf("Vitals") && html.indexOf("Vitals") < html.indexOf("Needs you"), html);
});

test("an unread vital is dim, so it never looks like a healthy row", () => {
  const rows = [{ question: "Cost", level: "nodata", parts: ["? per merged item"] }];
  assert.match(draw(home({ vitals: vitals({ rows }) })), /<div class="cline vital muted"><b>Cost<\/b> \? per merged item<\/div>/);
});

test("Vitals folds to its head when all are on target, and shows nothing until it is read", () => {
  const html = draw(home({ vitals: vitals({ head: "2 of 2 on target", all_ok: true }) }));
  assert.match(html, /<h2 class="sec" id="sec-vitals">Vitals<\/h2><div class="cline">2 of 2 on target<\/div>/);
  assert.doesNotMatch(html, /cline vital/, "green is one line (dashboards rule 4)");
  assert.doesNotMatch(draw(home({ vitals: null })), /Vitals/);
  assert.match(draw(home({ vitals: vitals(), grafana: "https://g" })), /Vitals<\/h2><div class="cline warn">1 of 2 off target <a class="glink" href="https:\/\/g\/d\/kb-agents-overview"/, "the trend is one click away");
});

// Cards as hub_core::cards serializes them: a link is its href.
const card = (tab, o = {}) => ({ tab, title: tab[0].toUpperCase() + tab.slice(1), big: "3", unit: "live", level: "ok", bar: [{ level: "ok", n: 2 }, { level: "red", n: 1 }],
  parts: [{ label: "Working", value: "2", level: "ok" }], first_head: "Where to look first", first: [], counted: `counted on ${tab}`, error: null, link: `#${tab}`, ...o });
const TABS = ["sessions", "queue", "alerts", "infra", "costs", "releases", "schedules", "projects"];
const cards = () => TABS.map((t) => card(t));
function drawCards(list, o = {}) {
  ctx.list = list;
  vm.runInContext("hst.cards = list; hst.cardsErr = null", ctx);
  return draw(home(o));
}

test("the cards lead Home, one per tab, each title opening its tab with what it counted", () => {
  const html = drawCards(cards());
  for (const t of TABS) assert.match(html, new RegExp(`<section class="kcard" data-card="${t}"><a class="kt" href="#${t}" title="counted on ${t}">`));
  assert.ok(html.indexOf("kgrid") < html.indexOf("Needs you"), html);
  assert.doesNotMatch(html, /Flow|Spend|cchip warn">ci/, "the cards replace the Flow, Health and Spend lines");
  assert.match(html, /<div class="kbig ok">3<span class="ku">live<\/span><\/div>/);
  assert.match(html, /<div class="kbar"[^>]*><i class="ok" style="flex:2"><\/i><i class="bad" style="flex:1"><\/i><\/div>/);
  assert.match(html, /<a class="kp" href="#sessions"><span>Working<\/span><b class="ok">2<\/b><\/a>/);
});

test("a look-first row opens its record, and is pilled only when it is not ok", () => {
  const first = [{ text: "trader-x", sub: "stalled 3h", level: "red", link: "#sessions/trader-x" }, { text: "binks", sub: "", level: "ok", link: null }];
  const html = drawCards([card("sessions", { first })]);
  assert.match(html, /<div class="kfh">Where to look first<\/div><a class="kf" href="#sessions\/trader-x"><span><b>trader-x<\/b><small>stalled 3h<\/small><\/span><em class="bad">broken<\/em><\/a>/);
  assert.match(html, /<a class="kf" href="#sessions"><span><b>binks<\/b><\/span><\/a>/, "no record: the row opens the tab, and an ok row has no pill");
});

test("a card whose read failed says NO DATA and why, never an all-clear", () => {
  const html = drawCards([card("alerts", { big: "-", unit: "no data", level: "nodata", bar: [], parts: [], error: "Prometheus: down" })]);
  assert.match(html, /<div class="kbig ">-<span class="ku">no data<\/span><\/div><div class="kbar" title="no data"><i><\/i><\/div><div class="cline warn">Prometheus: down<\/div>/);
  assert.doesNotMatch(html, /kbig ok/);
});

test("the phone line names only what is not green, all green is one chip, and unread says so", () => {
  const line = (list) => { ctx.list = list; return vm.runInContext("cardsLine(list)", ctx); };
  assert.equal(line(cards()), '<span class="cchip ok">all green (8)</span>');
  assert.equal(line([card("alerts", { level: "red" }), card("infra"), card("costs", { level: "nodata" })]), '<span class="cchip bad">Alerts broken</span> <span class="cchip ">Costs no data</span>');
  vm.runInContext("hst.cardsErr = null", ctx);
  assert.match(line(null), /<span class="muted">reading<\/span>/);
});

test("cards held after a failed refresh say they are stale, on the grid and the phone line", () => {
  ctx.list = cards();
  vm.runInContext("hst.cards = list; hst.cardsErr = 'HTTP 502'", ctx);
  const html = draw(home());
  assert.match(html, /<div class="cline warn">cards not refreshed: HTTP 502<\/div><div class="kgrid">/);
  assert.match(vm.runInContext("cardsLine(list)", ctx), /all green \(8\)<\/span> <span class="warn">cards not refreshed: HTTP 502<\/span>/);
  vm.runInContext("hst.cardsErr = null", ctx);
  assert.doesNotMatch(draw(home()), /not refreshed/, "a good refresh clears it");
});

test("Home asks for the cards as their own read, beside /api/home", async () => {
  reads.length = 0;
  await vm.runInContext("refreshHome()", ctx);
  assert.ok(reads.includes("/api/home/cards"), reads.join(" "));
  assert.equal(vm.runInContext("hst.cards.length", ctx), 8);
});

test("the summary leads, and a long list shows the cap with a button for the rest", () => {
  const needs = Array.from({ length: 11 }, (_, i) => ({ kind: "nightly", need: "red", project: "p", text: `red ${i}`, id: `r${i}` }));
  const html = draw(home({ needs }));
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
  assert.match(html, /<div id="home-prop-head"><h2 class="sec" id="sec-proposals">Proposals <span class="n">10<\/span><\/h2><\/div>/);
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
  assert.match(drawNight(night()), /<h2 class="sec" id="sec-night">Since last night<\/h2><div class="cline muted">all 6 areas ok<\/div><div class="cline muted"><b>Since<\/b> Thu 18:00<\/div>/);
  const html = drawNight(night({
    rows: [
      area("Workers overnight", "bad", { details: ["wave-roll failed 02:10"], fix: { project: "agent-runtime", task: "Fix it" } }),
      area("Sessions", "warn", { link: "#sessions" }),
    ],
    ok_line: "Infra, Nightly, Delivery, Costs ok",
    errors: ["watches: no such dir"],
  }));
  assert.match(html, /<h2 class="sec bad" id="sec-night">Since last night<\/h2><div class="cline warn">watches: no such dir<\/div>/, "a bad area hues the title");
  assert.match(html, /<a href="#fleet\?s=failed">Workers overnight<\/a> <span class="cchip bad">bad<\/span> Workers overnight line <button class="btn sm" data-fix="Workers overnight">Queue a fix<\/button><\/div><div class="cline muted">wave-roll failed 02:10<\/div>/);
  assert.match(html, /<a href="#sessions">Sessions<\/a> <span class="cchip warn">warn<\/span> Sessions line <\/div>/, "a warn row has no fix");
  assert.equal(html.match(/data-fix=/g).length, 1);
  assert.match(html, /Infra, Nightly, Delivery, Costs ok/);
  assert.ok(html.indexOf("Needs you") < html.indexOf("Since last night") && html.indexOf("Since last night") < html.indexOf("Proposals"));
});

test("a failed briefing read says why instead of an all-clear", () => {
  vm.runInContext("hst.night = null; hst.nightErr = 'agent-web: 502'", ctx);
  const html = draw(home());
  assert.match(html, /<h2 class="sec warn" id="sec-night">Since last night<\/h2><div class="cline warn">agent-web: 502<\/div>/);
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

test("an opened sheet row closes from its card: a refresh keeps the form, the row is read fresh by id, then the board's write", async () => {
  const sheet = (id) => ({ kind: "sheet", need: "todo", project: "p", text: "sheet row", id, score: { human: true, holds: "", priority: "urgent", value: 1 } });
  const needs = [sheet("t-1"), sheet("a row with no id")];
  const html = draw(home({ needs }), [], [], ["sheet:t-1", "sheet:a row with no id"]);
  assert.match(html, /data-close="t-1" data-closeproj="p".*data-closehow.*data-free data-closewhy.*data-closego>Close/s);
  assert.match(html, /href="#projects\/all">Open all rows/);
  assert.equal((html.match(/data-closego/g) || []).length, 1);
  // What was picked and typed is Home's state, so the next draw shows it again.
  vm.runInContext(`hst.close["t-1"] = { how: "done:proof", why: "pr:9" }`, ctx);
  assert.match(draw(home({ needs }), [], [], ["sheet:t-1"]), /value="done:proof" selected.*value="pr:9"/s);
  const sent = [];
  const reply = (body) => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body });
  const row = { id: "t-1", project: "p", state: "open", profile: "personal", lane: "human", raw: "- [ ] sheet row #urgent" };
  const before = ctx.fetch;
  let rows = [row, { ...row, project: "other" }];
  ctx.fetch = async (path, o) => {
    if (path.startsWith("/api/board?")) { sent.push(["read", path]); return reply({ rows }); }
    if (path === "/api/board") { sent.push(["write", JSON.parse(o.body)]); return reply({ out: "dropped" }); }
    return reply(path === "/api/briefing" ? { error: "off" } : home({ needs }));
  };
  const close = () => vm.runInContext(`closeSheetRow("t-1", "p")`, ctx);
  try {
    vm.runInContext(`hst.close["t-1"] = { how: "drop:why", why: " " }`, ctx);
    await close();
    assert.equal(vm.runInContext(`hst.close["t-1"].err`, ctx), "Say why it is dropped.");
    assert.equal(sent.length, 0);
    vm.runInContext(`hst.close["t-1"] = { how: "drop:why", why: "stale" }`, ctx);
    await close();
    assert.deepEqual(sent, [["read", "/api/board?q=id%3A%3Dt-1"],
      ["write", { verb: "drop", why: "stale", profile: "personal", project: "p", lane: "human", raw: "- [ ] sheet row #urgent" }]]);
    assert.equal(vm.runInContext(`"t-1" in hst.close`, ctx), false);
    rows = [{ ...row, state: "done" }];
    vm.runInContext(`hst.close["t-1"] = { how: "done:proof", why: "pr:9" }`, ctx);
    await close();
    assert.match(vm.runInContext(`hst.close["t-1"].err`, ctx), /t-1 is not open on the p sheet any more/);
    assert.equal(vm.runInContext(`hst.close["t-1"].busy`, ctx), false);
    assert.equal(sent.filter(([k]) => k === "write").length, 1);
  } finally { ctx.fetch = before; vm.runInContext(`hst.close = {}`, ctx); }
});
