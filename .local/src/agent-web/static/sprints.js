"use strict";
// Release windows (/api/sprints, hub_core::tasks::SprintRow with its times read on the server,
// and hub_core::project_sprints for the scored past), on two surfaces that share this table:
// Projects' Sprints inner tab (every project's open and queued windows, then each project's last
// score) and an opened project's Sprint inner tab (its open window, the ones queued behind it,
// its Past sprints). Both were once Board's Sprints table. A window opens to its tasks, most
// urgent first; a task leads with its title over what the title leaves out, as its Board row does
// (hub_core::tasks::row_title), and opens in place to its whole line and, when it has one, the
// link to its Board row. Read only while shown, on resync and on a queue change.

const sprShown = () => st.tab === "projects" && (pst.open ? pst.inner === "sprint" : pTab() === "sprints");
const sprScope = () => pst.open || "";
const sprst = { data: null, err: null, scope: null, spr: null, stask: null, past: null };

const refreshSprints = coalesce(async () => {
  if (!sprShown()) return;
  const scope = sprScope();
  try {
    const got = await api("/api/sprints" + (scope ? "?scope=" + encodeURIComponent(scope) : ""));
    if (scope === sprScope()) {
      sprst.data = got; sprst.scope = scope; sprst.err = null;
      if (!scope) pCountSet("sprints", got.rows.length);
    }
  } catch (e) { if (scope === sprScope()) sprst.err = e.message; }
  if (st.tab === "projects") renderProjects();
});

// What the pane draws is the read for its own scope; another's is stale and waits for the next.
const sprData = () => (sprst.data && sprst.scope === sprScope() ? sprst.data : null);

const sprKey = (s) => `${s.profile}/${s.project}/${s.version}`;
const sprTaskKey = (s, t) => `${sprKey(s)}/${t.id || t.text}`;
const SPR_TASK_COLS = [["id", "ID", "lead"], ["title", "TASK", ""], ["priority", "PRIORITY", "glance"], ["state", "STATE", "glance"]];
const sprTask = (t) => `<div class="card qitem brow"><div class="q">${esc(t.text)}</div>` +
  (t.href ? `<div class="opts"><a class="btn sm" href="${esc(t.href)}">Open its Board row</a></div>` : "") + `</div>`;

function sprTasks(s) {
  if (!s.tasks.length) return `<div class="muted">No task in this window.</div>`;
  return `<table class="tbl"><tr>${SPR_TASK_COLS.map(([, h, r]) => `<th data-role="${r}" data-label="${h}">${h}</th>`).join("")}</tr>` +
    s.tasks.map((t) => {
      const state = t.queue || t.state, k = sprTaskKey(s, t), open = sprst.stask === k;
      const sum = t.summary ? `<div class="bsum muted">${esc(t.summary)}</div>` : "";
      const line = `<tr class="jr${open ? " sel" : ""}" data-stask="${esc(k)}"><td><code>${pDash(t.id)}</code></td>` +
        `<td class="btitle"><div class="bt">${esc(t.title)}${t.interrupt ? ` <span class="qtag">interrupt</span>` : ""}</div>${sum}</td>` +
        `<td><span class="qprio ${esc(t.priority)}">${esc(t.priority)}</span></td>` +
        `<td>${state === "running" || state === "doing" ? `<b>${esc(state)}</b>` : esc(state)}</td></tr>`;
      return open ? line + `<tr class="bopen"><td colspan="${SPR_TASK_COLS.length}">${sprTask(t)}</td></tr>` : line;
    }).join("") + `</table>`;
}

