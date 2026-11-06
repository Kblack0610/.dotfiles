"use strict";
// The Fleet tab: who pays (Claude accounts), what each agentctl runner did, and how often the two
// judges were right; their verdict lists are Log's Judges' verdicts section. From /api/fleet (hub-core `fleet`, the same reader as the hub's Fleet tab).

// Newest verdict keys and ask questions are cut to this many characters; the full text is the hover.
const FLEET_CLIP = 70;
// open: the runners whose registry row is expanded; tonight: Workers in hub-core's Tonight
// order, not the default. Both kept across refreshes.
const fst = { data: null, err: null, open: new Set(), said: "all", tonight: false };

const refreshFleet = coalesce(async () => {
  try { fst.data = await api("/api/fleet"); fst.err = null; } catch (e) { fst.err = e.message; }
  if (st.tab === "fleet") renderFleet();
  if (st.tab === "log") renderLogVerdicts();
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

const kTok = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : `${n}`);
const base = (p) => p.split("/").pop();

// A judge's per-rule table, judge-eval's numbers under its current prompt. A rule not yet live
// shows how far its labels are from the bar.
function evalTable(e) {
  const pc = (x) => pct(x == null ? null : x / 100);
  const live = (r) => (r.live ? "yes" : r.bar ? `no (${r.bar.labels}/${r.bar.need} to bar)` : "no");
  const rows = e.rules.map((r) => `<tr><td>${esc(r.rule)}</td><td class="n">${r.verdicts}</td><td class="n">${r.scored}</td><td class="n">${pc(r.precision)}</td><td class="n">${pc(r.false_defer_pct)}</td><td>${live(r)}</td></tr>`).join("");
  return `<table class="tbl"><tr><th>rule</th><th class="n">calls</th><th class="n">scored</th><th class="n">prec</th><th class="n">false-defer</th><th>live</th></tr>${rows ||
    `<tr><td colspan="6" class="muted">no verdicts under prompt ${esc(e.prompt_sha)}</td></tr>`}</table>`;
}

// The expanded row: what the runner is allowed and runs on, what it cost in 24h, its newest calls
// with their Langfuse trace, and for a judge its judge-eval table.
function workerDetail(w) {
  const r = w.registry, c = r.calls;
  const prompt = r.prompt ? `<span title="${esc(r.prompt)}">${esc(base(r.prompt))}</span> ${esc(c.prompt_sha || (r.eval && r.eval.prompt_sha) || "")}` : "-";
  let h = `<div><b>${esc(r.role || "no role")}</b> <span class="muted" title="${esc(r.role_desc)}">${esc(r.caps || "")}</span>` +
    ` &nbsp; model ${esc(r.model || "-")} &nbsp; prompt ${prompt} &nbsp; effect ${esc(r.effect || "-")}</div>`;
  h += `<div>trigger ${esc(r.trigger)} | 24h: ${c.n_24h} calls, <span class="${c.errors_24h ? "bad" : ""}">${c.errors_24h} errors</span>, ${usd(c.cost_24h)}, ${kTok(c.tokens_24h)} tokens, p95 ${secs(c.p95_ms && c.p95_ms / 1000)}</div>`;
  if (c.recent.length) {
    h += `<table class="tbl"><tr><th class="n">when</th><th class="n">took</th><th>model</th><th class="n">$</th><th class="n">tokens</th><th>ok</th><th>trace</th></tr>${c.recent.map((x) =>
      `<tr><td class="n">${when(x.at)}</td><td class="n">${secs(x.ms / 1000)}</td><td class="muted">${esc(x.model)}</td><td class="n">${usd(x.cost)}</td><td class="n">${kTok(x.tokens)}</td>` +
      `<td class="${x.ok ? "" : "bad"}">${x.ok ? "ok" : "error"}</td><td>${x.link ? `<a href="${esc(x.link)}" target="_blank" rel="noopener">Langfuse</a>` : `<span class="muted">${esc(x.id)}</span>`}</td></tr>`).join("")}</table>`;
  }
  if (r.eval) h += evalTable(r.eval);
  return `<tr class="wdet"><td colspan="10">${h}</td></tr>`;
}

// slots, when given, prefixes each name with its Tonight slot: a time, "always", or a call's
// indent under its caller.
function workersTable(ws, slots) {
  if (!ws.length) return `<div class="empty">${slots ? "No runner runs before morning." : "No runners configured in ~/.config/agentctl/agents."}</div>`;
  return `<table class="tbl"><tr><th>runner</th><th>lane</th><th>last</th><th class="n">when</th><th class="n">runs 24h</th><th class="n">failed</th><th>why</th><th class="n">next</th><th class="n">$ 24h</th><th>score 7d</th></tr>${ws.map((w, i) => {
    const last = w.running_since ? `<td class="muted">running since ${when(w.running_since)}</td><td class="n">-</td>`
      : w.last ? `<td class="${okClass(w.last.ok)}">${esc(w.last.word || "-")}</td><td class="n">${when(w.last.at)}</td>`
      : `<td class="muted">no run this week</td><td class="n">-</td>`;
    const why = w.why ? `${esc(w.why.word)} ${cut(w.why.text || "")}` : "";
    const open = fst.open.has(w.name);
    // hub-core's score cell: judge-eval's counted 7d score, its title what it counted.
    const score = w.score ? `<td title="${esc(w.score.title)}">${esc(w.score.text)}</td>` : `<td class="muted">-</td>`;
    return `<tr class="wr${open ? " sel" : ""}${w.enabled ? "" : " muted"}" data-key="${esc(w.name)}"><td title="${esc(w.description)}">${slots ? `${slots[i]} ` : ""}${esc(w.name)}${w.enabled ? "" : " (off)"}</td><td class="muted">${esc(w.lane || "-")}</td>${last}` +
      `<td class="n">${w.runs_24h}</td><td class="n${w.failed_24h ? " bad" : ""}">${w.failed_24h}</td><td class="wrap muted">${why}</td>` +
      `<td class="n">${w.next ? when(w.next) : "-"}</td><td class="n">${usd(w.cost_24h)}</td>${score}</tr>` + (open ? workerDetail(w) : "");
  }).join("")}</table>`;
}

// The Tonight order: hub-core's slots joined to their workers, and the other timers as a count
// whose rows are Infra's Jobs.
function tonightWorkers(d) {
  const by = new Map(d.workers.map((w) => [w.name, w]));
  const rows = d.tonight.slots.filter((s) => by.has(s.name));
  const slot = (s) => (s.under ? `<span class="muted" title="called by ${esc(s.under)}">\`- </span>` : s.at ? clock(s.at * 1e3) : "always");
  const n = d.tonight.other_timers;
  return workersTable(rows.map((s) => by.get(s.name)), rows.map(slot)) +
    (n ? `<div class="muted more">+ ${n} other timers before ${clock(d.tonight.until * 1e3)}: <a href="#jobs">Infra Jobs</a></div>` : "");
}

const VERDICT_COLOR = { dispatch: "var(--b-done)", skip: "var(--c-other)", failed: "var(--b-needs)", error: "var(--b-needs)" };
const verdictColor = (v) => VERDICT_COLOR[v] || "var(--c1)";

function dispatchTiles(d) {
  const kinds = [...new Set([...Object.keys(d.counts_7d), ...Object.keys(d.counts_24h)])].sort();
  const floor = d.partial ? "+" : "";
  const tiles = kinds.map((k) => tile(k.toUpperCase(), d.counts_24h[k] || 0, verdictColor(k), `${d.counts_7d[k] || 0}${floor} in 7d`)).join("") +
    tile("STARTED", d.log_24h.started || 0, "var(--c1)", "sessions, 24h") +
    tile("REAPED", d.log_24h.reaped || 0, "var(--c3)", "sessions, 24h");
  return `<div class="tiles">${tiles}</div>`;
}

function dispatchList(d) {
  const rows = d.recent.slice(0, LOG_ROWS).map((v) => `<tr><td class="n">${when(v.ts)}</td><td>${esc(v.project)}</td><td>${cut(v.key)}</td>` +
    `<td><span class="chip sm" style="--c:${verdictColor(v.verdict)}">${esc(v.verdict)}</span></td><td class="n">${v.tier ?? "-"}</td>` +
    `<td>${v.clear == null ? "-" : v.clear ? "yes" : "no"}</td><td class="wrap muted">${esc(v.reason)}</td></tr>`).join("");
  return `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n">when</th><th>project</th><th>row</th><th>verdict</th><th class="n">tier</th><th>clear</th><th>reason</th></tr>${rows}</table>` : `<div class="empty">No verdicts yet.</div>`}</div>` + older(d.recent.length - LOG_ROWS);
}

// judge-eval's numbers under the judge's current prompt; nothing is recounted here.
function judgeTiles(j) {
  const tiles = tile("AGREE", j.agree, "var(--b-done)", j.precision == null ? "none scored" : `${j.precision}% precision`) +
    tile("DISAGREE", j.disagree, "var(--b-needs)", j.kappa == null ? "" : `kappa ${j.kappa}`) +
    tile("DEFERRED", j.deferred, "var(--c-other)", "judge said: ask you") +
    tile("FALSE-DEFER", j.false_defer, "var(--b-needs)", "you took the recommendation") +
    tile("PENDING", j.pending, "var(--b-stalled)", "judged, unanswered") +
    tile("UNSCORED", j.unscored, "var(--c3)", "free text, no option named");
  return `<div class="tiles">${tiles}</div>`;
}

// The answer judge's filters: hub_core::fleet::ASK_FILTERS, read as the row they keep.
const ASK_FILTERS = ["all", "answered", "would answer", "passed", "wrong"];
const askShown = (v, f) => f === "all" || (f === "wrong" ? v.score === "wrong" : v.said === f);

function judgeList(j) {
  const pct = (x) => (x == null ? "-" : `${x}%`);
  const shown = j.verdicts.filter((v) => askShown(v, fst.said));
  const seg = `<div class="seg fseg">` + ASK_FILTERS.map((f) =>
    chipBtn(f === fst.said, "data-said", f, f, j.verdicts.filter((v) => askShown(v, f)).length)).join("") + `</div>`;
  const why = (x) => `${x.rule && x.rule !== x.type ? `<b>${esc(x.rule)}</b> ` : ""}${x.evidence ? `"${esc(x.evidence)}" ` : ""}${esc(x.reason)}`;
  const rows = shown.slice(0, LOG_ROWS).map((x) => `<tr><td class="n">${when(x.at)}</td><td>${esc(x.project)}</td><td>${esc(x.type || x.rule || "-")}</td>` +
    `<td>${esc(x.said)}${x.judge ? ` <span class="muted">${cut(x.judge, 20)}</span>` : ""}</td><td class="wrap">${cut(x.question)}</td><td class="wrap muted">${why(x)}</td>` +
    `<td>${x.score === "wrong" ? `<span class="cchip bad">${cut(x.you, 30)}</span>` : cut(x.you, 30)}</td></tr>`).join("");
  return `<div class="muted">7d: ${pct(j.week.live_pct)} answered, ${pct(j.week.coverage)} would answer, ${pct(j.week.precision)} right</div>${seg}` +
    `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n">when</th><th>project</th><th>type</th><th>said</th><th>question</th><th>why</th><th>you</th></tr>${rows}</table>` : `<div class="empty">No verdicts here.</div>`}</div>`;
}

