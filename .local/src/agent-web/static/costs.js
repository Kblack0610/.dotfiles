"use strict";
// The Costs tab: what the fleet spent, cut eight ways, with fleet-bench's evaluation on the model
// and harness cuts. /api/costs is hub_core::costs::board, the view the hub TUI draws; this file
// draws its answer and turns a click into the view keys (by, w, q, sort, dir, and Spend's day, dq,
// dsort, ddir, sid) in the URL, so
// `#costs?by=model&w=7d&q=harness:codex` is a link to that view. Trends are Grafana's. Above the
// tiles: the whole fleet's 24h cost, who pays (Burn, one row per source claude-acct reads), who
// spends (Consumers, one row per runner or gateway key with a priority), where the tokens go and
// what Langfuse sees; the Budget inner tab is what we pay in cash this month.

// open: the folded sections' state; tokWin: the tokens section's window.
const cost = tblTab({
  tab: "costs", id: "costs", api: "/api/costs", hint: "search, or harness:codex -model:opus project:dotfiles",
  state: { open: {}, tokWin: "week" }, open: () => cost.open,
  // The view keys past the table's: the cut, the window and the sessions sort.
  params: (p) => { const v = new URLSearchParams(st.views.costs || ""); for (const k of ["by", "w", "ssort", "sdir", "day", "dq", "dsort", "ddir", "sid", "csort", "cdir"]) if (v.get(k)) p.set(k, v.get(k)); },
  head: (t) => costsHead(t.data), lead: () => innerStrip("costs"),
  // The table (its bar and rows) belongs to the Spend inner tab, with the switches above it.
  wrap: (html) => innerWrap("costs", "table", html),
  body: (t) => costsBody(t.data), tail: (t) => costsTail(t.data),
  // A poll repaints the whole tab: the day search being typed keeps its text and focus.
  draw: (html) => keepTyping("#costs [data-id]", () => paint($("costs"), html, cost.open)),
});

// Every source is a file written nightly or per call; only the token snapshots push (onEvent), so
// the open tab re-reads on the Infra cadence; the server folds reads inside two minutes into one.
const COSTS_REFRESH_MS = INFRA_REFRESH_MS;

// A column key as its header, the TUI's words (coststab.rs `header`); [text, class].
const COST_COLS = {
  session: ["session"], tool: ["tool"], skill: ["skill"], kind: ["kind"], project: ["project"], harness: ["harness"],
  model: ["model"], runner: ["runner"], sessions: ["sess", "n"], calls: ["calls", "n"], tokens: ["tokens", "n"],
  cost: ["cost", "n"], share: ["share of table", "n"], landed: ["landed", "n"], redo: ["redo", "n"], reverts: ["rev", "n"],
  per_pr: ["$/PR", "n"], src: ["src"], pr: ["PR"], at: ["updated", "n"],
};


// One cell, as the TUI prints it (coststab.rs `show`).
function costCell(r, key, d) {
  const num = COST_COLS[key][1] === "n";
  const v = r[key];
  let html;
  if (d.unpriced && (key === "cost" || key === "share")) html = "-";
  else if (key === "cost" || key === "per_pr") html = usd(v);
  else if (key === "tokens") html = kfmt(v == null ? null : Math.round(v));
  else if (key === "share") html = pct(v);
  else if (key === "landed") html = v == null ? "-" : v.toFixed(2);
  else if (key === "at") html = when(v);
  else if (key === "session") html = v ? `<span title="${esc(r.title || v)}">${esc(v.slice(0, 8))}</span>` : "-";
  else html = v == null || v === "" ? "-" : esc(String(v));
  const warn = key === "src" && v === "mixed" ? " warn" : "";
  return `<td class="${num ? "n" : ""}${warn}">${html}</td>`;
}

function costsBody(d) {
  const t = d.table, rows = d.rows || [];
  if (!rows.length) return `<div class="panel">${t.total ? "Nothing matches the query." : "Nothing spent in this window."}</div>`;
  const shown = rows.slice(0, LOG_ROWS);
  // The table sends every Line column in one order; each cut draws its own (model before harness).
  const head = { ...t, columns: d.columns.map((k) => t.columns.find((c) => c.key === k)).filter(Boolean) };
  return `<div class="panel scroll"><table class="tbl">${tblHead(head, Object.fromEntries(d.columns.map((k) => [k, COST_COLS[k]])))}` +
    shown.map((r) => `<tr>${d.columns.map((k) => costCell(r, k, d)).join("")}</tr>`).join("") + `</table>${older(rows.length - shown.length)}</div>`;
}

// The window and cut switches: each a link, so a view is a URL.
function costsSwitch(name, all, on, key, label = (x) => x) {
  return `<div class="seg fseg"><span class="muted">${name}</span>` + all.map((x) =>
    `<button class="${x === on ? "on" : ""}" data-cv="${key}" data-cval="${esc(x)}">${esc(label(x))}</button>`).join("") + `</div>`;
}

