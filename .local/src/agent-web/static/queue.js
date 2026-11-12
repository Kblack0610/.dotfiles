"use strict";
// The Queue tab: agent-queue's items as one table (/api/queue), a box to queue a task, and a
// row's detail, opened under its row, with cancel and re-rank for an active one and the answer
// card for anything its session waits on you for. The table is the shared one
// (table.js): hub-core filters and sorts by the view in the tab's URL query, and the durations
// are its `timing` minutes. Design: ~/.config/agentctl/QUEUE.md. The page never writes the
// store itself; every change goes through agent-queue, and the SSE `queue` event re-reads it.
// Below the queue, the Candidates fold: the ranked board rows (/api/queue/candidates, hub-core
// over fleet-dispatch's snapshot, `as of` its time) on the shared table under its own view keys
// (cq, cs, csort, cdir), each with a Promote that is the board's Start.

const Q_PRIORITIES = ["urgent", "high", "low"];
// The line's snapshot is written every 10 minutes; a minute is plenty.
const FLOW_REFRESH_MS = 60e3;
// The queue form's modes in the human's words; the option values stay what agent-queue takes.
const Q_MODE = { oneshot: "Run to PR", plan: "Plan first" };
// Which folds are open, by data-k: a section (`sec:candidates`) or a task (`task:<slug>`).
// Re-renders come with every event, so the page keeps what the human folded or opened. Sections
// (Candidates, Stats detail) start open; a task's details start shut.
// items: the rows the view keeps; table: hub-core's controls for them; aliases: old section id ->
// state chip; needs: every item waiting on the human, whatever the view; sel: the opened row.
// The read is the tab's own (refreshQueue): it also follows old section links and reads the stats.
const qst = tblTab({
  tab: "queue", id: "qt", el: "q-list", on: "queue", scroller: "queue", refresh: () => refreshQueue(), table: (t) => t.table,
  hint: "search, or project:dotfiles kind:fix -acct:k1",
  state: {
    items: null, table: null, aliases: {}, needs: 0, openRows: 0, sel: "", dispatch: null,
    stats: null, projects: [], busy: false, msg: "", draft: null,
    open: {},
  },
  head: (t) => (t.err ? `<div class="panel down">${esc(t.err)}</div>` : "") + qFlow() + qTableHead(),
  // Candidates sit under the table and are drawn only with the whole list.
  body: () => qBody(),
  draw: (html) => {
    // Focus in the Candidates' bar: both tables repaint around it. Otherwise a redraw keeps a
    // reply half typed into an answer card.
    if (qcd.repaint()) { qst.redraw(); paint($("qc-sum"), qCandSum()); return; }
    keepTyping("#queue .card", () => { $("q-list").innerHTML = html + qCandidates(); });
  },
});

// The candidates are fleet-dispatch's snapshot, read on showing the tab, on a view change and after
// a promote (which takes its row out of the file), never on a queue event. The server searches every
// row and sends the first page; "+N more" asks for the rest (call).
const CAND_COLS = { rank: ["#", "n"], project: ["project"], key: ["key"], task: ["task"], start: ["start"], why: ["why"], blocked: ["blocked"] };
const qcd = tblTab({
  tab: "queue", id: "qc", el: "qc-fold", on: "queue", pre: "c", api: "/api/queue/candidates", pages: true,
  params: (p, t) => { if (t.all) p.set("call", "1"); },
  hint: "search, or project:dotfiles", state: { msg: "", promoting: null }, open: () => qst.open,
  wrap: (h) => `<div data-tbl="c">${h}</div>`,
  head: (t) => qCandHead(t), body: (t) => qCandBody(t), render: () => qCandPaint(),
});

// The pipeline line (flow.js) above the table: /api/flow is hub-core's `flow::Rail` over the live
// queue and fleet-bench's snapshot. A queue event re-reads it with the table; the snapshot is a
// file that pushes nothing, so the open tab also re-reads on a cadence. node: the step picked.
const qfl = { data: null, err: null, node: "" };
const refreshFlow = coalesce(async () => {
  try { qfl.data = await api("/api/flow"); qfl.err = null; } catch (e) { qfl.err = e.message; }
  if (st.tab === "queue") qst.render();
});
const pollFlow = poll("queue", refreshFlow, FLOW_REFRESH_MS);

