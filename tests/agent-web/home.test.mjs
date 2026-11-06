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
const doc = { getElementById: (id) => (id === "home" ? box : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [] };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
// In the page's own order: a script that calls another at load needs it loaded first.
const page = readFileSync(new URL("../src/index.html", dir), "utf8");
const scripts = new Set(["ui.js", "md.js", "app.js", "actions.js", "table.js", "waiting.js", "home.js", "queue.js"]);
for (const f of [...page.matchAll(/static\/([a-z]+\.js)/g)].map((m) => m[1]).filter((f) => scripts.has(f))) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const now = () => Math.floor(Date.now() / 1000);
function draw(home, agents = [], asks = []) {
  ctx.input = { home, agents, asks };
  return vm.runInContext(`st.agents = input.agents; st.asks = input.asks; hst.data = input.home; hst.err = null; drawHome(); $("home").innerHTML`, ctx);
}
const table = (n) => ({ q: "", state: "", sort: "", dir: "desc", total: n, shown: n, states: [{ name: "all", n }], facets: [],
  columns: ["stream", "project", "proposal", "created", "verb"].map((key) => ({ key, sort: null, next_sort: key, next_dir: "desc" })) });
const home = (o) => ({ needs: [], proposals: [], proposals_head: "", proposals_table: table(0), running: [], numbers: [], health: [], errors: [], shown: 8, ...o });
const prop = (id, o) => ({ id, stream: "dream", project: "dotfiles", title: `Keep ${id}`, why: "said twice", evidence: "", verb: "queue",
  does: "agent-queue add --project dotfiles -- x", created: "2026-11-05T10:00:00Z", expires: "2026-12-05T10:00:00Z", error: null, ...o });

test("an ask or an open dialog on Needs you is its answer card; a red nightly is a plain card", () => {
  const html = draw(home({
    needs: [
      { kind: "ask", project: "p", text: "Ship it?", id: "a1", since: now() - 120 },
      { kind: "session", project: "p", text: "Wire the join", id: "lab/w:1", target: "lab/w:1", since: now() - 300 },
      { kind: "nightly", project: "unity-core", text: "PlayMode.Lobby red", id: "unity-core" },
    ],
  }), [{ target: "lab/w:1", short: "w", session: "c1", project: "p", summary: "Wire the join", items: [], actions: [], question: { kind: "tool", text: "Run it?" } }],
  [{ id: "a1", project: "p", kind: "question", question: "Ship it?", title: "Ship it?", body: "", options: ["yes", "no"], recommend: "yes", session: "", agent: "x", judge: "", created: now() - 120 }]);
  assert.match(html, /<h2 class="sec">Needs you <span class="muted">3<\/span><\/h2>/);
  assert.match(html, /<div class="ntally"><span class="nchip k-ask">Question <b>1<\/b><\/span><span class="nchip k-perm">Permission <b>1<\/b><\/span><span class="nchip k-red">Failing <b>1<\/b><\/span><\/div>/);
  assert.match(html, /data-id="a1".*data-a="yes".*data-t="lab\/w:1".*data-k="1".*need k-red.*<span>nightly failed<\/span>/s, html);
  assert.match(html, /<span class="nkind">Failing<\/span><span>unity-core<\/span><span>nightly failed<\/span><\/div><div class="ntitle">PlayMode\.Lobby red/, "the id that only repeats the project is not shown twice");
});

test("Needs you keeps the server's ranked order and says what each row holds", () => {
  const plan = (t) => ({ target: t, short: t, session: t, project: "p", summary: t, items: [], actions: [], question: { kind: "plan", text: "do it" } });
  const score = (holds) => ({ human: true, holds, value: 1 });
  const html = draw(home({ needs: [
    { kind: "queue", project: "p", text: "blocked one", id: "q1", score: score("2 queued") },
    { kind: "session", project: "p", text: "s1", id: "s1", target: "s1", score: score("session") },
    { kind: "ask", project: "p", text: "first ask", id: "x1", score: score("") },
    { kind: "session", project: "p", text: "s2", id: "s2", target: "s2" },
  ] }), [plan("s1"), plan("s2")]);
  const at = (s) => html.indexOf(s);
  // Negative control: a queue row the server ranked first is not moved below the plans.
  assert.ok(at("blocked one") < at('data-t="s1"') && at('data-t="s1"') < at("first ask") && at("first ask") < at('data-t="s2"'), html);
  assert.match(html, /<span class="nkind">Blocked<\/span>.*<span>holds 2 queued<\/span>/s);
  assert.match(html, /<span class="nchip k-plan">Plan to approve <b>2<\/b><\/span><span class="nchip k-ask">Question <b>1<\/b><\/span><span class="nchip k-blocked">Blocked <b>1<\/b><\/span>/);
});

test("a stopped dispatch is a Stopped card with its one line, its age and no id", () => {
  const html = draw(home({ needs: [
    { kind: "stopped", project: "", text: "Dispatch stopped 13h: no account has room. Clears when an account is back under its pace.", id: "stopped:fleet-dispatch", since: now() - 13 * 3600 },
    { kind: "ask", project: "p", text: "Ship it?", id: "a1" },
  ] }));
  assert.match(html, /<span class="nchip k-stopped">Stopped <b>1<\/b><\/span>/);
  assert.match(html, /need k-stopped.*<span class="nkind">Stopped<\/span><span>dispatch<\/span><span>13h[^<]*<\/span><\/div><div class="ntitle">Dispatch stopped 13h: no account has room/s, html);
  assert.doesNotMatch(html, /stopped:fleet-dispatch<\/span>/);
});

test("a need whose session is gone has no Open button; a waiting queue item opens the queue", () => {
  const html = draw(home({ needs: [
    { kind: "session", project: "p", text: "Stalled", id: "lab/x:1", target: "lab/x:1" },
    { kind: "queue", project: "p", text: "Review the PR", id: "fix-it" },
  ] }));
  assert.doesNotMatch(html, /data-open/);
  assert.match(html, /need k-turn.*need k-blocked.*<span class="nkind">Blocked<\/span>.*data-tab="queue">Open the queue/s);
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
  assert.match(html, /^<div class="cline warn">Prometheus: down<\/div>/);
  assert.match(html, /<span><b>queue<\/b> 1 running, 2 up next<\/span>/);
});

test("the summary leads, and a long list shows the cap with the rest folded", () => {
  const needs = Array.from({ length: 11 }, (_, i) => ({ kind: "nightly", project: "p", text: `red ${i}`, id: `r${i}` }));
  const html = draw(home({ needs, numbers: [{ label: "queue", value: "1 running" }], health: [{ name: "ci", level: "red" }] }));
  assert.ok(html.indexOf("Numbers") < html.indexOf("Health") && html.indexOf("Health") < html.indexOf("Needs you"), html);
  const fold = html.indexOf('<details class="cfold" data-k="home-needs"');
  assert.ok(fold > html.indexOf("red 7") && fold < html.indexOf("red 8"), "rows past the cap sit in the fold");
  assert.match(html, /<summary>\+3 more<\/summary>/);
  assert.doesNotMatch(draw(home({ needs: needs.slice(0, 8) })), /cfold" data-k="home-needs/);
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
