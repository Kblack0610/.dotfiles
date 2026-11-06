"use strict";
// The Home tab, the front page: what needs you, what runs, the numbers and the health strip.
// The list and the numbers are hub_core::home (/api/home), the same join the hub TUI's Home tab
// draws; this file only lays them out. Needs you is the shared table (table.js, the view in the
// URL); a row opens its record under it, an ask or an open dialog waiting.js's answer card, so it
// is answered in place.

// Prometheus pushes nothing, so the open tab also re-reads on the board's cadence; the fleet
// state, the queue and the asks push file events and re-read on those.
const HOME_REFRESH_MS = 60e3;
// `open` holds the rows opened under the table, by needKey; `all` lifts its cap.
const hst = { data: null, err: null, open: new Set(), all: false };

const refreshHome = coalesce(async () => {
  const q = tblParams(st.views.home).toString();
  try { hst.data = await api("/api/home" + (q ? "?" + q : "")); hst.err = null; } catch (e) { hst.err = e.message; }
  if (st.tab === "home") renderHome();
});

const needKey = (n) => `${n.kind}:${n.id}`;

// What a ranked row holds (hub_core::home::Need::holds), or a sheet row's priority: the reason it
// sits where it does. `holds` is the same on a card, where no header names it.
const held = (n) => n.score?.holds || (n.score?.priority ? `#${n.score.priority}` : "");
const holds = (n) => (n.score?.holds ? `holds ${esc(n.score.holds)}` : esc(held(n)));

// A row with no answer card: what it is, how long it has waited, and a way to it.
const CARD_WHAT = { nightly: "nightly failed", red: "red now", queue: "queue item", sheet: "your sheet", stopped: "dispatch" };
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
const needCols = (t) => ({ rank: [t.sort ? "rank" : "rank v", "n"], kind: ["kind"], project: ["project"], waited: ["waited", "n"], holds: ["holds"], what: ["what"] });

// The first `shown` rows (dashboards: capped lists), or down to the last opened one, so a refresh
// that reranks never takes an answer being typed off the page.
function needsBody(h) {
  const t = h.table, rows = h.needs;
  if (!rows.length) return `<div class="empty">${t.total ? "No needs match." : "Nothing waits on you."}</div>`;
  const last = rows.reduce((at, n, i) => (hst.open.has(needKey(n)) ? i + 1 : at), 0);
  const cap = hst.all ? rows.length : Math.max(h.shown, last);
  const more = rows.length - cap;
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, needCols(t))}${rows.slice(0, cap).map(needRow).join("")}</table>` +
    (more > 0 ? `<button class="btn sm" data-all="1">+${more} more</button>` : "") + `</div>`;
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

const sec = (title, n, body) => `<h2 class="sec">${title}${n != null ? ` <span class="muted">${n}</span>` : ""}</h2>${body}`;
const needsHead = (t) => sec("Needs you", t.shown === t.total ? t.total : `${t.shown} of ${t.total}`, "");

function drawHome() {
  const el = $("home"), h = hst.data;
  if (!h) { paint(el, hst.err ? `<div class="err">${esc(hst.err)}</div>` : '<div class="empty">Reading...</div>', askst.open); return; }
  const errs = [hst.err, ...h.errors].filter(Boolean).map((e) => `<div class="cline warn">${esc(e)}</div>`).join("");
  // A long list shows its first `shown` rows; the rest fold under "+N more" (dashboards: capped lists).
  const capped = (k, rows, card, word, empty) => !rows.length ? `<div class="empty">${empty}</div>` :
    rows.slice(0, h.shown).map(card).join("") +
    (rows.length > h.shown ? cfold(k, `+${rows.length - h.shown} ${word}`, rows.slice(h.shown).map(card).join(""), askst.open) : "");
  const running = sec("Running", h.running.length, capped("home-running", h.running, runningCard, "more", "Nothing running from the queue."));
  const nums = h.numbers.map((n) => `<span><b>${esc(n.label)}</b> ${esc(n.value)}</span>`).join(", ");
  // The two summary lines lead, so a long Needs list never buries them.
  const top = errs + sec("Numbers", null, `<div class="cline hnum">${nums}</div>`) + sec("Health", null, `<div class="cline">${healthHtml(h.health)}</div>`);
  const t = h.table;
  // A refresh must not take the search box or an open dropdown from under the human, so
  // everything around the control in use repaints and it stays.
  const f = document.activeElement;
  if (f?.closest?.("#home") && (f.id === "home-q" || f.dataset.tq !== undefined)) {
    paint($("home-top"), top);
    paint($("home-nhead"), needsHead(t));
    if (f.id === "home-q") paint($("home-facets"), tblFacets(t));
    paint($("home-chips"), tblChips(t));
    paint($("home-nbody"), needsBody(h), askst.open);
    paint($("home-run"), running, askst.open);
    return;
  }
  const bar = t.total || t.q || t.state ? tblBar("home", t, "search, or kind:ask project:dotfiles -kind:red") : "";
  paint(el, `<div id="home-top">${top}</div><div id="home-nhead">${needsHead(t)}</div>${bar}` +
    `<div id="home-nbody">${needsBody(h)}</div><div id="home-run">${running}</div>`, askst.open);
}
// Session events re-render this often; keep a reply that is being typed.
const renderHome = () => keepTyping("#home .card", drawHome);

// The view changed: the URL follows it and the server applies it.
function homeView(patch) {
  setQuery(tblSet(st.views.home, patch));
  hst.all = false;
  refreshHome();
}

$("home").addEventListener("click", (e) => {
  if (e.target.closest("summary")) return;
  const open = e.target.dataset.open;
  if (open) {
    const a = st.agents.find((x) => x.target === open);
    if (a) { setTab("sessions"); select(a); }
    return;
  }
  if (e.target.dataset.tab) { setTab(e.target.dataset.tab); return; }
  if (e.target.dataset.all) { hst.all = true; renderHome(); return; }
  const v = tblPatch(e);
  if (v) { homeView(v); return; }
  const card = e.target.closest(".card[data-t], .card[data-id]");
  if (card) { answerCard(card, e).then(refreshHome); return; }
  const row = e.target.closest("tr.jr[data-need]");
  if (!row) return;
  if (!hst.open.delete(row.dataset.need)) hst.open.add(row.dataset.need);
  renderHome();
});
// A picked dropdown lets go of focus, so the answer redraws it with the new counts.
for (const ev of ["input", "change"]) $("home").addEventListener(ev, (e) => { const v = tblPatch(e); if (!v) return; if (e.type === "change" && e.target.dataset.tq !== undefined) e.target.blur?.(); homeView(v); });
$("home").addEventListener("keydown", answerOnEnter);
$("home").addEventListener("toggle", (e) => {
  askTrace(e, renderHome);
  if (e.target.dataset && e.target.dataset.k) askst.open[e.target.dataset.k] = e.target.open;
}, true);

const pollHome = poll("home", refreshHome, HOME_REFRESH_MS);
TABS.home = {
  show() { renderHome(); pollHome(); },
  onEvent(ev) { if (st.tab === "home" && ["watch", "queue", "asks", "resync"].includes(ev.kind)) refreshHome(); },
};
