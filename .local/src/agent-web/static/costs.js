"use strict";
// The Costs tab: what the fleet spent, cut seven ways, with fleet-bench's evaluation on the model
// and harness cuts. /api/costs is hub_core::costs::board, the view the hub TUI draws; this file
// draws its answer and turns a click into the view keys (by, w, q, sort, dir) in the URL, so
// `#costs?by=model&w=7d&q=harness:codex` is a link to that view. Trends are Grafana's.

const cost = { data: null, err: null };

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
  for (const k of ["by", "w"]) if (v.get(k)) p.set(k, v.get(k));
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
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, Object.fromEntries(d.columns.map((k) => [k, COST_COLS[k]])))}` +
    shown.map((r) => `<tr>${d.columns.map((k) => costCell(r, k, d)).join("")}</tr>`).join("") + `</table>${older(rows.length - shown.length)}</div>`;
}

// The window and cut switches: each a link, so a view is a URL.
function costsSwitch(name, all, on, key) {
  return `<div class="seg fseg"><span class="muted">${name}</span>` + all.map((x) =>
    `<button class="${x === on ? "on" : ""}" data-cv="${key}" data-cval="${esc(x)}">${esc(x)}</button>`).join("") + `</div>`;
}

function costsTiles(d) {
  const lz = d.live || {};
  const pool = lz.lazer_spend != null && lz.lazer_budget ? `of ${usd(lz.lazer_budget)} (${Math.round(lz.lazer_spend / lz.lazer_budget * 100)}%)` : "";
  return `<div class="tiles roomy">` + (d.totals || []).map((t) =>
    tile(`SPEND ${t.window.toUpperCase()}`, usd(t.usd), t.window === d.window ? "var(--c1)" : "var(--c-other)", `${t.sessions} sessions${t.unpriced ? `, ${t.unpriced} unpriced` : ""}`)).join("") +
    tile("LIVE 24H", usd(lz.claude_24h), "var(--c2)", "Prometheus, exported sessions only") +
    tile("LAZER POOL", usd(lz.lazer_spend), "var(--c3)", pool) + `</div>`;
}

function costsHead(d) {
  const asOf = (d.sources || []).map((s) => `<span class="${s.stale ? "warn" : "muted"}">${esc(s.name)} ${s.as_of ? when(s.as_of) : "never"}</span>`).join(" &middot; ");
  const g = d.grafana ? ` <a class="glink" href="${esc(d.grafana)}" target="_blank" rel="noopener">trends in Grafana</a>` : "";
  let html = `<h2 class="sec" id="sec-totals">Costs <span class="muted">as of: ${asOf}</span>${g}</h2>${costsTiles(d)}`;
  if (cost.err) html += `<div class="panel down">${esc(cost.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// The note under the table, the TUI's lines (coststab.rs `lines`).
function costsTail(d) {
  const ev = d.by === "model" || d.by === "harness"
    ? ` Landed, redo, rev and $/PR are fleet-bench models${d.eval_days ? ` over ${d.eval_days}d` : ""}, queue items only.` : "";
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
  if (tblRepaint("costs", d.table, () => costsBody(d))) {
    paint($("costs-tail"), costsTail(d));
    return;
  }
  paint(el, `<div id="costs-head">${costsHead(d)}</div>` +
    `<div id="sec-table">${costsSwitch("window", d.windows, d.window, "w")}${costsSwitch("by", d.cuts, d.by, "by")}</div>` +
    `${tblBar("costs", d.table, "search, or harness:codex -model:opus project:dotfiles")}` +
    `<div id="costs-body">${costsBody(d)}</div><div id="costs-tail">${costsTail(d)}</div>`);
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
  const v = tblPatch(e);
  if (v) costsView(v);
});
tblListen($("costs"), costsView);

const pollCosts = poll("costs", refreshCosts, COSTS_REFRESH_MS);
TABS.costs = {
  show() { renderCosts(); pollCosts(); },
  onEvent() {},
};
