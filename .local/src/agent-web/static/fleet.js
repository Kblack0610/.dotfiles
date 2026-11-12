"use strict";
// Sessions' Runners inner tab: every agentctl runner, what it is doing and why it is deployed. One
// table (the shared one, table.js), its KIND (lead or a lane) explained by the legend above it
// (lanes.tsv, read by hub-core); a row opens its runner's page, and a lead's UNDER counts the live
// sessions it oversees, which are the Sessions inner tab's rows. Who pays, where the tokens go and
// what Langfuse sees are Costs' (costs.js). The judges' verdict lists are Log's Judges' verdicts
// section. From /api/fleet (hub-core `fleet`, the same reader as the hub's Runners).
// `#sessions/runners/<runner>` is one runner's page, read from /api/fleet/runner only when it opens
// (hub-core `fleet::runner`); app.js routes the retired `#fleet/<runner>` there.

// Newest verdict keys and ask questions are cut to this many characters; the full text is the hover.
const FLEET_CLIP = 70;
// The Runners table's view keys in `#sessions?...`, beside the Sessions table's plain ones.
const RUNNERS_PRE = "r";
// The runner page open, "" on the table.
const runnerName = () => pageId("sessions", "runners");
const runnersShown = () => !st.sel && sessShows("runners");
// A read also answers the open runner page.
const fst = tblTab({
  tab: "sessions", id: "runners", el: "ov-runners", on: "scroll", pre: RUNNERS_PRE, api: "/api/fleet", hint: "search, or kind:lead state:failed -who:shepherd",
  shown: () => runnersShown() && !runnerName(),
  head: (t) => fleetHead(t.data), body: (t) => fleetBody(t.data),
  after: () => { if (runnerName()) renderRunners(); },
});

// The answer judge's verdicts are a table of their own (`v` keys, hub_core::fleet::AskVerdict),
// filtered on the server so the tiles count every verdict, not only the rows it sends: Log's
// Judges section (vst) and the ask-judge runner page, which keeps them in the Sessions URL.
const VERDICTS_PRE = "v";

// The open runner page: whose, what it read, and the run whose log is shown.
const rst = { name: "", data: null, err: null, log: null, sel: "" };

const refreshRunner = coalesce(async () => {
  const name = runnerName();
  if (!name) return;
  const v = tblParams(st.views.sessions, VERDICTS_PRE).toString();
  try { rst.data = await api("/api/fleet/runner?name=" + encodeURIComponent(name) + (v ? "&" + v : "")); rst.err = null; } catch (e) { rst.data = null; rst.err = e.message; }
  if (runnerName() === name) renderRunners();
});

// The rows re-read on their own events (runnersEvent); while Runners shows, they also re-read on
// Infra's cadence, so the ages and a runner page's status move with no event. The timer lives
// only while Runners shows (ui.js poll), so another inner tab has no tick to mark it behind.
const pollFleet = poll("sessions", () => (runnerName() ? refreshRunner() : fst.refresh()), INFRA_REFRESH_MS, runnersShown);

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
const FLEET_COLS = { kind: ["kind"], who: ["who"], state: ["state"], cost: ["cost 24h", "n"], since: ["since", "n"], for: ["for"], doing: ["doing now"], under: ["under it"] };
const STATE_CLASS = { failed: "bad", held: "bad", stalled: "warn", idle: "muted", off: "muted" };
// A runner opens its page, one line a row (clamp1). `l`: the row's links (tblLinks), its who to that page.
function whoRow(r, l) {
  return `<tr class="wr" data-href="${esc(l.who || "")}"><td class="muted">${esc(r.kind)}</td><td>${tblLink(l.who, r.who)}</td>` +
    `<td class="${STATE_CLASS[r.state] || ""}">${esc(r.state)}</td><td class="n">${r.cost_24h == null ? "-" : `<a href="#costs">${r.cost_estimated ? "~" : ""}${usd(r.cost_24h)}</a>`}</td><td class="n">${r.since ? ago(r.since) : "-"}</td>` +
    `<td>${clamp1(esc(r.for), r.for)}</td><td>${clamp1(esc(r.doing), r.doing)}</td><td class="muted">${clamp1(esc(r.under), r.under)}</td></tr>`;
}

