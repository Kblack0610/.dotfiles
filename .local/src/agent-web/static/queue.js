"use strict";
// The Queue tab: agent-queue's items (/api/queue), a box to queue a task, and cancel and
// re-rank on each active row. Design: ~/.config/agentctl/QUEUE.md. The page never writes the
// store itself; every change goes through agent-queue, and the SSE `queue` event re-reads it.

const Q_PRIORITIES = ["urgent", "high", "normal", "low"];
const Q_SECTIONS = [
  ["waiting", "Waiting for you"],
  ["running", "Running"],
  ["queued", "Up next"],
  ["done", "Done today"],
];
const qst = { items: null, err: null, stats: null, projects: [], busy: false, msg: "", draft: null };

const refreshQueue = coalesce(async () => {
  try { qst.items = await api("/api/queue"); qst.err = null; } catch (e) { qst.err = e.message; }
  // The window's line and what sits now; the list still shows when agent-queue stats fails.
  try { qst.stats = await api("/api/queue/stats"); } catch (e) { qst.stats = { week: `stats: ${e.message}`, sitting: null }; }
  if (st.tab === "queue") renderQueue();
  renderQueueBadge();
});

function renderQueueBadge() {
  const n = (qst.items || []).filter((i) => i.state === "waiting").length;
  $("queue-badge").innerHTML = n ? `<span class="badge">${n}</span>` : "";
}

// What the item's session needs from the human now: the dialog its pane shows, and the asks
// it filed. Answered in place, through the same cards the Waiting tab uses.
function qNeeds(a) {
  if (!a) return "";
  const cards = (a.question ? sessionCard(a) : "") +
    st.asks.filter((k) => k.session && k.session === a.session).map(askCard).join("");
  return cards ? `<div class="qneed">${cards}</div>` : "";
}

// The tmux pane agent-panel lists for this item's session, if it is still live.
function qAgent(i) {
  if (!i.session) return null;
  return st.agents.find((a) => a.target.slice(a.target.indexOf("/") + 1).startsWith(i.session + ":")) || null;
}

function qPr(pr) {
  if (!pr) return "";
  return /^https?:\/\//.test(pr) ? `<a href="${esc(pr)}" target="_blank" rel="noopener">PR</a>` : `PR ${esc(pr)}`;
}

function qItem(i) {
  const active = i.state !== "done";
  const tags = (i.tags || "").split(/\s+/).filter(Boolean).map((t) => `<span class="qtag">${esc(t)}</span>`).join("");
  const a = qAgent(i);
  const stamp = i.state === "done" ? `finished ${when(i.finished)}`
    : i.started ? `started ${when(i.started)}` : `queued ${when(i.queued)}`;
  const meta = [
    `<span class="qprio ${esc(i.priority)}">${esc(i.priority)}</span>`,
    esc(i.project), esc(i.mode), stamp,
    i.from && i.from !== "human" ? esc(i.from) : "",
    i.session ? `session ${esc(i.session)}` : "",
    a && a.phases ? esc(phasesText(a)) : "",
    i.state === "done" ? `<span class="${i.status === "ok" ? "" : "qbad"}">${esc(i.status || "")}</span>` : "",
    qPr(i.pr),
  ].filter(Boolean).join(", ");
  const hold = i.hold ? `<div class="qhold">waits: ${esc(i.hold)}</div>` : "";
  const note = i.note ? `<div class="qhold">${esc(i.note)}</div>` : "";
  const prio = Q_PRIORITIES.map((p) => `<option${p === i.priority ? " selected" : ""}>${p}</option>`).join("");
  const acts = active
    ? `<div class="opts">${a && a.question && a.question.kind === "plan" ? "" : approveButtons(a)}${a ? `<button class="btn sm${a.actions && a.actions.includes("approve-plan") ? "" : " primary"}" data-open="${esc(i.slug)}">Open session</button>` : ""}` +
      `<select data-bump="${esc(i.slug)}" title="priority">${prio}</select>` +
      `<button class="btn sm" data-cancel="${esc(i.slug)}">${i.state === "queued" ? "Cancel" : "Stop and cancel"}</button></div>`
    : "";
  return `<div class="card qitem"><div class="meta">${esc(i.slug)} ${tags}</div><div class="meta">${meta}</div>` +
    `<div class="q">${esc(i.task || "")}</div>${hold}${note}${active ? qNeeds(a) : ""}${acts}</div>`;
}

function qCompose() {
  const d = qst.draft || (qst.draft = { project: "", mode: "oneshot", priority: "normal", tags: "", task: "" });
  const opt = (list, cur) => list.map((v) => `<option${v === cur ? " selected" : ""}>${esc(v)}</option>`).join("");
  return `<div class="card qadd">` +
    `<textarea id="q-task" placeholder="The whole task, as you would type it to a session (Ctrl+Enter to queue)">${esc(d.task)}</textarea>` +
    `<div class="opts">` +
    `<select id="q-project"><option value="">project...</option>${opt(qst.projects, d.project)}</select>` +
    `<select id="q-mode">${opt(["oneshot", "plan"], d.mode)}</select>` +
    `<select id="q-priority">${opt(Q_PRIORITIES, d.priority)}</select>` +
    `<input id="q-tags" placeholder="tags: night, at:02:30" value="${esc(d.tags)}">` +
    `<button class="btn primary" id="q-add"${qst.busy ? " disabled" : ""}>${qst.busy ? "Queueing..." : "Queue"}</button>` +
    `</div><div class="err" id="q-msg">${esc(qst.msg)}</div>` +
    `<div class="muted qhint">oneshot runs /one-shot when capacity frees, by priority; plan starts a plan-mode session now. ` +
    `night waits for the night window and stops at the PR; at:HH:MM waits for that time.</div></div>`;
}

