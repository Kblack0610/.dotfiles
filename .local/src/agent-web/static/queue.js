"use strict";
// The Queue tab: agent-queue's items (/api/queue), a box to queue a task, and cancel and
// re-rank on each active row. Design: ~/.config/agentctl/QUEUE.md. The page never writes the
// store itself; every change goes through agent-queue, and the SSE `queue` event re-reads it.

const Q_PRIORITIES = ["urgent", "high", "low"];
const Q_SECTIONS = [
  ["waiting", "Waiting for you"],
  ["running", "Running"],
  ["queued", "Up next"],
  ["done", "Done, last 7 days"],
];
// Each state's chip on a card, with how long it has been in it.
const Q_STATE = { waiting: "Waiting on you", running: "Running", queued: "Queued" };
// Which folds are open, by data-k: a section (`sec:<state>`) or a card's task (`task:<slug>`).
// Re-renders come with every event, so the page keeps what the human opened. Done starts shut.
const qst = { items: null, err: null, stats: null, projects: [], busy: false, msg: "", draft: null, open: { "sec:done": false } };

const refreshQueue = coalesce(async () => {
  try { qst.items = await api("/api/queue"); qst.err = null; } catch (e) { qst.err = e.message; }
  // The window's line and what sits now; the list still shows when agent-queue stats fails.
  try { qst.stats = await api("/api/queue/stats"); } catch (e) { qst.stats = { week: `stats: ${e.message}` }; }
  if (st.tab === "queue") renderQueue();
  renderQueueBadge();
});

function renderQueueBadge() {
  const n = (qst.items || []).filter((i) => i.state === "waiting").length;
  $("queue-badge").innerHTML = n ? `<span class="badge">${n}</span>` : "";
}

// This item's panes; hub-core `with_items` makes that join. An item that recorded its window has
// that one pane. One that recorded only a shared tmux session has every pane in it.
const qPanes = (i) => st.agents.filter((a) => a.items.includes(i.slug));

// The one pane that is this item's, when the join found exactly one.
function qAgent(i) {
  const p = qPanes(i);
  return p.length === 1 ? p[0] : null;
}

// What the item's session needs from the human now: the dialogs its panes show and the asks they
// filed, answered in place through the same cards the Waiting tab uses. An ask belongs to the
// Claude session that filed it, never to a tmux name (agent-panel asks.rs). A waiting item with
// neither says where the human has to look instead.
function qNeeds(i) {
  const panes = qPanes(i);
  const asks = st.asks.filter((k) => k.session && panes.some((p) => p.session === k.session));
  const cards = panes.filter((p) => p.question).map((p) => sessionCard(p, true)).join("") + asks.map((k) => askCard(k, true)).join("");
  if (cards) return `<div class="qneed">${cards}</div>`;
  if (i.state !== "waiting" || !i.session) return "";
  return `<div class="qhold" title="tmux session ${esc(i.session)}">${panes.length ? "Waiting on a prompt in its window" : "Its session window is closed"}</div>`;
}

// The state chip: what the item is doing and for how long, or how it ended.
function qChip(i) {
  if (i.state === "done") {
    const s = i.status || "ok";
    const [cls, word] = s === "ok" ? ["ok", "Done"] : s === "failed" ? ["bad", "Failed"] : ["off", "Cancelled"];
    return cchip(cls, word);
  }
  const since = i.state === "waiting" ? i.waiting || i.started : i.state === "running" ? i.started : i.queued;
  return cchip(esc(i.state), `${Q_STATE[i.state] || esc(i.state)}${since ? ` ${ago(since)}` : ""}`);
}

// When it will be done: the session's estimate (fleet-bench through fleet-sessions), late when
// it has passed; a queued item's typical run; a done item's run time.
function qEta(i, a) {
  if (i.state === "done") {
    const m = (tms(i.finished) - tms(i.started)) / 60000;
    return m >= 0 ? `took ${dur(m)}` : "";
  }
  const eta = etaText(a && a.phases);
  if (eta) return eta;
  const run = qst.stats && qst.stats.run_minutes_median;
  return i.state === "queued" && run ? `usually ${dur(run)} once started` : "";
}

function qPr(pr) {
  if (!pr) return "";
  return /^https?:\/\//.test(pr) ? `<a href="${esc(pr)}" target="_blank" rel="noopener">PR</a>` : `PR ${esc(pr)}`;
}

