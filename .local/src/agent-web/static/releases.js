"use strict";
// The Releases tab: every app, what is live where it matters most and its worst status, from
// /api/releases (hub_core::releases). The table is the shared one (table.js): the server filters
// and sorts by the view in the URL. An opened app lists its headline env's channels, the other
// envs in a fold under them, then its changelog. A new snapshot pushes the `releases` event.
// The page is the layout's inner tabs (hub_core::layout, app.js INNER_TABS): Apps (the head, the
// table and an opened app) and Release runs, the strip above them. CI runs and Tests are Infra's.

// Only the "2m ago" changes between snapshots, so this redraws without reading.
const RELEASES_AGE_MS = 60e3;
// Which folds on the tab are open (an app's other envs, Release runs' folds), so a repaint keeps them as they were.
const REL_OPEN = {};
const relst = tblTab({
  tab: "releases", id: "rel", el: "releases", api: "/api/releases", hint: "search, or project:binks channel:prod status:drift",
  open: () => REL_OPEN,
  head: (t) => innerStrip("releases", relFlagged()) + innerWrap("releases", "table", releasesHead(t.data)),
  lead: () => innerStrip("releases", relFlagged()),
  body: (t) => releasesBody(t.data),
  wrap: (html) => innerWrap("releases", "table", html),
  tail: () => innerWrap("releases", "runs", relRuns.block()),
});
// The sections needing a look, the strip's counts: each read says its own (Releases::needs_look,
// Builds::needs_look on the release runs).
const relFlagged = () => [relst.data?.look && "table", relRuns.data?.look && "runs"].filter(Boolean);

const relKey = (a) => a.project;
// The channel whose detail is open inside an opened app, `project|id`.
let relCh = null;
const chKey = (r) => `${r.project}|${r.id}`;

const REL_COLS = { project: ["app"], live: ["live"], status: ["status"], channels: ["channels"], released: ["released"], last_deploy: ["last deploy"] };

function releaseRow(a) {
  const open = relKey(a) === relst.sel;
  const row = `<tr class="jr${open ? " sel" : ""}" data-key="${esc(relKey(a))}">` +
    `<td>${esc(a.project)}${a.stage ? ` <span class="${levelClass(a.stage_level) || "muted"}">${esc(a.stage)}</span>` : ""}</td><td class="wrap">${esc(a.live_text)}</td><td class="${levelClass(a.level)}">${esc(a.status_text)}</td>` +
    `<td class="wrap${a.unread ? " warn" : ""}">${esc(a.channels_text)}</td><td class="muted">${esc(a.released_text)}</td>` +
    `<td class="${levelClass(a.deploy_level)}">${esc(a.last_deploy_text)}</td></tr>`;
  return open ? row + appDetail(a) : row;
}

// One channel of an opened app; its own detail opens under it on a click.
function channelRow(r) {
  const open = chKey(r) === relCh;
  const where = r.status === "unknown" ? `<span class="warn">${esc(r.live.error || r.pinned.error || "")}</span>` : esc(r.where || "");
  const row = `<tr class="rc${open ? " sel" : ""}" data-ch="${esc(chKey(r))}"><td>${esc(r.channel)}</td><td class="wrap">${esc(r.id)}</td>` +
    `<td class="${r.status === "drift" ? "bad" : ""}">${esc(r.live_text)}</td><td>${esc(r.pinned_text)}</td>` +
    `<td class="${levelClass(r.status_level)}">${esc(r.status_text)}</td><td class="wrap muted">${where}</td></tr>`;
  return open ? row + releaseDetail(r) : row;
}

const CH_HEAD = '<tr><th data-role="lead">channel</th><th>id</th><th data-role="glance" data-named>live</th><th>pinned</th><th data-role="glance">status</th><th data-role="glance">where</th></tr>';
const chTable = (rows) => `<div class="scroll"><table class="tbl">${CH_HEAD}${rows.map(channelRow).join("")}</table></div>`;

// The opened app: its headline env's channels, the other envs in a fold that starts open, its
// release history, then what the picked tag shipped.
function appDetail(a) {
  const lead = a.channels.slice(0, a.lead), rest = a.channels.slice(a.lead);
  const others = rest.length
    ? cfold(`rel-env:${a.project}`, `<b>${rest.length} other channel${rest.length === 1 ? "" : "s"}</b> <span class="muted">${esc(a.others_text)}</span>`, chTable(rest), REL_OPEN, true)
    : "";
  const stage = `<div class="cline"><b>Stage</b> <span class="${levelClass(a.stage_level) || "muted"}">${esc(a.stage_text)}</span></div>`;
  return `<tr class="wdet"><td colspan="6"><div class="sdet">${stage}${chTable(lead)}${others}${releaseHistory(a)}` +
    `<div class="cline"><b>Changelog</b> ${releaseChangelog(a)}</div></div></td></tr>`;
}