function renderQueue() {
  const el = $("queue");
  // Re-rendering must not eat what the human is typing.
  if (document.activeElement && document.activeElement.closest(".qadd") && $("q-msg")) {
    $("q-msg").textContent = qst.msg;
    renderQueueList();
    return;
  }
  el.innerHTML = qCompose() + `<div id="q-list"></div>`;
  renderQueueList();
}

function renderQueueList() {
  const el = $("q-list");
  if (!el) return;
  // Keep a reply being typed into a row's answer card across the re-render.
  const f = document.activeElement, card = f && f.closest && f.closest("#q-list .qneed .card");
  const keep = card && f.matches("[data-free]") ? { k: card.dataset.t || card.dataset.id, v: f.value } : null;
  drawQueueList(el);
  if (!keep) return;
  const again = [...el.querySelectorAll(".qneed .card")].find((c) => (c.dataset.t || c.dataset.id) === keep.k);
  const input = again && again.querySelector("[data-free]");
  if (input) { input.value = keep.v; input.focus(); }
}

function drawQueueList(el) {
  if (!qst.items) { el.innerHTML = `<div class="empty">${qst.err ? esc(qst.err) : "Loading..."}</div>`; return; }
  let html = qst.err ? `<div class="panel down">${esc(qst.err)}</div>` : "";
  if (qst.stats) html += `<div class="muted qstats">${esc(qst.stats.week)}${qst.stats.sitting ? `<br>${esc(qst.stats.sitting)}` : ""}</div>`;
  for (const [state, title] of Q_SECTIONS) {
    const rows = qst.items.filter((i) => i.state === state);
    if (!rows.length && state === "waiting") continue;
    html += `<h2 class="sec">${title} <span class="muted">${rows.length}</span></h2>`;
    html += rows.length ? rows.map(qItem).join("") : `<div class="card muted">Nothing ${state === "done" ? "finished today" : "here"}.</div>`;
  }
  el.innerHTML = html;
}

function qSaveDraft() {
  if (!$("q-task")) return;
  qst.draft = {
    project: $("q-project").value, mode: $("q-mode").value, priority: $("q-priority").value,
    tags: $("q-tags").value, task: $("q-task").value,
  };
}

async function qAdd() {
  qSaveDraft();
  const d = qst.draft;
  if (!d.project) { qst.msg = "Pick a project."; renderQueue(); return; }
  if (!d.task.trim()) { qst.msg = "Type the task."; renderQueue(); return; }
  if (document.activeElement) document.activeElement.blur();
  qst.busy = true; qst.msg = ""; renderQueue();
  try {
    const r = await post("/api/queue", d);
    // agent-queue says "<state> <slug> -> <file>", then the plan start's own lines.
    qst.msg = ((r && r.out) || "queued").split(" -> ")[0].replace(/^(\w+) /, (m, w) => w[0].toUpperCase() + w.slice(1) + ": ");
    qst.draft = Object.assign({}, d, { task: "" });
  } catch (e) {
    qst.msg = e.message;
  }
  qst.busy = false;
  renderQueue();
  refreshQueue();
}

async function qAct(path, body) {
  try { await post(path, body); qst.msg = ""; } catch (e) { qst.msg = e.message; }
  renderQueue();
  refreshQueue();
}

const qPending = {};
$("queue").addEventListener("click", (e) => {
  const t = e.target;
  if (t.id === "q-add") { qAdd(); return; }
  const need = t.closest(".qneed .card");
  if (need) { answerCard(need, e); return; }
  if (t.dataset.open) {
    const a = qAgent((qst.items || []).find((i) => i.slug === t.dataset.open) || {});
    if (a) { setTab("sessions"); select(a); }
    return;
  }
  if (t.dataset.cancel) {
    // The page has no confirm dialog to lean on, so the button asks twice.
    const s = t.dataset.cancel;
    if (qPending[s]) { delete qPending[s]; qAct("/api/queue/cancel", { slug: s }); return; }
    qPending[s] = true;
    t.textContent = "Click again to cancel";
    setTimeout(() => { delete qPending[s]; }, 4000);
  }
});
$("queue").addEventListener("change", (e) => {
  const t = e.target;
  if (t.closest(".qneed")) return;
  if (t.dataset.bump) { qAct("/api/queue/bump", { slug: t.dataset.bump, priority: t.value }); return; }
  if (t.closest(".qadd")) qSaveDraft();
});
$("queue").addEventListener("input", (e) => { if (e.target.closest(".qadd")) qSaveDraft(); });
$("queue").addEventListener("keydown", (e) => {
  if (e.target.closest(".qneed")) { answerOnEnter(e); return; }
  if (e.target.id === "q-task" && e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); qAdd(); }
});

TABS.queue = {
  async show() {
    renderQueue();
    refreshQueue();
    if (!qst.projects.length) {
      try { qst.projects = await api("/api/queue/projects"); } catch (e) { /* the select stays empty; add says why */ }
      if (st.tab === "queue") { qSaveDraft(); renderQueue(); }
    }
  },
  onEvent(ev) {
    if (ev.kind === "queue" || ev.kind === "resync") refreshQueue();
  },
};
refreshQueue();
