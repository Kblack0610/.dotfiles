"use strict";
// The answer cards for what waits on you: a live session's open dialog or permission prompt
// (read from its transcript by the server) and a pending ask, the one record of a question to
// the human. Home (home.js) draws them on its Needs you rows, the one place they are answered;
// a Queue row counts its own and links there. Answering a session's card types the answer into
// its pane.

// Which folds are open, by data-k: a section (`sec:<name>`) or a card's details.
const askst = { open: {} };

const refreshAsks = coalesce(async () => {
  st.asks = await api("/api/asks");
  renderBadge();
  if (st.tab === "home") renderHome();
  if (st.tab === "queue") renderQueueList();
});

const asking = () => st.agents.filter((a) => a.question);
function renderBadge() {
  const n = asking().length + st.asks.length;
  const b = n ? `<span class="badge">${n}</span>` : "";
  for (const id of ["ask-badge", "menu-badge"]) $(id).innerHTML = b;
}

// What each kind of open dialog is: its Needs you kind (the stripe and label, app.css `.need`).
const DIALOG = { choice: "ask", tool: "perm", plan: "plan" };
const dialog = (q) => DIALOG[q.kind] || "turn";

// Every kind of row that waits on the human, in the order its tally chips list them: the label each
// card leads with and its stripe class. Status hues stay status (dashboards rule 5): blocked is
// amber, failing is red; the three dialog kinds take categorical colours.
const NEED_KINDS = {
  plan: "Plan to approve",
  ask: "Question",
  perm: "Permission",
  turn: "Your turn",
  blocked: "Blocked",
  red: "Failing",
};
const NEED_ORDER = Object.keys(NEED_KINDS);
// The band a Needs you card opens with: its kind, then where and how long, as quiet text.
const needBand = (k, meta) =>
  `<div class="nband"><span class="nkind">${NEED_KINDS[k]}</span>${meta.filter(Boolean).map((m) => `<span>${m}</span>`).join("")}</div>`;

// A live session's open dialog: what the session is, what it wants and for how long, then the
// question and its answers. The tmux target is the title's tooltip and sits in Details. A plan
// shows whole, its buttons above it, so a long plan never hides how to approve it.
function sessionCard(a) {
  const q = a.question, k = dialog(q);
  let opts = "";
  if (q.kind === "choice") opts = q.options.map((o, i) => `<button class="btn" data-k="${i + 1}">${i + 1}. ${esc(o)}</button>`).join("");
  if (q.kind === "tool") opts = ["1", "2", "3"].map((k) => `<button class="btn" data-k="${k}">${k}</button>`).join("");
  if (q.kind === "plan") opts = approveButtons(a);
  const body = `<div class="q md${q.kind === "plan" ? " planq" : ""}">${md(q.text)}</div>`;
  const reply = `<input placeholder="${q.kind === "plan" ? "or tell it what to change" : "reply in this session"}" data-free><button class="btn" data-reply>Send</button>`;
  const p = a.phases;
  const band = needBand(k, [esc(a.project), a.waiting_since ? ago(a.waiting_since) : "", p ? `phase ${p.done}/${p.total}` : "", etaText(p), a.attached ? "you are attached" : ""]);
  const title = `<div class="ntitle" title="${esc(a.target)}">${esc(a.summary || a.plan || a.short || a.target)}</div>`;
  const more = cfold(`ses:${a.target}`, "Details", facts([["target", a.target], ["session", a.session], ["account", a.account],
    ["plan", a.plan], ["next phase", p && p.next]]), askst.open);
  const open = `<button class="btn sm" data-open>Open session</button>`;
  const lead = q.kind === "plan" ? `<div class="opts">${opts}${open}</div>${body}<div class="opts">${reply}</div>`
    : `${body}<div class="opts">${opts}${open}${reply}</div>`;
  return `<div class="card need k-${k}" data-t="${esc(a.target)}" data-kind="${esc(q.kind)}">${band}${title}${lead}${more}<div class="err"></div></div>`;
}

