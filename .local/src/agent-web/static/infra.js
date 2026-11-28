"use strict";
// The Infra tab, as the hub's Infra tab, by inner tab: Machines (every machine, then the pools;
// one machine's page is `#infra/machines/<host>`), Runners
// (slots, waiting jobs, local Unity failures), Runs, Pipelines and Tests (ci.js), and Jobs (jobs.js); what is red and the health chips are on Alerts (alerts.js). /api/infra asks
// Prometheus the board's own queries; statuses are the cc:* rules, so nothing is judged here.

// Prometheus has no push to a browser, so the open tab re-reads on the board's cadence
// (REFRESH_SECS=60): the rules evaluate every minute, and faster only redraws the same numbers.
const INFRA_REFRESH_MS = 60e3;
// Each fold's open state, which outlives the re-render on every refresh.
const ist = { data: null, err: null, open: {} };

const refreshInfra = coalesce(async () => {
  const view = new URLSearchParams(Object.values(INFRA_TABLES).flatMap((pre) => [...tblParams(st.views.infra, pre)])).toString();
  try { ist.data = await api("/api/infra" + (view ? "?" + view : "")); ist.err = null; } catch (e) { ist.err = e.message; }
  // An open page re-reads with the board, so its numbers move and a failed read retries.
  if (infraPage()) refreshPage();
  if (st.tab === "infra") renderInfra();
});

// Status as the cc:* rules give it: 0 ok, 1 warn, 2 red, anything else no data. The colour
// always comes with its word.
const STATUS = [["OK", "var(--b-done)"], ["WARN", "var(--b-stalled)"], ["RED", "var(--b-needs)"]];
const statusOf = (v) => STATUS[v] || [NO_DATA.toUpperCase(), "var(--c-other)"];

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


// The head and the waiting line are hub_core::ci::Glance's (`head`, `pending_line`), served as words.
const pendingLine = (g) => (g && g.pending_line ? `<div class="cline warn">${esc(g.pending_line)}</div>` : "");

// The tiles are hub_core::infra::Infra::kpis: the value, the lines and the hue, judged once for the
// hub too. A tile's colour is its level; a count with no verdict (SESSIONS) is blue, and SPEND, a
// link to Costs, is fixed.
const KPI_HUE = { ok: "var(--b-done)", warn: "var(--b-stalled)", red: "var(--b-needs)", nodata: "var(--c-other)" };
function kpis(list) {
  const tiles = list.map((k) => tile(esc(k.name), esc(k.value), k.level ? KPI_HUE[k.level] : "var(--b-working)", esc(k.sub), k.href));
  tiles.splice(tiles.length - 1, 0, tile("SPEND", "on Costs", "var(--c2)", "the LAZER pool, Claude 24h and every cut", "#costs"));
  return `<div class="tiles roomy">${tiles.join("")}</div>`;
}

// The Space section (hub_core::workload::Space): the cluster's cores and memory by class, the
// words and cells as Rust says them, so this only lays them out. `sp` is null before the first
// read, said as no data, never an empty table.
function spaceSection(sp) {
  if (!sp) return `${secHead("", "Space", NO_DATA, "", "h3")}<div class="empty">${NO_DATA}</div>`;
  const done = sp.done > 0 ? ` <span class="muted">done </span>${tblLink(sp.done_link, `24h ${sp.done}`)}` : "";
  const head = `<div class="muted">${esc(sp.head)}${done}</div>`;
  const no = sp.no_split_note ? `<div class="muted">${esc(sp.no_split_note)}</div>` : "";
  if (!sp.classes.length) return `${secHead("", "Space", null, "", "h3")}${head}<div class="empty">${NO_DATA}</div>${no}`;
  const th = sp.columns.map((c, i) => `<th${i ? ' class="n"' : ""} data-role="${i ? "" : "lead"}" data-label="${esc(c)}">${esc(c)}</th>`).join("");
  const rows = sp.classes.map((c) => `<tr>${c.cells.map((x, i) => td(i ? "n" : "", esc(x))).join("")}${c.note ? td("muted wrap", esc(c.note)) : td("", "")}</tr>`).join("");
  return `${secHead("", "Space", null, "", "h3")}${head}<div class="panel scroll"><table class="tbl"><tr>${th}<th data-label="note"></th></tr>${rows}</table></div>${no}`;
}

// The tab's tables, each with its view keys' prefix in the URL; agent-web infra.rs TABLES names the
// same. The rows, their order, chips, facets and links are hub_core's (machines.rs, ci.rs), which the
// TUI draws too; this file only draws the cells.
const INFRA_TABLES = { machines: "m", pools: "p", runners: "r", queued: "w", local: "u" };

// One bar per core, in core order, from cc:host_core_busy_ratio; amber past 90% as the cpu meter.
function coreStrip(cores) {
  const busyColor = (v) => (v > 0.9 ? "var(--b-stalled)" : "var(--c1)");
  return `<span class="cores">${cores.map((v, i) => `<i title="cpu ${i}: ${pct(v)}"><b style="height:${(Math.max(0, Math.min(1, v || 0)) * 100).toFixed(0)}%;background:${busyColor(v)}"></b></i>`).join("")}</span>`;
}

