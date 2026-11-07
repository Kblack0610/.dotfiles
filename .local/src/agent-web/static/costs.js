"use strict";
// The Costs tab: what the fleet spent, cut seven ways, with fleet-bench's evaluation on the model
// and harness cuts. /api/costs is hub_core::costs::board, the view the hub TUI draws; this file
// draws its answer and turns a click into the view keys (by, w, q, sort, dir) in the URL, so
// `#costs?by=model&w=7d&q=harness:codex` is a link to that view. Trends are Grafana's.

const cost = { data: null, err: null, open: {} };

// Every source is a file written nightly or per call, and none pushes, so the open tab re-reads
// on the Infra cadence; the server folds reads inside two minutes into one.
const COSTS_REFRESH_MS = INFRA_REFRESH_MS;

// A column key as its header, the TUI's words (coststab.rs `header`); [text, class].
const COST_COLS = {
  session: ["session"], tool: ["tool"], kind: ["kind"], project: ["project"], harness: ["harness"],
  model: ["model"], runner: ["runner"], sessions: ["sess", "n"], calls: ["calls", "n"], tokens: ["tokens", "n"],
  cost: ["cost", "n"], share: ["share", "n"], landed: ["landed", "n"], redo: ["redo", "n"], reverts: ["rev", "n"],
  per_pr: ["$/PR", "n"], src: ["src"], pr: ["PR"], at: ["updated", "n"],
};

function costsParams() {
  const v = new URLSearchParams(st.views.costs || ""), p = tblParams(st.views.costs);
  for (const k of ["by", "w", "ssort", "sdir"]) if (v.get(k)) p.set(k, v.get(k));
  return p;
}

const refreshCosts = coalesce(async () => {
  const q = costsParams().toString();
  try { cost.data = await api("/api/costs" + (q ? "?" + q : "")); cost.err = null; } catch (e) { cost.err = e.message; }
  if (st.tab === "costs") renderCosts();
});

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
function costsSwitch(name, all, on, key) {
  return `<div class="seg fseg"><span class="muted">${name}</span>` + all.map((x) =>
    `<button class="${x === on ? "on" : ""}" data-cv="${key}" data-cval="${esc(x)}">${esc(x)}</button>`).join("") + `</div>`;
}

// "of $cap (pct%)" under a spend tile, or nothing when there is no cap.
const ofCap = (spent, cap) => spent != null && cap ? `of ${usd(cap)} (${pct(spent / cap)})` : "";

// The Lazer tiles, the TUI's `lazer` and `direct` lines: the gateway pool, the reserve key and the GLM
// pilot key (once minted) against their caps, and direct use with what it cannot see beside it, so a low figure never reads as all of it.
function lazerTiles(lz, dr) {
  const left = lz.reserve_reset_hours != null ? `${Math.round(lz.reserve_reset_hours / 24)}d left` : "";
  const glmLeft = lz.glm_reset_hours != null ? `${Math.round(lz.glm_reset_hours / 24)}d left` : "";
  const glm = lz.glm_spend != null || lz.glm_budget != null
    ? tile("LAZER GLM", usd(lz.glm_spend), "var(--c3)", [ofCap(lz.glm_spend, lz.glm_budget), glmLeft].filter(Boolean).join(", ")) : "";
  const unpriced = dr.unpriced ? `<span class="warn">+${dr.unpriced} unpriced</span>, ` : "";
  return tile("LAZER POOL", usd(lz.lazer_spend), "var(--c3)", ofCap(lz.lazer_spend, lz.lazer_budget)) +
    tile("LAZER RESERVE", usd(lz.reserve_spend), "var(--c3)", [ofCap(lz.reserve_spend, lz.reserve_budget), left].filter(Boolean).join(", ")) + glm +
    tile("LAZER DIRECT", usd(dr.usd), "var(--c3)", unpriced + esc(dr.note || "not read"));
}

function costsTiles(d) {
  const lz = d.live || {};
  return `<div class="tiles roomy">` + (d.totals || []).map((t) =>
    tile(`SPEND ${t.window.toUpperCase()}`, usd(t.usd), t.window === d.window ? "var(--c1)" : "var(--c-other)", `${t.sessions} sessions${t.unpriced ? `, ${t.unpriced} unpriced` : ""}`)).join("") +
    tile("LIVE 24H", usd(lz.claude_24h), "var(--c2)", "Prometheus, exported sessions only") +
    lazerTiles(lz, d.direct || {}) + `</div>`;
}

// The Burn section (hub_core::burn, the hub's coststab.rs `burn`): the headline coloured by the
// fleet's level, then the drip, when the accounts are back on pace and one row per account. Green
// folds to its headline (dashboards rule 4); amber and red start open until the reader folds it.
function burnPace(b) {
  const p = b.pace;
  if (p.on_pace) return "every account is on pace";
  const burn = p.at_burn.length ? p.at_burn.map(([n, t]) => `${esc(n)} ${when(t)}`).join(", ") : "not before the reset";
  const idle = p.idle_all_by == null ? "" : `; if idle: all by ${when(p.idle_all_by)}${p.idle_rest_after_reset ? ", the rest after the reset" : ""}`;
  return `at this burn: ${burn}${idle}`;
}

// A back-on-pace cell: on pace, the time, or after the reset (Account::on_pace).
const burnCell = (a, t, at) => (!(a.used > a.gone) || (t != null && t <= at) ? "on pace" : t == null ? "after reset" : when(t));

