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
for (const f of ["ui.js", "md.js", "app.js", "waiting.js", "home.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const now = () => Math.floor(Date.now() / 1000);
function draw(home, agents = [], asks = []) {
  ctx.input = { home, agents, asks };
  return vm.runInContext(`st.agents = input.agents; st.asks = input.asks; hst.data = input.home; hst.err = null; drawHome(); $("home").innerHTML`, ctx);
}
const home = (o) => ({ needs: [], running: [], numbers: [], health: [], errors: [], shown: 8, ...o });

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

test("Needs you is grouped by kind, plans first, the server's order kept within a kind", () => {
  const plan = (t) => ({ target: t, short: t, session: t, project: "p", summary: t, items: [], actions: [], question: { kind: "plan", text: "do it" } });
  const html = draw(home({ needs: [
    { kind: "queue", project: "p", text: "blocked one", id: "q1" },
    { kind: "session", project: "p", text: "s1", id: "s1", target: "s1" },
    { kind: "ask", project: "p", text: "first ask", id: "x1" },
    { kind: "session", project: "p", text: "s2", id: "s2", target: "s2" },
    { kind: "ask", project: "p", text: "second ask", id: "x2" },
  ] }), [plan("s1"), plan("s2")]);
  const at = (s) => html.indexOf(s);
  assert.ok(at('data-t="s1"') < at('data-t="s2"') && at('data-t="s2"') < at("first ask") && at("first ask") < at("second ask") && at("second ask") < at("blocked one"), html);
  assert.match(html, /<span class="nchip k-plan">Plan to approve <b>2<\/b><\/span><span class="nchip k-ask">Question <b>2<\/b><\/span><span class="nchip k-blocked">Blocked <b>1<\/b><\/span>/);
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