// The cells' hues are `m.level`, hub_core::machines::Machine::levels (the hub draws the same).
const GIB = 1024 ** 3;
// A reading as the slots table says it, as hub_core::machine_page::used_of does: 0, 2.8, 140.
const short = (v) => (v === 0 ? "0" : v < 100 ? v.toFixed(1) : Math.round(v).toString());
// `2.8/3`, `11.2/14G`; `2.8` with no limit; no data with no reading.
const usedOf = (used, max, scale, unit) => (used == null ? NO_DATA : max == null ? `${short(used / scale)}${unit}` : `${short(used / scale)}/${Math.round(max / scale)}${unit}`);
// `39 of 64G`, or no data unless both are read.
const gbOf = (used, total) => (used == null || total == null ? NO_DATA : `${Math.round(used / GIB)} of ${Math.round(total / GIB)}G`);

function diskCell(m) {
  const free = m.disk;
  if (free == null) return `<td class="n${lvl(m.level.disk)}" title="no disk metrics for this name: nothing alerts on its disk">${NO_DATA}</td>`;
  return `<td class="n${lvl(m.level.disk)}" title="${esc(`${gbOf(m.disk_avail, m.disk_size)} free`)}">${pct(free)}</td>`;
}

// hub_core::jobpods::Booked: what the pods on a CI node request, its fuller share and `4.4/32 2.5G/92G`.
// hub_core::jobpods::cores: one place, halves up as Rust rounds them (toFixed rounds 0.15 down).
const cores1 = (c) => (Math.round(c * 10) / 10).toFixed(1);
const bookedShare = (b) => Math.max(b.cpu_alloc > 0 ? b.cpu / b.cpu_alloc : 0, b.mem_alloc > 0 ? b.mem / b.mem_alloc : 0);
// hub_core::machines::Machine::booked_cell, or - on no CI node.
// hub_core::jobpods::Booked::cell: `4.4/32 2.5G/92G` taken of its units, bare `1.7 1.2G` on a node with no allocatable read.
const bookedCell = (m) => {
  const b = m.booked;
  if (!b) return "-";
  if (!(b.cpu_alloc > 0)) return `${cores1(b.cpu)} ${bytes(b.mem)}`;
  return `${cores1(b.cpu)}/${Math.round(b.cpu_alloc)} ${bytes(b.mem)}/${bytes(b.mem_alloc)}`;
};
// The CI POOL block (hub_core::jobpods::Units): its head, a bar of the share taken beside its line,
// and the TAKEN BY table, every word and cell Rust's so the hub and the waybar hover print the same.
function poolSection(u) {
  if (!u) return "";
  // hub_core::jobpods::Units::share: the share of the pool taken, 0 with no total.
  const share = u.total > 0 ? u.taken / u.total : 0;
  // On a phone each kind leads, its units and share under it (the last two columns), pods and each on a tap.
  const role = (i) => (i === 0 ? ' data-role="lead"' : i >= u.columns.length - 2 ? ' data-role="glance" data-named' : "");
  const th = u.columns.map((c, i) => `<th${i ? ' class="n"' : ""}${role(i)} data-label="${esc(c)}">${esc(c)}</th>`).join("");
  const rows = u.rows.map((r) => `<tr>${r.map((x, i) => td(i ? "n" : "", esc(x))).join("")}</tr>`).join("");
  return `<div class="cline"><b>${esc(u.head)}</b></div><div class="cline">${meter(share, share >= 1 ? "var(--b-stalled)" : "var(--c1)")} ${esc(u.line)}</div>` +
    `<div class="panel scroll"><table class="tbl"><tr>${th}</tr>${rows}</table></div>`;
}
// hub_core::ci::Next::line: the oldest waiting job that fits the machine, its repo and how long it has waited.
const nextLine = (x) => `${x.job}${x.repo ? ` (${x.repo})` : ""} ${secs(x.wait)}`;
// A machine's hover: what its cores and memory go to (hub_core::workload, one line per class),
// then each runner's cores and memory, the busiest first, each reading it lacks said as no data.
function cpuTitle(m) {
  const split = m.split.join("\n");
  const runners = runnerTitle(m);
  return split && runners ? `${split}\n\n${runners}` : split || runners;
}
function runnerTitle(m) {
  const mem = Object.fromEntries(m.runner_mem);
  const names = [...m.runner_cores.map(([n]) => n), ...m.runner_mem.map(([n]) => n).filter((n) => !m.runner_cores.some(([c]) => c === n))];
  const cores = Object.fromEntries(m.runner_cores);
  return names.map((n) => `${n}: ${cores[n] == null ? NO_DATA : cores[n].toFixed(1)} cores, mem ${usedOf(mem[n], null, GIB, "G")}`).join("\n");
}
const ciRef = (x) => (x.pr ? `${x.repo}#${x.pr}` : x.branch || x.repo || "");
// A judged cell's class, hub_core's level word: bad and warn colour it, the rest do not.
const lvl = (l) => (l === "bad" || l === "warn" ? ` ${l}` : l === "neutral" ? " muted" : "");
const td = (cls, html) => `<td${cls ? ` class="${cls}"` : ""}>${html}</td>`;

// Each table's cells by column, in the order the summary's columns come (hub_core Row::COLUMNS);
// `l` is the row's links (tblLinks). A label's second field is its header's class.
// hub_core::host_now::HOT_C, kept equal by its test: a sensor this hot or hotter shows amber.
const HOT_C = 85;
const MACH_COLS = { machine: ["machine"], state: ["state"], booked: ["booked", "n"], cpu: ["cpu now"], "6h": ["6h", "n"], load: ["load", "n"],
  mem: ["mem"], temp: ["temp", "n"], disk: ["disk free", "n"], running: ["running"], next: ["next"], up: ["up since", "n"] };
