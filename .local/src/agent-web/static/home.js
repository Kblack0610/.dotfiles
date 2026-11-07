"use strict";
// The Home tab, the front page: what needs you, what changed since last night, what analysis
// proposes, what runs, the numbers and the health strip.
// The list and the numbers are hub_core::home (/api/home), the same join the hub TUI's Home tab
// draws; this file only lays them out. An ask or an open dialog is drawn with waiting.js's
// answer card, so it is answered in place.

// Prometheus pushes nothing, so the open tab also re-reads on the board's cadence; the fleet
// state, the queue and the asks push file events and re-read on those.
const HOME_REFRESH_MS = 60e3;
// `prop`: the proposal row opened and the id whose accept or reject is in flight.
// `night`: Since last night (/api/briefing, hub_core::briefing::night) and its read error;
// `fix`: per area, "busy", or what Queue a fix answered ({ ok, text }).
const hst = { data: null, err: null, prop: { open: null, busy: null, err: null, all: false }, night: null, nightErr: null, fix: {} };

const refreshNight = async () => {
  try {
    const n = await api("/api/briefing");
    if (n.error) { hst.nightErr = n.error; return; }
    // A new window offers every fix again; the last good read stays up under a failed one.
    if (hst.night && hst.night.since !== n.since) hst.fix = {};
    hst.night = n; hst.nightErr = null;
  } catch (e) { hst.nightErr = e.message; }
};

const refreshHome = coalesce(async () => {
  const view = tblParams(st.views.home).toString();
  // The briefing read is the slower one: Home draws without it and again when it answers.
  const night = refreshNight().then(() => { if (st.tab === "home") renderHome(); });
  try { hst.data = await api("/api/home" + (view ? "?" + view : "")); hst.err = null; } catch (e) { hst.err = e.message; }
  if (st.tab === "home") renderHome();
  await night;
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
  const rows = h.proposals.slice(0, hst.prop.all ? undefined : h.shown), more = h.proposals.length - rows.length;
  const err = hst.prop.err ? `<div class="cline warn">${esc(hst.prop.err)}</div>` : "";
  return err + (h.proposals.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, PROP_COLS)}${rows.map(propRow).join("")}</table>` +
      (more ? `<button class="btn sm" data-propall="1">+${more} more</button>` : "") + `</div>`
    : `<div class="panel">No proposal matches.</div>`);
}

function propSection(h) {
  const t = h.proposals_table;
  if (!t.total) return `<h2 class="sec">Proposals</h2><div class="empty">${h.proposals_failed ? "Could not read proposals. The reason is at the top of this page." : "Nothing proposed."}</div>`;
  return `<h2 class="sec">Proposals <span class="muted">${esc(h.proposals_head)}</span></h2>` +
    tblBar("home-prop", t, "search, or stream:dream project:dotfiles") + `<div id="home-prop-body">${propBody(h)}</div>`;
}

// Accept or reject through agent-propose. What it says on failure stays on the page.
async function propDecide(verb, id) {
  hst.prop.busy = id; hst.prop.err = null;
  renderHome();
  try { await post("/api/proposals/" + verb, { id }); } catch (e) { hst.prop.err = e.message; }
  hst.prop.busy = null;
  refreshHome();
}

// The Needs you kind of a row hub_core::home sent (waiting.js NEED_KINDS): an ask is a
// question, a session its open dialog's kind, a waiting queue item blocked, a human-sheet row
// to do, a runner at its budget blocked, a stopped dispatch stopped, and the other conditions
// (a failed night item, the janitor, critical mail, a red main, red now) failing.
function needKind(n) {
  if (n.kind === "stopped") return "stopped";
  if (n.kind === "ask") return "ask";
  if (n.kind === "session") {
    const a = st.agents.find((x) => x.target === n.target && x.question);
    return a ? dialog(a.question) : "turn";
  }
  if (n.kind === "queue" || n.kind === "budget") return "blocked";
  if (n.kind === "sheet") return "todo";
  return "red";
}

// What a ranked row holds (hub_core::home::Score::holds), or a sheet row's priority: the
// reason it sits where it does.
const holds = (n) => (n.score && n.score.holds ? `holds ${esc(n.score.holds)}`
  : n.score && n.score.priority ? `#${esc(n.score.priority)}` : "");

// A row with no answer card: what it is, how long it has waited, and a way to it.
const CARD_WHAT = {
  nightly: "nightly failed", red: "red now", queue: "queue item", sheet: "your sheet", stopped: "dispatch",
  budget: "budget stop", night: "night task", janitor: "home cluster", mail: "critical mail",
};
function needCard(n) {
  const k = n.need;
  const what = CARD_WHAT[n.kind] || "";
  const id = n.kind === "stopped" || [n.text, n.target, n.project].includes(n.id) ? "" : esc(n.id);
  const band = needBand(k, [esc(n.project), what, id, n.since ? ago(n.since) : "", holds(n)]);
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
    if (a) return sessionCard(a);
  }
  return needCard(n);
}

