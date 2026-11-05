"use strict";
// The Infra tab: the hub board's infra pages (`hub` Home's lower half, CI, Machines) for the browser. /api/infra
// asks Prometheus the board's own queries; statuses are the cc:* rules, so nothing is judged here.

// Prometheus has no push to a browser, so the open tab re-reads on the board's cadence
// (REFRESH_SECS=60): the rules evaluate every minute, and faster only redraws the same numbers.
const INFRA_REFRESH_MS = 60e3;
// A job running past this shows amber: playground ci.md calls a gate past about an hour a bug.
const LONG_RUN_SECS = 3600;
const DOMAINS = ["k3s", "machines", "ci", "prod", "llm", "agents", "spend", "platform", "queue", "home", "other"];
// A day's failures start folded per group past this many rows, as the Log tab folds a busy day.
const FAILED_OPEN = 25;
// Each failed group's folded state, which outlives the re-render on every refresh.
const ist = { data: null, err: null, open: {} };
// Recent runs shown before the rest fold away.
const RECENT_OPEN = 30;

const refreshInfra = coalesce(async () => {
  try { ist.data = await api("/api/infra"); ist.err = null; } catch (e) { ist.err = e.message; }
  if (st.tab === "infra") renderInfra();
});

// Status as the cc:* rules give it: 0 ok, 1 warn, 2 red, anything else no data. The colour
// always comes with its word.
const STATUS = [["OK", "var(--b-done)"], ["WARN", "var(--b-stalled)"], ["RED", "var(--b-needs)"]];
const statusOf = (v) => STATUS[v] || ["NO DATA", "var(--b-unclear)"];
const statusColor = (v) => statusOf(v)[1];

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
  const lazer = [one("cc:lazer_spend_usd"), one("cc:lazer_budget_usd")];
  const ok = (a, b) => (a != null && a === b ? "var(--b-done)" : "var(--b-needs)");
  return `<div class="tiles roomy">${
    tile("NODES", `${nodes[0] ?? "?"}/${nodes[1] ?? "?"}`, ok(nodes[0], nodes[1]))}${
    tile("HEARTBEATS", `${beats[0] ?? "?"}/${beats[1] ?? "?"}`, ok(beats[0], beats[1]))}${
    tile("CI BUSY", `${busy}/${slots}`, "var(--c1)", `${where}, ${waiting} waiting`)}${
    tile("RUNNERS", `${one("cc:runners_failed") ?? "?"} failed`, one("cc:runners_failed") ? "var(--b-needs)" : "var(--b-done)", `of ${one("cc:runners_total") ?? "?"}`)}${
    tile("WATCHES", `${one("cc:watches_tripped") ?? "?"} tripped`, one("cc:watches_tripped") ? "var(--b-stalled)" : "var(--b-done)", `of ${one("cc:watches_total") ?? "?"}, ${one("cc:watches_stale") ?? 0} stale`)}${
    tile("LAZER", usd(lazer[0]), "var(--c2)", `${meter(lazer[1] ? lazer[0] / lazer[1] : 0, "var(--c2)")} of ${usd(lazer[1])}`)}${
    tile("CLAUDE 24H", usd(one("cc:claude_code_cost_24h_usd")), "var(--c2)")}${
    tile("SESSIONS", `${one("cc:sessions_working") ?? "?"}/${one("cc:sessions_total") ?? "?"}`, "var(--b-working)", `working, ${one("cc:sessions_attention") ?? 0} need you`)}</div>`;
}

function domainTiles(cc) {
  const dom = cc["cc:domain_status"] || {}, comp = cc["cc:component_status"] || {};
  return `<div class="tiles roomy">${DOMAINS.filter((d) => d in dom || d === "k3s" || d === "ci").map((d) => {
    const [word, c] = statusOf(dom[d]);
    const bad = Object.entries(comp).filter(([k, v]) => k.startsWith(d + "/") && v > 0).map(([k, v]) => `${k.slice(d.length + 1)} ${statusOf(v)[0].toLowerCase()}`);
    return `<div class="tile" style="--c:${c}"><span class="tl">${esc(d.toUpperCase())}</span><span class="tv sm">${word}</span>${bad.length ? `<span class="ts1">${esc(bad.join(", "))}</span>` : ""}</div>`;
  }).join("")}</div>`;
}

