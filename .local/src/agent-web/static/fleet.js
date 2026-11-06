"use strict";
// The Fleet tab: who pays (Claude accounts), what each agentctl runner did, and one tile each for
// the two judges; their verdict lists are Log's Judges' verdicts section. From /api/fleet (hub-core
// `fleet`, the same reader as the hub's Fleet tab). `#fleet/<runner>` is one runner's page, read
// from /api/fleet/runner only when it opens (hub-core `fleet::runner`).

// Newest verdict keys and ask questions are cut to this many characters; the full text is the hover.
const FLEET_CLIP = 70;
// open: the runners whose registry row is expanded; tonight: Workers in hub-core's Tonight
// order, not the default. Both kept across refreshes.
const fst = { data: null, err: null, open: new Set(), said: "all", tonight: false };

// The open runner page: whose, what it read, and the run whose log is shown.
const rst = { name: "", data: null, err: null, log: null, sel: "" };
const runnerHref = (name) => "#fleet/" + encodeURIComponent(name);

const refreshFleet = coalesce(async () => {
  try { fst.data = await api("/api/fleet"); fst.err = null; } catch (e) { fst.err = e.message; }
  if (st.tab === "fleet") renderFleet();
  if (st.tab === "log") renderLogVerdicts();
});

const refreshRunner = coalesce(async () => {
  const name = st.arg;
  if (!name) return;
  try { rst.data = await api("/api/fleet/runner?name=" + encodeURIComponent(name)); rst.err = null; } catch (e) { rst.data = null; rst.err = e.message; }
  if (st.tab === "fleet" && st.arg === name) renderFleet();
});

// The accounts and the dollars are Prometheus, which pushes nothing, so the open tab re-reads on
// Infra's cadence; a runner page re-reads its status the same way. The file parts also re-read
// on their own events (onEvent).
const pollFleet = poll("fleet", () => (st.arg ? refreshRunner() : refreshFleet()), INFRA_REFRESH_MS);

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

// What the runner is allowed and runs on: its role, model, prompt and effect.
function registryLine(r) {
  const prompt = r.prompt ? `<span title="${esc(r.prompt)}">${esc(base(r.prompt))}</span> ${esc(r.calls.prompt_sha || (r.eval && r.eval.prompt_sha) || "")}` : "-";
  return `<div><b>${esc(r.role || "no role")}</b> <span class="muted" title="${esc(r.role_desc)}">${esc(r.caps || "")}</span>` +
    ` &nbsp; model ${esc(r.model || "-")} &nbsp; prompt ${prompt} &nbsp; effect ${esc(r.effect || "-")}</div>`;
}

// Calls newest first, each with its Langfuse trace.
const callsTable = (recent) => `<table class="tbl"><tr><th class="n">when</th><th class="n">took</th><th>model</th><th class="n">$</th><th class="n">tokens</th><th>ok</th><th>trace</th></tr>${recent.map((x) =>
  `<tr><td class="n">${when(x.at)}</td><td class="n">${secs(x.ms / 1000)}</td><td class="muted">${esc(x.model)}</td><td class="n">${usd(x.cost)}</td><td class="n">${kTok(x.tokens)}</td>` +
  `<td class="${x.ok ? "" : "bad"}">${x.ok ? "ok" : "error"}</td><td>${x.link ? `<a href="${esc(x.link)}" target="_blank" rel="noopener">Langfuse</a>` : `<span class="muted">${esc(x.id)}</span>`}</td></tr>`).join("")}</table>`;

// The expanded row: what the runner is allowed and runs on, what it cost in 24h, its newest calls
// with their Langfuse trace, and for a judge its judge-eval table. The rest is its page.
function workerDetail(w) {
  const r = w.registry, c = r.calls;
  let h = registryLine(r);
  h += `<div>trigger ${esc(r.trigger)} | 24h: ${c.n_24h} calls, <span class="${c.errors_24h ? "bad" : ""}">${c.errors_24h} errors</span>, ${usd(c.cost_24h)}, ${kTok(c.tokens_24h)} tokens, p95 ${secs(c.p95_ms && c.p95_ms / 1000)}` +
    ` | <a href="${runnerHref(w.name)}">runs, logs, status and 7d on its page</a></div>`;
  if (c.recent.length) h += callsTable(c.recent);
  if (r.eval) h += evalTable(r.eval);
  return `<tr class="wdet"><td colspan="10">${h}</td></tr>`;
}

