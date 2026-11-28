"use strict";
// The Costs tab: what the fleet spent, cut eight ways, with fleet-bench's evaluation on the model
// and harness cuts. /api/costs is hub_core::costs::board, the view the hub TUI draws; this file
// draws its answer and turns a click into the view keys (by, w, q, sort, dir, Spend's day and sid,
// and each section table's own, COST_TABLES) in the URL, so
// `#costs?by=model&w=7d&q=harness:codex` is a link to that view. Trends are Grafana's. Above the
// tiles: the whole fleet's 24h cost, who pays (Burn, one row per source claude-acct reads), who
// spends (Consumers, one row per runner or gateway key with a priority), where the tokens go and
// what Langfuse sees; the Budget inner tab is what we pay in cash this month.

// open: the folded sections' state; tokWin: the tokens section's window.
const cost = tblTab({
  tab: "costs", id: "costs", api: "/api/costs", hint: "search, or harness:codex -model:opus project:dotfiles",
  state: { open: {}, tokWin: "week", paceDraft: { value: "", from: "", until: "" }, paceMsg: "", paceBusy: false }, open: () => cost.open,
  // The view keys past the table's: the cut, the window, the picked day and session, and each
  // section table's own (COST_TABLES).
  params: (p) => {
    const v = new URLSearchParams(st.views.costs || "");
    for (const k of ["by", "w", "day", "sid", "g", "gv"]) if (v.get(k)) p.set(k, v.get(k));
    for (const pre of Object.keys(COST_TABLES)) for (const [k, x] of tblParams(st.views.costs, pre)) p.set(k, x);
  },
  head: (t) => costsHead(t.data), lead: () => innerStrip("costs"),
  // The table (its bar and rows) belongs to the Spend inner tab, with the switches above it.
  wrap: (html) => innerWrap("costs", "table", html),
  body: (t) => costsBody(t.data), tail: (t) => costsTail(t.data),
  // A poll repaints the whole tab, unless a section table's search or dropdown is in use: then only
  // that table's rows repaint around it.
  draw: (html) => {
    if (Object.values(COST_TABLES).some((t) => t.repaint())) return;
    const field = paceFocus();
    paint($("costs"), html, cost.open);
    if (field && $(field)) $(field).focus();
  },
});

// The section tables of the one Costs read (Spend's day sessions, Consumers, Sections): each keeps
// its own view keys under its prefix (dq, cs, ssort...), and its bar and rows are drawn by its section.
const costTable = (pre, id, table, body) => tblTab({
  tab: "costs", id, el: "costs", pre, refresh: () => cost.refresh(), render: () => cost.render(),
  table: () => cost.data && table(cost.data), body: () => body(cost.data),
});
const COST_TABLES = {
  d: costTable("d", "costs-day", (d) => d.day?.table, (d) => dayRows(d.day)),
  c: costTable("c", "costs-cons", (d) => d.consumers?.table, (d) => consumerRows(d.consumers)),
  s: costTable("s", "costs-sec", (d) => d.sections?.table, (d) => sectionRows(d.sections)),
};
// One section table: its bar flush on its rows and its pager under them, in the block whose
// prefix routes its events.
const costBlock = (pre, id, t, hint, rows) => {
  const body = tblPaged(t, rows);
  return `<div data-tbl="${pre}">${tblBar(id, t, hint)}<div id="${id}-body">${body}</div></div>`;
};

// Every source is a file written nightly or per call; only the token snapshots push (onEvent), so
// the open tab re-reads on the Infra cadence; the server folds reads inside two minutes into one.
const COSTS_REFRESH_MS = INFRA_REFRESH_MS;

// A column key as its header, the TUI's words (coststab.rs `header`); [text, class].
const COST_COLS = {
  session: ["session"], tool: ["tool"], skill: ["skill"], kind: ["kind"], project: ["project"], harness: ["harness"],
  model: ["model"], runner: ["runner"], sessions: ["sess", "n"], calls: ["calls", "n"], tokens: ["tokens", "n"],
  cost: ["cost", "n"], share: ["share of table", "n"], landed: ["landed", "n"], redo: ["redo", "n"], reverts: ["rev", "n"],
  per_pr: ["$/PR", "n"], src: ["src"],
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
  else if (key === "session") html = v ? `<span title="${esc(r.title || v)}">${esc(v.slice(0, 8))}</span>` : "-";
  else html = v == null || v === "" ? "-" : esc(String(v));
  const warn = key === "src" && v === "mixed" ? " warn" : "";
  return `<td class="${num ? "n" : ""}${warn}">${html}</td>`;
}

function costsBody(d) {
  const t = d.table, rows = d.rows || [];
  if (!rows.length) return `<div class="panel">${t.total ? "Nothing matches the query." : "Nothing spent in this window."}</div>`;
  // The table sends every Line column in one order; each cut draws its own (model before harness).
  const head = { ...t, columns: d.columns.map((k) => t.columns.find((c) => c.key === k)).filter(Boolean) };
  return `<div class="panel scroll"><table class="tbl">${tblHead(head, Object.fromEntries(d.columns.map((k) => [k, COST_COLS[k]])))}` +
    rows.map((r) => `<tr>${d.columns.map((k) => costCell(r, k, d)).join("")}</tr>`).join("") + `</table></div>`;
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
  return tile("LAZER DIRECT", usd(dr.usd), "var(--c3)", unpriced + esc(dr.note || NOT_READ));
}