// Pools with slots or a queue, the longest queue first.
const poolOrder = (cc) => [...new Set([...Object.keys(cc["cc:pool_slots"] || {}), ...Object.keys(cc["cc:pool_waiting"] || {})])]
  .sort((a, b) => ((cc["cc:pool_waiting"] || {})[b] || 0) - ((cc["cc:pool_waiting"] || {})[a] || 0) || a.localeCompare(b));

function poolsTable(cc, inst) {
  const on = {}, ri = runnerIndex(inst);
  for (const r of inst.runners || []) if (isOnline(r, ri)) ((on[r.labels.pool] ||= {})[r.labels.host] = (on[r.labels.pool][r.labels.host] || 0) + 1);
  const pools = poolOrder(cc);
  const g = (n, p) => (cc[n] || {})[p];
  const row = (p, busy, slots, waiting, oldest, done, pass, hosts, room, held) => `<tr><td>${esc(p)}</td><td class="m">${meter(slots ? busy / slots : 0, "var(--c1)")}</td><td class="n">${busy ?? "-"}/${slots ?? "-"}${room > 0 ? `+${room}` : ""}${held > 0 ? ` <span class="muted">+${held} held</span>` : ""}</td><td class="n${waiting ? " warn" : ""}">${waiting ?? "-"}</td><td class="n">${secs(oldest)}</td><td class="n">${done ?? "-"}</td><td class="n ${pass == null ? "" : pass < 0.7 ? "bad" : pass < 0.9 ? "warn" : ""}">${pct(pass)}</td><td class="muted">${esc(hosts)}</td></tr>`;
  let rows = pools.map((p) => row(p, g("cc:pool_busy", p), g("cc:pool_slots", p), g("cc:pool_waiting", p), g("cc:pool_oldest_wait_seconds", p), g("cc:pool_done_24h", p), g("cc:pool_pass_ratio_24h", p),
    Object.entries(on[p] || {}).map(([h, n]) => (n > 1 ? `${h}:${n}` : h)).join(" "), 0, g("cc:pool_withheld", p))).join("");
  for (const h of Object.keys(cc["cc:host_local_slots"] || {})) rows += row("unity-local", g("cc:host_local_busy", h), g("cc:host_local_open_slots", h), g("cc:host_local_queued", h), null, g("cc:host_local_done_24h", h), g("cc:host_local_pass_ratio_24h", h), h, g("cc:host_local_slots", h) - g("cc:host_local_open_slots", h));
  for (const p of Object.keys(cc["cc:pool_done_24h"] || {}).filter((p) => !pools.includes(p))) rows += row(p, null, null, null, null, g("cc:pool_done_24h", p), g("cc:pool_pass_ratio_24h", p), "");
  return `<table class="tbl"><tr><th>pool</th><th></th><th class="n">busy</th><th class="n">waiting</th><th class="n">oldest</th><th class="n">done 24h</th><th class="n">pass</th><th>on</th></tr>${rows}</table>`;
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
// Online means it can take a job: running, or idle and not withheld (the cc:pool_slots rule).
const isOnline = (r, ri) => r.labels.state === "running" || (r.labels.state === "idle" && !(ri[r.labels.name] || {}).held);

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

// The hub Home's machine rollup, shaped like the Pools table: one row per machine that carries CI,
// the busiest first.
function machineSlotsTable(cc, inst) {
  const rows = machineSlots(cc, inst).filter((m) => m.slots || m.busy || m.pools.length).sort((a, b) => b.busy - a.busy || a.host.localeCompare(b.host));
  if (!rows.length) return '<div class="empty">No CI slot up.</div>';
  return `<table class="tbl"><tr><th>machine</th><th>where</th><th></th><th class="n">busy</th><th>pools</th></tr>${rows.map((m) =>
    `<tr><td>${esc(m.host)}</td><td class="muted">${whereCell(m)}</td><td class="m">${meter(m.slots ? m.busy / m.slots : 0, "var(--c1)")}</td><td class="n"${m.cpu.length ? ` title="${esc(cpuTitle(m))}"` : ""}>${busyCell(m)}</td><td class="wrap">${esc(m.pools.join("  ") || "-")}${m.off ? ` <span class="bad">+${m.off} off</span>` : ""}</td></tr>`).join("")}</table>`;
}

function machinesTable(cc, inst) {
  const g = (n, h) => (cc[n] || {})[h];
  const cores = {};
  for (const s of inst.cores || []) (cores[s.labels.host] ||= []).push([s.labels.cpu, s.value]);
  const num = (c) => c.split(",").map(Number);
  for (const c of Object.values(cores)) c.sort(([a], [b]) => { const [x, y] = [num(a), num(b)]; return x[0] - y[0] || (x[1] || 0) - (y[1] || 0); });
  const ci = Object.fromEntries(machineSlots(cc, inst).map((m) => [m.host, m]));
  const carries = (h) => !!(ci[h] && (ci[h].slots || ci[h].pools.length));
  // Machines that carry CI first, then the busiest.
  const hosts = Object.keys(cc["cc:host_cores"] || {}).sort((a, b) => carries(b) - carries(a) || (g("cc:host_cpu_busy_ratio", b) || 0) - (g("cc:host_cpu_busy_ratio", a) || 0));
  return `<table class="tbl"><tr><th>machine</th><th>where</th><th class="n">busy</th><th>cpu (per core)</th><th class="n">now</th><th class="n">6h</th><th class="n">load</th><th>mem</th><th class="n"></th><th class="n">temp</th><th>pools</th></tr>${hosts.map((h) => {
    const cpu = g("cc:host_cpu_busy_ratio", h), mem = g("cc:host_mem_used_ratio", h), temp = g("cc:host_temp_c", h), load = g("cc:host_load1", h), n = g("cc:host_cores", h), m = ci[h];
    return `<tr><td>${esc(h)}</td><td class="muted">${m ? whereCell(m) : "local"}</td><td class="n${m && m.off ? " warn" : ""}"${m && m.cpu.length ? ` title="${esc(cpuTitle(m))}"` : ""}>${m ? busyCell(m) : "-"}${m && m.off ? ` +${m.off} off` : ""}</td><td class="m">${cores[h] ? coreStrip(cores[h]) : meter(cpu, cpu > 0.9 ? "var(--b-stalled)" : "var(--c1)")}</td><td class="n">${pct(cpu)}</td><td class="n">${pct(g("cc:host_cpu_busy_ratio:avg6h", h))}</td><td class="n${load > n * 1.5 ? " warn" : ""}">${load == null ? "-" : load.toFixed(1)}/${n ?? "?"}</td><td class="m">${meter(mem, mem > 0.9 ? "var(--b-stalled)" : "var(--c3)")}</td><td class="n">${pct(mem)}</td><td class="n${temp > 85 ? " warn" : ""}">${temp == null ? "-" : Math.round(temp) + "C"}</td><td class="muted wrap">${esc(m ? m.pools.join("  ") : "")}</td></tr>`;
  }).join("")}</table>`;
}

// The CI section's running jobs, grouped by machine (the most jobs first, each group longest
// first): the group row carries the machine and its busy/slots, so pool and host columns go.
// A job using more than half its machine's cores shows amber: one job starving the rest.
function runningTable(cc, inst) {
  const ri = runnerIndex(inst), hostCores = cc["cc:host_cores"] || {};
  const prBy = {};
  for (const r of [...(inst.runners || []), ...(inst.waiting || [])]) if (r.labels.pr && r.labels.pr !== "") prBy[`${r.labels.repo}/${r.labels.branch}`] = r.labels.pr;
  const by = {};
  for (const r of (inst.runners || []).filter((r) => r.labels.state === "running")) {
    const l = r.labels;
    (by[l.host || "-"] ||= []).push({ v: r.value, name: l.name, repo: l.repo, pr: l.pr, job: l.job_name, detail: l.title && l.title !== l.workflow ? l.title : l.branch });
  }
  // A machine that is not a runner runs its gates locally: the PR from a runner or queue row on
  // the same branch.
  for (const r of inst.gates || []) {
    const l = r.labels, repo = l.repo || l.worktree;
    (by[l.host || "-"] ||= []).push({ v: r.value, repo, pr: prBy[`${repo}/${l.branch}`], job: `${l.platform} (local)`, detail: l.branch });
  }
  const groups = Object.entries(by).sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]));
  const jobs = groups.reduce((x, [, js]) => x + js.length, 0);
  if (!jobs) return { head: "nothing", body: '<div class="empty">Nothing running.</div>' };
  const ci = Object.fromEntries(machineSlots(cc, inst).map((m) => [m.host, m]));
  const body = `<table class="tbl"><tr><th>PR</th><th>job</th><th class="n">for</th><th class="n">cores</th><th>PR title or branch</th></tr>${groups.map(([host, js]) =>
    `<tr class="hgrp"><td colspan="5">${esc(host)} <span class="muted">${ci[host] ? `${whereCell(ci[host])}, ${busyCell(ci[host])} busy` : ""}</span></td></tr>${js.sort((a, b) => (b.v || 0) - (a.v || 0)).map((r) => {
      const c = ri[r.name] || {}, n = hostCores[host];
      const cores = c.busy == null ? "-" : `${c.busy.toFixed(1)}/${c.allowed ?? n ?? "?"}`;
      return `<tr><td>${esc(r.repo || "-")}${r.pr ? "#" + esc(r.pr) : ""}</td><td>${esc(r.job || "-")}</td><td class="n${r.v > LONG_RUN_SECS ? " warn" : ""}">${secs(r.v)}</td><td class="n${c.busy > n / 2 ? " warn" : ""}"${c.allowed ? ` title="pinned to ${c.allowed} CPUs of ${n ?? "?"}"` : ""}>${cores}</td><td class="wrap">${esc(r.detail || "-")}</td></tr>`;
    }).join("")}`).join("")}</table>`;
  return { head: `${jobs} job${jobs === 1 ? "" : "s"}`, body };
}

