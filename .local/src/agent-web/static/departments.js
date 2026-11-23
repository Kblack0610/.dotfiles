"use strict";
// Projects > Coverage (/api/coverage: every typed project's department cells, worst first) and an
// opened product's department tabs (/api/projects/{name}/departments), both from
// hub_core::departments, the cells and words the hub TUI draws. Coverage keeps c-prefixed view
// keys because the list keeps the plain ones; a row opens its product, a cell that department.

const C_COLS = { project: ["project"], type: ["type"], stage: ["stage"], product: ["product"], engineering: ["engineering"], ops: ["ops"], design: ["design"], analytics: ["analytics"], marketing: ["marketing"], legal: ["legal"], support: ["support"], money: ["money"] };
const C_TONE = { red: "bad", amber: "warn", off: "muted" };
const cTone = (w) => (C_TONE[w] ? ` class="${C_TONE[w]}"` : "");
const cShown = () => st.tab === "projects" && !pst.open && pTab() === "coverage";

const covst = tblTab({
  tab: "projects", id: "p-cv", el: "p-cov", pre: "c", api: "/api/coverage", hint: "search, or type:game stage:beta",
  shown: cShown, wait: "Reading every product's departments (it probes their URLs)...",
  got: (t) => pCountSet("coverage", t.data?.failing),
  head: (t) => secHead("coverage", "Coverage", t.data.head, t.data.red ? "bad" : null) +
    (t.data.says || []).map((s) => `<div class="panel down">${esc(s)}</div>`).join(""),
  body: (t) => cBody(t.data),
});

function cRow(r, i, t, depts) {
  const l = tblLinks(t, i);
  return `<tr class="jr" tabindex="0" data-open="${esc(r.key)}"><td>${tblLink(l.project, r.name)}</td>` +
    `<td>${pDash(r.type)}</td><td>${pDash(r.stage)}</td>` +
    depts.map(([d]) => { const w = r.cells[d] || "off"; return `<td${cTone(w)}>${tblLink(l[d], w)}</td>`; }).join("") + `</tr>`;
}

function cBody(d) {
  const t = d.table;
  const legend = t.legend ? `<div class="muted qstats">${esc(t.legend)}</div>` : "";
  if (d.rows.length) return `<div class="panel scroll"><table class="tbl">${tblHead(t, C_COLS)}${d.rows.map((r, i) => cRow(r, i, t, d.departments)).join("")}</table></div>` + legend;
  return `<div class="card muted">${esc(t.total ? "No product matches." : "No typed project: project-map.json gives none a type.")}</div>`;
}

function cRead() { if (cShown()) covst.refresh(); }

// An opened product's tabs, by project key: {data} or {err}, read once per open.
const deptGot = {};
async function deptRead(key) {
  try { deptGot[key] = { data: await api(`/api/projects/${encodeURIComponent(key)}/departments`) }; }
  catch (e) { deptGot[key] = { err: e.message }; }
  if (st.tab === "projects" && pst.open === key) renderProjects();
}
const deptOf = (key, id) => deptGot[key]?.data?.product?.depts?.find((d) => d.id === id) || null;
// The strip's count on a department: what needs the human there, as the TUI counts it.
const deptCounts = (key) => deptGot[key]?.data?.dept_needs || {};
const deptTotal = (key) => Object.values(deptCounts(key)).reduce((a, n) => a + n, 0);

