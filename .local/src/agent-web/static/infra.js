"use strict";
// The Infra tab: the hub:infra board (`command-center.sh`, Prefix e) for the browser. /api/infra
// asks Prometheus the board's own queries; statuses are the cc:* rules, so nothing is judged here.

// Prometheus has no push to a browser, so the open tab re-reads on the board's cadence
// (REFRESH_SECS=60): the rules evaluate every minute, and faster only redraws the same numbers.
const INFRA_REFRESH_MS = 60e3;
// A job running past this shows amber: playground ci.md calls a gate past about an hour a bug.
const LONG_RUN_SECS = 3600;
const DOMAINS = ["k3s", "machines", "ci", "prod", "llm", "agents", "spend", "platform", "other"];
const ist = { data: null, err: null, timer: null };

const refreshInfra = coalesce(async () => {
  try { ist.data = await api("/api/infra"); ist.err = null; } catch (e) { ist.err = e.message; }
  if (st.tab === "infra") renderInfra();
});

function infraTick() {
  if (st.tab !== "infra") { clearInterval(ist.timer); ist.timer = null; return; }
  if (!document.hidden) refreshInfra();
}

// Status as the cc:* rules give it: 0 ok, 1 warn, 2 red, anything else no data. The colour
// always comes with its word.
const STATUS = [["OK", "var(--b-done)"], ["WARN", "var(--b-stalled)"], ["RED", "var(--b-needs)"]];
const statusOf = (v) => STATUS[v] || ["NO DATA", "var(--b-unclear)"];
const statusColor = (v) => statusOf(v)[1];

// cc: "cc:pool_busy" -> {unity: 4, ...} by the given label, or the bare value with no label.
function ccIndex(series) {
  const by = {};
  for (const s of series || []) {
    const l = s.labels, key = l.domain && l.__name__ === "cc:domain_status" ? l.domain : l.pool || l.host || l.component && `${l.domain}/${l.component}`;
    (by[l.__name__] ||= {});
    if (key) by[l.__name__][key] = s.value; else by[l.__name__][""] = s.value;
  }
  return by;
}

const pct = (v) => (v == null ? "-" : Math.round(v * 100) + "%");
const secs = (s) => (s == null || !(s > 0) ? "-" : s < 60 ? Math.round(s) + "s" : dur(s / 60));
const grafanaBase = () => ((ist.data && ist.data.grafana) || "").replace(/\/d\/.*$/, "");
const gLink = (uid, text) => grafanaBase() ? `<a class="glink" href="${esc(grafanaBase())}/d/${uid}" target="_blank" rel="noopener">${esc(text)} &rarr;</a>` : "";

function statusStrip(range, t0, t1) {
  const lanes = [];
  const segs = (pts) => {
    const out = [];
    for (let i = 0; i < pts.length; i++) {
      const [t, v] = pts[i], b = i + 1 < pts.length ? pts[i + 1][0] : t1 / 1e3;
      const last = out[out.length - 1];
      if (last && last.key === v && last.b === t * 1e3) last.b = b * 1e3;
      else out.push({ a: t * 1e3, b: b * 1e3, key: v });
    }
    return out.map((s) => ({ ...s, title: `${statusOf(s.key)[0]} ${clock(s.a)}-${clock(s.b)}` }));
  };
  for (const s of range.overall || []) lanes.push({ label: "overall", segs: segs(s.points) });
  const by = Object.fromEntries((range.domains || []).map((s) => [s.labels.domain, s.points]));
  for (const d of [...DOMAINS, ...Object.keys(by).filter((d) => !DOMAINS.includes(d))]) if (by[d]) lanes.push({ label: d, segs: segs(by[d]) });
  return lanes.length ? swimlanes(lanes, t0, t1, statusColor) : '<div class="empty">No status history.</div>';
}

// Range points folded into fixed buckets (the largest value in each), so a day is a readable
// number of columns.
function buckets(points, t0, t1, n) {
  const w = (t1 - t0) / n, out = Array(n).fill(null);
  for (const [t, v] of points) {
    const i = Math.min(n - 1, Math.floor((t * 1e3 - t0) / w));
    if (i >= 0) out[i] = Math.max(out[i] ?? 0, v);
  }
  return out;
}

