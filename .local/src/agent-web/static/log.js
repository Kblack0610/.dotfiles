"use strict";
// The Log tab: the hub's Log tab (Prefix i, then 6) for the browser. It reads day-log's
// records through /api/log and /api/log/history; every number here is in the record already.

// The charts show this many days; the day picker can step back through the fetched history.
const LOG_CHART_DAYS = 30;
const LOG_HISTORY_DAYS = 120;
const lst = { day: null, rec: null, hist: [], err: null, open: {} };

const refreshLog = coalesce(async () => {
  try {
    const [rec, hist] = await Promise.all([
      api("/api/log" + (lst.day ? "?date=" + lst.day : "")),
      api("/api/log/history?days=" + LOG_HISTORY_DAYS),
    ]);
    Object.assign(lst, { rec, hist, err: null });
  } catch (e) { lst.err = e.message; }
  if (st.tab === "log") renderLog();
});

const shownDay = () => (lst.rec && lst.rec.date) || lst.day;
// The day a past-day link, the stepper, the keys and the chart bars all write: Work's `wday`. The
// shown day stays up until the next one arrives, so stepping never flashes or jumps.
const workDay = () => new URLSearchParams(st.views.log || "").get("wday") || "";
const urlDay = () => { const d = workDay(); return /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : null; };
function syncDay() { const d = urlDay(); if (d !== lst.day) { lst.day = d; refreshLog(); } }
function goDay(d) { wrk.view({ day: d || "today" }); }
function stepDay(n) {
  const ds = lst.hist.map((r) => r.date), i = ds.indexOf(shownDay());
  const j = i + n;
  if (i >= 0 && j >= 0 && j < ds.length) goDay(j === ds.length - 1 ? null : ds[j]);
}

const hm = (iso) => clock(new Date(iso).getTime());
const weekday = (d) => new Date(d + "T12:00").toLocaleDateString(undefined, { weekday: "short" });

// Areas keep one colour across the whole window: the top slots go to the busiest areas.
function areaColors(rows) {
  const tot = {};
  for (const r of rows) for (const [a, n] of Object.entries(r.areas)) tot[a] = (tot[a] || 0) + n;
  const top = Object.keys(tot).sort((a, b) => tot[b] - tot[a] || a.localeCompare(b)).slice(0, 3);
  return { top, of: (a) => (top.includes(a) ? SLOTS[top.indexOf(a)] : OTHER) };
}

function historyCharts(sel) {
  const rows = lst.hist.slice(-LOG_CHART_DAYS);
  if (!rows.length) return "";
  const ac = areaColors(rows);
  const lab = (d, i) => (i % 5 === 0 || d === sel ? d.slice(8) : "");
  const merged = columns(rows.map((r, i) => {
    const other = Object.entries(r.areas).filter(([a]) => !ac.top.includes(a)).reduce((s, [, n]) => s + n, 0);
    return {
      key: r.date, label: lab(r.date, i),
      tip: `${weekday(r.date)} ${r.date}: ${r.merged} merged in ${r.repos} repo(s)\n` + Object.entries(r.areas).sort((a, b) => b[1] - a[1]).map(([a, n]) => `${a} ${n}`).join("\n"),
      segs: [...ac.top.map((a) => ({ v: r.areas[a] || 0, color: ac.of(a) })), { v: other, color: OTHER }],
    };
  }), { sel });
  return `<div class="panel"><h3>Merged per day ${legend([...ac.top.map((a) => [a, ac.of(a)]), ["Other", OTHER]])}</h3>${merged}</div>`;
}

// Projects keep their colour for the day: the top slots go to the busiest (rec.projects is
// hub_core::boards::project_order, merges first), the rest share Other.
function projColors(rec) {
  const top = (rec.projects || []).slice(0, SLOTS.length);
  return { top, of: (p) => (top.includes(p) ? SLOTS[top.indexOf(p)] : OTHER) };
}

