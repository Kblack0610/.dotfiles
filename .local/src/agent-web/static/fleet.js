"use strict";
// The Fleet tab: who is working, on what, and why it is deployed. One table (the shared one,
// table.js) of every runner and live session, its KIND (lead, a lane, session) explained by the
// legend above it (lanes.tsv, read by hub-core); a row opens its record, and a lead row folds the
// rows under it. Who pays, where the tokens go and what Langfuse sees are Costs' (costs.js). The judges'
// verdict lists are Log's Judges' verdicts section. From /api/fleet (hub-core `fleet`, the same reader as the hub's
// Fleet tab). `#fleet/<runner>` is one runner's page, read from /api/fleet/runner only when it
// opens (hub-core `fleet::runner`).

// Newest verdict keys and ask questions are cut to this many characters; the full text is the hover.
const FLEET_CLIP = 70;
// fold: the lead rows the human closed, kept across refreshes; said: the answer judge's filter on Log.
// A read also answers Log's verdicts and the open runner page.
const fst = tblTab({
  tab: "fleet", id: "fleet", api: "/api/fleet", hint: "search, or kind:session state:failed project:dotfiles -who:shepherd",
  state: { fold: new Set(), said: "all" }, shown: () => st.tab === "fleet" && !st.arg,
  params: (p, t) => { if (t.fold.size) p.set("fold", [...t.fold].join(",")); },
  head: (t) => fleetHead(t.data), body: (t) => fleetBody(t.data),
  after: () => { if (st.tab === "log") renderLogVerdicts(); else if (st.tab === "fleet" && st.arg) renderFleet(); },
});

// The open runner page: whose, what it read, and the run whose log is shown.
const rst = { name: "", data: null, err: null, log: null, sel: "" };
const runnerHref = (name) => "#fleet/" + encodeURIComponent(name);

const refreshRunner = coalesce(async () => {
  const name = st.arg;
  if (!name) return;
  try { rst.data = await api("/api/fleet/runner?name=" + encodeURIComponent(name)); rst.err = null; } catch (e) { rst.data = null; rst.err = e.message; }
  if (st.tab === "fleet" && st.arg === name) renderFleet();
});

// The rows re-read on their own events (onEvent); the open tab also re-reads on Infra's cadence,
// so the ages and a runner page's status move with no event.
const pollFleet = poll("fleet", () => (st.arg ? refreshRunner() : fst.refresh()), INFRA_REFRESH_MS);

const cut = (s, n = FLEET_CLIP) => (s.length > n ? `<span title="${esc(s)}">${esc(s.slice(0, n - 2))}..</span>` : esc(s));

const okClass = (ok) => (ok === false ? "bad" : ok == null ? "warn" : "");

const kTok = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : `${n}`);
const base = (p) => p.split("/").pop();

// A judge's per-rule table, judge-eval's numbers under its current prompt. A rule not yet live
// shows how far its labels are from the bar.
function evalTable(e) {
  const pc = (x) => pct(x == null ? null : x / 100);
  const live = (r) => (r.live ? "yes" : r.bar ? `no (${r.bar.labels}/${r.bar.need} to bar)` : "no");
  const rows = e.rules.map((r) => `<tr><td>${esc(r.rule)}</td><td class="n">${r.verdicts}</td><td class="n">${r.scored}</td><td class="n">${pc(r.precision)}</td><td class="n">${pc(r.false_defer_pct)}</td><td>${live(r)}</td></tr>`).join("");
  return `<table class="tbl"><tr><th data-role="lead">rule</th><th class="n">calls</th><th class="n">scored</th><th class="n" data-role="glance" data-named>prec</th><th class="n" data-role="glance" data-named>false-defer</th><th data-role="glance" data-named>live</th></tr>${rows ||
    `<tr><td colspan="6" class="muted">no verdicts under prompt ${esc(e.prompt_sha)}</td></tr>`}</table>`;
}

