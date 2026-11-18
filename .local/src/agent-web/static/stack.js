"use strict";
// The Stack tab: what the agent system is made of, from /api/stack (hub_core::stack). One read
// holds five tables, one per inner tab: Flows, Skills, Agents (subagents), Hooks and Rules. Each keeps its
// own view keys under its prefix (STACK_TABLES) and the server filters and sorts. Runners are a
// count that links to Sessions' Runners, and a skill's spend links to Costs' by-skill cut: each of
// those has its home there (dashboards rule 2).

// Nothing here pushes: the stack changes by the PR, and the server folds reads inside two minutes.
const STACK_REFRESH_MS = 120e3;
// Rows a table opens with, the rest a click away; the chips, search and filters reach every row.
// 30 keeps Rules, whose rule text wraps to two lines on a phone, under three screens (render.mjs:
// 120 rules drew 6,944 px, 2026-11-18).
const STACK_OPEN_ROWS = 30;

// A column key as its header, the TUI's words (stacktab.rs); [text, class].
const FLOW_COLS = { flow: ["flow"], question: ["question"], source: ["defined in"], picture: ["picture"], checked: ["checked by"], state: ["state"] };
const SKILL_COLS = { skill: ["skill"], category: ["category"], repo: ["repo"], calls: ["calls", "n"], runners: ["runners"], drift: ["drift"] };
const AGENT_COLS = { agent: ["agent"], model: ["model"], tools: ["tools"], repo: ["repo"] };
const HOOK_COLS = { harness: ["harness"], event: ["event"], matcher: ["matcher"], script: ["script"], from: ["from"] };
const RULE_COLS = { rule: ["rule"], kind: ["kind"], number: ["number", "n"], confidence: ["confidence"], state: ["state"], source: ["source"] };

const stk = tblTab({
  tab: "stack", id: "stk", el: "stack", api: "/api/stack", hint: "search, or category:ops drift:deadpath -repo:private",
  lead: () => stackStrip(stk.data),
  params: (p) => { for (const pre of Object.keys(STACK_TABLES)) for (const [k, v] of tblParams(st.views.stack, pre)) p.set(k, v); },
  head: (t) => stackHead(t.data), wrap: (html) => innerWrap("stack", "skills", `<div data-tbl="">${html}</div>`),
  body: (t) => skillsBody(t.data),
  draw: (html) => paint($("stack"), html + Object.values(STACK_TABLES).map((t) => t.html()).join("")),
});

// The other four tables of the one read: each draws its bar and rows in its inner tab, under its
// prefix's block so a search or sort routes to it. `inner` puts it in its inner tab.
const stackTable = (pre, key, hint, body, inner) => tblTab({
  tab: "stack", id: "stk-" + pre, el: "stack", pre, hint, refresh: () => stk.refresh(), render: () => stk.render(),
  table: () => stk.data?.[key]?.table, body: () => body(stk.data),
  wrap: (html) => inner(`<div data-tbl="${pre}">${html}</div>`),
});
const STACK_TABLES = {
  f: stackTable("f", "flows", "search, or state:unchecked", (d) => flowsBody(d), (h) => innerWrap("stack", "flows", h)),
  g: stackTable("g", "agents", "search, or model:sonnet repo:public", (d) => agentsBody(d), (h) => innerWrap("stack", "agents", h)),
  k: stackTable("k", "hooks", "search, or event:PreToolUse harness:codex", (d) => hooksBody(d), (h) => innerWrap("stack", "hooks", h)),
  r: stackTable("r", "rules", "search, or kind:invariant state:moved", (d) => rulesBody(d), (h) => innerWrap("stack", "rules", h)),
};
// A search or dropdown in use in one table keeps its focus: only that table repaints, and the
// others redraw (Alerts' three tables).
const stackPaint = stk.render;
stk.render = () => {
  const all = [stk, ...Object.values(STACK_TABLES)], busy = stk.data?.table && all.find((t) => t.repaint());
  if (!busy) { stackPaint(); return; }
  for (const t of all) if (t !== busy) t.redraw();
};

// The strip, each inner tab's count of rows that need a look (the server's `strip`) as its pill.
const stackStrip = (d) => innerStrip("stack", [], d?.strip);

