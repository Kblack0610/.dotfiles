"use strict";
// The Home tab, the front page: what needs you, what changed since last night, what analysis
// proposes, what runs, the spend and the health strip.
// The list, the session counts and the spend are hub_core::home (/api/home), the same join the hub TUI's Home tab
// draws; this file only lays them out. Needs you is the shared table (table.js, the view in the
// URL); a row opens its record under it, an ask or an open dialog waiting.js's answer card, so it
// is answered in place.

// Prometheus pushes nothing, so the open tab also re-reads on the board's cadence; the fleet
// state, the queue and the asks push file events and re-read on those.
const HOME_REFRESH_MS = 60e3;
// `open` holds the Needs you rows opened under the table, by needKey; `all` lifts its cap.
// `prop`: the proposal row opened and the id whose accept or reject is in flight.
// `night`: Since last night (/api/briefing, hub_core::briefing::night) and its read error;
// `fix`: per area, "busy", or what Queue a fix answered ({ ok, text }).
const hst = { data: null, err: null, open: new Set(), prop: { open: null, busy: null, err: null }, night: null, nightErr: null, fix: {} };

const refreshNight = async () => {
  try {
    const n = await api("/api/briefing");
    if (n.error) { hst.nightErr = n.error; return; }
    // A new window offers every fix again; the last good read stays up under a failed one.
    if (hst.night && hst.night.since !== n.since) hst.fix = {};
    hst.night = n; hst.nightErr = null;
  } catch (e) { hst.nightErr = e.message; }
};

// Every Home read takes a number when it starts. The Proposals fields of an answer apply only
// if no read started after it, so a slow full read cannot put an older search over a newer one.
const PROP_KEYS = ["proposals", "proposals_head", "proposals_table"];
let homeSeq = 0;

// Three tables share Home, so Needs you's view keys carry this prefix (nq, ns, nsort, ndir) in the
// URL and in /api/home, and Running's `r` (rq, rs, rsort, rdir); Proposals came first and keeps the
// plain ones, so links to it stay valid.
const NEED_PRE = "n", RUN_PRE = "r";

// The tables are drawn by drawHome from the one Home read; these keep their views and their
// repaints around a search or dropdown in use. A search in Proposals reads only that section.
const needT = tblTab({
  tab: "home", id: "home-need", el: "home", pre: NEED_PRE, refresh: () => refreshHome(), table: () => hst.data?.table,
  head: () => needsHead(hst.data.table), body: () => needsBody(hst.data), render: () => renderHome(),
});
const runT = tblTab({
  tab: "home", id: "home-run", el: "home", pre: RUN_PRE, refresh: () => refreshHome(), table: () => hst.data?.running_table,
  head: () => runHead(hst.data), body: () => runBody(hst.data), render: () => renderHome(),
});
const propT = tblTab({
  tab: "home", id: "home-prop", el: "home", refresh: () => refreshProposals(), table: () => hst.data?.proposals_table,
  body: () => propBody(hst.data), render: () => renderHome(),
});

const refreshHome = coalesce(async () => {
  const view = new URLSearchParams([NEED_PRE, RUN_PRE, ""].flatMap((pre) => [...tblParams(st.views.home, pre)])).toString();
  const seq = ++homeSeq;
  // The briefing read is the slower one: Home draws without it and again when it answers.
  const night = refreshNight().then(() => { if (st.tab === "home") renderHome(); });
  try {
    const d = await api("/api/home" + (view ? "?" + view : ""));
    if (seq !== homeSeq && hst.data) for (const k of PROP_KEYS) d[k] = hst.data[k];
    hst.data = d; hst.err = null;
    // A row that left the list closes, so a returning id never comes back open or holds the cap.
    const keys = new Set((d.needs || []).map(needKey));
    for (const k of hst.open) if (!keys.has(k)) hst.open.delete(k);
  } catch (e) { hst.err = e.message; }
  if (st.tab === "home") renderHome();
  await night;
});

// A search keystroke or a sort changes only the Proposals section, so it asks for that alone:
// /api/home also reads the queue, its stats, the board and Prometheus (about 1.6s at load 20).
// Before Home has loaded, after a failed proposals read, or if this read fails, the full read
// answers and shows the reason.
const refreshProposals = coalesce(async () => {
  if (!hst.data || hst.data.proposals_failed) return refreshHome();
  const view = tblParams(st.views.home).toString();
  const seq = ++homeSeq;
  let p;
  try { p = await api("/api/home/proposals" + (view ? "?" + view : "")); } catch (e) { console.warn("proposals read:", e); return refreshHome(); }
  if (seq !== homeSeq) return;
  Object.assign(hst.data, p);
  if (st.tab === "home") renderHome();
});

