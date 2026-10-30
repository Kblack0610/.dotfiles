"use strict";
// The Watch tab: the hub:watch board (`fleet-sessions watch`, Prefix o) for the browser. It reads
// what that board writes, `state.json` and `watch.log`, through /api/watch; nothing is judged here.

const WATCH_HOURS = 24;
// Fields that move on almost every tick and drown the stage changes; the feed hides lines that
// change only these until "all changes" is on.
const NOISY = ["sync", "tree"];
const wst = { data: null, filter: null, allChanges: false, ended: false };

// watch.log targets carry no tmux server ("dotfiles:2"); state.json's do ("hub/dotfiles:2").
const shortTarget = (t) => String(t).split("/").pop();
// watch.log times are the host's local time, as written by `date '+%Y-%m-%d %H:%M'`.
const logTime = (ts) => new Date(ts.replace(" ", "T")).getTime();

const refreshWatch = coalesce(async () => {
  wst.data = await api("/api/watch");
  if (st.tab === "watch") renderWatch();
});

function sessionsOf() {
  const s = wst.data && wst.data.state;
  return s && Array.isArray(s.sessions) ? s.sessions : [];
}

// One lane per session: its bucket over the last day, from the transitions, ending in the
// bucket state.json shows now. A session whose first change in the window is a stage change
// was in that change's "from" bucket before it.
function buildLanes(now) {
  const t0 = now - WATCH_HOURS * 3600e3;
  const live = new Map(sessionsOf().map((s) => [shortTarget(s.target), s]));
  const lanes = new Map();
  const lane = (t) => { if (!lanes.has(t)) lanes.set(t, { target: t, segs: [], cur: null, since: null }); return lanes.get(t); };
  const open = (l, key, at) => { l.cur = key; l.since = at; };
  const close = (l, at) => { if (l.cur) l.segs.push({ a: l.since, b: at, key: l.cur, title: `${l.cur} ${clock(l.since)}-${clock(at)}` }); l.cur = null; };
  for (const tr of wst.data.transitions) {
    const at = logTime(tr.ts);
    if (!(at >= t0)) continue;
    const l = lane(tr.target);
    if (tr.kind === "new") { close(l, at); open(l, tr.to, at); }
    else if (tr.kind === "gone") { close(l, at); l.gone = at; }
    else if (tr.to) {
      if (!l.cur && !l.segs.length) open(l, tr.from, t0);
      close(l, at); open(l, tr.to, at);
    }
  }
  for (const [t, s] of live) {
    const l = lane(t);
    l.gone = null;
    if (!l.cur && !l.segs.length) open(l, s.bucket, Math.max(t0, now - (s.age_min || 0) * 60e3));
    if (l.cur) { l.cur = s.bucket; }
    else open(l, s.bucket, l.segs.length ? l.segs[l.segs.length - 1].b : t0);
    close(l, now);
  }
  const rank = (t) => { const s = live.get(t); return s ? BUCKETS.indexOf(s.bucket) : 99; };
  return { t0, lanes: [...lanes.values()].sort((a, b) => rank(a.target) - rank(b.target) || a.target.localeCompare(b.target)) };
}

const clock = (ms) => { const d = new Date(ms); return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };

function tiles(sessions, state) {
  const n = (b) => sessions.filter((s) => s.bucket === b).length;
  const main = (state && state.main) || [];
  const asks = (state && state.asks) || [];
  let html = BUCKETS.map((b) => `
    <button class="tile${wst.filter === b ? " on" : ""}" data-bucket="${b}" style="--c:${bucketColor(b)}">
      <span class="tl">${b}</span><span class="tv">${n(b)}</span>
    </button>`).join("");
  html += `<div class="tile" style="--c:var(--b-needs)"><span class="tl">ASKS</span><span class="tv">${asks.length}</span></div>`;
  html += `<div class="tile wide" style="--c:${main.length ? "var(--b-needs)" : "var(--b-done)"}"><span class="tl">MAIN</span>${
    main.length ? main.map((m) => `<span class="ts1" title="${esc(m.reason)}">${esc(m.repo)} red</span>`).join("") : '<span class="ts1">all green</span>'}</div>`;
  return `<div class="tiles">${html}</div>`;
}