// Needs you in the server's order (hub_core::home::needs ranks it; nothing here re-sorts), each
// row carrying its kind as `need`; and one chip per kind with its count, so the list reads at a
// glance.
function needsTally(needs) {
  const c = {};
  for (const n of needs) c[n.need] = (c[n.need] || 0) + 1;
  return NEED_ORDER.filter((k) => c[k]).map((k) => `<span class="nchip k-${k}">${esc(NEED_KINDS[k])} <b>${c[k]}</b></span>`).join("");
}

function runningCard(r) {
  const p = r.phases;
  const chips = [cchip("running", `running${r.started ? ` ${ago(r.started)}` : ""}`)];
  const line = cardLine([esc(r.project), p ? `phase ${p.done}/${p.total}` : "", p && p.next ? `next: ${esc(p.next)}` : "", etaText(p)]);
  return `<div class="card">${cardHead(r.title, chips, r.slug)}${line}</div>`;
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
  const head = (extra) => `<h2 class="sec">Since last night${extra ? ` <span class="muted">${extra}</span>` : ""}</h2>`;
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
  const sec = (title, n, body) => `<h2 class="sec">${title}${n != null ? ` <span class="muted">${n}</span>` : ""}</h2>${body}`;
  const errs = [hst.err, ...h.errors].filter(Boolean).map((e) => `<div class="cline warn">${esc(e)}</div>`).join("");
  // A long list shows its first `shown` rows; the rest fold under "+N more" (dashboards: capped lists).
  const capped = (k, rows, card, word, empty) => !rows.length ? `<div class="empty">${empty}</div>` :
    rows.slice(0, h.shown).map(card).join("") +
    (rows.length > h.shown ? cfold(k, `+${rows.length - h.shown} ${word}`, rows.slice(h.shown).map(card).join(""), askst.open) : "");
  const rows = h.needs.map((n) => ({ ...n, need: needKind(n) }));
  const needs = (rows.length ? `<div class="ntally">${needsTally(rows)}</div>` : "") +
    capped("home-needs", rows, needHtml, "more", "Nothing waits on you.");
  const running = capped("home-running", h.running, runningCard, "more", "Nothing running from the queue.");
  const nums = h.numbers.map((n) => `<span><b>${esc(n.label)}</b> ${esc(n.value)}</span>`).join(", ");
  // The flow strip and the two summary lines lead, so a long Needs list never buries them.
  paint(el, errs + sec("Flow", null, flowHtml(h.flow, h.grafana)) + sec("Numbers", null, `<div class="cline hnum">${nums}</div>`) +
    sec("Health", null, `<div class="cline">${healthHtml(h.health)}</div>`) +
    sec("Needs you", h.needs.length, needs) + nightSection() + propSection(h) + sec("Running", h.running.length, running), askst.open);
}
// Session events re-render this often; keep a reply that is being typed, and the proposal
// search or dropdown in use, around which only the rows and chips repaint.
const renderHome = () => {
  const h = hst.data;
  if (h?.proposals_table.total && $("home-prop-body") && tblRepaint("home-prop", h.proposals_table, () => propBody(h))) return;
  keepTyping("#home .card", drawHome);
};

// The view changed: the URL follows it and the server applies it.
function propView(patch) {
  setQuery(tblSet(st.views.home, patch));
  hst.prop.all = false;
  refreshHome();
}

$("home").addEventListener("click", (e) => {
  if (e.target.closest("summary")) return;
  const t = e.target;
  if (t.dataset.fix) { queueFix(t.dataset.fix); return; }
  if (t.dataset.accept) { propDecide("accept", t.dataset.accept); return; }
  if (t.dataset.reject) { propDecide("reject", t.dataset.reject); return; }
  if (t.dataset.propall) { hst.prop.all = true; renderHome(); return; }
  const v = tblPatch(e);
  if (v) { propView(v); return; }
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
  if (card) answerCard(card, e).then(refreshHome);
});
tblListen($("home"), propView);
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
