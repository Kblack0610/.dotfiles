"use strict";
// The Queue tab: agent-queue's items as one table (/api/queue), a box to queue a task, and a
// row's detail, opened under its row, with cancel and re-rank for an active one and the answer
// card for anything its session waits on you for. The table is the shared one
// (table.js): hub-core filters and sorts by the view in the tab's URL query, and the durations
// are its `timing` minutes. Design: ~/.config/agentctl/QUEUE.md. The page never writes the
// store itself; every change goes through agent-queue, and the SSE `queue` event re-reads it.
// Inner tabs (hub_core::layout): Active, Up next and Done 24h are the one table in three scopes
// (hub_core::queue::scope, the `in` the read asks for); Candidates is the ranked board rows
// (/api/queue/candidates, hub-core over fleet-dispatch's snapshot, `as of` its time), each with a
// Promote that is the board's Start, read and drawn only while its inner tab is open; the queue read
// carries its strip flag (`candidates`). The pipeline line leads Active and is read only there.

const Q_PRIORITIES = ["urgent", "high", "low"];
// The line's snapshot is written every 10 minutes; a minute is plenty.
const FLOW_REFRESH_MS = 60e3;
// The queue form's modes in the human's words; the option values stay what agent-queue takes.
const Q_MODE = { oneshot: "Run to PR", plan: "Plan first" };
// Which folds are open, by data-k: a section (`stats`) or a task (`task:<slug>`).
// Re-renders come with every event, so the page keeps what the human folded or opened. Stats
// detail starts open; a task's details start shut.
// items: the rows the view keeps; table: hub-core's controls for them; inner: the inner tab they
// are for; aliases: old section id -> state chip; needs: every item waiting on the human,
// whatever the view; sel: the opened row; candFlag: the Candidates strip's counts; pick: the
// tab was opened by a link that names no inner tab, so the next read lets the server pick one.
// The read is the tab's own (refreshQueue): it also follows old section links and reads the stats.
const qst = tblTab({
  tab: "queue", id: "qt", el: "q-list", on: "queue", scroller: "queue", refresh: () => refreshQueue(), table: (t) => t.table,
  hint: "search, or project:dotfiles kind:fix -acct:k1",
  state: {
    items: null, table: null, inner: "", aliases: {}, needs: 0, openRows: 0, sel: "", candFlag: null, pick: false,
    stats: null, projects: [], busy: false, msg: "", draft: null,
    cands: null, candErr: null, candMsg: "", promoting: null,
    // The Candidates filter: a reason chip ("" is every row) and the search words.
    candReason: "", candQ: "",
    open: {},
  },
  head: (t) => (t.err ? `<div class="panel down">${esc(t.err)}</div>` : "") + innerWrap("queue", "active", qFlow()) + innerWrap("queue", qst.inner, qTableHead()),
  // The table sits in the inner tab its rows are for. Candidates are drawn only with the whole
  // list, and only while their inner tab is open: a repaint while the search box has focus
  // leaves them as they were.
  wrap: (html) => innerWrap("queue", qst.inner, html),
  body: () => qBody(),
  draw: (html) => {
    // A redraw keeps the Candidates search box focused, its caret where it was, and a reply half
    // typed into an answer card.
    const typing = document.activeElement && document.activeElement.id === "qc-q" ? document.activeElement.selectionStart : null;
    $("q-tabs").innerHTML = innerStrip("queue", qFlagged());
    keepTyping("#queue .card", () => { $("q-list").innerHTML = html + (qOn() === "candidates" ? innerWrap("queue", "candidates", qCandidates()) : ""); });
    if (typing != null && $("qc-q")) { $("qc-q").focus(); $("qc-q").setSelectionRange(typing, typing); }
  },
});

// The candidates are fleet-dispatch's snapshot, read on showing the tab and after a promote (which
// takes its row out of the file), never on a queue event.
const refreshCands = coalesce(async () => {
  try { qst.cands = await api("/api/queue/candidates"); qst.candErr = null; } catch (e) { qst.candErr = e.message; }
  if (st.tab === "queue") qst.render();
});

// The inner tab shown: the one the URL names, else Active (a slug or old section id the read
// has not resolved yet reads as Active).
const qOn = () => innerOf("queue", st.tab === "queue" ? st.arg : "")[0];