// Direct Lazer use, the TUI's `direct` line, with what it cannot see beside it, so a low figure
// never reads as all of it. The pool and its keys are Burn rows.
function directTile(dr) {
  const unpriced = dr.unpriced ? `<span class="warn">+${dr.unpriced} unpriced</span>, ` : "";
  return tile("LAZER DIRECT", usd(dr.usd), "var(--c3)", unpriced + esc(dr.note || "not read"));
}

// The Spend tile row on the shared tile(): the whole fleet's 24h (hub_core::fleet_cost, the TUI's
// `fleet_head`), then the outcomes windows and direct Lazer use, each sub saying what it counts.
function costsTiles(d) {
  return `<div class="tiles roomy" id="sec-totals">` + fleetTile(d.fleet_cost || { why: "nothing read" }) + (d.totals || []).map((t) =>
    tile(`SPEND ${t.window.toUpperCase()}`, usd(t.usd), t.window === d.window ? "var(--c1)" : "var(--c-other)", `outcomes, ${t.sessions} sessions${t.unpriced ? `, ${t.unpriced} unpriced` : ""}`)).join("") +
    directTile(d.direct || {}) + `</div>` + (d.totals_note ? `<div class="muted fold">${esc(d.totals_note)}</div>` : "");
}

function fleetTile(f) {
  if (f.why) return tile("FLEET 24H", "-", "var(--c2)", `<span class="warn">${esc(f.why)}</span>`);
  const age = f.stale ? `<span class="warn">stale, as of ${when(f.as_of)}</span>` : `as of ${when(f.as_of)}`;
  return tile("FLEET 24H", esc(f.usd), "var(--c2)", `whole fleet, measured ${esc(f.measured)}, estimated ${esc(f.estimated)}, ${age}`);
}

// Who spent the fleet's 24h: hub_core::fleet_cost builds every row and word, the TUI's `fleet`
// draws the same ones. Every percentage is of the whole-fleet total, which leads the tile row.
function fleetCostSection(d) {
  const f = d.fleet_cost;
  if (!f || f.why) return "";
  // Every column is on a phone's row too: "estimated" is never behind a tap.
  const row = (r) => `<tr><td>${esc(r.name)}</td><td class="n">${esc(r.cost)}</td><td class="n">${esc(r.share)}</td><td class="muted">${esc(r.basis)}</td></tr>` +
    (r.detail ? `<tr><td></td><td colspan="3" class="muted wrap">${esc(r.detail)}</td></tr>` : "");
  return `<h2 class="sec" id="sec-fleet">Who spent the 24h</h2>` +
    pfold("cost-fleet", `${f.rows.length} rows`, `<div class="panel scroll"><div class="muted">${esc(f.coverage)}</div>` +
    `<table class="tbl"><tr><th data-role="lead">who</th><th class="n" data-role="glance">cost</th><th class="n" data-role="glance">% of fleet</th><th data-role="glance">measured or estimated</th></tr>${f.rows.map(row).join("")}</table>` +
    f.unpriced.map((u) => `<div class="warn">${esc(u)}</div>`).join("") +
    `<div class="muted">${esc(f.foot)}</div></div>`);
}

// The Budget inner tab (hub_core::budget, the TUI's coststab.rs `budget`): this month's cash, what
// needs a look, the bills grouped (agents, CI, infra), then the split by project and lane. List price stays on Spend.
function budgetSection(d) {
  const b = d.budget || { why: "nothing read" };
  const title = `<h2 class="sec" id="sec-budget">Budget`;
  if (b.why) return `${title}</h2><div class="panel"><span class="warn">${esc(b.why)}</span></div>`;
  const age = b.stale ? `<span class="warn">stale, as of ${when(b.as_of)}</span>` : `as of ${when(b.as_of)}`;
  const partial = b.partial.length ? `<div class="warn">partial, not counted: ${esc(b.partial.join(", "))}</div>` : "";
  const needs = b.needs.length ? `<h3 class="warn">Needs a look ${b.needs.length}</h3>` + b.needs.map((n) => `<div class="warn">${esc(n)}</div>`).join("") : "";
  // A bill off ok (over, unread, unpriced) is amber on its name and its spend.
  const row = (x) => { const w = x.status === "ok" ? "" : "warn"; return `<tr><td class="${w}">${esc(x.name)}</td><td class="muted">${esc(x.kind)}</td><td class="n">${esc(x.cap)}</td>` +
    `<td class="n ${w}">${esc(x.spent)}</td><td class="n">${esc(x.month)}</td><td class="muted wrap">${esc(x.note)}</td></tr>`; };
  const shares = (xs) => xs.map((x) => `${esc(x.name)} ${esc(x.usd)}`).join(", ");
  // Each group (agents, CI, infra) is a heading row with our cash in it, then its bills.
  const group = (g) => `<tr class="allrow"><td>${esc(g.name)}</td><td></td><td></td><td class="n">${esc(g.spent)}</td><td class="n">${esc(g.month)}</td><td></td></tr>` +
    g.bills.map(row).join("");
  return `${title} ${esc(b.spent)} so far, ${esc(b.projected)} by month end <span class="muted">${esc(b.month)}, caps ${esc(b.caps)}, ${age}</span></h2>` +
    `<div class="panel scroll">${partial}${needs}` +
    `<table class="tbl"><tr><th data-role="lead">bill</th><th>kind</th><th class="n">cap</th><th class="n" data-role="glance">so far</th><th class="n" data-role="glance">month est.</th><th>note</th></tr>${b.groups.map(group).join("")}</table>` +
    `<div><b>By project</b> ${shares(b.by_project)}</div><div><b>By lane</b> ${esc(b.by_lane.join(", "))}</div><div class="muted">${esc(b.foot)}</div></div>`;
}

