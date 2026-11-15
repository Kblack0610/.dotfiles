"use strict";
// The answer cards for what waits on you: a live session's open dialog or permission prompt
// (read from its transcript by the server) and a pending ask, the one record of a question to
// the human. Home (home.js) draws them on its Needs you rows, an opened Queue row draws its own
// session's, and a session's conversation pins its dialog; each answers in place. Answering a
// session's card types the answer into its pane.

// Which folds are open, by data-k: a section (`sec:<name>`) or a card's details. `sending` holds
// the answer in flight per card key (`ask:<id>`, `ses:<target>`), so a redraw mid-send keeps the
// card locked and saying what it sent.
const askst = { open: {}, sending: {} };

function drawAsks() {
  renderBadge();
  if (st.tab === "home") renderHome();
  if (st.tab === "queue") qst.render();
}
const refreshAsks = coalesce(async () => {
  [st.asks, st.parked] = await Promise.all([api("/api/asks"), api("/api/asks/parked").catch(() => st.parked)]);
  drawAsks();
});

const asking = () => st.agents.filter((a) => a.question);
function renderBadge() {
  // One session holding an ask and an open dialog is one thing to answer, as on Home.
  const asked = new Set(asking().map((a) => a.session));
  const n = asking().length + st.asks.filter((a) => !a.session || !asked.has(a.session)).length;
  const b = n ? `<span class="badge">${n}</span>` : "";
  for (const id of ["ask-badge", "menu-badge"]) $(id).innerHTML = b;
}

// Every kind of row that waits on the human (hub_core::home::NeedKind decides a row's, and its
// chips): the label a row and its card lead with, and the card's stripe class. Status hues stay
// status (dashboards rule 5): blocked is amber, failing is red; the three dialog kinds take
// categorical colours.
const NEED_KINDS = {
  stopped: "Stopped",
  plan: "Plan to approve",
  ask: "Question",
  perm: "Permission",
  turn: "Your turn",
  blocked: "Blocked",
  todo: "To do",
  red: "Failing",
};
// The band a Needs you card opens with: its kind, then where and how long, as quiet text.
const needBand = (k, meta) =>
  `<div class="nband"><span class="nkind">${NEED_KINDS[k]}</span>${meta.filter(Boolean).map((m) => `<span>${m}</span>`).join("")}</div>`;

// The Needs you kind of a session's open dialog, as hub-core's home::NeedKind::of_dialog gives it.
const dialogKind = (q) => ({ choice: "ask", tool: "perm", plan: "plan" })[q.kind] || "turn";

// A live session's open dialog: what the session is, what it wants and for how long, then the
// question and its answers. `k` is its row's kind. The tmux target is the title's tooltip and sits
// in Details. A plan shows whole, its buttons above it, so a long plan never hides how to approve
// it. `here` is a card drawn where an Open button already is (the session's own conversation, a
// Queue row's detail), so it draws none.
function sessionCard(a, k, here = false) {
  const q = a.question;
  let opts = "";
  if (q.kind === "choice") opts = q.options.map((o, i) => `<button class="btn" data-k="${i + 1}">${i + 1}. ${esc(o)}</button>`).join("");
  if (q.kind === "tool") opts = ["1", "2", "3"].map((k) => `<button class="btn" data-k="${k}">${k}</button>`).join("");
  if (q.kind === "plan") opts = approveButtons(a);
  const body = `<div class="q md${q.kind === "plan" ? " planq" : ""}">${md(q.text)}</div>`;
  const reply = `<input placeholder="${q.kind === "plan" ? "or tell it what to change" : "reply in this session"}" data-free><button class="btn" data-reply>Send</button>`;
  const p = a.phases;
  const band = needBand(k, [esc(a.project), a.wrote ? waited(a.wrote) : "", p ? `phase ${p.done}/${p.total}` : "", etaText(p), a.attached ? "you are attached" : ""]);
  const title = `<div class="ntitle" title="${esc(a.target)}">${esc(a.summary || a.plan || a.short || a.target)}</div>`;
  const more = cfold(`ses:${a.target}`, "Details", facts([["target", a.target], ["session", a.session], ["account", a.account],
    ["plan", a.plan], ["next phase", p && p.next]]), askst.open);
  const open = here ? "" : `<button class="btn sm" data-open>Open session</button>`;
  const lead = q.kind === "plan" ? `<div class="opts">${opts}${open}</div>${body}<div class="opts">${reply}</div>`
    : `${body}<div class="opts">${opts}${open}${reply}</div>`;
  return `<div class="card need k-${k}${sendingCls(`ses:${a.target}`)}" data-t="${esc(a.target)}" data-kind="${esc(q.kind)}">${band}${title}${lead}${more}${statusLine(`ses:${a.target}`)}</div>`;
}