// The Spend tile row on the shared tile(): the whole fleet's 24h (hub_core::fleet_cost, the TUI's
// `fleet_head`), then the 7d and 30d nightly days and direct Lazer use, each sub saying what it counts.
function costsTiles(d) {
  return `<div class="tiles roomy" id="sec-totals">` + fleetTile(d.fleet_cost || { why: "nothing read" }) + (d.totals || []).map((t) =>
    tile(`SPEND ${t.window.toUpperCase()}`, t.days ? usd(t.usd) : "-", t.window === d.window ? "var(--c1)" : "var(--c-other)",
      t.days ? `${t.days} nightly days to ${esc(t.through.slice(5))}, ${t.sessions} sessions` : `<span class="warn">no nightly day in ${esc(t.window)}</span>`)).join("") +
    directTile(d.direct || {}) + `</div>` + (d.totals_note ? `<div class="muted fold">${esc(d.totals_note)}</div>` : "");
}

function fleetTile(f) {
  if (f.why) return tile("FLEET 24H", "-", "var(--c2)", `<span class="warn">${esc(f.why)}</span>`);
  const age = f.stale ? `<span class="warn">stale, as of ${when(f.as_of)}</span>` : `as of ${when(f.as_of)}`;
  return tile("FLEET 24H", "about " + esc(f.usd), "var(--c2)", `whole fleet, API cash ${esc(f.cash)}, subscription burn ${esc(f.burn)}, ${age}`);
}

// The Budget inner tab (hub_core::budget, the TUI's coststab.rs `budget`): this month's cash, what
// needs a look, the bills grouped (agents, CI, infra), then the split by project and lane. List price stays on Spend.
function budgetSection(d) {
  const b = d.budget || { why: "nothing read" };
  if (b.why) return secHead("budget", "Budget", null, "warn") + `<div class="panel"><span class="warn">${esc(b.why)}</span></div>`;
  const stale = b.stale ? `<div class="cline warn">stale, as of ${when(b.as_of)}</div>` : "";
  const sum = `<div><b>So far</b> ${esc(b.spent)}, <b>by month end</b> ${esc(b.projected)}, <b>month</b> ${esc(b.month)}, <b>caps</b> ${esc(b.caps)}` +
    `${b.stale ? "" : `, <b>as of</b> ${when(b.as_of)}`}</div>`;
  const level = b.stale || b.needs.length || b.partial.length ? "warn" : null;
  const partial = b.partial.length ? `<div class="warn">partial, not counted: ${esc(b.partial.join(", "))}</div>` : "";
  const needs = b.needs.length ? `<h3 class="warn">Needs a look ${b.needs.length}</h3>` + b.needs.map((n) => `<div class="warn">${esc(n)}</div>`).join("") : "";
  // A bill off ok (over, unread, unpriced) is amber on its name and its spend.
  const row = (x) => { const w = x.status === "ok" ? "" : "warn"; return `<tr><td class="${w}">${esc(x.name)}</td><td class="muted">${esc(x.kind)}</td><td class="n">${esc(x.cap)}</td>` +
    `<td class="n ${w}">${esc(x.spent)}</td><td class="n">${esc(x.month)}</td><td class="muted wrap">${esc(x.note)}</td></tr>`; };
  const shares = (xs) => xs.map((x) => `${esc(x.name)} ${esc(x.usd)}`).join(", ");
  // Each group (agents, CI, infra) is a heading row with our cash in it, then its bills.
  const group = (g) => `<tr class="allrow"><td>${esc(g.name)}</td><td></td><td></td><td class="n">${esc(g.spent)}</td><td class="n">${esc(g.month)}</td><td></td></tr>` +
    g.bills.map(row).join("");
  return secHead("budget", "Budget", null, level) + stale +
    `<div class="panel scroll">${sum}${partial}${needs}` +
    `<table class="tbl"><tr><th data-role="lead">bill</th><th>kind</th><th class="n">cap</th><th class="n" data-role="glance">so far</th><th class="n" data-role="glance">month est.</th><th>note</th></tr>${b.groups.map(group).join("")}</table>` +
    `<div><b>By project</b> ${shares(b.by_project)}</div><div><b>By lane</b> ${esc(b.by_lane.join(", "))}</div><div class="muted">${esc(b.foot)}</div></div>`;
}

// The Spend section (hub_core::spend_history, the TUI's coststab.rs `history`, `spend_chart` and
// `day_table`): the fleet's $/day over 30 calendar days (billed and estimated stacked, a day with
// no figure an empty column), its months, then the year/month/day rows (folded). The one spend
// table, above it, is the day the chart picks. Open unless the reader folds it.
const SESS_COLS = {
  session: ["session"], who: ["who"], project: ["project"], harness: ["harness"],
  cost: ["cost", "n"], share: ["of day", "n"], est: ["est.", "n"], days: ["days", "n"],
};
const spendBars = (bars, every) => bars.map((b, i) => ({
  key: b.key, tip: b.tip, label: i % every === every - 1 || i === bars.length - 1 ? b.label : "",
  segs: [{ v: b.measured, color: "var(--c1)" }, { v: b.estimated, color: "var(--c-other)" }],
}));
const SPEND_KEY = legend([["billed", "var(--c1)"], ["estimated from tokens", "var(--c-other)"]]);

// A share that rounds to 0 but is not 0 reads "<1%", so a priced row never looks free.
const pctCell = (v) => `<td class="n">${v > 0 && v <= 0.5 ? "&lt;1" : Math.round(v)}%</td>`;

function sessCell(r, k) {
  if (k === "cost") return `<td class="n">${usd(r.cost)}</td>`;
  if (k === "share" || k === "est") return pctCell(r[k]);
  if (k === "days") return `<td class="n">${r.days}</td>`;
  if (k === "session") return `<td title="${esc(r.sid)}">${esc(r.session)}</td>`;
  return `<td>${r[k] == null ? "-" : esc(r[k])}</td>`;
}

