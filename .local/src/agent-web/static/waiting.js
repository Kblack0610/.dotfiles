"use strict";
// The answer cards for what waits on you: a live session's open dialog or permission prompt
// (read from its transcript by the server) and a pending ask, the one record of a question to
// the human. Home (home.js) draws them on its Needs you rows; the same two cards answer in place
// on a Queue row (queue.js, inQueue), without their head. Answering a session's card types the
// answer into its pane.

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
  $("ask-badge").innerHTML = n ? `<span class="badge">${n}</span>` : "";
}

// What each kind of open dialog is, as a chip and as the label on a Queue row.
const DIALOG = {
  choice: ["Asking", "The session is asking"],
  tool: ["Permission", "The session needs permission"],
  plan: ["Plan to approve", "A plan to approve"],
};
const dialog = (q) => DIALOG[q.kind] || ["Your turn", "Your turn in the session"];

// A live session's open dialog: what the session is, what it wants and for how long, then the
// question and its answers. The tmux target is the title's tooltip and sits in Details.
function sessionCard(a, inQueue) {
  const q = a.question, [chip, label] = dialog(q);
  let opts = "";
  if (q.kind === "choice") opts = q.options.map((o, i) => `<button class="btn" data-k="${i + 1}">${i + 1}. ${esc(o)}</button>`).join("");
  if (q.kind === "tool") opts = ["1", "2", "3"].map((k) => `<button class="btn" data-k="${k}">${k}</button>`).join("");
  if (q.kind === "plan") opts = approveButtons(a);
  const body = `<div class="q md${q.kind === "plan" ? " planq" : ""}">${md(q.text)}</div>`;
  const reply = `<input placeholder="${q.kind === "plan" ? "or tell it what to change" : "reply in this session"}" data-free><button class="btn" data-reply>Send</button>`;
  const attrs = `class="card" data-t="${esc(a.target)}" data-kind="${esc(q.kind)}"`;
  if (inQueue === true) {
    return `<div ${attrs}><div class="qask-h" title="${esc(a.target)}">${label}</div>${body}<div class="opts">${opts}${reply}</div><div class="err"></div></div>`;
  }
  const p = a.phases;
  const head = cardHead(a.summary || a.plan || a.short || a.target,
    [cchip("waiting", `${chip}${a.waiting_since ? ` ${ago(a.waiting_since)}` : ""}`)], a.target);
  const line = cardLine([esc(a.project), p ? `phase ${p.done}/${p.total}` : "", etaText(p), a.attached ? "you are attached" : ""]);
  const k = `ses:${a.target}`;
  const more = cfold(k, "Details", facts([["target", a.target], ["session", a.session], ["account", a.account],
    ["plan", a.plan], ["next phase", p && p.next]]), askst.open);
  return `<div ${attrs}>${head}${line}${body}` +
    `<div class="opts">${opts}<button class="btn sm" data-open>Open session</button>${reply}</div>${more}<div class="err"></div></div>`;
}

// The answer judge runs in shadow: it only says what it would do, next to the human's buttons.
// A judge that would leave it to the human says nothing the buttons do not.
function judgeText(a) {
  if (!a.judge || a.judge === "human" || a.judge === "error") return "";
  return a.judge === "take-recommend" ? `judge would take the recommendation (${esc(a.recommend)})`
    : `judge would answer "${esc(a.judge.replace(/^answer:/, ""))}"`;
}

// One pending ask, answered through agent-ask: its first sentence as the title, how long it has
// waited, who filed it, then the rest of the question, which the options often lean on.
function askCard(a, inQueue) {
  const owner = st.agents.find((x) => a.session && x.session === a.session);
  const from = owner ? owner.short || owner.target : a.agent;
  const opts = a.options.map((o) => `<button class="btn${o === a.recommend ? " rec" : ""}" data-a="${esc(o)}">${esc(o)}${o === a.recommend ? " (recommended)" : ""}</button>`).join("") +
    `<input placeholder="or type an answer" data-free><button class="btn" data-send>Answer</button>`;
  if (inQueue === true) {
    // The Queue card around it already names the project and session, so routing is a tooltip.
    const route = `${esc(a.project)}, ${owner ? esc(owner.target) : "headless"}, ${esc(a.kind)}, ${esc(a.id)}`;
    const judge = judgeText(a);
    return `<div class="card" data-id="${esc(a.id)}"><div class="qask-h" title="${route}">Question for you</div>` +
      `<div class="q md">${md(a.question)}</div>${judge ? `<div class="cline">${judge}</div>` : ""}<div class="opts">${opts}</div><div class="err"></div></div>`;
  }
  const head = cardHead(a.title || a.question, [cchip("waiting", `${esc(a.kind)}${a.created ? ` ${ago(a.created)}` : ""}`)]);
  const line = cardLine([esc(a.project), from ? `from ${esc(from)}` : "headless", judgeText(a)]);
  const body = a.title ? a.body : "";
  const k = `ask:${a.id}`;
  const more = cfold(k, "Details", facts([["id", a.id], ["kind", a.kind], ["filed by", a.agent], ["claude session", a.session]]), askst.open);
  return `<div class="card" data-id="${esc(a.id)}">${head}${line}${body ? `<div class="q md">${md(body)}</div>` : ""}` +
    `<div class="opts">${opts}</div>${more}<div class="err"></div></div>`;
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
  let answer = e.target.dataset.a;
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