function queuedTable(inst) {
  const groups = {};
  for (const r of (inst.waiting || []).filter((r) => r.labels.stuck !== "true")) {
    const k = [r.labels.pool, r.labels.repo, r.labels.pr, r.labels.branch].join("\t");
    const g = (groups[k] ||= { l: r.labels, n: 0, old: 0 });
    g.n++; g.old = Math.max(g.old, r.value || 0);
  }
  const rows = Object.values(groups).sort((a, b) => b.old - a.old);
  if (!rows.length) return '<div class="empty">Nothing waiting.</div>';
  return `<table class="tbl"><tr><th>pool</th><th>repo</th><th>PR</th><th class="n">jobs</th><th class="n">waiting</th><th>branch</th></tr>${rows.map((g) =>
    `<tr><td>${esc(g.l.pool || "-")}</td><td>${esc(g.l.repo || "-")}</td><td>${g.l.pr ? "#" + esc(g.l.pr) : "-"}</td><td class="n">${g.n}</td><td class="n">${secs(g.old)}</td><td class="wrap">${esc(g.l.branch || "-")}</td></tr>`).join("")}</table>`;
}

// What is red: cc:red_now, the dashboard's table (watches, runners, nodes, feed, Sentinel) plus the
// board's DOWN line (offline runners, stuck runs, the exporter and GitHub).
function redItems(inst) {
  const items = (inst.red || []).map((s) => s.labels.item).filter(Boolean).sort();
  for (const r of inst.runners || []) if (["offline", "missing"].includes(r.labels.state)) items.push(`runner ${r.labels.name} ${r.labels.state}`);
  for (const r of inst.waiting || []) if (r.labels.stuck === "true") items.push(`stuck run: ${r.labels.repo} ${r.labels.branch}, ${secs(r.value)}, no jobs`);
  // The likeliest cause first, as the hub board's DOWN line: a missed scrape (exporter_up 0 or
  // absent) blanks every exporter series, a spent rate limit leaves jobs and history unread,
  // and api counts only the runner sources, so one repo's failed run list says nothing here.
  const v = (q) => ((inst[q] || [])[0] || {}).value;
  if (v("exporter_up") !== 1) items.unshift("runner exporter missed its last scrape: runner rows may be missing");
  else if (v("rate_left") === 0) items.unshift("GitHub rate limit spent: runner jobs and history unread until it resets");
  else if (v("api") !== 1) items.unshift("GitHub not answering the exporter: runner rows may be missing");
  else if (!(inst.runners || []).length) items.push("no runner series from the exporter");
  return items;
}

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
  const seg = (a) => `<span class="stack" data-tip="${esc(`${a.repo} ${a.wf}\nmain: ${a.main.ok} passed, ${a.main.bad} failed, ${a.main.can} cancelled\nbranches: ${a.branch.ok} passed, ${a.branch.bad} failed, ${a.branch.can} cancelled`)}">${[[a.ok, "var(--b-done)"], [a.bad, "var(--b-needs)"], [a.can, "var(--b-unclear)"]].filter(([n]) => n).map(([n, c]) => `<i style="flex:${n};background:${c}"></i>`).join("")}</span>`;
  const cls = (p) => (p == null ? "" : p < 0.7 ? "bad" : p < 0.9 ? "warn" : "");
  const body = (bad.length ? `<table class="tbl"><tr><th>repo</th><th>workflow</th><th></th><th class="n">main</th><th class="n">branches</th><th class="n">runs</th><th class="n">failed</th><th class="n">cancelled</th></tr>${bad.map((a) => {
    const pm = pass(a.main);
    return `<tr><td>${esc(a.repo)}</td><td class="wrap">${esc(a.wf)}</td><td class="m">${seg(a)}</td><td class="n ${cls(pm)}">${pct(pm)}</td><td class="n muted">${pct(pass(a.branch))}</td><td class="n">${a.runs}</td><td class="n">${a.bad}</td><td class="n">${a.can}</td></tr>`;
  }).join("")}</table>` : "") + (green.length ? `<div class="muted fold">+${green.length} green workflows, ${green.reduce((x, a) => x + a.runs, 0)} runs</div>` : "");
  return { head, body };
}

