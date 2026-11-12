"use strict";
// The Infra tab, as the hub's Infra tab, by inner tab: Machines (every machine with its governor
// verdict and cloud power, then the pools; one machine's page is `#infra/machines/<host>`), CI (slots, queued, failed and finished runs) and Jobs
// (jobs.js); what is red and the health chips are on Alerts (alerts.js). /api/infra asks
// Prometheus the board's own queries; statuses are the cc:* rules, so nothing is judged here.

// Prometheus has no push to a browser, so the open tab re-reads on the board's cadence
// (REFRESH_SECS=60): the rules evaluate every minute, and faster only redraws the same numbers.
const INFRA_REFRESH_MS = 60e3;
// A day's failures start folded per group past this many rows, as the Log tab folds a busy day.
const FAILED_OPEN = 25;
// Each failed group's folded state, which outlives the re-render on every refresh.
const ist = { data: null, err: null, open: {} };

const refreshInfra = coalesce(async () => {
  const view = new URLSearchParams(Object.values(INFRA_TABLES).flatMap((pre) => [...tblParams(st.views.infra, pre)])).toString();
  try { ist.data = await api("/api/infra" + (view ? "?" + view : "")); ist.err = null; } catch (e) { ist.err = e.message; }
  // An open machine or pool page re-reads with the board, so its numbers move and a failed read
  // retries.
  if (machineHost()) refreshMachine();
  if (poolName()) refreshPool();
  if (st.tab === "infra") renderInfra();
});

// Status as the cc:* rules give it: 0 ok, 1 warn, 2 red, anything else no data. The colour
// always comes with its word.
const STATUS = [["OK", "var(--b-done)"], ["WARN", "var(--b-stalled)"], ["RED", "var(--b-needs)"]];
const statusOf = (v) => STATUS[v] || ["NO DATA", "var(--c-other)"];

// cc: "cc:pool_busy" -> {unity: 4, ...} by the series' key label (pool, host, site, or
// domain/component), or the bare value with no label.
function ccIndex(series) {
  const by = {};
  for (const s of series || []) {
    const l = s.labels, key = l.domain && l.__name__ === "cc:domain_status" ? l.domain : l.pool || l.host || l.site || l.component && `${l.domain}/${l.component}`;
    (by[l.__name__] ||= {});
    if (key) by[l.__name__][key] = s.value; else by[l.__name__][""] = s.value;
  }
  return by;
}

const grafanaBase = () => (ist.data && ist.data.grafana) || "";
const gLink = (uid, text) => grafanaBase() ? `<a class="glink" href="${esc(grafanaBase())}/d/${uid}" target="_blank" rel="noopener">${esc(text)}</a>` : "";


function kpis(cc) {
  const one = (n) => (cc[n] || {})[""];
  const nodes = [one("cc:k3s_nodes_ready"), one("cc:k3s_nodes_total")];
  const beats = [one("cc:machines_up"), one("cc:machines_total")];
  const busy = sumOf(cc["cc:pool_busy"]) + sumOf(cc["cc:host_local_busy"]), slots = sumOf(cc["cc:pool_slots"]) + sumOf(cc["cc:host_local_open_slots"]);
  const waiting = sumOf(cc["cc:pool_waiting"]) + sumOf(cc["cc:host_local_queued"]);
  // cc:site_* already fold the local gates into local. No site series at all is "?", while a
  // site with none of its own reads 0 (no cloud host up).
  const site = (n, s) => (cc[n] || {})[s] ?? (cc["cc:site_slots"] ? 0 : "?");
  const hosted = one("cc:github_hosted_running");
  const where = `local ${site("cc:site_busy", "local")}/${site("cc:site_slots", "local")}, cloud ${site("cc:site_busy", "cloud")}/${site("cc:site_slots", "cloud")}${hosted > 0 ? ` +${hosted} github-hosted` : ""}`;
  const ok = (a, b) => (a != null && a === b ? "var(--b-done)" : "var(--b-needs)");
  return `<div class="tiles roomy">${
    tile("NODES", `${nodes[0] ?? "?"}/${nodes[1] ?? "?"}`, ok(nodes[0], nodes[1]))}${
    tile("HEARTBEATS", `${beats[0] ?? "?"}/${beats[1] ?? "?"}`, ok(beats[0], beats[1]))}${
    tile("CI BUSY", `${busy}/${slots}`, "var(--c1)", `${where}, ${waiting} waiting`)}${
    tile("RUNNERS", `${one("cc:runners_failed") ?? "?"} failed`, one("cc:runners_failed") ? "var(--b-needs)" : "var(--b-done)", `of ${one("cc:runners_total") ?? "?"}`)}${
    tile("WATCHES", `${one("cc:watches_tripped") ?? "?"} tripped`, one("cc:watches_tripped") ? "var(--b-stalled)" : "var(--b-done)", `of ${one("cc:watches_total") ?? "?"}, ${one("cc:watches_stale") ?? 0} stale`, "#alerts/watches")}${
    tile("SPEND", "on Costs", "var(--c2)", "the LAZER pool, Claude 24h and every cut", "#costs")}${
    tile("SESSIONS", `${one("cc:sessions_working") ?? "?"}/${one("cc:sessions_total") ?? "?"}`, "var(--b-working)", `working, ${one("cc:sessions_attention") ?? 0} need you`)}</div>`;
}

// The tab's tables, each with its view keys' prefix in the URL; agent-web infra.rs TABLES names the
// same. The rows, their order, chips, facets and links are hub_core's (machines.rs, ci.rs), which the
// TUI draws too; this file only draws the cells.
const INFRA_TABLES = { machines: "m", pools: "p", runners: "r", queued: "w", finished: "f" };
// Finished runs past this many rows wait behind a "+N more" button.
const FINISHED_ROWS = 25;

// One bar per core, in core order, from cc:host_core_busy_ratio; amber past 90% as the cpu meter.
function coreStrip(cores) {
  const busyColor = (v) => (v > 0.9 ? "var(--b-stalled)" : "var(--c1)");
  return `<span class="cores">${cores.map((v, i) => `<i title="cpu ${i}: ${pct(v)}"><b style="height:${(Math.max(0, Math.min(1, v || 0)) * 100).toFixed(0)}%;background:${busyColor(v)}"></b></i>`).join("")}</span>`;
}