const MACH_CELLS = {
  machine: (m, l) => td("", tblLink(l.machine, m.host)),
  state: (m) => td(m.state === "up" ? "" : m.state === NO_DATA ? "muted" : "warn", esc(m.state)),
  booked: (m) => `<td class="n${lvl(m.level.booked)}"${m.split.length || m.runner_cores.length || m.runner_mem.length ? ` title="${esc(cpuTitle(m))}"` : ""}>${m.booked ? `${meter(bookedShare(m.booked), "var(--c1)")} ` : ""}${bookedCell(m)}${m.off ? ` +${m.off} off` : ""}</td>`,
  cpu: (m) => td("m", `${m.core_busy.length ? coreStrip(m.core_busy) : meter(m.cpu, m.level.cpu === "warn" ? "var(--b-stalled)" : "var(--c1)")} ${pct(m.cpu)}`),
  "6h": (m) => td("n", pct(m.cpu6h)),
  load: (m) => td(`n${lvl(m.level.load)}`, m.load == null ? "-" : `${m.load.toFixed(1)}/${m.cores ?? "?"}`),
  mem: (m) => `<td class="m" title="${esc(`mem ${gbOf(m.mem_used, m.mem_total)}`)}">${meter(m.mem, m.level.mem === "warn" ? "var(--b-stalled)" : "var(--c3)")} ${pct(m.mem)}</td>`,
  temp: (m) => td(`n${lvl(m.level.temp)}`, degC(m.temp)),
  disk: diskCell,
  running: (m) => td("wrap", esc(m.running.join(", ")) || "-"),
  next: (m) => td("wrap", m.next ? esc(nextLine(m.next)) : "-"),
  up: (m) => td("n muted", m.boot ? when(m.boot) : "-"),
};

// One row per job kind: its jobs running and waiting, and the machines that take it.
const POOL_COLS = { pool: ["kind"], running: ["running", "n"], waiting: ["waiting", "n"], oldest: ["oldest", "n"], done_1h: ["done 1h", "n"], done_5h: ["done 5h", "n"], done: ["done 24h", "n"], usual: ["usual", "n"], pass: ["pass", "n"], machines: ["machines"] };
const num = (v) => v ?? "-";
// hub_core::machines::Pool::machines_cell: each machine a link to its page, with its online slots.
const poolSeats = (p) => p.machines.map((s) => tblLink(s.href, s.host) + ` ${s.slots}`).join(", ") || "-";
const POOL_CELLS = {
  pool: (p, l) => td("", tblLink(l.pool, p.pool)),
  running: (p) => td("n", num(p.running)),
  waiting: (p) => td(`n${p.waiting ? " warn" : ""}`, num(p.waiting)),
  oldest: (p) => td("n", secs(p.oldest)),
  done_1h: (p) => td("n", num(p.done_1h)),
  done_5h: (p) => td("n", num(p.done_5h)),
  done: (p) => td("n", num(p.done)),
  usual: (p) => td("n muted", secs(p.usual)),
  pass: (p) => td(`n${lvl(p.pass_level)}`, pct(p.pass)),
  machines: (p) => td("wrap", poolSeats(p)),
};

// The CI slots, from hub_core::ci (the one join the TUI and fleet-bench share): each runner
// with a job and the job it runs and how long against its usual; a late job (past an hour or its
// usual p90) shows amber.
const SLOT_COLS = { host: ["host"], slot: ["slot"], state: ["state"], pool: ["pool"], ran: ["ran", "n"], usual: ["usual", "n"], job: ["job"], ref: ["ref"] };
const SLOT_CELLS = {
  host: (r, l) => td("", tblLink(l.host, r.host)),
  slot: (r) => td("", esc(r.slot)),
  state: (r) => td("", esc(r.state)),
  pool: (r, l) => td("muted", tblLink(l.pool, r.pool)),
  ran: (r) => td(`n${r.late ? " warn" : ""}`, secs(r.ran) + (r.late ? "!" : "")),
  usual: (r) => td("n muted", secs(r.usual)),
  job: (r) => td("wrap", esc(r.job || "-")),
  ref: (r) => td("muted", esc(ciRef(r))),
};

const QUEUED_COLS = { job: ["job"], pool: ["pool"], ref: ["ref"], n: ["n", "n"], wait: ["wait", "n"], needs: ["needs"], can: ["can run on"], starts: ["starts"] };
const QUEUED_CELLS = {
  job: (q) => td(q.stuck ? "bad" : "", esc(q.job || "-")),
  pool: (q, l) => td("muted", tblLink(l.pool, q.pool)),
  ref: (q) => td("muted", esc(ciRef(q))),
  n: (q) => td("n", q.n),
  wait: (q) => td("n", secs(q.wait)),
  needs: (q) => td("muted", esc(q.needs.join(", "))),
  can: (q) => td("wrap", q.can.length ? q.can.map((f) => `${esc(f.host)} <span class="muted">${esc(f.state)}</span>`).join(", ") : q.needs.length ? (q.pool === "github-hosted" ? "GitHub" : "nobody") : "-"),
  // hub_core::ci::Queued::starts: now, in about its fitting slot's usual time left, or - (no usual).
  starts: (q) => td("muted", q.starts == null ? "-" : `${q.starts === 0 ? "now" : `in ${secs(q.starts)}`} ${esc(q.at)}`),
};

// A local Unity gate's failures (hub_core::ci LocalFail): a gate run on a workstation never
// reaches GitHub, so the Runs table cannot show it. `last` is the start of its last failed hour.
const LOCAL_COLS = { last: ["last", "n"], repo: ["repo"], branch: ["branch"], platform: ["platform"], result: ["result"], failed: ["failed", "n"] };
const LOCAL_CELLS = {
  last: (f) => td("n", stamp(f.last)),
  repo: (f) => td("muted", esc(f.repo)),
  branch: (f) => td("wrap", esc(f.branch)),
  platform: (f) => td("", esc(f.platform)),
  result: (f) => td("bad", esc(f.result)),
  failed: (f) => td("n", f.n),
};

