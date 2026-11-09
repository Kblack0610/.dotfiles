"use strict";
// The Costs tab: what the fleet spent, cut seven ways, with fleet-bench's evaluation on the model
// and harness cuts. /api/costs is hub_core::costs::board, the view the hub TUI draws; this file
// draws its answer and turns a click into the view keys (by, w, q, sort, dir) in the URL, so
// `#costs?by=model&w=7d&q=harness:codex` is a link to that view. Trends are Grafana's. Above the
// tiles: who pays (Burn, one row per source claude-acct reads), where the tokens go and what Langfuse sees.

// open: the folded sections' state; tokWin: the tokens section's window.
const cost = tblTab({
  tab: "costs", id: "costs", api: "/api/costs", hint: "search, or harness:codex -model:opus project:dotfiles",
  state: { open: {}, tokWin: "week" }, open: () => cost.open,
  // The view keys past the table's: the cut, the window and the sessions sort.
  params: (p) => { const v = new URLSearchParams(st.views.costs || ""); for (const k of ["by", "w", "ssort", "sdir"]) if (v.get(k)) p.set(k, v.get(k)); },
  head: (t) => costsHead(t.data) + `<div id="sec-table">${costsSwitch("window", t.data.windows, t.data.window, "w")}${costsSwitch("by", t.data.cuts, t.data.by, "by")}</div>`,
  table: (t) => t.data?.table && costsCutTable(t.data),
  body: (t) => costsBody(t.data), tail: (t) => costsTail(t.data),
});

// Every source is a file written nightly or per call; only the token snapshots push (onEvent), so
// the open tab re-reads on the Infra cadence; the server folds reads inside two minutes into one.
const COSTS_REFRESH_MS = INFRA_REFRESH_MS;

// A column key as its header, the TUI's words (coststab.rs `header`); [text, class].
const COST_COLS = {
  session: ["session"], tool: ["tool"], kind: ["kind"], project: ["project"], harness: ["harness"],
  model: ["model"], runner: ["runner"], sessions: ["sess", "n"], calls: ["calls", "n"], tokens: ["tokens", "n"],
  cost: ["cost", "n"], share: ["share", "n"], landed: ["landed", "n"], redo: ["redo", "n"], reverts: ["rev", "n"],
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

// A cut's first column names the row, so it leads on a phone; these sit under it.
const COST_GLANCE = ["cost", "share", "tokens"];

// The table sends every Line column in one order; each cut draws its own (model before harness),
// and that cut's headers and phone sort list are the same columns.
function costsCutTable(d) {
  const role = (k) => (k === d.columns[0] ? "lead" : COST_GLANCE.includes(k) ? "glance" : "");
  return { ...d.table, columns: d.columns.map((k) => d.table.columns.find((c) => c.key === k)).filter(Boolean).map((c) => ({ ...c, role: role(c.key) })) };
}

function costsBody(d) {
  const t = d.table, rows = d.rows || [];
  if (!rows.length) return `<div class="panel">${t.total ? "Nothing matches the query." : "Nothing spent in this window."}</div>`;
  const shown = rows.slice(0, LOG_ROWS);
  const head = costsCutTable(d);
  return `<div class="panel scroll"><table class="tbl">${tblHead(head, Object.fromEntries(d.columns.map((k) => [k, COST_COLS[k]])))}` +
    shown.map((r) => `<tr>${d.columns.map((k) => costCell(r, k, d)).join("")}</tr>`).join("") + `</table>${older(rows.length - shown.length)}</div>`;
}

// The window and cut switches: each a link, so a view is a URL.
function costsSwitch(name, all, on, key) {
  return `<div class="seg fseg"><span class="muted">${name}</span>` + all.map((x) =>
    `<button class="${x === on ? "on" : ""}" data-cv="${key}" data-cval="${esc(x)}">${esc(x)}</button>`).join("") + `</div>`;
}

// Direct Lazer use, the TUI's `direct` line, with what it cannot see beside it, so a low figure
// never reads as all of it. The pool and its keys are Burn rows.
function directTile(dr) {
  const unpriced = dr.unpriced ? `<span class="warn">+${dr.unpriced} unpriced</span>, ` : "";
  return tile("LAZER DIRECT", usd(dr.usd), "var(--c3)", unpriced + esc(dr.note || "not read"));
}

function costsTiles(d) {
  const lz = d.live || {};
  return `<div class="tiles roomy">` + (d.totals || []).map((t) =>
    tile(`SPEND ${t.window.toUpperCase()}`, usd(t.usd), t.window === d.window ? "var(--c1)" : "var(--c-other)", `${t.sessions} sessions${t.unpriced ? `, ${t.unpriced} unpriced` : ""}`)).join("") +
    tile("LIVE 24H", usd(lz.claude_24h), "var(--c2)", "Prometheus, exported sessions only") +
    directTile(d.direct || {}) + `</div>`;
}

// The Burn section (hub_core::burn, the hub's coststab.rs `burn`): the headline coloured by the
// fleet's level, then the drip, when the accounts are back on pace and one row per source. Green
// folds to its headline (dashboards rule 4); amber and red start open until the reader folds it.
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

// The Burn table's columns, the TUI's header in its order; true is a number column.
const BURN_COLS = [["source"], ["kind"], ["live", true], ["bar"], ["used", true], ["gone", true], ["reserve", true], ["room"], ["burn/h", true], ["keeps/h", true],
  ["at burn"], ["if idle"], ["runs out"], ["resets"], ["5h", true], ["5h resets"], ["24h", true]];
// A key is a dollar budget: the columns that always say nothing for one are left out.
const KEY_COLS = BURN_COLS.filter(([t]) => ["source", "live", "bar", "used", "reserve", "room", "resets", "24h"].includes(t));

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
    "5h": `<td class="n">${pc(a.five_hour)}</td>`, "5h resets": `<td>${when(a.five_hour_resets)}</td>`, "24h": `<td class="n">${usd(a.cost_24h)}</td>`,
  };
  return `<tr>${cols.map(([t]) => cells[t]).join("")}</tr>`;
}