// Free share of a machine's fullest disk (the NodeDisk* alerts' rule, home-config): amber under
// the governor's 20% hold and NodeDiskLow, red under NodeDiskCritical's 10%. A cloud machine with
// no reading is amber, needs attention: the AWS hosts are never scraped, so nothing alerts on
// their disks.
function diskCell(m) {
  const free = m.disk;
  if (free == null) return `<td class="n${m.where === "cloud" ? " warn" : " muted"}" title="no disk metrics for this name: nothing alerts on its disk">no reading</td>`;
  return `<td class="n${free < 0.1 ? " bad" : free < 0.2 ? " warn" : ""}">${pct(free)}</td>`;
}

const busyCell = (m) => (m.busy || m.slots ? `${m.busy}/${m.slots}` : "-");
const cpuTitle = (m) => m.runner_cores.map(([n, v]) => `${n}: ${v.toFixed(1)} cores`).join("\n");
const ciRef = (x) => (x.pr ? `${x.repo}#${x.pr}` : x.branch || x.repo || "");
const passCls = (p) => (p == null ? "" : p < 0.7 ? "bad" : p < 0.9 ? "warn" : "");
const td = (cls, html) => `<td${cls ? ` class="${cls}"` : ""}>${html}</td>`;

// The governor (home-config apps/ci-runner-governor) per host: whether it acts for real, this
// cycle's action, and its verdict on a hover.
const ACTION_COLOR = { withhold: "var(--b-stalled)", stop: "var(--b-stalled)", admit: "var(--b-working)", start: "var(--b-working)" };
function governorCell(g) {
  if (!g) return td("muted", "-");
  const mode = g.live ? "live" : '<span class="muted">dry run</span>';
  const act = g.action ? ` <span class="chip sm" style="--c:${ACTION_COLOR[g.action] || "var(--c-other)"}">${esc(g.action.toUpperCase())}</span>` : "";
  return `<td title="${esc(`verdict: ${g.verdict || "-"}; admits ${g.admitted ?? "-"}`)}">${mode}${act}</td>`;
}

// A cloud host's power, which the governor starts for a deep queue: its state, today's hours
// against the cap and where its rule stands. Its buttons are on the machine's page.
const POWER_COLOR = { running: "var(--b-working)", starting: "var(--b-working)", draining: "var(--b-stalled)", stopping: "var(--b-stalled)" };
const powerChip = (state) => `<span class="chip sm" style="--c:${POWER_COLOR[state] || "var(--c-other)"}">${esc((state || "?").toUpperCase())}</span>`;

function powerCell(m) {
  const p = m.power;
  if (!p) return td("muted", "-");
  const last = p.changed_at ? `last ${p.changed} ${when(p.changed_at)}${p.reason ? ` (${p.reason})` : ""}` : p.reason;
  const cost = p.usd_per_hour != null ? ` ~${usd(p.hours * p.usd_per_hour)}` : "";
  return `<td class="wrap" title="${esc(last || "")}">${powerChip(p.state)} ${p.hours.toFixed(1)}/${p.max ?? "?"} h${cost} <span class="muted">${esc(p.rule)}</span></td>`;
}

// Each table's cells by column, in the order the summary's columns come (hub_core Row::COLUMNS);
// `l` is the row's links (tblLinks). A label's second field is its header's class.
const MACH_COLS = { machine: ["machine"], where: ["where"], state: ["state"], busy: ["busy", "n"], cpu: ["cpu now"], "6h": ["6h", "n"], load: ["load", "n"],
  mem: ["mem"], temp: ["temp", "n"], disk: ["disk free", "n"], pools: ["pools"], running: ["running"], governor: ["governor"], power: ["power"], up: ["up since", "n"] };
const MACH_CELLS = {
  machine: (m, l) => td("", tblLink(l.machine, m.host)),
  where: (m) => td("muted", esc(m.where)),
  state: (m) => td(m.state === "up" ? "" : m.state === "no reading" ? "muted" : "warn", esc(m.state)),
  busy: (m) => `<td class="n${m.off ? " warn" : ""}"${m.runner_cores.length ? ` title="${esc(cpuTitle(m))}"` : ""}>${busyCell(m)}${m.off ? ` +${m.off} off` : ""}</td>`,
  cpu: (m) => td("m", `${m.core_busy.length ? coreStrip(m.core_busy) : meter(m.cpu, m.cpu > 0.9 ? "var(--b-stalled)" : "var(--c1)")} ${pct(m.cpu)}`),
  "6h": (m) => td("n", pct(m.cpu6h)),
  load: (m) => td(`n${m.load > m.cores * 1.5 ? " warn" : ""}`, m.load == null ? "-" : `${m.load.toFixed(1)}/${m.cores ?? "?"}`),
  mem: (m) => td("m", `${meter(m.mem, m.mem > 0.9 ? "var(--b-stalled)" : "var(--c3)")} ${pct(m.mem)}`),
  temp: (m) => td(`n${m.temp > 85 ? " warn" : ""}`, m.temp == null ? "-" : Math.round(m.temp) + "C"),
  disk: diskCell,
  pools: (m) => td("muted wrap", esc(m.pools.join("  ")) || "-"),
  running: (m) => td("wrap", esc(m.running.join(", ")) || "-"),
  governor: (m) => governorCell(m.governor),
  power: powerCell,
  up: (m) => td("n muted", m.boot ? when(m.boot) : "-"),
};

const POOL_COLS = { pool: ["pool"], slots: ["slots", "n"], busy: ["busy", "n"], withheld: ["withheld", "n"], waiting: ["waiting", "n"], oldest: ["oldest", "n"],
  done: ["done 24h", "n"], pass: ["pass", "n"], machines: ["machines"] };
const num = (v) => v ?? "-";
const POOL_CELLS = {
  pool: (p, l) => td("", tblLink(l.pool, p.pool)),
  slots: (p) => td("n", num(p.slots)),
  busy: (p) => td("n", num(p.busy)),
  withheld: (p) => td(`n${p.withheld ? " warn" : ""}`, num(p.withheld)),
  waiting: (p) => td(`n${p.waiting ? " warn" : ""}`, num(p.waiting)),
  oldest: (p) => td("n", secs(p.oldest)),
  done: (p) => td("n", num(p.done)),
  pass: (p) => td(`n ${passCls(p.pass)}`, pct(p.pass)),
  machines: (p) => td("muted wrap", esc(p.machines.join(", ")) || "-"),
};