// A card says what the item is, its state and since when, what it needs from the human and when
// it will be done. The task as typed and the bookkeeping fold away.
function qItem(i) {
  const active = i.state !== "done";
  const a = qAgent(i);
  const p = a && a.phases;
  const prio = i.priority && i.priority !== "low" ? cchip(`prio ${esc(i.priority)}`, esc(i.priority)) : "";
  const when = i.state === "done" ? `finished ${stamp(i.finished)}`
    : i.started ? `started ${stamp(i.started)}` : `queued ${stamp(i.queued)}`;
  const line = cardLine([esc(i.project), when, p ? `phase ${p.done}/${p.total}` : "", qEta(i, a), qPr(i.pr)]);
  const next = active && p && p.next ? `<div class="qnext">Next: ${esc(p.next)}</div>` : "";
  const hold = i.hold ? `<div class="qhold">Waiting on: ${esc(i.hold)}</div>` : "";
  const note = i.note ? `<div class="qhold">${esc(i.note)}</div>` : "";
  const more = cfold(`task:${i.slug}`, "Full task and details", facts([
    ["slug", i.slug], ["mode", [i.mode, i.weight].filter(Boolean).join(", ")], ["tags", i.tags],
    ["from", i.from], ["session", i.session], ["queued", i.queued && stamp(i.queued)],
    ["started", i.started && stamp(i.started)], ["plan", i.plan], ["phases", i.phases],
  ]) + `<div class="q">${esc(i.task || "")}</div>`, qst.open);
  const prios = Q_PRIORITIES.map((x) => `<option${x === i.priority ? " selected" : ""}>${x}</option>`).join("");
  const acts = active
    ? `<div class="opts">${a && a.question && a.question.kind === "plan" ? "" : approveButtons(a)}${a ? `<button class="btn sm${a.actions && a.actions.includes("approve-plan") ? "" : " primary"}" data-open="${esc(i.slug)}">Open session</button>` : ""}` +
      `<select data-bump="${esc(i.slug)}" title="priority">${prios}</select>` +
      `<button class="btn sm quiet" data-cancel="${esc(i.slug)}">${i.state === "queued" ? "Cancel" : "Stop and cancel"}</button></div>`
    : "";
  return `<div class="card qitem ${esc(i.state)}">${cardHead(i.title || i.slug, [prio, qChip(i)])}` +
    `${line}${active ? qNeeds(i) : ""}${hold}${note}${next}${more}${acts}</div>`;
}

function qCompose() {
  const d = qst.draft || (qst.draft = { project: "", mode: "oneshot", priority: "high", tags: "", task: "" });
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
  keepTyping("#q-list .qneed .card", () => drawQueueList(el));
}

// The counts at the top, one tile each, and the week's prose folded under them.
function qTiles() {
  const it = qst.items, n = (st8) => it.filter((i) => i.state === st8).length;
  const held = it.filter((i) => i.state === "queued" && i.hold).length;
  const failed = it.filter((i) => i.state === "done" && i.status === "failed").length;
  const s = qst.stats || {};
  const prose = [s.week, s.sitting].filter(Boolean).map(esc).join("<br>");
  const k = "stats";
  return `<div class="tiles qtiles">${tile("NEEDS YOU", n("waiting"), "var(--b-needs)")}${tile("RUNNING", n("running"), "var(--b-working)")}` +
    `${tile("UP NEXT", n("queued"), "var(--c1)", held ? `${held} held` : "")}${tile("DONE, 7 DAYS", n("done"), "var(--b-done)", failed ? `${failed} failed` : "")}` +
    `${s.wait_minutes_median != null ? tile("TYPICAL WAIT", dur(s.wait_minutes_median), "var(--c3)") : ""}` +
    `${s.to_pr_minutes_median != null ? tile("TYPICAL TO PR", dur(s.to_pr_minutes_median), "var(--c3)") : ""}</div>` +
    (prose ? cfold(k, "Stats detail", `<div class="muted">${prose}</div>`, qst.open) : "");
}

// Done items under a heading per day, newest day first.
function qDoneDays(rows) {
  const day = (i) => new Date(tms(i.finished)).toDateString();
  const today = new Date().toDateString(), yday = new Date(Date.now() - 864e5).toDateString();
  const sorted = [...rows].sort((a, b) => tms(b.finished) - tms(a.finished));
  let html = "", last = null;
  for (const i of sorted) {
    const d = day(i);
    if (d !== last) {
      last = d;
      const label = d === today ? "Today" : d === yday ? "Yesterday"
        : new Date(tms(i.finished)).toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });
      html += `<h3 class="qday">${label}</h3>`;
    }
    html += qItem(i);
  }
  return html;
}

// Waiting: longest-waiting first. Running: soonest estimate first, none last. The rest as
// agent-queue ordered them.
function qSorted(state, rows) {
  const key = state === "waiting" ? (i) => tms(i.waiting || i.started) || 0
    : state === "running" ? (i) => { const a = qAgent(i); return (a && a.phases && a.phases.eta_epoch) || Infinity; }
    : null;
  return key ? [...rows].sort((a, b) => key(a) - key(b)) : rows;
}

function drawQueueList(el) {
  if (!qst.items) { el.innerHTML = `<div class="empty">${qst.err ? esc(qst.err) : "Loading..."}</div>`; return; }
  let html = qst.err ? `<div class="panel down">${esc(qst.err)}</div>` : "";
  html += qTiles();
  for (const [state, title] of Q_SECTIONS) {
    const rows = qSorted(state, qst.items.filter((i) => i.state === state));
    if (!rows.length && state === "waiting") continue;
    const k = `sec:${state}`, open = qst.open[k] != null ? qst.open[k] : true;
    const failed = state === "done" ? rows.filter((i) => i.status === "failed").length : 0;
    const body = !rows.length ? `<div class="card muted">Nothing ${state === "done" ? "finished this week" : "here"}.</div>`
      : state === "done" ? qDoneDays(rows) : rows.map(qItem).join("");
    html += `<details class="csec" data-k="${k}"${open ? " open" : ""}><summary><h2 class="sec">${title} ` +
      `<span class="muted">${rows.length}${failed ? `, <span class="qbad">${failed} failed</span>` : ""}</span></h2></summary>${body}</details>`;
  }
  const y = $("queue").scrollTop;
  el.innerHTML = html;
  $("queue").scrollTop = y;
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
$("queue").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) qst.open[e.target.dataset.k] = e.target.open;
}, true);
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
