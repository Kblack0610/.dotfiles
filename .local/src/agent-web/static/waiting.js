"use strict";
// The answer cards for what waits on you: a live session's open dialog or permission prompt
// (read from its transcript by the server) and a pending ask, the one record of a question to
// the human. Home (home.js) draws them on its Needs you rows, and a session's conversation pins
// its dialog; each answers in place. Answering a session's card types the answer into its pane.

// Which folds are open, by data-k: a section (`sec:<name>`) or a card's details. `sending` holds
// the answer in flight per card key (`ask:<id>`, `ses:<target>`), so a redraw mid-send keeps the
// card locked and saying what it sent.
const askst = { open: {}, sending: {} };

function drawAsks() {
  if (st.tab === "home") renderHome();
}
// Only the Parked fold reads asks here: the asks that wait on you are Home's Needs you rows, each
// carrying its own record (`need.ask`), so no second read of them exists to disagree with it.
const refreshAsks = coalesce(async () => {
  const parked = api("/api/asks/parked").catch(() => st.parked);
  await refreshWaiting();
  st.parked = await parked;
  drawAsks();
});

// The sidebar badge: the server's count of Needs you rows (/api/home/waiting, hub_core
// Home::waiting), the same number Home lists and Queue and Log link. A read that failed says
// NOT_READ, never 0, and nothing is drawn before the first answer.
const refreshWaiting = coalesce(async () => {
  try { st.waiting = await api("/api/home/waiting"); } catch (e) { st.waiting = null; }
  renderBadge();
  if (st.tab === "queue") qst.render();
  if (st.tab === "infra") renderInfra();
});
function renderBadge() {
  const w = st.waiting;
  const badge = (n) => w === undefined ? "" : w === null ? `<span class="badge" title="${NOT_READ}">?</span>` : n ? `<span class="badge">${n}</span>` : "";
  for (const id of ["ask-badge", "menu-badge"]) $(id).innerHTML = badge(w?.count);
  // Sessions' tab shows its own share of that count (Waiting.sessions), not a count of /api/agents.
  $("wait-badge").innerHTML = badge(w?.sessions);
}

// The band a Needs you card opens with: its kind label (hub_core::home::NeedKind::label, sent on
// the row and on a session's `need`), then where and how long, as quiet text. The card's kind
// class comes from the kind (status hues stay status, dashboards rule 5).
const needBand = (label, meta) =>
  `<div class="nband"><span class="nkind">${esc(label)}</span>${meta.filter(Boolean).map((m) => `<span>${m}</span>`).join("")}</div>`;

// A live session's open dialog: what the session is, what it wants and for how long, then the
// question and its answers. Its kind and label are `a.need`. The tmux target is the title's
// tooltip and sits in Details. A plan shows whole, its buttons above it, so a long plan never
// hides how to approve it. `here` is a card drawn where an Open button already is (the session's
// own conversation), so it draws none.
function sessionCard(a, here = false) {
  const q = a.question, k = a.need.kind;
  let opts = "";
  if (q.kind === "choice") opts = q.options.map((o, i) => `<button class="btn" data-k="${i + 1}">${i + 1}. ${esc(o)}</button>`).join("");
  if (q.kind === "tool") opts = ["1", "2", "3"].map((k) => `<button class="btn" data-k="${k}">${k}</button>`).join("");
  if (q.kind === "plan") opts = approveButtons(a);
  const body = `<div class="q md${q.kind === "plan" ? " planq" : ""}">${md(q.text)}</div>`;
  const reply = `<input placeholder="${q.kind === "plan" ? "or tell it what to change" : "reply in this session"}" data-free><button class="btn" data-reply>Send</button>`;
  const p = a.phases;
  const band = needBand(a.need.label, [esc(a.project), a.wrote ? waited(a.wrote) : "", p ? `phase ${p.done}/${p.total}` : "", etaText(p), a.attached ? "you are attached" : ""]);
  const title = `<div class="ntitle" title="${esc(a.target)}">${esc(a.summary?.text || a.plan || a.short || a.target)}</div>`;
  const more = cfold(`ses:${a.target}`, "Details", facts([["target", a.target], ["session", a.session], ["account", a.account],
    ["plan", a.plan], ["next phase", p && p.next]]), askst.open);
  const open = here ? "" : `<button class="btn sm" data-open>Open session</button>`;
  const lead = q.kind === "plan" ? `<div class="opts">${opts}${open}</div>${body}<div class="opts">${reply}</div>`
    : `${body}<div class="opts">${opts}${open}${reply}</div>`;
  return `<div class="card need k-${k}${sendingCls(`ses:${a.target}`)}" data-t="${esc(a.target)}" data-kind="${esc(q.kind)}">${band}${title}${lead}${more}${statusLine(`ses:${a.target}`)}</div>`;
}