const PROP_COLS = { stream: ["stream"], project: ["project"], proposal: ["proposal"], created: ["age", "n"], verb: ["action", "n"] };

// One row, and under it when opened the record: why, the evidence and what accept runs.
function propRow(p) {
  const busy = hst.prop.busy === p.id ? " disabled" : "";
  const row = `<tr class="prop" data-prop="${esc(p.id)}"><td>${esc(p.stream)}</td><td>${esc(p.project)}</td>` +
    `<td class="wrap">${esc(p.title)}${p.error ? ` <span class="cchip warn">accept failed</span>` : ""}</td><td class="n" title="${esc(p.created)}">${esc(ago(p.created))}</td>` +
    `<td class="n"><button class="btn sm primary" data-accept="${esc(p.id)}"${busy}>Accept</button> ` +
    `<button class="btn sm" data-reject="${esc(p.id)}"${busy}>Reject</button></td></tr>`;
  if (hst.prop.open !== p.id) return row;
  const link = /^https?:\/\//.test(p.evidence) ? `<a href="${esc(p.evidence)}" target="_blank" rel="noopener">${esc(p.evidence)}</a>` : esc(p.evidence);
  const line = (k, v) => v ? `<div><b>${k}</b> ${v}</div>` : "";
  return row + `<tr class="wdet"><td colspan="5">${line("Why", esc(p.why))}${line("Evidence", link)}` +
    `${line("Accept runs", `<code>${esc(p.does)}</code>`)}${line("Last accept failed", esc(p.error || ""))}${line("Expires", esc(p.expires))}</td></tr>`;
}

// The section: one line when nothing is open, else the shared table. The search box keeps
// focus across a refresh because only what is around it repaints (home-prop-*).
function propBody(h) {
  const t = h.proposals_table;
  const rows = h.proposals.slice(0, propT.all ? undefined : h.shown), more = h.proposals.length - rows.length;
  const err = hst.prop.err ? `<div class="cline warn">${esc(hst.prop.err)}</div>` : "";
  return err + (h.proposals.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, PROP_COLS)}${rows.map(propRow).join("")}</table>` +
      tblMore(more, "more") + `</div>`
    : `<div class="panel">No proposal matches.</div>`);
}

function propSection(h) {
  const t = h.proposals_table;
  if (!t.total) return `<h2 class="sec" id="sec-proposals">Proposals</h2><div class="empty">${h.proposals_failed ? "Could not read proposals. The reason is at the top of this page." : "Nothing proposed."}</div>`;
  const body = tblBodyFirst(t, () => propBody(h));
  return `<h2 class="sec" id="sec-proposals">Proposals <span class="muted">${esc(h.proposals_head)}</span></h2>` +
    tblBar("home-prop", t, "search, or stream:dream project:dotfiles") + `<div id="home-prop-body">${body}</div>`;
}

// Accept or reject through agent-propose. What it says on failure stays on the page.
async function propDecide(verb, id) {
  hst.prop.busy = id; hst.prop.err = null;
  renderHome();
  try { await post("/api/proposals/" + verb, { id }); } catch (e) { hst.prop.err = e.message; }
  hst.prop.busy = null;
  refreshHome();
}

const needKey = (n) => `${n.kind}:${n.id}`;

// What a ranked row holds (hub_core::home::Need::holds), or a sheet row's priority: the reason it
// sits where it does. `holds` is the same on a card, where no header names it.
const held = (n) => n.score?.holds || (n.score?.priority ? `#${n.score.priority}` : "");
const holds = (n) => (n.score?.holds ? `holds ${esc(n.score.holds)}` : esc(held(n)));

// A row with no answer card: what it is, how long it has waited, and a way to it.
const CARD_WHAT = {
  nightly: "nightly failed", red: "red now", queue: "queue item", sheet: "your sheet", stopped: "dispatch",
  budget: "budget stop", night: "night task", janitor: "home cluster", mail: "critical mail",
};
function needCard(n) {
  const k = n.need;
  const what = CARD_WHAT[n.kind] || "";
  const id = n.kind === "stopped" || [n.text, n.target, n.project].includes(n.id) ? "" : esc(n.id);
  const band = needBand(k, [esc(n.project), what, id, n.since ? waited(n.since) : "", holds(n)]);
  const live = n.target && st.agents.find((a) => a.target === n.target);
  const btn = live ? `<div class="opts"><button class="btn sm" data-open="${esc(n.target)}">Open session</button></div>`
    : n.kind === "queue" ? `<div class="opts"><button class="btn sm" data-tab="queue">Open the queue</button></div>` : "";
  return `<div class="card need k-${k}" title="${esc(n.target || n.id)}">${band}<div class="ntitle">${esc(n.text)}</div>${btn}</div>`;
}