// Merges per local hour, one stacked column per hour coloured by project, from the grid
// hub_core::boards::merges_by_hour serves as rec.hours.
function byHour(rec) {
  const g = rec.hours || { hours: [], rows: [] }, pc = projColors(rec);
  const hh = (h) => String(h).padStart(2, "0");
  const cols = Array.from({ length: 24 }, (_, h) => {
    const i = g.hours.indexOf(h);
    const at = g.rows.map((r) => [r.project, i < 0 ? 0 : r.counts[i]]).filter(([, n]) => n);
    const total = at.reduce((a, [, n]) => a + n, 0);
    const other = at.filter(([p]) => !pc.top.includes(p)).reduce((a, [, n]) => a + n, 0);
    return {
      key: "h" + h, label: h % 3 === 0 ? hh(h) : "",
      tip: `${hh(h)}:00 ${total} merged` + at.map(([p, n]) => `\n${p} ${n}`).join(""),
      segs: [...pc.top.map((p) => ({ v: at.find(([q]) => q === p)?.[1] || 0, color: pc.of(p) })), { v: other, color: OTHER }],
    };
  });
  const merged = new Set(g.rows.map((r) => r.project));
  const items = [...pc.top.filter((p) => merged.has(p)).map((p) => [p, pc.of(p)]), ...(g.rows.some((r) => !pc.top.includes(r.project)) ? [["Other", OTHER]] : [])];
  return { chart: columns(cols, { height: 110 }), legend: items.length ? legend(items) : "" };
}

// What waits on the human is Home's to show and answer; the day says how much and links there.
const waiting = (n) => (n ? `<div class="badge-line"><a href="#" data-asks><span class="chip sm" style="--c:var(--b-needs)">${n} waiting on you</span> answer on Home</a></div>` : "");

// A session leads with what it works on (its plan's name, hub_core::boards::log_view); on a
// phone the row is that line plus phase, PRs and cost, and a tap shows the rest.
function benchTable(rec) {
  const ss = ((rec.bench || {}).sessions || []).slice().sort((a, b) => (b.cost_usd || 0) - (a.cost_usd || 0));
  if (!ss.length) return "";
  const h = (label, role, n) => `<th${n ? ' class="n"' : ""}${role ? ` data-role="${role}"${role === "glance" ? " data-named" : ""}` : ""}>${label}</th>`;
  const head = h("what", "lead") + h("phase", "glance", 1) + h("PRs", "glance", 1) + h("working", "", 1) + h("waiting", "", 1) + h("stalled", "", 1) + h("CI reds", "", 1) + h("peak ctx", "", 1) + h("cost", "glance", 1) + h("session");
  const row = (s) => `<tr><td class="wrap" title="${esc(s.plan || "")}">${esc(s.name || s.plan || shortTarget(s.target))}</td><td class="n">${esc(s.phase || "-")}</td><td class="n">${s.prs_merged ?? "-"}</td><td class="n">${s.working_h ?? "-"}h</td><td class="n">${s.waiting_h ?? "-"}h</td><td class="n">${s.stalled_h ?? "-"}h</td><td class="n">${s.ci_reds ?? "-"}</td><td class="n">${s.peak_k ?? "-"}k</td><td class="n">${usd(s.cost_usd)}</td><td class="muted" title="${esc(s.target)}">${esc(clip(shortTarget(s.target), 30))}</td></tr>`;
  return `<h2 class="sec">Sessions <span class="muted">${ss.length}</span></h2><div class="panel scroll"><table class="tbl"><tr>${head}</tr>${ss.map(row).join("")}</table></div>`;
}