// The CI slots, from hub_core::ci (the one join the TUI and fleet-bench share): every machine's
// slots with the job each runs and how long against its usual; a late job (past an hour or its
// usual p90) shows amber.
const SLOT_COLS = { host: ["host"], slot: ["slot"], state: ["state"], pool: ["pool"], ran: ["ran", "n"], usual: ["usual", "n"], job: ["job"], ref: ["ref"] };
const slotState = (s) => (s === "off" ? "bad" : s === "withheld" ? "warn" : s === "busy" ? "" : "muted");
const SLOT_CELLS = {
  host: (r, l) => td("", tblLink(l.host, r.host)),
  slot: (r) => td("", esc(r.slot)),
  state: (r) => td(slotState(r.state), esc(r.state)),
  pool: (r, l) => td("muted", tblLink(l.pool, r.pool)),
  ran: (r) => td(`n${r.late ? " warn" : ""}`, secs(r.ran) + (r.late ? "!" : "")),
  usual: (r) => td("n muted", secs(r.usual)),
  job: (r) => (r.state === "busy" ? td("wrap", esc(r.job || "-")) : td("muted wrap", esc(r.note || ""))),
  ref: (r) => td("muted", esc(r.state === "busy" ? ciRef(r) : "")),
};

const QUEUED_COLS = { job: ["job"], pool: ["pool"], ref: ["ref"], n: ["n", "n"], wait: ["wait", "n"], needs: ["needs"], can: ["can run on"] };
const QUEUED_CELLS = {
  job: (q) => td(q.stuck ? "bad" : "", esc(q.job || "-")),
  pool: (q, l) => td("muted", tblLink(l.pool, q.pool)),
  ref: (q) => td("muted", esc(ciRef(q))),
  n: (q) => td("n", q.n),
  wait: (q) => td("n", secs(q.wait)),
  needs: (q) => td("muted", esc(q.needs.join(", "))),
  can: (q) => td("wrap", q.can.length ? q.can.map((f) => `${esc(f.host)} <span class="muted">${esc(f.state)}</span>`).join(", ") : q.needs.length ? "nobody" : "-"),
};

// Main's pass rate leads: a red on the default branch is everyone's problem, while a red gate on
// a work branch is usually the gate doing its job (github_runs_finished's scope label).
const passOf = (t) => (t.ok + t.bad ? t.ok / (t.ok + t.bad) : null);
const runSeg = (f) => `<span class="stack" data-tip="${esc(`${f.repo} ${f.workflow}\nmain: ${f.main.ok} passed, ${f.main.bad} failed, ${f.main.can} cancelled\nbranches: ${f.branch.ok} passed, ${f.branch.bad} failed, ${f.branch.can} cancelled`)}">${[[f.all.ok, "var(--b-done)"], [f.all.bad, "var(--b-needs)"], [f.all.can, "var(--c-other)"]].filter(([n]) => n).map(([n, c]) => `<i style="flex:${n};background:${c}"></i>`).join("")}</span>`;
const FIN_COLS = { repo: ["repo"], workflow: ["workflow"], main: ["main", "n"], branches: ["branches", "n"], runs: ["runs"], failed: ["failed", "n"], cancelled: ["cancelled", "n"] };
const FIN_CELLS = {
  repo: (f) => td("", esc(f.repo)),
  workflow: (f) => td("wrap", esc(f.workflow)),
  main: (f) => td(`n ${passCls(passOf(f.main))}`, pct(passOf(f.main))),
  branches: (f) => td("n muted", pct(passOf(f.branch))),
  runs: (f) => td("m", `${runSeg(f)} ${f.all.runs}`),
  failed: (f) => td("n", f.all.bad),
  cancelled: (f) => td("n", f.all.can),
};

