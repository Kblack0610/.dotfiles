"use strict";
// The Fleet tab: who is working, on what, and can I afford it. One table (the shared one,
// table.js) of every runner and live session by tier; a row opens its record, and a tier 1 row
// folds the rows under it. Below it, who pays (Claude accounts). The judges' verdict lists are
// Log's Judges' verdicts section. From /api/fleet (hub-core `fleet`, the same reader as the hub's
// Fleet tab). `#fleet/<runner>` is one runner's page, read from /api/fleet/runner only when it
// opens (hub-core `fleet::runner`).

// Newest verdict keys and ask questions are cut to this many characters; the full text is the hover.
const FLEET_CLIP = 70;
// fold: the tier 1 rows the human closed, kept across refreshes; said: the answer judge's filter on Log.
const fst = { data: null, err: null, fold: new Set(), said: "all" };

// The open runner page: whose, what it read, and the run whose log is shown.
const rst = { name: "", data: null, err: null, log: null, sel: "" };
const runnerHref = (name) => "#fleet/" + encodeURIComponent(name);

// The view keys of the URL plus the closed rows, as the API's query.
function fleetParams() {
  const p = tblParams(st.views.fleet);
  if (fst.fold.size) p.set("fold", [...fst.fold].join(","));
  const q = p.toString();
  return q ? "?" + q : "";
}

const refreshFleet = coalesce(async () => {
  try { fst.data = await api("/api/fleet" + fleetParams()); fst.err = null; } catch (e) { fst.err = e.message; }
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

// The table's headers: hub_core::fleet::who::Who::COLUMNS (checked by assets.rs).
const FLEET_COLS = { tier: ["tier", "n"], who: ["who"], state: ["state"], since: ["since", "n"], doing: ["doing now"], under: ["under it"], cost: ["$ 24h", "n"], project: ["project"] };
const STATE_CLASS = { failed: "bad", "needs you": "warn", stalled: "warn", idle: "muted", off: "muted", chat: "muted", parked: "muted", landed: "muted" };
// A runner opens its page, a session its record on the Sessions tab.
const whoHref = (r) => (r.opens === "runner" ? runnerHref(r.key) : "#sessions/" + encodeURIComponent(r.key));

function whoRow(r) {
  const shut = fst.fold.has(r.key);
  const fold = r.kids ? `<button class="thsort" data-fold="${esc(r.key)}" aria-expanded="${!shut}" title="${shut ? "unfold" : "fold"} the ${r.kids} rows under it">${shut ? "&gt;" : "v"}</button> ` : "";
  return `<tr class="wr" data-href="${esc(whoHref(r))}"><td class="n">${fold}${r.tier}</td><td><a href="${esc(whoHref(r))}">${esc(r.who)}</a></td>` +
    `<td class="${STATE_CLASS[r.state] || ""}">${esc(r.state)}</td><td class="n">${r.since ? ago(r.since) : "-"}</td>` +
    `<td class="wrap">${cut(r.doing)}</td><td class="wrap muted">${esc(r.under)}</td><td class="n">${usd(r.cost)}</td><td class="muted">${esc(r.project)}</td></tr>`;
}

function fleetBody(d) {
  const t = d.table;
  const more = d.hidden ? `<div class="muted more">+ ${d.hidden} folded under a tier 1 row</div>` : "";
  return d.who.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, FLEET_COLS)}${d.who.map(whoRow).join("")}</table>${more}</div>`
    : `<div class="panel">${t.total ? "No runner or session matches." : "No runner configured in ~/.config/agentctl/agents."}</div>`;
}

function fleetHead(d) {
  const errs = [...(fst.err ? [fst.err] : []), ...(d.errors || [])];
  return `<div class="bhead"><span>fleet <span class="muted">who is working, on what, and can I afford it; ${d.table.shown} of ${d.table.total} rows, ${usd(d.cost_24h)} in 24h across every agentctl run, read ${d.at ? clock(d.at * 1e3) : "-"}</span></span></div>` +
    (errs.length ? `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>` : "");
}

const fleetTail = (d) => `<h2 class="sec" id="sec-accounts">Claude accounts</h2><div class="panel scroll">${accountsTable(d)}</div>`;

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

// The runner whose page draws a judge's tiles is the one whose conf names that extras block
// (DETAIL=); no such conf, no link. Log's verdict headers link there.
const pageFor = (d, detail) => (d.workers || []).find((w) => w.detail === detail)?.name;
const pageLink = (name, label) => name ? `<a href="${runnerHref(name)}">${label}</a>` : label;

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
  if (!d || !d.table) { el.innerHTML = `<div class="empty">${fst.err ? esc(fst.err) : "Loading..."}</div>`; return; }
  // A refresh must not take the search box or an open dropdown from under the human, so
  // everything around the control in use repaints and it stays.
  const f = document.activeElement;
  if (f?.id === "fleet-q" || f?.dataset?.tq !== undefined) {
    paint($("fleet-head"), fleetHead(d));
    if (f.id === "fleet-q") paint($("fleet-facets"), tblFacets(d.table));
    paint($("fleet-chips"), tblChips(d.table));
    paint($("fleet-body"), fleetBody(d));
    paint($("fleet-tail"), fleetTail(d));
    return;
  }
  paint(el, `<div id="fleet-head">${fleetHead(d)}</div>${tblBar("fleet", d.table, "search, or tier:3 state:failed project:dotfiles -who:shepherd")}` +
    `<div id="fleet-body">${fleetBody(d)}</div><div id="fleet-tail">${fleetTail(d)}</div>`);
}

// The view changed: the URL follows it and the server applies it.
function fleetView(patch) {
  setQuery(tblSet(st.views.fleet, patch));
  refreshFleet();
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
  const t = e.target;
  const said = t.closest("[data-said]");
  if (said) { fst.said = said.dataset.said; renderFleet(); return; }
  const run = t.closest("tr.rr");
  if (run) { const j = rst.data && rst.data.runs[+run.dataset.i]; if (j) runnerLog(j); return; }
  const fold = t.closest("[data-fold]");
  if (fold) { const k = fold.dataset.fold; if (!fst.fold.delete(k)) fst.fold.add(k); refreshFleet(); return; }
  const v = tblPatch(e);
  if (v) { fleetView(v); return; }
  if (t.closest("a, button, select, input")) return;
  const row = t.closest("tr.wr");
  if (row) location.hash = row.dataset.href;
});
// A picked dropdown lets go of focus, so the answer redraws it with the new counts.
for (const ev of ["input", "change"]) $("fleet").addEventListener(ev, (e) => { const v = tblPatch(e); if (!v) return; if (e.type === "change" && e.target.dataset.tq !== undefined) e.target.blur?.(); fleetView(v); });

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