// A row of the group table: the day's total, a group, or the opened group. `go` is the group a click
// opens ("" for the total, which closes the open one); a row that goes nowhere has none.
function totRow(r, go, cls = "") {
  const attr = go == null ? "" : ` data-grp="${esc(go)}"`;
  return `<tr${attr} class="${cls}"><td>${esc(r.name)}</td><td class="n">${r.sessions}</td><td class="n">${usd(r.cost)}</td>${pctCell(r.share)}` +
    `<td class="n">${usd(r.per_session)}</td>${pctCell(r.est)}</tr>`;
}
const GRP_HEAD = `<tr><th data-role="lead">name</th><th class="n">sessions</th><th class="n" data-role="glance" data-named>cost</th><th class="n" data-role="glance" data-named>of day</th>` +
  `<th class="n" data-role="glance" data-named title="what one session cost">$/session</th><th class="n">est.</th></tr>`;

// The picked day's sessions: the opened one's own days over them, a row per session.
function dayRows(dv) {
  const t = dv.table;
  const series = dv.series ? `<div class="panel"><h3>${esc(dv.series.session)} <span class="muted">${esc(dv.series.total)} in the chart's 30 days; its row again closes this</span></h3>` +
    `<div id="spend-series">${columns(spendBars(dv.series.bars, 7), { height: 80, sel: dv.day, yfmt: usd })}</div></div>` : "";
  const rows = dv.rows.map((r) => `<tr data-sid="${esc(r.sid)}" class="${dv.series && dv.series.sid === r.sid ? "sel" : ""}">` +
    Object.keys(SESS_COLS).map((k) => sessCell(r, k)).join("") + `</tr>`).join("");
  return series + `<div class="panel scroll"><table class="tbl">${tblHead(t, SESS_COLS)}${rows}</table>` +
    (dv.more ? `<div class="muted more">+${dv.more} more sessions</div>` : "") + `</div>`;
}

const grpTable = (rows, outside) => `<div class="panel scroll"><table class="tbl" id="spend-groups">${GRP_HEAD}${rows}</table>${outside}</div>`;

// The table under the switches: the groups (total row on top, a click opens one), or the sessions
// of the cut `sessions` or of an opened group, which keep the total row on top and the group's
// beside it. Its sessions have no search, chips or dropdowns; the block's data-tbl routes a header
// sort to its own keys (dsort, ddir).
function dayTable(dv) {
  if (dv.why) return `<div class="panel muted">${esc(dv.why)}</div>`;
  const outside = dv.outside ? `<div class="muted">${esc(dv.outside)}</div>` : "";
  const total = dv.total ? totRow(dv.total, dv.in_group ? "" : null, "allrow") : "";
  if (!dv.table) {
    return grpTable(total + dv.groups.map((g) => totRow(g, g.name)).join(""), outside);
  }
  const head = grpTable(total + (dv.in_group ? totRow(dv.open, null, "sel") : ""), outside);
  return head + `<div data-tbl="d"><div id="costs-day-body">${tblBodyFirst(dv.table, () => dayRows(dv))}</div></div>`;
}

// The one spend table: the day picked on the chart (the live last 24h until one is), grouped by who,
// project, harness or account with a total row on top, or by session. A group row opens that
// group's sessions, the total row goes back, and a session row opens its own days. The coverage
// words and the foot are the fleet figure's (hub_core::fleet_cost).
function spendTable(d) {
  const dv = d.day;
  if (!dv) return "";
  const f = d.fleet_cost && !d.fleet_cost.why ? d.fleet_cost : null;
  const days = dv.has_live ? costsSwitch("day", dv.live ? [""] : ["", dv.day], dv.live ? "" : dv.day, "day", (x) => x || "last 24h") : "";
  const cuts = dv.cuts ? costsSwitch("group", dv.cuts, dv.group, "g") : "";
  const n = dv.table ? dv.table.total : dv.groups ? dv.groups.length : null;
  const live = f && dv.live ? `<div class="muted">${esc(f.coverage)}</div>` + f.unpriced.map((u) => `<div class="warn">${esc(u)}</div>`).join("") : "";
  const notes = f ? live + `<div class="muted">${esc(f.foot)}</div>` : "";
  return fold("csec", secHead("", "Spend table", n),
    (dv.head ? `<div class="panel"><div><span class="muted">DAY</span> ${esc(dv.head)}</div></div>` : "") +
    `<div>${days}${cuts}</div>` + dayTable(dv) + `<div class="panel">${notes}</div>`,
    { k: "spend-table", id: "sec-sessions", open: secOpen(cost.open, "spend-table") });
}

function historySection(d) {
  const h = d.history;
  if (!h) return "";
  if (h.why) return `<div id="sec-spend">${secHead("", "Spend")}<div class="panel muted">${esc(h.why)}</div></div>`;
  const stale = h.stale ? `<div class="cline warn">stale: no snapshot for yesterday</div>` : "";
  const pace = (h.month ? `<div><span class="muted">MONTH</span> ${esc(h.month)}</div>` : "") + (h.last_day ? `<div><span class="muted">LAST DAY</span> ${esc(h.last_day)}</div>` : "");
  const row = (r) => `<tr class="${r.kind === "day" ? "" : "allrow"}"><td>${esc(r.period)}</td><td class="n">${esc(r.total)}</td><td class="n">${r.days}</td>` +
    `<td class="n">${esc(r.per_day)}</td><td class="n">${esc(r.per_session)}</td><td class="n">${esc(r.vs_prev)}</td><td class="n">${esc(r.est)}</td></tr>`;
  const dv = d.day || {};
  const charts = `<div class="spendcharts"><div class="panel"><h3>$/day, last 30 days, click a day for its table above ${SPEND_KEY}</h3>` +
    `<div id="spend-days">${columns(spendBars(h.chart, 7), { height: 160, sel: dv.day, yfmt: usd })}</div>${pace}</div>` +
    (h.months.length ? `<div class="panel"><h3>By month</h3>${columns(spendBars(h.months, 1), { height: 160, yfmt: usd })}</div>` : "") + `</div>`;
  const periods = fold("sec-d", "Year, month and day rows",
    `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">period</th><th class="n">total</th><th class="n">days</th><th class="n" data-role="glance" data-named>$/day</th><th class="n" data-role="glance" data-named title="what one session cost on an average day">$/session</th><th class="n" data-role="glance" data-named>vs prev</th><th class="n">est.</th></tr>` +
    h.rows.map(row).join("") + `</table>${h.older ? older(h.older) : ""}` +
    (h.missing ? `<div class="warn">${h.missing} days in the range have no figure and are not counted</div>` : "") +
    `</div><div class="muted fold">${esc(h.note)}</div>`,
    { k: "spend-periods", open: secOpen(cost.open, "spend-periods"), sum: ' class="muted fold"' });
  return fold("csec", secHead("", "Spend", null, h.stale ? "warn" : null), stale + charts + periods,
    { k: "spend", id: "sec-spend", open: secOpen(cost.open, "spend") });
}

