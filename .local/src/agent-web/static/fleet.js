"use strict";
// The Fleet tab: who pays (Claude accounts), what each agentctl runner did, and how the two
// judges call it, from /api/fleet (hub-core `fleet`, the same reader as the hub's Fleet tab).

// Newest verdict keys and ask questions are cut to this many characters; the full text is the hover.
const FLEET_CLIP = 70;
const fst = { data: null, err: null };

const refreshFleet = coalesce(async () => {
  try { fst.data = await api("/api/fleet"); fst.err = null; } catch (e) { fst.err = e.message; }
  if (st.tab === "fleet") renderFleet();
});

// The accounts and the dollars are Prometheus, which pushes nothing, so the open tab re-reads on
// Infra's cadence. The file parts also re-read on their own events (onEvent).
const pollFleet = poll("fleet", refreshFleet, INFRA_REFRESH_MS);

const cut = (s, n = FLEET_CLIP) => (s.length > n ? `<span title="${esc(s)}">${esc(s.slice(0, n - 2))}..</span>` : esc(s));

// One row per Claude account, from claude-acct's textfile. The weekly percent is what stops work,
// the 5h window what stops it for the next few hours;
// dollars are the OTel list-price estimate, for scale.
function accountsTable(inst) {
  const by = {};
  for (const s of inst.accounts || []) {
    (by[s.labels.account] = by[s.labels.account] || {})[s.labels.__name__.replace("claude_account_", "")] = +s.value;
  }
  const names = Object.keys(by).sort();
  if (!names.length) return `<div class="empty">no data</div>`;
  return `<table class="tbl"><tr><th>account</th><th>week used</th><th class="n">used</th><th class="n">week gone</th><th>pace</th><th>runs out</th><th>resets</th><th class="n">5h</th><th>5h resets</th><th class="n">live</th><th class="n">24h</th></tr>${names.map((n) => {
    const a = by[n];
    if (a.read_ok === 0) return `<tr><td>${esc(n)}</td><td colspan="10" class="bad">usage unreadable</td></tr>`;
    if (a.week_used_percent == null) return `<tr><td>${esc(n)}</td><td colspan="10" class="muted">idle, token refreshes on launch</td></tr>`;
    const over = a.over_pace === 1;
    return `<tr><td>${esc(n)}</td><td class="m">${meter(a.week_used_percent / 100, over ? "var(--b-stalled)" : "var(--c1)")}</td><td class="n">${Math.floor(a.week_used_percent)}%</td><td class="n">${Math.floor(a.week_gone_percent)}%</td><td>${over ? "over" : "under"}</td><td>${when(a.run_out_timestamp_seconds)}</td><td>${when(a.resets_timestamp_seconds)}</td><td class="n">${a.five_hour_percent == null ? "-" : Math.floor(a.five_hour_percent) + "%"}</td><td>${when(a.five_hour_resets_timestamp_seconds)}</td><td class="n">${a.live_sessions ?? "-"}</td><td class="n">${usd(a.cost_24h_usd)}</td></tr>`;
  }).join("")}</table>`;
}

const okClass = (ok) => (ok === false ? "bad" : ok == null ? "warn" : "");

function workersTable(ws) {
  if (!ws.length) return `<div class="empty">No runners configured in ~/.config/agentctl/agents.</div>`;
  return `<table class="tbl"><tr><th>runner</th><th>lane</th><th>last</th><th class="n">when</th><th class="n">runs 24h</th><th class="n">failed</th><th>why</th><th class="n">next</th><th class="n">$ 24h</th></tr>${ws.map((w) => {
    const last = w.running_since ? `<td class="muted">running since ${when(w.running_since)}</td><td class="n">-</td>`
      : w.last ? `<td class="${okClass(w.last.ok)}">${esc(w.last.word || "-")}</td><td class="n">${when(w.last.at)}</td>`
      : `<td class="muted">no run this week</td><td class="n">-</td>`;
    const why = w.why ? `${esc(w.why.word)} ${cut(w.why.text || "")}` : "";
    return `<tr${w.enabled ? "" : ` class="muted"`}><td title="${esc(w.description)}">${esc(w.name)}${w.enabled ? "" : " (off)"}</td><td class="muted">${esc(w.lane || "-")}</td>${last}` +
      `<td class="n">${w.runs_24h}</td><td class="n${w.failed_24h ? " bad" : ""}">${w.failed_24h}</td><td class="wrap muted">${why}</td>` +
      `<td class="n">${w.next ? when(w.next) : "-"}</td><td class="n">${usd(w.cost_24h)}</td></tr>`;
  }).join("")}</table>`;
}