// An ask or a session dialog the page can answer gets its answer card; the rest a plain card.
function needHtml(n) {
  if (n.kind === "ask") {
    const a = st.asks.find((x) => x.id === n.id);
    if (a) return askCard(a, holds(n));
  }
  if (n.kind === "session") {
    const a = st.agents.find((x) => x.target === n.target && x.question);
    if (a) return sessionCard(a, n.need);
  }
  return needCard(n);
}

// One row of Needs you, and under it the record it opens.
function needRow(n) {
  const k = needKey(n), open = hst.open.has(k);
  const at = n.since ? ` title="${new Date(n.since * 1e3).toISOString()}"` : "";
  const row = `<tr class="jr${open ? " sel" : ""}" data-need="${esc(k)}"><td class="n">${n.rank}</td><td>${esc(NEED_KINDS[n.need])}</td>` +
    `<td>${esc(n.project) || "-"}</td><td class="n"${at}>${n.since ? waited(n.since) : "-"}</td>` +
    `<td class="wrap muted">${esc(held(n)) || "-"}</td><td class="wrap">${esc(n.text)}</td></tr>`;
  return open ? `${row}<tr class="wdet"><td colspan="6">${needHtml(n)}</td></tr>` : row;
}

// The rows in the server's order (hub_core::home::needs ranks them; nothing here re-sorts), the
// rank marked as the sort when none is asked for.
const needCols = (t) => ({ rank: [t.sort ? "rank" : "rank ^", "n"], kind: ["kind"], project: ["project"], waited: ["waited", "n"], holds: ["holds"], what: ["what"] });

// The first `shown` rows (dashboards: capped lists), or down to the last opened one, so a refresh
// that reranks never takes an answer being typed off the page.
function needsBody(h) {
  const t = h.table, rows = h.needs;
  if (!rows.length) return `<div class="empty">${t.total ? "No needs match." : "Nothing waits on you."}</div>`;
  const last = rows.reduce((at, n, i) => (hst.open.has(needKey(n)) ? i + 1 : at), 0);
  const cap = needT.all ? rows.length : Math.max(h.shown, last);
  const more = rows.length - cap;
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, needCols(t))}${rows.slice(0, cap).map(needRow).join("")}</table>` +
    tblMore(more, "more") + `</div>`;
}

// One running item: its row opens its session page, or its queue item when no session runs it,
// and each cell that names a record links to that record's page (`l`: tblLinks for the row).
function runRow(r, l) {
  const p = r.phases;
  const pr = r.pr ? tblLink(l.pr, `${r.pr}${r.pr_state && r.pr_state !== "open" ? ` ${r.pr_state}` : ""}`) : "-";
  return `<tr class="jr" data-slug="${esc(r.slug)}"${r.target ? ` data-target="${esc(r.target)}"` : ""} title="${esc(r.target || r.slug)}">` +
    `<td class="wrap">${tblLink(l.item, r.title)}${p && p.next ? `<div class="muted">next: ${esc(p.next)}</div>` : ""}</td>` +
    `<td>${tblLink(l.project, r.project)}</td><td>${tblLink(l.row, r.row)}</td><td>${tblLink(l.epic, r.epic)}</td>` +
    `<td class="n">${p ? `${p.done}/${p.total}` : "-"}</td><td class="n">${etaText(p, !!r.overdue) || "-"}</td><td>${pr}</td>` +
    `<td>${r.ci ? tblLink(l.ci, r.ci, `ci ${r.ci}`) : "-"}</td><td class="n"${r.started ? ` title="${esc(r.started)}"` : ""}>${r.started ? esc(ago(r.started)) : "-"}</td></tr>`;
}
const RUN_COLS = { item: ["item"], project: ["project"], row: ["row"], epic: ["epic"], phase: ["phase", "n"], eta: ["eta", "n"], pr: ["pr"], ci: ["ci"], since: ["since", "n"] };

// The first `shown` rows (dashboards: capped lists); the whole list of sessions is the Sessions tab.
function runBody(h) {
  const t = h.running_table, rows = h.running;
  if (!rows.length) return `<div class="empty">${t.total ? "No running item matches." : "Nothing running from the queue."}</div>`;
  const cap = runT.all ? rows.length : h.shown, more = rows.length - Math.min(cap, rows.length);
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, RUN_COLS)}${rows.slice(0, cap).map((r, i) => runRow(r, tblLinks(t, i))).join("")}</table>` +
    tblMore(more, "more") + `</div>`;
}

