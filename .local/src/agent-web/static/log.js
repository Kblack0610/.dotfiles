"use strict";
// The Log tab: the hub's Log tab (Prefix i, then 7) for the browser. It reads day-log's
// records through /api/log and /api/log/history; every number here is in the record already.

// The charts show this many days; the day picker can step back through the fetched history.
const LOG_CHART_DAYS = 30;
const LOG_HISTORY_DAYS = 120;
const LOG_OPEN_MERGED = 25;
// A project group shows this many rows and folds the rest (hub_core::home::SHOWN, as Home does).
const LOG_GROUP_SHOWN = 8;
// The legend key that stands for every project past the colour slots.
const LOG_OTHER = "\u0000other";
// proj: the project the legend filters the lists to (LOG_OTHER for the Other group), or null.
const lst = { day: null, rec: null, hist: [], err: null, proj: null, open: {} };

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
// The shown day stays up until the next one arrives, so stepping never flashes or jumps.
// A new day drops the legend pick: its projects are not the last day's.
function goDay(d) { lst.day = d; lst.proj = null; refreshLog(); }
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
  return { top, of: (p) => (top.includes(p) ? SLOTS[top.indexOf(p)] : OTHER), key: (p) => (top.includes(p) ? p : LOG_OTHER) };
}
const projLabel = (k) => (k === LOG_OTHER ? "Other" : k);

// Merges per local hour, one stacked column per hour coloured by project, from the grid
// hub_core::boards::merges_by_hour serves as rec.hours. The legend filters the lists below.
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
  const keys = [...pc.top.filter((p) => merged.has(p)), ...(g.rows.some((r) => !pc.top.includes(r.project)) ? [LOG_OTHER] : [])];
  const leg = keys.map((k) => `<button class="lg${lst.proj === k ? " on" : ""}" data-proj="${esc(k)}" title="show only ${esc(projLabel(k))}"><i style="background:${k === LOG_OTHER ? OTHER : pc.of(k)}"></i>${esc(projLabel(k))}</button>`).join("");
  return { chart: columns(cols, { height: 110 }), legend: leg ? `<span class="legend">${leg}</span>` : "" };
}

// `by` is what day-log calls the session that landed a PR: a short target ("agent-18") or an
// outcome's title. It links when a live agent still has that target.
function bySession(repo, by) {
  if (!by) return "";
  const a = st.agents.find((x) => { const t = shortTarget(x.target).replace(/:\d+$/, ""); return t === by || t === `${repo}-${by}`; });
  return a ? `<a class="by" href="#" data-target="${esc(a.target)}">${esc(by)}</a>` : `<span class="by">${esc(by)}</span>`;
}

// PRs by project, in rec.projects order, cut to the legend's pick: [[project, prs]].
function projGroups(rec, prs) {
  const pc = projColors(rec), by = new Map((rec.projects || []).map((p) => [p, []]));
  for (const m of prs) { if (!by.has(m.project)) by.set(m.project, []); by.get(m.project).push(m); }
  return [...by].filter(([p, l]) => l.length && (!lst.proj || pc.key(p) === lst.proj));
}
// A PR names its number alone when its repo is the project ("#722"), else "repo#722".
const prRef = (proj, m) => ((m.repo || "").replace(/^\./, "") === proj ? "" : esc(m.repo)) + "#" + m.number;
// One project group: its first LOG_GROUP_SHOWN rows, the rest under a "+N more" fold. A legend
// pick keys its groups apart, so the picked group opens even on a day that starts them folded.
function projPanel(rec, kind, proj, rows, open) {
  const k = `${kind}:${proj}${lst.proj ? ":only" : ""}`, isOpen = k in lst.open ? lst.open[k] : open || !!lst.proj;
  const more = rows.length > LOG_GROUP_SHOWN ? cfold(k + "+", `+${rows.length - LOG_GROUP_SHOWN} more`, rows.slice(LOG_GROUP_SHOWN).join(""), lst.open) : "";
  return `<details class="panel area" data-k="${esc(k)}"${isOpen ? " open" : ""}><summary><i class="sw" style="background:${projColors(rec).of(proj)}"></i>${esc(proj)} <span class="muted">${rows.length}</span></summary>${rows.slice(0, LOG_GROUP_SHOWN).join("")}${more}</details>`;
}
const prLink = (proj, m) => `<a href="${esc(m.url)}" target="_blank" rel="noopener">${prRef(proj, m)}</a>`;
// The area and group day-log filed the PR under, kept as a short label on its row.
const areaLabel = (m) => { const a = [m.area, m.group || m.scope].filter(Boolean).join(" / "); return a ? `<span class="lbl" title="${esc(a)}">${esc(a)}</span>` : ""; };