// One table's rows from the read: `cap` rows until its "+N more".
function infraBody(name, labels, cells, empty, o = {}) {
  const d = ist.data.tables[name], t = d.table, rows = d.rows;
  if (!rows.length) return `<div class="panel"><div class="empty">${t.total ? "No row matches." : empty}</div></div>`;
  const keys = t.columns.map((c) => c.key).filter((k) => labels[k] && cells[k]);
  const cap = o.cap && !INFRA_T[name].all ? o.cap : rows.length, shown = rows.slice(0, cap);
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, labels)}${shown.map((r, i) =>
    `<tr>${keys.map((k) => cells[k](r, tblLinks(t, i))).join("")}</tr>`).join("")}</table>${tblMore(rows.length - shown.length, "more")}</div>`;
}

const infraTable = (name, labels, cells, hint, empty, o) => tblTab({
  tab: "infra", id: "infra-" + INFRA_TABLES[name], el: "infra-main", pre: INFRA_TABLES[name], hint,
  refresh: () => refreshInfra(), render: () => renderInfra(), table: () => ist.data?.tables?.[name]?.table,
  wrap: (h) => `<div data-tbl="${INFRA_TABLES[name]}">${h}</div>`,
  body: () => infraBody(name, labels, cells, empty, o),
});
const INFRA_T = {
  machines: infraTable("machines", MACH_COLS, MACH_CELLS, "search, or where:cloud pools:unity -state:up", "No machine reports."),
  pools: infraTable("pools", POOL_COLS, POOL_CELLS, "search, or machines:razer-laptop", "No pool reports."),
  runners: infraTable("runners", SLOT_COLS, SLOT_CELLS, "search, or host:razer-laptop pool:unity", "No runner reports."),
  queued: infraTable("queued", QUEUED_COLS, QUEUED_CELLS, "search, or pool:unity can:aws-burst-1", "Nothing queued."),
  finished: infraTable("finished", FIN_COLS, FIN_CELLS, "search, or repo:unity-core-playground", "No finished-run series yet.", { cap: FINISHED_ROWS }),
};

// Done today. Each row's `hour` label is the start of the hour it finished in, epoch seconds.
// A conclusion that is none of these (skipped, neutral) counts in no column, as in hub_core::ci Tally.
const CI_OUTCOME = { success: "ok", failure: "bad", timed_out: "bad", cancelled: "can" };
const ciRows = (inst) => (inst.hourly || []).map((s) => ({ hour: +s.labels.hour, scope: s.labels.scope, out: CI_OUTCOME[s.labels.conclusion], n: s.value || 0 }));
const localRows = (inst) => (inst.local_hourly || []).map((s) => ({ hour: +s.labels.hour, out: s.labels.result === "pass" ? "ok" : "bad", n: s.value || 0 }));

function tally(rows) {
  const t = { ok: 0, bad: 0, can: 0 };
  for (const r of rows) if (r.out) t[r.out] += r.n;
  return t;
}
const hh = (hour) => String(new Date(hour * 1e3).getHours()).padStart(2, "0");

// What failed, like the Log tab's merged list: main first because a red there is everyone's
// problem, then each repo, then the local Unity runs by branch.
function failedList(inst) {
  const runs = (inst.failed || []).slice().sort((a, b) => b.value - a.value);
  const group = (key, name, n, body) => {
    const open = ist.open[key] ?? (key === "main" || n <= FAILED_OPEN);
    return `<details class="panel area" data-k="${esc(key)}"${open ? " open" : ""}><summary>${esc(name)} <span class="muted">${n}</span></summary>${body}</details>`;
  };
  const row = (s) => {
    const l = s.labels, what = l.pr ? "#" + l.pr : "run";
    const text = l.pr ? l.title : `${l.branch}${l.title ? ": " + l.title : ""}`;
    return `<div class="pr" data-tip="${esc(`${l.repo} ${l.workflow}\n${l.branch}\n${l.conclusion} ${clock(s.value * 1e3)}`)}"><span class="ft">${clock(s.value * 1e3)}</span><a href="${esc(l.url)}" target="_blank" rel="noopener">${esc(what)}</a><span class="pt">${esc(text)}</span>${l.conclusion === "timed_out" ? '<b class="ci fail">timeout</b>' : ""}</div>`;
  };
  const byWorkflow = (rows, name) => {
    const g = {};
    for (const s of rows) (g[name(s.labels)] ||= []).push(s);
    return Object.entries(g).sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0])).map(([w, rs]) => `<div class="grp">${esc(w)}</div>${rs.map(row).join("")}`).join("");
  };
  const main = runs.filter((s) => s.labels.scope === "main");
  const branch = {};
  for (const s of runs.filter((s) => s.labels.scope !== "main")) (branch[s.labels.repo] ||= []).push(s);
  let html = main.length ? group("main", "On main", main.length, byWorkflow(main, (l) => `${l.repo} ${l.workflow}`)) : "";
  html += Object.entries(branch).sort((a, b) => b[1].length - a[1].length).map(([repo, rs]) => group("repo:" + repo, repo, rs.length, byWorkflow(rs, (l) => l.workflow))).join("");
  // The ledger counts per hour, so a whole day folds one branch's runs into one row.
  const local = {};
  for (const s of inst.local_failed || []) {
    const l = s.labels, k = [l.repo, l.branch, l.platform, l.result].join("\t");
    const a = (local[k] ||= { l, n: 0, last: 0 });
    a.n += s.value || 0; a.last = Math.max(a.last, +l.hour);
  }
  const lrows = Object.values(local).sort((a, b) => b.last - a.last || b.n - a.n);
  if (lrows.length) {
    html += group("local", "Local Unity", lrows.reduce((x, a) => x + a.n, 0), lrows.map((a) =>
      `<div class="pr"><span class="ft">${hh(a.last)}:00</span><span class="pt">${esc(a.l.branch)}</span><span class="by">${esc(a.l.platform)} ${esc(a.l.result)}${a.n > 1 ? " x" + a.n : ""}</span></div>`).join(""));
  }
  return html || `<div class="panel">Nothing failed.</div>`;
}
const failedCount = (inst) => (inst.failed || []).length + (inst.local_failed || []).reduce((x, s) => x + (s.value || 0), 0);

function doneToday(inst, t1) {
  const ci = ciRows(inst), local = localRows(inst);
  if (!ci.length && !local.length) return `<h3 class="sec">Done today</h3><div class="panel">No hourly data yet.</div>`;
  const midnight = new Date(t1).setHours(0, 0, 0, 0) / 1e3, today = (r) => r.hour >= midnight;
  const tc = tally(ci.filter(today)), tl = tally(local.filter(today));
  const failed = (scope) => tally(ci.filter((r) => today(r) && r.scope === scope)).bad;
  const onMain = failed("main");
  const tiles = `<div class="tiles roomy">${
    tile("CI RUNS", tc.ok + tc.bad + tc.can, "var(--c1)", `${pct(passOf(tc))} pass`)}${
    tile("FAILED ON MAIN", onMain, onMain ? "var(--b-needs)" : "var(--b-done)")}${
    tile("FAILED ON BRANCHES", failed("branch"), "var(--b-stalled)")}${
    tile("CANCELLED", tc.can, "var(--c-other)")}${
    tile("LOCAL UNITY", tl.ok + tl.bad, "var(--c3)", `${pct(passOf(tl))} pass`)}</div>`;
  const note = `Tiles count from midnight; CI is read every 10 minutes. Runs per hour and the 24h status lanes are in Grafana ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-command-center", "Command Center")}.`;
  return `<h3 class="sec">Done today</h3>${tiles}<div class="muted fold">${note}</div>`;
}

