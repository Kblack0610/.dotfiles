// Unit tests for the answer cards (.local/src/agent-web/static/waiting.js), run by
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
const box = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const doc = { getElementById: (id) => (id === "asks" ? box : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [] };
const ctx = vm.createContext({
  console,
  document: doc,
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
for (const f of ["ui.js", "md.js", "app.js", "waiting.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const now = () => Math.floor(Date.now() / 1000);
const agent = (o) => ({ target: "lab:w-1", short: "w-1", session: "c1", project: "p", summary: "Wire the join", items: [], actions: [],
  question: { kind: "tool", text: "Run `rm x`?" }, waiting_since: now() - 300, ...o });
const ask = (o) => ({ id: "a1", project: "p", kind: "question", question: "Ship it? CI is green.", title: "Ship it?", body: "CI is green.",
  options: ["yes", "no"], recommend: "no", session: "", agent: "shepherd", judge: "", created: now() - 3 * 3600, ...o });

function run(expr, input) {
  ctx.input = input;
  return vm.runInContext(expr, ctx);
}
const sessionHtml = (a, inQueue) => run("st.agents = [input.a]; st.asks = []; sessionCard(input.a, input.q)", { a, q: inQueue });
const askHtml = (k, agents = [], inQueue) => run("st.agents = input.agents; askCard(input.k, input.q)", { k, agents, q: inQueue });

test("a session card leads with what the session is, what it wants and for how long", () => {
  const html = sessionHtml(agent());
  assert.match(html, /<span class="ctitle" title="lab:w-1">Wire the join<\/span><span class="cchip waiting">Permission 5m<\/span>/);
  assert.match(html, /<div class="cline">p<\/div>/);
  assert.match(html, /<button class="btn sm" data-open>Open session<\/button>/);
  assert.match(html, /<details class="cfold" data-k="ses:lab:w-1"><summary>Details<\/summary><dl>.*<dt>target<\/dt><dd>lab:w-1<\/dd>/s);
  assert.doesNotMatch(html, /class="meta"|class="open"/, "the old routing line and floating link are gone");
});

test("a session card with no summary is titled by its plan, then its target; its estimate is on the line", () => {
  const eta = now() + 3600;
  const html = sessionHtml(agent({ summary: "", plan: "big-plan", phases: { done: 1, total: 3, eta_epoch: eta } }));
  assert.match(html, /<span class="ctitle"[^>]*>big-plan<\/span>/);
  assert.match(html, /phase 1\/3 &middot; <span title="estimate ">ETA /);
  assert.match(sessionHtml(agent({ summary: "", short: "" })), /<span class="ctitle"[^>]*>lab:w-1<\/span>/);
});

test("a session card on a queue row has no head of its own", () => {
  const html = sessionHtml(agent(), true);
  assert.match(html, /<div class="qask-h" title="lab:w-1">The session needs permission<\/div>/);
  assert.doesNotMatch(html, /class="chead"|data-open/);
});

test("an ask card: first sentence as title, age, who filed it, then the rest of the question", () => {
  const html = askHtml(ask());
  assert.match(html, /<span class="ctitle">Ship it\?<\/span><span class="cchip waiting">question 3h<\/span>/);
  assert.match(html, /<div class="cline">p &middot; from shepherd<\/div>/);
  assert.match(html, /<div class="q md">.*CI is green\..*<\/div>/s);
  assert.doesNotMatch(html, /<div class="q md">[^<]*<p>Ship it/, "the title sentence is not repeated");
  assert.match(html, /class="btn rec" data-a="no">no \(rec\)/);
  assert.match(html, /<dt>id<\/dt><dd>a1<\/dd>/);
});

test("an ask names the live session that filed it, and says headless with neither", () => {
  assert.match(askHtml(ask({ session: "c1" }), [agent()]), /from w-1/);
  assert.match(askHtml(ask({ agent: "" })), /<div class="cline">p &middot; headless<\/div>/);
});

test("the judge's shadow call sits on the line, and only when it would act", () => {
  assert.doesNotMatch(askHtml(ask({ judge: "human" })), /judge would/);
  assert.match(askHtml(ask({ judge: "take-recommend" })), /&middot; judge would take the recommendation \(no\)<\/div>/);
  assert.match(askHtml(ask({ judge: "answer:yes" })), /judge would answer "yes"<\/div>/);
});

test("an ask from an older server with no title shows the whole question as the title", () => {
  const html = askHtml(ask({ title: undefined, body: undefined }));
  assert.match(html, /<span class="ctitle">Ship it\? CI is green\.<\/span>/);
  assert.doesNotMatch(html, /class="q md"/);
});

test("a re-render keeps the reply being typed into a card", () => {
  const input = { value: "", focused: false, focus() { this.focused = true; } };
  const again = { dataset: { id: "a1" }, querySelector: () => input };
  const typing = { value: "half a reply", matches: () => true, closest: () => ({ dataset: { id: "a1" } }) };
  doc.activeElement = typing;
  doc.querySelectorAll = () => [again];
  let drawn = false;
  ctx.draw = () => { drawn = true; };
  vm.runInContext(`keepTyping("#asks .card", draw)`, ctx);
  doc.activeElement = undefined;
  doc.querySelectorAll = () => [];
  assert.ok(drawn);
  assert.equal(input.value, "half a reply");
  assert.ok(input.focused);
});

test("the page's scripts share one global scope with no top-level name declared twice", () => {
  // The browser runs each script in the page's one scope, so a second `const wst` throws there
  // and the rest of that script never runs. Compiled as one script, the same clash is an early
  // SyntaxError, found without running anything.
  const html = readFileSync(new URL("../src/index.html", dir), "utf8");
  const files = [...html.matchAll(/src="\/static\/([a-z]+\.js)/g)].map((m) => m[1]);
  assert.ok(files.includes("waiting.js") && files.length > 10, files.join(" "));
  assert.doesNotThrow(() => new vm.Script(files.map((f) => readFileSync(new URL(f, dir), "utf8")).join(";\n")));
});