const burnTable = (b, cols, rows) => `<table class="tbl"><tr>${cols.map(([t, n]) => `<th${n ? ' class="n"' : ""}>${t}</th>`).join("")}</tr>` +
  rows.map((a) => burnRow(a, b.at, b.stale, cols)).join("") + `</table>`;

// The keys inside a pool, folded under its row. Amber starts open under its own fold key, because
// paint remembers every fold it saw and the quiet key's memory would keep it shut.
function burnKeys(b) {
  if (!b.keys) return "";
  const warn = b.keys.level !== "ok", k = warn ? "burn-keys-warn" : "burn-keys";
  const head = `KEYS <span class="${warn ? "warn" : "muted"}">${esc(b.keys.head)}</span>`;
  return `<div class="panel scroll">${cfold(k, head, burnTable(b, KEY_COLS, b.accounts.filter((a) => a.nested)), { [k]: cost.open[k] ?? warn })}</div>`;
}

function costsBurn(d) {
  const b = d.burn;
  if (!b || !b.accounts.length) return `<h2 class="sec" id="sec-burn">Burn</h2><div class="panel muted">no data from claude-acct</div>`;
  const cls = b.level === "bad" ? "bad" : b.level === "warn" ? "warn" : "ok";
  const held = b.drip.held ? ` <a class="warn" href="#sessions" title="${esc(b.drip.held)}">dispatch held -> Sessions</a>` : "";
  const open = cost.open.burn != null ? cost.open.burn : b.level !== "ok";
  return `<details class="csec" data-k="burn" id="sec-burn"${open ? " open" : ""}><summary><h2 class="sec">Burn <span class="burn ${cls}">${esc(b.head)}</span></h2></summary>` +
    `<div class="panel"><div><span class="muted">DRIP</span> ${esc(b.drip_line)}${held}</div>` +
    `<div><span class="muted">BACK ON PACE</span> ${burnPace(b)}</div></div>` +
    `<div class="panel scroll">${burnTable(b, BURN_COLS, b.accounts.filter((a) => !a.nested))}</div>` + burnKeys(b) +
    `<div class="muted fold">bar: the fill is the share used, the tick the share of the week gone; burn/h is the last 6h rate per live session; keeps/h is what the rest of the week can carry to the reset; 24h is the list-price estimate, for scale.</div></details>`;
}

// One table of a tokens window; a named row takes its chart slot, Other its grey (rule 5).
function tokensTable(title, rows) {
  const row = (r, i) => `<tr><td>${esc(r.name)}</td><td class="n">${r.calls.toLocaleString()}</td><td class="n">${kfmt(r.chars)} ch</td>` +
    `<td class="m">${meter(r.share, SLOTS[i] && !r.other ? SLOTS[i] : OTHER)}</td><td class="n">${(r.share * 100).toFixed(1)}%</td><td class="n">${kfmt(r.carried_tokens)}</td></tr>`;
  return `<table class="tbl"><tr><th>${title}</th><th class="n">calls</th><th class="n">output</th><th>share</th><th class="n">%</th><th class="n">re-read</th></tr>${rows.map(row).join("")}</table>`;
}

const TOK_WINDOWS = { day: "yesterday", week: "7d" };