// The CI runners section: the slots of hub_core::ci, the queued jobs with what each needs and the
// hosts that can take it, the day's failures, then the finished runs by workflow and the day's
// tiles. Each pool's queue and last day are the Pools table on Machines; the runs themselves
// (hub_core::builds) and the Tests are the sections under it (ci.js).
const ciHead = (ci) => `${ci.hosts} hosts, ${ci.slots} slots, ${ci.busy} busy, ${ci.queued} queued${ci.queued ? ` (oldest ${secs(ci.oldest)})` : ""}`;
function ciSection(inst, t1, ci) {
  const failed = failedCount(inst), done = ci.done;
  const fin = `${done.runs} runs, ${pct(passOf(done))} pass, ${done.bad} failed, ${done.can} cancelled`;
  const green = !ci.busy && !ci.queued && !failed;
  let html = `<h2 class="sec" id="sec-ci">CI runners <span class="muted">${esc(ciHead(ci))}${failed ? `, failed 24h ${failed}` : green ? `; green: nothing queued or failed in 24h` : ""}</span></h2>`;
  // A queued job no online runner can take: hub_core::ci words the line, once for both surfaces.
  if (ci.red.length) html += `<div class="panel down">${ci.red.map((r) => `<div class="pr"><span class="chip sm" style="--c:var(--b-needs)">RED</span><span class="pt">${esc(r)}</span></div>`).join("")}</div>`;
  html += INFRA_T.runners.html();
  html += `<h3 class="sec">Queued</h3>${INFRA_T.queued.html()}`;
  if (failed) html += `<h3 class="sec">Failed, last 24h</h3>${failedList(inst)}`;
  html += `<h3 class="sec">Finished 24h <span class="muted">${esc(fin)}</span></h3>${INFRA_T.finished.html()}`;
  const open = secOpen(ist.open, "ci-more") ? " open" : "";
  html += `<details class="sec-d" data-k="ci-more"${open}><summary class="muted fold">Done today</summary>${doneToday(inst, t1)}</details>`;
  return html;
}

// The governor's global series: whether it is up and saw every source, its queue, and the budget
// lines. Its per-host verdict and power are the machines table's governor and power columns.
function governorIndex(inst) {
  const g = { alerts: [], actions: [] };
  for (const s of inst.governor || []) {
    const l = s.labels, n = l.__name__.replace("ci_governor_", "");
    if (l.host) continue;
    if (n === "budget_alert") g.alerts.push([l.basis, Number(l.usd)]);
    else if (n === "budget_action_usd") g.actions.push([l.type, l.status, s.value]);
    else g[n] = s.value;
  }
  return g;
}

function governorLine(g) {
  if (g.up == null) return "";
  const health = g.up !== 1 ? `<span class="chip sm" style="--c:var(--b-needs)">DOWN</span>`
    : g.ok === 1 ? `<span class="chip sm" style="--c:var(--b-done)">OK</span>` : `<span class="chip sm" style="--c:var(--b-stalled)">BLIND</span> a source did not answer this cycle, so it holds every host;`;
  return `<div class="cline">Governor ${health} <span class="muted">queue ${g.queue ?? "?"}; a dry-run host is logged, never changed; the cloud hosts start for a deep queue and a button overrides it</span></div>`;
}

// [150, 100, 100] -> "$100 and $150"
const usdList = (xs) => [...new Set(xs)].sort((a, b) => a - b).map((x) => "$" + x).join(" and ");

// What AWS does at each budget line; the month's dollars are Costs > Budget, beside every other bill.
function budgetLines(g) {
  if (g.budget_ok == null) return "";
  const failed = g.budget_ok ? "" : ` <span class="chip sm" style="--c:var(--b-stalled)">READ FAILED</span> (runbook, "budget read")`;
  const month = `<div class="month"><span>Month: <a href="#costs/budget">Costs, Budget</a></span><span class="muted">the governor read AWS Budgets ${when(g.budget_updated)}${failed}</span></div>`;
  const act = g.alerts.filter(([b]) => b === "actual").map(([, v]) => v), fore = g.alerts.filter(([b]) => b === "forecasted").map(([, v]) => v);
  const mails = act.length ? `Emails at ${usdList(act)}${usdList(fore) === usdList(act) ? " (spent or forecast)" : fore.length ? `, forecast at ${usdList(fore)}` : ""}` : "";
  const stops = [...new Set(g.actions.map(([, , v]) => v))].map((v) => {
    const fired = g.actions.filter(([, st, x]) => x === v && st !== "STANDBY");
    return `at $${v} AWS stops it and blocks starts${fired.length ? ` <span class="chip sm" style="--c:var(--b-needs)">${esc(fired.map(([, st]) => st).join(", "))}</span> (undo: runbook, "Budget stop")` : ""}`;
  });
  const lines = [mails, ...stops].filter(Boolean).join("; ");
  return month + (lines ? `<div class="muted">${lines}. Each day stops at its hour cap.</div>` : "");
}

// `#infra/machines/<host>` (GET /api/infra/machine, hub_core::machine_page, which the hub's page
// draws too): its parts, the cores each pool uses there, what runs there, the governor and its
// buttons, its last 7 days and downtime, the CI jobs that ran there and the alerts naming it.
const mst = { host: "", data: null, err: null, all: false };
const machineHost = () => pageId("infra", "machines");
const refreshMachine = coalesce(async () => {
  const host = machineHost();
  if (!host) return;
  try { mst.data = await api("/api/infra/machine?host=" + encodeURIComponent(host)); mst.err = null; } catch (e) { if (mst.data && mst.data.host !== host) mst.data = null; mst.err = e.message; }
  if (machineHost() === host) renderInfra();
});
// Power changes shown before "+N older".
const HIST_ROWS = 30;

// Each pool one slot colour on the whole page (share bar and chart), by name.
function poolColors(d) {
  const names = new Set(d.share.filter((s) => s.what !== "idle" && s.what !== "other").map((s) => s.what));
  if (d.history) d.history.hours.forEach((x) => Object.keys(x.pools).forEach((p) => names.add(p)));
  return Object.fromEntries([...names].sort().map((p, i) => [p, SLOTS[i % SLOTS.length]]));
}

// Each pool its colour, other the muted one, idle the empty track.
function shareBar(d, colors) {
  if (!d.share.length) return `<div class="muted">No core reading: no runner and no CPU series.</div>`;
  const color = (s) => (s.what === "idle" ? "transparent" : s.what === "other" ? OTHER : colors[s.what]);
  const bar = d.share.map((s) => `<i style="flex:${s.cores.toFixed(2)};background:${color(s)}" title="${esc(`${s.what}: ${s.cores.toFixed(1)} cores`)}"></i>`).join("");
  const words = d.share.map((s) => `${tblLink(s.link, s.what)} ${s.cores.toFixed(1)}`).join(", ");
  return `<div><span class="stack">${bar}</span> ${words}${d.cores != null ? ` <span class="muted">of ${d.cores} cores</span>` : ""}</div>`;
}