const VERDICT_COLOR = { dispatch: "var(--b-done)", skip: "var(--b-unclear)", failed: "var(--b-needs)", error: "var(--b-needs)" };
const verdictColor = (v) => VERDICT_COLOR[v] || "var(--c1)";

function dispatchPart(d) {
  const kinds = [...new Set([...Object.keys(d.counts_7d), ...Object.keys(d.counts_24h)])].sort();
  const floor = d.partial ? "+" : "";
  const tiles = kinds.map((k) => tile(k.toUpperCase(), d.counts_24h[k] || 0, verdictColor(k), `${d.counts_7d[k] || 0}${floor} in 7d`)).join("") +
    tile("STARTED", d.log_24h.started || 0, "var(--c1)", "sessions, 24h") +
    tile("REAPED", d.log_24h.reaped || 0, "var(--c3)", "sessions, 24h");
  const rows = d.recent.map((v) => `<tr><td class="n">${when(v.ts)}</td><td>${esc(v.project)}</td><td>${cut(v.key)}</td>` +
    `<td><span class="chip sm" style="--c:${verdictColor(v.verdict)}">${esc(v.verdict)}</span></td><td class="n">${v.tier ?? "-"}</td>` +
    `<td>${v.clear == null ? "-" : v.clear ? "yes" : "no"}</td><td class="wrap muted">${esc(v.reason)}</td></tr>`).join("");
  return `<div class="tiles">${tiles}</div><div class="sp"></div>` +
    `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n">when</th><th>project</th><th>row</th><th>verdict</th><th class="n">tier</th><th>clear</th><th>reason</th></tr>${rows}</table>` : `<div class="empty">No verdicts yet.</div>`}</div>`;
}

function judgePart(j) {
  const scored = j.agree + j.disagree;
  const tiles = tile("AGREE", j.agree, "var(--b-done)", scored ? `${Math.round((100 * j.agree) / scored)}% of scored` : "none scored") +
    tile("DISAGREE", j.disagree, "var(--b-needs)") +
    tile("DEFERRED", j.deferred, "var(--b-unclear)", "judge said: ask you") +
    tile("PENDING", j.pending, "var(--b-stalled)", "judged, unanswered") +
    tile("UNSCORED", j.unscored, "var(--c3)", "answered in session");
  const rows = j.disagreements.map((x) => `<tr><td class="n">${when(x.answered_at)}</td><td>${esc(x.project)}</td><td class="wrap">${cut(x.question)}</td>` +
    `<td>${cut(x.judge, 30)}</td><td>${cut(x.answer, 30)}</td><td class="wrap muted">${esc(x.reason)}</td></tr>`).join("");
  return `<div class="tiles">${tiles}</div><div class="sp"></div>` +
    `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n">answered</th><th>project</th><th>question</th><th>judge</th><th>you</th><th>judge's reason</th></tr>${rows}</table>` : `<div class="empty">No disagreements.</div>`}</div>`;
}

function renderFleet() {
  const el = $("fleet");
  const d = fst.data;
  if (!d) { el.innerHTML = `<div class="empty">${fst.err ? esc(fst.err) : "Loading..."}</div>`; return; }
  const errs = [...(fst.err ? [fst.err] : []), ...(d.errors || [])];
  let html = `<div class="bhead"><span>fleet <span class="muted">read ${d.at ? clock(d.at * 1e3) : "-"}</span></span></div>`;
  if (errs.length) html += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  html += `<h2 class="sec">Claude accounts</h2><div class="panel scroll">${accountsTable(d)}</div>`;
  html += `<h2 class="sec">Workers <span class="muted">${d.workers.length} runners, ${usd(d.cost_24h)} in 24h across every agentctl run</span></h2>` +
    `<div class="panel scroll">${workersTable(d.workers)}</div>`;
  html += `<h2 class="sec">Dispatch judge <span class="muted">24h, with the week below; newest ${d.dispatch.recent.length}</span></h2>${dispatchPart(d.dispatch)}`;
  html += `<h2 class="sec">Answer judge <span class="muted">its call against your answer</span></h2>${judgePart(d.judge)}`;
  paint(el, html);
}

TABS.fleet = {
  show() { renderFleet(); pollFleet(); },
  onEvent(ev) {
    if (st.tab === "fleet" && (ev.kind === "fleet" || ev.kind === "asks" || ev.kind === "resync")) refreshFleet();
  },
};