// One table's rows from the read.
function infraBody(name, labels, cells, empty) {
  const d = ist.data.tables[name], t = d.table, rows = d.rows;
  if (!rows.length) return `<div class="panel"><div class="empty">${t.total ? "No row matches." : empty}</div></div>`;
  const keys = t.columns.map((c) => c.key).filter((k) => labels[k] && cells[k]);
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, labels)}${rows.map((r, i) =>
    `<tr>${keys.map((k) => cells[k](r, tblLinks(t, i))).join("")}</tr>`).join("")}</table></div>`;
}

const infraTable = (name, labels, cells, hint, empty, o) => tblTab({
  tab: "infra", id: "infra-" + INFRA_TABLES[name], el: "infra-main", pre: INFRA_TABLES[name], hint,
  refresh: () => refreshInfra(), render: () => renderInfra(), table: () => ist.data?.tables?.[name]?.table,
  wrap: (h) => `<div data-tbl="${INFRA_TABLES[name]}">${h}</div>`,
  body: () => infraBody(name, labels, cells, empty), tiles: o && o.tiles,
});
// A table's head count: its rows, or "N of M" while the view hides some.
const infraN = (name) => { const t = ist.data?.tables?.[name]?.table; return t && tblCount(t); };
const INFRA_T = {
  machines: infraTable("machines", MACH_COLS, MACH_CELLS, "search, or -state:up", "No machine reports."),
  pools: infraTable("pools", POOL_COLS, POOL_CELLS, "search", "No job kind reports."),
  runners: infraTable("runners", SLOT_COLS, SLOT_CELLS, "search, or host:razer-laptop pool:unity", "No runner reports."),
  queued: infraTable("queued", QUEUED_COLS, QUEUED_CELLS, "search, or pool:unity can:razer-laptop", "Nothing waiting."),
  local: infraTable("local", LOCAL_COLS, LOCAL_CELLS, "search, or platform:android branch:feat", "No local Unity gate failed in 24h."),
};

// CI runs finished today: hub_core::ci::Day counts the passed, failed and cancelled runs since local
// midnight (skipped and neutral count in none), so the tiles only draw its fields.
function doneToday(ci) {
  const t = ci.day;
  if (!t.read) return `<div class="panel">No hourly data yet.</div>`;
  const tiles = `<div class="tiles roomy">${
    tile("CI RUNS", t.runs, "var(--c1)", `${pct(t.pass)} pass`)}${
    tile("FAILED ON MAIN", t.failed_main, t.failed_main ? "var(--b-needs)" : "var(--b-done)")}${
    tile("FAILED ON BRANCHES", t.failed_branch, "var(--b-stalled)")}${
    tile("CANCELLED", t.cancelled, "var(--c-other)")}${
    tile("LOCAL UNITY", t.local, "var(--c3)", `${pct(t.local_pass)} pass`)}</div>`;
  const note = `Tiles count from midnight; CI is read every 10 minutes. Runs per hour and the 24h status lanes are in Grafana ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-command-center", "Command Center")}.`;
  return `${tiles}<div class="muted fold">${note}</div>`;
}

// Runners: the slots of hub_core::ci, the jobs waiting for a runner with what each needs and the
// hosts that can take it, the local Unity gate failures, and the day's tiles. Each pool's queue and
// last day are the Pools table on Machines; the runs themselves (hub_core::builds) are Runs.
// The CI runs that went red in the last day (Counts::recent_red, the Runs read's), as a line that
// opens Runs on its red state; none until that read is in.
function failed24h() {
  const n = bld.data?.counts?.recent_red;
  return n ? `<div class="cline warn"><a href="#infra/runs?bs=red" title="the red runs, newest first">${n} failed in 24h</a></div>` : "";
}
function runnersSection(ci) {
  // The head the TUI and the waybar hover read too (hub_core::ci::Glance): each slot once.
  const g = ci.glance, head = g ? `<div class="cline">${esc(g.head)}</div>` : "";
  let html = secHead("ci", "Runners", infraN("runners"), ci.red.length ? "bad" : bld.data?.counts?.recent_red ? "warn" : "") + head + poolSection(g && g.units) + failed24h();
  // A waiting job no online runner can take: hub_core::ci words the line, once for both surfaces.
  if (ci.red.length) html += `<div class="panel down">${ci.red.map((r) => `<div class="pr"><span class="chip sm" style="--c:var(--b-needs)">RED</span><span class="pt">${esc(r)}</span></div>`).join("")}</div>`;
  return html + INFRA_T.runners.html();
}
const waitingSection = () => secHead("waiting", "Waiting for a runner", infraN("queued"), "", "h3") + INFRA_T.queued.html();
function localSection(ci) {
  const n = infraN("local");
  return secHead("local", "Local Unity", n, n ? "bad" : "", "h3") + INFRA_T.local.html() +
    fold("sec-d", secHead("", "CI runs finished today", null, "", "h3"), doneToday(ci), { k: "ci-more", open: secOpen(ist.open, "ci-more") });
}