// An ask's Full log, read when its fold opens (askTrace) and kept here by id, so a redraw shows
// the last read instead of reading again. The server words it (hub_core::boards::AskTrace): the
// timeline and the judge's call as label/value rows, the Langfuse link, the raw reply.
askst.trace = {};
function traceHtml(t) {
  const link = t.langfuse ? `<div class="cline"><a href="${esc(t.langfuse)}" target="_blank" rel="noopener">Langfuse trace</a></div>` : "";
  const call = t.call ? facts(t.call) + link + (t.raw ? `<pre class="araw">${esc(t.raw)}</pre>` : "") : '<div class="muted">No judge call line for this ask.</div>';
  return facts(t.timeline) + call;
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
  catch (err) { askst.trace[id] = errPanel(err.message); }
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
// `n` is its Needs you row (hub_core::home): the label and what the ask holds come on the row,
// the ask's whole record, judge line included, as `n.ask`.
function askCard(n) {
  const a = n.ask;
  const owner = st.agents.find((x) => a.claude_session && x.session === a.claude_session);
  const from = owner ? owner.short || owner.target : a.session;
  // What follows the question: its context, its preview images (`mkt draft`), the judge's view,
  // then the answers.
  const prev = (a.previews || []).map((p, i) => `<a href="/api/asks/${encodeURIComponent(a.id)}/preview/${i}" target="_blank" rel="noopener">` +
    `<img src="/api/asks/${encodeURIComponent(a.id)}/preview/${i}" alt="${esc(p)}" loading="lazy"></a>`).join("");
  const tail = `${a.context ? `<div class="actx md">${md(a.context)}</div>` : ""}${prev ? `<div class="aprev">${prev}</div>` : ""}` +
    `${a.judge_line ? `<div class="cline">${esc(a.judge_line)}</div>` : ""}${askOptions(a)}`;
  const kind = a.kind && a.kind !== "question" ? esc(a.kind) : "";
  const band = needBand(n.label, [esc(a.project), from ? `from ${esc(from)}` : "headless", kind, a.created ? waited(a.created) : "", esc(n.holds_line)]);
  const body = a.title ? a.body : "";
  const log = cfold(`trace:${a.id}`, "Full log", askst.trace[a.id] || '<div class="muted">Reading...</div>', askst.open);
  const more = cfold(`ask:${a.id}`, "Details", facts([["id", a.id], ["kind", a.kind], ["filed by", a.session], ["claude session", a.claude_session],
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
// says why; a sent ask leaves Home's list when the badge and Home read again.
const sendingCls = (key) => (askst.sending[key] ? " sending" : "");
const statusLine = (key) => askst.sending[key]
  ? `<div class="cstat" role="status"><span class="spin"></span>Sending ${esc(askst.sending[key])}...</div>${errPanel("")}`
  : `<div class="cstat" role="status"></div>${errPanel("")}`;
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
  // Answered: the server has closed it, so the badge and Home read again (Home's click handler refreshes the list).
  delete askst.sending[key];
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
  const err = askst.parkErr ? errPanel(askst.parkErr) : "";
  return cfold("parked", `Parked <span class="muted">${rows.length}</span>`, err + table, askst.open);
}

function answerOnEnter(e) {
  if (e.key !== "Enter" || !e.target.matches("[data-free]")) return;
  e.preventDefault();
  const btn = e.target.parentElement.querySelector("[data-reply], [data-send]");
  if (btn) btn.click();
}