// An hourly chart's column label: the weekday at midnight, else none.
const dayTick = (at) => { const d = new Date(at * 1e3); return d.getHours() === 0 ? d.toLocaleDateString([], { weekday: "short" }) : ""; };

// One column per hour: the pools' cores as a share of the machine, then the rest of its CPU.
function historyChart(h, cores, colors) {
  const pools = [...new Set(h.hours.flatMap((x) => Object.keys(x.pools)))].sort();
  const cols = h.hours.map((x) => {
    const segs = pools.map((p) => ({ v: cores ? (x.pools[p] || 0) / cores : 0, color: colors[p] }));
    const ci = segs.reduce((a, s) => a + s.v, 0);
    if (x.cpu != null) segs.push({ v: Math.max(0, x.cpu - ci), color: OTHER });
    const used = pools.filter((p) => x.pools[p]).map((p) => `\n${p} ${x.pools[p].toFixed(1)} cores`).join("");
    const tip = x.cpu == null ? `${stamp(x.at)}: no reading` : `${stamp(x.at)}: cpu ${pct(x.cpu)}${used}`;
    return { key: String(x.at), label: dayTick(x.at), tip, segs };
  });
  const key = [...pools.map((p) => [p, colors[p]]), ["other", OTHER]].map(([n, c]) => `<span class="chip sm" style="--c:${c}">${esc(n)}</span>`).join(" ");
  return `${columns(cols, { height: 120, yfmt: pct })}<div class="muted">${key} hourly means of ${h.step / 60}-minute samples</div>`;
}

const DOWN_COLS = { from: ["from"], to: ["to"], took: ["took", "n"], why: ["why"] };
const DOWN_CELLS = {
  from: (r) => td("", stamp(r.from)),
  to: (r) => td(r.open ? "warn" : "", r.open ? "now" : stamp(r.to)),
  took: (r) => td("n", secs(r.to - r.from)),
  why: (r) => td("muted", esc(r.why)),
};
const RECENT_COLS = { started: ["started"], repo: ["repo"], job: ["job"], runner: ["runner"], conclusion: ["conclusion"], took: ["took", "n"] };
const RECENT_CELLS = {
  started: (r, l) => td("", tblLink(l.started, r.started ? stamp(r.started) : "-")),
  repo: (r) => td("muted", esc(r.repo)),
  job: (r, l) => td("wrap", tblLink(l.job, r.job)),
  runner: (r) => td("muted", esc(r.runner)),
  conclusion: (r) => td(r.conclusion === "failure" ? "bad" : r.conclusion === "success" ? "" : "muted", esc(r.conclusion || "running")),
  took: (r) => td("n", secs(r.took)),
};
const PAGE_ALERT_COLS = { sev: ["sev"], what: ["what"], source: ["source"], since: ["since", "n"], state: ["state"] };
const PAGE_ALERT_CELLS = {
  sev: (a) => td("warn", esc(a.sev)),
  what: (a, l) => td("wrap", tblLink(l.what, a.what)),
  source: (a) => td("muted", esc(a.source)),
  since: (a) => td("n", a.since ? stamp(a.since) : "-"),
  state: (a) => td("muted", esc(a.state)),
};
// A page table: the rows in hub_core's order with their links, with no view of its own.
function pageTable(d, labels, cells, empty) {
  if (!d || !d.rows.length) return `<div class="empty">${empty}</div>`;
  const keys = d.table.columns.map((c) => c.key).filter((k) => labels[k] && cells[k]);
  const role = Object.fromEntries(d.table.columns.map((c) => [c.key, c.role || ""]));
  const head = keys.map((k) => `<th${labels[k][1] ? ` class="${labels[k][1]}"` : ""} data-role="${role[k]}" data-label="${esc(labels[k][0])}">${esc(labels[k][0])}</th>`).join("");
  return `<div class="panel scroll"><table class="tbl"><tr>${head}</tr>${d.rows.map((r, i) => `<tr>${keys.map((k) => cells[k](r, tblLinks(d.table, i))).join("")}</tr>`).join("")}</table></div>`;
}

function powerHistory(p) {
  const ch = [...p.changes].reverse(), shown = mst.all ? ch : ch.slice(0, HIST_ROWS);
  const days = p.days.map((x) => `${esc(x.day.slice(5))} <b>${x.hours.toFixed(1)} h</b>`).join("  ");
  const rows = shown.map((c) => `<tr><td>${esc(stamp(c.at))}</td><td>${powerChip(c.state)}</td><td class="muted">${esc(c.reason && c.reason !== "none" ? c.reason : "")}</td></tr>`).join("");
  const more = ch.length > shown.length ? `<button class="btn sm" data-hist-all="1">+${ch.length - shown.length} older</button>` : "";
  return `<h3 class="sec">Power <span class="muted">run per UTC day, counted from ${p.step / 60}-minute samples of the governor's power state</span></h3><div>${days || "no samples"}</div>${rows ? `<table class="tbl"><tr><th data-role="lead">from</th><th data-role="glance">state</th><th>why</th></tr>${rows}</table>` : ""}${more}`;
}

// The governor's buttons for a host it powers: hold it on or off for a while, or hand it back.
// POST /api/cloud-runner writes the governor's override ConfigMap; the pod sees the change within
// about two minutes.
const CLOUD_ACTS = [["on", 2, "On 2h"], ["off", 6, "Off 6h"], ["clear", 0, "Clear"]];
// The button armed by a first click ("host:action") and the last answer.
const cst = { armed: "", msg: "", host: "" };
function cloudButtons(p) {
  const btns = CLOUD_ACTS.map(([a, n, label]) => {
    const k = `${p.host}:${a}`;
    return `<button class="btn sm" data-cloud="${esc(k)}" data-hours="${n}">${cst.armed === k ? `Click again: ${label}` : label}</button>`;
  }).join(" ");
  return pageRow("Hold", btns) + (cst.msg && cst.host === p.host ? `<div class="err">${esc(cst.msg)}</div>` : "");
}