// Done today. Each row's `hour` label is the start of the hour it finished in, epoch seconds.
// A conclusion that is none of these (skipped, neutral) counts in no column, as in finishedTable.
const CI_OUTCOME = { success: "ok", failure: "bad", timed_out: "bad", cancelled: "can" };
const OUTCOMES = [["ok", "passed", "var(--b-done)"], ["bad", "failed", "var(--b-needs)"], ["can", "cancelled", "var(--b-unclear)"]];
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

function doneToday(inst, t1) {
  const ci = ciRows(inst), local = localRows(inst);
  if (!ci.length && !local.length) return `<h2 class="sec">Done today</h2><div class="panel">No hourly data yet.</div>`;
  const midnight = new Date(t1).setHours(0, 0, 0, 0) / 1e3, today = (r) => r.hour >= midnight;
  const tc = tally(ci.filter(today)), tl = tally(local.filter(today));
  const failed = (scope) => tally(ci.filter((r) => today(r) && r.scope === scope)).bad;
  const onMain = failed("main");
  const tiles = `<div class="tiles roomy">${
    tile("CI RUNS", tc.ok + tc.bad + tc.can, "var(--c1)", `${pct(passOf(tc))} pass`)}${
    tile("FAILED ON MAIN", onMain, onMain ? "var(--b-needs)" : "var(--b-done)")}${
    tile("FAILED ON BRANCHES", failed("branch"), "var(--b-stalled)")}${
    tile("CANCELLED", tc.can, "var(--b-unclear)")}${
    tile("LOCAL UNITY", tl.ok + tl.bad, "var(--c3)", `${pct(passOf(tl))} pass`)}</div>`;
  const note = `Tiles count from midnight; CI is read every 10 minutes. Runs per hour and the 24h status lanes are in Grafana ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-command-center", "Command Center")}.`;
  return `<h2 class="sec">Done today</h2>${tiles}<div class="muted fold">${note}</div>` +
    `<h2 class="sec">Failed, last 24h</h2>${failedList(inst)}`;
}