// The windows `rows` as one table; `all` opens every row to its tasks (one project's), else a click does.
function sprTable(d, rows, all) {
  const keys = d.table.columns.map((c) => c.key);
  const role = Object.fromEntries(d.table.columns.map((c) => [c.key, c.role || ""]));
  const th = (k) => `<th data-role="${role[k] || ""}" data-label="${esc(d.heads[k] || k)}">${esc(d.heads[k] || k)}</th>`;
  const cell = (s, k) => {
    if (k === "finish" && s.late) return `<td class="warn">${esc(s.finish)} late</td>`;
    if (k === "left" && s.left === "over") return `<td class="warn">over</td>`;
    // The next version's sprint, locked while the open one runs: STARTED is the open one's cut.
    if (k === "left" && s.left === "queued") return `<td class="muted">queued</td>`;
    return `<td>${pDash(k === "build" && s.build === "none" ? "" : s[k])}</td>`;
  };
  const body = rows.map((s) => {
    const open = all || sprst.spr === sprKey(s);
    const line = `<tr class="jr${open ? " sel" : ""}" data-spr="${esc(sprKey(s))}">${keys.map((k) => cell(s, k)).join("")}</tr>`;
    return open ? line + `<tr class="bopen"><td colspan="${keys.length}">${sprTasks(s)}</td></tr>` : line;
  }).join("");
  return `<div class="panel scroll"><table class="tbl"><tr>${keys.map(th).join("")}</tr>${body}</table></div>`;
}

// Projects' Sprints inner tab: every project's open and queued windows, then each project's last score.
function sprAll(d) {
  const last = d.last || [];
  return secHead("sprints", "Sprints", d.rows.length) +
    (d.rows.length ? sprTable(d, d.rows, false) : `<div class="card muted">No window is open or queued.</div>`) +
    secHead("", "Last score", last.length) +
    (last.length ? `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">PROJECT</th><th>VERSION</th><th>SCORE</th></tr>` +
      last.map((l) => `<tr><td>${esc(l.project)}</td><td>${esc(l.version)}</td><td class="wrap muted">${esc(l.line)}</td></tr>`).join("") + `</table></div>`
      : `<div class="card muted">No project has a scored window.</div>`);
}

const SPR_PAST = [["version", "VERSION", "lead"], ["opened", "OPENED", ""], ["cut", "CUT", ""], ["committed", "COMMITTED", ""],
  ["delivered", "DELIVERED", "glance"], ["carried", "CARRIED", ""], ["dropped", "DROPPED", ""], ["interrupted", "INTERRUPTED", ""], ["timing", "TIMING", "glance"]];
// The scored windows, newest first; a row opens to its score line and the sprint file it is in.
function sprPast(past) {
  if (!past.length) return `<div class="card muted">No window has been cut with a score yet.</div>`;
  const body = past.map((p) => {
    const open = sprst.past === p.version;
    const line = `<tr class="jr${open ? " sel" : ""}" data-past="${esc(p.version)}">${SPR_PAST.map(([k]) =>
      `<td${p.timing && p.timing !== "on time" && k === "timing" ? ` class="warn"` : ""}>${pDash(p[k])}</td>`).join("")}</tr>`;
    return open ? line + `<tr class="bopen"><td colspan="${SPR_PAST.length}"><div class="card qitem brow"><div class="q">${esc(p.line)}</div>` +
      `<div class="muted"><code>sprints/${esc(p.version)}.md</code> in the project's lab directory</div></div></td></tr>` : line;
  }).join("");
  return `<div class="panel scroll"><table class="tbl"><tr>${SPR_PAST.map(([, h, r]) => `<th data-role="${r}" data-label="${h}">${h}</th>`).join("")}</tr>${body}</table></div>`;
}

$("projects").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a")) return;
  const toggle = (key, sel) => { sprst[key] = sprst[key] === sel ? null : sel; renderProjects(); };
  const task = t.closest("tr[data-stask]");
  if (task) return toggle("stask", task.dataset.stask);
  const spr = t.closest("tr[data-spr]");
  if (spr) return toggle("spr", spr.dataset.spr);
  const past = t.closest("tr[data-past]");
  if (past) toggle("past", past.dataset.past);
});