// The Burn section (hub_core::burn, the hub's coststab.rs `burn`): the fleet's level on the head,
// then the headline in that colour, the drip, when the accounts are back on pace and one row per
// source. It starts open until the reader folds it (dashboards rule 4), except on a phone, where
// the head's colour is the verdict and the tables wait for a tap. A phone has its own fold key, because paint
// remembers every fold it saw and its closed one would stick.
function burnPace(b) {
  const p = b.pace;
  if (p.on_pace) return "every source is on pace";
  const burn = p.at_burn.length ? p.at_burn.map(([n, t]) => `${esc(n)} ${when(t)}`).join(", ") : "not before the reset";
  const idle = p.idle_all_by == null ? "" : `; if idle: all by ${when(p.idle_all_by)}${p.idle_rest_after_reset ? ", the rest after the reset" : ""}`;
  return `at this burn: ${burn}${idle}`;
}

// A back-on-pace cell: Account::back's word (`on pace`, `after reset`) or its time; nothing for a
// dollar budget, which has no pace line.
const burnCell = (b) => (b.word ?? (b.at == null ? "-" : when(b.at)));

// The Burn table's columns, the TUI's header in its order; true is a number column, and the third
// entry is the column's place in a phone's row.
const BURN_COLS = [["source", false, ' data-role="lead"'], ["kind"], ["live", true], ["bar"], ["used", true, ' data-role="glance" data-named'], ["gone", true, ' data-role="glance" data-named'], ["reserve", true], ["room", false, ' data-role="glance"'], ["burn/h", true], ["keeps/h", true],
  ["at burn"], ["if idle"], ["runs out"], ["resets"], ["5h", true], ["5h resets"], ["$24h", true]];
// A key is a dollar budget: the columns that always say nothing for one are left out.

