"use strict";
// The Queue tab: agent-queue's items as one table (/api/queue), a box to queue a task, and a
// row's detail with cancel and re-rank for an active one. The table is the shared one
// (table.js): hub-core filters and sorts by the view in the tab's URL query, and the durations
// are its `timing` minutes. Design: ~/.config/agentctl/QUEUE.md. The page never writes the
// store itself; every change goes through agent-queue, and the SSE `queue` event re-reads it.
// Below the queue, the Candidates fold: the ranked board rows (/api/queue/candidates, hub-core
// over `fleet-dispatch suggest`), each with a Promote that is the board's Start.

const Q_PRIORITIES = ["urgent", "high", "low"];
// The pipeline line reads 10-minute fleet-bench gauges; a minute is plenty.
const PIPELINE_REFRESH_MS = 60e3;
// The queue form's modes in the human's words; the option values stay what agent-queue takes.
const Q_MODE = { oneshot: "Run to PR", plan: "Plan first" };
// Which folds are open, by data-k: a section (`sec:candidates`) or a task (`task:<slug>`).
// Re-renders come with every event, so the page keeps what the human opened. Candidates start shut.
// items: the rows the view keeps; table: hub-core's controls for them; aliases: old section id ->
// state chip; needs: every item waiting on the human, whatever the view; sel: the opened row.
const qst = {
  items: null, table: null, aliases: {}, needs: 0, openRows: 0, all: false, sel: "",
  err: null, stats: null, projects: [], busy: false, msg: "", draft: null,
  cands: null, candErr: null, candMsg: "", promoting: null,
  // The Candidates filter: a reason chip ("" is every row) and the search words.
  candReason: "", candQ: "", candAutoOpened: false,
  open: { "sec:candidates": false },
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
const pollPipeline = poll("queue", refreshPipeline, PIPELINE_REFRESH_MS);

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
  try {
    const q = tblParams(st.views.queue).toString();
    const d = await api("/api/queue" + (q ? "?" + q : ""));
    Object.assign(qst, { items: d.items, table: d.table, aliases: d.section_aliases || {}, needs: d.needs_you, openRows: d.open_rows, err: null });
  } catch (e) { qst.err = e.message; }
  // An old section id (`#queue/running`) opens the table on its chip; a new one scrolls there.
  if (st.tab === "queue" && st.arg) {
    const chip = qst.aliases[st.arg], arg = st.arg;
    if (chip || ["flow", "table", "candidates"].includes(arg)) {
      st.arg = "";
      if (chip && !tblParams(st.views.queue).get("s")) { setQuery(tblSet(st.views.queue, { s: chip })); refreshQueue(); } else { setQuery(st.views.queue); }
      if (!chip) st.section = arg;
    }
  }
  // The window's line and what sits now; the list still shows when agent-queue stats fails.
  try { qst.stats = await api("/api/queue/stats"); } catch (e) { qst.stats = { week: `stats: ${e.message}` }; }
  if (st.tab === "queue") renderQueue();
  renderQueueBadge();
});

