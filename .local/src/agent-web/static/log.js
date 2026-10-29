"use strict";
// The Log tab: the hub:log board (`day-log watch`, Prefix O) for the browser. It reads day-log's
// records through /api/log and /api/log/history; every number here is in the record already.

// The charts show this many days; the day picker can step back through the fetched history.
const LOG_CHART_DAYS = 30;
const LOG_HISTORY_DAYS = 120;
const LOG_OPEN_MERGED = 25;
const lst = { day: null, rec: null, hist: [], err: null };

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
function goDay(d) { lst.day = d; refreshLog(); }
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
  const spend = columns(rows.map((r, i) => ({
    key: r.date, label: lab(r.date, i),
    tip: `${weekday(r.date)} ${r.date}: ${usd(r.cost_usd)}, ${r.sessions ?? "-"} sessions, ${kfmt(r.tokens)} tokens`,
    segs: [{ v: r.cost_usd || 0, color: "var(--c1)" }],
  })), { sel, yfmt: (v) => "$" + Math.round(v) });
  return `<div class="g2">
    <div class="panel"><h3>Merged per day ${legend([...ac.top.map((a) => [a, ac.of(a)]), ["Other", OTHER]])}</h3>${merged}</div>
    <div class="panel"><h3>Spend per day</h3>${spend}</div>
  </div>`;
}

function byHour(rec) {
  const n = Array(24).fill(0);
  for (const m of rec.merged || []) n[new Date(m.merged_at).getHours()]++;
  return columns(n.map((v, h) => ({ key: "h" + h, label: h % 3 === 0 ? String(h).padStart(2, "0") : "", tip: `${String(h).padStart(2, "0")}:00 ${v} merged`, segs: [{ v, color: "var(--c1)" }] })), { height: 110 });
}

function usageTable(rec) {
  const rows = (rec.usage || []).filter((u) => u.project !== "TOTAL").sort((a, b) => b.cost_usd - a.cost_usd);
  const total = (rec.usage || []).find((u) => u.project === "TOTAL");
  if (!rows.length) return '<div class="empty">No usage recorded.</div>';
  const max = Math.max(...rows.map((u) => u.cost_usd));
  return `<table class="tbl"><tr><th>project</th><th></th><th class="n">sessions</th><th class="n">tokens</th><th class="n">cost</th></tr>${
    rows.map((u) => `<tr><td>${esc(u.project)}</td><td class="m">${meter(u.cost_usd / max, "var(--c1)")}</td><td class="n">${u.sessions}</td><td class="n">${kfmt(u.tokens)}</td><td class="n">${usd(u.cost_usd)}</td></tr>`).join("")}${
    total ? `<tr class="tot"><td>total</td><td></td><td class="n">${total.sessions}</td><td class="n">${kfmt(total.tokens)}</td><td class="n">${usd(total.cost_usd)}</td></tr>` : ""}</table>`;
}

// `by` is what day-log calls the session that landed a PR: a short target ("agent-18") or an
// outcome's title. It links when a live agent still has that target.
function bySession(repo, by) {
  if (!by) return "";
  const a = st.agents.find((x) => { const t = shortTarget(x.target).replace(/:\d+$/, ""); return t === by || t === `${repo}-${by}`; });
  return a ? `<a class="by" href="#" data-target="${esc(a.target)}">${esc(by)}</a>` : `<span class="by">${esc(by)}</span>`;
}

function mergedList(rec) {
  const areas = {};
  for (const m of rec.merged || []) ((areas[m.area || "other"] ||= {})[m.group || m.scope || "other"] ||= []).push(m);
  const ac = areaColors(lst.hist.slice(-LOG_CHART_DAYS));
  // A busy day is a few hundred rows; then each area starts folded to its count.
  const open = (rec.merged || []).length <= LOG_OPEN_MERGED ? " open" : "";
  return Object.entries(areas).sort((a, b) => Object.values(b[1]).flat().length - Object.values(a[1]).flat().length).map(([area, groups]) => {
    const n = Object.values(groups).flat().length;
    return `<details class="panel area"${open}><summary><i class="sw" style="background:${ac.of(area)}"></i>${esc(area)} <span class="muted">${n}</span></summary>${
      Object.entries(groups).map(([g, prs]) => `<div class="grp">${esc(g)}</div>${prs.slice().reverse().map((m) =>
        `<div class="pr"><span class="ft">${hm(m.merged_at)}</span><a href="${esc(m.url)}" target="_blank" rel="noopener">${esc(m.repo)}#${m.number}</a><span class="pt">${esc(m.title)}</span>${bySession(m.repo, m.by)}</div>`).join("")}`).join("")}</details>`;
  }).join("");
}