// The judge's verdict as one line, in the words agent-ask's judge_line puts on the CLI card: what
// it did or would do, the rule that decided it, then its reason. A deferral shows too, so the
// card says why the judge left the ask to you. Empty only for an ask it never judged.
function judgeText(a) {
  const j = a.judge || "";
  if (!j) return "";
  const live = a.answered_by === "judge", ans = j.startsWith("answer:") ? `"${j.slice(7)}"` : "";
  const what = j === "human" ? "deferred"
    : j === "take-recommend" ? (live ? "answered" : "would take the recommendation")
    : ans ? `${live ? "answered" : "would answer"} ${ans}` : j;
  return esc(`Judge: ${what}${a.rule ? ` (${a.rule})` : ""}${a.reason ? ` - ${a.reason}` : ""}`);
}

// An ask's Full log (agent-ask trace --json), read when its fold opens (askTrace) and kept here by
// id, so a redraw shows the last read instead of reading again: the timeline, then the judge's
// call (model, time, cost, prompt sha) with its Langfuse session and raw reply.
askst.trace = {};
function traceHtml(t) {
  const ev = (t.events || []).map((e) => [`${(e.at || "").slice(5, 10)} ${(e.at || "").slice(11, 19)} ${e.event}`, e.detail]);
  const c = t.call;
  if (!c) return facts(ev) + '<div class="muted">No judge call line for this ask.</div>';
  const model = c["gen_ai.response.model"] || c["gen_ai.request.model"];
  const tok = c["gen_ai.usage.output_tokens"] != null ? `${c["gen_ai.usage.input_tokens"] || 0} in / ${c["gen_ai.usage.output_tokens"]} out` : "";
  const call = facts([["call", c.id], ["agent", c.agent], ["model", model],
    ["time", c.duration_ms != null ? `${(c.duration_ms / 1000).toFixed(1)}s` : ""],
    ["cost", c.cost_usd != null ? `$${c.cost_usd.toFixed(2)}` : ""], ["tokens", tok],
    ["prompt", c.prompt_sha ? `${c.prompt || ""} ${c.prompt_sha.slice(0, 7)}` : ""], ["exit", c.exit != null ? String(c.exit) : ""]]);
  const lf = /^https?:\/\//.test(t.langfuse || "") ? `<div class="cline"><a href="${esc(t.langfuse)}" target="_blank" rel="noopener">Langfuse trace</a></div>` : "";
  return facts(ev) + call + lf + (c.raw ? `<pre class="araw">${esc(c.raw)}</pre>` : "");
}
// The toggle of an ask's Full log fold (data-k "trace:<id>"), called before askst.open records
// it: opening it reads the trace again and redraws through `draw`; a read that fails shows why in
// the fold. A redraw re-inserts an open fold, which fires toggle too: askst.open already says
// open then, so it reads nothing, or every redraw would read again.
async function askTrace(e, draw) {
  const k = e.target.dataset && e.target.dataset.k;
  if (!k || !k.startsWith("trace:") || !e.target.open || askst.open[k]) return;
  const id = k.slice(6);
  try { askst.trace[id] = traceHtml(await api(`/api/asks/${encodeURIComponent(id)}/trace`)); }
  catch (err) { askst.trace[id] = `<div class="err">${esc(err.message)}</div>`; }
  draw();
}

// An ask's answers, one button per option with what it does (agent-ask `--options a=...`), the
// recommended one marked with its why (`--why`), then a free answer.
function askOptions(a) {
  const notes = a.notes || [];
  const rows = a.options.map((o, i) => {
    const rec = o === a.recommend;
    const note = notes[i] ? `<span class="aon">${esc(notes[i])}</span>` : "";
    const why = rec ? `<span class="aow">recommended${a.why ? ": " + esc(a.why) : ""}</span>` : "";
    return `<button class="aopt${rec ? " rec" : ""}" data-a="${esc(o)}"><span class="aok">${esc(o)}</span>${note}${why}</button>`;
  }).join("");
  return `<div class="aopts">${rows}</div><div class="opts"><input placeholder="or type an answer" data-free><button class="btn" data-send>Answer</button></div>`;
}