// What the tab read and when, and anything it could not read, above the open inner tab.
function stackHead(d) {
  let html = stackStrip(d) + `<div class="muted">Read ${d.at ? clock(d.at * 1e3) : "-"}. Runners: <a href="#sessions/runners">${d.runners ?? 0} on Sessions, Runners</a>. ` +
    `Skill spend: <a href="#costs?by=skill">Costs, Spend by skill</a>.</div>`;
  if (stk.err) html += `<div class="panel down">${esc(stk.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

const stackCell = (v, cls = "") => `<td class="${cls}">${v == null || v === "" ? "-" : esc(String(v))}</td>`;

// One table's rows under its head, the first STACK_OPEN_ROWS open (`tb` is its tblTab), or the
// words for none: `none` when nothing is there at all, `miss` when the view hides every row.
function stackList(tb, title, part, cols, row, miss, none) {
  const t = part.table, shown = part.rows || [];
  const rows = tb.all ? shown : shown.slice(0, STACK_OPEN_ROWS);
  return secHead("", title, tblCount(t)) + (shown.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, cols)}${rows.map(row).join("")}</table>${tblMore(shown.length - rows.length, "more")}</div>`
    : `<div class="panel">${t.total ? miss : none}</div>`);
}

// The skills' list names the window its calls column counts and the drift snapshot's day.
function skillsBody(d) {
  const days = d.use_days ? `calls over the newest ${d.use_days} day snapshots` : `calls ${NOT_READ}`;
  const drift = d.drift_day ? `drift as of ${d.drift_day}` : `drift ${NOT_READ}`;
  return `<div class="muted">${esc(days)}; ${esc(drift)}</div>` +
    stackList(stk, "Skills", d, SKILL_COLS, skillRow, "No skills match.", "No skills are installed.");
}

function skillRow(r) {
  const open = r.name === stk.sel;
  const runners = (r.runners || []).map((n) => `<a href="${runnerHref(n)}">${esc(n)}</a>`).join(", ") || "-";
  const drift = [...new Set((r.drift || []).map((f) => f.kind))];
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(r.name)}">` +
    `<td class="wrap">${esc(r.name)}${r.paths?.length ? ` <span class="muted" title="listed only once a session touches ${esc(r.paths.join(", "))}">scoped</span>` : ""}</td>` +
    stackCell(r.category, "muted") + stackCell(r.repo, "muted") + stackCell(r.calls, "n") + `<td class="wrap">${runners}</td>` +
    stackCell(drift.join(", "), drift.length ? "warn" : "") + `</tr>`;
  return open ? row + skillDetail(r) : row;
}

function skillDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const finds = (r.drift || []).map((f) => `<div><span class="warn">${esc(f.kind)}</span> ${esc(f.item)} <span class="muted">${esc(f.detail)}</span></div>`).join("");
  return `<tr class="wdet"><td colspan="${Object.keys(SKILL_COLS).length}"><div class="sdet">` +
    `<div>${esc(r.description || "no description")}</div>` +
    line("Loads on", esc((r.paths || []).join(", "))) + line("Drift", finds) +
    line("Spend", `<a href="#costs?by=skill&q=${encodeURIComponent(r.name)}">Costs, Spend by skill</a>`) + `</div></td></tr>`;
}