// The judge's verdict as one line, in the words agent-ask's judge_line puts on the CLI card: what
// it did or would do, the rule that decided it, then its reason. A deferral shows too, so the
// card says why the judge left the ask to you, and an armed ask says when its answer goes out.
// Empty only for an ask it never judged.
function judgeText(a) {
  const j = a.judge || "";
  if (!j) return "";
  const live = a.answered_by === "judge", ans = j.startsWith("answer:") ? `"${j.slice(7)}"` : "";
  const unproven = ", type not proven";
  const assumes = a.assume_at ? `assumes ${ans || `"${a.recommend}"`} at ${a.assume_at.slice(11, 16)} unless you reply` : "";
  const what = j === "human" ? "deferred"
    : j === "take-recommend" ? (live ? "answered" : assumes || `would take the recommendation${unproven}`)
    : ans ? (live ? `answered ${ans}` : assumes || `would answer ${ans}${unproven}`) : j;
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
  // Park takes it off Needs you until its revisit date (agent-ask park, by its item's priority).
  return `<div class="aopts">${rows}</div><div class="opts"><input placeholder="or type an answer" data-free><button class="btn" data-send>Answer</button>` +
    `<button class="btn" data-park title="off Needs you until its revisit date, set by its item's priority">Park</button></div>`;
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
  const band = needBand("ask", [esc(a.project), from ? `from ${esc(from)}` : "headless", kind, a.created ? waited(a.created) : "", held]);
  const body = a.title ? a.body : "";
  const log = cfold(`trace:${a.id}`, "Full log", askst.trace[a.id] || '<div class="muted">Reading...</div>', askst.open);
  const more = cfold(`ask:${a.id}`, "Details", facts([["id", a.id], ["kind", a.kind], ["filed by", a.agent], ["claude session", a.session],
    ["judge", a.judge], ["rule", a.rule], ["reason", a.reason], ["answered by", a.answered_by], ["answer note", a.answer_note]]) + log, askst.open);
  return `<div class="card need k-ask${sendingCls(`ask:${a.id}`)}" data-id="${esc(a.id)}">${band}<div class="ntitle">${esc(a.title || a.question)}</div>` +
    `${body ? `<div class="q md">${md(body)}</div>` : ""}${tail}${more}${statusLine(`ask:${a.id}`)}</div>`;
}