function renderFleet() {
  const el = $("fleet");
  const d = fst.data;
  if (!d) { el.innerHTML = `<div class="empty">${fst.err ? esc(fst.err) : "Loading..."}</div>`; return; }
  const errs = [...(fst.err ? [fst.err] : []), ...(d.errors || [])];
  let html = `<div class="bhead"><span>fleet <span class="muted">read ${d.at ? clock(d.at * 1e3) : "-"}</span></span></div>`;
  if (errs.length) html += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  html += `<h2 class="sec" id="sec-accounts">Claude accounts</h2><div class="panel scroll">${accountsTable(d)}</div>`;
  const order = `<button class="btn sm" data-tonight>${fst.tonight ? "Default order" : "Tonight"}</button>`;
  html += `<h2 class="sec" id="sec-workers">Workers ${order} <span class="muted">${fst.tonight ? `tonight, ${clock(d.at * 1e3)} to ${clock(d.tonight.until * 1e3)}` : `${d.workers.length} runners, ${usd(d.cost_24h)} in 24h across every agentctl run`}; click a runner for its role, prompt, calls and judge table</span></h2>` +
    `<div class="panel scroll">${fst.tonight ? tonightWorkers(d) : workersTable(d.workers)}</div>`;
  html += `<h2 class="sec" id="sec-judges">Dispatch judge <span class="muted">24h, with the week below; the verdicts are on Log</span></h2>${dispatchTiles(d.dispatch)}`;
  html += `<h2 class="sec">Answer judge <span class="muted">prompt ${esc(d.judge.prompt || "none")}, its call against your answer; every verdict is on Log</span></h2>${judgeTiles(d.judge)}`;
  paint(el, html);
}