// The page open in place of the tab's tables, `#infra/<word>/<name>` (hub_core::links PAGES, whose
// inner tab app.js ENTITY_PAGES mirrors), each read by hub_core for the hub's page too: its word,
// its read, its back button's words, and the body under the header every page shares. One state, one read and
// one header serve them all, so a third page is a row here.
const INFRA_PAGES = [
  // Its parts, the cores each pool uses there, what runs there and its buttons, its
  // last 7 days and downtime, the CI jobs that ran there and the alerts naming it.
  { word: "machines", api: (n) => "/api/infra/machine?host=" + encodeURIComponent(n), back: "All machines", body: machineBody },
  // Its parts, the machines with a slot in it, the CI jobs waiting for it, and its running
  // and waiting over 7 days.
  { word: "pools", api: (n) => "/api/infra/pool?name=" + encodeURIComponent(n), back: "All pools", body: poolBody },
];
// The open page, by its hash (`machines/<host>`), and its last read.
const pgst = { page: "", data: null, err: null };
// The row and name of the page the hash opens, or null on the tab's tables.
const infraPage = () => {
  if (st.tab !== "infra") return null;
  const p = INFRA_PAGES.find((r) => st.page.startsWith(r.word + "/"));
  return p ? { p, name: st.page.slice(p.word.length + 1) } : null;
};
// A read that lands after another page opened is dropped; a failed one keeps the last read up.
const refreshPage = coalesce(async () => {
  const o = infraPage(), page = st.page;
  if (!o || pgst.page !== page) return;
  let data = null, err = null;
  try { data = await api(o.p.api(o.name)); } catch (e) { err = e.message; }
  if (pgst.page !== page) return;
  if (data) pgst.data = data;
  pgst.err = err;
  if (st.page === page) renderInfra();
});
// Its header, back button and read errors, then its row's body.
function infraPageHtml() {
  const o = infraPage();
  if (!o) return "";
  const back = `<a class="btn sm" href="#infra/${ENTITY_PAGES.infra[o.p.word]}${st.views.infra ? "?" + st.views.infra : ""}">${o.p.back}</a>`;
  const d = pgst.data;
  if (!d) return `<div class="bhead"><span>${esc(o.name)}</span>${back}</div>${readPanel(pgst.err, "Loading...")}`;
  let h = `<div class="bhead"><span>${esc(d.head)}</span>${back}</div>`;
  const errs = pgst.err ? [`refresh failed, showing the last read: ${pgst.err}`, ...d.errors] : d.errors;
  if (errs.length) h += `<div class="panel down">${errs.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return h + o.p.body(d);
}
// Each pool one slot colour on the history chart, by name.
function poolColors(d) {
  const names = new Set();
  if (d.history) d.history.hours.forEach((x) => Object.keys(x.pools).forEach((p) => names.add(p)));
  return Object.fromEntries([...names].sort().map((p, i) => [p, SLOTS[i % SLOTS.length]]));
}

// The slots table (hub_core::machine_page::SlotUse): each runner, then the rest of the machine by class.
// A reading a runner has no series for says no data, never 0.
const SLOTUSE_COLS = { slot: ["slot"], takes: ["takes"], now: ["now"], job: ["job"], cores: ["cores", "n"], mem: ["mem", "n"], disk: ["disk", "n"] };
const readCell = (t) => td(`n${t === NO_DATA ? " muted" : ""}`, esc(t));
const SLOTUSE_CELLS = {
  slot: (r) => td(r.runner ? "" : "muted", esc(r.slot)),
  takes: (r) => td("wrap", r.takes.map((p) => tblLink("#infra/pools/" + encodeURIComponent(p), p)).join(" ")),
  now: (r) => td(r.now === "off" ? "warn" : "", esc(r.now)),
  job: (r) => td("wrap", r.runner ? esc(r.job || "-") : ""),
  cores: (r) => readCell(r.runner ? usedOf(r.cores, r.cores_max, 1, "") : r.cores == null ? "" : short(r.cores)),
  mem: (r) => readCell(r.runner ? usedOf(r.mem, r.mem_max, GIB, "G") : r.mem == null ? "" : `${short(r.mem / GIB)}G`),
  disk: (r) => (r.runner ? `<td class="n${r.disk == null ? " muted" : ""}"${r.disk_age != null ? ` title="read ${esc(secs(r.disk_age))} ago"` : ""}>${r.disk == null ? NO_DATA : bytes(r.disk)}</td>` : td("n", "")),
};

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
    const tip = x.cpu == null ? `${stamp(x.at)}: ${NO_DATA}` : `${stamp(x.at)}: cpu ${pct(x.cpu)}${used}`;
    return { key: String(x.at), label: dayTick(x.at), tip, segs };
  });
  const key = [...pools.map((p) => [p, colors[p]]), ["other", OTHER]].map(([n, c]) => `<span class="chip sm" style="--c:${c}">${esc(n)}</span>`).join(" ");
  return `${columns(cols, { height: 120, yfmt: pct })}<div class="muted">${key} hourly means of ${h.step / 60}-minute samples</div>`;
}

const DOWN_COLS = { from: ["from"], to: ["to"], took: ["took", "n"], cause: ["cause"], why: ["why"] };
const DOWN_CELLS = {
  from: (r) => td("", stamp(r.from)),
  to: (r) => td("", stamp(r.to)),
  took: (r) => td("n", secs(r.to - r.from)),
  cause: (r) => td(r.cause === "unknown" ? "warn" : "", esc(r.cause)),
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

// Bytes as a reader says them, as hub_core::host_now::bytes does: 2.5G, 340M, 12K.
function bytes(b) {
  if (b == null) return "-";
  const u = ["B", "K", "M", "G", "T"];
  let v = Math.max(0, b), i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (v < 10 && i > 0 ? v.toFixed(1) : Math.round(v)) + u[i];
}
const cpuCores = (c) => (c == null ? "-" : c.toFixed(2));
const degC = (c) => (c == null ? "-" : Math.round(c) + "C");

const DEVICE_COLS = { device: ["device"], hottest: ["hottest", "n"], readings: ["readings"], chip: ["chip"] };
const DEVICE_CELLS = {
  device: (r) => td("", esc(r.device)),
  hottest: (r) => td(`n${r.hottest >= HOT_C ? " warn" : ""}`, degC(r.hottest)),
  readings: (r) => td("wrap", esc([...r.temps.map(([n, c]) => `${n} ${degC(c)}`), ...r.fans.map(([n, v]) => `${n} ${Math.round(v)}rpm`)].join("  ")) || "-"),
  chip: (r) => td("muted", esc(r.chip)),
};
const POD_COLS = { pod: ["pod"], namespace: ["namespace"], cpu: ["cpu cores", "n"], mem: ["mem", "n"] };
const POD_CELLS = {
  pod: (r) => td("wrap", esc(r.pod)),
  namespace: (r) => td("muted", esc(r.namespace)),
  cpu: (r) => td("n", cpuCores(r.cpu)),
  mem: (r) => td("n", bytes(r.mem)),
};
// A Docker container's row or a process name's (hub_core::host_now::Proc): the empty column hides.
const PROC_COLS = { name: ["name"], image: ["image"], cpu: ["cpu cores", "n"], mem: ["mem", "n"], count: ["count", "n"] };
const PROC_CELLS = {
  name: (r) => td("wrap", esc(r.name)),
  image: (r) => td("muted wrap", esc(r.image)),
  cpu: (r) => td("n", cpuCores(r.cpu)),
  mem: (r) => td("n", bytes(r.mem)),
  count: (r) => td("n", r.count == null ? "-" : String(r.count)),
};

// An agent session (hub_core::host_now::Session): its scope's project and item, then its test runs.
const SCOPE_COLS = { project: ["project"], item: ["item"], cpu: ["cpu cores", "n"], mem: ["mem", "n"], tests: ["tests"] };
const SCOPE_CELLS = {
  project: (r) => td("wrap", esc(r.project)),
  item: (r) => td("wrap", r.item ? esc(r.item) : "-"),
  cpu: (r) => td("n", cpuCores(r.cpu)),
  mem: (r) => td("n", bytes(r.mem)),
  tests: (r) => td("muted wrap", r.tests ? esc(r.tests) : "-"),
};

// One column per hour: the CPU's hottest sensor, amber from HOT_C.
function tempChart(h) {
  if (!h.hours.some((x) => x.temp != null)) return "";
  const cols = h.hours.map((x) => ({ key: String(x.at), label: dayTick(x.at),
    tip: x.temp == null ? `${stamp(x.at)}: ${NO_DATA}` : `${stamp(x.at)}: hottest ${degC(x.temp)}`,
    segs: [{ v: x.temp || 0, color: x.temp >= HOT_C ? "var(--b-stalled)" : OTHER }] }));
  return `${columns(cols, { height: 80, yfmt: degC })}<div class="muted">the CPU's hottest sensor each hour, amber from ${HOT_C}C</div>`;
}