// The Workers filter lives in the URL so a view can be linked: `#fleet?lane=deliver&s=failed`.
// What keeps and orders a row mirrors hub_core::fleet (Worker::shown, hits, sort_value) as
// askShown does; the two lists are hub-core's, checked by assets.rs.
const W_FILTERS = ["all", "failed", "running", "idle", "off"];
const W_SORTS = ["runs", "failed", "cost", "last"];
const W_CHIP = { all: "All", failed: "Failed 24h", running: "Running", idle: "Idle", off: "Off" };
const workerShown = (w, s) => s === "all" || (s === "failed" ? w.failed_24h > 0 : w.state === s);
const W_VALUE = {
  runs: (w) => w.runs_24h,
  failed: (w) => w.failed_24h,
  cost: (w) => w.cost_24h,
  last: (w) => w.running_since ?? w.last?.at,
};

function fleetView() {
  const p = new URLSearchParams(st.views.fleet);
  const s = p.get("s"), sort = p.get("sort");
  return { q: p.get("q") || "", lane: p.get("lane") || "", s: W_FILTERS.includes(s) ? s : "all", sort: W_SORTS.includes(sort) ? sort : "", asc: p.get("dir") === "asc" };
}

// Writes only what differs from the plain view, so the plain view is a bare `#fleet`.
function setFleetView(patch) {
  const v = { ...fleetView(), ...patch };
  const p = new URLSearchParams();
  if (v.q) p.set("q", v.q);
  if (v.lane) p.set("lane", v.lane);
  if (v.s !== "all") p.set("s", v.s);
  if (v.sort) p.set("sort", v.sort);
  if (v.sort && v.asc) p.set("dir", "asc");
  setQuery(p.toString());
}

// The search and lane, which the chips' counts follow; the chip itself is left out of them.
function workerMatch(w, v) {
  const q = v.q.trim().toLowerCase();
  const hay = [w.name, w.description, w.why ? `${w.why.word} ${w.why.text}` : ""];
  return (!v.lane || w.lane === v.lane) && (!q || hay.some((t) => t.toLowerCase().includes(q)));
}
const workerKept = (w, v) => workerMatch(w, v) && workerShown(w, v.s);

// The kept rows in the sort, or in hub-core's order, exceptions first, with none. A runner with
// no value goes last in either direction.
function workersShown(ws, v) {
  const out = ws.filter((w) => workerKept(w, v));
  if (!v.sort) return out;
  const val = W_VALUE[v.sort];
  return out.sort((a, b) => {
    const x = val(a) ?? null, y = val(b) ?? null;
    if (x === null || y === null) return (x === null) - (y === null);
    return v.asc ? x - y : y - x;
  });
}