function burnRow(a, cols) {
  // a row with no figures: its name, then its note across the rest
  if (a.note) return `<tr><td>${esc(a.name)}</td><td colspan="${cols.length - 1}" class="${levelClass(a.note_level)}">${esc(a.note)}</td></tr>`;
  const pc = (v) => (v == null ? "-" : Math.floor(v) + "%");
  const rate = (v) => (v == null || a.unpaced ? "-" : v.toFixed(2));
  const cells = {
    source: `<td>${esc(a.name)}</td>`, kind: `<td>${esc(a.kind)}</td>`, live: `<td class="n">${a.live}</td>`,
    // the fill is the share used, the tick the share of the week gone; a dollar budget has no week
    bar: `<td>${meter(a.used / 100, null, a.unpaced || a.gone == null ? null : a.gone / 100)}</td>`,
    used: `<td class="n">${esc(a.used_text)}</td>`, gone: `<td class="n">${pc(a.gone)}</td>`, reserve: `<td class="n">${pc(a.reserve)}</td>`,
    room: `<td class="${a.room ? (a.room.ok ? "ok" : "bad") : "muted"}">${a.room ? esc(a.room.text) : "-"}</td>`,
    "burn/h": `<td class="n${a.is_over ? " warn" : ""}">${rate(a.burn)}</td>`, "keeps/h": `<td class="n">${rate(a.sustain)}</td>`,
    "at burn": `<td>${burnCell(a.burn_back)}</td>`, "if idle": `<td>${burnCell(a.idle_back)}</td>`, "runs out": `<td>${when(a.run_out)}</td>`, resets: `<td>${when(a.resets)}</td>`,
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
  rows.map((a) => burnRow(a, cols)).join("") + burnTotal(b.total, cols) + `</table>`;

// The keys inside a pool are Consumers rows, so Burn only points there.
const burnKeys = (b) => (b.keys ? `<div class="panel"><span class="muted">KEYS</span> <span class="${b.keys.level !== "ok" ? "warn" : "muted"}">${esc(b.keys.head)}</span> <a href="#costs/consumers">rows in Consumers</a></div>` : "");

// Every LLM consumer (hub_core::gateway, the TUI's coststab.rs `consumers`): a runner with a
// priority, or a gateway key no runner names, with what it runs on, its budget, spend and fallback.
// Open like every section (rule 4), its level on the head; a MISMATCH is its table's amber tile.
function consumerRows(c) {
  const labels = Object.fromEntries(c.columns.map((k, i) => [k, [c.headers[i].toLowerCase()]]));
  const row = (r) => `<tr>${c.columns.map((k) => `<td${r.level === "bad" ? ' class="bad"' : ""}>${esc(r[k])}</td>`).join("")}</tr>`;
  return c.rows.length ? `<div class="panel scroll"><table class="tbl">${tblHead(c.table, labels)}${c.rows.map(row).join("")}</table></div>`
    : `<div class="panel muted">${c.table.total ? "No consumer matches." : "No consumer configured."}</div>`;
}

function costsConsumers(d) {
  const c = d.consumers;
  if (!c || !c.table) return "";
  const open = secOpen(cost.open, "consumers");
  const notes = [c.stale, ...c.errors].filter(Boolean).map((e) => `<div class="warn">${esc(e)}</div>`).join("");
  return fold("csec", secHead("", "Consumers", tblCount(c.table), c.level === "ok" ? null : c.level),
    (notes ? `<div class="panel">${notes}</div>` : "") +
    costBlock("c", "costs-cons", c.table, "search, or priority:low -status:ok", () => consumerRows(c)) +
    `<div class="panel muted">${c.pools.map((l) => `<div>${esc(l)}</div>`).join("")}<div>${esc(c.routes)}</div></div>` +
    `<div class="muted fold">${c.legend.map(([t, x]) => `${esc(t.toLowerCase())}: ${esc(x)}`).join("; ")}</div>`,
    { k: "consumers", id: "sec-consumers", open });
}

function costsBurn(d) {
  const b = d.burn;
  if (!b) return "";
  if (!b.accounts.length) return secHead("burn", "Burn") + `<div class="panel muted">${esc(b.no_data)}</div>`;
  const cls = b.level === "bad" ? "bad" : b.level === "warn" ? "warn" : "ok";
  const held = b.drip.held ? ` <a class="warn" href="#sessions" title="${esc(b.drip.held)}">dispatch held -> Sessions</a>` : "";
  const key = isPhone() ? "burn-phone" : "burn", open = isPhone() ? !!cost.open[key] : secOpen(cost.open, key);
  return fold("csec", secHead("", "Burn", null, b.level),
    `<div class="panel"><div><span class="muted">BURN</span> <span class="burn ${cls}">${esc(b.head)}</span></div><div><span class="muted">DRIP</span> ${esc(b.drip_line)}${held}</div>` +
    `<div><span class="muted">BACK ON PACE</span> ${burnPace(b)}</div></div>` +
    `<div class="panel scroll">${burnTable(b, BURN_COLS, b.accounts.filter((a) => !a.nested))}</div>` + burnKeys(b) +
    (b.legend?.length ? `<div class="muted fold">${b.legend.map(([t, d]) => `${esc(t.toLowerCase())}: ${esc(d)}`).join("; ")}</div>` : ""),
    { k: key, id: "sec-burn", open });
}

// The Allowance and Pace config sections (hub_core::pace_conf, the TUI's coststab.rs): the burn
// allowance in force, what it lets through, its schedule (windows set from here or by hand with
// `pace-conf`), and every pace.conf key with its value and where it came from. The form posts
// /api/pace/set; a row's End posts /api/pace/end; both answer with pace-conf's own words on a refusal.
// claude-acct recomputes allowed and spare on its timer, so they lag a change (the as-of line).
const PACE_STATE = { Upcoming: "muted", Shadowed: "muted", "In force": "ok", Default: "muted" };
const paceErr = (e) => `<div class="panel down">${esc(e)}</div>`;
const paceRate = (n) => (n == null ? "-" : n.toFixed(2));
function paceSchedule(a) {
  const rows = a.rows.map((r) => {
    const end = r.can_end ? `<button class="btn" data-pace-end="${esc(a.key)}"${r.start != null ? ` data-from="${r.start}"` : ""}>End</button>` : "";
    return `<tr><td class="n">${esc(r.value)}%</td><td>${esc(r.from)}</td><td>${esc(r.until)}</td><td>${esc(r.by)}</td>` +
      `<td class="${PACE_STATE[r.state] || "muted"}">${esc(r.state)}</td><td>${end}</td></tr>`;
  }).join("");
  return `<div class="panel scroll"><table class="tbl"><tr><th class="n" data-role="lead">allowance</th><th data-role="glance">from</th><th data-role="glance">until</th><th>by</th><th data-role="glance">state</th><th></th></tr>${rows}</table></div>`;
}
function paceForm(a) {
  // datetime-local is the browser's clock; the hint says so, since the server's may differ.
  const zone = (() => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone || ""; } catch { return ""; } })();
  const f = cost.paceDraft, max = a.max != null ? ` max="${a.max}"` : "";
  const days = a.window_max_days ? ` A window is at most ${a.window_max_days} days.` : "";
  return `<div class="panel pace-form"><div class="qadd">` +
    `<input id="pace-value" type="number" min="0"${max} step="1" placeholder="allowance %" value="${esc(f.value)}">` +
    `<label class="muted">from <input id="pace-from" type="datetime-local" value="${esc(f.from)}"></label>` +
    `<label class="muted">until <input id="pace-until" type="datetime-local" value="${esc(f.until)}"></label>` +
    `<button class="btn primary" id="pace-set"${cost.paceBusy ? " disabled" : ""}>${cost.paceBusy ? "Setting..." : "Set"}</button></div>` +
    errPanel(cost.paceMsg, { id: "pace-msg" }) +
    `<div class="muted fold">Times are on this browser's clock${zone ? ` (${esc(zone)})` : ""}. Empty from is now; empty until is a standing override that lasts until it is ended.${days}</div></div>`;
}
function costsAllowance(d) {
  const p = d.pace;
  if (!p) return "";
  const a = p.allowance;
  if (!a) return secHead("allowance", "Allowance") + paceErr(p.error || "no pace config");
  const lag = a.lagging ? `<span class="warn">claude-acct's figures are for the allowance before this one (wrote them ${when(a.as_of)}); they catch up on its next run</span>`
    : a.as_of ? esc(`claude-acct wrote the figures ${when(a.as_of)}; a change shows there on its next run`) : esc(d.burn?.no_data || "");
  const over = a.level;
  const lines = `<div class="panel"><div><span class="muted">ALLOWANCE</span> ${esc(a.in_force)} (${esc(a.source)}), default ${esc(a.default)}</div>` +
    `<div><span class="muted">LETS THROUGH</span> <span class="burn ${over}">${paceRate(a.burn)}/h now</span> against ${paceRate(a.sustain)}/h sustainable and ${paceRate(a.allowed)}/h allowed` +
    `${a.spare != null ? `, ${a.spare} spare sessions` : ""}</div><div class="muted fold">${lag}. ${esc(a.note)}</div></div>`;
  const key = isPhone() ? "allowance-phone" : "allowance", open = isPhone() ? !!cost.open[key] : secOpen(cost.open, key);
  return fold("csec", secHead("", "Allowance", null, over === "ok" ? null : over), (p.error ? paceErr(p.error) : "") + lines + paceSchedule(a) + paceForm(a),
    { k: key, id: "sec-allowance", open });
}
function costsPace(d) {
  const p = d.pace;
  if (!p) return "";
  if (!p.keys.length) return secHead("pace", "Pace config") + paceErr(p.error || "no pace config");
  const rows = p.keys.map((k) => `<tr><td>${esc(k.key)}</td><td class="n">${esc(k.value)}</td><td class="${k.source === "default" ? "muted" : ""}">${esc(k.source)}</td>` +
    `<td class="n muted">${esc(k.default)}</td><td class="muted">${k.editable ? "yes" : ""}</td></tr>`).join("");
  return fold("csec", secHead("", "Pace config", p.keys.length), `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">key</th><th class="n" data-role="glance">value</th><th data-role="glance">source</th><th class="n">default</th><th>settable</th></tr>${rows}</table></div>` +
    `<div class="muted fold">pace.conf holds the defaults; <code>pace-conf set KEY VALUE</code> overrides one, and only a key with a maximum can be set.</div>`,
    { k: "pace", id: "sec-pace", open: secOpen(cost.open, "pace") });
}
// The form's typing and its buttons. A poll repaints the tab, so the draft is kept as it is typed
// and the field in use takes focus back after the repaint (paceFocus).
// A field in use is put back in focus after the repaint (the draft is kept as it is typed).
const paceFocus = () => (document.activeElement?.closest?.(".pace-form") ? document.activeElement.id || "" : "");
const paceEpoch = (minute) => (minute ? `@${Math.floor(new Date(minute).getTime() / 1000)}` : "");
async function paceAct(path, body) {
  cost.paceBusy = true; cost.paceMsg = "";
  if (document.activeElement) document.activeElement.blur();
  cost.render();
  try { await post(path, body); cost.paceMsg = ""; if (path.endsWith("/set")) cost.paceDraft = { value: "", from: "", until: "" }; }
  catch (e) { cost.paceMsg = e.message; }
  cost.paceBusy = false;
  cost.render();
  cost.refresh();
}