function queueChart(range, t0, t1) {
  const N = 48, series = range.queue || [];
  if (!series.length) return '<div class="empty">No queue history.</div>';
  const tot = series.map((s) => [s.labels.pool || "?", s.points.reduce((a, p) => a + p[1], 0), buckets(s.points, t0, t1, N)]).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  const top = tot.slice(0, 3), rest = tot.slice(3);
  const cols = Array.from({ length: N }, (_, i) => {
    const at = t0 + (i + 0.5) * ((t1 - t0) / N);
    const segs = top.map(([, , b], k) => ({ v: b[i] || 0, color: SLOTS[k] }));
    const other = rest.reduce((a, [, , b]) => a + (b[i] || 0), 0);
    if (rest.length) segs.push({ v: other, color: OTHER });
    const d = new Date(at);
    return {
      key: "q" + i, label: d.getMinutes() < 30 && d.getHours() % 6 === 0 ? clock(at) : "",
      tip: `${clock(at)} waiting\n` + top.map(([p, , b]) => `${p} ${b[i] ?? 0}`).join("\n") + (rest.length ? `\nother ${other}` : ""),
      segs,
    };
  });
  return `<h3>Jobs waiting, 24h ${legend([...top.map(([p], k) => [p, SLOTS[k]]), ...(rest.length ? [["Other", OTHER]] : [])])}</h3>${columns(cols, { height: 120 })}`;
}

function busyChart(range, t0, t1) {
  const s = (range.busy || [])[0];
  if (!s) return '<div class="empty">No busy-slot history.</div>';
  const N = 48, b = buckets(s.points, t0, t1, N);
  return `<h3>CI slots busy, 24h</h3>${columns(b.map((v, i) => {
    const at = t0 + (i + 0.5) * ((t1 - t0) / N), d = new Date(at);
    return { key: "b" + i, label: d.getMinutes() < 30 && d.getHours() % 6 === 0 ? clock(at) : "", tip: `${clock(at)} ${v ?? "-"} busy`, segs: [{ v: v || 0, color: "var(--c1)" }] };
  }), { height: 120 })}`;
}

const sumOf = (o) => Object.values(o || {}).reduce((a, v) => a + (v || 0), 0);