function machinePage() {
  const back = `<a class="btn sm" href="#infra/machines${st.views.infra ? "?" + st.views.infra : ""}">All machines</a>`;
  const d = mst.data;
  if (!d) return `<div class="bhead"><span>${esc(mst.host)}</span>${back}</div><div class="${mst.err ? "panel down" : "empty"}">${mst.err ? esc(mst.err) : "Loading..."}</div>`;
  const colors = poolColors(d);
  let h = `<div class="bhead"><span>${esc(d.head)} <span class="muted">read ${clock(d.at * 1e3)}</span></span>${back}</div>`;
  const errs = mst.err ? [`refresh failed, showing the last read: ${mst.err}`, ...d.errors] : d.errors;
  if (errs.length) h += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  h += `<div class="panel">${d.parts.map(pagePart).join("")}${d.machine.power ? cloudButtons(d.machine.power) : ""}</div>`;
  h += `<h3 class="sec">Share <span class="muted">cores by runner pool now, then other work, then idle</span></h3>${shareBar(d, colors)}`;
  const run = (r) => `<tr>${td("", esc(r.slot))}${td("muted", tblLink(r.pool ? "#infra/pools/" + encodeURIComponent(r.pool) : "", r.pool))}${td("wrap", esc(r.job || "-"))}${td("muted", esc(ciRef(r)))}${td(`n${r.late ? " warn" : ""}`, secs(r.ran) + (r.late ? "!" : ""))}</tr>`;
  h += `<h3 class="sec">Running</h3>${d.running.length ? `<div class="panel scroll"><table class="tbl"><tr><th>slot</th><th>pool</th><th data-role="lead">job</th><th>ref</th><th class="n" data-role="glance">ran</th></tr>${d.running.map(run).join("")}</table></div>` : `<div class="empty">Nothing runs there now.</div>`}`;
  const hist = d.history;
  if (hist) {
    h += `<h3 class="sec">7 days <span class="muted">${hist.readings ? `${hist.readings} readings` : "no reading in the window"}</span></h3>${historyChart(hist, d.cores, colors)}`;
    h += `<h3 class="sec">Downtime <span class="muted">stretches with no CPU reading, newest first</span></h3>${pageTable(d.tables.down, DOWN_COLS, DOWN_CELLS, "No gap in the readings.")}`;
    if (hist.power) h += powerHistory(hist.power);
  }
  h += `<h3 class="sec">Recent CI jobs <span class="muted">the newest ${d.tables.recent.rows.length} in the jobs archive</span></h3>${pageTable(d.tables.recent, RECENT_COLS, RECENT_CELLS, "No CI job in the archive ran there.")}`;
  h += `<h3 class="sec">Alerts <span class="muted">firing now and naming it</span></h3>${pageTable(d.tables.alerts, PAGE_ALERT_COLS, PAGE_ALERT_CELLS, "Nothing firing names it.")}`;
  return h;
}

// `#infra/pools/<pool>` (GET /api/infra/pool, hub_core::pool_page, which the hub's page draws
// too): its parts, the machines with a slot in it, the CI jobs waiting
// for it, and its busy, slots and waiting over 7 days.
const poolst = { name: "", data: null, err: null };
const poolName = () => pageId("infra", "pools");
const refreshPool = coalesce(async () => {
  const name = poolName();
  if (!name) return;
  try { poolst.data = await api("/api/infra/pool?name=" + encodeURIComponent(name)); poolst.err = null; } catch (e) { if (poolst.data && poolst.data.pool !== name) poolst.data = null; poolst.err = e.message; }
  if (poolName() === name) renderInfra();
});

// One column per hour: its busy slots, then its idle ones; the jobs waiting under it.
function poolChart(h) {
  const n = (v) => (v == null ? "?" : v.toFixed(1));
  const tip = (x) => (x.busy == null && x.slots == null ? `${stamp(x.at)}: no reading` : `${stamp(x.at)}: ${n(x.busy)} busy of ${n(x.slots)} slots, ${x.waiting ?? "?"} waiting at most`);
  const slots = h.hours.map((x) => ({ key: String(x.at), label: dayTick(x.at), tip: tip(x),
    segs: [{ v: x.busy || 0, color: SLOTS[0] }, { v: Math.max(0, (x.slots || 0) - (x.busy || 0)), color: OTHER }] }));
  const wait = h.hours.map((x) => ({ key: String(x.at), label: dayTick(x.at), tip: tip(x), segs: [{ v: x.waiting || 0, color: "var(--b-stalled)" }] }));
  const key = [["busy", SLOTS[0]], ["idle", OTHER]].map(([k, c]) => `<span class="chip sm" style="--c:${c}">${k}</span>`).join(" ");
  return `${columns(slots, { height: 120 })}<div class="muted">${key} slots, hourly means of ${h.step / 60}-minute samples</div>`
    + `${columns(wait, { height: 60 })}<div class="muted"><span class="chip sm" style="--c:var(--b-stalled)">waiting</span> the most jobs waiting in each hour</div>`;
}

function poolPage() {
  const back = `<a class="btn sm" href="#infra/machines${st.views.infra ? "?" + st.views.infra : ""}">All pools</a>`;
  const d = poolst.data;
  if (!d) return `<div class="bhead"><span>${esc(poolst.name)}</span>${back}</div><div class="${poolst.err ? "panel down" : "empty"}">${poolst.err ? esc(poolst.err) : "Loading..."}</div>`;
  let h = `<div class="bhead"><span>${esc(d.head)} <span class="muted">read ${clock(d.at * 1e3)}</span></span>${back}</div>`;
  const errs = poolst.err ? [`refresh failed, showing the last read: ${poolst.err}`, ...d.errors] : d.errors;
  if (errs.length) h += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  h += `<div class="panel">${d.parts.map(pagePart).join("")}</div>`;
  h += `<h3 class="sec">Machines <span class="muted">with a slot in it</span></h3>${pageTable(d.tables.machines, MACH_COLS, MACH_CELLS, "No machine has a slot in it.")}`;
  h += `<h3 class="sec">Waiting <span class="muted">CI jobs queued for it, as the CI section has them</span></h3>${pageTable(d.tables.waiting, QUEUED_COLS, QUEUED_CELLS, "Nothing waits for it.")}`;
  const hist = d.history;
  if (hist) h += `<h3 class="sec">7 days <span class="muted">${hist.readings ? `${hist.readings} readings` : "no reading in the window"}</span></h3>${poolChart(hist)}`;
  return h;
}