// The pipeline line (flow.js) leading Active: /api/flow is hub-core's `flow::Rail` over the live
// queue and fleet-bench's snapshot. A queue event re-reads it with the table; the snapshot is a
// file that pushes nothing, so Active also re-reads on a cadence. Off Active nothing reads it
// (dashboards rule 10). node: the step picked.
const qfl = { data: null, err: null, node: "" };
const refreshFlow = coalesce(async () => {
  if (st.tab !== "queue" || qOn() !== "active") return;
  try { qfl.data = await api("/api/flow"); qfl.err = null; } catch (e) { qfl.err = e.message; }
  if (st.tab === "queue") qst.render();
});
const pollFlow = poll("queue", refreshFlow, FLOW_REFRESH_MS);

const qStrip = () => qfl.data ? railHtml(qfl.data.line, qfl.node, qfl.data.grafana)
  : `<div class="flow muted">${qfl.err ? esc(qfl.err) : "reading"}</div>`;

// The strip's amber marks: Active while an item needs you, Candidates while an urgent row is blocked.
const qFlagged = () => [qst.needs && "active", qst.candFlag?.urgent_blocked && "candidates"].filter(Boolean);

// The inner tab the read is for: the one the URL names (Active for a bare `#queue`), or on
// Candidates the one the table last showed. Only a link that names none (`qst.pick`) sends blank,
// so the server picks (the one holding the chip, else the first the search finds a row in, else
// Active); a search typed on a tab stays on it.
function qIn() {
  const arg = st.tab === "queue" ? st.arg : lastInner.queue || "";
  const id = innerOf("queue", arg)[0] === arg ? arg : "";
  if (id === "candidates") return qst.inner;
  return id || (qst.pick ? "" : innerOf("queue", "")[0]);
}