// A part of `live` whose query failed: unknown, so it says not read and why, never none.
const unread = (l, part) => (l.unread[part] == null ? "" : `<div class="empty">${NOT_READ}: ${esc(l.unread[part])}</div>`);

// What runs on it now (hub_core::host_now): pods, then what runs outside Kubernetes.
function liveBody(d) {
  const l = d.live, t = d.tables;
  let h = secHead("", "Pods", t.pods.rows.length, "", "h3") + (unread(l, "pods") || pageTable(t.pods, POD_COLS, POD_CELLS, "No Kubernetes pod runs here."));
  const inv = unread(l, "inventory");
  if (inv) return h + secHead("", "Containers, processes, agent sessions, services", null, "", "h3") + inv;
  if (!l.inventory) return h + secHead("", "Containers, processes, agent sessions, services", null, "", "h3") + `<div class="empty">Not collected: no node_inventory.prom on it (home-config role node-inventory-metrics).</div>`;
  h += secHead("", "Containers", t.containers.rows.length, "", "h3") + pageTable(t.containers, PROC_COLS, PROC_CELLS, "No Docker container runs here.");
  const of = l.processes_total == null ? "" : ` of ${l.processes_total}`;
  h += secHead("", "Processes", `busiest ${t.processes.rows.length}${of}`, "", "h3") + pageTable(t.processes, PROC_COLS, PROC_CELLS, "No process reading.");
  h += secHead("", "Agent sessions", t.sessions.rows.length, "", "h3") + pageTable(t.sessions, SCOPE_COLS, SCOPE_CELLS, "No agent session runs in its own scope here.");
  return h + secHead("", "Services", l.services.length, "", "h3") + `<div class="panel">${esc(l.services.join("   ")) || "none running"}</div>`;
}