// The Spend section (hub_core::spend_history, the TUI's coststab.rs `history`, `spend_chart` and
// `day_table`): the fleet's $/day over 30 calendar days (billed and estimated stacked, a day with
// no figure an empty column), its months, then the picked day's sessions on the shared table and
// the opened session's own days. Open unless the reader folds it; the year/month/day rows fold.
const SESS_COLS = {
  session: ["session"], project: ["project"], origin: ["origin"], agent: ["agent"], harness: ["harness"],
  cost: ["cost", "n"], share: ["of day", "n"], est: ["est.", "n"], days: ["days", "n"],
};
const spendBars = (bars, every) => bars.map((b, i) => ({
  key: b.key, tip: b.tip, label: i % every === every - 1 || i === bars.length - 1 ? b.label : "",
  segs: [{ v: b.measured, color: "var(--c1)" }, { v: b.estimated, color: "var(--c-other)" }],
}));
const SPEND_KEY = legend([["billed", "var(--c1)"], ["estimated from tokens", "var(--c-other)"]]);

function sessCell(r, k) {
  if (k === "cost") return `<td class="n">${usd(r.cost)}</td>`;
  if (k === "share" || k === "est") return `<td class="n">${Math.round(r[k])}%</td>`;
  if (k === "days") return `<td class="n">${r.days}</td>`;
  if (k === "session") return `<td title="${esc(r.sid)}">${esc(r.session)}</td>`;
  return `<td>${r[k] == null ? "-" : esc(r[k])}</td>`;
}

// The day switch over the table: the chart's last week of days with a figure, the picked one on,
// so a day is one tap without finding its bar.
function dayChips(chart, on) {
  const days = chart.filter((b) => b.usd != null).slice(-7).map((b) => b.key);
  if (on && !days.includes(on)) days.push(on), days.sort();
  return costsSwitch("day", days, on, "day", (k) => k.slice(5));
}

function dayTable(dv, dq) {
  if (dv.why) return `<div class="panel muted">${esc(dv.why)}</div>`;
  const t = dv.table;
  const series = dv.series ? `<div class="panel"><h3>${esc(dv.series.session)} <span class="muted">${esc(dv.series.total)} in the chart's 30 days; its row again closes this</span></h3>` +
    `<div id="spend-series">${columns(spendBars(dv.series.bars, 7), { height: 80, sel: dv.day, yfmt: usd })}</div></div>` : "";
  const rows = dv.rows.map((r) => `<tr data-sid="${esc(r.sid)}" class="${dv.series && dv.series.sid === r.sid ? "sel" : ""}">` +
    Object.keys(SESS_COLS).map((k) => sessCell(r, k)).join("") + `</tr>`).join("");
  return `<div class="card bfilter qcfilter" data-id="spend-dq"><div class="opts"><input data-dq data-free placeholder="search the day, or project:dotfiles origin:runner" value="${esc(dq)}"> <span class="muted">${t.shown} of ${t.total}, ${esc(dv.shown_usd)}</span></div></div>` +
    series + `<div class="panel scroll"><table class="tbl">${tblHead(t, SESS_COLS, "d")}${rows}</table>` +
    (dv.more ? `<div class="muted">+${dv.more} more under this query: narrow it to see them</div>` : "") + `</div>`;
}

// Burn per session, per day: the picked day's sessions ranked by what they cost, a day switch over
// them, and a row opens that session's own days. Spend's first section, so it is not under charts.
function sessionsSection(d) {
  const h = d.history, dv = d.day;
  if (!h || h.why || !dv) return "";
  const dq = new URLSearchParams(st.views.costs || "").get("dq") || "";
  return `<details class="csec" data-k="spend-sessions" id="sec-sessions"${secOpen(cost.open, "spend-sessions") ? " open" : ""}><summary><h2 class="sec">Burn per session ` +
    `<span class="muted">${esc(dv.head || dv.day || "")}</span></h2></summary>` +
    `<div class="panel">${dayChips(h.chart || [], dv.day)}</div>` + dayTable(dv, dq) + `</details>`;
}