// slots, when given, prefixes each name with its Tonight slot: a time, "always", or a call's
// indent under its caller, and the headers do not sort. v is the filter in force.
function workersTable(ws, slots, v) {
  const filtered = v.q || v.lane || v.s !== "all";
  if (!ws.length) return `<div class="empty">${filtered ? "No runner matches this filter." : slots ? "No runner runs before morning." : "No runners configured in ~/.config/agentctl/agents."}</div>`;
  // A click on a sortable header goes biggest first, smallest first, back to the default order.
  const th = (key, label, cls) => {
    const on = !slots && v.sort === key;
    return `<th${cls ? ` class="${cls}"` : ""}${on ? ` aria-sort="${v.asc ? "ascending" : "descending"}"` : ""}>${slots ? label : `<button class="thsort" data-fsort="${key}" title="sort by ${label}">${label}${on ? (v.asc ? " ^" : " v") : ""}</button>`}</th>`;
  };
  return `<table class="tbl"><tr><th>runner</th><th>lane</th>${th("last", "last")}<th class="n">when</th>${th("runs", "runs 24h", "n")}${th("failed", "failed", "n")}<th>why</th><th class="n">next</th>${th("cost", "$ 24h", "n")}<th>score 7d</th></tr>${ws.map((w, i) => {
    const over = w.overdue ? `, over its usual ${secs(w.usual_s)}` : "";
    const last = w.running_since ? `<td class="${w.overdue ? "warn" : "muted"}">running since ${when(w.running_since)}${over}</td><td class="n">-</td>`
      : w.last ? `<td class="${okClass(w.last.ok)}">${esc(w.last.word || "-")}</td><td class="n">${when(w.last.at)}</td>`
      : `<td class="muted">no run this week</td><td class="n">-</td>`;
    const why = w.why ? `${esc(w.why.word)} ${cut(w.why.text || "")}` : "";
    const open = fst.open.has(w.name);
    // hub-core's score cell: judge-eval's counted 7d score, its title what it counted.
    const score = w.score ? `<td title="${esc(w.score.title)}">${esc(w.score.text)}</td>` : `<td class="muted">-</td>`;
    return `<tr class="wr${open ? " sel" : ""}${w.enabled ? "" : " muted"}" data-key="${esc(w.name)}"><td title="${esc(w.description)}">${slots ? `${slots[i]} ` : ""}<a href="${runnerHref(w.name)}">${esc(w.name)}</a>${w.enabled ? "" : " (off)"}</td><td class="muted">${esc(w.lane || "-")}</td>${last}` +
      `<td class="n">${w.runs_24h}</td><td class="n${w.failed_24h ? " bad" : ""}">${w.failed_24h}</td><td class="wrap muted">${why}</td>` +
      `<td class="n">${w.next ? when(w.next) : "-"}</td><td class="n">${usd(w.cost_24h)}</td>${score}</tr>` + (open ? workerDetail(w) : "");
  }).join("")}</table>`;
}

// The Tonight order: hub-core's slots joined to their workers, and the other timers as a count
// whose rows are Infra's Jobs.
function tonightWorkers(d, v) {
  const by = new Map(d.workers.filter((w) => workerKept(w, v)).map((w) => [w.name, w]));
  const rows = d.tonight.slots.filter((s) => by.has(s.name));
  const slot = (s) => (s.under ? `<span class="muted" title="called by ${esc(s.under)}">\`- </span>` : s.at ? clock(s.at * 1e3) : "always");
  const n = d.tonight.other_timers;
  return workersTable(rows.map((s) => by.get(s.name)), rows.map(slot), v) +
    (n ? `<div class="muted more">+ ${n} other timers before ${clock(d.tonight.until * 1e3)}: <a href="#jobs">Infra Jobs</a></div>` : "");
}

const workersBody = (d, v) => (fst.tonight ? tonightWorkers(d, v) : workersTable(workersShown(d.workers, v), null, v));
const workersChips = (d, v) => {
  const ws = d.workers.filter((w) => workerMatch(w, v));
  return W_FILTERS.map((f) => chipBtn(f === v.s, "data-fstate", f, W_CHIP[f], ws.filter((w) => workerShown(w, f)).length)).join("");
};

function workersFilter(d, v) {
  const lanes = [...new Set([...d.workers.map((w) => w.lane), v.lane].filter(Boolean))].sort();
  return `<div class="card bfilter qcfilter"><div class="opts"><input id="fw-q" placeholder="search name, description, why" value="${esc(v.q)}">` +
    `<select id="fw-lane"><option value="">every lane</option>${bOpt(lanes, v.lane)}</select></div></div>` +
    `<div class="seg fseg" id="fw-chips">${workersChips(d, v)}</div>`;
}

