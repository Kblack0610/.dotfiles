"use strict";
// The Infra tab, as the hub's Infra tab, by inner tab: Machines (the MACHINES table, the governor), CI,
// Jobs (jobs.js) and Cloud runners, exceptions first; what is red and the health chips are on Alerts (alerts.js). /api/infra asks Prometheus the board's own
// queries; statuses are the cc:* rules, so nothing is judged here.

// Prometheus has no push to a browser, so the open tab re-reads on the board's cadence
// (REFRESH_SECS=60): the rules evaluate every minute, and faster only redraws the same numbers.
const INFRA_REFRESH_MS = 60e3;
// A day's failures start folded per group past this many rows, as the Log tab folds a busy day.
const FAILED_OPEN = 25;
// Each failed group's folded state, which outlives the re-render on every refresh.
const ist = { data: null, err: null, open: {} };

const refreshInfra = coalesce(async () => {
  try { ist.data = await api("/api/infra"); ist.err = null; } catch (e) { ist.err = e.message; }
  // An opened history re-reads with the board, so its last state and today's hours stay current
  // and a failed read retries.
  for (const h of Object.keys(cst.hist)) loadHist(h);
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

// Pools with slots or a queue, the longest queue first.
const poolOrder = (cc) => [...new Set([...Object.keys(cc["cc:pool_slots"] || {}), ...Object.keys(cc["cc:pool_waiting"] || {})])]
  .sort((a, b) => ((cc["cc:pool_waiting"] || {})[b] || 0) - ((cc["cc:pool_waiting"] || {})[a] || 0) || a.localeCompare(b));

// Each pool's queue and its last day: waiting, the oldest wait, done and pass. Its slots and the
// machines serving it are the MACHINES table's pools column.
function queuesTable(cc) {
  const pools = poolOrder(cc);
  const g = (n, p) => (cc[n] || {})[p];
  const row = (p, waiting, oldest, done, pass) => `<tr><td>${esc(p)}</td><td class="n${waiting ? " warn" : ""}">${waiting ?? "-"}</td><td class="n">${secs(oldest)}</td><td class="n">${done ?? "-"}</td><td class="n ${pass == null ? "" : pass < 0.7 ? "bad" : pass < 0.9 ? "warn" : ""}">${pct(pass)}</td></tr>`;
  let rows = pools.map((p) => row(p, g("cc:pool_waiting", p), g("cc:pool_oldest_wait_seconds", p), g("cc:pool_done_24h", p), g("cc:pool_pass_ratio_24h", p))).join("");
  for (const h of Object.keys(cc["cc:host_local_slots"] || {})) rows += row(`unity-local on ${h}`, g("cc:host_local_queued", h), null, g("cc:host_local_done_24h", h), g("cc:host_local_pass_ratio_24h", h));
  for (const p of Object.keys(cc["cc:pool_done_24h"] || {}).filter((p) => !pools.includes(p))) rows += row(p, null, null, g("cc:pool_done_24h", p), g("cc:pool_pass_ratio_24h", p));
  return `<table class="tbl"><tr><th data-role="lead">pool</th><th class="n" data-role="glance" data-named>waiting</th><th class="n" data-role="glance" data-named>oldest</th><th class="n">done 24h</th><th class="n" data-role="glance" data-named>pass</th></tr>${rows}</table>`;
}

// One bar per core, in core order, from cc:host_core_busy_ratio; amber past 90% as the cpu meter.
function coreStrip(cores) {
  const busyColor = (v) => (v > 0.9 ? "var(--b-stalled)" : "var(--c1)");
  return `<span class="cores">${cores.map(([cpu, v]) => `<i title="cpu ${esc(cpu)}: ${pct(v)}"><b style="height:${(Math.max(0, Math.min(1, v || 0)) * 100).toFixed(0)}%;background:${busyColor(v)}"></b></i>`).join("")}</span>`;
}

// Per runner name: the cores its job uses and a pinned slot's CPUs (cc:runner_cores_*, from
// roles/ci-runner-cpu), and whether the governor withholds it.
function runnerIndex(inst) {
  const by = {};
  for (const s of inst.runner_cores || []) (by[s.labels.runner] ||= {})[s.labels.__name__ === "cc:runner_cores_busy" ? "busy" : "allowed"] = s.value;
  for (const s of inst.withheld || []) (by[s.labels.name] ||= {}).held = true;
  return by;
}

// Each machine's CI slots, counted as cc:pool_slots counts them and as the hub board's
// machine_slots does: a slot is a running runner, or an idle one the governor does not
// withhold. A withheld runner shows as `<pool> withheld` and is no slot; an offline or missing
// one counts in `off`. The workstation's local gates fold into its row as unity-local, as
// cc:site_slots folds them into local. `cpu` is the cores each runner's job is using.
function machineSlots(cc, inst) {
  const by = {}, ri = runnerIndex(inst), per = {}, order = poolOrder(cc);
  const at = (h) => (by[h] ||= { host: h, cloud: false, busy: 0, slots: 0, off: 0, pools: [], cpu: [] });
  const rank = (p) => { const i = order.indexOf(p); return i < 0 ? order.length : i; };
  for (const r of inst.runners || []) {
    const l = r.labels, m = at(l.host), c = ri[l.name] || {};
    m.cloud ||= l.site === "cloud";
    if (c.busy != null) m.cpu.push([l.name, c.busy]);
    if (l.state !== "running" && l.state !== "idle") { m.off++; continue; }
    const run = l.state === "running";
    if (run || !c.held) m.slots++;
    if (run) m.busy++;
    const pool = l.pool + (c.held ? " withheld" : "");
    const e = ((per[l.host] ||= {})[pool] ||= { rank: rank(l.pool), b: 0, n: 0 });
    e.n++; if (run) e.b++;
  }
  for (const [h, ps] of Object.entries(per)) at(h).pools.push(...Object.entries(ps).sort(([a, x], [b, y]) => x.rank - y.rank || a.localeCompare(b)).map(([p, e]) => `${p} ${e.b}/${e.n}`));
  const g = (n, h) => (cc[n] || {})[h];
  const gates = {};
  for (const r of inst.gates || []) gates[r.labels.host] = (gates[r.labels.host] || 0) + 1;
  for (const [h, n] of Object.entries(gates)) if (g("cc:host_local_slots", h) == null) at(h).pools.push(`${n} gates`);
  for (const [h, total] of Object.entries(cc["cc:host_local_slots"] || {})) {
    const busy = g("cc:host_local_busy", h) || 0, open = g("cc:host_local_open_slots", h) || 0, room = Math.round(total - open), m = at(h);
    m.busy += busy; m.slots += Math.max(open, busy);
    m.pools.push(`unity-local ${g("cc:host_local_busy", h) ?? "?"}/${g("cc:host_local_open_slots", h) ?? "?"}${room > 0 ? `+${room}` : ""}`);
  }
  return Object.values(by);
}
const busyCell = (m) => (m.busy || m.slots ? `${m.busy}/${m.slots}` : "-");
const whereCell = (m) => (m.cloud ? "cloud" : "local");
const cpuTitle = (m) => m.cpu.sort((a, b) => b[1] - a[1]).map(([n, v]) => `${n}: ${v.toFixed(1)} cores`).join("\n");

// Free share of a machine's fullest disk (the NodeDisk* alerts' rule, home-config): amber under
// the governor's 20% hold and NodeDiskLow, red under NodeDiskCritical's 10%. A cloud machine with
// no reading is amber, needs attention: the AWS hosts are never scraped, so nothing alerts on
// their disks. A local CI row with none says so plainly (cachyos-x8664-main's disk shows on its node row, workstation).
function diskCell(free, m) {
  if (free == null) {
    if (!m) return `<td class="n">-</td>`;
    return `<td class="n${m.cloud ? " warn" : " muted"}" title="no disk metrics for this name: nothing alerts on its disk">no reading</td>`;
  }
  return `<td class="n${free < 0.1 ? " bad" : free < 0.2 ? " warn" : ""}">${pct(free)}</td>`;
}

// The one MACHINES table: every machine with stats or a CI slot, those that carry CI first, then
// the busiest. Its pools column is each pool's busy/slots there, so it is the Pools table's
// slots and the old CI-by-machine rollup too.
function machinesTable(cc, inst) {
  const g = (n, h) => (cc[n] || {})[h];
  const cores = {};
  for (const s of inst.cores || []) (cores[s.labels.host] ||= []).push([s.labels.cpu, s.value]);
  const num = (c) => c.split(",").map(Number);
  for (const c of Object.values(cores)) c.sort(([a], [b]) => { const [x, y] = [num(a), num(b)]; return x[0] - y[0] || (x[1] || 0) - (y[1] || 0); });
  const ci = Object.fromEntries(machineSlots(cc, inst).map((m) => [m.host, m]));
  const disk = Object.fromEntries((inst.disk || []).map((s) => [s.labels.host, s.value]));
  const carries = (h) => !!(ci[h] && (ci[h].slots || ci[h].pools.length));
  // Machines that carry CI first, then the busiest.
  const hosts = [...new Set([...Object.keys(cc["cc:host_cores"] || {}), ...Object.keys(ci).filter(carries)])].sort((a, b) => carries(b) - carries(a) || (g("cc:host_cpu_busy_ratio", b) || 0) - (g("cc:host_cpu_busy_ratio", a) || 0));
  return `<table class="tbl"><tr><th data-role="lead">machine</th><th>where</th><th class="n" data-role="glance" data-named>busy</th><th>cpu (per core)</th><th class="n" data-role="glance" data-named>now</th><th class="n">6h</th><th class="n">load</th><th>mem</th><th class="n"></th><th class="n" data-role="glance" data-named>temp</th><th class="n" title="free on its fullest disk">disk free</th><th>pools</th></tr>${hosts.map((h) => {
    const cpu = g("cc:host_cpu_busy_ratio", h), mem = g("cc:host_mem_used_ratio", h), temp = g("cc:host_temp_c", h), load = g("cc:host_load1", h), n = g("cc:host_cores", h), m = ci[h];
    return `<tr><td>${esc(h)}</td><td class="muted">${m ? whereCell(m) : "local"}</td><td class="n${m && m.off ? " warn" : ""}"${m && m.cpu.length ? ` title="${esc(cpuTitle(m))}"` : ""}>${m ? busyCell(m) : "-"}${m && m.off ? ` +${m.off} off` : ""}</td><td class="m">${cores[h] ? coreStrip(cores[h]) : meter(cpu, cpu > 0.9 ? "var(--b-stalled)" : "var(--c1)")}</td><td class="n">${pct(cpu)}</td><td class="n">${pct(g("cc:host_cpu_busy_ratio:avg6h", h))}</td><td class="n${load > n * 1.5 ? " warn" : ""}">${load == null ? "-" : load.toFixed(1)}/${n ?? "?"}</td><td class="m">${meter(mem, mem > 0.9 ? "var(--b-stalled)" : "var(--c3)")}</td><td class="n">${pct(mem)}</td><td class="n${temp > 85 ? " warn" : ""}">${temp == null ? "-" : Math.round(temp) + "C"}</td>${diskCell(disk[h], m)}<td class="muted wrap">${esc(m ? m.pools.join("  ") : "")}</td></tr>`;
  }).join("")}</table>`;
}

// The CI runners tables, drawn from hub_core::ci (the `ci` field of the read, the one join the
// TUI and fleet-bench share): every machine's slots with the job each runs, how long against its
// usual, then the queued jobs with what each needs and the hosts that can take it. A late job
// (past an hour or its usual p90) shows amber.
const ciRef = (x) => (x.pr ? `${x.repo}#${x.pr}` : x.branch || x.repo || "");
const slotState = (st) => (st === "off" ? "bad" : st === "withheld" ? "warn" : st === "busy" ? "" : "muted");
function runnersTable(ci) {
  if (!ci.rows.length) return "";
  return `<table class="tbl"><tr><th data-role="lead">host</th><th>slot</th><th data-role="glance" data-named>state</th><th class="n" data-role="glance" data-named>ran</th><th class="n">usual</th><th data-role="glance">job</th></tr>${ci.rows.map((r) => {
    const job = r.state === "busy" ? `${esc(r.job || "-")} <span class="muted">${esc(ciRef(r))}</span>` : `<span class="muted">${esc(r.note || "")}</span>`;
    return `<tr><td>${esc(r.host)}</td><td>${esc(r.slot)}</td><td class="${slotState(r.state)}">${esc(r.state)}</td><td class="n${r.late ? " warn" : ""}">${secs(r.ran)}${r.late ? "!" : ""}</td><td class="n muted">${secs(r.usual)}</td><td class="wrap">${job}</td></tr>`;
  }).join("")}</table>`;
}
function queuedTable(ci) {
  if (!ci.queue.length) return "";
  return `<table class="tbl"><tr><th data-role="lead">queued</th><th class="n" data-role="glance" data-named>wait</th><th>needs</th><th data-role="glance" data-named>can run on</th></tr>${ci.queue.map((q) => {
    const can = q.can.length ? q.can.map((f) => `${esc(f.host)} <span class="muted">${esc(f.state)}</span>`).join(", ") : q.needs.length ? "nobody" : "-";
    return `<tr${q.stuck ? ' class="bad"' : ""}><td>${esc(q.job || "-")} <span class="muted">${esc(ciRef(q))}${q.n > 1 ? ` x${q.n}` : ""}</span></td><td class="n">${secs(q.wait)}</td><td class="muted">${esc(q.needs.join(", "))}</td><td class="wrap">${can}</td></tr>`;
  }).join("")}</table>`;
}
const ciHead = (ci) => `${ci.hosts} hosts, ${ci.slots} slots, ${ci.busy} busy, ${ci.queued} queued${ci.queued ? ` (oldest ${secs(ci.oldest)})` : ""}`;

// Main's pass rate leads: a red on the default branch is everyone's problem, while a red gate on
// a work branch is usually the gate doing its job (github_runs_finished's scope label).
function finishedTable(inst) {
  const agg = {};
  const zero = () => ({ ok: 0, bad: 0, can: 0 });
  for (const s of inst.finished || []) {
    const k = `${s.labels.repo}\t${s.labels.workflow}`, a = (agg[k] ||= { repo: s.labels.repo, wf: s.labels.workflow, runs: 0, ok: 0, bad: 0, can: 0, main: zero(), branch: zero() });
    const n = s.value || 0, c = s.labels.conclusion, sc = a[s.labels.scope] || {};
    a.runs += n;
    for (const t of [a, sc]) if (c === "success") t.ok += n; else if (c === "failure" || c === "timed_out") t.bad += n; else if (c === "cancelled") t.can += n;
  }
  const all = Object.values(agg);
  if (!all.length) return { head: "no finished-run series yet", body: "" };
  const sum = (xs) => xs.reduce((x, a) => ({ runs: x.runs + a.runs, ok: x.ok + a.ok, bad: x.bad + a.bad, can: x.can + a.can }), { runs: 0, ok: 0, bad: 0, can: 0 });
  const pass = (a) => (a.ok + a.bad ? a.ok / (a.ok + a.bad) : null);
  const t = sum(all), tm = sum(all.map((a) => ({ runs: 0, ...a.main })));
  const head = `${t.runs} runs, ${pct(pass(t))} pass, main ${pct(pass(tm))}, ${t.bad} failed, ${t.can} cancelled`;
  const bad = all.filter((a) => a.bad + a.can > 0).sort((a, b) => (pass(a.main) ?? 2) - (pass(b.main) ?? 2) || (pass(a) ?? 2) - (pass(b) ?? 2) || b.bad - a.bad);
  const green = all.filter((a) => a.bad + a.can === 0);
  const seg = (a) => `<span class="stack" data-tip="${esc(`${a.repo} ${a.wf}\nmain: ${a.main.ok} passed, ${a.main.bad} failed, ${a.main.can} cancelled\nbranches: ${a.branch.ok} passed, ${a.branch.bad} failed, ${a.branch.can} cancelled`)}">${[[a.ok, "var(--b-done)"], [a.bad, "var(--b-needs)"], [a.can, "var(--c-other)"]].filter(([n]) => n).map(([n, c]) => `<i style="flex:${n};background:${c}"></i>`).join("")}</span>`;
  const cls = (p) => (p == null ? "" : p < 0.7 ? "bad" : p < 0.9 ? "warn" : "");
  const body = (bad.length ? `<table class="tbl"><tr><th data-role="glance">repo</th><th data-role="lead">workflow</th><th></th><th class="n" data-role="glance" data-named>main</th><th class="n">branches</th><th class="n">runs</th><th class="n" data-role="glance" data-named>failed</th><th class="n">cancelled</th></tr>${bad.map((a) => {
    const pm = pass(a.main);
    return `<tr><td>${esc(a.repo)}</td><td class="wrap">${esc(a.wf)}</td><td class="m">${seg(a)}</td><td class="n ${cls(pm)}">${pct(pm)}</td><td class="n muted">${pct(pass(a.branch))}</td><td class="n">${a.runs}</td><td class="n">${a.bad}</td><td class="n">${a.can}</td></tr>`;
  }).join("")}</table>` : "") + (green.length ? `<div class="muted fold">+${green.length} green workflows, ${green.reduce((x, a) => x + a.runs, 0)} runs</div>` : "");
  return { head, body };
}

// Done today. Each row's `hour` label is the start of the hour it finished in, epoch seconds.
// A conclusion that is none of these (skipped, neutral) counts in no column, as in finishedTable.
const CI_OUTCOME = { success: "ok", failure: "bad", timed_out: "bad", cancelled: "can" };
const ciRows = (inst) => (inst.hourly || []).map((s) => ({ hour: +s.labels.hour, scope: s.labels.scope, out: CI_OUTCOME[s.labels.conclusion], n: s.value || 0 }));
const localRows = (inst) => (inst.local_hourly || []).map((s) => ({ hour: +s.labels.hour, out: s.labels.result === "pass" ? "ok" : "bad", n: s.value || 0 }));

function tally(rows) {
  const t = { ok: 0, bad: 0, can: 0 };
  for (const r of rows) if (r.out) t[r.out] += r.n;
  return t;
}
const passOf = (t) => (t.ok + t.bad ? t.ok / (t.ok + t.bad) : null);
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

// The CI runners section: the machines and queue of hub_core::ci, then the 24h pass rates with
// the green workflows as one line, one fold for the day's tiles and the queues by pool, and a
// line to the runs themselves: Releases' Builds section (hub_core::builds) lists every CI run.
function ciSection(cc, inst, t1, ci) {
  const failed = failedCount(inst), fin = finishedTable(inst);
  const green = !ci.busy && !ci.queued && !failed;
  let html = `<h2 class="sec" id="sec-ci">CI runners <span class="muted">${esc(ciHead(ci))}${failed ? `, failed 24h ${failed}` : green ? `; green: nothing queued or failed in 24h; ${esc(fin.head)}` : ""}</span></h2>`;
  // A queued job no online runner can take: hub_core::ci words the line, once for both surfaces.
  if (ci.red.length) html += `<div class="panel down">${ci.red.map((r) => `<div class="pr"><span class="chip sm" style="--c:var(--b-needs)">RED</span><span class="pt">${esc(r)}</span></div>`).join("")}</div>`;
  const run = runnersTable(ci);
  if (run) html += `<div class="panel scroll">${run}</div>`;
  if (ci.queue.length) html += `<h3 class="sec">Queued</h3><div class="panel scroll">${queuedTable(ci)}</div>`;
  if (failed) html += `<h3 class="sec">Failed, last 24h</h3>${failedList(inst)}`;
  // Workflows with a failure or a cancel get a row; the green ones are one line under them.
  if (fin.body) html += `<h3 class="sec">Finished 24h <span class="muted">${esc(fin.head)}</span></h3><div class="panel scroll">${fin.body}</div>`;
  const open = secOpen(ist.open, "ci-more") ? " open" : "";
  html += `<details class="sec-d" data-k="ci-more"${open}><summary class="muted fold">Done today, queues by pool</summary>` +
    doneToday(inst, t1) +
    `<h3 class="sec">Queues by pool</h3><div class="panel scroll">${queuesTable(cc)}</div></details>`;
  return html + `<div class="cline">Runs: every CI run is on <a href="#releases/builds">Releases, Builds</a></div>`;
}

// The Cloud runners card: each host the governor powers (its ci_governor_power_* series), with
// buttons that hold it on or off for a while or hand it back. POST /api/cloud-runner writes the
// governor's override ConfigMap; the pod sees the change within about two minutes.
const CLOUD_ACTS = [["on", 2, "On 2h"], ["off", 6, "Off 6h"], ["clear", 0, "Clear"]];
const POWER_COLOR = { running: "var(--b-working)", starting: "var(--b-working)", draining: "var(--b-stalled)", stopping: "var(--b-stalled)" };
// The button armed by a first click ("host:action"), and the last answer.
const cst = { armed: "", msg: "", hist: {} };
// Rows of an opened history shown before "+N older".
const HIST_ROWS = 30;

function cloudHosts(inst) {
  const by = {};
  const KEYS = { hours_today: "hours", max_hours_day: "max", usd_per_hour: "rate", idle_seconds: "idle", idle_off_seconds: "idleOff",
    want: "want", start_min_excess: "excess", held_seconds: "held", start_after_seconds: "holdFor" };
  for (const s of inst.power || []) {
    const l = s.labels, h = (by[l.host] ||= { host: l.host }), k = l.__name__.replace("ci_governor_power_", "");
    if (k === "state") { h.state = l.state; h.reason = l.reason; }
    else if (k === "override") { h.override = l.action; h.until = s.value; }
    else if (k === "last_change") { h.changed = l.action; h.changedAt = s.value; }
    else if (KEYS[k]) h[KEYS[k]] = s.value;
  }
  return Object.values(by).sort((a, b) => a.host.localeCompare(b.host));
}

const mins = (s) => Math.floor((s || 0) / 60);

// Where the governor's power rule stands for a host, from its own numbers (governor.py decide()).
function ruleText(h) {
  if (h.override === "on") return `held on by the button until ${when(h.until)}`;
  if (h.override === "off") return `held off by the button until ${when(h.until)}`;
  const capped = h.max && h.hours >= h.max;
  if (h.state === "starting") return "booting: its slots count once their runners are online";
  if (h.state === "stopping") return "stopping";
  if (h.state === "draining") return capped ? `${h.max} h used today: stops once no slot is busy` : "stops once no slot is busy";
  if (h.state === "running") return h.idle < 60 ? "busy" : `idle ${mins(h.idle)} of ${mins(h.idleOff)} min, then stops`;
  if (capped) return `${h.max} h used today: no start until 00:00 UTC`;
  if (h.held > 0) return `${h.want} jobs past the home hosts, held ${mins(h.held)} of ${mins(h.holdFor)} min, then starts`;
  return h.want ? `${h.want} job${h.want === 1 ? "" : "s"} past the home hosts, starts at ${h.excess}` : `no job past the home hosts; starts at ${h.excess ?? "?"}`;
}

// The governor's other series: per host and global, by metric name.
function governorIndex(inst) {
  const g = { host: {}, alerts: [], actions: [], usd: {} };
  for (const s of inst.governor || []) {
    const l = s.labels, n = l.__name__.replace("ci_governor_", "");
    if (l.host) {
      const h = (g.host[l.host] ||= { host: l.host });
      if (n === "decision") { h.verdict = l.verdict; h.action = l.action; } else h[n] = s.value;
    } else if (n === "budget_usd") g.usd[l.kind] = s.value;
    else if (n === "budget_alert") g.alerts.push([l.basis, Number(l.usd)]);
    else if (n === "budget_action_usd") g.actions.push([l.type, l.status, s.value]);
    else g[n] = s.value;
  }
  return g;
}

// [150, 100, 100] -> "$100 and $150"
const usdList = (xs) => [...new Set(xs)].sort((a, b) => a - b).map((x) => "$" + x).join(" and ");

// The month as AWS Budgets last gave it, and what happens at each line.
function budgetLines(g) {
  if (g.budget_ok == null) return "";
  const u = g.usd;
  if (u.limit == null) return `<div class="muted">Month: the governor has not read the AWS budget yet${g.budget_ok ? "" : ' (its last read failed: runbook, "budget read")'}.</div>`;
  // AWS forecasts from history; on a new account it can sit below what is already spent.
  const fc = u.forecast == null || u.forecast < u.actual ? "no AWS forecast yet" : `forecast ${usd(u.forecast)}`;
  const stale = g.budget_ok ? "" : ` <span class="chip sm" style="--c:var(--b-stalled)">READ FAILED</span>`;
  const month = `<div class="month"><span>Month: <b>${usd(u.actual)}</b> of ${usd(u.limit)}, ${fc}</span><span class="m">${meter(u.limit ? u.actual / u.limit : 0, u.actual >= u.limit * 0.75 ? "var(--b-stalled)" : "var(--c2)")}</span><span class="muted">AWS Budgets, as of ${when(g.budget_updated)}${stale}</span></div>`;
  const act = g.alerts.filter(([b]) => b === "actual").map(([, v]) => v), fore = g.alerts.filter(([b]) => b === "forecasted").map(([, v]) => v);
  const mails = act.length ? `Emails at ${usdList(act)}${usdList(fore) === usdList(act) ? " (spent or forecast)" : fore.length ? `, forecast at ${usdList(fore)}` : ""}` : "";
  const stops = [...new Set(g.actions.map(([, , v]) => v))].map((v) => {
    const fired = g.actions.filter(([, st, x]) => x === v && st !== "STANDBY");
    return `at $${v} AWS stops it and blocks starts${fired.length ? ` <span class="chip sm" style="--c:var(--b-needs)">${esc(fired.map(([, st]) => st).join(", "))}</span> (undo: runbook, "Budget stop")` : ""}`;
  });
  const lines = [mails, ...stops].filter(Boolean).join("; ");
  return month + (lines ? `<div class="muted">${lines}. Each day stops at its hour cap.</div>` : "");
}

function cloudCard(inst) {
  const hosts = cloudHosts(inst), g = governorIndex(inst);
  if (!hosts.length) return "";
  const rows = hosts.map((h) => {
    const btns = CLOUD_ACTS.map(([a, n, label]) => {
      const k = `${h.host}:${a}`;
      return `<button class="btn sm" data-cloud="${esc(k)}" data-hours="${n}">${cst.armed === k ? `Click again: ${label}` : label}</button>`;
    }).join(" ");
    const over = h.override && h.override !== "none" ? `${esc(h.override)} until ${when(h.until)}` : "none";
    const why = h.reason && h.reason !== "none" ? h.reason : "";
    const last = h.changedAt ? `${esc(h.changed)} ${when(h.changedAt)}${why ? ` (${esc(why)})` : ""}` : why ? esc(why) : "-";
    const cost = h.rate != null ? ` ~${usd((h.hours || 0) * h.rate)}` : "";
    return `<tr><td>${esc(h.host)}</td><td><span class="chip sm" style="--c:${POWER_COLOR[h.state] || "var(--c-other)"}">${esc((h.state || "?").toUpperCase())}</span></td><td class="wrap">${esc(ruleText(h))}</td><td class="muted">${last}</td><td class="m">${meter(h.max ? (h.hours || 0) / h.max : 0, "var(--c2)")}</td><td class="n">${(h.hours || 0).toFixed(1)}/${h.max ?? "?"} h${cost}</td><td>${over}</td><td>${btns} <button class="btn sm" data-hist="${esc(h.host)}">${cst.hist[h.host] ? "Hide 7 days" : "7 days"}</button></td></tr>${histRow(h.host)}`;
  }).join("");
  return `<h2 class="sec" id="sec-cloud">Cloud runners <span class="muted">the governor starts them for a deep queue; a button overrides it</span></h2><div class="panel"><div class="scroll"><table class="tbl"><tr><th data-role="lead">host</th><th data-role="glance">state</th><th>rule</th><th>last</th><th></th><th class="n" data-role="glance" data-named>today</th><th>override</th><th></th></tr>${rows}</table></div>${budgetLines(g)}<div class="err">${esc(cst.msg)}</div></div>`;
}

// An opened host's last days (GET /api/cloud-runner/history, hub_core::power_history): hours per
// UTC day, counted from the governor's 2-minute power samples, then each start and stop, newest
// first. Read when opened, then on the board's refresh while it stays open.
function histRow(host) {
  const o = cst.hist[host];
  if (!o) return "";
  let body;
  if (o.err) body = `<div class="err">${esc(o.err)}</div>`;
  else if (!o.data) body = `<div class="muted">Loading...</div>`;
  else {
    const d = o.data, ch = [...d.changes].reverse(), shown = o.all ? ch : ch.slice(0, HIST_ROWS);
    const days = d.days.map((x) => `${esc(x.day.slice(5))} <b>${x.hours.toFixed(1)} h</b>`).join("  ");
    const rows = shown.map((c) => `<tr><td>${esc(stamp(c.at))}</td><td><span class="chip sm" style="--c:${POWER_COLOR[c.state] || "var(--c-other)"}">${esc(c.state.toUpperCase())}</span></td><td class="muted">${esc(c.reason && c.reason !== "none" ? c.reason : "")}</td></tr>`).join("");
    const more = ch.length > shown.length ? `<button class="btn sm" data-hist-all="${esc(host)}">+${ch.length - shown.length} older</button>` : "";
    body = `<div>Run per UTC day: ${days || "no samples"} <span class="muted">(counted from ${d.step / 60}-minute samples of the governor's power state)</span></div><table class="tbl"><tr><th data-role="lead">from</th><th data-role="glance">state</th><th>why</th></tr>${rows}</table>${more}`;
  }
  return `<tr><td colspan="8">${body}</td></tr>`;
}

async function loadHist(host) {
  const o = cst.hist[host];
  try { o.data = await api(`/api/cloud-runner/history?host=${encodeURIComponent(host)}`); o.err = null; }
  catch (e) { o.err = `${host}: ${e.message}`; }
  if (st.tab === "infra") renderInfra();
}

// The governor (home-config apps/ci-runner-governor) per host: whether it acts for real, this
// cycle's verdict and action, and the slots it lets take jobs.
const ACTION_COLOR = { withhold: "var(--b-stalled)", stop: "var(--b-stalled)", admit: "var(--b-working)", start: "var(--b-working)" };
function governorPanel(inst) {
  const g = governorIndex(inst), hosts = Object.values(g.host).sort((a, b) => a.host.localeCompare(b.host));
  if (g.up == null && !hosts.length) return "";
  const health = g.up !== 1 ? `<span class="chip sm" style="--c:var(--b-needs)">DOWN</span>`
    : g.ok === 1 ? `<span class="chip sm" style="--c:var(--b-done)">OK</span>` : `<span class="chip sm" style="--c:var(--b-stalled)">BLIND</span> a source did not answer this cycle, so it holds every host;`;
  const rows = hosts.map((h) => `<tr><td>${esc(h.host)}</td><td>${h.live === 1 ? "live" : '<span class="muted">dry run</span>'}</td><td>${esc(h.verdict || "-")}</td><td><span class="chip sm" style="--c:${ACTION_COLOR[h.action] || "var(--c-other)"}">${esc((h.action || "-").toUpperCase())}</span></td><td class="n">${h.admitted ?? "-"}</td></tr>`).join("");
  return `<h2 class="sec" id="sec-governor">Governor <span class="muted">${health} queue ${g.queue ?? "?"}; a dry-run host is logged, never changed</span></h2><div class="panel scroll"><table class="tbl"><tr><th data-role="lead">host</th><th data-role="glance">mode</th><th data-role="glance">verdict</th><th data-role="glance">action</th><th class="n">admitted</th></tr>${rows}</table></div>`;
}

async function cloudAct(key, hours) {
  const i = key.lastIndexOf(":"), host = key.slice(0, i), action = key.slice(i + 1);
  cst.armed = "";
  try { await post("/api/cloud-runner", { host, action, hours }); cst.msg = `${host}: ${action} sent; the governor reads it within about 2 minutes.`; }
  catch (e) { cst.msg = `${host}: ${e.message}`; }
  renderInfra();
}

// The page has no confirm dialog to lean on, so a button asks twice; the arm lapses after 4 s.
$("infra").addEventListener("click", (e) => {
  const go = e.target.closest("[data-go]");
  if (go) { e.preventDefault(); setTab(go.dataset.go); return; }
  const hb = e.target.closest("[data-hist]");
  if (hb) {
    const h = hb.dataset.hist;
    if (cst.hist[h]) delete cst.hist[h]; else { cst.hist[h] = { data: null, err: null, all: false }; loadHist(h); }
    renderInfra();
    return;
  }
  const ha = e.target.closest("[data-hist-all]");
  if (ha) { const o = cst.hist[ha.dataset.histAll]; if (o) o.all = true; renderInfra(); return; }
  const b = e.target.closest("[data-cloud]");
  if (!b) return;
  const k = b.dataset.cloud;
  if (cst.armed === k) { cloudAct(k, Number(b.dataset.hours)); return; }
  cst.armed = k;
  renderInfra();
  setTimeout(() => { if (cst.armed === k) { cst.armed = ""; renderInfra(); } }, 4000);
});

function renderInfra() {
  const el = $("infra-main"), tail = $("infra-tail");
  const d = ist.data;
  // The strip comes first on every path, then each section in its inner tab's group
  // (hub_core::layout, app.js INNER_TABS). Jobs is its own element between main and the tail.
  innerHide("infra", "jobs", $("jobs"));
  const strip = innerStrip("infra", infraFlagged(d));
  if (!d) { el.innerHTML = strip + `<div class="empty">${ist.err ? esc(ist.err) : "Loading..."}</div>`; tail.innerHTML = ""; return; }
  const links = `${gLink("kb-command-center", "Command Center")} ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-fleet", "Machines")} ${gLink("kb-agents-overview", "Agents")}`;
  // As the board blanks: a failed read never leaves the last (maybe green) numbers up.
  if (!d.ok) { el.innerHTML = strip + `<div class="bhead"><span>infra</span><span>${links}</span></div><div class="panel down">${esc(d.error || "Prometheus did not answer")}</div>`; tail.innerHTML = ""; seekSection(); return; }
  const cc = ccIndex(d.instant.cc), inst = d.instant, t1 = d.at * 1e3;
  const overall = (cc["cc:overall_status"] || {})[""];
  const [word, color] = statusOf(overall);
  // Home owns the asks; Infra shows their count as a badge that opens Home.
  const asks = (cc["cc:asks_open"] || {})[""];
  const badge = asks > 0 ? ` <a href="#home" class="chip sm" data-go="home" style="--c:var(--b-needs)">${asks} ask${asks === 1 ? "" : "s"} on Home</a>` : "";
  let html = strip + `<div class="bhead"><span><span class="chip" style="--c:${color}">OVERALL ${word}</span>${badge} <span class="muted">read ${clock(t1)}</span></span>${pfold("infra-links", "Grafana", links)}</div>`;
  html += innerWrap("infra", "machines", `${kpis(cc)}<h2 class="sec" id="sec-machines">Machines</h2><div class="panel scroll">${machinesTable(cc, inst)}</div>`);
  html += innerWrap("infra", "governor", governorPanel(inst));
  html += innerWrap("infra", "ci", ciSection(cc, inst, t1, d.ci));
  paint(el, html, ist.open);
  paint(tail, innerWrap("infra", "cloud", cloudCard(inst)));
  seekSection();
}

// The sections whose inner tab carries a count: CI lines hub_core::ci judged red (a queued job no
// online runner can take); the hub's App::infra_flagged reads the same.
const infraFlagged = (d) => (d && d.ci && (d.ci.red || []).length ? ["ci"] : []);

const pollInfra = poll("infra", refreshInfra, INFRA_REFRESH_MS);

TABS.infra = {
  // The Jobs section (jobs.js) reads its own source on its own timer.
  show() { renderInfra(); pollInfra(); jst.render(); pollJobs(); },
  // Nothing on this machine changes Prometheus, so file events do not apply; only a resync does.
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "infra") { refreshInfra(); jst.refresh(); } },
};