// A session's closed time by what it waited on (fleet-states.md). The line under the bar carries
// the numbers, in the bar's order, so the colours are only a shape to scan.
const TIME_PARTS = [["work", "work_min", "var(--c1)"], ["jobs", "jobs_min", "var(--c2)"], ["you", "human_min", "var(--c3)"], ["parked", "parked_min", "var(--c4)"]];

function timeUse(t) {
  const parts = TIME_PARTS.map(([label, key, color]) => ({ label, color, min: (t && t[key]) || 0 })).filter((p) => p.min);
  const total = parts.reduce((n, p) => n + p.min, 0);
  if (!total) return "";
  const bar = parts.map((p) => `<span style="width:${((p.min / total) * 100).toFixed(1)}%;background:${p.color}" title="${p.label} ${dur(p.min)}"></span>`).join("");
  return `<div class="tbar">${bar}</div><div class="wn">${parts.map((p) => `${p.label} ${dur(p.min)}`).join(", ")}</div>`;
}

function prList(prs, now) {
  if (!(prs || []).length) return "";
  const merged = prs.filter((p) => p.state === "MERGED");
  const last = Math.max(0, ...merged.map((p) => Date.parse(p.merged_at) || 0));
  const items = prs.map((p) => `<li><a href="https://github.com/${esc(p.repo)}/pull/${esc(p.number)}" target="_blank" rel="noopener">${esc(p.repo)}#${esc(p.number)}</a> ${esc((p.state || "unknown").toLowerCase())}</li>`).join("");
  return `<details><summary>${merged.length}/${prs.length} PRs merged${last ? `, last ${dur((now - last) / 60e3)} ago` : ""}</summary><ul>${items}</ul></details>`;
}

function card(s, maxCtx, now) {
  const pr = s.pr && s.pr !== "-" ? `PR #${esc(s.pr)}${s.pr_state ? " " + esc(s.pr_state.toLowerCase()) : ""}${s.ci ? ` <b class="ci ${esc(s.ci.toLowerCase())}">${esc(s.ci)}</b>` : ""}` : "no PR";
  const git = [s.ahead ? `ahead ${s.ahead}` : "", s.behind ? `behind ${s.behind}` : "", s.dirty ? `${s.dirty} dirty` : "", s.conflicts ? "<b class=\"ci fail\">conflicts</b>" : ""].filter(Boolean).join(", ");
  const phases = s.phases_total ? `<span class="kv">phases ${meter(s.phases_done / s.phases_total, "var(--b-done)")} ${s.phases_done}/${s.phases_total}</span>` : "";
  const blockers = (s.blockers || []).length ? `<details><summary>${s.blockers.length} reason(s)</summary><ul>${s.blockers.map((b) => `<li>${esc(b)}</li>`).join("")}</ul></details>` : "";
  return `
    <div class="wcard" data-sid="${esc(s.session_id || "")}" data-t="${esc(s.target)}" style="--c:${bucketColor(s.bucket)}">
      <div class="wh"><span class="chip">${esc(s.bucket)}</span><span class="wt" title="${esc(s.target)}">${esc(clip(shortTarget(s.target), 34))}</span><span class="open">open</span></div>
      ${s.topic ? `<div class="wtask">${esc(s.topic)}</div>` : ""}
      <div class="wm">${esc(s.branch || "-")} &middot; ${pr}${git ? " &middot; " + git : ""}</div>
      <div class="wf">${esc((s.bucket === "WORKING" && s.doing) || s.reason || s.fact || "")}</div>
      ${timeUse(s.time)}
      <div class="wk">
        <span class="kv">ctx ${meter((s.context_tokens || 0) / maxCtx, "var(--accent)")} ${kfmt(s.context_tokens)}</span>
        ${phases}
        <span class="kv">idle ${dur(s.idle_min)}</span><span class="kv">open ${dur(s.age_min)}</span>
        ${s.compactions ? `<span class="kv">compactions ${esc(s.compactions)}</span>` : ""}
      </div>
      ${s.next_phase ? `<div class="wn">next: ${esc(s.next_phase)}</div>` : ""}
      ${s.said ? `<div class="wn" title="${esc(s.said)}">said: ${esc(s.said)}</div>` : ""}
      ${prList(s.prs, now)}
      ${blockers}
    </div>`;
}