const qStrip = () => qfl.data ? railHtml(qfl.data.line, qfl.node, qfl.data.grafana)
  : `<div class="flow muted">${qfl.err ? esc(qfl.err) : "reading"}</div>`;

const refreshQueue = coalesce(async () => {
  // The window's line and what sits now, read beside the rows so a tick's answer waits for one read,
  // not two; the list still shows when agent-queue stats fails.
  const stats = api("/api/queue/stats").catch((e) => ({ week: `stats: ${e.message}` }));
  try {
    const q = tblParams(st.views.queue).toString();
    const d = await api("/api/queue" + (q ? "?" + q : ""));
    Object.assign(qst, { items: d.items, table: d.table, aliases: d.section_aliases || {}, needs: d.needs_you, openRows: d.open_rows, dispatch: d.dispatch || null, err: null });
  } catch (e) { qst.err = e.message; }
  // An old section id (`#queue/running`) opens the table on its chip; a new one scrolls there.
  if (st.tab === "queue" && st.arg) {
    const arg = st.arg, key = arg.toLowerCase(), chip = Object.hasOwn(qst.aliases, key) ? qst.aliases[key] : "";
    if (chip || ["flow", "table", "candidates"].includes(arg)) {
      st.arg = "";
      if (chip && !tblParams(st.views.queue).get("s")) { setQuery(tblSet(st.views.queue, { s: chip })); refreshQueue(); } else { setQuery(st.views.queue); }
      if (!chip) st.section = arg;
    } else if ((qst.items || []).some((i) => i.slug === arg)) {
      // Any other arg is an item (`#queue/<slug>`, a Home row or a session page's link): it opens.
      st.arg = ""; qst.sel = arg; setQuery(st.views.queue);
    } else if (tblParams(st.views.queue).get("q") !== arg) {
      // Not in this view: search for it once on every row (a done item too), and the read that answers opens it.
      setQuery(tblSet(st.views.queue, { q: arg, s: "all" })); refreshQueue();
    } else st.arg = "";
  }
  qst.stats = await stats;
  if (st.tab === "queue") renderQueue();
  renderQueueBadge();
  if (st.tab === "queue") refreshFlow();
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

// What the item's session needs from the human now: the answer card (waiting.js) of each dialog its
// panes show and each ask they filed, answered here as on Home. An ask belongs to the Claude
// session that filed it, never to a tmux name (agent-panel asks.rs). A waiting item with neither
// says where the human has to look instead.
function qNeeds(i) {
  const panes = qPanes(i);
  const asks = st.asks.filter((k) => k.session && panes.some((p) => p.session === k.session));
  const cards = panes.filter((p) => p.question).map((p) => sessionCard(p, dialogKind(p.question), true)).concat(asks.map((k) => askCard(k)));
  if (cards.length) return cards.join("");
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

// The table's columns: key -> [header, class]. The title leads; `#` is the start order of the
// ready items (hub-core `QueueRow::start`), so sorting on it reads what starts next.
const Q_COLS = {
  "#": ["#", "n"], title: ["title"], project: ["project"], priority: ["priority"], state: ["state"], hold: ["hold"],
  from: ["from"], in: ["in", "n"], wait: ["wait", "n"], run: ["run", "n"], pr: ["pr"], row: ["row"],
  kind: ["kind"], size: ["size"], acct: ["acct"], mode: ["mode"], plan: ["plan"],
};

// The state cell: what the item is. A finish says how it ended.
function qState(i) {
  if (i.state === "waiting") return `<td class="warn">needs</td>`;
  if (i.state === "review") return `<td>on a PR</td>`;
  if (i.state === "done") {
    const s = i.status || "ok";
    return s === "ok" ? `<td>done</td>` : `<td class="${s === "failed" ? "bad" : "muted"}">${s === "failed" ? "failed" : "cancelled"}</td>`;
  }
  // Not started is ready or held (hub_core::vocab::QUEUE, the table's legend); a held cell names its hold.
  if (i.state === "queued") return i.hold ? `<td class="warn" title="held: ${esc(i.hold)}">held</td>` : `<td>ready</td>`;
  return `<td>${esc(i.state)}</td>`;
}

// The PR cell: hub-core's label as a link; a done item with no recorded merge says so on hover.
function qPrCell(i) {
  if (!i.pr) return `<td class="muted">-</td>`;
  const link = i.pr_url ? `<a href="${esc(i.pr_url)}" target="_blank" rel="noopener">${esc(i.pr_label || i.pr)}</a>` : esc(i.pr_label || i.pr);
  const flag = i.state === "done" && i.pr_label && !i.pr_merged ? ` <span class="muted" title="merge not recorded">?</span>` : "";
  return `<td>${link}${flag}</td>`;
}

// What a held item waits on (hub-core `Item::held_on`), the whole hold on hover; an item it
// waits after opens that item's row.
function qHoldCell(i) {
  if (!i.held_on) return `<td class="muted">-</td>`;
  // `after a b`: each slug it waits on opens that item.
  const m = /^after (.+)$/.exec(i.held_on);
  const text = m ? `after ${m[1].split(" ").map((s) => tblLink(`#queue/${encodeURIComponent(s)}`, s)).join(" ")}` : esc(i.held_on);
  return `<td title="${esc(i.hold || "")}">${text}</td>`;
}

// A row, and when it is the opened one its detail under it across every column. The title leads,
// so a glance reads what each item is; its note is the muted second line (the Board's two-line cell).
function qRow(i, n) {
  const t = i.timing || {};
  const dash = (v) => (v ? esc(v) : "-");
  const open = i.slug === qst.sel;
  const links = tblLinks(qst.table, n);
  return `<tr class="qr${open ? " sel" : ""}" data-slug="${esc(i.slug)}"><td class="n">${i.start ?? ""}</td>` +
    `<td class="btitle"><div class="bt">${esc(i.title || i.slug)}${qProof(i) ? " " + qProof(i) : ""}</div>${i.note ? `<div class="bsum muted" title="${esc(i.note)}">${esc(i.note)}</div>` : ""}</td>` +
    `<td>${tblLink(links.project, i.project)}</td><td${i.priority === "urgent" ? ` class="warn"` : ""}>${dash(i.priority)}</td>${qState(i)}${qHoldCell(i)}<td>${dash(i.source)}</td>` +
    `<td class="n">${qMin(t.in_state)}</td><td class="n">${qMin(t.wait)}</td><td class="n">${qMin(t.run)}</td>` +
    `${qPrCell(i)}<td>${tblLink(links.row, i.row_id)}</td><td>${dash(i.type)}</td><td>${dash(i.size)}</td><td>${dash(i.account)}</td>` +
    `<td class="muted">${dash(i.mode)}</td><td class="muted">${dash(i.plan_label)}</td></tr>` +
    (open ? `<tr class="wdet"><td colspan="${Object.keys(Q_COLS).length}">${qDetail(i)}</td></tr>` : "");
}

// The table in its own scroll box, capped at the server's open_rows (or down to the opened row)
// with the rest a click away.
function qBody() {
  const t = qst.table, shown = qst.items || [];
  if (!shown.length) return `<div class="panel">${t.total ? "No item matches." : "Nothing in the queue."}</div>`;
  const last = shown.findIndex((i) => i.slug === qst.sel) + 1;
  const rows = qst.all ? shown : shown.slice(0, Math.max(qst.openRows, last));
  const more = shown.length - rows.length;
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, Q_COLS)}${rows.map(qRow).join("")}</table>` +
    tblMore(more) + `</div>`;
}

// The stats window's prose, a fold under the flow line that starts open; the chips above the table are the counts.
function qFlowTail() {
  const s = qst.stats || {};
  const prose = [s.week, s.sitting].filter(Boolean).map(esc).join("<br>");
  const typical = [["typical wait", s.wait_minutes_median], ["typical run", s.run_minutes_median], ["typical to PR", s.to_pr_minutes_median]]
    .filter(([, v]) => v != null).map(([k, v]) => `${k} ${qMin(v)}`).join(", ");
  const body = [prose, typical && esc(typical)].filter(Boolean).join("<br>");
  return body ? cfold("stats", "Stats detail", `<div class="muted">${body}</div>`, qst.open, true) : "";
}

// What the item names, each to its page (hub-core Item::links): session, project, row, each PR and its CI runs.
const qLinks = (i) => ((i.links || []).length ? `<div class="cline qlinks">${i.links.map((l) => `${l.what === "ci" ? "" : esc(l.what) + " "}${tblLink(l.href, l.text)}`).join(", ")}</div>` : "");

// An opened row, drawn under it: every header, the stages with the minutes between them (hub-core's `timeline`),
// the task as typed, and for an active item what it needs from the human and its actions.
function qDetail(i) {
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
  return `<div class="card qitem ${esc(i.state)}">${cardHead(i.title || i.slug, [prio])}` +
    cardLine([esc(i.project), i.harness && `<span title="harness">${esc(i.harness)}</span>`, p ? `phase ${p.done}/${p.total}` : "", active ? etaText(p) : "", qPr(i), qCost(i), qProof(i)]) + qLinks(i) +
    (line ? `<div class="cline">${line}</div>` : "") +
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
    qst.render();
    return;
  }
  if (qst.repaint()) return;
  el.innerHTML = pfold("q-add", "Add to the queue", qCompose()) + `<div id="q-list"></div>`;
  qst.render();
}

// The worst step hues the head, so a phone's shut fold still says so, and is a line under it.
// The fold line is the head itself, so the open fold does not say Pipeline twice.
function qFlow() {
  const r = qfl.data?.line, n = r?.nodes[r.worst];
  const why = n?.stopped ? `${n.label} stopped` : n?.hot ? `${n.label} past its bound` : "";
  return pfold("q-flow", secHead("flow", "Pipeline", null, why ? "warn" : null), (why ? `<div class="cline warn">${esc(why)}</div>` : "") + qStrip() + qFlowTail(), true);
}
// The heading, then the last dispatch pass's verdict (hub-core `capacity::Dispatch`), amber when held.
const qTableHead = () => secHead("table", "Queue", tblCount(qst.table)) +
  (qst.dispatch ? `<div class="cline qdispatch${qst.dispatch.warn ? " warn" : ""}">${esc(qst.dispatch.line)}</div>` : "");

// One ranked row: rank, project, key, title, how it would start (hub-core's label) with its
// Promote, why, and each reason nothing would start it.
function qCandRow(c, L) {
  const busy = qcd.promoting === c.rank;
  const blocked = (c.blocked || []).map((b) => `<span class="cchip ${c.prio === 0 ? "bad" : "warn"}">${esc(b)}</span>`).join(" ");
  return `<tr><td class="n">${c.rank}</td><td>${tblLink(L.project, c.project)}</td><td>${esc(c.key)}</td><td class="wrap">${esc(c.title)}</td>` +
    `<td class="${c.held ? "warn" : ""}">${esc(c.start_label)} <button class="btn sm" data-promote="${c.rank}"${qcd.promoting ? " disabled" : ""}>${busy ? "Promoting..." : "Promote"}</button></td>` +
    `<td class="wrap muted">${esc(c.why)}</td><td>${blocked || "-"}</td></tr>`;
}

function qCandBody(t) {
  const d = t.data, v = d.table, rows = d.rows || [];
  if (!rows.length) return `<div class="card muted">${v.total ? "No row matches." : "No open board row to start."}</div>`;
  return `<div class="panel scroll"><table class="tbl">${tblHead(v, CAND_COLS)}${rows.map((c, i) => qCandRow(c, tblLinks(v, i))).join("")}</table>` +
    tblMore(d.more, "more") + `</div>`;
}

// Over the bar: a failed read, urgent rows blocked, a promote's answer, the projects worked on today
// that no worker covers, and the auto count with the read time.
function qCandHead(t) {
  const d = t.data, gap = d.uncovered || [];
  return (t.err ? `<div class="panel down">No candidates: ${esc(t.err)}</div>` : "") +
    (d.urgent_blocked ? `<div class="cline warn">${d.urgent_blocked} urgent blocked</div>` : "") +
    (t.msg ? `<div class="err">${esc(t.msg)}</div>` : "") +
    (gap.length ? `<div class="cline warn">Worked on today, and no worker covers a row: ${gap.map(esc).join(", ")}</div>` : "") +
    `<div class="cline muted"><b>auto</b> ${d.auto}${d.as_of ? `, <b>as of</b> ${esc(d.as_of)}` : ""}</div>`;
}

// The fold: its head counts the rows the view keeps, red on a failed read, amber on urgent rows blocked.
function qCandSum() {
  const v = qcd.data?.table;
  return secHead("", "Candidates", v ? tblCount(v) : null, qcd.err ? "bad" : qcd.data?.urgent_blocked ? "warn" : null);
}
const qCandFold = () => (qcd.data ? qcd.html() : qcd.err ? `<div class="panel down">No candidates: ${esc(qcd.err)}</div>` : `<div class="card muted">Reading candidates...</div>`);
function qCandidates() {
  const k = "sec:candidates";
  return `<details class="csec" id="sec-candidates" data-k="${k}"${secOpen(qst.open, k) ? " open" : ""}><summary id="qc-sum">${qCandSum()}</summary>` +
    `<div id="qc-fold">${qCandFold()}</div></details>`;
}

// A read of the candidates repaints their fold alone, so the queue's search box and a reply half
// typed in an answer card are left as they are; with focus in their own bar, only around it.
function qCandPaint() {
  if (st.tab !== "queue") return;
  if (!$("qc-fold")) { qst.render(); return; }
  paint($("qc-sum"), qCandSum());
  if (!qcd.repaint()) paint($("qc-fold"), qCandFold(), qst.open);
}

// A row is found by its rank, unique in a snapshot; a key is a row's text when it has no id.
async function qPromote(rank) {
  const c = (qcd.data?.rows || []).find((r) => r.rank === rank);
  if (!c || qcd.promoting) return;
  qcd.promoting = rank; qcd.msg = "";
  qcd.render();
  try {
    // The board's Start: fleet-dispatch promote, as board.js and the hub TUI's p run it.
    const r = await post("/api/board", { verb: "start", profile: c.profile, project: c.project, lane: c.lane, raw: c.text });
    qcd.msg = (r && r.out) || `Promoted ${c.key}.`;
  } catch (e) {
    qcd.msg = e.message;
  }
  qcd.promoting = null;
  qcd.render();
  refreshQueue();
  qcd.refresh();
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
  const point = t.closest("[data-rail]");
  if (point) { qfl.node = point.dataset.rail; qst.render(); return; }
  if (t.id === "q-add") { qAdd(); return; }
  // An answer card (a session's dialog or an ask) answers in place, as on Home. Its cards come
  // from st.asks and st.agents, whose own reads redraw the tab, so nothing re-reads the queue here.
  const card = t.closest(".card[data-t], .card[data-id]");
  if (card) { answerCard(card, e); return; }
  if (t.dataset.promote) { qPromote(Number(t.dataset.promote)); return; }
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
    qst.render();
  }
});
$("queue").addEventListener("change", (e) => {
  const t = e.target;
  if (t.dataset.bump) { qAct("/api/queue/bump", { slug: t.dataset.bump, priority: t.value }); return; }
  if (t.closest(".qadd")) qSaveDraft();
});
$("queue").addEventListener("input", (e) => {
  if (e.target.closest(".qadd")) qSaveDraft();
});
$("queue").addEventListener("toggle", (e) => {
  // An answer card's folds are waiting.js's (askst.open), and its Full log reads on opening.
  const card = e.target.closest && e.target.closest(".card[data-t], .card[data-id]");
  if (card) { askTrace(e, () => qst.render()); if (e.target.dataset.k) askst.open[e.target.dataset.k] = e.target.open; return; }
  if (e.target.dataset && e.target.dataset.k) qst.open[e.target.dataset.k] = e.target.open;
}, true);
$("queue").addEventListener("keydown", (e) => {
  if (e.target.id === "q-task" && e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); qAdd(); return; }
  answerOnEnter(e);
});

TABS.queue = {
  async show() {
    renderQueue();
    refreshQueue();
    qcd.refresh();
    pollFlow();
    if (!qst.projects.length) {
      try { qst.projects = await api("/api/queue/projects"); } catch (e) { /* the select stays empty; add says why */ }
      if (st.tab === "queue") { qSaveDraft(); renderQueue(); }
    }
  },
  onEvent(ev) {
    if (ev.kind === "queue" || ev.kind === "resync") refreshQueue();
    if (ev.kind === "resync") refreshFlow();
  },
};
// The nav badge needs one read on any tab. It waits for app.js's route (whose listener runs first:
// app.js loads before this file) so a linked view (`#queue?s=ready`) reads once, with its view,
// and the Queue tab's own show() makes that read there.
document.addEventListener("DOMContentLoaded", () => { if (st.tab !== "queue") refreshQueue(); });