function historySection(d) {
  const h = d.history;
  if (!h) return "";
  const title = `<h2 class="sec">Spend`;
  if (h.why) return `<div id="sec-spend">${title} <span class="muted">${esc(h.why)}</span></h2></div>`;
  const stale = h.stale ? ` <span class="warn">stale: no snapshot for yesterday</span>` : "";
  const row = (r) => `<tr class="${r.kind === "day" ? "" : "allrow"}"><td>${esc(r.period)}</td><td class="n">${esc(r.total)}</td><td class="n">${r.days}</td>` +
    `<td class="n">${esc(r.per_day)}</td><td class="n">${esc(r.vs_prev)}</td><td class="n">${esc(r.est)}</td></tr>`;
  const dv = d.day || {};
  const charts = `<div class="spendcharts"><div class="panel"><h3>$/day, last 30 days, click a day for its sessions above ${SPEND_KEY}</h3>` +
    `<div id="spend-days">${columns(spendBars(h.chart, 7), { height: 160, sel: dv.day, yfmt: usd })}</div></div>` +
    (h.months.length ? `<div class="panel"><h3>By month</h3>${columns(spendBars(h.months, 1), { height: 160, yfmt: usd })}</div>` : "") + `</div>`;
  const periods = `<details class="sec-d" data-k="spend-periods"${secOpen(cost.open, "spend-periods") ? " open" : ""}><summary class="muted fold">Year, month and day rows</summary>` +
    `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">period</th><th class="n">total</th><th class="n">days</th><th class="n" data-role="glance" data-named>$/day</th><th class="n" data-role="glance" data-named>vs prev</th><th class="n" data-role="glance" data-named>est.</th></tr>` +
    h.rows.map(row).join("") + `</table>${h.older ? older(h.older) : ""}` +
    (h.missing ? `<div class="warn">${h.missing} days in the range have no figure and are not counted</div>` : "") +
    `</div><div class="muted fold">${esc(h.note)}</div></details>`;
  return `<details class="csec" data-k="spend" id="sec-spend"${secOpen(cost.open, "spend") ? " open" : ""}><summary>${title} <span class="muted">${esc(h.head)}</span>${stale}</h2></summary>` +
    charts + periods + `</details>`;
}

// The Burn section (hub_core::burn, the hub's coststab.rs `burn`): the headline coloured by the
// fleet's level, then the drip, when the accounts are back on pace and one row per source. It
// starts open until the reader folds it (dashboards rule 4), except on a phone, where the headline
// is the verdict and the tables wait for a tap. A phone has its own fold key, because paint
// remembers every fold it saw and its closed one would stick.
function burnPace(b) {
  const p = b.pace;
  if (p.on_pace) return "every source is on pace";
  const burn = p.at_burn.length ? p.at_burn.map(([n, t]) => `${esc(n)} ${when(t)}`).join(", ") : "not before the reset";
  const idle = p.idle_all_by == null ? "" : `; if idle: all by ${when(p.idle_all_by)}${p.idle_rest_after_reset ? ", the rest after the reset" : ""}`;
  return `at this burn: ${burn}${idle}`;
}

// A back-on-pace cell: on pace, the time, or after the reset (Account::on_pace); nothing for a
// dollar budget, which has no pace line.
const burnCell = (a, t, at) => (a.unpaced ? "-" : !(a.used > a.gone) || (t != null && t <= at) ? "on pace" : t == null ? "after reset" : when(t));

// The Burn table's columns, the TUI's header in its order; true is a number column, and the third
// entry is the column's place in a phone's row.
const BURN_COLS = [["source", false, ' data-role="lead"'], ["kind"], ["live", true], ["bar"], ["used", true, ' data-role="glance" data-named'], ["gone", true, ' data-role="glance" data-named'], ["reserve", true], ["room", false, ' data-role="glance"'], ["burn/h", true], ["keeps/h", true],
  ["at burn"], ["if idle"], ["runs out"], ["resets"], ["5h", true], ["5h resets"], ["$24h", true]];
// A key is a dollar budget: the columns that always say nothing for one are left out.