// Log's Judges' verdicts section: the dispatch judge's newest verdicts and everything the answer
// judge said, with why and what you did.
function renderLogVerdicts() {
  const el = $("log-verdicts"), d = fst.data;
  if (!d) { el.innerHTML = `<div class="empty">${fst.err ? esc(fst.err) : "Loading."}</div>`; return; }
  paint(el, `<h3 class="sub">Dispatch judge <span class="muted">newest ${d.dispatch.recent.length}</span></h3>${dispatchList(d.dispatch)}` +
    `<h3 class="sub">Answer judge <span class="muted">newest ${d.judge.verdicts.length}</span></h3>${judgeList(d.judge)}`);
}

$("log-verdicts").addEventListener("click", (e) => {
  const b = e.target.closest("[data-said]");
  if (!b) return;
  fst.said = b.dataset.said;
  renderLogVerdicts();
});

$("fleet").addEventListener("click", (e) => {
  if (e.target.closest("a[target]")) return;
  if (e.target.closest("[data-tonight]")) { fst.tonight = !fst.tonight; renderFleet(); return; }
  const row = e.target.closest("tr.wr");
  if (!row) return;
  const k = row.dataset.key;
  if (!fst.open.delete(k)) fst.open.add(k);
  renderFleet();
});

const logFleetFeed = pushed("log", ["fleet", "asks"], refreshFleet);
LOG_PARTS.push({ show() { renderLogVerdicts(); logFleetFeed.show(!fst.data); }, onEvent: logFleetFeed.onEvent });
TABS.fleet = {
  show() { renderFleet(); pollFleet(); },
  onEvent(ev) {
    if (st.tab === "fleet" && (ev.kind === "fleet" || ev.kind === "asks" || ev.kind === "resync")) refreshFleet();
  },
};