// Which tags a history lists, as the collector named the line.
const LINE_SAYS = { release: "release tags", build: "build tags (no release tag yet)" };

// The opened app's releases, newest first: when each was tagged, the one before it, the
// channels it reached, its PRs and their board rows (hub_core::release_graph). A click shows that tag's changelog below.
function releaseHistory(a) {
  const h = a.history || [];
  if (!h.length) return `<div class="cline"><b>Releases</b> <span class="muted">no tags read</span></div>`;
  const shown = relcl.project === a.project ? relcl.data?.tag : null;
  const rows = h.map((s) => `<tr class="rh${s.tag === shown ? " sel" : ""}" data-project="${esc(a.project)}" data-tag="${esc(s.tag)}">` +
    `<td>${esc(s.tag)}</td><td class="n">${esc(s.at_text)}</td><td class="muted">${esc(s.prev || "-")}</td>` +
    `<td class="wrap${s.reached.length ? "" : " muted"}">${esc(s.reached_text)}</td>` +
    `<td class="wrap${s.prs.length ? "" : " muted"}">${esc(s.prs_text)}</td><td class="wrap${s.rows.length ? "" : " muted"}">${esc(s.rows_text)}</td></tr>`).join("");
  const body = `<div class="scroll"><table class="tbl"><tr><th data-role="lead">release</th><th data-role="glance" data-named>released</th><th>prev</th><th data-role="glance">reached</th><th>prs</th><th>rows</th></tr>${rows}</table></div>`;
  return cfold(`rel-hist:${a.project}`, `<b>Releases</b> <span class="muted">${h.length} ${esc(LINE_SAYS[a.line] || "tags")}</span>`, body, REL_OPEN, true);
}

function releaseSide(s, text) {
  return esc(text) + ` <span class="muted">from ${esc(s.source)}${s.image ? ", image " + esc(s.image) : ""}` +
    `${s.build ? ", build " + esc(s.build) : ""}${s.reason ? ": " + esc(s.reason) : ""}</span>` +
    (s.error ? ` <span class="warn">${esc(s.error)}</span>` : "");
}

function releaseWatch(w) {
  return `<div>${esc(w.watch)} <span class="${levelClass(w.level)}">${esc(w.state)}</span>${w.since ? ` <span class="muted">since ${when(w.since)}</span>` : ""}</div>`;
}

// The opened app's changelog: one read at a time, and the newest answer wins, so a slow read for
// an app closed since cannot overwrite the one now open.
const relcl = { project: null, data: null, err: null, loading: false, seq: 0 };

async function loadChangelog(project, tag = "") {
  const mine = ++relcl.seq;
  if (relcl.project !== project) relcl.data = null;
  Object.assign(relcl, { project, err: null, loading: true });
  relst.render();
  try {
    const d = await api(`/api/releases/changelog?project=${encodeURIComponent(project)}${tag ? "&tag=" + encodeURIComponent(tag) : ""}`);
    if (mine === relcl.seq) relcl.data = d;
  } catch (e) {
    if (mine === relcl.seq) relcl.err = e.message;
  }
  if (mine !== relcl.seq) return;
  relcl.loading = false;
  relst.render();
}

// What the tag shipped, with every tag of the project to pick from, newest first.
function releaseChangelog(r) {
  const c = relcl, d = c.data;
  if (c.project !== r.project) return "";
  const warn = c.err ? `<span class="warn">${esc(c.err)}</span>` : "";
  if (!d) return warn || `<span class="muted">reading...</span>`;
  const opts = d.tags.map((t) => `<option${t === d.tag ? " selected" : ""}>${esc(t)}</option>`).join("");
  const says = warn || `<span class="muted">${esc(d.range)}, from ${esc(d.source)}${c.loading ? ", reading..." : ""}</span>`;
  const text = c.err ? "" : d.text ? `<div class="md rel-cl">${md(d.text)}</div>` : `<div class="muted">No merged PRs in ${esc(d.range)}.</div>`;
  return `<select class="rel-tag" aria-label="Changelog tag" data-project="${esc(r.project)}">${opts}</select> ${says}${text}`;
}

function releaseDeploy(d) {
  const run = /^https:/.test(d.url || "") ? ` <a href="${esc(d.url)}" target="_blank" rel="noopener">run</a>` : "";
  return `<div>${when(d.at)} ${esc(d.version)}${d.build ? ` <span class="muted">build ${esc(d.build)}</span>` : ""} <span class="${d.state === "fail" ? "warn" : ""}">${esc(d.state)}</span>${run}</div>`;
}

