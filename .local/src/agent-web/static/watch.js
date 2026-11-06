"use strict";
// Sessions' fleet-state half (the Watch tab until phase 3 of the hub layout): each row's bucket
// and card fields, the folded facts card above an open transcript, and the overview shown while
// no session is open. It reads what fleet-state.timer writes, `state.json` and `watch.log`,
// through /api/watch; nothing is judged here.

const WATCH_HOURS = 24;
// Fields that move on almost every tick and drown the stage changes; the feed hides lines that
// change only these until "all changes" is on.
const NOISY = ["sync", "tree"];
const wst = { data: null, filter: null, allChanges: false, ended: false, open: {} };

// watch.log targets carry no tmux server ("dotfiles:2"); state.json's do ("hub/dotfiles:2").
const shortTarget = (t) => String(t).split("/").pop();
// watch.log times are the host's local time, as written by `date '+%Y-%m-%d %H:%M'`.
const logTime = (ts) => new Date(ts.replace(" ", "T")).getTime();

const refreshWatch = coalesce(async () => {
  wst.data = await api("/api/watch");
  if (st.tab === "sessions") { renderList(); renderFacts(); renderOverview(); }
  if (st.tab === "log") renderLogChanges();
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


function tiles(sessions, state) {
  const n = (b) => sessions.filter((s) => s.bucket === b).length;
  const main = (state && state.main) || [];
  const asks = (state && state.asks) || [];
  let html = BUCKETS.map((b) => `
    <button class="tile${wst.filter === b ? " on" : ""}" data-bucket="${b}" style="--c:${bucketColor(b)}">
      <span class="tl">${b}</span><span class="tv">${n(b)}</span>
    </button>`).join("");
  html += `<div class="tile" style="--c:var(--b-needs)"><span class="tl">ASKS</span><span class="tv">${asks.length}</span></div>`;
  html += `<div class="tile wide" style="--c:${main.length ? "var(--b-needs)" : "var(--b-done)"}"><span class="tl">NIGHTLY</span>${
    main.length ? main.map((m) => `<span class="ts1" title="${esc(m.reason)}">${esc(m.repo)} red</span>`).join("") : '<span class="ts1">all green</span>'}</div>`;
  return `<div class="tiles">${html}</div>`;
}

// A session's closed time by what it waited on (fleet-states.md). The line under the bar carries
// the numbers, in the bar's order, so the colours are only a shape to scan.
const TIME_PARTS = [["work", "work_min", "var(--c1)"], ["gate", "gate_min", "var(--c5)"], ["test", "test_min", "var(--c6)"], ["jobs", "jobs_min", "var(--c2)"], ["you", "human_min", "var(--c3)"], ["parked", "parked_min", "var(--c4)"]];

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
      <div class="wh"><span class="chip">${esc(s.bucket)}</span><span class="wt" title="${esc(s.target)}">${esc(clip(shortTarget(s.target), 34))}</span></div>
      ${s.topic ? `<div class="wtask">${esc(s.topic)}</div>` : ""}
      <div class="wm">${esc(s.branch || "-")}, ${pr}${git ? ", " + git : ""}</div>
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
    .reverse();
  if (!rows.length) return '<div class="empty">No changes in the last day.</div>';
  return rows.slice(0, LOG_ROWS).map((t) => {
    let what = esc(t.text);
    if (t.kind === "change" && t.to) what = `<span class="chip sm" style="--c:${bucketColor(t.from)}">${esc(t.from)}</span> -&gt; <span class="chip sm" style="--c:${bucketColor(t.to)}">${esc(t.to)}</span> ${esc(t.text.replace(/stage \S+ -> \S+,? ?/, ""))}`;
    if (t.kind === "new") what = `new <span class="chip sm" style="--c:${bucketColor(t.to)}">${esc(t.to)}</span> ${esc(t.text.replace(/^new: \S+ ?/, ""))}`;
    return `<div class="fr"><span class="ft">${esc(t.ts.slice(11))}</span><span class="fg" title="${esc(t.target)}">${esc(clip(t.target))}</span><span class="fw">${what}</span></div>`;
  }).join("") + older(rows.length - LOG_ROWS);
}

// Log's Changes section: fleet-state's transitions over the last day, newest first.
function renderLogChanges() {
  const el = $("log-changes");
  if (!wst.data) { el.innerHTML = '<div class="empty">Loading.</div>'; return; }
  paint(el, `<div class="ovbar"><label class="tog"><input type="checkbox" data-all${wst.allChanges ? " checked" : ""}> sync and tree too</label></div><div class="panel feed">${feed(Date.now())}</div>`);
}
$("log-changes").addEventListener("change", (e) => {
  if (e.target.matches("[data-all]")) { wst.allChanges = e.target.checked; renderLogChanges(); }
});

// The order of the list's groups: the shepherd first, then the buckets, PARKED last, where sessions
// fleet-state has no row for also go, as they do on the hub's Sessions tab.
const LIST_ORDER = ["SHEPHERD", ...BUCKETS];

// One row per session: every live or parked session here with its fleet-state row (matched by
// session id, then target), then the fleet-state rows with no session on this machine. Grouped
// in LIST_ORDER; a stable sort keeps each group in the server's order.
function sessionRows() {
  const states = sessionsOf(), used = new Set();
  const shep = shst.data && shst.data.target;
  const rows = st.agents.map((a) => {
    const s = states.find((x) => (x.session_id && x.session_id === a.session) || x.target === a.target);
    if (s) used.add(s);
    return { a, s, group: shep && a.target === shep ? "SHEPHERD" : s ? s.bucket : "PARKED" };
  });
  for (const s of states) if (!used.has(s)) rows.push({ a: null, s, group: s.bucket });
  const rank = (g) => { const i = LIST_ORDER.indexOf(g); return i < 0 ? LIST_ORDER.indexOf("CHAT") : i; };
  return rows.sort((x, y) => rank(x.group) - rank(y.group));
}

const maxContext = () => Math.max(200e3, ...sessionsOf().map((s) => s.context_tokens || 0));

// The open session's fleet-state card, folded to one line above its transcript.
function renderFacts() {
  const el = $("facts");
  const r = st.sel && sessionRows().find((x) => x.a && x.a.target === st.sel.target);
  const s = r && r.s;
  el.hidden = !s;
  if (!s) return;
  const pr = s.pr && s.pr !== "-" ? ` PR #${esc(s.pr)}${s.ci ? ` <b class="ci ${esc(s.ci.toLowerCase())}">${esc(s.ci)}</b>` : ""}` : "";
  const ph = s.phases_total ? `, ${s.phases_done}/${s.phases_total} phases` : "";
  const eta = s.eta ? `, eta ${esc(s.eta)}` : "";
  paint(el, `<details data-k="facts"${wst.open.facts ? " open" : ""}><summary><span class="chip" style="--c:${bucketColor(s.bucket)}">${esc(s.bucket)}</span> ${esc(s.topic || s.reason || "")}<span class="muted">${pr}${ph}${eta}</span></summary>${card(s, maxContext(), Date.now())}</details>`, wst.open);
}

// The detail pane while no session is open: the bucket tiles (they filter the list), then the
// last day's swimlanes and the shepherd's pass and due lines, each folded. The change feed, the
// rundowns and the ranked sessions are Log's.
function renderOverview() {
  if (st.sel || st.tab !== "sessions") return;
  const el = $("scroll");
  if (!wst.data) { el.innerHTML = '<div class="empty">Loading the overview.</div>'; return; }
  const state = wst.data.state;
  const now = Date.now();
  let html = "";
  if (!state) html += '<div class="empty">No fleet state yet: fleet-state.timer has not written ~/.local/state/fleet/state.json.</div>';
  else {
    const sessions = sessionsOf();
    const { t0, lanes } = buildLanes(now);
    const keep = lanes.filter((l) => wst.ended || !l.gone);
    const ended = lanes.length - lanes.filter((l) => !l.gone).length;
    const age = state.generated_at ? Math.round((now - new Date(state.generated_at).getTime()) / 60e3) : null;
    html += `<div class="bhead"><span>fleet ${sessions.length} session(s)</span><span class="muted">state ${age == null ? "?" : dur(age) + " old"}${(state.unreadable || []).length ? ", could not read " + esc(state.unreadable.join(", ")) : ""}</span></div>`;
    html += tiles(sessions, state);
    html += fold("lanes", `Last ${WATCH_HOURS}h`, `<div class="ovbar">${legend(BUCKETS.map((b) => [b, bucketColor(b)]))}<label class="tog"><input type="checkbox" data-ended${wst.ended ? " checked" : ""}> ended sessions (${ended})</label></div>` +
      `<div class="panel">${swimlanes(keep.map((l) => ({ label: l.target, sub: l.gone ? "gone" : "", dim: !!l.gone, segs: l.segs })), t0, now, bucketColor)}</div>`);
  }
  html += shepherdOverview();
  paint(el, html, wst.open);
}

// Log's Ranked sessions: the week's outcome rows worst first, by agentctl-session-outcomes'
// friction score. The list is read when the section opens and a card when its row is clicked
// (rule 10); the rows change once a night, so nothing re-reads them on its own.
const ost = { rows: null, err: null, open: null, cards: {} };
async function loadRanked() {
  try { ost.rows = await api("/api/outcomes"); ost.err = null; } catch (e) { ost.err = e.message; }
  renderLogRanked();
}
async function loadCard(sid) {
  try { ost.cards[sid] = await api(`/api/outcomes/card?sid=${encodeURIComponent(sid)}`); } catch (e) { ost.cards[sid] = e.message; }
  renderLogRanked();
}
function renderLogRanked() {
  const rows = ost.rows || [];
  const body = ost.err ? `<div class="card err">${esc(ost.err)}</div>` : !ost.rows ? '<div class="empty">Loading.</div>'
    : !rows.length ? '<div class="empty">No session with friction in the last 7 days.</div>'
    : `<div class="panel scroll"><table class="tbl"><tr><th class="n">friction</th><th>session</th><th>project</th><th class="n">wall</th><th class="n">cost</th><th class="n">PRs</th><th>why</th></tr>${rows.map((r) => {
        const prs = r.prs_merged + r.prs_open + r.prs_closed_unmerged;
        const open = ost.open === r.session_id;
        const card = open ? `<tr><td colspan="7" class="wrap"><pre class="joblog">${ost.cards[r.session_id] == null ? "Loading the card." : esc(ost.cards[r.session_id])}</pre></td></tr>` : "";
        return `<tr class="click" data-sid="${esc(r.session_id)}"><td class="n">${r.friction}</td><td>${esc(r.title.split("\n")[0].slice(0, 60))} <span class="muted">${esc(r.session_id.slice(0, 8))}</span></td><td>${esc(r.project)}</td>` +
          `<td class="n">${r.duration_s == null ? "-" : dur(r.duration_s / 60)}</td><td class="n">${r.cost_usd == null ? "-" : "$" + r.cost_usd.toFixed(2)}</td><td class="n">${r.prs_merged}/${prs}</td><td class="wrap">${esc(r.why)}</td></tr>${card}`;
      }).join("")}</table></div>`;
  $("log-ranked").innerHTML = `<div class="bhead"><span class="muted">${ost.rows ? `${rows.length} worst, 7d, by friction` : "7d, by friction"}</span></div>${body}`;
}
$("sec-ranked").addEventListener("toggle", (e) => { if (e.target.open && !ost.rows) loadRanked(); });
$("log-ranked").addEventListener("click", (e) => {
  const row = e.target.closest("tr[data-sid]");
  if (!row) return;
  const sid = row.dataset.sid;
  ost.open = ost.open === sid ? null : sid;
  if (ost.open && ost.cards[sid] == null) loadCard(sid); else renderLogRanked();
});
LOG_PARTS.push({ show() { renderLogRanked(); if ($("sec-ranked").open && !ost.rows) loadRanked(); }, onEvent() {} });

// A folded overview section; the fold is remembered across re-renders by its key.
const fold = (k, title, body) => `<details class="ovsec" data-k="${k}"${wst.open[k] ? " open" : ""}><summary><h2 class="sec">${title}</h2></summary>${body}</details>`;

$("scroll").addEventListener("click", (e) => {
  if (st.sel) return;
  const tile = e.target.closest("[data-bucket]");
  if (tile) { wst.filter = wst.filter === tile.dataset.bucket ? null : tile.dataset.bucket; renderList(); renderOverview(); }
});
$("scroll").addEventListener("change", (e) => {
  if (st.sel) return;
  if (e.target.matches("[data-ended]")) wst.ended = e.target.checked;
  renderOverview();
});
// A fold the reader opens stays open through the next push (paint reads it before a repaint;
// this catches the ones toggled between repaints).
for (const id of ["scroll", "facts", "list"]) {
  $(id).addEventListener("toggle", (e) => {
    const k = e.target.dataset && e.target.dataset.k;
    if (k) wst.open[k] = e.target.open;
  }, true);
}

// fleet-state writes every minute and the shepherd on each pass; only the open tab reads them.
const watchFeed = pushed("sessions", ["watch"], refreshWatch);
const shepFeed = pushed("sessions", ["shepherd", "sessions"], () => refreshShepherd()); // shepherd.js loads after this file
const logWatchFeed = pushed("log", ["watch"], refreshWatch);
LOG_PARTS.push({ show() { renderLogChanges(); logWatchFeed.show(!wst.data); }, onEvent: logWatchFeed.onEvent });
// #sessions/<target> opens that session, as a Fleet row does. The agents list may not be
// loaded yet, so the open waits for it (refreshAgents returns once it has).
async function openArg() {
  const target = st.arg;
  if (!st.agents.length) await refreshAgents();
  const a = st.agents.find((x) => x.target === target);
  if (a && st.arg === target && (!st.sel || st.sel.target !== target)) select(a);
}
TABS.sessions = {
  show() {
    if (st.arg) openArg();
    else if (!st.sel) overview(false);
    watchFeed.show(!wst.data); shepFeed.show(!shst.data);
  },
  onEvent(ev) { watchFeed.onEvent(ev); shepFeed.onEvent(ev); },
};