// The session counts head the list they count, linking to the tab that lists the sessions.
function runHead(h) {
  const t = h.running_table;
  const counts = h.sessions ? ` <span class="muted"><a href="#sessions">sessions</a>: ${esc(h.sessions)}</span>` : "";
  return sec("Running", t.shown === t.total ? t.total : `${t.shown} of ${t.total}`, "", counts + ` <a class="muted" href="#sessions?s=running">all in Sessions -&gt;</a>`);
}

// Green collapses to one chip; only what is not green is named.
const LEVEL = { ok: ["ok", "OK"], warn: ["warn", "WARN"], red: ["bad", "RED"], nodata: ["", "NO DATA"] };
function healthHtml(chips) {
  if (!chips.length) return `<span class="muted">no data</span>`;
  const bad = chips.filter((c) => c.level !== "ok");
  if (!bad.length) return cchip("ok", `all green (${chips.length})`);
  return bad.map((c) => cchip(LEVEL[c.level][0], `${esc(c.name)} ${LEVEL[c.level][1]}`)).join(" ") +
    ` <span class="muted">${chips.length - bad.length} green</span>`;
}

const sec = (title, n, body, extra = "") => `<h2 class="sec" id="sec-${title.split(" ")[0].toLowerCase()}">${title}${n != null ? ` <span class="muted">${n}</span>` : ""}${extra}</h2>${body}`;
const needsHead = (t) => sec("Needs you", t.shown === t.total ? t.total : `${t.shown} of ${t.total}`, "");

// Since last night: the briefing's areas that are not ok, each linking to the tab that owns
// its fact, a bad one with Queue a fix; the ok ones are one line (dashboards rule 4).
function nightRow(r) {
  const f = hst.fix[r.name];
  const act = !r.fix ? "" : !f && r.fix.queued ? `<span class="muted">queued ${esc(r.fix.queued)}</span>`
    : f && f !== "busy" ? `<span class="${f.ok ? "muted" : "warn"}">${esc(f.text)}</span>`
    : `<button class="btn sm" data-fix="${esc(r.name)}"${f === "busy" ? " disabled" : ""}>Queue a fix</button>`;
  const det = r.details.length ? `<div class="cline muted">${esc(r.details.join("; "))}</div>` : "";
  return `<div class="cline"><a href="${esc(r.link)}">${esc(r.name)}</a> ${cchip(r.level, r.level)} ${esc(r.line)} ${act}</div>${det}`;
}

function nightSection() {
  const n = hst.night;
  const head = (extra) => `<h2 class="sec" id="sec-night">Since last night${extra ? ` <span class="muted">${extra}</span>` : ""}</h2>`;
  if (!n) return head("") + `<div class="${hst.nightErr ? "cline warn" : "empty"}">${esc(hst.nightErr || "Reading...")}</div>`;
  const errs = [hst.nightErr, ...n.errors].filter(Boolean).map((e) => `<div class="cline warn">${esc(e)}</div>`).join("");
  const ok = n.ok_line ? `<div class="cline muted">${esc(n.ok_line)}</div>` : "";
  return head(`since ${esc(n.since_label)} <a href="#daily">briefing</a>`) + errs + n.rows.map(nightRow).join("") + ok;
}

// Queue a fix: the area's task, worded by hub-core, through the Queue tab's own POST.
async function queueFix(name) {
  const r = hst.night && hst.night.rows.find((x) => x.name === name);
  if (!r || !r.fix) return;
  hst.fix[name] = "busy";
  renderHome();
  try {
    const out = await post("/api/queue", { project: r.fix.project, task: r.fix.task });
    hst.fix[name] = { ok: true, text: `queued ${out.out || ""}`.trim() };
  } catch (e) { hst.fix[name] = { ok: false, text: e.message }; }
  renderHome();
}