// What the runner is allowed and runs on: its role, model, prompt, effect and trigger.
function registryLine(r) {
  const prompt = r.prompt ? `<span title="${esc(r.prompt)}">${esc(base(r.prompt))}</span> ${esc(r.calls.prompt_sha || (r.eval && r.eval.prompt_sha) || "")}` : "-";
  return `<div><b>${esc(r.role || "no role")}</b> <span class="muted" title="${esc(r.role_desc)}">${esc(r.caps || "")}</span>` +
    ` &nbsp; model ${esc(r.model || "-")} &nbsp; prompt ${prompt} &nbsp; effect ${esc(r.effect || "-")} &nbsp; trigger ${esc(r.trigger || "-")}</div>`;
}

// Calls newest first, each with its Langfuse trace.
const callsTable = (recent) => `<table class="tbl"><tr><th class="n" data-role="lead">when</th><th class="n">took</th><th>model</th><th class="n" data-role="glance">$</th><th class="n">tokens</th><th data-role="glance">ok</th><th data-role="glance">trace</th></tr>${recent.map((x) =>
  `<tr><td class="n">${when(x.at)}</td><td class="n">${secs(x.ms / 1000)}</td><td class="muted">${esc(x.model)}</td><td class="n">${usd(x.cost)}</td><td class="n">${kTok(x.tokens)}</td>` +
  `<td class="${x.ok ? "" : "bad"}">${x.ok ? "ok" : "error"}</td><td>${x.link ? `<a href="${esc(x.link)}" target="_blank" rel="noopener">Langfuse</a>` : `<span class="muted">${esc(x.id)}</span>`}</td></tr>`).join("")}</table>`;

// The table's headers: hub_core::fleet::who::Who::COLUMNS (checked by assets.rs).
const FLEET_COLS = { kind: ["kind"], who: ["who"], state: ["state"], cost: ["cost 24h", "n"], activity: ["activity"], since: ["since", "n"], for: ["for"], doing: ["doing now"], under: ["under it"], project: ["project"] };
const STATE_CLASS = { failed: "bad", held: "bad", "needs you": "warn", stalled: "warn", idle: "muted", off: "muted", chat: "muted", parked: "muted", landed: "muted" };
// A runner opens its page, a session its record on the Sessions tab.
// `l`: the row's links (tblLinks): its who and its project, each to its page.
function whoRow(r, l) {
  const shut = fst.fold.has(r.key);
  const fold = r.kids ? `<button class="thsort" data-fold="${esc(r.key)}" aria-expanded="${!shut}" title="${shut ? "unfold" : "fold"} the ${r.kids} rows under it">${shut ? "&gt;" : "v"}</button> ` : "";
  return `<tr class="wr" data-href="${esc(l.who || "")}"><td class="muted">${fold}${esc(r.kind)}</td><td>${tblLink(l.who, r.who)}</td>` +
    `<td class="${STATE_CLASS[r.state] || ""}">${esc(r.state)}</td><td class="n">${r.cost_24h == null ? "-" : `<a href="#costs">${r.cost_estimated ? "~" : ""}${usd(r.cost_24h)}</a>`}</td><td class="muted">${esc(r.activity)}</td><td class="n">${r.since ? ago(r.since) : "-"}</td>` +
    `<td class="wrap">${esc(r.for)}</td><td class="wrap">${cut(r.doing)}</td><td class="wrap muted">${esc(r.under)}</td><td class="muted">${r.project ? tblLink(l.project, r.project) : ""}</td></tr>`;
}