// The tool table of a tokens window. A row with parts (Bash's commands, a tool's file types, the
// tools Other holds) opens to every one of them under it, indented, and its click again closes it;
// The open rows are the view key `tok`, their paths comma-joined ("Bash,Other,Other/Edit", an
// Other keyed "Other" whatever its count), so `#costs/tokens?tok=Bash` is a link to Bash's commands.
// In each list a named row takes its chart slot, the rest and Other the grey (rule 5). Time is wall
// time from the transcripts over the calls that carry it, and avg is per timed call.
const tokOpen = () => new Set((new URLSearchParams(st.views.costs || "").get("tok") || "").split(",").filter(Boolean));
const tokLink = (path) => { const v = new URLSearchParams(st.views.costs || ""); v.set("tok", path); return "#costs/tokens?" + v; };
const tokTime = (r) => r.timed ? [r.ms < 1000 ? lfMs(r.ms) : secs(r.ms / 1e3), lfMs(Math.round(r.ms / r.timed))] : ["-", "-"];
function tokensTable(rows) {
  const out = [], open = tokOpen();
  const walk = (rs, depth, pre) => rs.forEach((r, i) => {
    const path = pre + (r.other ? "Other" : r.name), kids = r.parts || [], on = kids.length > 0 && open.has(path);
    const mark = kids.length ? `<span class="muted">${on ? "-" : "+"}</span> ` : "";
    out.push(`<tr${kids.length ? ` data-tokpart="${esc(path)}" class="tokpart${on ? " sel" : ""}"` : ""}>` +
      `<td${depth ? ` style="padding-left:${depth * 1.5}em"` : ""}>${mark}${esc(r.name)}</td><td class="n">${r.calls.toLocaleString()}</td><td class="n">${kfmt(r.chars)} ch</td>` +
      `<td class="m">${meter(r.share, SLOTS[i] && !r.other ? SLOTS[i] : OTHER)}</td><td class="n">${(r.share * 100).toFixed(1)}%</td><td class="n">${kfmt(r.carried_tokens)}</td>` +
      tokTime(r).map((x) => `<td class="n">${x}</td>`).join("") + `</tr>`);
    if (on) walk(kids, depth + 1, path + "/");
  });
  walk(rows, 0, "");
  return `<table class="tbl"><tr><th data-role="lead">by tool</th><th class="n" data-role="glance" data-named>calls</th><th class="n" data-role="glance" data-named>output</th><th>share</th><th class="n" data-role="glance" data-named>% of output</th><th class="n">re-read</th><th class="n">time</th><th class="n">avg</th></tr>${out.join("")}</table>`;
}

const TOK_WINDOWS = { day: "yesterday", week: "7d" };