function machineBody(d) {
  const colors = poolColors(d);
  let h = `<div class="panel">${d.parts.map(pagePart).join("")}${pageRow("Read", clock(d.at * 1e3))}</div>`;
  const hot = d.tables.devices.rows.some((r) => r.hottest >= HOT_C);
  h += secHead("", "Sensors", d.tables.devices.rows.length, hot ? "warn" : "", "h3") + (!d.live ? `<div class="empty">${NOT_READ}.</div>` : unread(d.live, "sensors") || pageTable(d.tables.devices, DEVICE_COLS, DEVICE_CELLS, "Its node exporter publishes no hwmon reading."));
  const slots = d.tables.slots;
  const runners = slots.rows.filter((r) => r.runner);
  h += secHead("", "Slots", runners.length ? `${runners.filter((r) => r.now === "busy").length} of ${runners.length} busy` : null, "", "h3") + pageTable(slots, SLOTUSE_COLS, SLOTUSE_CELLS, "No runner and no core reading.");
  const run = (r) => `<tr>${td("", esc(r.slot))}${td("muted", tblLink(r.pool ? "#infra/pools/" + encodeURIComponent(r.pool) : "", r.pool))}${td("wrap", esc(r.job || "-"))}${td("muted", esc(ciRef(r)))}${td(`n${r.late ? " warn" : ""}`, secs(r.ran) + (r.late ? "!" : ""))}</tr>`;
  h += `${secHead("", "Running", d.running.length, "", "h3")}${d.running.length ? `<div class="panel scroll"><table class="tbl"><tr><th>slot</th><th>pool</th><th data-role="lead">job</th><th>ref</th><th class="n" data-role="glance">ran</th></tr>${d.running.map(run).join("")}</table></div>` : `<div class="empty">Nothing runs there now.</div>`}`;
  if (d.live) h += liveBody(d);
  const hist = d.history;
  if (hist) {
    h += secHead("", "7 days", `${hist.readings} reading${hist.readings === 1 ? "" : "s"}`, "", "h3") + historyChart(hist, d.cores, colors) + tempChart(hist);
    // An unread list says not read and why, never the empty text; a record lands once its downtime ends.
    h += secHead("", "Downtime", hist.down_unread == null ? d.tables.down?.rows.length : null, "", "h3") + (hist.down_unread != null ? `<div class="empty">${NOT_READ}: ${esc(hist.down_unread)}</div>` : pageTable(d.tables.down, DOWN_COLS, DOWN_CELLS, "No downtime record in the window. One is written once a downtime ends."));
  }
  h += `${secHead("", "Recent CI jobs", d.tables.recent.rows.length, "", "h3")}${pageTable(d.tables.recent, RECENT_COLS, RECENT_CELLS, "No CI job in the archive ran there.")}`;
  h += `${secHead("", "Alerts", d.tables.alerts?.rows.length, d.tables.alerts?.rows.length ? "warn" : "", "h3")}${pageTable(d.tables.alerts, PAGE_ALERT_COLS, PAGE_ALERT_CELLS, "Nothing firing names it.")}`;
  return h;
}

// One column per hour: its own jobs running; the jobs waiting under it.
function poolChart(h) {
  const n = (v) => (v == null ? "?" : v.toFixed(1));
  const tip = (x) => (x.running == null ? `${stamp(x.at)}: ${NO_DATA}` : `${stamp(x.at)}: ${n(x.running)} running, ${x.waiting ?? "?"} waiting at most`);
  const slots = h.hours.map((x) => ({ key: String(x.at), label: dayTick(x.at), tip: tip(x),
    segs: [{ v: x.running || 0, color: SLOTS[0] }] }));
  const wait = h.hours.map((x) => ({ key: String(x.at), label: dayTick(x.at), tip: tip(x), segs: [{ v: x.waiting || 0, color: "var(--b-stalled)" }] }));
  const key = [["running", SLOTS[0]]].map(([k, c]) => `<span class="chip sm" style="--c:${c}">${k}</span>`).join(" ");
  return `${columns(slots, { height: 120 })}<div class="muted">${key} hourly means of ${h.step / 60}-minute samples</div>`
    + `${columns(wait, { height: 60 })}<div class="muted"><span class="chip sm" style="--c:var(--b-stalled)">waiting</span> the most jobs waiting in each hour</div>`;
}

function poolBody(d) {
  let h = `<div class="panel">${d.parts.map(pagePart).join("")}${pageRow("Read", clock(d.at * 1e3))}</div>`;
  h += `${secHead("", "Machines", d.tables.machines?.rows.length, "", "h3")}${pageTable(d.tables.machines, MACH_COLS, MACH_CELLS, "No machine has a slot in it.")}`;
  h += `${secHead("", "Waiting", d.tables.waiting?.rows.length, "", "h3")}${pageTable(d.tables.waiting, QUEUED_COLS, QUEUED_CELLS, "Nothing waits for it.")}`;
  const hist = d.history;
  if (hist) h += secHead("", "7 days", `${hist.readings} reading${hist.readings === 1 ? "" : "s"}`, "", "h3") + poolChart(hist);
  return h;
}

$("infra").addEventListener("click", (e) => {
  const go = e.target.closest("[data-go]");
  if (go) { e.preventDefault(); setTab(go.dataset.go); return; }
});