function fleetBody(d) {
  const t = d.table;
  const more = d.hidden ? `<div class="muted more">+ ${d.hidden} folded under a lead row</div>` : "";
  return d.who.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, FLEET_COLS)}${d.who.map((r, i) => whoRow(r, tblLinks(t, i))).join("")}</table>${more}</div>`
    : `<div class="panel">${t.total ? "No runner or session matches." : "No runner configured in ~/.config/agentctl/agents."}</div>`;
}

function fleetHead(d) {
  const errs = [...(fst.err ? [fst.err] : []), ...(d.errors || [])];
  return pfold("fleet-legend", "Legend", `<div class="muted legend">${esc((d.legend || []).join(" | ") || "-")}</div>`) +
    (errs.length ? `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>` : "");
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
  return `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n" data-role="glance">when</th><th>project</th><th data-role="lead">row</th><th data-role="glance">verdict</th><th class="n">tier</th><th>clear</th><th data-role="glance">reason</th></tr>${rows}</table>` : `<div class="empty">No verdicts yet.</div>`}</div>` + older(d.recent.length - LOG_ROWS);
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
    tile("PENDING", j.pending, "var(--b-stalled)", "judged, unanswered") +
    tile("UNSCORED", j.unscored, "var(--c3)", "free text, no option named");
  return `<div class="tiles">${tiles}</div>`;
}

// The answer judge per type and impact level, judge-eval's cells under its current prompt. A live
// cell's scored count is the answers you reviewed (audited); silence scores nothing.
// judge-eval's percent as it gives it, or "-" with none.
const share = (x) => (x == null ? "-" : `${x}%`);

function judgeCells(j) {
  const prec = (c) => c.precision == null ? "-" : `${c.precision}% <span class="muted">[${c.precision_lo}-${c.precision_hi}]</span>`;
  const rows = j.cells.map((c) => `<tr><td>${esc(c.type || "(no type)")}</td><td>${esc(c.level || "-")}</td><td class="n">${c.verdicts}</td><td class="n">${c.scored}</td>` +
    `<td class="n">${prec(c)}</td><td class="n">${c.pending}</td><td class="${c.live ? "" : "muted"}">${c.live ? "yes" : "no"}</td><td class="n">${c.audited}</td><td class="n">${share(c.level_raised_pct)}</td></tr>`).join("");
  return `<div class="muted">By type and level (self, repo, fleet, critical), under the current prompt</div>` +
    `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">type</th><th data-role="glance">level</th><th class="n">verdicts</th><th class="n">scored</th>` +
    `<th class="n" data-role="glance" data-named>precision [95%]</th><th class="n">pending</th><th data-role="glance" data-named>live</th><th class="n">audited</th><th class="n">raised</th></tr>${rows ||
    `<tr><td colspan="9" class="muted">no verdicts under prompt ${esc(j.prompt || "none")}</td></tr>`}</table></div>`;
}

// The answer judge's filters: hub_core::fleet::ASK_FILTERS, read as the row they keep.
const ASK_FILTERS = ["all", "answered", "would answer", "passed", "wrong"];
const askShown = (v, f) => f === "all" || (f === "wrong" ? v.score === "wrong" : v.said === f);