// Where the tokens go: hub-core's `tokens` sums the snapshots; it starts open (rule 4), its head
// amber and a line under it once stale.
// The dollars per tool are the tool cut of the table below, so this links there.
function tokensSection(d) {
  const t = d.tokens;
  if (!t) return secHead("tokens", "Where the tokens go", null, "warn") + `<div class="cline warn">no snapshot in ~/.agent/token-usage</div>`;
  const w = t[cost.tokWin], key = "tokens", open = secOpen(cost.open, key);
  const stale = t.stale ? `<div class="cline warn">stale: newest snapshot ${esc(t.date)}</div>` : "";
  const seg = `<div class="seg fseg"><span class="muted">window</span>` + Object.entries(TOK_WINDOWS).map(([k, l]) =>
    `<button class="${k === cost.tokWin ? "on" : ""}" data-tokwin="${k}">${l}</button>`).join("") + `</div>`;
  const partial = w.partial ? `<span class="warn">, ${w.partial} of ${w.days} partial</span>` : "";
  return fold("csec", secHead("", "Where the tokens go", null, t.stale ? "warn" : null),
    stale + `<div class="panel scroll">${seg}<div class="muted">${cost.tokWin === "day" && t.stale ? esc(t.date) : TOK_WINDOWS[cost.tokWin]}: ${kfmt(w.context)} context, ${kfmt(w.per_response)}/response, tool output carried ${pct(w.carried_share)} ` +
    `(snapshot ${esc(t.date.slice(5))}, ${t.generated_at ? clock(t.generated_at * 1e3) : "-"}${partial})</div>` +
    tokensTable(w.tools) +
    `<div class="muted more">a + row opens: Bash by command, a tool by file type, Other to every tool; counted by claude-recall tool-output, nightly, its time the wall clock between call and result (a permission wait included); dollars per tool: <a href="#costs?by=tool&w=7d">the tool cut</a></div></div>`,
    { k: key, id: "sec-tokens", open });
}