function openList(rec) {
  const now = Date.now();
  return (rec.open || []).map((p) => {
    const h = Math.round((now - new Date(p.created_at).getTime()) / 3600e3);
    const ci = p.draft ? '<b class="ci">draft</b>' : p.ci ? `<b class="ci ${esc(String(p.ci).toLowerCase())}">${esc(p.ci)}</b>` : "";
    return `<div class="pr"><span class="ft">${h >= 48 ? Math.floor(h / 24) + "d" : h + "h"}</span><a href="${esc(p.url)}" target="_blank" rel="noopener">${esc(p.repo)}#${p.number}</a><span class="pt">${esc(p.title)}</span>${ci}${bySession(p.repo, p.by)}</div>`;
  }).join("") || '<div class="empty">Nothing open.</div>';
}

function waiting(rec) {
  const w = rec.waiting || {};
  const rows = [
    ...(w.main || []).map((m) => `<div class="pr"><span class="chip sm" style="--c:var(--b-needs)">MAIN</span><span class="pt">${esc(m.reason)}</span></div>`),
    ...(w.needs || []).map((n) => `<div class="pr"><span class="chip sm" style="--c:var(--b-needs)">NEEDS</span><span class="pt">${esc(n.who)}: ${esc(n.reason)}</span><span class="muted">idle ${dur(n.idle_min)}</span></div>`),
    ...(w.asks || []).map((a) => `<div class="pr"><span class="chip sm" style="--c:var(--b-stalled)">ASK</span><span class="pt">${esc(a.project)}: ${esc(a.question)}</span><a href="#" data-asks>answer</a></div>`),
  ];
  return rows.length ? `<h2 class="sec">Waiting on you <span class="muted">${rows.length}</span></h2><div class="panel">${rows.join("")}</div>` : "";
}

function benchTable(rec) {
  const ss = ((rec.bench || {}).sessions || []).slice().sort((a, b) => (b.cost_usd || 0) - (a.cost_usd || 0));
  if (!ss.length) return "";
  return `<h2 class="sec">Sessions <span class="muted">${ss.length}</span></h2><div class="panel scroll"><table class="tbl"><tr><th>session</th><th>plan</th><th class="n">phases</th><th class="n">working</th><th class="n">waiting</th><th class="n">stalled</th><th class="n">PRs</th><th class="n">CI reds</th><th class="n">peak ctx</th><th class="n">cost</th></tr>${
    ss.map((s) => `<tr><td title="${esc(s.target)}">${esc(clip(shortTarget(s.target), 30))}</td><td class="muted">${esc(s.plan || "-")}</td><td class="n">${esc(s.phase || "-")}</td><td class="n">${s.working_h ?? "-"}h</td><td class="n">${s.waiting_h ?? "-"}h</td><td class="n">${s.stalled_h ?? "-"}h</td><td class="n">${s.prs_merged ?? "-"}</td><td class="n">${s.ci_reds ?? "-"}</td><td class="n">${s.peak_k ?? "-"}k</td><td class="n">${usd(s.cost_usd)}</td></tr>`).join("")}</table></div>`;
}

