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
  window: { addEventListener() {} },
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
const sessionHtml = (a) => run("st.agents = [input.a]; st.asks = []; sessionCard(input.a)", { a });
const askHtml = (k, agents = []) => run("st.agents = input.agents; askCard(input.k)", { k, agents });

test("a session card leads with its kind, project and wait, then what the session is", () => {
  const html = sessionHtml(agent());
  assert.match(html, /^<div class="card need k-perm" data-t="lab:w-1" data-kind="tool">/);
  assert.match(html, /<div class="nband"><span class="nkind">Permission<\/span><span>p<\/span><span>5m<\/span><\/div>/);
  assert.match(html, /<div class="ntitle" title="lab:w-1">Wire the join<\/div>/);
  assert.match(html, /<button class="btn sm" data-open>Open session<\/button>/);
  assert.match(html, /<details class="cfold" data-k="ses:lab:w-1"><summary>Details<\/summary><dl>.*<dt>target<\/dt><dd>lab:w-1<\/dd>/s);
  assert.doesNotMatch(html, /class="meta"|class="open"/, "the old routing line and floating link are gone");
  assert.match(sessionHtml(agent({ question: { kind: "choice", text: "Which?", options: ["a"] } })), /need k-ask/);
  assert.match(sessionHtml(agent({ question: { kind: "free", text: "Go on?" } })), /need k-turn.*<span class="nkind">Your turn<\/span>/s);
});

test("a plan card puts its buttons above the whole plan, uncapped", () => {
  const html = sessionHtml(agent({ question: { kind: "plan", text: "# Plan\nstep" } }));
  assert.match(html, /need k-plan.*<span class="nkind">Plan to approve<\/span>/s);
  assert.match(html, /data-open>Open session<\/button><\/div><div class="q md planq">/, "buttons first, then the plan");
  assert.match(html, /placeholder="or tell it what to change"/);
});

test("a session card with no summary is titled by its plan, then its target; its estimate is on the line", () => {
  const eta = now() + 3600;
  const html = sessionHtml(agent({ summary: "", plan: "big-plan", phases: { done: 1, total: 3, eta_epoch: eta } }));
  assert.match(html, /<div class="ntitle"[^>]*>big-plan<\/div>/);
  assert.match(html, /<span>phase 1\/3<\/span><span><span title="estimate ">ETA /);
  assert.match(sessionHtml(agent({ summary: "", short: "" })), /<div class="ntitle"[^>]*>lab:w-1<\/div>/);
});

test("an ask card: first sentence as title, age, who filed it, then the rest of the question", () => {
  const html = askHtml(ask());
  assert.match(html, /^<div class="card need k-ask" data-id="a1"><div class="nband"><span class="nkind">Question<\/span><span>p<\/span><span>from shepherd<\/span><span>3h<\/span><\/div>/);
  assert.match(html, /<div class="ntitle">Ship it\?<\/div>/);
  assert.match(html, /<div class="q md">.*CI is green\..*<\/div>/s);
  assert.doesNotMatch(html, /<div class="q md">[^<]*<p>Ship it/, "the title sentence is not repeated");
  assert.match(html, /<button class="aopt rec" data-a="no"><span class="aok">no<\/span><span class="aow">recommended<\/span><\/button>/);
  assert.match(html, /<dt>id<\/dt><dd>a1<\/dd>/);
});

test("an ask names the live session that filed it, and says headless with neither", () => {
  assert.match(askHtml(ask({ session: "c1" }), [agent()]), /from w-1/);
  assert.match(askHtml(ask({ agent: "" })), /<span>p<\/span><span>headless<\/span>/);
});

test("an ask's options say what each does, the recommended one why, and its context shows", () => {
  const html = askHtml(ask({ notes: ["ship now", "wait a day"], why: "CI flaked twice", context: "the release is Friday" }));
  assert.match(html, /<button class="aopt" data-a="yes"><span class="aok">yes<\/span><span class="aon">ship now<\/span><\/button>/);
  assert.match(html, /<button class="aopt rec" data-a="no"><span class="aok">no<\/span><span class="aon">wait a day<\/span><span class="aow">recommended: CI flaked twice<\/span>/);
  assert.match(html, /<div class="actx md"><p>the release is Friday<\/p><\/div>/);
});

test("the judge's shadow call sits on the line, and only when it would act", () => {
  assert.doesNotMatch(askHtml(ask({ judge: "human" })), /judge would/);
  assert.match(askHtml(ask({ judge: "take-recommend" })), /<div class="cline">judge would take the recommendation \(no\)<\/div>/);
  assert.match(askHtml(ask({ judge: "answer:yes" })), /judge would answer "yes"<\/div>/);
});

test("an ask from an older server with no title shows the whole question as the title", () => {
  const html = askHtml(ask({ title: undefined, body: undefined }));
  assert.match(html, /<div class="ntitle">Ship it\? CI is green\.<\/div>/);
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
