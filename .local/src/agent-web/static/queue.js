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
const qst = { items: null, err: null, projects: [], busy: false, msg: "", draft: null };

const refreshQueue = coalesce(async () => {
  try { qst.items = await api("/api/queue"); qst.err = null; } catch (e) { qst.err = e.message; }
  if (st.tab === "queue") renderQueue();
  renderQueueBadge();
});

function renderQueueBadge() {
  const n = (qst.items || []).filter((i) => i.state === "waiting").length;
  $("queue-badge").innerHTML = n ? `<span class="badge">${n}</span>` : "";
}

// An ISO time as HH:MM today, with its weekday otherwise.
function qWhen(t) {
  if (!t) return "";
  const d = new Date(t);
  if (isNaN(d)) return esc(t);
  return d.toDateString() === new Date().toDateString() ? clock(d.getTime())
    : d.toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" });
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
  const when = i.state === "done" ? `finished ${qWhen(i.finished)}`
    : i.started ? `started ${qWhen(i.started)}` : `queued ${qWhen(i.queued)}`;
  const meta = [
    `<span class="qprio ${esc(i.priority)}">${esc(i.priority)}</span>`,
    esc(i.project), esc(i.mode), when,
    i.from && i.from !== "human" ? esc(i.from) : "",
    i.session ? `session ${esc(i.session)}` : "",
    i.state === "done" ? `<span class="${i.status === "ok" ? "" : "qbad"}">${esc(i.status || "")}</span>` : "",
    qPr(i.pr),
  ].filter(Boolean).join(", ");
  const hold = i.hold ? `<div class="qhold">waits: ${esc(i.hold)}</div>` : "";
  const note = i.note ? `<div class="qhold">${esc(i.note)}</div>` : "";
  const prio = Q_PRIORITIES.map((p) => `<option${p === i.priority ? " selected" : ""}>${p}</option>`).join("");
  const acts = active
    ? `<div class="opts">${a ? `<button class="btn sm primary" data-open="${esc(i.slug)}">Open session</button>` : ""}` +
      `<select data-bump="${esc(i.slug)}" title="priority">${prio}</select>` +
      `<button class="btn sm" data-cancel="${esc(i.slug)}">${i.state === "queued" ? "Cancel" : "Stop and cancel"}</button></div>`
    : "";
  return `<div class="card qitem"><div class="meta">${esc(i.slug)} ${tags}</div><div class="meta">${meta}</div>` +
    `<div class="q">${esc(i.task || "")}</div>${hold}${note}${acts}</div>`;
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
  if (!qst.items) { el.innerHTML = `<div class="empty">${qst.err ? esc(qst.err) : "Loading..."}</div>`; return; }
  let html = qst.err ? `<div class="panel down">${esc(qst.err)}</div>` : "";
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
  if (t.dataset.bump) { qAct("/api/queue/bump", { slug: t.dataset.bump, priority: t.value }); return; }
  if (t.closest(".qadd")) qSaveDraft();
});
$("queue").addEventListener("input", (e) => { if (e.target.closest(".qadd")) qSaveDraft(); });
$("queue").addEventListener("keydown", (e) => {
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
