"use strict";
// Projects' Ladder inner tab (stages.md at a glance): the Gate, Filer and Kinds lines, Projects by
// stage (/api/stages, each staged project against its next stage, failing first) and the
// Requirements of every stage (/api/stages/requirements, the doc's own table, read live). The rows
// and words are hub_core::stages', the ones the hub TUI draws. Each table keeps its own view keys
// (l and r prefixed) because the list keeps the plain ones. A project row opens its Stage page.

const L_COLS = { project: ["project"], type: ["type"], stage: ["stage"], next: ["next"], met: ["met", "n"], failing: ["failing", "n"], filed: ["filed", "n"] };
const R_COLS = { stage: ["stage"], applies: ["applies"], requirement: ["requirement"], check: ["check"], by: ["by"] };

const lShown = () => st.tab === "projects" && !pst.open && pTab() === "ladder";

// The three lines under the head, each in its level's color, and the doc the tables read.
const lLine = (name, says, level, href) =>
  `<div class="cline vital${level === "bad" || level === "warn" ? " " + level : ""}"><b>${name}</b> ` +
  (href ? `<a href="${esc(href)}">${esc(says)}</a>` : esc(says)) + "</div>";

const ladst = tblTab({
  tab: "projects", id: "p-lad", el: "p-lstages", pre: "l", api: "/api/stages", hint: "search, or stage:dev type:game",
  shown: lShown, wait: "Reading the nightly stage pass...",
  got: (t) => pCountSet("ladder", t.data?.failing),
  head: (t) => secHead("stages", "Projects by stage", tblCount(t.data.table), t.data.failing ? "bad" : null) +
    `<div>${lLine("Gate", t.data.gate_says, t.data.gate_level)}${lLine("Filer", t.data.filer_says, t.data.filer_level, t.data.filer_href)}` +
    `${lLine("Kinds", t.data.kinds_says, t.data.kinds_level)}<div class="cline vital"><b>Doc</b> <code>${esc(t.data.doc)}</code></div></div>`,
  body: (t) => lBody(t.data),
});

// A project: its check could not run (red, why on hover), or its next stage's counts. A not-yet row
// is a TODO, never a failure; a human row waits on a sign-off.
function lRow(r) {
  const why = r.error ? `<td class="n bad" title="${esc(r.error)}">${NOT_READ}</td>` :
    `<td class="n${r.fail ? " bad" : ""}" title="${r.fail} failing, ${r.todo} not yet (TODO), ${r.human} human">${r.fail}${r.todo ? ` <span class="muted">${r.todo} todo</span>` : ""}</td>`;
  return `<tr class="jr" tabindex="0" data-open="${esc(r.profile + "/" + r.name)}" data-inner="stage">` +
    `<td>${rec2(esc(r.name), r.name, esc(r.profile), r.profile)}</td>` +
    `<td>${pDash(r.type)}</td><td>${pDash(r.stage)}</td><td>${pDash(r.next)}</td>` +
    `<td class="n" title="${r.met} of ${r.total} checked rows of ${esc(r.next)} pass">${pDash(r.met_says)}</td>${why}` +
    `<td class="n" title="filed by the nightly pass: open/closed">${pDash(r.filed_says)}</td></tr>`;
}

function lBody(d) {
  const t = d.table;
  if (d.rows.length) return `<div class="panel scroll"><table class="tbl">${tblHead(t, L_COLS)}${d.rows.map(lRow).join("")}</table></div>`;
  return `<div class="card muted">${esc(d.says || (t.total ? "No project matches." : "No project is at dev or later."))}</div>`;
}

const reqst = tblTab({
  tab: "projects", id: "p-req", el: "p-lreqs", pre: "r", api: "/api/stages/requirements", hint: "search, or stage:prod check:human applies:game",
  shown: lShown, wait: "Reading stages.md...",
  head: (t) => secHead("requirements", "Requirements", tblCount(t.data.table)),
  body: (t) => rBody(t.data),
});

// A requirement: its check kind as the doc's word, the check itself on hover; a predicate in code.
const R_KIND = { test: "", human: "warn", "not yet": "muted" };
const rLine = (r) =>
  `<tr><td>${esc(r.stage)}</td><td>${esc(r.applies.join(" "))}</td><td>${clamp2(esc(r.requirement), r.requirement)}</td>` +
  `<td${R_KIND[r.says] ? ` class="${R_KIND[r.says]}"` : ""} title="${esc(r.check)}">${esc(r.says)}</td><td>${pDash(r.skills.join(" "))}</td></tr>`;

function rBody(d) {
  const t = d.table;
  if (d.rows.length) return `<div class="panel scroll"><table class="tbl">${tblHead(t, R_COLS)}${d.rows.map(rLine).join("")}</table></div>`;
  return `<div class="card muted">${esc(d.says || (t.total ? "No requirement matches." : "stages.md has no Requirements rows."))}</div>`;
}

// Both tables read while the tab shows, and again on a new stages.json (the `stages` event).
function lRead() {
  if (!lShown()) return;
  ladst.refresh(); reqst.refresh();
}