function drawHome() {
  const el = $("home"), h = hst.data;
  if (!h) { paint(el, hst.err ? `<div class="err">${esc(hst.err)}</div>` : '<div class="empty">Reading...</div>', askst.open); return; }
  const errs = [hst.err, ...h.errors].filter(Boolean).map((e) => `<div class="cline warn">${esc(e)}</div>`).join("");
  const rt = h.running_table;
  const rbar = rt.total || rt.q || rt.state ? tblBar("home-run", rt, "search, or project:dotfiles ci:fail epic:ar-1292") : "";
  const running = `<div data-tbl="${RUN_PRE}"><div id="home-run-head">${runHead(h)}</div>${rbar}<div id="home-run-body">${tblBodyFirst(rt, () => runBody(h))}</div></div>`;
  const spend = h.spend ? sec("Spend", null, `<div class="cline">${esc(h.spend)} <a href="#costs">Costs</a></div>`) : "";
  const vitals = h.vitals ? sec("Vitals", esc(h.vitals.head), h.vitals.all_ok ? "" : h.vitals.rows.map((r) =>
    `<div class="cline vital${r.level === "warn" ? " warn" : r.level === "nodata" ? " muted" : ""}"><b>${esc(r.question)}</b> ${esc(r.parts.join("; "))}</div>`).join(""),
    h.grafana ? ` <a class="glink" href="${esc(h.grafana)}/d/kb-agents-overview" target="_blank" rel="noopener">graph</a>` : "") : "";
  const t = h.table;
  const body = tblBodyFirst(t, () => needsBody(h));
  const bar = t.total || t.q || t.state ? tblBar("home-need", t, "search, or kind:ask project:dotfiles -kind:red") : "";
  const needs = `<div data-tbl="${NEED_PRE}"><div id="home-need-head">${needsHead(t)}</div>${bar}<div id="home-need-body">${body}</div></div>`;
  // Wide, the flow strip, health, spend and vitals lead, so a long Needs list never buries them.
  // On a phone they are one line saying whether anything is wrong, so Needs you comes first.
  const warn = (t) => `<span class="warn">${esc(t)}</span>`;
  const status = [healthHtml(h.health), h.flow?.bottleneck && warn(h.flow.bottleneck), h.vitals && !h.vitals.all_ok && warn(h.vitals.head)].filter(Boolean).join(" ");
  paint(el, errs + pfold("home-status", status, sec("Flow", null, flowHtml(h.flow, h.grafana)) +
    sec("Health", null, `<div class="cline">${healthHtml(h.health)} <a href="#alerts">Alerts</a></div>`) + spend + vitals) + needs + nightSection() + propSection(h) + running, askst.open);
}
// Session events re-render this often; keep a reply that is being typed, and a table's search
// or dropdown in use, around which only that table's rows and chips repaint.
// The table without focus repaints whole, so a search in one never leaves the other stale.
const HOME_TABLES = { "home-prop": propT, "home-need": needT, "home-run": runT };
const renderHome = () => {
  const busy = Object.values(HOME_TABLES).find((t) => t.repaint());
  if (busy) { for (const [id, t] of Object.entries(HOME_TABLES)) if (t !== busy && $(id + "-body")) t.redraw(); return; }
  keepTyping("#home .card", drawHome);
};

$("home").addEventListener("click", (e) => {
  if (e.target.closest("summary")) return;
  const t = e.target;
  if (t.dataset.fix) { queueFix(t.dataset.fix); return; }
  if (t.dataset.accept) { propDecide("accept", t.dataset.accept); return; }
  if (t.dataset.reject) { propDecide("reject", t.dataset.reject); return; }
  const prow = t.closest("tr.prop");
  if (prow && !t.closest("a")) {
    hst.prop.open = hst.prop.open === prow.dataset.prop ? null : prow.dataset.prop;
    renderHome();
    return;
  }
  const open = e.target.dataset.open;
  if (open) {
    const a = st.agents.find((x) => x.target === open);
    if (a) openAgent(a);
    return;
  }
  if (e.target.dataset.tab) { setTab(e.target.dataset.tab); return; }
  const card = e.target.closest(".card[data-t], .card[data-id]");
  if (card) { answerCard(card, e).then(refreshHome); return; }
  const row = e.target.closest("tr.jr[data-need]");
  if (row) {
    if (!hst.open.delete(row.dataset.need)) hst.open.add(row.dataset.need);
    renderHome();
    return;
  }
  // A Running row opens its session page, or its queue item when no session runs it.
  const run = e.target.closest("tr.jr[data-slug]");
  if (!run || t.closest("a")) return;
  if (run.dataset.target) setTab("sessions", run.dataset.target); else setTab("queue", run.dataset.slug);
});
$("home").addEventListener("keydown", answerOnEnter);
$("home").addEventListener("toggle", (e) => {
  askTrace(e, renderHome);
  if (e.target.dataset && e.target.dataset.k) askst.open[e.target.dataset.k] = e.target.open;
}, true);

const pollHome = poll("home", refreshHome, HOME_REFRESH_MS);
TABS.home = {
  show() { renderHome(); pollHome(); },
  onEvent(ev) { if (st.tab === "home" && ["watch", "queue", "asks", "proposals", "resync"].includes(ev.kind)) refreshHome(); },
};