function renderQueueBadge() {
  const n = qst.needs;
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

// The PR: the label and link hub-core words (`owner/repo#N` as agent-land records it), and for a
// done item whether the ledger recorded the merge. An older bare number or URL keeps its link.
function qPr(i) {
  if (!i.pr) return "";
  if (!i.pr_label) return /^https?:\/\//.test(i.pr) ? `<a href="${esc(i.pr)}" target="_blank" rel="noopener">PR</a>` : `PR ${esc(i.pr)}`;
  const link = i.pr_url ? `<a href="${esc(i.pr_url)}" target="_blank" rel="noopener">${esc(i.pr_label)}</a>` : esc(i.pr_label);
  return `PR ${link}${i.state === "done" ? (i.pr_merged ? " merged" : " merge not recorded") : ""}`;
}

// A done item's dollars (hub-core's cost: unknown shows "-", never $0) and the flag for a finish
// that shows nothing for its work.
const qCost = (i) => (i.state === "done" ? `<span title="dollars of the sessions that worked it">${i.cost_label ? esc(i.cost_label) : "-"}</span>` : "");
const qProof = (i) => (i.unproven ? `<span class="qbad" title="finished ok with no PR and no report">! no PR, no proof</span>` : "");

// A duration in minutes, exact: "42m", "1h05", "2d3h"; "-" when the item has not reached the stage.
// Hub-core's `timing` is the only source; the page works nothing out from the stamps.
function qMin(m) {
  if (m == null || isNaN(m)) return "-";
  if (m < 60) return `${m}m`;
  if (m < 1440) return `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}`;
  return `${Math.floor(m / 1440)}d${Math.floor((m % 1440) / 60)}h`;
}

// The table's columns: key -> [header, class]. `qx` columns drop away at phone width (app.css),
// leaving state, in, project and title.
const Q_COLS = {
  state: ["state"], in: ["in", "n"], wait: ["wait", "n qx"], run: ["run", "n qx"], project: ["project"],
  kind: ["kind", "qx"], size: ["size", "qx"], acct: ["acct", "qx"], pr: ["pr", "qx"], title: ["title"],
};

// The state cell: what the item is. A finish says how it ended.
function qState(i) {
  if (i.state === "waiting") return `<td class="warn">needs</td>`;
  if (i.state === "done") {
    const s = i.status || "ok";
    return s === "ok" ? `<td>done</td>` : `<td class="${s === "failed" ? "bad" : "muted"}">${s === "failed" ? "failed" : "cancelled"}</td>`;
  }
  return `<td>${esc(i.state)}</td>`;
}

// The PR cell: hub-core's label as a link; a done item with no recorded merge says so on hover.
function qPrCell(i) {
  if (!i.pr) return `<td class="qx muted">-</td>`;
  const link = i.pr_url ? `<a href="${esc(i.pr_url)}" target="_blank" rel="noopener">${esc(i.pr_label || i.pr)}</a>` : esc(i.pr_label || i.pr);
  const flag = i.state === "done" && i.pr_label && !i.pr_merged ? ` <span class="muted" title="merge not recorded">?</span>` : "";
  return `<td class="qx">${link}${flag}</td>`;
}

function qRow(i) {
  const t = i.timing || {};
  const dash = (v) => (v ? esc(v) : "-");
  return `<tr class="qr${i.slug === qst.sel ? " sel" : ""}" data-slug="${esc(i.slug)}">${qState(i)}` +
    `<td class="n">${qMin(t.in_state)}</td><td class="n qx">${qMin(t.wait)}</td><td class="n qx">${qMin(t.run)}</td>` +
    `<td>${esc(i.project)}</td><td class="qx">${dash(i.type)}</td><td class="qx">${dash(i.size)}</td><td class="qx">${dash(i.account)}</td>` +
    `${qPrCell(i)}<td class="wrap">${esc(i.title || i.slug)}${i.note ? ` <span class="muted">(${esc(i.note)})</span>` : ""}${qProof(i) ? " " + qProof(i) : ""}</td></tr>`;
}

// The table in its own scroll box, capped at the server's open_rows with the rest a click away.
function qBody() {
  const t = qst.table, shown = qst.items || [];
  if (!shown.length) return `<div class="panel">${t.total ? "No item matches." : "Nothing in the queue."}</div>`;
  const rows = qst.all ? shown : shown.slice(0, qst.openRows);
  const more = shown.length - rows.length;
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, Q_COLS)}${rows.map(qRow).join("")}</table>` +
    (more > 0 ? `<button class="btn sm" data-qall="1">+${more} older</button>` : "") + `</div>`;
}

// The stats window's prose, folded under the flow line; the chips above the table are the counts.
function qFlowTail() {
  const s = qst.stats || {};
  const prose = [s.week, s.sitting].filter(Boolean).map(esc).join("<br>");
  const typical = [["typical wait", s.wait_minutes_median], ["typical run", s.run_minutes_median], ["typical to PR", s.to_pr_minutes_median]]
    .filter(([, v]) => v != null).map(([k, v]) => `${k} ${qMin(v)}`).join(", ");
  const body = [prose, typical && esc(typical)].filter(Boolean).join("<br>");
  return body ? cfold("stats", "Stats detail", `<div class="muted">${body}</div>`, qst.open) : "";
}

// An opened row: every header, the stages with the minutes between them (hub-core's `timeline`),
// the task as typed, and for an active item what it needs from the human and its actions.
function qDetail() {
  const i = qst.sel && (qst.items || []).find((x) => x.slug === qst.sel);
  if (!i) return "";
  const active = i.state !== "done";
  const a = qAgent(i);
  const p = a && a.phases;
  const t = i.timing || {};
  const line = (i.timeline || []).map((s) =>
    `${esc(s.step)}${s.at ? " " + stamp(s.at) : s.sha ? " " + esc(s.sha.slice(0, 8)) : ""}${s.gap_min != null ? ` (+${qMin(s.gap_min)})` : ""}`).join(" -> ");
  const prio = i.priority && i.priority !== "low" ? cchip(`prio ${esc(i.priority)}`, esc(i.priority)) : "";
  const prios = Q_PRIORITIES.map((x) => `<option${x === i.priority ? " selected" : ""}>${x}</option>`).join("");
  const acts = active
    ? `<div class="opts">${a && a.question && a.question.kind === "plan" ? "" : approveButtons(a)}${a ? `<button class="btn sm${a.actions && a.actions.includes("approve-plan") ? "" : " primary"}" data-open="${esc(i.slug)}">Open session</button>` : ""}` +
      `<select data-bump="${esc(i.slug)}" title="priority">${prios}</select>` +
      `<button class="btn sm quiet" data-cancel="${esc(i.slug)}">${i.state === "queued" ? "Cancel" : "Stop and cancel"}</button></div>`
    : "";
  return `<h2 class="sec">Item <span class="muted">${esc(i.slug)}</span> <button class="btn sm quiet" data-qclose="1">Close</button></h2>` +
    `<div class="card qitem ${esc(i.state)}">${cardHead(i.title || i.slug, [prio])}` +
    cardLine([esc(i.project), i.harness && `<span title="harness">${esc(i.harness)}</span>`, p ? `phase ${p.done}/${p.total}` : "", active ? etaText(p) : "", qPr(i), qCost(i), qProof(i)]) +
    (line ? `<div class="cline qline">${line}</div>` : "") +
    (i.hold ? `<div class="qhold">Waiting on: ${esc(i.hold)}</div>` : "") + (i.note ? `<div class="qhold">${esc(i.note)}</div>` : "") +
    (active ? qNeeds(i) : "") + (active && p && p.next ? `<div class="qnext">Next: ${esc(p.next)}</div>` : "") +
    cfold(`task:${i.slug}`, "Full task and details", facts([
      ["state", i.state === "done" ? `done, ${i.status || "ok"}` : i.state], ["in state", qMin(t.in_state)], ["wait", qMin(t.wait)], ["run", qMin(t.run)],
      ["project", i.project], ["kind", i.type], ["size", i.size], ["acct", i.account], ["pr", i.pr_label || i.pr],
      ["slug", i.slug], ["mode", [i.mode, i.weight].filter(Boolean).join(", ")], ["tags", i.tags], ["from", i.from],
      ["session", i.session], ["plan", i.plan], ["phases", i.phases],
    ]) + `<div class="q">${esc(i.task || "")}</div>`, qst.open) + acts + `</div>`;
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

function drawQueueList(el) {
  if (!qst.table) { el.innerHTML = `<div class="empty">${qst.err ? esc(qst.err) : "Loading..."}</div>`; return; }
  // A refresh must not take the search box from under the human: with focus in the bar only what
  // is around it repaints.
  if (tblRepaint("qt", qst.table, qBody)) {
    paint($("qt-head"), qTableHead());
    paint($("qt-detail"), qDetail());
    paint($("q-flow"), qFlow());
    return;
  }
  const y = $("queue").scrollTop;
  // A redraw keeps the Candidates search box focused, its caret where it was.
  const typing = document.activeElement && document.activeElement.id === "qc-q" ? document.activeElement.selectionStart : null;
  el.innerHTML = (qst.err ? `<div class="panel down">${esc(qst.err)}</div>` : "") +
    `<div id="q-flow">${qFlow()}</div><div id="qt-head">${qTableHead()}</div>` +
    tblBar("qt", qst.table, "search, or project:dotfiles kind:fix -acct:k1") +
    `<div id="qt-body">${qBody()}</div><div id="qt-detail">${qDetail()}</div>` + qCandidates();
  $("queue").scrollTop = y;
  if (typing != null && $("qc-q")) { $("qc-q").focus(); $("qc-q").setSelectionRange(typing, typing); }
  seekSection();
}

const qFlow = () => `<h2 class="sec" id="sec-flow">Flow</h2>${qPipeline()}${qFlowTail()}`;
const qTableHead = () => `<h2 class="sec" id="sec-table">Queue <span class="muted">${qst.table.shown} of ${qst.table.total}</span></h2>`;

// The view changed: the URL follows it and the server applies it.
function qView(patch) {
  setQuery(tblSet(st.views.queue, patch));
  qst.all = false;
  refreshQueue();
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
  return `<details class="csec" id="sec-candidates" data-k="${k}"${open ? " open" : ""}><summary><h2 class="sec">Candidates ` +
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
  if (t.dataset.qall) { qst.all = true; renderQueueList(); return; }
  if (t.dataset.qclose) { qst.sel = ""; renderQueueList(); return; }
  const v = tblPatch(e);
  if (v) { qView(v); return; }
  if (t.dataset.creason != null) { qst.candReason = t.dataset.creason; renderQueueList(); return; }
  if (t.dataset.open) {
    const a = qAgent((qst.items || []).find((i) => i.slug === t.dataset.open) || {});
    if (a) openAgent(a);
    return;
  }
  if (t.dataset.cancel) {
    // The page has no confirm dialog to lean on, so the button asks twice.
    const s = t.dataset.cancel;
    if (qPending[s]) { delete qPending[s]; qAct("/api/queue/cancel", { slug: s }); return; }
    qPending[s] = true;
    t.textContent = "Click again to cancel";
    setTimeout(() => { delete qPending[s]; }, 4000);
    return;
  }
  // A click on a row (not its PR link) opens its detail; the same row again shuts it.
  const row = t.closest("tr.qr");
  if (row && !t.closest("a")) {
    qst.sel = qst.sel === row.dataset.slug ? "" : row.dataset.slug;
    renderQueueList();
  }
});
tblListen($("queue"), qView);
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
