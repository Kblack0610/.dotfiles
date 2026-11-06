"use strict";
// The Queue tab: agent-queue's items (/api/queue), a box to queue a task, and cancel and
// re-rank on each active row. Design: ~/.config/agentctl/QUEUE.md. The page never writes the
// store itself; every change goes through agent-queue, and the SSE `queue` event re-reads it.
// Below the queue, the Candidates fold: the ranked board rows (/api/queue/candidates, hub-core
// over `fleet-dispatch suggest`), each with a Promote that is the board's Start.

const Q_PRIORITIES = ["urgent", "high", "low"];
// The queue form's modes in the human's words; the option values stay what agent-queue takes.
const Q_MODE = { oneshot: "Run to PR", plan: "Plan first" };
const Q_SECTIONS = [
  ["waiting", "Waiting for you"],
  ["running", "Running"],
  ["queued", "Up next"],
  ["done", "Done, last 7 days"],
];
// Each state's chip on a card, with how long it has been in it.
const Q_STATE = { waiting: "Waiting on you", running: "Running", queued: "Queued" };
// Which folds are open, by data-k: a section (`sec:<state>`) or a card's task (`task:<slug>`).
// Re-renders come with every event, so the page keeps what the human opened. Done and
// Candidates start shut.
const qst = {
  items: null, err: null, stats: null, projects: [], busy: false, msg: "", draft: null,
  cands: null, candErr: null, candMsg: "", promoting: null,
  // The Candidates filter: a reason chip ("" is every row) and the search words.
  candReason: "", candQ: "", candAutoOpened: false,
  open: { "sec:done": false, "sec:candidates": false },
};

// The candidates read every board, so they are read on showing the tab and after a promote,
// never on a queue event.
const refreshCands = coalesce(async () => {
  try { qst.cands = await api("/api/queue/candidates"); qst.candErr = null; } catch (e) { qst.candErr = e.message; }
  // An #urgent row nothing will start opens the fold, once; shut again, it stays shut.
  if (qst.cands && qst.cands.urgent_blocked > 0 && !qst.candAutoOpened) {
    qst.candAutoOpened = true;
    qst.open["sec:candidates"] = true;
  }
  if (st.tab === "queue") renderQueueList();
});

// The pipeline line above the tiles: /api/pipeline, hub-core's `pipeline` worded once for this page
// and the hub TUI. Prometheus pushes nothing, so the open tab re-reads on Infra's cadence. With
// the gauges absent the line says `pipeline -`; the page never invents a zero.
const qpl = { data: null, err: null };
const refreshPipeline = coalesce(async () => {
  try { qpl.data = await api("/api/pipeline"); qpl.err = null; } catch (e) { qpl.err = e.message; }
  if (st.tab === "queue") renderQueueList();
});
const pollPipeline = poll("queue", refreshPipeline, INFRA_REFRESH_MS);

function qPipeline() {
  const d = qpl.data;
  if (!d) return `<div class="qpipe muted">${qpl.err ? `pipeline - ${esc(qpl.err)}` : "pipeline  reading Prometheus"}</div>`;
  const [first, ...rest] = d.lines;
  const g = d.grafana ? ` <a class="glink" href="${esc(d.grafana)}/d/kb-agents-overview" target="_blank" rel="noopener">graph</a>` : "";
  const why = d.error ? ` <span class="muted">${esc(d.error)}</span>` : "";
  return `<div class="qpipe${d.pipeline ? "" : " muted"}">${esc(first)}${why}${g}` +
    rest.map((l) => `<br><span class="qwarn">${esc(l.trim())}</span>`).join("") + `</div>`;
}

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