function burnRow(a, at, note, cols) {
  // a row with no figures: its name, then one cell across the rest
  const span = (cls, text) => `<tr><td>${esc(a.name)}</td><td colspan="${cols.length - 1}" class="${cls}">${esc(text)}</td></tr>`;
  if (a.state === "unreadable") return span("bad", "usage unreadable");
  if (a.state === "stale") return span("bad", note);
  // burn::idle_note's words
  if (a.state === "idle") return span("muted", a.kind === "claude" ? "idle, token refreshes on launch" : "no usage read yet");
  const pc = (v) => (v == null ? "-" : Math.floor(v) + "%");
  const rate = (v) => (v == null || a.unpaced ? "-" : v.toFixed(2));
  const cells = {
    source: `<td>${esc(a.name)}</td>`, kind: `<td>${esc(a.kind)}</td>`, live: `<td class="n">${a.live}</td>`,
    // the fill is the share used, the tick the share of the week gone; a dollar budget has no week
    bar: `<td>${meter(a.used / 100, null, a.unpaced || a.gone == null ? null : a.gone / 100)}</td>`,
    used: `<td class="n">${esc(a.used_text)}</td>`, gone: `<td class="n">${pc(a.gone)}</td>`, reserve: `<td class="n">${pc(a.reserve)}</td>`,
    room: `<td class="${a.room ? (a.room.ok ? "ok" : "bad") : "muted"}">${a.room ? esc(a.room.text) : "-"}</td>`,
    "burn/h": `<td class="n${!a.unpaced && a.sustain != null && a.burn > a.sustain ? " warn" : ""}">${rate(a.burn)}</td>`, "keeps/h": `<td class="n">${rate(a.sustain)}</td>`,
    "at burn": `<td>${burnCell(a, a.burn_at, at)}</td>`, "if idle": `<td>${burnCell(a, a.idle_at, at)}</td>`, "runs out": `<td>${when(a.run_out)}</td>`, resets: `<td>${when(a.resets)}</td>`,
    "5h": `<td class="n">${pc(a.five_hour)}</td>`, "5h resets": `<td>${when(a.five_hour_resets)}</td>`, "$24h": `<td class="n">${usd(a.cost_24h)}</td>`,
  };
  return `<tr>${cols.map(([t]) => cells[t]).join("")}</tr>`;
}

// hub-core's total row (burn::Total); the columns it has no sum for print a dash.
function burnTotal(f, cols) {
  if (!f) return "";
  const cells = {
    source: `<td><b>total</b></td>`, live: `<td class="n">${f.live}</td>`,
    "burn/h": `<td class="n${f.over ? " warn" : ""}">${f.burn.toFixed(2)}</td>`, "keeps/h": `<td class="n">${f.sustain.toFixed(2)}</td>`,
    "runs out": `<td>${when(f.run_out)}</td>`, "$24h": `<td class="n">${usd(f.cost_24h)}</td>`,
  };
  return `<tr class="tot">${cols.map(([t, num]) => cells[t] || `<td${num ? ' class="n"' : ""}>-</td>`).join("")}</tr>`;
}

const burnTable = (b, cols, rows) => `<table class="tbl"><tr>${cols.map(([t, n, phone]) => `<th${n ? ' class="n"' : ""}${phone || ""}>${t}</th>`).join("")}</tr>` +
  rows.map((a) => burnRow(a, b.at, b.stale, cols)).join("") + burnTotal(b.total, cols) + `</table>`;

// The keys inside a pool are Consumers rows, so Burn only points there.
const burnKeys = (b) => (b.keys ? `<div class="panel"><span class="muted">KEYS</span> <span class="${b.keys.level !== "ok" ? "warn" : "muted"}">${esc(b.keys.head)}</span> <a href="#costs/consumers">rows in Consumers</a></div>` : "");

// Every LLM consumer (hub_core::gateway, the TUI's coststab.rs `consumers`): a runner with a
// priority, or a gateway key no runner names, with what it runs on, its budget, spend and fallback.
// Open like every section (rule 4), its hue on the headline; its headers sort apart from the
// table's (csort/cdir).
function costsConsumers(d) {
  const c = d.consumers;
  if (!c || !c.table) return "";
  const cls = c.level === "ok" ? "muted" : `burn ${c.level === "bad" ? "bad" : "warn"}`;
  const open = secOpen(cost.open, "consumers");
  const labels = Object.fromEntries(c.columns.map((k, i) => [k, [c.headers[i].toLowerCase()]]));
  const row = (r) => `<tr>${c.columns.map((k) => `<td${r.level === "bad" ? ' class="bad"' : ""}>${esc(r[k])}</td>`).join("")}</tr>`;
  const notes = [c.stale, ...c.errors].filter(Boolean).map((e) => `<div class="warn">${esc(e)}</div>`).join("");
  return `<details class="csec" data-k="consumers" id="sec-consumers"${open ? " open" : ""}><summary><h2 class="sec">Consumers <span class="${cls}">${esc(c.head)}</span></h2></summary>` +
    (notes ? `<div class="panel">${notes}</div>` : "") +
    (c.rows.length ? `<div class="panel scroll"><table class="tbl">${tblHead(c.table, labels, "c")}${c.rows.map(row).join("")}</table></div>` : "") +
    `<div class="panel muted">${c.pools.map((l) => `<div>${esc(l)}</div>`).join("")}<div>${esc(c.routes)}</div></div>` +
    `<div class="muted fold">${c.legend.map(([t, x]) => `${esc(t.toLowerCase())}: ${esc(x)}`).join("; ")}</div></details>`;
}