function renderLog() {
  const el = $("log-day");
  if (lst.err && !lst.rec) { el.innerHTML = `<div class="empty">${esc(lst.err)}</div>`; return; }
  if (!lst.rec) { el.innerHTML = '<div class="empty">Loading...</div>'; return; }
  const rec = lst.rec, day = rec.date;
  const ds = lst.hist.map((r) => r.date), i = ds.indexOf(day);
  const total = (rec.usage || []).find((u) => u.project === "TOTAL") || {};
  const w = rec.waiting || {};
  const nWait = (w.main || []).length + (w.needs || []).length + (w.asks || []).length;
  const repos = new Set((rec.merged || []).map((m) => m.repo)).size;
  let html = `<div class="bhead daynav">
    <span><button class="btn" data-step="-1"${i > 0 ? "" : " disabled"}>Previous day</button>
    <b>${weekday(day)} ${esc(day)}</b> <span class="muted">${rec.live ? "live" : "closed"}, gathered ${rec.gathered_at ? hm(rec.gathered_at) : "?"}</span>
    <button class="btn" data-step="1"${i >= 0 && i < ds.length - 1 ? "" : " disabled"}>Next day</button>
    <button class="btn" data-today${lst.day ? "" : " disabled"}>Today</button></span>
    <span class="muted">[ ] day, t today${(rec.unreadable || []).length ? ", could not read " + esc(rec.unreadable.join(", ")) : ""}</span></div>`;
  html += `<div class="tiles roomy">${tile("MERGED", (rec.merged || []).length, "var(--c1)", `${repos} repo(s)`)}${tile("OPEN", (rec.open || []).length, "var(--b-working)")}${
    tile("WAITING", nWait, nWait ? "var(--b-needs)" : "var(--b-done)", `${(w.main || []).length} nightly, ${(w.asks || []).length} asks`)}${
    tile("SPEND", "on Costs", "var(--c2)", "by project, last 24h", "#costs?by=project&w=24h")}${tile("SESSIONS", total.sessions ?? "-", "var(--c3)")}</div>`;
  if (rec.bench && rec.bench.headline) html += `<div class="headline muted">${esc(rec.bench.headline)}</div>`;
  html += `<div id="sec-history">${historyCharts(day)}</div>`;
  const hours = byHour(rec);
  html += `<div class="panel"><h3>Merged by hour ${hours.legend}</h3>${hours.chart}</div>`;
  html += waiting(nWait);
  html += benchTable(rec);
  const tl = rec.timeline || [];
  if (tl.length) html += `<details class="sec-d" data-k="timeline"${secOpen(lst.open, "timeline") ? " open" : ""}><summary><h2 class="sec">Timeline <span class="muted">${tl.length}</span></h2></summary><div class="panel feed">${tl.slice().reverse().map((l) => `<div class="tl1">${esc(l)}</div>`).join("")}</div></details>`;
  paint(el, html, lst.open);
}

$("log").addEventListener("click", (e) => {
  const t = e.target;
  const step = t.closest("[data-step]");
  if (step) { stepDay(Number(step.dataset.step)); return; }
  if (t.closest("[data-today]")) { goDay(null); return; }
  const col = t.closest(".cc[data-key]");
  if (col && /^\d{4}-/.test(col.dataset.key)) { const ds = lst.hist.map((r) => r.date); goDay(col.dataset.key === ds[ds.length - 1] ? null : col.dataset.key); return; }
  if (t.closest("[data-asks]")) { e.preventDefault(); setTab("home"); }
});
document.addEventListener("keydown", (e) => {
  if (st.tab !== "log" || e.ctrlKey || e.metaKey || e.altKey || e.target.closest("input, textarea, select")) return;
  if (e.key === "[") stepDay(-1);
  else if (e.key === "]") stepDay(1);
  else if (e.key === "t") goDay(null);
});

// Any record written changes the history charts, so a log event refetches both.
const logFeed = pushed("log", ["log"], refreshLog);
TABS.log = {
  show() { syncDay(); renderLog(); logFeed.show(!lst.rec); for (const p of LOG_PARTS) p.show(); seekSection(); },
  onEvent(ev) { logFeed.onEvent(ev); for (const p of LOG_PARTS) p.onEvent(ev); },
};