const D_PART = {
  "-needs": (d, sec) => secHead(sec, "Needs you", d.needs.length, d.needs[0]?.level) + (d.needs.length
    ? `<div class="card">${d.needs.map((n) => `<div class="${n.level === "ok" ? "" : esc(n.level)}">${esc(n.says)}</div>`).join("")}</div>`
    : `<div class="card muted">${d.due_at ? `Nothing; ${esc(d.title)} is due at ${esc(d.due_at)}.` : "Nothing."}</div>`),
  "-outbound": (d, sec) => secHead(sec, "Outbound", d.outbound.length ? `${d.outbound.filter((i) => i.state === "sent").length} sent in 30d` : null) + (d.outbound.length
    ? `<div class="panel scroll"><table class="tbl"><tr><th>when</th><th>channel</th><th>kind</th><th data-role="lead">item</th><th>review</th><th data-role="glance">state</th><th>result</th></tr>` +
      d.outbound.map((i) => `<tr><td>${when(i.sent || i.created)}</td><td>${esc(i.channel)}</td><td>${esc(i.kind)}</td>` +
        `<td class="wrap">${tblLink(i.url, i.title)} <span class="muted">${esc(i.id)}</span></td>` +
        `<td>${pDash([i.verdict, i.reviewed_by].filter(Boolean).join(" by "))}</td>` +
        `<td class="${i.state === "sent" ? "" : i.state === "review" ? "warn" : "muted"}">${esc(i.state)}</td><td>${pDash(i.results)}</td></tr>`).join("") + `</table></div>`
    : `<div class="card muted">${esc(d.outbound_says || "Nothing in the outbound ledger: mkt draft opens an item, mkt log records a hand post.")}</div>`),
  "-checks": (d, sec) => secHead(sec, "Checklist", d.checks.length ? `${d.checks.filter((c) => c.state === "ok").length} of ${d.checks.length}` : null) + (d.checks.length
    ? `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">item</th><th data-role="glance">state</th><th>says</th><th>evidence</th></tr>` +
      d.checks.map((c) => `<tr><td>${esc(c.item)}</td><td class="${levelClass(c.level) || (c.state === "ok" ? "" : "muted")}">${esc(c.state)}</td>` +
        `<td>${pDash(c.says)}</td><td class="wrap">${/^https?:/.test(c.evidence) ? tblLink(c.evidence, c.evidence) : pDash(c.evidence)}</td></tr>`).join("") + `</table></div>`
    : `<div class="card muted">No store file yet: game.json or mobile/metadata.yaml.</div>`),
  "-numbers": (d, sec) => secHead(sec, "Numbers", d.numbers.length || null) + `<div class="card">` + (d.numbers.length
    ? d.numbers.map((n) => `<div class="cline"><b>${esc(n.metric)}</b> ${esc(n.says)}</div>`).join("")
    : `<div class="muted">${esc(d.numbers_says)}</div>`) +
    (d.grafana ? `<div class="cline">${tblLink(d.grafana, "trends in Grafana")}</div>` : "") + `</div>`,
  "-pipes": (d, sec) => secHead(sec, "Pipelines", d.pipes.length) + (d.pipes.length
    ? `<div class="panel scroll"><table class="tbl"><tr><th data-role="lead">source</th><th>kind</th><th>for</th><th data-role="glance">last</th><th data-role="glance">verdict</th><th>record</th></tr>` +
      d.pipes.map((p) => `<tr><td>${esc(p.source)}</td><td>${esc(p.kind)}</td><td class="muted">${p.shared ? "every product" : "this one"}</td>` +
        `<td${p.found === "ok" ? "" : p.found === "missing" ? ` class="${p.shared ? "warn" : "bad"}"` : ` class="muted"`}>${pDash(p.last_says)}</td>` +
        `<td class="${levelClass(p.level)}">${pDash(p.verdict)}</td><td class="wrap">${pDash(p.record)}</td></tr>`).join("") + `</table></div>`
    : `<div class="card muted">No pipeline in departments.tsv feeds ${esc(d.title)}.</div>`),
};

// A department pane: its question, then each section PROJECT_DEPTS gives it, in that order.
function deptPane(key, id) {
  const got = deptGot[key];
  if (!got) return `<div class="muted">Reading the departments...</div>`;
  if (got.err) return `<div class="panel down">${esc(got.err)}</div>`;
  const d = deptOf(key, id);
  if (!d) return `<div class="card muted">${esc(got.data.says || NOT_READ)}</div>`;
  const secs = PROJECT_DEPTS.find((t) => t[0] === id)[2];
  return `<div class="muted qstats">${esc(d.question)}</div>` +
    secs.map((s) => D_PART[s.slice(s.lastIndexOf("-"))](d, s)).join("");
}
