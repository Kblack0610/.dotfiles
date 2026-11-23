"use strict";
// Release windows (/api/sprints, hub_core::tasks::SprintRow with its times read on the server,
// and hub_core::project_sprints for the scored past), on two surfaces that share this table:
// Projects' Sprints inner tab (every project's open and queued windows, then each project's last
// score) and an opened project's Sprint inner tab (its open window, the ones queued behind it,
// its Past sprints). A version in either table links to that window's own page (/api/sprints/page,
// hub_core::sprint_page): its dates and score, a By area rollup and every row with its outcome on
// the shared table, shown in place of the list while `pst.sprint` names it. Read only while
// shown, on resync and on a queue change.

const sprShown = () => st.tab === "projects" && (pst.open ? pst.inner === "sprint" && !pst.sprint : pTab() === "sprints");
const sprScope = () => pst.open || "";
const sprst = { data: null, err: null, scope: null };

// One window's page: its view keys carry the `sp` prefix, so they never read the Rows tab's.
const spgShown = () => st.tab === "projects" && !!pst.open && pst.inner === "sprint" && !!pst.sprint;
const SPG_COLS = {
  id: ["ID", "", false], type: ["TYPE", "", false], scope: ["SCOPE", "", false], group: ["AREA", "", false], title: ["TITLE", "", false],
  pts: ["PTS", "n", false], outcome: ["OUTCOME", "", false], state: ["STATE", "", false], interrupt: ["INTERRUPT", "", false],
};
const SPG_CELL = { type: "kind" };
const spg = tblTab({
  tab: "projects", id: "spg", el: "p-spg", on: "projects", pre: "sp", api: "/api/sprints/page", hint: "search, or group:engineering outcome:carried -type:chore",
  shown: spgShown, wait: "Reading the sprint...",
  table: (t) => (t.data && t.data.asked === pst.sprint ? t.data.table : null),
  params: (p) => { const [profile, project] = pst.open.split("/"); p.set("profile", profile); p.set("project", project); p.set("version", pst.sprint); },
  wrap: (html) => `<div data-tbl="sp">${html}</div>`,
  head: (t) => spgHead(t.data), body: (t) => spgRows(t.data),
});

// The version page's top: the way back and to the neighbours, its dates and score, then the By area
// rollup; a row of it narrows the rows below to that group (a click on the bar's clear gives them back).
function spgHead(d) {
  const g = d.page, heads = d.area_heads, keys = Object.keys(heads);
  const near = (href, text) => (href ? tblLink(href, text) : `<span class="muted">${esc(text)}</span>`);
  const quote = (v) => (/\s/.test(v) ? `"${v}"` : v);
  const area = (a) => `<tr class="jr" data-tqc="${esc("group:" + quote(a.group))}" title="rows of ${esc(a.group)}">${keys.map((k) => `<td${k === "group" ? "" : ` class="n"`}>${esc(a[k])}</td>`).join("")}</tr>`;
  return `<nav class="crumb" aria-label="breadcrumb"><a href="#" id="spg-back">All sprints</a> <span class="muted">&gt;</span> <b>${esc(g.version)}</b>` +
    ` ${near(g.prev, "previous")} ${near(g.next, "next")}</nav>` +
    secHead("p-sprint-page", `Sprint ${g.version}`, null) +
    `<div class="card">${g.head.map((l) => `<div class="cline">${esc(l)}</div>`).join("")}</div>` +
    (g.errors || []).map((e) => `<div class="panel down">${esc(e)}</div>`).join("") +
    secHead("p-sprint-areas", "By area", g.by_area.length) +
    (g.by_area.length
      ? `<div class="panel scroll"><table class="tbl"><tr>${keys.map((k) => `<th${k === "group" ? "" : ` class="n"`}>${esc(heads[k])}</th>`).join("")}</tr>${g.by_area.map(area).join("")}</table></div>`
      : `<div class="card muted">No row in this window.</div>`) +
    secHead("p-sprint-rows", "Rows", d.table.total);
}

function spgRows(d) {
  const t = d.table, cols = t.columns.filter((c) => SPG_COLS[c.key]);
  const cell = (r, i, k) => {
    if (k === "pts") return `<td class="n">${r.pts}</td>`;
    if (k === "interrupt") return `<td>${r.interrupt ? `<span class="qtag">interrupt</span>` : "-"}</td>`;
    if (k === "title") return `<td class="wrap">${esc(r.title)}</td>`;
    if (k === "outcome") return `<td${r.outcome === "dropped" ? ` class="warn"` : ""}>${pDash(r.outcome)}</td>`;
    const v = r[SPG_CELL[k] || k];
    return `<td>${k === "id" ? tblLink(tblLinks(t, i).id, v) : pDash(v)}</td>`;
  };
  return d.rows.length
    ? `<div class="panel scroll"><table class="tbl">${tblHead(t, SPG_COLS)}${d.rows.map((r, i) => `<tr>${cols.map((c) => cell(r, i, c.key)).join("")}</tr>`).join("")}</table></div>`
    : `<div class="card muted">${t.total ? "No row matches." : "No row in this window."}</div>`;
}