function burnRow(a, at, note) {
  if (a.state === "unreadable") return `<tr><td>${esc(a.name)}</td><td colspan="10" class="bad">usage unreadable</td></tr>`;
  if (a.state === "stale") return `<tr><td>${esc(a.name)}</td><td colspan="10" class="bad">${esc(note)}</td></tr>`;
  if (a.state === "idle") return `<tr><td>${esc(a.name)}</td><td colspan="10" class="muted">idle, token refreshes on launch</td></tr>`;
  const pc = (v) => (v == null ? "-" : Math.floor(v) + "%");
  const rate = (v) => (v == null ? "-" : v.toFixed(2));
  return `<tr><td>${esc(a.name)}</td><td class="n">${a.live}</td><td class="n">${pc(a.used)}</td><td class="n">${pc(a.gone)}</td>` +
    `<td class="${a.room ? (a.room.ok ? "ok" : "bad") : "muted"}">${a.room ? esc(a.room.text) : "-"}</td>` +
    `<td class="n${a.sustain != null && a.burn > a.sustain ? " warn" : ""}">${rate(a.burn)}</td><td class="n">${rate(a.sustain)}</td>` +
    `<td>${burnCell(a, a.burn_at, at)}</td><td>${burnCell(a, a.idle_at, at)}</td><td>${when(a.run_out)}</td><td>${when(a.resets)}</td></tr>`;
}

function costsBurn(d) {
  const b = d.burn;
  if (!b || !b.accounts.length) return `<h2 class="sec" id="sec-burn">Burn</h2><div class="panel muted">no data from claude-acct</div>`;
  const cls = b.level === "bad" ? "bad" : b.level === "warn" ? "warn" : "ok";
  const held = b.drip.held ? ` <a class="warn" href="#sessions" title="${esc(b.drip.held)}">dispatch held -> Sessions</a>` : "";
  const open = cost.open.burn != null ? cost.open.burn : b.level !== "ok";
  const th = (t) => `<th class="n">${t}</th>`;
  return `<details class="csec" data-k="burn" id="sec-burn"${open ? " open" : ""}><summary><h2 class="sec">Burn <span class="burn ${cls}">${esc(b.head)}</span></h2></summary>` +
    `<div class="panel"><div><span class="muted">DRIP</span> ${esc(b.drip_line)}${held}</div>` +
    `<div><span class="muted">BACK ON PACE</span> ${burnPace(b)}</div></div>` +
    `<div class="panel scroll"><table class="tbl"><tr><th>account</th>${["live", "used", "gone"].map(th).join("")}<th>room</th>${["burn/h", "keeps/h"].map(th).join("")}<th>at burn</th><th>if idle</th><th>runs out</th><th>resets</th></tr>` +
    b.accounts.map((a) => burnRow(a, b.at, b.stale)).join("") + `</table></div>` +
    `<div class="muted fold">burn/h is the last 6h rate per live session; keeps/h is what the rest of the week can carry to the reset.</div></details>`;
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
  let html = `${costsBurn(d)}${costsSections(d)}<h2 class="sec" id="sec-totals">Costs <span class="muted">as of: ${asOf}</span>${g}</h2>${costsTiles(d)}`;
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

function renderCosts() {
  const el = $("costs");
  const d = cost.data;
  if (!d || !d.table) {
    el.innerHTML = `<div class="empty">${cost.err ? esc(cost.err) : "Loading..."}</div>`;
    return;
  }
  // A fold the reader just opened is in the page and not yet in `cost.open`, and the head below is
  // built from that map: record it first, or the next repaint (a sort click) closes it again.
  el.querySelectorAll("details[data-k]").forEach((f) => { cost.open[f.dataset.k] = f.open; });
  if (tblRepaint("costs", d.table, () => costsBody(d))) {
    paint($("costs-tail"), costsTail(d));
    return;
  }
  paint(el, `<div id="costs-head">${costsHead(d)}</div>` +
    `<div id="sec-table">${costsSwitch("window", d.windows, d.window, "w")}${costsSwitch("by", d.cuts, d.by, "by")}</div>` +
    `${tblBar("costs", d.table, "search, or harness:codex -model:opus project:dotfiles")}` +
    `<div id="costs-body">${costsBody(d)}</div><div id="costs-tail">${costsTail(d)}</div>`, cost.open);
  seekSection();
}

// The view changed: the URL follows it and the server applies it. A new cut has other columns,
// so its sort goes back to the cut's own.
function costsView(patch) {
  if ("by" in patch) Object.assign(patch, { sort: "", dir: "" });
  setQuery(tblSet(st.views.costs, patch));
  refreshCosts();
}

$("costs").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest && t.closest("a[target]")) return;
  const sw = t.closest && t.closest("[data-cv]");
  if (sw) { costsView({ [sw.dataset.cv]: sw.dataset.cval }); return; }
  const ss = t.closest && t.closest("[data-ssort]");
  if (ss) { costsView({ ssort: ss.dataset.ssort, sdir: ss.dataset.ssort && ss.dataset.sdir === "asc" ? "asc" : "" }); return; }
  const v = tblPatch(e);
  if (v) costsView(v);
});
tblListen($("costs"), costsView);

const pollCosts = poll("costs", refreshCosts, COSTS_REFRESH_MS);
TABS.costs = {
  show() { renderCosts(); pollCosts(); },
  onEvent() {},
};