function kpis(cc) {
  const one = (n) => (cc[n] || {})[""];
  const tile = (l, v, c, sub) => `<div class="tile" style="--c:${c}"><span class="tl">${l}</span><span class="tv">${v}</span>${sub ? `<span class="ts1">${sub}</span>` : ""}</div>`;
  const nodes = [one("cc:k3s_nodes_ready"), one("cc:k3s_nodes_total")];
  const beats = [one("cc:machines_up"), one("cc:machines_total")];
  const busy = sumOf(cc["cc:pool_busy"]) + sumOf(cc["cc:host_local_busy"]), slots = sumOf(cc["cc:pool_slots"]) + sumOf(cc["cc:host_local_open_slots"]);
  const waiting = sumOf(cc["cc:pool_waiting"]) + sumOf(cc["cc:host_local_queued"]);
  const lazer = [one("cc:lazer_spend_usd"), one("cc:lazer_budget_usd")];
  const ok = (a, b) => (a != null && a === b ? "var(--b-done)" : "var(--b-needs)");
  return `<div class="tiles roomy">${
    tile("NODES", `${nodes[0] ?? "?"}/${nodes[1] ?? "?"}`, ok(nodes[0], nodes[1]))}${
    tile("HEARTBEATS", `${beats[0] ?? "?"}/${beats[1] ?? "?"}`, ok(beats[0], beats[1]))}${
    tile("CI BUSY", `${busy}/${slots}`, "var(--c1)", `${waiting} waiting`)}${
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

function poolsTable(cc, inst) {
  const on = {};
  for (const r of inst.runners || []) if (["running", "idle"].includes(r.labels.state)) ((on[r.labels.pool] ||= {})[r.labels.host] = (on[r.labels.pool][r.labels.host] || 0) + 1);
  const pools = [...new Set([...Object.keys(cc["cc:pool_slots"] || {}), ...Object.keys(cc["cc:pool_waiting"] || {})])]
    .sort((a, b) => ((cc["cc:pool_waiting"] || {})[b] || 0) - ((cc["cc:pool_waiting"] || {})[a] || 0) || a.localeCompare(b));
  const g = (n, p) => (cc[n] || {})[p];
  const row = (p, busy, slots, waiting, oldest, done, pass, hosts, room) => `<tr><td>${esc(p)}</td><td class="m">${meter(slots ? busy / slots : 0, "var(--c1)")}</td><td class="n">${busy ?? "-"}/${slots ?? "-"}${room > 0 ? `+${room}` : ""}</td><td class="n${waiting ? " warn" : ""}">${waiting ?? "-"}</td><td class="n">${secs(oldest)}</td><td class="n">${done ?? "-"}</td><td class="n ${pass == null ? "" : pass < 0.7 ? "bad" : pass < 0.9 ? "warn" : ""}">${pct(pass)}</td><td class="muted">${esc(hosts)}</td></tr>`;
  let rows = pools.map((p) => row(p, g("cc:pool_busy", p), g("cc:pool_slots", p), g("cc:pool_waiting", p), g("cc:pool_oldest_wait_seconds", p), g("cc:pool_done_24h", p), g("cc:pool_pass_ratio_24h", p),
    Object.entries(on[p] || {}).map(([h, n]) => (n > 1 ? `${h}:${n}` : h)).join(" "))).join("");
  for (const h of Object.keys(cc["cc:host_local_slots"] || {})) rows += row("unity-local", g("cc:host_local_busy", h), g("cc:host_local_open_slots", h), g("cc:host_local_queued", h), null, g("cc:host_local_done_24h", h), g("cc:host_local_pass_ratio_24h", h), h, g("cc:host_local_slots", h) - g("cc:host_local_open_slots", h));
  for (const p of Object.keys(cc["cc:pool_done_24h"] || {}).filter((p) => !pools.includes(p))) rows += row(p, null, null, null, null, g("cc:pool_done_24h", p), g("cc:pool_pass_ratio_24h", p), "");
  return `<table class="tbl"><tr><th>pool</th><th></th><th class="n">busy</th><th class="n">waiting</th><th class="n">oldest</th><th class="n">done 24h</th><th class="n">pass</th><th>on</th></tr>${rows}</table>`;
}

function machinesTable(cc) {
  const g = (n, h) => (cc[n] || {})[h];
  const hosts = Object.keys(cc["cc:host_cores"] || {}).sort((a, b) => (g("cc:host_cpu_busy_ratio", b) || 0) - (g("cc:host_cpu_busy_ratio", a) || 0));
  return `<table class="tbl"><tr><th>machine</th><th>cpu</th><th class="n">now</th><th class="n">6h</th><th class="n">load</th><th>mem</th><th class="n"></th><th class="n">temp</th></tr>${hosts.map((h) => {
    const cpu = g("cc:host_cpu_busy_ratio", h), mem = g("cc:host_mem_used_ratio", h), temp = g("cc:host_temp_c", h), load = g("cc:host_load1", h), cores = g("cc:host_cores", h);
    return `<tr><td>${esc(h)}</td><td class="m">${meter(cpu, cpu > 0.9 ? "var(--b-stalled)" : "var(--c1)")}</td><td class="n">${pct(cpu)}</td><td class="n">${pct(g("cc:host_cpu_busy_ratio:avg6h", h))}</td><td class="n${load > cores * 1.5 ? " warn" : ""}">${load == null ? "-" : load.toFixed(1)}/${cores ?? "?"}</td><td class="m">${meter(mem, mem > 0.9 ? "var(--b-stalled)" : "var(--c3)")}</td><td class="n">${pct(mem)}</td><td class="n${temp > 85 ? " warn" : ""}">${temp == null ? "-" : Math.round(temp) + "C"}</td></tr>`;
  }).join("")}</table>`;
}

function runningTable(inst) {
  const prBy = {};
  for (const r of [...(inst.runners || []), ...(inst.waiting || [])]) if (r.labels.pr && r.labels.pr !== "") prBy[`${r.labels.repo}/${r.labels.branch}`] = r.labels.pr;
  const rows = [
    ...(inst.runners || []).filter((r) => r.labels.state === "running").map((r) => ({ v: r.value, host: r.labels.host, pool: r.labels.pool, repo: r.labels.repo, pr: r.labels.pr, job: r.labels.job_name, branch: r.labels.branch + (r.labels.title && r.labels.title !== r.labels.workflow ? " - " + r.labels.title : "") })),
    ...(inst.gates || []).map((r) => { const repo = r.labels.repo || r.labels.worktree; return { v: r.value, host: r.labels.host, pool: "unity-local", repo, pr: prBy[`${repo}/${r.labels.branch}`], job: r.labels.platform, branch: r.labels.branch }; }),
  ].sort((a, b) => (b.v || 0) - (a.v || 0));
  if (!rows.length) return '<div class="empty">Nothing running.</div>';
  return `<table class="tbl"><tr><th>host</th><th>pool</th><th>repo</th><th>PR</th><th>job</th><th class="n">for</th><th>branch</th></tr>${rows.map((r) =>
    `<tr><td>${esc(r.host || "-")}</td><td>${esc(r.pool || "-")}</td><td>${esc(r.repo || "-")}</td><td>${r.pr ? "#" + esc(r.pr) : "-"}</td><td>${esc(r.job || "-")}</td><td class="n${r.v > LONG_RUN_SECS ? " warn" : ""}">${secs(r.v)}</td><td class="wrap">${esc(r.branch || "-")}</td></tr>`).join("")}</table>`;
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

// What is red: the dashboard's table (watches tripped, runners failed, nodes NotReady) plus the
// board's DOWN line (offline runners, stuck runs, the GitHub API).
function redItems(inst) {
  const items = (inst.red || []).map((s) => s.labels.item).filter(Boolean).sort();
  for (const r of inst.runners || []) if (["offline", "missing"].includes(r.labels.state)) items.push(`runner ${r.labels.name} ${r.labels.state}`);
  for (const r of inst.waiting || []) if (r.labels.stuck === "true") items.push(`stuck run: ${r.labels.repo} ${r.labels.branch}, ${secs(r.value)}, no jobs`);
  if (((inst.api || [])[0] || {}).value !== 1) items.unshift("GitHub API not answering: runner rows may be missing");
  if (!(inst.runners || []).length) items.push("no runner series (exporter down?)");
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

function renderInfra() {
  const el = $("infra");
  const d = ist.data;
  if (!d) { el.innerHTML = `<div class="empty">${ist.err ? esc(ist.err) : "Loading..."}</div>`; return; }
  const links = `${gLink("kb-command-center", "Command Center")} ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-fleet", "Machines")} ${gLink("kb-agents-overview", "Agents")}`;
  // As the board blanks: a failed read never leaves the last (maybe green) numbers up.
  if (!d.ok) { el.innerHTML = `<div class="bhead"><span>infra</span><span>${links}</span></div><div class="panel down">${esc(d.error || "Prometheus did not answer")}</div>`; return; }
  const cc = ccIndex(d.instant.cc), inst = d.instant, t1 = d.at * 1e3, t0 = t1 - 24 * 3600e3;
  const overall = (cc["cc:overall_status"] || {})[""];
  const [word, color] = statusOf(overall);
  const red = redItems(inst);
  const fin = finishedTable(inst);
  let html = `<div class="bhead"><span><span class="chip" style="--c:${color}">OVERALL ${word}</span> <span class="muted">needs you: ${(cc["cc:asks_open"] || {})[""] ?? "?"} asks, ${(cc["cc:sessions_attention"] || {})[""] ?? "?"} sessions waiting, read ${clock(t1)}</span></span><span>${links}</span></div>`;
  html += domainTiles(cc);
  html += `<div class="sp"></div>` + kpis(cc);
  html += `<h2 class="sec">Last 24h ${legend(STATUS.map(([w, c]) => [w, c]).concat([["NO DATA", "var(--b-unclear)"]]))}</h2><div class="panel">${statusStrip(d.range, t0, t1)}</div>`;
  html += `<div class="g2"><div class="panel">${queueChart(d.range, t0, t1)}</div><div class="panel">${busyChart(d.range, t0, t1)}</div></div>`;
  html += `<h2 class="sec">Red right now <span class="muted">${red.length}</span></h2><div class="panel${red.length ? " down" : ""}">${red.length ? red.map((r) => `<div class="pr"><span class="chip sm" style="--c:var(--b-needs)">RED</span><span class="pt">${esc(r)}</span></div>`).join("") : "Nothing: every rostered runner is registered and online."}</div>`;
  html += `<h2 class="sec">Pools</h2><div class="panel scroll">${poolsTable(cc, inst)}</div>`;
  html += `<h2 class="sec">Running</h2><div class="panel scroll">${runningTable(inst)}</div>`;
  html += `<h2 class="sec">Queued</h2><div class="panel scroll">${queuedTable(inst)}</div>`;
  html += `<h2 class="sec">Machines</h2><div class="panel scroll">${machinesTable(cc)}</div>`;
  html += `<h2 class="sec">Finished 24h <span class="muted">${esc(fin.head)}</span></h2>${fin.body ? `<div class="panel scroll">${fin.body}</div>` : ""}`;
  const y = el.scrollTop;
  el.innerHTML = html;
  el.scrollTop = y;
}

TABS.infra = {
  show() {
    renderInfra();
    refreshInfra();
    if (!ist.timer) ist.timer = setInterval(infraTick, INFRA_REFRESH_MS);
  },
  // Nothing on this machine changes Prometheus, so file events do not apply; only a resync does.
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "infra") refreshInfra(); },
};