// The exporter's last runs per repo, newest first: one series per run, valued at when it ended.
function recentTable(inst) {
  const dur = Object.fromEntries((inst.recent_dur || []).map((s) => [s.labels.url, s.value]));
  const runs = (inst.recent || []).filter((s) => s.value).sort((a, b) => b.value - a.value);
  if (!runs.length) return `<div class="panel">No recent-run series (exporter down, or RUN_REPOS empty).</div>`;
  const cls = { success: "", failure: "bad", timed_out: "bad", cancelled: "warn" };
  const row = (s) => {
    const l = s.labels;
    return `<tr><td class="n">${clock(s.value * 1e3)}</td><td>${esc(l.repo)}</td><td class="wrap"><a href="${esc(l.url)}" target="_blank" rel="noopener">${esc(l.workflow)}</a></td><td>${esc(clip(l.branch || "", 28))}</td><td class="muted">${esc(l.event || "")}</td><td class="n">${secs(dur[l.url])}</td><td class="${cls[l.conclusion] ?? "muted"}">${esc(l.conclusion || "-")}</td></tr>`;
  };
  const head = `<tr><th class="n">ended</th><th>repo</th><th>workflow</th><th>branch</th><th>event</th><th class="n">took</th><th>result</th></tr>`;
  const open = runs.slice(0, RECENT_OPEN), rest = runs.slice(RECENT_OPEN);
  return `<div class="panel scroll"><table class="tbl">${head}${open.map(row).join("")}</table>` +
    (rest.length ? `<details class="sec-d" data-k="recent-more"${ist.open["recent-more"] ? " open" : ""}><summary class="muted fold">+${rest.length} older</summary><table class="tbl">${rest.map(row).join("")}</table></details>` : "") + `</div>`;
}