function mergedList(rec) {
  // A busy day is a few hundred rows; then each project starts folded to its count.
  const open = (rec.merged || []).length <= LOG_OPEN_MERGED;
  const newest = (rec.merged || []).slice().sort((a, b) => String(b.merged_at).localeCompare(String(a.merged_at)));
  return projGroups(rec, newest).map(([proj, prs]) => projPanel(rec, "m", proj, prs.map((m) =>
    `<div class="pr"><span class="ft">${hm(m.merged_at)}</span>${prLink(proj, m)}${areaLabel(m)}<span class="pt">${esc(m.title)}</span>${bySession(m.repo, m.by)}</div>`), open)).join("");
}

function openList(rec) {
  const now = Date.now();
  return projGroups(rec, rec.open || []).map(([proj, prs]) => projPanel(rec, "o", proj, prs.map((p) => {
    const h = Math.round((now - new Date(p.created_at).getTime()) / 3600e3);
    const ci = p.draft ? '<b class="ci">draft</b>' : p.ci ? `<b class="ci ${esc(String(p.ci).toLowerCase())}">${esc(p.ci)}</b>` : "";
    return `<div class="pr"><span class="ft">${h >= 48 ? Math.floor(h / 24) + "d" : h + "h"}</span>${prLink(proj, p)}<span class="pt">${esc(p.title)}</span>${ci}${bySession(p.repo, p.by)}</div>`;
  }), true)).join("");
}

// What waits on the human is Home's to show and answer; the day says how much and links there.
const waiting = (n) => (n ? `<div class="badge-line"><a href="#" data-asks><span class="chip sm" style="--c:var(--b-needs)">${n} waiting on you</span> answer on Home</a></div>` : "");

function benchTable(rec) {
  const ss = ((rec.bench || {}).sessions || []).slice().sort((a, b) => (b.cost_usd || 0) - (a.cost_usd || 0));
  if (!ss.length) return "";
  return `<h2 class="sec">Sessions <span class="muted">${ss.length}</span></h2><div class="panel scroll"><table class="tbl"><tr><th>session</th><th>plan</th><th class="n">phases</th><th class="n">working</th><th class="n">waiting</th><th class="n">stalled</th><th class="n">PRs</th><th class="n">CI reds</th><th class="n">peak ctx</th><th class="n">cost</th></tr>${
    ss.map((s) => `<tr><td title="${esc(s.target)}">${esc(clip(shortTarget(s.target), 30))}</td><td class="muted">${esc(s.plan || "-")}</td><td class="n">${esc(s.phase || "-")}</td><td class="n">${s.working_h ?? "-"}h</td><td class="n">${s.waiting_h ?? "-"}h</td><td class="n">${s.stalled_h ?? "-"}h</td><td class="n">${s.prs_merged ?? "-"}</td><td class="n">${s.ci_reds ?? "-"}</td><td class="n">${s.peak_k ?? "-"}k</td><td class="n">${usd(s.cost_usd)}</td></tr>`).join("")}</table></div>`;
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
  // The legend's pick narrows both lists to one project's group; the head says so.
  const only = lst.proj ? ` <span class="muted only">${esc(projLabel(lst.proj))} only, <a href="#" data-proj="${esc(lst.proj)}">show all</a></span>` : "";
  html += `<h2 class="sec">Merged <span class="muted">${(rec.merged || []).length}</span>${only}</h2>${mergedList(rec) || '<div class="empty">Nothing merged.</div>'}`;
  html += `<h2 class="sec">Open PRs <span class="muted">${(rec.open || []).length}</span>${only}</h2>${openList(rec) || '<div class="panel"><div class="empty">Nothing open.</div></div>'}`;
  html += benchTable(rec);
  const tl = rec.timeline || [];
  if (tl.length) html += `<details class="sec-d"><summary><h2 class="sec">Timeline <span class="muted">${tl.length}</span></h2></summary><div class="panel feed">${tl.slice().reverse().map((l) => `<div class="tl1">${esc(l)}</div>`).join("")}</div></details>`;
  paint(el, html, lst.open);
}

$("log").addEventListener("click", (e) => {
  const t = e.target;
  const step = t.closest("[data-step]");
  if (step) { stepDay(Number(step.dataset.step)); return; }
  if (t.closest("[data-today]")) { goDay(null); return; }
  const proj = t.closest("[data-proj]");
  if (proj) { e.preventDefault(); lst.proj = lst.proj === proj.dataset.proj ? null : proj.dataset.proj; renderLog(); return; }
  const col = t.closest(".cc[data-key]");
  if (col && /^\d{4}-/.test(col.dataset.key)) { const ds = lst.hist.map((r) => r.date); goDay(col.dataset.key === ds[ds.length - 1] ? null : col.dataset.key); return; }
  const by = t.closest("[data-target]");
  if (by) { e.preventDefault(); const a = st.agents.find((x) => x.target === by.dataset.target); if (a) openAgent(a); return; }
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
  show() { renderLog(); logFeed.show(!lst.rec); for (const p of LOG_PARTS) p.show(); seekSection(); },
  onEvent(ev) { logFeed.onEvent(ev); for (const p of LOG_PARTS) p.onEvent(ev); },
};