async function cloudAct(key, hours) {
  const i = key.lastIndexOf(":"), host = key.slice(0, i), action = key.slice(i + 1);
  cst.armed = "";
  cst.host = host;
  try { await post("/api/cloud-runner", { host, action, hours }); cst.msg = `${host}: ${action} sent; the governor reads it within about 2 minutes.`; }
  catch (e) { cst.msg = `${host}: ${e.message}`; }
  renderInfra();
}

// The page has no confirm dialog to lean on, so a button asks twice; the arm lapses after 4 s.
$("infra").addEventListener("click", (e) => {
  const go = e.target.closest("[data-go]");
  if (go) { e.preventDefault(); setTab(go.dataset.go); return; }
  if (e.target.closest("[data-hist-all]")) { mst.all = true; renderInfra(); return; }
  const b = e.target.closest("[data-cloud]");
  if (!b) return;
  const k = b.dataset.cloud;
  if (cst.armed === k) { cloudAct(k, Number(b.dataset.hours)); return; }
  cst.armed = k;
  renderInfra();
  setTimeout(() => { if (cst.armed === k) { cst.armed = ""; renderInfra(); } }, 4000);
});

function drawInfra() {
  const el = $("infra-main");
  const d = ist.data;
  // The strip comes first on every path, then each section in its inner tab's group
  // (hub_core::layout, app.js INNER_TABS). CI's runs and Tests (ci.js) and Jobs (jobs.js) are
  // elements of their own under main, each painted by its own read.
  innerHide("infra", "runs", $("ci-runs"));
  innerHide("infra", "tests", $("ci-tests"));
  innerHide("infra", "jobs", $("jobs"));
  const strip = innerStrip("infra", infraFlagged(d));
  if (machineHost()) { paint(el, strip + machinePage()); return; }
  // A run's own page stands in for CI's sections, as a machine's does for Machines.
  if (ciRunId()) { $("ci-runs").hidden = $("ci-tests").hidden = true; paint(el, strip + runPage()); return; }
  if (poolName()) { paint(el, strip + poolPage()); return; }
  if (!d) { el.innerHTML = strip + `<div class="empty">${ist.err ? esc(ist.err) : "Loading..."}</div>`; return; }
  const links = `${gLink("kb-command-center", "Command Center")} ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-fleet", "Machines")} ${gLink("kb-agents-overview", "Agents")}`;
  // As the board blanks: a failed read never leaves the last (maybe green) numbers up.
  if (!d.ok) { el.innerHTML = strip + `<div class="bhead"><span>infra</span><span>${links}</span></div><div class="panel down">${esc(d.error || "Prometheus did not answer")}</div>`; seekSection(); return; }
  const cc = ccIndex(d.instant.cc), inst = d.instant, t1 = d.at * 1e3, g = governorIndex(inst);
  const overall = (cc["cc:overall_status"] || {})[""];
  const [word, color] = statusOf(overall);
  // Home owns the asks; Infra shows their count as a badge that opens Home.
  const asks = (cc["cc:asks_open"] || {})[""];
  const badge = asks > 0 ? ` <a href="#home" class="chip sm" data-go="home" style="--c:var(--b-needs)">${asks} ask${asks === 1 ? "" : "s"} on Home</a>` : "";
  let html = strip + `<div class="bhead"><span><span class="chip" style="--c:${color}">OVERALL ${word}</span>${badge} <span class="muted">read ${clock(t1)}</span></span>${pfold("infra-links", "Grafana", links)}</div>`;
  html += innerWrap("infra", "machines", `${kpis(cc)}<h2 class="sec" id="sec-machines">Machines</h2>${INFRA_T.machines.html()}${governorLine(g)}${budgetLines(g)}`);
  html += innerWrap("infra", "pools", `<h2 class="sec" id="sec-pools">Pools <span class="muted">each pool's slots and the last day of its queue</span></h2>${INFRA_T.pools.html()}`);
  html += innerWrap("infra", "ci", ciSection(inst, t1, d.ci));
  paint(el, html, ist.open);
  seekSection();
}

// A table's search or dropdown in use keeps focus: only that table's rows and chips repaint, and
// the others redraw around it (home.js renderHome).
function renderInfra() {
  const busy = ist.data?.ok && Object.values(INFRA_T).find((t) => t.repaint());
  if (busy) { for (const [name, t] of Object.entries(INFRA_T)) if (t !== busy && $(`infra-${INFRA_TABLES[name]}-body`)) t.redraw(); return; }
  drawInfra();
}

// The sections whose inner tab carries a count: CI lines hub_core::ci judged red (a queued job no
// online runner can take), runs that need a look (Builds::needs_look) and a failed suite in the
// Tests run on show (ci.js); the hub's App::infra_flagged reads the same.
const infraFlagged = (d) => [d && d.ci && (d.ci.red || []).length && "ci", bld.data?.look && "runs", tst.data?.totals?.failed_suites > 0 && "tests"].filter(Boolean);

const pollInfra = poll("infra", refreshInfra, INFRA_REFRESH_MS);

TABS.infra = {
  // The Jobs section (jobs.js) reads its own source on its own timer; CI's runs and Tests (ci.js)
  // read on show and again on each new ledger line.
  show() {
    const h = machineHost();
    if (h !== mst.host) { Object.assign(mst, { host: h, data: null, err: null, all: false }); if (h) refreshMachine(); }
    const p = poolName();
    if (p !== poolst.name) { Object.assign(poolst, { name: p, data: null, err: null }); if (p) refreshPool(); }
    showRunPage();
    renderInfra(); pollInfra(); showJobs(); bldFeed.show(!bld.data || bld.moved()); tstFeed.show(!tst.data || tst.moved());
  },
  // Nothing on this machine changes Prometheus, so file events do not apply; only a resync does.
  onEvent(ev) {
    if (ev.kind === "resync" && st.tab === "infra") { refreshInfra(); jst.refresh(); }
    bldFeed.onEvent(ev); tstFeed.onEvent(ev); runFeed.onEvent(ev);
  },
};