function feed(now) {
  const t0 = now - WATCH_HOURS * 3600e3;
  const rows = wst.data.transitions
    .filter((t) => logTime(t.ts) >= t0)
    .filter((t) => wst.allChanges || t.kind !== "change" || t.fields.some((f) => !NOISY.includes(f)))
    .slice(-200).reverse();
  if (!rows.length) return '<div class="empty">No changes in the last day.</div>';
  return rows.map((t) => {
    let what = esc(t.text);
    if (t.kind === "change" && t.to) what = `<span class="chip sm" style="--c:${bucketColor(t.from)}">${esc(t.from)}</span> &rarr; <span class="chip sm" style="--c:${bucketColor(t.to)}">${esc(t.to)}</span> ${esc(t.text.replace(/stage \S+ -> \S+,? ?/, ""))}`;
    if (t.kind === "new") what = `new <span class="chip sm" style="--c:${bucketColor(t.to)}">${esc(t.to)}</span> ${esc(t.text.replace(/^new: \S+ ?/, ""))}`;
    return `<div class="fr"><span class="ft">${esc(t.ts.slice(11))}</span><span class="fg" title="${esc(t.target)}">${esc(clip(t.target))}</span><span class="fw">${what}</span></div>`;
  }).join("");
}

function renderWatch() {
  const el = $("watch");
  if (!wst.data) { el.innerHTML = '<div class="empty">Loading...</div>'; return; }
  const state = wst.data.state;
  if (!state) { el.innerHTML = '<div class="empty">No fleet state yet: fleet-state.path has not written ~/.local/state/fleet/state.json.</div>'; return; }
  const now = Date.now();
  const sessions = sessionsOf();
  const shown = sessions.filter((s) => !wst.filter || s.bucket === wst.filter);
  const maxCtx = Math.max(200e3, ...sessions.map((s) => s.context_tokens || 0));
  const { t0, lanes } = buildLanes(now);
  const keep = lanes.filter((l) => wst.ended || !l.gone);
  const ended = lanes.length - lanes.filter((l) => !l.gone).length;
  const age = state.generated_at ? Math.round((now - new Date(state.generated_at).getTime()) / 60e3) : null;

  let html = `<div class="bhead"><span>fleet ${sessions.length} session(s)</span><span class="muted">state ${age == null ? "?" : dur(age) + " old"}${(state.unreadable || []).length ? ", could not read " + esc(state.unreadable.join(", ")) : ""}</span></div>`;
  html += tiles(sessions, state);
  html += `<h2 class="sec">Last ${WATCH_HOURS}h ${legend(BUCKETS.map((b) => [b, bucketColor(b)]))}<label class="tog"><input type="checkbox" data-ended${wst.ended ? " checked" : ""}> ended sessions (${ended})</label></h2>`;
  html += `<div class="panel">${swimlanes(keep.map((l) => ({
    label: l.target, sub: l.gone ? "gone" : "", dim: !!l.gone, segs: l.segs,
  })), t0, now, bucketColor)}</div>`;
  for (const b of BUCKETS) {
    const list = shown.filter((s) => s.bucket === b);
    if (!list.length) continue;
    html += `<h2 class="sec">${b} <span class="muted">${list.length}</span></h2><div class="wgrid">${list.map((s) => card(s, maxCtx, now)).join("")}</div>`;
  }
  html += `<h2 class="sec">Changes <label class="tog"><input type="checkbox" data-all${wst.allChanges ? " checked" : ""}> sync and tree too</label></h2><div class="panel feed">${feed(now)}</div>`;
  const y = el.scrollTop;
  el.innerHTML = html;
  el.scrollTop = y;
}

$("watch").addEventListener("click", (e) => {
  const tile = e.target.closest("[data-bucket]");
  if (tile) { wst.filter = wst.filter === tile.dataset.bucket ? null : tile.dataset.bucket; renderWatch(); return; }
  const c = e.target.closest(".wcard");
  if (c && e.target.closest(".open")) {
    const a = st.agents.find((x) => (c.dataset.sid && x.session === c.dataset.sid) || x.target === c.dataset.t);
    if (a) { setTab("sessions"); select(a); }
  }
});
$("watch").addEventListener("change", (e) => {
  if (e.target.matches("[data-ended]")) wst.ended = e.target.checked;
  if (e.target.matches("[data-all]")) wst.allChanges = e.target.checked;
  renderWatch();
});

TABS.watch = {
  show() { if (wst.data) renderWatch(); else { renderWatch(); refreshWatch(); } },
  onEvent(ev) { if (ev.kind === "watch" || ev.kind === "resync") refreshWatch(); },
};