function costsBurn(d) {
  const b = d.burn;
  if (!b || !b.accounts.length) return `<h2 class="sec" id="sec-burn">Burn</h2><div class="panel muted">no data from claude-acct</div>`;
  const cls = b.level === "bad" ? "bad" : b.level === "warn" ? "warn" : "ok";
  const held = b.drip.held ? ` <a class="warn" href="#sessions" title="${esc(b.drip.held)}">dispatch held -> Sessions</a>` : "";
  const key = isPhone() ? "burn-phone" : "burn", open = isPhone() ? !!cost.open[key] : secOpen(cost.open, key);
  return `<details class="csec" data-k="${key}" id="sec-burn"${open ? " open" : ""}><summary><h2 class="sec">Burn <span class="burn ${cls}">${esc(b.head)}</span></h2></summary>` +
    `<div class="panel"><div><span class="muted">DRIP</span> ${esc(b.drip_line)}${held}</div>` +
    `<div><span class="muted">BACK ON PACE</span> ${burnPace(b)}</div></div>` +
    `<div class="panel scroll">${burnTable(b, BURN_COLS, b.accounts.filter((a) => !a.nested))}</div>` + burnKeys(b) +
    (b.legend?.length ? `<div class="muted fold">${b.legend.map(([t, d]) => `${esc(t.toLowerCase())}: ${esc(d)}`).join("; ")}</div>` : "") + "</details>";
}

// One table of a tokens window; a named row takes its chart slot, Other its grey (rule 5).
function tokensTable(title, rows) {
  const row = (r, i) => `<tr><td>${esc(r.name)}</td><td class="n">${r.calls.toLocaleString()}</td><td class="n">${kfmt(r.chars)} ch</td>` +
    `<td class="m">${meter(r.share, SLOTS[i] && !r.other ? SLOTS[i] : OTHER)}</td><td class="n">${(r.share * 100).toFixed(1)}%</td><td class="n">${kfmt(r.carried_tokens)}</td></tr>`;
  return `<table class="tbl"><tr><th data-role="lead">${title}</th><th class="n" data-role="glance" data-named>calls</th><th class="n" data-role="glance" data-named>output</th><th>share</th><th class="n" data-role="glance" data-named>% of output</th><th class="n">re-read</th></tr>${rows.map(row).join("")}</table>`;
}

const TOK_WINDOWS = { day: "yesterday", week: "7d" };

// Where the tokens go: hub-core's `tokens` sums the snapshots; it starts open (rule 4), its head
// amber once stale.
// The dollars per tool are the tool cut of the table below, so this links there.
function tokensSection(d) {
  const t = d.tokens;
  if (!t) return `<h2 class="sec" id="sec-tokens">Where the tokens go <span class="warn">no snapshot in ~/.agent/token-usage</span></h2>`;
  const w = t[cost.tokWin], key = "tokens", open = secOpen(cost.open, key);
  const week = `7d ${kfmt(t.week.context)}, tool output ${pct(t.week.carried_share)}`;
  const head = t.stale ? `<span class="warn">${week}, stale: newest snapshot ${esc(t.date)}</span>` : `<span class="muted">${week}</span>`;
  const seg = `<div class="seg fseg"><span class="muted">window</span>` + Object.entries(TOK_WINDOWS).map(([k, l]) =>
    `<button class="${k === cost.tokWin ? "on" : ""}" data-tokwin="${k}">${l}</button>`).join("") + `</div>`;
  const partial = w.partial ? `<span class="warn">, ${w.partial} of ${w.days} partial</span>` : "";
  return `<details class="csec" data-k="${key}" id="sec-tokens"${open ? " open" : ""}><summary><h2 class="sec">Where the tokens go ${head}</h2></summary>` +
    `<div class="panel scroll">${seg}<div class="muted">${cost.tokWin === "day" && t.stale ? esc(t.date) : TOK_WINDOWS[cost.tokWin]}: ${kfmt(w.context)} context, ${kfmt(w.per_response)}/response, tool output carried ${pct(w.carried_share)} ` +
    `(snapshot ${esc(t.date.slice(5))}, ${t.generated_at ? clock(t.generated_at * 1e3) : "-"}${partial})</div>` +
    tokensTable("by tool", w.tools) + tokensTable("by Bash command", w.commands) +
    `<div class="muted more">counted by claude-recall tool-output, nightly; dollars per tool: <a href="#costs?by=tool&w=7d">the tool cut</a></div></div></details>`;
}