// The Cloud runners card: each host the governor powers (its ci_governor_power_* series), with
// buttons that hold it on or off for a while or hand it back. POST /api/cloud-runner writes the
// governor's override ConfigMap; the pod sees the change within about two minutes.
const CLOUD_ACTS = [["on", 2, "On 2h"], ["off", 6, "Off 6h"], ["clear", 0, "Clear"]];
const POWER_COLOR = { running: "var(--b-working)", starting: "var(--b-working)", draining: "var(--b-stalled)", stopping: "var(--b-stalled)" };
// The button armed by a first click ("host:action"), and the last answer.
const cst = { armed: "", msg: "" };

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
    return `<tr><td>${esc(h.host)}</td><td><span class="chip sm" style="--c:${POWER_COLOR[h.state] || "var(--b-unclear)"}">${esc((h.state || "?").toUpperCase())}</span></td><td class="wrap">${esc(ruleText(h))}</td><td class="muted">${last}</td><td class="m">${meter(h.max ? (h.hours || 0) / h.max : 0, "var(--c2)")}</td><td class="n">${(h.hours || 0).toFixed(1)}/${h.max ?? "?"} h${cost}</td><td>${over}</td><td>${btns}</td></tr>`;
  }).join("");
  return `<h2 class="sec">Cloud runners <span class="muted">the governor starts them for a deep queue; a button overrides it</span></h2><div class="panel"><div class="scroll"><table class="tbl"><tr><th>host</th><th>state</th><th>rule</th><th>last</th><th></th><th class="n">today</th><th>override</th><th></th></tr>${rows}</table></div>${budgetLines(g)}<div class="err">${esc(cst.msg)}</div></div>`;
}

// The governor (home-config apps/ci-runner-governor) per host: whether it acts for real, this
// cycle's verdict and action, and the slots it lets take jobs.
const ACTION_COLOR = { withhold: "var(--b-stalled)", stop: "var(--b-stalled)", admit: "var(--b-working)", start: "var(--b-working)" };
function governorPanel(inst) {
  const g = governorIndex(inst), hosts = Object.values(g.host).sort((a, b) => a.host.localeCompare(b.host));
  if (g.up == null && !hosts.length) return "";
  const health = g.up !== 1 ? `<span class="chip sm" style="--c:var(--b-needs)">DOWN</span>`
    : g.ok === 1 ? `<span class="chip sm" style="--c:var(--b-done)">OK</span>` : `<span class="chip sm" style="--c:var(--b-stalled)">BLIND</span> a source did not answer this cycle, so it holds every host;`;
  const rows = hosts.map((h) => `<tr><td>${esc(h.host)}</td><td>${h.live === 1 ? "live" : '<span class="muted">dry run</span>'}</td><td>${esc(h.verdict || "-")}</td><td><span class="chip sm" style="--c:${ACTION_COLOR[h.action] || "var(--b-unclear)"}">${esc((h.action || "-").toUpperCase())}</span></td><td class="n">${h.admitted ?? "-"}</td></tr>`).join("");
  return `<h2 class="sec">Governor <span class="muted">${health} queue ${g.queue ?? "?"}; a dry-run host is logged, never changed</span></h2><div class="panel scroll"><table class="tbl"><tr><th>host</th><th>mode</th><th>verdict</th><th>action</th><th class="n">admitted</th></tr>${rows}</table></div>`;
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
  const b = e.target.closest("[data-cloud]");
  if (!b) return;
  const k = b.dataset.cloud;
  if (cst.armed === k) { cloudAct(k, Number(b.dataset.hours)); return; }
  cst.armed = k;
  renderInfra();
  setTimeout(() => { if (cst.armed === k) { cst.armed = ""; renderInfra(); } }, 4000);
});