// What the item's session needs from the human now: a count of the dialogs its panes show and the
// asks they filed, linking to Home, which answers them in place. An ask belongs to the Claude
// session that filed it, never to a tmux name (agent-panel asks.rs). A waiting item with neither
// says where the human has to look instead.
function qNeeds(i) {
  const panes = qPanes(i);
  const asks = st.asks.filter((k) => k.session && panes.some((p) => p.session === k.session));
  const n = panes.filter((p) => p.question).length + asks.length;
  if (n) return `<div class="badge-line"><a href="#" data-home><span class="chip sm" style="--c:var(--b-needs)">${n} waiting on you</span> answer on Home</a></div>`;
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
    `<select id="q-mode">${["oneshot", "plan"].map((m) => `<option value="${m}"${m === d.mode ? " selected" : ""}>${Q_MODE[m]}</option>`).join("")}</select>` +
    `<select id="q-priority">${opt(Q_PRIORITIES, d.priority)}</select>` +
    `<input id="q-tags" placeholder="tags: night, at:02:30" value="${esc(d.tags)}">` +
    `<button class="btn primary" id="q-add"${qst.busy ? " disabled" : ""}>${qst.busy ? "Adding..." : "Add to queue"}</button>` +
    `</div><div class="err" id="q-msg">${esc(qst.msg)}</div>` +
    `<div class="muted qhint">Run to PR starts when a slot frees, by priority, and ends at a PR; Plan first opens a planning session now. ` +
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
  drawQueueList(el);
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
  html += qPipeline() + qTiles();
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
  html += qCandidates();
  const y = $("queue").scrollTop;
  // A redraw keeps the Candidates search box focused, its caret where it was.
  const typing = document.activeElement && document.activeElement.id === "qc-q" ? document.activeElement.selectionStart : null;
  el.innerHTML = html;
  $("queue").scrollTop = y;
  if (typing != null && $("qc-q")) { $("qc-q").focus(); $("qc-q").setSelectionRange(typing, typing); }
}

// Every row the page has, in rank order: the first ones, then the rows kept per reason chip.
const qCandAll = () => (qst.cands ? qst.cands.rows.concat(qst.cands.blocked_rows || []) : []);

// The rows the chip and the search keep. The search reads the title, project, key, why and
// what blocks it.
function qCandShown() {
  const q = qst.candQ.trim().toLowerCase();
  return qCandAll().map((c, i) => [c, i]).filter(([c]) => {
    if (qst.candReason === "_takes" && (c.blocked || []).length) return false;
    if (qst.candReason && qst.candReason !== "_takes" && !(c.reasons || []).includes(qst.candReason)) return false;
    return !q || [c.title, c.project, c.key, c.why, ...(c.blocked || [])].join(" ").toLowerCase().includes(q);
  });
}

// One ranked row: rank, project, key, title, how it would start (hub-core's label), why, and
// each reason nothing would start it.
function qCandRow([c, i], n) {
  const cls = c.held ? "warn" : "";
  const busy = qst.promoting === c.key;
  const blocked = (c.blocked || []).map((b) => `<span class="cchip ${c.prio === 0 ? "bad" : "warn"}">${esc(b)}</span>`).join(" ");
  return `<tr><td class="n">${n + 1}</td><td>${esc(c.project)}</td><td>${esc(c.key)}</td>` +
    `<td class="wrap">${esc(c.title)}</td><td class="${cls}">${esc(c.start_label)}</td><td class="wrap muted">${esc(c.why)}${blocked ? `<div>${blocked}</div>` : ""}</td>` +
    `<td><button class="btn sm" data-promote="${i}"${qst.promoting ? " disabled" : ""}>${busy ? "Promoting..." : "Promote"}</button></td></tr>`;
}

// The table under the chips: the first CAND_SHOWN rows the filter keeps, and what it leaves out.
const CAND_SHOWN = 30;
function qCandBody() {
  const c = qst.cands, rows = qCandShown();
  if (!rows.length) return `<div class="card muted">No row matches.</div>`;
  // A chip's count is over every row; the page holds at most CAND_SHOWN of each.
  const chip = (c.reasons || []).find((r) => r.reason === qst.candReason);
  const of = qst.candQ.trim() ? rows.length : chip ? chip.rows : qst.candReason === "_takes" ? c.clear : c.total;
  const more = of - Math.min(rows.length, CAND_SHOWN);
  return `<div class="panel scroll"><table class="tbl"><tr><th class="n">#</th><th>project</th><th>key</th><th>task</th><th>start</th><th>why</th><th></th></tr>` +
    `${rows.slice(0, CAND_SHOWN).map(qCandRow).join("")}</table></div>` +
    (more > 0 ? `<div class="muted">+${more} more${qst.candQ.trim() ? " (the search reads the rows this page holds)" : ""}</div>` : "");
}