// A duration in ms as the tool tables read it: 99ms, 17.5s.
const lfMs = (ms) => (ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`);

// What Langfuse sees: the figures only it has (tool latency, tool errors by class, gateway errors
// and cost), the newest snapshot's `.langfuse` through hub-core's `tokens`. It starts open (rule 4),
// its head amber and a line under it when the reader failed that night or the snapshot is stale. The
// gateway's dollars are the gateway's alone; session cost is Spend's FLEET 24H, so none is summed here.
function langfuseSection(d) {
  const t = d.tokens, lf = t?.langfuse;
  if (!t) return "";
  const f = lf?.figures, key = "langfuse", open = secOpen(cost.open, key);
  const lfFold = (warn, inner) => fold("csec", secHead("", "What Langfuse sees", null, warn ? "warn" : null), inner, { k: key, id: "sec-langfuse", open });
  if (!f) {
    return lfFold(true, `<div class="cline warn">no figures in snapshot ${esc(t.date)}</div>` +
      `<div class="panel"><div class="warn">${esc(lf?.why || "the snapshot has no langfuse section: written before the reader, or the run stopped")}</div>` +
      `<div class="muted more">read nightly by agent-usage langfuse; the Sentinel watch gateway-errors trips after two nights</div></div>`);
  }
  const shares = `<div><b>tool errors</b> ${pct(f.tool_error_share)}, <b>gateway errors</b> ${pct(f.gateway_error_share)}, <b>gateway cost</b> ${usd(f.gateway_cost_usd)}</div>`;
  // A tool the tokens table opens links to its rows there, where each carries its own time.
  const split = new Set(t[cost.tokWin].tools.filter((r) => !r.other && r.parts?.length).map((r) => r.name));
  const rows = f.tools.map((x) => `<tr><td>${split.has(x.tool) ? `<a href="${esc(tokLink(x.tool))}">${esc(x.tool)}</a>` : esc(x.tool)}</td><td class="n">${x.calls.toLocaleString()}</td><td class="n">${lfMs(x.p50_ms)}</td><td class="n">${lfMs(x.p95_ms)}</td><td class="n">${secs(x.total_s)}</td></tr>`).join("");
  const models = f.gateway_models.map((m) => `${esc(m.model)} ${usd(m.cost_usd)}`).join(", ") + (f.gateway_other_models ? `, ${f.gateway_other_models} more` : "");
  const trunc = f.truncated ? `<span class="warn"> (classes partial: more errors than were paged)</span>` : "";
  return lfFold(t.stale, (t.stale ? `<div class="cline warn">stale: newest snapshot ${esc(t.date)}</div>` : "") +
    `<div class="panel scroll">${shares}<table class="tbl"><tr><th data-role="lead">slowest tools, by total time</th><th class="n" data-role="glance" data-named>calls</th><th class="n">p50</th><th class="n" data-role="glance" data-named>p95</th><th class="n" data-role="glance" data-named>total</th></tr>${rows}</table>` +
    `<div class="muted">tool errors: ${f.tool_errors.toLocaleString()} of ${f.tool_executions.toLocaleString()} executions (${esc(f.tool_error_line)})${trunc}</div>` +
    `<div class="muted">gateway: ${f.gateway_calls.toLocaleString()} calls, ${f.gateway_errors.toLocaleString()} errors (${esc(f.gateway_error_line)}), ${kfmt(f.gateway_tokens)} tokens; dearest: ${models || "none"}</div>` +
    `<div class="muted more">snapshot ${esc(t.date.slice(5))}, counted by agent-usage langfuse, nightly; the gateway is not Claude sessions, whose cost is <a href="#costs/sessions">the spend table</a> on Spend</div></div>`);
}

// The Sections block (hub_core::sections, the TUI's coststab.rs `sections`): what each section of
// the repo costs to build, over the window its first line names. It starts open, All PRs stays on
// top of its rows, and the note says what the figures cannot.
function sectionRows(b) {
  const cells = (r, cls) => `<tr${cls}>` + r.map((c, i) => `<td class="${i ? "n" : ""}">${esc(c)}</td>`).join("") + `</tr>`;
  return `<div class="panel scroll"><div><b>window</b> last ${b.days}d</div><table class="tbl">${tblHead(b.table, Object.fromEntries(b.columns.map((k, i) => [k, i ? [b.headers[i], "n"] : [b.headers[i]]])))}` +
    cells(b.all, ' class="allrow"') + b.rows.map((r) => cells(r, "")).join("") + `</table></div>`;
}

function costsSections(d) {
  const b = d.sections;
  if (!b || !b.table) return "";
  return fold("csec", secHead("", "Sections", tblCount(b.table)),
    costBlock("s", "costs-sec", b.table, "search, or section:agent-web", () => sectionRows(b)) +
    `<div class="muted fold">${b.notes.map(esc).join(" ")}</div>`,
    { k: "sections", id: "sec-sections", open: secOpen(cost.open, "sections") });
}

// The page is the layout's inner tabs (hub_core::layout, app.js INNER_TABS): the strip first, then
// each section inside its inner tab's group in the layout's order (Spend: the tile row, the spend table,
// the history chart and period rows, the outcomes table; Limits: burn, allowance, pace config, consumers; Models: tokens,
// langfuse, sections; Budget).
function costsHead(d) {
  const asOf = (d.sources || []).map((s) => `<span class="${s.stale ? "warn" : "muted"}">${esc(s.name)} ${s.as_of ? when(s.as_of) : NO_DATA}</span>`).join(" &middot; ");
  const g = d.grafana ? ` <a class="glink" href="${esc(d.grafana)}" target="_blank" rel="noopener">trends in Grafana</a>` : "";
  const totals = costsTiles(d) + `<div class="muted fold">as of: ${asOf}${g}</div>`;
  const switches = `<div id="sec-table">${costsSwitch("window", d.windows, d.window, "w")}${costsSwitch("by", d.cuts, d.by, "by")}</div>`;
  let html = innerStrip("costs", d.amber) + innerWrap("costs", "totals", totals) + innerWrap("costs", "sessions", spendTable(d)) + innerWrap("costs", "spend", historySection(d)) + innerWrap("costs", "table", switches);
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
  // The Limits and Models sections follow the table, as the layout lists them.
  return innerWrap("costs", "table", note) + innerWrap("costs", "burn", costsBurn(d)) + innerWrap("costs", "allowance", costsAllowance(d)) + innerWrap("costs", "pace", costsPace(d)) + innerWrap("costs", "consumers", costsConsumers(d)) +
    innerWrap("costs", "tokens", tokensSection(d)) +
    innerWrap("costs", "langfuse", langfuseSection(d)) + innerWrap("costs", "sections", costsSections(d)) +
    innerWrap("costs", "budget", budgetSection(d));
}

// A new cut has other columns, so its sort goes back to the cut's own.
function costsView(patch) {
  if ("by" in patch) Object.assign(patch, { sort: "", dir: "" });
  // A new cut has other groups: the opened one and session are the old cut's.
  if ("g" in patch) Object.assign(patch, { gv: "", sid: "" });
  cost.view(patch);
}

$("costs").addEventListener("input", (e) => {
  const id = e.target.id;
  if (id === "pace-value") cost.paceDraft.value = e.target.value;
  else if (id === "pace-from") cost.paceDraft.from = e.target.value;
  else if (id === "pace-until") cost.paceDraft.until = e.target.value;
});

$("costs").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest && t.closest("a[target]")) return;
  const win = t.closest && t.closest("[data-tokwin]");
  if (win) { cost.tokWin = win.dataset.tokwin; cost.render(); return; }
  const part = t.closest && t.closest("tr[data-tokpart]");
  if (part) {
    const o = tokOpen(), p = part.dataset.tokpart, v = new URLSearchParams(st.views.costs || "");
    if (!o.delete(p)) o.add(p);
    if (o.size) v.set("tok", [...o].join(",")); else v.delete("tok");
    setQuery(v.toString());
    cost.render();
    return;
  }
  if (t.id === "pace-set") {
    const v = (id) => ($(id).value || "").trim();
    cost.paceDraft = { value: v("pace-value"), from: v("pace-from"), until: v("pace-until") };
    if (!cost.paceDraft.value) { cost.paceMsg = "Type the allowance in percent."; cost.render(); return; }
    // The field is a minute on this browser's clock; the server reads in its own zone, so it gets the epoch.
    const { value, from, until } = cost.paceDraft;
    paceAct("/api/pace/set", { key: "BURN_OVER_PCT", value, from: paceEpoch(from), until: paceEpoch(until) });
    return;
  }
  const end = t.closest && t.closest("[data-pace-end]");
  if (end) { paceAct("/api/pace/end", { key: end.dataset.paceEnd, ...(end.dataset.from ? { from: Number(end.dataset.from) } : {}) }); return; }
  const sw = t.closest && t.closest("[data-cv]");
  if (sw) { costsView({ [sw.dataset.cv]: sw.dataset.cval }); return; }
  // Spend: a day column picks the day, a group row opens its sessions, the total row goes back, and
  // a session row opens (or closes) its own days.
  const day = t.closest && t.closest("#spend-days [data-key], #spend-series [data-key]");
  // The spend table sits above the chart, so the paint scrolls up to it (seekSection).
  if (day) { if (day.closest("#spend-days")) st.section = "sessions"; costsView({ day: day.dataset.key }); return; }
  const grp = t.closest && t.closest("tr[data-grp]");
  if (grp) { costsView({ gv: grp.dataset.grp, sid: "" }); return; }
  const sess = t.closest && t.closest("tr[data-sid]");
  if (sess) { const v = new URLSearchParams(st.views.costs || ""); costsView({ sid: v.get("sid") === sess.dataset.sid ? "" : sess.dataset.sid }); }
});

const pollCosts = poll("costs", cost.refresh, COSTS_REFRESH_MS);
TABS.costs = {
  show() { cost.render(); pollCosts(); },
  // A new token snapshot (main.rs `COSTS_EVENT`, sent once the server's kept read is dropped).
  onEvent(ev) { if (st.tab === "costs" && (ev.kind === "costs" || ev.kind === "resync")) cost.refresh(); },
};
