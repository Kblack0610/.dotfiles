"use strict";
// The Releases tab: every channel, what is pinned there and what is live, from /api/releases
// (hub_core::releases). The table is the shared one (table.js): the server filters, sorts and
// folds the green rows by the view in the URL. A new snapshot pushes the `releases` event.

// Only the "2m ago" changes between snapshots, so this redraws without reading.
const RELEASES_AGE_MS = 60e3;
const relst = tblTab({
  tab: "releases", id: "rel", el: "releases", api: "/api/releases", hint: "search, or project:binks channel:prod status:drift",
  head: (t) => releasesHead(t.data), body: (t) => releasesBody(t.data), tail: () => releaseBuilds(),
});

const relKey = (r) => `${r.project}|${r.id}`;
const relClass = (level) => (level === "bad" ? "bad" : level === "warn" ? "warn" : "");

const REL_COLS = { project: ["project"], channel: ["channel"], pinned: ["pinned", "opt"], live: ["live"], status: ["status"], prev: ["prev", "opt"], last_deploy: ["last deploy", "opt"], telemetry: ["telemetry", "opt"], deps: ["deps", "opt"] };

function releaseRow(r) {
  const open = relKey(r) === relst.sel;
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(relKey(r))}">` +
    `<td>${esc(r.project)}</td><td class="wrap">${esc(r.label)}</td><td class="opt">${esc(r.pinned_text)}</td>` +
    `<td class="${r.status === "drift" ? "bad" : ""}">${esc(r.live_text)}</td><td class="${relClass(r.status_level)}">${esc(r.status)}</td>` +
    `<td class="opt">${esc(r.prev_text)}</td><td class="opt ${relClass(r.deploy_level)}">${esc(r.last_deploy_text)}</td>` +
    `<td class="opt ${relClass(r.watch_level)}">${esc(r.telemetry_text)}</td><td class="wrap muted opt">${esc(r.deps_text)}</td></tr>`;
  return open ? row + releaseDetail(r) : row;
}

function releaseSide(s, text) {
  return esc(text) + ` <span class="muted">from ${esc(s.source)}${s.image ? ", image " + esc(s.image) : ""}</span>` +
    (s.error ? ` <span class="warn">${esc(s.error)}</span>` : "");
}

function releaseWatch(w) {
  return `<div>${esc(w.watch)} <span class="${relClass(w.level)}">${esc(w.state)}</span>${w.since ? ` <span class="muted">since ${when(w.since)}</span>` : ""}</div>`;
}

function releaseDeploy(d) {
  const run = /^https:/.test(d.url || "") ? ` <a href="${esc(d.url)}" target="_blank" rel="noopener">run</a>` : "";
  return `<div>${when(d.at)} ${esc(d.version)} <span class="${d.state === "fail" ? "warn" : ""}">${esc(d.state)}</span>${run}</div>`;
}

function releaseDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const status = [r.drift_since ? `drift since ${when(r.drift_since)}` : "", r.probed_at ? `probed ${when(r.probed_at)}` : ""].filter(Boolean).join(", ");
  return `<tr class="wdet"><td colspan="9"><div class="sdet"><div class="muted">${status || esc(r.status)}</div>` +
    line("Pinned", releaseSide(r.pinned, r.pinned_text)) + line("Live", releaseSide(r.live, r.live_text)) +
    line("Tag", esc(r.tag || "")) + line("Where", esc(r.where || "")) +
    line("Prev", esc(r.deploys.prev || "")) +
    line("Deploys", r.deploys.error ? `<span class="warn">${esc(r.deploys.error)} (${esc(r.deploys.source)})</span>` : r.deploys.history.map(releaseDeploy).join("")) +
    line("Watches", r.telemetry.map(releaseWatch).join("")) + line("Deps", r.deps.length ? esc(r.deps_text) : "") + `</div></td></tr>`;
}

function releasesBody(d) {
  const t = d.table, rows = d.rows || [];
  const fold = d.fold ? `<div class="panel"><button class="btn sm" data-ts="green" title="list the green channels">${esc(d.fold)}</button></div>` : "";
  if (rows.length) return `<div class="panel scroll"><table class="tbl">${tblHead(t, REL_COLS)}${rows.map(releaseRow).join("")}</table></div>` + fold;
  if (fold) return `<div class="panel">Nothing needs attention.</div>` + fold;
  return `<div class="panel">${t && t.total ? "No channels match." : "No channels."}</div>`;
}