// Where the tokens go: hub-core's `tokens` sums the snapshots; shut while fresh, open and amber
// once stale (rule 4), which is its own fold key because paint remembers every fold it saw.
// The dollars per tool are the tool cut of the table below, so this links there.
function tokensSection(d) {
  const t = d.tokens;
  if (!t) return `<h2 class="sec" id="sec-tokens">Where the tokens go <span class="warn">no snapshot in ~/.agent/token-usage</span></h2>`;
  const w = t[cost.tokWin], key = t.stale ? "tokens-stale" : "tokens";
  const open = cost.open[key] ?? t.stale;
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
// and cost), the newest snapshot's `.langfuse` through hub-core's `tokens`. Shut while it
// reads, open and amber when the reader failed that night or the snapshot is stale (rule 4). The
// gateway's dollars are the gateway's alone; session cost is the table below, so none is summed here.
function langfuseSection(d) {
  const t = d.tokens, lf = t?.langfuse;
  if (!t) return "";
  const f = lf?.figures, bad = !f || t.stale, key = bad ? "langfuse-stale" : "langfuse", open = cost.open[key] ?? bad;
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
    `<div class="panel scroll"><table class="tbl"><tr><th>slowest tools, by total time</th><th class="n">calls</th><th class="n">p50</th><th class="n">p95</th><th class="n">total</th></tr>${rows}</table>` +
    `<div class="muted">tool errors: ${f.tool_errors.toLocaleString()} of ${f.tool_executions.toLocaleString()} executions (${lfClasses(f.tool_error_classes)})${trunc}</div>` +
    `<div class="muted">gateway: ${f.gateway_calls.toLocaleString()} calls, ${f.gateway_errors.toLocaleString()} errors (${lfClasses(f.gateway_error_classes)}), ${kfmt(f.gateway_tokens)} tokens; dearest: ${models || "none"}</div>` +
    `<div class="muted more">snapshot ${esc(t.date.slice(5))}, counted by agent-usage langfuse, nightly; the gateway is not Claude sessions, whose cost is <a href="#costs?by=runner&w=24h">the table below</a></div></div></details>`;
}

// The Sections block (hub_core::sections, the TUI's coststab.rs `sections`): what each section of
// the repo costs to build. Folded to the All PRs headline until opened; its headers sort apart from
// the main table's (ssort/sdir), All PRs stays on top, and the note says what the figures cannot.
function costsSections(d) {
  const b = d.sections;
  if (!b || !b.table) return "";
  const cells = (r, cls) => `<tr${cls}>` + r.map((c, i) => `<td class="${i ? "n" : ""}">${esc(c)}</td>`).join("") + `</tr>`;
  const shown = b.rows.slice(0, LOG_ROWS);
  return `<details class="csec" data-k="sections" id="sec-sections"${cost.open.sections ? " open" : ""}><summary><h2 class="sec">Sections <span class="muted">${esc(b.head)}</span></h2></summary>` +
    `<div class="panel scroll"><table class="tbl">${tblHead(b.table, Object.fromEntries(b.columns.map((k, i) => [k, i ? [b.headers[i], "n"] : [b.headers[i]]])), "s")}` +
    cells(b.all, ' class="allrow"') + shown.map((r) => cells(r, "")).join("") + `</table>${older(b.rows.length - shown.length)}</div>` +
    `<div class="muted fold">${b.notes.map(esc).join(" ")}</div></details>`;
}

function costsHead(d) {
  const asOf = (d.sources || []).map((s) => `<span class="${s.stale ? "warn" : "muted"}">${esc(s.name)} ${s.as_of ? when(s.as_of) : "never"}</span>`).join(" &middot; ");
  const g = d.grafana ? ` <a class="glink" href="${esc(d.grafana)}" target="_blank" rel="noopener">trends in Grafana</a>` : "";
  let html = `${costsBurn(d)}${tokensSection(d)}${langfuseSection(d)}${costsSections(d)}<h2 class="sec" id="sec-totals">Costs <span class="muted">as of: ${asOf}</span>${g}</h2>${costsTiles(d)}`;
  if (cost.err) html += `<div class="panel down">${esc(cost.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// The note under the table, the TUI's lines (coststab.rs `lines`).
function costsTail(d) {
  const ev = d.by === "model" || d.by === "harness"
    ? ` Landed, redo, rev and $/PR are fleet-bench models${d.eval_days ? ` over ${d.eval_days}d` : ""}, per family (opus), queue items only.` : "";
  return `<div class="muted fold">${d.unpriced ? `<span class="warn">${esc(d.unpriced)}.</span> ` : ""}Rows: ${esc(d.source)}.${ev} ` +
    `${d.table.shown} of ${d.table.total} rows, ${d.unpriced ? "-" : usd(d.shown_usd)}.</div>`;
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
  if (ss) costsView({ ssort: ss.dataset.ssort, sdir: ss.dataset.ssort && ss.dataset.sdir === "asc" ? "asc" : "" });
});

const pollCosts = poll("costs", cost.refresh, COSTS_REFRESH_MS);
TABS.costs = {
  show() { cost.render(); pollCosts(); },
  // A new token snapshot (main.rs `COSTS_EVENT`, sent once the server's kept read is dropped).
  onEvent(ev) { if (st.tab === "costs" && (ev.kind === "costs" || ev.kind === "resync")) cost.refresh(); },
};