// A duration in ms as the tool table reads it: 99ms, 17.5s.
const lfMs = (ms) => (ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`);
const lfClasses = (cs) => cs.length ? cs.map((c) => `${esc(c.name)} ${c.n.toLocaleString()}`).join(", ") : "none";

// What Langfuse sees: the figures only it has (tool latency, tool errors by class, gateway errors
// and cost), the newest snapshot's `.langfuse` through hub-core's `tokens`. It starts open (rule 4),
// its head amber when the reader failed that night or the snapshot is stale. The
// gateway's dollars are the gateway's alone; session cost is Fleet cost 24h, so none is summed here.
function langfuseSection(d) {
  const t = d.tokens, lf = t?.langfuse;
  if (!t) return "";
  const f = lf?.figures, key = "langfuse", open = secOpen(cost.open, key);
  const title = `<h2 class="sec">What Langfuse sees `;
  if (!f) {
    return `<details class="csec" data-k="${key}" id="sec-langfuse"${open ? " open" : ""}><summary>${title}<span class="warn">no figures in snapshot ${esc(t.date)}</span></h2></summary>` +
      `<div class="panel"><div class="warn">${esc(lf?.why || "the snapshot has no langfuse section: written before the reader, or the run stopped")}</div>` +
      `<div class="muted more">read nightly by agent-usage langfuse; the Sentinel watch langfuse-read trips after two nights</div></div></details>`;
  }
  const head = `tool errors ${pct(f.tool_error_share)}, gateway errors ${pct(f.gateway_error_share)}, ${usd(f.gateway_cost_usd)} gateway`;
  const rows = f.tools.map((x) => `<tr><td>${esc(x.tool)}</td><td class="n">${x.calls.toLocaleString()}</td><td class="n">${lfMs(x.p50_ms)}</td><td class="n">${lfMs(x.p95_ms)}</td><td class="n">${secs(x.total_s)}</td></tr>`).join("");
  const models = f.gateway_models.map((m) => `${esc(m.model)} ${usd(m.cost_usd)}`).join(", ") + (f.gateway_other_models ? `, ${f.gateway_other_models} more` : "");
  const trunc = f.truncated ? `<span class="warn"> (classes partial: more errors than were paged)</span>` : "";
  return `<details class="csec" data-k="${key}" id="sec-langfuse"${open ? " open" : ""}><summary>${title}<span class="${t.stale ? "warn" : "muted"}">${head}${t.stale ? `, stale: newest snapshot ${esc(t.date)}` : ""}</span></h2></summary>` +
    `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">slowest tools, by total time</th><th class="n" data-role="glance" data-named>calls</th><th class="n">p50</th><th class="n" data-role="glance" data-named>p95</th><th class="n" data-role="glance" data-named>total</th></tr>${rows}</table>` +
    `<div class="muted">tool errors: ${f.tool_errors.toLocaleString()} of ${f.tool_executions.toLocaleString()} executions (${lfClasses(f.tool_error_classes)})${trunc}</div>` +
    `<div class="muted">gateway: ${f.gateway_calls.toLocaleString()} calls, ${f.gateway_errors.toLocaleString()} errors (${lfClasses(f.gateway_error_classes)}), ${kfmt(f.gateway_tokens)} tokens; dearest: ${models || "none"}</div>` +
    `<div class="muted more">snapshot ${esc(t.date.slice(5))}, counted by agent-usage langfuse, nightly; the gateway is not Claude sessions, whose cost is <a href="#costs">Fleet cost 24h</a></div></div></details>`;
}

// The Sections block (hub_core::sections, the TUI's coststab.rs `sections`): what each section of
// the repo costs to build. It starts open under the All PRs headline; its headers sort apart from
// the main table's (ssort/sdir), All PRs stays on top, and the note says what the figures cannot.
function costsSections(d) {
  const b = d.sections;
  if (!b || !b.table) return "";
  const cells = (r, cls) => `<tr${cls}>` + r.map((c, i) => `<td class="${i ? "n" : ""}">${esc(c)}</td>`).join("") + `</tr>`;
  const shown = b.rows.slice(0, LOG_ROWS);
  return `<details class="csec" data-k="sections" id="sec-sections"${secOpen(cost.open, "sections") ? " open" : ""}><summary><h2 class="sec">Sections <span class="muted">${esc(b.head)}</span></h2></summary>` +
    `<div class="panel scroll"><table class="tbl">${tblHead(b.table, Object.fromEntries(b.columns.map((k, i) => [k, i ? [b.headers[i], "n"] : [b.headers[i]]])), "s")}` +
    cells(b.all, ' class="allrow"') + shown.map((r) => cells(r, "")).join("") + `</table>${older(b.rows.length - shown.length)}</div>` +
    `<div class="muted fold">${b.notes.map(esc).join(" ")}</div></details>`;
}