// Repaints what a filter changes and nothing around it, so the search box keeps its focus.
function paintWorkers() {
  const v = fleetView();
  paint($("fw-chips"), workersChips(fst.data, v));
  paint($("fw-body"), workersBody(fst.data, v));
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

// The Fleet tab's one tile per judge; its tiles and newest verdicts are the judge's runner page.
// The judge's runner is the one whose conf names that extras block (DETAIL=); no such conf, no link.
const pageFor = (d, detail) => (d.workers || []).find((w) => w.detail === detail)?.name;
const pageHref = (d, detail) => { const n = pageFor(d, detail); return n && runnerHref(n); };
const pageLink = (name, label) => name ? `<a href="${runnerHref(name)}">${label}</a>` : label;
function judgeSummary(f) {
  const d = f.dispatch, j = f.judge, c = d.counts_24h;
  return `<div class="tiles roomy">` +
    tile("DISPATCH JUDGE", c.dispatch || 0, verdictColor("dispatch"), `dispatched 24h, ${c.skip || 0} skipped, ${(c.failed || 0) + (c.error || 0)} failed`, pageHref(f, "dispatch-verdicts")) +
    tile("ANSWER JUDGE", j.precision == null ? "-" : `${j.precision}%`, "var(--b-done)", `precision, ${j.agree} agree, ${j.disagree} disagree, ${j.pending} pending`, pageHref(f, "ask-judge")) +
    `</div>`;
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
  if (st.arg) { renderRunner(el); return; }
  const d = fst.data;
  if (!d) { el.innerHTML = `<div class="empty">${fst.err ? esc(fst.err) : "Loading..."}</div>`; return; }
  const v = fleetView();
  const errs = [...(fst.err ? [fst.err] : []), ...(d.errors || [])];
  let head = `<div class="bhead"><span>fleet <span class="muted">read ${d.at ? clock(d.at * 1e3) : "-"}</span></span></div>`;
  if (errs.length) head += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  head += `<h2 class="sec" id="sec-accounts">Claude accounts</h2><div class="panel scroll">${accountsTable(d)}</div>`;
  const order = `<button class="btn sm" data-tonight>${fst.tonight ? "Default order" : "Tonight"}</button>`;
  head += `<h2 class="sec" id="sec-workers">Workers ${order} <span class="muted">${fst.tonight ? `tonight, ${clock(d.at * 1e3)} to ${clock(d.tonight.until * 1e3)}` : `${d.workers.length} runners, ${usd(d.cost_24h)} in 24h across every agentctl run`}; click a runner for its role, prompt, calls and judge table</span></h2>`;
  const tail = `<h2 class="sec" id="sec-judges">Judges <span class="muted">24h; each judge's page has its tiles and newest verdicts, Log has every verdict</span></h2>${judgeSummary(d)}`;
  // A refresh must not take the search box or an open lane list from under the human, so
  // everything around them repaints and they stay.
  if (["fw-q", "fw-lane"].includes(document.activeElement?.id)) {
    paint($("fleet-head"), head);
    paintWorkers();
    paint($("fleet-tail"), tail);
    return;
  }
  paint(el, `<div id="fleet-head">${head}</div>${workersFilter(d, v)}<div class="panel scroll" id="fw-body">${workersBody(d, v)}</div><div id="fleet-tail">${tail}</div>`);
}

// One run's log on the runner page, through Infra's reader and the run's byte range.
async function runnerLog(j) {
  rst.sel = jobKey(j);
  const log = rst.log = { title: `${j.name} ${when(j.started)}`, text: "Loading..." };
  renderFleet();
  log.text = await jobLogText(j);
  if (st.tab === "fleet" && rst.log === log) renderFleet();
}

const RUNNER_TIME_KEYS = ["updated", "next"];

// A lane's extras block, picked by the runner conf's DETAIL= key (hub_core::fleet::runner::DETAILS).
function runnerExtras(x) {
  switch (x.kind) {
    case "dispatch-verdicts":
      return `<h2 class="sec">Dispatch judge <span class="muted">24h, with the week below; newest ${x.dispatch.recent.length} here, every verdict on <a href="#log">Log</a></span></h2>` +
        dispatchTiles(x.dispatch) + dispatchList(x.dispatch);
    case "ask-judge":
      return `<h2 class="sec">Answer judge <span class="muted">prompt ${esc(x.judge.prompt || "none")}, its call against your answer; newest ${x.judge.verdicts.length} here, every verdict on <a href="#log">Log</a></span></h2>` +
        judgeTiles(x.judge) + judgeList(x.judge);
    case "ingest": {
      const kinds = Object.keys(x.counts_7d).sort();
      const tiles = kinds.map((k) => tile(k.toUpperCase(), x.counts_7d[k], "var(--c1)", `in 7d${x.partial ? "+" : ""}`)).join("");
      const rows = x.steps.map((t) => `<tr><td class="n">${when(t.ts)}</td><td>${esc(t.action)}</td><td class="muted">${esc(t.from)}${t.to ? ` -&gt; ${esc(t.to)}` : ""}</td><td class="wrap">${cut(t.text)}</td></tr>`).join("");
      return `<h2 class="sec">Intake <span class="muted">what it filed from the inbox, from the ingest record</span></h2>` +
        (tiles ? `<div class="tiles">${tiles}</div>` : "") +
        `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n">when</th><th>action</th><th>from -&gt; to</th><th>line</th></tr>${rows}</table>` : `<div class="empty">No intake step in 7 days.</div>`}</div>`;
    }
    case "sentinel-watches": {
      const cls = (w) => (w.state === "TRIP" || w.state === "ERROR" ? "bad" : w.state === "OK" ? "" : "muted");
      const rows = x.watches.map((w) => `<tr><td>${esc(w.name)}</td><td class="${cls(w)}">${esc(w.state)}</td><td class="muted">${esc(w.severity || "-")}</td><td class="n">${when(w.since)}</td><td class="n">${when(w.lastrun)}</td><td class="n">${when(w.lasttrip)}</td></tr>`).join("");
      const trip = x.watches.filter((w) => w.state === "TRIP").length;
      return `<h2 class="sec">Watches <span class="muted">${x.watches.length} watches, ${trip} tripped</span></h2>` +
        `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th>watch</th><th>state</th><th>severity</th><th class="n">since</th><th class="n">last run</th><th class="n">last trip</th></tr>${rows}</table>` : `<div class="empty">No watch defined.</div>`}</div>`;
    }
    default:
      return "";
  }
}