// An opened channel: both sides with their sources, its deploys, watches and deps.
function releaseDetail(r) {
  const line = (k, v) => (v ? `<div class="cline"><b>${k}</b> ${v}</div>` : "");
  const status = [r.drift_since ? `drift since ${when(r.drift_since)}` : "", r.probed_at ? `probed ${when(r.probed_at)}` : ""].filter(Boolean).join(", ");
  return `<tr class="rcd"><td colspan="6"><div class="sdet"><div class="muted">${status || esc(r.status_text)}</div>` +
    line("Pinned", releaseSide(r.pinned, r.pinned_text)) + line("Live", releaseSide(r.live, r.live_text)) +
    line("Tag", esc(r.tag || "")) + line("Where", esc(r.where || "")) +
    line("Prev", esc(r.deploys.prev || "")) + line("Last deploy", r.deploys.last ? esc(r.last_deploy_text) : "") +
    line("Deploys", r.deploys.error ? `<span class="warn">${esc(r.deploys.error)} (${esc(r.deploys.source)})</span>` : r.deploys.history.map(releaseDeploy).join("")) +
    line("Watches", r.telemetry.map(releaseWatch).join("")) + line("Deps", r.deps.length ? esc(r.deps_text) : "") + `</div></td></tr>`;
}

function releasesBody(d) {
  const t = d.table, rows = d.rows || [];
  if (rows.length) return `<div class="panel scroll"><table class="tbl">${tblHead(t, REL_COLS)}${rows.map(releaseRow).join("")}</table></div>`;
  return `<div class="panel">${t && t.total ? "No apps match." : "No apps."}</div>`;
}

function releasesHead(d) {
  const age = d.at ? Date.now() / 1e3 - d.at : 0, stale = d.at && age > d.stale_after;
  const read = d.at ? `refreshed ${clock(d.at * 1e3)} (${ago(d.at)} ago)` : "no snapshot read";
  let html = `<h2 class="sec">Releases <span class="muted">${esc(d.question || "")}</span></h2>` +
    `<div class="cline">${esc(d.summary || "")} <span class="${stale ? "warn" : "muted"}">${esc(read)}</span></div>`;
  if (d.gaps) html += `<div class="cline warn">${esc(d.gaps)}</div>`;
  if (relst.err) html += `<div class="panel down">${esc(relst.err)}</div>`;
  if ((d.errors || []).length) html += `<div class="panel down">${d.errors.map((e) => `<div>${esc(e)}</div>`).join("")}</div>`;
  return html;
}
// The Release runs inner tab: the CI runs the release graph tied to a release (Builds::releases,
// scope=release), drawn by ci.js's run table under this tab's own view keys (bq, bs, bsort, bdir).
// It draws inside this tab's page, so its render is the tab's. Every run is Infra's CI runs.
const relRuns = runsTable({
  tab: "releases", id: "relrun", el: "releases", scope: "release", title: "Release runs", folds: REL_OPEN,
  lead: `<div class="cline muted">The runs that deployed or ran on a release tag; every run is on <a href="#infra/runs">Infra, CI</a>.</div>`,
  none: "No run tied to a release in 30 days.", render: () => relst.render(),
});
// A refresh must not take the focus from either search box: the section repaints when it holds it.
const relRepaint = relst.repaint;
relst.repaint = () => relRepaint() || relRuns.repaint();
$("releases").addEventListener("toggle", (e) => { if (e.target.dataset?.k) REL_OPEN[e.target.dataset.k] = e.target.open; }, true);

$("releases").addEventListener("click", (e) => {
  const t = e.target;
  if (t.closest("a") || t.closest("button") || t.closest("summary") || t.closest("select") || t.closest("tr.rcd")) return;
  const rh = t.closest("tr.rh");
  if (rh) { loadChangelog(rh.dataset.project, rh.dataset.tag); return; }
  const ch = t.closest("tr.rc");
  if (ch) { relCh = relCh === ch.dataset.ch ? null : ch.dataset.ch; relst.render(); return; }
  if (t.closest(".wdet")) return;
  const tr = t.closest("tr.jr");
  if (!tr) return;
  relst.sel = relst.sel === tr.dataset.key ? null : tr.dataset.key;
  relCh = null;
  if (relst.sel) loadChangelog(relst.sel);
  else relst.render();
});

$("releases").addEventListener("change", (e) => {
  const pick = e.target.closest("select.rel-tag");
  if (pick) loadChangelog(pick.dataset.project, pick.value);
});

const relFeed = pushed("releases", ["releases"], relst.refresh);
const relRunsFeed = pushed("releases", ["builds"], relRuns.refresh);
const ageReleases = poll("releases", () => relst.render(), RELEASES_AGE_MS);
TABS.releases = {
  // Always read: a link from a Projects card arrives here with a new view in the URL.
  show() { relFeed.show(true); relRunsFeed.show(true); ageReleases(); },
  onEvent(ev) { relFeed.onEvent(ev); relRunsFeed.onEvent(ev); },
};