function renderInfra() {
  const el = $("infra");
  const d = ist.data;
  if (!d) { el.innerHTML = `<div class="empty">${ist.err ? esc(ist.err) : "Loading..."}</div>`; return; }
  const links = `${gLink("kb-command-center", "Command Center")} ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-fleet", "Machines")} ${gLink("kb-agents-overview", "Agents")}`;
  // As the board blanks: a failed read never leaves the last (maybe green) numbers up.
  if (!d.ok) { el.innerHTML = `<div class="bhead"><span>infra</span><span>${links}</span></div><div class="panel down">${esc(d.error || "Prometheus did not answer")}</div>`; return; }
  const cc = ccIndex(d.instant.cc), inst = d.instant, t1 = d.at * 1e3;
  const overall = (cc["cc:overall_status"] || {})[""];
  const [word, color] = statusOf(overall);
  const red = redItems(inst);
  const fin = finishedTable(inst), run = runningTable(cc, inst);
  let html = `<div class="bhead"><span><span class="chip" style="--c:${color}">OVERALL ${word}</span> <span class="muted">needs you: ${(cc["cc:asks_open"] || {})[""] ?? "?"} asks, ${(cc["cc:sessions_attention"] || {})[""] ?? "?"} sessions waiting, read ${clock(t1)}</span></span><span>${links}</span></div>`;
  html += domainTiles(cc);
  html += `<div class="sp"></div>` + kpis(cc);
  html += doneToday(inst, t1);
  html += `<h2 class="sec">Red right now <span class="muted">${red.length}</span></h2><div class="panel${red.length ? " down" : ""}">${red.length ? red.map((r) => `<div class="pr"><span class="chip sm" style="--c:var(--b-needs)">RED</span><span class="pt">${esc(r)}</span></div>`).join("") : "Nothing: every rostered runner is registered and online."}</div>`;
  html += cloudCard(inst);
  html += governorPanel(inst);
  html += `<h2 class="sec">Pools</h2><div class="panel scroll">${poolsTable(cc, inst)}</div>`;
  html += `<h2 class="sec">CI by machine</h2><div class="panel scroll">${machineSlotsTable(cc, inst)}</div>`;
  html += `<h2 class="sec">Queued</h2><div class="panel scroll">${queuedTable(inst)}</div>`;
  html += `<h2 class="sec">Running <span class="muted">${esc(run.head)}</span></h2><div class="panel scroll">${run.body}</div>`;
  html += `<h2 class="sec">Recent runs <span class="muted">every job, any source: the Jobs tab</span></h2>${recentTable(inst)}`;
  html += `<h2 class="sec">Machines</h2><div class="panel scroll">${machinesTable(cc, inst)}</div>`;
  html += `<h2 class="sec">Finished 24h <span class="muted">${esc(fin.head)}</span></h2>${fin.body ? `<div class="panel scroll">${fin.body}</div>` : ""}`;
  paint(el, html, ist.open);
}

const pollInfra = poll("infra", refreshInfra, INFRA_REFRESH_MS);

TABS.infra = {
  show() { renderInfra(); pollInfra(); },
  // Nothing on this machine changes Prometheus, so file events do not apply; only a resync does.
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "infra") refreshInfra(); },
};