// The Candidates fold: counts in the heading; chips for each reason a row is blocked, with how
// many it blocks; a search box; the projects worked on today that no worker covers; the rows.
function qCandidates() {
  const k = "sec:candidates", open = !!qst.open[k];
  const c = qst.cands;
  const count = c ? `${c.total}, ${c.auto} auto${c.urgent_blocked ? `, <span class="qbad">${c.urgent_blocked} urgent blocked</span>` : ""}`
    : qst.candErr ? "unread" : "reading";
  let body;
  if (qst.candErr) body = `<div class="panel down">No candidates: ${esc(qst.candErr)}</div>`;
  else if (!c) body = `<div class="card muted">Reading fleet-dispatch suggest...</div>`;
  else if (!c.rows.length) body = `<div class="card muted">No open board row to start.</div>`;
  else {
    const chip = (v, label) => `<button class="btn sm${v === qst.candReason ? " primary" : ""}" data-creason="${esc(v)}">${esc(label)}</button>`;
    const chips = [chip("", `all ${c.total}`), chip("_takes", `nothing blocks it ${c.clear}`),
      ...(c.reasons || []).map((r) => chip(r.reason, `${r.reason} ${r.rows}`))].join(" ");
    const gap = (c.uncovered || []).length
      ? `<div class="cline warn">Worked on today, and no worker covers a row: ${c.uncovered.map(esc).join(", ")}</div>` : "";
    body = `<div class="card qcfilter"><div class="opts"><input id="qc-q" placeholder="search task, project, why" value="${esc(qst.candQ)}">${chips}</div></div>` +
      `${gap}<div id="qc-body">${qCandBody()}</div>`;
  }
  const msg = qst.candMsg ? `<div class="err">${esc(qst.candMsg)}</div>` : "";
  return `<details class="csec" data-k="${k}"${open ? " open" : ""}><summary><h2 class="sec">Candidates ` +
    `<span class="muted">(${count})</span></h2></summary>${msg}${body}</details>`;
}

async function qPromote(i) {
  const c = qCandAll()[i];
  if (!c || qst.promoting) return;
  qst.promoting = c.key; qst.candMsg = "";
  renderQueueList();
  try {
    // The board's Start: fleet-dispatch promote, as board.js and the hub TUI's p run it.
    const r = await post("/api/board", { verb: "start", profile: c.profile, project: c.project, lane: c.lane, raw: c.text });
    qst.candMsg = (r && r.out) || `Promoted ${c.key}.`;
  } catch (e) {
    qst.candMsg = e.message;
  }
  qst.promoting = null;
  renderQueueList();
  refreshQueue();
  refreshCands();
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
  if (t.closest("[data-home]")) { e.preventDefault(); setTab("home"); return; }
  if (t.dataset.promote) { qPromote(Number(t.dataset.promote)); return; }
  if (t.dataset.creason != null) { qst.candReason = t.dataset.creason; renderQueueList(); return; }
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
$("queue").addEventListener("input", (e) => {
  if (e.target.id === "qc-q") { qst.candQ = e.target.value; const b = $("qc-body"); if (b) b.innerHTML = qCandBody(); return; }
  if (e.target.closest(".qadd")) qSaveDraft();
});
$("queue").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) qst.open[e.target.dataset.k] = e.target.open;
}, true);
$("queue").addEventListener("keydown", (e) => {
  if (e.target.id === "q-task" && e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); qAdd(); }
});

TABS.queue = {
  async show() {
    renderQueue();
    refreshQueue();
    refreshCands();
    pollPipeline();
    if (!qst.projects.length) {
      try { qst.projects = await api("/api/queue/projects"); } catch (e) { /* the select stays empty; add says why */ }
      if (st.tab === "queue") { qSaveDraft(); renderQueue(); }
    }
  },
  onEvent(ev) {
    if (ev.kind === "queue" || ev.kind === "resync") refreshQueue();
    if (ev.kind === "resync") refreshPipeline();
  },
};
refreshQueue();