function judgeList(j) {
  const shown = j.verdicts.filter((v) => askShown(v, fst.said));
  const seg = `<div class="seg fseg">` + ASK_FILTERS.map((f) =>
    chipBtn(f === fst.said, "data-said", f, f, j.verdicts.filter((v) => askShown(v, f)).length)).join("") + `</div>`;
  const why = (x) => `${x.rule && x.rule !== x.type ? `<b>${esc(x.rule)}</b> ` : ""}${x.evidence ? `"${esc(x.evidence)}" ` : ""}${esc(x.reason)}`;
  const rows = shown.slice(0, LOG_ROWS).map((x) => `<tr><td class="n">${when(x.at)}</td><td>${esc(x.project)}</td><td>${esc(x.type || x.rule || "-")}</td>` +
    `<td>${esc(x.said)}${x.judge ? ` <span class="muted">${cut(x.judge, 20)}</span>` : ""}</td><td class="wrap">${cut(x.question)}</td><td class="wrap muted">${why(x)}</td>` +
    `<td>${x.score === "wrong" ? `<span class="cchip bad">${cut(x.you, 30)}</span>` : cut(x.you, 30)}</td></tr>`).join("");
  return `<div class="muted">7d: ${share(j.week.live_pct)} answered, ${share(j.week.coverage)} would answer, ${share(j.week.precision)} right</div>${seg}` +
    `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n">when</th><th>project</th><th>type</th><th data-role="glance">said</th><th data-role="lead">question</th><th data-role="glance">why</th><th data-role="glance" data-named>you</th></tr>${rows}</table>` : `<div class="empty">No verdicts here.</div>`}</div>`;
}

function renderFleet() {
  if (st.arg) renderRunner($("fleet")); else fst.render();
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
      return secHead("", "Dispatch judge") +
        dispatchTiles(x.dispatch) + dispatchList(x.dispatch);
    case "ask-judge":
      return secHead("", "Answer judge") +
        judgeTiles(x.judge) + judgeCells(x.judge) + judgeList(x.judge);
    case "ingest": {
      const kinds = Object.keys(x.counts_7d).sort();
      const tiles = kinds.map((k) => tile(k.toUpperCase(), x.counts_7d[k], "var(--c1)", `in 7d${x.partial ? "+" : ""}`)).join("");
      const rows = x.steps.map((t) => `<tr><td class="n">${when(t.ts)}</td><td>${esc(t.action)}${t.id ? ` <span class="muted">${esc(t.id)}</span>` : ""}</td><td class="muted">${esc(t.from)}${t.to && t.to !== t.from ? ` -&gt; ${esc(t.to)}` : ""}</td><td class="muted">${esc(t.by || "-")}</td><td class="wrap">${cut(t.text)}${t.row && t.row !== t.text ? `<div class="muted">=&gt; ${cut(t.row)}</div>` : ""}</td><td class="wrap muted">${cut(t.why || "")}</td></tr>`).join("");
      return secHead("", "Intake") +
        (tiles ? `<div class="tiles">${tiles}</div>` : "") +
        `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n" data-role="glance">when</th><th data-role="glance">action</th><th data-role="glance">from -&gt; to</th><th>by</th><th data-role="lead">line</th><th>why</th></tr>${rows}</table>` : `<div class="empty">No intake step in 7 days.</div>`}</div>`;
    }
    case "sentinel-watches": {
      // Every watch, its state and owner are on Alerts; Fleet keeps the count, and a tripped one
      // is a warn line that sends you there.
      const trip = x.watches.filter((w) => w.state === "TRIP").length;
      return secHead("", "Watches", x.watches.length, trip ? "warn" : "") +
        (trip ? `<div class="cline warn"><a href="#alerts/watches">${trip} tripped</a></div>` : "");
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
  let h = `<div class="bhead"><span>${esc(r.name)} <span class="muted">${esc(r.lane || "no lane")}</span></span>${back}</div>`;
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

  h += secHead("", "Runs", r.runs_total, r.failed_total ? "warn" : "");
  if (r.days.some((x) => x.runs)) {
    h += `<div class="panel scroll"><table class="tbl"><tr><th></th>${r.days.map((x) => `<th class="n">${esc(x.day)}</th>`).join("")}</tr>` +
      `<tr><td>runs</td>${r.days.map((x) => `<td class="n">${x.runs || "-"}</td>`).join("")}</tr>` +
      `<tr><td>failed</td>${r.days.map((x) => `<td class="n${x.failed ? " bad" : ""}">${x.failed || "-"}</td>`).join("")}</tr></table></div>`;
  }
  if (!r.runs.length) {
    h += `<div class="empty">no run in 14 days${g.kind === "call" ? ` <span class="muted">(${esc(g.trigger)}; its calls are below)</span>` : ""}</div>`;
  } else {
    const rows = r.runs.map((j, i) => `<tr class="jr rr${jobKey(j) === rst.sel ? " sel" : ""}${j.log ? " haslog" : ""}" data-i="${i}"><td class="n">${when(j.started)}</td><td class="n">${secs(j.secs)}</td>${resultCell(j)}<td class="muted">${esc(j.detail || "")}</td></tr>`).join("");
    h += `<div class="panel scroll"><table class="tbl"><tr><th class="n" data-role="lead">started</th><th class="n" data-role="glance" data-named>took</th><th data-role="glance">result</th><th data-role="glance">detail</th></tr>${rows}</table></div>` + older(r.runs_older);
  }
  if (rst.log) h += `<h3 class="sub">Log <span class="muted">${esc(rst.log.title)}</span></h3><pre class="panel joblog">${esc(rst.log.text)}</pre>`;

  const status = Object.entries(r.status).map(([k, v]) => `<tr><td>${esc(k)}</td><td class="wrap">${RUNNER_TIME_KEYS.includes(k) && /^\d+$/.test(v) ? when(+v) : esc(v)}</td></tr>`).join("");
  const act = r.activity.map((a) => `<tr><td class="n">${when(a.at)}</td><td class="${okClass(a.ok)}">${esc(a.word)}</td><td class="wrap muted">${esc(a.text || "")}</td></tr>`).join("");
  h += secHead("", "Status and activity") +
    `<div class="panel scroll">${status ? `<table class="tbl">${status}</table>` : `<div class="empty">No status file.</div>`}</div>` +
    (act ? `<div class="panel scroll"><table class="tbl"><tr><th class="n" data-role="glance">when</th><th data-role="glance">outcome</th><th data-role="lead">text</th></tr>${act}</table></div>` : "");

  const plus = r.calls.partial ? "+" : "";
  const trow = (l, t, p = "") => `<tr><td>${l}</td><td class="n">${t.calls}${p}</td><td class="n${t.errors ? " bad" : ""}">${t.errors}${p}</td><td class="n">${kTok(t.tokens)}${p}</td><td class="n">${usd(t.cost)}${t.cost == null ? "" : p}</td><td class="n">${secs(t.p50_ms && t.p50_ms / 1000)}</td></tr>`;
  h += secHead("", "Calls", null, day.errors ? "warn" : "") + (plus ? `<div class="cline warn">7d is a floor: the week starts past the tail read</div>` : "") +
    `<div class="panel scroll"><table class="tbl"><tr><th></th><th class="n">calls</th><th class="n">errors</th><th class="n">tokens</th><th class="n">$</th><th class="n">p50</th></tr>${trow("24h", day)}${trow("7d", week, plus)}</table>` +
    (r.calls.recent.length ? callsTable(r.calls.recent) : "") + `</div>`;

  h += secHead("", "Registry") + `<div class="panel">${registryLine(g)}${g.eval ? evalTable(g.eval) : ""}</div>`;
  h += runnerExtras(r.extras);
  const conf = r.conf.map((c) => `<tr><td>${esc(c.key)}</td><td class="wrap muted">${esc(c.value)}</td></tr>`).join("");
  h += secHead("", "Conf") + `<div class="panel scroll">${conf ? `<table class="tbl">${conf}</table>` : `<div class="empty">Empty.</div>`}</div>`;
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
  if (fold) { const k = fold.dataset.fold; if (!fst.fold.delete(k)) fst.fold.add(k); fst.refresh(); return; }
  if (t.closest("a, button, select, input")) return;
  const row = t.closest("tr.wr");
  if (row) location.hash = row.dataset.href;
});

const logFleetFeed = pushed("log", ["fleet", "asks", "sessions"], fst.refresh);
LOG_PARTS.push({ show() { renderLogVerdicts(); logFleetFeed.show(!fst.data); }, onEvent: logFleetFeed.onEvent });
TABS.fleet = {
  show() {
    if (rst.name !== st.arg) Object.assign(rst, { name: st.arg, data: null, err: null, log: null, sel: "" });
    renderFleet();
    pollFleet();
  },
  onEvent(ev) {
    if (st.tab === "fleet" && (ev.kind === "fleet" || ev.kind === "asks" || ev.kind === "sessions" || ev.kind === "resync")) (st.arg ? refreshRunner() : fst.refresh());
    // The ingest record pushes as the outbox's kind; only a runner page with the ingest table reads it.
    else if (st.tab === "fleet" && ev.kind === "outbox" && rst.data?.extras?.kind === "ingest") refreshRunner();
  },
};