// The page is the layout's inner tabs (hub_core::layout, app.js INNER_TABS): the strip first, then
// each section inside its inner tab's group in the layout's order (Spend: the tile row, burn per
// session, who spent the 24h, the history chart, the table; Limits: burn, consumers; Models:
// tokens, langfuse, sections; Budget).
function costsHead(d) {
  const asOf = (d.sources || []).map((s) => `<span class="${s.stale ? "warn" : "muted"}">${esc(s.name)} ${s.as_of ? when(s.as_of) : "never"}</span>`).join(" &middot; ");
  const g = d.grafana ? ` <a class="glink" href="${esc(d.grafana)}" target="_blank" rel="noopener">trends in Grafana</a>` : "";
  const totals = costsTiles(d) + `<div class="muted fold">as of: ${asOf}${g}</div>`;
  const switches = `<div id="sec-table">${costsSwitch("window", d.windows, d.window, "w")}${costsSwitch("by", d.cuts, d.by, "by")}</div>`;
  let html = innerStrip("costs", d.amber) + innerWrap("costs", "totals", totals) + innerWrap("costs", "sessions", sessionsSection(d)) +
    innerWrap("costs", "fleet", fleetCostSection(d)) + innerWrap("costs", "spend", historySection(d)) + innerWrap("costs", "table", switches);
  if (cost.err) html += `<div class="panel down">${esc(cost.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// The note under the table, the TUI's lines (coststab.rs `lines`).
function costsTail(d) {
  const ev = d.by === "model" || d.by === "harness"
    ? ` Landed, redo, rev and $/PR are fleet-bench models${d.eval_days ? ` over ${d.eval_days}d` : ""}, per family (opus), queue items only.` : "";
  const note = `<div class="muted fold">${d.unpriced ? `<span class="warn">${esc(d.unpriced)}.</span> ` : ""}Rows: ${esc(d.source)}.${ev} ` +
    `${d.table.shown} of ${d.table.total} rows, ${d.unpriced ? "-" : usd(d.shown_usd)}.</div>`;
  // The Limits and Models sections follow the table in the page, as the layout lists them.
  return innerWrap("costs", "table", note) + innerWrap("costs", "burn", costsBurn(d)) + innerWrap("costs", "consumers", costsConsumers(d)) +
    innerWrap("costs", "tokens", tokensSection(d)) +
    innerWrap("costs", "langfuse", langfuseSection(d)) + innerWrap("costs", "sections", costsSections(d)) +
    innerWrap("costs", "budget", budgetSection(d));
}

// A new cut has other columns, so its sort goes back to the cut's own.
function costsView(patch) {
  if ("by" in patch) Object.assign(patch, { sort: "", dir: "" });
  cost.view(patch);
}

$("costs").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest && t.closest("a[target]")) return;
  const win = t.closest && t.closest("[data-tokwin]");
  if (win) { cost.tokWin = win.dataset.tokwin; cost.render(); return; }
  const sw = t.closest && t.closest("[data-cv]");
  if (sw) { costsView({ [sw.dataset.cv]: sw.dataset.cval }); return; }
  const ss = t.closest && t.closest("[data-ssort]");
  if (ss) { costsView({ ssort: ss.dataset.ssort, sdir: ss.dataset.ssort && ss.dataset.sdir === "asc" ? "asc" : "" }); return; }
  const cs = t.closest && t.closest("[data-csort]");
  if (cs) { costsView({ csort: cs.dataset.csort, cdir: cs.dataset.csort && cs.dataset.cdir === "asc" ? "asc" : "" }); return; }
  // Spend: a day column or chip picks the day, a session row opens (or closes) its own days.
  const ds = t.closest && t.closest("[data-dsort]");
  if (ds) { costsView({ dsort: ds.dataset.dsort, ddir: ds.dataset.dsort && ds.dataset.ddir === "asc" ? "asc" : "" }); return; }
  const day = t.closest && t.closest("#spend-days [data-key], #spend-series [data-key]");
  if (day) { costsView({ day: day.dataset.key }); return; }
  const sess = t.closest && t.closest("tr[data-sid]");
  if (sess) { const v = new URLSearchParams(st.views.costs || ""); costsView({ sid: v.get("sid") === sess.dataset.sid ? "" : sess.dataset.sid }); }
});
$("costs").addEventListener("change", (e) => { if (e.target.dataset && e.target.dataset.dq != null) costsView({ dq: e.target.value }); });

const pollCosts = poll("costs", cost.refresh, COSTS_REFRESH_MS);
TABS.costs = {
  show() { cost.render(); pollCosts(); },
  // A new token snapshot (main.rs `COSTS_EVENT`, sent once the server's kept read is dropped).
  onEvent(ev) { if (st.tab === "costs" && (ev.kind === "costs" || ev.kind === "resync")) cost.refresh(); },
};