function drawInfra() {
  const el = $("infra-main");
  const d = ist.data;
  // The strip comes first on every path, then each section in its inner tab's group
  // (hub_core::layout, app.js INNER_TABS). Runs, Pipelines and Tests with its Quarantine (ci.js)
  // and Jobs (jobs.js) are elements of their own under main, each painted by its own read.
  innerHide("infra", "runs", $("ci-runs"));
  innerHide("infra", "pipelines", $("ci-pipelines"));
  innerHide("infra", "tests", $("ci-tests"));
  innerHide("infra", "quarantine", $("ci-tests"));
  innerHide("infra", "jobs", $("jobs"));
  const strip = innerStrip("infra", infraFlagged(d));
  if (infraPage()) { paint(el, strip + infraPageHtml()); return; }
  // A run's own page stands in for the Runs table, as a machine's does for Machines.
  if (ciRunId()) { $("ci-runs").hidden = true; paint(el, strip + runPage()); return; }
  if (!d) { paint(el, strip + `<div class="empty">${ist.err ? esc(ist.err) : "Loading..."}</div>`); return; }
  const links = `${gLink("kb-command-center", "Command Center")} ${gLink("kb-ci-runners", "CI / Runners")} ${gLink("kb-fleet", "Machines")} ${gLink("kb-agents-overview", "Agents")}`;
  // As the board blanks: a failed read never leaves the last (maybe green) numbers up.
  if (!d.ok) { paint(el, strip + `<div class="bhead"><span>infra</span><span>${links}</span></div><div class="panel down">${esc(d.error || "Prometheus did not answer")}</div>`); seekSection(); return; }
  const cc = ccIndex(d.instant.cc), t1 = d.at * 1e3;
  // Home owns what waits on you; Infra shows its count (Home::waiting, the badge's number) as a link to it.
  const w = st.waiting;
  const badge = w === null ? ` <span class="chip sm" style="--c:var(--b-needs)" title="${NOT_READ}">waiting on you: ${NOT_READ}</span>`
    : w && w.count > 0 ? ` <a href="${esc(w.href)}" class="chip sm" style="--c:var(--b-needs)">${w.count} waiting on you, on Home</a>` : "";
  let html = strip + `<div class="bhead"><span>${overallPill(cc)}${badge} <span class="muted">read ${clock(t1)}</span></span>${pfold("infra-links", "Grafana", links)}</div>`;
  html += innerWrap("infra", "machines", `${kpis(d.kpis)}${spaceSection(d.space)}${secHead("machines", "Machines", infraN("machines"))}${INFRA_T.machines.html()}${pendingLine(d.ci.glance)}`);
  html += innerWrap("infra", "pools", secHead("pools", "Job kinds", infraN("pools")) + INFRA_T.pools.html());
  html += innerWrap("infra", "ci", runnersSection(d.ci)) + innerWrap("infra", "waiting", waitingSection()) +
    innerWrap("infra", "local", localSection(d.ci));
  paint(el, html, ist.open);
  seekSection();
}

// The OVERALL pill is cc:overall_status, the heart: RED when a domain is down, else OK, since a
// warn never colours it (home-config prometheus-rules-command-center.yaml, the human's
// 2026-11-12 call). Its warn domains (cc:domain_status 1, hub_core Infra::domains) follow as an
// amber count naming them in its hover, so an OK heart beside amber tiles says why (ar-5013). It
// is no link: a record link comes from hub_core::links (links.test.mjs), and none serves health.
function overallPill(cc) {
  const [word, color] = statusOf((cc["cc:overall_status"] || {})[""]);
  const warn = Object.entries(cc["cc:domain_status"] || {}).filter(([, v]) => v === 1).map(([d]) => d).sort();
  const why = "the health heart: red when a domain is down; a warn domain shows on its tile and Alerts' health chips";
  const warns = warn.length ? ` <span class="chip sm" style="--c:var(--b-stalled)" title="${esc(`at warn: ${warn.join(", ")}; Alerts' health chips say why`)}">${warn.length} warn</span>` : "";
  return `<span class="chip" style="--c:${color}" title="${why}">OVERALL ${word}</span>${warns}`;
}

// A table's search or dropdown in use keeps focus: only that table's rows and chips repaint, and
// the others redraw around it (home.js renderHome).
function renderInfra() {
  const busy = ist.data?.ok && Object.values(INFRA_T).find((t) => t.repaint());
  if (busy) { for (const [name, t] of Object.entries(INFRA_T)) if (t !== busy && $(`infra-${INFRA_TABLES[name]}-body`)) t.redraw(); return; }
  drawInfra();
}

// The sections whose inner tab carries a count: Runners' lines hub_core::ci judged red (a queued
// job no online runner can take), runs that need a look (Builds::needs_look), a red pipeline
// (Pipelines::red) and a failed suite in the Tests run on show (ci.js); the hub's
// App::infra_flagged reads the same.
const infraFlagged = (d) => [d && d.ci && (d.ci.red || []).length && "ci", bld.data?.look && "runs", pip.data?.red > 0 && "pipelines",
  tst.data?.totals?.failed_suites > 0 && "tests"].filter(Boolean);

const pollInfra = poll("infra", refreshInfra, INFRA_REFRESH_MS);

TABS.infra = {
  // The Jobs section (jobs.js) reads its own source on its own timer; Runs, Pipelines and Tests
  // (ci.js) read on show and again on each new ledger line (and Pipelines on a state.json write).
  show() {
    const page = infraPage() ? st.page : "";
    if (page !== pgst.page) { Object.assign(pgst, { page, data: null, err: null }); if (page) refreshPage(); }
    showRunPage();
    renderInfra(); pollInfra(); showJobs(); bldFeed.show(!bld.data || bld.moved()); pipFeed.show(!pip.data || pip.moved()); tstFeed.show(!tst.data || tst.moved());
    // A section not read yet says so at once: its read paints it only when it answers (a cold
    // /api/pipelines takes seconds), and an empty element reads as a broken tab.
    for (const t of [bld, pip, tst]) if (!t.data) t.render();
  },
  // Nothing on this machine changes Prometheus, so file events do not apply; only a resync does.
  onEvent(ev) {
    if (ev.kind === "resync" && st.tab === "infra") { refreshInfra(); jst.refresh(); }
    bldFeed.onEvent(ev); pipFeed.onEvent(ev); tstFeed.onEvent(ev); runFeed.onEvent(ev);
  },
};