// A session card answers through the session's own pane, so the answer lands in that
// conversation. A typed reply to a dialog first closes it with Escape; the text then
// arrives as the human's next message.
async function answerSession(card, e) {
  const t = card.dataset.t;
  if (e.target.dataset.open !== undefined) {
    const a = st.agents.find((x) => x.target === t);
    if (a) openAgent(a);
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

// A card from the click to the server's reply: locked (app.css .card.sending), its status line
// saying what went out, so a slow answer never reads as a dead click. A failure unlocks it and
// says why; a sent ask leaves the list at once, as the server has already closed it.
const sendingCls = (key) => (askst.sending[key] ? " sending" : "");
const statusLine = (key) => askst.sending[key]
  ? `<div class="cstat" role="status"><span class="spin"></span>Sending ${esc(askst.sending[key])}...</div><div class="err"></div>`
  : `<div class="cstat" role="status"></div><div class="err"></div>`;
// Every drawn card for `key` (a session's card can show on Home and pinned in its conversation),
// found afresh, since a redraw mid-send replaces the clicked one.
const cardKey = (c) => (c.dataset.t ? `ses:${c.dataset.t}` : `ask:${c.dataset.id}`);
const cardsFor = (key) => [...document.querySelectorAll(".card[data-t], .card[data-id]")].filter((c) => cardKey(c) === key);
function markSending(key, what, error = "") {
  if (what) askst.sending[key] = what; else delete askst.sending[key];
  for (const card of cardsFor(key)) {
    card.classList.toggle("sending", !!what);
    card.setAttribute("aria-busy", what ? "true" : "false");
    const s = card.querySelector(".cstat"), x = card.querySelector(".err");
    if (s) s.innerHTML = what ? `<span class="spin"></span>Sending ${esc(what)}...` : "";
    if (x) x.textContent = error;
    // Typing stays out too: a reply input is cleared once its send returns.
    for (const i of card.querySelectorAll("input")) i.readOnly = !!what;
  }
}
const quoted = (t) => `"${t.length > 40 ? `${t.slice(0, 40)}...` : t}"`;

// What a click inside a session card sends, as its status line names it; empty sends nothing.
function sessionSend(card, e) {
  if (e.target.dataset.k) return `option ${e.target.dataset.k}`;
  if (e.target.dataset.reply === undefined) return "";
  const text = card.querySelector("[data-free]").value.trim();
  return text ? quoted(text) : "";
}

// A click inside a session card or an ask card, on Home or a queue row. A card already sending
// takes no second answer.
async function answerCard(card, e) {
  const key = cardKey(card);
  if (askst.sending[key]) return;
  if (card.dataset.t) {
    const what = e.target.dataset.open !== undefined ? "" : sessionSend(card, e);
    if (what) markSending(key, what);
    try { await answerSession(card, e); if (what) markSending(key, ""); }
    catch (x) { markSending(key, "", x.message); }
    return;
  }
  if (e.target.dataset.park !== undefined) { await parkAsk(card.dataset.id, false); return; }
  const opt = e.target.closest("[data-a]");
  let answer = opt && opt.dataset.a;
  if (e.target.dataset.send !== undefined) answer = card.querySelector("[data-free]").value;
  if (!answer || !answer.trim()) return;
  const id = card.dataset.id;
  markSending(key, quoted(answer.trim()));
  try { await post("/api/asks/answer", { id, answer }); }
  catch (x) { markSending(key, "", x.message); return; }
  // Answered: drop it here rather than wait on a refetch that may be queued behind another.
  delete askst.sending[key];
  st.asks = st.asks.filter((a) => a.id !== id);
  drawAsks();
  refreshAsks();
}

// Park an ask off Needs you, or put a parked one back; either way it moves between the lists.
async function parkAsk(id, unpark) {
  const key = `ask:${id}`;
  if (askst.sending[key]) return;
  markSending(key, unpark ? "unpark" : "park");
  askst.parkErr = "";
  try { await post("/api/asks/park", { id, unpark }); }
  catch (x) { markSending(key, "", x.message); if (unpark) { askst.parkErr = x.message; drawAsks(); } return; }
  delete askst.sending[key];
  st.asks = st.asks.filter((a) => a.id !== id);
  st.parked = st.parked.filter((a) => a.id !== id);
  drawAsks();
  refreshAsks();
  if (typeof refreshHome === "function") refreshHome();
}

// Home's Parked fold: the asks parked until a date, soonest back first, shut until opened.
function parkedSection() {
  const rows = [...(st.parked || [])].sort((a, b) => (a.parked_until < b.parked_until ? -1 : 1));
  if (!rows.length) return "";
  const row = (a) => `<tr><td>${esc(a.project) || "-"}</td><td class="n" title="${esc(a.parked_until)}">${stamp(a.parked_until)}</td>` +
    `<td class="wrap">${esc(a.title || a.question)}</td><td><button class="btn sm" data-unpark="${esc(a.id)}">Unpark</button></td></tr>`;
  const table = `<div class="panel scroll"><table class="tbl"><tr><th>project</th><th class="n" data-role="glance">back</th><th data-role="lead">question</th><th></th></tr>${rows.map(row).join("")}</table></div>`;
  const err = askst.parkErr ? `<div class="err">${esc(askst.parkErr)}</div>` : "";
  return cfold("parked", `Parked <span class="muted">${rows.length}</span>`, err + table, askst.open);
}

function answerOnEnter(e) {
  if (e.key !== "Enter" || !e.target.matches("[data-free]")) return;
  e.preventDefault();
  const btn = e.target.parentElement.querySelector("[data-reply], [data-send]");
  if (btn) btn.click();
}
