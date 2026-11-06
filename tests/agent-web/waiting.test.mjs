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

test("the judge's line says what it did or would do, a deferral included, with its rule and reason", () => {
  assert.match(askHtml(ask({ judge: "human", rule: "taste", reason: "only you know" })), /<div class="cline">Judge: deferred \(taste\) - only you know<\/div>/);
  assert.match(askHtml(ask({ judge: "take-recommend" })), /<div class="cline">Judge: would take the recommendation, type not proven<\/div>/);
  assert.match(askHtml(ask({ judge: "take-recommend", answered_by: "judge", rule: "ship_deploy", reason: "rules say fix failing CI yourself" })),
    /Judge: answered \(ship_deploy\) - rules say fix failing CI yourself<\/div>/);
  assert.match(askHtml(ask({ judge: "answer:yes" })), /Judge: would answer &quot;yes&quot;, type not proven<\/div>/);
  assert.doesNotMatch(askHtml(ask()), /Judge:/, "an ask never judged has no line");
});

test("an ask's Details fold carries the judge's fields and a Full log fold that reads the trace when opened", () => {
  const html = askHtml(ask({ judge: "human", rule: "taste", reason: "only you know", answered_by: "", answer_note: "" }));
  assert.match(html, /<details class="cfold" data-k="ask:a1"><summary>Details<\/summary><dl>.*<dt>judge<\/dt><dd>human<\/dd><dt>rule<\/dt><dd>taste<\/dd><dt>reason<\/dt><dd>only you know<\/dd><\/dl>/s);
  assert.doesNotMatch(html, /answered by/, "an empty field is left out");
  assert.match(html, /<details class="cfold" data-k="trace:a1"><summary>Full log<\/summary><div class="muted">Reading\.\.\.<\/div><\/details>/);
});

test("the Full log shows the timeline, the judge's call, a Langfuse link and the raw reply", () => {
  const t = { events: [{ at: "2026-11-05T10:00:00Z", event: "posted", detail: "by shepherd" }, { at: "2026-11-05T10:00:04Z", event: "judged", detail: "human (taste)" }],
    call: { id: "c9", agent: "ask-judge", "gen_ai.request.model": "m", duration_ms: 3100, cost_usd: 0.081, "gen_ai.usage.input_tokens": 2,
      "gen_ai.usage.output_tokens": 76, prompt: "judge.md", prompt_sha: "fffabcc123", exit: 0, raw: "{\"verdict\":\"<human>\"}" },
    langfuse: "https://lf.example/project/x/sessions/s1" };
  const html = run("traceHtml(input)", t);
  assert.match(html, /<dt>11-05 10:00:00 posted<\/dt><dd>by shepherd<\/dd><dt>11-05 10:00:04 judged<\/dt><dd>human \(taste\)<\/dd>/);
  assert.match(html, /<dt>model<\/dt><dd>m<\/dd><dt>time<\/dt><dd>3\.1s<\/dd><dt>cost<\/dt><dd>\$0\.08<\/dd><dt>tokens<\/dt><dd>2 in \/ 76 out<\/dd><dt>prompt<\/dt><dd>judge\.md fffabcc<\/dd><dt>exit<\/dt><dd>0<\/dd>/);
  assert.match(html, /<a href="https:\/\/lf\.example\/project\/x\/sessions\/s1" target="_blank" rel="noopener">Langfuse trace<\/a>/);
  assert.match(html, /<pre class="araw">\{&quot;verdict&quot;:&quot;&lt;human&gt;&quot;\}<\/pre>/);
  assert.doesNotMatch(run("traceHtml(input)", { ...t, langfuse: "javascript:alert(1)" }), /<a /, "only an http link is a link");
  assert.match(run("traceHtml(input)", { events: [], call: null }), /No judge call line for this ask\./);
});

test("the Full log reads its trace when you open it, not when a redraw re-inserts it open", async () => {
  const toggle = (open) => ({ target: { dataset: { k: "trace:a1" }, open } });
  run("globalThis.drew = 0; askst.trace = {}; askst.open['trace:a1'] = true");
  await run("askTrace(input, () => drew++)", toggle(true));
  assert.equal(run("drew"), 0, "a redraw of an open fold reads nothing");
  run("askst.open['trace:a1'] = false");
  await run("askTrace(input, () => drew++)", toggle(true));
  assert.equal(run("drew"), 1);
  assert.match(run("askst.trace.a1"), /No judge call line/);
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