function renderLog() {
  const el = $("log");
  if (lst.err && !lst.rec) { el.innerHTML = `<div class="empty">${esc(lst.err)}</div>`; return; }
  if (!lst.rec) { el.innerHTML = '<div class="empty">Loading...</div>'; return; }
  const rec = lst.rec, day = rec.date;
  const ds = lst.hist.map((r) => r.date), i = ds.indexOf(day);
  const total = (rec.usage || []).find((u) => u.project === "TOTAL") || {};
  const w = rec.waiting || {};
  const nWait = (w.main || []).length + (w.needs || []).length + (w.asks || []).length;
  const repos = new Set((rec.merged || []).map((m) => m.repo)).size;
  const tile = (l, v, c, sub) => `<div class="tile" style="--c:${c}"><span class="tl">${l}</span><span class="tv">${v}</span>${sub ? `<span class="ts1">${sub}</span>` : ""}</div>`;
  let html = `<div class="bhead daynav">
    <span><button class="btn" data-step="-1"${i > 0 ? "" : " disabled"}>&lsaquo;</button>
    <b>${weekday(day)} ${esc(day)}</b> <span class="muted">${rec.live ? "live" : "closed"}, gathered ${rec.gathered_at ? hm(rec.gathered_at) : "?"}</span>
    <button class="btn" data-step="1"${i >= 0 && i < ds.length - 1 ? "" : " disabled"}>&rsaquo;</button>
    <button class="btn" data-today${lst.day ? "" : " disabled"}>today</button></span>
    <span class="muted">[ ] day, t today${(rec.unreadable || []).length ? ", could not read " + esc(rec.unreadable.join(", ")) : ""}</span></div>`;
  html += `<div class="tiles roomy">${tile("MERGED", (rec.merged || []).length, "var(--c1)", `${repos} repo(s)`)}${tile("OPEN", (rec.open || []).length, "var(--b-working)")}${
    tile("WAITING", nWait, nWait ? "var(--b-needs)" : "var(--b-done)", `${(w.main || []).length} main, ${(w.asks || []).length} asks`)}${
    tile("SPEND", usd(total.cost_usd), "var(--c2)", `${kfmt(total.tokens)} tokens`)}${tile("SESSIONS", total.sessions ?? "-", "var(--c3)")}</div>`;
  if (rec.bench && rec.bench.headline) html += `<div class="headline muted">${esc(rec.bench.headline)}</div>`;
  html += historyCharts(day);
  html += `<div class="g2"><div class="panel"><h3>Merged by hour</h3>${byHour(rec)}</div><div class="panel"><h3>Spend by project</h3>${usageTable(rec)}</div></div>`;
  html += waiting(rec);
  html += `<h2 class="sec">Merged <span class="muted">${(rec.merged || []).length}</span></h2>${mergedList(rec) || '<div class="empty">Nothing merged.</div>'}`;
  html += `<h2 class="sec">Open PRs <span class="muted">${(rec.open || []).length}</span></h2><div class="panel">${openList(rec)}</div>`;
  html += benchTable(rec);
  const tl = rec.timeline || [];
  if (tl.length) html += `<details class="sec-d"><summary><h2 class="sec">Timeline <span class="muted">${tl.length}</span></h2></summary><div class="panel feed">${tl.slice().reverse().map((l) => `<div class="tl1">${esc(l)}</div>`).join("")}</div></details>`;
  const y = el.scrollTop;
  el.innerHTML = html;
  el.scrollTop = y;
}

$("log").addEventListener("click", (e) => {
  const t = e.target;
  const step = t.closest("[data-step]");
  if (step) { stepDay(Number(step.dataset.step)); return; }
  if (t.closest("[data-today]")) { goDay(null); return; }
  const col = t.closest(".cc[data-key]");
  if (col && /^\d{4}-/.test(col.dataset.key)) { const ds = lst.hist.map((r) => r.date); goDay(col.dataset.key === ds[ds.length - 1] ? null : col.dataset.key); return; }
  const by = t.closest("[data-target]");
  if (by) { e.preventDefault(); const a = st.agents.find((x) => x.target === by.dataset.target); if (a) { setTab("sessions"); select(a); } return; }
  if (t.closest("[data-asks]")) { e.preventDefault(); setTab("asks"); }
});
document.addEventListener("keydown", (e) => {
  if (st.tab !== "log" || e.ctrlKey || e.metaKey || e.altKey || e.target.closest("input, textarea, select")) return;
  if (e.key === "[") stepDay(-1);
  else if (e.key === "]") stepDay(1);
  else if (e.key === "t") goDay(null);
});

TABS.log = {
  show() { renderLog(); if (!lst.rec) refreshLog(); },
  // Any record written changes the history charts, so every log event refetches both.
  onEvent(ev) { if (ev.kind === "log" || ev.kind === "resync") refreshLog(); },
};