// One pending ask, answered through agent-ask: its first sentence as the title, how long it has
// waited, who filed it, then the rest of the question and its context, which the options lean on.
// `held` is what the ask holds, as Home's ranked row says it ("holds session, 2 phases").
function askCard(a, held = "") {
  const owner = st.agents.find((x) => a.session && x.session === a.session);
  const from = owner ? owner.short || owner.target : a.agent;
  const judge = judgeText(a);
  // What follows the question: its context, the judge's view, then the answers.
  const tail = `${a.context ? `<div class="actx md">${md(a.context)}</div>` : ""}${judge ? `<div class="cline">${judge}</div>` : ""}${askOptions(a)}`;
  const kind = a.kind && a.kind !== "question" ? esc(a.kind) : "";
  const band = needBand("ask", [esc(a.project), from ? `from ${esc(from)}` : "headless", kind, a.created ? ago(a.created) : "", held]);
  const body = a.title ? a.body : "";
  const log = cfold(`trace:${a.id}`, "Full log", askst.trace[a.id] || '<div class="muted">Reading...</div>', askst.open);
  const more = cfold(`ask:${a.id}`, "Details", facts([["id", a.id], ["kind", a.kind], ["filed by", a.agent], ["claude session", a.session],
    ["judge", a.judge], ["rule", a.rule], ["reason", a.reason], ["answered by", a.answered_by], ["answer note", a.answer_note]]) + log, askst.open);
  return `<div class="card need k-ask" data-id="${esc(a.id)}">${band}<div class="ntitle">${esc(a.title || a.question)}</div>` +
    `${body ? `<div class="q md">${md(body)}</div>` : ""}${tail}${more}<div class="err"></div></div>`;
}

// A session card answers through the session's own pane, so the answer lands in that
// conversation. A typed reply to a dialog first closes it with Escape; the text then
// arrives as the human's next message.
async function answerSession(card, e) {
  const t = card.dataset.t;
  if (e.target.dataset.open !== undefined) {
    const a = st.agents.find((x) => x.target === t);
    if (a) { setTab("sessions"); select(a); }
    return;
  }
  const key = e.target.dataset.k;
  const text = e.target.dataset.reply !== undefined ? card.querySelector("[data-free]").value : "";
  if (!key && !text.trim()) return;
  if (key) await post("/api/send", { t, key });
  else {
    if (card.dataset.kind !== "text") await post("/api/send", { t, key: "Escape" });
    await post("/api/send", { t, text });
  }
  card.querySelector("[data-free]").value = "";
}

// A click inside a session card or an ask card, on Home or a queue row.
async function answerCard(card, e) {
  if (card.dataset.t) {
    try { await answerSession(card, e); card.querySelector(".err").textContent = ""; }
    catch (err) { card.querySelector(".err").textContent = err.message; }
    return;
  }
  const opt = e.target.closest("[data-a]");
  let answer = opt && opt.dataset.a;
  if (e.target.dataset.send !== undefined) answer = card.querySelector("[data-free]").value;
  if (!answer || !answer.trim()) return;
  try { await post("/api/asks/answer", { id: card.dataset.id, answer }); refreshAsks(); }
  catch (err) { card.querySelector(".err").textContent = err.message; }
}

function answerOnEnter(e) {
  if (e.key !== "Enter" || !e.target.matches("[data-free]")) return;
  e.preventDefault();
  const btn = e.target.parentElement.querySelector("[data-reply], [data-send]");
  if (btn) btn.click();
}