const refreshQueue = coalesce(async () => {
  // The window's line and what sits now, read beside the rows so a tick's answer waits for one read,
  // not two; the list still shows when agent-queue stats fails.
  const stats = api("/api/queue/stats").catch((e) => ({ week: `stats: ${e.message}` }));
  try {
    const p = tblParams(st.views.queue);
    if (qIn()) p.set("in", qIn());
    const d = await api("/api/queue?" + p);
    Object.assign(qst, { items: d.items, table: d.table, inner: d.inner, aliases: d.section_aliases || {}, needs: d.needs_you, openRows: d.open_rows, candFlag: d.candidates || null, err: null });
  } catch (e) { qst.err = e.message; }
  // A link's word that sets the view reads again (`again`), and only that read settles the pick.
  let again = false;
  // A word that is no inner tab: an old section id (`#queue/running`) opens its chip, and so the
  // inner tab holding it.
  if (st.tab === "queue" && st.arg && !homeOf("queue", st.arg)) {
    const arg = st.arg, key = arg.toLowerCase(), chip = Object.hasOwn(qst.aliases, key) ? qst.aliases[key] : "";
    if (chip) {
      st.arg = "";
      if (!tblParams(st.views.queue).get("s")) { setQuery(tblSet(st.views.queue, { s: chip })); again = true; } else { setQuery(st.views.queue); }
    } else if ((qst.items || []).some((i) => i.slug === arg)) {
      // Any other arg is an item (`#queue/<slug>`, a Home row or a session page's link): it opens.
      st.arg = ""; qst.sel = arg; setQuery(st.views.queue);
    } else if (tblParams(st.views.queue).get("q") !== arg) {
      // Not in this view: search for it once, and the read that answers opens it.
      setQuery(tblSet(st.views.queue, { q: arg, s: "" })); again = true;
    } else st.arg = "";
  }
  if (again) { refreshQueue(); return; }
  // A link that names no inner tab shows the one the server picked: the strip, the URL and the
  // tab button's memory follow (Active, the first, is the bare URL), and later reads keep it.
  if (st.tab === "queue" && qst.pick && !st.arg && qst.inner) {
    qst.pick = false;
    st.arg = lastInner.queue = qst.inner === innerOf("queue", "")[0] ? "" : qst.inner;
    if (st.arg) { showUrl(); stripMark($("queue"), "itab", qst.inner); }
  }
  qst.stats = await stats;
  if (st.tab === "queue") renderQueue();
  renderQueueBadge();
  // The line is read once the inner tab is settled, and only on Active (refreshFlow).
  if (st.tab === "queue") pollFlow();
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

// The table's columns: key -> [header, class].
const Q_COLS = {
  state: ["state"], title: ["title"], project: ["project"], in: ["in", "n"], wait: ["wait", "n"], run: ["run", "n"],
  kind: ["kind"], size: ["size"], acct: ["acct"], pr: ["pr"], plan: ["plan"],
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

// The PR cell: hub-core's label as a link (the first PR and "+N" for the rest, every ref on
// hover); a done item with no recorded merge says so on hover.
function qPrCell(i) {
  if (!i.pr) return `<td class="muted">-</td>`;
  const link = i.pr_url ? `<a href="${esc(i.pr_url)}" target="_blank" rel="noopener">${esc(i.pr_label || i.pr)}</a>` : esc(i.pr_label || i.pr);
  const flag = i.state === "done" && i.pr_label && !i.pr_merged ? ` <span class="muted" title="merge not recorded">?</span>` : "";
  return `<td title="${esc(i.pr)}"><div class="clamp">${link}${flag}</div></td>`;
}

// A row, and when it is the opened one its detail under it across every column. The title leads,
// so a glance reads what each item is; its note is the muted second line (the Board's two-line cell).
// Title and note clamp to two lines each, the full text on hover or open; the proof flag goes first
// so the clamp never hides it.
function qRow(i, n) {
  const t = i.timing || {};
  const dash = (v) => (v ? esc(v) : "-");
  const open = i.slug === qst.sel;
  return `<tr class="qr${open ? " sel" : ""}" data-slug="${esc(i.slug)}">${qState(i)}` +
    `<td class="btitle"><div class="bt clamp" title="${esc(i.title || i.slug)}">${qProof(i) ? qProof(i) + " " : ""}${esc(i.title || i.slug)}</div>${i.note ? `<div class="bsum clamp muted" title="${esc(i.note)}">${esc(i.note)}</div>` : ""}</td>` +
    `<td>${tblLink(tblLinks(qst.table, n).project, i.project)}</td>` +
    `<td class="n">${qMin(t.in_state)}</td><td class="n">${qMin(t.wait)}</td><td class="n">${qMin(t.run)}</td>` +
    `<td>${dash(i.type)}</td><td>${dash(i.size)}</td><td>${dash(i.account)}</td>` +
    `${qPrCell(i)}<td class="muted">${dash(i.plan_label)}</td></tr>` +
    (open ? `<tr class="wdet"><td colspan="${Object.keys(Q_COLS).length}">${qDetail(i)}</td></tr>` : "");
}

// The table in its own scroll box, capped at the server's open_rows (or down to the opened row)
// with the rest a click away.
function qBody() {
  const t = qst.table, shown = qst.items || [];
  if (!shown.length) return `<div class="panel">${t.total ? "No item matches." : `Nothing in ${qTitle()}.`}</div>`;
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
  // The strip leads on every path, the loading one too; the add box shows under it on each inner tab.
  el.innerHTML = `<div id="q-tabs">${innerStrip("queue", qFlagged())}</div>` + pfold("q-add", "Add to the queue", qCompose()) + `<div id="q-list"></div>`;
  qst.render();
}

// The fold's title says the worst step even while it is shut.
function qFlowTitle() {
  const r = qfl.data?.line, n = r?.nodes[r.worst];
  const why = n?.stopped ? `${n.label} stopped` : n?.hot ? `${n.label} past its bound` : "";
  return `Pipeline${why ? ` <span class="warn">${esc(why)}</span>` : ""}`;
}
const qFlow = () => pfold("q-flow", qFlowTitle(), `<h2 class="sec" id="sec-flow">Pipeline</h2>${qStrip()}${qFlowTail()}`);
// The table's inner tab by its title; its heading counts what the view keeps of it. A search on
// Done 24h reads every finish the window holds (hub_core::queue::scope), and says so.
const qTitle = () => (homeOf("queue", qst.inner) || [, "Queue"])[1];
const qTableHead = () => `<h2 class="sec" id="sec-${esc(qst.inner)}">${qTitle()} <span class="muted">${qst.table.shown} of ${qst.table.total}` +
  `${qst.inner === "today" && qst.table.q ? ", every finish in the window" : ""}</span></h2>`;

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
    `<td class="wrap"><div class="clamp" title="${esc(c.title)}">${esc(c.title)}</div></td><td class="${cls}">${esc(c.start_label)}</td><td class="wrap muted"><div class="clamp" title="${esc(c.why)}">${esc(c.why)}</div>${blocked ? `<div>${blocked}</div>` : ""}</td>` +
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
  return `<div class="panel scroll"><table class="tbl"><tr><th class="n">#</th><th data-role="glance">project</th><th>key</th><th data-role="lead">task</th><th data-role="glance">start</th><th>why</th><th></th></tr>` +
    `${rows.slice(0, CAND_SHOWN).map(qCandRow).join("")}</table></div>` +
    (more > 0 ? `<div class="muted">+${more} more${qst.candQ.trim() ? " (the search reads the rows this page holds)" : ""}</div>` : "");
}

// The Candidates inner tab: counts in the heading; chips for each reason a row is blocked, with how
// many it blocks; a search box; the projects worked on today that no worker covers; the rows.
function qCandidates() {
  const c = qst.cands;
  const count = c ? `${c.total}, ${c.auto} auto${c.urgent_blocked ? `, <span class="qbad">${c.urgent_blocked} urgent blocked</span>` : ""}${c.as_of ? `, as of ${esc(c.as_of)}` : ""}`
    : qst.candErr ? "unread" : "reading";
  let body;
  if (qst.candErr) body = `<div class="panel down">No candidates: ${esc(qst.candErr)}</div>`;
  else if (!c) body = `<div class="card muted">Reading candidates...</div>`;
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
  return `<h2 class="sec" id="sec-candidates">Candidates <span class="muted">(${count})</span></h2>${msg}${body}`;
}

async function qPromote(i) {
  const c = qCandAll()[i];
  if (!c || qst.promoting) return;
  qst.promoting = c.key; qst.candMsg = "";
  qst.render();
  try {
    // The board's Start: fleet-dispatch promote, as board.js and the hub TUI's p run it.
    const r = await post("/api/board", { verb: "start", profile: c.profile, project: c.project, lane: c.lane, raw: c.text });
    qst.candMsg = (r && r.out) || `Promoted ${c.key}.`;
  } catch (e) {
    qst.candMsg = e.message;
  }
  qst.promoting = null;
  qst.render();
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
  const point = t.closest("[data-rail]");
  if (point) { qfl.node = point.dataset.rail; qst.render(); return; }
  if (t.id === "q-add") { qAdd(); return; }
  // An answer card (a session's dialog or an ask) answers in place, as on Home. Its cards come
  // from st.asks and st.agents, whose own reads redraw the tab, so nothing re-reads the queue here.
  const card = t.closest(".card[data-t], .card[data-id]");
  if (card) { answerCard(card, e); return; }
  if (t.dataset.promote) { qPromote(Number(t.dataset.promote)); return; }
  if (t.dataset.creason != null) { qst.candReason = t.dataset.creason; qst.render(); return; }
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
  if (e.target.id === "qc-q") { qst.candQ = e.target.value; const b = $("qc-body"); if (b) b.innerHTML = qCandBody(); return; }
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
  // `#queue/<slug>` and an old section id stay the arg (app.js innerRoute); refreshQueue resolves them.
  word: true,
  async show() {
    // A link (not the tab button) whose arg is no inner tab: a bare `#queue?s=..`, a slug or an
    // old section id; the read it starts lets the server pick the inner tab.
    qst.pick = st.linked && innerOf("queue", st.arg)[0] !== st.arg;
    renderQueue();
    refreshQueue();
    if (qOn() === "candidates") refreshCands();
    if (!qst.projects.length) {
      try { qst.projects = await api("/api/queue/projects"); } catch (e) { /* the select stays empty; add says why */ }
      if (st.tab === "queue") { qSaveDraft(); renderQueue(); }
    }
  },
  // A strip switch: Candidates draws its reading state and reads its snapshot; a scope reads its
  // rows, without the last scope's chip, which the new one may not have (and Active its line).
  inner(id) {
    if (id === "candidates") { qst.render(); refreshCands(); return; }
    if (tblParams(st.views.queue).get("s")) setQuery(tblSet(st.views.queue, { s: "" }));
    qst.all = false;
    refreshQueue();
  },
  onEvent(ev) {
    if (ev.kind === "queue" || ev.kind === "resync") refreshQueue();
    if (ev.kind === "resync") refreshFlow();
  },
};
refreshQueue();
