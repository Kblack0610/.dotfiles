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
for (const f of ["ui.js", "md.js", "app.js", "waiting.js", "table.js", "actions.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const now = () => Math.floor(Date.now() / 1000);
const KINDS = { perm: "Permission", turn: "Your turn", plan: "Plan to approve" };
const agent = (o) => ({ target: "lab:w-1", short: "w-1", session: "c1", project: "p", summary: "Wire the join", items: [], actions: [],
  question: { kind: "tool", text: "Run `rm x`?" }, wrote: now() - 300, need: { kind: "perm", label: "Permission" }, ...o });
// An ask as hub_core::boards::Ask serves it: `session` is the tmux session that filed it,
// `claude_session` the Claude session, `judge_line` the server's wording of the judge's verdict.
const ask = (o) => ({ id: "a1", project: "p", kind: "question", question: "Ship it? CI is green.", title: "Ship it?", body: "CI is green.",
  options: ["yes", "no"], recommend: "no", session: "shepherd", claude_session: "", judge: "", judge_line: "", created: now() - 3 * 3600, ...o });
// A Needs you row for an ask: the label and holds line come from hub_core::home::NeedRow.
const needRow = (a, o) => ({ ask: a, label: "Question", holds_line: "", ...o });

function run(expr, input) {
  ctx.input = input;
  return vm.runInContext(expr, ctx);
}
const sessionHtml = (a, k = "perm") => run("st.agents = [input]; sessionCard(input)",{ ...a, need: { kind: k, label: KINDS[k] } });
const askHtml = (a, agents = [], row = {}) => run("st.agents = input.agents; askCard(input.n)", { n: needRow(a, row), agents });

test("a session card leads with its kind, project and wait, then what the session is", () => {
  const html = sessionHtml(agent());
  assert.match(html, /^<div class="card need k-perm" data-t="lab:w-1" data-kind="tool">/);
  assert.match(html, /<div class="nband"><span class="nkind">Permission<\/span><span>p<\/span><span>5m<\/span><\/div>/);
  assert.match(html, /<div class="ntitle" title="lab:w-1">Wire the join<\/div>/);
  assert.match(html, /<button class="btn sm" data-open>Open session<\/button>/);
  assert.match(html, /<details class="cfold" data-k="ses:lab:w-1"><summary>Details<\/summary><dl>.*<dt>target<\/dt><dd>lab:w-1<\/dd>/s);
  assert.doesNotMatch(html, /class="meta"|class="open"/, "the old routing line and floating link are gone");
  assert.match(sessionHtml(agent({ question: { kind: "free", text: "Go on?" } }), "turn"), /need k-turn.*<span class="nkind">Your turn<\/span>/s);
});

test("a plan card puts its buttons above the whole plan, uncapped", () => {
  const html = sessionHtml(agent({ question: { kind: "plan", text: "# Plan\nstep" } }), "plan");
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
  assert.match(askHtml(ask({ claude_session: "c1" }), [agent()]), /from w-1/);
  assert.match(askHtml(ask({ session: "" })), /<span>p<\/span><span>headless<\/span>/);
});

test("an ask's band shows the server's label and what it holds, nothing the page words itself", () => {
  const html = askHtml(ask(), [], { label: "Decision", holds_line: "holds ar-7" });
  assert.match(html, /<span class="nkind">Decision<\/span>.*<span>holds ar-7<\/span><\/div>/s);
  assert.doesNotMatch(askHtml(ask()), /holds/, "a row that holds nothing says nothing");
});

test("an ask's options say what each does, the recommended one why, and its context shows", () => {
  const html = askHtml(ask({ notes: ["ship now", "wait a day"], why: "CI flaked twice", context: "the release is Friday" }));
  assert.match(html, /<button class="aopt" data-a="yes"><span class="aok">yes<\/span><span class="aon">ship now<\/span><\/button>/);
  assert.match(html, /<button class="aopt rec" data-a="no"><span class="aok">no<\/span><span class="aon">wait a day<\/span><span class="aow">recommended: CI flaked twice<\/span>/);
  assert.match(html, /<div class="actx md"><p>the release is Friday<\/p><\/div>/);
});

test("an ask's preview images show between its context and its answers, each served by the ask", () => {
  const html = askHtml(ask({ context: "a mockup", previews: ["shot.png", "b.jpg"] }));
  assert.match(html, /<\/div><div class="aprev"><a href="\/api\/asks\/a1\/preview\/0"[^>]*><img src="\/api\/asks\/a1\/preview\/0" alt="shot.png"[^>]*><\/a><a href="\/api\/asks\/a1\/preview\/1".*<\/div><div class="aopts">/s);
  assert.doesNotMatch(askHtml(ask()), /aprev/, "no previews, no strip");
});

test("the judge's line is the server's wording, shown as it came, and an ask never judged has none", () => {
  // The wording (answered, would answer, assumes at, deferred) is hub_core::boards::Ask::judge_words,
  // tested there; the page only draws the line.
  assert.match(askHtml(ask({ judge: "human", judge_line: "Judge: deferred (taste) - only you know" })), /<div class="cline">Judge: deferred \(taste\) - only you know<\/div>/);
  assert.match(askHtml(ask({ judge_line: "Judge: would answer \"yes\", type not proven" })), /Judge: would answer &quot;yes&quot;, type not proven<\/div>/);
  assert.doesNotMatch(askHtml(ask()), /Judge:/);
});

test("an ask's Details fold carries the judge's fields and a Full log fold that reads the trace when opened", () => {
  const html = askHtml(ask({ judge: "human", rule: "taste", reason: "only you know", answered_by: "", answer_note: "" }));
  assert.match(html, /<details class="cfold" data-k="ask:a1"><summary>Details<\/summary><dl>.*<dt>judge<\/dt><dd>human<\/dd><dt>rule<\/dt><dd>taste<\/dd><dt>reason<\/dt><dd>only you know<\/dd><\/dl>/s);
  assert.doesNotMatch(html, /answered by/, "an empty field is left out");
  assert.match(html, /<details class="cfold" data-k="trace:a1"><summary>Full log<\/summary><div class="muted">Reading\.\.\.<\/div><\/details>/);
});

test("the Full log draws the server's timeline, call rows, Langfuse link and raw reply", () => {
  // The words (the stamp, the model, the cost, the tokens, the http-only link) are
  // hub_core::boards::ask_trace, tested there; the page lays the rows out.
  const t = { timeline: [["11-05 10:00:00 posted", "by shepherd"], ["11-05 10:00:04 judged", "human (taste)"]],
    call: [["model", "m"], ["time", "3.1s"], ["cost", "$0.08"]], langfuse: "https://lf.example/project/x/sessions/s1", raw: "{\"verdict\":\"<human>\"}" };
  const html = run("traceHtml(input)", t);
  assert.match(html, /<dt>11-05 10:00:00 posted<\/dt><dd>by shepherd<\/dd><dt>11-05 10:00:04 judged<\/dt><dd>human \(taste\)<\/dd>/);
  assert.match(html, /<dt>model<\/dt><dd>m<\/dd><dt>time<\/dt><dd>3\.1s<\/dd><dt>cost<\/dt><dd>\$0\.08<\/dd>/);
  assert.match(html, /<a href="https:\/\/lf\.example\/project\/x\/sessions\/s1" target="_blank" rel="noopener">Langfuse trace<\/a>/);
  assert.match(html, /<pre class="araw">\{&quot;verdict&quot;:&quot;&lt;human&gt;&quot;\}<\/pre>/);
  assert.doesNotMatch(run("traceHtml(input)", { ...t, langfuse: null }), /<a /, "no link from the server, no link");
  assert.match(run("traceHtml(input)", { timeline: [], call: null, langfuse: null, raw: "" }), /No judge call line for this ask\./);
});

test("the Full log reads its trace when you open it, not when a redraw re-inserts it open", async () => {
  const toggle = (open) => ({ target: { dataset: { k: "trace:a1" }, open } });
  const fetch0 = ctx.fetch;
  ctx.fetch = async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({ timeline: [], call: null, langfuse: null, raw: "" }) });
  run("globalThis.drew = 0; askst.trace = {}; askst.open['trace:a1'] = true");
  await run("askTrace(input, () => drew++)", toggle(true));
  assert.equal(run("drew"), 0, "a redraw of an open fold reads nothing");
  run("askst.open['trace:a1'] = false");
  await run("askTrace(input, () => drew++)", toggle(true));
  assert.equal(run("drew"), 1);
  assert.match(run("askst.trace.a1"), /No judge call line/);
  ctx.fetch = fetch0;
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

test("a card mid-send draws locked, saying what it sent, and a redraw keeps it so", () => {
  run('askst.sending["ask:a1"] = \'"yes"\'', {});
  const html = askHtml(ask());
  run('delete askst.sending["ask:a1"]', {});
  assert.match(html, /^<div class="card need k-ask sending" data-id="a1">/);
  assert.match(html, /<div class="cstat" role="status"><span class="spin"><\/span>Sending &quot;yes&quot;\.\.\.<\/div>/);
  assert.match(askHtml(ask()), /^<div class="card need k-ask" data-id="a1">.*<div class="cstat" role="status"><\/div><div class="err"><\/div><\/div>$/s);
});

test("answering an ask locks its card until the server replies, takes no second click, and a failure unlocks it with why", async () => {
  const cls = new Set(), attrs = {}, stat = { innerHTML: "" }, err = { textContent: "" }, reply = { readOnly: false };
  const card = { dataset: { id: "a1" }, classList: { toggle: (c, on) => (on ? cls.add(c) : cls.delete(c)) },
    setAttribute: (k, v) => { attrs[k] = v; }, querySelectorAll: () => [reply],
    querySelector: (q) => (q === ".cstat" ? stat : q === ".err" ? err : null) };
  const click = { target: { dataset: {}, closest: () => ({ dataset: { a: "yes" } }) } };
  let posts = 0, release;
  const reads = [];
  const fetch0 = ctx.fetch;
  ctx.fetch = (path) => (path === "/api/asks/answer"
    ? (posts++, new Promise((res) => { release = res; }))
    : (reads.push(path), Promise.resolve({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => (path === "/api/home/waiting" ? { count: 1, href: "#home" } : []) })));
  doc.querySelectorAll = () => [card];
  ctx.card = card; ctx.click = click;
  try {
    const first = vm.runInContext("answerCard(card, click)", ctx);
    assert.ok(cls.has("sending"));
    assert.equal(attrs["aria-busy"], "true");
    assert.ok(reply.readOnly, "the reply input takes no typing while sending");
    assert.match(stat.innerHTML, /Sending &quot;yes&quot;\.\.\./);
    await vm.runInContext("answerCard(card, click)", ctx);
    assert.equal(posts, 1, "a second click while sending posts nothing");
    release({ ok: false, status: 400, statusText: "Bad Request", headers: { get: () => "text/plain" }, text: async () => "no ask 'a1'" });
    await first;
    assert.ok(!cls.has("sending"));
    assert.equal(attrs["aria-busy"], "false");
    assert.ok(!reply.readOnly);
    assert.equal(stat.innerHTML, "");
    assert.match(err.textContent, /no ask 'a1'/, "the failure says why");

    run('st.tab = "sessions"; st.waiting = undefined');
    const ok = vm.runInContext("answerCard(card, click)", ctx);
    release({ ok: true, status: 204, headers: { get: () => "" } });
    await ok;
    await vm.runInContext("refreshAsks()", ctx);
    assert.ok(reads.includes("/api/home/waiting"), "an answered ask re-reads the server's count and Needs you: " + reads);
    assert.equal(run('askst.sending["ask:a1"]'), undefined);
  } finally {
    doc.querySelectorAll = () => [];
    ctx.fetch = fetch0;
  }
});

test("a sent plan approval draws its button busy, and a failed one shows why beside it", () => {
  const a = agent({ actions: ["approve-plan"] });
  run('askst.sending["ses:lab:w-1"] = "the plan approval"', {});
  assert.match(run("approveButtons(input)", a), /^<button class="btn sm primary" disabled><span class="spin"><\/span>Approving\.\.\.<\/button>$/);
  run('delete askst.sending["ses:lab:w-1"]; st.approveErr["lab:w-1"] = "Could not send"', {});
  assert.match(run("approveButtons(input)", a), /^<span class="err">Could not send<\/span><button class="btn sm primary" data-approve="lab:w-1">Approve plan<\/button>$/);
  run('delete st.approveErr["lab:w-1"]', {});
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

test("the badge is the server's count, `?` when the read failed, and blank only on a true 0", () => {
  const spots = { "ask-badge": { innerHTML: "x" }, "menu-badge": { innerHTML: "x" }, "wait-badge": { innerHTML: "x" } };
  const getById = doc.getElementById;
  doc.getElementById = (id) => spots[id] || getById(id);
  try {
    const badge = (w) => { run("st.waiting = input.w; renderBadge()", { w }); return spots["ask-badge"].innerHTML; };
    assert.equal(badge({ count: 2, href: "#home" }), '<span class="badge">2</span>');
    assert.equal(spots["menu-badge"].innerHTML, '<span class="badge">2</span>', "the menu badge says the same");
    assert.equal(badge({ count: 5, sessions: 3, href: "#home" }), '<span class="badge">5</span>');
    assert.equal(spots["wait-badge"].innerHTML, '<span class="badge">3</span>', "Sessions' tab shows Waiting.sessions, not a count of its own");
    assert.equal(badge({ count: 0, href: "#home" }), "");
    assert.match(badge(null), /^<span class="badge" title="[^"]+">\?<\/span>$/, "a failed read is never drawn as 0");
  } finally {
    doc.getElementById = getById;
  }
});

test("a failed count read shows `?`, and the next good read shows the count", async () => {
  const fetch0 = ctx.fetch;
  try {
    ctx.fetch = async () => ({ ok: false, status: 502, statusText: "Bad Gateway", headers: { get: () => "text/plain" }, text: async () => "agent-ask failed" });
    await run("refreshWaiting()");
    assert.equal(run("st.waiting"), null);
    ctx.fetch = async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({ count: 2, href: "#home" }) });
    await run("refreshWaiting()");
    assert.equal(run("st.waiting.count"), 2);
  } finally {
    ctx.fetch = fetch0;
  }
});