// `#fleet/<runner>`: summary first, then its runs with their logs, status and activity, calls,
// what the registry says, the lane's extras, and the conf.
function renderRunner(el) {
  const back = `<a class="btn sm" href="#fleet${st.views.fleet ? "?" + st.views.fleet : ""}">All runners</a>`;
  const r = rst.data;
  if (!r) { paint(el, `<div class="bhead"><span>${esc(st.arg)}</span>${back}</div><div class="${rst.err ? "panel down" : "empty"}">${rst.err ? esc(rst.err) : "Loading..."}</div>`); return; }
  const g = r.registry, day = r.calls.day, week = r.calls.week;
  let h = `<div class="bhead"><span>${esc(r.name)} <span class="muted">${esc(r.lane || "no lane")}, read ${clock(r.at * 1e3)}</span></span>${back}</div>`;
  if (r.errors.length) h += `<div class="panel down">${r.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  if (r.description) h += `<div class="muted">${esc(r.description)}</div>`;
  const state = r.state === "running" ? `since ${when(r.running_since)}` : r.enabled ? "" : "disabled in its conf";
  const detail = r.status.detail || "";
  h += `<div class="tiles roomy">` +
    tile("STATE", esc(r.state.toUpperCase()), r.state === "running" ? "var(--b-working)" : r.state === "off" ? "var(--b-parked)" : "var(--c1)", state) +
    tile("NEXT", r.next ? when(r.next) : "-", "var(--c1)", r.next ? "" : "no timer, no retry") +
    tile("RUNS 14D", r.runs_total, "var(--c1)", `${r.failed_total} failed`) +
    tile("CALLS 24H", day.calls, day.errors ? "var(--b-needs)" : "var(--c1)", day.cost == null ? `${day.errors} errors` : `${day.errors} errors, ${usd(day.cost)}`) +
    `</div>`;
  if (detail) h += `<div>status: ${cut(detail, 160)}</div>`;

  h += `<h2 class="sec">Runs <span class="muted">14 days of runs.jsonl, ${r.runs_total} runs, ${r.failed_total} failed; click a run for its log</span></h2>`;
  if (r.days.some((x) => x.runs)) {
    h += `<div class="panel scroll"><table class="tbl"><tr><th></th>${r.days.map((x) => `<th class="n">${esc(x.day)}</th>`).join("")}</tr>` +
      `<tr><td>runs</td>${r.days.map((x) => `<td class="n">${x.runs || "-"}</td>`).join("")}</tr>` +
      `<tr><td>failed</td>${r.days.map((x) => `<td class="n${x.failed ? " bad" : ""}">${x.failed || "-"}</td>`).join("")}</tr></table></div>`;
  }
  if (!r.runs.length) {
    h += `<div class="empty">no run in 14 days${g.kind === "call" ? ` <span class="muted">(${esc(g.trigger)}; its calls are below)</span>` : ""}</div>`;
  } else {
    const rows = r.runs.map((j, i) => `<tr class="jr rr${jobKey(j) === rst.sel ? " sel" : ""}${j.log ? " haslog" : ""}" data-i="${i}"><td class="n">${when(j.started)}</td><td class="n">${secs(j.secs)}</td>${resultCell(j)}<td class="muted">${esc(j.detail || "")}</td></tr>`).join("");
    h += `<div class="panel scroll"><table class="tbl"><tr><th class="n">started</th><th class="n">took</th><th>result</th><th>detail</th></tr>${rows}</table></div>` + older(r.runs_older);
  }
  if (rst.log) h += `<h3 class="sub">Log <span class="muted">${esc(rst.log.title)}</span></h3><pre class="panel joblog">${esc(rst.log.text)}</pre>`;

  const status = Object.entries(r.status).map(([k, v]) => `<tr><td>${esc(k)}</td><td class="wrap">${RUNNER_TIME_KEYS.includes(k) && /^\d+$/.test(v) ? when(+v) : esc(v)}</td></tr>`).join("");
  const act = r.activity.map((a) => `<tr><td class="n">${when(a.at)}</td><td class="${okClass(a.ok)}">${esc(a.word)}</td><td class="wrap muted">${esc(a.text || "")}</td></tr>`).join("");
  h += `<h2 class="sec">Status and activity <span class="muted">its status file, then the newest activity.log lines</span></h2>` +
    `<div class="panel scroll">${status ? `<table class="tbl">${status}</table>` : `<div class="empty">No status file.</div>`}</div>` +
    (act ? `<div class="panel scroll"><table class="tbl"><tr><th class="n">when</th><th>outcome</th><th>text</th></tr>${act}</table></div>` : "");

  const plus = r.calls.partial ? "+" : "";
  const trow = (l, t, p = "") => `<tr><td>${l}</td><td class="n">${t.calls}${p}</td><td class="n${t.errors ? " bad" : ""}">${t.errors}${p}</td><td class="n">${kTok(t.tokens)}${p}</td><td class="n">${usd(t.cost)}${t.cost == null ? "" : p}</td><td class="n">${secs(t.p50_ms && t.p50_ms / 1000)}</td></tr>`;
  h += `<h2 class="sec">Calls <span class="muted">calls.jsonl${plus ? "; the week is a floor, its start is past the tail read" : ""}</span></h2>` +
    `<div class="panel scroll"><table class="tbl"><tr><th></th><th class="n">calls</th><th class="n">errors</th><th class="n">tokens</th><th class="n">$</th><th class="n">p50</th></tr>${trow("24h", day)}${trow("7d", week, plus)}</table>` +
    (r.calls.recent.length ? callsTable(r.calls.recent) : "") + `</div>`;

  h += `<h2 class="sec">Registry <span class="muted">trigger ${esc(g.trigger)}</span></h2><div class="panel">${registryLine(g)}${g.eval ? evalTable(g.eval) : ""}</div>`;
  h += runnerExtras(r.extras);
  const conf = r.conf.map((c) => `<tr><td>${esc(c.key)}</td><td class="wrap muted">${esc(c.value)}</td></tr>`).join("");
  h += `<h2 class="sec">Conf <span class="muted">~/.config/agentctl/agents/${esc(r.name)}.conf</span></h2><div class="panel scroll">${conf ? `<table class="tbl">${conf}</table>` : `<div class="empty">Empty.</div>`}</div>`;
  paint(el, h);
}

// Log's Judges' verdicts section: the dispatch judge's newest verdicts and everything the answer
// judge said, with why and what you did.
function renderLogVerdicts() {
  const el = $("log-verdicts"), d = fst.data;
  if (!d) { el.innerHTML = `<div class="empty">${fst.err ? esc(fst.err) : "Loading."}</div>`; return; }
  paint(el, `<h3 class="sub">${pageLink(pageFor(d, "dispatch-verdicts"), "Dispatch judge")} <span class="muted">newest ${d.dispatch.recent.length}</span></h3>${dispatchList(d.dispatch)}` +
    `<h3 class="sub">${pageLink(pageFor(d, "ask-judge"), "Answer judge")} <span class="muted">newest ${d.judge.verdicts.length}</span></h3>${judgeList(d.judge)}`);
}

$("log-verdicts").addEventListener("click", (e) => {
  const b = e.target.closest("[data-said]");
  if (!b) return;
  fst.said = b.dataset.said;
  renderLogVerdicts();
});

$("fleet").addEventListener("click", (e) => {
  if (e.target.closest("a")) return;
  const said = e.target.closest("[data-said]");
  if (said) { fst.said = said.dataset.said; renderFleet(); return; }
  const run = e.target.closest("tr.rr");
  if (run) { const j = rst.data && rst.data.runs[+run.dataset.i]; if (j) runnerLog(j); return; }
  if (e.target.closest("[data-tonight]")) { fst.tonight = !fst.tonight; renderFleet(); return; }
  const chip = e.target.closest("[data-fstate]");
  if (chip) { setFleetView({ s: chip.dataset.fstate }); renderFleet(); return; }
  const sort = e.target.closest("[data-fsort]");
  if (sort) {
    const k = sort.dataset.fsort, v = fleetView();
    setFleetView(v.sort !== k ? { sort: k, asc: false } : v.asc ? { sort: "", asc: false } : { asc: true });
    renderFleet();
    return;
  }
  const row = e.target.closest("tr.wr");
  if (!row) return;
  const k = row.dataset.key;
  if (!fst.open.delete(k)) fst.open.add(k);
  renderFleet();
});

$("fleet").addEventListener("input", (e) => {
  if (e.target.id !== "fw-q") return;
  setFleetView({ q: e.target.value });
  paintWorkers();
});
$("fleet").addEventListener("change", (e) => {
  if (e.target.id !== "fw-lane") return;
  setFleetView({ lane: e.target.value });
  paintWorkers();
});

const logFleetFeed = pushed("log", ["fleet", "asks"], refreshFleet);
LOG_PARTS.push({ show() { renderLogVerdicts(); logFleetFeed.show(!fst.data); }, onEvent: logFleetFeed.onEvent });
TABS.fleet = {
  show() {
    if (rst.name !== st.arg) Object.assign(rst, { name: st.arg, data: null, err: null, log: null, sel: "" });
    renderFleet();
    pollFleet();
  },
  onEvent(ev) {
    if (st.tab === "fleet" && (ev.kind === "fleet" || ev.kind === "asks" || ev.kind === "resync")) (st.arg ? refreshRunner() : refreshFleet());
  },
};