// Flows: ARCHITECTURE.md's Flows table. A row opens its doc section, read now from the file the
// row names, with its picture; `flowDocs` keeps each opened section until the next read.
const FLOW_HUE = { ok: "", unchecked: "warn", broken: "bad" };
const flowDocs = {};
let flowOpen = null;
function flowRow(r) {
  const open = r.flow === flowOpen;
  const row = `<tr class="jf${open ? " sel" : ""}" data-flow="${esc(r.flow)}" title="${esc((r.why || []).join("; "))}">${stackCell(r.flow)}${stackCell(r.question, "wrap muted")}` +
    `${stackCell((r.source || "").replace(/^~\//, ""), "wrap muted")}${stackCell((r.picture || "").split("/").pop(), "muted")}` +
    `${stackCell((r.checked || []).map((t) => t.split("/").pop()).join(", ") || "none", r.checked?.length ? "muted" : "warn")}${stackCell(r.state, FLOW_HUE[r.state] ?? "")}</tr>`;
  return open ? row + flowDetail(r) : row;
}
function flowDetail(r) {
  const d = flowDocs[r.flow], why = (r.why || []).map((w) => `<div class="bad">${esc(w)}</div>`).join("");
  const body = !d ? `<div class="muted">Reading ${esc(r.source)}...</div>` : d.err ? `<div class="panel down">${esc(d.err)}</div>`
    : `<div class="md">${md(d.text)}</div>${d.picture ? `<img class="flowpic" alt="${esc(r.flow)}" src="/api/stack/flow.svg?name=${encodeURIComponent(r.flow)}">` : ""}`;
  return `<tr class="wdet"><td colspan="${Object.keys(FLOW_COLS).length}"><div class="sdet">${why}${body}</div></td></tr>`;
}
async function flowLoad(name) {
  try { flowDocs[name] = await api(`/api/stack/flow?name=${encodeURIComponent(name)}`); }
  catch (e) { flowDocs[name] = { err: e.message }; }
  stk.render();
}
const flowsBody = (d) => `<div class="muted">From the Flows table of ARCHITECTURE.md; checked by a test that fails when the code leaves the doc.</div>` +
  stackList(STACK_TABLES.f, "Flows", d.flows, FLOW_COLS, flowRow, "No flows match.", "ARCHITECTURE.md lists no flows.");

const agentRow = (r) => `<tr title="${esc(r.description)}"><td>${esc(r.name)}</td>${stackCell(r.model || "inherit", r.model ? "" : "muted")}` +
  `${stackCell(r.tools, "wrap muted")}${stackCell(r.repo, "muted")}</tr>`;
const agentsBody = (d) => stackList(STACK_TABLES.g, "Subagents", d.agents, AGENT_COLS, agentRow, "No subagents match.", "No subagents are defined.");

const hookRow = (r) => `<tr title="${esc(r.command)}">${stackCell(r.harness, "muted")}${stackCell(r.event)}${stackCell(r.matcher || "*", "wrap muted")}` +
  `<td class="${r.found ? "" : "bad"}">${esc(r.script)}${r.found ? "" : " (missing)"}</td>${stackCell(r.from, "muted")}</tr>`;
const hooksBody = (d) => stackList(STACK_TABLES.k, "Hooks", d.hooks, HOOK_COLS, hookRow, "No hooks match.", "No hooks are configured.");

const RULE_HUE = { ok: "", stale: "warn", moved: "warn", dead: "bad" };
const ruleRow = (r) => `<tr title="${esc(r.why || r.today)}">${stackCell(r.rule, "wrap")}${stackCell(r.kind, "muted")}${stackCell(r.number, "n")}` +
  `${stackCell(r.confidence, "muted")}${stackCell(r.state, RULE_HUE[r.state] ?? "")}${stackCell(r.source, "wrap muted")}</tr>`;

// The rules table, then the path-scoped rule files and the globs that load each.
function rulesBody(d) {
  const files = (d.rule_files || []).map((f) => `<div><b>${esc(f.name)}</b> <span class="muted">${esc((f.paths || []).join(", "))}</span></div>`).join("");
  const scoped = files ? `<div class="panel"><div class="muted">Path-scoped rules (.claude/rules)</div>${files}</div>` : "";
  return stackList(STACK_TABLES.r, "Rules", d.rules, RULE_COLS, ruleRow, "No rules match.", "No rules are recorded.") + scoped;
}

$("stack").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest("details") || t.closest("button")) return;
  const fr = t.closest("tr.jf");
  if (fr && stk.data) {
    const name = fr.dataset.flow;
    flowOpen = flowOpen === name ? null : name;
    if (flowOpen) { delete flowDocs[name]; flowLoad(name); }
    stk.render();
    return;
  }
  const tr = t.closest("tr.jr");
  if (!tr || !stk.data) return;
  stk.sel = stk.sel === tr.dataset.key ? null : tr.dataset.key;
  stk.render();
});

const pollStack = poll("stack", stk.refresh, STACK_REFRESH_MS);
TABS.stack = {
  show() { stk.render(); pollStack(); },
  onEvent(ev) { if (ev.kind === "resync" && st.tab === "stack") stk.refresh(); },
};