function releasesHead(d) {
  const age = d.at ? Date.now() / 1e3 - d.at : 0, stale = d.at && age > d.stale_after;
  const read = d.at ? `refreshed ${clock(d.at * 1e3)} (${ago(d.at)} ago)` : "no snapshot read";
  let html = `<h2 class="sec">Releases <span class="muted">${esc(d.question || "")}</span></h2>` +
    `<div class="cline">${esc(d.summary || "")} <span class="${stale ? "warn" : "muted"}">${esc(read)}</span></div>`;
  if (relst.err) html += `<div class="panel down">${esc(relst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// The Builds section under the channels: CI runs of the last 30 days from /api/builds
// (hub_core::builds), its own table with its own view keys (bq, bs, bsort, bdir). It draws inside
// this tab's page, so its render is the tab's and its refresh reads only its own rows.
const BUILDS_PRE = "b";
const BUILDS_HINT = "search, or repo:binks state:red owner:agent-3 workflow:Tests";
const bld = tblTab({
  tab: "releases", id: "bld", pre: BUILDS_PRE, el: "releases", api: "/api/builds", hint: BUILDS_HINT, state: { log: null },
  head: (t) => buildsHead(t.data), body: (t) => buildsBody(t.data),
  render: () => relst.render(),
});
// A refresh must not take the focus from either search box: the section repaints when it holds it.
const relRepaint = relst.repaint;
relst.repaint = () => relRepaint() || bld.repaint();

const BLD_COLS = { started: ["started", "n"], state: ["state"], repo: ["repo"], workflow: ["workflow"], branch: ["branch"], took: ["took", "n"], owner: ["owner"] };
const bldKey = (r) => `${r.forge}|${r.repo}|${r.id}|${r.attempt}`;

function buildRow(r) {
  const open = bldKey(r) === bld.sel;
  const wait = r.state === "queued" ? `wait ${secs(r.took)}` : secs(r.took);
  const row = `<tr class="br${open ? " sel" : ""}" data-bkey="${esc(bldKey(r))}">` +
    `<td class="n">${when(r.started)}</td><td class="${relClass(r.level)}">${esc(r.state)}</td><td>${esc(r.repo)}</td>` +
    `<td class="wrap">${esc(r.workflow)}</td><td class="wrap muted">${esc(r.branch)}</td><td class="n">${wait}</td>` +
    `<td class="muted">${esc(r.owner || "-")}</td></tr>`;
  return open ? row + buildDetail(r) : row;
}

function buildDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const prs = (r.prs || []).map((n) => `#${n}`).join(" ");
  const log = bld.log && bld.log.key === bldKey(r) ? `<pre class="joblog">${esc(bld.log.text)}</pre>` : "";
  const link = r.url ? `<a href="${esc(r.url)}" target="_blank" rel="noopener">Open run</a>` : "";
  return `<tr class="wdet"><td colspan="7"><div class="sdet"><div class="muted">${esc(r.title || r.workflow)}</div>` +
    line("Run", `${esc(r.forge)} ${esc(r.repo)} #${r.id}${r.attempt > 1 ? " attempt " + r.attempt : ""} ${link}`) +
    line("Event", esc(r.event)) + line("Branch", esc(r.branch)) + line("Owner", esc(r.owner || "")) + line("PRs", esc(prs)) + log + `</div></td></tr>`;
}

function buildsBody(d) {
  const t = d.table, rows = d.rows || [];
  if (!rows.length) return `<div class="panel">${t && t.total ? "No runs match." : "No runs in the ledger."}</div>`;
  return `<div class="panel scroll"><table class="tbl">${tblHead(t, BLD_COLS)}${rows.map(buildRow).join("")}</table>` +
    (d.more > 0 ? `<div class="muted">${d.more} older not shown; narrow the search to list them.</div>` : "") + `</div>`;
}

function buildsHead(d) {
  const stale = d.at && Date.now() / 1e3 - d.at > d.stale_after;
  let html = `<h2 class="sec" id="sec-builds">Builds <span class="muted">${esc(d.summary || "")}</span>` +
    (stale ? ` <span class="warn">ledger older than ${dur(d.stale_after / 60)}</span>` : "") + `</h2>`;
  if (bld.err) html += `<div class="panel down">${esc(bld.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}

// The channels' tail: the Builds block, once it has been read.
function releaseBuilds() {
  if (!bld.data) return bld.err ? `<div class="panel down">${esc(bld.err)}</div>` : "";
  if (!bld.data.table) return `<div id="bld-head">${buildsHead(bld.data)}</div>`;
  return `<div data-tbl="${BUILDS_PRE}"><div id="bld-head">${buildsHead(bld.data)}</div>${tblBar("bld", bld.data.table, BUILDS_HINT)}` +
    `<div id="bld-body">${buildsBody(bld.data)}</div></div>`;
}

// A run's failed-job log, read when its row opens and never before.
async function openBuild(key, r) {
  bld.sel = key;
  bld.log = { key, text: "Loading..." };
  relst.render();
  const q = new URLSearchParams({ forge: r.forge, repo: r.repo, id: r.id, attempt: r.attempt });
  try { bld.log.text = (await api("/api/builds/log?" + q)) || "(empty)"; } catch (e) { bld.log.text = e.message; }
  if (st.tab === "releases" && bld.sel === key) relst.render();
}

$("releases").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest(".wdet") || t.closest("button")) return;
  const tr = t.closest("tr.br");
  if (!tr) return;
  const key = tr.dataset.bkey;
  if (bld.sel === key) { bld.sel = null; bld.log = null; relst.render(); return; }
  const r = (bld.data.rows || []).find((x) => bldKey(x) === key);
  if (r) openBuild(key, r);
});

$("releases").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest(".wdet") || t.closest("button")) return;
  const tr = t.closest("tr.jr");
  if (!tr) return;
  relst.sel = relst.sel === tr.dataset.key ? null : tr.dataset.key;
  relst.render();
});

const relFeed = pushed("releases", ["releases"], relst.refresh);
const bldFeed = pushed("releases", ["builds"], bld.refresh);
const ageReleases = poll("releases", () => relst.render(), RELEASES_AGE_MS);
TABS.releases = {
  // Always read: a link from a Projects card arrives here with a new view in the URL.
  show() { relFeed.show(true); bldFeed.show(true); ageReleases(); },
  onEvent(ev) { relFeed.onEvent(ev); bldFeed.onEvent(ev); },
};