function fleetBody(d) {
  const t = d.table;
  return d.who.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, FLEET_COLS)}${d.who.map((r, i) => whoRow(r, tblLinks(t, i))).join("")}</table></div>`
    : `<div class="panel">${t.total ? "No runner matches." : "No runner configured in ~/.config/agentctl/agents."}</div>`;
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

// A verdict list's first `cap` rows, or all of them when cap is null ("+N older" was asked for).
const firstRows = (list, cap) => (cap == null ? list : list.slice(0, cap));

function dispatchList(d, cap) {
  const shown = firstRows(d.recent, cap);
  const rows = shown.map((v) => `<tr><td class="n">${when(v.ts)}</td><td>${esc(v.project)}</td><td>${cut(v.key)}</td>` +
    `<td><span class="chip sm" style="--c:${verdictColor(v.verdict)}">${esc(v.verdict)}</span></td><td class="n">${v.tier ?? "-"}</td>` +
    `<td>${v.clear == null ? "-" : v.clear ? "yes" : "no"}</td><td class="wrap muted">${clamp2(esc(v.reason), v.reason)}</td></tr>`).join("");
  return `<div class="panel scroll" data-list="dispatch">${rows ? `<table class="tbl"><tr><th class="n" data-role="glance">when</th><th>project</th><th data-role="lead">row</th><th data-role="glance">verdict</th><th class="n">tier</th><th>clear</th><th data-role="glance">reason</th></tr>${rows}</table>` : `<div class="empty">No verdicts yet.</div>`}${tblMore(d.recent.length - shown.length)}</div>`;
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

const judgeWeek = (j) => `<div class="muted">7d: ${share(j.week.live_pct)} answered, ${share(j.week.coverage)} would answer, ${share(j.week.precision)} right</div>`;

const VERDICT_COLS = { when: ["when", "n"], project: ["project"], type: ["type"], said: ["said"], question: ["question"], why: ["why"], you: ["you", "", true] };

// The verdicts the server kept (Judge::view), newest first, then what its cap left out: `more`
// draws that count, Log's a button that reads them all, the runner page's a line.
function judgeRows(j, more = older) {
  const t = j.table;
  // Why, built once as its parts (the rule, the quoted evidence, the reason): the title is their
  // text, the cell the same parts escaped, the rule in bold.
  const whyCell = (x) => {
    const parts = [x.rule && x.rule !== x.type ? x.rule : "", x.evidence ? `"${x.evidence}"` : "", x.reason || ""];
    const html = parts.map((p, i) => (i === 0 && p ? `<b>${esc(p)}</b>` : esc(p)));
    return clamp2(html.filter((_, i) => parts[i]).join(" "), parts.filter(Boolean).join(" "));
  };
  const rows = j.verdicts.map((x) => `<tr><td class="n">${when(x.at)}</td><td>${esc(x.project)}</td><td>${esc(x.type || x.rule || "-")}</td>` +
    `<td>${esc(x.said)}${x.judge ? ` <span class="muted">${cut(x.judge, 20)}</span>` : ""}</td><td class="wrap">${clamp2(esc(x.question), x.question)}</td><td class="wrap muted">${whyCell(x)}</td>` +
    `<td>${x.score === "wrong" ? `<span class="cchip bad">${cut(x.you, 30)}</span>` : cut(x.you, 30)}</td></tr>`).join("");
  return `<div class="panel scroll">${rows ? `<table class="tbl">${tblHead(t, VERDICT_COLS)}${rows}</table>` : `<div class="empty">${t.total ? "No verdict matches." : "No verdicts yet."}</div>`}</div>` +
    more(t.shown - j.verdicts.length);
}

function renderRunners() {
  const el = $("ov-runners");
  if (!el || !runnersShown()) return;
  if (runnerName()) renderRunner(el); else fst.render();
}

// One run's log on the runner page, through Infra's reader and the run's byte range.
async function runnerLog(j) {
  rst.sel = jobKey(j);
  const log = rst.log = { title: `${j.name} ${when(j.started)}`, text: "Loading..." };
  renderRunners();
  log.text = await jobLogText(j);
  if (rst.log === log) renderRunners();
}

const RUNNER_TIME_KEYS = ["updated", "next"];

// A lane's extras block, picked by the runner conf's DETAIL= key (hub_core::fleet::runner::DETAILS).
function runnerExtras(x) {
  switch (x.kind) {
    case "dispatch-verdicts":
      return secHead("", "Dispatch judge") + dispatchTiles(x.dispatch) + dispatchList(x.dispatch);
    case "ask-judge":
      return secHead("", "Answer judge") + judgeTiles(x.judge) + judgeCells(x.judge) + judgeWeek(x.judge) +
        `<div data-tbl="${VERDICTS_PRE}">${tblTiles(x.judge.table)}${judgeRows(x.judge)}</div>`;
    case "ingest": {
      const kinds = Object.keys(x.counts_7d).sort();
      const tiles = kinds.map((k) => tile(k.toUpperCase(), x.counts_7d[k], "var(--c1)", `in 7d${x.partial ? "+" : ""}`)).join("");
      const rows = x.steps.map((t) => `<tr><td class="n">${when(t.ts)}</td><td>${esc(t.action)}${t.id ? ` <span class="muted">${esc(t.id)}</span>` : ""}</td><td class="muted">${esc(t.from)}${t.to && t.to !== t.from ? ` -&gt; ${esc(t.to)}` : ""}</td><td class="muted">${esc(t.by || "-")}</td><td class="wrap">${cut(t.text)}${t.row && t.row !== t.text ? `<div class="muted">=&gt; ${cut(t.row)}</div>` : ""}</td><td class="wrap muted">${cut(t.why || "")}</td></tr>`).join("");
      return secHead("", "Intake") +
        (tiles ? `<div class="tiles">${tiles}</div>` : "") +
        `<div class="panel scroll">${rows ? `<table class="tbl"><tr><th class="n" data-role="glance">when</th><th data-role="glance">action</th><th data-role="glance">from -&gt; to</th><th>by</th><th data-role="lead">line</th><th>why</th></tr>${rows}</table>` : `<div class="empty">No intake step in 7 days.</div>`}</div>`;
    }
    case "sentinel-watches": {
      // Every watch, its state and owner are on Alerts; Runners keeps the count, and a tripped one
      // is a warn line that sends you there.
      const trip = x.watches.filter((w) => w.state === "TRIP").length;
      return secHead("", "Watches", x.watches.length, trip ? "warn" : "") +
        (trip ? `<div class="cline warn"><a href="#alerts/watches">${trip} tripped</a></div>` : "");
    }
    default:
      return "";
  }
}

// `#sessions/runners/<runner>`: summary first, then its runs with their logs, status and activity, calls,
// what the registry says, the lane's extras, and the conf.
function renderRunner(el) {
  const back = `<a class="btn sm" href="#sessions/runners${st.views.sessions ? "?" + st.views.sessions : ""}">All runners</a>`;
  const r = rst.data;
  if (!r) { paint(el, `<div class="bhead"><span>${esc(runnerName())}</span>${back}</div><div class="${rst.err ? "panel down" : "empty"}">${rst.err ? esc(rst.err) : "Loading..."}</div>`); return; }
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

// Log's Judges' verdicts section: the dispatch judge's newest verdicts, then everything the answer
// judge said, with why and what you did, under its tiles and search. Each list stops at the
// server's verdicts_shown: the answer judge's "+N older" reads the rest (vall), the dispatch
// list's shows what it holds (dispatchAll).
const vst = tblTab({
  tab: "log", id: "verd", el: "log-verdicts", pre: VERDICTS_PRE, api: "/api/fleet", wait: "Loading.", pages: true,
  params: (p, t) => { if (t.all) p.set("vall", "1"); }, state: { dispatchAll: false },
  shown: () => logShows("verdicts"), hint: "search a question, project, rule or answer",
  table: (t) => t.data?.judge?.table,
  head: (t) => verdictsHead(t.data), body: (t) => judgeRows(t.data.judge, tblMore),
  wrap: (h) => `<div data-tbl="${VERDICTS_PRE}">${h}</div>`,
});

// The dispatch list's "+N older" sits above the verdicts' block, so tblTab leaves it here.
$("log-verdicts").addEventListener("click", (e) => {
  if (!e.target.dataset?.all || !e.target.closest?.('[data-list="dispatch"]')) return;
  vst.dispatchAll = true;
  vst.render();
});

function verdictsHead(d) {
  return `<h3 class="sub">${pageLink(pageFor(d, "dispatch-verdicts"), "Dispatch judge")} <span class="muted">newest ${d.dispatch.recent.length}</span></h3>${dispatchList(d.dispatch, vst.dispatchAll ? null : d.verdicts_shown)}` +
    `<h3 class="sub">${pageLink(pageFor(d, "ask-judge"), "Answer judge")} <span class="n">${tblCount(d.judge.table)}</span></h3>${judgeWeek(d.judge)}`;
}

$("scroll").addEventListener("click", (e) => {
  const t = e.target;
  if (st.sel || !t.closest("#ov-runners")) return;
  // The runner page's verdict tiles and headers: the Sessions URL keeps their view, the page re-reads.
  if (tblOf(e) === VERDICTS_PRE) {
    const v = tblPatch(e);
    if (v) { setQuery(tblSet(st.views.sessions, v, VERDICTS_PRE)); refreshRunner(); }
    return;
  }
  const run = t.closest("tr.rr");
  if (run) { const j = rst.data && rst.data.runs[+run.dataset.i]; if (j) runnerLog(j); return; }
  if (t.closest("a, button, select, input")) return;
  const row = t.closest("tr.wr");
  if (row) location.hash = row.dataset.href;
});

const logFleetFeed = pushed("log", ["fleet", "asks", "sessions"], vst.refresh, () => logShows("verdicts"));
LOG_PARTS.push({ sec: "verdicts", show() { vst.render(); logFleetFeed.show(!vst.data || vst.moved()); }, onEvent: logFleetFeed.onEvent });
// TABS.sessions (sessions.js) calls these for the Runners inner tab.
function runnersShow() {
  const name = runnerName();
  if (rst.name !== name) Object.assign(rst, { name, data: null, err: null, log: null, sel: "" });
  renderRunners();
  pollFleet();
}
function runnersEvent(ev) {
  if (!runnersShown()) return;
  if (["fleet", "asks", "sessions", "resync"].includes(ev.kind)) (runnerName() ? refreshRunner() : fst.refresh());
  // The ingest record pushes as the outbox's kind; only a runner page with the ingest table reads it.
  else if (ev.kind === "outbox" && rst.data?.extras?.kind === "ingest") refreshRunner();
}