// The page shows in place of the list; the way back drops the version from the URL.
function sprBack() { if (pst.open) pInner("sprint"); }

const refreshSprints = coalesce(async () => {
  if (spgShown()) { await spg.refresh(); return; }
  if (!sprShown()) return;
  const scope = sprScope();
  try {
    const got = await api("/api/sprints" + (scope ? "?scope=" + encodeURIComponent(scope) : ""));
    if (scope === sprScope()) {
      sprst.data = got; sprst.scope = scope; sprst.err = null;
      if (!scope) pCountSet("sprints", got.rows.length);
    }
  } catch (e) { if (scope === sprScope()) { sprst.err = e.message; sprst.data = null; } }
  if (st.tab === "projects") renderProjects();
});

// What the pane draws is the read for its own scope; another's is stale and waits for the next.
const sprData = () => (sprst.data && sprst.scope === sprScope() ? sprst.data : null);

// The windows `rows` as one table; a version is the link to its page.
function sprTable(d, rows) {
  const keys = d.table.columns.map((c) => c.key);
  const role = Object.fromEntries(d.table.columns.map((c) => [c.key, c.role || ""]));
  const th = (k) => `<th data-role="${role[k] || ""}" data-label="${esc(d.heads[k] || k)}">${esc(d.heads[k] || k)}</th>`;
  const cell = (s, i, k) => {
    if (k === "version") return `<td>${tblLink(tblLinks(d.table, i).version, s.version)}</td>`;
    if (k === "finish" && s.late) return `<td class="warn">${esc(s.finish)} late</td>`;
    if (k === "left" && s.left === "over") return `<td class="warn">over</td>`;
    // The next version's sprint, locked while the open one runs: STARTED is the open one's cut.
    if (k === "left" && s.left === "queued") return `<td class="muted">queued</td>`;
    return `<td>${pDash(k === "build" && s.build === "none" ? "" : s[k])}</td>`;
  };
  const at = new Map(d.rows.map((s, i) => [s, i]));
  const body = rows.map((s) => `<tr>${keys.map((k) => cell(s, at.get(s), k)).join("")}</tr>`).join("");
  return `<div class="panel scroll"><table class="tbl"><tr>${keys.map(th).join("")}</tr>${body}</table></div>`;
}

// Projects' Sprints inner tab: every project's open and queued windows, then each project's last score.
function sprAll(d) {
  const last = d.last || [];
  return secHead("sprints", "Sprints", d.rows.length) +
    (d.rows.length ? sprTable(d, d.rows) : `<div class="card muted">No window is open or queued.</div>`) +
    secHead("", "Last score", last.length) +
    (last.length ? `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">PROJECT</th><th>VERSION</th><th>SCORE</th></tr>` +
      last.map((l) => `<tr><td>${esc(l.project)}</td><td>${esc(l.version)}</td><td class="wrap muted">${esc(l.line)}</td></tr>`).join("") + `</table></div>`
      : `<div class="card muted">No project has a scored window.</div>`);
}

const SPR_PAST = [["version", "VERSION", "lead"], ["opened", "OPENED", ""], ["cut", "CUT", ""], ["committed", "COMMITTED", ""],
  ["delivered", "DELIVERED", "glance"], ["carried", "CARRIED", ""], ["dropped", "DROPPED", ""], ["interrupted", "INTERRUPTED", ""], ["timing", "TIMING", "glance"]];
// The scored windows, newest first; the version links to its page.
function sprPast(past) {
  if (!past.length) return `<div class="card muted">No window has been cut with a score yet.</div>`;
  const body = past.map((p) => `<tr>${SPR_PAST.map(([k]) => k === "version" ? `<td>${tblLink(p.link, p.version)}</td>` :
    `<td${p.timing && p.timing !== "on time" && k === "timing" ? ` class="warn"` : ""}>${pDash(p[k])}</td>`).join("")}</tr>`).join("");
  return `<div class="panel scroll"><table class="tbl"><tr>${SPR_PAST.map(([, h, r]) => `<th data-role="${r}" data-label="${h}">${h}</th>`).join("")}</tr>${body}</table></div>`;
}

$("projects").addEventListener("click", (e) => {
  if (e.target.closest("#spg-back")) { e.preventDefault(); sprBack(); }
});
